import Foundation

/// Read-only view over a memory-mapped `vimeu.dic`.
///
/// Opening does no parsing beyond the ~90-entry kana alphabet and the POS-name
/// index: everything else is indexed straight out of the mapping. Instances are
/// immutable after `init` and safe to share across threads.
public final class DicReader: @unchecked Sendable {
    private let file: MappedFile
    private let bytes: UnsafeRawBufferPointer

    public let readingCount: Int
    public let tokenCount: Int
    /// Number of Mozc POS ids. The connection matrix is `posCount²`.
    public let posCount: Int
    /// Mozc's `unknown_id` — the POS of 名詞,サ変接続, which its own decoder gives
    /// to character-type fallback nodes. Read from the file rather than hard-coded
    /// so it follows the `id.def` the dictionary was built from.
    public let unknownPOSID: Int
    public let fileSize: Int

    private let alphabetOff: Int
    private let alphabetCount: Int
    private let keyOffsetsOff: Int
    private let keyBytesOff: Int
    private let tokenOffsetsOff: Int
    private let tokensOff: Int
    private let surfacePoolOff: Int
    private let connectionOff: Int
    private let boundaryOff: Int
    private let posNamesOff: Int

    /// Unicode scalar → alphabet code (1-based; 0 means "not in the dictionary").
    private let codeOfScalar: [UInt32: UInt8]

    /// Byte offset of each POS name inside the `posNames` section. Resolved at
    /// open time because it is ~2,700 entries the tuning UI walks, unlike the
    /// million-entry tables that stay untouched until a lookup needs them.
    private let posNameOffsets: [Int]

    /// - Parameter verifyContentHash: recomputes the FNV hash over the whole
    ///   body. That touches every page, which defeats the point of `mmap` at
    ///   runtime — it is for `dictbuild inspect` and tests, not the IME.
    public init(path: String, verifyContentHash: Bool = false) throws {
        file = try MappedFile(path: path)
        bytes = file.bytes
        fileSize = bytes.count

        guard bytes.count >= DicFormat.headerSize else { throw DicError.badMagic }
        for (i, b) in DicFormat.magic.enumerated() where bytes[i] != b {
            throw DicError.badMagic
        }
        let version = bytes.u32(8)
        guard version == DicFormat.formatVersion else {
            throw DicError.unsupportedVersion(version)
        }

        readingCount = Int(bytes.u32(16))
        tokenCount = Int(bytes.u32(20))
        posCount = Int(bytes.u32(24))
        unknownPOSID = Int(bytes.u32(28))
        alphabetCount = Int(bytes.u32(32))
        let storedHash = bytes.u64(40)

        let map = bytes
        func section(_ s: DicFormat.Section) throws -> Int {
            let base = DicFormat.sectionTableOffset + s.rawValue * 16
            let offset = Int(map.u64(base))
            let length = Int(map.u64(base + 8))
            guard offset >= 0, length >= 0, offset + length <= map.count else {
                throw DicError.truncated(s)
            }
            return offset
        }

        alphabetOff = try section(.alphabet)
        keyOffsetsOff = try section(.keyOffsets)
        keyBytesOff = try section(.keyBytes)
        tokenOffsetsOff = try section(.tokenOffsets)
        tokensOff = try section(.tokens)
        surfacePoolOff = try section(.surfacePool)
        connectionOff = try section(.connection)
        boundaryOff = try section(.boundary)
        posNamesOff = try section(.posNames)

        var codes = [UInt32: UInt8](minimumCapacity: alphabetCount)
        for i in 0..<alphabetCount {
            codes[map.u32(alphabetOff + i * 4)] = UInt8(i + 1)
        }
        codeOfScalar = codes

        var offsets = [Int](repeating: 0, count: posCount)
        var at = 0
        for i in 0..<posCount {
            offsets[i] = at
            at += 2 + Int(map.u16(posNamesOff + at))
        }
        posNameOffsets = offsets

        if verifyContentHash {
            let body = UnsafeRawBufferPointer(
                rebasing: bytes[DicFormat.headerSize..<bytes.count]
            )
            guard ContentHash.hash(body) == storedHash else { throw DicError.corruptContent }
        }
    }

    // MARK: - Readings

    /// Map a hiragana reading onto alphabet codes. Characters the dictionary
    /// never uses become 0, which no key can contain, so lookups through them
    /// simply find nothing and the lattice falls back to the unknown-word node.
    public func encode(_ reading: String) -> [UInt8] {
        reading.unicodeScalars.map { codeOfScalar[$0.value] ?? 0 }
    }

