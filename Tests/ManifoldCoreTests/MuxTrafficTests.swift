import Foundation
import Testing
@testable import ManifoldCore

@Test func trafficMeterCountsWholeSecondsByKind() {
    var m = TrafficMeter()
    let t0: TimeInterval = 1_000_000
    m.count(.page, sent: 100, received: 1000, at: t0 + 0.2)
    m.count(.page, received: 500, at: t0 + 0.9)
    m.count(.terminal, sent: 10, at: t0 + 1.5)
    m.count(.page, received: 7, at: t0 + 2.1)
    // The two whole seconds before t0+2: both of them, not the one still coming.
    let two = m.flow(over: 2, before: t0 + 2.5)
    #expect(two[.page] == Flow(sent: 100, received: 1500))
    #expect(two[.terminal] == Flow(sent: 10))
    #expect(two[.file] == nil)
    // One: only the second before.
    #expect(m.flow(over: 1, before: t0 + 2.5) == [.terminal: Flow(sent: 10)])
    #expect(m.total[.page] == Flow(sent: 100, received: 1507))
}

@Test func trafficMeterForgetsWhatsOlderThanItsSpan() {
    var m = TrafficMeter()
    let t0: TimeInterval = 2_000_000
    m.count(.file, received: 42, at: t0)
    // The same slot, a span later: the old second's bytes gone from it.
    m.count(.file, received: 1, at: t0 + TimeInterval(TrafficMeter.span))
    #expect(m.flow(over: 60, before: t0 + TimeInterval(TrafficMeter.span) + 1) == [.file: Flow(received: 1)])
    // Asked of a time it no longer holds: nothing.
    #expect(m.flow(over: 5, before: t0 + 10).isEmpty)
    #expect(m.total[.file] == Flow(received: 43))
}

@Test func muxCountsEachStreamByItsPurpose() {
    var fds: [Int32] = [0, 0]
    #if canImport(Darwin)
    socketpair(AF_UNIX, SOCK_STREAM, 0, &fds)
    #else
    socketpair(AF_UNIX, Int32(SOCK_STREAM.rawValue), 0, &fds)
    #endif
    let queue = DispatchQueue(label: "mux-traffic-test")
    let client = Mux(Connection(fd: fds[0], queue: queue))
    let server = Mux(Connection(fd: fds[1], queue: queue))
    server.onStream = { s in s.onFrame = { [unowned s] f in s.send(Frame(.data, f.payload + f.payload)) } }
    var page: MuxStream!, term: MuxStream!
    queue.sync {
        client.start()
        server.start()
        page = client.open(bulk: true, purpose: StreamPurpose(.page, "example.com:443"))
        term = client.open(bulk: true, urgent: true, purpose: StreamPurpose(.terminal))
        page.onFrame = { _ in }
        term.onFrame = { _ in }
        page.send(Frame(.data, Data(count: 1000)))
        term.send(Frame(.data, Data(count: 10)))
        client.control.send(Frame(.data, Data(count: 50)))
    }
    let end = Date().addingTimeInterval(10)
    while Date() < end, client.openStreams.first(where: { $0.purpose.kind == .page })?.flow.received ?? 0 < 2000 { usleep(5_000) }
    let streams = client.openStreams
    #expect(streams.map(\.purpose.kind) == [.page, .terminal])
    let p = streams[0]
    #expect(p.purpose.detail == "example.com:443")
    // Its frame and its echo, each with its framing.
    #expect(p.flow.sent > 1000 && p.flow.sent < 1100)
    #expect(p.flow.received > 2000 && p.flow.received < 2100)
    #expect(streams[1].urgent)
    let total = client.traffic.total
    #expect(total[.page] == p.flow)
    #expect(total[.control]?.sent ?? 0 >= 55)
    // The server's side: streams it was asked for, of no purpose it knows.
    #expect(server.openStreams.allSatisfy { $0.purpose.kind == .other })
    _ = term
}
