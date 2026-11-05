import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#endif

/// SOCKS5 (RFC 1928), with its username and password (RFC 1929), as far
/// as a page loaded through a host needs it (§7.6): what a client sends —
/// read from the bytes come so far, which may stop short of a whole
/// message, or run on past it — and the answers. Only CONNECT is done.
public enum Socks5 {
    /// A message read from the start of what's come: not all of it yet,
    /// not SOCKS5, or what it says and how many bytes it took.
    public enum Read<Value> {
        case more
        case bad
        case done(Value, length: Int)
    }

    /// The method a client and a server agree on to say who it is.
    public static let usernamePassword: UInt8 = 2
    /// What a server says when none of the client's methods will do.
    public static let noMethod: UInt8 = 0xFF
    public static let connectCommand: UInt8 = 1

    /// The client's first words: the methods it can say who it is by.
    public static func greeting(_ d: Data) -> Read<[UInt8]> {
        let b = [UInt8](d.prefix(257))
        guard b.count >= 2 else { return b.isEmpty || b[0] == 5 ? .more : .bad }
        guard b[0] == 5, b[1] > 0 else { return .bad }
        let n = Int(b[1])
        guard b.count >= 2 + n else { return .more }
        return .done(Array(b[2..<2 + n]), length: 2 + n)
    }

    /// The client's name and password (RFC 1929).
    public static func credentials(_ d: Data) -> Read<(user: String, password: String)> {
        let b = [UInt8](d.prefix(513))
        guard b.count >= 2 else { return b.isEmpty || b[0] == 1 ? .more : .bad }
        guard b[0] == 1 else { return .bad }
        let u = Int(b[1])
        guard b.count >= 3 + u else { return .more }
        let p = Int(b[2 + u])
        guard b.count >= 3 + u + p else { return .more }
        let user = String(decoding: b[2..<2 + u], as: UTF8.self)
        let password = String(decoding: b[3 + u..<3 + u + p], as: UTF8.self)
        return .done((user, password), length: 3 + u + p)
    }

    /// Where the client asks to be connected: a name, as it was given (to
    /// be looked up by whoever connects), or an address, as text.
    public struct Request: Equatable, Sendable {
        public var command: UInt8
        public var host: String
        public var port: Int

        public init(command: UInt8, host: String, port: Int) {
            self.command = command
            self.host = host
            self.port = port
        }
    }

    public static func request(_ d: Data) -> Read<Request> {
        let b = [UInt8](d.prefix(262))
        guard b.count >= 5 else { return b.isEmpty || b[0] == 5 ? .more : .bad }
        guard b[0] == 5, b[2] == 0 else { return .bad }
        let host: String
        let at: Int
        switch b[3] {
        case 1:
            guard b.count >= 4 + 4 + 2 else { return .more }
            host = b[4..<8].map(String.init).joined(separator: ".")
            at = 8
        case 3:
            let n = Int(b[4])
            guard n > 0 else { return .bad }
            guard b.count >= 5 + n + 2 else { return .more }
            host = String(decoding: b[5..<5 + n], as: UTF8.self)
            at = 5 + n
        case 4:
            guard b.count >= 4 + 16 + 2 else { return .more }
            var addr = in6_addr()
            withUnsafeMutableBytes(of: &addr) { $0.copyBytes(from: b[4..<20]) }
            var text = [CChar](repeating: 0, count: Int(INET6_ADDRSTRLEN))
            guard inet_ntop(AF_INET6, &addr, &text, socklen_t(text.count)) != nil else { return .bad }
            host = String(cString: text)
            at = 20
        default:
            return .bad
        }
        let port = Int(b[at]) << 8 | Int(b[at + 1])
        return .done(Request(command: b[1], host: host, port: port), length: at + 2)
    }

    /// The server's choice of method.
    public static func chose(_ method: UInt8) -> Data { Data([5, method]) }

    /// Whether the name and password were taken.
    public static func authenticated(_ ok: Bool) -> Data { Data([1, ok ? 0 : 1]) }

    /// How a request went, as a SOCKS reply says it.
    public enum Reply: UInt8, Sendable {
        case succeeded = 0
        case failure = 1
        case notAllowed = 2
        case networkUnreachable = 3
        case hostUnreachable = 4
        case refused = 5
        case ttlExpired = 6
        case commandNotSupported = 7
        case addressNotSupported = 8

        /// A host's reason, as near as SOCKS has one.
        public init(_ why: ConnectFailure) {
            switch why {
            case .notFound, .unreachable: self = .hostUnreachable
            case .refused: self = .refused
            case .timedOut: self = .ttlExpired
            case .failed: self = .failure
            }
        }

        /// The reply's bytes. Where the host bound is its own business: none
        /// is said (0.0.0.0, port 0), which clients don't use.
        public var bytes: Data { Data([5, rawValue, 0, 1, 0, 0, 0, 0, 0, 0]) }
    }
}
