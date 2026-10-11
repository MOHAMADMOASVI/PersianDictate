import Foundation

/// Turns a stream of microphone samples into live typing.
///
/// Speech is cut into segments at pauses. While a segment is still being spoken it is re-transcribed
/// every half second and the typed text is patched (backspace + retype) to match; at the pause the
/// segment gets one final pass and is then left alone.
final class LiveDictation {
    enum LanguageMode: String, CaseIterable {
        case auto, fa, en
    }

    private enum Work {
        case partial([Int16])
        case final([Int16])
    }

    private static let rate = Int(AudioCapture.sampleRate)
    private static let preroll = rate * 4 / 10
    private static let minVoiced = rate * 3 / 10
    private static let partialStep = rate / 2
    private static let pause = rate * 8 / 10
    /// Long segments make every pass slower, so they end at the first short breath.
    private static let longSegment = rate * 12
    private static let shortPause = rate * 35 / 100
    private static let maxSegment = rate * 28
    /// Whisper often respells an early word between passes. A partial may only erase this much;
    /// beyond it the typed text stays and only new words are added, until the final pass settles it.
    private static let maxPartialDelete = 24
    /// Language detection on less audio than this is a coin toss.
    private static let minDetect = rate * 3 / 2

    enum Translation: String, CaseIterable {
        /// Type what was said.
        case off
        /// Type it in English (Whisper's own translation).
        case english
        /// Type it in Persian (through `translate`, at each pause).
        case persian
    }

    var languageMode: LanguageMode = .auto
    var translation: Translation = .off
    /// Translates a finished sentence into Persian.
    var translate: ((String) async throws -> String)?
    /// Something went wrong that does not stop dictation.
    var onNotice: ((String) -> Void)?

    private let speech: GroqSpeech
    /// Applies an edit to the focused app: backspaces, then text.
    private let output: (Int, String) -> Void
    private let frontApp: () -> pid_t?

    /// A finished segment and the language it was transcribed in.
    var onText: ((String, String) -> Void)?
    /// The text of the segment being spoken, as currently typed.
    var onLive: ((String) -> Void)?
    /// Microphone level (RMS, 0…1) per chunk, on the audio queue.
    var onLevel: ((Float) -> Void)?
    var onError: ((Error) -> Void)?
    var onFinished: (() -> Void)?

    // Audio state, guarded by `queue`.
    private let queue = DispatchQueue(label: "PersianDictate.LiveDictation")
    private var running = false
    private var draining = false
    private var prerollBuffer: [Int16] = []
    private var segment: [Int16] = []
    private var inSpeech = false
    private var voiced = 0
    private var silence = 0
    private var partialMark = 0
    private var noiseFloor: Float = 0.003
    private var finals: [[Int16]] = []

    // Typing state, touched only by the worker task.
    private var typed = ""
    private var segmentLanguage: String?
    /// Language of the previous segment in this session; the best guess before detection is possible.
    private var lastLanguage: String?
    /// Set when detection contradicts the guess: what was typed is in the wrong language.
    private var rewriteAllowed = false
    private var segmentApp: pid_t?
    /// The previous sentence as Whisper wrote it, and the language of that text.
    private var context = ""
    private var contextLanguage = ""

    init(speech: GroqSpeech,
         output: @escaping (Int, String) -> Void,
         frontApp: @escaping () -> pid_t?) {
        self.speech = speech
        self.output = output
        self.frontApp = frontApp
    }

    func start() {
        queue.sync {
            running = true
            draining = false
            prerollBuffer = []
            segment = []
            inSpeech = false
            finals = []
        }
        typed = ""
        segmentLanguage = nil
        lastLanguage = nil
        segmentApp = nil
        context = ""
        Task.detached { [self] in await work() }
    }

    /// Finishes whatever is being spoken, then calls `onFinished`.
    func stop() {
        queue.sync {
            guard running, !draining else { return }
            if inSpeech { endSegment() }
            draining = true
        }
    }

    // MARK: - Audio in

    func feed(_ samples: [Int16]) {
        guard !samples.isEmpty else { return }
        queue.async { [self] in
            guard running, !draining else { return }

            let level = Self.level(of: samples)
            onLevel?(level)
            let threshold = max(0.01, noiseFloor * 3.5)
            let isVoice = level > threshold

            if !inSpeech {
                prerollBuffer.append(contentsOf: samples)
                if prerollBuffer.count > Self.preroll {
                    prerollBuffer.removeFirst(prerollBuffer.count - Self.preroll)
                }
                guard isVoice else {
                    noiseFloor = noiseFloor * 0.95 + level * 0.05
                    return
                }
                inSpeech = true
                segment = prerollBuffer
                prerollBuffer = []
                voiced = samples.count
                silence = 0
                partialMark = 0
                return
            }

            segment.append(contentsOf: samples)
            if isVoice {
                voiced += samples.count
                silence = 0
            } else {
                silence += samples.count
            }
            let limit = segment.count > Self.longSegment ? Self.shortPause : Self.pause
            if silence >= limit || segment.count >= Self.maxSegment { endSegment() }
        }
    }

