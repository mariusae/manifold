import Foundation

/// A host: a machine running a `manifoldd`, named when first attached
/// (`local` for this one). Its key is stable across renames of the machine.
public struct HostID: Hashable, Codable, Sendable, CustomStringConvertible, Comparable {
    public let raw: String

    public init(_ raw: String) { self.raw = raw }

    public static let local = HostID("local")

    public init(from decoder: Decoder) throws {
        raw = try decoder.singleValueContainer().decode(String.self)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        try c.encode(raw)
    }

    public var description: String { raw }
    public static func < (a: HostID, b: HostID) -> Bool { a.raw < b.raw }
}

/// A block's identity: the host it lives on, and a ULID made there. Encoded
/// as `host/ulid`. Ids never change: a file block keeps its id through
/// renames and moves.
public struct BlockID: Hashable, Codable, Sendable, CustomStringConvertible, Comparable {
    public let host: HostID
    public let ulid: String

    public init(host: HostID, ulid: String) {
        self.host = host
        self.ulid = ulid
    }

    /// A new id on `host`.
    public init(host: HostID = .local) {
        self.init(host: host, ulid: ULID.make())
    }

    /// A `manifold:` link's address split: the block, and what follows a
    /// `#` (a place in it — `command=7`, a terminal's command), if any.
    public static func link(_ address: String) -> (block: BlockID, fragment: String?)? {
        var s = address.hasPrefix("manifold:") ? String(address.dropFirst(9)) : address
        s = s.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        var fragment: String?
        if let hash = s.firstIndex(of: "#") {
            fragment = String(s[s.index(after: hash)...])
            s = String(s[..<hash])
        }
        return BlockID(string: s).map { ($0, fragment) }
    }

    public init?(string: String) {
        guard let slash = string.firstIndex(of: "/") else { return nil }
        let host = String(string[..<slash]), ulid = String(string[string.index(after: slash)...])
        guard !host.isEmpty, !ulid.isEmpty else { return nil }
        self.init(host: HostID(host), ulid: ulid)
    }

    public init(from decoder: Decoder) throws {
        let s = try decoder.singleValueContainer().decode(String.self)
        guard let id = BlockID(string: s) else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "bad block id \(s)"))
        }
        self = id
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        try c.encode(description)
    }

    public var description: String { "\(host.raw)/\(ulid)" }

    public static func < (a: BlockID, b: BlockID) -> Bool {
        a.host == b.host ? a.ulid < b.ulid : a.host < b.host
    }
}

/// A placement's id: one appearance of a block in an arrangement.
public typealias PlacementID = String

/// A ULID: 48 bits of milliseconds then 80 random bits, in Crockford's
/// base32, so ids sort by time and need no coordination to make.
public enum ULID {
    private static let alphabet = Array("0123456789ABCDEFGHJKMNPQRSTVWXYZ")

    public static func make(now: Date = Date()) -> String {
        let ms = UInt64(now.timeIntervalSince1970 * 1000)
        var bytes = [UInt8](repeating: 0, count: 16)
        for i in 0..<6 { bytes[i] = UInt8((ms >> (8 * UInt64(5 - i))) & 0xff) }
        for i in 6..<16 { bytes[i] = UInt8.random(in: 0...255) }
        // 128 bits → 26 characters of 5 bits (the first holds 3).
        var out = ""
        var acc: UInt32 = 0, nbits = 0
        var i = 0
        // Lead with the top 3 bits of the first byte so 130 bits divide evenly.
        acc = UInt32(bytes[0] >> 5)
        out.append(alphabet[Int(acc)])
        acc = UInt32(bytes[0] & 0x1f)
        nbits = 5
        i = 1
        while out.count < 26 {
            while nbits < 5, i < 16 {
                acc = (acc << 8) | UInt32(bytes[i])
                nbits += 8
                i += 1
            }
            let shift = nbits - 5
            out.append(alphabet[Int((acc >> UInt32(shift)) & 0x1f)])
            acc &= (1 << UInt32(shift)) - 1
            nbits = shift
        }
        return out
    }
}

/// A hybrid logical clock stamp: close to wall time, never running
/// backwards, and ordering causally related entries across hosts.
public struct Stamp: Hashable, Codable, Sendable, Comparable, CustomStringConvertible {
    /// Milliseconds since 1970.
    public var wall: Int64
    public var logical: Int32
    public var host: HostID

    public init(wall: Int64, logical: Int32 = 0, host: HostID = .local) {
        self.wall = wall
        self.logical = logical
        self.host = host
    }

    public var date: Date { Date(timeIntervalSince1970: Double(wall) / 1000) }

    public static func < (a: Stamp, b: Stamp) -> Bool {
        if a.wall != b.wall { return a.wall < b.wall }
        if a.logical != b.logical { return a.logical < b.logical }
        return a.host < b.host
    }

    public var description: String { "\(wall).\(logical)@\(host)" }
}

/// The clock a host or client stamps its entries with.
public final class Clock {
    public let host: HostID
    private var last = Stamp(wall: 0)
    private let lock = NSLock()

    public init(host: HostID) { self.host = host }

    public func now() -> Stamp {
        lock.lock()
        defer { lock.unlock() }
        let wall = Int64(Date().timeIntervalSince1970 * 1000)
        if wall > last.wall {
            last = Stamp(wall: wall, logical: 0, host: host)
        } else {
            last = Stamp(wall: last.wall, logical: last.logical + 1, host: host)
        }
        return last
    }

    /// Takes note of a stamp seen from elsewhere, so ours stay ahead of it.
    public func observe(_ s: Stamp) {
        lock.lock()
        defer { lock.unlock() }
        if s.wall > last.wall || (s.wall == last.wall && s.logical > last.logical) {
            last = Stamp(wall: s.wall, logical: s.logical, host: host)
        }
    }
}
