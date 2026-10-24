import Foundation

/// Remembers the text just committed, with the reading it came from, so that
/// the very next Backspace can bring it back as a conversion. One shot: any
/// key, including that Backspace, forgets it.
struct CommitUndo {
    struct Entry: Equatable {
        let text: String
        let reading: String
        /// Left context the conversion used, restored with the reading.
        let previousRightID: Int?
    }

    private(set) var entry: Entry?

    mutating func record(text: String, reading: String, previousRightID: Int?) {
        entry = text.isEmpty || reading.isEmpty
            ? nil : Entry(text: text, reading: reading, previousRightID: previousRightID)
    }

    mutating func clear() { entry = nil }

    /// The UTF-16 range holding the committed text, or nil to let Backspace
    /// behave normally. Only when the caret sits right after the committed
    /// text with nothing selected, checked against the client's own text: the
    /// caret may have moved (a click) without the input method seeing it.
    static func range(for text: String?, selectedRange: NSRange,
                      textIn: (NSRange) -> String?) -> NSRange? {
        guard let text, !text.isEmpty,
              selectedRange.location != NSNotFound, selectedRange.length == 0 else { return nil }
        let length = text.utf16.count
        guard selectedRange.location >= length else { return nil }
        let range = NSRange(location: selectedRange.location - length, length: length)
        guard textIn(range) == text else { return nil }
        return range
    }

    /// Candidates for the restored conversion, starting on the committed text.
    /// Kept first-found order; the committed text goes in front only when the
    /// fresh conversion no longer lists it (e.g. a kana form forced by Ctrl+J).
    static func reconversionCandidates(committed: String, candidates: [String]) -> (candidates: [String], selected: Int) {
        if let i = candidates.firstIndex(of: committed) { return (candidates, i) }
        return ([committed] + candidates, 0)
    }
}
