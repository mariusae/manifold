import Foundation

// An editing session: a note being written, held as what it is.
//
// An editor does not edit text. It edits a note — its frontmatter, and its
// body as a tree of blocks — and a `Session` is that note, open. A text view
// is only how the body is shown while it is written: the session gives it a
// projection of the tree to display (`text`, `layout()`), takes every change
// made in the view as a change to the tree (`replace`, `perform`), and
// answers with what the view should then show (`Change`).
//
// A note is shown as rows, a row a block, as Bike shows an outline. The view
// holds each block's words as they read — rich text, never its Markdown;
// what kind of block it is, and how deep, is for the view to draw beside
// them. Return splits a block, Tab puts it under the one before, and every
// such command is an operation on the tree (`Markup.Outline`). `markdown()`
// is the file, and what was not edited is written as it was read.
//
// Offsets are bytes of the projection. A line break inside a block — a
// paragraph of two lines, a code block — is shown as U+2028, so that a row
// is always one line of the view.
//
// prism's sessions (Weft's) keep a note's `# Title` apart and write folds,
// row names and cards into the note as comments; Manifold's do none of it
// (`Options`), and keep folds and focus in memory.

extension Markup {
    /// A line break inside a block, as an outline shows it.
    public static let softBreak: Unicode.Scalar = "\u{2028}"
    static let softBreakBytes = "\u{2028}".u8

    /// What a view should do after the session changed: replace a range of
    /// what it shows, and put the selection somewhere.
    public struct Change: Equatable, Sendable {
        /// The range to replace, of the projection as it was.
        public var range: Range<Int>
        public var replacement: String
        /// The selection after, in the projection as it then is.
        public var selection: Range<Int>
    }

    /// A row of the outline, as a search of it lists it.
    public struct OutlineRow: Equatable, Sendable {
        /// How many rows it is under.
        public var depth: Int
        /// Its words, as written: Markdown.
        public var text: String
        /// A heading's level.
        public var heading: Int?
        /// A checkbox: open, or done.
        public var task: Bool?
        public var hasChildren: Bool
    }

    /// What can be done to a row of an outline: see `Session.rowInfo`.
    public struct RowInfo: Equatable, Sendable {
        public var folded = false
        public var hasChildren = false
        public var hidden = 0
        public var shown = 0
        public var foldsInside = false
        public var openInside = false
        public var task: Bool? = nil
        public var hasChecklist = false
        public var doneToMove = false
        public var canMoveUp = false
        public var canMoveDown = false
    }

    /// How a session reads and writes a note: as Weft's (prism's) do, or as
    /// Manifold's.
    public struct Options: Equatable, Sendable {
        /// Whether a first line `# Title` is kept apart from the rows, as a
        /// card shows a title on its own.
        public var keepsTitleApart: Bool
        /// Whether folds and rows' names are written into the note
        /// (`<!-- folded -->`, `<!-- ^name -->`) and read from it.
        public var writesMarks: Bool
        /// Whether a row can be shown as the card of its link (`<!-- card -->`).
        public var cards: Bool

        public init(keepsTitleApart: Bool, writesMarks: Bool, cards: Bool) {
            self.keepsTitleApart = keepsTitleApart; self.writesMarks = writesMarks; self.cards = cards
        }

        /// Manifold's: the title a row, folds and focus the view's, no cards.
        public static let manifold = Options(keepsTitleApart: false, writesMarks: false, cards: false)
        /// prism's, for Weft.
        public static let prism = Options(keepsTitleApart: true, writesMarks: true, cards: true)
    }

    struct RowSpan: Equatable {
        var path: Path
        var range: Range<Int>
    }

    /// What a focused session is not showing: the whole body — but for the
    /// rows under the one focused on, which are the session's body while it
    /// is — and where in it that row is.
    struct Outer {
        var whole: Document
        var root: Path
    }

    // Marks put in a block's words while rows are rearranged: noncharacters,
    // which no text holds.
    static let markAnchor = Unicode.Scalar(0xFDD0 as UInt32)!
    static let markCaret = Unicode.Scalar(0xFDD1 as UInt32)!
    static let markChosen = Unicode.Scalar(0xFDD2 as UInt32)!
    static let markAbove = Unicode.Scalar(0xFDD3 as UInt32)!
    static let markBelow = Unicode.Scalar(0xFDD4 as UInt32)!

    /// What a folded row's first line ends with, in a note whose session
    /// writes its marks.
    public static let foldedMark = "<!-- folded -->"
    /// What a row shown as the card of its link ends with.
    public static let cardMark = "<!-- card -->"

    /// A note, open for writing. See the top of this file.
    public final class Session {
        public let options: Options
        var frontmatter: Frontmatter?
        /// The line that titles the note, with the blank lines after it —
        /// kept apart only as Weft's sessions keep it.
        var heading: String
        public private(set) var body: Document
        /// What the view shows.
        public private(set) var text: String = ""
        var textBytes: Bytes = []
        /// Each row's block, and where its words are.
        var rows: [RowSpan] = []
        /// The body as it was before each change, newest last, with the
        /// selection there was: what Undo goes back to.
        var undone: [(Document, Range<Int>)] = []
        var redone: [(Document, Range<Int>)] = []
        /// Where the last typing left the caret: typing on from there is
        /// part of the same change.
        var typing: Int? = nil
        /// For a session focused on one row: the rest of the body.
        var outer: Outer? = nil
        /// A row just made a kind by what was typed at its start, with what
        /// was typed and the kind it was: Delete straight after gives the
        /// typed characters back, as Bike's does.
        var typedKind: (Path, String, BlockKind)? = nil
        /// Styles put on — or off — with nothing chosen: what is typed next
        /// at that place takes them.
        var pending: (Int, [Mark])? = nil
        /// Whether the note is shown as prose: a body row made, or put, at the
        /// top level is written as a paragraph rather than as `- `.
        var prose = false
        /// Rows' words, read from their Markdown, by it: most rows are the
        /// same from one change to the next.
        var richCache: [String: Rich] = [:]

        /// Opens a note's file.
        public init(_ source: String, options: Options = .manifold) {
            self.options = options
            let (front, rest) = Frontmatter.split(source)
            frontmatter = front
            let restBytes = rest.u8
            let headingLen = options.keepsTitleApart ? Markup.headingLength(restBytes) : 0
            heading = restBytes.string(0..<headingLen)
            let parsed = Document.parse(restBytes.string(headingLen..<restBytes.count))
            body = options.writesMarks ? Markup.readMarks(parsed) : parsed
            project()
        }

        /// The note's file, as it now is. What was not edited is as it was read.
        public func markdown() -> String {
            let front = frontmatter?.description ?? ""
            let whole = self.whole()
            return front + heading + (options.writesMarks ? Markup.writtenMarks(whole) : whole).toMarkdown()
        }

        // --- Undoing -----------------------------------------------------

        /// Remembers the body as it is, before a change to it.
        func remember(_ selection: Range<Int>) {
            undone.append((body, selection))
            if undone.count > 200 { undone.removeFirst() }
            redone.removeAll()
        }

        public var canUndo: Bool { !undone.isEmpty }
        public var canRedo: Bool { !redone.isEmpty }

        /// Takes the last change back: the tree as it was, structure and all.
        public func undo() -> Change? {
            guard let (body, selection) = undone.popLast() else { return nil }
            return restore(body, selection, redoing: false)
        }

        /// Makes again a change that was undone.
        public func redo() -> Change? {
            guard let (body, selection) = redone.popLast() else { return nil }
            return restore(body, selection, redoing: true)
        }

        func restore(_ restored: Document, _ selection: Range<Int>, redoing: Bool) -> Change? {
            let before = textBytes
            let now = (body, selection)
            body = restored
            if redoing { undone.append(now) } else { redone.append(now) }
            typing = nil
            project()
            let (range, replacement) = Markup.difference(before, textBytes)
            // Back where the change was made — or, made again, just after it.
            let end = range.lowerBound + replacement.utf8.count
            let selection = redoing ? end..<end : Markup.clamp(textBytes, selection)
            return Change(range: range, replacement: replacement, selection: selection)
        }

        // --- The note's own ----------------------------------------------

        public func frontmatterValue() -> Frontmatter? { frontmatter }

        /// Changes the frontmatter, made if the note had none.
        public func changeFrontmatter(_ change: (inout Frontmatter) -> Void) {
            var front = frontmatter ?? Frontmatter()
            change(&front)
            frontmatter = front
        }

        /// Takes the frontmatter away, if nothing is left in it.
        public func dropEmptyFrontmatter() {
            if frontmatter?.isEmpty == true { frontmatter = nil }
        }

        /// The title the note's first heading gives, its markup taken out
        /// (kept apart only by a session that keeps its title apart).
        public func title() -> String? {
            guard let line = heading.u8.lines.first(where: { !$0.isBlankWS }), line.hasPrefix("# ".u8) else { return nil }
            let words = line.sub(from: 2).trimmed
            return words.isEmpty ? nil : Inline.plainText(words.trimmingEnd("#".u8).string)
        }

        /// The words a note with no title could be titled by: its first
        /// line's, if that line is words — not code, not only a picture.
        public func firstLine() -> String? {
            guard let block = body.blocks.first, block.kind != .code, let line = block.text.u8.lines.first else { return nil }
            let words = Inline.plainText(line.trimmed.trimmingEnd("#".u8).trimmed.string)
            return words.isEmpty ? nil : words
        }

        /// Takes the first line out of the body, and gives its words. What
        /// that line held under it moves up into its place; what it went on
        /// to say on later lines stays.
        public func takeFirstLine() -> String? {
            guard let words = firstLine() else { return nil }
            remember(0..<0)
            typing = nil
            let rest = body.blocks[0].text.u8.lines.dropFirst()
            if rest.contains(where: { !$0.isBlankWS }) {
                body.blocks[0].text = rest.map(\.string).joined(separator: "\n")
            } else {
                // Its rows, last first, each put after it at its own level: in their order.
                while !body.blocks[0].children.isEmpty {
                    if Outline.outdent(&body, [0, body.blocks[0].children.count - 1]) == nil { break }
                }
                if body.blocks[0].children.isEmpty { Outline.remove(&body, [0]) } else { body.blocks[0].text = "" }
            }
            project()
            return words
        }

        /// Titles the note: its first heading, made if it had none.
        public func setTitle(_ title: String) {
            let title = title.trimmedWS
            if title.isEmpty { return }
            // The blank lines a file has before its heading are kept.
            let h = heading.u8
            var blank = 0
            while blank < h.count && "\n\r \t".u8.contains(h[blank]) { blank += 1 }
            let before = h.string(0..<blank)
            let rest = h.sub(from: blank)
            if let newline = rest.find(byte: .newline) {
                heading = before + "# " + title + "\n" + rest.string(newline + 1..<rest.count)
            } else if rest.isEmpty {
                heading = before + "# " + title + "\n\n"
            } else {
                heading = before + "# " + title
            }
        }

        // --- Showing -----------------------------------------------------

