import AppKit
import AVFoundation
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate {
    private enum State {
        case idle, listening, finishing
    }

    private static let languageDefaultsKey = "Language"
    private static let translationDefaultsKey = "Translation"

    private var statusItem: NSStatusItem!
    private let menu = NSMenu()
    private let toggleItem = NSMenuItem(title: "", action: #selector(toggleDictation), keyEquivalent: "")
    private let statusLine = NSMenuItem(title: "آماده", action: nil, keyEquivalent: "")
    private var languageItems: [LiveDictation.LanguageMode: NSMenuItem] = [:]
    private var translationItems: [LiveDictation.Translation: NSMenuItem] = [:]

    private let model = DashboardModel()
    private var dashboard: NSWindow?

    private let capture = AudioCapture()
    private let speech = GroqSpeech()
    private lazy var dictation = LiveDictation(
        speech: speech,
        output: { delete, insert in
            // With the dashboard in front there is nowhere to type; it shows the text itself.
            guard NSWorkspace.shared.frontmostApplication?.processIdentifier != ProcessInfo.processInfo.processIdentifier else { return }
            TextTyper.backspace(delete)
            TextTyper.type(insert)
        },
        frontApp: { NSWorkspace.shared.frontmostApplication?.processIdentifier })
    private var hotkey: HotkeyManager?

    private var state: State = .idle {
        didSet { refreshUI() }
    }

    // MARK: - Lifecycle

    func applicationDidFinishLaunching(_ notification: Notification) {
        setUpStatusItem()
        setUpMenu()
        setUpDictation()

        hotkey = HotkeyManager { [weak self] in self?.toggleDictation() }
        if hotkey?.register() != true {
            report("ثبت شورت‌کات ⌘⇧D ناموفق بود (احتمالاً برنامهٔ دیگری آن را گرفته).")
        }

        requestMicrophoneAccess()
        TextTyper.requestAccessibility()
        refreshUI()
        checkKey()
        showDashboard()
    }

    /// Opening the app again (Finder, Spotlight, `open`) while it runs.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showDashboard()
        return false
    }

    func applicationWillTerminate(_ notification: Notification) {
        capture.stop()
    }

    private func setUpStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        guard let button = statusItem.button else { return }
        button.target = self
        button.action = #selector(statusItemClicked(_:))
        button.sendAction(on: [.leftMouseUp, .rightMouseUp])
    }

    private func setUpMenu() {
        toggleItem.target = self
        statusLine.isEnabled = false
        menu.addItem(toggleItem)
        let dashboardItem = NSMenuItem(title: "داشبورد…", action: #selector(showDashboard), keyEquivalent: "")
        dashboardItem.target = self
        menu.addItem(dashboardItem)
        menu.addItem(.separator())

        let saved = UserDefaults.standard.string(forKey: Self.languageDefaultsKey)
        dictation.languageMode = saved.flatMap(LiveDictation.LanguageMode.init(rawValue:)) ?? .auto
        let titles: [(LiveDictation.LanguageMode, String)] = [(.auto, "زبان: خودکار"), (.fa, "فارسی"), (.en, "English")]
        for (mode, title) in titles {
            let item = NSMenuItem(title: title, action: #selector(languageChosen(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = mode.rawValue
            languageItems[mode] = item
            menu.addItem(item)
        }

        menu.addItem(.separator())
        let savedTranslation = UserDefaults.standard.string(forKey: Self.translationDefaultsKey)
        dictation.translation = savedTranslation.flatMap(LiveDictation.Translation.init(rawValue:)) ?? .off
        let translations: [(LiveDictation.Translation, String)] = [
            (.off, "بدون ترجمه"), (.english, "ترجمه به انگلیسی"), (.persian, "ترجمه به فارسی")]
        for (translation, title) in translations {
            let item = NSMenuItem(title: title, action: #selector(translationChosen(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = translation.rawValue
            translationItems[translation] = item
            menu.addItem(item)
        }

        menu.addItem(.separator())
        menu.addItem(statusLine)
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "خروج", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
    }

    private func setUpDictation() {
        dictation.onText = { [weak self] text, language in
            DispatchQueue.main.async { self?.model.add(text, language: language) }
        }
        dictation.onLive = { [weak self] text in
            DispatchQueue.main.async { self?.model.live = text }
        }
        dictation.onLevel = { [weak self] level in
            DispatchQueue.main.async { self?.model.level = level }
        }
        model.onToggle = { [weak self] in self?.toggleDictation() }
        model.onLanguage = { [weak self] mode in self?.setLanguage(mode) }
        model.onTranslation = { [weak self] translation in self?.setTranslation(translation) }
        dictation.translate = { try await Translator.translate($0, to: "fa") }
        dictation.onNotice = { [weak self] message in
            DispatchQueue.main.async { self?.setStatus(message) }
        }
        model.onSaveKey = { [weak self] key in
            GroqSpeech.store(apiKey: key)
            self?.checkKey()
        }
        dictation.onError = { [weak self] error in
            DispatchQueue.main.async { self?.report(error.localizedDescription) }
        }
        dictation.onFinished = { [weak self] in
            DispatchQueue.main.async { self?.finished() }
        }
    }

    private func requestMicrophoneAccess() {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .audio) { [weak self] granted in
                if !granted {
                    DispatchQueue.main.async { self?.report("دسترسی میکروفون رد شد.") }
                }
            }
        case .denied, .restricted:
            report("دسترسی میکروفون در تنظیمات سیستم بسته است.")
        default:
            break
        }
    }

    /// Shows in the dashboard whether a key is stored and whether Groq accepts it.
    private func checkKey() {
        guard GroqSpeech.apiKey != nil else {
            model.keyState = .missing
            setStatus("کلید Groq را در داشبورد وارد کنید.")
            return
        }
        model.keyState = .checking
        Task { [speech] in
            let valid = await speech.validateKey()
            await MainActor.run {
                self.model.keyState = valid ? .valid : .rejected
                if self.state == .idle { self.setStatus(valid ? "آماده" : "کلید Groq پذیرفته نشد (یا اینترنت قطع است).") }
            }
        }
    }

    // MARK: - Actions

    @objc private func statusItemClicked(_ sender: NSStatusBarButton) {
        let event = NSApp.currentEvent
        let wantsMenu = event?.type == .rightMouseUp || event?.modifierFlags.contains(.control) == true
        if wantsMenu {
            showMenu()
        } else {
            toggleDictation()
        }
    }

    private func showMenu() {
        guard let button = statusItem.button else { return }
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: button.bounds.height + 4), in: button)
    }

    @objc private func languageChosen(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String,
              let mode = LiveDictation.LanguageMode(rawValue: raw) else { return }
        setLanguage(mode)
    }

    private func setLanguage(_ mode: LiveDictation.LanguageMode) {
        dictation.languageMode = mode
        UserDefaults.standard.set(mode.rawValue, forKey: Self.languageDefaultsKey)
        refreshUI()
    }

    @objc private func translationChosen(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String,
              let translation = LiveDictation.Translation(rawValue: raw) else { return }
        setTranslation(translation)
    }

    private func setTranslation(_ translation: LiveDictation.Translation) {
        dictation.translation = translation
        UserDefaults.standard.set(translation.rawValue, forKey: Self.translationDefaultsKey)
        refreshUI()
    }

    @objc private func showDashboard() {
        if dashboard == nil {
            let window = NSWindow(contentViewController: NSHostingController(rootView: DashboardView(model: model)))
            window.title = "PersianDictate"
            window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
            window.isReleasedWhenClosed = false
            window.setContentSize(NSSize(width: 480, height: 680))
            window.center()
            dashboard = window
        }
        model.refreshPermissions()
        NSApp.activate(ignoringOtherApps: true)
        dashboard?.makeKeyAndOrderFront(nil)
    }

    @objc private func toggleDictation() {
        switch state {
        case .idle: startListening()
        case .listening: stopListening()
        case .finishing: NSSound.beep()
        }
    }

    private func startListening() {
        guard AVCaptureDevice.authorizationStatus(for: .audio) == .authorized else {
            requestMicrophoneAccess()
            report("اول به میکروفون دسترسی بدهید.")
            return
        }
        guard TextTyper.isTrusted else {
            TextTyper.requestAccessibility()
            report("برای تایپ، دسترسی Accessibility لازم است.")
            return
        }
        guard GroqSpeech.apiKey != nil else {
            report("کلید Groq وارد نشده.")
            showDashboard()
            return
        }
        do {
            dictation.start()
            try capture.start { [dictation] samples in dictation.feed(samples) }
            state = .listening
            setStatus("گوش می‌دهم…")
        } catch {
            dictation.stop()
            report(error.localizedDescription)
        }
    }

    private func stopListening() {
        capture.stop()
        state = .finishing
        dictation.stop()
    }

    private func finished() {
        capture.stop()
        state = .idle
        model.level = 0
        model.live = ""
        if model.status == "گوش می‌دهم…" { setStatus("آماده") }
    }

    // MARK: - UI

    private func refreshUI() {
        let symbol: String
        let description: String
        switch state {
        case .idle: symbol = "mic"; description = "PersianDictate"
        case .listening: symbol = "mic.fill"; description = "گوش می‌دهم"
        case .finishing: symbol = "waveform"; description = "در حال تمام‌کردن"
        }
        let image = NSImage(systemSymbolName: symbol, accessibilityDescription: description)
        image?.isTemplate = true
        statusItem?.button?.image = image
        statusItem?.button?.contentTintColor = state == .listening ? .systemRed : nil
        statusItem?.button?.toolTip = "\(description) — ⌘⇧D"
        toggleItem.title = state == .listening ? "توقف دیکته" : "شروع دیکته"
        toggleItem.isEnabled = state != .finishing
        model.listening = state == .listening
        model.busy = state == .finishing
        model.language = dictation.languageMode
        model.translation = dictation.translation
        for (translation, item) in translationItems {
            item.state = translation == dictation.translation ? .on : .off
        }
        for (mode, item) in languageItems {
            item.state = mode == dictation.languageMode ? .on : .off
        }
    }

    private func setStatus(_ text: String) {
        statusLine.title = text
        model.status = text
    }

    private func report(_ message: String) {
        setStatus(message)
        NSSound.beep()
        NSLog("PersianDictate: %@", message)
    }
}
