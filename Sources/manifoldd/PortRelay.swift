import Foundation
import ManifoldCore
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#endif

private func relayClose(_ fd: Int32) { _ = close(fd) }
private func relayConnect(_ fd: Int32, _ addr: UnsafePointer<sockaddr>, _ len: socklen_t) -> Int32 { connect(fd, addr, len) }

/// One forwarded connection, on the host (§8): a socket to a port on the
/// host's own loopback — IPv4, else IPv6, as servers bind one or the
/// other — its bytes handed up as they come, and written as they're sent.
/// Its stream says when to stop reading (`pause`) and go on (`resume`):
/// a fast server and a slow link fill nothing but the socket.
final class PortRelay {
    private let fd: Int32
    private let source: DispatchSourceRead
    private let queue: DispatchQueue
    private let writes = DispatchQueue(label: "manifoldd.relay")
    private var ended = false
    private var paused = false
    var onData: ((Data) -> Void)?
    var onClose: (() -> Void)?
    /// Bytes from the client written on to the socket (on the queue).
    var onWritten: ((Int) -> Void)?

    init?(port: Int, queue: DispatchQueue) {
        guard let fd = Self.open(port) else { return nil }
        self.fd = fd
        self.queue = queue
        source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        source.setEventHandler { [weak self] in self?.readAvailable() }
        source.setCancelHandler { relayClose(fd) }
        source.resume()
    }

    private static func open(_ port: Int) -> Int32? {
        var v4 = sockaddr_in()
        #if canImport(Darwin)
        v4.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        #endif
        v4.sin_family = sa_family_t(AF_INET)
        v4.sin_port = in_port_t(UInt16(port).bigEndian)
        v4.sin_addr.s_addr = inet_addr("127.0.0.1")
        var v6 = sockaddr_in6()
        #if canImport(Darwin)
        v6.sin6_len = UInt8(MemoryLayout<sockaddr_in6>.size)
        #endif
        v6.sin6_family = sa_family_t(AF_INET6)
        v6.sin6_port = in_port_t(UInt16(port).bigEndian)
        v6.sin6_addr = in6addr_loopback
        for family in [AF_INET, AF_INET6] {
            let fd = socket(family, Int32(SOCK_STREAM), 0)
            guard fd >= 0 else { continue }
            #if canImport(Darwin)
            var one: Int32 = 1
            setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
            #endif
            let ok: Int32
            if family == AF_INET {
                ok = withUnsafePointer(to: &v4) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { relayConnect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }
            } else {
                ok = withUnsafePointer(to: &v6) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { relayConnect(fd, $0, socklen_t(MemoryLayout<sockaddr_in6>.size)) } }
            }
            if ok == 0 { return fd }
            relayClose(fd)
        }
        return nil
    }

    private func readAvailable() {
        var buf = [UInt8](repeating: 0, count: Mux.bulkPiece)
        let n = read(fd, &buf, buf.count)
        if n > 0 {
            onData?(Data(buf[0..<n]))
        } else if n == 0 || (errno != EAGAIN && errno != EINTR) {
            end()
        }
    }

    /// Reading stopped, until `resume`.
    func pause() {
        guard !paused, !ended else { return }
        paused = true
        source.suspend()
    }

    func resume() {
        guard paused, !ended else { return }
        paused = false
        source.resume()
    }

    /// Written in order, off the server's queue (a slow reader there
    /// holds up only its own tunnel), and said to be when it is.
    func write(_ data: Data) {
        writes.async { [weak self, fd, queue] in
            data.withUnsafeBytes { raw in
                guard let base = raw.baseAddress else { return }
                var off = 0
                while off < raw.count {
                    let n = Foundation.write(fd, base + off, raw.count - off)
                    if n > 0 { off += n } else if n < 0 && errno == EINTR { continue } else { return }
                }
            }
            queue.async { self?.onWritten?(data.count) }
        }
    }

    /// The client's side is done sending: what it sent is written, then
    /// the socket's sending side shut, while what comes back still goes
    /// up until the server here closes.
    func finishWriting() {
        writes.async { [fd] in _ = shutdown(fd, Int32(SHUT_WR)) }
    }

    func end() {
        guard !ended else { return }
        ended = true
        // A suspended source must be going again to be cancelled.
        if paused {
            paused = false
            source.resume()
        }
        source.cancel()
        onClose?()
    }
}
