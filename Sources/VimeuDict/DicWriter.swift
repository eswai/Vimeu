import Foundation

/// Builds a `vimeu.dic`. Build-time only — the IME never links this path in
/// anger, so it trades memory for simplicity: everything is accumulated in RAM
/// and laid out in one pass at `write(to:)`.
///
/// Output is deterministic: the same input always produces byte-identical
/// output, which makes dictionary changes reviewable as a hash diff.
public final class DicWriter {
    public struct Stats {
        public var readingCount = 0
        public var tokenCount = 0
        public var surfaceCount = 0
        public var posCount = 0
        public var droppedLongReadings = 0
        public var fileSize = 0
    }

    private struct Token {
        var surface: String
        var cost: Int32
        var lid: Int
        var rid: Int
    }

    private var tokensByReading: [String: [Token]] = [:]
    private var surfaceRefs: [String: UInt32] = [:]
    private var surfacePool: [UInt8] = []
    private var droppedLongReadings = 0

    /// Mozc's connection matrix, row-major `[rid * posCount + lid]`, and the POS
    /// table it is indexed by. Set once, by `setPOSTable`.
    private var connection: [Int16] = []
    private var posNames: [String] = []
    private var prefixPenalty: [UInt16] = []
    private var suffixPenalty: [UInt16] = []
    private var unknownPOSID: Int = 0

    public init() {}

    /// Install the POS table and everything indexed by it. Must be called before
    /// `write(to:)`; the three arrays are all `posCount` long and `connection`
    /// is `posCount²`.
    ///
    /// `unknownPOSID` is resolved from `id.def` rather than hard-coded, so it
    /// tracks the dictionary the file was actually built from.
    public func setPOSTable(
        names: [String],
        connection: [Int16],
        prefixPenalty: [UInt16],
        suffixPenalty: [UInt16],
        unknownPOSID: Int = 0
    ) throws {
        let n = names.count
        guard n <= Int(UInt16.max) else { throw DicError.posOverflow(n) }
        guard connection.count == n * n else {
            throw DicError.connectionSizeMismatch(expected: n * n, got: connection.count)
        }
        precondition(prefixPenalty.count == n && suffixPenalty.count == n)
        self.posNames = names
        self.connection = connection
        self.prefixPenalty = prefixPenalty
        self.suffixPenalty = suffixPenalty
        self.unknownPOSID = unknownPOSID
    }

    /// Add one Mozc token. Readings longer than `DicFormat.maxReadingLength` are
    /// dropped: the lattice never asks for a substring that long, so they could
    /// never be reached.
    ///
    /// Duplicate `(reading, surface, lid, rid)` keys are **not** collapsed here —
    /// the caller decides, because "same surface, different POS" is a real
    /// distinction in Mozc and merging it would erase a connection cost.
    public func add(reading: String, surface: String, cost: Int32, lid: Int, rid: Int) throws {
        guard !reading.isEmpty, !surface.isEmpty else { return }
        guard reading.unicodeScalars.count <= DicFormat.maxReadingLength else {
            droppedLongReadings += 1
            return
        }
        guard surface.utf8.count <= Int(UInt16.max) else { throw DicError.surfaceTooLong(surface) }
        tokensByReading[reading, default: []].append(
            Token(surface: surface, cost: cost, lid: lid, rid: rid)
        )
    }

    private func intern(_ surface: String) -> UInt32 {
        if let ref = surfaceRefs[surface] { return ref }
        let utf8 = Array(surface.utf8)
        let ref = UInt32(surfacePool.count)
        surfacePool.appendLE(UInt16(utf8.count))
        surfacePool.append(contentsOf: utf8)
        surfaceRefs[surface] = ref
        return ref
    }

    // MARK: - Emit

