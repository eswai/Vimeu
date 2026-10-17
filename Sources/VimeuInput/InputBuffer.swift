import Foundation

// Accumulated input buffer: kana / digits so far + pending roman chars.
public struct InputBuffer {
    public var reading: String = ""
    public var converter = RomajiConverter()

    public init() {}

    // Display string shown as marked text while composing.
    public var displayString: String { reading + converter.pending }

    public var isEmpty: Bool { reading.isEmpty && converter.pending.isEmpty }

    // Feed one character.
    public mutating func accept(_ ch: Character) {
        if Self.isASCIIDigit(ch) {
            // A number ends the pending syllable: n1 → ん1, never n1.
            acceptKana(String(ch))
        } else {
            reading += converter.accept(ch)
        }
    }

    public static func isASCIIDigit(_ ch: Character) -> Bool {
        ch >= "0" && ch <= "9"
    }

    public static func isComposingCharacter(_ ch: Character) -> Bool {
        ch.isLetter || isASCIIDigit(ch)
    }

    // Directly append a kana character (e.g. ー from the minus key).
    public mutating func acceptKana(_ kana: String) {
        reading += converter.drain()
        reading += kana
    }

    // Backspace: delete pending roman first, then last hiragana.
    public mutating func deleteLast() {
        if !converter.pending.isEmpty {
            _ = converter.deleteLast()
        } else if !reading.isEmpty {
            reading.removeLast()
        }
    }

    // Flush and return the full hiragana reading for conversion.
    public mutating func flushForConversion() -> String {
        reading += converter.drain()
        return reading
    }
}
