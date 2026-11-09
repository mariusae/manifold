import Foundation

/// The headings of a Markdown text, by line: what an outline of it is
/// made of (⌘P, the scrubber).
enum MarkdownOutline {
    struct Heading { var line: Int; var level: Int; var text: String }

    static func headings(in text: String) -> [Heading] {
        var out: [Heading] = []
        var inFence = false
        var line = 0
        for raw in text.split(separator: "\n", omittingEmptySubsequences: false) {
            defer { line += 1 }
            if raw.hasPrefix("```") { inFence.toggle() }
            guard !inFence, raw.hasPrefix("#") else { continue }
            let level = raw.prefix { $0 == "#" }.count
            guard level <= 6, raw.dropFirst(level).first == " " else { continue }
            out.append(Heading(line: line, level: level, text: raw.dropFirst(level).trimmingCharacters(in: .whitespaces)))
        }
        return out
    }
}
