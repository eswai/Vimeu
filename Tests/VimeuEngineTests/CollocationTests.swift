import XCTest
import VimeuDict
import VimeuUserDict
@testable import VimeuEngine

/// The co-occurrence term: which words can pair, what a registered pair is
/// worth, and — the part that matters most — what it is *not* allowed to do.
final class CollocationTests: XCTestCase {
    private var directory = URL(fileURLWithPath: "/tmp")
    private var dicPath = ""
    private var system: DicReader!
    private var store: UserDictionaryStore!
    private var editor: DictionaryEditor!

    /// `かわをむく` in miniature — the case the whole feature exists for.
    ///
    /// Every reading here has the same POS sequence (名詞 → 助詞 → 動詞), so the
    /// connection cost is identical for all four sentences and the ranking is
    /// decided entirely by word costs. `川を向く` wins by 300, which is exactly
    /// the situation Mozc's cost model cannot get out of on its own.
    private static let systemWords: [(reading: String, surface: String, cost: Int32, lid: Int, rid: Int)] = [
        ("かわ", "川", 1000, 1, 1),
        ("かわ", "皮", 1100, 1, 1),
        ("を", "を", 100, 2, 2),
        ("むく", "向く", 1000, 3, 3),
        ("むく", "剥く", 1200, 3, 3),
    ]

    override func setUpWithError() throws {
        let unique = UUID().uuidString
        dicPath = FileManager.default.temporaryDirectory
            .appendingPathComponent("vimeu-colloc-\(unique).dic").path
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("vimeu-colloc-\(unique)", isDirectory: true)

        system = try TestDictionary.write(to: dicPath, words: Self.systemWords)
        store = UserDictionaryStore(directory: directory)
        editor = DictionaryEditor(system: system, store: store)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(atPath: dicPath)
        try? FileManager.default.removeItem(at: directory)
    }

    private func convert(_ reading: String, limit: Int = 9) -> [Candidate] {
        Converter(dictionary: editor.dictionary).convert(reading: reading, limit: limit)
    }

    private func candidate(_ text: String, in candidates: [Candidate]) throws -> Candidate {
        try XCTUnwrap(candidates.first { $0.text == text }, "\(text) not among the candidates")
    }

    // MARK: - What can pair

    /// 皮 と 剥く, with `を` passed over. The particle is a word of the path but
    /// not of the pair — this is the whole reason the term cannot live inside
    /// the Viterbi, where only adjacent nodes see each other.
    func testParticlesAreSkippedBetweenContentWords() throws {
        let candidates = convert("かわをむく")
        let pairs = Collocation.pairs(
            of: try candidate("皮を剥く", in: candidates).segments,
            dictionary: editor.dictionary
        )
        XCTAssertEqual(pairs, [CollocationKey(left: "皮", right: "剥く")])
    }

    func testContentWordClassification() {
        XCTAssertTrue(Collocation.isContentWord(posName: "名詞,一般,*,*,*,*,*"))
        XCTAssertTrue(Collocation.isContentWord(posName: "動詞,自立,*,*,五段・カ行イ音便,基本形,*"))
        XCTAssertTrue(Collocation.isContentWord(posName: "副詞,一般,*,*,*,*,*"))
        XCTAssertFalse(Collocation.isContentWord(posName: "助詞,格助詞,一般,*,*,*,を"))
        XCTAssertFalse(Collocation.isContentWord(posName: "助動詞,*,*,*,特殊・タ,基本形,*"))
        XCTAssertFalse(Collocation.isContentWord(posName: "動詞,非自立,*,*,一段,基本形,*"))
        XCTAssertFalse(Collocation.isContentWord(posName: "名詞,接尾,人名,*,*,*,*"))
        XCTAssertFalse(Collocation.isContentWord(posName: "接頭詞,名詞接続,*,*,*,*,*"))
        XCTAssertFalse(Collocation.isContentWord(posName: "BOS/EOS,*,*,*,*,*,*"))
    }

