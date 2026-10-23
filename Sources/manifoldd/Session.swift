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

/// A shell running on a pseudo-terminal the server owns, so it outlives the
/// app. Terminals in the app attach to it on streams of their connection
/// (§8): each is sent what the shell prints as it comes, beginning from a
/// snapshot of the terminal as the host keeps it (`screen`).
final class Session {
    let id: BlockID
    let pid: pid_t
    private let master: Int32
    private let queue: DispatchQueue
    private let readSource: DispatchSourceRead
    private let exitWatch: ProcessWatch
    private var replay: ReplayBuffer
    /// The terminal as the host keeps it: what an attaching terminal is
    /// sent, and one that fell behind.
    private let screen: TerminalScreen?
    /// Attachments that fell behind (their streams full, on a slow link):
    /// sent nothing until they've caught up, then the screen as it is.
    private var behind: Set<ObjectIdentifier> = []
    /// Whether there's output not yet saved to disk.
    private(set) var unsaved = false
    private var titles = TitleScanner()
    private var attachments: [any Channel] = []
    private var size: (cols: UInt16, rows: UInt16)
    private var input = Data()
    private var inputSource: DispatchSourceWrite?
    private var inputSourceActive = false
    private var exited = false
    /// Set when the shell was ended for lying idle, so its end is recorded
    /// as dormancy rather than an exit.
    private(set) var endedForIdleness = false
    private(set) var idleSeconds = 0

    var onExit: ((Int32) -> Void)?
    var onTitle: ((String) -> Void)?
    /// What the program says of its status (§3.7), as it says it.
    var onStatus: (([StatusSignal]) -> Void)?
    /// The program is reading a password, or has stopped.
    var onPasswordInput: ((Bool) -> Void)?
    private(set) var readingPassword = false
    private var passwordCheck: DispatchWorkItem?

    /// Echo off with lines still edited: a password being read (a full-
    /// screen program turns both off).
    private func checkPassword() {
        var t = termios()
        guard tcgetattr(master, &t) == 0 else { return }
        let password = t.c_lflag & tcflag_t(ECHO) == 0 && t.c_lflag & tcflag_t(ICANON) != 0
        guard password != readingPassword else { return }
        readingPassword = password
        onPasswordInput?(password)
    }
    private var statuses = StatusScanner()
    /// Where each command's output lies in the replay buffer (§3.8), by
    /// the command's id: from just after the shell said it would run it
    /// (OSC 7502) to where it said it had ended (OSC 133;D).
    private var captures: [Int: (start: Int64, end: Int64?)] = [:]
    private var pendingStart: Int64?
    private var pendingEnd: Int64?
    /// The last few bytes of the last read, for a mark split across two.
    private var markTail: [UInt8] = []
    /// The shell has said where it is (OSC 7): its directory isn't polled.
    var reportsDirectory = false

    init?(id: BlockID, cwd: String?, cols: UInt16, rows: UInt16, env: [String: String], history: Data,
          command: String? = nil, shell preferred: String? = nil, queue: DispatchQueue) {
        var (shell, environment) = Session.shellAndEnvironment(clientEnv: env, preferred: preferred)
        // So `manifold` run in this shell knows where it is, and `$EDITOR`
        // edits in Manifold, beside it.
        environment["MANIFOLD_BLOCK"] = id.description
        environment["MANIFOLD_HOST"] = id.host.raw
        let editor = Session.editorCommand
        environment["EDITOR"] = editor
        environment["VISUAL"] = editor
        let argv0 = "-" + shell.lastPathComponent
        let dir = cwd.flatMap { FileManager.default.fileExists(atPath: $0) ? $0 : nil }
            ?? FileManager.default.homeDirectoryForCurrentUser.path

        var master: Int32 = -1
        // An agent runs its command in a login shell, so the PATH is the
        // user's. An interactive shell gets Manifold's tools first on the
        // PATH once its rc files have run: zsh through the .zshenv layer
        // (in the environment), fish through a command run after its
        // configuration, bash through an rc file that sources yours.
        var args = command.map { [argv0, "-c", $0] } ?? [argv0]
        if command == nil {
            switch shell.lastPathComponent {
            case "fish":
                args.append(contentsOf: ["-C", Session.fishStartup])
            case "bash":
                if let rc = Session.bashLayer() { args = [shell.lastPathComponent, "--rcfile", rc] }
            default: break
            }
        }
        let pid = withCStrings(args) { argv in
            withCStrings(environment.map { "\($0.key)=\($0.value)" }) { envp in
                mf_pty_spawn(shell, argv, envp, dir, cols, rows, &master)
            }
        }
        guard pid > 0 else {
            log("spawn \(shell) failed: \(String(cString: strerror(errno)))")
            return nil
        }
        log("session \(id) started: pid \(pid) in \(dir)")

        self.id = id
        self.replay = ReplayBuffer(restoring: history)
        screen = TerminalScreen(cols: cols, rows: rows)
        screen?.feed(replay.contents)
        self.pid = pid
        self.master = master
        self.queue = queue
        self.size = (cols, rows)
        readSource = DispatchSource.makeReadSource(fileDescriptor: master, queue: queue)
        exitWatch = ProcessWatch(pid: pid, queue: queue)
        readSource.setEventHandler { [weak self] in self?.readOutput() }
        readSource.setCancelHandler { close(master) }
        exitWatch.onExit = { [weak self] in self?.processExited() }
        readSource.resume()
        exitWatch.start()
    }

