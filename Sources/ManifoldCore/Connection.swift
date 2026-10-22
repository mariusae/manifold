import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#endif

func sysClose(_ fd: Int32) { _ = close(fd) }
private func sysConnect(_ fd: Int32, _ addr: UnsafePointer<sockaddr>, _ len: socklen_t) -> Int32 { connect(fd, addr, len) }
private func sysListen(_ fd: Int32, _ backlog: Int32) -> Int32 { listen(fd, backlog) }

/// A framed, non-blocking connection over a socket, or over a pair of
/// pipes (a remote host's bridge, by its stdio), driven by dispatch
/// sources on one queue. All methods must be called on that queue.
///
/// Frames go in two lanes. `send` is the ordered one: frames arrive as
/// they were sent. `sendBulk` is for big things whose order doesn't matter
/// (a file's bytes, a piece of an upload): each is cut into fragments
/// that go out between the ordered frames, one fragment at a time and in
/// turn with other bulk sends, so a file on its way holds up nothing
/// else for longer than a fragment takes.
public final class Connection {
    /// How much of a bulk send goes at a time.
    public static let fragmentSize = 64 << 10
    /// Read from here...
    public let fd: Int32
    /// ...and written to here (the same, for a socket).
    public let writeFD: Int32
    private let queue: DispatchQueue
    private let readSource: DispatchSourceRead
    private var writeSource: DispatchSourceWrite?
    private var writeSourceActive = false
    /// Ordered bytes to write, from `sent` on.
    private var outbox = Data()
    private var sent = 0
    /// Bulk sends on their way: their encoded frames, and how far each is.
    private var bulk: [(id: UInt32, data: Data, offset: Int)] = []
    private var nextBulk: UInt32 = 1
    /// Bulk frames coming in, by id, until their last fragment.
    private var fragments: [UInt32: Data] = [:]
    private var decoder = FrameDecoder()
    /// When bytes last came in, and last went out.
    public private(set) var lastRead = Date()
    public private(set) var lastWrite = Date()
    public private(set) var isClosed = false

    public var onFrame: ((Frame) -> Void)?
    public var onClose: (() -> Void)?
    /// Bytes as they arrive, before they make whole frames: a large
    /// frame on its way.
    public var onRead: ((Int) -> Void)?
    /// Told when what was waiting has been written (a `Mux` sends more of
    /// its paced streams then).
    public var onDrain: (() -> Void)?
    private var flushing = false

    /// Takes ownership of the descriptors. Call `start` once the handlers
    /// are set.
    public init(fd: Int32, writeFD: Int32? = nil, queue: DispatchQueue) {
        self.fd = fd
        self.writeFD = writeFD ?? fd
        self.queue = queue
        for d in Set([fd, self.writeFD]) {
            _ = fcntl(d, F_SETFL, fcntl(d, F_GETFL) | O_NONBLOCK)
            _ = fcntl(d, F_SETFD, FD_CLOEXEC)
        }
        #if canImport(Darwin)
        var on: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
        #endif
        let w = self.writeFD
        readSource = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        readSource.setEventHandler { [weak self] in self?.readAvailable() }
        readSource.setCancelHandler {
            sysClose(fd)
            if w != fd { sysClose(w) }
        }
    }

    public func start() { readSource.resume() }

    public func send(_ frame: Frame) {
        guard !isClosed else { return }
        outbox.append(frame.encoded)
        guard !stalled else { return close() }
        flush()
    }

    /// A frame in the bulk lane: whole when it arrives, but not in order
    /// with the frames around it.
    public func sendBulk(_ frame: Frame) {
        guard !isClosed else { return }
        let data = frame.encoded
        guard data.count > Self.fragmentSize else { return send(frame) }
        bulk.append((nextBulk, data, 0))
        nextBulk &+= 1
        guard !stalled else { return close() }
        flush()
    }

    /// Bytes waiting to be written.
    public var pending: Int { outbox.count - sent + bulk.reduce(0) { $0 + $1.data.count - $1.offset } }

    /// A peer that stopped reading doesn't get to hold unbounded memory:
    /// a lot waiting and none of it taken for half a minute (a slow link
    /// that is taking it is let be), or far too much.
    private var stalled: Bool {
        let p = pending
        return p > 1 << 30 || (p > 64 << 20 && Date().timeIntervalSince(lastWrite) > 30)
    }

    public func close() {
        guard !isClosed else { return }
        isClosed = true
        if let writeSource {
            if !writeSourceActive { writeSource.resume() }
            writeSource.cancel()
        }
        readSource.cancel()
        onClose?()
        onClose = nil
        onFrame = nil
        onRead = nil
        onDrain = nil
    }

    private func readAvailable() {
        var buf = [UInt8](repeating: 0, count: 65536)
        let n = read(fd, &buf, buf.count)
        if n < 0 && (errno == EAGAIN || errno == EINTR) { return }
        guard n > 0 else {
            close()
            return
        }
        lastRead = Date()
        onRead?(n)
        decoder.append(Data(buf[0..<n]))
        do {
            while !isClosed, let frame = try decoder.next() {
                if frame.kind == .fragment {
                    if let whole = try reassemble(frame) { onFrame?(whole) }
                } else {
                    onFrame?(frame)
                }
            }
        } catch {
            close()
        }
    }

