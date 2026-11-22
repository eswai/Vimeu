import Foundation
import Testing
import VimeuInput
@testable import VimeuSession

/// Records everything the session does to its client.
final class FakeClient: SessionClient {
    var preedit = ""
    var preeditConverting = false
    var committed: [String] = []
    var candidates: [String]?
    var selected = 0
    var surrounding: SurroundingText?
    var deleted: [Int] = []
    var timers: [SessionTimer: Int] = [:]
    var tunerOpened: [String?] = []

    func setPreedit(_ text: String, converting: Bool) {
        preedit = text
        preeditConverting = converting
    }

    func commit(_ text: String) {
        committed.append(text)
        preedit = ""
    }

    func showCandidates(_ candidates: [String], selected: Int) {
        self.candidates = candidates
        self.selected = selected
    }

    func selectCandidate(_ index: Int) { selected = index }
    func hideCandidates() { candidates = nil }
    func surroundingText() -> SurroundingText? { surrounding }
    func deleteBeforeCursor(_ count: Int) { deleted.append(count) }
    func startTimer(_ timer: SessionTimer, milliseconds: Int) { timers[timer] = milliseconds }
    func cancelTimer(_ timer: SessionTimer) { timers[timer] = nil }
    func openTuner(reading: String?) { tunerOpened.append(reading) }
}

private let dictionaryPath = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    .appendingPathComponent("dict/vimeu.dic").path
private let hasDictionary = FileManager.default.fileExists(atPath: dictionaryPath)

/// One engine per process, like fcitx5: the shipped dictionary is mmap'ed once.
private let shippedEngine = Engine(dictionaryPath: dictionaryPath,
                                   userDirectory: NSTemporaryDirectory() + "vimeu-session-tests-empty")
private let kanaOnlyEngine = Engine(dictionaryPath: nil,
                                    userDirectory: NSTemporaryDirectory() + "vimeu-session-tests-empty")

private func makeSession(engine: Engine = kanaOnlyEngine, live: Bool = false,
                         _ configure: (inout SessionSettings) -> Void = { _ in }) -> (Session, FakeClient) {
    let client = FakeClient()
    var settings = SessionSettings(liveConversion: live)
    configure(&settings)
    return (Session(engine: engine, client: client, settings: settings), client)
}

private func type(_ session: Session, _ text: String) {
    for ch in text { session.handle(.character(ch)) }
}

struct SessionStateMachineTests {
    @Test func kanaOnlyEngineReportsWhy() {
        #expect(kanaOnlyEngine.isReady == false)
        #expect(kanaOnlyEngine.loadFailure != nil)
    }

    @Test func romajiComposesAndEnterCommitsReading() {
        let (s, c) = makeSession()
        type(s, "kana")
        #expect(c.preedit == "かな")
        #expect(s.handle(.enter))
        #expect(c.committed == ["かな"])
        #expect(!s.isComposing)
    }

    @Test func pendingRomajiIsShownAndFlushedOnCommit() {
        let (s, c) = makeSession()
        type(s, "kan")
        #expect(c.preedit == "かn")
        s.handle(.enter)
        #expect(c.committed == ["かん"])
    }

    @Test func uppercaseIsLowered() {
        let (s, c) = makeSession()
        type(s, "KA")
        #expect(c.preedit == "か")
    }

    @Test func punctuationMapsToJapanese() {
        let (s, c) = makeSession()
        type(s, "a,i.u-/")
        #expect(c.preedit == "あ、い。うー・")
    }

    @Test func directPassesUnhandledKeys() {
        let (s, _) = makeSession()
        #expect(s.handle(.enter) == false)
        #expect(s.handle(.space) == false)
        #expect(s.handle(.character("!")) == false)
        #expect(s.handle(.character("a"), modifiers: .control) == false)
    }

    @Test func escapeRewindsOneLevelAtATime() {
        let (s, c) = makeSession()
        type(s, "kana")
        #expect(s.handle(.space))
        #expect(c.candidates != nil)
        #expect(c.preeditConverting)
        // Converting → Composing keeps the reading.
        #expect(s.handle(.escape))
        #expect(c.candidates == nil)
        #expect(c.preedit == "かな")
        #expect(!c.preeditConverting)
        // Composing → Direct clears it.
        #expect(s.handle(.escape))
        #expect(c.preedit == "")
        #expect(!s.isComposing)
        #expect(c.committed.isEmpty)
    }