    @discardableResult
    public func write(to path: String) throws -> Stats {
        // 1. The alphabet is whatever the readings actually use (~90 kana), in
        //    ascending scalar order. Assigning codes in that order keeps the
        //    code-sequence ordering identical to code-point ordering, so the
        //    sorted key table below matches Mozc's own sort order.
        var scalarSet = Set<UInt32>()
        for reading in tokensByReading.keys {
            for s in reading.unicodeScalars { scalarSet.insert(s.value) }
        }
        let alphabet = scalarSet.sorted()
        guard alphabet.count <= 255 else { throw DicError.alphabetOverflow(alphabet.count) }
        var code = [UInt32: UInt8](minimumCapacity: alphabet.count)
        for (i, scalar) in alphabet.enumerated() { code[scalar] = UInt8(i + 1) }

        // 2. Sort readings by their code sequence. Sorted keys are what lets the
        //    key table act as a trie (DESIGN.md §2.3).
        var keys: [(codes: [UInt8], reading: String)] = []
        keys.reserveCapacity(tokensByReading.count)
        for reading in tokensByReading.keys {
            keys.append((reading.unicodeScalars.map { code[$0.value]! }, reading))
        }
        keys.sort { lexLess($0.codes, $1.codes) }

        // 3. Flatten keys and tokens into the parallel offset/data arrays.
        var keyOffsets: [UInt8] = []
        var keyBytes: [UInt8] = []
        var tokenOffsets: [UInt8] = []
        var tokens: [UInt8] = []
        keyOffsets.reserveCapacity((keys.count + 1) * 4)
        tokenOffsets.reserveCapacity((keys.count + 1) * 4)

        var tokenCount = 0
        for (codes, reading) in keys {
            keyOffsets.appendLE(UInt32(keyBytes.count))
            keyBytes.append(contentsOf: codes)
            tokenOffsets.appendLE(UInt32(tokenCount))
            // Cheapest first, so the lattice's first candidate for a reading is
            // its most likely surface.
            //
            // The tie-break is load-bearing, not just a determinism nicety.
            // Mozc's costs are integers, so exact ties are common — and they are
            // common precisely among the highest-frequency words. Whichever of a
            // tied pair sorts first wins every hypothesis the costs alone cannot
            // decide. Breaking on the surface's UTF-8 order puts hiragana
            // (U+3040–309F) ahead of katakana (U+30A0–30FF), so を beats ヲ and
            // の beats ノ. `lid`/`rid` break the remaining ties so that two
            // POS-variants of one surface still have a defined order.
            let group = tokensByReading[reading]!.sorted {
                if $0.cost != $1.cost { return $0.cost < $1.cost }
                if $0.surface != $1.surface { return utf8Less($0.surface, $1.surface) }
                if $0.lid != $1.lid { return $0.lid < $1.lid }
                return $0.rid < $1.rid
            }
            for t in group {
                tokens.appendLE(intern(t.surface))
                tokens.appendLE(UInt16(bitPattern: Int16(clamping: t.cost)))
                tokens.appendLE(UInt16(t.lid))
                tokens.appendLE(UInt16(t.rid))
                tokens.appendLE(UInt16(0))  // reserved
            }
            tokenCount += group.count
        }
        keyOffsets.appendLE(UInt32(keyBytes.count))
        tokenOffsets.appendLE(UInt32(tokenCount))
        assert(tokens.count == tokenCount * DicFormat.tokenSize)

        // 4. The POS-indexed tables, verbatim from Mozc.
        var alphabetBytes: [UInt8] = []
        alphabetBytes.reserveCapacity(alphabet.count * 4)
        for scalar in alphabet { alphabetBytes.appendLE(scalar) }

        var connectionBytes: [UInt8] = []
        connectionBytes.reserveCapacity(connection.count * 2)
        for c in connection { connectionBytes.appendLE(UInt16(bitPattern: c)) }

        var boundaryBytes: [UInt8] = []
        boundaryBytes.reserveCapacity(posNames.count * 4)
        for i in 0..<posNames.count {
            boundaryBytes.appendLE(prefixPenalty[i])
            boundaryBytes.appendLE(suffixPenalty[i])
        }

        var posNameBytes: [UInt8] = []
        for name in posNames {
            let utf8 = Array(name.utf8)
            guard utf8.count <= Int(UInt16.max) else { throw DicError.surfaceTooLong(name) }
            posNameBytes.appendLE(UInt16(utf8.count))
            posNameBytes.append(contentsOf: utf8)
        }

        // 5. Lay the sections out back to back, 8-byte aligned.
        let sections: [(DicFormat.Section, [UInt8])] = [
            (.alphabet, alphabetBytes),
            (.keyOffsets, keyOffsets),
            (.keyBytes, keyBytes),
            (.tokenOffsets, tokenOffsets),
            (.tokens, tokens),
            (.surfacePool, surfacePool),
            (.connection, connectionBytes),
            (.boundary, boundaryBytes),
            (.posNames, posNameBytes),
        ]

        var body: [UInt8] = []
        var table = [(offset: UInt64, length: UInt64)](
            repeating: (0, 0), count: DicFormat.Section.allCases.count
        )
        for (section, data) in sections {
            body.align(to: 8)
            table[section.rawValue] = (UInt64(DicFormat.headerSize + body.count), UInt64(data.count))
            body.append(contentsOf: data)
        }

        let contentHash = body.withUnsafeBytes { ContentHash.hash($0) }

        var out: [UInt8] = []
        out.reserveCapacity(DicFormat.headerSize + body.count)
        out.append(contentsOf: DicFormat.magic)
        out.appendLE(DicFormat.formatVersion)
        out.appendLE(UInt32(0))  // flags
        out.appendLE(UInt32(keys.count))
        out.appendLE(UInt32(tokenCount))
        out.appendLE(UInt32(posNames.count))
        out.appendLE(UInt32(unknownPOSID))
        out.appendLE(UInt32(alphabet.count))
        out.appendLE(UInt32(0))  // reserved
        out.appendLE(contentHash)
        for entry in table {
            out.appendLE(entry.offset)
            out.appendLE(entry.length)
        }
        assert(out.count == DicFormat.sectionTableOffset + table.count * 16)
        out.append(contentsOf: repeatElement(0, count: DicFormat.headerSize - out.count))
        out.append(contentsOf: body)

        try Data(out).write(to: URL(fileURLWithPath: path), options: .atomic)

        return Stats(
            readingCount: keys.count,
            tokenCount: tokenCount,
            surfaceCount: surfaceRefs.count,
            posCount: posNames.count,
            droppedLongReadings: droppedLongReadings,
            fileSize: out.count
        )
    }
}

/// UTF-8 byte order, i.e. code-point order.
///
/// `String`'s own `<` uses Unicode canonical ordering, which is a different
/// relation. The dictionary's key table and its per-reading tie-break are both in
/// code-point order, so every comparison that has to agree with them goes here.
public func utf8Less(_ a: String, _ b: String) -> Bool {
    var ai = a.utf8.makeIterator()
    var bi = b.utf8.makeIterator()
    while true {
        switch (ai.next(), bi.next()) {
        case (nil, nil): return false
        case (nil, _): return true
        case (_, nil): return false
        case (let x?, let y?):
            if x != y { return x < y }
        }
    }
}

@inline(__always)
private func lexLess(_ a: [UInt8], _ b: [UInt8]) -> Bool {
    let n = min(a.count, b.count)
    var i = 0
    while i < n {
        if a[i] != b[i] { return a[i] < b[i] }
        i += 1
    }
    return a.count < b.count
}
