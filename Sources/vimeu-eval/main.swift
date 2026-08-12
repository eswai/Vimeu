import Foundation
import VimeuDict
import VimeuEngine
import VimeuUserDict

// Measures conversion accuracy against a frozen test set, so dictionary and
// scoring changes can be compared on identical data.
//
//   vimeu-eval --dic dict/vimeu.dic --testset corpus/testset.tsv
//               [--user <dir>] [--convert <reading>]
//               [--topn 5] [--limit N] [--every K] [--dump-errors errors.tsv]
//
// There are no scoring knobs: Mozc's cost model has no free parameters.
//
// The test sets in corpus/ are fixed inputs: each line pairs a hiragana input
// with the expected surface string. Sampling (--every / --limit) is
// deterministic, so any two runs are directly comparable.

let usage = """
usage: vimeu-eval --dic <path> --testset <path> [options]

  --user <dir>          layer a user dictionary on top (the directory holding
                        user_word.tsv)
  --convert <reading>   convert one reading, print the candidates with their
                        cost breakdown, and exit
  --topn <n>            N for top-N accuracy (default 5)
  --limit <n>           evaluate at most n sentences (0 = all)
  --every <k>           take one sentence in every k (default 1)
  --dump-errors <path>  write mismatched cases (input/gold/got) to a TSV
"""

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("vimeu-eval: \(message)\n".utf8))
    exit(1)
}

var flags: [String: String] = [:]
var argv = Array(CommandLine.arguments.dropFirst())
if argv.isEmpty || argv.contains("-h") || argv.contains("--help") {
    print(usage)
    exit(argv.isEmpty ? 2 : 0)
}
var i = 0
while i < argv.count {
    guard argv[i].hasPrefix("--"), i + 1 < argv.count else { fail("bad argument \(argv[i])") }
    flags[String(argv[i].dropFirst(2))] = argv[i + 1]
    i += 2
}

let dicPath = flags["dic"] ?? "dict/vimeu.dic"
let testsetPath = flags["testset"] ?? "corpus/testset.tsv"
let topN = Int(flags["topn"] ?? "5") ?? 5
let limit = Int(flags["limit"] ?? "0") ?? 0
let every = max(1, Int(flags["every"] ?? "1") ?? 1)

// MARK: - Metrics

/// Edit distance between two scalar arrays (two-row DP). Scalars, not
/// grapheme clusters, so the character-accuracy figure stays comparable with
/// the predecessor's (Go counted runes).
func levenshtein(_ lhs: [Unicode.Scalar], _ rhs: [Unicode.Scalar]) -> Int {
    var a = lhs
    var b = rhs
    if a.count < b.count { swap(&a, &b) }
    var previous = Array(0...b.count)
    var current = [Int](repeating: 0, count: b.count + 1)
    for i in 1...max(a.count, 1) where !a.isEmpty {
        current[0] = i
        for j in 1...max(b.count, 1) where !b.isEmpty {
            let cost = a[i - 1] == b[j - 1] ? 0 : 1
            current[j] = min(previous[j] + 1, current[j - 1] + 1, previous[j - 1] + cost)
        }
        swap(&previous, &current)
    }
    return previous[b.count]
}

struct Metrics {
    var sentences = 0
    var sentenceCorrect = 0
    var topNCorrect = 0
    var goldCharacters = 0
    var editDistance = 0

    mutating func add(gold: String, candidates: [String], topN: Int) {
        sentences += 1
        let goldChars = Array(gold.unicodeScalars)
        goldCharacters += goldChars.count
        let top1 = candidates.first ?? ""
        editDistance += levenshtein(Array(top1.unicodeScalars), goldChars)
        if top1 == gold { sentenceCorrect += 1 }
        if candidates.prefix(topN).contains(gold) { topNCorrect += 1 }
    }

    var sentenceAccuracy: Double { ratio(sentenceCorrect, sentences) }
    /// 1 − ΣeditDistance/ΣgoldCharacters: corpus-level character accuracy.
    /// Summing distances before dividing keeps short sentences from dominating
    /// and avoids per-sentence negative accuracies.
    var characterAccuracy: Double { 1 - ratio(editDistance, goldCharacters) }
    var topNAccuracy: Double { ratio(topNCorrect, sentences) }

    private func ratio(_ numerator: Int, _ denominator: Int) -> Double {
        denominator == 0 ? 0 : Double(numerator) / Double(denominator)
    }
}