        func project() {
            rows.removeAll(keepingCapacity: true)
            // A row with nothing left under it has nothing folded.
            func tidy(_ blocks: inout [Block]) {
                for i in blocks.indices {
                    if blocks[i].folded && blocks[i].children.isEmpty { blocks[i].folded = false }
                    if !blocks[i].children.isEmpty { tidy(&blocks[i].children) }
                }
            }
            if body.any({ $0.folded && $0.children.isEmpty }) { tidy(&body.blocks) }
            var out = Bytes()
            out.reserveCapacity(textBytes.count + 64)
            var used: [String: Rich] = [:]
            for (index, path) in Markup.visible(body).enumerated() {
                guard let block = body.get(path) else { continue }
                if index > 0 { out.append(.newline) }
                let start = out.count
                // A row's words as they read: its Markdown never in the view.
                let words = wordsOf(block, &used)
                for b in words.bytes {
                    if b == .newline { out.append(contentsOf: Markup.softBreakBytes) } else { out.append(b) }
                }
                rows.append(RowSpan(path: path, range: start..<out.count))
            }
            richCache = used
            textBytes = out
            text = out.string
        }

        /// A block's words, read once for as long as they stay the same.
        func wordsOf(_ block: Block, _ used: inout [String: Rich]) -> Rich {
            guard Markup.isRich(block) else { return Markup.wordsOf(block) }
            if let rich = used[block.text] ?? richCache[block.text] {
                used[block.text] = rich
                return rich
            }
            let rich = Rich.parse(block.text)
            used[block.text] = rich
            return rich
        }

        func words(_ block: Block) -> Rich {
            if Markup.isRich(block), let rich = richCache[block.text] { return rich }
            return Markup.wordsOf(block)
        }

        /// What the view shows, read for drawing: each line and what it is,
        /// each run and what it means. A line is a row, and its marker is not
        /// in the text: its kind says what to draw beside it.
        public func layout() -> TextLayout {
            var layout = TextLayout()
            layout.lines.reserveCapacity(rows.count)
            for row in rows {
                guard let block = body.get(row.path) else { continue }
                let depth = row.path.count
                let kind: LineKind
                switch block.kind {
                case .item(let item):
                    switch item.marker {
                    case .bullet(let bullet): kind = .item(ordered: nil, task: item.task.map(\.isDone), bullet: bullet)
                    case .ordered(let number, let delimiter): kind = .item(ordered: number, task: item.task.map(\.isDone), bullet: delimiter)
                    }
                // Every row a row, as Bike's: one under a row is a level deeper, whatever it is.
                case .paragraph, .raw: kind = .paragraph
                case .heading(let level): kind = .heading(level)
                case .quote: kind = .quote
                case .code: kind = .code
                case .table: kind = .table
                case .rule: kind = .rule
                }
                if Markup.isRich(block) {
                    Markup.richRuns(words(block), row.range.lowerBound, &layout.runs)
                } else if block.hasInlineContent {
                    Editor.readInline(textBytes, row.range, &layout.runs)
                }
                layout.lines.append(Line(range: row.range, kind: kind, indent: 0, content: row.range.lowerBound, depth: depth))
            }
            return layout
        }

        // --- Writing -----------------------------------------------------

        /// What was typed, pasted or deleted in the view: a range of what it
        /// shows, replaced. The answer is what the view should then do —
        /// which is not always what was typed: `- ` typed at the start of a
        /// line makes it a bullet.
        public func replace(_ range: Range<Int>, _ replacement: String) -> Change {
            var range = Markup.clamp(textBytes, range)
            var replacement = replacement
            // `->` and `<-`, as they are typed, are the arrows they draw.
            if let (arrowRange, arrow) = Markup.arrow(textBytes, range, replacement) { range = arrowRange; replacement = arrow }
            let single = replacement.unicodeScalars.count == 1
            // Typing on from where typing left off is one change to undo.
            let typingOn = range.isEmpty && typing == range.lowerBound && !replacement.unicodeScalars.contains("\n") && replacement != " " && single
            if !typingOn { remember(range) }
            typedKind = nil
            let change = replaceRows(range, replacement)
            typing = single && !replacement.unicodeScalars.contains("\n") && !replacement.unicodeScalars.contains(" ") ? change.selection.upperBound : nil
            return change
        }

        /// Carries out a command. nil when it has nothing to do there, and
        /// the view should do what it would have done.
        public func perform(_ selection: Range<Int>, _ command: Command) -> Change? {
            undoably(selection) { $0.performNow($1, nil, command) }
        }

        /// Carries out a command on some rows of an outline, wherever the
        /// caret is. `rows` counts the rows shown, from the first; each takes
        /// what is under it along. nil for a command done at the caret.
        public func perform(onRows rows: [Int], _ selection: Range<Int>, _ command: Command) -> Change? {
            undoably(selection) { $0.performNow($1, rows, command) }
        }

        /// Makes a change that Undo takes back — if it is one: a change that
        /// answers nil is none.
        func undoably(_ selection: Range<Int>, _ change: (Session, Range<Int>) -> Change?) -> Change? {
            let selection = Markup.clamp(textBytes, selection)
            remember(selection)
            typing = nil
            let made = change(self, selection)
            if made != nil { typedKind = nil } else { undone.removeLast() }
            return made
        }

        func performNow(_ selection: Range<Int>, _ chosenRows: [Int]?, _ command: Command) -> Change? {
            // A paragraph put under another row is written as one of a list,
            // `- `; shown as prose, a body row a command makes or puts at the
            // top level is a paragraph.
            let nests = command == .indent || command == .indentRowOnly || command == .group
            let places: Bool
            switch command {
            case .newline, .deleteBackward, .outdent, .outdentRowOnly, .promoteChildren, .insertBelow, .insertAbove, .turn, .bullet, .numbered,
                 .cycleChecklist, .toggleTask, .toggleCheckbox, .heading:
                places = true
            default:
                places = false
            }
            guard let change = performRows(selection, chosenRows, command) else { return nil }
            if nests || (prose && places) {
                let (first, last) = (rowAt(change.selection.lowerBound), rowAt(change.selection.upperBound))
                let paths = first <= last && last < rows.count ? rows[first...last].map(\.path) : []
                for path in paths {
                    if nests { asItem(path) } else { asParagraph(path) }
                }
            }
            return change
        }

        /// Shows the note as prose, or not. The note is not changed.
        public func setProse(_ prose: Bool) { self.prose = prose }

        /// Whether the note is written as prose: its top level more
        /// paragraphs than list items.
        public var readsAsProse: Bool {
            let top = whole().blocks
            let paragraphs = top.filter { $0.kind == .paragraph }.count
            let items = top.filter(\.isItem).count
            return paragraphs > 0 && paragraphs >= items
        }

        /// A paragraph under another row made a `- ` row.
        func asItem(_ path: Path) {
            let under = path.count > 1 || outer != nil
            body.modify(path) { block in
                guard under && block.kind == .paragraph else { return }
                block.kind = .item(Item(marker: .bullet("-"), task: nil))
                block.layout.spacing = 1
                // A list's rows follow one another: the blank line a paragraph had before it goes.
                block.layout.gap = []
            }
        }

        /// A body row at the top level, written `- `, made a paragraph.
        func asParagraph(_ path: Path) {
            let top = path.count == 1 && outer == nil
            body.modify(path) { block in
                if top && block.isBodyRow && block.isItem { block.kind = .paragraph }
            }
        }

        /// Links the words selected to an address, or points the link they
        /// are the words of there. nil when nothing is selected, the
        /// selection spans rows or lines, or the address is none.
        public func link(_ selection: Range<Int>, _ address: String) -> Change? {
            guard Inline.address(address) != nil else { return nil }
            return undoably(selection) { session, selection in
                let index = session.rowAt(selection.lowerBound)
                guard index < session.rows.count else { return nil }
                let row = session.rows[index]
                guard !selection.isEmpty, selection.upperBound <= row.range.upperBound, let block = session.body.get(row.path), Markup.isRich(block) else { return nil }
                let before = session.textBytes
                let view = session.textBytes.sub(row.range)
                let (a, b) = (Markup.richOffset(view, selection.lowerBound - row.range.lowerBound), Markup.richOffset(view, selection.upperBound - row.range.lowerBound))
                var words = Markup.wordsOf(block)
                if Inline.address(words.bytes.string(a..<b)) != nil { return nil }
                // Brackets and spaces in an address would end its Markdown early.
                words.link(a..<b, Inline.escapedAddress(address))
                session.body.modify(row.path) { Markup.setWords(&$0, words) }
                let caret = Markup.viewOffset(words.bytes, b)
                return session.changed(before, (row.path, caret), nil)
            }
        }

        // --- An outline's rows -------------------------------------------

        /// The row an offset is in.
        func rowAt(_ offset: Int) -> Int {
            var (low, high) = (0, rows.count)
            while low < high {
                let mid = (low + high) / 2
                if rows[mid].range.upperBound < offset { low = mid + 1 } else { high = mid }
            }
            return min(low, max(rows.count - 1, 0))
        }

        func rowOf(_ path: Path) -> RowSpan? { rows.first { $0.path == path } }

        /// Where a place in a block's words is in the view.
        func place(_ path: Path, _ offset: Int) -> Int {
            guard let row = rowOf(path) else { return textBytes.count }
            return min(row.range.lowerBound + offset, row.range.upperBound)
        }

        /// Unfolds whatever a block is folded away under: it is shown.
        func reveal(_ path: Path) {
            guard path.count > 1 else { return }
            for depth in 1..<path.count {
                body.modify(Array(path[..<depth])) { if $0.folded { $0.folded = false } }
            }
        }

        /// After a change to the tree: shows it again, and says how the view
        /// gets from what it showed to what it should. The caret is never
        /// left out of sight.
        func changed(_ before: Bytes, _ caret: (Path, Int), _ anchor: (Path, Int)?) -> Change {
            reveal(caret.0)
            if let anchor { reveal(anchor.0) }
            project()
            let (range, replacement) = Markup.difference(before, textBytes)
            let end = place(caret.0, caret.1)
            let start = anchor.map { place($0.0, $0.1) } ?? end
            return Change(range: range, replacement: replacement, selection: min(start, end)..<max(start, end))
        }

        func viewRow(_ index: Int) -> Bytes { textBytes.sub(rows[index].range) }

