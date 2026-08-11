import Foundation

// Stateful romaji→hiragana converter using a greedy longest-match automaton.
//
// State:
//   pending  — typed roman letters that haven't yet produced a kana
//   accept() — feeds one character, returns any emitted hiragana
//   drain()  — flushes pending state before Space / Enter
public struct RomajiConverter {
    public var pending: String = ""

    public init() {}

    // Feed one character. Returns emitted hiragana (empty if still buffering).
    public mutating func accept(_ ch: Character) -> String {
        // っ rule: same consonant repeated (except "n") → っ, restart with ch
        if pending.count == 1,
           let first = pending.first,
           first == ch, ch != "n",
           Self.consonants.contains(ch) {
            pending = String(ch)
            return "っ"
        }

        pending.append(ch)
        return drain(partial: true)
    }

    // Delete the last pending roman char. Returns remaining pending (for display).
    public mutating func deleteLast() -> String {
        if !pending.isEmpty { pending.removeLast() }
        return pending
    }

    // Flush any pending state before conversion or insertion.
    // "n" alone → "ん"; other incomplete sequences returned as-is.
    public mutating func drain() -> String {
        if pending == "n" || pending.hasSuffix("n") && pending.count == 1 {
            pending = ""
            return "ん"
        }
        let result = pending
        pending = ""
        return result
    }

    // Internal: try to match and output, optionally allowing partial wait.
    private mutating func drain(partial: Bool) -> String {
        // Try exact match (longest first via table key length ≤ 4)
        for len in stride(from: min(pending.count, 4), through: 1, by: -1) {
            let sub = String(pending.prefix(len))
            if let kana = Self.table[sub] {
                pending = String(pending.dropFirst(len))
                return kana + (pending.isEmpty ? "" : drain(partial: partial))
            }
        }
        // Check if pending is a valid prefix of any table key
        if partial && Self.prefixes.contains(pending) {
            return ""  // waiting for more input
        }
        // "n" before consonant or at end → ん
        if pending.hasPrefix("n"), pending.count > 1 {
            let afterN = String(pending.dropFirst())
            if let next = afterN.first, Self.consonants.contains(next), next != "n" {
                pending = afterN
                return "ん" + drain(partial: partial)
            }
        }
        // No match and no valid prefix: flush the first char and retry
        if pending.count > 1 {
            let first = pending.removeFirst()
            return String(first) + drain(partial: partial)
        }
        // Single char that won't match — keep buffering (unusual input like "x")
        return ""
    }

    // MARK: - Table

    private static let consonants: Set<Character> = Set("bcdfghjklmnpqrstvwxyz")

    // Build the valid-prefix set from table keys.
    private static let prefixes: Set<String> = {
        var s = Set<String>()
        for key in table.keys {
            for len in 1...key.count {
                s.insert(String(key.prefix(len)))
            }
        }
        return s
    }()

    public static let table: [String: String] = {
        var t = [String: String]()
        for (k, v) in entries { t[k] = v }
        return t
    }()

