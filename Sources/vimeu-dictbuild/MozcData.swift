import Foundation
import VimeuDict

/// Reads Mozc's `src/data` directory as-is.
///
/// Everything vimeu needs is plain text in the Mozc source tree, in Mozc's own
/// layout, so "install the dictionary" is `cp -R mozc/src/data dict/mozc` and
/// nothing else. There is no intermediate TSV: costs and POS ids are used
/// unchanged, so a middle format would be a slower copy of these files.
///
///     <root>/dictionary_oss/dictionary00..09.txt   reading \t lid \t rid \t cost \t surface
///     <root>/dictionary_oss/id.def                 "<id> <feature>"
///     <root>/dictionary_oss/connection_single_column.txt
///                                                  first line N, then N² costs, row-major
///     <root>/rules/boundary.def                    PREFIX/SUFFIX <pattern> <cost>
///
/// The UT dictionaries (`mozcdic-ut-*`) are deliberately *not* part of this.
/// Every one of their lines carries `lid = rid = 0000`, which is the POS id of
/// BOS/EOS, so their words cannot be connected to anything — see DESIGN.md §2.1.
/// `--extra` exists for anyone who wants them anyway, at a known cost in
/// accuracy.
enum MozcData {
    struct Paths {
        var dictionaries: [String]
        var idDef: String
        var connection: String
        var boundary: String

        /// Resolve Mozc's own directory layout under `root`.
        init(root: String) throws {
            let oss = root + "/dictionary_oss"
            dictionaries = expandGlob(oss + "/dictionary*.txt")
            idDef = oss + "/id.def"
            connection = oss + "/connection_single_column.txt"
            boundary = root + "/rules/boundary.def"

            var missing: [String] = []
            if dictionaries.isEmpty { missing.append(oss + "/dictionary00..09.txt") }
            for path in [idDef, connection, boundary]
            where !FileManager.default.fileExists(atPath: path) {
                missing.append(path)
            }
            guard missing.isEmpty else {
                throw Failure("""
                \(root) does not look like Mozc's src/data. Missing:
                  \(missing.joined(separator: "\n  "))
                Copy it with: cp -R /path/to/mozc/src/data \(root)
                """)
            }
        }
    }

    struct Failure: Error, CustomStringConvertible {
        let description: String
        init(_ description: String) { self.description = description }
    }

    // MARK: - id.def

