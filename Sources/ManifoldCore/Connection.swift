import Foundation

/// A framed, non-blocking connection over a socket, driven by dispatch
/// sources on one queue. All methods must be called on that queue.
public final class Connection {
    public let fd: Int32
    private let queue: DispatchQueue
    private let readSource: DispatchSourceRead
    private var writeSource: DispatchSourceWrite?
    private var writeSourceActive = false
    private var outbox = Data()
    private var decoder = FrameDecoder()
    public private(set) var isClosed = false

    public var onFrame: ((Frame) -> Void)?
    public var onClose: (() -> Void)?

    /// Takes ownership of `fd`. Call `start` once the handlers are set.
    public init(fd: Int32, queue: DispatchQueue) {
        self.fd = fd
        self.queue = queue
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
        _ = fcntl(fd, F_SETFD, FD_CLOEXEC)
        var on: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
        readSource = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        readSource.setEventHandler { [weak self] in self?.readAvailable() }
        readSource.setCancelHandler { Darwin.close(fd) }
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
            let n = outbox.withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }
            if n > 0 {
                outbox.removeFirst(n)
            } else if n < 0 && errno == EINTR {
                continue
            } else if n < 0 && errno == EAGAIN {
                if writeSource == nil {
                    let source = DispatchSource.makeWriteSource(fileDescriptor: fd, queue: queue)
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
                Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        if ok != 0 {
            let e = errno
            Darwin.close(fd)
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
        guard ok == 0, Darwin.listen(fd, 64) == 0 else {
            let e = errno
            Darwin.close(fd)
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
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Manifold")
    }

    public static var socket: String { directory.appendingPathComponent("manifoldd.sock").path }
    public static var state: URL { directory.appendingPathComponent("state.json") }
    public static var log: URL { directory.appendingPathComponent("manifoldd.log") }

    public static func ensureDirectory() {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }
}
