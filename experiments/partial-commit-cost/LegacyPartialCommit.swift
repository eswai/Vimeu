// Frozen pre-POS planner for reproducing the historical comparison policies.
// The installed IME uses Sources/VimeuIME/PartialCommit.swift instead.
import VimeuEngine
import VimeuInput

struct LegacyPartialCommit {
    let reading: String
    let text: String
    let remainingReading: String
    let remainingText: String

    init?(reading: String, candidate: Candidate?, settings: PartialCommitSettings,
          liveConversion: Bool = true, stablePrefixScalarCount: Int = 0) {
        guard settings.isNeeded(reading: reading), let candidate else { return nil }
        var limit = reading.index(reading.endIndex, offsetBy: -settings.retainedLength)
        if settings.requiresStableCandidate {
            guard stablePrefixScalarCount > 0 else { return nil }
            limit = min(limit, reading.unicodeScalars.index(reading.startIndex,
                offsetBy: min(stablePrefixScalarCount, reading.unicodeScalars.count)))
        }
        guard candidate.segments.map(\.reading).joined().unicodeScalars.elementsEqual(reading.unicodeScalars),
              candidate.segments.map(\.surface).joined() == candidate.text else { return nil }
        var position = reading.startIndex
        var end = reading.startIndex
        var count = 0
        for (index, word) in candidate.segments.enumerated() {
            let next = reading.unicodeScalars.index(position, offsetBy: word.reading.unicodeScalars.count)
            guard next <= limit else { break }
            position = next
            if reading.indices.contains(next) { end = next; count = index + 1 }
        }
        guard count > 0, end > reading.startIndex else { return nil }
        self.reading = String(reading[..<end])
        text = settings.converts(liveConversion: liveConversion)
            ? candidate.segments.prefix(count).map(\.surface).joined() : self.reading
        remainingReading = String(reading[end...])
        remainingText = candidate.segments.dropFirst(count).map(\.surface).joined()
    }
}
