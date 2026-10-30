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
    /// Sapling's Interactive Smartlog for a repository (§7.6): the host's
    /// `sl web`, shown as a block of its own.
    case smartlog
    case process
    case agent
    /// A terminal command's output, captured as the terminal received it
    /// (§3.8): read-only, linked back to the command.
    case output
    /// A shell notebook (§7.7): cells of commands run in one shell that
    /// lives on, each with what its last run printed.
    case notebook
    /// Placements of other blocks, laid out (§3 of DESIGN.md).
    case arrangement
    /// A form made from a shell (`mani ui`): widgets an agent describes,
    /// their values, kept (§7.8).
    case ui

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
        case .smartlog: "Smartlog"
        case .process: "Processes"
        case .agent: "Agent"
        case .output: "Output"
        case .notebook: "Shell Notebook"
        case .arrangement: "Untitled"
        case .ui: "Panel"
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
    case smartlog
    case process
    case agent
    /// An arrangement as a card: its title and a small live picture.
    case card
    /// A command's output, as the terminal showed it (§3.8).
    case output
    /// A shell notebook's cells (§7.7).
    case notebook
    /// A `ui` block's widgets (§7.8).
    case ui
    /// What a block's scrubber marks — a terminal's commands, a text's
    /// headings — as a list to steer the block's tile by (§3.8).
    case outline
    /// A note (Markdown) as an outline to edit — rows, checkboxes, folds
    /// — its Markdown written back as it changes (§7.9).
    case outliner

    public init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        guard let lens = Lens(rawValue: raw == "timeline" ? "outline" : raw) else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "unknown lens \(raw)"))
        }
        self = lens
    }

    /// The lens a block of `kind` is shown with unless another is asked for.
    public static func `default`(for kind: BlockKind, path: String? = nil) -> Lens {
        switch kind {
        case .text:
            // A file is viewed until ⌘↩ edits it; a note is written in.
            return path == nil ? .editor : .preview
        case .terminal: return .terminal
        case .directory: return .directory
        case .web: return .web
        case .image: return .image
        case .pdf: return .pdf
        case .search: return .search
        case .diff: return .diff
        case .git: return .git
        case .smartlog: return .smartlog
        case .process: return .process
        case .agent: return .agent
        case .output: return .output
        case .notebook: return .notebook
        case .arrangement: return .card
        case .ui: return .ui
        }
    }

    public static func isMarkdown(_ path: String) -> Bool {
        ["md", "markdown", "mdown", "mkd", "mdx"].contains(path.pathExtension.lowercased())
    }

    /// Editing a text or viewing it: the two lenses ⌘↩ goes between.
    public var isText: Bool { self == .editor || self == .preview }

    /// How a text is shown in view mode, by its file's extension; a note
    /// (no file) is Markdown, and an extension not in the table plain text.
    public static func viewRendering(for path: String?) -> ViewRendering {
        guard let path else { return .markdown }
        return viewRenderings[path.pathExtension.lowercased()] ?? .plain
    }

    public static let viewRenderings: [String: ViewRendering] = {
        var table: [String: ViewRendering] = [:]
        for e in ["md", "markdown", "mdown", "mkd", "mdx"] { table[e] = .markdown }
        for e in ["swift", "swiftinterface", "go", "c", "h", "cc", "cpp", "hpp", "m", "mm", "rs", "zig", "py", "rb", "js", "mjs", "ts", "tsx", "jsx",
                  "java", "kt", "scala", "cs", "php", "lua", "sh", "bash", "zsh", "fish", "pl", "hs", "ml", "ex", "exs", "erl",
                  "clj", "el", "lisp", "scm", "sql", "r", "jl", "dart", "nim", "v", "sv", "vhd", "proto", "thrift", "graphql",
                  "json", "yaml", "yml", "toml", "ini", "cfg", "conf", "xml", "html", "htm", "css", "scss", "less",
                  "make", "mk", "cmake", "dockerfile", "nix", "bzl", "gradle", "tex", "diff", "patch", "vim"] { table[e] = .code }
        return table
    }()
}

/// What a text's view mode is: Markdown rendered, or the text as it is on
/// the grey of a page of code (golang.org's) — code, or plain text.
public enum ViewRendering: Sendable, Equatable {
    case markdown, code, plain
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

