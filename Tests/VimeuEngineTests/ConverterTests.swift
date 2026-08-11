import XCTest
import VimeuDict
@testable import VimeuEngine

/// The decoder, against a hand-built dictionary: lattice coverage, Mozc's cost
/// recurrence, the exactness of the n-best, and the identity the tuning UI
/// depends on.
final class ConverterTests: XCTestCase {
    private var path = ""

    override func setUpWithError() throws {
        path = FileManager.default.temporaryDirectory
            .appendingPathComponent("vimeu-engine-\(UUID().uuidString).dic").path
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(atPath: path)
    }

    private func makeDictionary(
        _ words: [(reading: String, surface: String, cost: Int32, lid: Int, rid: Int)],
        prefixPenalty: [UInt16]? = nil,
        suffixPenalty: [UInt16]? = nil
    ) throws -> DicReader {
        try TestDictionary.write(
            to: path, words: words,
            prefixPenalty: prefixPenalty, suffixPenalty: suffixPenalty
        )
    }

    private func lattice(_ dic: DicReader, _ reading: String) -> Lattice {
        Lattice.build(
            reading: Array(reading.unicodeScalars),
            codes: dic.encode(reading),
            dictionary: dic
        )
    }

    // MARK: - Lattice

    /// Mozc adds a one-character node at every position unconditionally
    /// (`AddCharacterTypeBasedNodes`), which is what guarantees the lattice spans
    /// the input no matter how the dictionary entries fall.
    func testEveryPositionHasAPassthroughNode() throws {
        let dic = try makeDictionary([("はし", "橋", 2000, 1, 1)])
        let lattice = lattice(dic, "はしだ")
        let kana = Array("はしだ").map(String.init)

        XCTAssertEqual(lattice.length, 3)
        XCTAssertEqual(lattice.beginIndices.count, 3)
        for position in 0..<3 {
            let surfaces = lattice.beginIndices[position].map { lattice.nodes[$0].surface }
            XCTAssertTrue(surfaces.contains(kana[position]), "position \(position)")
        }
        // は also starts the two-kana entry 橋.
        let atZero = lattice.beginIndices[0].map { lattice.nodes[$0].surface }
        XCTAssertEqual(Set(atZero), ["橋", "は"])
        // The passthrough carries Mozc's kMaxCost and its unknown POS.
        let passthrough = lattice.nodes[lattice.beginIndices[2][0]]
        XCTAssertEqual(passthrough.wcost, Lattice.unknownCost)
        XCTAssertEqual(passthrough.lid, TestDictionary.unknownPOSID)
    }

    func testEndIndicesMirrorBeginIndices() throws {
        let dic = try makeDictionary([("はし", "橋", 2000, 1, 1)])
        let lattice = lattice(dic, "はしだ")
        for (index, node) in lattice.nodes.enumerated() {
            XCTAssertTrue(lattice.beginIndices[node.begin].contains(index))
            XCTAssertTrue(lattice.endIndices[node.end].contains(index))
        }
    }

    /// `boundary.def`'s penalties belong to the first and last words only, as in
    /// Mozc's `ApplyPrefixSuffixPenalty`, and are folded into `wcost` so the
    /// decoder does not have to know about them.
    func testBoundaryPenaltiesApplyOnlyAtTheEnds() throws {
        var prefix = [UInt16](repeating: 0, count: TestDictionary.posCount)
        var suffix = [UInt16](repeating: 0, count: TestDictionary.posCount)
        prefix[1] = 700
        suffix[1] = 300
        let dic = try makeDictionary(
            [("あ", "亜", 1000, 1, 1), ("い", "居", 1000, 1, 1), ("う", "宇", 1000, 1, 1)],
            prefixPenalty: prefix, suffixPenalty: suffix
        )
        let lattice = lattice(dic, "あいう")

        func wcost(_ surface: String) -> Int32 {
            lattice.nodes.first { $0.surface == surface }!.wcost
        }
        XCTAssertEqual(wcost("亜"), 1000 + 700)  // first word: prefix only
        XCTAssertEqual(wcost("居"), 1000)        // middle: neither
        XCTAssertEqual(wcost("宇"), 1000 + 300)  // last word: suffix only
    }

    /// A reading with no dictionary coverage at all still converts — to itself.
    func testUnknownReadingPassesThrough() throws {
        let dic = try makeDictionary([("あ", "亜", 1000, 1, 1)])
        XCTAssertEqual(Converter(dictionary: dic).best(reading: "ぬぬぬ"), "ぬぬぬ")
    }

    func testEmptyReadingConvertsToNothing() throws {
        let dic = try makeDictionary([("あ", "亜", 1000, 1, 1)])
        XCTAssertEqual(Converter(dictionary: dic).convert(reading: "").count, 0)
    }

