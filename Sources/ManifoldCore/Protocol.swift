import Foundation

/// Bumped whenever the messages below change incompatibly — which includes
/// a type the server decodes gaining a value (a theme, a block kind): a
/// server from before it would read the value as its default and hand
/// every client that default back, so the app asks for it to be restarted.
public let protocolVersion = 58

/// What this build's server can do beyond its protocol (`welcome`'s
/// `features`).
public let serverFeatures = ["zstd"]

/// The app (the command, agents' hooks) talks to the server over its Unix
/// socket, in frames: a 4-byte big-endian payload length, a kind byte, then
/// the payload. The first frame on a connection, or on one of its streams
/// (`Mux`), says what it is: a `hello` (the app), an `attach` (a terminal),
/// a `tunnel`, a file.
public enum FrameKind: UInt8, Sendable {
    /// A `ClientMessage` or `ServerMessage`, as `Codec` encodes it.
    case message = 1
    /// Terminal bytes: what's typed, from the app; output, from the server.
    case data = 2
    /// A terminal size: cols then rows, 2 bytes each, big-endian.
    case resize = 3
    /// Sent by the server after it has replayed a session's recent output.
    case replayDone = 4
    /// Where a terminal's history has got to (`HistoryMark`): after output
    /// that scrolled rows into it, and after a screen sent whole (an attach,
    /// a catch-up), whose history comes after, by backfill.
    case historyMark = 5
    /// How the terminal's pty takes what's typed (`TTYMode`): sent to an
    /// attachment that asked (`AttachRequest.ttyModes`) when it attaches and
    /// whenever it changes.
    case ttyMode = 7
    /// One stream's part of the connection (`Mux`): a 4-byte stream id, an
    /// op (open, a frame, close, credit), then the op's bytes — for a
    /// frame, the stream's own frame, encoded.
    case stream = 8
    /// How many bytes of paced streams' frames have been received, in all
    /// (8 bytes): the sender's measure of the link.
    case linkAck = 9
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

