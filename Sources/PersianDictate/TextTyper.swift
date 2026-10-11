import ApplicationServices
import Foundation

/// Types arbitrary Unicode text into the focused app by posting synthetic keyboard events.
enum TextTyper {
    /// CGEvent accepts at most 20 UTF-16 units per event.
    private static let maxUnitsPerEvent = 20

    static var isTrusted: Bool { AXIsProcessTrusted() }

    /// Shows the system Accessibility prompt if the app is not yet trusted.
    @discardableResult
    static func requestAccessibility() -> Bool {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        return AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
    }

    static func type(_ text: String) {
        guard !text.isEmpty else { return }
        let source = CGEventSource(stateID: .combinedSessionState)

        for chunk in chunks(of: text) {
            let units = Array(chunk.utf16)
            for keyDown in [true, false] {
                guard let event = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: keyDown) else { continue }
                event.flags = []
                units.withUnsafeBufferPointer { buffer in
                    event.keyboardSetUnicodeString(stringLength: buffer.count, unicodeString: buffer.baseAddress)
                }
                event.post(tap: .cghidEventTap)
            }
            usleep(4_000)
        }
    }

    /// Presses Backspace `count` times.
    static func backspace(_ count: Int) {
        guard count > 0 else { return }
        let source = CGEventSource(stateID: .combinedSessionState)
        for _ in 0..<count {
            for keyDown in [true, false] {
                guard let event = CGEvent(keyboardEventSource: source, virtualKey: 51, keyDown: keyDown) else { continue }
                event.flags = []
                event.post(tap: .cghidEventTap)
            }
            usleep(2_000)
        }
        usleep(4_000)
    }

    /// Splits on Character boundaries so no surrogate pair or combining mark is cut.
    private static func chunks(of text: String) -> [String] {
        var result: [String] = []
        var current = ""
        for character in text {
            if current.utf16.count + character.utf16.count > maxUnitsPerEvent, !current.isEmpty {
                result.append(current)
                current = ""
            }
            current.append(character)
        }
        if !current.isEmpty { result.append(current) }
        return result
    }
}