    /// A file's text not yet read by its host: nothing in it, not even an
    /// empty file's (a read records the file's fingerprint, a new file's
    /// an empty one), and not found unreadable.
    public var isUnread: Bool { version == 0 && diskFingerprint == nil && !unreadable }
}

// MARK: Terminal

/// A repository's working tree at a moment, as a git tree object (§7.5).
public struct TreeSnapshot: Codable, Equatable, Sendable {
    public var repo: String
    public var tree: String
    public var at: Stamp
    public init(repo: String, tree: String, at: Stamp) {
        self.repo = repo
        self.tree = tree
        self.at = at
    }
}

/// One turn of an agent (§3.8): what was asked, the repository's working
/// tree as it began and as it ended (when it's in one), what changed, the
/// agent's last words, and where its transcript is.
public struct AgentTurn: Codable, Equatable, Sendable {
    /// The command it is, on the terminal's scrubber.
    public var id: Int
    public var agent: String
    public var prompt: String
    public var repo: String?
    public var before: String?
    public var after: String?
    /// The files it changed, relative to the repository.
    public var files: [String]?
    public var message: String?
    public var transcript: String?
    public var began: Stamp
    public var ended: Stamp?

    public init(id: Int, agent: String, prompt: String, began: Stamp) {
        self.id = id
        self.agent = agent
        self.prompt = prompt
        self.began = began
    }
}

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
    /// For an agent started in a repository: its working tree then, the
    /// whole of it, to show what the agent changed since.
    public var snapshot: TreeSnapshot?
    /// An agent's turns (§3.8), by the command each is on the scrubber.
    public var turns: [AgentTurn]?
    /// How long the last shell had been idle when it was ended, in seconds.
    public var dormantAfter: Int?
    /// The commands the shell ran (§3.8), the last `commandLimit` of them:
    /// what the scrubber marks.
    public var commands: [ShellCommand]?

    public static let commandLimit = 1000

    public init() {}
}

/// A command the shell ran, as its integration reported it: the line, when
/// it started, and how it ended.
public struct ShellCommand: Codable, Equatable, Sendable, Identifiable {
    public var id: Int
    public var text: String
    public var at: Stamp
    /// The exit status, once it has ended.
    public var status: Int32?
    public var ended: Stamp?
    /// Where the shell was as it ran the command: what the names in its
    /// line and its output are relative to. Nil for one from before
    /// commands kept it.
    public var cwd: String?

    public init(id: Int, text: String, at: Stamp, status: Int32? = nil, ended: Stamp? = nil, cwd: String? = nil) {
        self.id = id
        self.text = text
        self.at = at
        self.status = status
        self.ended = ended
        self.cwd = cwd
    }

    /// The directory a row of a terminal's names are relative to: the
    /// command's whose prompt is at or above it (by `rows`, each command's
    /// row), where it ran — so after `ls` and then `cd sub`, the names `ls`
    /// printed are still the folder's it listed. Below the last command
    /// once it has ended, the prompt the shell is at now: where it is
    /// (`current`); so too above every command, or for one that didn't
    /// keep where it ran.
    public static func directory(ofRow row: Int, commands: [ShellCommand], rows: [Int: Int], current: String?) -> String? {
        var at: (command: ShellCommand, row: Int)?
        for c in commands {
            guard let r = rows[c.id], r <= row, r >= (at?.row ?? Int.min) else { continue }
            at = (c, r)
        }
        guard let (c, r) = at else { return current }
        if c.id == commands.last?.id, c.ended != nil, row > r { return current }
        return c.cwd ?? current
    }

    public var isRunning: Bool { ended == nil }
    public var failed: Bool { (status ?? 0) != 0 }

    /// The prompt a command was typed at, as its line on the screen shows
    /// it: what comes before the command. Nil if the line doesn't show it.
    public static func prompt(onLine line: String, command: String) -> String? {
        let t = line.trimmingCharacters(in: .whitespaces)
        guard !command.isEmpty, let r = t.range(of: command) else { return nil }
        let p = t[..<r.lowerBound].trimmingCharacters(in: .whitespaces)
        return p.isEmpty ? nil : p
    }

