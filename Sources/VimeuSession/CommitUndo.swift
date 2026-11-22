/// Remembers the text just committed, with the reading it came from, so that
/// the very next Backspace can bring it back as a conversion. One shot: any
/// key, including that Backspace, forgets it.
///
/// Linux counterpart of `VimeuIME/CommitUndo.swift`. fcitx5 exposes the
/// client's text as "surrounding text" (text + cursor + anchor, in Unicode
/// scalars) instead of IMK's UTF-16 ranges, so the check is done on the text
/// before the cursor and the restore deletes that many scalars.
public struct CommitUndo: Sendable {
    public struct Entry: Equatable, Sendable {
        public let text: String
        public let reading: String
        /// Left context the conversion used, restored with the reading.
        public let previousRightID: Int?
    }

    public private(set) var entry: Entry?

    public init() {}

    public mutating func record(text: String, reading: String, previousRightID: Int?) {
        entry = text.isEmpty || reading.isEmpty
            ? nil : Entry(text: text, reading: reading, previousRightID: previousRightID)
    }

    public mutating func clear() { entry = nil }

    /// Number of Unicode scalars to delete before the cursor to remove the
    /// committed text, or nil to let Backspace behave normally. Only when the
    /// cursor sits right after the committed text with nothing selected: the
    /// caret may have moved (a click) without the input method seeing it.
    public static func scalarsToDelete(for text: String?, surrounding: SurroundingText?) -> Int? {
        guard let text, !text.isEmpty, let s = surrounding, s.cursor == s.anchor else { return nil }
        let scalars = Array(s.text.unicodeScalars)
        let n = text.unicodeScalars.count
        guard s.cursor >= n, s.cursor <= scalars.count else { return nil }
        let before = String(String.UnicodeScalarView(scalars[(s.cursor - n)..<s.cursor]))
        return before == text ? n : nil
    }

    /// Candidates for the restored conversion, starting on the committed text.
    /// Kept first-found order; the committed text goes in front only when the
    /// fresh conversion no longer lists it (e.g. a kana form forced by Ctrl+J).
    public static func reconversionCandidates(committed: String, candidates: [String]) -> (candidates: [String], selected: Int) {
        if let i = candidates.firstIndex(of: committed) { return (candidates, i) }
        return ([committed] + candidates, 0)
    }
}