    /// What's written across the transcript where a dormant terminal's old
    /// shell ended and its new one begins (§4): never a silent restart.
    static func seam(idle: Int, since: Date) -> Data {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .short
        let hours = idle / 3600
        let how = hours >= 1 ? "\(hours) h" : "\(max(idle / 60, 1)) min"
        let line = "\r\n\u{1b}[0m\u{1b}[2m── new shell · the last one ended \(f.string(from: since)), after \(how) idle ──\u{1b}[0m\r\n"
        return Data(line.utf8)
    }

    /// Hangs up on the shell, as closing a terminal window does.
    func terminate() {
        guard !exited else { return }
        kill(-pid, SIGHUP)
        kill(pid, SIGHUP)
    }

    /// Ends the shell for having lain idle off screen; its exit is recorded
    /// as dormancy.
    func endForIdleness(idleSeconds: Int) {
        guard !exited else { return }
        endedForIdleness = true
        self.idleSeconds = idleSeconds
        terminate()
    }

    /// Each attachment's last size: when one leaves (an overview closed),
    /// the pty goes back to the size of the one that remains, so the
    /// program isn't left drawing for a pane that is gone.
    private var sizes: [ObjectIdentifier: (cols: UInt16, rows: UInt16)] = [:]

    /// Whether any attachment has seen the output so far: until one
    /// has, the replay is live — a shell's startup queries, say, whose
    /// answers it is still waiting for — and the attachment is told so.
    private var replayShown = false

    func attach(_ conn: any Channel, cols: UInt16, rows: UInt16, resume: Bool = false) {
        attachments.append(conn)
        sizes[ObjectIdentifier(conn)] = (cols, rows)
        // At its size first, so the snapshot is drawn for it.
        resize(cols: cols, rows: rows)
        if let screen {
            // The terminal as it is: its queries were answered when they came,
            // so what's typed now goes straight through. Its screen at once;
            // the history above it after, by backfill, from where its mark says.
            conn.send(Frame(.data, resume ? screen.catchUp : screen.attaching))
            conn.send(screen.mark(screen: true).frame)
            conn.send(Frame(.replayDone, Data([1])))
        } else {
            conn.send(Frame(.data, replay.replay))
            conn.send(Frame(.replayDone, Data([replayShown ? 0 : 1])))
        }
        replayShown = true
        if let stream = conn as? MuxStream {
            // Behind once a piece waits: then caught up with the screen.
            stream.highWater = Self.highWater(stream)
            stream.onDrain = { [weak self, weak stream] in
                guard let self, let stream else { return }
                self.caughtUp(stream)
            }
        }
    }

    func detach(_ conn: any Channel) {
        attachments.removeAll { $0 === conn }
        behind.remove(ObjectIdentifier(conn))
        sizes.removeValue(forKey: ObjectIdentifier(conn))
        if let last = attachments.last, let s = sizes[ObjectIdentifier(last)] { resize(cols: s.cols, rows: s.rows) }
    }

    var isAttached: Bool { !attachments.isEmpty }

    func handle(_ frame: Frame, from conn: (any Channel)? = nil) {
        switch frame.kind {
        case .data:
            input.append(frame.payload)
            writeInput()
        case .resize:
            guard let s = frame.size else { break }
            if let conn { sizes[ObjectIdentifier(conn)] = (s.cols, s.rows) }
            resize(cols: s.cols, rows: s.rows)
        default:
            break
        }
    }

