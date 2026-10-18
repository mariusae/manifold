import AppKit
import CPTY
import ManifoldCore

/// The app's attachment to a host's `manifoldd`: a replica of its shards,
/// led here for the ones the app edits (arrangements, text, the desk) and
/// followed for the rest. It starts the local server when there isn't one,
/// and starts it again if it goes away.
final class HostClient {
    enum Transport {
        /// This machine's server, over its socket; started if need be.
        case local
        /// Another machine's, over a provider's pipe to a bridge there.
        case remote(Destination, name: String)
    }

    let node = Node()
    let transport: Transport
    private(set) var clock = Clock(host: .local)
    private(set) var host = HostID.local
    private var conn: Connection?
    private var child: Child?
    private(set) var hasState = false
    private(set) var isConnected = false
    private var disconnected = false
    private var nextProposal = 1
    private var pendingProposals: [Int: (String?) -> Void] = [:]
    private var pendingLSP: [Int: (LSPResult) -> Void] = [:]
    /// What the host's language servers say about its text blocks.
    private(set) var diagnostics: [BlockID: [Diagnostic]] = [:]
    /// Each language server's state, by "language|root".
    private(set) var languageServerStates: [String: String] = [:]
    private var changeScheduled = false

    /// Called on the main queue once per turn in which something changed.
    var onChange: (() -> Void)?
    var onDisconnect: (() -> Void)?
    /// The server speaks another version of the protocol (it's from an older
    /// or newer build, still running).
    var onVersionMismatch: ((Int) -> Void)?

    /// The first welcome arrived: the host's name is known.
    var onWelcome: (() -> Void)?

    init(transport: Transport) {
        self.transport = transport
        if case let .remote(_, name) = transport {
            host = HostID(name)
            clock = Clock(host: host)
        }
        node.onChange = { [weak self] _ in self?.scheduleChange() }
    }

    var isRemote: Bool {
        if case .remote = transport { return true }
        return false
    }

    var destination: Destination? {
        if case let .remote(d, _) = transport { return d }
        return nil
    }

    /// The server executable: next to ours in the app bundle.
    static var serverExecutable: String {
        Bundle.main.executableURL!.deletingLastPathComponent().appendingPathComponent("manifoldd").path
    }

    /// The command a terminal runs to attach to a block's shell. Ghostty
    /// splits commands on spaces, so a path with spaces goes through a symlink.
    static func attachCommand(block: BlockID) -> String {
        var exe = serverExecutable
        if exe.contains(" ") {
            let link = NSTemporaryDirectory() + "manifoldd-\(getuid())"
            unlink(link)
            symlink(exe, link)
            exe = link
        }
        return "direct:\(exe) attach \(block.description)"
    }

    // MARK: Reading

    var desk: DeskState { node.desk(host) }
    var registry: Registry { node.registry(host) }
    var links: Links { node.links(host) }
    func block(_ id: BlockID) -> Block? { node.block(id) }
    func arrangement(_ id: BlockID?) -> ArrangementState? { id.flatMap { node.block($0)?.arrangement } }
    var selectedArrangement: BlockID? { desk.selected }

    /// The text block for a file on this host, if there is one.
    func textBlock(path: String) -> Block? {
        node.blocks.first { $0.kind == .text && $0.path == path }
    }

    func directoryBlock(path: String) -> Block? {
        node.blocks.first { $0.kind == .directory && $0.path == path }
    }

    // MARK: Writing

    /// Appends events to a shard the app leads: applied here at once, and
    /// sent to the host to keep and pass on.
    func append(_ events: [Event], to shard: ShardID) {
        guard !events.isEmpty else { return }
        var entries: [Entry] = []
        for e in events {
            if let entry = node.append(e, to: shard, at: clock.now()) { entries.append(entry) }
        }
        if !entries.isEmpty { conn?.send(.message(ClientMessage.append(shard: shard, entries: entries))) }
    }

    func append(_ event: Event, to shard: ShardID) { append([event], to: shard) }

