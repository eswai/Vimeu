import Testing
import Foundation
import VimeuEngine
@testable import VimeuIME

@MainActor
struct LiveConversionCoordinatorTests {
    @Test func idleDelayRestartsForUnchangedReading() async throws {
        var readings: [String] = []
        let coordinator = LiveConversionCoordinator { reading, _ in readings.append(reading) }
        coordinator.submit(reading: "か", delayMilliseconds: 150)
        try await Task.sleep(for: .milliseconds(80))
        // A pending consonant leaves the kana reading unchanged.
        coordinator.submit(reading: "か", delayMilliseconds: 150)
        try await Task.sleep(for: .milliseconds(100))
        #expect(readings.isEmpty)
        try await Task.sleep(for: .milliseconds(100))
        #expect(readings == ["か"])
    }

    @Test func resetCancelsTimer() async throws {
        var calls = 0
        let coordinator = LiveConversionCoordinator { _, _ in calls += 1 }
        coordinator.submit(reading: "あ", delayMilliseconds: 50)
        coordinator.reset()
        try await Task.sleep(for: .milliseconds(100))
        #expect(calls == 0)
    }

    @Test func runningCompletionCannotBypassNewDelay() async throws {
        var readings: [String] = []
        var finish: (@MainActor ([Candidate], String) -> Void)?
        let coordinator = LiveConversionCoordinator { reading, completion in
            readings.append(reading)
            finish = completion
        }
        coordinator.submit(reading: "あ")
        #expect(readings == ["あ"])
        coordinator.submit(reading: "あい", delayMilliseconds: 100)
        finish?([], "あ")
        #expect(readings == ["あ"])
        try await Task.sleep(for: .milliseconds(150))
        #expect(readings == ["あ", "あい"])
    }

    @Test func elapsedDelayWaitsForRunningConversion() async throws {
        var readings: [String] = []
        var finish: (@MainActor ([Candidate], String) -> Void)?
        let coordinator = LiveConversionCoordinator { reading, completion in
            readings.append(reading)
            finish = completion
        }
        coordinator.submit(reading: "あ")
        coordinator.submit(reading: "い", delayMilliseconds: 50)
        try await Task.sleep(for: .milliseconds(100))
        #expect(readings == ["あ"])
        finish?([], "あ")
        #expect(readings == ["あ", "い"])
    }
    @Test func resetRejectsOldResultEvenForSameReading() {
        var finish: (@MainActor ([Candidate], String) -> Void)?
        var results: [String] = []
        let coordinator = LiveConversionCoordinator { _, completion in finish = completion }
        coordinator.onResult = { _, reading in results.append(reading) }
        let candidate = Candidate(text: "亜", cost: 0, wordCost: 0,
                                  connectionCost: 0, segments: [], boundaries: [])
        coordinator.submit(reading: "あ")
        let oldFinish = finish
        coordinator.reset()
        coordinator.submit(reading: "あ")
        oldFinish?([candidate], "あ")
        #expect(results.isEmpty)
        finish?([candidate], "あ")
        #expect(results == ["あ"])
    }

}