    /// The recent output, to save; marks it saved.
    /// The shell's own marks in the stream, by where they fall: a command
    /// about to run (output starts after the mark's end), and one ended
    /// (output stops where the mark begins).
    private func scanMarks(_ data: Data) {
        let base = replay.end - Int64(markTail.count)
        let hay = markTail + [UInt8](data)
        let run: [UInt8] = Array("\u{1b}]7502;".utf8), done: [UInt8] = Array("\u{1b}]133;D".utf8)
        var i = 0
        while i < hay.count {
            if hay[i] == 0x1B {
                if hay.count - i >= run.count, Array(hay[i..<i + run.count]) == run {
                    // Past its terminator: BEL, or ESC \.
                    var j = i + run.count
                    while j < hay.count, hay[j] != 0x07, !(hay[j] == 0x1B && j + 1 < hay.count && hay[j + 1] == 0x5C) { j += 1 }
                    if j < hay.count { pendingStart = base + Int64(j + (hay[j] == 0x07 ? 1 : 2)) }
                    i = j
                    continue
                }
                if hay.count - i >= done.count, Array(hay[i..<i + done.count]) == done {
                    pendingEnd = base + Int64(i)
                }
            }
            i += 1
        }
        markTail = Array(hay.suffix(16))
    }

    /// The shell said a command (this id) would run: its output begins at
    /// the mark just seen.
    func beginCapture(_ id: Int) {
        captures[id] = (pendingStart ?? replay.end, nil)
        pendingStart = nil
        if captures.count > 2000, let oldest = captures.keys.min() { captures.removeValue(forKey: oldest) }
    }

    /// The command (this id) ended: its output stops at the mark just seen.
    func endCapture(_ id: Int) {
        guard let c = captures[id] else { return }
        captures[id] = (c.start, max(c.start, pendingEnd ?? replay.end))
        pendingEnd = nil
    }

    /// What a command printed, as the terminal received it, if it's still
    /// in the buffer; so far, if it hasn't ended.
    func output(ofCommand id: Int) -> Data? {
        guard let c = captures[id] else { return nil }
        return replay.slice(from: c.start, to: c.end ?? replay.end)
    }

    func takeHistory() -> Data {
        unsaved = false
        return replay.contents
    }

    var cwd: String? {
        var buf = [CChar](repeating: 0, count: 4096)
        guard mf_proc_cwd(pid, &buf, Int32(buf.count)) == 0 else { return nil }
        return String(cString: buf)
    }

    /// Whether something other than the shell itself is in the foreground.
    var isBusy: Bool {
        guard !exited else { return false }
        let fg = mf_pty_foreground(master)
        return fg > 0 && fg != pid
    }

    private func resize(cols: UInt16, rows: UInt16) {
        guard cols > 0, rows > 0, (cols, rows) != size else { return }
        size = (cols, rows)
        _ = mf_pty_resize(master, cols, rows)
        guard let screen else { return }
        let epoch = screen.epoch
        screen.resize(cols: cols, rows: rows)
        // A new width renumbers the history (rows rewrapped): said at once.
        if screen.epoch != epoch { sendMark(force: true) }
    }

    /// Where the history has got to, as last told the attachments.
    private var markedEnd: UInt64?

    /// The attachments told where the history has got to, when it moved.
    private func sendMark(force: Bool = false) {
        guard let screen else { return }
        let mark = screen.mark(screen: false)
        guard force || mark.end != markedEnd else { return }
        markedEnd = mark.end
        let frame = mark.frame
        for conn in attachments where !behind.contains(ObjectIdentifier(conn)) { conn.send(frame) }
    }

