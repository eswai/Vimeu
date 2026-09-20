import Foundation
import Testing
@testable import VimeuNatural

struct NaturalCandidateFilterTests {
    @Test func instructionsAcceptPartialOrAmbiguousJapanese() {
        let instructions = FoundationModelsNaturalJapaneseClassifier.instructions

        #expect(instructions.contains("変換途中の部分文字列"))
        #expect(instructions.contains("前後に文脈を補えば日本語として成立しうる場合は y"))
        #expect(instructions.contains("判断の迷いがある場合は y"))
        #expect(instructions.contains("明らかに破綻している場合だけ n"))
        #expect(!instructions.contains("少しでも不自然"))
    }

    @Test func promotesTheFirstNaturalCandidateAndStops() async {
        let calls = LockedCalls()
        let filter = NaturalCandidateFilter { candidate in
            calls.append(candidate)
            return candidate == "第二候補"
        }

        let result = await filter.filter(["第一候補", "第二候補", "第三候補"])

        #expect(result == ["第二候補", "第一候補", "第三候補"])
        #expect(calls.values == ["第一候補", "第二候補"])
    }

    @Test func recordsRejectedCandidatesBeforeTheAcceptedOne() async {
        let filter = NaturalCandidateFilter { $0 == "第三候補" }

        let result = await filter.evaluate(["第一候補", "第二候補", "第三候補"])

        #expect(result.acceptedIndex == 2)
        #expect(result.unnaturalIndices == [0, 1])
        #expect(result.completedWithoutError)
    }

    @Test func evaluationCanRerankACompleteListSharingItsPrefix() {
        let evaluation = NaturalCandidateEvaluation(
            acceptedIndex: 2,
            unnaturalIndices: [0, 1],
            completedWithoutError: true
        )

        let result = evaluation.applying(
            to: ["第一候補", "第二候補", "第三候補", "未評価候補"]
        )

        #expect(result == ["第三候補", "第一候補", "第二候補", "未評価候補"])
    }

    @Test func keepsTheOriginalListWhenTenCandidatesAreRejected() async {
        let candidates = (1...12).map { "候補\($0)" }
        let calls = LockedCalls()
        let filter = NaturalCandidateFilter { candidate in
            calls.append(candidate)
            return false
        }

        let result = await filter.filter(candidates)

        #expect(result == candidates)
        #expect(calls.values == Array(candidates.prefix(10)))
    }

    @Test func promotesTheTenthCandidateButNeverChecksTheEleventh() async {
        let candidates = (1...12).map { "候補\($0)" }
        let calls = LockedCalls()
        let filter = NaturalCandidateFilter { candidate in
            calls.append(candidate)
            return candidate == "候補10"
        }

        let result = await filter.filter(candidates)

        let expected = ["候補10"]
            + Array(candidates[0..<9])
            + Array(candidates[10...])
        #expect(result == expected)
        #expect(calls.values == Array(candidates.prefix(10)))
    }

    @Test func keepsTheOriginalListWhenClassificationFails() async {
        enum ExpectedFailure: Error { case failed }
        let candidates = ["第一候補", "第二候補"]
        let filter = NaturalCandidateFilter { _ in throw ExpectedFailure.failed }

        let evaluation = await filter.evaluate(candidates)
        let result = await filter.filter(candidates)

        #expect(result == candidates)
        #expect(!evaluation.completedWithoutError)
    }
}

private final class LockedCalls: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String] = []

    var values: [String] {
        lock.withLock { storage }
    }

    func append(_ value: String) {
        lock.withLock { storage.append(value) }
    }
}
