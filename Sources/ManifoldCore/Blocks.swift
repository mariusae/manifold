import Foundation

/// What a block is.
public enum BlockKind: String, Codable, Sendable, CaseIterable {
    /// A file on its host, or, with no path, a note.
    case text
    case terminal
    case directory
    case web
    case image
    case pdf
    case search
    case diff
    case git
    case process
    case agent
    /// Placements of other blocks, laid out (§3 of DESIGN.md).
    case arrangement

    public var defaultTitle: String {
        switch self {
        case .text: "Untitled"
        case .terminal: "Terminal"
        case .directory: "Folder"
        case .web: "Web"
        case .image: "Image"
        case .pdf: "PDF"
        case .search: "Search"
        case .diff: "Diff"
        case .git: "Git"
        case .process: "Processes"
        case .agent: "Agent"
        case .arrangement: "Untitled"
        }
    }
}

/// How a block is shown.
public enum Lens: String, Codable, Sendable, CaseIterable {
    case editor
    /// Markdown rendered, on a text block.
    case preview
    case terminal
    case directory
    case web
    case image
    case pdf
    case search
    case diff
    case git
    case process
    case agent
    /// An arrangement as a card: its title and a small live picture.
    case card

    /// The lens a block of `kind` is shown with unless another is asked for.
    public static func `default`(for kind: BlockKind, path: String? = nil) -> Lens {
        switch kind {
        case .text:
            if let path, Lens.isMarkdown(path) { return .preview }
            return .editor
        case .terminal: return .terminal
        case .directory: return .directory
        case .web: return .web
        case .image: return .image
        case .pdf: return .pdf
        case .search: return .search
        case .diff: return .diff
        case .git: return .git
        case .process: return .process
        case .agent: return .agent
        case .arrangement: return .card
        }
    }

    public static func isMarkdown(_ path: String) -> Bool {
        ["md", "markdown", "mdown", "mkd", "mdx"].contains(path.pathExtension.lowercased())
    }
}

/// Where a block is on the ladder from on screen to only in its log (§4).
public enum LifeState: String, Codable, Sendable {
    case live, warm, dormant, held
}

// MARK: Text

public struct TextState: Codable, Equatable, Sendable {
    public var text = Rope()
    /// Counts up with every content change.
    public var version = 0
    /// The version as last read from or written to disk; dirty is derived.
    public var cleanVersion = 0
    public var encoding = "utf-8"
    public var lineEnding = "\n"
    /// A fingerprint of the file as last read or written, to tell a change
    /// on disk from our own write.
    public var diskFingerprint: String?
    /// The file changed on disk under unsaved changes.
    public var stale = false
    /// Whether the file could be read as text at all.
    public var unreadable = false
    /// Each placement's selections (several, for several cursors) and scroll.
    public var selections: [PlacementID: [TextRange]] = [:]
    public var scroll: [PlacementID: Double] = [:]

    public init() {}

    public var isDirty: Bool { version != cleanVersion }
}

// MARK: Terminal

public struct TerminalState: Codable, Equatable, Sendable {
    public var cwd: String?
    /// The title the program in it last set.
    public var title: String?
    /// The shell's process, while one is running.
    public var pid: Int32?
    /// Whether something other than the idle shell is running in it.
    public var busy = false
    /// Set when the shell was ended for lying idle off screen: the terminal
    /// is dormant, and the next shell starts under the old transcript, with
    /// a seam between.
    public var dormantSince: Stamp?
    /// For an agent: the command run in place of the login shell.
    public var command: String?
    /// How long the last shell had been idle when it was ended, in seconds.
    public var dormantAfter: Int?

    public init() {}
}

// MARK: Status (§3.7)

/// What a block is doing, in OSC 7501's states.
public enum StatusState: String, Codable, Sendable, CaseIterable {
    case idle, working, done, blocked, error
}

/// What a blocked program needs.
public enum BlockedKind: String, Codable, Sendable {
    case permission, question, auth
}

