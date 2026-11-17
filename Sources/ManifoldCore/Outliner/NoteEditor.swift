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
    let session: Markup.Session
    /// What links to pages are shown as, by target — once a view has said;
    /// till then each is its atom alone.
    var labels: [String: String]? = nil
    /// The text as the view shows it, while the session's is the same.
    var cached: Shown? = nil

    /// Opens a note's file.
    public init(source: String) { session = Markup.Session(source, options: .manifold) }

    /// Opens a note's file, read and written as these options say.
    init(source: String, options: Markup.Options) { session = Markup.Session(source, options: options) }

    /// The note's file, as it now is. What was not edited is as it was read.
    public var markdown: String { session.markdown() }
    /// Whether the note is written as prose — its top level more paragraphs
    /// than list items: how it is shown when no one has said.
    public var readsAsProse: Bool { session.readsAsProse }
    /// Shows the note as prose, or not: rows made at the top level are
    /// written as paragraphs from then on. Nothing is changed by it.
    public func setProse(_ prose: Bool) { session.setProse(prose) }
    /// What the view shows.
    public var text: String { shown().text }
    /// The pages the note links to (`[[…]]`), as written.
    public var linkTargets: [String] {
        var targets: [String] = []
        for run in session.layout().runs {
            if case .pageLink(let target, false) = run.kind, !targets.contains(target) { targets.append(target) }
        }
        return targets
    }
    /// What each link to a page is shown as, by its target. From then on
    /// each such link is its atom and then those words, which wrap as words
    /// do; one with none given, its target. The text changes: a view shows
    /// it again.
    public func setLinkLabels(_ labels: [String: String]) {
        self.labels = labels
        cached = nil
    }
    /// What the view shows, read for drawing.
    public var layout: BodyLayout { NoteEditor.layout(session.layout(), shown(), session.rowFolds(), session.rowCards()) }
    /// What was typed, pasted or deleted in the view: a range of what it
    /// showed, replaced. The answer is what the view should now do — which
    /// is not always what was typed.
    public func replace(start: Int, end: Int, with replacement: String) -> BodyEdit {
        let edit = changing { session, offsets in session.replace(offsets.range(start, end), replacement) }
        return edit ?? BodyEdit(start: start, end: end, replacement: "", selectionStart: start, selectionEnd: start)
    }
    /// Carries out a command; nil when it has nothing to do there, and the
    /// view should do what it would have done.
    public func perform(_ command: EditCommand, selectionStart: Int, selectionEnd: Int) -> BodyEdit? {
        guard let command = NoteEditor.command(command) else { return nil }
        return changing { session, offsets in session.perform(offsets.range(selectionStart, selectionEnd), command) }
    }
    /// A command on some rows (lines of the body, from the first), wherever
    /// the caret is; nil for one done at the caret, and as text.
    public func perform(_ command: EditCommand, onRows rows: [Int], selectionStart: Int, selectionEnd: Int) -> BodyEdit? {
        guard let command = NoteEditor.command(command) else { return nil }
        return changing { session, offsets in session.perform(onRows: rows, offsets.range(selectionStart, selectionEnd), command) }
    }
    /// Rows, with what's under them, put before another row (one past the
    /// last for the end) at a depth, held to what can be (`dropDepth`); nil
    /// when that's where they are.
    public func moveRows(_ rows: [Int], before: Int, depth: Int, selectionStart: Int, selectionEnd: Int) -> BodyEdit? {
        changing { session, offsets in session.moveRows(rows, before, depth, offsets.range(selectionStart, selectionEnd)) }
    }
    /// Rows written as Markdown put before a row at a depth; one change.
    public func insertRows(markdown: String, before: Int, depth: Int, selectionStart: Int, selectionEnd: Int) -> BodyEdit? {
        changing { session, offsets in session.insertRows(markdown, before, depth, offsets.range(selectionStart, selectionEnd)) }
    }
    /// How deep rows carried would lie put down before a row at a depth
    /// asked for; nil where they can't be (among the rows under one of them).
    public func dropDepth(rows: [Int], before: Int, depth: Int) -> Int? { session.dropDepth(rows, before, depth) }
    /// What can be done to a row; nil for no such row.
    public func rowInfo(_ row: Int) -> BodyRowInfo? {
        guard let info = session.rowInfo(row) else { return nil }
        return BodyRowInfo(isFolded: info.folded, hasChildren: info.hasChildren, hidden: info.hidden, shown: info.shown, foldsInside: info.foldsInside,
                           openInside: info.openInside, done: info.task, hasChecklist: info.hasChecklist, doneToMove: info.doneToMove,
                           canMoveUp: info.canMoveUp, canMoveDown: info.canMoveDown)
    }
    /// A row's own Markdown.
    public func rowMarkdown(_ row: Int) -> String? { session.rowMarkdown(row) }
    /// The words chosen in the view, as Markdown: what copying them gives.
    public func markdownBetween(start: Int, end: Int) -> String { session.markdownBetween(shown().range(start, end)) }
    /// Rows, with what is under them, as Markdown of their own.
    public func markdownOf(rows: [Int]) -> String { session.markdownOf(rows) }
    /// Links the words selected to an address, or points the link they are
    /// the words of there; nil when nothing's selected, the selection spans
    /// lines, or the address is none.
    public func link(selectionStart: Int, selectionEnd: Int, address: String) -> BodyEdit? {
        changing { session, offsets in session.link(offsets.range(selectionStart, selectionEnd), address) }
    }
    /// Every row, under folds or not, in reading order.
    public var outline: [BodyOutlineRow] {
        session.outline().enumerated().map { index, row in
            BodyOutlineRow(index: index, depth: row.depth, words: NoteEditor.words(row.text, labels), heading: row.heading, done: row.task, hasChildren: row.hasChildren)
        }
    }
    /// Brings a row into sight (what it's under unfolded); where its words
    /// then start in `text`. nil for no such row or one not shown.
    public func revealRow(_ index: Int) -> Int? {
        let before = session.text
        guard let at = session.revealRow(index) else { return nil }
        if !session.text.same(before) { cached = nil }
        return shown().to16(at)
    }
    /// The rows folded.
    public var foldedRows: [FoldedRow] { session.foldedRows() }
    /// Folds these rows and no others; whether anything changed (if it did,
    /// `text` is other, and undo starts afresh).
    @discardableResult public func setFoldedRows(_ rows: [FoldedRow]) -> Bool {
        let changed = session.setFoldedRows(rows)
        if changed { cached = nil }
        return changed
    }
    /// Shows only what's under a row (a line of `text`, from the first) —
    /// or, given none, the whole note again; whether there was such a row.
    /// Kept in memory, never written into the note.
    @discardableResult public func setFocus(row: Int?) -> Bool {
        defer { cached = nil }
        guard let row else { return session.setFocus(path: nil) }
        guard row >= 0, row < session.rows.count, session.body.get(session.rows[row].path)?.canHaveChildren == true else { return false }
        return session.setFocus(path: (session.focusRoot ?? []) + session.rows[row].path)
    }
    /// Whether a row is focused on.
    public var isFocused: Bool { session.isFocused }
    /// The row focused on, as it reads.
    public var focusLabel: String? { session.focusLabel }
    /// The rows the row focused on is under, outermost first, each as it reads.
    public var focusTrail: [String] { session.focusTrail }
    /// Focus moved out `levels` rows (past the top: the whole note); whether it moved.
    @discardableResult public func focusOut(levels: Int) -> Bool {
        guard session.isFocused, levels >= 1 else { return false }
        cached = nil
        return session.setFocus(path: session.focusOutPath(levels))
    }
    /// Takes the last change back, structure and all.
    public func undo() -> BodyEdit? { changing { session, _ in session.undo() } }
    public func redo() -> BodyEdit? { changing { session, _ in session.redo() } }
    public var canUndo: Bool { session.canUndo }
    public var canRedo: Bool { session.canRedo }
    /// Whether the note has nothing in it.
    public var isBlank: Bool { session.body.isBlank }

    /// The 0-based lines of `markdown` that a row (a line of `text`) and its
    /// own continuation lines take — not the rows under it; nil for no such row.
    public func markdownLines(ofRow row: Int) -> ClosedRange<Int>? {
        guard row >= 0, row < session.rows.count else { return nil }
        let path = (session.focusRoot ?? []) + session.rows[row].path
        let whole = session.whole()
        guard let index = whole.rows().firstIndex(where: { $0.path == path }) else { return nil }
        var flat: [(Int, Markup.Block)] = []
        Markup.flatten(whole.blocks, 0, &flat)
        var spans: [(Int, Int)] = []
        _ = Markup.write(flat, whole.trailingBlank, whole.finalNewline, whole.lineEnding) { spans.append(($0, $1)) }
        guard index < spans.count else { return nil }
        let before = (session.frontmatter?.description ?? "").utf8.filter { $0 == .newline }.count + session.heading.utf8.filter { $0 == .newline }.count
        let (start, count) = spans[index]
        return (before + start)...(before + start + max(count, 1) - 1)
    }

    /// A text that is a web or mail address and nothing else, trimmed:
    /// what, pasted onto words, links them. nil for any other text.
    public static func webAddress(_ text: String) -> String? { Markup.Inline.address(text) }
    /// What's being typed at the caret that something could be offered for.
    public static func completion(in text: String, caret: Int) -> BodyCompletion? {
        let offsets = Shown.of(text.u8, [])
        guard let found = Markup.Editor.completion(text, caret: offsets.to8(caret, after: false)) else { return nil }
        let kind: BodyCompletion.Kind
        switch found.kind {
        case .link: kind = .link
        case .embed: kind = .embed
        case .tag: kind = .tag
        case .mention: kind = .mention
        }
        return BodyCompletion(kind: kind, typed: found.typed, start: offsets.to16(found.range.lowerBound), end: offsets.to16(found.range.upperBound))
    }

    // --- In the view's own offsets ------------------------------------------

    /// The session's text as the view shows it: each link to a page with its
    /// label, if labels are given.
    func shown() -> Shown {
        if let cached { return cached }
        var expand: [(Int, String)] = []
        if let labels, session.textBytes.contains(Markup.atomBytes) {
            for run in session.layout().runs {
                guard case .pageLink(let target, false) = run.kind, session.textBytes.sub(run.range) == Markup.atomBytes else { continue }
                let label = labels[target].flatMap { $0.isEmpty ? nil : $0 } ?? target
                expand.append((run.range.lowerBound, label))
            }
        }
        let shown = Shown.of(session.textBytes, expand)
        cached = shown
        return shown
    }

    /// A change of the session's, in the view's own offsets: what of the
    /// text as it was is replaced, found by comparing it with the text as it
    /// now is; and the selection, of the text as it now is.
    func changing(_ change: (Markup.Session, Shown) -> Markup.Change?) -> BodyEdit? {
        let before = shown()
        guard let made = change(session, before) else { return nil }
        cached = nil
        let after = shown()
        let (start, end, replacement) = NoteEditor.difference(before.units, after.units)
        return BodyEdit(start: start, end: end, replacement: replacement, selectionStart: after.to16(made.selection.lowerBound), selectionEnd: after.to16(made.selection.upperBound))
    }

    /// Where two texts differ, in UTF-16: the range of the first that the
    /// second replaces, and what with.
    static func difference(_ was: [UInt16], _ is_: [UInt16]) -> (Int, Int, String) {
        var same = 0
        while same < min(was.count, is_.count) && was[same] == is_[same] { same += 1 }
        var tail = 0
        while tail < min(was.count, is_.count) - same && was[was.count - 1 - tail] == is_[is_.count - 1 - tail] { tail += 1 }
        let replacement = String(decoding: is_[same..<(is_.count - tail)], as: UTF16.self)
        return (same, was.count - tail, replacement)
    }

    /// A row's words, plain, as a view shows them: a link to a page by its
    /// label — the one given, else its own, else its target — and a picture
    /// by nothing; one line.
    static func words(_ markdown: String, _ labels: [String: String]?) -> String {
        let rich = Markup.Rich.parse(markdown)
        var out = ""
        for (at, c) in rich.bytes.scalars {
            if c != Markup.atom {
                out.unicodeScalars.append(c == "\n" || c == "\u{2028}" ? " " : c)
                continue
            }
            let atom = rich.runs.first { $0.range.lowerBound == at && $0.mark.isAtom }
            if case .atom(let a) = atom?.mark, case .page(let target, let label, false) = a.kind {
                let given = labels?[target].flatMap { $0.isEmpty ? nil : $0 }
                out += given ?? label ?? target
            }
        }
        return out.trimmedWS
    }

    /// A layout in the view's own offsets. `folds` says of each line whether
    /// it is folded, and whether it has rows under it.
    static func layout(_ read: Markup.TextLayout, _ offsets: Shown, _ folds: [(Bool, Bool)], _ cards: [Bool]) -> BodyLayout {
        let lines = read.lines.enumerated().map { index, line -> BodyLine in
            let kind: BodyLineKind
            switch line.kind {
            case .blank: kind = .blank
            case .paragraph: kind = .paragraph
            case .heading(let level): kind = .heading(level: level)
            case .item(let ordered, let task, let bullet): kind = .item(number: ordered, done: task, bullet: String(bullet))
            case .quote: kind = .quote
            case .fence: kind = .fence
            case .code: kind = .code
            case .table: kind = .table
            case .rule: kind = .rule
            }
            return BodyLine(start: offsets.to16(line.range.lowerBound), end: offsets.to16(line.range.upperBound), kind: kind, indent: line.indent,
                            content: offsets.to16(line.content), depth: line.depth, isFolded: index < folds.count && folds[index].0,
                            hasChildren: index < folds.count && folds[index].1, isCard: index < cards.count && cards[index])
        }
        let runs = read.runs.map { run -> BodyRun in
            let kind: BodyRunKind
            switch run.kind {
            case .markup: kind = .markup
            case .strong: kind = .strong
            case .emphasis: kind = .emphasis
            case .strikethrough: kind = .strikethrough
            case .highlight: kind = .highlight
            case .code: kind = .code
            case .pageLink(let target, let embed): kind = .pageLink(target: target, isEmbed: embed)
            case .webLink(let url): kind = .webLink(url: url)
            case .tag(let name): kind = .tag(name: name)
            case .image(let source, let alt, let width, let height): kind = .image(source: source, alt: alt, width: width, height: height)
            case .bullet: kind = .bullet
            case .checkbox(let done): kind = .checkbox(isDone: done)
            case .quoteMark: kind = .quoteMark
            case .callout(let k): kind = .callout(kind: k)
            case .fenceInfo(let info): kind = .fenceInfo(info: info)
            }
            // A link to a page shown with its label covers its atom and its words.
            return BodyRun(start: offsets.to16(run.range.lowerBound), end: offsets.to16(run.range.upperBound), kind: kind)
        }
        return BodyLayout(lines: lines, runs: runs)
    }

    static func command(_ command: EditCommand) -> Markup.Command? {
        switch command {
        case .newline: return .newline
        case .deleteBackward: return .deleteBackward
        case .indent: return .indent
        case .outdent: return .outdent
        case .moveUp: return .moveUp
        case .moveDown: return .moveDown
        case .deleteRows: return .deleteRows
        case .duplicateRows: return .duplicateRows
        case .bold: return .toggle(.strong)
        case .italic: return .toggle(.emphasis)
        case .strikethrough: return .toggle(.strikethrough)
        case .highlight: return .toggle(.highlight)
        case .code: return .toggle(.code)
        case .cycleChecklist: return .cycleChecklist
        case .toggleTask: return .toggleTask
        case .toggleCheckbox: return .toggleCheckbox
        case .heading1: return .heading(1)
        case .heading2: return .heading(2)
        case .heading3: return .heading(3)
        case .bullet: return .bullet
        case .numbered: return .numbered
        case .quote: return .quote
        case .moveToTop: return .moveToTop
        case .moveToBottom: return .moveToBottom
        case .fold: return .fold
        case .unfold: return .unfold
        case .toggleFold: return .toggleFold
        // No cards in Manifold: nothing to do.
        case .toggleCard: return nil
        case .foldCompletely: return .foldCompletely
        case .unfoldCompletely: return .unfoldCompletely
        case .foldAll: return .foldAll
        case .unfoldAll: return .unfoldAll
        case .markDone: return .markDone
        case .moveDoneToBottom: return .moveDoneToBottom
        case .turnParagraph: return .turn(.paragraph)
        case .turnBullet: return .turn(.bullet)
        case .turnCheckbox: return .turn(.checkbox)
        case .turnTask: return .turn(.task)
        case .turnNumbered: return .turn(.numbered)
        case .turnHeading1: return .turn(.heading(1))
        case .turnHeading2: return .turn(.heading(2))
        case .turnHeading3: return .turn(.heading(3))
        case .turnQuote: return .turn(.quote)
        case .insertBelow: return .insertBelow
        case .insertAbove: return .insertAbove
        case .insertChild: return .insertChild
        case .moveUpKeepingLevel: return .moveUpKeepingLevel
        case .moveDownKeepingLevel: return .moveDownKeepingLevel
        case .joinRows: return .joinRows
        case .promoteChildren: return .promoteChildren
        case .demoteSiblings: return .demoteSiblings
        case .group: return .group
        case .deleteRowOnly: return .deleteRowOnly
        case .indentRowOnly: return .indentRowOnly
        case .outdentRowOnly: return .outdentRowOnly
        case .foldByLevel: return .foldByLevel
        case .unfoldByLevel: return .unfoldByLevel
        case .foldAllByLevel: return .foldAllByLevel
        case .unfoldAllByLevel: return .unfoldAllByLevel
        case .moveUpRowOnly: return .moveUpRowOnly
        case .moveDownRowOnly: return .moveDownRowOnly
        }
    }
}

