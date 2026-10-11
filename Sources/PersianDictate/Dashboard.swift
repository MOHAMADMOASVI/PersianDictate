import AppKit
import AVFoundation
import SwiftUI

/// Everything the dashboard window shows. Mutated on the main thread only.
final class DashboardModel: ObservableObject {
    struct Entry: Codable, Identifiable {
        var id = UUID()
        let date: Date
        let text: String
        let language: String
    }

    private struct Stats: Codable {
        var total = 0
        var day = ""
        var today = 0
    }

    private static let historyLimit = 200
    private static let statsDefaultsKey = "Stats"
    static var supportDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("PersianDictate")
    }
    private static var historyURL: URL { supportDirectory.appendingPathComponent("history.json") }

    enum KeyState {
        case missing, checking, valid, rejected
    }

    @Published var listening = false
    @Published var busy = false
    @Published var status = "آماده"
    @Published var live = ""
    @Published var level: Float = 0
    @Published var language: LiveDictation.LanguageMode = .auto
    @Published var translation: LiveDictation.Translation = .off
    @Published var microphoneGranted = false
    @Published var accessibilityGranted = false
    @Published var keyState: KeyState = .missing
    /// What is being typed into the key field; never stored anywhere but the Keychain.
    @Published var keyDraft = ""
    @Published private(set) var history: [Entry] = []
    @Published private var stats = Stats()

    var onToggle: () -> Void = {}
    var onLanguage: (LiveDictation.LanguageMode) -> Void = { _ in }
    var onTranslation: (LiveDictation.Translation) -> Void = { _ in }
    var onSaveKey: (String) -> Void = { _ in }

    var wordsToday: Int { stats.day == Self.today ? stats.today : 0 }
    var wordsTotal: Int { stats.total }

    init() {
        if let data = try? Data(contentsOf: Self.historyURL),
           let saved = try? JSONDecoder().decode([Entry].self, from: data) {
            history = saved
        }
        if let data = UserDefaults.standard.data(forKey: Self.statsDefaultsKey),
           let saved = try? JSONDecoder().decode(Stats.self, from: data) {
            stats = saved
        }
    }

    func add(_ text: String, language: String) {
        history.insert(Entry(date: Date(), text: text, language: language), at: 0)
        if history.count > Self.historyLimit { history.removeLast(history.count - Self.historyLimit) }

        let words = text.split(separator: " ").count
        if stats.day != Self.today { stats.day = Self.today; stats.today = 0 }
        stats.today += words
        stats.total += words
        save()
    }

    func clearHistory() {
        history = []
        save()
    }

    func refreshPermissions() {
        microphoneGranted = AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
        accessibilityGranted = TextTyper.isTrusted
    }

    private func save() {
        try? FileManager.default.createDirectory(at: Self.supportDirectory, withIntermediateDirectories: true)
        try? JSONEncoder().encode(history).write(to: Self.historyURL, options: .atomic)
        UserDefaults.standard.set(try? JSONEncoder().encode(stats), forKey: Self.statsDefaultsKey)
    }

    private static var today: String {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: Date())
    }
}

struct DashboardView: View {
    @ObservedObject var model: DashboardModel
    private let permissionTimer = Timer.publish(every: 2, on: .main, in: .common).autoconnect()

    private static let numbers: NumberFormatter = {
        let formatter = NumberFormatter()
        formatter.locale = Locale(identifier: "fa_IR")
        formatter.numberStyle = .decimal
        return formatter
    }()

