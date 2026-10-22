import Foundation

/// What an agent did in one turn, from its transcript (§3.8): Claude Code's
/// JSON lines — what it said along the way, and each tool it used, by
/// what it worked on — from the turn's prompt to the next. Nil for a
/// transcript it can't read (another agent's format).
public enum TurnTranscript {
    public static func render(path: String, prompt: String, limit: Int = 60_000) -> String? {
        guard let data = FileManager.default.contents(atPath: path), let text = String(data: data, encoding: .utf8) else { return nil }
        let entries: [[String: Any]] = text.split(separator: "\n").compactMap {
            try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any]
        }
        guard !entries.isEmpty else { return nil }
        // The turn begins at the last of the user's own messages that is its prompt.
        let wanted = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        let key = String(wanted.prefix(200))
        guard let start = entries.lastIndex(where: { e in
            guard e["type"] as? String == "user", let said = userText(e) else { return false }
            return said.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix(key) || (!key.isEmpty && said.contains(key))
        }) else { return nil }
        var out: [String] = []
        var size = 0
        for e in entries[(start + 1)...] {
            // The next prompt ends it.
            if e["type"] as? String == "user", userText(e) != nil { break }
            guard e["type"] as? String == "assistant", let message = e["message"] as? [String: Any],
                  let content = message["content"] as? [[String: Any]] else { continue }
            for part in content {
                var line: String?
                switch part["type"] as? String {
                case "text":
                    if let t = (part["text"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !t.isEmpty { line = t }
                case "tool_use":
                    let name = part["name"] as? String ?? "tool"
                    let input = part["input"] as? [String: Any] ?? [:]
                    line = "- `\(name)` " + summary(name, input)
                default:
                    break
                }
                guard let line else { continue }
                size += line.count
                if size > limit { out.append("…"); return out.joined(separator: "\n\n") }
                out.append(line)
            }
        }
        // Tool lines run together, as a list; what it said, as paragraphs.
        var joined = ""
        for (i, l) in out.enumerated() {
            if i > 0 { joined += l.hasPrefix("- ") && out[i - 1].hasPrefix("- ") ? "\n" : "\n\n" }
            joined += l
        }
        return joined
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
