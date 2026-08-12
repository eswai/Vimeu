import XCTest
import VimeuDict
import VimeuUserDict
@testable import VimeuEngine

/// The third kind of edit: a cell of Mozc's connection matrix.
///
/// What these fix in place is the part that makes it different from a word edit.
/// A word edit is keyed by `(reading, surface)`, which is stable across
/// dictionary rebuilds by construction. A connection edit names a pair of parts
/// of speech, and the matrix is indexed by `id.def` line numbers — so the file
/// stores names and resolves them at load, and `testEditIsKeyedByPOSNameNotID`
/// is the test that this is really what happens.
final class ConnectionTests: XCTestCase {
    private var directory = URL(fileURLWithPath: "/tmp")
    private var dicPath = ""
    private var system: DicReader!
    private var editor: DictionaryEditor!

    /// `したい` — the shape the shipped dictionary actually has for this reading:
    /// a noun and a verb in 連用形, indistinguishable in word cost, separated
    /// only by what it costs to *start a sentence* with each.
    ///
    ///     死体   BOS→名詞 100 + 3000 + 名詞→EOS 200 = 3300
    ///     したい BOS→動詞 500 + 3000 + 動詞→EOS   0 = 3500
    ///
    /// No word edit expresses "a verb may open a sentence"; this is the case the
    /// connection pane exists for.
    private static let words: [(reading: String, surface: String, cost: Int32, lid: Int, rid: Int)] = [
        ("したい", "死体", 3000, 1, 1),   // 名詞,一般
        ("したい", "したい", 3000, 3, 3),  // 動詞,自立
        ("そら", "空", 3000, 1, 1),
    ]

    private static let bos = "BOS/EOS,*,*"
    private static let noun = "名詞,一般,*"
    private static let verb = "動詞,自立,*"