    @inline(__always)
    private func keyStart(_ id: Int) -> Int { Int(bytes.u32(keyOffsetsOff + id * 4)) }

    @inline(__always)
    private func keyLength(_ id: Int) -> Int { keyStart(id + 1) - keyStart(id) }

    @inline(__always)
    private func keyByte(_ id: Int, _ index: Int) -> UInt8 {
        bytes[keyBytesOff + keyStart(id) + index]
    }

    /// Every dictionary reading that is a prefix of `codes[from...]`, shortest
    /// first. `body` receives the length in kana and the reading id.
    ///
    /// The key table is sorted, so the keys sharing a prefix occupy one
    /// contiguous range and each extra kana narrows it with two binary searches.
    /// Among the keys sharing a prefix, the key *equal* to that prefix sorts
    /// first — which is how a hit is recognised.
    public func commonPrefixSearch(
        codes: [UInt8],
        from: Int,
        maxLength: Int = DicFormat.maxReadingLength,
        _ body: (_ length: Int, _ readingID: Int) -> Void
    ) {
        var lo = 0
        var hi = readingCount
        let limit = min(maxLength, codes.count - from)
        guard limit > 0 else { return }

        for step in 0..<limit {
            let c = codes[from + step]
            if c == 0 { return }  // character absent from the dictionary alphabet
            let depth = step + 1

            // First key with (length >= depth && byte[step] >= c); everything
            // before it is either the exact prefix or sorts lower.
            let newLo = partitionPoint(lo, hi) { id in
                keyLength(id) < depth || keyByte(id, step) < c
            }
            let newHi: Int
            if c == UInt8.max {
                newHi = hi
            } else {
                newHi = partitionPoint(newLo, hi) { id in
                    keyLength(id) < depth || keyByte(id, step) <= c
                }
            }
            if newLo >= newHi { return }

            if keyLength(newLo) == depth { body(depth, newLo) }
            lo = newLo
            hi = newHi
        }
    }

    /// Index of the first element in `[lo, hi)` for which `predicate` is false.
    /// `predicate` must be true for a (possibly empty) prefix of the range.
    @inline(__always)
    private func partitionPoint(_ lo: Int, _ hi: Int, _ predicate: (Int) -> Bool) -> Int {
        var low = lo
        var high = hi
        while low < high {
            let mid = low + (high - low) / 2
            if predicate(mid) { low = mid + 1 } else { high = mid }
        }
        return low
    }

    /// Decode alphabet codes back to kana. The inverse of `encode`; a code of 0
    /// (a character the dictionary has never seen) has no kana to map back to
    /// and is dropped.
    public func decode(_ codes: ArraySlice<UInt8>) -> String {
        var scalars = String.UnicodeScalarView()
        for code in codes where code != 0 {
            let value = bytes.u32(alphabetOff + (Int(code) - 1) * 4)
            if let scalar = Unicode.Scalar(value) { scalars.append(scalar) }
        }
        return String(scalars)
    }

    /// The id of an exact reading, or nil when the dictionary has no such key.
    public func readingID(of reading: String) -> Int? {
        let codes = encode(reading)
        guard !codes.isEmpty, codes.count <= DicFormat.maxReadingLength else { return nil }
        var found: Int?
        commonPrefixSearch(codes: codes, from: 0) { length, id in
            if length == codes.count { found = id }
        }
        return found
    }

    /// Every token of one exact `(reading, surface)` pair — empty when the
    /// dictionary does not have it.
    ///
    /// One pair can yield several tokens: Mozc registers the same spelling under
    /// different POS ids (`ああると` is both 名詞,一般 and 名詞,固有名詞) and those
    /// carry different costs and connect differently.
    ///
    /// This is also the provenance test the user dictionary is built on — "did
    /// this key come from the system dictionary?" is the only thing that decides
    /// whether an edit is an override or a user-added word, which is what lets
    /// `vimeu.dic` be rebuilt and swapped underneath the user's edits.
    public func tokens(reading: String, surface: String) -> [DicToken] {
        guard let readingID = readingID(of: reading) else { return [] }
        var found: [DicToken] = []
        forEachToken(readingID: readingID) { token in
            if token.surface == surface { found.append(token) }
        }
        return found
    }