    /// A command's output as the screen shows it (the rows to the next
    /// command's, or the end), less the next prompt at its end: lines that
    /// show the prompt the command was typed at, or end as it does (in its
    /// last word, ending in a prompt's mark: "›", "$", "❯") — the next
    /// command not typed yet, or the first lines of a prompt over several,
    /// a right prompt's host on them — and blank ones.
    /// The prompt may have changed since (its directory after a `cd`, a
    /// repository's status in it — `host repo[f]/dir›` then `host
    /// repo[f*]/sub›`): a line that begins with its first word and has its
    /// closing mark at its end, or before a command typed, is one too.
    public static func output(_ output: String, prompt: String?) -> String {
        var lines = output.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        let mark = prompt?.split(separator: " ").last.map(String.init).flatMap { w in
            w.unicodeScalars.last.map { !CharacterSet.alphanumerics.contains($0) } == true ? w : nil
        }
        let close = mark?.unicodeScalars.last.map { String($0) }
        let first = prompt?.split(separator: " ").first.map(String.init)
        // Its first word less the mark that closes it: a status put in
        // before the mark after a failure (fish's `s/manifold[127]›` for
        // `s/manifold›`) leaves the start and the mark as they were.
        let stem = first.map { w in String(w.reversed().drop { !$0.isLetter && !$0.isNumber }.reversed()) }
        func isPrompt(_ line: String) -> Bool {
            let t = line.trimmingCharacters(in: .whitespaces)
            if t.isEmpty { return true }
            if let prompt, t.contains(prompt) { return true }
            if let mark, t.hasSuffix(mark) { return true }
            if let first, let close, first != prompt, t.hasPrefix(first), t.hasSuffix(close) || t.contains(close + " ") { return true }
            if let stem, !stem.isEmpty, let close, t.hasPrefix(stem), t.hasSuffix(close) || t.contains(close + " ") { return true }
            return false
        }
        while let last = lines.last, isPrompt(last) { lines.removeLast() }
        return lines.joined(separator: "\n")
    }
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
    /// Ignored by the repository it's in (git's or Sapling's ignore rules).
    public var isIgnored: Bool?

    public init(name: String, isDirectory: Bool, size: Int64, modified: Double, isHidden: Bool, isIgnored: Bool? = nil) {
        self.name = name
        self.isDirectory = isDirectory
        self.size = size
        self.modified = modified
        self.isHidden = isHidden
        self.isIgnored = isIgnored
    }
}

public struct DirectoryState: Codable, Equatable, Sendable {
    public var entries: [DirectoryEntry] = []
    public var listedAt: Stamp?
    /// Why it couldn't be listed when last tried (it isn't there, it can't
    /// be read); nil once it is.
    public var error: String?
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
    /// The repository the root is in (git or Sapling), its root: what
    /// Expand to Project widens to. The host says it, as it runs the
    /// search — only it can look, the files being its own.
    public var project: String?

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
    /// The executable's path.
    public var path: String?
    /// The terminal or agent block whose shell it runs under (§7.5): the
    /// host lists the trees under its blocks' shells, nothing else.
    public var block: BlockID?

