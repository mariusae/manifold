import AppKit
import ManifoldCore

/// What's left when Manifold crashes, and a way back in when it crashes
/// as it starts (§9). Ghostty's crash handler turns a crash into a quiet
/// exit, with no report from the system; so before handing on to it, a
/// handler of our own writes the signal and a backtrace to the logs —
/// from a stack of its own, as a stack overflow leaves none. Started from
/// the Finder, Manifold's error output (Swift's "Fatal error: …" among
/// it) goes to a log there too. And launches that die within half a
/// minute are counted: after two in a row, Manifold offers to start safe.
enum CrashGuard {
    /// ~/Library/Logs/Manifold (beside a test instance's data, for one).
    static var logs: URL {
        if let dir = ProcessInfo.processInfo.environment["MANIFOLD_DIR"], !dir.isEmpty {
            return URL(fileURLWithPath: dir).appendingPathComponent("CrashLogs")
        }
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/Manifold")
    }

    private static var pending: URL { logs.appendingPathComponent("last-crash.txt") }
    private static var launches: URL { Paths.directory.appendingPathComponent("unfinished-launches") }

    /// A report the last run left, moved to a name with its date: shown once.
    private(set) static var lastReport: URL?
    /// Launches in a row that ended (crashed) within half a minute, before this one.
    private(set) static var unfinished = 0

    /// Before anything else: the log and the launch counted. The handler
    /// comes later (`armHandler`), after Ghostty's, to run before it.
    static func start() {
        try? FileManager.default.createDirectory(at: logs, withIntermediateDirectories: true)
        if FileManager.default.fileExists(atPath: pending.path) {
            let f = DateFormatter()
            f.dateFormat = "yyyy-MM-dd-HHmmss"
            let date = ((try? FileManager.default.attributesOfItem(atPath: pending.path))?[.modificationDate] as? Date) ?? Date()
            let dated = logs.appendingPathComponent("crash-\(f.string(from: date)).txt")
            try? FileManager.default.moveItem(at: pending, to: dated)
            lastReport = dated
        }
        unfinished = Int((try? String(contentsOf: launches, encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "") ?? 0
        try? "\(unfinished + 1)".write(to: launches, atomically: true, encoding: .utf8)
        // Running a while, or quitting, it wasn't a crash on the way in.
        DispatchQueue.main.asyncAfter(deadline: .now() + 30) { launchedFine() }
        redirectErrors()
    }

    static func launchedFine() { try? FileManager.default.removeItem(at: launches) }

    /// The error output to Manifold.log, when it goes nowhere (started from
    /// the Finder), the log started afresh past 10 MB.
    private static func redirectErrors() {
        guard isatty(STDERR_FILENO) == 0, ProcessInfo.processInfo.environment["MANIFOLD_DEBUG"] == nil else { return }
        let log = logs.appendingPathComponent("Manifold.log")
        let size = (try? FileManager.default.attributesOfItem(atPath: log.path))?[.size] as? Int ?? 0
        let fd = open(log.path, O_WRONLY | O_CREAT | (size > 10 << 20 ? O_TRUNC : O_APPEND), 0o644)
        guard fd >= 0 else { return }
        dup2(fd, STDERR_FILENO)
        close(fd)
        let header = "\n--- Manifold started \(Date()) (pid \(getpid())) ---\n"
        FileHandle.standardError.write(Data(header.utf8))
    }

    /// The handler, over whatever is there (Ghostty's), which it hands on to.
    static func armHandler() {
        crashPath = strdup(pending.path)
        // Ghostty's crash reporter takes the task's exceptions (a bad access,
        // a Swift trap) before they become signals, and quits quietly: with
        // the task's ports given up, the system's crash reporter has them
        // again (a report in DiagnosticReports), then the signal comes here.
        let masks = exception_mask_t(EXC_MASK_BAD_ACCESS | EXC_MASK_BAD_INSTRUCTION | EXC_MASK_ARITHMETIC | EXC_MASK_BREAKPOINT | EXC_MASK_SOFTWARE)
        task_set_exception_ports(mach_task_self_, masks, mach_port_t(MACH_PORT_NULL), EXCEPTION_DEFAULT, THREAD_STATE_NONE)
        // A stack of its own, for a crash that used up the thread's.
        let size = 256 * 1024
        var stack = stack_t()
        stack.ss_sp = UnsafeMutableRawPointer.allocate(byteCount: size, alignment: 16)
        stack.ss_size = size
        stack.ss_flags = 0
        sigaltstack(&stack, nil)
        for sig in [SIGSEGV, SIGBUS, SIGILL, SIGTRAP, SIGABRT, SIGFPE] {
            var action = sigaction()
            action.__sigaction_u.__sa_sigaction = crashHandler
            action.sa_flags = SA_SIGINFO | SA_ONSTACK
            sigemptyset(&action.sa_mask)
            var old = sigaction()
            sigaction(sig, &action, &old)
            previous[Int(sig)] = old
        }
    }
}

extension CrashGuard {
    /// Debugging: whether each signal's handler is ours now.
    static var debugHandlers: String {
        [SIGSEGV, SIGBUS, SIGILL, SIGTRAP, SIGABRT, SIGFPE].map { sig in
            var now = sigaction()
            sigaction(sig, nil, &now)
            let ours = now.__sigaction_u.__sa_sigaction.map { unsafeBitCast($0, to: Int.self) } == unsafeBitCast(crashHandler as @convention(c) (Int32, UnsafeMutablePointer<__siginfo>?, UnsafeMutableRawPointer?) -> Void, to: Int.self)
            return "\(sig): \(ours ? "ours" : "another")"
        }.joined(separator: ", ")
    }
}

/// Set up before a crash: where the report goes, and the handlers there were.
private nonisolated(unsafe) var crashPath: UnsafeMutablePointer<CChar>?
private nonisolated(unsafe) var previous: [sigaction] = Array(repeating: sigaction(), count: 32)

private func crashHandler(_ sig: Int32, _ info: UnsafeMutablePointer<__siginfo>?, _ context: UnsafeMutableRawPointer?) {
    if let crashPath {
        let fd = open(crashPath, O_WRONLY | O_CREAT | O_TRUNC, 0o644)
        if fd >= 0 {
            func say(_ s: StaticString) { _ = write(fd, s.utf8Start, s.utf8CodeUnitCount) }
            say("Manifold crashed: signal ")
            var n = sig
            var digits = [UInt8](repeating: 0, count: 12)
            var i = digits.count
            repeat { i -= 1; digits[i] = UInt8(48 + n % 10); n /= 10 } while n > 0
            digits.withUnsafeBufferPointer { _ = write(fd, $0.baseAddress! + i, digits.count - i) }
            say("\nThe error output before it is in Manifold.log, beside this.\n\n")
            var frames = [UnsafeMutableRawPointer?](repeating: nil, count: 128)
            let count = backtrace(&frames, Int32(frames.count))
            backtrace_symbols_fd(&frames, count, fd)
            close(fd)
        }
    }
    // On to the handler that was there (Ghostty's), or the default.
    var old = previous[Int(sig)]
    let handler = old.__sigaction_u.__sa_handler
    if old.sa_flags & SA_SIGINFO != 0, let f = old.__sigaction_u.__sa_sigaction {
        f(sig, info, context)
    } else if let handler, unsafeBitCast(handler, to: Int.self) > 1 {
        handler(sig)
    } else {
        old = sigaction()
        old.__sigaction_u.__sa_handler = SIG_DFL
        sigaction(sig, &old, nil)
        raise(sig)
    }
}
