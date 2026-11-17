import Foundation

// The outliner's engine as its view sees it: a note open for editing as
// an outline, in the manner of Bike 2 — a Swift port of prism's note
// session (prism-markup's `Session`, and the `NoteEditor` its editor's
// view drives through prism-ffi), entirely Manifold's own. The view shows
// `text` (each row's words, rich, never Markdown), hands what was typed to
// `replace` and what was asked for to `perform`, and does what each
// answer says; `markdown` is the note's file. Every offset here is
// UTF-16, as NSString's.
//
// Where Manifold's notes differ from Weft's (the session's `Options`):
// a note's `# Title` is a row like any other, not kept apart; folds and
// the row focused on are the view's to keep, never written into the
// note; there are no cards (`<!-- card -->`).

/// A row of a note's outline, as a search of its rows lists it.
public struct BodyOutlineRow: Equatable, Sendable {
    /// Its place among all the note's rows, folded away or not: what
    /// `NoteEditor.revealRow` is asked with.
    public var index: Int
    /// How many rows it is under.
    public var depth: Int
    /// Its words, plain: no Markdown.
    public var words: String
    /// A heading's level.
    public var heading: Int?
    /// Its checkbox: open, or done.
    public var done: Bool?
    public var hasChildren: Bool

    public init(index: Int, depth: Int, words: String, heading: Int?, done: Bool?, hasChildren: Bool) {
        self.index = index; self.depth = depth; self.words = words; self.heading = heading; self.done = done; self.hasChildren = hasChildren
    }
}

/// What a line of a body is.
public enum BodyLineKind: Equatable, Sendable {
    case blank
    case paragraph
    case heading(level: Int)
    /// A list item's first line: its number (for `1.`), its checkbox
    /// (open or done), and the bullet it is written with (`-`, `*`, `+`, `1.`).
    case item(number: Int?, done: Bool?, bullet: String)
    case quote
    /// A code fence's opening or closing line.
    case fence
    /// A line inside a code fence.
    case code
    case table
    case rule
}

/// One line of a body.
public struct BodyLine: Equatable, Sendable {
    public var start: Int
    /// The line's end, before its line break.
    public var end: Int
    public var kind: BodyLineKind
    /// The spaces it is indented by.
    public var indent: Int
    /// Where its words begin: after its indentation and marker.
    public var content: Int
    /// How many list items it is inside.
    public var depth: Int
    /// In an outline: whether the row is folded — the rows under it are
    /// not shown, and so are no lines of the body.
    public var isFolded: Bool
    /// In an outline: whether the row has rows under it, shown or not.
    public var hasChildren: Bool
    /// In an outline: whether the row is shown as the card of what it
    /// links to. Never, in Manifold (kept for the view's sake).
    public var isCard: Bool

    public init(start: Int, end: Int, kind: BodyLineKind, indent: Int, content: Int, depth: Int, isFolded: Bool, hasChildren: Bool, isCard: Bool) {
        self.start = start; self.end = end; self.kind = kind; self.indent = indent; self.content = content; self.depth = depth
        self.isFolded = isFolded; self.hasChildren = hasChildren; self.isCard = isCard
    }
}

/// What a stretch of a line means.
public enum BodyRunKind: Equatable, Sendable {
    /// Markup with nothing to show: hidden off the lines being written in.
    case markup
    case strong
    case emphasis
    case strikethrough
    case highlight
    case code
    /// A link to a page (`[[Title]]`): its shown words.
    case pageLink(target: String, isEmbed: Bool)
    /// A link to an address (`[words](address)`, or one bare): its shown
    /// words. Manifold's own (`manifold:host/id`) are among them.
    case webLink(url: String)
    case tag(name: String)
    /// A picture: the whole of its markup.
    case image(source: String, alt: String, width: Double?, height: Double?)
    /// A list item's bullet or number.
    case bullet
    case checkbox(isDone: Bool)
    case quoteMark
    case callout(kind: String)
    /// A code fence's info string.
    case fenceInfo(info: String)
}

/// A stretch of a body, and what it means.
public struct BodyRun: Equatable, Sendable {
    public var start: Int
    public var end: Int
    public var kind: BodyRunKind

