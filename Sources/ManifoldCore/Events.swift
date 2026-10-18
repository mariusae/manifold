import Foundation

/// A shard: an independent log. One per block, and a few per host.
public enum ShardID: Hashable, Codable, Sendable, CustomStringConvertible {
    case block(BlockID)
    /// The desk: which arrangements are up, the window, settings.
    case desk(HostID)
    /// Which blocks a host has, and what state each is in.
    case registry(HostID)
    case links(HostID)

    public var host: HostID {
        switch self {
        case .block(let id): id.host
        case .desk(let h), .registry(let h), .links(let h): h
        }
    }

    public var block: BlockID? {
        if case .block(let id) = self { return id }
        return nil
    }

    public var description: String {
        switch self {
        case .block(let id): "block/\(id)"
        case .desk(let h): "desk/\(h)"
        case .registry(let h): "registry/\(h)"
        case .links(let h): "links/\(h)"
        }
    }

    /// A file name for the shard's log.
    public var fileName: String {
        switch self {
        case .block(let id): "block-\(id.host.raw)-\(id.ulid)"
        case .desk(let h): "desk-\(h.raw)"
        case .registry(let h): "registry-\(h.raw)"
        case .links(let h): "links-\(h.raw)"
        }
    }

    public init?(fileName: String) {
        let parts = fileName.split(separator: "-", maxSplits: 2).map(String.init)
        switch parts.first {
        case "block" where parts.count == 3: self = .block(BlockID(host: HostID(parts[1]), ulid: parts[2]))
        case "desk" where parts.count == 2: self = .desk(HostID(parts[1]))
        case "registry" where parts.count == 2: self = .registry(HostID(parts[1]))
        case "links" where parts.count == 2: self = .links(HostID(parts[1]))
        default: return nil
        }
    }
}

/// Who leads a shard: appends to it, and is asked by the other side to.
public enum Leader: String, Codable, Sendable {
    case client, host
}

public enum LinkKind: String, Codable, Sendable {
    case opened, found, output, cwd, source, mention, placed
}

public struct Link: Codable, Equatable, Hashable, Sendable, Identifiable {
    public var id: String
    public var from: BlockID
    public var to: BlockID
    public var kind: LinkKind
    public var at: Stamp

    public init(id: String = ULID.make(), from: BlockID, to: BlockID, kind: LinkKind, at: Stamp) {
        self.id = id
        self.from = from
        self.to = to
        self.kind = kind
        self.at = at
    }
}

/// What a host knows of each of its blocks, for finding and collecting
/// them without opening their logs.
public struct RegistryEntry: Codable, Equatable, Sendable, Identifiable {
    public var id: BlockID
    public var kind: BlockKind
    public var title: String?
    public var path: String?
    public var created: Stamp
    public var lastSeen: Stamp
    public var life: LifeState = .warm
    public var held = false

    public init(id: BlockID, kind: BlockKind, title: String? = nil, path: String? = nil, created: Stamp, lastSeen: Stamp) {
        self.id = id
        self.kind = kind
        self.title = title
        self.path = path
        self.created = created
        self.lastSeen = lastSeen
    }
}

public struct Registry: Codable, Equatable, Sendable {
    public var blocks: [BlockID: RegistryEntry] = [:]
    public init() {}
}

public struct Links: Codable, Equatable, Sendable {
    public var links: [Link] = []
    public init() {}

    public func from(_ id: BlockID) -> [Link] { links.filter { $0.from == id } }
    public func to(_ id: BlockID) -> [Link] { links.filter { $0.to == id } }
}

/// The desk: what the sidebar shows and the window keeps (one per host; the
/// local host's is the one in use).
public struct DeskState: Codable, Equatable, Sendable {
    /// Arrangements on the desk, in the sidebar's order.
    public var order: [BlockID] = []
    public var selected: BlockID?
    /// Arrangements most recently settled on first (⌃⇥'s order, the timeline).
    public var settled: [BlockID] = []
    public var window = WindowState()
    public var appearance = Appearance()
    public var settings = Settings()

    public init() {}
}

public enum ShellEvent: Codable, Equatable, Sendable {
    case started(pid: Int32)
    case ended(status: Int32)
    /// Ended for lying idle off screen for `idleSeconds`.
    case dormant(idleSeconds: Int)
    case busy(Bool)
}

/// What can be appended to a shard. Which cases make sense depends on the
/// shard's kind; `apply` ignores the rest.
public enum Event: Codable, Equatable, Sendable {
    // Any block: its first entry, and its title.
    case create(kind: BlockKind, title: String?, path: String?)
    case title(String?)
    case path(String?)

