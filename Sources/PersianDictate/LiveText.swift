import Foundation

/// Pure text helpers for live typing: cleaning Whisper output and diffing against what is already typed.
enum LiveText {
    /// Phrases Whisper invents on noise or silence.
    private static let hallucinations = [
        "thanks for watching", "thank you for watching", "subtitles by", "amara.org",
        "زیرنویس", "تماشای شما", "کانال ما", "لایک و سابسکرایب",
    ]

    static func clean(_ raw: String) -> String {
        var text = raw
        for pattern in [#"\[[^\]]*\]"#, #"\([^)]*\)"#, #"\*[^*]*\*"#, "♪"] {
            text = text.replacingOccurrences(of: pattern, with: " ", options: .regularExpression)
        }
        text = text.replacingOccurrences(of: "ي", with: "ی").replacingOccurrences(of: "ك", with: "ک")
        // Astral scalars (emoji) would break the one-backspace-per-scalar rule.
        text = String(String.UnicodeScalarView(text.unicodeScalars.filter { $0.value <= 0xFFFF }))
        text = text.split(whereSeparator: \.isWhitespace).joined(separator: " ")

        let lowered = text.lowercased()
        if hallucinations.contains(where: lowered.contains) { return "" }
        if ["you", "you.", "."].contains(lowered) { return "" }
        return text
    }

    /// The tail of `text`, cut at a word, short enough to hand to Whisper as context.
    static func context(_ text: String, limit: Int = 200) -> String {
        guard text.count > limit else { return text }
        let tail = text.suffix(limit)
        guard let space = tail.firstIndex(of: " ") else { return String(tail) }
        return String(tail[tail.index(after: space)...])
    }

    /// The last word of a partial result is the one most likely to change, so it is held back.
    static func withoutLastWord(_ text: String) -> String {
        guard let space = text.lastIndex(of: " ") else { return "" }
        return String(text[..<space])
    }

    /// Keeps `typed` as it is and adds only the words `text` has beyond it, matched by position.
    static func appendingNewWords(of text: String, to typed: String) -> String {
        let have = typed.split(separator: " ").count
        let extra = text.split(separator: " ").dropFirst(have)
        return extra.isEmpty ? typed : typed + " " + extra.joined(separator: " ")
    }

    /// Backspaces and insertion that turn `typed` into `target`. Counted in Unicode scalars:
    /// that is what one Backspace removes in Persian text (a ZWNJ goes on its own).
    static func edit(from typed: String, to target: String) -> (delete: Int, insert: String) {
        let old = Array(typed.unicodeScalars)
        let new = Array(target.unicodeScalars)
        var common = 0
        while common < old.count, common < new.count, old[common] == new[common] { common += 1 }
        return (old.count - common, String(String.UnicodeScalarView(new[common...])))
    }
}