    // swiftlint:disable line_length
    private static let entries: [(String, String)] = [
        // Vowels
        ("a", "あ"), ("i", "い"), ("u", "う"), ("e", "え"), ("o", "お"),
        // N
        ("nn", "ん"), ("n'", "ん"),
        // K
        ("ka", "か"), ("ki", "き"), ("ku", "く"), ("ke", "け"), ("ko", "こ"),
        ("kya", "きゃ"), ("kyi", "きぃ"), ("kyu", "きゅ"), ("kye", "きぇ"), ("kyo", "きょ"),
        // S
        ("sa", "さ"), ("si", "し"), ("su", "す"), ("se", "せ"), ("so", "そ"),
        ("shi", "し"), ("sha", "しゃ"), ("shu", "しゅ"), ("she", "しぇ"), ("sho", "しょ"),
        ("sya", "しゃ"), ("syi", "しぃ"), ("syu", "しゅ"), ("sye", "しぇ"), ("syo", "しょ"),
        // T
        ("ta", "た"), ("ti", "ち"), ("tu", "つ"), ("te", "て"), ("to", "と"),
        ("chi", "ち"), ("cha", "ちゃ"), ("chu", "ちゅ"), ("che", "ちぇ"), ("cho", "ちょ"),
        ("tsu", "つ"),
        ("tya", "ちゃ"), ("tyi", "ちぃ"), ("tyu", "ちゅ"), ("tye", "ちぇ"), ("tyo", "ちょ"),
        ("tha", "てゃ"), ("thi", "てぃ"), ("thu", "てゅ"), ("the", "てぇ"), ("tho", "てょ"),
        // N
        ("na", "な"), ("ni", "に"), ("nu", "ぬ"), ("ne", "ね"), ("no", "の"),
        ("nya", "にゃ"), ("nyi", "にぃ"), ("nyu", "にゅ"), ("nye", "にぇ"), ("nyo", "にょ"),
        // H / F
        ("ha", "は"), ("hi", "ひ"), ("hu", "ふ"), ("he", "へ"), ("ho", "ほ"),
        ("fu", "ふ"),
        ("hya", "ひゃ"), ("hyi", "ひぃ"), ("hyu", "ひゅ"), ("hye", "ひぇ"), ("hyo", "ひょ"),
        ("fa", "ふぁ"), ("fi", "ふぃ"), ("fe", "ふぇ"), ("fo", "ふぉ"),
        // M
        ("ma", "ま"), ("mi", "み"), ("mu", "む"), ("me", "め"), ("mo", "も"),
        ("mya", "みゃ"), ("myi", "みぃ"), ("myu", "みゅ"), ("mye", "みぇ"), ("myo", "みょ"),
        // Y
        ("ya", "や"), ("yu", "ゆ"), ("yo", "よ"),
        // R
        ("ra", "ら"), ("ri", "り"), ("ru", "る"), ("re", "れ"), ("ro", "ろ"),
        ("rya", "りゃ"), ("ryi", "りぃ"), ("ryu", "りゅ"), ("rye", "りぇ"), ("ryo", "りょ"),
        // W
        ("wa", "わ"), ("wi", "うぃ"), ("we", "うぇ"), ("wo", "を"),
        // G
        ("ga", "が"), ("gi", "ぎ"), ("gu", "ぐ"), ("ge", "げ"), ("go", "ご"),
        ("gya", "ぎゃ"), ("gyi", "ぎぃ"), ("gyu", "ぎゅ"), ("gye", "ぎぇ"), ("gyo", "ぎょ"),
        // Z / J
        ("za", "ざ"), ("zi", "じ"), ("zu", "ず"), ("ze", "ぜ"), ("zo", "ぞ"),
        ("ja", "じゃ"), ("ji", "じ"), ("ju", "じゅ"), ("je", "じぇ"), ("jo", "じょ"),
        ("jya", "じゃ"), ("jyi", "じぃ"), ("jyu", "じゅ"), ("jye", "じぇ"), ("jyo", "じょ"),
        ("zya", "じゃ"), ("zyu", "じゅ"), ("zyo", "じょ"), ("zyi", "じぃ"), ("zye", "じぇ"),
        // D
        ("da", "だ"), ("di", "ぢ"), ("du", "づ"), ("de", "で"), ("do", "ど"),
        ("dya", "ぢゃ"), ("dyu", "ぢゅ"), ("dyo", "ぢょ"),
        ("dha", "でゃ"), ("dhi", "でぃ"), ("dhu", "でゅ"), ("dhe", "でぇ"), ("dho", "でょ"),
        // B
        ("ba", "ば"), ("bi", "び"), ("bu", "ぶ"), ("be", "べ"), ("bo", "ぼ"),
        ("bya", "びゃ"), ("byu", "びゅ"), ("byo", "びょ"),
        // P
        ("pa", "ぱ"), ("pi", "ぴ"), ("pu", "ぷ"), ("pe", "ぺ"), ("po", "ぽ"),
        ("pya", "ぴゃ"), ("pyu", "ぴゅ"), ("pyo", "ぴょ"),
        // V
        ("va", "ゔぁ"), ("vi", "ゔぃ"), ("vu", "ゔ"), ("ve", "ゔぇ"), ("vo", "ゔぉ"),
        // Small kana (x prefix)
        ("xa", "ぁ"), ("xi", "ぃ"), ("xu", "ぅ"), ("xe", "ぇ"), ("xo", "ぉ"),
        ("xya", "ゃ"), ("xyu", "ゅ"), ("xyo", "ょ"),
        ("xtu", "っ"), ("xtsu", "っ"), ("xwa", "ゎ"),
        // Small kana (l prefix — alternate)
        ("la", "ぁ"), ("li", "ぃ"), ("lu", "ぅ"), ("le", "ぇ"), ("lo", "ぉ"),
        ("lya", "ゃ"), ("lyu", "ゅ"), ("lyo", "ょ"),
        ("ltu", "っ"), ("ltsu", "っ"),
    ]
    // swiftlint:enable line_length
}