    @Test func kanaFallbackWithoutDictionary() {
        let (s, c) = makeSession()
        type(s, "kana")
        s.handle(.space)
        #expect(c.candidates == ["かな", "カナ"])
        s.handle(.down)
        #expect(c.selected == 1)
        #expect(c.preedit == "カナ")
        s.handle(.up)
        #expect(c.selected == 0)
        s.handle(.space)
        s.handle(.enter)
        #expect(c.committed == ["カナ"])
    }

    @Test func digitsOfferHalfAndFullWidth() {
        let (s, c) = makeSession()
        type(s, "n1")
        #expect(c.preedit == "ん1")
        s.handle(.space)
        #expect(c.candidates == ["ん1", "ん１", "ン1", "ン１"])
    }

    @Test func numberKeySelectsWithinTheVisiblePage() {
        #expect(Session.pageStart(selected: 0) == 0)
        #expect(Session.pageStart(selected: 9) == 0)
        #expect(Session.pageStart(selected: 10) == 10)
        let (s, c) = makeSession()
        type(s, "kana")
        s.handle(.space)
        s.handle(.character("2"))
        #expect(c.committed == ["カナ"])
    }

    @Test func letterDuringConversionCommitsAndStartsAnew() {
        let (s, c) = makeSession()
        type(s, "kana")
        s.handle(.space)
        s.handle(.character("a"))
        #expect(c.committed == ["かな"])
        #expect(c.preedit == "あ")
    }

    @Test func controlMCommitsOnlyWhileComposing() {
        let (s, c) = makeSession()
        #expect(s.handle(.character("m"), modifiers: .control) == false)
        type(s, "ka")
        #expect(s.handle(.character("m"), modifiers: .control))
        #expect(c.committed == ["か"])
    }

    @Test func controlJAndKForceKana() {
        let (s, c) = makeSession()
        #expect(s.handle(.character("k"), modifiers: .control) == false)
        type(s, "kana")
        #expect(s.handle(.character("k"), modifiers: .control))
        #expect(c.candidates == ["かな", "カナ"])
        #expect(c.selected == 1)
        #expect(s.handle(.character("j"), modifiers: .control))
        #expect(c.selected == 0)
    }

    @Test func altSpaceTypesFullWidthSpace() {
        let (s, c) = makeSession()
        #expect(s.handle(.space, modifiers: .alt))
        #expect(c.committed == ["\u{3000}"])
        type(s, "a")
        s.handle(.space, modifiers: .alt)
        #expect(c.preedit == "あ\u{3000}")
    }

    @Test func otherKeyCommitsAndPassesThrough() {
        let (s, c) = makeSession()
        type(s, "ka")
        #expect(s.handle(.other) == false)
        #expect(c.committed == ["か"])
    }

    @Test func backspaceEditsThenClears() {
        let (s, c) = makeSession()
        type(s, "kak")
        s.handle(.backspace)
        #expect(c.preedit == "か")
        s.handle(.backspace)
        #expect(c.preedit == "")
        #expect(!s.isComposing)
    }

    @Test func controlSemicolonOpensTunerWithReading() {
        let (s, c) = makeSession()
        #expect(s.handle(.character(";"), modifiers: .control))
        type(s, "kana")
        s.handle(.character(";"), modifiers: .control)
        #expect(c.tunerOpened == [nil, "かな"])
    }

    @Test func deactivateCommitsActivateDiscards() {
        let (s, c) = makeSession()
        type(s, "ka")
        s.deactivate(commit: true)
        #expect(c.committed == ["か"])
        type(s, "ki")
        s.activate()
        #expect(c.committed == ["か"])
        #expect(!s.isComposing)
    }
}

struct SessionReconversionTests {
    @Test func backspaceRightAfterCommitReconverts() {
        let (s, c) = makeSession()
        type(s, "kana")
        s.handle(.space)
        s.handle(.down)
        s.handle(.enter)
        #expect(c.committed == ["カナ"])
        c.surrounding = SurroundingText(text: "あいカナ", cursor: 4, anchor: 4)
        #expect(s.handle(.backspace))
        #expect(c.deleted == [2])
        #expect(c.candidates == ["かな", "カナ"])
        #expect(c.selected == 1)
        #expect(c.preedit == "カナ")
    }

