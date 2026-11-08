import Foundation

/// A shard's state: a block, or one of a host's own shards.
public enum ShardState: Codable, Equatable, Sendable {
    case block(Block)
    case desk(DeskState)
    case registry(Registry)
    case links(Links)

    public mutating func apply(_ event: Event, at: Stamp) {
        // Each payload taken out with an empty one left in its place, so
        // it's the only reference and changes in place — not copied (a
        // text's rope, a block's lists) at every keystroke.
        switch self {
        case .block(var b):
            self = .links(Links())
            b.apply(event, at: at)
            self = .block(b)
        case .desk(var d):
            self = .links(Links())
            d.apply(event)
            self = .desk(d)
        case .registry(var r):
            self = .links(Links())
            r.apply(event)
            self = .registry(r)
        case .links(var l):
            self = .links(Links())
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
    /// How many recent entries a replica keeps in memory (a quarter more
    /// before they are trimmed).
    public var keptEntries = 4096
    /// Called with each shard that changed.
    public var onChange: ((ShardID) -> Void)?

    public init() {}

    // MARK: Reading

    public func replica(_ shard: ShardID) -> Replica? { shards[shard] }
    public func seq(_ shard: ShardID) -> Int { shards[shard]?.seq ?? 0 }
    public func has(_ shard: ShardID) -> Bool { shards[shard] != nil }

    public func block(_ id: BlockID) -> Block? {
        guard cachesBlocks else { return shards[.block(id)]?.state.block }
        if let b = blockCache[id] { return b }
        guard let b = shards[.block(id)]?.state.block else { return nil }
        blockCache[id] = b
        return b
    }

    /// Blocks kept as read (`blockCache`): only where one thread reads and
    /// writes the node, as the app's main thread does — reading writes.
    public var cachesBlocks = false

    /// Blocks as last read, by id: read far more often than they change (a
    /// render reads each tile's several times), and read out of their
    /// shard the whole replica was copied, entries and all, each time.
    /// Dropped before the shard changes — kept, a copy would make the
    /// change copy the block's text.
    private var blockCache: [BlockID: Block] = [:]

    private func changing(_ shard: ShardID) {
        if case .block(let id) = shard { blockCache.removeValue(forKey: id) }
    }

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
        case .desk, .registry, .links: return .host
        case .block(let id):
            switch block(id)?.kind {
            case .terminal?, .directory?, .search?, .git?, .process?, .agent?, .notebook?, .thread?: return .host
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
        if let seq = shards[shard]?.seq {
            guard entry.seq == seq + 1 else { return entry.seq <= seq }
            changing(shard)
            // Changed where it's kept, not copied out and back (its entries,
            // its state) at every keystroke.
            shards[shard]!.state.apply(entry.event, at: entry.at)
            shards[shard]!.seq = entry.seq
            shards[shard]!.entries.append(entry)
            // Trimmed a quarter at a time, not one shifted off every entry.
            if let n = shards[shard]?.entries.count, n > keptEntries + keptEntries / 4 { shards[shard]!.entries.removeFirst(n - keptEntries) }
            graph.apply(entry, to: shard, state: shards[shard]!.state)
        } else {
            guard entry.seq == 1, let state = Self.initialState(shard, entry) else { return false }
            changing(shard)
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
        changing(snapshot.shard)
        shards[snapshot.shard] = Replica(seq: snapshot.seq, state: snapshot.state, entries: [])
        graph.load(snapshot.shard, state: snapshot.state, entries: [])
        onChange?(snapshot.shard)
    }

    public func snapshot(_ shard: ShardID) -> ShardSnapshot? {
        shards[shard].map { ShardSnapshot(shard: shard, seq: $0.seq, state: $0.state) }
    }

    public func remove(_ shard: ShardID) {
        changing(shard)
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
/// state, lowered to events by whoever leads it. Bringing a block here
/// (§3.1) is the one way a tile is made.
extension ArrangementState {
    /// A tile of `block` through `lens`, anywhere here. Editing a text and
    /// viewing it are one tile, unless `exact` (one of each, side by side).
    public func tile(of block: BlockID, lens: Lens, exact: Bool = false) -> Placement? {
        placements.first { $0.block == block && $0.lens == lens }
            ?? (exact || !lens.isText ? nil : placements.first { $0.block == block && $0.lens.isText })
    }

    /// Events that bring `block` into column `column`, as acme places a
    /// new window: below the column's biggest tile, taking its lower half
    /// (or below `below`, when given); a column past the end is a new
    /// one. A tile of the block here already (docked too) is gone to instead.
    public func bringing(_ block: BlockID, lens: Lens, inColumn column: Int, below: PlacementID? = nil, exact: Bool = false,
                         newPlacement: () -> PlacementID) -> [Event] {
        if let t = tile(of: block, lens: lens, exact: exact) { return revealing(t.id) }
        let c = max(column, 0)
        guard c < columns.count else {
            return [.place(Placement(id: newPlacement(), block: block, lens: lens), column: columns.count, at: 0)]
        }
        let anchor = below.flatMap { id in columns[c].firstIndex { $0.id == id } }
            ?? biggestTile(inColumn: c).flatMap { b in columns[c].firstIndex { $0.id == b.id } }
        let at = anchor.map { $0 + 1 } ?? columns[c].count
        return [.place(Placement(id: newPlacement(), block: block, lens: lens), column: c, at: at)]
    }

    /// Events that bring `block` into a new column at `index`.
    public func bringing(_ block: BlockID, lens: Lens, inNewColumnAt index: Int, exact: Bool = false, newPlacement: () -> PlacementID) -> [Event] {
        if let t = tile(of: block, lens: lens, exact: exact) { return revealing(t.id) }
        var events: [Event] = [.place(Placement(id: newPlacement(), block: block, lens: lens), column: columns.count, at: 0)]
        if index < columns.count { events.append(.moveColumn(from: columns.count, to: max(index, 0))) }
        return events
    }

    /// Heights after a tile grows (acme's colgrow): by `step` of the column
    /// taken from its neighbors nearest first; or, with `whole`, the whole
    /// column, the column's other tiles docked (§3.1), their room its.
    public func growing(_ id: PlacementID, step: Double = 0.15, whole: Bool = false) -> [Event] {
        guard let (c, i) = locate(id), columns[c].count > 1 else { return [] }
        let column = columns[c]
        if whole {
            return column.filter { $0.id != id }.map { Event.dock($0.id, heir: nil) } + [.focus(id)]
        }
        var h = column.reduce(into: [PlacementID: Double]()) { $0[$1.id] = height(of: $1.id) }
        let sliver = 0.04
        var want = step
        // Nearest neighbors first, below then above, each giving down to a sliver.
        var order: [Int] = []
        var d = 1
        while order.count < column.count - 1 {
            if i + d < column.count { order.append(i + d) }
            if i - d >= 0 { order.append(i - d) }
            d += 1
        }
        for j in order where want > 0 {
            let pid = column[j].id
            let give = min(want, max(0, (h[pid] ?? 0) - sliver))
            h[pid] = (h[pid] ?? 0) - give
            want -= give
        }
        h[id] = (h[id] ?? 0) + (step - want)
        return [.heights(h)]
    }

    /// A tile taking its column but for the others' bars (a bar ⌥-clicked):
    /// each other down to a sliver — its bar alone, as the grid draws one
    /// that short — still in the grid, not docked; the rest this one's.
    public func squeezing(_ id: PlacementID) -> [Event] {
        guard let (c, _) = locate(id), columns[c].count > 1 else { return [] }
        let others = Double(columns[c].count - 1)
        var h: [PlacementID: Double] = [:]
        for p in columns[c] { h[p.id] = p.id == id ? 1 - Self.barSliver * others : Self.barSliver }
        return [.heights(h), .focus(id)]
    }

    /// A column a tile filled put back (a click on its bar after a fill):
    /// those docked back the last first — each to its place beside the
    /// tiles it was beside, which are back by then — and every share as
    /// it was.
    public func unfilling(_ ids: [PlacementID], heights: [PlacementID: Double], focus: PlacementID) -> [Event] {
        let back = docked.map(\.placement.id).filter(ids.contains).reversed()
        return back.map { Event.undock($0) } + [.heights(heights), .focus(focus)]
    }

    /// A share so small the grid draws only the tile's bar.
    public static let barSliver = 0.001

    /// A tile docked (⌘M, §3.1): out of the grid, its room back where it
    /// came from; still in the space.
    public func docking(_ id: PlacementID) -> [Event] {
        locate(id) == nil ? [] : [.dock(id, heir: nil)]
    }

    /// Events that bring a tile into view and focus, as going to its
    /// block does (a link, the finder, the sidebar, ⌃⇥, Back): a maximized
    /// other tile gives way, a docked one goes back where it was, and it's
    /// focused.
    public func revealing(_ id: PlacementID) -> [Event] {
        var events: [Event] = isDocked(id) ? [.undock(id), .focus(id)] : [.focus(id)]
        if let full, full != id { events.insert(.full(nil), at: 0) }
        return events
    }

    /// A tile in another's place (⌥-dropped on it, or opened over it):
    /// that one docked, its room the tile's — so taking the tile away
    /// again (⌘W, docking it) and going back to the other puts things as
    /// they were.
    public func replacing(_ target: PlacementID, with id: PlacementID) -> [Event] {
        guard id != target, let (c, i) = locate(target), locate(id) != nil || isDocked(id) else { return [] }
        // Just under it, the room from it, then it docked to the tile.
        var spot = i + 1
        if let (c2, j) = locate(id), c2 == c, j < i { spot -= 1 }
        return [.move(id, column: c, at: spot), .dock(target, heir: id), .focus(id)]
    }

    /// A tile moved to a spot in a column, as dropped there.
    public func moving(_ id: PlacementID, column: Int, at: Int) -> [Event] {
        [.move(id, column: column, at: at)]
    }

    /// A tile moved one step a way (⌥⇧⌘ and an arrow): up or down past the
    /// tile beside it in its column; left or right into the next column,
    /// about as far down as it was, or — at the edge, with others still in
    /// its column — a new column of its own there. Nil where it can go no
    /// further.
    public func nudging(_ id: PlacementID, _ way: ManiLayout.Direction) -> [Event]? {
        guard let (c, i) = locate(id) else { return nil }
        let rest = columns[c].filter { $0.id != id }
        switch way {
        case .above:
            guard i > 0 else { return nil }
            return [.move(id, column: c, at: i - 1), .focus(id)]
        case .below:
            guard i < rest.count else { return nil }
            return [.move(id, column: c, at: i + 1), .focus(id)]
        case .left, .right:
            let t = way == .left ? c - 1 : c + 1
            guard columns.indices.contains(t) else {
                // A column of its own at the edge, if it isn't one already.
                guard !rest.isEmpty else { return nil }
                let move = Event.move(id, column: columns.count, at: 0)
                return way == .right ? [move, .focus(id)] : [move, .moveColumn(from: columns.count, to: 0), .focus(id)]
            }
            // About as far down: before the first tile there whose middle
            // is below this one's.
            func middles(_ col: [Placement]) -> [(Int, Double)] {
                var y = 0.0
                return col.enumerated().map { j, p in
                    defer { y += height(of: p.id) }
                    return (j, y + height(of: p.id) / 2)
                }
            }
            let mine = middles(columns[c]).first { columns[c][$0.0].id == id }?.1 ?? 0
            let spot = middles(columns[t]).first { $0.1 > mine }?.0 ?? columns[t].count
            return [.move(id, column: t, at: spot), .focus(id)]
        }
    }
}
