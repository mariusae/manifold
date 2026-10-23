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

        var isLocal: Bool { if case .local = self { return true } else { return false } }
    }

    let node = Node()
    let transport: Transport
    private(set) var clock = Clock(host: .local)
    private(set) var host = HostID.local
    /// What the host calls itself (§8), once it has said.
    private(set) var label: String?
    /// The control stream of the host's one connection (§8): sent to from
    /// the main thread, its frames handled there.
    private var conn: ControlChannel?
    /// The connection's own thread: frames read and written, streams
    /// carried (a terminal's straight to it), off the main thread.
    private lazy var linkQueue = DispatchQueue(label: "manifold.link.\(host.raw)", qos: .userInteractive)
    /// The connection's streams (§8): its own frames are the control
    /// stream; terminals, forwarded ports and files have streams of their own.
    private(set) var mux: Mux?
    private var child: Child?
    private(set) var hasState = false
    private(set) var isConnected = false
    private var disconnected = false
    /// The user's folder on the host, once it has said.
    private(set) var home: String?

    /// How the host stands (§8): being reached, there, or not reachable
    /// now — then what is mirrored of it is what was last seen.
    enum Standing: Equatable {
        case connecting
        case connected
        case unreachable(String?)
    }
    private(set) var link: Standing = .connecting {
        didSet {
            if link != .connecting { step = nil; reachingSince = nil; received = 0 }
            if link != oldValue { scheduleChange() }
        }
    }
    /// While the host is being reached: the step under way and when it
    /// began, so a slow attach says what it's waiting on.
    private(set) var step: (what: String, since: Date)?
    /// When this try at reaching the host began, its first step.
    private var reachingSince: Date?
    /// Bytes from the host on the connection being made, before it has
    /// answered in full.
    private var received = 0
    /// How far the step has got, of how much, where it can say.
    private var stepProgress: (done: Int, total: Int)?

    /// A step in reaching the host begins: it's connecting, at that.
    func begin(_ what: String) {
        if link != .connecting || reachingSince == nil { reachingSince = Date() }
        step = (what, Date())
        stepProgress = nil
        link = .connecting
        scheduleChange()
    }

    /// How far the step under way has got: said with it, as of the hover.
    func progress(_ done: Int, of total: Int) {
        guard step != nil else { return }
        stepProgress = (done, total)
    }

    /// What reaching the host is at and how long it has taken, as of now;
    /// nil once it's there or given up on.
    var stepDescription: String? {
        guard link == .connecting, let step else { return nil }
        func seconds(_ since: Date) -> String { String(format: "%.1f s", Date().timeIntervalSince(since)) }
        var what = step.what
        func mb(_ n: Int) -> String { ByteCountFormatter.string(fromByteCount: Int64(n), countStyle: .file) }
        if let p = stepProgress { what += " (\(mb(p.done)) of \(mb(p.total)))" }
        if received > 0 { what += " (\(ByteCountFormatter.string(fromByteCount: Int64(received), countStyle: .file)))" }
        var lines = ["\(what): \(seconds(step.since))"]
        if let reachingSince, reachingSince < step.since { lines.append("Connecting for \(seconds(reachingSince))") }
        return lines.joined(separator: "\n")
    }
    /// The last time the host answered.
    private(set) var lastHeard: Date?
    /// How long until the next try at reaching the host: doubles with
    /// each failure, from two seconds to two minutes, and starts over
    /// once the host answers.
    private var backoff: TimeInterval = 2
    private var retryWork: DispatchWorkItem?
    /// When the next try is due, while there is one.
    private(set) var nextTry: Date?

    /// Bridges that closed before the host answered, in a row: after a
    /// few, the host is bootstrapped again (its server put back) rather
    /// than bridged to.
    private var closedUnanswered = 0
    /// Set by the hosts registry: bootstrap this host again.
    var onNeedsBootstrap: (() -> Void)?

    func nextRetryDelay() -> TimeInterval {
        let delay = backoff
        backoff = min(backoff * 2, 120)
        return delay
    }

    /// A try, `delay` from now (or at once): the work is kept so Try
    /// Again Now can hurry it.
    func scheduleRetry(after delay: TimeInterval, _ work: @escaping () -> Void) {
        retryWork?.cancel()
        let item = DispatchWorkItem { [weak self] in
            self?.retryWork = nil
            self?.nextTry = nil
            work()
        }
        retryWork = item
        nextTry = Date().addingTimeInterval(delay)
        NSLog("host %@: trying again in %.0f s", host.raw, delay)
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: item)
        scheduleChange()
    }

    /// Try Again Now: whatever try was due, now.
    func retryNow() {
        guard let item = retryWork else { return }
        retryWork = nil
        nextTry = nil
        backoff = 2
        DispatchQueue.main.async(execute: item)
    }
    private var pingTimer: Timer?
    private var pongWaiters: [() -> Void] = []

    /// Debugging: how long a ping takes to be answered now, and how the
    /// pacing stands.
    func debugRoundTrip(_ done: @escaping (TimeInterval?, String) -> Void) {
        guard let conn, let mux else { return done(nil, "not connected") }
        let sent = Date()
        pongWaiters.append { done(Date().timeIntervalSince(sent), mux.debugPacing) }
        conn.send(.message(ClientMessage.ping))
    }
    private var pingSent: Date?
    private var nextProposal = 1
    private var pendingProposals: [Int: (String?) -> Void] = [:]
    private var pendingLSP: [Int: (LSPResult) -> Void] = [:]
    private var pendingListings: [Int: ([DirectoryEntry]?, Bool) -> Void] = [:]
    /// What the host's language servers say about its text blocks.
    private(set) var diagnostics: [BlockID: [Diagnostic]] = [:]
    /// How each text block stands against what's committed.
    private(set) var gutters: [BlockID: [GutterMark]] = [:]
    /// Each language server's state, by "language|root".
    private(set) var languageServerStates: [String: String] = [:]
    private var changeScheduled = false

    /// Called on the main queue once per turn in which something changed.
    var onChange: (() -> Void)?
    var onDisconnect: (() -> Void)?
    /// The server speaks another version of the protocol (it's from an older
    /// or newer build, still running).
    var onVersionMismatch: ((Int) -> Void)?
    /// A remote server of another version was told to stop, so the bridge
    /// starts the one just installed (§8.1): the version it spoke, so it's
    /// told once, not again and again should the install not take.
    private var restartedServerSpeaking: Int?
    /// The connection about to close is the server stopping for that: come back soon.
    private var serverRestarting = false

    /// The first welcome arrived: the host's name is known.
    var onWelcome: (() -> Void)?
    /// Shards another attachment took the pen for (§8.2): mirrored, not
    /// appended to, until the block is focused here again.
    private(set) var fenced: Set<ShardID> = []

    /// `known`: the host's id from the hosts file, for one remembered,
    /// so it stands in the app (unreachable, as last seen) before it says
    /// its name again.
    init(transport: Transport, known: HostID? = nil) {
        self.transport = transport
        if case let .remote(_, name) = transport {
            host = known ?? HostID(name)
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

    // MARK: Reading

    var desk: DeskState { node.desk(host) }
    var registry: Registry { node.registry(host) }
    var links: Links { node.links(host) }
    func block(_ id: BlockID) -> Block? { node.block(id) }
    func arrangement(_ id: BlockID?) -> ArrangementState? { id.flatMap { node.block($0)?.arrangement } }

    /// The text block for a file on this host, if there is one.
    func textBlock(path: String) -> Block? { block(kind: .text, path: path) }

    func directoryBlock(path: String) -> Block? { block(kind: .directory, path: path) }

    /// The block for a path, by its spelling first, then — on this
    /// machine, where it can be looked up — as the file system resolves
    /// it (/tmp and /private/tmp are one file).
    func block(kind: BlockKind, path: String) -> Block? {
        if let b = node.blocks.first(where: { $0.kind == kind && $0.path == path }) { return b }
        guard transport.isLocal else { return nil }
        let wanted = URL(fileURLWithPath: path).resolvingSymlinksInPath().path
        return node.blocks.first { b in
            guard b.kind == kind, let p = b.path else { return false }
            return URL(fileURLWithPath: p).resolvingSymlinksInPath().path == wanted
        }
    }

    // MARK: Writing

    /// Appends events to a shard the app leads: applied here at once, and
    /// sent to the host to keep and pass on.
    func append(_ events: [Event], to shard: ShardID) {
        guard !events.isEmpty, !fenced.contains(shard) else { return }
        var entries: [Entry] = []
        for e in events {
            if let entry = node.append(e, to: shard, at: clock.now()) { entries.append(entry) }
        }
        if !entries.isEmpty { conn?.send(.message(ClientMessage.append(shard: shard, entries: entries))) }
    }

    func append(_ event: Event, to shard: ShardID) { append([event], to: shard) }

    /// Takes the pen for a shard this client may lead (§8.2): on focusing
    /// its block. The host fences whoever held it.
    func own(_ shard: ShardID) {
        guard node.leader(of: shard) == .client else { return }
        fenced.remove(shard)
        conn?.send(.message(ClientMessage.own(shard: shard)))
    }

    /// Asks the host to do something only it can.
    func propose(_ proposal: Proposal, done: ((String?) -> Void)? = nil) {
        let id = nextProposal
        nextProposal += 1
        if let done { pendingProposals[id] = done }
        // A link broken can be made again at once.
        if case .unlink = proposal { recentLinks = [:] }
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

    /// A folder's entries, ignored ones marked (§7.4).
    func listFolder(_ path: String, done: @escaping ([DirectoryEntry]?) -> Void) {
        list(.listFolder(path: path)) { entries, _ in done(entries) }
    }

    /// The tree under a folder, less what's ignored, named relative to it.
    func listTree(_ path: String, limit: Int = 20_000, done: @escaping ([DirectoryEntry]?, Bool) -> Void) {
        list(.listTree(path: path, limit: limit), done: done)
    }

    private func list(_ proposal: Proposal, done: @escaping ([DirectoryEntry]?, Bool) -> Void) {
        guard conn != nil else { return done(nil, false) }
        let id = nextProposal
        nextProposal += 1
        pendingListings[id] = done
        conn?.send(.message(ClientMessage.propose(id: id, proposal)))
    }

    // MARK: Conveniences

    /// A new, empty arrangement on the desk, selected.
    @discardableResult
    /// A new workspace on this host, after `after` in its desk's order (the
    /// host keeps the order; the client proposes).
    func newArrangement(title: String? = nil, after: BlockID? = nil) -> BlockID {
        let id = BlockID(host: host)
        append(.create(kind: .arrangement, title: title, path: nil), to: .block(id))
        var order = desk.order
        let index = after.flatMap { order.firstIndex(of: $0) }.map { $0 + 1 } ?? order.count
        order.insert(id, at: index)
        setWorkspaceOrder(order)
        return id
    }

    func setWorkspaceOrder(_ order: [BlockID]) {
        guard order != desk.order else { return }
        propose(.workspaces(order: order))
    }

    /// A workspace of this host that this desk doesn't list yet: listed.
    func adoptWorkspace(_ id: BlockID) {
        guard id.host == host, !desk.order.contains(id), block(id)?.kind == .arrangement else { return }
        setWorkspaceOrder(desk.order + [id])
    }

    func removeWorkspace(_ id: BlockID) {
        setWorkspaceOrder(desk.order.filter { $0 != id })
    }

    /// A new terminal block on the host, in `cwd`.
    func newTerminal(cwd: String?) -> BlockID {
        let id = BlockID(host: host)
        propose(.newTerminal(block: id, cwd: cwd))
        return id
    }

    /// An agent: a terminal block running the agent command.
    func newAgent(cwd: String?, command: String) -> BlockID {
        let id = BlockID(host: host)
        propose(.newAgent(block: id, cwd: cwd, command: command))
        return id
    }

    /// The block for an image or PDF at a path, made if there isn't one.
    func mediaBlock(for path: String, kind: BlockKind) -> BlockID {
        if let b = block(kind: kind, path: path) { return b.id }
        let id = BlockID(host: host)
        append(.create(kind: kind, title: nil, path: path), to: .block(id))
        return id
    }

    /// The host's process block: one per host, listed again.
    func processBlock() -> BlockID {
        if let b = node.blocks.first(where: { $0.kind == .process }) {
            propose(.processes(block: b.id))
            return b.id
        }
        let id = BlockID(host: host)
        propose(.processes(block: id))
        return id
    }

    /// The text block for a path, made (and read) if there isn't one. One
    /// already here is made sure of: read if its text never came in (a
    /// block the host made for a file another text names), looked at
    /// again on disk if it has no edits (the host sends it only if it
    /// differs).
    func textBlock(for path: String) -> BlockID {
        if let b = textBlock(path: path) {
            if b.needsRead { ensureRead(b.id) } else if b.text?.isDirty == false { propose(.readFile(b.id)) }
            return b.id
        }
        let id = BlockID(host: host)
        append(.create(kind: .text, title: nil, path: path), to: .block(id))
        ensureRead(id)
        return id
    }

    // MARK: Texts read in

    /// Files this client wants the text of: asked for until it's in,
    /// whatever goes astray on the way — a request made while the link
    /// was down, an answer lost to a refused append or a fence, a copy
    /// that fell out of step.
    private var wantedReads: Set<BlockID> = []
    private var readsInFlight: Set<BlockID> = []
    private var readAttempts: [BlockID: Int] = [:]

    /// A file's text, read in if it isn't yet; asked again until it is.
    func ensureRead(_ id: BlockID) {
        guard node.block(id)?.needsRead == true else { return }
        wantedReads.insert(id)
        requestRead(id)
    }

    private func requestRead(_ id: BlockID) {
        guard conn != nil, !readsInFlight.contains(id) else { return }
        guard node.block(id)?.needsRead == true else {
            wantedReads.remove(id)
            readAttempts[id] = nil
            return
        }
        readsInFlight.insert(id)
        propose(.readFile(id)) { [weak self] error in
            guard let self, self.readsInFlight.remove(id) != nil else { return }
            guard self.node.block(id)?.needsRead == true else {
                self.wantedReads.remove(id)
                self.readAttempts[id] = nil
                return
            }
            // Answered, and still not in: the answer went astray, or the
            // host thinks this copy has it — ask for the host's copy too.
            let n = (self.readAttempts[id] ?? 0) + 1
            self.readAttempts[id] = n
            NSLog("host %@: %@ still not read in after %d tries%@", self.host.raw, id.description, n, error.map { ": \($0)" } ?? "")
            if error == nil { self.resync(.block(id)) }
            DispatchQueue.main.asyncAfter(deadline: .now() + min(8, 0.25 * pow(2, Double(min(n, 6))))) { [weak self] in
                self?.requestRead(id)
            }
        }
    }

    /// Every wanted text not in yet, asked for again (on attaching, on a
    /// fresh copy of a shard).
    private func retryReads() {
        for id in wantedReads { requestRead(id) }
    }

    /// Shards asked for afresh and not yet come: asked once a while.
    private var resyncing: [ShardID: Date] = [:]

    private func resync(_ shard: ShardID) {
        if let asked = resyncing[shard], Date().timeIntervalSince(asked) < 3 { return }
        resyncing[shard] = Date()
        conn?.send(.message(ClientMessage.resync(shard: shard)))
    }

    func directoryBlock(for spelled: String) -> BlockID {
        // Spelled with a trailing slash (a folder `manifold` said was one), kept without.
        let path = spelled.count > 1 && spelled.hasSuffix("/") ? String(spelled.dropLast()) : spelled
        if let b = directoryBlock(path: path) { return b.id }
        let id = BlockID(host: host)
        propose(.directory(block: id, path: path))
        return id
    }

    /// The git block for the repository a path is in: an existing one
    /// whose root holds the path, else a new one the host roots.
    /// `done`, with why not if the host couldn't make the block.
    func gitBlock(for path: String, done: ((String?) -> Void)? = nil) -> BlockID {
        let roots = node.blocks.filter { $0.kind == .git && $0.path != nil && (path == $0.path! || path.hasPrefix($0.path! + "/")) }
        if let b = roots.max(by: { $0.path!.count < $1.path!.count }) {
            propose(.refreshGit(block: b.id))
            done?(nil)
            return b.id
        }
        let id = BlockID(host: host)
        propose(.git(block: id, path: path), done: done)
        return id
    }

    /// An Interactive Smartlog block for the repository holding `path`: the
    /// one there is, its host's smartlog asked for again, else a new one.
    func smartlogBlock(for path: String, done: ((String?) -> Void)? = nil) -> BlockID {
        let roots = node.blocks.filter { $0.kind == .smartlog && $0.path != nil && (path == $0.path! || path.hasPrefix($0.path! + "/")) }
        if let b = roots.max(by: { $0.path!.count < $1.path!.count }) {
            propose(.smartlog(block: b.id, path: b.path!), done: done)
            return b.id
        }
        let id = BlockID(host: host)
        propose(.smartlog(block: id, path: path), done: done)
        return id
    }

    /// A diff block comparing something: the one that already does, reloaded,
    /// else a new one.
    func diffBlock(_ subject: DiffSubject) -> BlockID {
        if let b = node.blocks.first(where: { $0.kind == .diff && $0.diff?.subject == subject }) {
            propose(.reloadDiff(block: b.id))
            return b.id
        }
        let id = BlockID(host: host)
        propose(.diff(block: id, subject: subject))
        return id
    }

    /// A search block on this host, looking already.
    func newSearch(_ query: SearchQuery) -> BlockID {
        let id = BlockID(host: host)
        propose(.search(block: id, query: query))
        return id
    }

    /// A note: text with no file, at home in `home` — the folder of the
    /// block it was made from, where it is found and saved by default.
    func newNote(home: String? = nil, text: String = "") -> BlockID {
        let id = BlockID(host: host)
        append(.create(kind: .text, title: nil, path: nil), to: .block(id))
        if let home { append(.cwd(home), to: .block(id)) }
        append(.content(text, encoding: "utf-8", lineEnding: "\n", fingerprint: ""), to: .block(id))
        return id
    }

    /// A web block, at a URL.
    /// The web block showing a page kept as a file, made if there isn't one.
    func webBlock(forFile path: String) -> BlockID {
        let url = URL(fileURLWithPath: path).standardizedFileURL.absoluteString
        if let b = node.blocks.first(where: { $0.kind == .web && $0.web?.url == url }) { return b.id }
        let id = BlockID(host: host)
        append([.create(kind: .web, title: nil, path: path), .url(url, viaHost: false)], to: .block(id))
        return id
    }

    func newWeb(url: String) -> BlockID {
        let id = BlockID(host: host)
        append([.create(kind: .web, title: nil, path: nil), .url(url, viaHost: false)], to: .block(id))
        return id
    }


    /// A link made again within moments — one action saying it twice, the
    /// second time perhaps without its words — is made once: a re-link
    /// replaces the link, words and all.
    func link(from: BlockID, to: BlockID, kind: LinkKind, context: String? = nil) {
        guard from != to else { return }
        let key = "\(from) \(to) \(kind)", now = Date()
        recentLinks = recentLinks.filter { now.timeIntervalSince($0.value.at) < 5 }
        if let last = recentLinks[key], context == nil || context == last.context { return }
        recentLinks[key] = (context, now)
        propose(.link(Link(from: from, to: to, kind: kind, at: clock.now(), context: context)))
    }
    private var recentLinks: [String: (context: String?, at: Date)] = [:]

    func setSettings(_ s: Settings) { propose(.settings(s)) }

    // MARK: Connection

    func connect() {
        guard case .local = transport else { return reconnectRemote() }
        Paths.ensureDirectory()
        if let fd = try? UnixSocket.connect(path: Paths.socket) {
            attach(Connection(fd: fd, queue: linkQueue))
            return
        }
        begin("Starting the server")
        let pid = launchServer()
        var attempts = 0
        func retry() {
            attempts += 1
            if let fd = try? UnixSocket.connect(path: Paths.socket) {
                attach(Connection(fd: fd, queue: linkQueue))
            } else if attempts < 100 || (pid > 0 && kill(pid, 0) == 0) {
                // As long as the server lives, it's coming: it may be
                // rewriting its logs first.
                DispatchQueue.main.asyncAfter(deadline: .now() + (attempts < 100 ? 0.05 : 0.25), execute: retry)
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

    /// Starts a server, returning its pid, or -1.
    @discardableResult
    private func launchServer() -> pid_t {
        let exe = Self.serverExecutable
        let pid = withCStrings([exe, "serve"]) { argv in
            mf_spawn_detached(exe, argv, Paths.log.path)
        }
        if pid < 0 { NSLog("could not start %@: %s", exe, strerror(errno)) }
        return pid
    }

    /// Readies a remote host: asks what it is, installs our server if the
    /// one there isn't ours, and starts the bridge. Slow; not on the main
    /// thread.
    /// `step` is told each step as it begins, on this thread.
    /// `progress`, how much of the server has gone of how much, from
    /// another thread.
    /// `reset`: the server put there afresh whatever's there, and the one
    /// running stopped, so the bridge starts the new one (Reset Server).
    static func bootstrap(_ dest: Destination, name: String, reset: Bool = false, step: (String) -> Void = { _ in },
                          progress: @escaping @Sendable (Int, Int) -> Void = { _, _ in }) throws -> Child {
        step("Asking the host what it is (\(dest.provider))")
        let probe = try Bootstrap.probe(dest)
        let binaryName = Bootstrap.binaryName(os: probe.os, arch: probe.arch)
        // Servers for other systems under Resources/servers; this Mac's own kind beside it in Helpers.
        let contents = Bundle.main.bundleURL.appendingPathComponent("Contents")
        var binary = contents.appendingPathComponent("Resources/servers").appendingPathComponent(binaryName)
        if !FileManager.default.fileExists(atPath: binary.path) { binary = contents.appendingPathComponent("Helpers").appendingPathComponent(binaryName) }
        if !FileManager.default.fileExists(atPath: binary.path), probe.os == "darwin", probe.arch == "arm64" {
            binary = URL(fileURLWithPath: serverExecutable)
        }
        guard let data = FileManager.default.contents(atPath: binary.path) else {
            throw RemoteError.noBinary("\(probe.os) \(probe.arch)")
        }
        if reset || probe.hash != Bootstrap.sha256(data) {
            NSLog("installing manifoldd on %@ (%@)%@", dest.description, binaryName, reset ? ", reset" : "")
            step("Installing the server there" + (probe.gunzip ? ", compressed" : ""))
            let total = data.count
            try Bootstrap.upload(dest, binary: data, compressed: probe.gunzip) { progress($0, total) }
        }
        if reset {
            // The new binary is in place; the old server goes, and the
            // bridge below starts the new one.
            step("Stopping the server there")
            let (out, status) = try Child.run(dest.invocation(Bootstrap.stopCommand), timeout: 60)
            if status != 0 { NSLog("stopping manifoldd on %@: status %d: %@", dest.description, status, String(decoding: out, as: UTF8.self)) }
        }
        return try Child.spawn(dest.invocation(Bootstrap.bridgeCommand(name: name)))
    }

    /// Takes a bridge just spawned as the connection.
    func adopt(_ child: Child) {
        self.child = child
        attach(Connection(fd: child.output, writeFD: child.input, queue: linkQueue))
    }

    private func reconnectRemote() {
        guard case let .remote(dest, name) = transport, !disconnected else { return }
        begin("Starting the bridge (\(dest.provider))")
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let child: Child?
            var why: String? = nil
            do { child = try Child.spawn(dest.invocation(Bootstrap.bridgeCommand(name: name))) } catch { child = nil; why = "\(error)" }
            DispatchQueue.main.async {
                guard let self, !self.disconnected else { return }
                if let child {
                    self.adopt(child)
                } else {
                    self.link = .unreachable(why)
                    self.scheduleRetry(after: self.nextRetryDelay()) { [weak self] in self?.reconnectRemote() }
                }
            }
        }
    }

    /// Reaching the host failed before a bridge could be spawned (its
    /// bootstrap): said so, until the next try.
    func markUnreachable(_ why: String?) {
        link = .unreachable(why)
    }

    func disconnect() {
        disconnected = true
        retryWork?.cancel()
        pingTimer?.invalidate()
        conn?.close()
        if let child { kill(child.pid, SIGTERM) }
    }

    /// The Mac woke, or its network came back or changed: a host waiting
    /// to try again tries now; one connected is asked at once whether it's
    /// still there (a link from before sleep is often dead without saying),
    /// and given up on in a few seconds if it doesn't answer.
    func networkMayHaveChanged() {
        guard !disconnected else { return }
        if retryWork != nil { return retryNow() }
        guard isRemote, let conn else { return }
        let sent = Date()
        pingSent = sent
        conn.send(.message(ClientMessage.ping))
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in
            guard let self, self.pingSent == sent, self.conn === conn, !self.busy(within: 5) else { return }
            NSLog("host %@: no answer after waking; dropping the connection", self.host.raw)
            self.pingSent = nil
            self.link = .unreachable("not answering")
            conn.close()
        }
    }

    /// Every so often, a ping over a remote bridge; no pong in time, and
    /// the connection is given up on, to be made again.
    private func startPinging() {
        pingTimer?.invalidate()
        guard isRemote else { return }
        pingTimer = Timer.scheduledTimer(withTimeInterval: 15, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, let conn = self.conn else { return }
                if let sent = self.pingSent, Date().timeIntervalSince(sent) > 12 {
                    // Still busy (a file coming, one going): the pong is
                    // behind it; asked again when it's quiet.
                    if self.busy(within: 12) { return }
                    NSLog("host %@: no answer to a ping; dropping the connection", self.host.raw)
                    self.pingSent = nil
                    self.link = .unreachable("not answering")
                    conn.close()
                    return
                }
                self.pingSent = Date()
                conn.send(.message(ClientMessage.ping))
            }
        }
    }

    /// Ports of this host's forwarded to this Mac (§8).
    lazy var forwards = PortForwards(client: self)


    /// Whether the link is plainly alive without its pong: bytes came in
    /// lately, or what's being sent is still being taken. A big piece
    /// ahead of the pong on a slow link isn't the host gone.
    private func busy(within seconds: TimeInterval) -> Bool {
        guard let link = mux?.linkState() else { return false }
        let now = Date()
        return now.timeIntervalSince(link.lastRead) < seconds || (link.pending > 0 && now.timeIntervalSince(link.lastWrite) < seconds)
    }

    private func attach(_ connection: Connection) {
        let mux = Mux(connection)
        let conn = mux.control
        conn.callbackQueue = .main
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
            self.mux = nil
            self.isConnected = false
            // Reads asked over this link won't be answered: asked again on the next.
            self.readsInFlight = []
            self.forwards.linkClosed()
            self.pingTimer?.invalidate()
            self.pingSent = nil
            // Gone before it answered: unreachable, not still connecting.
            let answered = self.link == .connected
            self.link = .unreachable(answered ? nil : "the connection closed before the host answered")
            self.closedUnanswered = answered ? 0 : self.closedUnanswered + 1
            if let child = self.child {
                var status: Int32 = 0
                waitpid(child.pid, &status, WNOHANG)
                self.child = nil
            }
            self.onDisconnect?()
            self.scheduleChange()
            guard !self.disconnected else { return }
            // Bring the server back; terminals re-attach once it's up — a
            // remote one after a while, longer each time it can't be.
            if self.isRemote {
                let again = self.closedUnanswered >= 3 && self.onNeedsBootstrap != nil
                let delay = self.serverRestarting ? 1 : self.nextRetryDelay()
                self.serverRestarting = false
                self.scheduleRetry(after: delay) { [weak self] in
                    guard let self else { return }
                    if again { self.closedUnanswered = 0; self.onNeedsBootstrap?() } else { self.connect() }
                }
            } else {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { self.connect() }
            }
        }
        // Until the host has answered: what of its answer has come.
        received = 0
        connection.onRead = { [weak self] n in
            DispatchQueue.main.async {
                guard let self, self.link == .connecting else { return }
                if self.received == 0 { self.begin("Receiving the host's state") }
                self.received += n
            }
        }
        mux.start()
        conn.send(.message(ClientMessage.hello(version: protocolVersion, name: "Manifold")))
        self.conn = conn
        self.mux = mux
        isConnected = true
        begin(isRemote ? "Waiting for the host to answer (the bridge, its server)" : "Waiting for the server to answer")
    }

    private func handle(_ message: ServerMessage) {
        switch message {
        case let .welcome(version, _, host, label, _, home, snapshots, features):
            // Streams opened compressed from now on, where they ask to be:
            // over a link to another machine, to a server that takes them.
            mux?.compression = isRemote && features?.contains("zstd") == true
            if version != protocolVersion {
                NSLog("manifoldd speaks protocol %d, we speak %d", version, protocolVersion)
                if isRemote {
                    // The host's server is from before our build; the binary
                    // there is ours now (bootstrap put it there), but the
                    // old one kept running. Stopped, it goes; the bridge we
                    // come back through finds no socket and starts the new
                    // one. Its shells start again, each in its directory.
                    if restartedServerSpeaking != version {
                        restartedServerSpeaking = version
                        NSLog("restarting the server on %@ for protocol %d", label ?? host.description, protocolVersion)
                        conn?.send(.message(ClientMessage.shutdown))
                        serverRestarting = true
                    } else {
                        NSLog("the server on %@ still speaks protocol %d after a restart; left as it is", label ?? host.description, version)
                    }
                } else {
                    onVersionMismatch?(version)
                }
            }
            let first = !hasState
            self.host = host
            self.label = label
            self.home = home
            lastHeard = Date()
            link = .connected
            backoff = 2
            closedUnanswered = 0
            startPinging()
            fenced = []
            clock = Clock(host: host)
            for s in snapshots { node.load(s) }
            // Shards we had that the host no longer has (a fresh host).
            let known = Set(snapshots.map(\.shard))
            for shard in node.shards.keys where !known.contains(shard) { node.remove(shard) }
            resyncing = [:]
            readsInFlight = []
            retryReads()
            hasState = true
            if first { onWelcome?() }
            onConnected?()
            scheduleChange()
        case .pong:
            pingSent = nil
            lastHeard = Date()
            let waiting = pongWaiters
            pongWaiters = []
            for w in waiting { w() }
        case let .entries(shard, entries):
            for e in entries { clock.observe(e.at) }
            if !node.apply(entries, to: shard) {
                // Out of step: the host's copy, rather than this one wrong
                // until the next attach.
                NSLog("entries for %@ don't follow; asking for a snapshot", shard.description)
                resync(shard)
            }
            // A block discarded by the host is gone here too.
            if case .registry = shard {
                for e in entries { if case let .unregister(id) = e.event { node.remove(.block(id)) } }
            }
            if let block = shard.block {
                for e in entries {
                    if case .shell(.ended) = e.event { onTerminalEnded?(block) }
                }
            }
        case let .snapshot(snap):
            node.load(snap)
            resyncing[snap.shard] = nil
            if let id = snap.shard.block, wantedReads.contains(id) { requestRead(id) }
        case let .rejected(shard):
            NSLog("append to %@ was refused", shard.description)
        case let .fenced(shard):
            // Another attachment has the pen: what this one appended since
            // is gone; the snapshot that follows is the truth.
            NSLog("fenced on %@: another attachment took the pen", shard.description)
            fenced.insert(shard)
        case let .propose(shard, proposal):
            lower(proposal, into: shard)
        case let .done(id, error):
            if let error { NSLog("proposal %d: %@", id, error) }
            pendingProposals.removeValue(forKey: id)?(error)
        case let .history(shard, base, entries):
            onHistory?(shard, base, entries)
        case let .removed(shard):
            node.remove(shard)
        case let .open(id, client, paths, beside, wait):
            onOpen?(id, client, paths, beside, wait)
        case let .show(id, client, block, beside):
            onShow?(id, client, block, beside)
        case let .diagnostics(block, items):
            diagnostics[block] = items
            onDiagnostics?(block)
        case let .gutter(block, marks):
            gutters[block] = marks
            onGutter?(block)
        case let .lspResult(id, result):
            pendingLSP.removeValue(forKey: id)?(result)
        case .end:
            break // only on a file's stream
        case let .notebookLive(block, cell, output):
            onNotebookLive?(block, cell, output)
        case let .passwordInput(block, on):
            SecureInput.shared.set(block, readingPassword: on)
        case let .listing(id, entries, complete):
            pendingListings.removeValue(forKey: id)?(entries, complete)
        case let .languageServer(language, root, state):
            languageServerStates[language + "|" + root] = state
            onLanguageServer?(language, root, state)
        }
    }

    /// The host welcomed us (each time: a reconnection too).
    var onConnected: (() -> Void)?
    var onDiagnostics: ((BlockID) -> Void)?
    var onGutter: ((BlockID) -> Void)?
    /// A notebook's running cell printed (§7.7).
    var onNotebookLive: ((BlockID, String, String) -> Void)?
    var onLanguageServer: ((String, String, String) -> Void)?

    var onHistory: ((ShardID, ShardSnapshot?, [Entry]) -> Void)?
    /// A terminal's shell ended (not for dormancy), while we were attached.
    var onTerminalEnded: ((BlockID) -> Void)?
    /// A `manifold` command on this host asked for paths to be opened.
    var onOpen: ((Int, Int, [String], BlockID?, Bool) -> Void)?
    var onShow: ((Int, Int, BlockID, BlockID?) -> Void)?

    /// The host asked us, as the leader, to append something.
    private func lower(_ proposal: HostProposal, into shard: ShardID) {
        guard node.has(shard) else { return }
        switch proposal {
        case let .content(text, encoding, lineEnding, fingerprint):
            // A text not in yet is this client's to put in, fenced or
            // not: no one can have edited what isn't there.
            if fenced.contains(shard), let id = shard.block, node.block(id)?.needsRead == true { own(shard) }
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