    /// The reading of `readingID`, decoded back to kana. Only needed for
    /// inspection and tests; conversion never needs it.
    public func reading(_ readingID: Int) -> String {
        let start = keyStart(readingID)
        let length = keyLength(readingID)
        var scalars = String.UnicodeScalarView()
        for i in 0..<length {
            let code = Int(bytes[keyBytesOff + start + i])
            let value = bytes.u32(alphabetOff + (code - 1) * 4)
            scalars.append(Unicode.Scalar(value)!)
        }
        return String(scalars)
    }

    // MARK: - Tokens

    @inline(__always)
    private func tokenStart(_ readingID: Int) -> Int {
        Int(bytes.u32(tokenOffsetsOff + readingID * 4))
    }

    public func tokenCount(readingID: Int) -> Int {
        tokenStart(readingID + 1) - tokenStart(readingID)
    }

    /// Tokens for a reading, **cheapest first**.
    ///
    /// The callback takes the fields separately rather than a `DicToken` so the
    /// hot path — lattice construction — never has to build the struct. Use
    /// `forEachToken` when the value type is what you want.
    @inline(__always)
    public func forEachTokenField(
        readingID: Int,
        _ body: (_ surface: String, _ cost: Int32, _ lid: Int, _ rid: Int) -> Void
    ) {
        let start = tokenStart(readingID)
        let end = tokenStart(readingID + 1)
        for i in start..<end {
            let at = tokensOff + i * DicFormat.tokenSize
            body(
                surface(ref: Int(bytes.u32(at))),
                Int32(Int16(bitPattern: bytes.u16(at + 4))),
                Int(bytes.u16(at + 6)),
                Int(bytes.u16(at + 8))
            )
        }
    }

    public func forEachToken(readingID: Int, _ body: (DicToken) -> Void) {
        forEachTokenField(readingID: readingID) { surface, cost, lid, rid in
            body(DicToken(surface: surface, cost: cost, lid: lid, rid: rid))
        }
    }

    public func tokens(readingID: Int) -> [DicToken] {
        var out: [DicToken] = []
        out.reserveCapacity(tokenCount(readingID: readingID))
        forEachToken(readingID: readingID) { out.append($0) }
        return out
    }

    private func surface(ref: Int) -> String {
        let at = surfacePoolOff + ref
        let length = Int(bytes.u16(at))
        let start = at + 2
        return String(
            decoding: UnsafeRawBufferPointer(rebasing: bytes[start..<(start + length)]),
            as: UTF8.self
        )
    }

    // MARK: - The POS-indexed tables

    /// Mozc's connection cost for `left.rid` followed by `right.lid`.
    ///
    /// This is the innermost operation of the Viterbi loop — one multiply-add
    /// into the mapping, no decompression. Mozc's own runtime pays a
    /// succinct-bit-vector lookup here and caches around it; we ship the matrix
    /// uncompressed (14 MB, mapped) and do not have to.
    ///
    /// Out-of-range ids give 0 rather than trapping: user-added words can carry
    /// a POS id from a dictionary that has since been rebuilt, and a wrong-but-
    /// neutral cost is a better failure than a crash inside the input method.
    @inline(__always)
    public func transitionCost(_ rid: Int, _ lid: Int) -> Int32 {
        guard rid >= 0, rid < posCount, lid >= 0, lid < posCount else { return 0 }
        return Int32(Int16(bitPattern: bytes.u16(connectionOff + (rid * posCount + lid) * 2)))
    }

    /// Extra cost for starting the conversion with this POS (`boundary.def`).
    @inline(__always)
    public func prefixPenalty(_ lid: Int) -> Int32 {
        guard lid >= 0, lid < posCount else { return 0 }
        return Int32(bytes.u16(boundaryOff + lid * 4))
    }

    /// Extra cost for ending the conversion with this POS (`boundary.def`).
    @inline(__always)
    public func suffixPenalty(_ rid: Int) -> Int32 {
        guard rid >= 0, rid < posCount else { return 0 }
        return Int32(bytes.u16(boundaryOff + rid * 4 + 2))
    }

    /// The `id.def` feature string of a POS id, e.g. `助詞,格助詞,一般,*,*,*,*`.
    public func posName(_ id: Int) -> String {
        guard id >= 0, id < posCount else { return "?" }
        let at = posNamesOff + posNameOffsets[id]
        let length = Int(bytes.u16(at))
        let start = at + 2
        return String(
            decoding: UnsafeRawBufferPointer(rebasing: bytes[start..<(start + length)]),
            as: UTF8.self
        )
    }
}
