import CPTY
import Foundation
import ManifoldCore

enum ServerError: Error {
    case alreadyRunning
}

/// A host: every shard's log, the registry and links, the shells, the files.
/// The app attaches and mirrors; it leads the shards it edits (arrangements,
/// text, the desk) and asks for the rest by proposal. Everything runs on one
/// serial queue.
final class Server {
    let host = HostID.local
    private let queue = DispatchQueue(label: "manifoldd")
    private let node = Node()
    private let store: LogStore
    private let clock = Clock(host: .local)
    private var clients: [Connection] = []
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

    init() {
        store = LogStore(directory: Paths.logs)
    }

    func run() throws {
        Paths.ensureDirectory()
        // One server per directory: a second one exits quietly.
        let lock = open(Paths.directory.appendingPathComponent("manifoldd.lock").path, O_CREAT | O_RDWR | O_CLOEXEC, 0o600)
        guard lock >= 0, flock(lock, LOCK_EX | LOCK_NB) == 0 else { throw ServerError.alreadyRunning }
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
            let fd = Darwin.accept(listenFD, nil, nil)
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
        case .hello?:
            clients.append(conn)
            attachments += 1
            conn.onFrame = { [weak self, unowned conn] frame in self?.clientFrame(frame, from: conn) }
            conn.onClose = { [weak self, unowned conn] in self?.clients.removeAll { $0 === conn } }
            let snapshots = node.shards.keys.sorted { $0.description < $1.description }.compactMap { node.snapshot($0) }
            conn.send(.message(ServerMessage.welcome(version: protocolVersion, pid: getpid(), host: host,
                                                     attachment: attachments, snapshots: snapshots)))
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
        case let .append(shard, entries)?:
            clientAppended(shard, entries, from: conn)
        case let .propose(id, proposal)?:
            propose(id, proposal, from: conn)
        case .shutdown?:
            exit(endSessions: true)
        default:
            break
        }
    }

    // MARK: Entries

    /// The client, leading a shard, appended to it: kept and passed on, if
    /// it continues the log; else the client is sent the log as it is.
    private func clientAppended(_ shard: ShardID, _ entries: [Entry], from conn: Connection) {
        guard let first = entries.first else { return }
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
        shardChanged(shard)
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
    private func shardChanged(_ shard: ShardID) {
        guard let id = shard.block, let block = node.block(id) else { return }
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
        case let .seen(ids):
            let known = ids.filter { node.registry(host).blocks[$0] != nil }
            if !known.isEmpty { append(.seen(known, at: clock.now()), to: .registry(host)) }
            done()
        case let .link(link):
            append(.link(link), to: .links(host))
            done()
        case let .unlink(linkID):
            append(.unlink(linkID), to: .links(host))
            done()
        case let .history(shard):
            conn.send(.message(ServerMessage.history(shard: shard, entries: store.entries(shard))))
            done()
        }
    }

    private func list(_ block: BlockID) {
        guard let b = node.block(block), b.kind == .directory, let path = b.path else { return }
        if let entries = TextFile.list(path) {
            append(.entries(entries, at: clock.now()), to: .block(block))
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
        guard let block = node.block(id), block.kind == .terminal, let state = block.terminal else {
            conn.close()
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
                                  env: req.env, history: history, queue: queue) else {
                conn.close()
                return
            }
            s.onExit = { [weak self] status in self?.sessionExited(id, status: status) }
            s.onTitle = { [weak self] title in
                guard self?.node.block(id)?.terminal?.title != title else { return }
                self?.append(.title(title), to: .block(id))
            }
            sessions[id] = s
            session = s
            append(.shell(.started(pid: s.pid)), to: .block(id))
        }
        conn.onFrame = { [weak session] frame in session?.handle(frame) }
        conn.onClose = { [weak session, unowned conn] in session?.detach(conn) }
        session.attach(conn, cols: req.cols, rows: req.rows)
    }

    private func sessionExited(_ id: BlockID, status: Int32) {
        guard let s = sessions.removeValue(forKey: id) else { return }
        if s.endedForIdleness {
            append(.shell(.dormant(idleSeconds: s.idleSeconds)), to: .block(id))
        } else {
            append(.shell(.ended(status: status)), to: .block(id))
        }
    }

    private func pollSessions() {
        for (id, session) in sessions {
            guard let t = node.block(id)?.terminal else { continue }
            if let cwd = session.cwd, t.cwd != cwd {
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
        let live = Set(node.blocks(of: .terminal).map(\.id.ulid))
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

    /// Exits, saving state first. Sessions die with us either way, as their
    /// terminals hang up when we go; `endSessions` hangs up on them first.
    private func exit(endSessions: Bool) {
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
        Darwin.exit(0)
    }

    // MARK: For `manifoldd state`

    func describe() -> String {
        var out = "host \(host)\n"
        let desk = node.desk(host)
        out += "desk: \(desk.order.count) arrangements, selected \(desk.selected.map(\.description) ?? "none")\n"
        for b in node.blocks.sorted(by: { $0.created < $1.created }) {
            out += "\(b.id) \(b.kind) \"\(b.displayTitle)\""
            if let p = b.path { out += " \(p)" }
            if let a = b.arrangement { out += " columns=\(a.columns.map(\.count)) layout=\(a.layout)" }
            if let t = b.text { out += " v\(t.version) clean\(t.cleanVersion)\(t.isDirty ? " dirty" : "")" }
            if let t = b.terminal { out += " cwd=\(t.cwd ?? "-")\(t.busy ? " busy" : "")\(t.dormantSince != nil ? " dormant" : "")" }
            out += "\n"
        }
        return out
    }
}