    public init(start: Int, end: Int, kind: BodyRunKind) { self.start = start; self.end = end; self.kind = kind }
}

/// A body, read for a text view.
public struct BodyLayout: Equatable, Sendable {
    public var lines: [BodyLine]
    public var runs: [BodyRun]

    public init(lines: [BodyLine], runs: [BodyRun]) { self.lines = lines; self.runs = runs }
}

/// Something an editor does to a body beyond typing a character.
public enum EditCommand: Equatable, Sendable, CaseIterable {
    /// Return: a new line of the same sort.
    case newline
    /// Delete at the start of a line's words: its marker is taken off.
    case deleteBackward
    case indent, outdent, moveUp, moveDown, deleteRows, duplicateRows
    case bold, italic, strikethrough, highlight, code
    /// A plain line → a checklist item → checked → a plain item.
    case cycleChecklist
    /// Made a task (`+ [ ]`), or a plain item again.
    case toggleTask
    /// A click on a checkbox.
    case toggleCheckbox
    case heading1, heading2, heading3, bullet, numbered, quote
    /// The rows above every sibling before them; below every one after.
    /// These, and the commands after them, are an outline's.
    case moveToTop, moveToBottom
    /// The rows under each row put out of sight; shown again.
    case fold, unfold, toggleFold
    /// Shown as the card of what it links to, or as its words again (no
    /// cards in Manifold: nothing to do).
    case toggleCard
    /// Each row folded, with every row under it that has rows of its own.
    case foldCompletely, unfoldCompletely
    /// Every row of the note that has rows under it, folded.
    case foldAll, unfoldAll
    /// The open tasks and checklist items among the rows, checked.
    case markDone
    /// The checked rows right under each row, put after the rest.
    case moveDoneToBottom
    /// Made a row of this kind, whatever it was.
    case turnParagraph, turnBullet, turnCheckbox, turnTask, turnNumbered, turnHeading1, turnHeading2, turnHeading3, turnQuote
    /// ⌘↩, ⇧⌘↩, ⌥⌘↩: a new, empty row below the row's branch, above it, or its first child.
    case insertBelow, insertAbove, insertChild
    /// ⌃⌥⌘↑ ⌃⌥⌘↓: moved among siblings, at their level.
    case moveUpKeepingLevel, moveDownKeepingLevel
    /// ⌃⌘⌫: the next row joined in, a space between.
    case joinRows
    /// ⌃⌥⇧← / ⌃⌥⇧→.
    case promoteChildren, demoteSiblings
    /// ⌥⌘G: under a new row.
    case group
    /// ⌃⌥K, ⌃⌥→, ⌃⌥←: the row alone, its children staying.
    case deleteRowOnly, indentRowOnly, outdentRowOnly
    /// ⌥⌘9 ⌥⌘0 ⌃⌥⌘9 ⌃⌥⌘0: folded or shown a level at a time — the row's, or the note's.
    case foldByLevel, unfoldByLevel, foldAllByLevel, unfoldAllByLevel
    /// ⌃⌥↑ ⌃⌥↓: the row alone, a line up or down.
    case moveUpRowOnly, moveDownRowOnly
}

/// What a command comes to: text to replace, and where the selection then
/// stands. The range is of the text as it was, the selection of the text
/// as it then is.
public struct BodyEdit: Equatable, Sendable {
    public var start: Int
    public var end: Int
    public var replacement: String
    public var selectionStart: Int
    public var selectionEnd: Int

    public init(start: Int, end: Int, replacement: String, selectionStart: Int, selectionEnd: Int) {
        self.start = start; self.end = end; self.replacement = replacement; self.selectionStart = selectionStart; self.selectionEnd = selectionEnd
    }
}

