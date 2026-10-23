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

extension Zstd {
    /// A stream's frames compressed in turn, each against those before it
    /// (a window of them), each flushed whole: a `Decoder` given the same
    /// frames, in order, makes them again. Kept small: one per compressing
    /// stream, each end.
    public final class Encoder {
        private let ctx: OpaquePointer
        /// What it's taken in and made, in all.
        public private(set) var taken = 0, made = 0

        public init?(level: Int32 = Zstd.level, windowLog: Int32 = Zstd.streamWindowLog) {
            guard let c = ZSTD_createCCtx() else { return nil }
            ctx = c
            ZSTD_CCtx_setParameter(ctx, ZSTD_c_compressionLevel, level)
            ZSTD_CCtx_setParameter(ctx, ZSTD_c_windowLog, windowLog)
            // Tables in keeping with the window (the level's own are sized
            // for bigger inputs).
            ZSTD_CCtx_setParameter(ctx, ZSTD_c_hashLog, windowLog - 2)
            ZSTD_CCtx_setParameter(ctx, ZSTD_c_chainLog, windowLog - 2)
        }

        deinit { ZSTD_freeCCtx(ctx) }

        /// `data`, compressed and flushed; nil if zstd fails (the stream
        /// can't go on compressed).
        public func compress(_ data: Data) -> Data? {
            var out = Data(count: ZSTD_compressBound(data.count) + 32)
            var written = 0
            let ok: Bool = data.withUnsafeBytes { src in
                var input = ZSTD_inBuffer(src: src.baseAddress, size: data.count, pos: 0)
                while true {
                    if written == out.count { out.count += 4096 }
                    let (left, pos): (Int, Int) = out.withUnsafeMutableBytes { dst in
                        var output = ZSTD_outBuffer(dst: dst.baseAddress! + written, size: dst.count - written, pos: 0)
                        let left = ZSTD_compressStream2(ctx, &output, &input, ZSTD_e_flush)
                        return (left, output.pos)
                    }
                    written += pos
                    if ZSTD_isError(left) != 0 { return false }
                    if left == 0 { return true }
                }
            }
            guard ok else { return nil }
            out.count = written
            taken += data.count
            made += written
            return out
        }

        /// The end of its frames (a few bytes): the `Decoder` that takes it
        /// is done, and neither need be kept. Nil if zstd fails.
        public func end() -> Data? {
            var out = Data(count: 64)
            var written = 0
            while true {
                if written == out.count { out.count += 64 }
                var input = ZSTD_inBuffer(src: nil, size: 0, pos: 0)
                let (left, pos): (Int, Int) = out.withUnsafeMutableBytes { dst in
                    var output = ZSTD_outBuffer(dst: dst.baseAddress! + written, size: dst.count - written, pos: 0)
                    let left = ZSTD_compressStream2(ctx, &output, &input, ZSTD_e_end)
                    return (left, output.pos)
                }
                written += pos
                if ZSTD_isError(left) != 0 { return nil }
                if left == 0 { break }
            }
            out.count = written
            made += written
            return out
        }

        /// What it holds (debugging).
        public var memory: Int { ZSTD_sizeof_CCtx(ctx) }
    }

    /// An `Encoder`'s frames made again, in the order it made them.
    public final class Decoder {
        private let ctx: OpaquePointer
        /// Its encoder's frames ended (`Encoder.end`): it isn't needed.
        public private(set) var finished = false

        public init?(windowLogMax: Int32 = Zstd.streamWindowLog + 2) {
            guard let c = ZSTD_createDCtx() else { return nil }
            ctx = c
            // No window bigger than ours is taken: memory a peer could
            // otherwise ask for.
            ZSTD_DCtx_setParameter(ctx, ZSTD_d_windowLogMax, windowLogMax)
        }

        deinit { ZSTD_freeDCtx(ctx) }

        /// One of the encoder's frames; nil if it isn't (corrupt, out of
        /// turn) or comes to more than `limit`.
        public func decompress(_ data: Data, limit: Int = 64 << 20) -> Data? {
            var out = Data(count: max(4096, data.count * 4))
            var written = 0
            let ok: Bool = data.withUnsafeBytes { src in
                var input = ZSTD_inBuffer(src: src.baseAddress, size: data.count, pos: 0)
                while true {
                    if written == out.count {
                        guard out.count < limit else { return false }
                        out.count = min(limit, out.count * 2)
                    }
                    let (r, pos): (Int, Int) = out.withUnsafeMutableBytes { dst in
                        var output = ZSTD_outBuffer(dst: dst.baseAddress! + written, size: dst.count - written, pos: 0)
                        let r = ZSTD_decompressStream(ctx, &output, &input)
                        return (r, output.pos)
                    }
                    written += pos
                    if ZSTD_isError(r) != 0 { return false }
                    // All taken, and the output not full (nothing held back).
                    if input.pos == input.size, written < out.count {
                        finished = r == 0
                        return true
                    }
                }
            }
            guard ok else { return nil }
            out.count = written
            return out
        }

        public var memory: Int { ZSTD_sizeof_DCtx(ctx) }
    }

    /// A compressing stream's window: 128 KB of what it sent before.
    public static let streamWindowLog: Int32 = 17
}