// MARK: - Run

let system: DicReader
do {
    system = try DicReader(path: dicPath)
} catch {
    fail("\(error)")
}

// With --user the effective dictionary is the packed one plus the user's edits,
// exactly as the IME sees it — so the effect of an edit can be measured, not
// just eyeballed.
let source: DictionarySource
if let userDirectory = flags["user"] {
    let editor = DictionaryEditor(
        system: system,
        store: UserDictionaryStore(directory: URL(fileURLWithPath: userDirectory))
    )
    source = editor.dictionary
} else {
    source = system
}

let converter = Converter(dictionary: source)

// --convert is the "why did it choose that?" path: one reading, every candidate
// with its segmentation, its POS ids and the cost split that decided it.
if let reading = flags["convert"] {
    for (rank, candidate) in converter.convert(reading: reading, limit: topN).enumerated() {
        let split = candidate.segments
            .map { "\($0.surface)(\($0.reading))" }
            .joined(separator: " | ")
        // The collocation term is omitted while it is zero for every candidate,
        // which is every run without a user dictionary — printing "+ 0" on each
        // line would explain a term the reader has not turned on.
        let collocation = candidate.collocationCost != 0
            ? " + collocation \(candidate.collocationCost)"
                + " [" + candidate.collocations.map { "\($0.left)→\($0.right)" }.joined(separator: ", ") + "]"
            : ""
        print("""
        \(rank + 1). \(candidate.text)
           \(split)
           cost \(candidate.cost) = word \(candidate.wordCost) + connection \(candidate.connectionCost)\(collocation)
        """)
        for boundary in candidate.boundaries {
            let left = boundary.left.map { "\($0.surface) \(source.posName($0.rid))" } ?? "BOS"
            let right = boundary.right.map { "\($0.surface) \(source.posName($0.lid))" } ?? "EOS"
            print("     \(left)  →  \(right)   \(boundary.cost)")
        }
    }
    exit(0)
}

guard let testsetData = FileManager.default.contents(atPath: testsetPath) else {
    fail("cannot read \(testsetPath)")
}
let lines = String(decoding: testsetData, as: UTF8.self).split(separator: "\n", omittingEmptySubsequences: false)
guard lines.first == "input\tgold" else {
    fail("\(testsetPath): expected header 'input\\tgold'")
}

var errorLines: [String] = []
let dumpErrors = flags["dump-errors"]
if dumpErrors != nil { errorLines.append("input\tgold\tgot") }

var metrics = Metrics()
var index = 0
let start = Date()

for line in lines.dropFirst() where !line.isEmpty {
    index += 1
    guard index % every == 0 else { continue }
    if limit > 0, metrics.sentences >= limit { break }

    let parts = line.split(separator: "\t", omittingEmptySubsequences: false)
    guard parts.count == 2, !parts[0].isEmpty, !parts[1].isEmpty else {
        fail("\(testsetPath): bad line: \(line)")
    }
    let input = String(parts[0])
    let gold = String(parts[1])

    let candidates = converter.convert(reading: input, limit: max(topN, 1)).map(\.text)
    metrics.add(gold: gold, candidates: candidates, topN: topN)

    if dumpErrors != nil, candidates.first != gold {
        errorLines.append("\(input)\t\(gold)\t\(candidates.first ?? "")")
    }
}

let elapsed = Date().timeIntervalSince(start)

if let path = dumpErrors {
    try? errorLines.joined(separator: "\n").appending("\n")
        .write(toFile: path, atomically: true, encoding: .utf8)
    print("wrote \(errorLines.count - 1) mismatches → \(path)")
}

let info = converter.statistics
print("""
dictionary   \(dicPath) (\(info.readings) readings, \(info.tokens) tokens, \
\(info.posCount) POS ids)
user dict    \(flags["user"] ?? "(none)") (\(info.userWordEdits) word edits, \
\(info.userConnectionEdits) connection edits)
testset      \(testsetPath)

sentences    \(metrics.sentences)
char acc     \(String(format: "%.2f%%", metrics.characterAccuracy * 100))
sentence acc \(String(format: "%.2f%%", metrics.sentenceAccuracy * 100))
top-\(topN) acc    \(String(format: "%.2f%%", metrics.topNAccuracy * 100))
elapsed      \(String(format: "%.1fs", elapsed)) \
(\(String(format: "%.1f", Double(metrics.sentences) / max(elapsed, 1e-9))) sentences/s)
""")
