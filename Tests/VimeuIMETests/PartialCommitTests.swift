import Foundation
import Testing
import VimeuEngine
import VimeuInput
@testable import VimeuIME

struct PartialCommitTests {
    // Synthetic IDs, independent of the shipped dictionary's numbering.
    private let boundaryRules = PartialCommitBoundaryRules(posNames: [
        "名詞,一般", "助詞,格助詞", "助動詞,*", "動詞,非自立", "名詞,接尾",
        "接頭詞,名詞接続", "動詞,自立", "名詞,代名詞", "感動詞,*", "形容詞,自立", "名詞,動詞非自立的",
    ])
    private let lengthOnly = PartialCommitSettings(requiresStableCandidate: false)

    private func candidate(_ words: [(String, String)], ids: [Int]? = nil) -> Candidate {
        candidate(segments: words.enumerated().map { i, word in
            Segment(reading: word.0, surface: word.1, wcost: 0, lid: ids?[i] ?? 0, rid: ids?[i] ?? 0)
        })
    }

    private func candidate(segments: [Segment]) -> Candidate {
        Candidate(text: segments.map(\.surface).joined(), cost: 0, wordCost: 0,
                  connectionCost: 0, segments: segments, boundaries: [])
    }

    private func passthrough(_ reading: String) -> Candidate {
        candidate(reading.map { (String($0), String($0)) })
    }

    private func plan(_ reading: String, best: Candidate? = nil,
                      settings: PartialCommitSettings? = nil, live: Bool = true,
                      stable: Int = 0) -> PartialCommit? {
        PartialCommit(boundaryRules: boundaryRules, reading: reading, candidate: best ?? passthrough(reading),
                      settings: settings ?? lengthOnly, liveConversion: live, stablePrefixScalarCount: stable)
    }

    @Test func startsAtThresholdAndLeavesRecentInput() throws {
        #expect(plan(String(repeating: "あ", count: 39)) == nil)
        let reading = String(repeating: "あ", count: 40)
        let prefix = try #require(plan(reading))
        #expect(prefix.reading.count == 20)
        #expect(prefix.remainingReading.count == 20)
        #expect(prefix.text + prefix.remainingText == reading)
    }

    @Test func splitsOnlyAtWordBoundaryAndKeepsConvertedSuffix() throws {
        let first = String(repeating: "あ", count: 18)
        let second = String(repeating: "い", count: 7)
        let last = String(repeating: "う", count: 15)
        let best = candidate([(first, "先頭"), (second, "途中"), (last, "末尾")])
        let prefix = try #require(plan(first + second + last, best: best))
        #expect(prefix.reading == first)
        #expect(prefix.text == "先頭")
        #expect(prefix.remainingReading == second + last)
        #expect(prefix.text + prefix.remainingText == best.text)
    }

    @Test func modeSelectsConvertedOrKanaPrefix() throws {
        let first = String(repeating: "あ", count: 18)
        let last = String(repeating: "い", count: 22)
        let best = candidate([(first, "先頭"), (last, "末尾")])
        let kana = PartialCommitSettings(mode: .reading, requiresStableCandidate: false)
        #expect(try #require(plan(first + last, best: best, live: false)).text == "先頭")
        #expect(try #require(plan(first + last, best: best, settings: kana, live: false)).text == first)
        #expect(try #require(plan(first + last, best: best, settings: kana, live: true)).text == "先頭")
    }

    @Test func customLengthAndDisabledSettings() throws {
        let settings = PartialCommitSettings(length: 10, requiresStableCandidate: false)
        #expect(plan(String(repeating: "あ", count: 9), settings: settings) == nil)
        #expect(try #require(plan(String(repeating: "あ", count: 10), settings: settings)).remainingReading.count == 5)
        let minimum = try #require(plan("あい", settings: PartialCommitSettings(length: 2, requiresStableCandidate: false)))
        #expect(minimum.text == "あ")
        #expect(minimum.remainingReading == "い")
        #expect(plan(String(repeating: "あ", count: 100), settings: PartialCommitSettings(enabled: false)) == nil)
    }

    @Test func defaultStabilityRequiresActualObservation() throws {
        let reading = String(repeating: "あ", count: 40)
        #expect(plan(reading, settings: PartialCommitSettings()) == nil)
        #expect(try #require(plan(reading, settings: PartialCommitSettings(), stable: 10)).reading.count == 10)
    }

