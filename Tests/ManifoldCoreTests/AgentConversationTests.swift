import Foundation
import Testing
@testable import ManifoldCore

// An agent's conversation (§3.8): what you asked as typed, what it did on
// the way folded to a line, what it said after its last tool as its answer.
@Test func aTurnsAnswerIsWhatItSaidAfterItsLastTool() {
    let parts: [TurnTranscript.Part] = [.text("Let me look."), .tool(name: "Read", summary: "`a.swift`"), .tool(name: "Edit", summary: "`a.swift`"),
                                        .text("Done: it was the cache."), .text("Anything else?")]
    let (steps, said) = AgentConversation.split(parts)
    #expect(steps.count == 3)
    #expect(said == ["Done: it was the cache.", "Anything else?"])
    // No tools: all it said is its answer.
    #expect(AgentConversation.split([.text("Hi")]).said == ["Hi"])
    #expect(AgentConversation.split([.text("Hi")]).steps.isEmpty)
}

@Test func whatItDidIsALine() {
    let steps: [TurnTranscript.Part] = [.tool(name: "Read", summary: ""), .tool(name: "Read", summary: ""), .tool(name: "Bash", summary: ""),
                                        .tool(name: "Edit", summary: ""), .tool(name: "Mystery", summary: "")]
    #expect(AgentConversation.summary(steps) == "Read 2 files · ran a command · made an edit · used another tool")
    #expect(AgentConversation.summary([.tool(name: "Grep", summary: "")], files: ["Sources/a.swift"]) == "Searched once · changed a.swift")
}

@Test func theConversationIsMarkdownWithItsPartsMarked() {
    var t = AgentTurn(id: 7, agent: "Claude Code", prompt: "fix <this> & that", began: Stamp(wall: 0))
    t.ended = Stamp(wall: 5)
    let md = AgentConversation.markdown(turns: [t], contents: [7: [.tool(name: "Read", summary: "`x`"), .text("Fixed **it**.")]], standing: .idle)
    #expect(md.contains("<pre class=\"mf-prompt\">fix &lt;this&gt; &amp; that</pre>"))
    #expect(md.contains("<details class=\"mf-steps\" id=\"steps-7\"><summary>Read a file</summary>"))
    #expect(md.contains("Fixed **it**."))
    #expect(!md.contains("Working…"))
    // Running: said so after what it's said so far.
    var running = t
    running.ended = nil
    let live = AgentConversation.markdown(turns: [running], contents: [:], standing: .working)
    #expect(live.contains("Working…"))
    // Unreadable (another agent's transcript): its last words.
    t.message = "All done."
    #expect(AgentConversation.markdown(turns: [t], contents: [:], standing: .idle).contains("All done."))
    // What waits for it: at the end, marked.
    #expect(AgentConversation.markdown(turns: [t], contents: [:], standing: .working, queued: ["and then"]).contains("mf-prompt mf-queued"))
}

