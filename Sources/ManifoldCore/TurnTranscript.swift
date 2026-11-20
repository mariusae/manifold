import Foundation

/// What an agent did in one turn, from its transcript (§3.8): Claude Code's
/// JSON lines — what it said along the way, and each tool it used, by
/// what it worked on — from the turn's prompt to the next. Nil for a
/// transcript it can't read (another agent's format).
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
        guard !entries.isEmpty else { return nil }
        let wanted = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        let key = String(wanted.prefix(200))
        guard let start = entries.lastIndex(where: { e in
            guard e["type"] as? String == "user", let said = userText(e) else { return false }
            return said.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix(key) || (!key.isEmpty && said.contains(key))
        }) else { return nil }
        var out: [Part] = []
        var size = 0
        for e in entries[(start + 1)...] {
            // The next prompt ends it.
            if e["type"] as? String == "user", userText(e) != nil { break }
            guard e["type"] as? String == "assistant", let message = e["message"] as? [String: Any],
                  let content = message["content"] as? [[String: Any]] else { continue }
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
                if case .text(let t) = part { size += t.count } else { size += 80 }
                if size > limit { out.append(.text("…")); return out }
                out.append(part)
            }
        }
        return out
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
        guard let message = e["message"] as? [String: Any] else { return nil }
        if let s = message["content"] as? String { return s }
        guard let parts = message["content"] as? [[String: Any]] else { return nil }
        let texts = parts.filter { $0["type"] as? String == "text" }.compactMap { $0["text"] as? String }
        return texts.isEmpty ? nil : texts.joined(separator: "\n")
    }

    /// What a tool worked on, in a few words.
    private static func summary(_ name: String, _ input: [String: Any]) -> String {
        for key in ["file_path", "path", "notebook_path"] {
            if let p = input[key] as? String { return "`\(p)`" }
        }
        if let c = input["command"] as? String { return "`" + String(c.split(separator: "\n").first ?? "").prefix(160) + "`" }
        if let p = input["pattern"] as? String { return "`\(p.prefix(120))`" }
        if let u = input["url"] as? String { return u }
        if let q = input["query"] as? String { return "“\(q.prefix(120))”" }
        if let d = input["description"] as? String { return String(d.prefix(160)) }
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
