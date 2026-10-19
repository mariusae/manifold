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
/// app. Terminals in the app attach to it through `manifoldd attach`.
final class Session {
    let id: BlockID
    let pid: pid_t
    private let master: Int32
    private let queue: DispatchQueue
    private let readSource: DispatchSourceRead
    private let exitWatch: ProcessWatch
    private var replay: ReplayBuffer
    /// Whether there's output not yet saved to disk.
    private(set) var unsaved = false
    private var titles = TitleScanner()
    private var attachments: [Connection] = []
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
    private var statuses = StatusScanner()

    init?(id: BlockID, cwd: String?, cols: UInt16, rows: UInt16, env: [String: String], history: Data,
          command: String? = nil, queue: DispatchQueue) {
        var (shell, environment) = Session.shellAndEnvironment(clientEnv: env)
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

    func attach(_ conn: Connection, cols: UInt16, rows: UInt16) {
        attachments.append(conn)
        sizes[ObjectIdentifier(conn)] = (cols, rows)
        conn.send(Frame(.data, replay.replay))
        conn.send(Frame(.replayDone, Data([replayShown ? 0 : 1])))
        replayShown = true
        resize(cols: cols, rows: rows)
    }

    func detach(_ conn: Connection) {
        attachments.removeAll { $0 === conn }
        sizes.removeValue(forKey: ObjectIdentifier(conn))
        if let last = attachments.last, let s = sizes[ObjectIdentifier(last)] { resize(cols: s.cols, rows: s.rows) }
    }

    var isAttached: Bool { !attachments.isEmpty }

    func handle(_ frame: Frame, from conn: Connection? = nil) {
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
        let frame = Frame(.data, data)
        for conn in attachments { conn.send(frame) }
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
            let frame = Frame(.data, data)
            for conn in attachments { conn.send(frame) }
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

    /// The user's login shell, and the environment to start it with: ours,
    /// less what belongs to the app that started us, plus the terminal's.
    private static func shellAndEnvironment(clientEnv: [String: String]) -> (String, [String: String]) {
        var env = ProcessInfo.processInfo.environment
        for key in ["__CFBundleIdentifier", "XPC_SERVICE_NAME", "XPC_FLAGS", "PWD", "OLDPWD", "SHLVL",
                    "MANIFOLD_PANE", "MANIFOLD_BLOCK", "_", "TERM_SESSION_ID", "INSIDE_EMACS"] {
            env.removeValue(forKey: key)
        }
        for key in env.keys where key.hasPrefix("GHOSTTY_") || key.hasPrefix("OS_ACTIVITY_") {
            env.removeValue(forKey: key)
        }
        let pw = getpwuid(getuid())
        let shell = pw.flatMap { String(cString: $0.pointee.pw_shell) }.flatMap { $0.isEmpty ? nil : $0 } ?? "/bin/zsh"
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
        if [[ -o 'interactive' && -n "$MANIFOLD_BIN" ]]; then
            __manifold_path() {
                'builtin' 'typeset' -gU path
                path=("${(s/:/)MANIFOLD_BIN}" $path)
                precmd_functions=(${precmd_functions:#__manifold_path})
                'builtin' 'unfunction' '--' __manifold_path
            }
            'builtin' 'autoload' '-Uz' add-zsh-hook
            add-zsh-hook precmd __manifold_path
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
    static let fishStartup = "for d in (string split : \"$MANIFOLD_BIN\")[-1..1]; test -d $d; and fish_add_path --global --prepend --move $d; end"

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
