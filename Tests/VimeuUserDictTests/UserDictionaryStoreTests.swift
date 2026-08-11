import XCTest
@testable import VimeuUserDict

final class UserDictionaryStoreTests: XCTestCase {
    private var directory = URL(fileURLWithPath: "/tmp")
    private var store: UserDictionaryStore!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("vimeu-user-\(UUID().uuidString)", isDirectory: true)
        store = UserDictionaryStore(directory: directory)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    /// Every user starts with no files at all; that has to read as "no edits".
    func testMissingFilesLoadAsEmpty() throws {
        XCTAssertTrue(try store.load().isEmpty)
    }

    func testWordRoundTrip() throws {
        let words: [WordKey: WordEdit] = [
            WordKey(reading: "はし", surface: "橋"): WordEdit(
                reading: "はし", surface: "橋", cost: 1500, disabled: false, updatedAt: 111
            ),
            WordKey(reading: "はし", surface: "箸"): WordEdit(
                reading: "はし", surface: "箸", cost: nil, disabled: true, updatedAt: 222
            ),
        ]
        try store.saveWords(words)

        let loaded = try store.load().words
        XCTAssertEqual(loaded.count, 2)
        let bridge = loaded[WordKey(reading: "はし", surface: "橋")]
        XCTAssertEqual(bridge?.cost, 1500)
        XCTAssertEqual(bridge?.disabled, false)
        XCTAssertEqual(bridge?.updatedAt, 111)

        // A hide-only edit carries no cost of its own.
        let chopsticks = loaded[WordKey(reading: "はし", surface: "箸")]
        XCTAssertNil(chopsticks?.cost ?? nil)
        XCTAssertEqual(chopsticks?.disabled, true)
    }

    func testCollocationRoundTrip() throws {
        let pairs: [CollocationKey: CollocationEdit] = [
            CollocationKey(left: "皮", right: "剥く"): CollocationEdit(
                left: "皮", right: "剥く", updatedAt: 111
            ),
            CollocationKey(left: "風邪", right: "ひく"): CollocationEdit(
                left: "風邪", right: "ひく", updatedAt: 222
            ),
        ]
        try store.saveCollocations(pairs)

        let loaded = try store.load().collocations
        XCTAssertEqual(loaded.count, 2)
        XCTAssertEqual(loaded[CollocationKey(left: "皮", right: "剥く")]?.updatedAt, 111)
        // Ordered: the reverse pair is a different key and is not present.
        XCTAssertNil(loaded[CollocationKey(left: "剥く", right: "皮")])
    }

    /// Words and pairs live in separate files, and saving one must not disturb
    /// the other — they are written by different actions in the UI.
    func testWordsAndCollocationsAreIndependent() throws {
        try store.saveWords([
            WordKey(reading: "はし", surface: "橋"): WordEdit(
                reading: "はし", surface: "橋", cost: 1500, disabled: false, updatedAt: 1
            )
        ])
        try store.saveCollocations([
            CollocationKey(left: "皮", right: "剥く"): CollocationEdit(
                left: "皮", right: "剥く", updatedAt: 2
            )
        ])

        let loaded = try store.load()
        XCTAssertEqual(loaded.words.count, 1)
        XCTAssertEqual(loaded.collocations.count, 1)
    }

    /// The core is the authority on ranges; the UI may soft-limit but cannot
    /// push a value past them.
    func testValuesAreClamped() {
        XCTAssertEqual(WordEdit(reading: "あ", surface: "亜", cost: 99999, disabled: false).cost, 32767)
        XCTAssertEqual(WordEdit(reading: "あ", surface: "亜", cost: -5, disabled: false).cost, 0)
    }

    /// Same edits in, same bytes out — so a user's dictionary diffs cleanly and
    /// syncing it between machines does not churn.
    func testOutputIsDeterministic() throws {
        let words: [WordKey: WordEdit] = [
            WordKey(reading: "とうきょう", surface: "東京"): WordEdit(
                reading: "とうきょう", surface: "東京", cost: 3000, disabled: false, updatedAt: 5
            ),
            WordKey(reading: "あおい", surface: "青い"): WordEdit(
                reading: "あおい", surface: "青い", cost: 2000, disabled: false, updatedAt: 6
            ),
            WordKey(reading: "あおい", surface: "葵"): WordEdit(
                reading: "あおい", surface: "葵", cost: 1000, disabled: false, updatedAt: 7
            ),
        ]
        try store.saveWords(words)
        let first = try String(contentsOf: directory.appendingPathComponent("user_word.tsv"), encoding: .utf8)
        try store.saveWords(words)
        let second = try String(contentsOf: directory.appendingPathComponent("user_word.tsv"), encoding: .utf8)
        XCTAssertEqual(first, second)

        // Sorted by reading, then surface — both in code-point order.
        let readings = first.split(separator: "\n").dropFirst().map { $0.split(separator: "\t")[0] }
        XCTAssertEqual(readings, ["あおい", "あおい", "とうきょう"])
        let surfaces = first.split(separator: "\n").dropFirst().map { $0.split(separator: "\t")[1] }
        XCTAssertEqual(surfaces, ["葵", "青い", "東京"])
    }

    /// A hand-edited file with a stray blank line or a short row should not take
    /// the dictionary down — it is a text file the user is invited to open.
    func testMalformedRowsAreSkipped() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try """
        reading\tsurface\tcost\tdisabled\tupdated_at
        はし\t橋\t3000\t0\t1

        broken-row
        \t空\t1000\t0\t1
        とうきょう\t東京\t2000\t0\t2
        """.write(to: directory.appendingPathComponent("user_word.tsv"), atomically: true, encoding: .utf8)

        let words = try store.load().words
        XCTAssertEqual(words.count, 2)
        XCTAssertNotNil(words[WordKey(reading: "はし", surface: "橋")])
        XCTAssertNotNil(words[WordKey(reading: "とうきょう", surface: "東京")])
    }

    /// Code-point order, not `String`'s canonical ordering — the packed
    /// dictionary sorts this way and the two have to agree.
    func testUTF8LessIsCodePointOrder() {
        XCTAssertTrue(UserDict.utf8Less("を", "ヲ"))   // U+3092 before U+30F2
        XCTAssertTrue(UserDict.utf8Less("あ", "あい"))
        XCTAssertFalse(UserDict.utf8Less("あ", "あ"))
    }
}
