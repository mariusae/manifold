import Foundation

/// What an agent did in one turn, from its transcript (§3.8): Claude Code's
/// and Antigravity's JSON lines — what it said along the way, and each tool
/// it used, by what it worked on — from the turn's prompt to the next. Nil
/// for a transcript it can't read (another agent's format).
public enum TurnTranscript {
    /// One thing in a turn, in order: words it said, or a tool it used
    /// (its name, and what it worked on in a few words).
    public enum Part: Codable, Equatable, Sendable {
        case text(String)
        case tool(name: String, summary: String)
    }

    public static func render(path: String, prompt: String, limit: Int = 60_000) -> String? {
        guard let entries = entries(path: path), let parts = parts(entries, prompt: prompt, limit: limit) else { return nil }
        return markdown(parts)
    }

    /// Parts as Markdown: what it said as paragraphs, tools as a list.
    public static func markdown(_ parts: [Part]) -> String {
        let lines = parts.map { p -> String in
            switch p {
            case .text(let t): t
            case let .tool(name, summary): "- `\(name)` " + summary
            }
        }
        // Tool lines run together, as a list; what it said, as paragraphs.
        var joined = ""
        for (i, l) in lines.enumerated() {
            if i > 0 { joined += l.hasPrefix("- ") && lines[i - 1].hasPrefix("- ") ? "\n" : "\n\n" }
            joined += l
        }
        return joined
    }