    /// The menus offer the words of *every* candidate, not just the winner.
    /// `皮` and `剥く` are in different candidates here, and a pane that could
    /// only offer one candidate's words could never register the pair the user
    /// came to register.
    func testChoicesPoolEveryCandidate() {
        let candidates = convert("かわをむく")
        let choices = editor.collocationChoices(for: candidates)
        XCTAssertTrue(choices.contains("皮"))
        XCTAssertTrue(choices.contains("剥く"))
        XCTAssertFalse(choices.contains("を"), "particles are not offerable")
    }

    // MARK: - What a pair does

    func testRegisteredPairWins() throws {
        var candidates = convert("かわをむく")
        XCTAssertEqual(candidates.first?.text, "川を向く")
        XCTAssertEqual(candidates.first?.collocationCost, 0)

        editor.addCollocation(left: "皮", right: "剥く")
        candidates = convert("かわをむく")

        XCTAssertEqual(candidates.first?.text, "皮を剥く")
        let winner = try candidate("皮を剥く", in: candidates)
        XCTAssertEqual(winner.collocationCost, -UserDict.collocationBonus)
        XCTAssertEqual(winner.collocations, [CollocationKey(left: "皮", right: "剥く")])
        // The word and connection terms are Mozc's and stay Mozc's: the pair
        // moved the total and nothing else.
        XCTAssertEqual(winner.wordCost, 2400)
        XCTAssertEqual(winner.connectionCost, 350)
    }

    func testNegativePairExcludesMatchingCandidatesAbsolutely() throws {
        editor.addNegativeCollocation(left: "皮", right: "剥く")
        let candidates = convert("かわをむく")

        XCTAssertFalse(candidates.contains { $0.text == "皮を剥く" })
        XCTAssertTrue(candidates.allSatisfy {
            !Collocation.containsNegativePair(
                in: $0.segments,
                table: editor.dictionary.negativeCollocations,
                dictionary: editor.dictionary
            )
        })
        XCTAssertTrue(editor.dictionary.collocations.isEmpty)
        XCTAssertEqual(
            editor.dictionary.negativeCollocations,
            [CollocationKey(left: "剥く", right: "皮")]
        )
    }

    func testNegativePairIsUnorderedAndReplacesOppositeRelation() throws {
        editor.addPositiveCollocation(left: "皮", right: "剥く")
        editor.addNegativeCollocation(left: "剥く", right: "皮")

        XCTAssertTrue(editor.dictionary.collocations.isEmpty)
        XCTAssertEqual(
            editor.collocations.first?.polarity,
            .negative
        )
        XCTAssertEqual(editor.collocations.first?.left, "剥く")
        XCTAssertEqual(editor.collocations.first?.right, "皮")
        XCTAssertFalse(convert("かわをむく").contains { $0.text == "皮を剥く" })
    }

    /// Pairs are ordered. `(剥く, 皮)` is a different pair and does not fire on
    /// `皮を剥く`.
    func testPairsAreDirectional() throws {
        editor.addCollocation(left: "剥く", right: "皮")
        let candidates = convert("かわをむく")
        XCTAssertEqual(candidates.first?.text, "川を向く")
        XCTAssertTrue(candidates.allSatisfy { $0.collocationCost == 0 })
    }

    /// The bound that makes this safe to hand to users. A candidate more than
    /// `collocationWindow` behind is out of the running whatever the table says,
    /// so a wrong entry can only reshuffle the top — it cannot promote a
    /// sentence the cost model ruled out.
    func testPairCannotReachOutsideTheWindow() throws {
        let farPath = dicPath + ".far"
        let far = try TestDictionary.write(to: farPath, words: [
            ("かわ", "川", 1000, 1, 1),
            ("かわ", "皮", 1100, 1, 1),
            ("を", "を", 100, 2, 2),
            ("むく", "向く", 1000, 3, 3),
            // 5000 over 向く: 皮を剥く now trails by more than the window.
            ("むく", "剥く", 6000, 3, 3),
        ])
        defer { try? FileManager.default.removeItem(atPath: farPath) }

        let editor = DictionaryEditor(system: far, store: store)
        editor.addCollocation(left: "皮", right: "剥く")
        let candidates = Converter(dictionary: editor.dictionary)
            .convert(reading: "かわをむく", limit: 9)

        XCTAssertEqual(candidates.first?.text, "川を向く")
        let loser = try candidate("皮を剥く", in: candidates)
        XCTAssertEqual(loser.collocationCost, 0, "outside the window, nothing is credited")
    }