/// What can be done to a row of an outline: what a menu for it offers.
public struct BodyRowInfo: Equatable, Sendable {
    public var isFolded: Bool
    /// Whether it has rows under it, shown or folded away.
    public var hasChildren: Bool
    /// How many rows its fold hides.
    public var hidden: Int
    /// How many rows are shown under it.
    public var shown: Int
    /// Whether a row under it, however deep, is folded.
    public var foldsInside: Bool
    /// Whether it is unfolded and a row under it could be folded.
    public var openInside: Bool
    /// Its checkbox: open, or done; nil for a row without one.
    public var done: Bool?
    /// Whether it is a plain bullet with checkboxes among the rows under it.
    public var hasChecklist: Bool
    /// Whether Move Done to Bottom has something to do under it.
    public var doneToMove: Bool
    /// Whether it has a row before it at its level, and one after it.
    public var canMoveUp: Bool
    public var canMoveDown: Bool

    public init(isFolded: Bool, hasChildren: Bool, hidden: Int, shown: Int, foldsInside: Bool, openInside: Bool, done: Bool?,
                hasChecklist: Bool, doneToMove: Bool, canMoveUp: Bool, canMoveDown: Bool) {
        self.isFolded = isFolded; self.hasChildren = hasChildren; self.hidden = hidden; self.shown = shown; self.foldsInside = foldsInside
        self.openInside = openInside; self.done = done; self.hasChecklist = hasChecklist; self.doneToMove = doneToMove
        self.canMoveUp = canMoveUp; self.canMoveDown = canMoveDown
    }
}

/// A row folded, as the view keeps it: its place among all the body's
/// rows, shown or not, and its words (found again by them, nearest its place).
public struct FoldedRow: Equatable, Sendable, Codable {
    public var index: Int
    public var text: String

    public init(index: Int, text: String) { self.index = index; self.text = text }
}

/// What is being typed that something could be offered for.
public struct BodyCompletion: Equatable, Sendable {
    public enum Kind: Equatable, Sendable { case link, embed, tag, mention }
    public var kind: Kind
    /// What has been typed of it so far.
    public var typed: String
    /// The range typed, to be replaced by what's chosen.
    public var start: Int
    public var end: Int

    public init(kind: Kind, typed: String, start: Int, end: Int) { self.kind = kind; self.typed = typed; self.start = start; self.end = end }
}

/// A note open for editing as an outline (see the top of this file).
/// Not thread-safe: one thread (the main one) drives it.
public final class NoteEditor {
    /// Opens a note's file.
    public init(source: String) { fatalError("NoteEditor: being ported") }