    // MARK: - The cost model

    /// The whole point of the project, checked by hand.
    ///
    /// `亜` (名詞, 1000) then `偉` (助詞, 500) costs
    /// `trans(BOS→名詞) + 1000 + trans(名詞→助詞) + 500 + trans(助詞→EOS)`
    /// = 100 + 1000 + 100 + 500 + 300 = 2000, while the single entry `愛`
    /// (名詞, 1500) costs 100 + 1500 + 200 = 1800 and therefore wins.
    func testTotalCostFollowsMozcsRecurrence() throws {
        let dic = try makeDictionary([
            ("あ", "亜", 1000, 1, 1),
            ("い", "偉", 500, 2, 2),
            ("あい", "愛", 1500, 1, 1),
        ])
        let candidates = Converter(dictionary: dic).convert(reading: "あい", limit: 5)

        XCTAssertEqual(candidates[0].text, "愛")
        XCTAssertEqual(candidates[0].cost, 1800)
        XCTAssertEqual(candidates[0].wordCost, 1500)
        XCTAssertEqual(candidates[0].connectionCost, 300)

        let twoWord = candidates.first { $0.text == "亜偉" }
        XCTAssertEqual(twoWord?.cost, 2000)
        XCTAssertEqual(twoWord?.wordCost, 1500)
        XCTAssertEqual(twoWord?.connectionCost, 500)
    }

    /// `cost == wordCost + connectionCost`, exactly — with no registered pairs
    /// the collocation term is not there at all. The tuning window shows the
    /// numbers side by side and they have to reconcile, or the breakdown is
    /// unreadable. `CollocationTests` fixes the same identity with the third
    /// term in play.
    func testCostSplitsExactly() throws {
        let dic = try makeDictionary([
            ("きょう", "今日", 3000, 1, 1),
            ("は", "は", 100, 2, 2),
            ("あめ", "雨", 2500, 1, 1),
            ("あめ", "飴", 4000, 1, 1),
        ])
        let candidates = Converter(dictionary: dic).convert(reading: "きょうはあめ", limit: 9)
        XCTAssertFalse(candidates.isEmpty)
        for candidate in candidates {
            XCTAssertEqual(
                candidate.cost, candidate.wordCost + candidate.connectionCost, candidate.text
            )
            XCTAssertEqual(candidate.wordCost, candidate.segments.reduce(0) { $0 + $1.wcost })
            XCTAssertEqual(candidate.connectionCost, candidate.boundaries.reduce(0) { $0 + $1.cost })
            XCTAssertEqual(candidate.collocationCost, 0)
        }
    }

    /// Boundaries bracket the segments: one per gap, plus BOS at the front and
    /// EOS at the back. The 接続 pane reads straight off this.
    func testBoundariesBracketTheSegments() throws {
        let dic = try makeDictionary([
            ("あ", "亜", 1000, 1, 1),
            ("い", "偉", 500, 2, 2),
        ])
        let candidate = Converter(dictionary: dic).convert(reading: "あい", limit: 1)[0]

        XCTAssertEqual(candidate.boundaries.count, candidate.segments.count + 1)
        XCTAssertNil(candidate.boundaries.first?.left)   // BOS
        XCTAssertEqual(candidate.boundaries.first?.rid, 0)
        XCTAssertNil(candidate.boundaries.last?.right)   // EOS
        XCTAssertEqual(candidate.boundaries.last?.lid, 0)
    }

    func testSegmentsCarryReadingsAndPOS() throws {
        let dic = try makeDictionary([
            ("きょう", "今日", 3000, 1, 1),
            ("は", "は", 100, 2, 2),
        ])
        let candidate = Converter(dictionary: dic).convert(reading: "きょうは", limit: 1)[0]
        XCTAssertEqual(candidate.segments.map(\.reading), ["きょう", "は"])
        XCTAssertEqual(candidate.segments.map(\.surface), ["今日", "は"])
        XCTAssertEqual(candidate.segments.map(\.lid), [1, 2])
    }

    // MARK: - n-best

    func testCandidatesAreOrderedByCostAscending() throws {
        let dic = try makeDictionary([
            ("あ", "亜", 1000, 1, 1),
            ("あ", "阿", 1200, 1, 1),
            ("あ", "吾", 1500, 1, 1),
            ("い", "偉", 500, 2, 2),
        ])
        let candidates = Converter(dictionary: dic).convert(reading: "あい", limit: 9)
        XCTAssertEqual(candidates.map(\.cost), candidates.map(\.cost).sorted())
        XCTAssertEqual(candidates.first?.text, "亜偉")
    }

