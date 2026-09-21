import Testing
@testable import VimeuIME

struct ComposingDisplayTests {
    @Test func keepsLiveTextWhileTheSameReadingIsWaitingForCandidates() {
        let text = ComposingDisplay.text(
            liveConversionEnabled: true,
            reading: "かな",
            pendingRomaji: "",
            liveReading: "かな",
            liveText: "漢字"
        )

        #expect(text == "漢字")
    }

    @Test func appendsNewKanaAndPendingRomajiToTheRetainedLiveText() {
        let text = ComposingDisplay.text(
            liveConversionEnabled: true,
            reading: "かな",
            pendingRomaji: "n",
            liveReading: "か",
            liveText: "蚊"
        )

        #expect(text == "蚊なn")
    }
}
