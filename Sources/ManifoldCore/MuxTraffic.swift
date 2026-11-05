import Foundation

/// What a stream of a `Mux` is for, as whoever opened it says — for
/// showing what a link carries (the host inspector), not on the wire:
/// the other end knows a stream by its first frame.
public struct StreamPurpose: Sendable, Equatable {
    /// The kinds a link's bytes are counted by. `control` isn't a stream:
    /// it's the connection's own frames (the state, its events, pings).
    public enum Kind: Int, Sendable, CaseIterable, Comparable {
        case control, terminal, replay, file, forward, page, other

        public static func < (a: Kind, b: Kind) -> Bool { a.rawValue < b.rawValue }

        /// Its name, one and many ("1 page connection", "3 page connections").
        public var noun: (one: String, many: String) {
            switch self {
            case .control: ("state", "state")
            case .terminal: ("terminal", "terminals")
            case .replay: ("terminal replay", "terminal replays")
            case .file: ("file", "files")
            case .forward: ("forwarded port", "forwarded ports")
            case .page: ("page connection", "page connections")
            case .other: ("other", "others")
            }
        }
    }

    public var kind: Kind
    /// What it carries, in a few words: a file's path, "localhost:3000",
    /// "github.com:443"; empty if there's nothing more to say.
    public var detail: String
    /// The block it's for (a terminal's), if it's one's.
    public var block: BlockID?

    public init(_ kind: Kind, _ detail: String = "", block: BlockID? = nil) {
        self.kind = kind
        self.detail = detail
        self.block = block
    }

    public static let other = StreamPurpose(.other)
}

/// Bytes both ways.
public struct Flow: Sendable, Equatable {
    public var sent = 0
    public var received = 0

    public init(sent: Int = 0, received: Int = 0) {
        self.sent = sent
        self.received = received
    }

    public var isEmpty: Bool { sent == 0 && received == 0 }

    public static func + (a: Flow, b: Flow) -> Flow { Flow(sent: a.sent + b.sent, received: a.received + b.received) }
}

/// A link's bytes, by kind, each second of the last five minutes: what
/// went each way as it went over the wire (compressed, framed), so its
/// rates are the link's.
public struct TrafficMeter: Sendable {
    public static let span = 300
    private static let kinds = StreamPurpose.Kind.allCases.count

    /// The second each slot holds (since 1970), and its bytes: by kind,
    /// sent then received.
    private var seconds = [Int](repeating: .min, count: span)
    private var counts = [Int](repeating: 0, count: span * kinds * 2)
    /// Since it was made, by kind.
    private var totals = [Flow](repeating: Flow(), count: kinds)

    public init() {}

    public mutating func count(_ kind: StreamPurpose.Kind, sent: Int = 0, received: Int = 0, at t: TimeInterval) {
        let s = Int(t.rounded(.down))
        let slot = ((s % Self.span) + Self.span) % Self.span
        if seconds[slot] != s {
            seconds[slot] = s
            let from = slot * Self.kinds * 2
            for i in from..<from + Self.kinds * 2 { counts[i] = 0 }
        }
        let i = (slot * Self.kinds + kind.rawValue) * 2
        counts[i] += sent
        counts[i + 1] += received
        totals[kind.rawValue].sent += sent
        totals[kind.rawValue].received += received
    }

    /// Each kind's bytes over the `n` whole seconds before the one `t` is
    /// in (that one's still coming); kinds with none left out.
    public func flow(over n: Int, before t: TimeInterval) -> [StreamPurpose.Kind: Flow] {
        let now = Int(t.rounded(.down))
        var out: [StreamPurpose.Kind: Flow] = [:]
        for s in now - min(n, Self.span - 1)..<now {
            let slot = ((s % Self.span) + Self.span) % Self.span
            guard seconds[slot] == s else { continue }
            for k in StreamPurpose.Kind.allCases {
                let i = (slot * Self.kinds + k.rawValue) * 2
                guard counts[i] != 0 || counts[i + 1] != 0 else { continue }
                out[k, default: Flow()] = out[k, default: Flow()] + Flow(sent: counts[i], received: counts[i + 1])
            }
        }
        return out
    }

    /// Each kind's bytes since the meter was made; kinds with none left out.
    public var total: [StreamPurpose.Kind: Flow] {
        var out: [StreamPurpose.Kind: Flow] = [:]
        for k in StreamPurpose.Kind.allCases where !totals[k.rawValue].isEmpty { out[k] = totals[k.rawValue] }
        return out
    }
}

/// What a link carries now (`Mux.traffic`): by kind, bytes a second
/// lately, the last minute's, and all since the link was made.
public struct LinkTraffic: Sendable {
    /// Over the last `rateWindow` whole seconds, a second.
    public var rate: [StreamPurpose.Kind: Flow]
    public var lastMinute: [StreamPurpose.Kind: Flow]
    public var total: [StreamPurpose.Kind: Flow]
    /// When the link was made.
    public var since: Date

    public static let rateWindow = 2

    public static func sum(_ flows: [StreamPurpose.Kind: Flow]) -> Flow { flows.values.reduce(Flow(), +) }
}

/// One stream open on a link, as it stands (`Mux.openStreams`).
public struct StreamInfo: Sendable {
    public var id: UInt32
    public var purpose: StreamPurpose
    /// Paced (`bulk`), and ahead of the others (`urgent`: a terminal's).
    public var bulk: Bool
    public var urgent: Bool
    public var compresses: Bool
    public var opened: Date
    /// Its bytes as they went over the wire, each way.
    public var flow: Flow
    /// Waiting here to go, and whether it's held for the other end's
    /// credit (its window spent: the other end takes it slower than it
    /// comes).
    public var queued: Int
    public var heldForCredit: Bool
}
