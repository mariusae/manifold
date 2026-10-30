import Foundation
import Testing
@testable import ManifoldCore

@Test func blocksSayThemselvesInAFewLines() {
    let h = HostID("h")
    let now = Date(timeIntervalSince1970: 10_000)
    func at(_ s: Double) -> Stamp { Stamp(wall: Int64(s * 1000), host: h) }
    // A note: its first lines, its title's own left out, Markdown's marks off.
    var note = Block(id: BlockID(host: h), kind: .text, created: at(0))
    note.apply(.content("# Plan\n\n- **ship** the [beta](https://x)\n\nthen rest\n", encoding: "utf-8", lineEnding: "\n", fingerprint: nil), at: at(1))
    let ns = note.summary(now: now)
    #expect(ns.title == "Plan")
    #expect(ns.lines == ["ship the beta", "then rest"])
    #expect(Block.firstLines("Plain, _italic_, *bold italic*, snake_case_name", skipping: "", count: 1) == ["Plain, italic, bold italic, snake_case_name"])
    // A terminal: its last command, how it ended, the one before; when.
    var term = Block(id: BlockID(host: h), kind: .terminal, created: at(0))
    term.apply(.ran(id: 1, "make", at: at(9000)), at: at(9000))
    term.apply(.exited(id: 1, status: 0, at: at(9001)), at: at(9001))
    term.apply(.ran(id: 2, "make test", at: at(9990)), at: at(9990))
    term.apply(.exited(id: 2, status: 2, at: at(9995)), at: at(9995))
    let ts = term.summary(now: now)
    #expect(ts.lines == ["$ make test", "exit 2", "$ make"])
    #expect(ts.note == "now" && ts.tone == .failed && ts.code)
    // A diff: files and lines changed.
    var diff = Block(id: BlockID(host: h), kind: .diff, created: at(0))
    diff.apply(.diffLoaded(oldText: nil, newText: nil, patch: "--- a/x.swift\n+++ b/x.swift\n@@ -1 +1,2 @@\n-a\n+b\n+c\n", error: nil, at: at(9000)), at: at(9000))
    #expect(diff.summary(now: now).lines == ["1 file, +2 −1", "x.swift"])
    #expect(BlockSummary.ago(at(10_000 - 7200), now: now) == "2h")
}

@Test func summaryLinesLeaveATerminalsEscapesOut() {
    // Shell integration's marks and colors, as output captures them.
    #expect(Block.oneLine("\u{1B}]133;C\u{07}\u{1B}[1;32mwait-test\u{1B}[0m \u{1B}]133;D;0\u{1B}\\") == "wait-test")
    #expect(Block.oneLine("a\tb\r\n c") == "a b c")
}

@Test func aCommandsOutputEndsBeforeTheNextPromptEvenChanged() {
    let prompt = ShellCommand.prompt(onLine: "devvm41244 api-envelope[f]/brick› ls", command: "ls")
    #expect(prompt == "devvm41244 api-envelope[f]/brick›")
    let out = "brick*  build_defs/  client/\nBRICK.md  cli/\n"
    // The same prompt after it; one whose status or directory changed;
    // one with the next command typed at it.
    #expect(ShellCommand.output(out + "devvm41244 api-envelope[f]/brick› ", prompt: prompt) == "brick*  build_defs/  client/\nBRICK.md  cli/")
    #expect(ShellCommand.output(out + "devvm41244 api-envelope[f*]/brick› ", prompt: prompt) == "brick*  build_defs/  client/\nBRICK.md  cli/")
    #expect(ShellCommand.output(out + "devvm41244 api-envelope[f]/brick/cli› git status", prompt: prompt) == "brick*  build_defs/  client/\nBRICK.md  cli/")
    // Output that merely ends in the mark, not at the prompt's start, stays.
    #expect(ShellCommand.output("total: 3›", prompt: prompt) == "total: 3›")
}

@Test func aPlaceInABlockSaysItselfToo() {
    let h = HostID("h")
    let now = Date(timeIntervalSince1970: 10_000)
    func at(_ s: Double) -> Stamp { Stamp(wall: Int64(s * 1000), host: h) }
    var note = Block(id: BlockID(host: h), kind: .text, created: at(0))
    note.apply(.content("# Plan\n\n## Steps\n- **ship** it\n- rest\n## Later\nmore\n", encoding: "utf-8", lineEnding: "\n", fingerprint: nil), at: at(1))
    let steps = note.summary(at: "line=3", now: now)
    #expect(steps?.title == "Steps")
    #expect(steps?.lines == ["ship it", "rest"])
    #expect(steps?.place == note.displayTitle)
    var term = Block(id: BlockID(host: h), kind: .terminal, created: at(0))
    term.apply(.ran(id: 7, "make test", at: at(9990)), at: at(9990))
    term.apply(.exited(id: 7, status: 2, at: at(9995)), at: at(9995))
    let made = term.summary(at: "command=7", now: now)
    #expect(made?.title == "make test" && made?.lines == ["exit 2"] && made?.tone == .failed && made?.code == true)
    #expect(term.summary(at: "command=8", now: now) == nil)
    #expect(note.summary(at: "page=2", now: now) == nil)
}
