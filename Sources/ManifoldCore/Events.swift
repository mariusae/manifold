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
    /// A note about a block (§3.5): from the note to what it's about.
    case about
}

public struct Link: Codable, Equatable, Hashable, Sendable, Identifiable {
    public var id: String
    public var from: BlockID
    public var to: BlockID
    public var kind: LinkKind
    public var at: Stamp
    /// What made it, in words: the terminal line a path was ⌘-clicked on,
    /// the editor line that named it, the search hit.
    public var context: String?

    public init(id: String = ULID.make(), from: BlockID, to: BlockID, kind: LinkKind, at: Stamp, context: String? = nil) {
        self.id = id
        self.from = from
        self.to = to
        self.kind = kind
        self.at = at
        self.context = context
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
    /// The trail (§3.5): blocks gone to on this host's desk, in order, as
    /// the host saw them focused and selected; so many, the oldest dropped.
    public var trail: [Step] = []
    public static let trailLimit = 20_000

    public init() {}

    enum CodingKeys: String, CodingKey { case blocks, trail }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        blocks = try c.decode([BlockID: RegistryEntry].self, forKey: .blocks)
        trail = (try? c.decodeIfPresent([Step].self, forKey: .trail)) ?? []
    }
}

public struct Links: Codable, Equatable, Sendable {
    public var links: [Link] = []
    public init() {}

    public func from(_ id: BlockID) -> [Link] { links.filter { $0.from == id } }
    public func to(_ id: BlockID) -> [Link] { links.filter { $0.to == id } }
}

/// The desk, a host's metalog of its workspaces (§8.2): which exist, in
/// order, and the host's settings. Host-written; clients propose. (The
/// selection, the settled order, the window and the appearance are each
/// client's own, `ClientState`; older logs' entries for them still apply.)
public struct DeskState: Codable, Equatable, Sendable {
    /// Workspaces on this host, in the sidebar's order.
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
    /// A placement's lens state: keys set (an empty value takes one away).
    case view(placement: PlacementID, [String: String])

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
    /// An agent's command, run in place of the login shell.
    case command(String?)
    /// The shell ran a command (§3.8): its line, as it started.
    case ran(id: Int, String, at: Stamp)
    /// A command the shell ran ended, with its status.
    case exited(id: Int, status: Int32, at: Stamp)

    // Processes.
    case processes([ProcessEntry], at: Stamp)

    // Directory.
    case entries([DirectoryEntry], at: Stamp)

    // Web.
    case url(String?, viaHost: Bool)

    // Git.
    /// Which system the repository is under.
    case vcs(VCS)
    case gitRefreshed(branch: String?, status: [GitStatusEntry], log: [GitCommit], ahead: Int, behind: Int, error: String?, at: Stamp)

    // Diff.
    case diffSubject(DiffSubject)
    case diffLoaded(oldText: String?, newText: String?, patch: String?, error: String?, at: Stamp)

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
    /// A tile into the stack behind another (§3.1): placed right after it
    /// in its column, taking no room.
    case stash(PlacementID, behind: PlacementID)
    /// The workspace as it was (undo, §3.1): its tiles, shares, focus and
    /// maximized tile put back, in one entry — the log stays as it is,
    /// and the history keeps what was undone.
    case restore(ArrangementState)
    case remove(PlacementID)
    case focus(PlacementID?)
    case fractions([Double])
    case heights([PlacementID: Double])
    case layout(ArrangementLayout)
    /// A tile maximized over the whole arrangement, or none (§3.1).
    case full(PlacementID?)
    /// Columns swapped in whole from another arrangement (merging tabs).
    case adopt(columns: [[Placement]], at: Int)
    /// A whole column moved to another index.
    case moveColumn(from: Int, to: Int)

    // Status (§3.7): a record reported (replacing the last for its id),
    // or, with nil, cleared with everything under it.
    case status(id: String, StatusRecord?)

    // Desk.
    case order([BlockID])
    case select(BlockID?)
    case settled(BlockID)
    case window(WindowState)
    case appearance(Appearance)
    case settings(Settings)