    /// Call on `queue`. A segment with almost no voice in it was a click or a cough.
    private func endSegment() {
        if voiced >= Self.minVoiced { finals.append(segment) }
        segment = []
        inSpeech = false
    }

    private static func level(of samples: [Int16]) -> Float {
        var sum: Float = 0
        for sample in samples {
            let value = Float(sample) / 32768
            sum += value * value
        }
        return (sum / Float(samples.count)).squareRoot()
    }

    // MARK: - Worker

    private func nextWork() -> Work? {
        queue.sync {
            if !finals.isEmpty { return .final(finals.removeFirst()) }
            guard inSpeech, voiced >= Self.minVoiced, segment.count - partialMark >= Self.partialStep else { return nil }
            partialMark = segment.count
            return .partial(segment)
        }
    }

    private func work() async {
        while true {
            guard let work = nextWork() else {
                if queue.sync(execute: { draining }) { break }
                try? await Task.sleep(nanoseconds: 60_000_000)
                continue
            }
            do {
                switch work {
                case .partial(let samples):
                    guard speech.hasBudgetForPartial else { continue }
                    let heard: String?
                    do {
                        heard = try await transcribe(samples, isFinal: false)
                    } catch let error as GroqSpeech.SpeechError {
                        // A live pass is expendable unless the key itself is the problem.
                        switch error {
                        case .missingKey, .invalidKey: throw error
                        default: continue
                        }
                    } catch {
                        continue
                    }
                    guard let text = heard else { continue }
                    // The segment ended meanwhile; its final pass supersedes this one.
                    if queue.sync(execute: { !finals.isEmpty }) { continue }
                    if translation == .persian {
                        // A half-heard sentence cannot be translated; show it and type at the pause.
                        onLive?(text)
                    } else {
                        apply(LiveText.withoutLastWord(text), isFinal: false)
                    }
                case .final(let samples):
                    var text = try await transcribe(samples, isFinal: true) ?? ""
                    var language = translation == .english ? "en" : (segmentLanguage ?? languageMode.rawValue)
                    if !text.isEmpty {
                        context = LiveText.context(text)
                        contextLanguage = language
                    }
                    if translation == .persian, !text.isEmpty, let translate {
                        do {
                            text = LiveText.clean(try await translate(text))
                            language = "fa"
                        } catch {
                            onNotice?("ترجمه نشد (اینترنت؟) — متن اصلی تایپ شد.")
                        }
                    }
                    apply(text.isEmpty ? "" : text + " ", isFinal: true)
                    if !text.isEmpty { onText?(text, language) }
                    onLive?("")
                    typed = ""
                    segmentLanguage = nil
                    segmentApp = nil
                    rewriteAllowed = false
                }
            } catch {
                onError?(error)
                break
            }
        }
        queue.sync {
            running = false
            draining = false
        }
        onFinished?()
    }

    /// Live passes guess the language until there is enough audio to detect it; the service gives them
    /// the smaller model and the final pass of a segment the larger one. Returns nil to skip a pass.
    private func transcribe(_ samples: [Int16], isFinal: Bool) async throws -> String? {
        let toEnglish = translation == .english
        func pass(_ language: String) async throws -> GroqSpeech.Transcript {
            let writes = toEnglish ? "en" : language
            return try await speech.transcribe(samples, language: language, translate: toEnglish,
                                               prompt: writes == contextLanguage ? context : nil, isFinal: isFinal)
        }

        // Translation does not need to be told the source language.
        if toEnglish { return LiveText.clean(try await pass("auto").text) }
        if languageMode != .auto { return LiveText.clean(try await pass(languageMode.rawValue).text) }
        if let language = segmentLanguage { return LiveText.clean(try await pass(language).text) }
        if !isFinal && samples.count < Self.minDetect {
            // Too early to detect, and a pass in the wrong language is useless, so wait if there is no guess.
            guard let guess = lastLanguage else { return nil }
            return LiveText.clean(try await pass(guess).text)
        }

        var result = try await pass("auto")
        if !["fa", "en"].contains(result.language) {
            // Short Persian clips are often taken for Arabic, Urdu or Tajik.
            result = try await pass("fa")
            segmentLanguage = "fa"
        } else {
            segmentLanguage = result.language
        }
        if let guess = lastLanguage, guess != segmentLanguage { rewriteAllowed = true }
        lastLanguage = segmentLanguage
        return LiveText.clean(result.text)
    }

    private func apply(_ wanted: String, isFinal: Bool) {
        let front = frontApp()
        if segmentApp == nil { segmentApp = front }

        var target = wanted
        var edit = LiveText.edit(from: typed, to: target)
        if !isFinal && !rewriteAllowed && edit.delete > Self.maxPartialDelete {
            target = LiveText.appendingNewWords(of: wanted, to: typed)
            edit = LiveText.edit(from: typed, to: target)
        }
        // Never backspace in an app the text was not typed into.
        if edit.delete > 0 && front != segmentApp { return }
        guard edit.delete > 0 || !edit.insert.isEmpty else { return }
        output(edit.delete, edit.insert)
        typed = target
        onLive?(typed)
        rewriteAllowed = false
    }
}
