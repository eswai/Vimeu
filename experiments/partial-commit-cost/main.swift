// Offline investigation only. See README.md; no IME behavior is changed.
import Foundation
import VimeuDict
import VimeuEngine
import VimeuInput

struct Span: Hashable {
    let begin: Int
    let end: Int
    let surface: String
}

func startsWithHiragana(_ text: String) -> Bool {
    guard let scalar = text.unicodeScalars.first else { return false }
    return (0x3040...0x309F).contains(scalar.value)
}

enum POSBoundaryRule: String, CaseIterable {
    case particles, attachedWords, attachedWordsAndPrefixes

    func allows(leftPOS: String, rightPOS: String) -> Bool {
        let right = rightPOS.split(separator: ",", omittingEmptySubsequences: false)
        guard let major = right.first else { return false }
        if major == "助詞" { return false }
        if self == .particles { return true }
        if major == "助動詞" { return false }
        if right.count > 1, ["非自立", "接尾", "動詞非自立的"].contains(String(right[1])) { return false }
        // A prefix belongs to the word AFTER it: allow it at the start of the
        // suffix, but do not leave it behind at the end of the committed part.
        if self == .attachedWordsAndPrefixes, leftPOS.hasPrefix("接頭詞,") { return false }
        return true
    }
}

func verifyPOSRules() {
    for rule in POSBoundaryRule.allCases {
        precondition(!rule.allows(leftPOS: "名詞,一般", rightPOS: "助詞,格助詞"))
        precondition(rule.allows(leftPOS: "助詞,格助詞", rightPOS: "名詞,代名詞"))
        precondition(rule.allows(leftPOS: "助詞,格助詞", rightPOS: "感動詞,*,*"))
    }
    precondition(POSBoundaryRule.particles.allows(leftPOS: "動詞,自立", rightPOS: "助動詞,*"))
    for rule in [POSBoundaryRule.attachedWords, .attachedWordsAndPrefixes] {
        precondition(!rule.allows(leftPOS: "動詞,自立", rightPOS: "助動詞,*"))
        precondition(!rule.allows(leftPOS: "動詞,自立", rightPOS: "動詞,非自立"))
        precondition(!rule.allows(leftPOS: "名詞,一般", rightPOS: "名詞,接尾"))
    }
    precondition(!POSBoundaryRule.attachedWordsAndPrefixes.allows(leftPOS: "接頭詞,名詞接続", rightPOS: "名詞,一般"))
    precondition(POSBoundaryRule.attachedWordsAndPrefixes.allows(leftPOS: "名詞,一般", rightPOS: "接頭詞,名詞接続"))
}

func spans(_ candidate: Candidate) -> [Span] {
    var position = 0
    return candidate.segments.map { segment in
        let begin = position
        position += segment.reading.unicodeScalars.count
        return Span(begin: begin, end: position, surface: segment.surface)
    }
}

/// Exact minimum cost of a path that changes a target prefix's word spans or
/// surfaces. POS-only differences are allowed. No n-best truncation is used.
/// Applies to the dictionary-only model, without user collocation constraints.
func alternativeMargins(reading: String, best: Candidate, dictionary: DicReader) -> [Int: Int32] {
    let lattice = Lattice.build(reading: Array(reading.unicodeScalars),
                                codes: dictionary.encode(reading), dictionary: dictionary)
    let forward = Viterbi.run(lattice: lattice, dictionary: dictionary)
    precondition(forward.totalCost == best.cost)
    let nodes = lattice.nodes
    var backward = [Int32](repeating: Viterbi.unreachable, count: nodes.count)
    let target = Set(spans(best))
    var changedAt = [Int32](repeating: Viterbi.unreachable, count: lattice.length)
    for position in (0..<lattice.length).reversed() {
        for index in lattice.beginIndices[position] {
            let node = nodes[index]
            var suffix = Viterbi.unreachable
            if node.end == lattice.length {
                suffix = dictionary.transitionCost(node.rid, 0)
            } else {
                for next in lattice.beginIndices[node.end] where backward[next] < Viterbi.unreachable {
                    suffix = min(suffix, dictionary.transitionCost(node.rid, nodes[next].lid) + backward[next])
                }
            }
            guard suffix < Viterbi.unreachable else { continue }
            backward[index] = node.wcost + suffix
            if !target.contains(Span(begin: node.begin, end: node.end, surface: node.surface)),
               forward.cost[index] < Viterbi.unreachable {
                let wholeCost = forward.cost[index] + backward[index] - node.wcost
                changedAt[position] = min(changedAt[position], wholeCost)
            }
        }
    }
    var result: [Int: Int32] = [:]
    var cheapestAlternative = Viterbi.unreachable
    for position in 0..<lattice.length {
        cheapestAlternative = min(cheapestAlternative, changedAt[position])
        result[position + 1] = cheapestAlternative - best.cost
    }
    return result
}