/// The text a view shows: the session's, with each link to a page — one
/// atom there — shown as that atom and then its label's words, so that the
/// words of a long title wrap as any words do. The atom stays, first: the
/// room for the link's icon. Offsets of the shown text are UTF-16.
struct Shown {
    var text: String
    /// The shown text in UTF-16.
    var units: [UInt16]
    /// For each byte offset of the session's text that starts a character
    /// (and its end): the UTF-16 units before it in the shown text.
    var utf16: [Int]
    /// Each label: its UTF-16 span in the shown text — its atom's offset, and
    /// its words' end — and its atom's bytes in the session's text.
    var labels: [(start: Int, end: Int, atom: Range<Int>)]

    /// The session's text, with these atoms — by byte offset — given these labels.
    static func of(_ raw: Bytes, _ expand: [(Int, String)]) -> Shown {
        var utf16 = [Int](repeating: 0, count: raw.count + 1)
        var out = Bytes()
        out.reserveCapacity(raw.count)
        var labels: [(start: Int, end: Int, atom: Range<Int>)] = []
        var next = 0
        var units = 0
        var at = 0
        while at < raw.count {
            let len = raw.charLen(at: at)
            for inside in 0..<len { utf16[at + inside] = units }
            out.append(contentsOf: raw[at..<(at + len)])
            let start = units
            units += raw.scalar(at: at)?.utf16Len ?? 1
            while next < expand.count && expand[next].0 < at { next += 1 }
            if next < expand.count && expand[next].0 == at {
                let label = expand[next].1
                out.append(contentsOf: label.utf8)
                units += label.utf16.count
                labels.append((start, units, at..<(at + len)))
                next += 1
            }
            at += len
        }
        utf16[raw.count] = units
        let text = out.string
        return Shown(text: text, units: Array(text.utf16), utf16: utf16, labels: labels)
    }

    func to16(_ byte: Int) -> Int { utf16[min(max(byte, 0), utf16.count - 1)] }

    /// The session's byte offset of a place in the shown text. A place in a
    /// label's words is none of the session's: it is the link's start, or —
    /// `after` — its end, for a link is changed whole or not at all.
    func to8(_ unit: Int, after: Bool) -> Int {
        if let label = labels.first(where: { $0.start < unit && unit < $0.end }) { return after ? label.atom.upperBound : label.atom.lowerBound }
        var (low, high) = (0, utf16.count)
        while low < high {
            let mid = (low + high) / 2
            if utf16[mid] < unit { low = mid + 1 } else { high = mid }
        }
        return min(low, utf16.count - 1)
    }

    /// A range of the shown text, in the session's bytes: a link it runs
    /// into is in it whole; a place in a label, its end.
    func range(_ start: Int, _ end: Int) -> Range<Int> {
        let end = max(end, start)
        if start == end {
            let at = to8(start, after: true)
            return at..<at
        }
        let (a, b) = (to8(start, after: false), to8(end, after: true))
        return a..<max(a, b)
    }
}