    // Text.
    /// The whole text, as read from disk (or set at creation).
    case content(String, encoding: String, lineEnding: String, fingerprint: String?)
    /// One group of edits (one undo step).
    case edit([TextEdit])
    /// Clean as of a version: what's on disk is this.
    case clean(version: Int, fingerprint: String?)
    /// The file on disk changed under unsaved changes.
    case stale(Bool)
    case unreadable(Bool)
    case selection(placement: PlacementID, ranges: [TextRange])
    case scroll(placement: PlacementID, y: Double)
    case forget(placement: PlacementID)

    // Terminal.
    case cwd(String?)
    case shell(ShellEvent)

    // Directory.
    case entries([DirectoryEntry], at: Stamp)

    // Web.
    case url(String?, viaHost: Bool)

    // Search.
    /// A query asked: the hits so far go, and the host is looking.
    case search(SearchQuery, at: Stamp)
    /// Hits found, in order; `done` when the host has looked everywhere
    /// (or stopped: `truncated`, or an `error`).
    case hits([SearchHit], done: Bool, truncated: Bool, error: String?)

    // Arrangement.
    /// At column `column` (one past the last makes a new column), index
    /// `at` in it (past the end: on top).
    case place(Placement, column: Int, at: Int)
    case move(PlacementID, column: Int, at: Int)
    case remove(PlacementID)
    case focus(PlacementID?)
    case fractions([Double])
    case heights([PlacementID: Double])
    case layout(ArrangementLayout)
    /// Columns swapped in whole from another arrangement (merging tabs).
    case adopt(columns: [[Placement]], at: Int)
    /// A whole column moved to another index.
    case moveColumn(from: Int, to: Int)

    // Desk.
    case order([BlockID])
    case select(BlockID?)
    case settled(BlockID)
    case window(WindowState)
    case appearance(Appearance)
    case settings(Settings)

    // Registry.
    case register(RegistryEntry)
    case seen([BlockID], at: Stamp)
    case life(BlockID, LifeState, held: Bool)
    case unregister(BlockID)

    // Links.
    case link(Link)
    case unlink(String)
}

/// An entry in a log.
public struct Entry: Codable, Equatable, Sendable {
    public var seq: Int
    public var at: Stamp
    public var event: Event

    public init(seq: Int, at: Stamp, event: Event) {
        self.seq = seq
        self.at = at
        self.event = event
    }
}

// MARK: Applying

extension Block {
    /// Applies an event; pure (no clock, no I/O).
    public mutating func apply(_ event: Event, at: Stamp) {
        switch event {
        case let .create(kind, title, path):
            self = Block(id: id, kind: kind, created: at, title: title, path: path)
        case let .title(t):
            title = t?.trimmingCharacters(in: .whitespacesAndNewlines)
            if title?.isEmpty == true { title = nil }
        case let .path(p):
            path = p
        default:
            break
        }
        if text != nil { text!.apply(event) }
        if terminal != nil { terminal!.apply(event, at: at) }
        if directory != nil { directory!.apply(event) }
        if web != nil { web!.apply(event) }
        if search != nil { search!.apply(event) }
        if arrangement != nil { arrangement!.apply(event) }
    }
}

extension SearchState {
    public mutating func apply(_ event: Event) {
        switch event {
        case let .search(q, at):
            query = q
            hits = []
            running = true
            truncated = false
            error = nil
            ranAt = at
        case let .hits(h, done, truncated, error):
            hits.append(contentsOf: h)
            if done {
                running = false
                self.truncated = truncated
                self.error = error
            }
        default: break
        }
    }
}

extension TextState {
    public mutating func apply(_ event: Event) {
        switch event {
        case let .content(s, encoding, lineEnding, fingerprint):
            text = Rope(s)
            version += 1
            self.encoding = encoding
            self.lineEnding = lineEnding
            if let fingerprint {
                diskFingerprint = fingerprint
                cleanVersion = version
                stale = false
            }
            unreadable = false
            clampSelections()
        case let .edit(edits):
            for e in edits { text.apply(e) }
            version += 1
            clampSelections()
        case let .clean(v, fingerprint):
            cleanVersion = v
            if let fingerprint { diskFingerprint = fingerprint }
            stale = false
        case let .stale(s):
            stale = s
        case let .unreadable(u):
            unreadable = u
        case let .selection(p, ranges):
            selections[p] = ranges.map { $0.clamped(to: text.count) }
        case let .scroll(p, y):
            scroll[p] = y
        case let .forget(p):
            selections.removeValue(forKey: p)
            scroll.removeValue(forKey: p)
        default:
            break
        }
    }

    private mutating func clampSelections() {
        for (k, v) in selections { selections[k] = v.map { $0.clamped(to: text.count) } }
    }
}

extension TerminalState {
    mutating func apply(_ event: Event, at: Stamp) {
        switch event {
        case let .cwd(c): cwd = c
        case let .title(t): title = t
        case let .shell(s):
            switch s {
            case let .started(pid):
                self.pid = pid
                busy = false
                dormantSince = nil
                dormantAfter = nil
            case .ended:
                pid = nil
                busy = false
            case let .dormant(idle):
                pid = nil
                busy = false
                dormantSince = at
                dormantAfter = idle
            case let .busy(b):
                busy = b
            }
        default: break
        }
    }
}

