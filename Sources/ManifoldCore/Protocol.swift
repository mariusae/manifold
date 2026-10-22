import Foundation

/// Bumped whenever the messages below change incompatibly — which includes
/// a type the server decodes gaining a value (a theme, a block kind): a
/// server from before it would read the value as its default and hand
/// every client that default back, so the app asks for it to be restarted.
public let protocolVersion = 40

/// The app and the attach helper both talk to the server over its Unix
/// socket, in frames: a 4-byte big-endian payload length, a kind byte, then
/// the payload. The first frame on a connection says which kind it is: a
/// `hello` (the app) or an `attach` (a terminal's byte stream).
public enum FrameKind: UInt8, Sendable {
    /// A `ClientMessage` or `ServerMessage`, as `Codec` encodes it.
    case message = 1
    /// Terminal bytes: input from the attach helper, output from the server.
    case data = 2
    /// A terminal size: cols then rows, 2 bytes each, big-endian.
    case resize = 3
    /// Sent by the server after it has replayed a session's recent output.
    case replayDone = 4
    /// A forwarded port's bytes (§8), either way: a 4-byte big-endian
    /// tunnel id, then the bytes; none, the tunnel closed.
    case tunnel = 5
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

    public static func tunnel(_ id: UInt32, _ data: Data) -> Frame {
        var d = Data(capacity: 4 + data.count)
        withUnsafeBytes(of: id.bigEndian) { d.append(contentsOf: $0) }
        d.append(data)
        return Frame(.tunnel, d)
    }