    @Test func waitsForFirstWordMissingDictionaryOrMismatchedPath() {
        let reading = String(repeating: "あ", count: 40)
        #expect(plan(reading, best: candidate([(reading, "長い単語")])) == nil)
        #expect(plan(reading, best: candidate([("い", "異")])) == nil)
        #expect(PartialCommit(boundaryRules: boundaryRules, reading: reading, candidate: nil, settings: lengthOnly) == nil)
    }

    @Test(arguments: [1, 2, 3, 4, 10])
    func attachedWordCannotHeadRemainder(_ attachedID: Int) {
        let first = String(repeating: "あ", count: 18)
        let attached = String(repeating: "い", count: 4)
        let last = String(repeating: "う", count: 18)
        let best = candidate([(first, "語"), (attached, "付属語"), (last, "末尾")], ids: [0, attachedID, 0])
        #expect(plan(first + attached + last, best: best) == nil)
    }

    @Test func retreatsToLastAllowedBoundaryWithinStablePrefix() throws {
        let a = String(repeating: "あ", count: 10)
        let b = String(repeating: "い", count: 8)
        let c = String(repeating: "う", count: 4)
        let d = String(repeating: "え", count: 18)
        let best = candidate([(a, "前"), (b, "語"), (c, "ます"), (d, "後")], ids: [0, 6, 2, 0])
        let prefix = try #require(plan(a + b + c + d, best: best, settings: PartialCommitSettings(), stable: 18))
        #expect(prefix.reading == a)
        #expect(prefix.remainingText == "語ます後")
    }

    @Test func prefixStaysWithFollowingWordAndHiraganaContentWordsMayStart() throws {
        let a = String(repeating: "あ", count: 10)
        let b = String(repeating: "い", count: 8)
        let c = String(repeating: "う", count: 22)
        let best = candidate([(a, "前"), (b, "お"), (c, "土産")], ids: [0, 5, 0])
        #expect(try #require(plan(a + b + c, best: best)).text == "前")
        for id in [7, 8, 9] {
            let content = candidate([(a + b, "前"), (c, "これ")], ids: [0, id])
            #expect(try #require(plan(a + b + c, best: content)).remainingText == "これ")
        }
    }

    @Test func compoundUsesRightPOSOnLeftAndLeftPOSOnRight() throws {
        let a = String(repeating: "あ", count: 18)
        let b = String(repeating: "い", count: 22)
        let best = candidate(segments: [
            Segment(reading: a, surface: "前", wcost: 0, lid: 5, rid: 6),
            Segment(reading: b, surface: "後", wcost: 0, lid: 0, rid: 1),
        ])
        let prefix = try #require(plan(a + b, best: best))
        #expect(prefix.text == "前")
        #expect(prefix.previousRightID == 6)
    }

    @Test func unknownPOSIsNotAnAllowedBoundary() {
        #expect(!boundaryRules.allows(leftRightID: -1, rightLeftID: 0))
        #expect(!boundaryRules.allows(leftRightID: 0, rightLeftID: 999))
    }

    @Test func continuousTypingPreservesSuffixAndPendingRomaji() {
        var buffer = InputBuffer()
        var tracker = PartialCommitStability()
        let settings = PartialCommitSettings()
        var committed = ""
        var commits = 0
        for ch in String(repeating: "ka", count: 100) + "ky" {
            buffer.accept(ch)
            let best = passthrough(buffer.reading)
            let stable = tracker.observe(reading: buffer.reading, candidate: best, settings: settings)
            if let prefix = plan(buffer.reading, best: best, settings: settings, stable: stable) {
                committed += prefix.text
                buffer.reading = prefix.remainingReading
                tracker.reset()
                commits += 1
            }
        }
        #expect(commits == 4)
        #expect(buffer.reading.count == 20)
        #expect(committed + buffer.reading == String(repeating: "か", count: 100))
        #expect(buffer.converter.pending == "ky")
        buffer.accept("a")
        #expect(buffer.reading == String(repeating: "か", count: 20) + "きゃ")
    }

    @Test func preservesUnicodeGraphemesAndDigits() throws {
        let reading = String(repeating: "か\u{3099}", count: 40)
        let best = candidate(reading.unicodeScalars.map { (String($0), String($0)) })
        let prefix = try #require(plan(reading, best: best))
        #expect(prefix.reading.count == 20)
        #expect(prefix.reading.unicodeScalars.count == 40)
        #expect(prefix.text + prefix.remainingText == reading)
        let mixed = String(repeating: "1か👨‍👩‍👧‍👦", count: 14)
        #expect(try #require(plan(mixed)).remainingReading.count == 20)
    }
}