    public static func message<T: Encodable>(_ value: T) -> Frame {
        Frame(.message, try! Codec.encode(value))
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
        guard kind == .message else { return nil }
        return try? Codec.decode(type, from: payload)
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
        guard n <= 256 << 20 else { throw ProtocolError.frameTooLarge }
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

/// What a client asks of a host that only the host can do (its files, its
/// processes, its own shards), answered with `done`, and with entries or a
/// proposal back.
/// What a path is on its host.
public enum PathKind: String, Codable, Sendable {
    case file, folder
}

public enum Proposal: Codable, Sendable {
    /// Makes a terminal block, with a shell started when it's attached to.
    case newTerminal(block: BlockID, cwd: String?)
    case endTerminal(BlockID)
    /// Reads the file a text block names; the host proposes its content.
    case readFile(BlockID)
    /// Writes a text block's text to its file as the host has it at
    /// `version` — the client's edits up to it come first, on the same
    /// link, so the text isn't sent again; the host proposes `clean`.
    /// Refused if the host's copy isn't at that version.
    case writeFile(BlockID, version: Int)
    /// Makes (or finds) the directory block for a path, and lists it.
    case directory(block: BlockID, path: String)
    case listDirectory(BlockID)
    /// The host's workspaces, in order (§8.2): one added, taken off, or moved.
    case workspaces(order: [BlockID])
    /// The host's settings, as the client sets them.
    case settings(Settings)
    /// The host's own preferences; refused (and not kept) when the host
    /// can't do as they say.
    case preferences(HostPreferences)
    /// Look again for the known agents on the host (it does so on its own
    /// when a client says hello, too).
    case indexAgents
    case seen([BlockID])
    /// The user attended to a block (focused it): its done or error
    /// status is dismissed (§3.7).
    case attend(BlockID)
    /// The user cleared a block's status: whatever it reported is gone
    /// until it reports again.
    case clearStatus(BlockID)
    /// Kept, or let go (§4): a root of its own.
    case pin(BlockID, Bool)
    /// Another host's reference to a block here, taken or released (§4).
    case hold(Hold)
    case release(String)
    /// A block gone for good — an outline whose tile closed: its log
    /// deleted, unregistered, every replica told.
    case discard(BlockID)
    case link(Link)
    case unlink(String)
    /// Reset Graph: every link on the host and its trail forgotten.
    case resetGraph
    /// The whole history of a shard, for scrubbing.
    case history(ShardID)
    /// The command's `open --wait` is done: what it opened was put away.
    case openDone(id: Int, client: Int)
    /// The app's answer to a `mani` command (`ManiRequest`), passed on to
    /// the client that asked: some of what it prints, and, last, its status.
    case commandReply(id: Int, client: Int, ManiReply)
    /// Typed into a terminal's shell, as if at its keyboard (`mani run`).
    case input(block: BlockID, text: String)
    /// A panel widget's command (§7.8), run on the panel's host with what
    /// happened (`event`, JSON) in its environment.
    case runPanel(block: BlockID, command: String, event: String)
    /// Which language servers to run for which files (the app's settings,
    /// given to every host).
    case languageServers([LanguageServerConfig])
    /// A question for the language server of a block's file.
    case lsp(LSPRequest)
    /// Edits applied to a file on the host that isn't open as a block (a
    /// rename across files).
    case editFile(path: String, edits: [TextEdit])
    /// The text blocks placed in the client's arrangements: open with
    /// their language servers while they are.
    case editing([BlockID])
    /// Look for something in files on the host, in a search block (made
    /// if it's new); the hits come as entries.
    case search(block: BlockID, query: SearchQuery)
    /// Stop looking.
    case cancelSearch(block: BlockID)
    /// A git block for the repository holding `path` (made if new),
    /// refreshed.
    case git(block: BlockID, path: String)
    case refreshGit(block: BlockID)
    /// An Interactive Smartlog block for the Sapling repository holding
    /// `path` (made if new): the host's `sl web` started (or the one
    /// running found), and where it serves said in the block.
    case smartlog(block: BlockID, path: String)
    /// A diff block (made if new), its texts read.
    case diff(block: BlockID, subject: DiffSubject)
    case reloadDiff(block: BlockID)
    /// A terminal command's output captured as a block of its own (§3.8):
    /// the host's copy of what the terminal received for it, or, gone
    /// from the host's buffer, `fallback` (the text as the screen shows it).
    case captureOutput(block: BlockID, terminal: BlockID, command: Int, fallback: String)
    /// An agent: a terminal block that runs `command` instead of a shell.
    case newAgent(block: BlockID, cwd: String?, command: String)
    /// A process block (made if new), listed; listed again.
    case processes(block: BlockID)
    /// Send a signal to a process on the host.
    case signal(pid: Int32, signal: Int32)
    /// A folder's entries, ignored ones marked (§7.4), answered with `listing`.
    case listFolder(path: String)
    /// What each path is on the host — a file, a folder, or nothing —
    /// answered with `pathKinds`: for telling which of the names a
    /// terminal shows are files there (§3.8). A path starting with ~ is
    /// from the host's home.
    case lookUpPaths(paths: [String])
    /// The tree under a folder, less what's ignored, as paths relative to
    /// it: `limit` files at most; answered with `listing`.
    case listTree(path: String, limit: Int)
    /// A folder made, with those on the way.
    case makeFolder(path: String)
    /// A file as a revision (a commit, a tree) has it, as a block of its own
    /// to read: made if new.
    case showRevision(block: BlockID, repo: String, path: String, revision: String, title: String)
    /// A file or folder moved (renamed) on the host; `replace`: over what's
    /// there, else failing ("exists").
    case movePath(from: String, to: String, replace: Bool)
    /// An agent's turn as a block of its own (§3.8), linked from the agent
    /// and to what the turn changed; made if new, refreshed if not.
    case captureTurn(block: BlockID, agent: BlockID, turn: Int)
    /// An agent's turn undone: its changes to the working tree applied in
    /// reverse (failing, and saying so, where later work is in the way).
    case undoTurn(agent: BlockID, turn: Int)
    /// A shell notebook made, one empty cell in it, its shell started in
    /// `cwd` (§7.7).
    case newNotebook(block: BlockID, cwd: String?)
    /// A notebook's cells changed as the user edits them.
    case editNotebook(block: BlockID, edit: NotebookEdit)
    /// Cells run, in order, after any running or waiting.
    case runCells(block: BlockID, cells: [String])
    /// The running cell interrupted (^C), those waiting dropped; asked
    /// again while it runs, its program killed.
    case interruptNotebook(block: BlockID)
    /// The notebook's shell ended and a fresh one started.
    case restartNotebook(block: BlockID)
    /// The notebook's shell started if it isn't running.
    case startNotebook(block: BlockID)
}

/// One item of a tree on a file stream (§8): where it is under the tree's
/// root ("" for the root itself), what it is, how big, its permissions,
/// when it was modified, and, for a link, where it points.
public struct TreeEntry: Codable, Sendable, Equatable {
    public enum Kind: String, Codable, Sendable { case file, directory, symlink }
    public var path: String
    public var kind: Kind
    public var size: Int64
    public var mode: UInt16
    public var modified: Double
    public var target: String?

    public init(path: String, kind: Kind, size: Int64 = 0, mode: UInt16 = 0o644, modified: Double = 0, target: String? = nil) {
        self.path = path
        self.kind = kind
        self.size = size
        self.mode = mode
        self.modified = modified
        self.target = target
    }

    /// A path under a root that stays under it: relative, no "..".
    public var isSafe: Bool {
        !path.hasPrefix("/") && !path.split(separator: "/").contains("..")
    }

    /// What's under `root` (the root first; a folder before what's in it),
    /// links not followed. Nil if the root can't be read.
    public static func walk(_ root: String) -> [TreeEntry]? {
        let fm = FileManager.default
        func entry(_ full: String, _ rel: String) -> TreeEntry? {
            guard let a = try? fm.attributesOfItem(atPath: full) else { return nil }
            let type = a[.type] as? FileAttributeType
            let mode = UInt16(truncatingIfNeeded: (a[.posixPermissions] as? NSNumber)?.intValue ?? 0o644)
            let modified = (a[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
            switch type {
            case .typeDirectory?: return TreeEntry(path: rel, kind: .directory, mode: mode, modified: modified)
            case .typeSymbolicLink?: return TreeEntry(path: rel, kind: .symlink, mode: mode, modified: modified, target: try? fm.destinationOfSymbolicLink(atPath: full))
            case .typeRegular?: return TreeEntry(path: rel, kind: .file, size: (a[.size] as? NSNumber)?.int64Value ?? 0, mode: mode, modified: modified)
            default: return nil // sockets, devices: not copied
            }
        }
        guard let top = entry(root, "") else { return nil }
        var out = [top]
        func descend(_ dir: String, _ rel: String) {
            guard let names = try? fm.contentsOfDirectory(atPath: dir) else { return }
            for name in names.sorted() {
                let full = dir + "/" + name, r = rel.isEmpty ? name : rel + "/" + name
                guard let e = entry(full, r) else { continue }
                out.append(e)
                if e.kind == .directory { descend(full, r) }
            }
        }
        if top.kind == .directory { descend(root, "") }
        return out
    }

    /// The bytes all its files hold.
    public static func total(_ entries: [TreeEntry]) -> Int64 {
        entries.reduce(0) { $0 + ($1.kind == .file ? $1.size : 0) }
    }
}

/// How a file is written (an image kept, `saveImage`): a new file (failing if one is there), over
/// whatever is there, onto the end of what's there, or a new file under
/// the name or, taken, the first free "name 2", "name 3"…
public enum WriteMode: String, Codable, Sendable {
    case create, replace, append, unique
}

/// What a host asks the leader of a shard to append.
public enum HostProposal: Codable, Sendable {
    case content(String, encoding: String, lineEnding: String, fingerprint: String)
    case clean(version: Int, fingerprint: String)
    case stale
    case unreadable
}

public enum ClientMessage: Codable, Sendable {
    case hello(version: Int, name: String)
    /// Is the host there? Answered with `pong` at once (§8): a client
    /// over a pipe that hangs learns so.
    case ping
    /// Entries the client appended as a shard's owner.
    case append(shard: ShardID, entries: [Entry])
    /// The client wants the pen for a shard it may lead (§8.2): it focused
    /// the block. The host hands it over, fencing the last owner.
    case own(shard: ShardID)
    /// The client's copy of a shard fell out of step (entries that don't
    /// follow, a text that should be in and isn't): the host sends its
    /// snapshot.
    case resync(shard: ShardID)
    case propose(id: Int, Proposal)
    case attach(AttachRequest)
    /// A terminal's history after its screen (`BackfillRequest`), the first
    /// frame on a stream of its own.
    case backfill(BackfillRequest)
    /// Asks the server to exit, ending every session.
    case shutdown
    /// A `mani` command the app does (`ManiRequest`): answered with
    /// `commandReply`s, the last with its status — or `done`, with why
    /// not, when there's no app.
    case command(id: Int, ManiRequest)
    /// `mani diff`: a patch read from its input, shown as a diff block
    /// (its files opened against `root`, the command's directory).
    case openPatch(id: Int, patch: String, root: String, title: String?, beside: BlockID?)
    /// An agent's hook (`mani agent`): what happened in the agent
    /// running in `block`. A connection's one message, with no hello.
    case agent(block: BlockID, AgentEvent)
    /// A stream's first frame: a forwarded port's connection (§8). The host
    /// connects to `port` on its own loopback, and `data` frames carry the
    /// bytes both ways; an empty one says that side is done sending.
    case tunnel(port: Int)
    /// A stream's first frame: a file's bytes from `offset`, `length` of
    /// them at most (all, if nil), come down it as `data` frames, then
    /// `end` — or only `end`, saying why not (unreadable; bigger than
    /// `limit`, if given).
    case readFile(path: String, offset: Int64, length: Int64?, limit: Int64?)
    /// A stream's first frame: a file or folder (all under it) comes down
    /// the stream as a tree (`TreeMessage`: its total, each item and a
    /// file's bytes, then `done`), or `end` says why not.
    case readTree(path: String)
    /// A stream's first frame: a tree goes up the stream as `readTree`'s
    /// comes down, and is put at `path` once all of it has come — over
    /// what's there if `replace`, else failing ("exists"); answered `end`.
    case writeTree(path: String, replace: Bool)
    /// A stream's first frame: a file or folder copied within the host,
    /// from `from` to `to` (over what's there if `replace`, else failing),
    /// its `progress` said as it goes, then `end`.
    case copyTree(from: String, to: String, replace: Bool)
    /// A stream's first frame: an image put in a text (pasted, dropped,
    /// from an iPhone's camera), its bytes up the stream as `writeFile`'s,
    /// kept as `name` in `folder` (beside a Markdown file) or in
    /// Manifold's own folder for a note — "name 2" if it's taken — and an
    /// image block made for it.
    case saveImage(block: BlockID, name: String, folder: String?)
}

/// A terminal's input typed lately, from byte `from` of all it's typed.
public struct InputResume: Codable, Sendable {
    public var from: UInt64
    public var data: Data
    public init(from: UInt64, data: Data) {
        self.from = from
        self.data = data
    }
}

/// How a terminal's pty takes what's typed, as its program set it: whether
/// it gathers it into lines (canonical: the kernel's own editing — `cat`,
/// `read`; off: raw, for a program that edits and echoes for itself — a
/// shell's line editor, a full-screen program); whether the kernel echoes
/// it (off with lines gathered: a password); and whether a backspace
/// echoes as erasing.
public struct TTYMode: OptionSet, Equatable, Sendable {
    public let rawValue: UInt8
    public init(rawValue: UInt8) { self.rawValue = rawValue }
    public static let echo = TTYMode(rawValue: 1)
    public static let canonical = TTYMode(rawValue: 2)
    public static let echoErase = TTYMode(rawValue: 4)

    public var frame: Frame { Frame(.ttyMode, Data([rawValue])) }
    public init?(_ frame: Frame) {
        guard frame.kind == .ttyMode, let b = frame.payload.first else { return nil }
        rawValue = b
    }
}

/// Where a terminal's history (its primary screen's scrollback, as the host
/// keeps it) has got to: how many rows have ever scrolled into it, counted
/// in the host's terminal of this `epoch` (a new one when the terminal is
/// made again or reflowed to a new width, renumbering its rows). `screen`:
/// sent right after a screen sent whole, everything above which is history
/// the app may not have — its backfill.
public struct HistoryMark: Equatable, Sendable {
    public var epoch: UInt64
    public var end: UInt64
    public var screen: Bool

    public init(epoch: UInt64, end: UInt64, screen: Bool) {
        self.epoch = epoch
        self.end = end
        self.screen = screen
    }

    public var frame: Frame {
        var d = Data(capacity: 17)
        withUnsafeBytes(of: epoch.bigEndian) { d.append(contentsOf: $0) }
        withUnsafeBytes(of: end.bigEndian) { d.append(contentsOf: $0) }
        d.append(screen ? 1 : 0)
        return Frame(.historyMark, d)
    }

    public init?(_ frame: Frame) {
        let p = frame.payload
        guard frame.kind == .historyMark, p.count == 17 else { return nil }
        func u64(_ at: Int) -> UInt64 { p[p.startIndex + at..<p.startIndex + at + 8].reduce(0) { $0 << 8 | UInt64($1) } }
        epoch = u64(0)
        end = u64(8)
        screen = p[p.startIndex + 16] != 0
    }
}

/// A terminal's history rows asked for after its screen (§8), on a stream of
/// their own at a lower priority than the terminal's: rows `from` to `to`
/// of the host's terminal of `epoch`, at most `limit` of them (the newest).
/// They come newest first, in pieces: each a data frame of the first and
/// end rows it holds (8 bytes each), the width it's drawn at (2 bytes),
/// then the rows as escape sequences, ending with a newline unless the last
/// row goes on in the row after it (the stream compressed, `Mux`, where it
/// can be); then `replayDone` (all there is) and
/// the stream closes. Closed without it, the rest may be asked for again.
public struct BackfillRequest: Codable, Sendable {
    public var block: BlockID
    public var epoch: UInt64
    public var from: UInt64
    public var to: UInt64
    public var limit: UInt64

    public init(block: BlockID, epoch: UInt64, from: UInt64, to: UInt64, limit: UInt64) {
        self.block = block
        self.epoch = epoch
        self.from = from
        self.to = to
        self.limit = limit
    }
}

public struct AttachRequest: Codable, Sendable {
    public var block: BlockID
    public var cols: UInt16
    public var rows: UInt16
    /// Terminal-related variables from the attaching terminal (TERM and the
    /// like), used if the attach starts a new session.
    public var env: [String: String]
    /// The terminal was attached before and still shows what it did (its
    /// host's link went and came back): it's caught up with the screen as
    /// it is, its own history kept, not sent a whole snapshot.
    public var resume: Bool?
    /// The pty's modes wanted (`FrameKind.ttyMode`): an app that knows them
    /// says so (one from before would take the frame for a broken one).
    public var ttyModes: Bool?
    /// The terminal's input numbered (`InputResume`): which it is, so the
    /// host counts what it takes of it; and, attaching again after the
    /// link went, what it typed lately — the host writes what it hasn't
    /// taken yet, so a keystroke sent into a dying link isn't lost, nor
    /// one that arrived written twice.
    public var inputID: String?
    public var input: InputResume?

    public init(block: BlockID, cols: UInt16, rows: UInt16, env: [String: String], resume: Bool = false, ttyModes: Bool = false) {
        self.block = block
        self.cols = cols
        self.rows = rows
        self.env = env
        self.resume = resume ? true : nil
        self.ttyModes = ttyModes ? true : nil
        self.inputID = nil
        self.input = nil
    }
}

public enum ServerMessage: Codable, Sendable {
    /// `host` is the session id (§8); `label` what the host calls itself;
    /// `home` the user's folder there; `features` what it can do that a
    /// server of the same protocol from before couldn't (`zstd`: streams
    /// opened compressed, `Mux`) — none, from one before them.
    case welcome(version: Int, pid: Int32, host: HostID, label: String?, attachment: Int, home: String, snapshots: [ShardSnapshot], features: [String]? = nil)
    case pong
    case entries(shard: ShardID, entries: [Entry])
    case snapshot(ShardSnapshot)
    /// The client's append didn't continue the log, or it doesn't own the
    /// shard; a snapshot follows.
    case rejected(shard: ShardID)
    /// Another attachment took the pen for a shard (§8.2): this client
    /// stops appending to it and mirrors, until it focuses the block again.
    case fenced(shard: ShardID)
    case propose(shard: ShardID, HostProposal)
    case done(id: Int, error: String?)
    /// A shard's history: the state its (compacted) log starts from, if
    /// any, and the entries since.
    case history(shard: ShardID, base: ShardSnapshot?, entries: [Entry])
    /// A shard is gone (a block forgotten).
    case removed(shard: ShardID)
    /// A `mani` command, for the app to do and answer (`commandReply`).
    case command(id: Int, client: Int, ManiRequest)
    /// Some of what a command prints; the last says its status.
    case commandReply(id: Int, ManiReply)
    /// The client that asked for a command has gone (a `watch` ended):
    /// nothing more to say to it.
    case commandEnded(id: Int, client: Int)
    /// A block the host made at a command's asking (a patch): the app
    /// places it and answers the command.
    case show(id: Int, client: Int, block: BlockID, beside: BlockID?)
    /// A language server's diagnostics for a block, as they stand.
    case diagnostics(BlockID, [Diagnostic])
    /// The answer to a `lsp` proposal.
    case lspResult(id: Int, LSPResult)
    /// A language server's state: starting, ready, or gone, with a word.
    case languageServer(language: String, root: String, state: String)
    /// How a text block's lines stand against what's committed.
    case gutter(BlockID, [GutterMark])
    /// A file stream's last word: done (`path`, the file written, for a
    /// write), or why not.
    case end(error: String?, path: String?)

    /// Entries for `listFolder` or `listTree`; nil if the folder couldn't
    /// be read; `complete` false when the tree had more than asked for.
    case listing(id: Int, entries: [DirectoryEntry]?, complete: Bool)
    /// What `lookUpPaths` asked, path by path, in order (nil: nothing
    /// there); fewer than asked when the host ran out of time looking.
    case pathKinds(id: Int, [PathKind?])
    /// What a notebook's running cell has printed so far (its end, if
    /// long): sent as it comes, not kept; the cell's output is written
    /// when it ends (§7.7).
    case notebookLive(block: BlockID, cell: String, output: String)
    /// A terminal's program is reading a password (its terminal not
    /// echoing, lines edited): the Mac's keyboard kept from other apps
    /// while it is (§9). Said as it changes, not kept.
    case passwordInput(block: BlockID, Bool)
}

/// A `mani` command as the app is asked to do it: the command and what it
/// was given, parsed (`Mani.parse`), where it was run, and its input.
public struct ManiRequest: Codable, Sendable, Equatable {
    public var verb: String
    public var flags: [String: String]
    public var args: [String]
    /// The command's working directory, on its host.
    public var cwd: String
    /// The terminal block it was run in, if one of Manifold's.
    public var here: BlockID?
    /// What it read from its input, for a command that takes it.
    public var input: String?

    public init(verb: String, flags: [String: String], args: [String], cwd: String, here: BlockID?, input: String? = nil) {
        self.verb = verb
        self.flags = flags
        self.args = args
        self.cwd = cwd
        self.here = here
        self.input = input
    }
}

/// Some of what a `mani` command prints: to its output, to its errors;
/// with `status`, the last of it.
public struct ManiReply: Codable, Sendable, Equatable {
    public var out: String
    public var err: String
    public var status: Int32?

    public init(out: String = "", err: String = "", status: Int32? = nil) {
        self.out = out
        self.err = err
        self.status = status
    }
}
