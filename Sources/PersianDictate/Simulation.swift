import AVFoundation

/// `PersianDictate --simulate file.wav [auto|fa|en] [off|english|persian]` plays an audio file through the live pipeline at
/// real-time speed and prints every edit instead of typing it. For checking recognition without a microphone.
/// Takes the key from `GROQ_API_KEY`.
enum Simulation {
    static func run(path: String, language: String?, translation: String?) -> Never {
        let samples: [Int16]
        do {
            samples = try load(URL(fileURLWithPath: path))
        } catch {
            print("خواندن فایل ناموفق بود: \(error.localizedDescription)")
            exit(1)
        }

        let speech = GroqSpeech()
        var screen = ""
        var started = Date()
        let dictation = LiveDictation(speech: speech, output: { delete, insert in
            screen = String(String.UnicodeScalarView(screen.unicodeScalars.dropLast(delete))) + insert
            print(String(format: "%5.1fs  -%d +\"%@\"", Date().timeIntervalSince(started), delete, insert))
        }, frontApp: { 0 })
        dictation.languageMode = language.flatMap(LiveDictation.LanguageMode.init(rawValue:)) ?? .auto
        dictation.translation = translation.flatMap(LiveDictation.Translation.init(rawValue:)) ?? .off
        dictation.translate = { try await Translator.translate($0, to: "fa") }
        dictation.onNotice = { print($0) }
        dictation.onError = { print("خطا: \($0.localizedDescription)") }
        dictation.onFinished = {
            print("\n\(screen)")
            exit(0)
        }

        Task.detached {
            started = Date()
            dictation.start()
            let chunk = Int(AudioCapture.sampleRate) / 10
            let silence = [Int16](repeating: 0, count: chunk * 12)
            let stream = samples + silence
            for start in stride(from: 0, to: stream.count, by: chunk) {
                dictation.feed(Array(stream[start..<min(start + chunk, stream.count)]))
                try? await Task.sleep(nanoseconds: 100_000_000)
            }
            dictation.stop()
        }
        dispatchMain()
    }

    private static func load(_ url: URL) throws -> [Int16] {
        let file = try AVAudioFile(forReading: url)
        guard let input = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)),
              let converter = AVAudioConverter(from: file.processingFormat, to: AudioCapture.format) else {
            throw AudioCapture.CaptureError.converterUnavailable
        }
        try file.read(into: input)
        let ratio = AudioCapture.sampleRate / file.processingFormat.sampleRate
        let capacity = AVAudioFrameCount(Double(input.frameLength) * ratio) + 4096
        guard let output = AVAudioPCMBuffer(pcmFormat: AudioCapture.format, frameCapacity: capacity),
              AudioCapture.convert(input, with: converter, into: output) else {
            throw AudioCapture.CaptureError.converterUnavailable
        }
        return AudioCapture.samples(of: output)
    }
}