    /// A turn's parts, from its transcript's entries: from its prompt (the
    /// last of the user's own messages that is it) to the next.
    public static func parts(_ entries: [[String: Any]], prompt: String, limit: Int = 60_000) -> [Part]? {
        guard let start = turnStart(entries, prompt: prompt) else { return nil }
        var out: [Part] = []
        var size = 0
        func append(_ part: Part) -> Bool {
            if case .text(let t) = part { size += t.count } else { size += 80 }
            if size > limit { out.append(.text("…")); return false }
            out.append(part)
            return true
        }
        for e in entries[(start + 1)...] {
            // The next prompt ends it.
            if userText(e) != nil { break }
            let kind = e["type"] as? String
            if kind == "assistant", let message = e["message"] as? [String: Any],
               let content = message["content"] as? [[String: Any]] {
                for piece in content {
                    var part: Part?
                    switch piece["type"] as? String {
                    case "text":
                        if let t = (piece["text"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !t.isEmpty { part = .text(t) }
                    case "tool_use":
                        let name = piece["name"] as? String ?? "tool"
                        part = .tool(name: name, summary: summary(name, piece["input"] as? [String: Any] ?? [:]))
                    default:
                        break
                    }
                    guard let part else { continue }
                    if !append(part) { return out }
                }
            } else if kind == "PLANNER_RESPONSE" {
                let text = ((e["content"] as? String) ?? (e["response"] as? String) ?? (e["text"] as? String))?
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if let text, !text.isEmpty, !append(.text(text)) { return out }
                if let calls = e["tool_calls"] as? [[String: Any]] {
                    for call in calls {
                        let name = call["name"] as? String ?? "tool"
                        let args = call["args"] as? [String: Any] ?? [:]
                        if !append(.tool(name: name, summary: summary(name, args))) { return out }
                    }
                }
            }
        }
        return out
    }

    /// What a running turn is doing now, from its latest tool call in the
    /// transcript (as `AgentEvent.doing` describes it): used by hosts for
    /// agents whose hooks don't fire `PreToolUse` (`agy`), so minimized tile
    /// bars, sidebar rows, hover cards and threads show it too.
    public static func doing(_ entries: [[String: Any]], prompt: String) -> String? {
        guard let start = turnStart(entries, prompt: prompt) else { return nil }
        var latest: String?
        for e in entries[(start + 1)...] {
            if userText(e) != nil { break }
            let kind = e["type"] as? String
            if kind == "PLANNER_RESPONSE", let calls = e["tool_calls"] as? [[String: Any]] {
                for call in calls {
                    guard let name = call["name"] as? String, !name.isEmpty else { continue }
                    let args = decodedArgs(call["args"] as? [String: Any] ?? [:])
                    if let what = AgentEvent.doing(tool: name, input: args) { latest = what }
                }
            } else if kind == "assistant", let message = e["message"] as? [String: Any],
                      let content = message["content"] as? [[String: Any]] {
                for piece in content where piece["type"] as? String == "tool_use" {
                    guard let name = piece["name"] as? String, !name.isEmpty else { continue }
                    let input = piece["input"] as? [String: Any] ?? [:]
                    if let what = AgentEvent.doing(tool: name, input: input) { latest = what }
                }
            }
        }
        return latest
    }

    /// The `step_index` of the last user entry matching `prompt` (or its
    /// array index if `step_index` is absent): lets the host tell a
    /// background-task wakeup (same `USER_INPUT`) from a new prompt that
    /// happens to repeat the same words.
    public static func lastUserStep(_ entries: [[String: Any]], prompt: String) -> Int? {
        guard let idx = turnStart(entries, prompt: prompt) else { return nil }
        return (entries[idx]["step_index"] as? Int) ?? idx
    }

    /// The index of the user entry that began `prompt` (the last matching one).
    private static func turnStart(_ entries: [[String: Any]], prompt: String) -> Int? {
        guard !entries.isEmpty else { return nil }
        let wanted = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        let key = String(wanted.prefix(200))
        return entries.lastIndex(where: { e in
            guard let said = userText(e) else { return false }
            let trimmed = said.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.hasPrefix(key) || (!key.isEmpty && trimmed.contains(key))
        })
    }

    /// A transcript's entries, each a JSON line — read once and then, as
    /// it grows (an agent at work writes it as it goes), only what was
    /// added: a turn shown live asks again every second or so.
    public static func entries(path: String) -> [[String: Any]]? {
        cache.entries(path: path)
    }

    private static let cache = EntryCache()

    private final class EntryCache: @unchecked Sendable {
        private let lock = NSLock()
        private struct Kept { var size: UInt64; var modified: Date; var consumed: UInt64; var entries: [[String: Any]]; var used: Date }
        private var kept: [String: Kept] = [:]

        func entries(path: String) -> [[String: Any]]? {
            guard let attrs = try? FileManager.default.attributesOfItem(atPath: path),
                  let size = (attrs[.size] as? NSNumber)?.uint64Value else { return nil }
            let modified = attrs[.modificationDate] as? Date ?? .distantPast
            lock.lock()
            defer { lock.unlock() }
            if var k = kept[path], k.size == size, k.modified == modified {
                k.used = Date()
                kept[path] = k
                return k.entries
            }
            // Grown: only the lines added since, from the end of the last
            // whole line read (a line being written is read once it's whole).
            var k = kept[path].flatMap { $0.size <= size ? $0 : nil } ?? Kept(size: 0, modified: .distantPast, consumed: 0, entries: [], used: Date())
            guard let handle = FileHandle(forReadingAtPath: path) else { return nil }
            defer { try? handle.close() }
            try? handle.seek(toOffset: k.consumed)
            let data = handle.readDataToEndOfFile()
            guard let lastNewline = data.lastIndex(of: UInt8(ascii: "\n")) else {
                k.size = size
                k.modified = modified
                kept[path] = k
                return k.entries
            }
            let whole = data[data.startIndex...lastNewline]
            for line in whole.split(separator: UInt8(ascii: "\n")) {
                if let e = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any] { k.entries.append(e) }
            }
            k.consumed += UInt64(whole.count)
            k.size = size
            k.modified = modified
            k.used = Date()
            kept[path] = k
            // A few at most: the transcripts of the agents being looked at.
            if kept.count > 8, let oldest = kept.min(by: { $0.value.used < $1.value.used })?.key { kept[oldest] = nil }
            return k.entries
        }
    }

    /// A user entry's own words (not a tool's result handed back).
    private static func userText(_ e: [String: Any]) -> String? {
        let kind = e["type"] as? String
        if kind == "USER_INPUT", let content = e["content"] as? String {
            if let a = content.range(of: "<USER_REQUEST>"), let b = content.range(of: "</USER_REQUEST>", range: a.upperBound..<content.endIndex) {
                let inner = content[a.upperBound..<b.lowerBound].trimmingCharacters(in: .whitespacesAndNewlines)
                return inner.isEmpty ? nil : inner
            }
            let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }
        guard kind == "user", let message = e["message"] as? [String: Any] else { return nil }
        if let s = message["content"] as? String { return s }
        guard let parts = message["content"] as? [[String: Any]] else { return nil }
        let texts = parts.filter { $0["type"] as? String == "text" }.compactMap { $0["text"] as? String }
        return texts.isEmpty ? nil : texts.joined(separator: "\n")
    }

    /// A tool arg value as a plain string: Antigravity's `transcript.jsonl`
    /// stores each arg value as a JSON-encoded string (e.g. `"\"/a/b\""`),
    /// while Claude Code stores raw strings.
    private static func argString(_ raw: Any?) -> String? {
        guard let s = raw as? String, !s.isEmpty else { return nil }
        if s.hasPrefix("\""), s.hasSuffix("\""), s.count >= 2,
           let data = s.data(using: .utf8),
           let decoded = try? JSONSerialization.jsonObject(with: data, options: .fragmentsAllowed) as? String {
            return decoded.isEmpty ? nil : decoded
        }
        return s
    }

    /// Unwraps JSON-encoded string values in an Antigravity `tool_calls` args dict.
    private static func decodedArgs(_ raw: [String: Any]) -> [String: Any] {
        var out: [String: Any] = [:]
        out.reserveCapacity(raw.count)
        for (k, v) in raw { out[k] = argString(v) ?? v }
        return out
    }

    /// What a tool worked on, in a few words.
    private static func summary(_ name: String, _ input: [String: Any]) -> String {
        for key in ["file_path", "path", "notebook_path", "Path", "TargetFile", "AbsolutePath", "File", "DirectoryPath", "SearchPath", "SearchDirectory"] {
            if let p = argString(input[key]) { return "`\(p)`" }
        }
        if let c = argString(input["command"]) ?? argString(input["CommandLine"]) {
            return "`" + String(c.split(separator: "\n").first ?? "").prefix(160) + "`"
        }
        if let p = argString(input["pattern"]) ?? argString(input["Pattern"]) { return "`\(p.prefix(120))`" }
        if let u = argString(input["url"]) ?? argString(input["Url"]) { return u }
        if let q = argString(input["query"]) ?? argString(input["Query"]) { return "“\(q.prefix(120))”" }
        if let d = argString(input["description"]) ?? argString(input["toolSummary"]) ?? argString(input["Description"]) ?? argString(input["Role"]) {
            return String(d.prefix(160))
        }
        if let todos = input["todos"] as? [Any] { return "\(todos.count) items" }
        return ""
    }
}

/// A turn's parts, as its host read them from the agent's transcript
/// (`Proposal.turnContent`), for the agent's conversation (§3.8).
public struct TurnContent: Codable, Equatable, Sendable {
    public var turn: Int
    public var parts: [TurnTranscript.Part]

    public init(turn: Int, parts: [TurnTranscript.Part]) {
        self.turn = turn
        self.parts = parts
    }
}
