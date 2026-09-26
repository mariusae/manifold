import Foundation
import ManifoldCore

enum ServerError: Error {
    case alreadyRunning
}

/// Owns the workspace and the terminal sessions. Everything runs on one
/// serial queue.
final class Server {
    private let queue = DispatchQueue(label: "manifoldd")
    private var workspace = Workspace()
    private var clients: [Connection] = []
    /// Connections that haven't said what they are yet.
    private var pending: [Connection] = []
    private var sessions: [UUID: Session] = [:]
    private var listener: DispatchSourceRead?
    private var saveScheduled = false
    private var cwdTimer: DispatchSourceTimer?

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
            self?.pollWorkingDirectories()
            self?.saveHistory()
        }
        timer.resume()
        cwdTimer = timer

        for sig in [SIGTERM, SIGINT] {
            signal(sig, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: sig, queue: queue)
            source.setEventHandler { [weak self] in self?.exit(endSessions: false) }
            source.resume()
            signalSources.append(source)
        }
        log("manifoldd \(getpid()) listening on \(Paths.socket)")
    }

    private var signalSources: [DispatchSourceSignal] = []

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
            conn.onFrame = { [weak self, unowned conn] frame in self?.clientFrame(frame, from: conn) }
            conn.onClose = { [weak self, unowned conn] in self?.clients.removeAll { $0 === conn } }
            conn.send(.json(ServerMessage.welcome(version: protocolVersion, pid: getpid())))
            conn.send(.json(ServerMessage.state(workspace)))
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
        case .command(let command)?:
            apply(command)
        case .shutdown?:
            exit(endSessions: true)
        default:
            break
        }
    }

    private func apply(_ command: Command) {
        let before = workspace
        let removed = workspace.apply(command)
        for id in removed {
            sessions.removeValue(forKey: id)?.terminate()
            try? FileManager.default.removeItem(at: historyFile(id))
        }
        if workspace != before { changed() }
    }

    private func changed() {
        let frame = Frame.json(ServerMessage.state(workspace))
        for conn in clients { conn.send(frame) }
        scheduleSave()
    }

    // MARK: Sessions

    private func attach(_ conn: Connection, _ req: AttachRequest) {
        guard let pane = workspace.pane(req.pane) else {
            conn.close()
            return
        }
        let session: Session
        if let existing = sessions[pane.id] {
            session = existing
        } else {
            let history = (try? Data(contentsOf: historyFile(pane.id))) ?? Data()
            guard let s = Session(id: pane.id, cwd: pane.cwd, cols: req.cols, rows: req.rows,
                                  env: req.env, history: history, queue: queue) else {
                conn.close()
                return
            }
            s.onExit = { [weak self] in self?.sessionExited(pane.id) }
            s.onTitle = { [weak self] title in self?.apply(.setPaneTitle(pane.id, title)) }
            sessions[pane.id] = s
            session = s
        }
        conn.onFrame = { [weak session] frame in session?.handle(frame) }
        conn.onClose = { [weak session, unowned conn] in session?.detach(conn) }
        session.attach(conn, cols: req.cols, rows: req.rows)
    }

    private func sessionExited(_ id: UUID) {
        guard sessions.removeValue(forKey: id) != nil else { return }
        // The shell is gone, so is its pane.
        apply(.closePane(id))
    }

    private func pollWorkingDirectories() {
        for (id, session) in sessions {
            if let cwd = session.cwd, workspace.pane(id)?.cwd != cwd {
                apply(.setPaneCwd(id, cwd))
            }
        }
    }

    // MARK: Persistence

    /// Each pane's recent output is kept on disk too, so that when the server
    /// starts over (after a restart, say) its terminal shows what it showed.
    private var historyDirectory: URL { Paths.directory.appendingPathComponent("history") }

    private func historyFile(_ pane: UUID) -> URL {
        historyDirectory.appendingPathComponent(pane.uuidString)
    }

    private func saveHistory() {
        try? FileManager.default.createDirectory(at: historyDirectory, withIntermediateDirectories: true)
        for (id, session) in sessions where session.unsaved {
            try? session.takeHistory().write(to: historyFile(id), options: .atomic)
        }
    }

    private func pruneHistory() {
        let live = Set(workspace.allPanes.map(\.id.uuidString))
        let files = (try? FileManager.default.contentsOfDirectory(atPath: historyDirectory.path)) ?? []
        for f in files where !live.contains(f) {
            try? FileManager.default.removeItem(at: historyDirectory.appendingPathComponent(f))
        }
    }

    private func load() {
        guard let data = try? Data(contentsOf: Paths.state) else { return }
        do {
            workspace = try JSONDecoder().decode(Workspace.self, from: data)
        } catch {
            log("could not read \(Paths.state.path): \(error); starting fresh")
            try? FileManager.default.moveItem(at: Paths.state, to: Paths.state.appendingPathExtension("bad"))
        }
    }

    private func scheduleSave() {
        guard !saveScheduled else { return }
        saveScheduled = true
        queue.asyncAfter(deadline: .now() + 0.25) { [weak self] in
            self?.saveScheduled = false
            self?.save()
        }
    }

    private func save() {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        do {
            try encoder.encode(workspace).write(to: Paths.state, options: .atomic)
        } catch {
            log("could not save state: \(error)")
        }
    }

    /// Exits, saving state first. Sessions die with us either way, as their
    /// terminals hang up when we go; `endSessions` hangs up on them first.
    private func exit(endSessions: Bool) {
        if endSessions {
            for s in sessions.values { s.terminate() }
        }
        save()
        if endSessions {
            try? FileManager.default.removeItem(at: historyDirectory)
        } else {
            saveHistory()
        }
        unlink(Paths.socket)
        log("manifoldd exiting")
        Darwin.exit(0)
    }
}
