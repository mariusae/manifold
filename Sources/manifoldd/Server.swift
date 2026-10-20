import CPTY
import Foundation
import ManifoldCore
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#endif

enum ServerError: Error {
    case alreadyRunning
}

private func sysAccept(_ fd: Int32) -> Int32 { accept(fd, nil, nil) }
private func sysExit(_ code: Int32) -> Never { exit(code) }

/// A host: every shard's log, the registry and links, the shells, the files.
/// The app attaches and mirrors; it leads the shards it edits (arrangements,
/// text, the desk) and asks for the rest by proposal. Everything runs on one
/// serial queue.
final class Server {
    /// The host's session id (§8), minted the first time; logs from before
    /// sessions are rewritten to it.
    let host: HostID
    /// What the host calls itself, for clients to show.
    let label: String?
    private let queue = DispatchQueue(label: "manifoldd")
    private let node = Node()
    private let store: LogStore
    private let clock: Clock
    private var clients: [Connection] = []
    /// Each client's attachment number, and the app among them (named so).
    private var clientIDs: [ObjectIdentifier: Int] = [:]
    private var appClients: Set<ObjectIdentifier> = []
    /// Which attachment holds the pen for each shard a client may lead
    /// (§8.2): the last to focus its block, or the first to append.
    private var owners: [ShardID: ObjectIdentifier] = [:]
    /// Connections that haven't said what they are yet.
    private var pending: [Connection] = []
    private var attachments = 0
    private var sessions: [BlockID: Session] = [:]
    private var watchers: [BlockID: FileWatcher] = [:]
    private var listener: DispatchSourceRead?
    private var timer: DispatchSourceTimer?
    private var snapshotTimer: DispatchSourceTimer?
    private var signalSources: [DispatchSourceSignal] = []
    /// Shards changed since their last snapshot.
    private var dirtyShards: Set<ShardID> = []
    private let languageServers: LanguageServers
    private let searches: Searches
    private let mentions: Mentions
    private let git: Git
    /// Gutter marks pending for text blocks, a moment after their last change.
    private var gutterWork: [BlockID: DispatchWorkItem] = [:]
    /// Repositories watched (their index) for git blocks and gutters.
    private var repoWatchers: [String: FileWatcher] = [:]
    /// When each repository's git blocks last refreshed for a change
    /// under it, and a refresh waiting its turn.
    private var gitRefreshedAt: [String: Date] = [:]
    private var gitRefreshDue: [String: DispatchWorkItem] = [:]

    /// Held for the life of the server: one per directory.
    private let lock: Int32

    init() throws {
        Paths.ensureDirectory()
        // One server per directory: a second one exits quietly. Taken
        // before anything is read or rewritten.
        lock = open(Paths.directory.appendingPathComponent("manifoldd.lock").path, O_CREAT | O_RDWR | O_CLOEXEC, 0o600)
        guard lock >= 0, flock(lock, LOCK_EX | LOCK_NB) == 0 else { throw ServerError.alreadyRunning }
        let session = HostSession.identify(directory: Paths.directory, logs: Paths.logs)
        host = session.id
        label = session.label
        clock = Clock(host: session.id)
        store = LogStore(directory: Paths.logs)
        git = Git(queue: queue)
        searches = Searches(queue: queue)
        mentions = Mentions(queue: queue)
        languageServers = LanguageServers(queue: queue)
        mentions.blocks = { [weak self] in self?.node.blocks ?? [] }
        mentions.mentions = { [weak self] block in self?.node.graph.edges(from: block, kind: .link(.mention)) ?? [] }
        mentions.makeBlock = { [weak self] kind, path in
            guard let self else { return BlockID(host: HostID("none")) }
            let id = BlockID(host: self.host)
            // A block for a file the text names, before anyone opens it: the
            // app finds it by path when they do.
            self.append(.create(kind: kind, title: nil, path: path), to: .block(id))
            return id
        }
        mentions.link = { [weak self] link in self?.append(.link(link), to: .links(self!.host)) }
        mentions.unlink = { [weak self] id in self?.append(.unlink(id), to: .links(self!.host)) }
        languageServers.textOf = { [weak self] block in
            guard let b = self?.node.block(block), let t = b.text else { return nil }
            return (t.text, b.path)
        }
        searches.onHits = { [weak self] block, hits, done, truncated, error in
            guard let self, self.node.block(block)?.kind == .search else { return }
            self.append(.hits(hits, done: done, truncated: truncated, error: error), to: .block(block))
            if let error {
                self.report(block, .error, msg: error)
            } else if done {
                let n = self.node.block(block)?.search?.hits.count ?? 0
                self.report(block, .done, msg: "\(n) hit\(n == 1 ? "" : "s")" + (truncated ? ", stopped" : ""))
            }
        }
        languageServers.onDiagnostics = { [weak self] block, items in
            let frame = Frame.message(ServerMessage.diagnostics(block, items))
            for c in self?.clients ?? [] { c.send(frame) }
        }
        languageServers.onState = { [weak self] language, root, state in
            log("language server \(language) at \(root): \(state)")
            let frame = Frame.message(ServerMessage.languageServer(language: language, root: root, state: state))
            for c in self?.clients ?? [] { c.send(frame) }
        }
    }

    func run() throws {
        load()
        pruneHistory()
        let fd = try UnixSocket.listen(path: Paths.socket)
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
        let listener = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        listener.setEventHandler { [weak self] in self?.accept(fd) }
        listener.resume()
        self.listener = listener

        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 2, repeating: 2)
        timer.setEventHandler { [weak self] in
            self?.pollSessions()
            self?.saveHistory()
        }
        timer.resume()
        self.timer = timer

