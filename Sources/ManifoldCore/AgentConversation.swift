import Foundation

/// An agent's conversation (§3.8), its "default thread": each turn — what
/// you asked, in the technical face, as typed; what it did on the way,
/// folded to a line ("read 6 files · edited 2 · ran 3 commands"); what it
/// said, rendered as a page is, in the reading face — the latest last.
/// Made as Markdown with a little HTML, for the page a preview shows.
public enum AgentConversation {
    /// How it stands at its end, said after the last turn.
    public enum Standing: Equatable, Sendable {
        case idle
        case working
        case needsYou
        case asleep
    }

    /// The conversation: `turns` (the agent's, oldest first), what each
    /// did as its host read it (`contents`, by turn; none for one it
    /// couldn't), and what you've sent that waits for it (`queued`).
    public static func markdown(turns: [AgentTurn], contents: [Int: [TurnTranscript.Part]], standing: Standing,
                                queued: [String] = [], most: Int = 40) -> String {
        var out = "<div class=\"mf-conversation\"></div>\n\n"
        let shown = turns.suffix(most)
        if turns.count > shown.count {
            out += "<p class=\"mf-earlier\">\(turns.count - shown.count) earlier turns</p>\n\n"
        }
        if shown.isEmpty, queued.isEmpty {
            out += "<p class=\"mf-standing\">Nothing asked yet: what you write below is its first prompt.</p>\n\n"
        }
        for t in shown {
            out += "<section class=\"mf-turn\" id=\"turn-\(t.id)\">\n\n"
            // Asked from a thread: the thread and what was said there, not
            // the instructions Manifold wrote round it.
            let (asked, words) = promptShown(t.prompt)
            out += asked ? "<p class=\"mf-asked\">\(escape(words))</p>\n\n" : prompt(words)
            let (steps, said) = split(contents[t.id])
            if !steps.isEmpty {
                out += "<details class=\"mf-steps\" id=\"steps-\(t.id)\"><summary>\(escape(summary(steps, files: t.files)))</summary>\n\n"
                out += TurnTranscript.markdown(steps) + "\n\n</details>\n\n"
            }
            var reply = said.joined(separator: "\n\n")
            // What it didn't say along the way, its last words (an agent whose
            // transcript can't be read, or one read before it ended).
            if reply.isEmpty, t.ended != nil, let m = t.message?.trimmingCharacters(in: .whitespacesAndNewlines) { reply = m }
            if !reply.isEmpty { out += reply + "\n\n" }
            if t.isRunning, standing == .working || standing == .needsYou {
                out += "<p class=\"mf-standing mf-working\">\(standing == .needsYou ? "Needs you — answer in its terminal (⌘↩)" : "Working…")</p>\n\n"
            }
            out += "</section>\n\n"
        }
        // Not in a turn (it asked before it began, or between): said at the end.
        if standing == .needsYou, shown.last?.isRunning != true {
            out += "<p class=\"mf-standing mf-working\">Needs you — answer in its terminal (⌘↩)</p>\n\n"
        }
        for q in queued {
            out += prompt(q, queued: true)
        }
        if standing == .asleep, !queued.isEmpty {
            out += "<p class=\"mf-standing\">Asleep: sending wakes it.</p>\n\n"
        }
        return out
    }

    /// What was asked, as it's shown: from a thread, the thread and what
    /// was said there (`asked`); else as typed — less the name it was told
    /// it goes by in threads, which a prompt typed here once carried.
    public static func promptShown(_ prompt: String) -> (asked: Bool, words: String) {
        if let a = ThreadText.askShown(prompt) { return (true, a) }
        var p = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        if p.hasPrefix("(You are "), let end = p.range(of: " in these threads.) ") { p = String(p[end.upperBound...]) }
        return (false, p)
    }

    /// What was asked, in a line for an outline: from a thread, only what
    /// was said there (every entry began "In the thread on…").
    public static func promptTitle(_ prompt: String) -> String {
        let (asked, words) = promptShown(prompt)
        if asked, let open = words.firstIndex(of: "“"), let close = words.lastIndex(of: "”"), open < close {
            return String(words[words.index(after: open)..<close])
        }
        return words.split(whereSeparator: \.isNewline).first.map(String.init) ?? words
    }

    /// What you asked, as typed.
    private static func prompt(_ text: String, queued: Bool = false) -> String {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return "" }
        let title = queued ? " title=\"Sent once it's done\"" : ""
        return "<pre class=\"mf-prompt\(queued ? " mf-queued" : "")\"\(title)>\(escape(t))</pre>\n\n"
    }

    /// A turn's parts as what it did on the way (up to its last tool) and
    /// what it said after: its answer.
    public static func split(_ parts: [TurnTranscript.Part]?) -> (steps: [TurnTranscript.Part], said: [String]) {
        guard let parts else { return ([], []) }
        guard let last = parts.lastIndex(where: { if case .tool = $0 { true } else { false } }) else {
            return ([], parts.compactMap { if case .text(let t) = $0 { t } else { nil } })
        }
        let said = parts[(last + 1)...].compactMap { p -> String? in if case .text(let t) = p { t } else { nil } }
        return (Array(parts[...last]), said)
    }

    /// What it did on the way, in a line: "read 6 files · edited 2 ·
    /// ran 3 commands".
    public static func summary(_ steps: [TurnTranscript.Part], files: [String]? = nil) -> String {
        var counts: [String: Int] = [:]
        var order: [String] = []
        func count(_ k: String) {
            if counts[k] == nil { order.append(k) }
            counts[k, default: 0] += 1
        }
        for case let .tool(name, _) in steps {
            switch name {
            case "Read", "NotebookRead": count("read")
            case "Edit", "MultiEdit", "Write", "NotebookEdit": count("edit")
            case "Bash", "BashOutput", "KillShell", "KillBash": count("run")
            case "Grep", "Glob", "LS": count("search")
            case "WebFetch", "WebSearch": count("web")
            case "Task", "Agent": count("agent")
            case "TodoWrite": count("todo")
            default: count("other")
            }
        }
        func n(_ k: String, _ one: String, _ many: String) -> String {
            let c = counts[k] ?? 0
            return c == 1 ? one : String(format: many, c)
        }
        var words = order.map { k -> String in
            switch k {
            case "read": n(k, "read a file", "read %d files")
            case "edit": n(k, "made an edit", "made %d edits")
            case "run": n(k, "ran a command", "ran %d commands")
            case "search": n(k, "searched once", "searched %d times")
            case "web": n(k, "looked on the web", "looked on the web %d times")
            case "agent": n(k, "asked a subagent", "asked %d subagents")
            case "todo": "kept its to-do list"
            default: n(k, "used another tool", "used %d other tools")
            }
        }
        if let files, !files.isEmpty { words.append(files.count == 1 ? "changed \(files[0].split(separator: "/").last ?? "")" : "changed \(files.count) files") }
        if words.isEmpty { return "Thought it through" }
        let line = words.joined(separator: " · ")
        return line.prefix(1).uppercased() + line.dropFirst()
    }

    static func escape(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }
}