    /// The A\* must return the *true* k-best, not an approximation. Checked
    /// against brute force over every path in the lattice.
    func testNBestMatchesExhaustiveSearch() throws {
        let dic = try makeDictionary([
            ("あ", "亜", 1000, 1, 1),
            ("あ", "阿", 1200, 3, 3),
            ("い", "偉", 500, 2, 2),
            ("い", "井", 900, 1, 1),
            ("あい", "愛", 2600, 1, 1),
            ("う", "宇", 700, 1, 1),
            ("いう", "言う", 1800, 3, 3),
        ])
        let reading = "あいう"
        let lattice = lattice(dic, reading)
        let viterbi = Viterbi.run(lattice: lattice, dictionary: dic)

        let exhaustive = allPathCosts(lattice: lattice, dictionary: dic)
        XCTAssertEqual(viterbi.totalCost, exhaustive.map(\.cost).min())

        // Cheapest cost per distinct surface string, which is what the converter
        // collapses to.
        var cheapest: [String: Int32] = [:]
        for path in exhaustive {
            cheapest[path.text] = min(cheapest[path.text] ?? .max, path.cost)
        }
        let expected = cheapest.sorted {
            $0.value != $1.value ? $0.value < $1.value : $0.key < $1.key
        }

        let candidates = Converter(dictionary: dic).convert(reading: reading, limit: 1000)
        XCTAssertEqual(candidates.count, expected.count)
        XCTAssertEqual(candidates.map(\.cost), expected.map(\.value))
        XCTAssertEqual(Set(candidates.map(\.text)), Set(expected.map(\.key)))
    }

    /// The best path from the forward pass and the first result of the backward
    /// pass have to be the same sentence — they are two different algorithms
    /// over the same lattice.
    func testViterbiBestPathAgreesWithFirstCandidate() throws {
        let dic = try makeDictionary([
            ("あ", "亜", 1000, 1, 1),
            ("あ", "阿", 1200, 3, 3),
            ("い", "偉", 500, 2, 2),
            ("あい", "愛", 2600, 1, 1),
        ])
        let lattice = lattice(dic, "あい")
        let viterbi = Viterbi.run(lattice: lattice, dictionary: dic)
        let viterbiText = viterbi.bestPath().map { lattice.nodes[$0].surface }.joined()

        let candidate = Converter(dictionary: dic).convert(reading: "あい", limit: 1)[0]
        XCTAssertEqual(viterbiText, candidate.text)
        XCTAssertEqual(viterbi.totalCost, candidate.cost)
    }

    func testDuplicateSurfacesAreCollapsed() throws {
        // 亜 is reachable both as one two-kana entry and as one one-kana entry
        // followed by an empty-ish continuation, producing the same string by
        // different segmentations.
        let dic = try makeDictionary([
            ("あ", "亜", 1000, 1, 1),
            ("あい", "亜", 3000, 1, 1),
            ("い", "偉", 500, 2, 2),
        ])
        let candidates = Converter(dictionary: dic).convert(reading: "あい", limit: 9)
        XCTAssertEqual(Set(candidates.map(\.text)).count, candidates.count)
    }

    func testLimitIsRespected() throws {
        let dic = try makeDictionary([
            ("あ", "亜", 1000, 1, 1),
            ("あ", "阿", 1200, 1, 1),
            ("あ", "吾", 1500, 1, 1),
            ("あ", "唖", 1700, 1, 1),
        ])
        XCTAssertEqual(Converter(dictionary: dic).convert(reading: "あ", limit: 2).count, 2)
    }

    // MARK: - Brute force reference

    private struct ExhaustivePath {
        var text: String
        var cost: Int32
    }

    /// Every path through the lattice with its exact Mozc cost. Exponential —
    /// only usable on the tiny test lattices, which is the point: it is an
    /// independent implementation to check the fast one against.
    private func allPathCosts(lattice: Lattice, dictionary: DictionarySource) -> [ExhaustivePath] {
        var out: [ExhaustivePath] = []

        func walk(position: Int, previousRID: Int, text: String, cost: Int32) {
            if position == lattice.length {
                out.append(ExhaustivePath(
                    text: text, cost: cost + dictionary.transitionCost(previousRID, 0)
                ))
                return
            }
            for index in lattice.beginIndices[position] {
                let node = lattice.nodes[index]
                walk(
                    position: node.end,
                    previousRID: node.rid,
                    text: text + node.surface,
                    cost: cost + dictionary.transitionCost(previousRID, node.lid) + node.wcost
                )
            }
        }

        walk(position: 0, previousRID: 0, text: "", cost: 0)
        return out
    }
}