        func replaceRows(_ range: Range<Int>, _ replacement: String) -> Change {
            let before = textBytes
            if rows.isEmpty {
                // Nothing written yet: the first words make the first row.
                body.blocks.append(prose ? Block(.paragraph, "") : .bullet(""))
                project()
            }
            let (first, last) = (rowAt(range.lowerBound), rowAt(range.upperBound))
            var path = rows[first].path
            // The range as places in the first and last rows' words.
            let start = Markup.richOffset(viewRow(first), range.lowerBound - rows[first].range.lowerBound)
            let end = Markup.richOffset(viewRow(last), range.upperBound - rows[last].range.lowerBound)
            let firstWords = body.get(path).map(words) ?? Rich()
            var lastWords = body.get(rows[last].path).map(words) ?? Rich()
            let tail = lastWords.splitOff(end)
            // What is typed takes the marks of the words it joins — or those just put on there.
            let pendingMarks = pending.flatMap { $0.0 == range.lowerBound && range.isEmpty ? $0.1 : nil }
            pending = nil
            let within = first == last && start < end
            let marks = pendingMarks ?? (within ? firstWords.marks(over: start..<end) : firstWords.marks(at: start))
            var words = firstWords
            _ = words.splitOff(start)
            let prefix = words.bytes

            // The rows after the first that the range reaches into are joined onto it.
            if last > first {
                for row in (first + 1)...last {
                    let shown = Markup.visible(body)
                    guard let position = shown.firstIndex(of: path), position + 1 < shown.count else { break }
                    let next = shown[position + 1]
                    // A folded row taken whole takes with it what it hid.
                    if row < last { body.modify(next) { if $0.folded { $0.children = [] } } }
                    if Outline.joinOnto(&body, next, path) == nil {
                        // A block that does not join — code, a table — is taken out whole.
                        Outline.remove(&body, next)
                    }
                }
            }

            let splits = body.get(path)?.splits ?? false
            // Inside a block that is one piece, a line break stays inside it.
            func own(_ piece: Bytes) -> Bytes { piece.replacing(Markup.softBreakBytes, with: [.newline]) }
            let replacementBytes = replacement.u8
            let pieces: [Bytes] = splits ? replacementBytes.split(byte: .newline).map(own) : [own(replacementBytes).filter { $0 != UInt8(ascii: "\r") }]
            let rich = body.get(path).map(Markup.isRich) ?? false
            func pieceWords(_ piece: Bytes) -> Rich { rich ? Markup.inserted(piece) : Rich.plain(bytes: piece) }
            let at = words.bytes.count
            words.replace(at..<at, with: pieceWords(pieces[0]), marks: marks)
            var caretWords = words.bytes.count
            if pieces.count == 1 { words.append(tail) }
            let firstSet = words
            body.modify(path) { Markup.setWords(&$0, firstSet) }
            if pieces.count > 1 {
                for index in 1..<pieces.count {
                    let end = body.get(path)?.text.utf8.count ?? 0
                    guard let next = Outline.split(&body, path, end) else { break }
                    var nextWords = pieceWords(pieces[index])
                    caretWords = nextWords.bytes.count
                    if index == pieces.count - 1 { nextWords.append(tail) }
                    let set = nextWords
                    body.modify(next) { Markup.setWords(&$0, set) }
                    path = next
                    words = nextWords
                }
            }
            var caret = (path, Markup.viewOffset(words.bytes, caretWords))

            // A marker typed at a row's start makes the row that kind. What was
            // typed is a step of its own to undo, as is Delete straight after it.
            if replacement == " " && pieces.count == 1 && first == last, let kind = typedMarker(path, prefix) {
                let place = rows[first].range.lowerBound + prefix.count + 1
                let literal = (body, place..<place)
                let was = body.get(path)?.kind
                body.modify(path) { Markup.setWords(&$0, tail) }
                Outline.setKind(&body, path, kind)
                undone.append(literal)
                typedKind = was.map { (path, prefix.string + " ", $0) }
                caret = (path, 0)
            }
            return changed(before, caret, nil)
        }

        /// The kind a row becomes when this was typed at its start, then a space.
        func typedMarker(_ path: Path, _ typed: Bytes) -> BlockKind? {
            guard let block = body.get(path) else { return nil }
            var plainItem = false
            var bullet: Character = "-"
            if case .item(let item) = block.kind, item.task == nil, case .bullet(let b) = item.marker { plainItem = true; bullet = b }
            guard block.kind == .paragraph || plainItem else { return nil }
            func item(_ marker: Marker, _ task: Task?) -> BlockKind { .item(Item(marker: marker, task: task)) }
            // Bike's bulleted row is a `*` item; a `-` item is a body row, drawn with no bullet.
            let bodyRow = plainItem && bullet == "-"
            func numbered(_ typed: Bytes) -> BlockKind? {
                // By characters: what was typed may end in any letter.
                guard let last = typed.scalar(before: typed.count), last == "." || last == ")" else { return nil }
                let digits = typed.sub(0..<(typed.count - 1))
                guard digits.count <= 9, !digits.isEmpty, digits.allSatisfy(\.isAsciiDigit), let number = Int(digits.string) else { return nil }
                return item(.ordered(number: number, delimiter: Character(last)), nil)
            }
            switch typed.string {
            case "-", "*": return !plainItem || bodyRow ? item(.bullet("*"), nil) : numbered(typed)
            case "+": return item(.bullet("+"), .open)
            case "[]", "[ ]", "-[]": return item(.bullet(bullet), .open)
            case "[x]", "[X]": return item(.bullet(bullet), .done("x"))
            case ">": return .quote
            default:
                if !typed.isEmpty && typed.count <= 6 && typed.allSatisfy({ $0 == UInt8(ascii: "#") }) { return .heading(typed.count) }
                return numbered(typed)
            }
        }

        func performRows(_ selection: Range<Int>, _ chosenRows: [Int]?, _ command: Command) -> Change? {
            let atCaret: Bool
            switch command {
            case .newline, .deleteBackward, .toggle: atCaret = true
            default: atCaret = false
            }
            if atCaret && chosenRows != nil { return nil }
            if command == .toggleCard && !options.cards { return nil }
            let before = textBytes
            if rows.isEmpty { return nil }
            if atCaret { return performAtCaret(before, selection, command) }
            if let change = performBeside(before, selection, chosenRows, command) { return change }
            let chosen = self.chosen(selection, chosenRows)
            guard let position = rows.firstIndex(where: { $0.path == chosen.first }) else { return nil }
            mark(selection, chosen)
            let done = rearrange(command)
            let folding: Bool
            switch command {
            case .fold, .toggleFold, .foldCompletely, .foldAll, .foldByLevel, .foldAllByLevel: folding = true
            default: folding = false
            }
            return rearranged(before, done, position, folding)
        }

        /// The commands that put a row beside the rows, join, or group them.
        /// nil for any other command; `.some(nil)` when it had nothing to do.
        func performBeside(_ before: Bytes, _ selection: Range<Int>, _ chosenRows: [Int]?, _ command: Command) -> Change?? {
            let beside: Outline.Beside?
            switch command {
            case .insertBelow: beside = .below
            case .insertAbove: beside = .above
            case .insertChild: beside = .child
            case .joinRows, .group: beside = nil
            default: return nil
            }
            let chosen = self.chosen(selection, chosenRows)
            func done() -> Change? {
                if let beside {
                    // Above the first of them; below, or under, the last.
                    guard let path = beside == .above ? chosen.first : chosen.last else { return nil }
                    guard let new = Outline.insertRow(&body, path, beside) else { return nil }
                    return changed(before, (new, 0), nil)
                }
                if command == .group {
                    guard let new = Outline.group(&body, chosen) else { return nil }
                    return changed(before, (new, 0), nil)
                }
                // Joined: the row the caret is in, and the row shown after it. The caret stays.
                let at = rowAt(selection.lowerBound)
                let path = rows[at].path
                guard at + 1 < rows.count else { return nil }
                let next = rows[at + 1].path
                let caret = selection.lowerBound - rows[at].range.lowerBound
                guard let this = body.get(path), let that = body.get(next) else { return nil }
                var words = Markup.wordsOf(this)
                let nextWords = Markup.wordsOf(that)
                guard let (onto, _) = Outline.joinNext(&body, path, next) else { return nil }
                // The words joined as words: a space between, unless either has none to need.
                if !words.bytes.isEmpty && !nextWords.bytes.isEmpty && !(words.bytes.scalar(before: words.bytes.count)?.isWS ?? false) && !(nextWords.bytes.scalar(at: 0)?.isWS ?? false) {
                    let at = words.bytes.count
                    words.replace(at..<at, with: .plain(" "), marks: [])
                }
                words.append(nextWords)
                let joined = words
                guard body.modify(onto, { Markup.setWords(&$0, joined) }) != nil else { return nil }
                return changed(before, (onto, caret), nil)
            }
            return .some(done())
        }

