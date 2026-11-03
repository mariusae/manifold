import Foundation
import Testing
@testable import ManifoldCore

/// A socket listening on a loopback address (`::1` for v6), at a port
/// the system picks: its descriptor and port.
private func listening(v6: Bool = false) -> (fd: Int32, port: Int) {
    #if canImport(Darwin)
    let fd = socket(v6 ? AF_INET6 : AF_INET, SOCK_STREAM, 0)
    #else
    let fd = socket(v6 ? AF_INET6 : AF_INET, Int32(SOCK_STREAM.rawValue), 0)
    #endif
    var port = 0
    if v6 {
        var a = sockaddr_in6()
        #if canImport(Darwin)
        a.sin6_len = UInt8(MemoryLayout<sockaddr_in6>.size)
        #endif
        a.sin6_family = sa_family_t(AF_INET6)
        a.sin6_addr = in6addr_loopback
        _ = withUnsafePointer(to: &a) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in6>.size)) } }
        var len = socklen_t(MemoryLayout<sockaddr_in6>.size)
        _ = withUnsafeMutablePointer(to: &a) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &len) } }
        port = Int(UInt16(bigEndian: a.sin6_port))
    } else {
        var a = sockaddr_in()
        #if canImport(Darwin)
        a.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        #endif
        a.sin_family = sa_family_t(AF_INET)
        a.sin_addr.s_addr = inet_addr("127.0.0.1")
        _ = withUnsafePointer(to: &a) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }
        var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &a) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &len) } }
        port = Int(UInt16(bigEndian: a.sin_port))
    }
    listen(fd, 4)
    return (fd, port)
}

@Test func aConnectionIsMadeByAddressAndByName() throws {
    let (server, port) = listening()
    defer { close(server) }
    for host in ["127.0.0.1", "localhost"] {
        let fd = try TCPConnect.open(host: host, port: port).get()
        let peer = accept(server, nil, nil)
        #expect(peer >= 0)
        // Blocking, as the relay wants it, and carrying bytes both ways.
        #expect(fcntl(fd, F_GETFL) & O_NONBLOCK == 0)
        #expect(write(fd, "ping", 4) == 4)
        var buf = [UInt8](repeating: 0, count: 4)
        #expect(read(peer, &buf, 4) == 4)
        #expect(String(decoding: buf, as: UTF8.self) == "ping")
        close(peer)
        close(fd)
    }
}

@Test func anIPv6AddressIsTakenAsAURLWritesIt() throws {
    let (server, port) = listening(v6: true)
    defer { close(server) }
    let fd = try TCPConnect.open(host: "[::1]", port: port).get()
    close(fd)
}

@Test func whyAConnectionCantBeMadeIsSaid() {
    // A port that was just listening, and isn't now: nothing there.
    let (server, port) = listening()
    close(server)
    #expect(throws: ConnectFailure.refused) { try TCPConnect.open(host: "127.0.0.1", port: port).get() }
    // A name that's never anyone's (RFC 6761).
    #expect(throws: ConnectFailure.notFound) { try TCPConnect.open(host: "nothing.invalid", port: 80).get() }
    #expect(throws: ConnectFailure.notFound) { try TCPConnect.open(host: "", port: 80).get() }
    #expect(throws: ConnectFailure.failed) { try TCPConnect.open(host: "127.0.0.1", port: 0).get() }
    // Given up on as soon as it's not wanted.
    #expect(throws: ConnectFailure.failed) { try TCPConnect.open(host: "127.0.0.1", port: 9, cancelled: { true }).get() }
    #expect(TCPConnect.failure(ECONNREFUSED) == .refused)
    #expect(TCPConnect.failure(ETIMEDOUT) == .timedOut)
    #expect(TCPConnect.failure(EHOSTUNREACH) == .unreachable)
    #expect(TCPConnect.failure(ENETUNREACH) == .unreachable)
    #expect(TCPConnect.failure(EACCES) == .failed)
}

@Test func theAnswerToAConnectGoesOverTheWire() throws {
    for reply in [ConnectReply.connected, .failed(.notFound), .failed(.timedOut)] {
        #expect(Frame.message(reply).decode(ConnectReply.self) == reply)
    }
    guard case let .connect(host, port)? = Frame.message(ClientMessage.connect(host: "wiki.corp", port: 443)).decode(ClientMessage.self) else {
        Issue.record("connect didn't decode")
        return
    }
    #expect(host == "wiki.corp" && port == 443)
}