    /// Two pairs beat one. This is the entire ordering rule between candidates
    /// that both match, and the reason no per-pair weight is needed.
    func testHitsAccumulate() throws {
        let path = dicPath + ".two"
        let dic = try TestDictionary.write(to: path, words: [
            ("かわ", "川", 1000, 1, 1),
            ("かわ", "皮", 1000, 1, 1),
            ("を", "を", 100, 2, 2),
            ("むく", "向く", 1000, 3, 3),
            ("むく", "剥く", 1000, 3, 3),
        ])
        defer { try? FileManager.default.removeItem(atPath: path) }

        let editor = DictionaryEditor(system: dic, store: store)
        editor.addCollocation(left: "皮", right: "剥く")
        let candidates = Converter(dictionary: editor.dictionary)
            .convert(reading: "かわをむく", limit: 9)
        XCTAssertEqual(candidates.first?.text, "皮を剥く")
        XCTAssertEqual(candidates.first?.collocationCost, -UserDict.collocationBonus)
    }

    /// `cost == wordCost + connectionCost + collocationCost`, still exactly. The
    /// tuning window puts the four numbers in a row and they have to reconcile.
    func testCostSplitsExactlyWithACollocation() throws {
        editor.addCollocation(left: "皮", right: "剥く")
        for candidate in convert("かわをむく") {
            XCTAssertEqual(
                candidate.cost,
                candidate.wordCost + candidate.connectionCost + candidate.collocationCost,
                candidate.text
            )
            XCTAssertEqual(candidate.wordCost, candidate.segments.reduce(0) { $0 + $1.wcost })
            XCTAssertEqual(candidate.connectionCost, candidate.boundaries.reduce(0) { $0 + $1.cost })
            XCTAssertLessThanOrEqual(candidate.collocationCost, 0, "a credit never adds cost")
        }
    }

    // MARK: - Persistence

    func testPairsSurviveAReload() throws {
        editor.addCollocation(left: "皮", right: "剥く")
        editor.addNegativeCollocation(left: "川", right: "剥く")

        let reopened = DictionaryEditor(system: system, store: UserDictionaryStore(directory: directory))
        XCTAssertEqual(
            reopened.dictionary.collocations, [CollocationKey(left: "皮", right: "剥く")]
        )
        XCTAssertEqual(
            reopened.dictionary.negativeCollocations,
            [CollocationKey(left: "剥く", right: "川")]
        )
        XCTAssertEqual(
            Converter(dictionary: reopened.dictionary).convert(reading: "かわをむく").first?.text,
            "皮を剥く"
        )
    }

    func testRemoveDropsThePairEntirely() throws {
        editor.addCollocation(left: "皮", right: "剥く")
        editor.removeCollocation(left: "皮", right: "剥く")

        XCTAssertTrue(editor.collocations.isEmpty)
        XCTAssertEqual(convert("かわをむく").first?.text, "川を向く")
    }

    /// No pairs means the search is not deepened and no candidate is touched —
    /// the feature costs nothing until it is used.
    func testNoPairsLeavesConversionUntouched() throws {
        let candidates = convert("かわをむく")
        XCTAssertTrue(candidates.allSatisfy { $0.collocationCost == 0 })
        XCTAssertTrue(candidates.allSatisfy { $0.collocations.isEmpty })
        XCTAssertEqual(candidates.first?.text, "川を向く")
    }
}