    /// A terminal's history after its screen (`BackfillRequest`): the rows
    /// asked for that are still kept, at most `limit` (the newest), newest
    /// first in pieces, each its rows' first and end, its width, its rows;
    /// a seam above them if older ones were asked for that won't come;
    /// then `replayDone`: all there is. Another numbering (the terminal
    /// made again, or reflowed since): nothing, closed.
    func backfill(_ req: BackfillRequest, to stream: MuxStream) {
        defer { stream.close() }
        guard let screen, screen.epoch == req.epoch else { return }
        defer { stream.send(Frame(.replayDone, Data())) }
        let to = min(req.to, screen.historyEnd)
        var from = max(req.from, screen.historyStart)
        if to > req.limit { from = max(from, to - req.limit) }
        let lost = from > req.from
        func piece(_ lo: UInt64, _ hi: UInt64, _ rows: Data) -> Frame {
            var d = Data(capacity: 18 + rows.count)
            withUnsafeBytes(of: lo.bigEndian) { d.append(contentsOf: $0) }
            withUnsafeBytes(of: hi.bigEndian) { d.append(contentsOf: $0) }
            withUnsafeBytes(of: screen.width.bigEndian) { d.append(contentsOf: $0) }
            d.append(rows)
            return Frame(.data, d)
        }
        let seam = Data("\u{1b}[0m\u{1b}[2m── earlier output not kept ──\u{1b}[0m".utf8)
        var hi = to
        while hi > from {
            // Cut at the first row of a line (found within another piece's
            // rows up), so a line wrapped over rows comes whole.
            var lo = max(from, hi >= Self.backfillPiece ? hi - Self.backfillPiece : 0)
            if lo > from {
                let floor = max(from, lo >= Self.backfillPiece ? lo - Self.backfillPiece : 0)
                let start = screen.lineStart(lo, floor: floor)
                if start > floor || start == from { lo = start }
            }
            var rows = screen.history(from: lo, to: hi)
            if lo == from, lost { rows = seam + Data("\r\n".utf8) + rows }
            stream.send(piece(lo, hi, rows))
            hi = lo
        }
        if from >= to, lost { stream.send(piece(from, from, seam + Data("\r\n".utf8))) }
    }

    /// Rows in a piece of backfill: small enough that a keystroke's frames
    /// interleave, big enough not to be many frames.
    static let backfillPiece: UInt64 = 400

    /// Output to each attachment, as it comes — but not to one whose stream
    /// is full (a slow link, a flood): that one waits, and is sent the
    /// screen as it is once its stream has room (`caughtUp`), skipping what
    /// it would never have caught up with.
    /// How much of a terminal's output may wait to go before it's behind:
    /// what the link holds (a round trip of it), so a ^C's answer is never
    /// more than that behind what's on its way — no less than a little, so a
    /// slow link isn't caught up with all the time; no more than a piece.
    static func highWater(_ stream: MuxStream) -> Int { min(Mux.bulkPiece, max(4 << 10, stream.linkHolds)) }

    private func passOn(_ data: Data) {
        screen?.feed(data)
        let frame = Frame(.data, data)
        for conn in attachments {
            let key = ObjectIdentifier(conn)
            if behind.contains(key) { continue }
            if let stream = conn as? MuxStream { stream.highWater = Self.highWater(stream) }
            if let stream = conn as? MuxStream, screen != nil, !stream.wantsMore {
                behind.insert(key)
                continue
            }
            // In the link's pieces: a flood here doesn't sit in front of
            // another terminal's keystroke.
            if let stream = conn as? MuxStream { stream.sendPieces(data) } else { conn.send(frame) }
        }
        // After the output, in order with it: where it took the history.
        sendMark()
    }

    /// Caught up with the screen as it is; what it skipped of the history,
    /// by backfill (its mark says from where).
    private func caughtUp(_ stream: MuxStream) {
        guard behind.remove(ObjectIdentifier(stream)) != nil, let screen else { return }
        stream.send(Frame(.data, screen.catchUp))
        stream.send(screen.mark(screen: true).frame)
    }

    private func readOutput() {
        var buf = [UInt8](repeating: 0, count: 65536)
        let n = read(master, &buf, buf.count)
        if n < 0 && (errno == EAGAIN || errno == EINTR) { return }
        guard n > 0 else {
            // EOF or EIO: the terminal's last process is gone.
            readSource.cancel()
            return
        }
        let data = Data(buf[0..<n])
        scanMarks(data)
        replay.append(data)
        unsaved = true
        if let title = titles.feed(data) { onTitle?(title) }
        if !attachments.isEmpty { replayShown = true }
        let signals = statuses.feed(data)
        // A program asking whether 7501 is spoken is answered at once,
        // here, on its own input — ahead of the client's reply to any
        // device-attributes query it sent to race ours.
        if signals.contains(where: { if case .query = $0 { return true } else { return false } }) {
            input.append(Data(StatusSignal.queryReply.utf8))
            writeInput()
        }
        if !signals.isEmpty { onStatus?(signals) }
        // A prompt for a password: looked at as output comes (sudo and ssh
        // set the terminal, then write the prompt), and again a moment after
        // (a script that writes its prompt first).
        checkPassword()
        passwordCheck?.cancel()
        let again = DispatchWorkItem { [weak self] in self?.checkPassword() }
        passwordCheck = again
        queue.asyncAfter(deadline: .now() + 0.2, execute: again)
        passOn(data)
    }

