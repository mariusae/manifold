import Foundation

/// A place in a block that something refers to (§2.5): minted in the
/// block's own log when it's first referred to, and named in a reference
/// by its id alone — `manifold:host/ulid#<id>`, opaque to everything but
/// the block. It holds what it's at, as the block's kind knows the
/// block, and what finds it again.
public struct Anchor: Codable, Equatable, Hashable, Sendable, Identifiable {
    public var id: String
    public var at: AnchorTarget
    /// A text's: the range it covers now, moved through every edit as the
    /// block moves its selections.
    public var range: TextRange?
    /// Its first line as it was when made, to find it again by when the
    /// text changed where no edit said (the file written by another program).
    public var excerpt: String?
    /// What it's called: a declaration's path, a heading, the line's words.
    public var name: String?
    /// The text changed under it where no edit said: its range is a guess
    /// until it's found again.
    public var unsure: Bool?
    /// A declaration's global name in its project's SCIP index, where one
    /// was: what finds it in another file, moved there.
    public var scip: String?

    public init(id: String, at: AnchorTarget, range: TextRange? = nil, excerpt: String? = nil, name: String? = nil) {
        self.id = id
        self.at = at
        self.range = range
        self.excerpt = excerpt
        self.name = name
    }

    /// A new anchor's id: short, and not one the block has (`taken`).
    public static func newID(taken: Set<String>) -> String {
        let alphabet = Array("0123456789abcdefghjkmnpqrstvwxyz")
        while true {
            let id = String((0..<6).map { _ in alphabet[Int.random(in: 0..<alphabet.count)] })
            if !taken.contains(id), !id.contains("=") { return id }
        }
    }

    /// Whether a reference's fragment names an anchor (an id), not one of
    /// the legible places written before anchors (`line=12`, `page=3`).
    public static func isAnchor(_ fragment: String) -> Bool { !fragment.isEmpty && !fragment.contains("=") }
}

/// What an anchor is at, as its block's kind knows the block.
public enum AnchorTarget: Codable, Equatable, Hashable, Sendable {
    /// A declaration in code: its path (`Type.method`), by its language's grammar.
    case symbol(path: String)
    /// A heading in Markdown: its path, the headings over it and its own.
    case heading(path: [String])
    /// A stretch of text, known by nothing but where it is.
    case range
    /// One command of a terminal's, and its output.
    case command(Int)
    /// A page of a PDF, from 1.
    case page(Int)
}

extension TextRange {
    /// Where this range is after `edit` (made to the text it's in): before
    /// the edit, as it was; after, moved by what the edit added or took;
    /// an end within what was replaced, at the replacement's end, a start
    /// at its start.
    public func moved(by edit: TextEdit) -> TextRange {
        let added = edit.text.utf8.count - (edit.end - edit.start)
        func start(_ p: Int) -> Int {
            if p < edit.start { return p }
            if p >= edit.end { return p + added }
            return edit.start
        }
        func end(_ p: Int) -> Int {
            if p <= edit.start { return p }
            if p >= edit.end { return p + added }
            return edit.start + edit.text.utf8.count
        }
        let s = start(self.start), e = max(end(self.end), s)
        return TextRange(s, e)
    }
}

extension Block {
    /// Anchors' ranges moved through edits; or, the whole text read again
    /// (`before` what it was), moved through what changed between the two
    /// — those in the change marked unsure, to be found again.
    mutating func moveAnchors(_ event: Event, before: Rope?) {
        guard var all = anchors, !all.isEmpty else { return }
        switch event {
        case let .edit(edits):
            for (id, a) in all {
                guard var r = a.range else { continue }
                for e in edits { r = r.moved(by: e) }
                all[id]?.range = r
            }
        case .content:
            guard let before, let after = text?.text else { return }
            guard let (start, oldEnd, newEnd) = after.changed(from: before) else { return }
            let edit = TextEdit(start: start, end: oldEnd, text: String(repeating: " ", count: newEnd - start))
            for (id, a) in all {
                guard let r = a.range else { continue }
                all[id]?.range = r.moved(by: edit).clamped(to: after.count)
                if r.end > start, r.start < oldEnd { all[id]?.unsure = true }
            }
        default: return
        }
        anchors = all
    }
}