/// One status record: a report, replacing the last for its id whole.
public struct StatusRecord: Codable, Equatable, Sendable {
    public var state: StatusState
    public var kind: BlockedKind?
    /// 0–100 while working (or blocked); nil for indeterminate.
    public var progress: Int?
    public var app: String?
    public var title: String?
    public var msg: String?
    /// When it was reported.
    public var at: Stamp
    /// Done or error, attended to since (§3.7): read, and quiet.
    public var read: Bool?

    public init(state: StatusState, kind: BlockedKind? = nil, progress: Int? = nil, app: String? = nil,
                title: String? = nil, msg: String? = nil, at: Stamp, read: Bool? = nil) {
        self.state = state
        self.kind = kind
        self.progress = progress
        self.app = app
        self.title = title
        self.msg = msg
        self.at = at
        self.read = read
    }

    /// Needs attending to: finished or failed and not yet read, or waiting
    /// on you.
    public var wantsAttention: Bool { ((state == .done || state == .error) && read != true) || state == .blocked }
}

/// The root record's id.
public let rootStatusID = ""

// MARK: Directory

public struct DirectoryEntry: Codable, Equatable, Sendable {
    public var name: String
    public var isDirectory: Bool
    public var size: Int64
    /// Modified, as seconds since 1970.
    public var modified: Double
    public var isHidden: Bool

    public init(name: String, isDirectory: Bool, size: Int64, modified: Double, isHidden: Bool) {
        self.name = name
        self.isDirectory = isDirectory
        self.size = size
        self.modified = modified
        self.isHidden = isHidden
    }
}

public struct DirectoryState: Codable, Equatable, Sendable {
    public var entries: [DirectoryEntry] = []
    public var listedAt: Stamp?
    public init() {}
}

// MARK: Search

/// What to look for, where: text or a regular expression, in the files
/// under a root on the block's host, those matching a glob if given.
public struct SearchQuery: Codable, Equatable, Sendable {
    public var text: String
    public var regex: Bool
    public var caseSensitive: Bool
    public var root: String
    public var glob: String?

    public init(text: String, regex: Bool = false, caseSensitive: Bool = false, root: String, glob: String? = nil) {
        self.text = text
        self.regex = regex
        self.caseSensitive = caseSensitive
        self.root = root
        self.glob = glob
    }
}

/// A place the text was found: line and column from 1, the line's text.
public struct SearchHit: Codable, Equatable, Sendable {
    public var path: String
    public var line: Int
    public var column: Int
    public var text: String

    public init(path: String, line: Int, column: Int, text: String) {
        self.path = path
        self.line = line
        self.column = column
        self.text = text
    }
}

/// A search block: the last query asked, and what the host found, as it
/// found it. Asking again clears the hits.
public struct SearchState: Codable, Equatable, Sendable {
    public var query: SearchQuery?
    public var hits: [SearchHit] = []
    public var running = false
    public var truncated = false
    public var error: String?
    public var ranAt: Stamp?
    public init() {}
}

// MARK: Processes

/// A process on the host, as `ps` lists it.
public struct ProcessEntry: Codable, Equatable, Sendable {
    public var pid: Int32
    public var parent: Int32
    public var user: String
    public var cpu: Double
    /// Resident memory, in kilobytes.
    public var memory: Int64
    public var command: String

    public init(pid: Int32, parent: Int32, user: String, cpu: Double, memory: Int64, command: String) {
        self.pid = pid
        self.parent = parent
        self.user = user
        self.cpu = cpu
        self.memory = memory
        self.command = command
    }
}

/// A process block: the host's processes, as last listed.
public struct ProcessState: Codable, Equatable, Sendable {
    public var entries: [ProcessEntry] = []
    public var listedAt: Stamp?
    public init() {}
}

// MARK: Git

/// A file in a repository as `git status` has it: the index and work tree
/// letters (` M`, `M `, `??`, `A `, `D `...).
public struct GitStatusEntry: Codable, Equatable, Sendable {
    public var path: String
    public var index: String
    public var workTree: String

