import Foundation
import Testing
import ManifoldCore
@testable import Manifold

// I-6, M17 (STATE-MACHINES.md): a terminal attached once that attaches
// again — however it comes to (here, resized while unattached) — resumes:
// what it showed kept, what was typed meanwhile sent.

private func muxPair(_ queue: DispatchQueue) -> (Mux, Mux) {
    var fds: [Int32] = [0, 0]
    socketpair(AF_UNIX, SOCK_STREAM, 0, &fds)
    return (Mux(Connection(fd: fds[0], queue: queue)), Mux(Connection(fd: fds[1], queue: queue)))
}

private final class Attaches: @unchecked Sendable {
    private let lock = NSLock()
    private var requests: [AttachRequest] = []
    private var streams: [MuxStream] = []
    func add(_ r: AttachRequest, _ s: MuxStream) { lock.withLock { requests.append(r); streams.append(s) } }
    var all: [AttachRequest] { lock.withLock { requests } }
    var last: MuxStream? { lock.withLock { streams.last } }
}

@MainActor
@Test func aTerminalAttachedOnceThatsResizedWhileUnattachedResumes() async throws {
    let queue = DispatchQueue(label: "test.terminal-link")
    let (app, host) = muxPair(queue)
    let attaches = Attaches()
    host.onStream = { s in
        s.onFrame = { [unowned s] f in
            if f.kind == .message, case let .attach(req)? = f.decode(ClientMessage.self) { attaches.add(req, s) }
        }
    }
    queue.sync { app.start(); host.start() }
    let client = HostClient(transport: .remote(Destination(provider: "ssh", target: "far.invalid"), name: "far"))
    client.debugUse(app)
    let link = TerminalLink(block: BlockID(host: client.host), client: client)

    // Attached (as a terminal is, at its first size).
    link.resized(cols: 80, rows: 24)
    try await Task.sleep(for: .milliseconds(400))
    #expect(attaches.all.count == 1)
    #expect(attaches.all.first?.resume != true)

    // Its stream gone (the host let go of it), and then a resize before
    // anything else attaches it again.
    queue.sync { attaches.last?.close() }
    try await Task.sleep(for: .milliseconds(300))
    link.resized(cols: 100, rows: 30)
    try await Task.sleep(for: .milliseconds(400))
    #expect(attaches.all.count == 2)
    #expect(attaches.all.last?.resume == true, "attached afresh: what it showed and what was typed meanwhile lost")
}