extension DirectoryState {
    public mutating func apply(_ event: Event) {
        if case let .entries(e, at) = event {
            entries = e
            listedAt = at
        }
    }
}

extension WebState {
    public mutating func apply(_ event: Event) {
        switch event {
        case let .url(u, viaHost):
            url = u
            self.viaHost = viaHost
        case let .title(t): title = t
        default: break
        }
    }
}

extension ArrangementState {
    public mutating func apply(_ event: Event) {
        switch event {
        case let .title(t):
            title = t
        case let .place(p, column, at):
            guard placement(p.id) == nil else { return }
            if column >= columns.count {
                columns.append([p])
                fractions = Self.equalFractions(columns.count)
            } else {
                let c = max(column, 0)
                columns[c].insert(p, at: min(max(at, 0), columns[c].count))
            }
            focused = p.id
        case let .move(id, column, at):
            guard let (c, i) = locate(id) else { return }
            let p = columns[c].remove(at: i)
            var target = column
            if columns[c].isEmpty {
                columns.remove(at: c)
                if target > c { target -= 1 }
            }
            if target >= columns.count {
                columns.append([p])
            } else {
                let t = max(target, 0)
                columns[t].insert(p, at: min(max(at, 0), columns[t].count))
            }
            fractions = fractions.count == columns.count ? fractions : Self.equalFractions(columns.count)
            focused = id
        case let .remove(id):
            guard let (c, i) = locate(id) else { return }
            columns[c].remove(at: i)
            var next: PlacementID? = columns[c].last?.id
            if columns[c].isEmpty {
                columns.remove(at: c)
                fractions = Self.equalFractions(columns.count)
                next = columns.isEmpty ? nil : columns[min(c, columns.count - 1)].last?.id
            }
            if focused == id { focused = next }
            heights.removeValue(forKey: id)
        case let .focus(id):
            if let id, let (c, i) = locate(id) {
                if layout == .stacks, i != columns[c].count - 1 {
                    // Focusing raises, in stacks.
                    let p = columns[c].remove(at: i)
                    columns[c].append(p)
                }
                focused = id
            } else if id == nil {
                focused = nil
            }
        case let .fractions(f):
            if f.count == columns.count, f.allSatisfy({ $0 > 0 }) {
                let sum = f.reduce(0, +)
                fractions = f.map { $0 / sum }
            }
        case let .heights(h):
            for (k, v) in h where placement(k) != nil { heights[k] = v }
        case let .layout(l):
            layout = l
        case let .adopt(cols, at):
            let fresh = cols.map { $0.filter { placement($0.id) == nil } }.filter { !$0.isEmpty }
            guard !fresh.isEmpty else { return }
            columns.insert(contentsOf: fresh, at: min(max(at, 0), columns.count))
            fractions = Self.equalFractions(columns.count)
            focused = fresh.last?.last?.id ?? focused
        case let .moveColumn(from, to):
            guard from >= 0, from < columns.count else { return }
            let column = columns.remove(at: from)
            let f = fractions.count > from ? fractions.remove(at: from) : 1 / Double(max(columns.count, 1))
            let index = min(max(to, 0), columns.count)
            columns.insert(column, at: index)
            if fractions.count == columns.count - 1 { fractions.insert(f, at: index) }
        default:
            return
        }
        normalize()
    }
}

extension DeskState {
    public mutating func apply(_ event: Event) {
        switch event {
        case let .order(o): order = o
        case let .select(s): selected = s
        case let .settled(id): settled = [id] + settled.filter { $0 != id }
        case let .window(w): window = w
        case let .appearance(a): appearance = a
        case let .settings(s): settings = s
        default: break
        }
    }
}

extension Registry {
    public mutating func apply(_ event: Event) {
        switch event {
        case let .register(e):
            if var old = blocks[e.id] {
                old.kind = e.kind
                old.title = e.title
                old.path = e.path
                blocks[e.id] = old
            } else {
                blocks[e.id] = e
            }
        case let .seen(ids, at):
            for id in ids { blocks[id]?.lastSeen = at }
        case let .life(id, life, held):
            blocks[id]?.life = life
            blocks[id]?.held = held
        case let .unregister(id):
            blocks.removeValue(forKey: id)
        default: break
        }
    }
}

extension Links {
    public mutating func apply(_ event: Event) {
        switch event {
        case let .link(l):
            // One link of a kind between two blocks; a repeat moves it up.
            links.removeAll { $0.from == l.from && $0.to == l.to && $0.kind == l.kind }
            links.append(l)
        case let .unlink(id):
            links.removeAll { $0.id == id }
        default: break
        }
    }
}