    /// POS features in id order. `id.def` lines are `<id> <feature>` and the ids
    /// are dense and ascending, but the file is read defensively anyway: the
    /// connection matrix is indexed by these, so a gap would silently shift every
    /// cost.
    static func loadPOSNames(path: String) throws -> [String] {
        let text = try String(contentsOfFile: path, encoding: .utf8)
        var byID: [Int: String] = [:]
        for line in text.split(separator: "\n") {
            let fields = line.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true)
            guard fields.count == 2, let id = Int(fields[0]) else { continue }
            byID[id] = String(fields[1])
        }
        guard let maxID = byID.keys.max() else {
            throw Failure("\(path): no POS ids found")
        }
        var names = [String](repeating: "", count: maxID + 1)
        for (id, feature) in byID { names[id] = feature }
        if let gap = names.firstIndex(of: "") {
            throw Failure("\(path): no entry for POS id \(gap); ids must be dense")
        }
        return names
    }

    /// Mozc's `unknown_id`: the POS its decoder gives to nodes the dictionary
    /// cannot explain. `data/rules/pos_matcher_rule.def` defines it as the first
    /// id matching `名詞,サ変接続`.
    static func unknownPOSID(in names: [String]) throws -> Int {
        guard let id = names.firstIndex(where: { $0.hasPrefix("名詞,サ変接続") }) else {
            throw Failure("id.def has no 名詞,サ変接続 — cannot resolve Mozc's unknown_id")
        }
        return id
    }

    // MARK: - connection_single_column.txt

    /// The connection matrix, row-major `[rid * n + lid]`.
    ///
    /// The file is 36 MB of decimal integers, one per line, so this parses bytes
    /// directly — going through `String.split` costs about twenty seconds here
    /// and a gigabyte of transient strings.
    static func loadConnection(path: String, expectedSize: Int) throws -> [Int16] {
        let data = try Data(contentsOf: URL(fileURLWithPath: path), options: .mappedIfSafe)

        var values: [Int16] = []
        var declaredSize: Int?
        var current = 0
        var negative = false
        var inNumber = false

        func flush() throws {
            guard inNumber else { return }
            inNumber = false
            let value = negative ? -current : current
            negative = false
            current = 0
            guard let size = declaredSize else {
                declaredSize = value
                values.reserveCapacity(value * value)
                return
            }
            _ = size
            guard let narrowed = Int16(exactly: value) else {
                throw Failure("\(path): connection cost \(value) does not fit in Int16")
            }
            values.append(narrowed)
        }

        try data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            for byte in raw {
                switch byte {
                case UInt8(ascii: "0")...UInt8(ascii: "9"):
                    current = current * 10 + Int(byte - UInt8(ascii: "0"))
                    inNumber = true
                case UInt8(ascii: "-"):
                    negative = true
                    inNumber = true
                default:
                    try flush()
                }
            }
            try flush()
        }

        guard let size = declaredSize else { throw Failure("\(path): empty") }
        guard size == expectedSize else {
            throw Failure("""
            \(path) declares \(size) POS ids but id.def has \(expectedSize). \
            The two files come from different Mozc versions — copy src/data again.
            """)
        }
        guard values.count == size * size else {
            throw DicError.connectionSizeMismatch(expected: size * size, got: values.count)
        }
        return values
    }

    // MARK: - boundary.def

    /// Prefix and suffix penalties per POS id.
    ///
    /// A transcription of `converter/gen_boundary_data.py`: each rule's pattern
    /// is anchored at the start of the `id.def` feature, `*` matches one
    /// comma-free component, and a pattern not ending in `,` must also end on a
    /// component boundary. First match wins; no match is 0.
    static func loadBoundaryPenalties(
        path: String, posNames: [String]
    ) throws -> (prefix: [UInt16], suffix: [UInt16]) {
        let text = try String(contentsOfFile: path, encoding: .utf8)
        var prefixRules: [(NSRegularExpression, UInt16)] = []
        var suffixRules: [(NSRegularExpression, UInt16)] = []

        for line in text.split(separator: "\n") {
            guard !line.isEmpty, line.first != "#" else { continue }
            let fields = line.split(separator: " ", omittingEmptySubsequences: true)
            guard fields.count == 3, let cost = UInt16(fields[2]) else { continue }
            let regex = try NSRegularExpression(pattern: patternToRegex(String(fields[1])))
            switch fields[0] {
            case "PREFIX": prefixRules.append((regex, cost))
            case "SUFFIX": suffixRules.append((regex, cost))
            default: throw Failure("\(path): unknown rule label '\(fields[0])'")
            }
        }

        func cost(_ rules: [(NSRegularExpression, UInt16)], _ feature: String) -> UInt16 {
            let range = NSRange(feature.startIndex..., in: feature)
            for (regex, value) in rules where regex.firstMatch(in: feature, range: range) != nil {
                return value
            }
            return 0
        }

        return (
            posNames.map { cost(prefixRules, $0) },
            posNames.map { cost(suffixRules, $0) }
        )
    }

    private static func patternToRegex(_ pattern: String) -> String {
        var regex = "^" + pattern.replacingOccurrences(of: "*", with: "[^,]+")
        if !regex.hasSuffix(",") { regex += "(?:,|$)" }
        return regex
    }

    // MARK: - dictionary*.txt

    struct Stats {
        var lines = 0
        var malformed = 0
        var nonKana = 0
        var duplicates = 0
    }

    /// One Mozc dictionary line, already filtered.
    struct Entry: Hashable {
        var reading: String
        var surface: String
        var lid: Int
        var rid: Int
    }

    /// Read the dictionary files, keeping the cheapest cost per
    /// `(reading, surface, lid, rid)`.
    ///
    /// The key keeps `lid`/`rid`: `ああると` is registered as both 名詞,一般 (cost
    /// 7129) and 名詞,固有名詞 (cost 6390), and those connect to their neighbours
    /// differently. Collapsing them — which is what a dictionary without
    /// connection costs would do — throws away the distinction this whole design
    /// exists to use.
    ///
    /// Non-kana readings are dropped: nothing typed as kana can ever match them.
    /// Over-long readings are left to `DicWriter`, which counts them.
    static func loadEntries(
        paths: [String], defaultPOSID: Int? = nil
    ) throws -> (entries: [Entry: Int32], stats: Stats) {
        var best: [Entry: Int32] = [:]
        var stats = Stats()

        for path in paths {
            try TSV.forEachLine(path: path, skipHeader: false) { fields, _ in
                guard fields.count == 5,
                      let lid = TSV.int(fields[1]),
                      let rid = TSV.int(fields[2]),
                      let cost = TSV.int(fields[3])
                else {
                    stats.malformed += 1
                    return
                }
                let reading = TSV.string(fields[0])
                let surface = TSV.string(fields[4])
                guard !reading.isEmpty, !surface.isEmpty else {
                    stats.malformed += 1
                    return
                }
                stats.lines += 1

                guard isKanaReading(reading) else {
                    stats.nonKana += 1
                    return
                }

                // UT dictionaries write 0000 for "no POS". Left alone that is
                // BOS/EOS, which connects to nothing; `--extra` substitutes a
                // real id instead.
                var left = lid
                var right = rid
                if let defaultPOSID, left == 0, right == 0 {
                    left = defaultPOSID
                    right = defaultPOSID
                }

                let key = Entry(reading: reading, surface: surface, lid: left, rid: right)
                if let existing = best[key] {
                    stats.duplicates += 1
                    if existing <= Int32(cost) { return }
                }
                best[key] = Int32(cost)
            }
        }
        return (best, stats)
    }
}

/// Whether every scalar can appear in a kana reading. Mozc also carries ASCII
/// and symbol readings, which no kana input could ever match.
private func isKanaReading(_ reading: String) -> Bool {
    guard !reading.isEmpty else { return false }
    for s in reading.unicodeScalars {
        switch s.value {
        case 0x3041...0x3096: continue                 // ぁ..ゖ
        case 0x30FC, 0x309D, 0x309E, 0x30FB: continue  // ー ゝ ゞ ・
        default: return false
        }
    }
    return true
}
