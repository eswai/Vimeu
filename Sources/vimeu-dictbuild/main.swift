import Foundation
import VimeuDict

// Build-time dictionary tool. Deliberately dependency-free (no ArgumentParser):
// the whole package links nothing outside the standard library.
//
//   vimeu-dictbuild pack    --mozc-data <dir> --out <dic>
//   vimeu-dictbuild inspect <dic> [--sample n]
//   vimeu-dictbuild verify  --dic <dic> --mozc-data <dir>

let usage = """
usage: vimeu-dictbuild <command> [options]

  pack     Mozc's src/data → vimeu.dic
             --mozc-data <dir>  a copy of mozc/src/data (default: dict/mozc)
             --out <path>       output .dic
             --extra <glob>     extra Mozc-format dictionary files (e.g. Mozc UT)
             --extra-pos <id>   POS id for extra entries whose lid/rid is 0000

  inspect  print the contents of a .dic
             <path>             the dictionary to inspect
             --sample <n>       also print n sample readings (default 0)

  verify   check a .dic against the Mozc data it was built from
             --dic <path>       the dictionary to check
             --mozc-data <dir>  the same src/data copy
             --sample <n>       connection-matrix cells to spot-check (default 100000)
"""

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("vimeu-dictbuild: \(message)\n".utf8))
    exit(1)
}

/// `--flag value` parsing; positional arguments are returned in order.
struct Args {
    private var flags: [String: String] = [:]
    private(set) var positional: [String] = []

    init(_ argv: [String]) {
        var i = 0
        while i < argv.count {
            let arg = argv[i]
            if arg.hasPrefix("--") {
                guard i + 1 < argv.count else { fail("missing value for \(arg)") }
                flags[String(arg.dropFirst(2))] = argv[i + 1]
                i += 2
            } else {
                positional.append(arg)
                i += 1
            }
        }
    }

    func optional(_ name: String) -> String? { flags[name] }

    func required(_ name: String) -> String {
        guard let v = flags[name] else { fail("missing required option --\(name)") }
        return v
    }
}

/// Expand a shell-style glob. The Makefile quotes globs so they reach us intact,
/// which keeps "which files went in" visible in the build log.
func expandGlob(_ pattern: String) -> [String] {
    var g = glob_t()
    defer { globfree(&g) }
    guard glob(pattern, 0, nil, &g) == 0 else { return [] }
    return (0..<Int(g.gl_matchc)).compactMap { i in
        g.gl_pathv[i].map { String(cString: $0) }
    }.sorted()
}

func humanBytes(_ n: Int) -> String {
    let units = ["B", "KB", "MB", "GB"]
    var value = Double(n)
    var unit = 0
    while value >= 1024, unit < units.count - 1 {
        value /= 1024
        unit += 1
    }
    return unit == 0 ? "\(n) B" : String(format: "%.1f %@", value, units[unit])
}

// MARK: - Commands

func commandPack(_ args: Args) throws {
    let root = args.optional("mozc-data") ?? "dict/mozc"
    let outPath = args.required("out")
    let paths = try MozcData.Paths(root: root)

    let posNames = try MozcData.loadPOSNames(path: paths.idDef)
    let unknownPOSID = try MozcData.unknownPOSID(in: posNames)
    print("id.def: \(posNames.count) POS ids, unknown_id = \(unknownPOSID) (\(posNames[unknownPOSID]))")

    let connection = try MozcData.loadConnection(
        path: paths.connection, expectedSize: posNames.count
    )
    print("connection: \(posNames.count)² = \(connection.count) costs")

    let (prefixPenalty, suffixPenalty) = try MozcData.loadBoundaryPenalties(
        path: paths.boundary, posNames: posNames
    )
    print("boundary.def: \(prefixPenalty.filter { $0 > 0 }.count) prefix, "
        + "\(suffixPenalty.filter { $0 > 0 }.count) suffix penalties")

    var files = paths.dictionaries
    for path in files { print("  read \(URL(fileURLWithPath: path).lastPathComponent)") }

    var (entries, stats) = try MozcData.loadEntries(paths: files)

    if let extra = args.optional("extra") {
        let extraFiles = expandGlob(extra)
        guard !extraFiles.isEmpty else { fail("--extra matched no files") }
        let extraPOS = Int(args.optional("extra-pos") ?? "") ?? unknownPOSID
        print("extra: \(extraFiles.count) files, POS \(extraPOS) for lid/rid 0000 "
            + "(accuracy will suffer — see DESIGN.md §2.1)")
        let (extraEntries, extraStats) = try MozcData.loadEntries(
            paths: extraFiles, defaultPOSID: extraPOS
        )
        // The OSS dictionary wins: its entries carry real POS ids.
        for (key, cost) in extraEntries where entries[key] == nil {
            entries[key] = cost
        }
        stats.lines += extraStats.lines
        stats.malformed += extraStats.malformed
        stats.nonKana += extraStats.nonKana
        files += extraFiles
    }

    let writer = DicWriter()
    try writer.setPOSTable(
        names: posNames,
        connection: connection,
        prefixPenalty: prefixPenalty,
        suffixPenalty: suffixPenalty,
        unknownPOSID: unknownPOSID
    )
    for (entry, cost) in entries {
        try writer.add(
            reading: entry.reading, surface: entry.surface,
            cost: cost, lid: entry.lid, rid: entry.rid
        )
    }

    let written = try writer.write(to: outPath)
    print("""
    read \(stats.lines) lines from \(files.count) files \
    (malformed \(stats.malformed), non-kana \(stats.nonKana))
    wrote \(outPath) (\(humanBytes(written.fileSize)))
      readings          \(written.readingCount)
      tokens            \(written.tokenCount)
      unique surfaces   \(written.surfaceCount)
      POS ids           \(written.posCount)
      dropped (reading > \(DicFormat.maxReadingLength) kana)  \(written.droppedLongReadings)
    """)
}

