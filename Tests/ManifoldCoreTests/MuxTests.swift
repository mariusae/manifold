import Foundation
import Testing
@testable import ManifoldCore

/// Two muxes joined by a socket pair, on one queue: the client's and the
/// server's ends.
private func muxPair(_ queue: DispatchQueue) -> (Mux, Mux) {
    var fds: [Int32] = [0, 0]
    #if canImport(Darwin)
    socketpair(AF_UNIX, SOCK_STREAM, 0, &fds)
    #else
    socketpair(AF_UNIX, Int32(SOCK_STREAM.rawValue), 0, &fds)
    #endif
    return (Mux(Connection(fd: fds[0], queue: queue)), Mux(Connection(fd: fds[1], queue: queue)))
}

private func wait(until done: () -> Bool) {
    let end = Date().addingTimeInterval(10)
    while !done(), Date() < end { usleep(5_000) }
}

/// What arrives, kept under a lock (handlers run on the muxes' queue).
private final class Inbox: @unchecked Sendable {
    private let lock = NSLock()
    private var frames: [String: [Frame]] = [:]
    private var closes: Set<String> = []
    func add(_ key: String, _ f: Frame) { lock.lock(); frames[key, default: []].append(f); lock.unlock() }
    func closed(_ key: String) { lock.lock(); closes.insert(key); lock.unlock() }
    func get(_ key: String) -> [Frame] { lock.lock(); defer { lock.unlock() }; return frames[key] ?? [] }
    func isClosed(_ key: String) -> Bool { lock.lock(); defer { lock.unlock() }; return closes.contains(key) }
}

@Test func streamsCarryFramesBothWaysBesideTheControlStream() {
    let queue = DispatchQueue(label: "mux-test")
    let (client, server) = muxPair(queue)
    let inbox = Inbox()
    server.control.onFrame = { inbox.add("server control", $0) }
    server.onStream = { s in
        s.onFrame = { [unowned s] f in
            inbox.add("server \(s.id)", f)
            s.send(Frame(.data, Data("echo ".utf8) + f.payload))
        }
        s.onClose = { inbox.closed("server \(s.id)") }
    }
    client.control.onFrame = { inbox.add("client control", $0) }
    var a: MuxStream!, b: MuxStream!
    queue.sync {
        client.start()
        server.start()
        a = client.open(bulk: false)
        b = client.open(bulk: true)
        a.onFrame = { inbox.add("client a", $0) }
        b.onFrame = { inbox.add("client b", $0) }
        client.control.send(Frame(.data, Data("hello".utf8)))
        a.send(Frame(.data, Data("one".utf8)))
        b.send(Frame(.data, Data("two".utf8)))
        a.send(Frame(.data, Data("three".utf8)))
        a.close()
    }
    // (Stream a was closed here after sending: its echoes are dropped.)
    wait { inbox.get("client b").count == 1 && inbox.isClosed("server 1") }
    #expect(inbox.get("server control").map { String(decoding: $0.payload, as: UTF8.self) } == ["hello"])
    #expect(inbox.get("server 1").map { String(decoding: $0.payload, as: UTF8.self) } == ["one", "three"])
    #expect(inbox.get("server 2").map { String(decoding: $0.payload, as: UTF8.self) } == ["two"])
    #expect(inbox.get("client b").map { String(decoding: $0.payload, as: UTF8.self) } == ["echo two"])
    // Closed after what was sent before it, which still arrived.
    #expect(inbox.isClosed("server 1"))
    queue.sync { client.connection.close(); server.connection.close() }
}

@Test func aBigTransferGoesThroughItsWindowAndThePacing() {
    let queue = DispatchQueue(label: "mux-test")
    let (client, server) = muxPair(queue)
    let inbox = Inbox()
    let total = 24 << 20
    server.onStream = { s in
        s.onFrame = { inbox.add("server", Frame(.data, Data(count: $0.payload.count))) }
    }
    var s: MuxStream!
    queue.sync {
        client.start()
        server.start()
        s = client.open(bulk: true)
        // A producer that waits when told to.
        var sent = 0
        func produce() {
            while sent < total, s.wantsMore {
                s.send(Frame(.data, Data(count: Mux.bulkPiece)))
                sent += Mux.bulkPiece
            }
        }
        s.onDrain = { produce() }
        produce()
    }
    wait { inbox.get("server").reduce(0) { $0 + $1.payload.count } == total }
    #expect(inbox.get("server").reduce(0) { $0 + $1.payload.count } == total)
    // The pacing measured the link: the budget moved off its first guess.
    var pacing = ""
    queue.sync { pacing = client.debugPacing }
    #expect(!pacing.contains("rtt ?"))
    queue.sync { client.connection.close(); server.connection.close() }
}

@Test func streamsCloseWithTheirConnection() {
    let queue = DispatchQueue(label: "mux-test")
    let (client, server) = muxPair(queue)
    let inbox = Inbox()
    server.onStream = { _ in }
    queue.sync {
        client.start()
        server.start()
        let s = client.open(bulk: false)
        s.onClose = { inbox.closed("stream") }
        client.control.onClose = { inbox.closed("control") }
        server.connection.close()
    }
    wait { inbox.isClosed("stream") && inbox.isClosed("control") }
    #expect(inbox.isClosed("stream"))
    #expect(inbox.isClosed("control"))
}

/// A paced stream closed at one end while the other is still sending on
/// it (a terminal closed as its shell prints): what was on its way is
/// still acknowledged, so the sender's count of bytes in flight comes back
/// to nothing — else its pacing, waiting for that count to empty before
/// measuring the round trip, would stop every paced stream for good.
@Test func pacedBytesToAStreamClosedOnTheWayAreStillAcknowledged() {
    let queue = DispatchQueue(label: "mux-test")
    let (client, server) = muxPair(queue)
    let inbox = Inbox()
    // The server's side prints as a shell would, a lot, as fast as it may.
    server.onStream = { s in
        s.onFrame = { [unowned s] _ in
            for _ in 0..<64 { s.send(Frame(.data, Data(repeating: 65, count: 16 << 10))) }
        }
    }
    var t: MuxStream!
    queue.sync {
        client.start()
        server.start()
        let stream = client.open(bulk: true, urgent: true)
        // Closed as soon as its first output arrives.
        stream.onFrame = { [unowned stream] f in
            inbox.add("terminal", f)
            stream.abort()
        }
        t = stream
        t.send(Frame(.data, Data("attach".utf8)))
    }
    wait { !inbox.get("terminal").isEmpty }
    // Everything the server sent has arrived somewhere by now.
    wait { server.inFlight == 0 }
    #expect(server.inFlight == 0)
    #expect(client.inFlight == 0)
}
