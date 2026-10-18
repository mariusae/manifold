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
public final class Connection {
    /// Read from here...
    public let fd: Int32
    /// ...and written to here (the same, for a socket).
    public let writeFD: Int32
    private let queue: DispatchQueue
    private let readSource: DispatchSourceRead
    private var writeSource: DispatchSourceWrite?
    private var writeSourceActive = false
    private var outbox = Data()
    private var decoder = FrameDecoder()
    public private(set) var isClosed = false

    public var onFrame: ((Frame) -> Void)?
    public var onClose: (() -> Void)?

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
        // A peer that stops reading doesn't get to hold unbounded memory.
        if outbox.count > 64 << 20 {
            close()
            return
        }
        flush()
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
    }

    private func readAvailable() {
        var buf = [UInt8](repeating: 0, count: 65536)
        let n = read(fd, &buf, buf.count)
        if n < 0 && (errno == EAGAIN || errno == EINTR) { return }
        guard n > 0 else {
            close()
            return
        }
        decoder.append(Data(buf[0..<n]))
        do {
            while !isClosed, let frame = try decoder.next() {
                onFrame?(frame)
            }
        } catch {
            close()
        }
    }

    private func flush() {
        while !outbox.isEmpty {
            let n = outbox.withUnsafeBytes { write(writeFD, $0.baseAddress, $0.count) }
            if n > 0 {
                outbox.removeFirst(n)
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

    /// The host's name, as its first client named it.
    public static var hostName: URL { directory.appendingPathComponent("host") }

    public static var socket: String { directory.appendingPathComponent("manifoldd.sock").path }
    public static var state: URL { directory.appendingPathComponent("state.json") }
    public static var logs: URL { directory.appendingPathComponent("logs") }
    public static var log: URL { directory.appendingPathComponent("manifoldd.log") }

    public static func ensureDirectory() {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }
}