        /// The commands given where the caret is.
        func performAtCaret(_ before: Bytes, _ selection: Range<Int>, _ command: Command) -> Change? {
            let collapsed = selection.isEmpty
            let first = rowAt(selection.lowerBound)
            let start = (rows[first].path, selection.lowerBound - rows[first].range.lowerBound)
            let endRow = rowAt(selection.upperBound)
            let end = (rows[endRow].path, selection.upperBound - rows[endRow].range.lowerBound)
            let path = start.0
            guard let block = body.get(path) else { return nil }
            let kind = block.kind
            switch command {
            case .newline:
                if !collapsed { return replaceRows(selection, "\n") }
                if !block.splits {
                    // Return on a block of code's empty last line: out of the block, into a
                    // row after it — the empty line gone, as Bike's code rows are left.
                    let offset = Markup.richOffset(viewRow(first), start.1)
                    var code = Markup.wordsOf(block)
                    if kind == .code && offset == code.bytes.count && code.bytes.last == .newline {
                        let end = code.bytes.count
                        code.replace((end - 1)..<end, with: .plain(""), marks: nil)
                        let set = code
                        body.modify(path) { Markup.setWords(&$0, set) }
                        guard let index = path.last else { return nil }
                        let next = Array(path.dropLast()) + [index + 1]
                        guard Outline.insert(&body, next, Block(.item(Item(marker: .bullet("-"), task: nil)), "")) != nil else { return nil }
                        return changed(before, (next, 0), nil)
                    }
                    // In code, a line of the same block.
                    return replaceRows(selection, "\u{2028}")
                }
                // Return on a typed row with nothing in it — a task, a number, a
                // quote, a heading — makes it a plain row, where it is. On a plain
                // one it is a new row, as anywhere: never out a level.
                var typed = false
                switch kind {
                case .item(let item):
                    if item.task != nil { typed = true } else if case .bullet(let b) = item.marker { typed = b != "-" } else { typed = true }
                case .quote, .heading: typed = true
                default: typed = false
                }
                if block.text.isEmpty && typed {
                    let plain: BlockKind = block.isItem || path.count > 1 ? .item(Item(marker: .bullet("-"), task: nil)) : .paragraph
                    Outline.setKind(&body, path, plain)
                    body.modifySiblings(path) { Outline.renumber(&$0) }
                    return changed(before, (path, 0), nil)
                }
                let words = Markup.wordsOf(block)
                let offset = Markup.richOffset(viewRow(first), start.1)
                let atEnd = offset == words.bytes.count
                // Return after a fence — ``` or ```rust — and nothing else: the row
                // is a code block, and the caret is on the line between its fences.
                var isParagraphOrItem = false
                if case .item = kind { isParagraphOrItem = true } else if kind == .paragraph { isParagraphOrItem = true }
                let fenced = atEnd && block.children.isEmpty && isParagraphOrItem && words.bytes.hasPrefix("```".u8)
                    && !words.bytes.sub(from: 3).contains(UInt8(ascii: "`")) && !words.bytes.sub(from: 3).contains(.newline)
                if fenced {
                    let fence = words.bytes
                    let close = String(repeating: "`", count: fence.leading(UInt8(ascii: "`")))
                    Outline.setKind(&body, path, .code)
                    body.modify(path) { $0.text = fence.string + "\n" + close }
                    return changed(before, (path, 0), nil)
                }
                if offset == 0 && !atEnd {
                    // At a row's start: an empty row above it, and the caret stays with the words.
                    guard let below = Outline.openAbove(&body, path) else { return nil }
                    return changed(before, (below, 0), nil)
                }
                // The words split as words: the first half stays, the second goes to the new row.
                var head = words
                let tail = head.splitOff(offset)
                let headSet = head
                body.modify(path) { Markup.setWords(&$0, headSet) }
                let endOffset = body.get(path)?.text.utf8.count ?? 0
                guard let next = Outline.split(&body, path, endOffset) else { return nil }
                body.modify(next) { Markup.setWords(&$0, tail) }
                return changed(before, (next, 0), nil)

            case .deleteBackward:
                if !collapsed { return nil }
                // Inside a row, the view's own: a picture is one character, and goes whole.
                if start.1 != 0 { return nil }
                // Straight after a kind was made by typing: what was typed, back as words.
                if let (typedPath, typed, was) = typedKind, typedPath == path {
                    typedKind = nil
                    Outline.setKind(&body, typedPath, was)
                    guard let block = body.get(typedPath) else { return nil }
                    var words = Markup.wordsOf(block)
                    words.replace(0..<0, with: .plain(typed), marks: [])
                    let set = words
                    body.modify(typedPath) { Markup.setWords(&$0, set) }
                    return changed(before, (typedPath, typed.utf8.count), nil)
                }
                typedKind = nil
                var item: Item? = nil
                if case .item(let i) = kind { item = i }
                var bulleted = false
                if let item, item.task == nil, case .bullet(let b) = item.marker, b != "-" { bulleted = true }
                var ordered = false
                if let item, case .ordered = item.marker { ordered = true }
                if bulleted {
                    // A bulleted row: a body row again.
                    Outline.setKind(&body, path, .item(Item(marker: .bullet("-"), task: nil)))
                    return changed(before, (path, 0), nil)
                } else if kind == .code {
                    // A code block with nothing in it, back to the fence it was typed as.
                    let lines = block.text.u8.lines
                    let empty = lines.count >= 2 && Markup.isFence(lines[lines.count - 1]) && lines[1..<(lines.count - 1)].allSatisfy(\.isBlankWS)
                    if !empty || !Markup.isFence(lines[0]) { return nil }
                    let fence = lines[0].trimmed
                    body.modify(path) { $0.text = fence.string }
                    Outline.setKind(&body, path, .item(Item(marker: .bullet("-"), task: nil)))
                    return changed(before, (path, fence.count), nil)
                } else if let item, item.task != nil {
                    // First its checkbox — a body row then, as Bike's — then what makes it more than a line…
                    var marker = item.marker
                    if case .bullet = marker { marker = .bullet("-") }
                    Outline.setKind(&body, path, .item(Item(marker: marker, task: nil)))
                } else if kind == .quote || ordered || { if case .heading = kind { return true }; return false }() {
                    Outline.setKind(&body, path, .paragraph)
                } else {
                    // …then it joins the row shown before it. Onto a block of code, its
                    // words go on the code's last line, inside the fence.
                    guard first >= 1 else { return nil }
                    let onto = rows[first - 1].path
                    let ontoWords = body.get(onto).map(Markup.wordsOf) ?? Rich()
                    let rowWords = Markup.wordsOf(block)
                    if body.get(onto)?.kind == .code {
                        if !block.children.isEmpty { return nil }
                        var code = ontoWords
                        let offset = Markup.viewOffset(code.bytes, code.bytes.count)
                        code.append(rowWords)
                        guard Outline.remove(&body, path) != nil else { return nil }
                        let set = code
                        body.modify(onto) { Markup.setWords(&$0, set) }
                        return changed(before, (onto, offset), nil)
                    }
                    guard let (joinedPath, _) = Outline.joinOnto(&body, path, onto) else { return nil }
                    // The words joined as words, the caret where they meet.
                    var joined = ontoWords
                    let offset = Markup.viewOffset(joined.bytes, joined.bytes.count)
                    joined.append(rowWords)
                    let set = joined
                    body.modify(joinedPath) { Markup.setWords(&$0, set) }
                    return changed(before, (joinedPath, offset), nil)
                }
                return changed(before, (path, 0), nil)

            case .toggle(let style):
                guard first == endRow, Markup.isRich(block) else { return nil }
                let view = viewRow(first)
                let (a, b) = (Markup.richOffset(view, start.1), Markup.richOffset(view, end.1))
                let mark: Mark
                switch style {
                case .strong: mark = .strong
                case .emphasis: mark = .emphasis("*")
                case .strikethrough: mark = .strikethrough
                case .highlight: mark = .highlight
                case .code: mark = .code(1)
                }
                var words = Markup.wordsOf(block)
                if a == b {
                    // Nothing chosen: what is typed next here takes the style on, or off.
                    var marks = pending.flatMap { $0.0 == selection.lowerBound ? $0.1 : nil } ?? words.marks(at: a)
                    if let at = marks.firstIndex(where: { $0.sameKind(mark) }) { marks.remove(at: at) } else { marks.append(mark) }
                    pending = (selection.lowerBound, marks)
                    return Change(range: selection.lowerBound..<selection.lowerBound, replacement: "", selection: selection)
                }
                words.toggle(a..<b, mark)
                let set = words
                body.modify(path) { Markup.setWords(&$0, set) }
                return changed(before, (path, Markup.viewOffset(words.bytes, b)), (path, Markup.viewOffset(words.bytes, a)))

            default:
                return nil
            }
        }

        // --- Rows rearranged ---------------------------------------------
        //
        // A command done to rows moves blocks about the tree, and every move
        // changes the paths of others. So nothing is followed by its path:
        // the rows chosen, and the places of the selection's ends, are marked
        // in the blocks' own words — with characters no text has — and found
        // again by those marks when the tree has settled.

        /// The rows a command is for — those given, or those the selection
        /// touches — without any that is under another of them.
        func chosen(_ selection: Range<Int>, _ given: [Int]?) -> [Path] {
            var indexes: [Int]
            if let given {
                indexes = Array(Set(given.filter { $0 >= 0 && $0 < rows.count })).sorted()
            } else {
                let first = rowAt(selection.lowerBound)
                var last = rowAt(selection.upperBound)
                // A selection ending at a row's very start does not take that row.
                if last > first && rows[last].range.lowerBound == selection.upperBound { last -= 1 }
                indexes = Array(first...last)
            }
            var chosen: [Path] = []
            for index in indexes {
                let path = rows[index].path
                if !chosen.contains(where: { path.starts(with: $0) }) { chosen.append(path) }
            }
            return chosen
        }

        /// Marks the selection's ends, and the rows chosen.
        func mark(_ selection: Range<Int>, _ chosen: [Path]) {
            // The end first: a mark put in before it would move it.
            for (offset, mark) in [(selection.upperBound, Markup.markCaret), (selection.lowerBound, Markup.markAnchor)] {
                let index = rowAt(offset)
                guard index < rows.count else { continue }
                let row = rows[index]
                let view = textBytes.sub(row.range)
                body.modify(row.path) { block in
                    // Into the Markdown where the place is, so a row only moved is written as it was.
                    let at = Markup.markdownAt(block, Markup.richOffset(view, offset - row.range.lowerBound))
                    var text = block.text.u8
                    text.insert(contentsOf: String(mark).u8, at: min(at, text.count))
                    block.text = text.string
                }
            }
            for path in chosen { body.modify(path) { $0.text = String(Markup.markChosen) + $0.text } }
        }

        /// The first of the rows chosen that is still to be dealt with — or
        /// the last — its mark taken off.
        func nextChosen(_ last: Bool) -> Path? {
            guard let path = Markup.marked(body, Markup.markChosen, last) else { return nil }
            _ = Markup.unmark(&body, path, Markup.markChosen)
            return path
        }

        /// Where a mark is, taken out: its block, and the place in its words.
        func takeMark(_ mark: Unicode.Scalar) -> (Path, Int)? {
            guard let path = Markup.marked(body, mark, false), let at = Markup.unmark(&body, path, mark) else { return nil }
            return (path, at)
        }