/// Reconvert the suffix using the committed word's right POS as the initial
/// state. Remove only the artificial prefix penalty from the suffix's start.
func suffixWithContext(reading: String, rid: Int, dictionary: DicReader) -> (text: String, cost: Int32) {
    let lattice = Lattice.build(reading: Array(reading.unicodeScalars),
                                codes: dictionary.encode(reading), dictionary: dictionary)
    var costs = [Int32](repeating: Viterbi.unreachable, count: lattice.nodes.count)
    var previous = [Int](repeating: -1, count: lattice.nodes.count)
    for position in 0..<lattice.length {
        for index in lattice.beginIndices[position] {
            let node = lattice.nodes[index]
            if position == 0 {
                costs[index] = dictionary.transitionCost(rid, node.lid) + node.wcost - dictionary.prefixPenalty(node.lid)
            } else {
                for left in lattice.endIndices[position] {
                    let cost = costs[left] + dictionary.transitionCost(lattice.nodes[left].rid, node.lid) + node.wcost
                    if cost < costs[index] {
                        costs[index] = cost
                        previous[index] = left
                    }
                }
            }
        }
    }
    let last = lattice.endIndices[lattice.length].min {
        costs[$0] + dictionary.transitionCost(lattice.nodes[$0].rid, 0)
            < costs[$1] + dictionary.transitionCost(lattice.nodes[$1].rid, 0)
    }!
    var path: [String] = []
    var index = last
    while index >= 0 {
        path.append(lattice.nodes[index].surface)
        index = previous[index]
    }
    return (path.reversed().joined(), costs[last] + dictionary.transitionCost(lattice.nodes[last].rid, 0))
}

// Compare the forward/backward calculation with independent exhaustive path
// enumeration on a small dictionary, including POS variants and boundary costs.
func verifyMargins(root: String) throws -> Int {
    let path = NSTemporaryDirectory() + "vimeu-cost-probe-\(UUID().uuidString).dic"
    defer { try? FileManager.default.removeItem(atPath: path) }
    let dictionary = try TestDictionary.write(to: path, words: [
        ("あ", "亜", 100, 1, 1), ("あ", "阿", 130, 1, 1), ("あ", "亜", 120, 3, 3),
        ("い", "伊", 90, 1, 1), ("う", "宇", 110, 2, 2),
        ("あい", "愛", 150, 1, 1), ("いう", "言う", 80, 3, 3),
    ], prefixPenalty: [0, 12, 23, 34, 45], suffixPenalty: [0, 5, 6, 7, 8])
    var checked = 0
    for reading in ["あ", "あい", "あいう", "あいうあ"] {
        let best = Converter(dictionary: dictionary).convert(reading: reading, limit: 1)[0]
        let margins = alternativeMargins(reading: reading, best: best, dictionary: dictionary)
        let lattice = Lattice.build(reading: Array(reading.unicodeScalars),
                                    codes: dictionary.encode(reading), dictionary: dictionary)
        var paths: [([Int], Int32)] = []
        func enumerate(_ position: Int, _ rid: Int, _ cost: Int32, _ path: [Int]) {
            if position == lattice.length {
                paths.append((path, cost + dictionary.transitionCost(rid, 0)))
                return
            }
            for i in lattice.beginIndices[position] {
                let node = lattice.nodes[i]
                enumerate(node.end, node.rid, cost + dictionary.transitionCost(rid, node.lid) + node.wcost, path + [i])
            }
        }
        enumerate(0, 0, 0, [])
        let target = Set(spans(best))
        for cut in spans(best).map(\.end) {
            let alternative = paths.filter { path, _ in
                path.contains { i in
                    let node = lattice.nodes[i]
                    return node.begin < cut && !target.contains(Span(begin: node.begin, end: node.end, surface: node.surface))
                }
            }.map { $0.1 }.min()!
            precondition(margins[cut] == alternative - best.cost, "margin differs from exhaustive search")
            checked += 1
        }
    }
    return checked
}