    // Registry.
    /// A block gone to: the trail's next step.
    case step(Step)
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
    /// The block a log describes, replayed up to a moment (every entry when
    /// `upTo` is nil): how it was then (§3.4).
    public static func replaying(_ entries: [Entry], id: BlockID, upTo: Stamp? = nil, base: Block? = nil) -> Block? {
        var block = base
        for e in entries {
            if let upTo, e.at > upTo { break }
            if case let .create(kind, title, path) = e.event {
                block = Block(id: id, kind: kind, created: e.at, title: title, path: path)
            } else {
                block?.apply(e.event, at: e.at)
            }
        }
        return block
    }
}

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
        case let .cwd(c) where terminal == nil:
            // A block without a shell: where it was made.
            home = c
        case let .view(placement, values):
            var v = views?[placement] ?? [:]
            for (k, value) in values {
                if value.isEmpty { v.removeValue(forKey: k) } else { v[k] = value }
            }
            if views == nil { views = [:] }
            views![placement] = v
        case let .status(id, record):
            if let record {
                if status == nil { status = [:] }
                status![id] = record
            } else {
                for k in statusRecords(under: id) { status?.removeValue(forKey: k) }
                if status?.isEmpty == true { status = nil }
            }
        case .shell(.ended), .shell(.dormant):
            // The process gone: what was working or blocked is no more;
            // done and error stay to be attended to.
            for (k, r) in status ?? [:] where r.state == .working || r.state == .blocked { status?.removeValue(forKey: k) }
            if status?.isEmpty == true { status = nil }
        default:
            break
        }
        if text != nil { text!.apply(event) }
        if terminal != nil { terminal!.apply(event, at: at) }
        if directory != nil { directory!.apply(event) }
        if web != nil { web!.apply(event) }
        if search != nil { search!.apply(event) }
        if git != nil { git!.apply(event) }
        if diff != nil { diff!.apply(event) }
        if processes != nil { processes!.apply(event) }
        if arrangement != nil { arrangement!.apply(event, at: at) }
    }
}

extension ProcessState {
    public mutating func apply(_ event: Event) {
        if case let .processes(e, at) = event {
            entries = e
            listedAt = at
        }
    }
}

extension GitState {
    public mutating func apply(_ event: Event) {
        switch event {
        case let .vcs(v):
            vcs = v
        case let .gitRefreshed(branch, status, log, ahead, behind, error, at):
            self.branch = branch
            self.status = status
            self.log = log
            self.ahead = ahead
            self.behind = behind
            self.error = error
            refreshedAt = at
        default: break
        }
    }
}