        let snapshots = DispatchSource.makeTimerSource(queue: queue)
        snapshots.schedule(deadline: .now() + 60, repeating: 60)
        snapshots.setEventHandler { [weak self] in
            self?.writeSnapshots()
            self?.collectTerminals()
            self?.retain()
        }
        snapshots.resume()
        snapshotTimer = snapshots

        for sig in [SIGTERM, SIGINT] {
            signal(sig, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: sig, queue: queue)
            source.setEventHandler { [weak self] in self?.exit(endSessions: false) }
            source.resume()
            signalSources.append(source)
        }
        log("manifoldd \(getpid()) listening on \(Paths.socket)")
    }

    // MARK: Connections

    private func accept(_ listenFD: Int32) {
        while true {
            let fd = sysAccept(listenFD)
            guard fd >= 0 else { return }
            let conn = Connection(fd: fd, queue: queue)
            conn.onFrame = { [weak self, unowned conn] frame in self?.firstFrame(frame, on: conn) }
            conn.onClose = { [weak self, unowned conn] in self?.pending.removeAll { $0 === conn } }
            pending.append(conn)
            conn.start()
        }
    }

    private func firstFrame(_ frame: Frame, on conn: Connection) {
        pending.removeAll { $0 === conn }
        conn.onClose = nil
        switch frame.decode(ClientMessage.self) {
        case let .hello(_, name)?:
            clients.append(conn)
            attachments += 1
            clientIDs[ObjectIdentifier(conn)] = attachments
            if name == "Manifold" { appClients.insert(ObjectIdentifier(conn)) }
            conn.onFrame = { [weak self, unowned conn] frame in self?.clientFrame(frame, from: conn) }
            conn.onClose = { [weak self, unowned conn] in
                self?.clients.removeAll { $0 === conn }
                self?.clientIDs.removeValue(forKey: ObjectIdentifier(conn))
                self?.appClients.remove(ObjectIdentifier(conn))
                self?.owners = self?.owners.filter { $0.value != ObjectIdentifier(conn) } ?? [:]
            }
            let snapshots = node.shards.keys.sorted { $0.description < $1.description }.compactMap { node.snapshot($0) }
            conn.send(.message(ServerMessage.welcome(version: protocolVersion, pid: getpid(), host: host, label: label,
                                                     attachment: attachments, home: NSHomeDirectory(), snapshots: snapshots)))
        case .attach(let req)?:
            attach(conn, req)
        case .shutdown?:
            exit(endSessions: true)
        default:
            conn.close()
        }
    }

    private func clientFrame(_ frame: Frame, from conn: Connection) {
        switch frame.decode(ClientMessage.self) {
        case .ping?:
            conn.send(.message(ServerMessage.pong))
        case let .append(shard, entries)?:
            clientAppended(shard, entries, from: conn)
        case let .own(shard)?:
            own(shard, by: conn)
        case let .propose(id, proposal)?:
            propose(id, proposal, from: conn)
        case let .open(id, paths, beside, wait)?:
            // The command asks; the app, if attached, opens.
            guard let app = clients.first(where: { appClients.contains(ObjectIdentifier($0)) }) else {
                conn.send(.message(ServerMessage.done(id: id, error: "Manifold isn't attached to this host")))
                return
            }
            app.send(.message(ServerMessage.open(id: id, client: clientIDs[ObjectIdentifier(conn)] ?? 0, paths: paths, beside: beside, wait: wait)))
        case let .openPatch(id, patch, root, title, beside)?:
            // `manifold diff`: the patch becomes a diff block here, and the
            // app, if attached, places it and answers the command.
            guard let app = clients.first(where: { appClients.contains(ObjectIdentifier($0)) }) else {
                conn.send(.message(ServerMessage.done(id: id, error: "Manifold isn't attached to this host")))
                return
            }
            guard patch.utf8.count <= 64 << 20 else {
                conn.send(.message(ServerMessage.done(id: id, error: "that patch is over 64 MB")))
                return
            }
            let block = BlockID(host: host)
            append(.create(kind: .diff, title: nil, path: root), to: .block(block))
            append(.diffSubject(.patch(root: root, title: title)), to: .block(block))
            append(.diffLoaded(oldText: nil, newText: nil, patch: patch, error: nil, at: clock.now()), to: .block(block))
            app.send(.message(ServerMessage.show(id: id, client: clientIDs[ObjectIdentifier(conn)] ?? 0, block: block, beside: beside)))
        case .shutdown?:
            exit(endSessions: true)
        default:
            break
        }
    }

    // MARK: Entries

    /// The pen for a shard goes to `conn` (§8.2): whoever held it is told
    /// it's fenced, and mirrors from here on.
    private func own(_ shard: ShardID, by conn: Connection) {
        let me = ObjectIdentifier(conn)
        if let holder = owners[shard], holder != me, let other = clients.first(where: { ObjectIdentifier($0) == holder }) {
            other.send(.message(ServerMessage.fenced(shard: shard)))
        }
        owners[shard] = me
    }

    /// The client, owning a shard, appended to it: kept and passed on, if
    /// it continues the log; else the client is sent the log as it is. A
    /// shard no one owns is taken by the first to append; one another
    /// attachment owns is refused.
    private func clientAppended(_ shard: ShardID, _ entries: [Entry], from conn: Connection) {
        guard let first = entries.first else { return }
        let me = ObjectIdentifier(conn)
        if let holder = owners[shard], holder != me, clients.contains(where: { ObjectIdentifier($0) == holder }) {
            log("append to \(shard) refused: another attachment owns it")
            conn.send(.message(ServerMessage.fenced(shard: shard)))
            conn.send(.message(ServerMessage.rejected(shard: shard)))
            if let snap = node.snapshot(shard) { conn.send(.message(ServerMessage.snapshot(snap))) }
            return
        }
        owners[shard] = me
        guard first.seq == node.seq(shard) + 1, node.apply(entries, to: shard) else {
            log("append to \(shard) at \(first.seq) doesn't follow \(node.seq(shard)); resending")
            conn.send(.message(ServerMessage.rejected(shard: shard)))
            if let snap = node.snapshot(shard) { conn.send(.message(ServerMessage.snapshot(snap))) }
            return
        }
        for e in entries { clock.observe(e.at) }
        store.append(entries, to: shard)
        dirtyShards.insert(shard)
        let frame = Frame.message(ServerMessage.entries(shard: shard, entries: entries))
        for c in clients where c !== conn { c.send(frame) }
        shardChanged(shard, entries: entries)
        trail(shard, entries)
    }

    /// The host appends to a shard it leads, and tells every client.
    @discardableResult
    private func append(_ event: Event, to shard: ShardID) -> Entry? {
        guard let entry = node.append(event, to: shard, at: clock.now()) else { return nil }
        store.append([entry], to: shard)
        dirtyShards.insert(shard)
        let frame = Frame.message(ServerMessage.entries(shard: shard, entries: [entry]))
        for c in clients { c.send(frame) }
        shardChanged(shard)
        return entry
    }

    /// Keeps the registry in step with a block's log, whoever appended.
    private func shardChanged(_ shard: ShardID, entries: [Entry] = []) {
        guard let id = shard.block, let block = node.block(id) else { return }
        if block.kind == .text,
           entries.contains(where: { if case .edit = $0.event { return true }; if case .content = $0.event { return true }; return false }) {
            if block.path != nil {
                languageServers.textChanged(id)
                scheduleGutter(id)
            }
            mentions.textChanged(id)
        }
        let registry = node.registry(host)
        let current = registry.blocks[id]
        if current == nil || current!.kind != block.kind || current!.title != block.displayTitle || current!.path != block.path {
            var entry = current ?? RegistryEntry(id: id, kind: block.kind, created: block.created, lastSeen: block.created)
            entry.kind = block.kind
            entry.title = block.displayTitle
            entry.path = block.path
            append(.register(entry), to: .registry(host))
        }
        let held = block.isHeld
        let dormant = block.terminal?.dormantSince != nil && block.terminal?.pid == nil
        let life: LifeState = dormant ? .dormant : (held ? .held : .warm)
        if current == nil || current!.held != held || current!.life != life {
            append(.life(id, life, held: held), to: .registry(host))
        }
        if block.kind == .text { watch(block) }
    }

    // MARK: Proposals

    private func propose(_ id: Int, _ proposal: Proposal, from conn: Connection) {
        func done(_ error: String? = nil) { conn.send(.message(ServerMessage.done(id: id, error: error))) }
        switch proposal {
        case let .newTerminal(block, cwd):
            if node.block(block) == nil {
                append(.create(kind: .terminal, title: nil, path: nil), to: .block(block))
                if let cwd { append(.cwd(cwd), to: .block(block)) }
            }
            done()
        case let .endTerminal(block):
            sessions[block]?.terminate()
            done()
        case let .newAgent(block, cwd, command):
            if node.block(block) == nil {
                append(.create(kind: .agent, title: nil, path: nil), to: .block(block))
                if let cwd { append(.cwd(cwd), to: .block(block)) }
                append(.command(command), to: .block(block))
            }
            done()
        case let .readBytes(block):
            guard let b = node.block(block), let path = b.path else { return done("not a file") }
            let data = try? Data(contentsOf: URL(fileURLWithPath: path))
            conn.send(.message(ServerMessage.bytes(id: id, data)))
        case let .processes(block):
            if node.block(block) == nil {
                append(.create(kind: .process, title: nil, path: nil), to: .block(block))
            }
            listProcesses(block)
            done()
        case let .signal(pid, sig):
            if kill(pid, sig) != 0 { return done(String(cString: strerror(errno))) }
            done()
        case let .readFile(block):
            guard let b = node.block(block), b.kind == .text, let path = b.path else { return done("not a file") }
            if let contents = TextFile.read(path) {
                conn.send(.message(ServerMessage.propose(shard: .block(block), .content(contents.text, encoding: contents.encoding,
                                                                                          lineEnding: contents.lineEnding, fingerprint: contents.fingerprint))))
                watch(b, force: true)
                done()
            } else if FileManager.default.fileExists(atPath: path) {
                conn.send(.message(ServerMessage.propose(shard: .block(block), .unreadable)))
                done("can't be read as text")
            } else {
                // A new file: empty, clean, not yet on disk.
                conn.send(.message(ServerMessage.propose(shard: .block(block), .content("", encoding: "utf-8", lineEnding: "\n", fingerprint: ""))))
                done()
            }
        case let .writeFile(block, version, text):
            guard let b = node.block(block), b.kind == .text, let path = b.path, let t = b.text else { return done("not a file") }
            do {
                let fingerprint = try TextFile.write(text, to: path, encoding: t.encoding, lineEnding: t.lineEnding)
                expectedFingerprints[block] = fingerprint
                conn.send(.message(ServerMessage.propose(shard: .block(block), .clean(version: version, fingerprint: fingerprint))))
                watch(b, force: true)
                languageServers.textChanged(block, saved: true)
                gitChanged(under: path)
                done()
            } catch {
                done(error.localizedDescription)
            }
        case let .directory(block, path):
            let standard = URL(fileURLWithPath: path).standardizedFileURL.path
            if node.block(block) == nil {
                append(.create(kind: .directory, title: nil, path: standard), to: .block(block))
            }
            list(block)
            done()
        case let .listDirectory(block):
            list(block)
            done()
        case let .workspaces(order):
            if order != node.desk(host).order { append(.order(order), to: .desk(host)) }
            done()
        case let .settings(s):
            if s != node.desk(host).settings { append(.settings(s), to: .desk(host)) }
            done()
        case let .seen(ids):
            let known = ids.filter { node.registry(host).blocks[$0] != nil }
            if !known.isEmpty { append(.seen(known, at: clock.now()), to: .registry(host)) }
            done()
        case let .attend(block):
            // Attended to: what was done or failed has been read (§3.7).
            if var r = node.block(block)?.status?[rootStatusID], r.state == .done || r.state == .error, r.read != true {
                r.read = true
                append(.status(id: rootStatusID, r), to: .block(block))
            }
            done()
        case let .clearStatus(block):
            if node.block(block)?.status != nil { append(.status(id: rootStatusID, nil), to: .block(block)) }
            done()
        case let .archive(block, on):
            if let b = node.block(block), b.isArchived != on { append(.archived(on), to: .block(block)) }
            // Archived, a terminal's shell ends; it isn't started again (attach replays).
            if on, let s = sessions[block] { s.terminate() }
            done()
        case let .inbox(block, on):
            if let b = node.block(block), b.isInInbox != on { append(.inbox(on), to: .block(block)) }
            done()
        case let .outline(block, of):
            if node.block(block) == nil {
                append(.create(kind: .outline, title: nil, path: nil), to: .block(block))
                append(.outlineSubject(of), to: .block(block))
                append(.link(Link(from: block, to: of, kind: .source, at: clock.now(), context: "outline")), to: .links(host))
            }
            done()
        case let .discard(block):
            // Gone for good: its session ended, its log deleted, and the
            // registry told, which every replica follows.
            sessions.removeValue(forKey: block)?.terminate()
            if node.block(block) != nil {
                node.remove(.block(block))
                store.delete(.block(block))
                append(.unregister(block), to: .registry(host))
            }
            done()
        case let .link(link):
            append(.link(link), to: .links(host))
            done()
        case let .unlink(linkID):
            append(.unlink(linkID), to: .links(host))
            done()
        case let .history(shard):
            let h = store.history(shard)
            conn.send(.message(ServerMessage.history(shard: shard, base: h.base, entries: h.entries)))
            done()
        case let .openDone(openID, client):
            if let c = clients.first(where: { clientIDs[ObjectIdentifier($0)] == client }) {
                c.send(.message(ServerMessage.done(id: openID, error: nil)))
            }
            done()
        case let .languageServers(configs):
            languageServers.configure(configs)
            done()
        case let .editing(ids):
            languageServers.setOpen(Set(ids))
            for id in ids where gutterWork[id] == nil { scheduleGutter(id) }
            done()
        case let .git(block, path):
            guard let (root, vcs) = git.repository(of: path.expandingTildeInPath) else { return done("\(path) isn't in a git or Sapling repository") }
            if node.block(block) == nil {
                append(.create(kind: .git, title: nil, path: root), to: .block(block))
            }
            if node.block(block)?.git?.vcs != vcs { append(.vcs(vcs), to: .block(block)) }
            refreshGit(block)
            watchRepo(root, vcs)
            done()
        case let .refreshGit(block):
            refreshGit(block)
            done()
        case let .diff(block, subject):
            if node.block(block) == nil {
                let path: String?
                switch subject {
                case let .sides(_, new): path = new.path
                case let .commit(repo, _): path = repo
                case let .versions(id, _, _): path = node.block(id)?.path
                case let .patch(root, _): path = root
                }
                append(.create(kind: .diff, title: nil, path: path), to: .block(block))
            }
            append(.diffSubject(subject), to: .block(block))
            loadDiff(block)
            done()
        case let .reloadDiff(block):
            loadDiff(block)
            done()
        case let .search(block, query):
            var q = query
            q.root = URL(fileURLWithPath: q.root.expandingTildeInPath).standardizedFileURL.path
            if node.block(block) == nil {
                append(.create(kind: .search, title: nil, path: nil), to: .block(block))
            }
            append(.search(q, at: clock.now()), to: .block(block))
            report(block, .working, msg: "Looking for “\(q.text)”")
            searches.run(block, q)
            done()
        case let .cancelSearch(block):
            searches.cancel(block)
            if node.block(block)?.search?.running == true {
                append(.hits([], done: true, truncated: true, error: nil), to: .block(block))
            }
            done()
        case let .lsp(request):
            languageServers.request(request) { result in
                conn.send(.message(ServerMessage.lspResult(id: id, result)))
            }
        case let .editFile(path, edits):
            guard let contents = TextFile.read(path) else { return done("can't read \(path)") }
            var rope = Rope(contents.text)
            for e in edits.sorted(by: { $0.start > $1.start }) { rope.apply(e) }
            do {
                _ = try TextFile.write(rope.string, to: path, encoding: contents.encoding, lineEnding: contents.lineEnding)
                done()
            } catch {
                done(error.localizedDescription)
            }
        }
    }

    private func list(_ block: BlockID) {
        guard let b = node.block(block), b.kind == .directory, let path = b.path else { return }
        if let entries = TextFile.list(path) {
            append(.entries(entries, at: clock.now()), to: .block(block))
        }
    }

    // MARK: Processes

    /// The process trees under this host's shells (§7.5): `ps`, parsed —
    /// pid, parent, user, cpu, resident kilobytes, command, the
    /// executable's path — kept to what descends from a terminal's or
    /// agent's shell, each tagged with its block, shells first.
    private func listProcesses(_ block: BlockID) {
        let shells = sessions.map { ($0.key, $0.value.pid) }
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let out = (try? Child.run(["ps", "-eo", "pid=,ppid=,user=,%cpu=,rss=,args="], timeout: 20, quiet: true).output) ?? Data()
            var all: [Int32: ProcessEntry] = [:]
            let ours = Session.startupArguments
            for line in String(decoding: out, as: UTF8.self).split(separator: "\n") {
                let f = line.split(separator: " ", maxSplits: 5, omittingEmptySubsequences: true)
                guard f.count >= 6, let pid = Int32(f[0]), let ppid = Int32(f[1]) else { continue }
                // A shell's startup arguments are Manifold's, not yours: left out.
                var command = String(f[5])
                for arg in ours { command = command.replacingOccurrences(of: arg, with: "") }
                all[pid] = ProcessEntry(pid: pid, parent: ppid, user: String(f[2]), cpu: Double(f[3]) ?? 0,
                                        memory: Int64(f[4]) ?? 0, command: command)
            }
            var children: [Int32: [Int32]] = [:]
            for e in all.values { children[e.parent, default: []].append(e.pid) }
            var entries: [ProcessEntry] = []
            for (id, shell) in shells.sorted(by: { $0.1 < $1.1 }) {
                var queue = [shell]
                while let pid = queue.first {
                    queue.removeFirst()
                    guard var e = all[pid] else { continue }
                    e.block = id
                    // The executable's path, from the kernel.
                    var buf = [CChar](repeating: 0, count: 4096)
                    if mf_proc_path(pid, &buf, Int32(buf.count)) == 0 { e.path = String(cString: buf) }
                    entries.append(e)
                    queue.append(contentsOf: (children[pid] ?? []).sorted())
                }
            }
            self?.queue.async {
                guard let self, self.node.block(block)?.kind == .process else { return }
                self.append(.processes(entries, at: self.clock.now()), to: .block(block))
            }
        }
    }

    // MARK: The trail

    /// Focus and selection, as clients append them, become the registry's
    /// trail: a block gone to, when, by which placement.
    private func trail(_ shard: ShardID, _ entries: [Entry]) {
        for e in entries {
            switch (shard, e.event) {
            case let (.block(arrangement), .focus(pid?)):
                guard let block = node.block(arrangement)?.arrangement?.placement(pid)?.block else { continue }
                if node.registry(host).trail.last?.block != block {
                    append(.step(Step(block: block, at: e.at, placement: pid)), to: .registry(host))
                }
            case let (.desk, .select(id?)):
                if node.registry(host).trail.last?.block != id {
                    append(.step(Step(block: id, at: e.at)), to: .registry(host))
                }
            default:
                break
            }
        }
    }

    // MARK: Git

    /// The gutter for a text block in a repository: its lines against
    /// HEAD's, a moment after the last change.
    private func scheduleGutter(_ block: BlockID) {
        gutterWork[block]?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.computeGutter(block) }
        gutterWork[block] = work
        queue.asyncAfter(deadline: .now() + 0.3, execute: work)
    }

    private func computeGutter(_ block: BlockID) {
        guard let b = node.block(block), b.kind == .text, let path = b.path, let text = b.text?.text else { return }
        guard git.root(of: path) != nil else { return }
        git.show(path, at: "HEAD") { [weak self] head in
            guard let self, let head, let now = self.node.block(block)?.text?.text else { return }
            let marks = GutterMark.marks(LineDiff.hunks(old: head, new: now.string))
            let frame = Frame.message(ServerMessage.gutter(block, marks))
            for c in self.clients { c.send(frame) }
        }
    }

    private func refreshGit(_ block: BlockID) {
        guard let b = node.block(block), b.kind == .git, let root = b.path else { return }
        let vcs = b.git?.vcs ?? git.repository(of: root)?.vcs ?? .git
        report(block, .working, msg: "Refreshing")
        var commands = [vcs.statusArguments, vcs.logArguments(limit: 200)]
        if let w = vcs.whereArguments { commands.append(w) }
        if let a = vcs.aheadArguments { commands.append(a) }
        git.run(vcs, commands, in: root) { [weak self] results in
            guard let self, self.node.block(block) != nil else { return }
            var error: String?
            var branch: String?, ahead = 0, behind = 0, status: [GitStatusEntry] = [], log: [GitCommit] = []
            switch results[0] {
            case .success(let out): (branch, ahead, behind, status) = vcs.parseStatus(out)
            case .failure(let e): error = e.message
            }
            if case .success(let out) = results[1] { log = vcs.parseLog(out) }
            if vcs.whereArguments != nil, case .success(let out) = results[2] { branch = VCS.parseSaplingWhere(out) }
            if vcs.aheadArguments != nil, case .success(let out) = results[3] { ahead = out.split(separator: "\n").count }
            // Only a change is worth an entry: a refresh that finds the
            // repository as it was is not history.
            let was = self.node.block(block)?.git
            let same = was.map { $0.branch == branch && $0.status == status && $0.log == log && $0.ahead == ahead && $0.behind == behind && $0.error == error } ?? false
            if !same {
                self.append(.gitRefreshed(branch: branch, status: status, log: log, ahead: ahead, behind: behind, error: error, at: self.clock.now()), to: .block(block))
            }
            if let error { self.report(block, .error, msg: error) } else { self.report(block, .done, msg: "\(status.count) change\(status.count == 1 ? "" : "s")") }
        }
    }

    /// A file under a repository was written (by us) or its index changed:
    /// its git blocks refresh, its open files' gutters are redone.
    private func gitChanged(under path: String) {
        guard let root = git.root(of: path) else { return }
        // Listing the status can itself touch what's watched: refreshes a
        // repository's changes bring come no closer than a second apart,
        // the ones in between folded into one.
        if let last = gitRefreshedAt[root], Date().timeIntervalSince(last) < 1 {
            guard gitRefreshDue[root] == nil else { return }
            let work = DispatchWorkItem { [weak self] in
                self?.gitRefreshDue[root] = nil
                self?.gitChanged(under: path)
            }
            gitRefreshDue[root] = work
            queue.asyncAfter(deadline: .now() + 1, execute: work)
            return
        }
        gitRefreshedAt[root] = Date()
        for b in node.blocks where b.kind == .git && b.path == root { refreshGit(b.id) }
        for b in node.blocks where b.kind == .text && gutterWork[b.id] != nil && (b.path?.hasPrefix(root + "/") ?? false) { scheduleGutter(b.id) }
    }

    private func watchRepo(_ root: String, _ vcs: VCS) {
        guard repoWatchers[root] == nil else { return }
        let index = root.appendingPathComponent(vcs.stateFile)
        repoWatchers[root] = FileWatcher(path: index, queue: queue) { [weak self] in self?.gitChanged(under: index) }
    }

    private func loadDiff(_ block: BlockID) {
        guard let b = node.block(block), b.kind == .diff, let subject = b.diff?.subject else { return }
        report(block, .working, msg: "Comparing")
        switch subject {
        case let .sides(old, new):
            func side(_ s: DiffSide, _ done: @escaping (String?) -> Void) {
                if let rev = s.revision { git.show(s.path, at: rev, done: done) } else { done(TextFile.read(s.path)?.text ?? "") }
            }
            side(old) { [weak self] oldText in
                side(new) { newText in
                    guard let self, self.node.block(block) != nil else { return }
                    self.append(.diffLoaded(oldText: oldText ?? "", newText: newText ?? "", patch: nil, error: nil, at: self.clock.now()), to: .block(block))
                    self.report(block, .done, msg: "Compared")
                }
            }
        case .patch:
            break // given whole; nothing to read again
        case let .versions(id, from, to):
            let entries = store.entries(.block(id))
            let old = Block.replaying(entries, id: id, upTo: from)?.text?.text.string ?? ""
            let new = to.map { Block.replaying(entries, id: id, upTo: $0)?.text?.text.string ?? "" } ?? (node.block(id)?.text?.text.string ?? "")
            append(.diffLoaded(oldText: old, newText: new, patch: nil, error: nil, at: clock.now()), to: .block(block))
            report(block, .done, msg: "Compared")
        case let .commit(repo, sha):
            let vcs = git.repository(of: repo)?.vcs ?? .git
            git.run(vcs, vcs.showArguments(sha), in: repo) { [weak self] result in
                guard let self, self.node.block(block) != nil else { return }
                switch result {
                case .success(let patch):
                    self.append(.diffLoaded(oldText: nil, newText: nil, patch: patch, error: nil, at: self.clock.now()), to: .block(block))
                    self.report(block, .done, msg: "Compared")
                case .failure(let e):
                    self.append(.diffLoaded(oldText: nil, newText: nil, patch: nil, error: e.message, at: self.clock.now()), to: .block(block))
                    self.report(block, .error, msg: e.message)
                }
            }
        }
    }

    // MARK: Files

    /// Fingerprints of files we just wrote, so the watcher ignores them.
    private var expectedFingerprints: [BlockID: String] = [:]

    private func watch(_ block: Block, force: Bool = false) {
        guard let path = block.path else {
            watchers.removeValue(forKey: block.id)
            return
        }
        if !force, watchers[block.id] != nil { return }
        let id = block.id
        watchers[id] = FileWatcher(path: path, queue: queue) { [weak self] in self?.fileChanged(id) }
    }

    private func fileChanged(_ id: BlockID) {
        guard let b = node.block(id), let path = b.path, let t = b.text else { return }
        guard let fingerprint = TextFile.fingerprint(path) else { return }
        if fingerprint == t.diskFingerprint || fingerprint == expectedFingerprints[id] { return }
        guard let contents = TextFile.read(path) else { return }
        let proposal: HostProposal = t.isDirty
            ? .stale
            : .content(contents.text, encoding: contents.encoding, lineEnding: contents.lineEnding, fingerprint: contents.fingerprint)
        let frame = Frame.message(ServerMessage.propose(shard: .block(id), proposal))
        // The leader is whichever client is attached; with one, that's it.
        if let leader = clients.first { leader.send(frame) }
    }

    // MARK: Sessions

    private func attach(_ conn: Connection, _ req: AttachRequest) {
        let id = req.block
        if node.block(id) == nil {
            append(.create(kind: .terminal, title: nil, path: nil), to: .block(id))
        }
        guard let block = node.block(id), block.kind == .terminal || block.kind == .agent, let state = block.terminal else {
            conn.close()
            return
        }
        if block.isArchived {
            // Archived: the transcript as it was, and nothing more — no
            // shell; what's typed goes nowhere.
            let history = (try? Data(contentsOf: historyFile(id))) ?? Data()
            conn.send(Frame(.data, history))
            conn.send(Frame(.replayDone, Data([0])))
            conn.onFrame = { _ in }
            return
        }
        let session: Session
        if let existing = sessions[id] {
            session = existing
        } else {
            var history = (try? Data(contentsOf: historyFile(id))) ?? Data()
            if let since = state.dormantSince, !history.isEmpty {
                history.append(Session.seam(idle: state.dormantAfter ?? 0, since: since.date))
            }
            guard let s = Session(id: id, cwd: state.cwd, cols: req.cols, rows: req.rows,
                                  env: req.env, history: history, command: state.command, queue: queue) else {
                conn.close()
                return
            }
            s.onExit = { [weak self] status in self?.sessionExited(id, status: status) }
            s.onTitle = { [weak self] title in
                guard self?.node.block(id)?.terminal?.title != title else { return }
                self?.append(.title(title), to: .block(id))
            }
            s.onStatus = { [weak self] signals in self?.status(id, signals) }
            sessions[id] = s
            session = s
            append(.shell(.started(pid: s.pid)), to: .block(id))
        }
        conn.onFrame = { [weak session, unowned conn] frame in session?.handle(frame, from: conn) }
        conn.onClose = { [weak session, unowned conn] in session?.detach(conn) }
        session.attach(conn, cols: req.cols, rows: req.rows)
    }

    // MARK: Status (§3.7)

    /// The host's own report on a block it works for: its root record.
    /// Only a terminal's program says what its status is (§3.7), for now:
    /// the host keeps quiet about the blocks it works for itself.
    private func reportsStatus(_ block: BlockID) -> Bool {
        guard let k = node.block(block)?.kind else { return false }
        return k == .terminal || k == .agent
    }

    private func report(_ block: BlockID, _ state: StatusState, msg: String? = nil) {
        guard reportsStatus(block) else { return }
        append(.status(id: rootStatusID, StatusRecord(state: state, msg: msg, at: clock.now())), to: .block(block))
    }

    /// What a terminal's program said, applied to its block's records.
    private func status(_ block: BlockID, _ signals: [StatusSignal]) {
        guard let b = node.block(block) else { return }
        for signal in signals {
            switch signal {
            case let .report(id, state, kind, progress, app, title, msg):
                // A record without an app inherits its nearest ancestor's.
                var app = app
                if app == nil {
                    var parent = id
                    while app == nil, let slash = parent.lastIndex(of: "/") {
                        parent = String(parent[..<slash])
                        app = node.block(block)?.status?[parent]?.app
                    }
                    if app == nil, !id.isEmpty { app = node.block(block)?.status?[rootStatusID]?.app }
                }
                append(.status(id: id, StatusRecord(state: state, kind: kind, progress: progress, app: app, title: title, msg: msg, at: clock.now())), to: .block(block))
            case let .clear(id):
                append(.status(id: id ?? rootStatusID, nil), to: .block(block))
            case .query:
                break // answered by the session, on the program's input
            case .prompt:
                for (k, r) in node.block(block)?.status ?? [:] where r.state == .working || r.state == .blocked {
                    append(.status(id: k, nil), to: .block(block))
                }
            case let .command(text):
                // A command the shell is about to run (§3.8), after the ones
                // before it.
                let list = node.block(block)?.terminal?.commands ?? []
                append(.ran(id: (list.last?.id ?? 0) + 1, text, at: clock.now()), to: .block(block))
            case let .commandEnded(status):
                if let open = node.block(block)?.terminal?.commands?.last(where: { $0.ended == nil }) {
                    append(.exited(id: open.id, status: status ?? 0, at: clock.now()), to: .block(block))
                }
            case let .directory(host, path):
                // The shell says where it is (OSC 7): taken when it's on
                // this host — a shell on another machine, through ssh in
                // the terminal, is left to say so without moving the block.
                guard Self.isThisHost(host) else { break }
                sessions[block]?.reportsDirectory = true
                if b.terminal?.cwd != path { append(.cwd(path), to: .block(block)) }
            case let .progress(p, percent):
                switch p {
                case .remove:
                    if b.status?[rootStatusID] != nil { append(.status(id: rootStatusID, nil), to: .block(block)) }
                case .set: report(block, .working, progress: percent)
                case .indeterminate: report(block, .working)
                case .error: report(block, .error)
                case .pause: report(block, .working, progress: percent, msg: "Paused")
                }
            }
        }
    }

    private func report(_ block: BlockID, _ state: StatusState, progress: Int?, msg: String? = nil) {
        guard reportsStatus(block) else { return }
        append(.status(id: rootStatusID, StatusRecord(state: state, progress: progress, msg: msg, at: clock.now())), to: .block(block))
    }

    private func sessionExited(_ id: BlockID, status: Int32) {
        guard let s = sessions.removeValue(forKey: id) else { return }
        // Its transcript whole, for the archived block to show as it was.
        try? FileManager.default.createDirectory(at: historyDirectory, withIntermediateDirectories: true)
        try? s.takeHistory().write(to: historyFile(id), options: .atomic)
        if s.endedForIdleness {
            append(.shell(.dormant(idleSeconds: s.idleSeconds)), to: .block(id))
        } else {
            // The shell ended for good: the block is archived (§3.7) — kept
            // as it was, its transcript to be recalled, no shell to start.
            append(.shell(.ended(status: status)), to: .block(id))
            if node.block(id)?.isArchived != true { append(.archived(true), to: .block(id)) }
        }
    }

    /// Whether a host a shell names is this one: none, localhost, or this
    /// machine's name, short or long, however the case.
    static func isThisHost(_ name: String) -> Bool {
        let h = name.lowercased()
        if h.isEmpty || h == "localhost" { return true }
        var buf = [CChar](repeating: 0, count: 256)
        guard gethostname(&buf, buf.count) == 0 else { return false }
        let mine = String(cString: buf).lowercased()
        return h == mine || h.split(separator: ".").first == mine.split(separator: ".").first
    }

    private func pollSessions() {
        for (id, session) in sessions {
            guard let t = node.block(id)?.terminal else { continue }
            // A shell that reports its directory itself (OSC 7) is believed;
            // the rest are asked, through the process, every so often.
            if !session.reportsDirectory, let cwd = session.cwd, t.cwd != cwd {
                append(.cwd(cwd), to: .block(id))
            }
            let busy = session.isBusy
            if busy != t.busy { append(.shell(.busy(busy)), to: .block(id)) }
        }
    }

    /// Terminals off screen with an idle shell for long enough go dormant:
    /// the shell is ended, the transcript kept (§4).
    private func collectTerminals() {
        let hours = node.desk(host).settings.terminalDormantAfterHours
        guard hours > 0 else { return }
        let cutoff = Int64(Date().addingTimeInterval(-Double(hours) * 3600).timeIntervalSince1970 * 1000)
        let registry = node.registry(host)
        for (id, session) in sessions {
            guard let entry = registry.blocks[id], entry.lastSeen.wall < cutoff, !session.isBusy, !session.isAttached else { continue }
            let idle = Int(Date().timeIntervalSince1970 - Double(entry.lastSeen.wall) / 1000)
            log("terminal \(id) idle \(idle)s off screen: going dormant")
            session.endForIdleness(idleSeconds: idle)
        }
    }

    // MARK: Persistence

    /// Each terminal's recent output is kept on disk too, so that when the
    /// server starts over (after a restart, say) its terminal shows what it
    /// showed.
    private var historyDirectory: URL { Paths.directory.appendingPathComponent("history") }

    private func historyFile(_ block: BlockID) -> URL {
        historyDirectory.appendingPathComponent(block.ulid)
    }

    private func saveHistory() {
        try? FileManager.default.createDirectory(at: historyDirectory, withIntermediateDirectories: true)
        for (id, session) in sessions where session.unsaved {
            try? session.takeHistory().write(to: historyFile(id), options: .atomic)
        }
    }

    private func pruneHistory() {
        let live = Set((node.blocks(of: .terminal) + node.blocks(of: .agent)).map(\.id.ulid))
        let files = (try? FileManager.default.contentsOfDirectory(atPath: historyDirectory.path)) ?? []
        for f in files where !live.contains(f) {
            try? FileManager.default.removeItem(at: historyDirectory.appendingPathComponent(f))
        }
    }

    private func load() {
        let shards = store.shards()
        if shards.isEmpty, let data = try? Data(contentsOf: Paths.state) {
            migrate(data)
        }
        for shard in store.shards() {
            store.load(shard, into: node)
        }
        var n = 0
        for s in node.shards.values { n += s.seq }
        log("loaded \(node.shards.count) shards, \(n) entries")
        if !node.has(.desk(host)) { append(.settings(Settings()), to: .desk(host)) }
        if !node.has(.registry(host)) { append(.seen([], at: clock.now()), to: .registry(host)) }
        for block in node.blocks(of: .text) { watch(block) }
        for shard in node.shards.keys { shardChanged(shard) }
    }

    /// A `state.json` from before blocks becomes logs.
    private func migrate(_ data: Data) {
        let editors = Paths.directory.appendingPathComponent("editors")
        let out = Migration.migrate(stateJSON: data, editorsDirectory: editors, readFile: { TextFile.read($0)?.text },
                                    host: host, clock: clock)
        for (shard, entries) in out { store.append(entries, to: shard) }
        store.closeAll()
        try? FileManager.default.moveItem(at: Paths.state, to: Paths.state.appendingPathExtension("migrated"))
        log("migrated \(out.count) shards from \(Paths.state.lastPathComponent)")
    }

    private func writeSnapshots() {
        for shard in dirtyShards { store.snapshot(node, shard) }
        dirtyShards = []
    }

    private var lastRetention = Date.distantPast

    /// Retention, by the settings (§4), once an hour: text history older
    /// than `textHistoryDays` is folded into each block's base; transcripts
    /// of terminals dormant longer than `terminalHistoryDays` go.
    private func retain() {
        guard Date().timeIntervalSince(lastRetention) > 3600 else { return }
        lastRetention = Date()
        let settings = node.desk(host).settings
        if settings.textHistoryDays > 0 {
            let cutoff = Stamp(wall: Int64(Date().addingTimeInterval(-Double(settings.textHistoryDays) * 86400).timeIntervalSince1970 * 1000), logical: 0, host: host)
            for b in node.blocks(of: .text) {
                writeSnapshots()
                store.compact(.block(b.id), before: cutoff, node: node)
            }
        }
        // A git block's refreshes, and a process block's listings, replace
        // one another: their logs are folded into their bases whole.
        for b in node.blocks(of: .git) + node.blocks(of: .process) { store.fold(.block(b.id), node: node) }
        if settings.terminalHistoryDays > 0 {
            let cutoff = Int64(Date().addingTimeInterval(-Double(settings.terminalHistoryDays) * 86400).timeIntervalSince1970 * 1000)
            for b in node.blocks(of: .terminal) + node.blocks(of: .agent) {
                guard let t = b.terminal, t.pid == nil, let since = t.dormantSince, since.wall < cutoff, sessions[b.id] == nil else { continue }
                try? FileManager.default.removeItem(at: historyFile(b.id))
            }
        }
    }

    /// Exits, saving state first. Sessions die with us either way, as their
    /// terminals hang up when we go; `endSessions` hangs up on them first.
    private func exit(endSessions: Bool) {
        languageServers.stopAll()
        searches.stopAll()
        if endSessions {
            for s in sessions.values { s.terminate() }
        }
        writeSnapshots()
        store.closeAll()
        if endSessions {
            try? FileManager.default.removeItem(at: historyDirectory)
        } else {
            saveHistory()
        }
        unlink(Paths.socket)
        log("manifoldd exiting")
        sysExit(0)
    }

    // MARK: For `manifoldd state`

    func describe() -> String {
        var out = "host \(host)\n"
        let desk = node.desk(host)
        out += "desk: \(desk.order.count) workspaces, selected \(desk.selected.map(\.description) ?? "none")\n"
        for b in node.blocks.sorted(by: { $0.created < $1.created }) {
            out += "\(b.id) \(b.kind) \"\(b.displayTitle)\""
            if let p = b.path { out += " \(p)" }
            if let a = b.arrangement { out += " columns=\(a.columns.map(\.count))" }
            if let t = b.text { out += " v\(t.version) clean\(t.cleanVersion)\(t.isDirty ? " dirty" : "")" }
            if let t = b.terminal { out += " cwd=\(t.cwd ?? "-")\(t.busy ? " busy" : "")\(t.dormantSince != nil ? " dormant" : "")" }
            out += "\n"
        }
        return out
    }
}
