import Foundation

/// Enough to tell whether a file's text changed.
public enum Fingerprint {
    public static func of(_ s: String) -> String { of(Array(s.utf8)) }

    public static func of<C: Collection>(_ bytes: C) -> String where C.Element == UInt8 {
        var hash: UInt64 = 0xcbf29ce484222325
        for byte in bytes { hash = (hash ^ UInt64(byte)) &* 0x100000001b3 }
        return "\(bytes.count)-\(String(hash, radix: 16))"
    }
}
