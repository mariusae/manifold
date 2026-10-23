import CZstd
import Foundation

/// Zstandard (Sources/CZstd): what goes over a link compressed — terminal
/// history coming after its screen, so far.
public enum Zstd {
    /// Fast, and a good deal smaller for terminal output (text, and the same
    /// escape sequences again and again).
    public static let level: Int32 = 3

    public static func compress(_ data: Data, level: Int32 = level) -> Data {
        let bound = ZSTD_compressBound(data.count)
        var out = Data(count: bound)
        let n = out.withUnsafeMutableBytes { dst in
            data.withUnsafeBytes { src in
                ZSTD_compress(dst.baseAddress, bound, src.baseAddress, data.count, level)
            }
        }
        guard ZSTD_isError(n) == 0 else { return Data() }
        out.count = n
        return out
    }

    /// What `compress` made, as it was; nil if it isn't that, or would be
    /// bigger than `limit`.
    public static func decompress(_ data: Data, limit: Int = 64 << 20) -> Data? {
        let size = data.withUnsafeBytes { ZSTD_getFrameContentSize($0.baseAddress, data.count) }
        // Unknown (or an error, which is among the largest values): not ours.
        guard size <= UInt64(limit) else { return nil }
        var out = Data(count: Int(size))
        let n = out.withUnsafeMutableBytes { dst in
            data.withUnsafeBytes { src in
                ZSTD_decompress(dst.baseAddress, Int(size), src.baseAddress, data.count)
            }
        }
        guard ZSTD_isError(n) == 0, n == Int(size) else { return nil }
        return out
    }
}