extension DiffState {
    public mutating func apply(_ event: Event) {
        switch event {
        case let .diffSubject(s):
            subject = s
        case let .diffLoaded(old, new, patch, error, at):
            oldText = old
            newText = new
            self.patch = patch
            self.error = error
            loadedAt = at
        default: break
        }
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
        case let .command(c): command = c
        case let .ran(id, text, at):
            var list = commands ?? []
            list.append(ShellCommand(id: id, text: text, at: at))
            if list.count > Self.commandLimit { list.removeFirst(list.count - Self.commandLimit) }
            commands = list
        case let .exited(id, status, at):
            if let i = commands?.lastIndex(where: { $0.id == id }) {
                commands![i].status = status
                commands![i].ended = at
            }
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
    /// A tile gone from column `c`: its height to the one below it, else
    /// the one above (acme's colclose).
    /// A tile gone from a column leaves its room to the nearest tile that
    /// shows — the one that took its place, else the next below, else the
    /// nearest above — never to a stashed one, which would come out.
    private mutating func giveBack(_ id: PlacementID, inColumn c: Int, wasAt i: Int) {
        let h = heights.removeValue(forKey: id) ?? 0
        guard !columns[c].isEmpty else { return }
        let column = columns[c]
        let at = min(i, column.count - 1)
        let heir = column[at...].first(where: { !isStashed($0.id) })?.id
            ?? column[..<at].last(where: { !isStashed($0.id) })?.id
            ?? column[at].id
        heights[heir] = (heights[heir] ?? 0) + h
    }

    /// The stashed tiles right under a tile in its column: the stack
    /// behind it, which goes where it goes.
    private func followers(of id: PlacementID) -> [Placement] {
        guard let (c, i) = locate(id) else { return [] }
        return Array(columns[c][(i + 1)...].prefix { isStashed($0.id) })
    }

    public mutating func apply(_ event: Event) { apply(event, at: nil) }

    public mutating func apply(_ event: Event, at stamp: Stamp?) {
        switch event {
        case let .title(t):
            title = t
        case let .place(placed, column, at):
            guard placement(placed.id) == nil else { return }
            var p = placed
            if p.placedAt == nil { p.placedAt = stamp }
            if column >= columns.count {
                columns.append([p])
                fractions = Self.equalFractions(columns.count)
                heights[p.id] = 1
            } else {
                let c = max(column, 0)
                let i = min(max(at, 0), columns[c].count)
                // The new tile takes the lower half of the one above it (acme's
                // coladd), or the upper half of the first when it comes first.
                if columns[c].isEmpty {
                    heights[p.id] = 1
                } else {
                    let donor = columns[c][i > 0 ? i - 1 : 0].id
                    let h = heights[donor] ?? 1 / Double(columns[c].count)
                    heights[donor] = h / 2
                    heights[p.id] = h / 2
                }
                columns[c].insert(p, at: i)
            }
            focused = p.id
            normalize()
        case let .restore(state):
            columns = state.columns
            fractions = state.fractions
            heights = state.heights
            focused = state.focused
            full = state.full
            normalize()
        case let .stash(id, behind):
            guard id != behind, let (c, i) = locate(id), locate(behind) != nil, !isStashed(behind) else { return }
            // Its own stack goes with it, so stacks merge whole.
            let stack = isStashed(id) ? [] : followers(of: id)
            guard !stack.contains(where: { $0.id == behind }) else { return }
            let p = columns[c].remove(at: i)
            columns[c].removeAll { t in stack.contains { $0.id == t.id } }
            giveBack(id, inColumn: c, wasAt: i)
            if columns[c].isEmpty { columns.remove(at: c) }
            guard let (tc, ti) = locate(behind) else { return }
            columns[tc].insert(contentsOf: [p] + stack, at: ti + 1)
            heights[p.id] = 0
            fractions = fractions.count == columns.count ? fractions : Self.equalFractions(columns.count)
            if focused == id { focused = behind }
            normalize()
        case let .move(id, column, at):
            guard let (c, i) = locate(id) else { return }
            // A shown tile's stack moves with it.
            let stack = isStashed(id) ? [] : followers(of: id)
            let p = columns[c].remove(at: i)
            columns[c].removeAll { t in stack.contains { $0.id == t.id } }
            giveBack(id, inColumn: c, wasAt: i)
            var target = column
            if columns[c].isEmpty {
                columns.remove(at: c)
                if target > c { target -= 1 }
            }
            if target >= columns.count {
                columns.append([p] + stack)
                heights[p.id] = 1
            } else {
                let t = max(target, 0)
                let j = min(max(at, 0), columns[t].count)
                // The room comes from the nearest tile that shows above the
                // spot, else the first that shows; a stashed one has none.
                let shown = columns[t].filter { !isStashed($0.id) }
                if let donor = (columns[t][..<j].last { !isStashed($0.id) } ?? shown.first)?.id {
                    let h = heights[donor] ?? 1 / Double(max(shown.count, 1))
                    heights[donor] = h / 2
                    heights[p.id] = h / 2
                } else {
                    heights[p.id] = 1
                }
                columns[t].insert(contentsOf: [p] + stack, at: j)
            }
            fractions = fractions.count == columns.count ? fractions : Self.equalFractions(columns.count)
            focused = id
            normalize()
        case let .remove(id):
            guard let (c, i) = locate(id) else { return }
            columns[c].remove(at: i)
            giveBack(id, inColumn: c, wasAt: i)
            var next: PlacementID? = columns[c].isEmpty ? nil : columns[c][min(i, columns[c].count - 1)].id
            if columns[c].isEmpty {
                columns.remove(at: c)
                fractions = Self.equalFractions(columns.count)
                next = columns.isEmpty ? nil : columns[min(c, columns.count - 1)].first?.id
            }
            if focused == id { focused = next }
            normalize()
        case let .focus(id):
            if let id, placement(id) != nil {
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
            for (k, v) in h where placement(k) != nil && v >= 0 { heights[k] = v }
            normalize()
        case .layout:
            break
        case let .full(id):
            full = id.flatMap { placement($0) != nil ? $0 : nil }
            if let id = full { focused = id }
        case let .adopt(cols, at):
            let fresh = cols.map { $0.filter { placement($0.id) == nil }.map { p -> Placement in var q = p; if q.placedAt == nil { q.placedAt = stamp }; return q } }.filter { !$0.isEmpty }
            guard !fresh.isEmpty else { return }
            columns.insert(contentsOf: fresh, at: min(max(at, 0), columns.count))
            fractions = Self.equalFractions(columns.count)
            focused = fresh.last?.last?.id ?? focused
            normalize()
        case let .moveColumn(from, to):
            guard from >= 0, from < columns.count else { return }
            let column = columns.remove(at: from)
            let f = fractions.count > from ? fractions.remove(at: from) : 1 / Double(max(columns.count, 1))
            let index = min(max(to, 0), columns.count)
            columns.insert(column, at: index)
            if fractions.count == columns.count - 1 { fractions.insert(f, at: index) }
            normalize()
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
        case let .step(s):
            if trail.last?.block != s.block { trail.append(s) }
            if trail.count > Self.trailLimit { trail.removeFirst(trail.count - Self.trailLimit) }
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
