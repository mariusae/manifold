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
@Test func whatsSentFromAnotherThreadBeforeACloseAllArrives() {
    let queue = DispatchQueue(label: "mux-test")
    let (client, server) = muxPair(queue)
    let inbox = Inbox()
    let rounds = 20, frames = 300
    server.onStream = { s in
        // A producer of its own (as a file's reader is), sending and then
        // closing while the mux drains what's gone before.
        s.onFrame = { _ in
            DispatchQueue.global().async {
                for i in 0..<frames { s.send(Frame(.data, Data(repeating: UInt8(i & 0xff), count: 2_000))) }
                s.close()
            }
        }
    }
    queue.sync {
        client.start()
        server.start()
    }
    for r in 0..<rounds {
        queue.sync {
            let c = client.open(bulk: true)
            c.onFrame = { inbox.add("round \(r)", $0) }
            c.onClose = { inbox.closed("round \(r)") }
            c.send(Frame(.data, Data("go".utf8)))
        }
    }
    wait { (0..<rounds).allSatisfy { inbox.isClosed("round \($0)") } }
    #expect((0..<rounds).map { inbox.get("round \($0)").count } == Array(repeating: frames, count: rounds))
    queue.sync { client.connection.close(); server.connection.close() }
}

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

@Test func aHistoryMarkAndABackfillRequestSayWhatTheyWereMadeWith() throws {
    let mark = HistoryMark(epoch: 0xDEAD_BEEF_0000_0001, end: 1_234_567, screen: true)
    #expect(HistoryMark(mark.frame) == mark)
    // Not a mark: some other frame, or one the wrong length.
    #expect(HistoryMark(Frame(.data, mark.frame.payload)) == nil)
    #expect(HistoryMark(Frame(.historyMark, Data([1, 2, 3]))) == nil)

    let req = BackfillRequest(block: try #require(BlockID(string: "h4z3gpme3et/01M5HWNAR9X5JKASZVKVFM4GX2")), epoch: 7, from: 10, to: 400, limit: 5_000)
    guard case .backfill(let back)? = Frame.message(ClientMessage.backfill(req)).decode(ClientMessage.self) else {
        Issue.record("not a backfill")
        return
    }
    #expect(back.block == req.block && back.epoch == 7 && back.from == 10 && back.to == 400 && back.limit == 5_000)
}

/// Compressed streams (their tests set what's shared: one at a time).
@Suite(.serialized) struct CompressedStreams {
    @Test func aFilesBigPiecesGoCompressedAndAllArriveBeforeTheClose() throws {
        let saved = Mux.compressBelow
        Mux.compressBelow = .infinity
        defer { Mux.compressBelow = saved }
        let queue = DispatchQueue(label: "mux-test")
        let (client, server) = muxPair(queue)
        let inbox = Inbox()
        // Text, as a file of it: pieces of the most a bulk frame carries.
        var text = Data()
        var i = 0
        while text.count < 700_000 { i += 1; text += Data("-rw-r--r--  1 root  wheel  \(i * 31) Oct 23 file\(i)\n".utf8) }
        let pieces = stride(from: 0, to: text.count, by: Mux.bulkPiece).map { text[$0..<min(text.count, $0 + Mux.bulkPiece)] }
        server.onStream = { s in
            s.onFrame = { _ in
                for p in pieces { s.send(Frame(.data, Data(p))) }
                s.send(Frame(.data, Data("the end".utf8)))
                s.close()
            }
        }
        client.compression = true
        var c: MuxStream!
        queue.sync {
            client.start()
            server.start()
            c = client.open(bulk: true, compress: true)
            c.onFrame = { inbox.add("client", $0) }
            c.onClose = { inbox.closed("client") }
            c.send(Frame(.data, Data("send it".utf8)))
        }
        wait { inbox.isClosed("client") }
        let got = inbox.get("client")
        #expect(got.count == pieces.count + 1)
        #expect(got.dropLast().reduce(Data()) { $0 + $1.payload } == text)
        #expect(got.last?.payload == Data("the end".utf8))
        print("file: \(text.count) bytes, \(server.pacedSent) on the link")
        queue.sync { client.connection.close(); server.connection.close() }
    }

    @Test func aCompressedStreamsFramesGoSmallerBothWaysAndArriveAsTheyWere() {
        // A socket pair is as fast as links come: taken for a slow one here.
        let saved = Mux.compressBelow
        Mux.compressBelow = .infinity
        defer { Mux.compressBelow = saved }
        let queue = DispatchQueue(label: "mux-test")
        let (client, server) = muxPair(queue)
        let inbox = Inbox()
        var serverStream: MuxStream?
        server.onStream = { s in
            serverStream = s
            s.onFrame = { f in inbox.add("server", f) }
        }
        client.compression = true
        let lines = (1...2_000).map { Data("\u{1b}[32m-rw-r--r--\u{1b}[0m  1 marius  staff  \($0 * 37) Oct 23 file\($0).txt\r\n".utf8) }
        let raw = lines.reduce(0) { $0 + $1.count + 5 }
        var s: MuxStream!
        queue.sync {
            client.start()
            server.start()
            s = client.open(bulk: true, compress: true)
            s.onFrame = { inbox.add("client", $0) }
            // Small ones as they are: a keystroke.
            s.send(Frame(.data, Data("ls\r".utf8)))
            for l in lines { s.send(Frame(.data, l)) }
        }
        wait { inbox.get("server").count == lines.count + 1 }
        #expect(inbox.get("server").map(\.payload) == [Data("ls\r".utf8)] + lines)
        // What crossed the link: far less than the frames (each still with
        // its stream's and its own framing, ten bytes).
        print("compressed stream: \(raw) bytes of frames, \(client.pacedSent) on the link")
        #expect(client.pacedSent * 2 < UInt64(raw))
        #expect(s.compresses && serverStream?.compresses == true)

        // And back: the server's side of it compresses too.
        queue.sync { for l in lines.prefix(500) { serverStream!.send(Frame(.data, l)) } }
        wait { inbox.get("client").count == 500 }
        #expect(inbox.get("client").map(\.payload) == Array(lines.prefix(500)))
        #expect(server.pacedSent * 2 < UInt64(lines.prefix(500).reduce(0) { $0 + $1.count + 5 }))
        queue.sync { client.connection.close(); server.connection.close() }
    }

    @Test func anIdleCompressedStreamLetsGoOfItsCompressingAndTakesItUpAgain() {
        let saved = (MuxStream.compressIdle, Mux.compressBelow)
        MuxStream.compressIdle = 0.2
        Mux.compressBelow = .infinity
        defer { (MuxStream.compressIdle, Mux.compressBelow) = saved }
        let queue = DispatchQueue(label: "mux-test")
        let (client, server) = muxPair(queue)
        let inbox = Inbox()
        var serverStream: MuxStream?
        server.onStream = { s in
            serverStream = s
            s.onFrame = { f in inbox.add("server", f) }
        }
        client.compression = true
        let line = Data(String(repeating: "some output, again and again ", count: 10).utf8)
        var s: MuxStream!
        queue.sync {
            client.start()
            server.start()
            s = client.open(bulk: true, compress: true)
            s.send(Frame(.data, line))
        }
        wait { inbox.get("server").count == 1 }
        #expect(s.compressing.deflater && serverStream?.compressing.inflater == true)
        // Idle: both ends let go of theirs.
        wait { !s.compressing.deflater && serverStream?.compressing.inflater == false }
        #expect(!s.compressing.deflater && serverStream?.compressing.inflater == false)
        // Taken up again, the frames as they were.
        queue.sync { s.send(Frame(.data, line)) }
        wait { inbox.get("server").count == 2 }
        #expect(inbox.get("server").map(\.payload) == [line, line])
        queue.sync { client.connection.close(); server.connection.close() }
    }

    @Test func aStreamOpenedCompressedToAnEndThatCantTakeItGoesAsItIs() {
        let queue = DispatchQueue(label: "mux-test")
        let (client, server) = muxPair(queue)
        let inbox = Inbox()
        var serverStream: MuxStream?
        server.onStream = { s in
            serverStream = s
            s.onFrame = { f in inbox.add("server", f) }
        }
        // client.compression left false: a server from before.
        let line = Data(String(repeating: "x", count: 1_000).utf8)
        var s: MuxStream!
        queue.sync {
            client.start()
            server.start()
            s = client.open(bulk: true, compress: true)
            s.send(Frame(.data, line))
        }
        wait { inbox.get("server").count == 1 }
        #expect(!s.compresses && serverStream?.compresses == false)
        #expect(client.pacedSent > 1_000)
        queue.sync { client.connection.close(); server.connection.close() }
    }
}

@Test func aWelcomeSaysWhatItsServerCanDoAndOneFromBeforeSaysNothing() throws {
    let host = HostID("h4z3gpme3et")
    // An app from before reads a welcome with features as it did.
    enum Before: Codable { case welcome(version: Int, pid: Int32, host: HostID, label: String?, attachment: Int, home: String, snapshots: [ShardSnapshot]) }
    let now = Frame.message(ServerMessage.welcome(version: 51, pid: 1, host: host, label: nil, attachment: 0, home: "/", snapshots: [], features: ["zstd"]))
    guard case .welcome(51, 1, host, nil, 0, "/", _)? = now.decode(Before.self) else { Issue.record("not read as before"); return }
    guard case let .welcome(_, _, _, _, _, _, _, features)? = now.decode(ServerMessage.self) else { Issue.record("no welcome"); return }
    #expect(features == ["zstd"])
    // A server from before: none.
    let then = Frame.message(Before.welcome(version: 51, pid: 1, host: host, label: nil, attachment: 0, home: "/", snapshots: []))
    guard case let .welcome(_, _, _, _, _, _, _, none)? = then.decode(ServerMessage.self) else { Issue.record("no welcome"); return }
    #expect(none == nil)
}
