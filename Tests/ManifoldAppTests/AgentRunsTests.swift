import AppKit
import Testing
import ManifoldCore
@testable import Manifold

// An ask is typed into an agent only while the agent runs there: its
// terminal running it in place of a shell, or its shell's command now the
// agent's — not a shell an agent has left (what's typed would run as a
// command line), though the block still names the agent by its last status.
@MainActor
@Test func anAgentIsAskedOnlyWhileItRuns() {
    let t0 = Stamp(wall: 1), t1 = Stamp(wall: 2)
    func terminal(_ edit: (inout TerminalState) -> Void) -> Block {
        var b = Block(id: BlockID(host: .local), kind: .terminal, created: t0)
        var t = TerminalState()
        t.pid = 42
        edit(&t)
        b.terminal = t
        return b
    }
    // In place of a shell.
    #expect(MainWindowController.agentRuns(terminal { $0.command = "claude" }))
    // Typed at a shell's prompt, still running.
    #expect(MainWindowController.agentRuns(terminal { $0.commands = [ShellCommand(id: 1, text: "claude --resume", at: t0)] }))
    // Ended: the shell's back. Its last status still names Claude.
    var left = terminal { $0.commands = [ShellCommand(id: 1, text: "claude", at: t0, status: 0, ended: t1)] }
    left.status = [rootStatusID: StatusRecord(state: .idle, app: "claude", at: t1)]
    #expect(left.agent != nil)
    #expect(!MainWindowController.agentRuns(left))
    // Another program running in the shell.
    var other = terminal { $0.commands = [ShellCommand(id: 2, text: "vim notes.md", at: t1)] }
    other.status = [rootStatusID: StatusRecord(state: .idle, app: "claude", at: t1)]
    #expect(!MainWindowController.agentRuns(other))
    // No shell at all.
    #expect(!MainWindowController.agentRuns(terminal { $0.pid = nil; $0.command = "claude" }))
}