        /// Does to each chosen row what a command says. false when there was
        /// nothing to do.
        func rearrange(_ command: Command) -> Bool {
            var any = false
            switch command {
            case .indent, .outdent, .moveUp, .moveDown, .moveUpKeepingLevel, .moveDownKeepingLevel, .indentRowOnly, .outdentRowOnly,
                 .promoteChildren, .demoteSiblings, .moveUpRowOnly, .moveDownRowOnly:
                // Moved down, the last goes first, so each has room. Outdented,
                // too: each goes just after the parent, so the last goes first.
                let down = command == .moveDown || command == .moveDownKeepingLevel || command == .moveDownRowOnly || command == .outdent
                while let at = nextChosen(down) {
                    var moved: Path?
                    switch command {
                    case .indent:
                        moved = Outline.indent(&body, at)
                        // Under a folded row it would go out of sight: that row is unfolded.
                        if let to = moved { body.modify(Array(to.dropLast())) { $0.folded = false } }
                    case .outdent:
                        moved = Outline.outdent(&body, at)
                    case .outdentRowOnly:
                        // What followed it comes under it — and is not to go out of sight there.
                        let over = body.get(Array(at.dropLast()))
                        let followed = over.map { at[at.count - 1] + 1 < $0.children.count } ?? false
                        moved = Outline.outdentTakingFollowers(&body, at)
                        if let to = moved, followed { body.modify(to) { if $0.canHaveChildren { $0.folded = false } } }
                    case .indentRowOnly:
                        // Under the row before, and its own children left at the level they were.
                        moved = Outline.indent(&body, at)
                        if let to = moved {
                            body.modify(Array(to.dropLast())) { $0.folded = false }
                            Outline.promoteChildren(&body, to)
                        }
                    case .moveUp:
                        moved = Outline.moveUpShown(&body, at, Markup.visible(body))
                    case .moveDown:
                        moved = Outline.moveDownShown(&body, at, Markup.visible(body))
                    case .moveUpKeepingLevel:
                        moved = Outline.moveUp(&body, at)
                    case .moveDownKeepingLevel:
                        moved = Outline.moveDownKeepingLevel(&body, at, Markup.visible(body))
                    case .promoteChildren:
                        moved = Outline.promoteChildren(&body, at)
                    case .moveUpRowOnly:
                        moved = Outline.moveRowAlone(&body, at, up: true)
                    case .moveDownRowOnly:
                        moved = Outline.moveRowAlone(&body, at, up: false)
                    case .demoteSiblings:
                        moved = Outline.demoteSiblings(&body, at)
                    default:
                        moved = Outline.moveDown(&body, at)
                    }
                    if moved != nil {
                        any = true
                    } else if !any {
                        // The first could not go: none of them does.
                        return false
                    } else {
                        break
                    }
                }
            case .moveToTop, .moveToBottom:
                // To the top, the last goes first: the others come to stand above it, in their order.
                let up = command == .moveToTop
                while var at = nextChosen(up) {
                    while let to = up ? Outline.moveUp(&body, at) : Outline.moveDown(&body, at) {
                        at = to
                        any = true
                    }
                }
            case .deleteRows:
                while let at = nextChosen(true) { if Outline.remove(&body, at) != nil { any = true } }
            case .deleteRowOnly:
                while let at = nextChosen(true) { if Outline.removeRowOnly(&body, at) != nil { any = true } }
            case .duplicateRows:
                while let at = nextChosen(true) {
                    if Outline.duplicate(&body, at) != nil { any = true }
                    // The selection goes with the copy.
                    body.modify(at) { original in
                        var one = [original]
                        Markup.unmarkAll(&one, [Markup.markAnchor, Markup.markCaret])
                        original = one[0]
                    }
                }
            case .cycleChecklist, .toggleTask, .toggleCheckbox, .markDone, .heading, .bullet, .numbered, .quote, .turn:
                while let at = nextChosen(false) {
                    guard let kind = body.get(at)?.kind, let next = Markup.turned(kind, command) else { continue }
                    var numbered = false
                    if case .item(let item) = next, case .ordered = item.marker { numbered = true }
                    Outline.setKind(&body, at, next)
                    // A row made a numbered one takes the number its place gives it.
                    if numbered { body.modifySiblings(at) { Outline.renumber(&$0) } }
                    any = true
                }
            case .fold, .unfold, .toggleFold, .foldCompletely, .unfoldCompletely:
                while let at = nextChosen(false) {
                    let changedFold = body.modify(at) { block -> Bool in
                        switch command {
                        case .fold: return Markup.setFold(&block, true)
                        case .unfold: return Markup.setFold(&block, false)
                        case .toggleFold: return Markup.setFold(&block, !block.folded)
                        case .foldCompletely: var one = [block]; let c = Markup.foldAll(&one, true); block = one[0]; return c
                        default: var one = [block]; let c = Markup.foldAll(&one, false); block = one[0]; return c
                        }
                    } ?? false
                    any = any || changedFold
                }
            case .toggleCard:
                // One way for all of them: as cards, unless every one is one already.
                var chosen: [Path] = []
                while let at = nextChosen(false) { chosen.append(at) }
                let on = !chosen.allSatisfy { body.get($0)?.card == true }
                for at in chosen {
                    body.modify(at) { block in
                        guard block.canHaveChildren else { return }
                        if block.card != on { any = true }
                        block.card = on
                    }
                }
            case .foldByLevel, .unfoldByLevel:
                while let at = nextChosen(false) {
                    let c = body.modify(at) { block -> Bool in
                        var one = [block]
                        let c = command == .foldByLevel ? Markup.foldByLevel(&one) : Markup.unfoldByLevel(&one)
                        block = one[0]
                        return c
                    } ?? false
                    any = any || c
                }
            case .foldAllByLevel: any = Markup.foldByLevel(&body.blocks)
            case .unfoldAllByLevel: any = Markup.unfoldByLevel(&body.blocks)
            case .foldAll: any = Markup.foldAll(&body.blocks, true)
            case .unfoldAll: any = Markup.foldAll(&body.blocks, false)
            case .moveDoneToBottom:
                while let at = nextChosen(false) {
                    let c = body.modify(at) { Markup.sinkDone(&$0.children) } ?? false
                    any = any || c
                }
            case .newline, .deleteBackward, .toggle, .insertBelow, .insertAbove, .insertChild, .joinRows, .group:
                break
            }
            return any
        }

        /// After rows were rearranged — or were not: takes the marks out,
        /// shows the tree again, and says how the view gets there. `position`
        /// is the first chosen row's, where the caret goes if its own row is
        /// gone. A caret that a fold put out of sight goes to the row that was
        /// folding; put out of sight any other way, it is shown again.
        func rearranged(_ before: Bytes, _ done: Bool, _ position: Int, _ folding: Bool) -> Change? {
            Markup.unmarkAll(&body.blocks, [Markup.markChosen, Markup.markAbove, Markup.markBelow])
            let (anchor, caret) = (takeMark(Markup.markAnchor), takeMark(Markup.markCaret))
            guard done else { return nil }
            // Left as it was: nothing was done.
            if let last = undone.last, last.0 == body { return nil }
            func shown(_ place: (Path, Int)?) -> (Path, Int)? {
                guard let (path, offset) = place else { return nil }
                var fold: Int? = nil
                if path.count > 1 {
                    for depth in 1..<path.count where body.get(Array(path[..<depth]))?.folded == true { fold = depth; break }
                }
                if let fold, folding { return (Array(path[..<fold]), 0) }
                reveal(path)
                guard let block = body.get(path) else { return nil }
                return (path, Markup.shownIn(block, offset))
            }
            let (a, c) = (shown(anchor), shown(caret))
            project()
            let (range, replacement) = Markup.difference(before, textBytes)
            let gone = rows.isEmpty ? 0 : rows[min(position, rows.count - 1)].range.lowerBound
            let end = c.map { place($0.0, $0.1) } ?? gone
            let start = a.map { place($0.0, $0.1) } ?? end
            return Change(range: range, replacement: replacement, selection: min(start, end)..<max(start, end))
        }

        // --- Rows carried ------------------------------------------------

        /// Where rows carried would go, put down before a row: the row shown
        /// above that place and the one below it — the rows carried passed
        /// over — and how deep, held to what can be there.
        func dropPlace(_ chosen: [Path], _ before: Int, _ depth: Int) -> (Path?, Path?, Int)? {
            let before = min(before, rows.count)
            // Among the rows under one carried: nowhere to go.
            if before < rows.count, chosen.contains(where: { rows[before].path.count > $0.count && rows[before].path.starts(with: $0) }) { return nil }
            func stays(_ row: RowSpan) -> Bool { !chosen.contains { row.path.starts(with: $0) } }
            let above = rows[..<before].last(where: stays)?.path
            let below = rows[before...].first(where: stays)?.path
            let deepest = above.map { path -> Int in
                let holds = body.get(path).map { $0.canHaveChildren && !$0.folded } ?? false
                return path.count - 1 + (holds ? 1 : 0)
            } ?? 0
            let shallowest = min(below.map { $0.count - 1 } ?? 0, deepest)
            return (above, below, min(max(depth, shallowest), deepest))
        }

        /// How deep rows carried would lie, put down before a row at a depth
        /// asked for. nil where they cannot be put down.
        public func dropDepth(_ rows: [Int], _ before: Int, _ depth: Int) -> Int? {
            if self.rows.isEmpty { return nil }
            return dropPlace(chosen(0..<0, rows), before, depth)?.2
        }

        /// Where a row put down after `above` at a depth goes.
        func dropAt(_ above: Path?, _ below: Path?, _ depth: Int) -> Path? {
            guard let above else { return [0] }
            if depth == above.count {
                // Under the row above: before its first row, or its only one.
                var first: Int? = nil
                if let below, below.count == above.count + 1, below.starts(with: above) { first = below[above.count] }
                return above + [first ?? (body.get(above)?.children.count ?? 0)]
            }
            // After the row above, or after one it is under.
            var after = Array(above[...min(depth, above.count - 1)])
            after[after.count - 1] += 1
            return after
        }

        /// Puts rows of an outline, with what is under them, before another
        /// row — one past the last is the end — at a depth: what carrying a
        /// row and letting go does. nil when that is where the rows already
        /// are, or among the rows under one of them.
        public func moveRows(_ rows: [Int], _ before: Int, _ depth: Int, _ selection: Range<Int>) -> Change? {
            undoably(selection) { session, selection in
                if session.rows.isEmpty { return nil }
                let beforeText = session.textBytes
                let chosen = session.chosen(selection, rows)
                guard let position = session.rows.firstIndex(where: { $0.path == chosen.first }) else { return nil }
                guard let (above, below, depth) = session.dropPlace(chosen, before, depth) else { return nil }
                session.mark(selection, chosen)
                for (path, mark) in [(above, Markup.markAbove), (below, Markup.markBelow)] {
                    if let path { session.body.modify(path) { $0.text += String(mark) } }
                }
                // Taken out, the last first; the blank lines before each stay with the place.
                var carried: [Block] = []
                while let at = session.nextChosen(true) {
                    guard var block = Outline.remove(&session.body, at) else { continue }
                    let gap = block.layout.gap
                    session.body.modify(at) { follower in if follower.layout.gap.isEmpty { follower.layout.gap = gap } }
                    block.layout.gap = []
                    carried.insert(block, at: 0)
                }
                let (newAbove, newBelow) = (Markup.marked(session.body, Markup.markAbove, false), Markup.marked(session.body, Markup.markBelow, false))
                guard var at = session.dropAt(newAbove, newBelow, depth) else { return nil }
                for (index, original) in carried.enumerated() {
                    var block = original
                    // At another depth, it is set in as that depth asks, and no further.
                    if (index < chosen.count ? chosen[index].count : 0) != at.count { block.layout.extraIndent = 0 }
                    // Those where they go keep the blank lines before them, above.
                    if index == 0, let follower = session.body.get(at) {
                        block.layout.gap = follower.layout.gap
                        session.body.modify(at) { $0.layout.gap = [] }
                    }
                    Outline.insert(&session.body, at, block)
                    at[at.count - 1] += 1
                }
                return session.rearranged(beforeText, true, position, false)
            }
        }

        /// Puts rows written as Markdown — carried from another note — before
        /// a row, at a depth. A row that brings a name a row here already has
        /// comes without it. The caret is put at the first of them.
        public func insertRows(_ markdown: String, _ before: Int, _ depth: Int, _ selection: Range<Int>) -> Change? {
            undoably(selection) { session, _ in
                let parsed = Document.parse(markdown)
                var carried = (session.options.writesMarks ? Markup.readMarks(parsed) : parsed).blocks
                if carried.isEmpty { return nil }
                let taken = Set(session.whole().walk.compactMap(\.anchor))
                func unname(_ block: inout Block) {
                    if let name = block.anchor, taken.contains(name) { block.anchor = nil }
                    for i in block.children.indices { unname(&block.children[i]) }
                }
                for i in carried.indices { unname(&carried[i]) }
                let beforeText = session.textBytes
                guard let (above, below, depth) = session.dropPlace([], before, depth) else { return nil }
                guard var at = session.dropAt(above, below, depth) else { return nil }
                let first = at
                for (index, original) in carried.enumerated() {
                    var block = original
                    block.layout.extraIndent = 0
                    block.layout.gap = []
                    if index == 0, let follower = session.body.get(at) {
                        block.layout.gap = follower.layout.gap
                        session.body.modify(at) { $0.layout.gap = [] }
                    }
                    guard Outline.insert(&session.body, at, block) != nil else { return nil }
                    at[at.count - 1] += 1
                }
                session.project()
                let (range, replacement) = Markup.difference(beforeText, session.textBytes)
                let caret = session.place(first, 0)
                return Change(range: range, replacement: replacement, selection: caret..<caret)
            }
        }

        // --- What a view asks of rows ------------------------------------

        /// For each row shown: whether it is folded, and whether it has rows
        /// under it — shown or not.
        public func rowFolds() -> [(Bool, Bool)] {
            rows.map { row in
                guard let block = body.get(row.path) else { return (false, false) }
                return (block.folded && !block.children.isEmpty, !block.children.isEmpty)
            }
        }

        /// Of each row shown, whether it is shown as the card of its link.
        public func rowCards() -> [Bool] { rows.map { body.get($0.path)?.card == true } }

