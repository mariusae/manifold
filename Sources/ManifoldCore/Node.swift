import Foundation

/// A shard's state: a block, or one of a host's own shards.
public enum ShardState: Codable, Equatable, Sendable {
    case block(Block)
    case desk(DeskState)
    case registry(Registry)
    case links(Links)

    public mutating func apply(_ event: Event, at: Stamp) {
        switch self {
        case .block(var b):
            b.apply(event, at: at)
            self = .block(b)
        case .desk(var d):
            d.apply(event)
            self = .desk(d)
        case .registry(var r):
            r.apply(event)
            self = .registry(r)
        case .links(var l):
            l.apply(event)
            self = .links(l)
        }
    }

    public var block: Block? {
        if case .block(let b) = self { return b }
        return nil
    }
}

/// A shard's state as of a sequence number.
public struct ShardSnapshot: Codable, Equatable, Sendable {
    public var shard: ShardID
    public var seq: Int
    public var state: ShardState

    public init(shard: ShardID, seq: Int, state: ShardState) {
        self.shard = shard
        self.seq = seq
        self.state = state
    }
}

/// A replica of some shards: their state, and their recent entries. The
/// host's node has every shard; a client's, the ones it mirrors. Both apply
/// the same entries with the same code (`ShardState.apply`), so they agree.
public final class Node {
    public struct Replica: Equatable {
        public var seq: Int
        public var state: ShardState
        /// Recent entries, newest last (older ones are on the host's disk).
        public var entries: [Entry]
    }

    public private(set) var shards: [ShardID: Replica] = [:]
    /// The graph over the shards (§3.5), kept in step with them.
    public let graph = Graph()
    /// How many recent entries a replica keeps in memory.
    public var keptEntries = 4096
    /// Called with each shard that changed.
    public var onChange: ((ShardID) -> Void)?

    public init() {}

    // MARK: Reading

    public func replica(_ shard: ShardID) -> Replica? { shards[shard] }
    public func seq(_ shard: ShardID) -> Int { shards[shard]?.seq ?? 0 }
    public func has(_ shard: ShardID) -> Bool { shards[shard] != nil }

    public func block(_ id: BlockID) -> Block? { shards[.block(id)]?.state.block }

    public var blocks: [Block] {
        shards.values.compactMap { $0.state.block }
    }

    public func blocks(of kind: BlockKind) -> [Block] { blocks.filter { $0.kind == kind } }

    public func desk(_ host: HostID) -> DeskState {
        if case .desk(let d)? = shards[.desk(host)]?.state { return d }
        return DeskState()
    }

    public func registry(_ host: HostID) -> Registry {
        if case .registry(let r)? = shards[.registry(host)]?.state { return r }
        return Registry()
    }

    public func links(_ host: HostID) -> Links {
        if case .links(let l)? = shards[.links(host)]?.state { return l }
        return Links()
    }

    public var hosts: Set<HostID> { Set(shards.keys.map(\.host)) }

    /// Which side appends to a shard.
    public func leader(of shard: ShardID) -> Leader {
        switch shard {
        case .desk: return .client
        case .registry, .links: return .host
        case .block(let id):
            switch block(id)?.kind {
            case .terminal?, .directory?, .search?, .git?, .process?, .agent?: return .host
            case nil: return .client
            default: return .client
            }
        }
    }

    // MARK: Writing

    /// Applies an entry that continues the shard's log. One that doesn't
    /// (a gap, or a repeat) is refused: the caller should fetch a snapshot.
    @discardableResult
    public func apply(_ entry: Entry, to shard: ShardID) -> Bool {
        if var r = shards[shard] {
            guard entry.seq == r.seq + 1 else { return entry.seq <= r.seq }
            r.state.apply(entry.event, at: entry.at)
            r.seq = entry.seq
            r.entries.append(entry)
            if r.entries.count > keptEntries { r.entries.removeFirst(r.entries.count - keptEntries) }
            shards[shard] = r
            graph.apply(entry, to: shard, state: r.state)
        } else {
            guard entry.seq == 1, let state = Self.initialState(shard, entry) else { return false }
            shards[shard] = Replica(seq: 1, state: state, entries: [entry])
            graph.apply(entry, to: shard, state: state)
        }
        onChange?(shard)
        return true
    }

