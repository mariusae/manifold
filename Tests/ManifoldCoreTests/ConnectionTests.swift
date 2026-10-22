import Foundation
import Testing
@testable import ManifoldCore

/// Two connections joined by a socket pair, on one queue.
private func pair(_ queue: DispatchQueue) -> (Connection, Connection) {
    var fds: [Int32] = [0, 0]
    #if canImport(Darwin)
    socketpair(AF_UNIX, SOCK_STREAM, 0, &fds)
    #else
    socketpair(AF_UNIX, Int32(SOCK_STREAM.rawValue), 0, &fds)
    #endif
    return (Connection(fd: fds[0], queue: queue), Connection(fd: fds[1], queue: queue))
}

/// Waits (pumping nothing: the connections run on their own queue) until
/// `done` says so, or a few seconds pass.
private func wait(until done: () -> Bool) {
    let end = Date().addingTimeInterval(5)
    while !done(), Date() < end { usleep(5_000) }
}

@Test func aBulkFrameArrivesWholeAndOrderedFramesGoAroundIt() {
    let queue = DispatchQueue(label: "connection-test")
    let (a, b) = pair(queue)
    let lock = NSLock()
    var got: [Frame] = []
    b.onFrame = { f in lock.lock(); got.append(f); lock.unlock() }
    let big = Data((0..<(3 << 20)).map { UInt8(truncatingIfNeeded: $0 &* 31) })
    queue.sync {
        a.start()
        b.start()
        a.sendBulk(Frame(.data, big))
        for i in 0..<3 { a.send(Frame(.data, Data([UInt8(i)]))) }
    }
    wait { lock.lock(); defer { lock.unlock() }; return got.count == 4 }
    queue.sync { a.close(); b.close() }
    lock.lock(); defer { lock.unlock() }
    #expect(got.count == 4)
    // The small ones, sent after, came first: the big one was in pieces.
    #expect(got.prefix(3).map(\.payload) == [Data([0]), Data([1]), Data([2])])
    #expect(got.last?.payload == big)
    #expect(got.last?.kind == .data)
}

@Test func bulkFramesTakeTurns() {
    let queue = DispatchQueue(label: "connection-test")
    let (a, b) = pair(queue)
    let lock = NSLock()
    var got: [Frame] = []
    b.onFrame = { f in lock.lock(); got.append(f); lock.unlock() }
    let first = Data(repeating: 1, count: 2 << 20), second = Data(repeating: 2, count: 100_000)
    queue.sync {
        a.start()
        b.start()
        a.sendBulk(Frame(.data, first))
        a.sendBulk(Frame(.data, second))
    }
    wait { lock.lock(); defer { lock.unlock() }; return got.count == 2 }
    queue.sync { a.close(); b.close() }
    lock.lock(); defer { lock.unlock() }
    // The small one, sent second, isn't held up by all of the first.
    #expect(got.map(\.payload.count) == [second.count, first.count])
}
