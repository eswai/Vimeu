import Foundation
import Testing
import VimeuDict
import VimeuEngine
import VimeuInput
@testable import VimeuIME

struct PartialCommitIntegrationTests {
    private static var dictionaryPath: String {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("dict/vimeu.dic").path
    }

    @Test(.enabled(if: FileManager.default.fileExists(atPath: Self.dictionaryPath)),
          arguments: [true, false], [PartialCommitSettings.Mode.converted, .reading])
    func continuousCommitsPreserveReadingAndConvertedRemainder(live: Bool, mode: PartialCommitSettings.Mode) throws {
        let dictionary = try DicReader(path: Self.dictionaryPath)
        let converter = Converter(dictionary: dictionary)
        let rules = PartialCommitBoundaryRules(dictionary: dictionary)
        let settings = PartialCommitSettings(mode: mode)
        let reading = String(repeating: "きょうはいいてんきなのでさんぽにいきます", count: 5)
        var buffer = InputBuffer()
        var tracker = PartialCommitStability()
        var context: Int?
        var committedReading = ""
        var committedText = ""
        var commits = 0
        for ch in reading {
            buffer.acceptKana(String(ch))
            let best = try #require(converter.convert(reading: buffer.reading, limit: 1, previousRightID: context).first)
            #expect(best.cost == best.wordCost + best.connectionCost)
            #expect(best.boundaries.first?.rid == (context ?? 0))
            let stable = tracker.observe(reading: buffer.reading, candidate: best, settings: settings)
            guard let prefix = PartialCommit(boundaryRules: rules, reading: buffer.reading, candidate: best,
                                              settings: settings, liveConversion: live, stablePrefixScalarCount: stable) else { continue }
            #expect(prefix.remainingReading.count >= settings.retainedLength)
            committedReading += prefix.reading
            committedText += prefix.text
            buffer.reading = prefix.remainingReading
            context = prefix.previousRightID
            tracker.reset()
            commits += 1
            // The exact converted suffix stays on screen across the commit.
            #expect(converter.best(reading: buffer.reading, previousRightID: context) == prefix.remainingText)
        }
        #expect(commits > 1)
        #expect(committedReading + buffer.reading == reading)
        if live || mode == .converted {
            committedText += converter.best(reading: buffer.reading, previousRightID: context)
            #expect(committedText == converter.best(reading: reading))
        } else {
            #expect(committedText + buffer.reading == reading)
        }
    }
}
