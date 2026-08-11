import XCTest
@testable import VimeuInput

// Types the romaji string one character at a time and returns the accumulated
// reading plus whatever is still pending — i.e. what the user would see.
private func type(_ romaji: String) -> (reading: String, pending: String) {
    var buffer = InputBuffer()
    for ch in romaji { buffer.accept(ch) }
    return (buffer.reading, buffer.converter.pending)
}

// Same, but flushed as if the user pressed Space.
private func typeAndFlush(_ romaji: String) -> String {
    var buffer = InputBuffer()
    for ch in romaji { buffer.accept(ch) }
    return buffer.flushForConversion()
}

final class RomajiConverterTests: XCTestCase {
    func testBasicSyllables() {
        XCTAssertEqual(typeAndFlush("aiueo"), "あいうえお")
        XCTAssertEqual(typeAndFlush("konnnichiha"), "こんにちは")
        XCTAssertEqual(typeAndFlush("sakura"), "さくら")
    }

    func testAlternateRomanizations() {
        XCTAssertEqual(typeAndFlush("si"), typeAndFlush("shi"))
        XCTAssertEqual(typeAndFlush("ti"), typeAndFlush("chi"))
        XCTAssertEqual(typeAndFlush("tu"), typeAndFlush("tsu"))
        XCTAssertEqual(typeAndFlush("hu"), typeAndFlush("fu"))
        XCTAssertEqual(typeAndFlush("zya"), typeAndFlush("ja"))
    }

    func testYouon() {
        XCTAssertEqual(typeAndFlush("kyou"), "きょう")
        XCTAssertEqual(typeAndFlush("gyuunyuu"), "ぎゅうにゅう")
        XCTAssertEqual(typeAndFlush("sharin"), "しゃりん")
    }

    // Doubled consonant → っ, except "n" which is the ん rule instead.
    func testSokuon() {
        XCTAssertEqual(typeAndFlush("kitte"), "きって")
        XCTAssertEqual(typeAndFlush("gakkou"), "がっこう")
        XCTAssertEqual(typeAndFlush("massugu"), "まっすぐ")
        XCTAssertEqual(typeAndFlush("xtu"), "っ")
    }

    func testNHandling() {
        XCTAssertEqual(typeAndFlush("nn"), "ん")
        XCTAssertEqual(typeAndFlush("n"), "ん")           // lone n flushes to ん
        XCTAssertEqual(typeAndFlush("hon"), "ほん")
        XCTAssertEqual(typeAndFlush("shinbun"), "しんぶん")  // n before consonant
        XCTAssertEqual(typeAndFlush("kani"), "かに")        // n + vowel is NOT ん

        // "nn" is the explicit escape for ん and consumes both letters, so a
        // following vowel starts a fresh syllable rather than joining the n.
        // This matches MS-IME / Google IME: こんにちは is typed with three n's.
        XCTAssertEqual(typeAndFlush("konnichiha"), "こんいちは")
        XCTAssertEqual(typeAndFlush("hannou"), "はんおう")
        XCTAssertEqual(typeAndFlush("hannnou"), "はんのう")
    }

    // A partially typed syllable stays pending rather than emitting garbage.
    func testPendingIsHeldUntilResolvable() {
        XCTAssertEqual(type("k").pending, "k")
        XCTAssertEqual(type("k").reading, "")
        XCTAssertEqual(type("ky").pending, "ky")
        XCTAssertEqual(type("kya").reading, "きゃ")
        XCTAssertEqual(type("kya").pending, "")
    }

    func testSmallKana() {
        XCTAssertEqual(typeAndFlush("xa"), "ぁ")
        XCTAssertEqual(typeAndFlush("la"), "ぁ")
        XCTAssertEqual(typeAndFlush("ltsu"), "っ")
    }
}

final class InputBufferTests: XCTestCase {
    func testIsEmpty() {
        var buffer = InputBuffer()
        XCTAssertTrue(buffer.isEmpty)
        buffer.accept("k")
        XCTAssertFalse(buffer.isEmpty, "a pending romaji char counts as non-empty")
        buffer.accept("a")
        XCTAssertFalse(buffer.isEmpty)
    }

    // Backspace eats the pending romaji first, then completed kana.
    func testDeleteLast() {
        var buffer = InputBuffer()
        for ch in "kaky" { buffer.accept(ch) }
        XCTAssertEqual(buffer.displayString, "かky")

        buffer.deleteLast()
        XCTAssertEqual(buffer.displayString, "かk")
        buffer.deleteLast()
        XCTAssertEqual(buffer.displayString, "か")
        buffer.deleteLast()
        XCTAssertEqual(buffer.displayString, "")
        XCTAssertTrue(buffer.isEmpty)

        buffer.deleteLast()  // on empty: no crash, still empty
        XCTAssertTrue(buffer.isEmpty)
    }

    // Direct kana (ー, punctuation) flushes any pending romaji ahead of itself.
    func testAcceptKanaFlushesPending() {
        var buffer = InputBuffer()
        for ch in "ra" { buffer.accept(ch) }
        buffer.acceptKana("ー")
        XCTAssertEqual(buffer.displayString, "らー")

        var withPending = InputBuffer()
        withPending.accept("n")
        withPending.acceptKana("、")
        XCTAssertEqual(withPending.displayString, "ん、")
    }

    func testDisplayStringShowsPendingRomaji() {
        var buffer = InputBuffer()
        for ch in "nihonng" { buffer.accept(ch) }
        XCTAssertEqual(buffer.displayString, "にほんg")
    }

    func testFlushIsIdempotentlySafe() {
        var buffer = InputBuffer()
        for ch in "kyou" { buffer.accept(ch) }
        XCTAssertEqual(buffer.flushForConversion(), "きょう")
        XCTAssertEqual(buffer.flushForConversion(), "きょう", "flushing twice must not duplicate")
    }
}