        /// What can be done to a row shown: what a menu for it offers.
        public func rowInfo(_ row: Int) -> RowInfo? {
            guard row >= 0, row < rows.count else { return nil }
            let path = rows[row].path
            guard let block = body.get(path), let index = path.last else { return nil }
            let siblings = path.count == 1 ? body.blocks.count : (body.get(Array(path.dropLast()))?.children.count ?? 0)
            let under = Array(block.walk.dropFirst())
            let folded = block.folded && !block.children.isEmpty
            var plainBullet = false
            if case .item(let item) = block.kind, item.task == nil, case .bullet = item.marker { plainBullet = true }
            var children = block.children
            var info = RowInfo()
            info.folded = folded
            info.hasChildren = !block.children.isEmpty
            info.hidden = folded ? under.count : 0
            info.shown = rows[(row + 1)...].prefix(while: { $0.path.starts(with: path) }).count
            info.foldsInside = under.contains { $0.folded && !$0.children.isEmpty }
            info.openInside = !folded && under.contains { !$0.folded && !$0.children.isEmpty }
            info.task = block.taskState?.isDone
            info.hasChecklist = plainBullet && under.contains { $0.taskState != nil }
            info.doneToMove = Markup.sinkDone(&children)
            info.canMoveUp = index > 0
            info.canMoveDown = index + 1 < siblings
            return info
        }

        /// A row's own Markdown: its words as the note has them.
        public func rowMarkdown(_ row: Int) -> String? {
            guard row >= 0, row < rows.count else { return nil }
            return body.get(rows[row].path)?.text
        }

        /// What words chosen in the view are, as Markdown: what copying them
        /// gives. Rows' words, each row on a line of its own.
        public func markdownBetween(_ range: Range<Int>) -> String {
            if rows.isEmpty { return "" }
            let range = Markup.clamp(textBytes, range)
            let (first, last) = (rowAt(range.lowerBound), rowAt(range.upperBound))
            var lines: [String] = []
            for index in first...last {
                let row = rows[index]
                guard let block = body.get(row.path) else { continue }
                let view = textBytes.sub(row.range)
                let a = index == first ? Markup.richOffset(view, max(range.lowerBound - row.range.lowerBound, 0)) : 0
                let b0 = index == last ? Markup.richOffset(view, max(range.upperBound - row.range.lowerBound, 0)) : Int.max
                var words = Markup.wordsOf(block)
                let b = min(b0, words.bytes.count)
                _ = words.splitOff(b)
                let piece = words.splitOff(min(a, b))
                lines.append(Markup.isRich(block) ? piece.markdown(guarded: false) : piece.text)
            }
            return lines.joined(separator: "\n")
        }

        /// Some rows shown, with what is under them, as Markdown of their own.
        public func markdownOf(_ rows: [Int]) -> String {
            var blocks = chosen(0..<0, rows).compactMap { body.get($0) }
            for i in blocks.indices { blocks[i].layout.extraIndent = 0 }
            if !blocks.isEmpty { blocks[0].layout.gap = [] }
            return Document(blocks: blocks, finalNewline: true, lineEnding: body.lineEnding).toMarkdown()
        }

        // --- Focus ---------------------------------------------------------
        //
        // A session can be focused on one row of the outline: it then shows,
        // and edits, only the rows under that row — as a note of their own.
        // The rest of the note is kept aside, untouched, and `markdown()` is
        // the whole file all the same. Weft's sessions focus on a row by its
        // name, written in the note; Manifold's by its place, in memory.

        /// The whole body: what is shown, and — focused — what is not.
        func whole() -> Document {
            guard let outer else { return body }
            var whole = outer.whole
            let blocks = body.blocks
            whole.modify(outer.root) { root in
                root.children = blocks
                // The empty row a focus on a row with nothing under it is given to write in.
                if root.children.count == 1, let only = root.children.first, only.text.isEmpty && only.children.isEmpty && only.anchor == nil {
                    root.children = []
                }
            }
            return whole
        }

        /// The name of a row shown, given one now if it had none.
        public func anchorRow(_ row: Int) -> String? {
            guard row >= 0, row < rows.count else { return nil }
            return anchorAt(rows[row].path, shown: true)
        }

        func anchorAt(_ path: Path, shown: Bool) -> String? {
            let name = Markup.newAnchor(whole())
            func give(_ block: inout Block) -> String? {
                guard block.canHaveChildren else { return nil }
                if block.anchor == nil { block.anchor = name }
                return block.anchor
            }
            if shown { return body.modify(path, give) ?? nil }
            guard outer != nil else { return nil }
            return outer!.whole.modify(path, give) ?? nil
        }

        /// The name of the row focused on, if the session is focused.
        public var focus: String? { outer.flatMap { $0.whole.get($0.root)?.anchor } }

        /// Whether a row is focused on.
        public var isFocused: Bool { outer != nil }

        /// Where the row focused on is, in the whole body.
        public var focusRoot: Path? { outer?.root }

        /// The whole body again, if focused.
        func unfocus() {
            if let outer {
                let whole = self.whole()
                self.outer = nil
                body = whole
                _ = outer
            }
            undone.removeAll()
            redone.removeAll()
            typing = nil
        }

        /// Focuses on the row of a name — or, given none, the whole note
        /// again. Says whether there was such a row.
        public func setFocus(_ name: String?) -> Bool {
            unfocus()
            var found = true
            if let name { found = Markup.anchored(body, name).map { focusAt($0) } ?? false }
            project()
            return found
        }

        /// Focuses on the row at a place in the whole body — or, given none,
        /// the whole note again: Manifold's focus, kept in memory. Says
        /// whether there was such a row.
        public func setFocus(path: Path?) -> Bool {
            unfocus()
            var found = true
            if let path { found = focusAt(path) }
            project()
            return found
        }

        /// Focuses on the block at a path of the whole body.
        func focusAt(_ root: Path) -> Bool {
            guard !root.isEmpty, let block = body.get(root) else { return false }
            var under = block.children
            if under.isEmpty { under.append(.bullet("")) }
            body.modify(root) { $0.children = [] }
            let shown = Document(blocks: under, finalNewline: true, lineEnding: body.lineEnding)
            outer = Outer(whole: body, root: root)
            body = shown
            return true
        }

        /// Focuses where a page is spoken of: on the first row that links to
        /// it by any of `names`, the smallest subtree that holds it.
        public func focusOnLinks(_ names: [String]) -> Bool {
            let keys = names.map(Markup.nameKey).filter { !$0.isEmpty }
            return focusWhere { session in
                guard let found = session.body.rows().first(where: { $0.block.canHaveChildren && Markup.linksTo($0.block.text, keys) })?.path else { return nil }
                return session.subtreeAround(found)
            }
        }

        /// The smallest subtree holding a row that has rows under it.
        func subtreeAround(_ start: Path) -> Path? {
            var path = start
            while !path.isEmpty && !(body.get(path).map { $0.canHaveChildren && !$0.children.isEmpty } ?? false) { path.removeLast() }
            return path.isEmpty ? nil : path
        }

        /// Focuses on the smallest list item that holds every place any of
        /// `words` is said, case aside.
        public func focusOnWords(_ words: [String]) -> Bool {
            let words = words.map { $0.lowercased() }.filter { !$0.isEmpty }
            return focusWhere { session in
                let found = session.body.rows().filter { Markup.says($0.block.text, words) }.map(\.path)
                guard var common = found.first else { return nil }
                for path in found.dropFirst() {
                    let same = zip(common, path).prefix(while: { $0 == $1 }).count
                    common = Array(common.prefix(same))
                }
                return session.subtreeAround(common)
            }
        }

        func focusWhere(_ find: (Session) -> Path?) -> Bool {
            _ = setFocus(nil as String?)
            guard let root = find(self) else { return false }
            let found = focusAt(root)
            project()
            return found
        }

        /// The words of the row focused on, as written.
        public var focusTitle: String? { outer.flatMap { $0.whole.get($0.root)?.text } }

        /// The row focused on as it reads, its Markdown taken out.
        public var focusLabel: String? { focusTitle.map(Inline.plainText) }

        /// Writes the row focused on anew: its words, on one line.
        public func setFocusTitle(_ title: String) {
            guard outer != nil else { return }
            let root = outer!.root
            outer!.whole.modify(root) { $0.text = title.wordsWS.joined(separator: " ") }
        }

        /// The rows the row focused on is under, outermost first, each as it reads.
        public var focusTrail: [String] {
            guard let outer, outer.root.count > 1 else { return [] }
            return (1..<outer.root.count).compactMap { outer.whole.get(Array(outer.root[..<$0])) }.map { Inline.plainText($0.text) }
        }

        /// The name of a row the row focused on is under — `levels` 1 the one
        /// right over it — given one now if it had none. nil when that far out
        /// is the whole note.
        public func focusOut(_ levels: Int) -> String? {
            guard let path = focusOutPath(levels) else { return nil }
            return anchorAt(path, shown: false)
        }

        /// Where the row `levels` over the one focused on is; nil when that far
        /// out is the whole note, or nothing is focused.
        public func focusOutPath(_ levels: Int) -> Path? {
            guard let root = outer?.root, levels >= 1 else { return nil }
            let depth = root.count - levels
            return depth >= 1 ? Array(root[..<depth]) : nil
        }

        // --- Folds -------------------------------------------------------

        /// The rows folded: each by its place among all the body's rows —
        /// shown or not — and its words.
        public func foldedRows() -> [FoldedRow] {
            if !body.any({ $0.folded && !$0.children.isEmpty }) { return [] }
            return body.rows().enumerated().filter { $0.element.block.folded && !$0.element.block.children.isEmpty }.map { FoldedRow(index: $0.offset, text: $0.element.block.text) }
        }

        /// Every row of what is shown — under folds or not — in reading order.
        public func outline() -> [OutlineRow] {
            body.rows().map { row in
                var heading: Int? = nil
                if case .heading(let level) = row.block.kind { heading = level }
                return OutlineRow(depth: row.depth, text: row.block.text, heading: heading, task: row.block.taskState?.isDone, hasChildren: !row.block.children.isEmpty)
            }
        }

        /// Brings a row into sight: the rows it is under unfolded. Where its
        /// words then start in the text, if it is shown.
        public func revealRow(_ index: Int) -> Int? {
            let all = body.rows()
            guard index >= 0, index < all.count else { return nil }
            let path = all[index].path
            var opened = false
            if path.count > 1 {
                for end in 1..<path.count {
                    body.modify(Array(path[..<end])) { if $0.folded { $0.folded = false; opened = true } }
                }
            }
            if opened {
                typing = nil
                project()
            }
            return rowOf(path)?.range.lowerBound
        }

        /// Folds these rows, and no others. A row is found by its words — at
        /// its place, or nearest to it — and one no longer there, or with
        /// nothing under it, is passed over. Says whether anything changed;
        /// if it did, the view shows other text, and what was done before
        /// cannot be undone after.
        public func setFoldedRows(_ folded: [FoldedRow]) -> Bool {
            let before = foldedRows()
            fold(folded)
            if foldedRows() == before { return false }
            undone.removeAll()
            redone.removeAll()
            typing = nil
            project()
            return true
        }

