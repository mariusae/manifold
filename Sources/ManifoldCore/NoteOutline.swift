import Foundation

/// A note as an outline (the outliner lens, §7.9): a flat run of rows, each
/// at a depth — Prism's, read from and written back to the note's Markdown.
///
/// Markdown lists are the outline. A list item is a row, and what sits inside
/// it — its sublist, a paragraph after a blank line, a code block — is its
/// children, one level deeper. Anything outside a list (a heading, a
/// paragraph) is a row at the depth of the list it sits in, usually zero.
///
/// Rows keep the small facts of how they were written (which bullet, how many
/// spaces, the blank lines before) so that a note read and written without
/// being edited comes back byte for byte.
public struct NoteOutline: Equatable, Sendable {
    /// The frontmatter block, fences and all, exactly as read.
    public var frontmatter: String?
    public var rows: [NoteRow]
    /// Blank lines after the last row.
    public var trailingGap: [String] = []
    /// Whether the last line ends in a line break.
    public var endsWithNewline = true
    /// `\n`, or `\r\n` for a note written on Windows.
    public var lineEnding = "\n"

    public init(frontmatter: String? = nil, rows: [NoteRow], trailingGap: [String] = [], endsWithNewline: Bool = true) {
        self.frontmatter = frontmatter
        self.rows = rows
        self.trailingGap = trailingGap
        self.endsWithNewline = endsWithNewline
    }

    /// Whether there is nothing written: no rows, or only an empty bullet —
    /// which is how an outline begins.
    public var isBlank: Bool {
        frontmatter == nil && rows.allSatisfy { $0.text.trimmingCharacters(in: .whitespaces).isEmpty && $0.task == nil && $0.kind.isListItem }
    }
}

/// One row of an outline.
public struct NoteRow: Equatable, Sendable {
    public enum Kind: Equatable, Sendable {
        /// `- text`, `* text` or `+ text`.
        case bullet
        /// `1. text` or `1) text`.
        case ordered
        /// `## text`; the level is 1 to 6.
        case heading(Int)
        /// Text that is not a list item: a line at the top of a note, or a
        /// paragraph set inside a list item after a blank line.
        case paragraph
        /// `> text`.
        case quote
        /// A fenced code block, fences included in the text.
        case code
        /// `---`, `***` or `___`.
        case rule

        public var isListItem: Bool { self == .bullet || self == .ordered }
    }

    /// A checkbox on a list item.
    public enum Task: Equatable, Sendable {
        case open
        /// Done, with the letter it was checked with, `x` or `X`.
        case done(Character)

        public var isDone: Bool { if case .done = self { true } else { false } }
    }

    public var kind: Kind
    public var depth: Int
    /// The row's text without its marker. Lines after the first are joined
    /// with `\n`, without the indentation that places them in the outline.
    public var text: String
    public var task: Task?
    /// The bullet (`-`, `*`, `+`) or, for an ordered item, the delimiter
    /// after the number (`.` or `)`).
    public var marker: Character = "-"
    public var number: Int = 1
    /// Spaces between the marker (or heading hashes) and the text.
    public var spacing: Int = 1
    /// Spaces of indentation beyond what the depth asks for.
    public var extraIndent: Int = 0
    /// The blank lines before the row, as written.
    public var gap: [String] = []
    /// The indentation each continuation line was written with, when it was
    /// not the usual; nil is the usual.
    public var continuationIndents: [Int?]?
    /// Children folded out of sight, their depths counted from this row's:
    /// a child is at depth 1. Folding is how the note is shown, not what it
    /// says, so a folded row writes out its children like any other.
    public var folded: [NoteRow] = []

    public init(kind: Kind, depth: Int = 0, text: String = "", task: Task? = nil, marker: Character = "-",
                number: Int = 1, spacing: Int = 1, extraIndent: Int = 0, gap: [String] = []) {
        self.kind = kind
        self.depth = depth
        self.text = text
        self.task = task
        self.marker = marker
        self.number = number
        self.spacing = spacing
        self.extraIndent = extraIndent
        self.gap = gap
    }

    /// An empty bullet, the row an empty outline starts with.
    public static var blank: NoteRow { NoteRow(kind: .bullet) }

    /// Whether the row can hold children in Markdown: only list items can.
    public var canHaveChildren: Bool { kind.isListItem }

    public var isFolded: Bool { !folded.isEmpty }

    /// Done, and struck through: a short task, as a line through a line. A
    /// long one only greyed — struck through, a paragraph is all lines.
    public var isStruck: Bool {
        task?.isDone == true && text.count <= 80 && !text.contains(where: \.isNewline)
    }

    /// A top-level item with children — open or folded — a group's head,
    /// set a little heavier. Not a task: it is a thing to do, not a heading.
    public func headsGroup(before next: NoteRow?) -> Bool {
        guard depth == 0, kind.isListItem, task == nil else { return false }
        return isFolded || (next?.depth ?? 0) > 0
    }

    /// A top-level item after another's children: a new group, given room above.
    public func startsGroup(after previous: NoteRow?) -> Bool {
        guard let previous, depth == 0, kind.isListItem else { return false }
        return previous.depth > 0 && previous.kind.isListItem
    }
}

extension NoteOutline {
    /// The rows with every fold opened, as they are written.
    public var unfoldedRows: [NoteRow] { NoteRow.unfold(rows) }
}

extension NoteRow {
    /// Rows with their folded children put back in line.
    public static func unfold(_ rows: [NoteRow], under depth: Int = 0) -> [NoteRow] {
        var result: [NoteRow] = []
        result.reserveCapacity(rows.count)
        for var row in rows {
            let folded = row.folded
            row.folded = []
            row.depth += depth
            result.append(row)
            if !folded.isEmpty { result.append(contentsOf: unfold(folded, under: row.depth)) }
        }
        return result
    }
}
