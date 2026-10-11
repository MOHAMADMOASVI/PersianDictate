import Foundation

/// Translates text with Google Translate's public web endpoint. Needs the internet, and the text
/// leaves the Mac; it is only used when the user turns on translation to Persian.
enum Translator {
    enum TranslatorError: Error {
        case http(Int)
        case badResponse
    }

    private static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 8
        return URLSession(configuration: configuration)
    }()

    static func translate(_ text: String, to target: String) async throws -> String {
        var request = URLRequest(url: URL(string: "https://translate.googleapis.com/translate_a/single?client=gtx&sl=auto&tl=\(target)&dt=t")!)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded; charset=utf-8", forHTTPHeaderField: "Content-Type")
        // The text goes in the body, not the URL, so it stays out of logs along the way.
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        request.httpBody = Data("q=\(text.addingPercentEncoding(withAllowedCharacters: allowed) ?? "")".utf8)

        let (data, response) = try await session.data(for: request)
        if let http = response as? HTTPURLResponse, http.statusCode != 200 {
            throw TranslatorError.http(http.statusCode)
        }
        // [[["translated piece", "source piece", …], …], …]
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [Any],
              let pieces = root.first as? [[Any]] else {
            throw TranslatorError.badResponse
        }
        let translated = pieces.compactMap { $0.first as? String }.joined()
        guard !translated.isEmpty else { throw TranslatorError.badResponse }
        return translated
    }
}
