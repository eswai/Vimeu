import Testing
import VimeuEngine
import VimeuInput
@testable import VimeuIME

struct PartialCommitStabilityTests {
    private let boundaryRules = PartialCommitBoundaryRules(posNames: ["名詞,一般"])
    private let settings = PartialCommitSettings(length: 4, requiresStableCandidate: true, stableLength: 3)

    private func candidate(_ words: [(String, String)]) -> Candidate {
        Candidate(text: words.map { $0.1 }.joined(), cost: 0, wordCost: 0, connectionCost: 0,
                  segments: words.map {
            Segment(reading: $0.0, surface: $0.1, wcost: 0, lid: 0, rid: 0)
        }, boundaries: [])
    }

    @Test func countsAdditionalReadingEvenBeforeTotalLengthThreshold() throws {
        var tracker = PartialCommitStability()
        #expect(tracker.observe(reading: "はし", candidate: candidate([("はし", "橋")]), settings: settings) == 0)
        #expect(tracker.observe(reading: "はしあ", candidate: candidate([("はし", "橋"), ("あ", "亜")]), settings: settings) == 0)
        let before = candidate([("はし", "橋"), ("あい", "愛")])
        let beforeCount = tracker.observe(reading: "はしあい", candidate: before, settings: settings)
        #expect(PartialCommit(boundaryRules: boundaryRules, reading: "はしあい", candidate: before, settings: settings,
                              stablePrefixScalarCount: beforeCount) == nil)
        let best = candidate([("はし", "橋"), ("あいう", "あいう")])
        let count = tracker.observe(reading: "はしあいう", candidate: best, settings: settings)
        #expect(count == 2)
        let prefix = try #require(PartialCommit(boundaryRules: boundaryRules, reading: "はしあいう", candidate: best, settings: settings,
                                               stablePrefixScalarCount: count))
        #expect(prefix.text == "橋")
        #expect(prefix.remainingReading == "あいう")
    }

    @Test func unchangedReadingAndPendingRomajiCannotAdvanceStability() {
        var tracker = PartialCommitStability()
        let best = candidate([("はし", "橋")])
        for _ in 0..<10 {
            #expect(tracker.observe(reading: "はし", candidate: best, settings: settings) == 0)
        }
    }

    @Test func changedLeadingCandidateRestartsCount() {
        var tracker = PartialCommitStability()
        _ = tracker.observe(reading: "はし", candidate: candidate([("はし", "橋")]), settings: settings)
        #expect(tracker.observe(reading: "はしあい", candidate: candidate([("はし", "箸"), ("あい", "愛")]), settings: settings) == 0)
        #expect(tracker.observe(reading: "はしあいうえ", candidate: candidate([("はし", "箸"), ("あいうえ", "あいうえ")]), settings: settings) == 0)
        #expect(tracker.observe(reading: "はしあいうえお", candidate: candidate([("はし", "箸"), ("あいうえお", "あいうえお")]), settings: settings) == 2)
    }

    @Test func onlyChangedSuffixRestartsAndNewWordsMustMature() {
        var tracker = PartialCommitStability()
        _ = tracker.observe(reading: "はし", candidate: candidate([("はし", "橋")]), settings: settings)
        _ = tracker.observe(reading: "はしを", candidate: candidate([("はし", "橋"), ("を", "を")]), settings: settings)
        #expect(tracker.observe(reading: "はしをわた", candidate: candidate([
            ("はし", "橋"), ("を", "を"), ("わた", "綿"),
        ]), settings: settings) == 2)
        #expect(tracker.observe(reading: "はしをわたる", candidate: candidate([
            ("はし", "橋"), ("を", "を"), ("わたる", "渡る"),
        ]), settings: settings) == 3)
    }

    @Test func deletionReplacementResetAndPreferenceChangesDiscardHistory() {
        var tracker = PartialCommitStability()
        let best = candidate([("はし", "橋"), ("あいう", "あいう")])
        _ = tracker.observe(reading: "はし", candidate: candidate([("はし", "橋")]), settings: settings)
        #expect(tracker.observe(reading: "はしあいう", candidate: best, settings: settings) == 2)
        #expect(tracker.observe(reading: "はし", candidate: candidate([("はし", "橋")]), settings: settings) == 0)
        #expect(tracker.observe(reading: "かさ", candidate: candidate([("かさ", "傘")]), settings: settings) == 0)
        tracker.reset()
        #expect(tracker.observe(reading: "はしあいう", candidate: best, settings: settings) == 0)
        let changed = PartialCommitSettings(length: 4, requiresStableCandidate: true, stableLength: 1)
        #expect(tracker.observe(reading: "はしあいう", candidate: best, settings: changed) == 0)
    }

    @Test func dictionaryFailureCannotProveStabilityAndClearsHistory() {
        var tracker = PartialCommitStability()
        _ = tracker.observe(reading: "はし", candidate: candidate([("はし", "橋")]), settings: settings)
        #expect(tracker.observe(reading: "はしあいう", candidate: nil, settings: settings) == 0)
        #expect(PartialCommit(boundaryRules: boundaryRules, reading: "はしあいう", candidate: nil, settings: settings,
                              stablePrefixScalarCount: 2) == nil)
        #expect(tracker.observe(reading: "はしあいう", candidate: candidate([("はし", "橋"), ("あいう", "あいう")]), settings: settings) == 0)
    }

    @Test func kanaModeChecksConvertedCandidateAndStillCommitsKana() throws {
        var tracker = PartialCommitStability()
        let rawSettings = PartialCommitSettings(length: 4, mode: .reading, requiresStableCandidate: true, stableLength: 3)
        _ = tracker.observe(reading: "はし", candidate: candidate([("はし", "橋")]), settings: rawSettings)
        let best = candidate([("はし", "橋"), ("あいう", "あいう")])
        let count = tracker.observe(reading: "はしあいう", candidate: best, settings: rawSettings)
        let prefix = try #require(PartialCommit(boundaryRules: boundaryRules, reading: "はしあいう", candidate: best, settings: rawSettings,
                                               liveConversion: false, stablePrefixScalarCount: count))
        #expect(prefix.text == "はし")
    }

    @Test func countsGraphemesWhileReturningEngineScalarPositions() {
        var tracker = PartialCommitStability()
        let value = PartialCommitSettings(length: 2, requiresStableCandidate: true, stableLength: 2)
        let kana = "か\u{3099}"
        let emoji = "👨‍👩‍👧‍👦"
        _ = tracker.observe(reading: kana, candidate: candidate([(kana, "が")]), settings: value)
        #expect(tracker.observe(reading: kana + emoji, candidate: candidate([(kana, "が"), (emoji, emoji)]), settings: value) == 0)
        #expect(tracker.observe(reading: kana + emoji + "あ", candidate: candidate([(kana, "が"), (emoji, emoji), ("あ", "亜")]), settings: value) == 2)
    }

    @Test func normalizationChangeCannotReuseOldScalarPositions() {
        var tracker = PartialCommitStability()
        _ = tracker.observe(reading: "が", candidate: candidate([("が", "が")]), settings: settings)
        let reading = "か\u{3099}あいう"
        #expect(tracker.observe(reading: reading, candidate: candidate([
            ("か\u{3099}", "が"), ("あいう", "あいう"),
        ]), settings: settings) == 0)
    }

    @Test func stablePrefixStillObeysRetainedTailLimit() throws {
        let best = candidate([("はし", "橋"), ("あ", "亜"), ("いう", "いう")])
        let value = PartialCommitSettings(length: 4, requiresStableCandidate: true, stableLength: 1)
        let prefix = try #require(PartialCommit(boundaryRules: boundaryRules, reading: "はしあいう", candidate: best, settings: value,
                                               stablePrefixScalarCount: 5))
        #expect(prefix.text == "橋亜")
        #expect(prefix.remainingReading == "いう")
    }
}
