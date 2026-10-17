import VimeuEngine
import VimeuInput

/// Tracks how many additional reading Characters each leading word has
/// survived in the best conversion. Only the shared prefix keeps its age;
/// a changed word also restarts the observation of everything after it.
struct PartialCommitStability {
    private struct Word {
        let reading: String
        let surface: String
        let observedAt: Int
    }

    private var words: [Word] = []
    private var previousReading = ""
    private var previousSettings: PartialCommitSettings?

    mutating func reset() { self = Self() }

    /// Returns a scalar count so it lines up with the engine's word boundaries.
    /// Repeated results without additional input never advance the count.
    mutating func observe(reading: String, candidate: Candidate?, settings: PartialCommitSettings) -> Int {
        guard settings.observesStability,
              let candidate,
              candidate.segments.map(\.reading).joined().unicodeScalars.elementsEqual(reading.unicodeScalars),
              candidate.segments.map(\.surface).joined() == candidate.text else {
            reset()
            return 0
        }
        if previousSettings != settings || !reading.unicodeScalars.starts(with: previousReading.unicodeScalars) {
            reset()
        }
        previousSettings = settings
        previousReading = reading

        let inputLength = reading.count
        var matchingPrefix = true
        words = candidate.segments.enumerated().map { index, segment in
            if matchingPrefix, index < words.count,
               words[index].reading.unicodeScalars.elementsEqual(segment.reading.unicodeScalars),
               words[index].surface == segment.surface {
                return words[index]
            }
            matchingPrefix = false
            return Word(reading: segment.reading, surface: segment.surface, observedAt: inputLength)
        }

        var stableScalarCount = 0
        for word in words {
            guard inputLength - word.observedAt >= settings.stableLength else { break }
            stableScalarCount += word.reading.unicodeScalars.count
        }
        return stableScalarCount
    }
}