    public init(path: String, index: String, workTree: String) {
        self.path = path
        self.index = index
        self.workTree = workTree
    }

    public var isUntracked: Bool { index == "?" }
}

public struct GitCommit: Codable, Equatable, Sendable {
    public var sha: String
    public var short: String
    public var author: String
    /// Seconds since 1970.
    public var date: Double
    public var summary: String

    public init(sha: String, short: String, author: String, date: Double, summary: String) {
        self.sha = sha
        self.short = short
        self.author = author
        self.date = date
        self.summary = summary
    }
}

/// A git block: a repository (the block's path), its branch, what's
/// changed, and its recent history, as the host last looked.
public struct GitState: Codable, Equatable, Sendable {
    /// Which system the repository is under; nil before the host said.
    public var vcs: VCS?
    public var branch: String?
    public var status: [GitStatusEntry] = []
    public var log: [GitCommit] = []
    public var ahead = 0
    public var behind = 0
    public var error: String?
    public var refreshedAt: Stamp?
    public init() {}
}

// MARK: Diff

/// One side of a diff: a file as it is in the work tree (`revision` nil),
/// or as a revision has it (`HEAD`, a sha, `:0` for the index).
public struct DiffSide: Codable, Equatable, Sendable {
    public var path: String
    public var revision: String?

    public init(path: String, revision: String? = nil) {
        self.path = path
        self.revision = revision
    }
}

/// What a diff block compares: a file at two points, or a whole commit.
public enum DiffSubject: Codable, Equatable, Sendable {
    case sides(old: DiffSide, new: DiffSide)
    case commit(repo: String, sha: String)
    /// A text block at two moments of its log (`to` nil: as it is now).
    case versions(block: BlockID, from: Stamp, to: Stamp?)
}

/// A diff block: the subject, and the texts (or the patch) the host read
/// for it, kept in the log so the block is a record of what was compared.
public struct DiffState: Codable, Equatable, Sendable {
    public var subject: DiffSubject?
    public var oldText: String?
    public var newText: String?
    public var patch: String?
    public var error: String?
    public var loadedAt: Stamp?
    public init() {}
}

// MARK: Web

public struct WebState: Codable, Equatable, Sendable {
    public var url: String?
    /// Loaded from the client's network, or through the host (§7.6).
    public var viaHost = false
    public var title: String?
    public init() {}
}

// MARK: Arrangement

/// One appearance of a block in an arrangement.
public struct Placement: Codable, Equatable, Hashable, Sendable, Identifiable {
    public var id: PlacementID
    public var block: BlockID
    public var lens: Lens
    /// When it was placed: the `placed` edge's stamp, kept with the state
    /// so it outlives the log entry.
    public var placedAt: Stamp?

    enum CodingKeys: String, CodingKey { case id, block, lens, placedAt }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(PlacementID.self, forKey: .id)
        block = try c.decode(BlockID.self, forKey: .block)
        lens = try c.decode(Lens.self, forKey: .lens)
        placedAt = try? c.decodeIfPresent(Stamp.self, forKey: .placedAt)
    }

    public init(id: PlacementID = ULID.make(), block: BlockID, lens: Lens, placedAt: Stamp? = nil) {
        self.id = id
        self.block = block
        self.lens = lens
        self.placedAt = placedAt
    }
}

/// The layouts an arrangement had before §3.1 was simplified: kept so
/// older logs' `layout` entries still decode; never applied.
public enum ArrangementLayout: String, Codable, Sendable {
    case stacks, tiling, list
}

/// A grid (§3.1): columns of tiles, every tile a placement and all of
/// them visible, as acme tiles its windows. (Older logs' layouts and a
/// column's `shown` are decoded and ignored.)
public struct ArrangementState: Codable, Equatable, Sendable {
    public var title: String?
    public var columns: [[Placement]] = []
    /// Each column's share of the width; sums to 1.
    public var fractions: [Double] = []
    /// Each tile's share of its column's height; a column's sum to 1.
    public var heights: [PlacementID: Double] = [:]
    public var focused: PlacementID?