    /// Applies a run of entries; stops at the first that doesn't fit.
    public func apply(_ entries: [Entry], to shard: ShardID) -> Bool {
        for e in entries where !apply(e, to: shard) { return false }
        return true
    }

    /// Appends an event as the shard's next entry. A block's first event
    /// must be `create`.
    @discardableResult
    public func append(_ event: Event, to shard: ShardID, at: Stamp) -> Entry? {
        let entry = Entry(seq: seq(shard) + 1, at: at, event: event)
        return apply(entry, to: shard) ? entry : nil
    }

    /// Takes a snapshot in whole, replacing what's here.
    public func load(_ snapshot: ShardSnapshot) {
        shards[snapshot.shard] = Replica(seq: snapshot.seq, state: snapshot.state, entries: [])
        graph.load(snapshot.shard, state: snapshot.state, entries: [])
        onChange?(snapshot.shard)
    }

    public func snapshot(_ shard: ShardID) -> ShardSnapshot? {
        shards[shard].map { ShardSnapshot(shard: shard, seq: $0.seq, state: $0.state) }
    }

    public func remove(_ shard: ShardID) {
        shards.removeValue(forKey: shard)
        graph.remove(shard)
        onChange?(shard)
    }

    static func initialState(_ shard: ShardID, _ entry: Entry) -> ShardState? {
        switch shard {
        case .block(let id):
            guard case let .create(kind, title, path) = entry.event else { return nil }
            return .block(Block(id: id, kind: kind, created: entry.at, title: title, path: path))
        case .desk:
            var d = DeskState()
            d.apply(entry.event)
            return .desk(d)
        case .registry:
            var r = Registry()
            r.apply(entry.event)
            return .registry(r)
        case .links:
            var l = Links()
            l.apply(entry.event)
            return .links(l)
        }
    }
}

// MARK: Arrangement intents

/// Changes to an arrangement that take some working out against its current
/// state, lowered to events by whoever leads it.
extension ArrangementState {
    /// Events that place `block` beside placement `beside` (to its right,
    /// on that column's stack if there is one, else in a new column), or,
    /// with no `beside`, on the focused column's stack. A placement of the
    /// block already there is raised instead of a second one placed.
    public func placing(_ block: BlockID, lens: Lens, beside: PlacementID?, newPlacement: () -> PlacementID) -> [Event] {
        if let beside, let (c, _) = locate(beside) {
            let right = c + 1
            if right < columns.count {
                if let existing = columns[right].first(where: { $0.block == block && $0.lens == lens }) {
                    return [.focus(existing.id)]
                }
                return [.place(Placement(id: newPlacement(), block: block, lens: lens), column: right, at: columns[right].count)]
            }
            return [.place(Placement(id: newPlacement(), block: block, lens: lens), column: columns.count, at: 0)]
        }
        let c = focused.flatMap { columnIndex(of: $0) } ?? max(columns.count - 1, 0)
        if c < columns.count, let existing = columns[c].first(where: { $0.block == block && $0.lens == lens }) {
            return [.focus(existing.id)]
        }
        return [.place(Placement(id: newPlacement(), block: block, lens: lens), column: c, at: c < columns.count ? columns[c].count : 0)]
    }

    /// Events that put `block` on top of column `column`'s stack, or raise
    /// it there.
    public func placing(_ block: BlockID, lens: Lens, onColumn column: Int, newPlacement: () -> PlacementID) -> [Event] {
        if column < columns.count, let existing = columns[column].first(where: { $0.block == block && $0.lens == lens }) {
            return [.focus(existing.id)]
        }
        return [.place(Placement(id: newPlacement(), block: block, lens: lens), column: column,
                       at: column < columns.count ? columns[column].count : 0)]
    }

    /// The columns of this arrangement split out, one arrangement each
    /// (the focused column stays): what the others take with them.
    public func separated() -> [[Placement]] {
        guard columns.count > 1 else { return [] }
        let keep = focused.flatMap { columnIndex(of: $0) } ?? 0
        return columns.enumerated().filter { $0.offset != keep }.map(\.element)
    }
}
