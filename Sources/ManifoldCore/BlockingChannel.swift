import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#endif

/// A file descriptor written to.
public enum FD {
    /// All of `bytes` written, through short writes and interruptions;
    /// false if they couldn't all be.
    @discardableResult
    public static func writeAll(_ fd: Int32, _ bytes: UnsafeRawBufferPointer) -> Bool {
        guard let base = bytes.baseAddress else { return true }
        var off = 0
        while off < bytes.count {
            let n = write(fd, base + off, bytes.count - off)
            if n > 0 { off += n } else if n < 0 && errno == EINTR { continue } else { return false }
        }
        return true
    }

    @discardableResult
    public static func writeAll(_ fd: Int32, _ data: Data) -> Bool {
        data.withUnsafeBytes { writeAll(fd, $0) }
    }
}

/// A connection to a host's server, said to and heard from one frame at
/// a time on the thread that has it: `mani`'s, and `manifoldd`'s own
/// commands (`erase`, `stop`, `state`).
public struct BlockingChannel {
    public let fd: Int32
    private var decoder = FrameDecoder()
    private var buffer = [UInt8](repeating: 0, count: 1 << 20)

    public init(fd: Int32) { self.fd = fd }

    /// What came next.
    public enum Heard {
        case message(ServerMessage)
        /// Nothing by the time given.
        case timedOut
        /// The connection's gone.
        case closed
    }

    /// Sent whole; false if the connection's gone.
    @discardableResult
    public func send(_ message: ClientMessage) -> Bool {
        FD.writeAll(fd, Frame.message(message).encoded)
    }

    /// The hello, as `name`, at this build's version.
    @discardableResult
    public func hello(_ name: String) -> Bool {
        send(.hello(version: protocolVersion, name: name))
    }

    /// The next message from the server, waited for until `deadline`
    /// (nil: as long as it takes). Frames that aren't one are passed over.
    public mutating func next(until deadline: Date? = nil) -> Heard {
        while true {
            if let frame = try? decoder.next() {
                if let message = frame.decode(ServerMessage.self) { return .message(message) }
                continue
            }
            var pfd = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            let left = deadline.map { Int32(max(0, $0.timeIntervalSinceNow) * 1000) } ?? 60_000
            guard deadline == nil || left > 0 else { return .timedOut }
            let r = poll(&pfd, 1, left)
            if r == 0 { continue }
            guard r > 0 else { if errno == EINTR { continue }; return .closed }
            let n = read(fd, &buffer, buffer.count)
            guard n > 0 else { return .closed }
            decoder.append(Data(buffer[0..<n]))
        }
    }
}