    enum CodingKeys: String, CodingKey { case title, columns, fractions, heights, focused }

    public init() {}

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        title = try c.decodeIfPresent(String.self, forKey: .title)
        columns = try c.decodeIfPresent([[Placement]].self, forKey: .columns) ?? []
        fractions = try c.decodeIfPresent([Double].self, forKey: .fractions) ?? []
        heights = (try? c.decodeIfPresent([PlacementID: Double].self, forKey: .heights)) ?? [:]
        focused = try c.decodeIfPresent(PlacementID.self, forKey: .focused)
        normalize()
    }

    /// Named arrangements are kept (§3.3).
    public var isNamed: Bool { !(title ?? "").isEmpty }

    public var placements: [Placement] { columns.flatMap { $0 } }
    public var isEmpty: Bool { columns.allSatisfy(\.isEmpty) }

    public func placement(_ id: PlacementID) -> Placement? { placements.first { $0.id == id } }

    /// The column (and index in it) holding a placement.
    public func locate(_ id: PlacementID) -> (column: Int, index: Int)? {
        for (c, column) in columns.enumerated() {
            if let i = column.firstIndex(where: { $0.id == id }) { return (c, i) }
        }
        return nil
    }

    public func columnIndex(of id: PlacementID) -> Int? { locate(id)?.column }

    /// What shows: everything, in column order, top to bottom.
    public var visible: [Placement] { placements }

    public var focusedPlacement: Placement? {
        placements.first { $0.id == focused } ?? placements.first
    }

    /// The column the focus is in (acme's active column), else the last.
    public var focusedColumn: Int? {
        if let f = focused, let c = columnIndex(of: f) { return c }
        return columns.isEmpty ? nil : columns.count - 1
    }

    /// A tile's share of its column.
    public func height(of id: PlacementID) -> Double {
        guard let (c, _) = locate(id) else { return 0 }
        return heights[id] ?? 1 / Double(columns[c].count)
    }

    /// The biggest tile of a column: where a new one takes its lower half.
    public func biggestTile(inColumn c: Int) -> Placement? {
        guard c >= 0, c < columns.count else { return nil }
        return columns[c].max { height(of: $0.id) < height(of: $1.id) }
    }

    public func placements(of block: BlockID) -> [Placement] { placements.filter { $0.block == block } }

    static func equalFractions(_ n: Int) -> [Double] {
        n == 0 ? [] : Array(repeating: 1 / Double(n), count: n)
    }

    public mutating func normalize() {
        columns.removeAll(where: \.isEmpty)
        if fractions.count != columns.count || fractions.contains(where: { !($0 > 0) }) {
            fractions = Self.equalFractions(columns.count)
        }
        // Every tile has a share, and each column's sum to 1.
        var fixed: [PlacementID: Double] = [:]
        for column in columns {
            let shares: [Double?] = column.map { heights[$0.id].flatMap { $0 > 0 ? $0 : nil } }
            let known = shares.compactMap { $0 }
            let missing = shares.filter { $0 == nil }.count
            let left = max(0, 1 - known.reduce(0, +))
            var out = shares.map { $0 ?? (missing > 0 ? max(left / Double(missing), 0.05) : 0) }
            let sum = out.reduce(0, +)
            if sum > 0 { out = out.map { $0 / sum } }
            for (p, h) in zip(column, out) { fixed[p.id] = h }
        }
        heights = fixed
        if let f = focused, placement(f) == nil { focused = nil }
        if focused == nil { focused = placements.first?.id }
    }
}

// MARK: Block

