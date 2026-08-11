import XCTest
import VimeuDict
import VimeuUserDict
@testable import VimeuEngine

/// End-to-end checks against the real `dict/vimeu.dic`.
///
/// The synthetic dictionaries in the other tests have a handful of entries; this
/// is the only place the decoder and the overlay meet 739K readings, 2,672 POS
/// ids and the real connection matrix. Skipped when the dictionary has not been
/// built.
final class ShippedDictionaryTests: XCTestCase {
    private var system: DicReader!
    private var directory = URL(fileURLWithPath: "/tmp")
    private var editor: DictionaryEditor!

    private static var dicPath: String {
        URL(fileURLWithPath: #filePath)          // Tests/VimeuEngineTests/…
            .deletingLastPathComponent()          // Tests/VimeuEngineTests
            .deletingLastPathComponent()          // Tests
            .deletingLastPathComponent()          // package root
            .appendingPathComponent("dict/vimeu.dic")
            .path
    }

    override func setUpWithError() throws {
        try XCTSkipUnless(
            FileManager.default.fileExists(atPath: Self.dicPath),
            "dict/vimeu.dic not built — run `make dict`"
        )
        system = try DicReader(path: Self.dicPath)
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("vimeu-shipped-\(UUID().uuidString)", isDirectory: true)
        editor = DictionaryEditor(system: system, store: UserDictionaryStore(directory: directory))
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func convert(_ reading: String, limit: Int = 9) -> [Candidate] {
        Converter(dictionary: editor.dictionary).convert(reading: reading, limit: limit)
    }

    private func best(_ reading: String) -> String {
        convert(reading, limit: 1).first?.text ?? ""
    }

    /// The shipped dictionary is Mozc's, unchanged.
    func testShippedDictionaryCarriesMozcsPOSTable() {
        XCTAssertEqual(system.posCount, 2672)
        XCTAssertEqual(system.posName(0), "BOS/EOS,*,*,*,*,*,*")
        XCTAssertEqual(system.posName(system.unknownPOSID), "名詞,サ変接続,*,*,*,*,*")
    }

    /// The errors the predecessor could not fix without connection costs. Each
    /// of these was wrong when the model was word costs alone (see DESIGN.md
    /// §1), and each is right now because a particle following a pronoun is
    /// cheap and a noun following one is not.
    func testConnectionCostsFixThePredecessorsErrors() {
        XCTAssertEqual(best("これをください"), "これをください")
        XCTAssertEqual(best("きょうはいいてんきですよ"), "今日はいい天気ですよ")
    }

    /// Every candidate's total has to reconcile with its parts on the real
    /// dictionary too, not just the toy ones — this is what the tuning window
    /// prints.
    func testCostIdentityHoldsOnRealConversions() {
        for candidate in convert("きょうはいいてんきですね") {
            XCTAssertEqual(
                candidate.cost, candidate.wordCost + candidate.connectionCost, candidate.text
            )
            XCTAssertEqual(candidate.boundaries.count, candidate.segments.count + 1)
        }
    }

    func testCandidatesComeBackCheapestFirst() {
        let costs = convert("あめがふる").map(\.cost)
        XCTAssertGreaterThan(costs.count, 1)
        XCTAssertEqual(costs, costs.sorted())
    }

    /// Hiding an entry, on the real dictionary, from the sentence that provoked
    /// it.
    ///
    /// `となりのいえ → 隣の家` looks like three words but is a *single* dictionary
    /// entry: Mozc registers whole phrases, so the reading is all six kana and
    /// the surface is all three words. That is exactly why the tuning window
    /// lists knobs built from a candidate's segmentation rather than from its
    /// characters — the row it shows is the key that can actually be edited,
    /// however many words it looks like.
    ///
    /// Hiding it changes the *segmentation*, not the string: with connection
    /// costs, 隣 + の + 家 spells the same thing and is only slightly dearer. The
    /// assertion is therefore about which entries the winner is made of, which
    /// is what the user dictionary actually controls.
    func testHidingAnEntryRemovesItFromRealConversions() throws {
        let candidates = convert("となりのいえ")
        XCTAssertEqual(candidates.first?.text, "隣の家")
        XCTAssertEqual(
            candidates.first?.segments.map(\.reading), ["となりのいえ"],
            "the whole phrase is one entry"
        )

        let knobs = editor.wordKnobs(for: candidates, reading: "となりのいえ")
        let phrase = try XCTUnwrap(knobs.first { $0.surface == "隣の家" })
        XCTAssertEqual(phrase.reading, "となりのいえ")
        XCTAssertNotNil(phrase.baseCost, "it comes from the system dictionary")
        XCTAssertFalse(phrase.userOverride)
        XCTAssertFalse(phrase.posNames.isEmpty)

        editor.deleteWord(reading: phrase.reading, surface: phrase.surface)
        let hidden = convert("となりのいえ")
        XCTAssertFalse(
            hidden.contains { $0.segments.contains { $0.surface == "隣の家" } },
            "the phrase entry is out of the lattice"
        )

        editor.reviveWord(reading: phrase.reading, surface: phrase.surface)
        XCTAssertEqual(convert("となりのいえ").first?.segments.map(\.reading), ["となりのいえ"])
    }

    /// A surface can have several readings, and each is its own entry. Hiding
    /// one leaves the others.
    func testEntriesAreKeyedByReadingAndSurface() throws {
        XCTAssertFalse(system.tokens(reading: "となり", surface: "隣").isEmpty)
        XCTAssertFalse(system.tokens(reading: "とな", surface: "隣").isEmpty)

        editor.deleteWord(reading: "となり", surface: "隣")
        XCTAssertNil(editor.dictionary.effectiveCost(reading: "となり", surface: "隣"))
        XCTAssertNotNil(editor.dictionary.effectiveCost(reading: "とな", surface: "隣"))
    }

    func testOverrideChangesRealConversions() throws {
        let before = best("はし")
        XCTAssertNotEqual(before, "箸", "the test would be vacuous if 箸 already won")
        editor.setWordCost(reading: "はし", surface: "箸", cost: 0)
        XCTAssertEqual(best("はし"), "箸")
    }

    /// A word the shipped dictionary does not have has to reach the lattice
    /// through the overlay's own probe.
    func testUserAddedWordReachesRealConversions() throws {
        let reading = "びめう"
        let surface = "vimeu"
        XCTAssertTrue(system.tokens(reading: reading, surface: surface).isEmpty)

        editor.setWordCost(reading: reading, surface: surface, cost: 0)
        XCTAssertEqual(best(reading), surface)
    }
}
