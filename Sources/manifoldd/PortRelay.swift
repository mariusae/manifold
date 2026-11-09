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

/// One connection made for the client, on the host (`TCPConnect`): a
/// forwarded port's (§8) or a page's loaded through the host (§7.6), its
/// bytes handed up as they come, and written as they're sent.
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

    /// Over a socket connected already (blocking), which it closes.
    init(fd: Int32, queue: DispatchQueue) {
        self.fd = fd
        self.queue = queue
        source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        source.setEventHandler { [weak self] in self?.readAvailable() }
        source.setCancelHandler { relayClose(fd) }
        source.resume()
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
    /// holds up only its own connection), and said to be when it is.
    func write(_ data: Data) {
        writes.async { [weak self, fd, queue] in
            FD.writeAll(fd, data)
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