/// A block's state, built from its log by `apply`.
public struct Block: Codable, Equatable, Sendable, Identifiable {
    public var id: BlockID
    public var kind: BlockKind
    public var created: Stamp
    public var title: String?
    /// For a file, folder or image: its path on its host.
    public var path: String?
    public var text: TextState?
    public var terminal: TerminalState?
    public var directory: DirectoryState?
    public var web: WebState?
    public var search: SearchState?
    public var git: GitState?
    public var diff: DiffState?
    public var processes: ProcessState?
    public var arrangement: ArrangementState?
    /// Status records by id (§3.7); the root record under `rootStatusID`.
    public var status: [String: StatusRecord]?
    /// What each placement's lens needs to come back as it was — scroll
    /// position, selection, zoom, a filter — by placement, as the lens
    /// keeps it (§3.5): in the log, so it survives a restart and a move
    /// between lenses, like the editor's selection does.
    public var views: [PlacementID: [String: String]]?

    public init(id: BlockID, kind: BlockKind, created: Stamp, title: String? = nil, path: String? = nil) {
        self.id = id
        self.kind = kind
        self.created = created
        self.title = title
        self.path = path
        switch kind {
        case .text: text = TextState()
        case .terminal, .agent: terminal = TerminalState()
        case .process: processes = ProcessState()
        case .directory: directory = DirectoryState()
        case .web: web = WebState()
        case .search: search = SearchState()
        case .git: git = GitState()
        case .diff: diff = DiffState()
        case .arrangement: arrangement = ArrangementState()
        default: break
        }
    }

    /// What to call it: its title, the program's title, its file's name, or
    /// its kind.
    public var displayTitle: String {
        if let title, !title.isEmpty { return title }
        if let t = terminal?.title, !t.isEmpty { return kind == .agent && !t.lowercased().contains("agent") && !t.lowercased().contains("claude") ? "Agent: \(t)" : t }
        if let t = web?.title, !t.isEmpty { return t }
        if let q = search?.query { return "“\(q.text)” in \(q.root.lastPathComponent.isEmpty ? q.root : q.root.lastPathComponent)" }
        if kind == .git, let path { return path.lastPathComponent + (git?.branch.map { " (\($0))" } ?? "") }
        if let subject = diff?.subject {
            switch subject {
            case let .sides(old, new):
                let name = new.path.lastPathComponent
                let from = old.revision ?? "working tree", to = new.revision ?? "working tree"
                return "\(name): \(from) → \(to)"
            case let .commit(_, sha):
                let first = diff?.patch?.split(separator: "\n").first(where: { $0.hasPrefix("    ") })?.trimmingCharacters(in: .whitespaces)
                return first.map { "\(sha.prefix(7)) \($0)" } ?? String(sha.prefix(7))
            case let .versions(_, from, to):
                let f = DateFormatter()
                f.dateStyle = .short
                f.timeStyle = .short
                let name = path?.lastPathComponent ?? "Note"
                return "\(name): \(f.string(from: from.date)) → \(to.map { f.string(from: $0.date) } ?? "now")"
            }
        }
        if let path { return path.lastPathComponent }
        if kind == .arrangement, let a = arrangement, !a.isEmpty {
            return "Untitled"
        }
        return kind.defaultTitle
    }

    /// The block's own status (§3.7): its root record; else, for a
    /// terminal with something in the foreground that says nothing,
    /// working without saying how far; else idle.
    public var statusRecord: StatusRecord? {
        if let r = status?[rootStatusID] { return r }
        if let t = terminal, t.busy { return StatusRecord(state: .working, at: created) }
        return nil
    }

    public var statusState: StatusState { statusRecord?.state ?? .idle }

    /// The records under an id, the id itself included.
    public func statusRecords(under id: String) -> [String] {
        (status ?? [:]).keys.filter { $0 == id || id.isEmpty || $0.hasPrefix(id + "/") }
    }

    /// Not reconstructible from the log: never collected (§2.3).
    public var isHeld: Bool {
        if let text { return text.isDirty && path != nil }
        if let terminal { return terminal.busy }
        return false
    }

    /// Where it is, for finding it: a folder, or a working directory.
    public var place: String? {
        if let path { return path.deletingLastPathComponent }
        return terminal?.cwd
    }
}
