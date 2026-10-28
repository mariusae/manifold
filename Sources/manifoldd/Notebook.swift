import CPTY
import Foundation
import ManifoldCore

/// A shell notebook's shell (§7.7): the user's zsh or bash on a pty of its
/// own, with `TERM=dumb`, living on between runs so that what one cell
/// sets (a variable, a directory, an alias) the next one has.
///
/// The shell is quieted once its rc files have run — no echo, no prompt,
/// no line editor — and given a prompt hook that writes `OSC 7503;E;
/// status;pwd`. A cell's text is written to a file the shell evaluates, on a
/// line that first writes `OSC 7503;B`: what comes between the two marks
/// is the cell's output. The end mark comes from the prompt hook, so a
/// run cut short by ^C, which takes the rest of the line with it, still
/// ends, with its status (130).
final class NotebookShell {
    let id: BlockID
    let pid: pid_t
    let name: String
    private let master: Int32
    private let queue: DispatchQueue
    private let readSource: DispatchSourceRead
    private let exitWatch: ProcessWatch
    private let folder: URL
    private var pending: [UInt8] = []
    private var input = Data()
    private var writer: DispatchSourceWrite?
    private var writerActive = false
    private var exited = false
    /// The shell has run its rc files and the quieting line: runs may go.
    private(set) var ready = false
    /// A run's line sent; its output is what follows its begin mark.
    private(set) var busy = false
    private var capturing = false
    /// Interrupted before its begin mark showed: the next end mark is its.
    private var interrupted = false
    private var output = Data()
    private var runs = 0

    /// Ready for its first run.
    var onReady: (() -> Void)?
    /// What the running cell has printed so far.
    var onOutput: ((Data) -> Void)?
    /// The run ended: its status and where the shell is now.
    var onEnded: ((Data, Int32?, String?) -> Void)?
    var onExit: (() -> Void)?

    static let begin = Array("\u{1b}]7503;".utf8)

    init?(id: BlockID, cwd: String?, preferred: String?, queue: DispatchQueue) {
        var (shell, env) = Session.shellAndEnvironment(clientEnv: [:], preferred: preferred)
        // zsh or bash, whose hooks it knows; the user's if it's one of them.
        let base = shell.lastPathComponent
        if base != "zsh" && base != "bash" {
            shell = ["/bin/zsh", "/usr/bin/zsh", "/bin/bash", "/usr/bin/bash"].first { FileManager.default.isExecutableFile(atPath: $0) } ?? "/bin/sh"
            env["SHELL"] = shell
        }
        // No terminal to speak to: nothing of Ghostty's.
        env.removeValue(forKey: "MANIFOLD_GHOSTTY_ZDOTDIR")
        for k in env.keys where k.hasPrefix("GHOSTTY_") { env.removeValue(forKey: k) }
        env["TERM"] = "dumb"
        env.removeValue(forKey: "COLORTERM")
        env["PAGER"] = "cat"
        env["GIT_PAGER"] = "cat"
        env["MANPAGER"] = "cat"
        env["MANIFOLD_BLOCK"] = id.description
        env["MANIFOLD_HOST"] = id.host.raw
        let editor = Session.editorCommand
        env["EDITOR"] = editor
        env["VISUAL"] = editor
        env["MANIFOLD_EDITOR"] = editor
        let name = shell.lastPathComponent
        var args = ["-" + name]
        if name == "bash", let rc = Session.bashLayer() { args = [name, "--rcfile", rc] }
        let dir = cwd.flatMap { FileManager.default.fileExists(atPath: $0) ? $0 : nil } ?? FileManager.default.homeDirectoryForCurrentUser.path
        var master: Int32 = -1
        let pid = withCStrings(args) { argv in
            withCStrings(env.map { "\($0.key)=\($0.value)" }) { envp in
                mf_pty_spawn(shell, argv, envp, dir, 120, 40, &master)
            }
        }
        guard pid > 0 else {
            log("notebook \(id): spawn \(shell) failed: \(String(cString: strerror(errno)))")
            return nil
        }
        log("notebook \(id) shell started: pid \(pid) in \(dir)")
        self.id = id
        self.pid = pid
        self.name = name
        self.master = master
        self.queue = queue
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("manifold-notebook-\(getuid())-\(pid)")
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        readSource = DispatchSource.makeReadSource(fileDescriptor: master, queue: queue)
        exitWatch = ProcessWatch(pid: pid, queue: queue)
        readSource.setEventHandler { [weak self] in self?.readAvailable() }
        readSource.setCancelHandler { close(master) }
        exitWatch.onExit = { [weak self] in self?.processExited() }
        readSource.resume()
        exitWatch.start()
        send(Self.quieting(name) + "; printf '\\033]7503;R\\007'\n")
    }

    /// The line that quiets the shell and gives it the end mark.
    static func quieting(_ shell: String) -> String {
        let mark = #"printf '\033]7503;E;%d;%s\007' $? "$PWD""#
        let env = "export TERM=dumb PAGER=cat GIT_PAGER=cat MANPAGER=cat"
        if shell == "bash" {
            return "stty -echo; trap - DEBUG; PS1=''; PS2=''; PS0=''; PROMPT_COMMAND='\(mark.replacingOccurrences(of: "'", with: "'\\''"))'; \(env)"
        }
        return "unsetopt zle prompt_cr prompt_sp 2>/dev/null; stty -echo; PROMPT=''; RPROMPT=''; PS2=''; PROMPT_EOL_MARK=''; "
            + "precmd_functions=(); preexec_functions=(); chpwd_functions=(); precmd() { \(mark); }; \(env)"
    }