    override func setUpWithError() throws {
        let unique = UUID().uuidString
        dicPath = FileManager.default.temporaryDirectory
            .appendingPathComponent("vimeu-connection-\(unique).dic").path
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("vimeu-connection-\(unique)", isDirectory: true)
        system = try TestDictionary.write(to: dicPath, words: Self.words)
        editor = DictionaryEditor(system: system, store: UserDictionaryStore(directory: directory))
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

    /// The BOS transition of the candidate that begins with a verb.
    private func bosToVerbKnob() throws -> ConnectionKnob {
        let candidate = try XCTUnwrap(convert("したい").first { $0.text == "したい" })
        return try XCTUnwrap(
            editor.connectionKnobs(for: candidate).first { $0.left == nil }
        )
    }

    // MARK: - Composition

    /// With no connection edits the effective matrix is Mozc's, cell for cell.
    func testNoEditsIsPassThrough() {
        XCTAssertEqual(best("したい"), "死体")
        XCTAssertEqual(editor.dictionary.statistics.userConnectionEdits, 0)
        for rid in 0..<TestDictionary.posCount {
            for lid in 0..<TestDictionary.posCount {
                XCTAssertEqual(
                    editor.dictionary.transitionCost(rid, lid),
                    system.transitionCost(rid, lid)
                )
            }
        }
    }

    func testOverrideChangesTheWinner() {
        XCTAssertEqual(best("したい"), "死体")
        // 500 → 100: opening with a verb now costs what opening with a noun does.
        editor.setConnectionCost(rid: 0, lid: 3, cost: 100)
        XCTAssertEqual(best("したい"), "したい")
        XCTAssertEqual(editor.dictionary.statistics.userConnectionEdits, 1)
    }

    /// 強める lowers the cost, as it does for a word, and one press of ∓500 is
    /// enough here — the two candidates were 200 apart.
    func testBoostLowersFromTheCurrentValue() throws {
        editor.boostConnection(rid: 0, lid: 3, steps: 1)  // 500 − 500
        XCTAssertEqual(best("したい"), "したい")

        let knob = try bosToVerbKnob()
        XCTAssertEqual(knob.cost, 0)
        // Stored absolute, so a rebuilt matrix cannot move it.
        XCTAssertEqual(knob.baseCost, 500)
        XCTAssertTrue(knob.userOverride)
    }

    func testBoostIsClamped() {
        editor.boostConnection(rid: 1, lid: 1, steps: -100)  // 弱める, far past the top
        XCTAssertEqual(
            editor.dictionary.transitionCost(1, 1),
            UserDict.costRange.upperBound
        )
    }

    /// The word list's "変換に出さない", on a transition. It must not remove the
    /// transition — the lattice still has to span the input — only make it lose.
    func testDisabledConnectionIsPinnedAndReversible() throws {
        editor.disableConnection(rid: 0, lid: 1)  // BOS → 名詞
        XCTAssertEqual(
            editor.dictionary.transitionCost(0, 1),
            UserDict.forbiddenConnectionCost
        )
        XCTAssertEqual(best("したい"), "したい")
        // 死体 is still reachable, just hopeless — the path exists.
        XCTAssertTrue(convert("したい").contains { $0.text == "死体" })

        let knob = try XCTUnwrap(
            editor.connectionKnobs(for: try XCTUnwrap(convert("したい").first { $0.text == "死体" }))
                .first { $0.left == nil }
        )
        XCTAssertTrue(knob.disabled)
        XCTAssertEqual(knob.baseCost, 100)

        editor.reviveConnection(rid: 0, lid: 1)
        XCTAssertEqual(editor.dictionary.transitionCost(0, 1), 100)
        XCTAssertEqual(best("したい"), "死体")
    }

    /// 復活 keeps a cost the user had set before hiding, exactly as it does for
    /// a word — making it identical to リセット would throw that work away.
    func testReviveKeepsAnEarlierCost() {
        editor.setConnectionCost(rid: 0, lid: 3, cost: 100)
        editor.disableConnection(rid: 0, lid: 3)
        XCTAssertEqual(best("したい"), "死体")

        editor.reviveConnection(rid: 0, lid: 3)
        XCTAssertEqual(editor.dictionary.transitionCost(0, 3), 100)
        XCTAssertEqual(best("したい"), "したい")
    }

    func testResetRestoresTheMozcValue() {
        editor.setConnectionCost(rid: 0, lid: 3, cost: 0)
        editor.resetConnection(rid: 0, lid: 3)
        XCTAssertEqual(editor.dictionary.transitionCost(0, 3), 500)
        XCTAssertEqual(editor.dictionary.statistics.userConnectionEdits, 0)
        XCTAssertEqual(best("したい"), "死体")
    }

    /// An edit is one cell. Nothing else in the matrix may move — this is the
    /// bound on the damage a bad connection edit can do.
    func testAnEditTouchesExactlyOneCell() {
        editor.setConnectionCost(rid: 0, lid: 3, cost: 0)
        for rid in 0..<TestDictionary.posCount {
            for lid in 0..<TestDictionary.posCount where !(rid == 0 && lid == 3) {
                XCTAssertEqual(
                    editor.dictionary.transitionCost(rid, lid),
                    system.transitionCost(rid, lid),
                    "cell (\(rid), \(lid)) moved"
                )
            }
        }
    }

    // MARK: - The cost identity

    /// `cost == wordCost + connectionCost`, and the connection term is the sum
    /// of the boundaries the pane lists — with the edited value in both places.
    /// The pane shows these numbers side by side, so they have to reconcile.
    func testCostIdentityHoldsWithEditedConnections() {
        editor.setConnectionCost(rid: 0, lid: 3, cost: 42)
        for candidate in convert("したいそら") {
            XCTAssertEqual(candidate.cost, candidate.wordCost + candidate.connectionCost)
            XCTAssertEqual(
                candidate.connectionCost,
                candidate.boundaries.reduce(0) { $0 + $1.cost }
            )
        }
        let verbFirst = convert("したいそら").first { $0.text.hasPrefix("したい") }
        XCTAssertEqual(verbFirst?.boundaries.first?.cost, 42)
    }

    // MARK: - Persistence and provenance

    func testEditsSurviveAReload() throws {
        editor.setConnectionCost(rid: 0, lid: 3, cost: 100)
        editor.disableConnection(rid: 0, lid: 1)

        let reopened = DictionaryEditor(
            system: system, store: UserDictionaryStore(directory: directory)
        )
        XCTAssertEqual(reopened.dictionary.transitionCost(0, 3), 100)
        XCTAssertEqual(
            reopened.dictionary.transitionCost(0, 1),
            UserDict.forbiddenConnectionCost
        )
        XCTAssertEqual(reopened.dictionary.statistics.userConnectionEdits, 2)
    }

    /// The file names parts of speech; it does not number them.
    ///
    /// A Mozc data drop that inserts one POS shifts every id after it. An edit
    /// stored as `0 → 3` would then land on whatever now occupies line 3, and
    /// nothing about the result would tell the user why. Stored as
    /// `BOS/EOS,*,* → 動詞,自立,*` it follows the grammar instead of the file
    /// offsets.
    func testEditIsKeyedByPOSNameNotID() throws {
        editor.setConnectionCost(rid: 0, lid: 3, cost: 42)  // BOS → 動詞
        XCTAssertEqual(best("したい"), "したい")

        // Rebuild with 名詞,一般 and 動詞,自立 swapped, matrix permuted to match,
        // so the *grammar* is untouched and only the numbering changed.
        let renumberedPath = dicPath + ".renumbered"
        defer { try? FileManager.default.removeItem(atPath: renumberedPath) }
        let table = TestDictionary.permutingPOS(1, 3)
        let renumbered = try TestDictionary.write(
            to: renumberedPath,
            words: Self.words.map { word in
                func swap(_ id: Int) -> Int { id == 1 ? 3 : (id == 3 ? 1 : id) }
                return (word.reading, word.surface, word.cost, swap(word.lid), swap(word.rid))
            },
            posNames: table.names,
            connection: table.connection
        )
        let reopened = DictionaryEditor(
            system: renumbered, store: UserDictionaryStore(directory: directory)
        )
        // 動詞,自立 is id 1 here. The edit found it by name, not by the 3 it was
        // made against.
        XCTAssertEqual(reopened.dictionary.transitionCost(0, 1), 42)
        // Id 3 is now 名詞,一般, and nothing was done to it — Mozc's own 100.
        XCTAssertEqual(reopened.dictionary.transitionCost(0, 3), 100)
        XCTAssertEqual(Converter(dictionary: reopened.dictionary).best(reading: "したい"), "したい")
    }

    /// A POS the current `id.def` does not have drops out of the effective
    /// matrix and stays in the file — the same treatment a word edit for a
    /// reading the dictionary no longer has gets.
    func testUnknownPOSNameIsIgnoredButKept() throws {
        let store = UserDictionaryStore(directory: directory)
        try store.saveConnections([
            ConnectionKey(left: Self.bos, right: "接続詞,*,*"):
                ConnectionEdit(left: Self.bos, right: "接続詞,*,*", cost: 0, disabled: false),
            ConnectionKey(left: Self.bos, right: Self.verb):
                ConnectionEdit(left: Self.bos, right: Self.verb, cost: 100, disabled: false),
        ])

        let reopened = DictionaryEditor(system: system, store: store)
        XCTAssertEqual(reopened.dictionary.transitionCost(0, 3), 100)
        // Only the resolvable one reaches the matrix…
        XCTAssertEqual(reopened.dictionary.statistics.userConnectionEdits, 1)
        // …and both are still on disk, so a dictionary that has 接続詞 again
        // brings the edit back.
        XCTAssertEqual(try store.load().connections.count, 2)
    }

    /// A row with neither a cost nor the hidden flag says nothing and is dropped
    /// on the way in, so it can never reach the matrix as a 0.
    func testEmptyRowIsDropped() throws {
        let path = directory.appendingPathComponent("user_connection.tsv")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try("left_pos\tright_pos\tcost\tdisabled\tupdated_at\n"
            + "\(Self.bos)\t\(Self.verb)\t\t0\t1\n")
            .write(to: path, atomically: true, encoding: .utf8)

        let store = UserDictionaryStore(directory: directory)
        XCTAssertTrue(try store.load().connections.isEmpty)
        XCTAssertEqual(DictionaryEditor(system: system, store: store).dictionary.transitionCost(0, 3), 500)
    }

    /// The pane lists one row per boundary, BOS first and EOS last, so the path
    /// reads in order — even when the same POS pair occurs twice.
    func testKnobsFollowThePathInOrder() throws {
        let candidate = try XCTUnwrap(convert("したいそら").first { $0.text == "死体空" })
        let knobs = editor.connectionKnobs(for: candidate)
        XCTAssertEqual(knobs.map(\.index), [0, 1, 2])
        XCTAssertNil(knobs.first?.left)          // BOS
        XCTAssertEqual(knobs.first?.leftPOS, Self.bos)
        XCTAssertEqual(knobs[1].left, "死体")
        XCTAssertEqual(knobs[1].right, "空")
        XCTAssertNil(knobs.last?.right)          // EOS
    }
}
