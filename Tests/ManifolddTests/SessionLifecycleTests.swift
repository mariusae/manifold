import Foundation
import Testing
import ManifoldCore
@testable import manifoldd

/// How many descriptors this process has open.
func openDescriptors() -> Int {
    (try? FileManager.default.contentsOfDirectory(atPath: "/dev/fd").count) ?? -1
}

/// A process as the kernel has it, without reaping it: gone (reaped),
/// a zombie (ended, not reaped), or alive.
private enum ProcessState { case gone, zombie, alive }
private func state(of pid: pid_t) -> ProcessState {
    var info = kinfo_proc()
    var size = MemoryLayout<kinfo_proc>.stride
    var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
    guard sysctl(&mib, 4, &info, &size, nil, 0) == 0, size > 0 else { return .gone }
    return info.kp_proc.p_stat == SZOMB ? .zombie : .alive
}

/// Runs `queue` (and the main run loop) until `done` or the time's up.
func wait(_ seconds: Double, on queue: DispatchQueue, until done: () -> Bool) {
    let end = Date().addingTimeInterval(seconds)
    while Date() < end, !done() {
        queue.sync {}
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))
    }
}

/// Tests that start processes and count this process's descriptors: one at
/// a time, so one's descriptors don't land in another's count.
@Suite(.serialized) struct ProcessLifecycle {}

extension ProcessLifecycle {
    /// A shell's session let go of as the server discards a block — taken
    /// out of its table and hung up on, before the shell has exited — still
    /// sees it out: the shell reaped (not left a zombie) and its pty closed.
    @Test func aSessionLetGoOfWhileItsShellEndsStillReapsItAndClosesItsPty() throws {
        let queue = DispatchQueue(label: "test.session")
        let before = openDescriptors()
        var session: Session? = queue.sync {
            Session(id: BlockID(host: HostID("testhost")), cwd: "/tmp", cols: 80, rows: 24, env: [:], history: Data(),
                    shell: "/bin/sh", queue: queue)
        }
        let pid = try #require(session?.pid)
        #expect(openDescriptors() > before)
        queue.sync {
            session?.terminate()
            session = nil
        }
        // Long enough for the hang-up to end it and the exit to be seen.
        wait(3, on: queue) { state(of: pid) == .gone }
        #expect(state(of: pid) != .zombie, "the shell was left a zombie")
        #expect(state(of: pid) != .alive, "the shell is still running")
        wait(1, on: queue) { openDescriptors() <= before }
        #expect(openDescriptors() <= before, "the session's pty is still open")
    }

    /// A notebook's shell, let go of as a notebook is restarted or deleted:
    /// reaped too, and its pty closed. (Nothing reaped a notebook's shell, so
    /// every one that ended was left a zombie.)
    @Test func aNotebookShellLetGoOfWhileItEndsIsReapedAndClosed() throws {
        let queue = DispatchQueue(label: "test.notebook")
        let before = openDescriptors()
        var shell: NotebookShell? = queue.sync {
            NotebookShell(id: BlockID(host: HostID("testhost")), cwd: "/tmp", preferred: "/bin/zsh", queue: queue)
        }
        let pid = try #require(shell?.pid)
        // Started (its first prompt), so the hang-up lands on a shell at rest.
        wait(3, on: queue) { queue.sync { shell?.ready ?? true } }
        queue.sync {
            shell?.terminate()
            shell = nil
        }
        wait(3, on: queue) { state(of: pid) == .gone }
        #expect(state(of: pid) != .zombie, "the notebook's shell was left a zombie")
        #expect(state(of: pid) != .alive, "the notebook's shell is still running")
        wait(1, on: queue) { openDescriptors() <= before }
        #expect(openDescriptors() <= before, "the notebook's pty is still open")
    }
}