    /// The note's file, as it now is. What was not edited is as it was read.
    public var markdown: String { fatalError("NoteEditor: being ported") }
    /// Whether the note is written as prose — its top level more paragraphs
    /// than list items: how it is shown when no one has said.
    public var readsAsProse: Bool { fatalError("NoteEditor: being ported") }
    /// Shows the note as prose, or not: rows made at the top level are
    /// written as paragraphs from then on. Nothing is changed by it.
    public func setProse(_ prose: Bool) { fatalError("NoteEditor: being ported") }
    /// What the view shows.
    public var text: String { fatalError("NoteEditor: being ported") }
    /// The pages the note links to (`[[…]]`), as written.
    public var linkTargets: [String] { fatalError("NoteEditor: being ported") }
    /// What each link to a page is shown as, by its target.
    public func setLinkLabels(_ labels: [String: String]) { fatalError("NoteEditor: being ported") }
    /// What the view shows, read for drawing.
    public var layout: BodyLayout { fatalError("NoteEditor: being ported") }
    /// What was typed, pasted or deleted in the view: a range of what it
    /// showed, replaced. The answer is what the view should now do — which
    /// is not always what was typed.
    public func replace(start: Int, end: Int, with replacement: String) -> BodyEdit { fatalError("NoteEditor: being ported") }
    /// Carries out a command; nil when it has nothing to do there, and the
    /// view should do what it would have done.
    public func perform(_ command: EditCommand, selectionStart: Int, selectionEnd: Int) -> BodyEdit? { fatalError("NoteEditor: being ported") }
    /// A command on some rows (lines of the body, from the first), wherever
    /// the caret is; nil for one done at the caret, and as text.
    public func perform(_ command: EditCommand, onRows rows: [Int], selectionStart: Int, selectionEnd: Int) -> BodyEdit? { fatalError("NoteEditor: being ported") }
    /// Rows, with what's under them, put before another row (one past the
    /// last for the end) at a depth, held to what can be (`dropDepth`); nil
    /// when that's where they are.
    public func moveRows(_ rows: [Int], before: Int, depth: Int, selectionStart: Int, selectionEnd: Int) -> BodyEdit? { fatalError("NoteEditor: being ported") }
    /// Rows written as Markdown put before a row at a depth; one change.
    public func insertRows(markdown: String, before: Int, depth: Int, selectionStart: Int, selectionEnd: Int) -> BodyEdit? { fatalError("NoteEditor: being ported") }
    /// How deep rows carried would lie put down before a row at a depth
    /// asked for; nil where they can't be (among the rows under one of them).
    public func dropDepth(rows: [Int], before: Int, depth: Int) -> Int? { fatalError("NoteEditor: being ported") }
    /// What can be done to a row; nil for no such row.
    public func rowInfo(_ row: Int) -> BodyRowInfo? { fatalError("NoteEditor: being ported") }
    /// A row's own Markdown.
    public func rowMarkdown(_ row: Int) -> String? { fatalError("NoteEditor: being ported") }
    /// The words chosen in the view, as Markdown: what copying them gives.
    public func markdownBetween(start: Int, end: Int) -> String { fatalError("NoteEditor: being ported") }
    /// Rows, with what is under them, as Markdown of their own.
    public func markdownOf(rows: [Int]) -> String { fatalError("NoteEditor: being ported") }
    /// Links the words selected to an address, or points the link they are
    /// the words of there; nil when nothing's selected, the selection spans
    /// lines, or the address is none.
    public func link(selectionStart: Int, selectionEnd: Int, address: String) -> BodyEdit? { fatalError("NoteEditor: being ported") }
    /// Every row, under folds or not, in reading order.
    public var outline: [BodyOutlineRow] { fatalError("NoteEditor: being ported") }
    /// Brings a row into sight (what it's under unfolded); where its words
    /// then start in `text`. nil for no such row or one not shown.
    public func revealRow(_ index: Int) -> Int? { fatalError("NoteEditor: being ported") }
    /// The rows folded.
    public var foldedRows: [FoldedRow] { fatalError("NoteEditor: being ported") }
    /// Folds these rows and no others; whether anything changed (if it did,
    /// `text` is other, and undo starts afresh).
    @discardableResult public func setFoldedRows(_ rows: [FoldedRow]) -> Bool { fatalError("NoteEditor: being ported") }
    /// Shows only what's under a row (a line of `text`, from the first) —
    /// or, given none, the whole note again; whether there was such a row.
    /// Kept in memory, never written into the note.
    @discardableResult public func setFocus(row: Int?) -> Bool { fatalError("NoteEditor: being ported") }
    /// Whether a row is focused on.
    public var isFocused: Bool { fatalError("NoteEditor: being ported") }
    /// The row focused on, as it reads.
    public var focusLabel: String? { fatalError("NoteEditor: being ported") }
    /// The rows the row focused on is under, outermost first, each as it reads.
    public var focusTrail: [String] { fatalError("NoteEditor: being ported") }
    /// Focus moved out `levels` rows (past the top: the whole note); whether it moved.
    @discardableResult public func focusOut(levels: Int) -> Bool { fatalError("NoteEditor: being ported") }
    /// Takes the last change back, structure and all.
    public func undo() -> BodyEdit? { fatalError("NoteEditor: being ported") }
    public func redo() -> BodyEdit? { fatalError("NoteEditor: being ported") }
    public var canUndo: Bool { fatalError("NoteEditor: being ported") }
    public var canRedo: Bool { fatalError("NoteEditor: being ported") }
    /// Whether the note has nothing in it.
    public var isBlank: Bool { fatalError("NoteEditor: being ported") }

    /// A text that is a web or mail address and nothing else, trimmed:
    /// what, pasted onto words, links them. nil for any other text.
    public static func webAddress(_ text: String) -> String? { fatalError("NoteEditor: being ported") }
    /// What's being typed at the caret that something could be offered for.
    public static func completion(in text: String, caret: Int) -> BodyCompletion? { fatalError("NoteEditor: being ported") }
}
