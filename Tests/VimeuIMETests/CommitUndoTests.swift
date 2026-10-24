import Foundation
import Testing
@testable import VimeuIME

struct CommitUndoTests {
    /// A client whose document is `doc`, with the caret at `caret` (UTF-16).
    private func range(_ committed: String?, doc: String, caret: Int, selection: Int = 0) -> NSRange? {
        let ns = doc as NSString
        return CommitUndo.range(for: committed, selectedRange: NSRange(location: caret, length: selection)) {
            NSMaxRange($0) <= ns.length ? ns.substring(with: $0) : nil
        }
    }

    @Test func deletesWholeCommitRightBeforeCaret() {
        let doc = "今日は東京へ"
        #expect(range("東京へ", doc: doc, caret: 6) == NSRange(location: 3, length: 3))
    }

    @Test func countsUTF16ForSurrogatePairs() {
        let doc = "a𠮷野家"
        #expect(range("𠮷野家", doc: doc, caret: doc.utf16.count) == NSRange(location: 1, length: 4))
    }

    @Test func normalBackspaceWhenNothingWasCommitted() {
        #expect(range(nil, doc: "東京", caret: 2) == nil)
    }

    @Test func normalBackspaceWhenCaretMoved() {
        #expect(range("東京", doc: "東京へ", caret: 3) == nil)
    }

    @Test func normalBackspaceWithSelectionOrUnknownCaret() {
        #expect(range("東京", doc: "東京", caret: 2, selection: 1) == nil)
        #expect(range("東京", doc: "東京", caret: NSNotFound) == nil)
        #expect(range("東京", doc: "京", caret: 1) == nil)
    }

    @Test func normalBackspaceWhenClientCannotReadText() {
        let r = CommitUndo.range(for: "東京", selectedRange: NSRange(location: 2, length: 0)) { _ in nil }
        #expect(r == nil)
    }

    @Test func recordIsOneShotAndIgnoresEmptyText() {
        var undo = CommitUndo()
        undo.record(text: "", reading: "とうきょう", previousRightID: nil)
        #expect(undo.entry == nil)
        undo.record(text: "東京", reading: "とうきょう", previousRightID: nil)
        #expect(undo.entry?.text == "東京")
        undo.clear()
        #expect(undo.entry == nil)
    }
}

struct ReconversionTests {
    @Test func startsOnCommittedCandidate() {
        let r = CommitUndo.reconversionCandidates(committed: "東京へ", candidates: ["東京へ", "当協へ", "とうきょうへ"])
        #expect(r.candidates == ["東京へ", "当協へ", "とうきょうへ"])
        #expect(r.selected == 0)
        let r2 = CommitUndo.reconversionCandidates(committed: "当協へ", candidates: ["東京へ", "当協へ"])
        #expect(r2.selected == 1)
    }

    @Test func keepsCommittedTextMissingFromFreshConversion() {
        let r = CommitUndo.reconversionCandidates(committed: "トウキョウ", candidates: ["東京", "とうきょう"])
        #expect(r.candidates == ["トウキョウ", "東京", "とうきょう"])
        #expect(r.selected == 0)
    }

    @Test func recordNeedsTextAndReading() {
        var undo = CommitUndo()
        undo.record(text: "東京", reading: "", previousRightID: nil)
        #expect(undo.entry == nil)
        undo.record(text: "東京", reading: "とうきょう", previousRightID: 7)
        #expect(undo.entry == CommitUndo.Entry(text: "東京", reading: "とうきょう", previousRightID: 7))
    }

    @Test func chromiumClientsDeleteThenMark() {
        #expect(CommitUndo.restoreMethod(bundleIdentifier: "com.anthropic.claudefordesktop") == .deleteThenMark)
        #expect(CommitUndo.restoreMethod(bundleIdentifier: "com.google.Chrome.canary") == .deleteThenMark)
    }

    @Test func otherClientsReplaceRange() {
        #expect(CommitUndo.restoreMethod(bundleIdentifier: "com.apple.Safari") == .replaceRange)
        #expect(CommitUndo.restoreMethod(bundleIdentifier: "com.apple.Notes") == .replaceRange)
        #expect(CommitUndo.restoreMethod(bundleIdentifier: nil) == .replaceRange)
    }

    @Test func leavesAllButTheLastCharacterForTheClientBackspace() {
        #expect(CommitUndo.rangeLeftAfterBackspace(NSRange(location: 3, length: 3), text: "東京へ")
                == NSRange(location: 3, length: 2))
        #expect(CommitUndo.rangeLeftAfterBackspace(NSRange(location: 0, length: 3), text: "東𠮷")
                == NSRange(location: 0, length: 1))
        #expect(CommitUndo.rangeLeftAfterBackspace(NSRange(location: 5, length: 1), text: "へ")
                == NSRange(location: 5, length: 0))
    }
}