    /// Asks the host to do something only it can.
    func propose(_ proposal: Proposal, done: ((String?) -> Void)? = nil) {
        let id = nextProposal
        nextProposal += 1
        if let done { pendingProposals[id] = done }
        conn?.send(.message(ClientMessage.propose(id: id, proposal)))
    }

    /// Asks the block's host's language server something.
    func lsp(_ request: LSPRequest, done: @escaping (LSPResult) -> Void) {
        guard conn != nil else { return done(.error("not attached")) }
        let id = nextProposal
        nextProposal += 1
        pendingLSP[id] = done
        conn?.send(.message(ClientMessage.propose(id: id, .lsp(request))))
    }

    // MARK: Conveniences

    /// A new, empty arrangement on the desk, selected.
    @discardableResult
    func newArrangement(title: String? = nil, select: Bool = true, after: BlockID? = nil) -> BlockID {
        let id = BlockID(host: host)
        append(.create(kind: .arrangement, title: title, path: nil), to: .block(id))
        var order = desk.order
        let index = after.flatMap { order.firstIndex(of: $0) }.map { $0 + 1 } ?? order.count
        order.insert(id, at: index)
        append(.order(order), to: .desk(host))
        if select { append(.select(id), to: .desk(host)) }
        return id
    }

    /// A new terminal block on the host, in `cwd`.
    func newTerminal(cwd: String?) -> BlockID {
        let id = BlockID(host: host)
        propose(.newTerminal(block: id, cwd: cwd))
        return id
    }

    /// The text block for a path, made (and read) if there isn't one.
    func textBlock(for path: String) -> BlockID {
        if let b = textBlock(path: path) { return b.id }
        let id = BlockID(host: host)
        append(.create(kind: .text, title: nil, path: path), to: .block(id))
        propose(.readFile(id))
        return id
    }

    func directoryBlock(for path: String) -> BlockID {
        if let b = directoryBlock(path: path) { return b.id }
        let id = BlockID(host: host)
        propose(.directory(block: id, path: path))
        return id
    }

    /// A search block on this host, looking already.
    func newSearch(_ query: SearchQuery) -> BlockID {
        let id = BlockID(host: host)
        propose(.search(block: id, query: query))
        return id
    }

    /// A note: text with no file.
    func newNote() -> BlockID {
        let id = BlockID(host: host)
        append(.create(kind: .text, title: nil, path: nil), to: .block(id))
        append(.content("", encoding: "utf-8", lineEnding: "\n", fingerprint: ""), to: .block(id))
        return id
    }

    /// A web block, at a URL.
    func newWeb(url: String) -> BlockID {
        let id = BlockID(host: host)
        append([.create(kind: .web, title: nil, path: nil), .url(url, viaHost: false)], to: .block(id))
        return id
    }

    func link(from: BlockID, to: BlockID, kind: LinkKind) {
        guard from != to else { return }
        propose(.link(Link(from: from, to: to, kind: kind, at: clock.now())))
    }

    func select(_ arrangement: BlockID?) {
        guard desk.selected != arrangement else { return }
        if let arrangement, !desk.order.contains(arrangement) {
            append(.order(desk.order + [arrangement]), to: .desk(host))
        }
        append(.select(arrangement), to: .desk(host))
    }

    func setAppearance(_ a: Appearance) { append(.appearance(a), to: .desk(host)) }
    func setSettings(_ s: Settings) { append(.settings(s), to: .desk(host)) }
    func setWindow(_ w: WindowState) { append(.window(w), to: .desk(host)) }

    // MARK: Connection