    @Test func onlyTheVeryNextKeyMayUndo() {
        let (s, c) = makeSession()
        type(s, "ka")
        s.handle(.enter)
        s.handle(.other)
        c.surrounding = SurroundingText(text: "か", cursor: 1, anchor: 1)
        #expect(s.handle(.backspace) == false)
    }

    @Test func mismatchOrSelectionFallsBackToNormalBackspace() {
        for surrounding in [
            SurroundingText(text: "かx", cursor: 2, anchor: 2),
            SurroundingText(text: "か", cursor: 1, anchor: 0),
            nil,
        ] {
            let (s, c) = makeSession()
            type(s, "ka")
            s.handle(.enter)
            c.surrounding = surrounding
            #expect(s.handle(.backspace) == false)
            #expect(c.deleted.isEmpty)
        }
    }

    @Test func settingOffKeepsControlBackspace() {
        let (s, c) = makeSession { $0.reconvertOnBackspace = false }
        type(s, "ka")
        s.handle(.enter)
        c.surrounding = SurroundingText(text: "か", cursor: 1, anchor: 1)
        #expect(s.handle(.backspace) == false)

        type(s, "ki")
        s.handle(.enter)
        c.surrounding = SurroundingText(text: "かき", cursor: 2, anchor: 2)
        #expect(s.handle(.backspace, modifiers: .control))
        #expect(c.deleted == [1])
    }

    @Test func scalarCountHandlesNonBMP() {
        let s = SurroundingText(text: "a𠮷野家", cursor: 4, anchor: 4)
        #expect(CommitUndo.scalarsToDelete(for: "𠮷野家", surrounding: s) == 3)
    }
}

struct SessionTimerTests {
    @Test func liveDelayWaitsForHostTimer() {
        let (s, c) = makeSession(live: true) { $0.liveConversionDelayMilliseconds = 150 }
        type(s, "ka")
        #expect(c.timers[.liveConversion] == 150)
        s.timerFired(.liveConversion)
        #expect(c.preedit == "か")
    }

    @Test func clearingCancelsTimers() {
        let (s, c) = makeSession(live: true) { $0.liveConversionDelayMilliseconds = 150 }
        type(s, "ka")
        s.handle(.escape)
        #expect(c.timers.isEmpty)
    }
}

@Suite(.enabled(if: hasDictionary, "dict/vimeu.dic not built — run `make dict`"))
struct SessionShippedDictionaryTests {
    @Test func liveConversionShowsBestPathInline() {
        let (s, c) = makeSession(engine: shippedEngine, live: true)
        type(s, "kyouhaiitenkidesune")
        #expect(c.preedit == shippedEngine.convert(reading: "きょうはいいてんきですね", limit: 1).first?.text)
        #expect(c.preedit != "きょうはいいてんきですね")
        s.handle(.enter)
        #expect(c.committed.count == 1)
        #expect(c.committed.first == c.committed.first.map { _ in
            shippedEngine.convert(reading: "きょうはいいてんきですね", limit: 1).first?.text ?? "" })
    }

    @Test func spaceListsNBestThenKanaForms() throws {
        let (s, c) = makeSession(engine: shippedEngine)
        type(s, "kawa")
        s.handle(.space)
        let list = try #require(c.candidates)
        #expect(list.count > 2)
        #expect(list.contains("川"))
        #expect(list.contains("かわ"))
        #expect(list.contains("カワ"))
    }

    @Test func autoCommitArmsAfterLiveResult() {
        let (s, c) = makeSession(engine: shippedEngine, live: true) {
            $0.autoCommitEnabled = true
            $0.autoCommitDelayMilliseconds = 500
        }
        type(s, "kawa")
        #expect(c.timers[.autoCommit] == 500)
        s.timerFired(.autoCommit)
        #expect(c.committed.count == 1)
        #expect(!s.isComposing)
    }

    @Test func longInputCommitsPrefixAndKeepsTailEditable() {
        let (s, c) = makeSession(engine: shippedEngine, live: true) {
            $0.partialCommit = PartialCommitSettings(length: 12, requiresStableCandidate: false)
        }
        type(s, "kyouhaiitenkinanodesanponiikimasu")
        #expect(!c.committed.isEmpty)
        #expect(s.isComposing)
        s.handle(.enter)
        let all = c.committed.joined()
        #expect(all == shippedEngine.convert(reading: "きょうはいいてんきなのでさんぽにいきます", limit: 1).first?.text)
    }
}