    /// Runs a cell's text: written to a file, evaluated by the shell.
    func run(_ source: String) {
        guard ready, !busy, !exited else { return }
        // The last run's file goes now: removed on the line, it would
        // stand in for the cell's status.
        try? FileManager.default.removeItem(at: folder.appendingPathComponent("cell-\(runs)"))
        runs += 1
        let file = folder.appendingPathComponent("cell-\(runs)")
        try? (source.hasSuffix("\n") ? source : source + "\n").write(to: file, atomically: true, encoding: .utf8)
        busy = true
        capturing = false
        interrupted = false
        output = Data()
        let quoted = "'" + file.path.replacingOccurrences(of: "'", with: "'\\''") + "'"
        // Evaluated, not sourced: an error reads as it would at a prompt,
        // not prefixed with the file's name.
        send("printf '\\033]7503;B\\007'; eval \"$(<\(quoted))\"\n")
    }

    /// ^C to whatever runs in the foreground.
    func interrupt() {
        interrupted = true
        send("\u{03}")
    }

    /// The foreground program killed, if it isn't the shell itself (a
    /// program that ignores ^C).
    func killForeground() {
        let group = mf_pty_foreground(master)
        if group > 0, group != pid { kill(-group, SIGKILL) } else { interrupt() }
    }

    func terminate() {
        guard !exited else { return }
        kill(-pid, SIGHUP)
        kill(pid, SIGHUP)
    }

    // MARK: Reading

    private func readAvailable() {
        var buf = [UInt8](repeating: 0, count: 65536)
        let n = read(master, &buf, buf.count)
        guard n > 0 else {
            if n == 0 || (errno != EAGAIN && errno != EINTR) { readSource.cancel() }
            return
        }
        scan(Array(buf[0..<n]))
    }

    /// The bytes, between the marks: kept while a run's output; the marks acted on.
    private func scan(_ data: [UInt8]) {
        var hay = pending + data
        pending = []
        var grew = false
        while !hay.isEmpty {
            guard let at = find(Self.begin, in: hay) else {
                // A mark may be starting at the very end: kept for the next read.
                var keep = hay.count
                if let esc = hay.lastIndex(of: 0x1B), hay.count - esc < Self.begin.count, Array(hay[esc...]) == Array(Self.begin.prefix(hay.count - esc)) { keep = esc }
                if capturing, keep > 0 { output.append(contentsOf: hay[0..<keep]); grew = true }
                pending = Array(hay[keep...])
                break
            }
            if capturing, at > 0 { output.append(contentsOf: hay[0..<at]); grew = true }
            guard let bel = hay[at...].firstIndex(of: 0x07) else {
                pending = Array(hay[at...])
                break
            }
            let body = String(decoding: hay[(at + Self.begin.count)..<bel], as: UTF8.self)
            hay = Array(hay[(bel + 1)...])
            mark(body)
        }
        if grew { onOutput?(output) }
    }

    private func mark(_ body: String) {
        let parts = body.split(separator: ";", maxSplits: 2, omittingEmptySubsequences: false).map(String.init)
        switch parts.first {
        case "B":
            if busy { capturing = true }
        case "R":
            // The quieting line has run: prompts from here on are the hook's.
            if !ready {
                ready = true
                onReady?()
            }
        case "E":
            // A prompt's end mark ends a run only once the run has begun
            // (a stray prompt from the shell's start doesn't), or was cut short.
            if ready, busy, capturing || interrupted {
                busy = false
                capturing = false
                let status = parts.count > 1 ? Int32(parts[1]) : nil
                let pwd = parts.count > 2 && !parts[2].isEmpty ? parts[2] : nil
                onEnded?(output, status, pwd)
                output = Data()
            }
        default:
            break
        }
    }

    private func find(_ needle: [UInt8], in hay: [UInt8]) -> Int? {
        guard hay.count >= needle.count else { return nil }
        var i = 0
        while let j = hay[i...].firstIndex(of: needle[0]), j + needle.count <= hay.count {
            if Array(hay[j..<j + needle.count]) == needle { return j }
            i = j + 1
        }
        return nil
    }

    // MARK: Writing

    private func send(_ s: String) {
        input.append(Data(s.utf8))
        flush()
    }

    private func flush() {
        while !input.isEmpty {
            let n = input.withUnsafeBytes { write(master, $0.baseAddress, $0.count) }
            if n > 0 {
                input.removeFirst(n)
            } else if n < 0 && errno == EINTR {
                continue
            } else if n < 0 && errno == EAGAIN {
                if writer == nil {
                    let w = DispatchSource.makeWriteSource(fileDescriptor: master, queue: queue)
                    w.setEventHandler { [weak self] in self?.flush() }
                    writer = w
                }
                if !writerActive { writerActive = true; writer!.resume() }
                return
            } else {
                input.removeAll()
            }
        }
        if writerActive { writerActive = false; writer!.suspend() }
    }

    private func processExited() {
        guard !exited else { return }
        exited = true
        log("notebook \(id) shell exited")
        if busy {
            busy = false
            onEnded?(output, nil, nil)
        }
        if writerActive { writer?.resume() }
        writer?.cancel()
        readSource.cancel()
        try? FileManager.default.removeItem(at: folder)
        onExit?()
    }
}
