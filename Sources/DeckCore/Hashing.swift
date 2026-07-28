import Foundation

/// Stable, portable hashing for cache filenames.
///
/// Swift's built-in `hashValue` is seeded per process, so it cannot name anything that
/// has to survive a relaunch. CryptoKit would do the job but is Apple-only, and pulling
/// in swift-crypto for cache keys is not worth a dependency.
///
/// This is FNV-1a run twice with different offsets to give 128 bits. It is not a
/// security primitive and is not used as one — the only requirement is that the same
/// input always produces the same filename and that distinct inputs realistically never
/// collide.
public enum StableHash {
    private static let prime: UInt64 = 1_099_511_628_211
    private static let offsetA: UInt64 = 14_695_981_039_346_656_037
    private static let offsetB: UInt64 = 0xcbf2_9ce4_8422_2325 ^ 0x9e37_79b9_7f4a_7c15

    public static func hex(_ input: String) -> String {
        var a = offsetA
        var b = offsetB
        for byte in input.utf8 {
            a = (a ^ UInt64(byte)) &* prime
            // The second lane consumes the byte complemented, so inputs differing only
            // by a transposition do not land on the same pair.
            b = (b ^ UInt64(255 - byte)) &* prime
            b = b ^ (b >> 29)
        }
        // Fold the length in so prefixes cannot share a hash.
        let length = UInt64(input.utf8.count)
        a = (a ^ length) &* prime
        b = (b ^ length) &* prime
        return String(format: "%016llx%016llx", a, b)
    }
}
