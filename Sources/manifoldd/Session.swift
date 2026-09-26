import CPTY
import Foundation
import ManifoldCore

/// A shell running on a pseudo-terminal the server owns, so it outlives the
/// app. Terminals in the app attach to it through `manifoldd attach`.
final class Session {
    let id: UUID
    let pid: pid_t
    private let master: Int32
    private let queue: DispatchQueue
    private let readSource: DispatchSourceRead
    private let exitSource: DispatchSourceProcess
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

    var onExit: (() -> Void)?
    var onTitle: ((String) -> Void)?

    init?(id: UUID, cwd: String?, cols: UInt16, rows: UInt16, env: [String: String], history: Data,
          queue: DispatchQueue) {
        let (shell, environment) = Session.shellAndEnvironment(clientEnv: env)
        let argv0 = "-" + (shell as NSString).lastPathComponent
        let dir = cwd.flatMap { FileManager.default.fileExists(atPath: $0) ? $0 : nil }
            ?? FileManager.default.homeDirectoryForCurrentUser.path

        var master: Int32 = -1
        let pid = withCStrings([argv0]) { argv in
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
        exitSource = DispatchSource.makeProcessSource(identifier: pid, eventMask: .exit, queue: queue)
        readSource.setEventHandler { [weak self] in self?.readOutput() }
        readSource.setCancelHandler { close(master) }
        exitSource.setEventHandler { [weak self] in self?.processExited() }
        readSource.resume()
        exitSource.resume()
    }

    /// Hangs up on the shell, as closing a terminal window does.
    func terminate() {
        guard !exited else { return }
        kill(-pid, SIGHUP)
        kill(pid, SIGHUP)
    }

    func attach(_ conn: Connection, cols: UInt16, rows: UInt16) {
        attachments.append(conn)
        conn.send(Frame(.data, replay.replay))
        conn.send(Frame(.replayDone))
        resize(cols: cols, rows: rows)
    }

    func detach(_ conn: Connection) {
        attachments.removeAll { $0 === conn }
    }

    func handle(_ frame: Frame) {
        switch frame.kind {
        case .data:
            input.append(frame.payload)
            writeInput()
        case .resize:
            if let s = frame.size { resize(cols: s.cols, rows: s.rows) }
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
        var buf = [CChar](repeating: 0, count: Int(MAXPATHLEN))
        guard mf_proc_cwd(pid, &buf, Int32(buf.count)) == 0 else { return nil }
        return String(cString: buf)
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
        exitSource.cancel()
        // Pass on whatever the shell wrote on its way out.
        while !readSource.isCancelled {
            var buf = [UInt8](repeating: 0, count: 65536)
            let n = read(master, &buf, buf.count)
            guard n > 0 else { break }
            let frame = Frame(.data, Data(buf[0..<n]))
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
        onExit?()
    }

    /// The user's login shell, and the environment to start it with: ours,
    /// less what belongs to the app that started us, plus the terminal's.
    private static func shellAndEnvironment(clientEnv: [String: String]) -> (String, [String: String]) {
        var env = ProcessInfo.processInfo.environment
        for key in ["__CFBundleIdentifier", "XPC_SERVICE_NAME", "XPC_FLAGS", "PWD", "OLDPWD", "SHLVL",
                    "MANIFOLD_DIR", "_", "TERM_SESSION_ID", "INSIDE_EMACS"] {
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
        if env["LANG"] == nil { env["LANG"] = "en_US.UTF-8" }
        for (k, v) in clientEnv where allowedClientEnv.contains(k) {
            env[k] = v
        }
        env["TERM_PROGRAM"] = "Manifold"
        env.removeValue(forKey: "TERM_PROGRAM_VERSION")

        // Ghostty's zsh integration reports the working directory and sets
        // titles; it's loaded by pointing ZDOTDIR at it.
        if (shell as NSString).lastPathComponent == "zsh", let res = env["GHOSTTY_RESOURCES_DIR"] {
            let dir = res + "/shell-integration/zsh"
            if FileManager.default.fileExists(atPath: dir) {
                if let old = env["ZDOTDIR"] { env["GHOSTTY_ZSH_ZDOTDIR"] = old }
                env["ZDOTDIR"] = dir
                env["GHOSTTY_SHELL_FEATURES"] = "title"
            }
        }
        return (shell, env)
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
