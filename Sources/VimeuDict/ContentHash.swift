import Foundation

/// The 64-bit hash stamped into the dictionary header over the file body.
///
/// It is an integrity check for `dictbuild inspect` and the tests, never
/// something the IME computes — verifying it touches every page and would defeat
/// the point of mapping the file.
///
/// FNV-1a mixes each byte; the SplitMix64 finaliser fixes FNV's weak avalanche in
/// the high bits.
public enum ContentHash {
    @inline(__always)
    public static func hash(_ bytes: UnsafeRawBufferPointer) -> UInt64 {
        var h: UInt64 = 0xcbf2_9ce4_8422_2325
        for b in bytes {
            h ^= UInt64(b)
            h = h &* 0x0000_0100_0000_01b3
        }
        return finalize(h)
    }

    @inline(__always)
    public static func finalize(_ x: UInt64) -> UInt64 {
        var z = x &+ 0x9e37_79b9_7f4a_7c15
        z = (z ^ (z >> 30)) &* 0xbf58_476d_1ce4_e5b9
        z = (z ^ (z >> 27)) &* 0x94d0_49bb_1331_11eb
        return z ^ (z >> 31)
    }
}
