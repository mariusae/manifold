import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#endif

/// The host's answer to a `connect` (§7.6), the first frame back on its
/// stream: connected, the bytes to follow, or why not.
public enum ConnectReply: Codable, Sendable, Equatable {
    case connected
    case failed(ConnectFailure)
}

/// Why the host couldn't connect, in as much as a SOCKS reply can say.
public enum ConnectFailure: String, Codable, Sendable, Error {
    /// The name isn't known there.
    case notFound
    /// Nothing is listening at the port.
    case refused
    /// There's no way from the host to the address.
    case unreachable
    /// Nothing answered in time.
    case timedOut
    /// Anything else.
    case failed
}

private func tcpClose(_ fd: Int32) { _ = close(fd) }
private func tcpConnect(_ fd: Int32, _ addr: UnsafePointer<sockaddr>, _ len: socklen_t) -> Int32 { connect(fd, addr, len) }

/// A TCP connection made by the host for a page loaded through it (§7.6):
/// `host` — a name, looked up here, as the host's own resolver has it (a
/// VPN's names too), or an address — at `port`. Each of its addresses is
/// tried in the order the resolver gives them, until one answers, for
/// `timeout` at most each. It blocks, so it's called off any queue that
/// has other work; `cancelled` is asked as it waits, and gives up once
/// it's true (the page went). The socket comes back blocking, as a
/// relay wants it, and isn't inherited by what the host starts.
public enum TCPConnect {
    public static func open(host: String, port: Int, timeout: TimeInterval = 10,
                            cancelled: () -> Bool = { false }) -> Result<Int32, ConnectFailure> {
        guard (1...65535).contains(port) else { return .failure(.failed) }
        // An IPv6 address as a URL writes it.
        var name = host
        if name.hasPrefix("["), name.hasSuffix("]") { name = String(name.dropFirst().dropLast()) }
        guard !name.isEmpty else { return .failure(.notFound) }
        // The host's own loopback, both ways — IPv4, else IPv6, as servers
        // bind one or the other — whatever its resolver says of the name.
        if name == "localhost" {
            var why = ConnectFailure.refused
            for address in ["127.0.0.1", "::1"] {
                switch open(host: address, port: port, timeout: timeout, cancelled: cancelled) {
                case let .success(fd): return .success(fd)
                case let .failure(f): why = f
                }
            }
            return .failure(why)
        }
        var hints = addrinfo()
        hints.ai_family = AF_UNSPEC
        hints.ai_socktype = Int32(SOCK_STREAM)
        hints.ai_flags = AI_NUMERICSERV
        var list: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(name, String(port), &hints, &list) == 0, let first = list else { return .failure(.notFound) }
        defer { freeaddrinfo(first) }
        // What went wrong with the last address tried, if none answers.
        var why = ConnectFailure.unreachable
        var next: UnsafeMutablePointer<addrinfo>? = first
        while let ai = next {
            next = ai.pointee.ai_next
            guard !cancelled() else { return .failure(.failed) }
            switch attempt(ai.pointee, timeout: timeout, cancelled: cancelled) {
            case let .success(fd): return .success(fd)
            case let .failure(f): why = f
            }
        }
        return .failure(why)
    }

    /// One address: connected without blocking, and waited on in short
    /// steps, so a page that goes stops the wait.
    private static func attempt(_ ai: addrinfo, timeout: TimeInterval, cancelled: () -> Bool) -> Result<Int32, ConnectFailure> {
        guard let addr = ai.ai_addr else { return .failure(.failed) }
        let fd = socket(ai.ai_family, ai.ai_socktype, ai.ai_protocol)
        guard fd >= 0 else { return .failure(.failed) }
        _ = fcntl(fd, F_SETFD, FD_CLOEXEC)
        #if canImport(Darwin)
        var one: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
        #endif
        let flags = fcntl(fd, F_GETFL)
        _ = fcntl(fd, F_SETFL, flags | O_NONBLOCK)
        var error: Int32 = 0
        if tcpConnect(fd, addr, ai.ai_addrlen) != 0 {
            error = errno
            if error == EINPROGRESS || error == EINTR {
                error = wait(fd, timeout: timeout, cancelled: cancelled)
            }
        }
        guard error == 0 else {
            tcpClose(fd)
            return .failure(failure(error))
        }
        _ = fcntl(fd, F_SETFL, flags & ~O_NONBLOCK)
        return .success(fd)
    }

    /// Until the connection is made or refused (its error, or 0), given
    /// up on (ETIMEDOUT), or no longer wanted (ECANCELED).
    private static func wait(_ fd: Int32, timeout: TimeInterval, cancelled: () -> Bool) -> Int32 {
        let end = Date().addingTimeInterval(timeout)
        while true {
            if cancelled() { return ECANCELED }
            let left = end.timeIntervalSinceNow
            guard left > 0 else { return ETIMEDOUT }
            var p = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
            let n = poll(&p, 1, Int32(min(left, 0.1) * 1000) + 1)
            if n < 0 {
                if errno == EINTR { continue }
                return errno
            }
            guard n > 0 else { continue }
            var error: Int32 = 0
            var len = socklen_t(MemoryLayout<Int32>.size)
            guard getsockopt(fd, SOL_SOCKET, SO_ERROR, &error, &len) == 0 else { return errno }
            return error
        }
    }

    static func failure(_ error: Int32) -> ConnectFailure {
        switch error {
        case ECONNREFUSED: .refused
        case ETIMEDOUT: .timedOut
        case ENETUNREACH, EHOSTUNREACH, ENETDOWN, EHOSTDOWN, EADDRNOTAVAIL: .unreachable
        default: .failed
        }
    }
}