    private func writeInput() {
        while !input.isEmpty {
            let n = input.withUnsafeBytes { write(master, $0.baseAddress, $0.count) }
            if n > 0 {
                input.removeFirst(n)
            } else if n < 0 && errno == EINTR {
                continue
            } else if n < 0 && errno == EAGAIN {
                if inputSource == nil {
                    let source = DispatchSource.makeWriteSource(fileDescriptor: master, queue: queue)
                    source.setEventHandler { [weak self] in self?.writeInput() }
                    inputSource = source
                }
                if !inputSourceActive {
                    inputSourceActive = true
                    inputSource!.resume()
                }
                return
            } else {
                input.removeAll()
                break
            }
        }
        if inputSourceActive {
            inputSourceActive = false
            inputSource!.suspend()
        }
    }

    private func processExited() {
        var status: Int32 = 0
        guard waitpid(pid, &status, WNOHANG) == pid else { return }
        exited = true
        exitWatch.cancel()
        // Pass on whatever the shell wrote on its way out.
        while !readSource.isCancelled {
            var buf = [UInt8](repeating: 0, count: 65536)
            let n = read(master, &buf, buf.count)
            guard n > 0 else { break }
            let data = Data(buf[0..<n])
            replay.append(data)
            unsaved = true
            passOn(data)
        }
        if let inputSource {
            if !inputSourceActive { inputSource.resume() }
            inputSource.cancel()
        }
        if !readSource.isCancelled { readSource.cancel() }
        log("session \(id) exited: status \(status)")
        let conns = attachments
        attachments = []
        for conn in conns { conn.close() }
        onExit?(status)
    }

    /// A shell named in the host's preferences, as a path to run: the
    /// path given, or the name found on the PATH; nil if it can't be run.
    static func resolveShell(_ name: String) -> String? {
        let name = name.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return nil }
        func runnable(_ path: String) -> Bool {
            var dir: ObjCBool = false
            return FileManager.default.fileExists(atPath: path, isDirectory: &dir) && !dir.boolValue && access(path, X_OK) == 0
        }
        if name.contains("/") {
            let path = (name as NSString).expandingTildeInPath
            return runnable(path) ? path : nil
        }
        let dirs = (ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin").split(separator: ":")
        return dirs.map { "\($0)/\(name)" }.first(where: runnable)
    }

    /// The shell a terminal starts: the host's preference, else your
    /// login shell, unless $MANIFOLD_SHELL (in the server's environment)
    /// names another.
    static func chosenShell(preferred: String?) -> String {
        let chosen = preferred.flatMap(resolveShell)
        if let preferred, chosen == nil { log("the preferred shell \(preferred) can't be run here; the login shell instead") }
        let pw = getpwuid(getuid())
        let login: String = pw.flatMap { String(cString: $0.pointee.pw_shell) }.flatMap { $0.isEmpty ? nil : $0 } ?? "/bin/zsh"
        return chosen ?? ProcessInfo.processInfo.environment["MANIFOLD_SHELL"].flatMap { $0.isEmpty ? nil : $0 } ?? login
    }

