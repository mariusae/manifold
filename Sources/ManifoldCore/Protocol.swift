import Foundation

/// Bumped whenever the messages below change incompatibly.
public let protocolVersion = 5

/// The app and the attach helper both talk to the server over its Unix
/// socket, in frames: a 4-byte big-endian payload length, a kind byte, then
/// the payload. The first frame on a connection says which kind it is: a
/// `hello` (the app) or an `attach` (a terminal's byte stream).
public enum FrameKind: UInt8, Sendable {
    /// A JSON `ClientMessage` or `ServerMessage`.
    case json = 1
    /// Terminal bytes: input from the attach helper, output from the server.
    case data = 2
    /// A terminal size: cols then rows, 2 bytes each, big-endian.
    case resize = 3
    /// Sent by the server after it has replayed a session's recent output.
    case replayDone = 4
}

public struct Frame: Sendable {
    public var kind: FrameKind
    public var payload: Data

    public init(_ kind: FrameKind, _ payload: Data = Data()) {
        self.kind = kind
        self.payload = payload
    }

    public var encoded: Data {
        var d = Data(capacity: 5 + payload.count)
        let n = UInt32(payload.count).bigEndian
        withUnsafeBytes(of: n) { d.append(contentsOf: $0) }
        d.append(kind.rawValue)
        d.append(payload)
        return d
    }

    public static func json<T: Encodable>(_ value: T) -> Frame {
        Frame(.json, try! JSONEncoder().encode(value))
    }

    public static func resize(cols: UInt16, rows: UInt16) -> Frame {
        var d = Data()
        withUnsafeBytes(of: cols.bigEndian) { d.append(contentsOf: $0) }
        withUnsafeBytes(of: rows.bigEndian) { d.append(contentsOf: $0) }
        return Frame(.resize, d)
    }

    public var size: (cols: UInt16, rows: UInt16)? {
        guard kind == .resize, payload.count == 4 else { return nil }
        let b = [UInt8](payload)
        return (UInt16(b[0]) << 8 | UInt16(b[1]), UInt16(b[2]) << 8 | UInt16(b[3]))
    }

    public func decode<T: Decodable>(_ type: T.Type) -> T? {
        guard kind == .json else { return nil }
        return try? JSONDecoder().decode(type, from: payload)
    }
}

/// Splits a byte stream into frames.
public struct FrameDecoder: Sendable {
    private var buffer = Data()

    public init() {}

    public mutating func append(_ data: Data) { buffer.append(data) }

    /// The next complete frame, or nil if more bytes are needed. Throws on a
    /// malformed stream.
    public mutating func next() throws -> Frame? {
        guard buffer.count >= 5 else { return nil }
        let start = buffer.startIndex
        let n = buffer[start..<start + 4].reduce(0) { $0 << 8 | Int($1) }
        guard n <= 64 << 20 else { throw ProtocolError.frameTooLarge }
        guard buffer.count >= 5 + n else { return nil }
        guard let kind = FrameKind(rawValue: buffer[start + 4]) else { throw ProtocolError.badFrameKind }
        let payload = buffer.subdata(in: start + 5..<start + 5 + n)
        buffer.removeSubrange(start..<start + 5 + n)
        return Frame(kind, payload)
    }
}

public enum ProtocolError: Error {
    case frameTooLarge
    case badFrameKind
}

public enum ClientMessage: Codable, Sendable {
    case hello(version: Int)
    case command(Command)
    case attach(AttachRequest)
    /// Asks the server to exit, ending every session.
    case shutdown
}

public struct AttachRequest: Codable, Sendable {
    public var pane: UUID
    public var cols: UInt16
    public var rows: UInt16
    /// Terminal-related variables from the attaching terminal (TERM and the
    /// like), used if the attach starts a new session.
    public var env: [String: String]

    public init(pane: UUID, cols: UInt16, rows: UInt16, env: [String: String]) {
        self.pane = pane
        self.cols = cols
        self.rows = rows
        self.env = env
    }
}

public enum ServerMessage: Codable, Sendable {
    case welcome(version: Int, pid: Int32)
    case state(Workspace)
}
