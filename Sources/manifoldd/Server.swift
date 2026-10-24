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
    /// The language servers' table as the app last gave it (the desk's),
    /// before this host's own settings are put over it.
    private var deskLanguageServers = LanguageServerConfig.defaults
    private let node = Node()
    private let store: LogStore
    private let clock: Clock
    private var clients: [any Channel] = []
    /// Each client's attachment number, and the app among them (named so).
    private var clientIDs: [ObjectIdentifier: Int] = [:]
    private var appClients: Set<ObjectIdentifier> = []
    /// `mani` commands passed on to the app and not yet answered in full,
    /// by the client that asked: the app is told when it goes.
    private var commandsOut: [Int: Set<Int>] = [:]
    /// Which attachment holds the pen for each shard a client may lead
    /// (§8.2): the last to focus its block, or the first to append.
    private var owners: [ShardID: ObjectIdentifier] = [:]
    /// Connections that haven't said what they are yet.
    private var pending: [any Channel] = []
    private var attachments = 0
    private var sessions: [BlockID: Session] = [:]
    /// Shell notebooks' shells (§7.7), and what a running cell has printed
    /// that the clients haven't been sent yet.
    private var notebooks: [BlockID: NotebookShell] = [:]
    /// Forwarded ports' connections (§8), by the client they're for and id.
    private var notebookLive: [BlockID: (cell: String, output: Data)] = [:]
    private var notebookLiveScheduled: Set<BlockID> = []
    /// When each notebook's running cell was last interrupted: asked again
    /// while it still runs, its program is killed.
    private var notebookInterrupted: [BlockID: Date] = [:]
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

    /// The shape of what's on disk. When it changes without a migration,
    /// the logs, snapshots and transcripts are set aside and the host
    /// starts afresh — its identity (the session file) kept, so clients
    /// and other hosts still know it.
    static let dataFormat = 2

    private static func resetIfFormatChanged() {
        let marker = Paths.directory.appendingPathComponent("format")
        let found = (try? String(contentsOf: marker, encoding: .utf8)).flatMap { Int($0.trimmingCharacters(in: .whitespacesAndNewlines)) }
        guard found != dataFormat else { return }
        let fm = FileManager.default
        let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
        for name in ["logs", "history", "editors"] {
            let url = Paths.directory.appendingPathComponent(name)
            guard fm.fileExists(atPath: url.path) else { continue }
            try? fm.moveItem(at: url, to: Paths.directory.appendingPathComponent("\(name).before-format-\(dataFormat)-\(stamp)"))
        }
        try? "\(dataFormat)\n".write(to: marker, atomically: true, encoding: .utf8)
        log("data format \(found.map(String.init) ?? "none") → \(dataFormat): logs set aside, starting afresh")
    }

    init() throws {
        Paths.ensureDirectory()
        // One server per directory: a second one exits quietly. Taken
        // before anything is read or rewritten.
        lock = open(Paths.directory.appendingPathComponent("manifoldd.lock").path, O_CREAT | O_RDWR | O_CLOEXEC, 0o600)
        guard lock >= 0, flock(lock, LOCK_EX | LOCK_NB) == 0 else { throw ServerError.alreadyRunning }
        Server.resetIfFormatChanged()
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
        mentions.mentions = { [weak self] block in
            guard let g = self?.node.graph else { return [] }
            return g.edges(from: block, kind: .link(.opened)).filter { $0.context?.hasPrefix("[[") == true }
                + g.edges(from: block, kind: .link(.embeds)).filter { $0.context?.hasPrefix("![") == true }
        }
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
        // Its language servers as its own settings say, from the start.
        languageServers.configure(LanguageServerConfig.applying(deskLanguageServers, node.desk(host).preferences.lsp))
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
            self?.writeSnapshots(later: true)
            self?.collectTerminals()
            self?.collect()
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
            // One connection, its streams in it (§8): what each is, its
            // first frame says — the connection's own, a client's hello.
            let mux = Mux(Connection(fd: fd, queue: queue))
            let conn = mux.control
            conn.onFrame = { [weak self, unowned conn] frame in self?.firstFrame(frame, on: conn) }
            conn.onClose = { [weak self, unowned conn] in self?.pending.removeAll { $0 === conn } }
            mux.onStream = { [weak self] stream in
                stream.onFrame = { [weak self, unowned stream] frame in self?.firstFrame(frame, on: stream) }
            }
            pending.append(conn)
            mux.start()
        }
    }

    private func firstFrame(_ frame: Frame, on conn: any Channel) {
        pending.removeAll { $0 === conn }
        conn.onClose = nil
        switch frame.decode(ClientMessage.self) {
        case let .hello(_, name)?:
            clients.append(conn)
            attachments += 1
            clientIDs[ObjectIdentifier(conn)] = attachments
            if name == "Manifold" {
                appClients.insert(ObjectIdentifier(conn))
                indexAgents()
            }
            conn.onFrame = { [weak self, unowned conn] frame in self?.clientFrame(frame, from: conn) }
            conn.onClose = { [weak self, unowned conn] in
                self?.commandsEnded(by: conn)
                self?.clients.removeAll { $0 === conn }
                self?.clientIDs.removeValue(forKey: ObjectIdentifier(conn))
                self?.appClients.remove(ObjectIdentifier(conn))
                self?.owners = self?.owners.filter { $0.value != ObjectIdentifier(conn) } ?? [:]
            }
            // `mani` needs none of it: only that the versions agree.
            let snapshots = name == Mani.name ? [] : node.shards.keys.sorted { $0.description < $1.description }.compactMap { node.snapshot($0) }
            conn.send(.message(ServerMessage.welcome(version: protocolVersion, pid: getpid(), host: host, label: label,
                                                     attachment: attachments, home: NSHomeDirectory(), snapshots: snapshots,
                                                     features: serverFeatures)))
        case .attach(let req)?:
            attach(conn, req)
        case .backfill(let req)?:
            // A terminal's history after its screen, on a stream of its own.
            guard let stream = conn as? MuxStream, let session = sessions[req.block] else { return conn.close() }
            session.backfill(req, to: stream)
        case let .tunnel(port)?:
            guard let stream = conn as? MuxStream else { return conn.close() }
            tunnel(stream, to: port)
        // Files, each on a stream of its own (§8): read and written off the
        // queue, paced to the link.
        case let .readFile(path, offset, length, limit)?:
            guard let stream = conn as? MuxStream else { return conn.close() }
            FileSender.start(stream, path: path, offset: offset, length: length, limit: limit, queue: queue)
        // Trees (§8): what a copy is — a file or a folder and all in it.
        case let .readTree(path)?:
            guard let stream = conn as? MuxStream else { return conn.close() }
            let source = TreeSource(stream, root: path)
            source.onFinished = { [weak stream] _ in stream?.close() }
            stream.onClose = { source.cancel() }
            stream.onFrame = { _ in }
            source.start()
        case let .writeTree(path, replace)?:
            guard let stream = conn as? MuxStream else { return conn.close() }
            let sink = TreeSink(stream, destination: path, replace: replace)
            if sink.refusedAtOnce() {
                stream.send(.message(TreeMessage.end(error: "exists", path: nil)))
                return stream.close()
            }
            sink.onFinished = { [weak stream] error, path in
                stream?.send(.message(TreeMessage.end(error: error, path: path)))
                stream?.close()
            }
            stream.onFrame = { frame in sink.received(frame) }
            stream.onClose = { sink.cut() }
        case let .copyTree(from, to, replace)?:
            guard let stream = conn as? MuxStream else { return conn.close() }
            let copier = TreeCopier(from: from, to: to, replace: replace)
            copier.onProgress = { [weak stream] done, total in stream?.send(.message(TreeMessage.progress(done: done, total: total))) }
            copier.onFinished = { [weak stream] error, path in
                stream?.send(.message(TreeMessage.end(error: error, path: path)))
                stream?.close()
            }
            stream.onFrame = { _ in }
            stream.onClose = { copier.cancel() }
            copier.start()
        case let .saveImage(block, name, folder)?:
            // Beside a Markdown file; for a note, in Manifold's own folder.
            guard let stream = conn as? MuxStream else { return conn.close() }
            FileReceiver.start(stream, path: (folder ?? Self.imagesFolder) + "/" + name, mode: .unique, queue: queue) { [weak self] path in
                guard let self, self.node.block(block) == nil else { return }
                self.append(.create(kind: .image, title: nil, path: path), to: .block(block))
            }
        case let .agent(block, event)?:
            agentEvent(block, event)
            conn.close()
        case .shutdown?:
            exit(endSessions: true)
        default:
            conn.close()
        }
    }

    /// A panel widget's command (§7.8): run by sh in the panel's folder,
    /// with Manifold's tools on the PATH, the panel as MANIFOLD_BLOCK (so
    /// `mani ui set @here …` sets its values) and what happened as
    /// MANI_EVENT and MANI_VALUE; what it prints goes to the log.
    private func runPanel(_ block: BlockID, command: String, event: String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", command]
        var env = ProcessInfo.processInfo.environment
        let tools = Session.toolDirectories
        env["PATH"] = (tools + [env["PATH"] ?? "/usr/bin:/bin"]).joined(separator: ":")
        env["MANIFOLD_BLOCK"] = block.description
        env["MANIFOLD_HOST"] = block.host.raw
        env["MANI_EVENT"] = event
        if let data = event.data(using: .utf8), let o = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any], let v = o["value"] {
            env["MANI_VALUE"] = (v as? String) ?? (try? JSONSerialization.data(withJSONObject: v, options: .fragmentsAllowed)).map { String(decoding: $0, as: UTF8.self) } ?? ""
        }
        p.environment = env
        let home = node.block(block)?.home ?? NSHomeDirectory()
        p.currentDirectoryURL = URL(fileURLWithPath: FileManager.default.fileExists(atPath: home) ? home : NSHomeDirectory())
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        p.standardInput = FileHandle.nullDevice
        p.terminationHandler = { proc in
            let out = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile().prefix(4000), as: UTF8.self)
            log("panel \(block): `\(command)` ended \(proc.terminationStatus)\(out.isEmpty ? "" : ": " + out)")
        }
        do { try p.run() } catch { log("panel \(block): `\(command)` didn't start: \(error)") }
    }

    /// A client gone with `mani` commands unanswered: the app stops on them.
    private func commandsEnded(by conn: any Channel) {
        guard let client = clientIDs[ObjectIdentifier(conn)], let ids = commandsOut.removeValue(forKey: client), !ids.isEmpty,
              let app = clients.first(where: { appClients.contains(ObjectIdentifier($0)) && $0 !== conn }) else { return }
        for id in ids { app.send(.message(ServerMessage.commandEnded(id: id, client: client))) }
    }

    private func clientFrame(_ frame: Frame, from conn: any Channel) {
        switch frame.decode(ClientMessage.self) {
        case .ping?:
            conn.send(.message(ServerMessage.pong))
        case let .append(shard, entries)?:
            clientAppended(shard, entries, from: conn)
        case let .own(shard)?:
            own(shard, by: conn)
        case let .resync(shard)?:
            if let snap = node.snapshot(shard) { conn.send(.message(ServerMessage.snapshot(snap))) }
        case let .propose(id, proposal)?:
            propose(id, proposal, from: conn)
        case let .command(id, request)?:
            // `mani` asks; the app, if attached, does it and answers.
            guard let app = clients.first(where: { appClients.contains(ObjectIdentifier($0)) }) else {
                conn.send(.message(ServerMessage.done(id: id, error: "Manifold isn't attached to this host")))
                return
            }
            let client = clientIDs[ObjectIdentifier(conn)] ?? 0
            commandsOut[client, default: []].insert(id)
            app.send(.message(ServerMessage.command(id: id, client: client, request)))
        case let .openPatch(id, patch, root, title, beside)?:
            // `mani diff`: the patch becomes a diff block here, and the
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
    private func own(_ shard: ShardID, by conn: any Channel) {
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
    private func clientAppended(_ shard: ShardID, _ entries: [Entry], from conn: any Channel) {
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

    /// Where a note's images are kept: Manifold's own, on this host.
    static var imagesFolder: String { Paths.directory.appendingPathComponent("Images").path }

    // MARK: Collection (§4)

    /// When each block was first found unreachable; forgotten when it is
    /// reached again, or collected.
    private var unreachableSince: [BlockID: Date] = [:]

    /// A block gone for good: its session ended, its file unwatched, its
    /// links here gone, its log deleted, and the registry told, which
    /// every replica follows.
    private func discard(_ block: BlockID) {
        sessions.removeValue(forKey: block)?.terminate()
        notebooks.removeValue(forKey: block)?.terminate()
        watchers.removeValue(forKey: block)
        unreachableSince.removeValue(forKey: block)
        guard let b = node.block(block) else { return }
        // An image Manifold kept for a note goes with its block.
        if b.kind == .image, let path = b.path, path.hasPrefix(Self.imagesFolder + "/") { try? FileManager.default.removeItem(atPath: path) }
        for l in node.links(host).links where l.from == block || l.to == block { append(.unlink(l.id), to: .links(host)) }
        node.remove(.block(block))
        store.delete(.block(block))
        append(.unregister(block), to: .registry(host))
    }

    /// Unnamed workspaces drift (§3.3): one unseen for the days the
    /// settings give leaves the desk, a root no longer, and is collected
    /// with whatever only it held once the grace has passed.
    private func drift() {
        let days = node.desk(host).settings.workspaceDriftDays
        guard days > 0 else { return }
        let cutoff = Int64(Date().addingTimeInterval(-Double(days) * 86400).timeIntervalSince1970 * 1000)
        let desk = node.desk(host)
        let registry = node.registry(host)
        let kept = desk.order.filter { id in
            guard id.host == host, let b = node.block(id), let a = b.arrangement, !a.isNamed, (b.title ?? "").isEmpty, !node.hasPins(id) else { return true }
            let seen = registry.blocks[id]?.lastSeen.wall ?? b.created.wall
            return seen >= cutoff
        }
        if kept != desk.order {
            for id in desk.order where !kept.contains(id) { log("workspace \(id) unseen for \(days) days: off the desk") }
            append(.order(kept), to: .desk(host))
        }
    }

    /// The collector (§4): what no root reaches over strong edges —
    /// workspaces on the desk and named ones, kept
    /// blocks, other hosts' holds — is noted, and collected once it has
    /// been so for the grace the settings give. Reached again meanwhile,
    /// it is simply kept.
    private func collect() {
        drift()
        let minutes = node.desk(host).settings.collectAfterMinutes
        guard minutes > 0 else { return }
        let reachable = node.reachable(on: host)
        let now = Date()
        var gone: [BlockID] = []
        for b in node.blocks where b.id.host == host {
            if reachable.contains(b.id) {
                unreachableSince.removeValue(forKey: b.id)
                continue
            }
            let since = unreachableSince[b.id] ?? { unreachableSince[b.id] = now; return now }()
            if now.timeIntervalSince(since) >= Double(minutes) * 60 { gone.append(b.id) }
        }
        for id in gone {
            let what = node.block(id).map { "\($0.kind) \"\($0.displayTitle)\"" } ?? "block"
            log("collected \(what) \(id): reached by nothing for \(minutes) min")
            discard(id)
        }
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
        if block.kind == .text { watch(block) }
    }

    // MARK: Proposals

    private func propose(_ id: Int, _ proposal: Proposal, from conn: any Channel) {
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
                // Its repository as it starts, to show what it changed since.
                if let cwd, let (root, vcs) = git.repository(of: cwd), vcs == .git {
                    git.snapshotTree(root) { [weak self] tree in
                        guard let self, let tree else { return }
                        self.append(.snapshot(TreeSnapshot(repo: root, tree: tree, at: self.clock.now())), to: .block(block))
                    }
                }
            }
            done()
        case let .newNotebook(block, cwd):
            if node.block(block) == nil {
                append(.create(kind: .notebook, title: nil, path: nil), to: .block(block))
                if let cwd { append(.cwd(cwd), to: .block(block)) }
                append(.notebook(.insert(NotebookCell(id: NotebookCell.newID()), at: 0)), to: .block(block))
            }
            startNotebook(block)
            done()
        case let .editNotebook(block, edit):
            guard edit.isUsers, let nb = node.block(block)?.notebook else { return done("not a notebook") }
            if case let .remove(cell) = edit, nb.running == cell { notebooks[block]?.interrupt() }
            append(.notebook(edit), to: .block(block))
            done()
        case let .runCells(block, cells):
            guard let nb = node.block(block)?.notebook else { return done("not a notebook") }
            log("notebook \(block): run asked for \(cells), running \(nb.running ?? "nothing"), waiting \(nb.queued)")
            var queue = nb.queued
            for c in cells where c != nb.running && !queue.contains(c) && nb.cell(c) != nil { queue.append(c) }
            if queue != nb.queued { append(.notebook(.queued(queue)), to: .block(block)) }
            advanceNotebook(block)
            done()
        case let .interruptNotebook(block):
            guard let nb = node.block(block)?.notebook else { return done("not a notebook") }
            if !nb.queued.isEmpty { append(.notebook(.queued([])), to: .block(block)) }
            if nb.running != nil, let shell = notebooks[block] {
                if let last = notebookInterrupted[block], Date().timeIntervalSince(last) < 10 {
                    shell.killForeground()
                } else {
                    shell.interrupt()
                }
                notebookInterrupted[block] = Date()
            }
            done()
        case let .restartNotebook(block):
            guard node.block(block)?.notebook != nil else { return done("not a notebook") }
            if let old = notebooks.removeValue(forKey: block) {
                old.terminate()
                notebookStopped(block, old)
            }
            startNotebook(block)
            done()
        case let .startNotebook(block):
            startNotebook(block)
            done()
        case let .captureOutput(block, terminal, command, fallback):
            // A command's output as a block of its own (§3.8): the bytes the
            // terminal received for it, from this host's buffer — or the
            // screen's text, when they've gone from it.
            if node.block(block) == nil {
                let c = node.block(terminal)?.terminal?.commands?.first { $0.id == command }
                var state = OutputState(source: terminal, command: command, line: c?.text ?? "", status: c?.status, ran: c?.at, ended: c?.ended)
                if let data = sessions[terminal]?.output(ofCommand: command), !data.isEmpty {
                    // A megabyte at most: the end of it, which is what a terminal shows.
                    let kept = data.count > 1 << 20 ? data.suffix(1 << 20) : data
                    state.output = OutputState.trimmed(String(decoding: kept, as: UTF8.self))
                } else {
                    state.output = fallback
                    state.plain = true
                }
                append(.create(kind: .output, title: c?.text, path: nil), to: .block(block))
                if let cwd = node.block(terminal)?.terminal?.cwd { append(.cwd(cwd), to: .block(block)) }
                append(.output(state), to: .block(block))
                append(.link(Link(from: terminal, to: block, kind: .opened, at: clock.now(), context: "command \(command)")), to: .links(host))
            }
            done()
        case let .listFolder(path):
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                let entries = FolderListing.children(of: path)
                self?.queue.async { conn.send(.message(ServerMessage.listing(id: id, entries: entries, complete: true))) }
            }
        case let .listTree(path, limit):
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                var isDir: ObjCBool = false
                let readable = FileManager.default.fileExists(atPath: path, isDirectory: &isDir) && isDir.boolValue
                let tree = readable ? FolderListing.tree(of: path, limit: min(limit, 50_000)) : nil
                self?.queue.async { conn.send(.message(ServerMessage.listing(id: id, entries: tree?.entries, complete: tree?.complete ?? false))) }
            }
        case let .captureTurn(block, agent, turn):
            writeTurn(block, agent: agent, turn: turn)
            done(node.block(block) == nil ? "no such turn" : nil)
        case let .undoTurn(agent, turn):
            undoTurn(agent, turn: turn) { [weak self] error in
                guard let self else { return }
                self.queue.async { done(error) }
            }
        case let .showRevision(block, repo, path, revision, title):
            // `git show rev:path`: the file as it was, read-only, in an output block.
            let rel = path.hasPrefix(repo + "/") ? String(path.dropFirst(repo.count + 1)) : path
            git.run(git.repository(of: repo)?.vcs ?? .git, ["show", "\(revision):\(rel)"], in: repo) { [weak self] result in
                guard let self else { return }
                guard case .success(let text) = result else { return done("\(rel) isn't in \(revision.prefix(10))") }
                if self.node.block(block) == nil {
                    self.append(.create(kind: .output, title: title, path: nil), to: .block(block))
                    self.append(.cwd(path.deletingLastPathComponent), to: .block(block))
                }
                self.append(.output(OutputState(line: title, status: 0, output: text, plain: true)), to: .block(block))
                done()
            }
        case let .movePath(from, to, replace):
            let fm = FileManager.default
            do {
                if fm.fileExists(atPath: to) {
                    guard replace else { return done("exists") }
                    try fm.removeItem(atPath: to)
                }
                try fm.createDirectory(atPath: to.deletingLastPathComponent, withIntermediateDirectories: true)
                try fm.moveItem(atPath: from, toPath: to)
                done()
            } catch {
                done(error.localizedDescription)
            }
        case let .makeFolder(path):
            do {
                try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
                done()
            } catch {
                done(error.localizedDescription)
            }
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
            readFile(block, for: conn, done: done)
        case let .writeFile(block, version):
            guard let b = node.block(block), b.kind == .text, let path = b.path, let t = b.text else { return done("not a file") }
            // Its own copy written, which the client's edits have brought to
            // the version saved — or not, if they were refused (another has
            // the pen): then nothing is.
            guard t.version == version else { return done("This host's copy is at version \(t.version), not \(version); not written.") }
            let text = t.text.string
            // Whatever asked, a file is never written over by a text that
            // never came from it.
            if b.needsRead, FileManager.default.fileExists(atPath: path) { return done("The file hasn't been read in yet; not written over.") }
            // Encoded here, the fingerprint noted (so the watcher doesn't
            // take the write for another's); written on the files' queue —
            // this one answers every client, and waited on the disk.
            let data: Data
            do { data = try TextFile.encoded(text, encoding: t.encoding, lineEnding: t.lineEnding) } catch { return done(error.localizedDescription) }
            let fingerprint = Fingerprint.of(data)
            expectedFingerprints[block] = fingerprint
            Self.files.async { [weak self] in
                let failure: String?
                do { try TextFile.write(data, to: path); failure = nil } catch { failure = error.localizedDescription }
                self?.queue.async {
                    guard let self else { return }
                    if let failure { return done(failure) }
                    conn.send(.message(ServerMessage.propose(shard: .block(block), .clean(version: version, fingerprint: fingerprint))))
                    if let b = self.node.block(block) { self.watch(b, force: true) }
                    self.languageServers.textChanged(block, saved: true)
                    self.gitChanged(under: path)
                    done()
                }
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
        case var .preferences(p):
            p.shell = p.shell.map { $0.trimmingCharacters(in: .whitespaces) }.flatMap { $0.isEmpty ? nil : $0 }
            if let shell = p.shell, Session.resolveShell(shell) == nil {
                return done("There's no shell \(shell) here that can be run.")
            }
            if p != node.desk(host).preferences {
                append(.preferences(p), to: .desk(host))
                // Another shell may find other agents.
                indexAgents(again: true)
                // Its language servers as its settings now say.
                languageServers.configure(LanguageServerConfig.applying(deskLanguageServers, p.lsp))
            }
            done()
        case .indexAgents:
            indexAgents()
            done()
        case let .seen(ids):
            let known = ids.filter { node.registry(host).blocks[$0] != nil }
            if !known.isEmpty { append(.seen(known, at: clock.now()), to: .registry(host)) }
            // A workspace seen is one gone to: a step of the trail (its
            // selection is the client's own, so this is how the host hears).
            for id in known where node.block(id)?.kind == .arrangement && node.registry(host).trail.last?.block != id {
                append(.step(Step(block: id, at: clock.now())), to: .registry(host))
            }
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
        case let .pin(block, on):
            if let b = node.block(block), b.isPinned != on { append(.pinned(on), to: .block(block)) }
            done()
        case let .hold(h):
            // Another host's reference to a block here: a root, while it
            // stands. For a block that's gone there is nothing to hold.
            if node.block(h.block) != nil, node.registry(host).holds[h.id] != h { append(.hold(h), to: .registry(host)) }
            done()
        case let .release(id):
            if node.registry(host).holds[id] != nil { append(.release(id), to: .registry(host)) }
            done()
        case let .discard(block):
            discard(block)
            done()
        case let .link(link):
            append(.link(link), to: .links(host))
            done()
        case let .unlink(linkID):
            append(.unlink(linkID), to: .links(host))
            done()
        case .resetGraph:
            append(.clearGraph, to: .links(host))
            append(.clearGraph, to: .registry(host))
            log("graph reset: links and trail forgotten")
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
        case let .commandReply(commandID, client, reply):
            if reply.status != nil { commandsOut[client]?.remove(commandID) }
            if let c = clients.first(where: { clientIDs[ObjectIdentifier($0)] == client }) {
                c.send(.message(ServerMessage.commandReply(id: commandID, reply)))
            }
            done()
        case let .runPanel(block, command, event):
            runPanel(block, command: command, event: event)
            done()
        case let .input(block, text):
            guard let session = sessions[block] else { return done("that terminal has no shell running") }
            session.type(text)
            done()
        case let .languageServers(configs):
            // The desk's table, with this host's own settings over it.
            deskLanguageServers = configs
            languageServers.configure(LanguageServerConfig.applying(configs, node.desk(host).preferences.lsp))
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
        case let .smartlog(block, path):
            // The repository holding the path.
            let full = path.expandingTildeInPath
            let repo = git.repository(of: full)
            if node.block(block) == nil {
                // Named for its repository, or, with none, the folder it was asked in.
                var isDir: ObjCBool = false
                let folder = FileManager.default.fileExists(atPath: full, isDirectory: &isDir) && !isDir.boolValue ? full.deletingLastPathComponent : full
                append(.create(kind: .smartlog, title: nil, path: repo?.root ?? folder), to: .block(block))
            }
            // Sapling's or git's: sl web serves either.
            guard let repo else {
                append(.smartlog(url: nil, error: "Not in a repository", at: clock.now()), to: .block(block))
                return done()
            }
            report(block, .working, msg: "Starting Interactive Smartlog")
            Smartlog.start(in: repo.root) { [weak self] url, error in
                self?.queue.async {
                    guard let self, self.node.block(block) != nil else { return }
                    self.append(.smartlog(url: url, error: error, at: self.clock.now()), to: .block(block))
                    self.report(block, error == nil ? .done : .error, msg: error ?? "Interactive Smartlog")
                    done()
                }
            }
        case let .diff(block, subject):
            if node.block(block) == nil {
                let path: String?
                switch subject {
                case let .sides(_, new): path = new.path
                case let .commit(repo, _): path = repo
                case let .versions(id, _, _): path = node.block(id)?.path
                case let .patch(root, _): path = root
                case let .uncommitted(repo): path = repo
                case let .since(repo, _, _), let .trees(repo, _, _, _): path = repo
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
        // Listed off the queue (asking git what's ignored takes a moment);
        // only a change is written, so a listing asked for again and again
        // (a folder view keeping current) doesn't grow the log.
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let entries = FolderListing.children(of: path) else {
                // Said why, once: the folder isn't left waiting to be listed.
                var isDir: ObjCBool = false
                let why = !FileManager.default.fileExists(atPath: path, isDirectory: &isDir) ? "This folder isn't there"
                    : !isDir.boolValue ? "This isn't a folder" : "This folder can't be read"
                self?.queue.async {
                    guard let self, let d = self.node.block(block)?.directory, d.error != why else { return }
                    self.append(.listingFailed(why, at: self.clock.now()), to: .block(block))
                }
                return
            }
            self?.queue.async {
                guard let self, let d = self.node.block(block)?.directory else { return }
                if entries != d.entries || d.listedAt == nil || d.error != nil { self.append(.entries(entries, at: self.clock.now()), to: .block(block)) }
            }
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
        // The repository's changes in one diff, if open, looked at with it.
        for d in node.blocks where d.kind == .diff {
            switch d.diff?.subject {
            case .uncommitted(root)?: loadDiff(d.id)
            case let .since(repo, _, _)? where repo == root: loadDiff(d.id)
            case let .trees(repo, _, nil, _)? where repo == root: loadDiff(d.id)
            default: break
            }
        }
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
        let index = root.appendingPathComponent(vcs.stateFile(in: root))
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
        case let .uncommitted(repo):
            let vcs = git.repository(of: repo)?.vcs ?? .git
            watchRepo(repo, vcs)
            git.run(vcs, vcs.uncommittedArguments, in: repo) { [weak self] result in
                guard let self, self.node.block(block) != nil else { return }
                switch result {
                case .success(let patch):
                    // Unchanged since it was last read: nothing to append.
                    if let d = self.node.block(block)?.diff, d.patch == patch, d.error == nil {
                        self.report(block, .done, msg: patch.isEmpty ? "No changes" : "Compared")
                        return
                    }
                    self.append(.diffLoaded(oldText: nil, newText: nil, patch: patch, error: nil, at: self.clock.now()), to: .block(block))
                    self.linkChangedFiles(of: block, repo: repo, patch: patch)
                    self.report(block, .done, msg: patch.isEmpty ? "No changes" : "Compared")
                case .failure(let e):
                    self.append(.diffLoaded(oldText: nil, newText: nil, patch: nil, error: e.message, at: self.clock.now()), to: .block(block))
                    self.report(block, .error, msg: e.message)
                }
            }
        case let .trees(repo, from, to?, _):
            // Two snapshots: a turn that has ended.
            showTreeDiff(block, repo: repo, from: from, to: to)
        case let .since(repo, tree, _), let .trees(repo, tree, nil, _):
            // The tree now, against the one then: everything, new files too.
            watchRepo(repo, .git)
            git.snapshotTree(repo) { [weak self] now in
                guard let self, self.node.block(block) != nil else { return }
                guard let now else {
                    self.append(.diffLoaded(oldText: nil, newText: nil, patch: nil, error: "couldn't read the working tree", at: self.clock.now()), to: .block(block))
                    return self.report(block, .error, msg: "couldn't read the working tree")
                }
                self.git.run(.git, ["diff", "--no-color", tree, now], in: repo) { [weak self] result in
                    guard let self, self.node.block(block) != nil else { return }
                    switch result {
                    case .success(let patch):
                        if let d = self.node.block(block)?.diff, d.patch == patch, d.error == nil {
                            return self.report(block, .done, msg: patch.isEmpty ? "No changes" : "Compared")
                        }
                        self.append(.diffLoaded(oldText: nil, newText: nil, patch: patch, error: nil, at: self.clock.now()), to: .block(block))
                        self.linkChangedFiles(of: block, repo: repo, patch: patch)
                        self.report(block, .done, msg: patch.isEmpty ? "No changes" : "Compared")
                    case .failure(let e):
                        self.append(.diffLoaded(oldText: nil, newText: nil, patch: nil, error: e.message, at: self.clock.now()), to: .block(block))
                        self.report(block, .error, msg: e.message)
                    }
                }
            }
        case let .commit(repo, sha):
            let vcs = git.repository(of: repo)?.vcs ?? .git
            git.run(vcs, vcs.showArguments(sha), in: repo) { [weak self] result in
                guard let self, self.node.block(block) != nil else { return }
                switch result {
                case .success(let patch):
                    self.append(.diffLoaded(oldText: nil, newText: nil, patch: patch, error: nil, at: self.clock.now()), to: .block(block))
                    self.linkChangedFiles(of: block, repo: repo, patch: patch)
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

    /// A watched file changed: read on the files' queue, weighed here.
    private func fileChanged(_ id: BlockID) {
        guard let b = node.block(id), let path = b.path, b.text != nil else { return }
        Self.files.async { [weak self] in
            let contents = TextFile.read(path)
            self?.queue.async {
                guard let self, let t = self.node.block(id)?.text, let contents else { return }
                if contents.fingerprint == t.diskFingerprint || contents.fingerprint == self.expectedFingerprints[id] { return }
                let proposal: HostProposal = t.isDirty
                    ? .stale
                    : .content(contents.text, encoding: contents.encoding, lineEnding: contents.lineEnding, fingerprint: contents.fingerprint)
                self.leader(of: .block(id))?.send(.message(ServerMessage.propose(shard: .block(id), proposal)))
            }
        }
    }

    /// Where files are read and written: not the queue every client's
    /// answers and pings wait on. Serial, so writes to a file keep their order.
    static let files = DispatchQueue(label: "manifoldd.files", qos: .userInitiated)

    /// Who writes what the host proposes for a shard it doesn't lead: the
    /// app attachment holding its pen, else any app attachment — never a
    /// command-line client, which would let it drop.
    private func leader(of shard: ShardID) -> (any Channel)? {
        let apps = clients.filter { appClients.contains(ObjectIdentifier($0)) }
        if let owner = owners[shard], let c = apps.first(where: { ObjectIdentifier($0) == owner }) { return c }
        return apps.first ?? clients.first
    }

    /// A text block's file read in, for the attachment that asked. What
    /// it already has, unedited and as on disk, isn't sent again (opening
    /// a file checks it so). A file not there in a folder that is, is a
    /// new one at once — watched, so one being replaced is read as it
    /// comes (it waited 1.2 s, an empty editor ⌘-clicked to); one whose
    /// folder isn't there either (a slow file system, a folder being made)
    /// is looked for again a few times first. One there that can't be
    /// read is tried once more (a file being written).
    private func readFile(_ block: BlockID, for conn: any Channel, attempt: Int = 0, done: @escaping (String?) -> Void) {
        guard let b = node.block(block), b.kind == .text, let path = b.path else { return done("not a file") }
        // Read on the files' queue (a big file, a slow disk, held up every
        // client's answers here), weighed back here.
        Self.files.async { [weak self] in
            let contents = TextFile.read(path)
            let exists = contents != nil || FileManager.default.fileExists(atPath: path)
            let folder = FileManager.default.fileExists(atPath: (path as NSString).deletingLastPathComponent)
            self?.queue.async {
                self?.readFile(block, for: conn, attempt: attempt, read: contents, exists: exists, folder: folder, done: done)
            }
        }
    }

    private func readFile(_ block: BlockID, for conn: any Channel, attempt: Int, read contents: TextFile.Contents?, exists: Bool, folder: Bool,
                          done: @escaping (String?) -> Void) {
        guard let b = node.block(block), b.kind == .text, let path = b.path else { return done("not a file") }
        let send = { (p: HostProposal) in conn.send(.message(ServerMessage.propose(shard: .block(block), p))) }
        if let contents {
            if let t = b.text, !t.isDirty, t.version > 0, t.diskFingerprint == contents.fingerprint, !t.unreadable {
                // Already so.
            } else {
                send(.content(contents.text, encoding: contents.encoding, lineEnding: contents.lineEnding, fingerprint: contents.fingerprint))
            }
            watch(b, force: true)
            done(nil)
        } else if exists {
            if attempt < 1 {
                queue.asyncAfter(deadline: .now() + 0.15) { [weak self] in self?.readFile(block, for: conn, attempt: attempt + 1, done: done) }
                return
            }
            send(.unreadable)
            done("can't be read as text")
        } else if attempt < 3, !folder {
            queue.asyncAfter(deadline: .now() + 0.2 * Double(attempt + 1)) { [weak self] in self?.readFile(block, for: conn, attempt: attempt + 1, done: done) }
        } else {
            // A new file: empty, clean, not yet on disk; watched, so it's
            // read when it comes.
            send(.content("", encoding: "utf-8", lineEnding: "\n", fingerprint: ""))
            watch(b, force: true)
            done(nil)
        }
    }

    // MARK: Sessions

    private func attach(_ conn: any Channel, _ req: AttachRequest) {
        let id = req.block
        if node.block(id) == nil {
            append(.create(kind: .terminal, title: nil, path: nil), to: .block(id))
        }
        guard let block = node.block(id), block.kind == .terminal || block.kind == .agent, let state = block.terminal else {
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
                                  env: req.env, history: history, command: state.command,
                                  shell: node.desk(host).preferences.shell, queue: queue) else {
                conn.close()
                return
            }
            s.onExit = { [weak self] status in self?.sessionExited(id, status: status) }
            s.onTitle = { [weak self] title in
                guard self?.node.block(id)?.terminal?.title != title else { return }
                self?.append(.title(title), to: .block(id))
            }
            s.onStatus = { [weak self] signals in self?.status(id, signals) }
            s.onPasswordInput = { [weak self] on in
                let frame = Frame.message(ServerMessage.passwordInput(block: id, on))
                for c in self?.clients ?? [] { c.send(frame) }
            }
            sessions[id] = s
            session = s
            append(.shell(.started(pid: s.pid)), to: .block(id))
        }
        conn.onFrame = { [weak session, unowned conn] frame in session?.handle(frame, from: conn) }
        conn.onClose = { [weak session, unowned conn] in session?.detach(conn) }
        session.attach(conn, cols: req.cols, rows: req.rows, resume: req.resume == true, ttyModes: req.ttyModes == true,
                       inputID: req.inputID, input: req.input)
    }

    // MARK: Forwarded ports (§8)

    /// A forwarded port's connection, on its own stream: the host's
    /// loopback port's bytes up it, and its bytes written there. The
    /// relay stops reading while the stream has enough on its way, and
    /// what's written is credited only once it is, so neither side's
    /// slowness piles up anywhere but in itself.
    private func tunnel(_ stream: MuxStream, to port: Int) {
        guard let relay = PortRelay(port: port, queue: queue) else { return stream.close() }
        stream.manualCredit = true
        relay.onData = { [weak relay, weak stream] data in
            guard let stream else { return }
            stream.sendPieces(data)
            if !stream.wantsMore { relay?.pause() }
        }
        stream.onDrain = { [weak relay] in relay?.resume() }
        relay.onWritten = { [weak stream] count in stream?.consumed(count + 5) }
        // The port's side closed: the stream with it (after what it sent).
        relay.onClose = { [weak stream] in stream?.close() }
        // The stream keeps the relay, until it closes.
        stream.onFrame = { frame in
            guard frame.kind == .data else { return }
            // Empty: the client's side is done sending; its answer still comes.
            if frame.payload.isEmpty { relay.finishWriting() } else { relay.write(frame.payload) }
        }
        // (Held here too: the stream lets go of its frame handler first.)
        stream.onClose = {
            relay.onClose = nil
            relay.end()
        }
    }

    // MARK: Shell notebooks (§7.7)

    /// The notebook's shell, started if it isn't running.
    @discardableResult
    private func startNotebook(_ block: BlockID) -> NotebookShell? {
        if let s = notebooks[block] { return s }
        guard let b = node.block(block), b.kind == .notebook else { return nil }
        guard let s = NotebookShell(id: block, cwd: b.home, preferred: node.desk(host).preferences.shell, queue: queue) else { return nil }
        notebooks[block] = s
        s.onReady = { [weak self] in self?.advanceNotebook(block) }
        s.onOutput = { [weak self] data in self?.notebookPrinted(block, data) }
        s.onEnded = { [weak self] data, status, pwd in self?.notebookCellEnded(block, data, status: status, pwd: pwd) }
        s.onExit = { [weak self, weak s] in
            guard let self, let s, self.notebooks[block] === s else { return }
            self.notebooks.removeValue(forKey: block)
            self.notebookStopped(block, s)
        }
        append(.notebook(.shell(pid: s.pid, name: s.name, at: clock.now())), to: .block(block))
        return s
    }

    /// A shell gone: its block says so, and what was waiting won't run.
    private func notebookStopped(_ block: BlockID, _ shell: NotebookShell) {
        guard node.block(block)?.notebook != nil else { return }
        if let running = node.block(block)?.notebook?.running {
            append(.notebook(.finished(running, output: "", status: nil, truncated: false, at: clock.now())), to: .block(block))
        }
        append(.notebook(.shell(pid: nil, name: nil, at: clock.now())), to: .block(block))
        notebookLive.removeValue(forKey: block)
    }

    /// The next waiting cell run, if nothing runs and the shell is ready.
    private func advanceNotebook(_ block: BlockID) {
        guard let nb = node.block(block)?.notebook, nb.running == nil, let next = nb.queued.first else { return }
        guard let cell = nb.cell(next) else {
            append(.notebook(.queued(Array(nb.queued.dropFirst()))), to: .block(block))
            return advanceNotebook(block)
        }
        guard let shell = startNotebook(block), shell.ready, !shell.busy else { return }
        notebookInterrupted.removeValue(forKey: block)
        log("notebook \(block): cell \(next) runs as [\(nb.runs + 1)]")
        append(.notebook(.started(next, count: nb.runs + 1, at: clock.now())), to: .block(block))
        let line = cell.source.split(separator: "\n").first.map(String.init) ?? ""
        report(block, .working, msg: line)
        notebookLive[block] = (next, Data())
        shell.run(cell.source)
    }

    /// The running cell printed: sent to the clients, a tenth of a second at most apart.
    private func notebookPrinted(_ block: BlockID, _ data: Data) {
        guard let running = node.block(block)?.notebook?.running else { return }
        notebookLive[block] = (running, data)
        guard notebookLiveScheduled.insert(block).inserted else { return }
        queue.asyncAfter(deadline: .now() + 0.1) { [weak self] in
            guard let self else { return }
            self.notebookLiveScheduled.remove(block)
            guard let live = self.notebookLive[block] else { return }
            let tail = live.output.count > 256 << 10 ? live.output.suffix(256 << 10) : live.output
            let frame = Frame.message(ServerMessage.notebookLive(block: block, cell: live.cell, output: String(decoding: tail, as: UTF8.self)))
            for c in self.clients { c.send(frame) }
        }
    }

    /// The running cell ended: its output written (the last megabyte), where
    /// the shell went, its status; a failure stops what was waiting.
    private func notebookCellEnded(_ block: BlockID, _ data: Data, status: Int32?, pwd: String?) {
        notebookLive.removeValue(forKey: block)
        guard let b = node.block(block), let nb = b.notebook, let id = nb.running else { return }
        let limit = 1 << 20
        let kept = data.count > limit ? data.suffix(limit) : data
        append(.notebook(.finished(id, output: String(decoding: kept, as: UTF8.self), status: status, truncated: data.count > limit, at: clock.now())), to: .block(block))
        if let pwd, pwd != b.home { append(.cwd(pwd), to: .block(block)) }
        let failed = (status ?? 0) != 0
        if failed, !nb.queued.isEmpty { append(.notebook(.queued([])), to: .block(block)) }
        let line = nb.cell(id)?.source.split(separator: "\n").first.map(String.init) ?? ""
        if failed {
            report(block, .error, msg: status == 130 ? "Interrupted: \(line)" : "Exit \(status ?? -1): \(line)")
        } else if (node.block(block)?.notebook?.queued ?? []).isEmpty {
            report(block, .done, msg: line)
        }
        advanceNotebook(block)
    }

    // MARK: Status (§3.7)

    /// The host's own report on a block it works for: its root record.
    /// Only a terminal's program says what its status is (§3.7), for now:
    /// the host keeps quiet about the blocks it works for itself.
    private func reportsStatus(_ block: BlockID) -> Bool {
        guard let k = node.block(block)?.kind else { return false }
        return k == .terminal || k == .agent || k == .notebook
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
                let id = (list.last?.id ?? 0) + 1
                append(.ran(id: id, text, at: clock.now()), to: .block(block))
                sessions[block]?.beginCapture(id)
            case let .commandEnded(status):
                // The shell's command, not an agent's turn within it.
                let turns = agentTurns[block] ?? []
                if let open = node.block(block)?.terminal?.commands?.last(where: { $0.ended == nil && !turns.contains($0.id) }) {
                    append(.exited(id: open.id, status: status ?? 0, at: clock.now()), to: .block(block))
                    sessions[block]?.endCapture(open.id)
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

    // MARK: Agents' hooks

    /// The marks each block's agent made for its turns, as opposed to the
    /// shell's commands they run within (an agent run by hand at a prompt).
    private var agentTurns: [BlockID: Set<Int>] = [:]

    /// What an agent's hook said (`mani agent`): each prompt a mark on
    /// the terminal's scrubber and outline, as a shell's command is, open
    /// until the turn ends; and the agent's status the block's, by name.
    private func agentEvent(_ block: BlockID, _ event: AgentEvent) {
        guard let b = node.block(block), reportsStatus(block) else { return }
        func line(_ text: String?) -> String? {
            let first = text?.split(whereSeparator: \.isNewline).first.map { $0.trimmingCharacters(in: .whitespaces) } ?? ""
            return first.isEmpty ? nil : String(first.prefix(200))
        }
        func endTurn() {
            let turns = agentTurns[block] ?? []
            for c in node.block(block)?.terminal?.commands ?? [] where c.ended == nil && turns.contains(c.id) {
                append(.exited(id: c.id, status: 0, at: clock.now()), to: .block(block))
            }
        }
        func status(_ state: StatusState, kind: BlockedKind? = nil, msg: String?) {
            append(.status(id: rootStatusID, StatusRecord(state: state, kind: kind, app: event.agent, msg: msg, at: clock.now())), to: .block(block))
        }
        switch event {
        case .started:
            status(.idle, msg: nil)
        case let .prompt(agent, text, transcript):
            endTurn()
            finishTurns(block, message: nil, transcript: nil)
            if let mark = line(text) {
                let id = (node.block(block)?.terminal?.commands?.last?.id ?? 0) + 1
                append(.ran(id: id, mark, at: clock.now()), to: .block(block))
                agentTurns[block, default: []].insert(id)
                beginTurn(block, id: id, agent: agent, prompt: text, transcript: transcript)
            }
            status(.working, msg: line(text))
        case .working:
            // After a permission or a tool: working on what it was.
            let current = b.status?[rootStatusID]
            if current?.state != .working { status(.working, msg: current?.state == .blocked ? nil : current?.msg) }
        case let .finished(_, message, transcript):
            endTurn()
            finishTurns(block, message: message, transcript: transcript)
            status(.done, msg: line(message))
        case let .todos(_, items):
            keepTodos(block, items)
            let current = b.status?[rootStatusID]
            if current?.state != .working { status(.working, msg: current?.state == .blocked ? nil : current?.msg) }
        case let .waiting(_, message):
            status(.blocked, kind: .permission, msg: line(message))
        case .ended:
            endTurn()
            finishTurns(block, message: nil, transcript: nil)
            agentTurns[block] = nil
            append(.status(id: rootStatusID, nil), to: .block(block))
        }
    }

    /// A diff linked to the files it changes that are blocks here, so each
    /// is found from the other.
    private func linkChangedFiles(of diff: BlockID, repo: String, patch: String) {
        // The repository as given and as the files' blocks may have it
        // (/tmp, not /private/tmp).
        let roots = Set([repo, URL(fileURLWithPath: repo).resolvingSymlinksInPath().path])
        var paths: Set<String> = []
        for line in patch.split(separator: "\n") where line.hasPrefix("+++ b/") && paths.count < 400 {
            for root in roots { paths.insert(root + "/" + line.dropFirst(6)) }
        }
        let linked = Set(node.links(host).links.filter { $0.from == diff }.map(\.to))
        for b in node.blocks where b.kind == .text {
            guard let path = b.path, paths.contains(path), !linked.contains(b.id) else { continue }
            let file = b.id
            append(.link(Link(from: diff, to: file, kind: .opened, at: clock.now(), context: "changed")), to: .links(host))
        }
    }

    /// A diff block of the changes between two trees of a repository.
    private func showTreeDiff(_ block: BlockID, repo: String, from: String, to: String) {
        git.run(.git, ["diff", "--no-color", from, to], in: repo) { [weak self] result in
            guard let self, self.node.block(block) != nil else { return }
            switch result {
            case .success(let patch):
                if let d = self.node.block(block)?.diff, d.patch == patch, d.error == nil {
                    return self.report(block, .done, msg: patch.isEmpty ? "No changes" : "Compared")
                }
                self.append(.diffLoaded(oldText: nil, newText: nil, patch: patch, error: nil, at: self.clock.now()), to: .block(block))
                self.linkChangedFiles(of: block, repo: repo, patch: patch)
                self.report(block, .done, msg: patch.isEmpty ? "No changes" : "Compared")
            case .failure(let e):
                self.append(.diffLoaded(oldText: nil, newText: nil, patch: nil, error: e.message, at: self.clock.now()), to: .block(block))
                self.report(block, .error, msg: e.message)
            }
        }
    }

    // MARK: Agents' turns (§3.8)

    /// A turn begun: its record, and the working tree as it begins (in a
    /// git repository) — the checkpoint undoing it goes back to.
    private func beginTurn(_ block: BlockID, id: Int, agent: String, prompt: String, transcript: String?) {
        var turn = AgentTurn(id: id, agent: agent, prompt: String(prompt.prefix(20_000)), began: clock.now())
        turn.transcript = transcript
        append(.turn(turn), to: .block(block))
        guard let cwd = node.block(block)?.terminal?.cwd, let (root, vcs) = git.repository(of: cwd), vcs == .git else { return }
        git.snapshotTree(root) { [weak self] tree in
            guard let self, let tree, var t = self.node.block(block)?.terminal?.turns?.first(where: { $0.id == id }) else { return }
            t.repo = root
            t.before = tree
            self.append(.turn(t), to: .block(block))
        }
    }

    /// The turns still open, ended: the working tree as each ends, what it
    /// changed, the agent's last words.
    private func finishTurns(_ block: BlockID, message: String?, transcript: String?) {
        for var t in node.block(block)?.terminal?.turns ?? [] where t.ended == nil {
            t.ended = clock.now()
            if let message, !message.isEmpty { t.message = String(message.prefix(20_000)) }
            if let transcript { t.transcript = transcript }
            append(.turn(t), to: .block(block))
            guard let repo = t.repo, let before = t.before else { continue }
            let id = t.id
            git.snapshotTree(repo) { [weak self] after in
                guard let self, let after else { return }
                self.git.run(.git, ["diff", "--name-only", before, after], in: repo) { [weak self] result in
                    guard let self, var t = self.node.block(block)?.terminal?.turns?.first(where: { $0.id == id }) else { return }
                    t.after = after
                    if case .success(let out) = result { t.files = out.split(separator: "\n").map(String.init).filter { !$0.isEmpty } }
                    self.append(.turn(t), to: .block(block))
                    // Its block, if made, says the turn as it ended.
                    for b in self.node.blocks where b.kind == .output && b.output?.source == block && b.output?.command == id && b.output?.markdown != nil {
                        self.writeTurn(b.id, agent: block, turn: id)
                    }
                }
            }
        }
    }

    /// A turn's block: the turn in Markdown, linked from the agent and to
    /// the files it changed and its diff.
    private func writeTurn(_ block: BlockID, agent: BlockID, turn id: Int) {
        guard let a = node.block(agent), let t = a.terminal?.turns?.first(where: { $0.id == id }) else { return }
        let firstLine = t.prompt.split(whereSeparator: \.isNewline).first.map(String.init) ?? "Turn"
        if node.block(block) == nil {
            append(.create(kind: .output, title: "Turn: " + String(firstLine.prefix(80)), path: nil), to: .block(block))
            if let cwd = a.terminal?.cwd { append(.cwd(cwd), to: .block(block)) }
            append(.link(Link(from: agent, to: block, kind: .opened, at: clock.now(), context: "turn \(id)")), to: .links(host))
        }
        var md = "# " + firstLine.replacingOccurrences(of: "#", with: "") + "\n\n"
        let took = t.ended.map { " · took " + Self.duration(Double($0.wall - t.began.wall) / 1000) } ?? " · still working"
        md += "*\(t.agent) · \(a.displayTitle)\(took)*\n\n"
        md += "## Asked\n\n" + t.prompt + "\n\n"
        var did = ""
        if let path = t.transcript, let done = TurnTranscript.render(path: path, prompt: t.prompt), !done.isEmpty {
            did = done
            md += "## What it did\n\n" + done + "\n\n"
        }
        // Its last words, unless what it did ends with them already.
        if let m = t.message?.trimmingCharacters(in: .whitespacesAndNewlines), !m.isEmpty, !did.hasSuffix(m) { md += "## Said\n\n" + m + "\n\n" }
        if let repo = t.repo, let before = t.before {
            let files = t.files ?? []
            md += "## Changed\n\n"
            if t.after != nil, files.isEmpty { md += "Nothing in \(repo.lastPathComponent).\n\n" }
            for f in files.prefix(200) {
                let path = repo + "/" + f
                let fileBlock = textBlock(for: path)
                md += "- [\(f)](manifold:\(fileBlock.description))\n"
                if !node.links(host).links.contains(where: { $0.from == block && $0.to == fileBlock }) {
                    append(.link(Link(from: block, to: fileBlock, kind: .opened, at: clock.now(), context: "changed in this turn")), to: .links(host))
                }
            }
            let subject = DiffSubject.trees(repo: repo, from: before, to: t.after, title: "Turn: " + String(firstLine.prefix(60)))
            let diff = node.blocks.first { $0.kind == .diff && $0.diff?.subject == subject }?.id ?? {
                let d = BlockID(host: host)
                append(.create(kind: .diff, title: nil, path: repo), to: .block(d))
                append(.diffSubject(subject), to: .block(d))
                loadDiff(d)
                return d
            }()
            if !node.links(host).links.contains(where: { $0.from == block && $0.to == diff }) {
                append(.link(Link(from: block, to: diff, kind: .opened, at: clock.now(), context: "changes in this turn")), to: .links(host))
            }
            md += "\n[Changes in this turn](manifold:\(diff.description))\n"
        }
        var state = OutputState(source: agent, command: id, line: firstLine, status: t.ended == nil ? nil : 0, ran: t.began, ended: t.ended)
        state.markdown = md
        if node.block(block)?.output != state { append(.output(state), to: .block(block)) }
    }

    /// An agent's to-do list (Claude Code's TodoWrite) as a checklist note
    /// of its own, linked from the agent — by hand's kind, so the agent
    /// keeps it — rewritten as the list changes: done ticked, the item at
    /// work in bold.
    private func keepTodos(_ agent: BlockID, _ items: [AgentTodo]) {
        let name = node.block(agent)?.displayTitle ?? "Agent"
        let title = "To-do · " + name
        let existing = node.links(host).links.first { $0.from == agent && $0.context == "to-do list" && node.block($0.to) != nil }?.to
        let note = existing ?? {
            let id = BlockID(host: host)
            append(.create(kind: .text, title: title, path: nil), to: .block(id))
            if let cwd = node.block(agent)?.terminal?.cwd { append(.cwd(cwd), to: .block(id)) }
            append(.link(Link(from: agent, to: id, kind: .linked, at: clock.now(), context: "to-do list")), to: .links(host))
            return id
        }()
        let done = items.filter { $0.status == "completed" }.count
        var text = "# \(title)\n\n\(done) of \(items.count) done\n\n"
        for i in items {
            let words = i.text.replacingOccurrences(of: "\n", with: " ")
            text += "- [\(i.status == "completed" ? "x" : " ")] " + (i.status == "in_progress" ? "**\(words)**" : words) + "\n"
        }
        guard node.block(note)?.text?.text.string != text else { return }
        append(.content(text, encoding: "utf-8", lineEnding: "\n", fingerprint: nil), to: .block(note))
    }

    /// The text block for a file here: the one there is, else one made.
    private func textBlock(for path: String) -> BlockID {
        if let b = node.blocks.first(where: { $0.kind == .text && $0.path == path }) { return b.id }
        let id = BlockID(host: host)
        append(.create(kind: .text, title: nil, path: path), to: .block(id))
        return id
    }

    static func duration(_ s: Double) -> String {
        if s < 60 { return "\(Int(s)) s" }
        if s < 3600 { return "\(Int(s) / 60) min \(Int(s) % 60) s" }
        return "\(Int(s) / 3600) h \(Int(s) % 3600 / 60) min"
    }

    /// A turn's changes, taken back: the patch from its end to its start
    /// applied to the working tree as it is.
    private func undoTurn(_ agent: BlockID, turn id: Int, done: @escaping (String?) -> Void) {
        guard let t = node.block(agent)?.terminal?.turns?.first(where: { $0.id == id }) else { return done("no such turn") }
        guard let repo = t.repo, let before = t.before, let after = t.after else { return done("the turn has no checkpoint (not in a git repository, or not ended)") }
        git.run(.git, ["diff", "--binary", after, before], in: repo) { [weak self] result in
            guard let self else { return }
            guard case .success(let patch) = result else { return done("couldn't read the turn's changes") }
            guard !patch.isEmpty else { return done(nil) }
            let file = NSTemporaryDirectory() + "manifold-undo-\(UUID().uuidString).patch"
            try? patch.write(toFile: file, atomically: true, encoding: .utf8)
            self.git.run(.git, ["apply", "--whitespace=nowarn", file], in: repo) { result in
                try? FileManager.default.removeItem(atPath: file)
                if case .failure = result { return done("later changes are in the way: the turn's changes couldn't be taken back cleanly") }
                done(nil)
            }
        }
    }

    private func report(_ block: BlockID, _ state: StatusState, progress: Int?, msg: String? = nil) {
        guard reportsStatus(block) else { return }
        append(.status(id: rootStatusID, StatusRecord(state: state, progress: progress, msg: msg, at: clock.now())), to: .block(block))
    }

    private func sessionExited(_ id: BlockID, status: Int32) {
        guard let s = sessions.removeValue(forKey: id) else { return }
        // Its transcript whole, to show as it was until a shell starts again.
        try? FileManager.default.createDirectory(at: historyDirectory, withIntermediateDirectories: true)
        try? s.takeHistory().write(to: historyFile(id), options: .atomic)
        if s.endedForIdleness {
            append(.shell(.dormant(idleSeconds: s.idleSeconds)), to: .block(id))
        } else {
            append(.shell(.ended(status: status)), to: .block(id))
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

    /// When the host last looked for agents, so a burst of asking looks once.
    private var agentsIndexed: Date?

    /// Looks for the known agents through the user's shell, off the queue,
    /// and keeps what it finds in the desk when that changes.
    private func indexAgents(again: Bool = false) {
        if !again, let t = agentsIndexed, Date().timeIntervalSince(t) < 10 { return }
        agentsIndexed = Date()
        let shell = node.desk(host).preferences.shell
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let found = Session.availableAgents(preferred: shell)
            self?.queue.async {
                guard let self, found != self.node.desk(self.host).agents else { return }
                log("agents here: \(found.isEmpty ? "none" : found.joined(separator: ", "))")
                self.append(.agents(found), to: .desk(self.host))
            }
        }
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

    /// The changed shards' snapshots written. `later`: encoded and written
    /// on the files' queue (every minute: the shards are big, this queue
    /// answers every client); else here, once what's queued there is done.
    private func writeSnapshots(later: Bool = false) {
        if !later { Self.files.sync {} }
        for shard in dirtyShards { store.snapshot(node, shard, on: later ? Self.files : nil) }
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
        // A notebook's shell goes with the server (its cells and outputs
        // stay in the log; the next run starts a fresh shell).
        for n in notebooks.values { n.terminate() }
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
