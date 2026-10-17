import VimeuEngine
import VimeuInput

/// A prefix of the best path that can be committed while leaving the recent
/// input editable. Lengths are policy values in Characters, not timings.
struct PartialCommit {
    let reading: String
    let text: String
    let remainingReading: String
    let remainingText: String
    let previousRightID: Int

    init?(
        boundaryRules: PartialCommitBoundaryRules,
        reading: String,
        candidate: Candidate?,
        settings: PartialCommitSettings = PartialCommitSettings(),
        liveConversion: Bool = true,
        stablePrefixScalarCount: Int = 0
    ) {
        guard settings.isNeeded(reading: reading) else { return nil }
        var limit = reading.index(reading.endIndex, offsetBy: -settings.retainedLength)
        if settings.requiresStableCandidate {
            guard candidate != nil, stablePrefixScalarCount > 0 else { return nil }
            let stableEnd = reading.unicodeScalars.index(
                reading.startIndex, offsetBy: min(stablePrefixScalarCount, reading.unicodeScalars.count)
            )
            limit = min(limit, stableEnd)
        }

        // Without a path we cannot establish a grammatical boundary or carry
        // its POS context forward. Manual commit still works without a dictionary.
        guard let candidate else { return nil }

        // Segments use Unicode scalar positions. Validate their correspondence
        // before using them to remove anything from the user's input.
        guard candidate.segments.map(\.reading).joined().unicodeScalars
            .elementsEqual(reading.unicodeScalars),
              candidate.segments.map(\.surface).joined() == candidate.text else { return nil }

        var end = reading.startIndex
        var position = reading.startIndex
        var segmentCount = 0
        for (index, segment) in candidate.segments.enumerated() {
            let next = reading.unicodeScalars.index(position, offsetBy: segment.reading.unicodeScalars.count)
            guard next <= limit else { break }
            position = next
            // Never split a grapheme, even if the engine's passthrough nodes
            // split decomposed kana into separate scalars.
            if reading.indices.contains(next), index + 1 < candidate.segments.count,
               boundaryRules.allows(leftRightID: segment.rid,
                                    rightLeftID: candidate.segments[index + 1].lid) {
                end = next
                segmentCount = index + 1
            }
        }
        guard segmentCount > 0, end > reading.startIndex else { return nil }
        self.reading = String(reading[..<end])
        text = settings.converts(liveConversion: liveConversion)
            ? candidate.segments.prefix(segmentCount).map(\.surface).joined() : self.reading
        remainingReading = String(reading[end...])
        remainingText = candidate.segments.dropFirst(segmentCount).map(\.surface).joined()
        previousRightID = candidate.segments[segmentCount - 1].rid
    }
}
