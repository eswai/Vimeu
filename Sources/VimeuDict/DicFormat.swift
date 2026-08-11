import Foundation

/// On-disk layout of `vimeu.dic`. See DESIGN.md §2.3.
///
/// One little-endian file, every section 8-byte aligned, read at runtime with
/// `mmap(2)`. Nothing is parsed at open time except the ~90-entry kana alphabet:
/// lookups index straight into the mapped bytes, so resident memory is only the
/// pages actually touched and the kernel can evict them under pressure.
///
/// The file carries **everything the Mozc cost model needs** — word costs with
/// their POS ids, the full connection matrix, the boundary penalties and the POS
/// names — so the installed app is one binary plus one data file, and conversion
/// never consults a second source.
///
/// ```
/// Header (192 B)
///   0   8   magic "VIMEUDIC"
///   8   4   formatVersion
///   12  4   flags (reserved, 0)
///   16  4   readingCount
///   20  4   tokenCount
///   24  4   posCount            (POS ids; the connection matrix is posCount²)
///   28  4   unknownPOSID        (id.def id of 名詞,サ変接続 — Mozc's unknown_id)
///   32  4   alphabetCount
///   36  4   reserved
///   40  8   contentHash         (FNV-1a over every byte after the header)
///   48  144 section table: 9 × (offset: UInt64, length: UInt64)
/// ```
///
/// Sections, in `Section` order:
///
/// - `alphabet`     `UInt32` × alphabetCount — Unicode scalars, code = index + 1
/// - `keyOffsets`   `UInt32` × (readingCount + 1) — into `keyBytes`
/// - `keyBytes`     alphabet codes of every reading, concatenated, **sorted**
/// - `tokenOffsets` `UInt32` × (readingCount + 1) — into `tokens`
/// - `tokens`       `tokenSize` B each × tokenCount, per reading **cost ascending**
/// - `surfacePool`  `[len: UInt16][UTF-8 bytes]` records, surfaces deduplicated
/// - `connection`   `Int16` × posCount² — `[rid * posCount + lid]`, Mozc's matrix verbatim
/// - `boundary`     (prefix: `UInt16`, suffix: `UInt16`) × posCount
/// - `posNames`     `[len: UInt16][UTF-8]` × posCount — id.def features, in id order
///
/// Readings are stored as **sorted** sequences of 1-byte alphabet codes. That
/// makes the key table double as a trie: the keys sharing a prefix form one
/// contiguous range, and among them the key equal to the prefix sorts first.
/// Common-prefix search is therefore a walk of narrowing binary searches — the
/// operation lattice construction needs — in a fraction of the space a
/// double-array trie would take.
public enum DicFormat {
    public static let magic: [UInt8] = Array("VIMEUDIC".utf8)
    public static let formatVersion: UInt32 = 1
    public static let headerSize = 192
    public static let sectionTableOffset = 48

    /// Bytes per entry in the `tokens` section.
    ///
    /// `surfaceRef: UInt32` + `cost: Int16` + `lid: UInt16` + `rid: UInt16` +
    /// 2 bytes reserved. The padding buys 4-byte alignment for `surfaceRef` and
    /// leaves room for a per-token flag without a format break.
    public static let tokenSize = 12

    /// Longest dictionary reading, in kana. Longer entries are unreachable from
    /// the lattice (it never asks for a longer substring), so the builder drops
    /// them rather than shipping dead weight.
    public static let maxReadingLength = 16

    public enum Section: Int, CaseIterable, Sendable {
        case alphabet = 0
        case keyOffsets
        case keyBytes
        case tokenOffsets
        case tokens
        case surfacePool
        case connection
        case boundary
        case posNames
    }
}

/// One dictionary entry as conversion sees it: a Mozc token.
///
/// `cost`, `lid` and `rid` are Mozc's own values, unmodified. Keeping the POS
/// ids on every token is the whole point of this format — they are what the
/// connection matrix is indexed by, and dropping them is exactly what limited
/// the predecessor (see DESIGN.md §1).
public struct DicToken: Sendable, Equatable {
    public let surface: String
    /// Mozc word cost. **Smaller is more likely.**
    public let cost: Int32
    /// Left POS id — the *column* index when this token follows another:
    /// `trans(previous.rid, self.lid)`.
    public let lid: Int
    /// Right POS id — the *row* index when the next token follows this one.
    public let rid: Int

    public init(surface: String, cost: Int32, lid: Int, rid: Int) {
        self.surface = surface
        self.cost = cost
        self.lid = lid
        self.rid = rid
    }
}

public enum DicError: Error, CustomStringConvertible {
    case cannotOpen(String, Int32)
    case emptyFile(String)
    case badMagic
    case unsupportedVersion(UInt32)
    case truncated(DicFormat.Section)
    case corruptContent
    case alphabetOverflow(Int)
    case surfaceTooLong(String)
    case posOverflow(Int)
    case connectionSizeMismatch(expected: Int, got: Int)

    public var description: String {
        switch self {
        case .cannotOpen(let path, let errno):
            return "cannot open \(path): \(String(cString: strerror(errno)))"
        case .emptyFile(let path):
            return "\(path) is empty"
        case .badMagic:
            return "not a vimeu dictionary (bad magic)"
        case .unsupportedVersion(let v):
            return "unsupported dictionary format version \(v)"
        case .truncated(let s):
            return "dictionary truncated in section \(s)"
        case .corruptContent:
            return "dictionary content hash mismatch"
        case .alphabetOverflow(let n):
            return "readings use \(n) distinct characters; the 1-byte alphabet holds 255"
        case .surfaceTooLong(let s):
            return "surface longer than 65535 bytes: \(s.prefix(32))…"
        case .posOverflow(let n):
            return "\(n) POS ids; lid/rid are UInt16 and the matrix is posCount²"
        case .connectionSizeMismatch(let expected, let got):
            return "connection matrix has \(got) entries, expected \(expected) (posCount²)"
        }
    }
}
