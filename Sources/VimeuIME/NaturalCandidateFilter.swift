import Foundation
import VimeuEngine
import VimeuNatural

/// Coordinates engine conversion and asynchronous model filtering. The engine
/// result is published before the model starts so the caller can show Mozc's
/// first candidate immediately. All mutable state is main-thread state, like
/// `LiveConversionCoordinator`; generations prevent a late model response from
/// reviving an abandoned composition.
final class ExplicitConversionCoordinator: @unchecked Sendable {
    typealias Convert = (String, @escaping @MainActor ([Candidate], String) -> Void) -> Void
    typealias Filter = @Sendable ([String]) async -> [String]

    private let convert: Convert
    private let filter: Filter
    private var generation: UInt64 = 0
    private var task: Task<Void, Never>?

    /// The complete Mozc-ordered list, including the plain-kana fallbacks.
    var onInitialResult: (@MainActor ([String], String) -> Void)?
    /// The list after the presentation-only naturalness pass completes.
    var onResult: (@MainActor ([String], String) -> Void)?

    init(service: ConversionService = .shared) {
        convert = { reading, completion in
            service.convert(reading: reading, limit: NBest.maxExpansions, completion: completion)
        }
        filter = { candidates in
            await FoundationModelsCandidateFilter().filter(candidates)
        }
    }

    init(convert: @escaping Convert, filter: @escaping Filter) {
        self.convert = convert
        self.filter = filter
    }

    func submit(
        reading: String,
        fallbackCandidates: [String],
        filterOverride: Filter? = nil
    ) {
        reset()
        let submittedGeneration = generation

        convert(reading) { [weak self] candidates, convertedReading in
            guard let self, submittedGeneration == self.generation else { return }

            var texts = candidates.map(\.text)
            for fallback in fallbackCandidates where !texts.contains(fallback) {
                texts.append(fallback)
            }

            // This callback deliberately precedes task creation. The first
            // Space therefore never waits for the model before displaying the
            // Mozc winner.
            self.onInitialResult?(texts, convertedReading)

            let filter = filterOverride ?? self.filter
            self.task = Task.detached(priority: .userInitiated) { [weak self] in
                let filtered = await filter(texts)
                guard !Task.isCancelled else { return }
                await MainActor.run { [weak self] in
                    guard let self,
                          !Task.isCancelled,
                          submittedGeneration == self.generation else { return }
                    self.task = nil
                    self.onResult?(filtered, convertedReading)
                }
            }
        }
    }

    func reset() {
        generation &+= 1
        task?.cancel()
        task = nil
    }
}