    public init(pid: Int32, parent: Int32, user: String, cpu: Double, memory: Int64, command: String, path: String? = nil, block: BlockID? = nil) {
        self.pid = pid
        self.parent = parent
        self.user = user
        self.path = path
        self.block = block
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

/// An Interactive Smartlog block (§7.6): a Sapling repository (the block's
/// path) and where the host's `sl web` serves its smartlog — a URL on the
/// host's own loopback — or why it can't.
public struct SmartlogState: Codable, Equatable, Sendable {
    public var url: String?
    public var error: String?
    public var startedAt: Stamp?
    public init() {}
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
    /// Two files, or a file at two revisions.
    public var isSides: Bool { if case .sides = self { true } else { false } }

    case sides(old: DiffSide, new: DiffSide)
    case commit(repo: String, sha: String)
    /// A text block at two moments of its log (`to` nil: as it is now).
    case versions(block: BlockID, from: Stamp, to: Stamp?)
    /// A patch given to `mani diff`, its paths against `root`.
    case patch(root: String, title: String?)
    /// What's changed in a repository and not yet committed, as plain
    /// `git diff` (`sl diff`) shows it: read again as the repository moves.
    case uncommitted(repo: String)
    /// Everything that's changed in a repository's working tree since a
    /// snapshot of it (`tree`, the whole tree, untracked files too, as an
    /// agent started): committed since or not, new files included.
    case since(repo: String, tree: String, title: String)
    /// A repository's working tree between two snapshots (`to` nil: as it
    /// is now): an agent's turn.
    case trees(repo: String, from: String, to: String?, title: String)
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

/// A command's output (§3.8): which terminal and command it came from,
/// the command line, how it ended, and what it printed — the bytes as the
/// terminal received them, colours and all.
public struct OutputState: Codable, Equatable, Sendable {
    public var source: BlockID?
    public var command: Int?
    public var line: String = ""
    public var status: Int32?
    public var ran: Stamp?
    public var ended: Stamp?
    /// What it printed, escape sequences and all (as UTF-8, invalid bytes
    /// replaced); `plain` says it was taken as plain text instead.
    public var output: String = ""
    public var plain = false
    /// An agent's turn, as Markdown (§3.8): what was asked, what it did,
    /// what it said, what it changed — shown rendered, not as a terminal's.
    public var markdown: String?

    public init(source: BlockID? = nil, command: Int? = nil, line: String = "", status: Int32? = nil, ran: Stamp? = nil, ended: Stamp? = nil, output: String = "", plain: Bool = false) {
        self.source = source
        self.command = command
        self.line = line
        self.status = status
        self.ran = ran
        self.ended = ended
        self.output = output
        self.plain = plain
    }

    /// What a command wrote, without what its shell wrote around it: zsh's
    /// mark for output that didn't end its line (an inverse `%` or `#`, a
    /// row of spaces and carriage returns, which the prompt then draws
    /// over), at the end.
    public static func trimmed(_ raw: String) -> String {
        guard raw.hasSuffix("\r \r") else { return raw }
        // Led only by attributes being set, so the output's own reset stays.
        let set = "(?:\u{1B}\\[[1-9][0-9;]*m)*", any = "(?:\u{1B}\\[[0-9;]*m)*"
        guard let r = try? NSRegularExpression(pattern: set + "[%#]" + any + " +\r \r\\z") else { return raw }
        let ns = raw as NSString
        guard let m = r.firstMatch(in: raw, range: NSRange(location: 0, length: ns.length)) else { return raw }
        return ns.substring(to: m.range.location)
    }
}

// MARK: Shell notebooks

/// A cell of a shell notebook (§7.7): a command, and what its last run
/// printed (escapes and all), how it ended, and when.
public struct NotebookCell: Codable, Equatable, Sendable {
    public var id: String
    public var source: String
    public var output: String?
    public var status: Int32?
    /// Its run's number in the notebook's shell, as Jupyter counts.
    public var count: Int?
    public var ran: Stamp?
    public var ended: Stamp?
    /// Only the end of a long output was kept.
    public var truncated: Bool?

    public init(id: String, source: String = "") {
        self.id = id
        self.source = source
    }

    /// A fresh id for a cell.
    public static func newID() -> String {
        let letters = Array("abcdefghijkmnpqrstuvwxyz23456789")
        return String((0..<8).map { _ in letters.randomElement()! })
    }
}

/// A shell notebook's state (§7.7): its cells, which is running and which
/// wait their turn, and its shell.
public struct NotebookState: Codable, Equatable, Sendable {
    public var cells: [NotebookCell] = []
    public var running: String?
    public var queued: [String] = []
    /// Runs so far, in this shell and the ones before it.
    public var runs = 0
    /// The shell's pid while there is one, and its name.
    public var pid: Int32?
    public var shell: String?
    public var shellStarted: Stamp?
    public init() {}

    public func cell(_ id: String) -> NotebookCell? { cells.first { $0.id == id } }

    mutating func apply(_ edit: NotebookEdit) {
        func update(_ id: String, _ f: (inout NotebookCell) -> Void) {
            if let i = cells.firstIndex(where: { $0.id == id }) { f(&cells[i]) }
        }
        switch edit {
        case let .insert(cell, at):
            guard !cells.contains(where: { $0.id == cell.id }) else { return }
            cells.insert(cell, at: max(0, min(at, cells.count)))
        case let .remove(id):
            cells.removeAll { $0.id == id }
            queued.removeAll { $0 == id }
        case let .move(id, to):
            guard let i = cells.firstIndex(where: { $0.id == id }) else { return }
            let c = cells.remove(at: i)
            cells.insert(c, at: max(0, min(to, cells.count)))
        case let .source(id, text):
            update(id) { $0.source = text }
        case let .clear(id):
            update(id) {
                $0.output = nil
                $0.status = nil
                $0.count = nil
                $0.ran = nil
                $0.ended = nil
                $0.truncated = nil
            }
        case .clearAll:
            for i in cells.indices where cells[i].id != running {
                cells[i].output = nil
                cells[i].status = nil
                cells[i].count = nil
                cells[i].ran = nil
                cells[i].ended = nil
                cells[i].truncated = nil
            }
        case let .queued(ids):
            queued = ids
        case let .started(id, count, at):
            running = id
            runs = max(runs, count)
            queued.removeAll { $0 == id }
            update(id) {
                $0.count = count
                $0.ran = at
                $0.ended = nil
                $0.status = nil
                $0.output = ""
                $0.truncated = nil
            }
        case let .finished(id, output, status, truncated, at):
            if running == id { running = nil }
            update(id) {
                $0.output = output
                $0.status = status
                $0.ended = at
                $0.truncated = truncated ? true : nil
            }
        case let .shell(pid, name, at):
            pid.map { _ in shellStarted = at }
            self.pid = pid
            if let name { shell = name }
            if pid == nil { running = nil; queued = [] }
        }
    }
}

/// A change to a shell notebook: the cells, as the user edits them
/// (proposed by the app, written by the host), and their runs and the
/// shell, as the host has them.
public enum NotebookEdit: Codable, Equatable, Sendable {
    case insert(NotebookCell, at: Int)
    case remove(String)
    case move(String, to: Int)
    case source(String, String)
    case clear(String)
    case clearAll
    case queued([String])
    case started(String, count: Int, at: Stamp)
    case finished(String, output: String, status: Int32?, truncated: Bool, at: Stamp)
    case shell(pid: Int32?, name: String?, at: Stamp)

    /// Whether the app may ask for it (the rest are the host's to say).
    public var isUsers: Bool {
        switch self {
        case .insert, .remove, .move, .source, .clear, .clearAll: true
        default: false
        }
    }
}

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
    /// Each tile's share of its column's height; a column's shown tiles'
    /// sum to 1. A share of 0 is a **stashed** tile (§3.1): not laid out,
    /// its pill bunched under the tile that fills the column, until it is
    /// unstashed.
    public var heights: [PlacementID: Double] = [:]
    public var focused: PlacementID?
    /// A tile **maximized** over the whole arrangement (§3.1), the rest
    /// hidden behind it until it is restored.
    public var full: PlacementID?

    enum CodingKeys: String, CodingKey { case title, columns, fractions, heights, focused, full }

    public init() {}

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        title = try c.decodeIfPresent(String.self, forKey: .title)
        columns = try c.decodeIfPresent([[Placement]].self, forKey: .columns) ?? []
        fractions = try c.decodeIfPresent([Double].self, forKey: .fractions) ?? []
        heights = (try? c.decodeIfPresent([PlacementID: Double].self, forKey: .heights)) ?? [:]
        focused = try c.decodeIfPresent(PlacementID.self, forKey: .focused)
        full = try? c.decodeIfPresent(PlacementID.self, forKey: .full)
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

    /// Stashed: not laid out, its pill bunched under the column's filling tile.
    public func isStashed(_ id: PlacementID) -> Bool { heights[id] == 0 }

    /// The shown tile a stashed one is behind: the nearest shown above it
    /// in its column, else the column's first shown tile.
    public func tile(behind id: PlacementID) -> Placement? {
        guard let (c, i) = locate(id) else { return nil }
        if let above = columns[c][..<i].last(where: { !isStashed($0.id) }) { return above }
        return columns[c].first { !isStashed($0.id) }
    }

    /// A column's tiles that show, and those stashed, in order.
    public func shownTiles(inColumn c: Int) -> [Placement] { columns[c].filter { !isStashed($0.id) } }
    public func stashedTiles(inColumn c: Int) -> [Placement] { columns[c].filter { isStashed($0.id) } }

    public func placements(of block: BlockID) -> [Placement] { placements.filter { $0.block == block } }

    static func equalFractions(_ n: Int) -> [Double] {
        n == 0 ? [] : Array(repeating: 1 / Double(n), count: n)
    }

    public mutating func normalize() {
        columns.removeAll(where: \.isEmpty)
        if fractions.count != columns.count || fractions.contains(where: { !($0 > 0) }) {
            fractions = Self.equalFractions(columns.count)
        }
        // Every tile has a share, and each column's shown ones sum to 1;
        // stashed tiles (0) stay so, unless a column is all stashed.
        var fixed: [PlacementID: Double] = [:]
        for column in columns {
            let shares: [Double?] = column.map { heights[$0.id].flatMap { $0 >= 0 ? $0 : nil } }
            let known = shares.compactMap { $0 }
            let missing = shares.filter { $0 == nil }.count
            let left = max(0, 1 - known.reduce(0, +))
            var out = shares.map { $0 ?? (missing > 0 ? max(left / Double(missing), 0.05) : 0) }
            var sum = out.reduce(0, +)
            if sum == 0 { out = out.map { _ in 1 }; sum = Double(out.count) }
            out = out.map { $0 / sum }
            for (p, h) in zip(column, out) { fixed[p.id] = h }
        }
        heights = fixed
        if let f = focused, placement(f) == nil { focused = nil }
        if focused == nil { focused = placements.first?.id }
        if let f = full, placement(f) == nil { full = nil }
    }
}

// MARK: Panels

/// A `ui` block's state (§7.8): its widgets, as the JSON `mani ui` was
/// given (a title and items, each a widget, some holding others), and the
/// values they hold by id, each as JSON — what's set from the shell and
/// what's changed by hand alike.
public struct UIState: Codable, Equatable, Sendable {
    public var spec = #"{"items":[]}"#
    public var values: [String: String] = [:]

    public init() {}

    public mutating func apply(_ event: Event) {
        switch event {
        case let .uiSpec(json): spec = json
        case let .uiValues(changed):
            for (k, v) in changed { values[k] = v.isEmpty ? nil : v }
        default: break
        }
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
    /// For a block with no file (a note): the folder it was made in, where
    /// it is found and where it is saved by default.
    public var home: String?
    public var text: TextState?
    public var terminal: TerminalState?
    public var directory: DirectoryState?
    public var web: WebState?
    public var search: SearchState?
    public var git: GitState?
    public var smartlog: SmartlogState?
    public var diff: DiffState?
    public var output: OutputState?
    public var notebook: NotebookState?
    public var processes: ProcessState?
    public var arrangement: ArrangementState?
    public var ui: UIState?
    /// Status records by id (§3.7); the root record under `rootStatusID`.
    public var status: [String: StatusRecord]?
    /// What each placement's lens needs to come back as it was — scroll
    /// position, selection, zoom, a filter — by placement, as the lens
    /// keeps it (§3.5): in the log, so it survives a restart and a move
    /// between lenses, like the editor's selection does.
    public var views: [PlacementID: [String: String]]?
    /// Kept (§4): a root of its own, whatever refers to it, until let go.
    public var pinned: Bool?

    public var isPinned: Bool { pinned == true }
    /// Something to attend to (§3.7): its status needs you, or finished
    /// and hasn't been read. What the Inbox lists.
    public var needsAttention: Bool { statusRecord?.wantsAttention ?? false }

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
        case .smartlog: smartlog = SmartlogState()
        case .diff: diff = DiffState()
        case .output: output = OutputState()
        case .notebook: notebook = NotebookState()
        case .arrangement: arrangement = ArrangementState()
        case .ui: ui = UIState()
        default: break
        }
    }

    /// What to call it: its title, the program's title, its file's name, or
    /// its kind.
    /// A text with nowhere on disk yet: a note.
    public var isNote: Bool { kind == .text && path == nil }

    /// What an untitled note is called: its first line that says
    /// something, read as words — images left out, a link by its words, no
    /// emphasis, heading, quote or bullet marks — at most 60 characters;
    /// nil while it says nothing. Only the text's beginning is read.
    public static func noteTitle(from text: Rope) -> String? {
        let head = text[TextRange(0, text.floorBoundary(min(text.count, 16 << 10)))]
        for line in head.split(separator: "\n").prefix(40) {
            let words = plainWords(String(line))
            if !words.isEmpty { return String(words.prefix(60)) }
        }
        return nil
    }

    /// A line of Markdown as its words.
    public static func plainWords(_ line: String) -> String {
        var s = line.replacingOccurrences(of: #"!\[[^\]]*\]\([^)]*\)"#, with: "", options: .regularExpression)
        s = s.replacingOccurrences(of: #"\[([^\]]*)\]\([^)]*\)"#, with: "$1", options: .regularExpression)
        s = s.replacingOccurrences(of: #"(\*\*|__|`)"#, with: "", options: .regularExpression)
        s = s.replacingOccurrences(of: #"^\s*(#+|>|[-*+]|\d+\.)\s+"#, with: "", options: .regularExpression)
        return s.trimmingCharacters(in: .whitespaces)
    }

    /// A file whose text has never come in from disk: nothing to show or
    /// edit yet, only to read (a block made for a file before anyone
    /// opened it, a read that went astray).
    public var needsRead: Bool {
        guard kind == .text, path != nil, let t = text else { return false }
        return t.diskFingerprint == nil && !t.unreadable && t.version == 0
    }

    /// The coding agent at work in it, if any (Claude Code, Codex…): an
    /// agent block's by the command it runs; any terminal's by what its
    /// status hooks name, or by a command still running in it that starts
    /// one.
    public var agent: AgentCatalog.Agent? {
        guard let t = terminal else { return nil }
        if let c = t.command, let a = AgentCatalog.agent(inCommand: c) { return a }
        if let app = statusRecord?.app, let a = AgentCatalog.agent(namedByApp: app) { return a }
        for c in (t.commands ?? []).reversed().prefix(5) where c.status == nil {
            if let a = AgentCatalog.agent(inCommand: c.text) { return a }
        }
        return nil
    }

    public var displayTitle: String {
        if let title, !title.isEmpty { return title }
        if let t = terminal?.title, !t.isEmpty { return kind == .agent && !t.lowercased().contains("agent") && !t.lowercased().contains("claude") ? "Agent: \(t)" : t }
        if let t = web?.title, !t.isEmpty { return t }
        if let q = search?.query { return "“\(q.text)” in \(q.root.lastPathComponent.isEmpty ? q.root : q.root.lastPathComponent)" }
        if kind == .git, let path { return path.lastPathComponent + (git?.branch.map { " (\($0))" } ?? "") }
        if kind == .smartlog, let path { return "Smartlog · " + path.lastPathComponent }
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
            case let .uncommitted(repo):
                return "Changes in \(repo.lastPathComponent)"
            case let .since(_, _, title), let .trees(_, _, _, title):
                return title
            case let .patch(_, title):
                if let title, !title.isEmpty { return title }
                let files = diff?.patch?.split(separator: "\n").filter { $0.hasPrefix("+++ ") }.count ?? 0
                return files == 1 ? "Patch, 1 file" : "Patch, \(files) files"
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
    /// The root status record (§3.7), as the program reported it: nothing
    /// is made up from a terminal being busy.
    public var statusRecord: StatusRecord? { status?[rootStatusID] }

    public var statusState: StatusState { statusRecord?.state ?? .idle }

    /// The records under an id, the id itself included.
    public func statusRecords(under id: String) -> [String] {
        (status ?? [:]).keys.filter { $0 == id || id.isEmpty || $0.hasPrefix(id + "/") }
    }

    /// Not reconstructible from the log: never collected (§2.3).

    /// Where it is, for finding it, and where a new terminal from it
    /// starts: a file's folder; a listing's or a repository's own folder;
    /// a terminal's working directory; the folder a search looks under;
    /// the folder a note was made in.
    public var place: String? {
        if let path {
            switch kind {
            case .directory, .git: return path
            default: return path.deletingLastPathComponent
            }
        }
        if let root = search?.query?.root, !root.isEmpty { return root }
        return terminal?.cwd ?? home
    }
}