    /// A bulk frame's fragment: kept until the last, which makes it whole.
    private func reassemble(_ fragment: Frame) throws -> Frame? {
        let p = fragment.payload
        guard p.count >= 5 else { throw ProtocolError.badFrameKind }
        let s = p.startIndex
        let id = p[s..<s + 4].reduce(UInt32(0)) { $0 << 8 | UInt32($1) }
        fragments[id, default: Data()].append(p[(s + 5)...])
        guard fragments[id]!.count <= 1 << 30 else { throw ProtocolError.frameTooLarge }
        guard p[s + 4] != 0, let whole = fragments.removeValue(forKey: id) else { return nil }
        var d = FrameDecoder()
        d.append(whole)
        guard let frame = try d.next() else { throw ProtocolError.badFrameKind }
        return frame
    }

    /// The next bulk send's next fragment, onto the ordered bytes; the
    /// send goes to the back of the line, if there's more of it.
    private func nextFragment() {
        var b = bulk.removeFirst()
        let end = min(b.offset + Self.fragmentSize, b.data.count)
        let last = end == b.data.count
        var p = Data(capacity: 5 + end - b.offset)
        withUnsafeBytes(of: b.id.bigEndian) { p.append(contentsOf: $0) }
        p.append(last ? 1 : 0)
        p.append(b.data[(b.data.startIndex + b.offset)..<(b.data.startIndex + end)])
        outbox.append(Frame(.fragment, p).encoded)
        if !last {
            b.offset = end
            bulk.append(b)
        }
    }

    /// Writes what it can; called again (by the write source) when more can
    /// go. Not re-entered: a send while it's writing just adds to the line.
    private func flush() {
        guard !flushing else { return }
        flushing = true
        defer {
            flushing = false
            if !isClosed, pending == 0 { onDrain?() }
        }
        while true {
            if sent == outbox.count {
                // The ordered bytes all gone: a bulk send's next piece.
                outbox.removeAll(keepingCapacity: outbox.count <= 1 << 20)
                sent = 0
                guard !bulk.isEmpty else { break }
                nextFragment()
            }
            let n = outbox.withUnsafeBytes { write(writeFD, $0.baseAddress! + sent, $0.count - sent) }
            if n > 0 {
                sent += n
                lastWrite = Date()
                // Written bytes dropped now and then, not on every write
                // (which would copy what's left each time).
                if sent >= 1 << 20, sent * 2 >= outbox.count {
                    outbox = outbox.subdata(in: (outbox.startIndex + sent)..<outbox.endIndex)
                    sent = 0
                }
            } else if n < 0 && errno == EINTR {
                continue
            } else if n < 0 && errno == EAGAIN {
                if writeSource == nil {
                    let source = DispatchSource.makeWriteSource(fileDescriptor: writeFD, queue: queue)
                    source.setEventHandler { [weak self] in self?.flush() }
                    writeSource = source
                }
                if !writeSourceActive {
                    writeSourceActive = true
                    writeSource!.resume()
                }
                return
            } else {
                close()
                return
            }
        }
        if writeSourceActive {
            writeSourceActive = false
            writeSource!.suspend()
        }
    }
}

public enum UnixSocket {
    public static func connect(path: String) throws -> Int32 {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw POSIXError(.init(rawValue: errno) ?? .EIO) }
        var addr = try address(path)
        let ok = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                sysConnect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        if ok != 0 {
            let e = errno
            sysClose(fd)
            throw POSIXError(.init(rawValue: e) ?? .EIO)
        }
        _ = fcntl(fd, F_SETFD, FD_CLOEXEC)
        return fd
    }

    public static func listen(path: String) throws -> Int32 {
        unlink(path)
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw POSIXError(.init(rawValue: errno) ?? .EIO) }
        var addr = try address(path)
        let ok = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard ok == 0, sysListen(fd, 64) == 0 else {
            let e = errno
            sysClose(fd)
            throw POSIXError(.init(rawValue: e) ?? .EIO)
        }
        chmod(path, 0o600)
        _ = fcntl(fd, F_SETFD, FD_CLOEXEC)
        return fd
    }

    private static func address(_ path: String) throws -> sockaddr_un {
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        guard bytes.count < MemoryLayout.size(ofValue: addr.sun_path) else {
            throw POSIXError(.ENAMETOOLONG)
        }
        withUnsafeMutableBytes(of: &addr.sun_path) { raw in
            raw.copyBytes(from: bytes)
            raw[bytes.count] = 0
        }
        return addr
    }
}

/// Where Manifold keeps its socket, state, and logs. MANIFOLD_DIR overrides
/// it, so a second instance can run without touching the first.
public enum Paths {
    public static var directory: URL {
        if let dir = ProcessInfo.processInfo.environment["MANIFOLD_DIR"], !dir.isEmpty {
            return URL(fileURLWithPath: dir)
        }
        #if os(macOS)
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Manifold")
        #else
        if let state = ProcessInfo.processInfo.environment["XDG_STATE_HOME"], !state.isEmpty {
            return URL(fileURLWithPath: state).appendingPathComponent("manifold")
        }
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".manifold")
        #endif
    }

    /// Where a host keeps the `manifoldd` a client installed on it (§8.1).
    public static var installedServer: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".manifold/bin/manifoldd")
    }

    /// The host's name, as its first client named it (before sessions).
    public static var hostName: URL { directory.appendingPathComponent("host") }
    /// The host's session id (§8), minted once.
    public static var session: URL { directory.appendingPathComponent("session") }
    /// What the host calls itself, for clients to show.
    public static var label: URL { directory.appendingPathComponent("label") }

    public static var socket: String { directory.appendingPathComponent("manifoldd.sock").path }
    public static var state: URL { directory.appendingPathComponent("state.json") }
    public static var logs: URL { directory.appendingPathComponent("logs") }
    public static var log: URL { directory.appendingPathComponent("manifoldd.log") }

    public static func ensureDirectory() {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }
}
