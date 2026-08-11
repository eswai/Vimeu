import XCTest
import VimeuDict
import VimeuUserDict
@testable import VimeuEngine

/// The user dictionary's contract: what an edit does to conversion, and what
/// survives a rebuild of the system dictionary.
final class OverlayTests: XCTestCase {
    private var directory = URL(fileURLWithPath: "/tmp")
    private var dicPath = ""
    private var system: DicReader!
    private var store: UserDictionaryStore!
    private var editor: DictionaryEditor!

    /// A small system dictionary standing in for `vimeu.dic`. Costs are Mozc's
    /// scale, so lower wins.
    private static let systemWords: [(reading: String, surface: String, cost: Int32, lid: Int, rid: Int)] = [
        ("はし", "橋", 3000, 1, 1),
        ("はし", "箸", 4500, 1, 1),
        ("わたる", "渡る", 3000, 3, 3),
        ("あおい", "青い", 5000, 1, 1),
        ("あおい", "葵", 4000, 1, 1),
        ("そら", "空", 3000, 1, 1),
    ]

    override func setUpWithError() throws {
        let unique = UUID().uuidString
        dicPath = FileManager.default.temporaryDirectory
            .appendingPathComponent("vimeu-overlay-\(unique).dic").path
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("vimeu-overlay-\(unique)", isDirectory: true)

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

    private func best(_ reading: String) -> String {
        convert(reading, limit: 1).first?.text ?? ""
    }

    // MARK: - Composition

    /// With no edits the effective dictionary is the system dictionary.
    func testNoEditsIsPassThrough() {
        XCTAssertEqual(best("はし"), "橋")
        XCTAssertEqual(editor.dictionary.statistics.userWordEdits, 0)
    }

    func testCostOverrideChangesTheWinner() {
        XCTAssertEqual(best("はし"), "橋")
        editor.setWordCost(reading: "はし", surface: "箸", cost: 1000)
        XCTAssertEqual(best("はし"), "箸")
    }

    /// 強める lowers the cost — the UI's direction is the opposite of the
    /// number's, which is exactly why `boostWord` exists.
    func testBoostLowersCostFromTheCurrentValue() {
        editor.boostWord(reading: "はし", surface: "箸", steps: 4)  // 4500 − 4×500
        let knob = editor.wordKnobs(for: convert("はし"), reading: "はし")
            .first { $0.surface == "箸" }
        XCTAssertEqual(knob?.cost, 2500)
        // Stored absolute, so it does not drift if the system value changes.
        XCTAssertEqual(knob?.baseCost, 4500)
        XCTAssertEqual(knob?.userOverride, true)
    }

    func testBoostIsClamped() {
        editor.boostWord(reading: "はし", surface: "橋", steps: 100)
        XCTAssertEqual(
            editor.dictionary.effectiveCost(reading: "はし", surface: "橋"),
            UserDict.costRange.lowerBound
        )
    }

    /// A hidden word must not reach the lattice at all. Costing it up is not
    /// enough — if it is the only entry for a reading it still wins.
    func testDeletedWordLeavesTheLattice() {
        editor.deleteWord(reading: "はし", surface: "橋")
        XCTAssertEqual(best("はし"), "箸")
        XCTAssertFalse(convert("はし").contains { $0.text == "橋" })
    }

    func testUserAddedWordEntersTheLattice() {
        // Not in the system dictionary at all: the mapped trie cannot find it,
        // so the overlay has to probe for it separately.
        editor.setWordCost(reading: "はし", surface: "端", cost: 500)
        XCTAssertEqual(best("はし"), "端")
    }

    func testUserAddedWordComposesWithSystemWords() {
        editor.setWordCost(reading: "はし", surface: "端", cost: 500)
        XCTAssertEqual(best("はしわたる"), "端渡る")
    }

    /// A user-added word has no POS of its own, so it gets Mozc's `unknown_id` —
    /// the same class Mozc gives words its dictionary cannot explain.
    func testUserAddedWordUsesTheUnknownPOS() {
        editor.setWordCost(reading: "はし", surface: "端", cost: 500)
        let segment = convert("はし").first { $0.text == "端" }?.segments.first
        XCTAssertEqual(segment?.lid, TestDictionary.unknownPOSID)
        XCTAssertEqual(segment?.rid, TestDictionary.unknownPOSID)
    }

    /// One `(reading, surface)` pair can be several Mozc tokens. The user edits
    /// the pair, so the override has to reach all of them — otherwise the
    /// untouched token quietly keeps winning.
    func testOverrideAppliesToEveryTokenOfThePair() throws {
        let path = dicPath + ".multipos"
        defer { try? FileManager.default.removeItem(atPath: path) }
        let multi = try TestDictionary.write(to: path, words: [
            ("ああ", "亜阿", 6000, 1, 1),
            ("ああ", "亜阿", 6500, 3, 3),
            ("ああ", "嗚呼", 5000, 1, 1),
        ])
        let localEditor = DictionaryEditor(
            system: multi,
            store: UserDictionaryStore(directory: directory.appendingPathComponent("multi"))
        )
        XCTAssertEqual(Converter(dictionary: localEditor.dictionary).best(reading: "ああ"), "嗚呼")

        localEditor.setWordCost(reading: "ああ", surface: "亜阿", cost: 100)
        let candidate = Converter(dictionary: localEditor.dictionary)
            .convert(reading: "ああ", limit: 9)
        XCTAssertEqual(candidate.first?.text, "亜阿")
        // Both POS variants moved, so the pair really is one knob.
        XCTAssertEqual(localEditor.dictionary.effectiveCost(reading: "ああ", surface: "亜阿"), 100)
    }

    // MARK: - Provenance

    /// The only provenance test is "is the key in the system dictionary" — no
    /// edit records the value it shadows, which is what lets `vimeu.dic` be
    /// rebuilt underneath.
    func testProvenanceComesFromTheSystemDictionary() {
        editor.setWordCost(reading: "はし", surface: "箸", cost: 2000)   // override
        editor.setWordCost(reading: "はし", surface: "端", cost: 2000)   // user-added

        let knobs = editor.wordKnobs(for: convert("はし"), reading: "はし")
        XCTAssertEqual(knobs.first { $0.surface == "箸" }?.baseCost, 4500)
        XCTAssertNil(knobs.first { $0.surface == "端" }?.baseCost ?? nil)
    }

    /// Deleting behaves differently by provenance: a system word is hidden and
    /// can come back; a user-added word has nothing to come back to.
    func testDeleteHidesSystemWordsButRemovesAddedOnes() {
        editor.deleteWord(reading: "はし", surface: "橋")
        XCTAssertEqual(editor.dictionary.wordEdit(reading: "はし", surface: "橋")?.disabled, true)

        editor.setWordCost(reading: "はし", surface: "端", cost: 2000)
        editor.deleteWord(reading: "はし", surface: "端")
        XCTAssertNil(editor.dictionary.wordEdit(reading: "はし", surface: "端"))
    }

    func testReviveKeepsAnEarlierCost() {
        editor.setWordCost(reading: "はし", surface: "箸", cost: 1000)
        editor.deleteWord(reading: "はし", surface: "箸")
        XCTAssertEqual(best("はし"), "橋")

        editor.reviveWord(reading: "はし", surface: "箸")
        XCTAssertEqual(best("はし"), "箸")  // the 1000 is back, not just visibility
    }

    func testResetRestoresSystemValueAndRemovesAddedWords() {
        editor.setWordCost(reading: "はし", surface: "箸", cost: 1000)
        editor.resetWord(reading: "はし", surface: "箸")
        XCTAssertEqual(editor.dictionary.effectiveCost(reading: "はし", surface: "箸"), 4500)

        editor.setWordCost(reading: "はし", surface: "端", cost: 2000)
        editor.resetWord(reading: "はし", surface: "端")
        XCTAssertNil(editor.dictionary.effectiveCost(reading: "はし", surface: "端"))
    }

    /// A hidden word produces no candidate, so the sentence that made the user
    /// want it back has to surface it anyway.
    func testDeletedWordStillAppearsAsAKnob() {
        editor.deleteWord(reading: "はし", surface: "橋")
        let knobs = editor.wordKnobs(for: convert("はし"), reading: "はし")
        XCTAssertEqual(knobs.first { $0.surface == "橋" }?.deleted, true)
    }

    /// Mozc keys entries by POS, so the list has to say which POS a row is —
    /// otherwise two rows for one spelling are indistinguishable.
    func testKnobsCarryPOSNames() {
        let knobs = editor.wordKnobs(for: convert("はし"), reading: "はし")
        XCTAssertEqual(knobs.first { $0.surface == "橋" }?.posNames, ["名詞,一般,*"])
    }

    // MARK: - Persistence

    func testEditsSurviveAReload() throws {
        editor.setWordCost(reading: "はし", surface: "箸", cost: 1000)
        editor.deleteWord(reading: "はし", surface: "橋")

        let reopened = DictionaryEditor(
            system: system, store: UserDictionaryStore(directory: directory)
        )
        XCTAssertEqual(reopened.dictionary.effectiveCost(reading: "はし", surface: "箸"), 1000)
        XCTAssertNil(reopened.dictionary.effectiveCost(reading: "はし", surface: "橋"))
    }

    /// Rebuilding and swapping `vimeu.dic` must not disturb the user's edits —
    /// that is the whole point of not storing the shadowed value.
    func testEditsSurviveASystemDictionaryRebuild() throws {
        editor.setWordCost(reading: "はし", surface: "箸", cost: 1000)
        editor.deleteWord(reading: "はし", surface: "橋")

        // Rebuild with different costs, as a dictionary regeneration would.
        let rebuiltPath = dicPath + ".rebuilt"
        defer { try? FileManager.default.removeItem(atPath: rebuiltPath) }
        let rebuilt = try TestDictionary.write(
            to: rebuiltPath,
            words: Self.systemWords.map { ($0.reading, $0.surface, 7777, $0.lid, $0.rid) }
        )
        let reopened = DictionaryEditor(
            system: rebuilt, store: UserDictionaryStore(directory: directory)
        )

        // The override still holds its own absolute value…
        XCTAssertEqual(reopened.dictionary.effectiveCost(reading: "はし", surface: "箸"), 1000)
        // …the hidden word is still hidden…
        XCTAssertNil(reopened.dictionary.effectiveCost(reading: "はし", surface: "橋"))
        // …and only the base value follows the new dictionary.
        let knobs = reopened.wordKnobs(
            for: Converter(dictionary: reopened.dictionary).convert(reading: "はし"),
            reading: "はし"
        )
        XCTAssertEqual(knobs.first { $0.surface == "箸" }?.baseCost, 7777)
    }
}
