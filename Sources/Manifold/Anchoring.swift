import Foundation
import ManifoldCore
import ManifoldSyntax

/// Anchors (§2.5) as the app makes and finds them in a text: what one at a
/// place is at — a declaration, by the code's grammar; a heading, in
/// Markdown; else the text there — and where one is now, found again by
/// what it's at when the text changed where no edit said.
enum Anchoring {
    /// The anchor a reference to `line` (from 0) of a text would name: the
    /// declaration that starts on it (else the innermost it's in), the
    /// heading on it, else the line itself. Its id is to be given.
    static func anchor(atLine line: Int, of b: Block, exactly: Bool = false) -> Anchor? {
        guard let rope = b.text?.text, line >= 0, line < rope.lineCount else { return nil }
        let lineRange = rope.lineRange(line)
        if let tree = tree(of: b) {
            let decls = tree.declarations()
            let starting = decls.last { rope.line(at: $0.range.start) == line }
            let within = decls.last { $0.range.start <= lineRange.start && $0.range.end >= lineRange.end }
            if let d = starting ?? (exactly ? nil : within) {
                return Anchor(id: "", at: .symbol(path: d.path), range: d.range, excerpt: firstLine(rope, d.range), name: d.path)
            }
        }
        if isMarkdown(b), let path = headingPath(atLine: line, in: rope.string) {
            return Anchor(id: "", at: .heading(path: path), range: lineRange, excerpt: rope[lineRange], name: path.last)
        }
        let words = rope[lineRange].trimmingCharacters(in: .whitespaces)
        return Anchor(id: "", at: .range, range: lineRange, excerpt: words, name: String(words.prefix(60)))
    }

    /// The block's anchor for the same place as `a`, if it has one: a
    /// reference to it again is to that anchor, not a new one.
    static func existing(_ a: Anchor, in b: Block) -> Anchor? {
        b.anchors?.values.first { other in
            guard other.at == a.at else { return false }
            if case .range = a.at { return other.range == a.range }
            return true
        }
    }

    /// Where an anchor is in the text as it is now, and, if it was found
    /// elsewhere than it said (or had to be looked for), the anchor put
    /// right; nil if it's gone.
    static func locate(_ a: Anchor, in b: Block) -> (range: TextRange, putRight: Anchor?)? {
        guard let rope = b.text?.text else { return nil }
        let was = a.range ?? TextRange(at: 0)
        func found(_ r: TextRange) -> (TextRange, Anchor?) {
            guard r != a.range || a.unsure == true else { return (r, nil) }
            var moved = a
            moved.range = r
            moved.unsure = nil
            moved.excerpt = firstLine(rope, r)
            return (r, moved)
        }
        switch a.at {
        case let .symbol(path):
            if let tree = tree(of: b) {
                let same = tree.declarations().filter { $0.path == path }
                // The one nearest where it was, several being so named (overloads).
                if let d = same.min(by: { abs($0.range.start - was.start) < abs($1.range.start - was.start) }) { return found(d.range) }
            }
        case let .heading(path):
            if isMarkdown(b) {
                let lines = headingLines(path, in: rope.string)
                if let n = lines.min(by: { abs(rope.offset(ofLine: $0) - was.start) < abs(rope.offset(ofLine: $1) - was.start) }) { return found(rope.lineRange(n)) }
            }
        case .range:
            if a.unsure != true, was.end <= rope.count { return (was, nil) }
        case .command, .page:
            return nil
        }
        // By its words, nearest where it was.
        if let excerpt = a.excerpt?.trimmingCharacters(in: .whitespaces), !excerpt.isEmpty {
            let hits = rope.findAll(excerpt, limit: 200)
            if let hit = hits.min(by: { abs($0.start - was.start) < abs($1.start - was.start) }) {
                let line = rope.line(at: hit.start)
                return found(TextRange(rope.offset(ofLine: line), max(rope.lineRange(line).end, min(hit.start + (was.length), rope.count))))
            }
        }
        return nil
    }

    /// Its name, as a pill says it: the declaration's path, the heading.
    static func name(of a: Anchor) -> String {
        switch a.at {
        case let .symbol(path): path
        case let .heading(path): path.last ?? a.name ?? ""
        case let .command(n): a.name ?? "Command \(n)"
        case let .page(n): "Page \(n)"
        case .range: a.name ?? a.excerpt ?? ""
        }
    }

    // MARK: Structure

    private static func tree(of b: Block) -> SyntaxTree? {
        guard let path = b.path, let language = SyntaxLanguage.forPath(path), let rope = b.text?.text else { return nil }
        return SyntaxTree(language, text: rope, background: false)
    }

    private static func isMarkdown(_ b: Block) -> Bool { b.path.map(Lens.isMarkdown) ?? (b.kind == .text) }

    private static func firstLine(_ rope: Rope, _ r: TextRange) -> String {
        rope.lineText(rope.line(at: r.start)).trimmingCharacters(in: .whitespaces)
    }

    /// The headings over a line's heading and its own, if it's one.
    private static func headingPath(atLine line: Int, in text: String) -> [String]? {
        var path: [(level: Int, title: String)] = []
        for item in NoteOutlineMarkdown.items(in: text) where item.isHeading {
            while let last = path.last, last.level >= item.level { path.removeLast() }
            path.append((item.level, item.title))
            if item.line == line { return path.map(\.title) }
            if item.line > line { break }
        }
        return nil
    }

    /// The lines of the headings with this path.
    private static func headingLines(_ wanted: [String], in text: String) -> [Int] {
        var path: [(level: Int, title: String)] = []
        var out: [Int] = []
        for item in NoteOutlineMarkdown.items(in: text) where item.isHeading {
            while let last = path.last, last.level >= item.level { path.removeLast() }
            path.append((item.level, item.title))
            if path.map(\.title) == wanted { out.append(item.line) }
        }
        // Moved under another heading: by its own title alone.
        if out.isEmpty, let own = wanted.last {
            out = NoteOutlineMarkdown.items(in: text).filter { $0.isHeading && $0.title == own }.map(\.line)
        }
        return out
    }
}
