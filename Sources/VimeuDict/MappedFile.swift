import Foundation

/// A read-only `mmap` of a whole file.
///
/// `Data(contentsOf:options:.mappedIfSafe)` would be shorter, but it does not
/// promise a stable base address for the lifetime of the value, and every
/// lookup here holds raw pointers into the mapping. Doing the `mmap` directly
/// also lets us set `MADV_RANDOM`: dictionary lookups jump around, and the
/// kernel's default read-ahead would fault in megabytes we never read.
public final class MappedFile: @unchecked Sendable {
    public let bytes: UnsafeRawBufferPointer

    private let base: UnsafeMutableRawPointer
    private let length: Int

    public init(path: String) throws {
        let fd = open(path, O_RDONLY)
        guard fd >= 0 else { throw DicError.cannotOpen(path, errno) }
        defer { close(fd) }

        var st = stat()
        guard fstat(fd, &st) == 0 else { throw DicError.cannotOpen(path, errno) }
        let size = Int(st.st_size)
        guard size > 0 else { throw DicError.emptyFile(path) }

        guard let p = mmap(nil, size, PROT_READ, MAP_PRIVATE | MAP_FILE, fd, 0),
              p != MAP_FAILED
        else {
            throw DicError.cannotOpen(path, errno)
        }
        madvise(p, size, MADV_RANDOM)

        base = p
        length = size
        bytes = UnsafeRawBufferPointer(start: UnsafeRawPointer(p), count: size)
    }

    deinit {
        munmap(base, length)
    }
}

// MARK: - Unaligned little-endian reads
//
// Section starts are 8-byte aligned, but `loadUnaligned` is used throughout
// anyway: it costs nothing on arm64/x86_64 and removes a whole class of
// alignment bugs from format changes.

extension UnsafeRawBufferPointer {
    @inline(__always)
    func u8(_ offset: Int) -> UInt8 { self[offset] }

    @inline(__always)
    func u16(_ offset: Int) -> UInt16 {
        UInt16(littleEndian: loadUnaligned(fromByteOffset: offset, as: UInt16.self))
    }

    @inline(__always)
    func u32(_ offset: Int) -> UInt32 {
        UInt32(littleEndian: loadUnaligned(fromByteOffset: offset, as: UInt32.self))
    }

    @inline(__always)
    func u64(_ offset: Int) -> UInt64 {
        UInt64(littleEndian: loadUnaligned(fromByteOffset: offset, as: UInt64.self))
    }

    @inline(__always)
    func f32(_ offset: Int) -> Float {
        Float(bitPattern: u32(offset))
    }
}

// MARK: - Little-endian appends

extension Array where Element == UInt8 {
    mutating func appendLE(_ v: UInt16) {
        Swift.withUnsafeBytes(of: v.littleEndian) { append(contentsOf: $0) }
    }

    mutating func appendLE(_ v: UInt32) {
        Swift.withUnsafeBytes(of: v.littleEndian) { append(contentsOf: $0) }
    }

    mutating func appendLE(_ v: UInt64) {
        Swift.withUnsafeBytes(of: v.littleEndian) { append(contentsOf: $0) }
    }

    mutating func appendLE(_ v: Float) {
        appendLE(v.bitPattern)
    }

    /// Pad to the next multiple of `alignment` so every section starts aligned.
    mutating func align(to alignment: Int) {
        let rem = count % alignment
        if rem != 0 { append(contentsOf: repeatElement(0, count: alignment - rem)) }
    }
}
