import Foundation
import Testing
@testable import ManifoldCore

// I-2 (STATE-MACHINES.md): a command or an agent's turn is never left
// running without a live shell, and "running" and how a run ended are
// read one way.

private let h = HostID("h")
private func at(_ s: Double) -> Stamp { Stamp(wall: Int64(s * 1000), host: h) }
private let now = Date(timeIntervalSince1970: 10_000)

private func terminal(running command: String = "make") -> Block {
    var b = Block(id: BlockID(host: h), kind: .terminal, created: at(0))
    b.apply(.shell(.started(pid: 42)), at: at(9000))
    b.apply(.ran(id: 1, command, at: at(9001)), at: at(9001))
    return b
}

@Test func aCommandWhoseShellEndsIsNoLongerRunning() {
    for end: ShellEvent in [.ended(status: 129), .dormant(idleSeconds: 3600), .started(pid: 43)] {
        var b = terminal()
        #expect(b.terminal?.commands?.last?.isRunning == true)
        b.apply(.shell(end), at: at(9500))
        let c = b.terminal?.commands?.last
        #expect(c?.isRunning == false, "still running after \(end)")
        #expect(c?.abandoned == true)
        #expect(c?.ended == at(9500))
        #expect(c?.outcome == "its shell ended")
        // Not "running for 3 d" in mani ls and the cards, nor "ok".
        let s = b.summary(now: now)
        #expect(s.tone != .running)
        #expect(!s.lines.joined().contains("running"))
        #expect(s.lines.contains { $0.hasPrefix("its shell ended") })
    }
}

@Test func aCommandThatEndsOfItsOwnIsKeptAsItSaid() {
    var b = terminal()
    b.apply(.exited(id: 1, status: 2, at: at(9005)), at: at(9005))
    b.apply(.shell(.ended(status: 0)), at: at(9500))
    let c = b.terminal?.commands?.last
    #expect(c?.status == 2 && c?.ended == at(9005) && c?.abandoned == false)
    #expect(c?.outcome == "exit 2")
}

@Test func anAgentsTurnWhoseShellEndsIsNoLongerWorking() {
    var b = terminal(running: "claude")
    b.apply(.turn(AgentTurn(id: 1, agent: "claude", prompt: "fix it", began: at(9001))), at: at(9001))
    #expect(b.summary(now: now).note == "working")
    b.apply(.shell(.ended(status: 1)), at: at(9500))
    #expect(b.terminal?.turns?.last?.ended == at(9500))
    #expect(b.summary(now: now).note != "working")
    // Nor taken for an agent at work by the command still open.
    #expect(b.agent == nil)
}

@Test func anOutputSaysHowItsRunEndedOneWay() {
    func output(_ o: OutputState) -> Block {
        var b = Block(id: BlockID(host: h), kind: .output, created: at(0))
        b.apply(.output(o), at: at(9000))
        return b
    }
    // A file's old version: no command, so neither "running" nor "ok".
    let old = OutputState(line: "notes.md as of today", ended: at(9000), output: "text", plain: true)
    #expect(old.run == .none && old.outcome == nil)
    #expect(!output(old).summary(now: now).lines.joined().contains("running"))
    #expect(output(old).summary(now: now).lines.first == "notes.md as of today")
    // A notebook's cell whose shell died: ended, with no status.
    let died = OutputState(line: "make", ran: at(9000), ended: at(9002))
    #expect(died.outcome == "its shell ended")
    #expect(output(died).summary(now: now).lines.contains { $0.hasPrefix("its shell ended") })
    let running = OutputState(line: "make", ran: at(9000))
    #expect(running.run == .running(since: at(9000)) && running.outcome == "running")
    let failed = OutputState(line: "make", status: 2, ran: at(9000), ended: at(9002))
    #expect(failed.outcome == "exit 2")
    #expect(output(failed).summary(now: now).lines.contains { $0.hasPrefix("exit 2") })
}