    func connect() {
        guard case .local = transport else { return reconnectRemote() }
        Paths.ensureDirectory()
        if let fd = try? UnixSocket.connect(path: Paths.socket) {
            attach(Connection(fd: fd, queue: .main))
            return
        }
        launchServer()
        var attempts = 0
        func retry() {
            attempts += 1
            if let fd = try? UnixSocket.connect(path: Paths.socket) {
                attach(Connection(fd: fd, queue: .main))
            } else if attempts < 100 {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.05, execute: retry)
            } else {
                let alert = NSAlert()
                alert.messageText = "Manifold couldn't start its server."
                alert.informativeText = "See \(Paths.log.path)."
                alert.runModal()
                NSApp.terminate(nil)
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05, execute: retry)
    }

    /// Ends the server and every session in it.
    static func stopServer() {
        guard let fd = try? UnixSocket.connect(path: Paths.socket) else { return }
        let frame = Frame.message(ClientMessage.shutdown).encoded
        _ = frame.withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }
        var b: UInt8 = 0
        _ = read(fd, &b, 1)
        close(fd)
    }

    private func launchServer() {
        let exe = Self.serverExecutable
        let pid = withCStrings([exe, "serve"]) { argv in
            mf_spawn_detached(exe, argv, Paths.log.path)
        }
        if pid < 0 { NSLog("could not start %@: %s", exe, strerror(errno)) }
    }

    /// Readies a remote host: asks what it is, installs our server if the
    /// one there isn't ours, and starts the bridge. Slow; not on the main
    /// thread.
    static func bootstrap(_ dest: Destination, name: String) throws -> Child {
        let probe = try Bootstrap.probe(dest)
        let binaryName = Bootstrap.binaryName(os: probe.os, arch: probe.arch)
        let helpers = Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers")
        var binary = helpers.appendingPathComponent(binaryName)
        if !FileManager.default.fileExists(atPath: binary.path), probe.os == "darwin", probe.arch == "arm64" {
            binary = URL(fileURLWithPath: serverExecutable)
        }
        guard let data = FileManager.default.contents(atPath: binary.path) else {
            throw RemoteError.noBinary("\(probe.os) \(probe.arch)")
        }
        if probe.hash != Bootstrap.sha256(data) {
            NSLog("installing manifoldd on %@ (%@)", dest.description, binaryName)
            try Bootstrap.upload(dest, binary: data)
        }
        return try Child.spawn(dest.invocation(Bootstrap.bridgeCommand(name: name)))
    }

    /// Takes a bridge just spawned as the connection.
    func adopt(_ child: Child) {
        self.child = child
        attach(Connection(fd: child.output, writeFD: child.input, queue: .main))
    }

    private func reconnectRemote() {
        guard case let .remote(dest, name) = transport, !disconnected else { return }
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let child = try? Child.spawn(dest.invocation(Bootstrap.bridgeCommand(name: name)))
            DispatchQueue.main.async {
                guard let self, !self.disconnected else { return }
                if let child {
                    self.adopt(child)
                } else {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 10) { self.reconnectRemote() }
                }
            }
        }
    }

    func disconnect() {
        disconnected = true
        conn?.close()
        if let child { kill(child.pid, SIGTERM) }
    }

    private func attach(_ conn: Connection) {
        conn.onFrame = { [weak self] frame in
            guard let self else { return }
            guard let message = frame.decode(ServerMessage.self) else {
                NSLog("host %@: a frame of kind %d (%d bytes) couldn't be decoded", self.host.raw, frame.kind.rawValue, frame.payload.count)
                return
            }
            if self.isRemote, ProcessInfo.processInfo.environment["MANIFOLD_DEBUG"] != nil {
                NSLog("host %@: %@", self.host.raw, String(describing: message).prefix(80).description)
            }
            self.handle(message)
        }
        conn.onClose = { [weak self] in
            guard let self else { return }
            NSLog("host %@: connection closed", self.host.raw)
            self.conn = nil
            self.isConnected = false
            if let child = self.child {
                var status: Int32 = 0
                waitpid(child.pid, &status, WNOHANG)
                self.child = nil
            }
            self.onDisconnect?()
            self.scheduleChange()
            guard !self.disconnected else { return }
            // Bring the server back; terminals re-attach once it's up.
            let delay: TimeInterval = self.isRemote ? 5 : 0.5
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { self.connect() }
        }
        conn.start()
        conn.send(.message(ClientMessage.hello(version: protocolVersion, name: "Manifold")))
        self.conn = conn
        isConnected = true
    }

    private func handle(_ message: ServerMessage) {
        switch message {
        case let .welcome(version, _, host, _, snapshots):
            if version != protocolVersion {
                NSLog("manifoldd speaks protocol %d, we speak %d", version, protocolVersion)
                onVersionMismatch?(version)
            }
            let first = !hasState
            self.host = host
            clock = Clock(host: host)
            for s in snapshots { node.load(s) }
            // Shards we had that the host no longer has (a fresh host).
            let known = Set(snapshots.map(\.shard))
            for shard in node.shards.keys where !known.contains(shard) { node.remove(shard) }
            hasState = true
            if first { onWelcome?() }
            onConnected?()
            scheduleChange()
        case let .entries(shard, entries):
            for e in entries { clock.observe(e.at) }
            if !node.apply(entries, to: shard) {
                NSLog("entries for %@ don't follow; waiting for a snapshot", shard.description)
            }
            if let block = shard.block {
                for e in entries {
                    if case .shell(.ended) = e.event { onTerminalEnded?(block) }
                }
            }
        case let .snapshot(snap):
            node.load(snap)
        case let .rejected(shard):
            NSLog("append to %@ was refused", shard.description)
        case let .propose(shard, proposal):
            lower(proposal, into: shard)
        case let .done(id, error):
            if let error { NSLog("proposal %d: %@", id, error) }
            pendingProposals.removeValue(forKey: id)?(error)
        case let .history(shard, entries):
            onHistory?(shard, entries)
        case let .removed(shard):
            node.remove(shard)
        case let .open(id, client, paths, beside, wait):
            onOpen?(id, client, paths, beside, wait)
        case let .diagnostics(block, items):
            diagnostics[block] = items
            onDiagnostics?(block)
        case let .lspResult(id, result):
            pendingLSP.removeValue(forKey: id)?(result)
        case let .languageServer(language, root, state):
            languageServerStates[language + "|" + root] = state
            onLanguageServer?(language, root, state)
        }
    }

    /// The host welcomed us (each time: a reconnection too).
    var onConnected: (() -> Void)?
    var onDiagnostics: ((BlockID) -> Void)?
    var onLanguageServer: ((String, String, String) -> Void)?

    var onHistory: ((ShardID, [Entry]) -> Void)?
    /// A terminal's shell ended (not for dormancy), while we were attached.
    var onTerminalEnded: ((BlockID) -> Void)?
    /// A `manifold` command on this host asked for paths to be opened.
    var onOpen: ((Int, Int, [String], BlockID?, Bool) -> Void)?

    /// The host asked us, as the leader, to append something.
    private func lower(_ proposal: HostProposal, into shard: ShardID) {
        guard node.has(shard) else { return }
        switch proposal {
        case let .content(text, encoding, lineEnding, fingerprint):
            append(.content(text, encoding: encoding, lineEnding: lineEnding, fingerprint: fingerprint), to: shard)
        case let .clean(version, fingerprint):
            append(.clean(version: version, fingerprint: fingerprint), to: shard)
        case .stale:
            append(.stale(true), to: shard)
        case .unreadable:
            append(.unreadable(true), to: shard)
        }
    }

    private func scheduleChange() {
        guard !changeScheduled else { return }
        changeScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.changeScheduled = false
            self.onChange?()
        }
    }
}

func withCStrings<R>(_ strings: [String], _ body: (UnsafePointer<UnsafeMutablePointer<CChar>?>) -> R) -> R {
    var ptrs: [UnsafeMutablePointer<CChar>?] = strings.map { strdup($0) }
    ptrs.append(nil)
    defer { for p in ptrs { free(p) } }
    return ptrs.withUnsafeBufferPointer { body($0.baseAddress!) }
}
