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