    /// A tunnel frame's id and bytes.
    public var tunnel: (id: UInt32, data: Data)? {
        guard kind == .tunnel, payload.count >= 4 else { return nil }
        let b = [UInt8](payload.prefix(4))
        let id = UInt32(b[0]) << 24 | UInt32(b[1]) << 16 | UInt32(b[2]) << 8 | UInt32(b[3])
        return (id, payload.count > 4 ? payload.subdata(in: payload.startIndex + 4..<payload.endIndex) : Data())
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
public enum Proposal: Codable, Sendable {
    /// Makes a terminal block, with a shell started when it's attached to.
    case newTerminal(block: BlockID, cwd: String?)
    case endTerminal(BlockID)
    /// Reads the file a text block names; the host proposes its content.
    case readFile(BlockID)
    /// Writes a text block's text at `version` to its file; the host
    /// proposes `clean`.
    case writeFile(BlockID, version: Int, text: String)
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
    /// A diff block (made if new), its texts read.
    case diff(block: BlockID, subject: DiffSubject)
    case reloadDiff(block: BlockID)
    /// A terminal command's output captured as a block of its own (§3.8):
    /// the host's copy of what the terminal received for it, or, gone
    /// from the host's buffer, `fallback` (the text as the screen shows it).
    case captureOutput(block: BlockID, terminal: BlockID, command: Int, fallback: String)
    /// An agent: a terminal block that runs `command` instead of a shell.
    case newAgent(block: BlockID, cwd: String?, command: String)
    /// A file's bytes (an image, a PDF), answered with `bytes`.
    case readBytes(block: BlockID)
    /// A process block (made if new), listed; listed again.
    case processes(block: BlockID)
    /// Send a signal to a process on the host.
    case signal(pid: Int32, signal: Int32)
    /// A folder's entries, ignored ones marked (§7.4), answered with `listing`.
    case listFolder(path: String)
    /// The tree under a folder, less what's ignored, as paths relative to
    /// it: `limit` files at most; answered with `listing`.
    case listTree(path: String, limit: Int)
    /// A file's bytes by its path, `limit` at most, answered with `bytes`
    /// (nil when it's bigger, or unreadable).
    case readPath(path: String, limit: Int)
    /// A file's bytes from `offset`, `length` at most (fewer at its end),
    /// answered with `bytes`: a big file fetched in pieces.
    case readRange(path: String, offset: Int64, length: Int)
    /// Bytes written to a path (a file dropped on a folder, sent back from
    /// an app on this Mac), the folders on the way made; `mode` says
    /// whether it may be there already, or is being added to.
    case writePath(path: String, data: Data, mode: WriteMode)
    /// A folder made, with those on the way.
    case makeFolder(path: String)
    /// A file or folder moved (renamed) on the host; `replace`: over what's
    /// there, else failing ("exists").
    case movePath(from: String, to: String, replace: Bool)
    /// An image put in a text (pasted, dropped, from an iPhone's camera):
    /// its bytes written as `name` in `folder` (beside a Markdown file), or
    /// in Manifold's own folder for a note, and an image block made for it.
    case saveImage(block: BlockID, data: Data, name: String, folder: String?)
    /// An agent's turn as a block of its own (§3.8), linked from the agent
    /// and to what the turn changed; made if new, refreshed if not.
    case captureTurn(block: BlockID, agent: BlockID, turn: Int)
    /// An agent's turn undone: its changes to the working tree applied in
    /// reverse (failing, and saying so, where later work is in the way).
    case undoTurn(agent: BlockID, turn: Int)
    /// A forwarded port's connection (§8): the host connects to `port` on
    /// its own loopback, and `tunnel` frames carry the bytes as `id`.
    case openTunnel(id: Int, port: Int)
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

/// How `writePath` writes: a new file (failing if one is there), over
/// whatever is there, or onto the end of what a previous piece wrote.
public enum WriteMode: String, Codable, Sendable {
    case create, replace, append
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
    /// Asks the server to exit, ending every session.
    case shutdown
    /// The `manifold` command: open these, beside a block if run in one
    /// of Manifold's terminals; with `wait`, answered when they're put away.
    case open(id: Int, paths: [String], beside: BlockID?, wait: Bool)
    /// `manifold diff`: a patch read from its input, shown as a diff block
    /// (its files opened against `root`, the command's directory).
    case openPatch(id: Int, patch: String, root: String, title: String?, beside: BlockID?)
    /// An agent's hook (`manifold agent`): what happened in the agent
    /// running in `block`. A connection's one message, with no hello.
    case agent(block: BlockID, AgentEvent)
}

public struct AttachRequest: Codable, Sendable {
    public var block: BlockID
    public var cols: UInt16
    public var rows: UInt16
    /// Terminal-related variables from the attaching terminal (TERM and the
    /// like), used if the attach starts a new session.
    public var env: [String: String]

    public init(block: BlockID, cols: UInt16, rows: UInt16, env: [String: String]) {
        self.block = block
        self.cols = cols
        self.rows = rows
        self.env = env
    }
}

public enum ServerMessage: Codable, Sendable {
    /// `host` is the session id (§8); `label` what the host calls itself;
    /// `home` the user's folder there.
    case welcome(version: Int, pid: Int32, host: HostID, label: String?, attachment: Int, home: String, snapshots: [ShardSnapshot])
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
    /// The command asked for these to be opened (the app places them).
    case open(id: Int, client: Int, paths: [String], beside: BlockID?, wait: Bool)
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
    /// A file's bytes, for `readBytes`; nil if it couldn't be read.
    case bytes(id: Int, Data?)
    /// Entries for `listFolder` or `listTree`; nil if the folder couldn't
    /// be read; `complete` false when the tree had more than asked for.
    case listing(id: Int, entries: [DirectoryEntry]?, complete: Bool)
    /// What a notebook's running cell has printed so far (its end, if
    /// long): sent as it comes, not kept; the cell's output is written
    /// when it ends (§7.7).
    case notebookLive(block: BlockID, cell: String, output: String)
    /// A terminal's program is reading a password (its terminal not
    /// echoing, lines edited): the Mac's keyboard kept from other apps
    /// while it is (§9). Said as it changes, not kept.
    case passwordInput(block: BlockID, Bool)
}
