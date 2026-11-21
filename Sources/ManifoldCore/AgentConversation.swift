import Foundation

/// An agent's conversation (§3.8), its "default thread": each turn — what
/// you asked, in the technical face, as typed, in a bubble at the right;
/// what it did on the way, folded to a line ("read 6 files · edited 2 ·
/// ran 3 commands"); what it said, rendered as a page is, in the editing
/// face — the latest last.
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
    /// `doing`: what it says it's doing now (`Block.agentDoing`), said at
    /// the end while it works; else its last tool's, as read.
    public static func markdown(turns: [AgentTurn], contents: [Int: [TurnTranscript.Part]], standing: Standing,
                                queued: [String] = [], doing: String? = nil, most: Int = 40) -> String {
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
            if let note = notification(t.prompt) {
                // Not asked: its harness telling it something (a task of its
                // own finished) — said as what happened, not as a prompt.
                out += "<p class=\"mf-event\">\(escape(note))</p>\n\n"
            } else {
                // Asked from a thread: the thread and what was said there, not
                // the instructions Manifold wrote round it.
                let (asked, words) = promptShown(t.prompt)
                out += asked ? "<p class=\"mf-asked\">\(linked(escape(words)))</p>\n\n" : prompt(words)
            }
            let (steps, said) = split(contents[t.id])
            out += along(steps, turn: t.id, files: t.files)
            var reply = said.joined(separator: "\n\n")
            // What it didn't say along the way, its last words (an agent whose
            // transcript can't be read, or one read before it ended).
            if reply.isEmpty, t.ended != nil, let m = t.message?.trimmingCharacters(in: .whitespacesAndNewlines) { reply = m }
            if !reply.isEmpty { out += reply + "\n\n" }
            if t.isRunning, standing == .needsYou {
                out += "<p class=\"mf-standing mf-working\">Needs you — answer in its terminal (⌘↩)</p>\n\n"
            } else if t.isRunning, standing == .working {
                // What it's doing now, beside the dots that say it's at it.
                let now = doing ?? activity(contents[t.id]) ?? "Working"
                out += "<p class=\"mf-standing mf-working\"><span class=\"mf-dots\"><i></i><i></i><i></i></span>\(escape(now))…</p>\n\n"
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
        if let note = notification(prompt) { return note }
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
        return "<pre class=\"mf-prompt\(queued ? " mf-queued" : "")\"\(title)>\(linked(escape(t)))</pre>\n\n"
    }

    /// What was written, escaped, with its references — a block dropped
    /// in, `[name](manifold:…)` — links again, which the page shows as
    /// their pills (as a note does).
    static func linked(_ escaped: String) -> String {
        escaped.replacingOccurrences(of: #"\[([^\]\n]+)\]\((manifold:[^)\s"]+)\)"#, with: "<a href=\"$2\">$1</a>", options: .regularExpression)
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

    /// What it did on the way, in order: what it said as it went (what it
    /// was about to do, what it found), each run of tools between folded
    /// to a line — the last run's line saying the files the turn changed.
    static func along(_ steps: [TurnTranscript.Part], turn: Int, files: [String]?) -> String {
        var out = "", run: [TurnTranscript.Part] = [], runs = 0
        let tools = steps.filter { if case .tool = $0 { true } else { false } }.count
        var seen = 0
        func flush() {
            guard !run.isEmpty else { return }
            seen += run.count
            let line = summary(run, files: seen == tools ? files : nil)
            out += "<details class=\"mf-steps\" id=\"steps-\(turn)\(runs == 0 ? "" : "-\(runs)")\"><summary>\(escape(line))</summary>\n\n"
            out += TurnTranscript.markdown(run) + "\n\n</details>\n\n"
            run = []
            runs += 1
        }
        for p in steps {
            switch p {
            case .tool: run.append(p)
            case .text(let t):
                flush()
                out += "<div class=\"mf-aside\">\n\n\(t)\n\n</div>\n\n"
            }
        }
        flush()
        return out
    }

    /// What a turn at work is doing now, in a few words: its last tool,
    /// as "Running `make`" or "Reading main.swift"; nil when it's last
    /// said something (that's on the page) or nothing's been read.
    public static func activity(_ parts: [TurnTranscript.Part]?) -> String? {
        guard case let .tool(name, summary)? = parts?.last else { return nil }
        let what = summary.replacingOccurrences(of: "`", with: "")
        let file = what.split(separator: "/").last.map(String.init) ?? what
        switch name {
        case "Read", "NotebookRead": return what.isEmpty ? "Reading" : "Reading \(file)"
        case "Edit", "MultiEdit", "Write", "NotebookEdit": return what.isEmpty ? "Editing" : "Editing \(file)"
        case "Bash": return what.isEmpty ? "Running a command" : "Running \(what.prefix(80))"
        case "BashOutput": return "Watching a command"
        case "Grep", "Glob", "LS": return what.isEmpty ? "Searching" : "Searching for \(what.prefix(60))"
        case "WebFetch", "WebSearch": return "Looking on the web"
        case "Task", "Agent": return what.isEmpty ? "Asking a subagent" : "Asking a subagent: \(what.prefix(60))"
        case "TodoWrite": return "Updating its to-do list"
        default: return "Using \(name)"
        }
    }

    /// A prompt that wasn't asked but is its harness telling it something
    /// (Claude Code's `<task-notification>`: a background command of its
    /// own finished), in a line: "Build brick compiler — completed". Nil for
    /// one that was asked.
    public static func notification(_ prompt: String) -> String? {
        let p = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard p.hasPrefix("<task-notification>") else { return nil }
        func tag(_ name: String) -> String? {
            guard let a = p.range(of: "<\(name)>"), let b = p.range(of: "</\(name)>", range: a.upperBound..<p.endIndex) else { return nil }
            return String(p[a.upperBound..<b.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if let s = tag("summary"), !s.isEmpty { return s }
        return "A background task " + (tag("status") ?? "finished")
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

extension Block {
    /// An agent at work: what it says it's doing now — its last tool's
    /// report, kept as its status's message by its host (`AgentEvent.doing`);
    /// nil before it's said anything since it was asked (the message is
    /// then what it was asked), or when it isn't at work.
    public var agentDoing: String? {
        guard agent != nil, let r = statusRecord, r.state == .working, let m = r.msg?.trimmingCharacters(in: .whitespaces), !m.isEmpty else { return nil }
        if let t = terminal?.turns?.last, t.prompt.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix(m) { return nil }
        return m
    }
}