    /// The known agents' commands the user's shell finds, as a login
    /// shell (as an agent block runs its command), in the catalog's order.
    static func availableAgents(preferred: String?) -> [String] {
        let shell = chosenShell(preferred: preferred)
        let names = AgentCatalog.known.map(\.command)
        let list = names.joined(separator: " ")
        let posix = "for c in \(list); do command -v \"$c\" >/dev/null 2>&1 && echo \"$c\"; done"
        let argv: [String]
        switch shell.lastPathComponent {
        case "fish": argv = [shell, "-l", "-c", "for c in \(list); if command -q $c; echo $c; end; end"]
        case "bash", "zsh", "sh", "dash", "ksh": argv = [shell, "-l", "-c", posix]
        default: argv = ["/bin/sh", "-l", "-c", posix]
        }
        guard let (out, _) = try? Child.run(argv, timeout: 20, quiet: true) else { return [] }
        // What rc files print on the way in is passed over: only the names.
        let said = Set(String(decoding: out, as: UTF8.self).split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) })
        return names.filter(said.contains)
    }

    /// The shell to start, and the environment to start it with: ours,
    /// less what belongs to the app that started us, plus the terminal's.
    /// The shell is the host's preference (`preferred`), else
    /// $MANIFOLD_SHELL, else the user's login shell.
    static func shellAndEnvironment(clientEnv: [String: String], preferred: String? = nil) -> (String, [String: String]) {
        var env = ProcessInfo.processInfo.environment
        for key in ["__CFBundleIdentifier", "XPC_SERVICE_NAME", "XPC_FLAGS", "PWD", "OLDPWD", "SHLVL",
                    "MANIFOLD_PANE", "MANIFOLD_BLOCK", "_", "TERM_SESSION_ID", "INSIDE_EMACS"] {
            env.removeValue(forKey: key)
        }
        for key in env.keys where key.hasPrefix("GHOSTTY_") || key.hasPrefix("OS_ACTIVITY_") {
            env.removeValue(forKey: key)
        }
        let pw = getpwuid(getuid())
        let shell = chosenShell(preferred: preferred)
        if let pw {
            env["HOME"] = String(cString: pw.pointee.pw_dir)
            env["USER"] = String(cString: pw.pointee.pw_name)
            env["LOGNAME"] = String(cString: pw.pointee.pw_name)
        }
        env["SHELL"] = shell
        if env["PATH"] == nil { env["PATH"] = "/usr/bin:/bin:/usr/sbin:/sbin" }
        // `manifold` on the PATH: beside the server in the app bundle
        // (Helpers/), or the server's own folder on a host it was installed
        // on, where a `manifold` script stands in for it.
        for dir in toolDirectories.reversed() where !(env["PATH"] ?? "").split(separator: ":").contains(Substring(dir)) {
            env["PATH"] = dir + ":" + (env["PATH"] ?? "")
        }
        if env["LANG"] == nil { env["LANG"] = "en_US.UTF-8" }
        for (k, v) in clientEnv where allowedClientEnv.contains(k) {
            env[k] = v
        }
        env["TERM_PROGRAM"] = "Manifold"
        env.removeValue(forKey: "TERM_PROGRAM_VERSION")

        env["MANIFOLD_BIN"] = toolDirectories.joined(separator: ":")
        // fish finds Ghostty's integration (working directory, titles) among
        // its vendor configuration.
        if shell.lastPathComponent == "fish", let res = env["GHOSTTY_RESOURCES_DIR"], FileManager.default.fileExists(atPath: res + "/shell-integration/fish") {
            env["XDG_DATA_DIRS"] = res + "/shell-integration" + (env["XDG_DATA_DIRS"].map { ":" + $0 } ?? ":/usr/local/share:/usr/share")
            env["GHOSTTY_SHELL_FEATURES"] = "title"
        }
        // zsh starts through Manifold's own layer (a .zshenv in the data
        // folder), which hands over to Ghostty's integration (working
        // directory, titles), which hands over to yours — and then, once
        // your rc files have run, puts `manifold` first on the PATH.
        if shell.lastPathComponent == "zsh", let layer = zshLayer() {
            if let old = env["ZDOTDIR"] { env["MANIFOLD_ZSH_ZDOTDIR"] = old }
            if let res = env["GHOSTTY_RESOURCES_DIR"], FileManager.default.fileExists(atPath: res + "/shell-integration/zsh") {
                env["MANIFOLD_GHOSTTY_ZDOTDIR"] = res + "/shell-integration/zsh"
                env["GHOSTTY_SHELL_FEATURES"] = "title"
            }
            env["ZDOTDIR"] = layer
        }
        return (shell, env)
    }

    /// The folder with Manifold's `.zshenv`, written fresh: it restores
    /// your ZDOTDIR, sources Ghostty's integration (which sources your
    /// .zshenv), and in an interactive shell adds a hook that runs once,
    /// before the first prompt, putting $MANIFOLD_BIN first on the PATH —
    /// after .zprofile and .zshrc, so nothing there comes before it.
    static func zshLayer() -> String? {
        let dir = Paths.directory.appendingPathComponent("zsh")
        let file = dir.appendingPathComponent(".zshenv")
        let script = """
        # Manifold's zsh layer. Written by manifoldd; edits are lost.
        if [[ -n "${MANIFOLD_ZSH_ZDOTDIR+X}" ]]; then
            'builtin' 'export' ZDOTDIR="$MANIFOLD_ZSH_ZDOTDIR"
            'builtin' 'unset' 'MANIFOLD_ZSH_ZDOTDIR'
        else
            'builtin' 'unset' 'ZDOTDIR'
        fi
        if [[ -n "${MANIFOLD_GHOSTTY_ZDOTDIR+X}" && -r "$MANIFOLD_GHOSTTY_ZDOTDIR/.zshenv" ]]; then
            [[ -z "${ZDOTDIR+X}" ]] || 'builtin' 'export' GHOSTTY_ZSH_ZDOTDIR="$ZDOTDIR"
            'builtin' 'typeset' _manifold_file="$MANIFOLD_GHOSTTY_ZDOTDIR/.zshenv"
            'builtin' 'unset' 'MANIFOLD_GHOSTTY_ZDOTDIR'
            'builtin' 'source' '--' "$_manifold_file"
            'builtin' 'unset' '_manifold_file'
        else
            'builtin' 'typeset' _manifold_file=${ZDOTDIR-$HOME}"/.zshenv"
            [[ ! -r "$_manifold_file" ]] || 'builtin' 'source' '--' "$_manifold_file"
            'builtin' 'unset' '_manifold_file'
        fi
        if [[ -o 'interactive' ]]; then
            'builtin' 'autoload' '-Uz' add-zsh-hook
            # Each command the shell runs, told to Manifold (OSC 7502) for
            # the terminal's scrubber: control characters blanked.
            __manifold_cmd() {
                'builtin' 'print' -rn -- $'\\e]7502;'"${1//[[:cntrl:]]/ }"$'\\a'
            }
            add-zsh-hook preexec __manifold_cmd
            if [[ -n "$MANIFOLD_BIN" ]]; then
                __manifold_path() {
                    'builtin' 'typeset' -gU path
                    path=("${(s/:/)MANIFOLD_BIN}" $path)
                    precmd_functions=(${precmd_functions:#__manifold_path})
                    'builtin' 'unfunction' '--' __manifold_path
                }
                add-zsh-hook precmd __manifold_path
            fi
        fi

        """
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            if (try? String(contentsOf: file, encoding: .utf8)) != script { try script.write(to: file, atomically: true, encoding: .utf8) }
            return dir.path
        } catch {
            return nil
        }
    }

    /// What fish runs after its configuration: $MANIFOLD_BIN's folders
    /// first on the PATH, in their order.
    static let fishStartup = "for d in (string split : \"$MANIFOLD_BIN\")[-1..1]; test -d $d; and fish_add_path --global --prepend --move $d; end; "
        + "function __manifold_cmd --on-event fish_preexec; printf '\\e]7502;%s\\a' (string replace -ra '[\\x00-\\x1f\\x7f]' ' ' -- \"$argv\"); end"

    /// The startup arguments Manifold gives a shell, as `ps` shows them,
    /// so a listing can leave them out: they are Manifold's, not yours.
    static var startupArguments: [String] {
        [" -C " + fishStartup, " --rcfile " + Paths.directory.appendingPathComponent("bash/rc").path]
    }

    /// bash's rc file, written fresh: it sources the profile files a login
    /// shell would, and .bashrc, then puts $MANIFOLD_BIN first on the PATH.
    static func bashLayer() -> String? {
        let dir = Paths.directory.appendingPathComponent("bash")
        let file = dir.appendingPathComponent("rc")
        let script = """
        # Manifold's bash rc. Written by manifoldd; edits are lost.
        [ -r /etc/profile ] && . /etc/profile
        if [ -r "$HOME/.bash_profile" ]; then . "$HOME/.bash_profile"
        elif [ -r "$HOME/.bash_login" ]; then . "$HOME/.bash_login"
        elif [ -r "$HOME/.profile" ]; then . "$HOME/.profile"
        fi
        [ -r "$HOME/.bashrc" ] && . "$HOME/.bashrc"
        # Prompt marks (OSC 133) and each command run (OSC 7502), for the
        # terminal's status and scrubber.
        __manifold_precmd() {
            local status=$?
            [ -n "$__manifold_ran" ] && printf '\\033]133;D;%s\\a' "$status"
            __manifold_ran=
            printf '\\033]7;kitty-shell-cwd://%s%s\\a' "$HOSTNAME" "$PWD"
            printf '\\033]133;A\\a'
        }
        __manifold_preexec() {
            [ -n "$COMP_LINE" ] && return
            [ -n "$__manifold_ran" ] && return
            case "$BASH_COMMAND" in __manifold_precmd*) return;; esac
            __manifold_ran=1
            local line
            line=$(HISTTIMEFORMAT= builtin history 1 2>/dev/null)
            line=${line#*[0-9]  }
            [ -z "$line" ] && line=$BASH_COMMAND
            printf '\\033]7502;%s\\a' "${line//[[:cntrl:]]/ }"
            printf '\\033]133;C\\a'
        }
        PROMPT_COMMAND="__manifold_precmd${PROMPT_COMMAND:+;$PROMPT_COMMAND}"
        trap '__manifold_preexec' DEBUG
        if [ -n "$MANIFOLD_BIN" ]; then
            __manifold_rest=$(printf '%s' "$PATH" | tr ':' '\\n' | grep -vxF -e "$(printf '%s' "$MANIFOLD_BIN" | tr ':' '\\n')" | paste -sd: -)
            export PATH="$MANIFOLD_BIN${__manifold_rest:+:$__manifold_rest}"
            unset __manifold_rest
        fi

        """
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            if (try? String(contentsOf: file, encoding: .utf8)) != script { try script.write(to: file, atomically: true, encoding: .utf8) }
            return file.path
        } catch {
            return nil
        }
    }

    /// Folders with the `manifold` command: Helpers/ beside this server in
    /// the app bundle, if there; the server's own folder.
    static var toolDirectories: [String] {
        let exe = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath()
        let own = exe.deletingLastPathComponent()
        let helpers = own.deletingLastPathComponent().appendingPathComponent("Helpers")
        var dirs: [String] = []
        if FileManager.default.isExecutableFile(atPath: helpers.appendingPathComponent("manifold").path) { dirs.append(helpers.path) }
        if FileManager.default.isExecutableFile(atPath: own.appendingPathComponent("manifold").path) { dirs.append(own.path) }
        return dirs
    }

    /// The `manifold` command, as a shell runs it with `--wait`: beside
    /// this server in the app bundle, else the server itself on a remote
    /// host (`manifoldd open`).
    static var editorCommand: String {
        let exe = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath()
        let helper = exe.deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Helpers/manifold")
        // Quoted only when it must be: a shell expands `$EDITOR` without
        // parsing quotes, and most paths have no spaces.
        func quote(_ s: String) -> String { s.contains(" ") ? "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'" : s }
        if FileManager.default.isExecutableFile(atPath: helper.path) { return quote(helper.path) + " --wait" }
        return quote(exe.path) + " open --wait"
    }

    private static let allowedClientEnv: Set<String> = [
        "TERM", "TERMINFO", "COLORTERM", "GHOSTTY_RESOURCES_DIR", "GHOSTTY_BIN_DIR", "LANG", "LC_ALL", "LC_CTYPE",
    ]
}