func commandInspect(_ args: Args) throws {
    guard let path = args.positional.first else { fail("inspect needs a .dic path") }
    let dic = try DicReader(path: path, verifyContentHash: true)

    print("""
    \(path)
      size              \(humanBytes(dic.fileSize))
      readings          \(dic.readingCount)
      tokens            \(dic.tokenCount)
      POS ids           \(dic.posCount)
      unknown_id        \(dic.unknownPOSID) (\(dic.posName(dic.unknownPOSID)))
      content hash      ok
    """)

    let sample = Int(args.optional("sample") ?? "0") ?? 0
    guard sample > 0, dic.readingCount > 0 else { return }
    print("  sample:")
    let stride = max(1, dic.readingCount / sample)
    for id in Swift.stride(from: 0, to: dic.readingCount, by: stride).prefix(sample) {
        let rendered = dic.tokens(readingID: id).prefix(3).map {
            "\($0.surface) \($0.cost) [\($0.lid)/\($0.rid)]"
        }
        print("    \(dic.reading(id))\t\(rendered.joined(separator: ", "))")
    }
}

/// Cross-check a packed dictionary against the Mozc data it came from.
///
/// This is the mechanical proof of "vimeu uses Mozc's dictionary unchanged":
/// every connection cost, every boundary penalty, every POS name and a sample of
/// word tokens have to come back identical.
func commandVerify(_ args: Args) throws {
    let dic = try DicReader(path: args.required("dic"))
    let root = args.optional("mozc-data") ?? "dict/mozc"
    let paths = try MozcData.Paths(root: root)
    var failures = 0

    func check(_ condition: Bool, _ message: @autoclosure () -> String) {
        guard !condition else { return }
        failures += 1
        if failures <= 10 { print("  \(message())") }
    }

    let posNames = try MozcData.loadPOSNames(path: paths.idDef)
    check(dic.posCount == posNames.count, "posCount \(dic.posCount) vs \(posNames.count)")
    for (id, name) in posNames.enumerated() {
        check(dic.posName(id) == name, "posName(\(id)) = \(dic.posName(id)), expected \(name)")
    }
    print("checked \(posNames.count) POS names")

    let connection = try MozcData.loadConnection(path: paths.connection, expectedSize: posNames.count)
    let sampleSize = Int(args.optional("sample") ?? "100000") ?? 100_000
    let n = posNames.count
    // Deterministic spread over the matrix rather than a random sample, so a
    // failure is reproducible and a rebuild is comparable to the last run.
    let step = max(1, (n * n) / max(sampleSize, 1))
    var checkedCells = 0
    for flat in Swift.stride(from: 0, to: n * n, by: step) {
        let rid = flat / n
        let lid = flat % n
        check(
            dic.transitionCost(rid, lid) == Int32(connection[flat]),
            "trans(\(rid), \(lid)) = \(dic.transitionCost(rid, lid)), expected \(connection[flat])"
        )
        checkedCells += 1
    }
    print("checked \(checkedCells) connection cells")

    let (prefixPenalty, suffixPenalty) = try MozcData.loadBoundaryPenalties(
        path: paths.boundary, posNames: posNames
    )
    for id in 0..<min(dic.posCount, posNames.count) {
        check(dic.prefixPenalty(id) == Int32(prefixPenalty[id]), "prefixPenalty(\(id))")
        check(dic.suffixPenalty(id) == Int32(suffixPenalty[id]), "suffixPenalty(\(id))")
    }
    print("checked \(posNames.count) boundary penalties")

    let (entries, _) = try MozcData.loadEntries(paths: paths.dictionaries)
    var checkedTokens = 0
    let tokenStep = max(1, entries.count / max(sampleSize, 1))
    for (index, (entry, cost)) in entries.enumerated() where index % tokenStep == 0 {
        guard entry.reading.unicodeScalars.count <= DicFormat.maxReadingLength else { continue }
        let tokens = dic.tokens(reading: entry.reading, surface: entry.surface)
        check(
            tokens.contains { $0.cost == cost && $0.lid == entry.lid && $0.rid == entry.rid },
            "missing \(entry.reading) → \(entry.surface) \(cost) [\(entry.lid)/\(entry.rid)]"
        )
        checkedTokens += 1
    }
    print("checked \(checkedTokens) word tokens")

    if failures > 0 { fail("\(failures) mismatches") }
    print("all checks passed")
}

// MARK: - Entry point

let argv = Array(CommandLine.arguments.dropFirst())
guard let command = argv.first else {
    print(usage)
    exit(2)
}
let args = Args(Array(argv.dropFirst()))

do {
    switch command {
    case "pack": try commandPack(args)
    case "inspect": try commandInspect(args)
    case "verify": try commandVerify(args)
    case "-h", "--help", "help": print(usage)
    default: fail("unknown command '\(command)'\n\n\(usage)")
    }
} catch {
    fail("\(error)")
}