    private static let time: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "fa_IR")
        formatter.dateFormat = "d MMM، HH:mm"
        return formatter
    }()

    var body: some View {
        VStack(spacing: 16) {
            recorder
            liveBox
            HStack(spacing: 12) {
                stat("امروز", model.wordsToday, "کلمه")
                stat("در مجموع", model.wordsTotal, "کلمه")
                stat("جمله‌های اخیر", model.history.count, "مورد")
            }
            checks
            historyList
        }
        .padding(20)
        .frame(minWidth: 460, minHeight: 640)
        .environment(\.layoutDirection, .rightToLeft)
        .onAppear { model.refreshPermissions() }
        .onReceive(permissionTimer) { _ in model.refreshPermissions() }
    }

    // MARK: - Sections

    private var recorder: some View {
        VStack(spacing: 10) {
            Button(action: model.onToggle) {
                ZStack {
                    Circle()
                        .fill(model.listening ? Color.red : Color.accentColor)
                        .frame(width: 84, height: 84)
                        .overlay(Circle().stroke(Color.red.opacity(0.35), lineWidth: CGFloat(min(model.level * 120, 14))))
                    Image(systemName: model.listening ? "stop.fill" : "mic.fill")
                        .font(.system(size: 30, weight: .semibold))
                        .foregroundColor(.white)
                }
            }
            .buttonStyle(.plain)
            .disabled(model.busy)
            .animation(.easeOut(duration: 0.1), value: model.level)

            Text(verbatim: model.listening ? "گوش می‌دهم — برای توقف بزنید" : "برای شروع بزنید")
                .font(.headline)
            Text(verbatim: "\u{200F}میان‌بر \u{2066}⌘⇧D\u{2069} در هر برنامه. متن در برنامه‌ای تایپ می‌شود که جلوی صفحه است.")
                .font(.caption)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)

            Picker("", selection: Binding(get: { model.language }, set: { model.onLanguage($0) })) {
                Text(verbatim: "خودکار").tag(LiveDictation.LanguageMode.auto)
                Text(verbatim: "فارسی").tag(LiveDictation.LanguageMode.fa)
                Text(verbatim: "English").tag(LiveDictation.LanguageMode.en)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 280)

            Picker("", selection: Binding(get: { model.translation }, set: { model.onTranslation($0) })) {
                Text(verbatim: "بدون ترجمه").tag(LiveDictation.Translation.off)
                Text(verbatim: "به انگلیسی").tag(LiveDictation.Translation.english)
                Text(verbatim: "به فارسی").tag(LiveDictation.Translation.persian)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 280)
            if model.translation == .persian {
                Text(verbatim: "ترجمه به فارسی با Google Translate است و متن در هر مکث تایپ می‌شود.")
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }
        }
    }

    private var liveBox: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(verbatim: model.status).font(.caption).foregroundColor(.secondary)
            Text(verbatim: model.live.isEmpty ? "…" : model.live)
                .font(.title3)
                .foregroundColor(model.live.isEmpty ? .secondary : .primary)
                .frame(maxWidth: .infinity, minHeight: 44, alignment: .topLeading)
                .lineLimit(3)
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.primary.opacity(0.06)))
    }

    private func stat(_ title: String, _ value: Int, _ unit: String) -> some View {
        VStack(spacing: 2) {
            Text(verbatim: Self.numbers.string(from: NSNumber(value: value)) ?? "\(value)")
                .font(.system(size: 24, weight: .semibold))
            Text(verbatim: "\(title) · \(unit)").font(.caption).foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 10)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.primary.opacity(0.06)))
    }

    private var checks: some View {
        VStack(spacing: 6) {
            check("میکروفون", ok: model.microphoneGranted, pane: "Privacy_Microphone")
            check("اجازهٔ تایپ در برنامه‌ها (Accessibility)", ok: model.accessibilityGranted, pane: "Privacy_Accessibility")
            HStack {
                Image(systemName: model.keyState == .valid ? "checkmark.circle.fill" : "xmark.circle.fill")
                    .foregroundColor(model.keyState == .valid ? .green : (model.keyState == .checking ? .gray : .red))
                Text(verbatim: keyTitle)
                Spacer()
                if model.keyState == .valid {
                    Button("حذف کلید") { model.onSaveKey("") }.controlSize(.small)
                } else {
                    Button("گرفتن کلید رایگان") { NSWorkspace.shared.open(GroqSpeech.keysPage) }.controlSize(.small)
                }
            }
            if model.keyState != .valid {
                HStack {
                    SecureField("gsk_…", text: $model.keyDraft)
                        .textFieldStyle(.roundedBorder)
                        .environment(\.layoutDirection, .leftToRight)
                    Button("ذخیره") {
                        model.onSaveKey(model.keyDraft)
                        model.keyDraft = ""
                    }
                    .disabled(model.keyDraft.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
        }
        .font(.callout)
    }

    private var keyTitle: String {
        switch model.keyState {
        case .missing: return "کلید Groq وارد نشده"
        case .checking: return "در حال بررسی کلید…"
        case .valid: return "کلید Groq"
        case .rejected: return "کلید پذیرفته نشد (یا اینترنت قطع است)"
        }
    }

    private func check(_ title: String, ok: Bool, pane: String) -> some View {
        HStack {
            Image(systemName: ok ? "checkmark.circle.fill" : "xmark.circle.fill")
                .foregroundColor(ok ? .green : .red)
            Text(verbatim: title)
            Spacer()
            if !ok {
                Button("باز کردن تنظیمات") {
                    if pane == "Privacy_Accessibility" { TextTyper.requestAccessibility() }
                    NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)")!)
                }
                .controlSize(.small)
            }
        }
    }

    private var historyList: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(verbatim: "تاریخچه").font(.headline)
                Spacer()
                if !model.history.isEmpty {
                    Button("پاک کردن", action: model.clearHistory).controlSize(.small)
                }
            }
            if model.history.isEmpty {
                Text(verbatim: "هنوز چیزی دیکته نشده.")
                    .foregroundColor(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 8) {
                        ForEach(model.history) { entry in
                            HStack(alignment: .top) {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(verbatim: entry.text)
                                        .textSelection(.enabled)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                    Text(verbatim: Self.time.string(from: entry.date))
                                        .font(.caption2)
                                        .foregroundColor(.secondary)
                                }
                                Button {
                                    NSPasteboard.general.clearContents()
                                    NSPasteboard.general.setString(entry.text, forType: .string)
                                } label: {
                                    Image(systemName: "doc.on.doc")
                                }
                                .buttonStyle(.borderless)
                                .help("کپی")
                            }
                            Divider()
                        }
                    }
                }
            }
        }
        .frame(maxHeight: .infinity)
    }
}

/// `PersianDictate --snapshot out.png` draws the dashboard off screen, for checking the layout.
enum DashboardSnapshot {
    static func write(to path: String) -> Never {
        let model = DashboardModel()
        model.refreshPermissions()
        let view = NSHostingView(rootView: DashboardView(model: model).background(Color(NSColor.windowBackgroundColor)))
        view.frame = NSRect(x: 0, y: 0, width: 480, height: 680)
        let window = NSWindow(contentRect: view.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = view
        view.layoutSubtreeIfNeeded()
        guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { exit(1) }
        view.cacheDisplay(in: view.bounds, to: bitmap)
        try? bitmap.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
        exit(0)
    }
}