        /// Folds the rows that answer to these, and unfolds every other.
        func fold(_ folded: [FoldedRow]) {
            if folded.isEmpty && !body.any({ $0.folded }) { return }
            let all = body.rows()
            func fits(_ at: Int, _ row: FoldedRow) -> Bool { at >= 0 && at < all.count && all[at].block.text.same(row.text) && !all[at].block.children.isEmpty }
            let paths: [Path] = folded.compactMap { row in
                if fits(row.index, row) { return all[row.index].path }
                var best: Int? = nil
                for at in all.indices where fits(at, row) {
                    if best == nil || abs(at - row.index) < abs(best! - row.index) { best = at }
                }
                return best.map { all[$0].path }
            }
            _ = Markup.foldAll(&body.blocks, false)
            for path in paths { body.modify(path) { $0.folded = true } }
        }
    }
}

// --- What the session is made of ------------------------------------------

extension Markup {
    /// The first block with a mark in its words, in reading order — or the last.
    static func marked(_ document: Document, _ mark: Unicode.Scalar, _ last: Bool) -> Path? {
        let needle = String(mark)
        var found: Path? = nil
        var path: Path = []
        func visit(_ blocks: [Block]) -> Bool {
            for (index, block) in blocks.enumerated() {
                path.append(index)
                if block.text.utf8.count >= 3 && block.text.unicodeScalars.contains(mark) {
                    found = path
                    if !last { return true }
                }
                if visit(block.children) { return true }
                path.removeLast()
            }
            return false
        }
        _ = visit(document.blocks)
        _ = needle
        return found
    }

    /// Takes a mark out of a block's words; says where it was.
    static func unmark(_ document: inout Document, _ path: Path, _ mark: Unicode.Scalar) -> Int? {
        document.modify(path) { block -> Int? in
            var text = block.text.u8
            guard let at = text.find(String(mark).u8) else { return nil }
            text.removeSubrange(at..<(at + 3))
            block.text = text.string
            return at
        } ?? nil
    }

    static func unmarkAll(_ blocks: inout [Block], _ marks: [Unicode.Scalar]) {
        for i in blocks.indices {
            if blocks[i].text.unicodeScalars.contains(where: { marks.contains($0) }) {
                var scalars = String.UnicodeScalarView()
                scalars.append(contentsOf: blocks[i].text.unicodeScalars.filter { !marks.contains($0) })
                blocks[i].text = String(scalars)
            }
            if !blocks[i].children.isEmpty { unmarkAll(&blocks[i].children, marks) }
        }
    }

    /// The rows an outline shows, in reading order: every block not under a
    /// folded one.
    static func visible(_ document: Document) -> [Path] {
        var out: [Path] = []
        var path: Path = []
        func visit(_ blocks: [Block]) {
            for (index, block) in blocks.enumerated() {
                path.append(index)
                out.append(path)
                if !block.folded { visit(block.children) }
                path.removeLast()
            }
        }
        visit(document.blocks)
        return out
    }

    /// A row's name, as the note's file has it after the row's first line.
    static func writtenAnchor(_ name: String) -> String { "<!-- ^\(name) -->" }

    /// The name in a comment that is a row's name and nothing else.
    static func readAnchor(_ comment: Bytes) -> String? {
        guard comment.hasPrefix("<!--".u8), comment.hasSuffix("-->".u8), comment.count >= 7 else { return nil }
        let inner = comment.sub(4..<(comment.count - 3)).trimmed
        guard inner.first == UInt8(ascii: "^") else { return nil }
        let name = inner.sub(from: 1)
        guard !name.isEmpty, name.allSatisfy({ ($0 < 0x80 && Unicode.Scalar($0).isAsciiAlnum) || $0 == UInt8(ascii: "-") || $0 == UInt8(ascii: "_") }) else { return nil }
        return name.string
    }

    /// A body as it was read, the marks at the end of its rows' first lines
    /// taken out of their words: a row marked folded, having rows under it,
    /// is folded; a row with a name has it as its anchor.
    static func readMarks(_ document: Document) -> Document {
        var document = document
        func read(_ blocks: inout [Block]) {
            for i in blocks.indices {
                while blocks[i].canHaveChildren {
                    let text = blocks[i].text.u8
                    let line = text.find(byte: .newline) ?? text.count
                    let first = text.sub(0..<line).trimmedEnd
                    if first.hasSuffix(foldedMark.u8) {
                        let kept = first.sub(0..<(first.count - foldedMark.utf8.count)).trimmedEnd.count
                        blocks[i].text = (text.sub(0..<kept) + text.sub(from: line)).string
                        blocks[i].folded = !blocks[i].children.isEmpty
                    } else if first.hasSuffix(cardMark.u8) {
                        let kept = first.sub(0..<(first.count - cardMark.utf8.count)).trimmedEnd.count
                        blocks[i].text = (text.sub(0..<kept) + text.sub(from: line)).string
                        blocks[i].card = true
                    } else if let at = first.rfind("<!--".u8), let name = readAnchor(first.sub(from: at)) {
                        // The first written is the one kept, were there two.
                        blocks[i].anchor = name
                        let kept = first.sub(0..<at).trimmedEnd.count
                        blocks[i].text = (text.sub(0..<kept) + text.sub(from: line)).string
                    } else {
                        break
                    }
                }
                read(&blocks[i].children)
            }
        }
        read(&document.blocks)
        return document
    }

    /// A body as it is written: each named row's first line ending with its
    /// name, and each folded row's with the mark of a fold.
    static func writtenMarks(_ document: Document) -> Document {
        if !document.any({ $0.anchor != nil || $0.card || ($0.folded && !$0.children.isEmpty) }) { return document }
        var marked = document
        func write(_ blocks: inout [Block]) {
            for i in blocks.indices {
                let block = blocks[i]
                var marks: [String] = []
                if let anchor = block.anchor { marks.append(writtenAnchor(anchor)) }
                if block.card { marks.append(cardMark) }
                if block.folded && !block.children.isEmpty { marks.append(foldedMark) }
                if !marks.isEmpty {
                    var text = block.text.u8
                    let line = text.find(byte: .newline) ?? text.count
                    let gap = line == 0 ? "" : " "
                    text.insert(contentsOf: (gap + marks.joined(separator: " ")).u8, at: line)
                    blocks[i].text = text.string
                }
                write(&blocks[i].children)
            }
        }
        write(&marked.blocks)
        return marked
    }

    /// What a name is known by: its words, one space between, lower case.
    static func nameKey(_ name: String) -> String { name.wordsWS.joined(separator: " ").lowercased() }

    /// Whether a block's words link to a page by one of these name keys.
    static func linksTo(_ text: String, _ keys: [String]) -> Bool {
        func any(_ spans: [Span]) -> Bool {
            spans.contains { span in
                var target: String? = nil
                if case .wikiLink(let t, _, _) = span.kind { target = t }
                if case .tag(let name) = span.kind { target = name }
                return target.map { keys.contains(nameKey($0)) } == true || any(span.children)
            }
        }
        return !keys.isEmpty && any(Inline.parse(text))
    }

    /// Whether a block's words say any of these, case aside.
    static func says(_ text: String, _ words: [String]) -> Bool {
        let said = Inline.plainText(text).lowercased().u8
        return words.contains { said.find($0.u8) != nil }
    }

    /// A name for a row: a few letters no row of the body has.
    static func newAnchor(_ document: Document) -> String {
        let letters = Array("abcdefghijklmnopqrstuvwxyz0123456789")
        while true {
            let name = String((0..<6).map { _ in letters[Int.random(in: 0..<letters.count)] })
            if !document.any({ $0.anchor == name }) { return name }
        }
    }

    /// Where the row of a name is.
    static func anchored(_ document: Document, _ name: String) -> Path? {
        document.rows().first { $0.block.anchor == name }?.path
    }

    /// Folds a block, or unfolds it; a block with nothing under it is never
    /// folded. Says whether that changed it.
    static func setFold(_ block: inout Block, _ folded: Bool) -> Bool {
        let folded = folded && !block.children.isEmpty
        let was = block.folded
        block.folded = folded
        return was != folded
    }

    /// Folds some blocks and every block under them, or unfolds them.
    static func foldAll(_ blocks: inout [Block], _ folded: Bool) -> Bool {
        var any = false
        for i in blocks.indices {
            if setFold(&blocks[i], folded) { any = true }
            if foldAll(&blocks[i].children, folded) { any = true }
        }
        return any
    }

    /// The deepest level, among blocks and those under them, of rows whose
    /// children are shown.
    static func deepestShown(_ blocks: [Block], _ depth: Int) -> Int? {
        blocks.filter { !$0.children.isEmpty && !$0.folded }.map { deepestShown($0.children, depth + 1) ?? depth }.max()
    }

    /// The shallowest level of folded rows that can be seen.
    static func shallowestFolded(_ blocks: [Block], _ depth: Int) -> Int? {
        blocks.compactMap { block -> Int? in
            if block.children.isEmpty { return nil }
            return block.folded ? depth : shallowestFolded(block.children, depth + 1)
        }.min()
    }

    static func foldAt(_ blocks: inout [Block], _ depth: Int, _ level: Int, _ folded: Bool) -> Bool {
        var any = false
        for i in blocks.indices {
            if depth == level {
                if setFold(&blocks[i], folded) { any = true }
            } else if !blocks[i].folded {
                if foldAt(&blocks[i].children, depth + 1, level, folded) { any = true }
            }
        }
        return any
    }

    /// Collapse by level, as Bike's: the deepest level of rows whose children
    /// are shown is folded.
    static func foldByLevel(_ blocks: inout [Block]) -> Bool {
        guard let level = deepestShown(blocks, 0) else { return false }
        return foldAt(&blocks, 0, level, true)
    }

    /// Expand by level: the shallowest level folded is shown.
    static func unfoldByLevel(_ blocks: inout [Block]) -> Bool {
        guard let level = shallowestFolded(blocks, 0) else { return false }
        return foldAt(&blocks, 0, level, false)
    }

    /// Puts the checked items of a list after the rest, each kind in the
    /// order it was in; the blank lines stay where they were on the page.
    static func sinkDone(_ children: inout [Block]) -> Bool {
        func done(_ block: Block) -> Bool { block.taskState?.isDone == true }
        guard let firstDone = children.firstIndex(where: done), children[firstDone...].contains(where: { !done($0) }) else { return false }
        let gaps = children.map(\.layout.gap)
        var sorted = children.filter { !done($0) } + children.filter(done)
        for i in sorted.indices { sorted[i].layout.gap = gaps[i] }
        children = sorted
        return true
    }

