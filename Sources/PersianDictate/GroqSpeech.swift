import Foundation
import Security

/// Speech recognition through Groq's hosted Whisper (OpenAI-compatible API). Audio leaves the Mac.
final class GroqSpeech {
    enum SpeechError: LocalizedError {
        case missingKey
        case invalidKey
        case rateLimited
        case http(Int)
        case badResponse

        var errorDescription: String? {
            switch self {
            case .missingKey: return "کلید Groq وارد نشده — در داشبورد واردش کنید."
            case .invalidKey: return "کلید Groq پذیرفته نشد."
            case .rateLimited: return "سقف درخواست Groq پر شد؛ کمی صبر کنید."
            case .http(let code): return "پاسخ نامعتبر از Groq (HTTP \(code))."
            case .badResponse: return "پاسخ Groq خوانده نشد."
            }
        }
    }

    struct Transcript {
        let text: String
        /// ISO code such as "fa" or "en".
        let language: String
    }

    /// Groq's free tier allows 20 speech requests a minute; raise this on a paid plan.
    static let requestsPerMinuteDefaultsKey = "GroqRequestsPerMinute"
    /// For testing against another OpenAI-compatible server.
    static let baseURLDefaultsKey = "SpeechBaseURL"
    static let keysPage = URL(string: "https://console.groq.com/keys")!

    private static let fastModel = "whisper-large-v3-turbo"
    private static let accurateModel = "whisper-large-v3"

    private let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 20
        return URLSession(configuration: configuration)
    }()
    private let lock = NSLock()
    private var recent: [Date] = []

    private var baseURL: String {
        UserDefaults.standard.string(forKey: Self.baseURLDefaultsKey) ?? "https://api.groq.com/openai/v1"
    }

    private var limit: Int {
        let stored = UserDefaults.standard.integer(forKey: Self.requestsPerMinuteDefaultsKey)
        return stored > 0 ? stored : 20
    }

    // MARK: - Key

    private static let keychainQuery: [String: Any] = [
        kSecClass as String: kSecClassGenericPassword,
        kSecAttrService as String: "com.persiandictate.app",
        kSecAttrAccount as String: "groq-api-key",
    ]

    /// `GROQ_API_KEY` in the environment wins (command-line runs); otherwise the Keychain.
    static var apiKey: String? {
        if let key = ProcessInfo.processInfo.environment["GROQ_API_KEY"], !key.isEmpty { return key }
        var query = keychainQuery
        query[kSecReturnData as String] = true
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess, let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func store(apiKey: String) {
        SecItemDelete(keychainQuery as CFDictionary)
        let key = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { return }
        var item = keychainQuery
        item[kSecValueData as String] = Data(key.utf8)
        SecItemAdd(item as CFDictionary, nil)
    }

    /// Asks Groq whether the stored key works.
    func validateKey() async -> Bool {
        guard let key = Self.apiKey, let url = URL(string: "\(baseURL)/models") else { return false }
        var request = URLRequest(url: url)
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        guard let (_, response) = try? await session.data(for: request) else { return false }
        return (response as? HTTPURLResponse)?.statusCode == 200
    }

    // MARK: - Budget

    /// Requests left in the current minute.
    private var remaining: Int {
        lock.withLock {
            let cutoff = Date().addingTimeInterval(-60)
            recent.removeAll { $0 < cutoff }
            return limit - recent.count
        }
    }

    /// Live passes may only use what the end-of-sentence passes can spare.
    var hasBudgetForPartial: Bool { remaining > max(4, limit / 4) }

    // MARK: - Requests

    /// `language` is an ISO code or "auto". `translate` writes the speech in English whatever its language.
    /// `prompt` is text that came just before, for context. Final passes use the larger model and wait
    /// out a full budget; live passes throw `rateLimited` instead.
    func transcribe(_ samples: [Int16], language: String, translate: Bool, prompt: String?, isFinal: Bool) async throws -> Transcript {
        guard let key = Self.apiKey else { throw SpeechError.missingKey }

        let boundary = "PersianDictate-\(UUID().uuidString)"
        var body = Data()
        func field(_ name: String, _ value: String) {
            body.append(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(name)\"\r\n\r\n\(value)\r\n".utf8))
        }
        // Only the large model translates.
        field("model", isFinal || translate ? Self.accurateModel : Self.fastModel)
        field("response_format", "verbose_json")
        field("temperature", "0")
        if !translate && language != "auto" { field("language", language) }
        if let prompt, !prompt.isEmpty { field("prompt", prompt) }
        body.append(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"file\"; filename=\"audio.wav\"\r\nContent-Type: audio/wav\r\n\r\n".utf8))
        body.append(AudioCapture.wavData(samples))
        body.append(Data("\r\n--\(boundary)--\r\n".utf8))

        var request = URLRequest(url: URL(string: "\(baseURL)/audio/\(translate ? "translations" : "transcriptions")")!)
        request.httpMethod = "POST"
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")

        for attempt in 0..<3 {
            if remaining <= 0 {
                guard isFinal else { throw SpeechError.rateLimited }
                try await Task.sleep(nanoseconds: 3_000_000_000)
            }
            lock.withLock { recent.append(Date()) }

            let (data, response) = try await session.upload(for: request, from: body)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            switch status {
            case 200:
                guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let text = json["text"] as? String else {
                    throw SpeechError.badResponse
                }
                let reported = translate ? "en" : ((json["language"] as? String) ?? language)
                return Transcript(text: text, language: Self.languageCode(reported))
            case 401, 403:
                throw SpeechError.invalidKey
            case 429:
                guard isFinal, attempt < 2 else { throw SpeechError.rateLimited }
                let wait = Double((response as? HTTPURLResponse)?.value(forHTTPHeaderField: "retry-after") ?? "") ?? 5
                try await Task.sleep(nanoseconds: UInt64(min(wait, 20) * 1_000_000_000))
            default:
                throw SpeechError.http(status)
            }
        }
        throw SpeechError.rateLimited
    }

    /// The API reports either a code ("fa") or a name ("Persian").
    private static func languageCode(_ reported: String) -> String {
        switch reported.lowercased() {
        case "persian", "farsi": return "fa"
        case "english": return "en"
        default: return reported.lowercased()
        }
    }
}