// A transcript read again as it grows: what was added, whole lines only.
@Test func aGrowingTranscriptIsReadAsItGrows() throws {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("turn-\(UUID().uuidString).jsonl")
    defer { try? FileManager.default.removeItem(at: url) }
    func line(_ o: [String: Any]) -> String { String(data: try! JSONSerialization.data(withJSONObject: o), encoding: .utf8)! + "\n" }
    let ask = line(["type": "user", "message": ["content": "do it"]])
    let read = line(["type": "assistant", "message": ["content": [["type": "tool_use", "name": "Read", "input": ["file_path": "/a"]]]]])
    try (ask + read).write(to: url, atomically: false, encoding: .utf8)
    var parts = TurnTranscript.parts(try #require(TurnTranscript.entries(path: url.path)), prompt: "do it")
    #expect(parts == [.tool(name: "Read", summary: "`/a`")])
    // Added to, with half a line still being written: the whole one read.
    let said = line(["type": "assistant", "message": ["content": [["type": "text", "text": "Done."]]]])
    let h = try FileHandle(forWritingTo: url)
    try h.seekToEnd()
    try h.write(contentsOf: Data((said + "{\"type\": \"assis").utf8))
    try h.close()
    parts = TurnTranscript.parts(try #require(TurnTranscript.entries(path: url.path)), prompt: "do it")
    #expect(parts == [.tool(name: "Read", summary: "`/a`"), .text("Done.")])
}

// Asked from a thread: the thread and what was said there, not Manifold's instructions.
@Test func anAskFromAThreadShowsWhatWasSaidThere() {
    let prompt = "(You are Elm in these threads.) [Manifold thread manifold:h/01, about x.proto] The user wrote: \"and what else?\" — read it with `mani thread read`"
    let t = AgentTurn(id: 1, agent: "Claude Code", prompt: prompt, began: Stamp(wall: 0))
    let md = AgentConversation.markdown(turns: [t], contents: [:], standing: .idle)
    #expect(md.contains("mf-asked"))
    #expect(md.contains("and what else?"))
    #expect(!md.contains("mani thread read"))
}

// A prompt once sent with the name it goes by in threads: shown without it.
@Test func aPromptIsShownWithoutItsThreadName() {
    #expect(AgentConversation.promptShown("(You are Yarrow in these threads.) summarize the recent change") == (false, "summarize the recent change"))
    #expect(AgentConversation.promptShown("plain") == (false, "plain"))
}

@Test func aTurnFromAThreadIsTitledByWhatWasSaid() {
    let prompt = "(You are Elm in these threads.) [Manifold thread manifold:h/01, about x.proto] The user wrote: \"and what else?\" — read it with `mani thread read`"
    #expect(AgentConversation.promptTitle(prompt) == "and what else?")
    #expect(AgentConversation.promptTitle("fix it\nplease") == "fix it")
}

// What it said along the way shows, between its tools folded to lines.
@Test func whatItSaidOnTheWayShowsBetweenItsTools() {
    var t = AgentTurn(id: 3, agent: "Claude Code", prompt: "build it", began: Stamp(wall: 0))
    t.ended = Stamp(wall: 5)
    let parts: [TurnTranscript.Part] = [.text("I'm copying the protos over unchanged."), .tool(name: "Bash", summary: "`cp a b`"),
                                        .text("Now a stub server."), .tool(name: "Write", summary: "`stub.go`"), .text("Done.")]
    let md = AgentConversation.markdown(turns: [t], contents: [3: parts], standing: .idle)
    #expect(md.contains("<div class=\"mf-aside\">\n\nI'm copying the protos over unchanged.\n\n</div>"))
    #expect(md.contains("<div class=\"mf-aside\">\n\nNow a stub server.\n\n</div>"))
    #expect(md.contains("id=\"steps-3\"><summary>Ran a command</summary>"))
    #expect(md.contains("id=\"steps-3-1\"><summary>Made an edit</summary>"))
    #expect(md.contains("Done."))
    let order = ["copying the protos", "steps-3\"", "a stub server", "steps-3-1", "Done."].map { md.range(of: $0)!.lowerBound }
    #expect(order == order.sorted())
}

// At work: what it's doing now, by its last tool.
@Test func aTurnAtWorkSaysWhatItsDoing() {
    let t = AgentTurn(id: 4, agent: "Claude Code", prompt: "go", began: Stamp(wall: 0))
    let md = AgentConversation.markdown(turns: [t], contents: [4: [.tool(name: "Bash", summary: "`swift build`")]], standing: .working)
    #expect(md.contains("mf-dots"))
    #expect(md.contains("Running swift build…"))
    #expect(AgentConversation.activity([.tool(name: "Read", summary: "`/a/b/main.swift`")]) == "Reading main.swift")
    #expect(AgentConversation.activity([.text("Thinking aloud.")]) == nil)
    #expect(AgentConversation.markdown(turns: [t], contents: [:], standing: .working).contains("Working…"))
}

// Its harness telling it a task finished: said as what happened, not as asked.
@Test func aTaskNotificationIsAnEventNotAPrompt() {
    let prompt = "<task-notification>\n<task-id>b9</task-id>\n<status>completed</status>\n<summary>Background command \"Build brick\" completed (exit code 0)</summary>\n</task-notification>"
    let t = AgentTurn(id: 5, agent: "Claude Code", prompt: prompt, began: Stamp(wall: 0))
    let md = AgentConversation.markdown(turns: [t], contents: [:], standing: .idle)
    #expect(md.contains("<p class=\"mf-event\">Background command &quot;Build brick&quot; completed (exit code 0)</p>"))
    #expect(!md.contains("mf-prompt"))
    #expect(!md.contains("task-id"))
    #expect(AgentConversation.promptTitle(prompt) == "Background command \"Build brick\" completed (exit code 0)")
    #expect(AgentConversation.notification("fix it") == nil)
}

// A block dropped into what was asked: its pill, not its Markdown.
@Test func aReferenceInAPromptIsALink() {
    let t = AgentTurn(id: 9, agent: "Claude Code", prompt: "[mc2art](manifold:hw698j2smp0/01M7V7FG1MTQ8VTY2W8MD003ZX) they are here & there", began: Stamp(wall: 0))
    let md = AgentConversation.markdown(turns: [t], contents: [:], standing: .idle)
    #expect(md.contains("<pre class=\"mf-prompt\"><a href=\"manifold:hw698j2smp0/01M7V7FG1MTQ8VTY2W8MD003ZX\">mc2art</a> they are here &amp; there</pre>"))
}

// Antigravity's transcript.jsonl: USER_INPUT (<USER_REQUEST> wrapper) and
// PLANNER_RESPONSE (thinking ignored, JSON-encoded tool args unwrapped, text kept).
@Test func antigravityTranscriptIsParsedAndSummarized() throws {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("agy-turn-\(UUID().uuidString).jsonl")
    defer { try? FileManager.default.removeItem(at: url) }
    func line(_ o: [String: Any]) -> String { String(data: try! JSONSerialization.data(withJSONObject: o), encoding: .utf8)! + "\n" }
    let u1 = line(["step_index": 0, "type": "USER_INPUT", "source": "USER_EXPLICIT",
                   "content": "<USER_REQUEST>\nfix the parser\n</USER_REQUEST>\n<ADDITIONAL_METADATA>\nnow\n</ADDITIONAL_METADATA>"])
    let p1 = line(["step_index": 1, "type": "PLANNER_RESPONSE", "source": "MODEL", "thinking": "internal thoughts",
                   "tool_calls": [
                       ["name": "read_file", "args": ["Path": "\"/repo/Sources/Parser.swift\""]],
                       ["name": "run_command", "args": ["CommandLine": "\"swift test\"", "toolSummary": "\"Run tests\""]],
                   ]])
    let g1 = line(["step_index": 2, "type": "GENERIC", "content": "file contents"])
    let p2 = line(["step_index": 3, "type": "PLANNER_RESPONSE", "source": "MODEL",
                   "tool_calls": [["name": "edit_file", "args": ["Path": "\"/repo/Sources/Parser.swift\""]]],
                   "content": "Updating the parser now."])
    let p3 = line(["step_index": 4, "type": "PLANNER_RESPONSE", "source": "MODEL",
                   "content": "Fixed the parser and tests pass."])
    let u2 = line(["step_index": 5, "type": "USER_INPUT", "source": "USER_EXPLICIT",
                   "content": "<USER_REQUEST>\nnext question\n</USER_REQUEST>"])
    let p4 = line(["step_index": 6, "type": "PLANNER_RESPONSE", "source": "MODEL",
                   "response": "Here is the answer."])
    try (u1 + p1 + g1 + p2 + p3 + u2 + p4).write(to: url, atomically: true, encoding: .utf8)
    let entries = try #require(TurnTranscript.entries(path: url.path))
    let first = try #require(TurnTranscript.parts(entries, prompt: "fix the parser"))
    #expect(first == [
        .tool(name: "read_file", summary: "`/repo/Sources/Parser.swift`"),
        .tool(name: "run_command", summary: "`swift test`"),
        .text("Updating the parser now."),
        .tool(name: "edit_file", summary: "`/repo/Sources/Parser.swift`"),
        .text("Fixed the parser and tests pass."),
    ])
    let (steps, said) = AgentConversation.split(first)
    #expect(said == ["Fixed the parser and tests pass."])
    #expect(AgentConversation.summary(steps) == "Read a file · ran a command · made an edit")
    #expect(AgentConversation.activity([.tool(name: "read_file", summary: "`/repo/Sources/Parser.swift`")]) == "Reading Parser.swift")
    #expect(AgentConversation.activity([.tool(name: "run_command", summary: "`swift test`")]) == "Running swift test")
    #expect(AgentConversation.activity([.tool(name: "edit_file", summary: "`/repo/Sources/Parser.swift`")]) == "Editing Parser.swift")
    #expect(AgentConversation.activity([.tool(name: "search_web", summary: "“swift”")]) == "Looking on the web")
    #expect(AgentConversation.activity([.tool(name: "invoke_subagent", summary: "Researcher")]) == "Asking a subagent: Researcher")
    // Second turn stops cleanly and reads `response` too.
    let second = try #require(TurnTranscript.parts(entries, prompt: "next question"))
    #expect(second == [.text("Here is the answer.")])
}