let root = CommandLine.arguments[1]
let sampleCount = Int(CommandLine.arguments[2])!
let output = CommandLine.arguments[3]
let startLength = Int(CommandLine.arguments[4])!
let checks = try verifyMargins(root: root)
verifyPOSRules()
let dictionary = try DicReader(path: root + "/dict/vimeu.dic")
let converter = Converter(dictionary: dictionary)
let settings = PartialCommitSettings(length: startLength, requiresStableCandidate: false)
let stableSettings = PartialCommitSettings(length: startLength, requiresStableCandidate: true)
var observations: [[String: Any]] = []
var samples: [[String: Any]] = []
let started = Date()

for corpus in ["testset.tsv", "testset_messenger.tsv"] {
    let lines = try String(contentsOfFile: root + "/corpus/" + corpus, encoding: .utf8)
        .split(separator: "\n").dropFirst()
    let eligible = lines.enumerated().compactMap { index, line -> (Int, String)? in
        let reading = String(line.split(separator: "\t", omittingEmptySubsequences: false)[0])
        return (40...100).contains(reading.count) ? (index + 2, reading) : nil
    }
    let count = min(sampleCount, eligible.count)
    for sample in 0..<count {
        let (line, reading) = eligible[sample * (eligible.count - 1) / max(count - 1, 1)]
        samples.append(["corpus": corpus, "line": line, "reading": reading])
        let final = converter.convert(reading: reading, limit: 1)[0]
        var finalPrefixes: [Int: String] = [:]
        var finalPosition = 0
        var finalText = ""
        for word in final.segments {
            finalPosition += word.reading.unicodeScalars.count
            finalText += word.surface
            finalPrefixes[finalPosition] = finalText
        }
        var tracker = PartialCommitStability()
        let chars = Array(reading)
        for length in 1..<chars.count {
            let input = String(chars.prefix(length))
            let best = converter.convert(reading: input, limit: 1)[0]
            let stable = tracker.observe(reading: input, candidate: best, settings: stableSettings)
            guard let baseline = LegacyPartialCommit(reading: input, candidate: best, settings: settings) else { continue }
            let margins = alternativeMargins(reading: input, best: best, dictionary: dictionary)
            let maxCut = baseline.reading.unicodeScalars.count
            let stableCut = LegacyPartialCommit(reading: input, candidate: best, settings: stableSettings,
                                          stablePrefixScalarCount: stable)?.reading.unicodeScalars.count ?? 0
            var cut = 0
            var text = ""
            var wordCost: Int32 = 0
            var connectionCost: Int32 = 0
            var cuts: [[String: Any]] = []
            var lastRID = 0
            var nonHiraganaSuffix: (reading: String, text: String)?
            var posSuffixes: [String: (reading: String, text: String)] = [:]
            for (i, word) in best.segments.enumerated() {
                cut += word.reading.unicodeScalars.count
                guard cut <= maxCut else { break }
                text += word.surface
                lastRID = word.rid
                wordCost += word.wcost
                connectionCost += best.boundaries[i].cost
                let next = best.segments[i + 1]
                let remainingText = best.segments.dropFirst(i + 1).map(\.surface).joined()
                let remainingStartsWithHiragana = startsWithHiragana(remainingText)
                let readingIndex = input.unicodeScalars.index(input.startIndex, offsetBy: cut)
                // Preserve the production planner's grapheme-boundary rule.
                guard input.indices.contains(readingIndex) else { continue }
                if !remainingStartsWithHiragana {
                    nonHiraganaSuffix = (String(input[readingIndex...]), remainingText)
                }
                let leftPOS = dictionary.posName(word.rid)
                let rightPOS = dictionary.posName(next.lid)
                let allowedPOSRules = POSBoundaryRule.allCases.filter {
                    $0.allows(leftPOS: leftPOS, rightPOS: rightPOS)
                }.map(\.rawValue)
                for rule in allowedPOSRules {
                    posSuffixes[rule] = (String(input[readingIndex...]), remainingText)
                }
                let splitPenalty = dictionary.transitionCost(word.rid, 0) + dictionary.transitionCost(0, next.lid)
                    - dictionary.transitionCost(word.rid, next.lid)
                    + dictionary.suffixPenalty(word.rid) + dictionary.prefixPenalty(next.lid)
                let finalPrefix = finalPrefixes[cut]
                cuts.append([
                    "cut": cut, "text": text, "margin": Int(margins[cut]!),
                    "prefixCost": Int(wordCost + connectionCost), "wordCost": Int(wordCost),
                    "connectionCost": Int(connectionCost), "splitPenalty": Int(splitPenalty),
                    "revised": finalPrefix != text,
                    "boundaryChanged": finalPrefix == nil,
                    "remainingStartsWithHiragana": remainingStartsWithHiragana,
                    "leftPOS": leftPOS, "rightPOS": rightPOS,
                    "allowedPOSRules": allowedPOSRules,
                    "finalPrefix": finalPrefix as Any? ?? NSNull(),
                ])
            }
            let suffixAfterReset = converter.best(reading: baseline.remainingReading)
            let suffixAfterContext = suffixWithContext(reading: baseline.remainingReading, rid: lastRID, dictionary: dictionary)
            precondition(suffixAfterContext.cost == best.cost - wordCost - connectionCost,
                         "retaining left context must preserve the original suffix's optimal cost")
            let nonHiraganaSuffixAfterReset = nonHiraganaSuffix.map { converter.best(reading: $0.reading) }
            let nonHiraganaSuffixChanged = nonHiraganaSuffix.map { nonHiraganaSuffixAfterReset != $0.text }
            var posSuffixChanges: [String: Bool] = [:]
            for (rule, suffix) in posSuffixes {
                posSuffixChanges[rule] = converter.best(reading: suffix.reading) != suffix.text
            }
            // Also test moving the boundary forward, including intervening
            // hiragana in the commit even if this leaves less recent context.
            var forwardCut: [String: Any]?
            var forwardSuffixChanged: Bool?
            var forwardPosition = 0
            var forwardText = ""
            for (i, word) in best.segments.dropLast().enumerated() {
                forwardPosition += word.reading.unicodeScalars.count
                forwardText += word.surface
                guard forwardPosition >= maxCut else { continue }
                let remainingText = best.segments.dropFirst(i + 1).map(\.surface).joined()
                guard !startsWithHiragana(remainingText) else { continue }
                let index = input.unicodeScalars.index(input.startIndex, offsetBy: forwardPosition)
                guard input.indices.contains(index) else { continue }
                let remainingReading = String(input[index...])
                forwardCut = [
                    "cut": forwardPosition, "text": forwardText,
                    "margin": Int(margins[forwardPosition]!),
                    "revised": finalPrefixes[forwardPosition] != forwardText,
                    "boundaryChanged": finalPrefixes[forwardPosition] == nil,
                    "remainingStartsWithHiragana": false,
                ]
                forwardSuffixChanged = converter.best(reading: remainingReading) != remainingText
                break
            }
            observations.append([
                "corpus": corpus, "line": line, "inputLength": length, "input": input,
                "best": best.text, "fullReading": reading, "fullBest": final.text,
                "maxCut": maxCut, "stableCut": stableCut, "stablePrefixScalarCount": stable,
                "suffixChangedAfterBOSReset": suffixAfterReset != baseline.remainingText,
                "suffixChangedWithLeftContext": suffixAfterContext.text != baseline.remainingText,
                "suffixBeforeReset": baseline.remainingText, "suffixAfterReset": suffixAfterReset,
                "suffixWithLeftContext": suffixAfterContext.text,
                "nonHiraganaSuffixChangedAfterBOSReset": nonHiraganaSuffixChanged as Any? ?? NSNull(),
                "nonHiraganaSuffixBeforeReset": nonHiraganaSuffix?.text as Any? ?? NSNull(),
                "nonHiraganaSuffixAfterReset": nonHiraganaSuffixAfterReset as Any? ?? NSNull(),
                "posSuffixChanges": posSuffixChanges,
                "forwardNonHiraganaCut": forwardCut as Any? ?? NSNull(),
                "forwardNonHiraganaSuffixChangedAfterBOSReset": forwardSuffixChanged as Any? ?? NSNull(),
                "cuts": cuts,
            ])
        }
    }
}
let result: [String: Any] = [
    "sampleCountPerCorpus": sampleCount, "eligibleReadingLength": [40, 100],
    "startLength": settings.length, "retainedLength": settings.retainedLength,
    "stabilityLength": stableSettings.stableLength, "exhaustiveBoundaryChecks": checks,
    "elapsedSeconds": Date().timeIntervalSince(started), "samples": samples, "observations": observations,
    "posExamples": ["これをください", "ありがとうございます", "かいています", "きょうはいいてんきです"].map { input in
        let candidate = converter.convert(reading: input, limit: 1)[0]
        return ["reading": input, "text": candidate.text, "segments": candidate.segments.map {
            ["reading": $0.reading, "surface": $0.surface, "leftPOS": dictionary.posName($0.lid), "rightPOS": dictionary.posName($0.rid)]
        }] as [String: Any]
    },
]
try JSONSerialization.data(withJSONObject: result, options: [.sortedKeys])
    .write(to: URL(fileURLWithPath: output))
print("\(samples.count) sentences; \(observations.count) eligible snapshots; \(checks) exhaustive checks; wrote \(output)")