    /// What a block of a kind becomes under a command; nil when the command
    /// has nothing to say to it.
    static func turned(_ kind: BlockKind, _ command: Command) -> BlockKind? {
        func item(_ marker: Marker, _ task: Task?) -> BlockKind { .item(Item(marker: marker, task: task)) }
        var marker: Marker? = nil
        var task: Task? = nil
        switch kind {
        case .item(let i): marker = i.marker; task = i.task
        case .paragraph, .heading, .quote: break
        default: return nil
        }
        var bullet: Character? = nil
        if case .bullet(let b) = marker { bullet = b }
        let dash: Character = bullet.flatMap { $0 != "+" ? $0 : nil } ?? "-"
        var isOrdered = false
        if case .ordered = marker { isOrdered = true }
        switch command {
        case .cycleChecklist:
            switch task {
            case nil: return item(.bullet(dash), .open)
            case .open: return item(marker ?? .bullet("-"), .done("x"))
            case .done: return item(.bullet(dash), nil)
            }
        case .toggleTask:
            if bullet == "+" && task != nil { return item(.bullet("-"), nil) }
            return item(.bullet("+"), .open)
        case .toggleCheckbox:
            guard let marker else { return nil }
            switch task {
            case .open: return item(marker, .done("x"))
            case .done: return item(marker, .open)
            case nil: return nil
            }
        case .heading(let level):
            return kind == .heading(level) ? .paragraph : .heading(min(max(level, 1), 6))
        case .bullet:
            return bullet != nil && task == nil ? .paragraph : item(.bullet("-"), nil)
        case .numbered:
            return isOrdered ? .paragraph : item(.ordered(number: 1, delimiter: "."), nil)
        case .quote:
            return kind == .quote ? .paragraph : .quote
        case .markDone:
            guard task == .open, let marker else { return nil }
            return item(marker, .done("x"))
        case .turn(let to):
            switch to {
            case .paragraph: return .paragraph
            case .bullet: return item(.bullet(dash), nil)
            case .checkbox: return item(.bullet(dash), task ?? .open)
            case .task: return item(.bullet("+"), task ?? .open)
            case .numbered: return item(isOrdered ? marker! : .ordered(number: 1, delimiter: "."), nil)
            case .heading(let level): return .heading(min(max(level, 1), 6))
            case .quote: return .quote
            }
        default:
            return nil
        }
    }

    /// The arrow that what is typed completes: `>` after `-` is →, `-` after
    /// `<` is ←. Not in code, and not the `-->` that ends a comment.
    static func arrow(_ text: Bytes, _ range: Range<Int>, _ typed: String) -> (Range<Int>, String)? {
        if !range.isEmpty { return nil }
        let start = range.lowerBound
        let arrow: String
        if typed == ">" && text.has([UInt8(ascii: "-")], endingAt: start) && !text.has("--".u8, endingAt: start) {
            arrow = "→"
        } else if typed == "-" && text.has([UInt8(ascii: "<")], endingAt: start) {
            arrow = "←"
        } else {
            return nil
        }
        // Inside a code span or a fence, a backtick before here is still open.
        if text[0..<start].filter({ $0 == UInt8(ascii: "`") }).count % 2 == 1 { return nil }
        return ((start - 1)..<start, arrow)
    }

    /// How much of a note's text after its frontmatter is its title: a first
    /// line that is `# Title` — after blank lines, if any — with the blank
    /// lines after it.
    static func headingLength(_ rest: Bytes) -> Int {
        func inclusiveLines(_ b: Bytes, from: Int) -> [Range<Int>] {
            var out: [Range<Int>] = []
            var at = from
            while at < b.count {
                let end = (b.find(byte: .newline, from: at).map { $0 + 1 }) ?? b.count
                out.append(at..<end)
                at = end
            }
            return out
        }
        var blank = 0
        for line in inclusiveLines(rest, from: 0) {
            guard rest.trimmed(line).isEmpty && rest[line.upperBound - 1] == .newline else { break }
            blank = line.upperBound
        }
        guard let first = inclusiveLines(rest, from: blank).first else { return 0 }
        var words = rest.sub(first)
        while let last = words.last, last == .newline || last == UInt8(ascii: "\r") { words.removeLast() }
        guard words.hasPrefix("# ".u8), !words.sub(from: 2).isBlankWS else { return 0 }
        var end = first.upperBound
        for line in inclusiveLines(rest, from: end) {
            if !rest.trimmed(line).isEmpty { break }
            end = line.upperBound
        }
        return end
    }

    /// A range held to the text and to its characters' boundaries.
    static func clamp(_ text: Bytes, _ range: Range<Int>) -> Range<Int> {
        func floor(_ at: Int) -> Int {
            var at = min(max(at, 0), text.count)
            while !text.isBoundary(at) { at -= 1 }
            return at
        }
        let start = floor(range.lowerBound)
        return start..<max(floor(range.upperBound), start)
    }

    /// Whether a line is a code fence: three backticks or tildes, and perhaps a language.
    static func isFence(_ line: Bytes) -> Bool {
        let line = line.trimmed
        let marks = line.count - line.trimmingStart("`~".u8).count
        return marks >= 3 && line.sub(from: marks).scalars.allSatisfy { $0.1.isAlnum || "+#.-_".unicodeScalars.contains($0.1) }
    }

    /// Whether a block's words are edited as rich text — shown without their
    /// Markdown — rather than as written: code and tables are as written.
    static func isRich(_ block: Block) -> Bool {
        switch block.kind {
        case .paragraph, .heading, .item, .quote: return true
        default: return false
        }
    }

    /// A fenced block of code's parts: its opening fence line, its code, and
    /// its closing fence — one made to match, if it had none.
    static func fenced(_ block: Block) -> (open: Bytes, code: Bytes, close: Bytes)? {
        guard block.kind == .code else { return nil }
        let text = block.text.u8
        let newline = text.find(byte: .newline)
        let open = newline.map { text.sub(0..<$0) } ?? text
        let rest = newline.map { text.sub(from: $0 + 1) } ?? []
        let opening = open.trimmedStart
        guard let mark = opening.first, mark == UInt8(ascii: "`") || mark == UInt8(ascii: "~") else { return nil }
        let run = opening.leading(mark)
        if run < 3 { return nil }
        func closes(_ line: Bytes) -> Bool {
            let t = line.trimmed
            return t.count >= run && t.allSatisfy { $0 == mark }
        }
        if let last = rest.rfind([.newline]) {
            let close = rest.sub(from: last + 1)
            if closes(close) { return (open, rest.sub(0..<last), close) }
        } else if closes(rest) {
            return (open, [], rest)
        }
        return (open, rest, Bytes(repeating: mark, count: run))
    }

    /// A block's words: rich, as written — or, for code between fences, the
    /// code: its fences are Markdown, and never shown.
    static func wordsOf(_ block: Block) -> Rich {
        if isRich(block) { return Rich.parse(block.text) }
        if let (_, code, _) = fenced(block) { return Rich.plain(bytes: code) }
        return Rich.plain(block.text)
    }

    /// Words put back in a block: as Markdown, as written, or as code between its fences.
    static func setWords(_ block: inout Block, _ words: Rich) {
        if isRich(block) {
            var guarded = true
            if case .heading = block.kind { guarded = false }
            block.text = words.markdown(guarded: guarded)
        } else if let (open, _, close) = fenced(block) {
            var text = open
            text.append(.newline)
            if !words.bytes.isEmpty { text += words.bytes; text.append(.newline) }
            text += close
            block.text = text.string
        } else {
            block.text = words.text
        }
    }

    /// A place in a row as the view shows it — its line breaks U+2028 — as a
    /// place in its words, whose line breaks are `\n`.
    static func richOffset(_ viewRow: Bytes, _ offset: Int) -> Int {
        let offset = min(max(offset, 0), viewRow.count)
        return offset - viewRow.occurrences(of: softBreakBytes, to: offset) * 2
    }

    /// A place in a row's words as the view shows it.
    static func viewOffset(_ words: Bytes, _ offset: Int) -> Int {
        let offset = min(max(offset, 0), words.count)
        var breaks = 0
        for i in 0..<offset where words[i] == .newline { breaks += 1 }
        return offset + breaks * 2
    }

    /// A block's Markdown, at a place in its words.
    static func markdownAt(_ block: Block, _ rich: Int) -> Int {
        if isRich(block) { return Rich.markdownOffset(block.text, rich, inside: false) }
        if let (open, code, _) = fenced(block) { return open.count + 1 + min(rich, code.count) }
        return rich
    }

    /// Where a place in a block's Markdown is shown in its row.
    static func shownIn(_ block: Block, _ markdown: Int) -> Int {
        let rich: Int
        if isRich(block) {
            rich = Rich.shownOffset(block.text, markdown)
        } else if let (open, code, _) = fenced(block) {
            rich = min(max(markdown - (open.count + 1), 0), code.count)
        } else {
            rich = markdown
        }
        return viewOffset(wordsOf(block).bytes, rich)
    }

    /// What text inserted in words means: Markdown, for what was pasted or
    /// put in whole — a link completed, a picture — and plain for what is typed.
    static func inserted(_ piece: Bytes) -> Rich {
        if piece.scalars.count > 1 {
            let rich = Rich.parse(piece.string)
            if !rich.runs.isEmpty { return rich }
        }
        return Rich.plain(bytes: piece)
    }

    /// The layout's runs for a rich row: its marks, and its atoms, in the view.
    static func richRuns(_ words: Rich, _ rowStart: Int, _ runs: inout [Run]) {
        // Where each place in the words is in the view, past the line breaks before it.
        var breaksBefore: [Int] = []
        if words.bytes.contains(.newline) {
            breaksBefore = [Int](repeating: 0, count: words.bytes.count + 1)
            var n = 0
            for i in 0..<words.bytes.count {
                breaksBefore[i] = n
                if words.bytes[i] == .newline { n += 1 }
            }
            breaksBefore[words.bytes.count] = n
        }
        func at(_ offset: Int) -> Int { rowStart + offset + (breaksBefore.isEmpty ? 0 : breaksBefore[min(offset, words.bytes.count)] * 2) }
        for run in words.runs {
            let kind: RunKind
            switch run.mark {
            case .strong: kind = .strong
            case .emphasis: kind = .emphasis
            case .strikethrough: kind = .strikethrough
            case .highlight: kind = .highlight
            case .code: kind = .code
            case .link(let target, _): kind = .webLink(url: target)
            case .autolink, .url: kind = .webLink(url: words.bytes.string(run.range))
            case .tag(let name): kind = .tag(name: name)
            case .atom(let atom):
                switch atom.kind {
                case .page(let target, _, let embed): kind = .pageLink(target: target, embed: embed)
                case .picture(let source, let alt, let width, let height): kind = .image(source: source, alt: alt, width: width, height: height)
                case .comment: kind = .markup
                }
            }
            runs.append(Run(range: at(run.range.lowerBound)..<at(run.range.upperBound), kind: kind))
        }
    }

    /// The least that turns one text into another: a range of the first,
    /// and what replaces it.
    static func difference(_ before: Bytes, _ after: Bytes) -> (Range<Int>, String) {
        var start = 0
        let shorter = min(before.count, after.count)
        while start < shorter && before[start] == after[start] { start += 1 }
        while !before.isBoundary(start) || !after.isBoundary(start) { start -= 1 }
        let (restBefore, restAfter) = (before.count - start, after.count - start)
        var same = 0
        while same < min(restBefore, restAfter) && before[before.count - 1 - same] == after[after.count - 1 - same] { same += 1 }
        while !before.isBoundary(before.count - same) || !after.isBoundary(after.count - same) { same -= 1 }
        return (start..<(before.count - same), after.string(start..<(after.count - same)))
    }
}