func withCStrings<R>(_ strings: [String], _ body: (UnsafePointer<UnsafeMutablePointer<CChar>?>) -> R) -> R {
    var ptrs: [UnsafeMutablePointer<CChar>?] = strings.map { strdup($0) }
    ptrs.append(nil)
    defer { for p in ptrs { free(p) } }
    return ptrs.withUnsafeBufferPointer { body($0.baseAddress!) }
}

func log(_ message: String) {
    let stamp = ISO8601DateFormatter().string(from: Date())
    FileHandle.standardError.write(Data("\(stamp) \(message)\n".utf8))
}

/// Tells when a child process exits: a process source where there is one
/// (Darwin), else SIGCHLD, shared, with the pids looked up.
final class ProcessWatch {
    let pid: pid_t
    var onExit: (() -> Void)?
    #if canImport(Darwin)
    private var source: DispatchSourceProcess?
    #else
    private static var watches: [pid_t: ProcessWatch] = [:]
    private static var signalSource: DispatchSourceSignal?
    #endif
    private let queue: DispatchQueue

    init(pid: pid_t, queue: DispatchQueue) {
        self.pid = pid
        self.queue = queue
    }

    func start() {
        #if canImport(Darwin)
        let s = DispatchSource.makeProcessSource(identifier: pid, eventMask: .exit, queue: queue)
        s.setEventHandler { [weak self] in self?.onExit?() }
        s.resume()
        source = s
        #else
        Self.watches[pid] = self
        if Self.signalSource == nil {
            signal(SIGCHLD, SIG_IGN)
            let s = DispatchSource.makeSignalSource(signal: SIGCHLD, queue: queue)
            s.setEventHandler {
                // Any child may have gone; each watched one is asked.
                for (pid, w) in Self.watches {
                    var status: Int32 = 0
                    let r = waitpid(pid, &status, WNOHANG | WNOWAIT)
                    if r == pid || (r < 0 && errno == ECHILD) {
                        Self.watches.removeValue(forKey: pid)
                        w.onExit?()
                    }
                }
            }
            s.resume()
            Self.signalSource = s
        }
        #endif
    }

    func cancel() {
        #if canImport(Darwin)
        source?.cancel()
        source = nil
        #else
        Self.watches.removeValue(forKey: pid)
        #endif
    }
}
