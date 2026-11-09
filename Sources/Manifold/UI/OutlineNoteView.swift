import AppKit
import ManifoldCore

/// The outliner lens (§7.9): a note — any Markdown text — edited as an
/// outline, as Prism's notes are. The Markdown is read into rows
/// (`NoteOutlineMarkdown`: list items and what nests in them, headings,
/// quotes, code, rules, paragraphs, checkboxes), the rows are what's edited
/// — Return makes a row, Tab and ⇧Tab move it in and out with its
/// children, ⌃⌘↑ and ⌃⌘↓ move it among its siblings, ⌘↩ gives it a
/// checkbox and checks it, a bullet clicked folds what's under it — and
/// each change is written back as the Markdown it says, only the bytes that
/// changed. A note read and written without being edited comes back byte
/// for byte; a change made elsewhere (its editor, another Mac, `mani
/// write`) is read in again, the caret staying on its row.
final class OutlineNoteView: NSView, PaneContent {
    let placement: PlacementID
    let block: BlockID
    var source: () -> Block? = { nil }
    /// Edits to the block's text, as an editor makes them.
    var apply: ([TextEdit]) -> Void = { _ in }
    /// A link in it clicked: followed, by the one rule.
    var onOpen: ((String) -> Void)? {
        get { text.onOpen }
        set { text.onOpen = newValue }
    }
    /// A block dropped in by its link: linked from the note.
    var onLinked: ((BlockID) -> Void)? {
        get { text.onLinked }
        set { text.onLinked = newValue }
    }
    /// A picture dropped, kept for the note: given the Markdown that shows it.
    var keepImage: ((Data, String, @escaping (String) -> Void) -> Void)? {
        get { text.keepImage }
        set { text.keepImage = newValue }
    }
    /// A block's card (a place's in it), for a row that's only its embed.
    var cardFor: ((BlockID, String?) -> SummaryCardContent?)? {
        get { text.cardFor }
        set { text.cardFor = newValue }
    }
    /// A picture by its source (a note's own relative to its file), when
    /// it's here; nil sends for it, `picturesArrived` after.
    var pictureFor: ((String) -> NSImage?)? {
        get { text.styler.pictureFor }
        set { text.styler.pictureFor = newValue }
    }
    /// Pictures sent for came: shown.
    func picturesArrived() { text.picturesArrived() }
    var theme: FontTheme { didSet { if theme != oldValue { text.metrics = Self.metrics(theme) } } }

    private let scroll = NSScrollView()
    private let text: NoteOutlineTextView

    /// ⌘↩ from the menu: the caret's row a checkbox, checked, a bullet again.
    func cycleChecklist() { text.cycleChecklist(nil) }
    /// What isn't rows — frontmatter, blank lines at the end, the line
    /// ending — kept to write the rows back with.
    private var shell = NoteOutline(rows: [])
    /// The Markdown last read or written: the block's, unless it changed
    /// elsewhere since.
    private var written: String?
    private let headings = Outline()

    var focusView: NSView { text }
    /// What takes things dropped on it.
    var dropTarget: DropTaking { text }
    var isDead: Bool { false }
    var outline: Outline? { headings }

    /// Its folds, in the tile's menu (⌥⌘9 and ⌥⌘0 in it).
    var pillItems: [NSMenuItem] {
        [ClosureMenuItem("Collapse All", symbol: "arrow.down.right.and.arrow.up.left") { [weak self] in self?.text.collapseAll(nil) },
         ClosureMenuItem("Expand All", symbol: "arrow.up.left.and.arrow.down.right") { [weak self] in self?.text.expandAll(nil) },
         .separator()]
    }

    init(placement: PlacementID, block: BlockID, theme: FontTheme) {
        self.placement = placement
        self.block = block
        self.theme = theme
        text = NoteOutlineTextView(metrics: Self.metrics(theme))
        super.init(frame: .zero)
        wantsLayer = true
        themed { $0.layer?.backgroundColor = Theme.windowBackground.cgColor }
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.documentView = text
        text.autoresizingMask = [.width]
        text.isVerticallyResizable = true
        text.isHorizontallyResizable = false
        text.minSize = NSSize(width: 0, height: 0)
        text.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        text.textContainerInset = NSSize(width: 14, height: 14)
        text.onRowsChanged = { [weak self] in self?.rowsChanged() }
        text.onFocusChange = { [weak self] in
            self?.showPath()
            self?.markCurrent()
        }
        path.onStep = { [weak self] index in
            guard let self else { return }
            if let index { self.text.focusOn(fullRow: index) } else { self.text.unfocus(nil) }
            self.window?.makeFirstResponder(self.text)
        }
        addSubview(scroll)
        addSubview(path)
        headings.onPick = { [weak self] i in self?.goToHeading(i) }
        // An entry's place: its line in the Markdown, as the editor's are.
        headings.block = block
        headings.placeFor = { [weak self] i in
            guard let lines = self?.itemLines, lines.indices.contains(i) else { return nil }
            return .line(lines[i] + 1)
        }
        scroll.contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(self, selector: #selector(scrolled), name: NSView.boundsDidChangeNotification, object: scroll.contentView)
    }

    required init?(coder: NSCoder) { fatalError() }

    func destroy() { NotificationCenter.default.removeObserver(self) }

    @objc private func scrolled() { markCurrent() }

    override func layout() {
        super.layout()
        // The path to the row focused on, or why it can't be edited, over the rows.
        let barShown = text.focus != nil || !text.isEditable
        path.isHidden = !barShown
        let bar: CGFloat = barShown ? NoteOutlinePath.height : 0
        path.frame = NSRect(x: 14, y: bounds.height - bar - 4, width: max(0, bounds.width - 28), height: bar)
        scroll.frame = NSRect(x: 0, y: 0, width: bounds.width, height: bounds.height - (barShown ? bar + 4 : 0))
        text.frame.size.width = scroll.contentSize.width
    }

    private let path = NoteOutlinePath()

    /// The focus's path shown (or the note's being read only), over the rows.
    private func showPath() {
        let name = source()?.displayTitle ?? "Note"
        if let focus = text.focus {
            path.show(note: name, ancestors: focus.ancestors, fontSize: text.metrics.fontSize)
        } else if !text.isEditable {
            path.showReadOnly()
        }
        needsLayout = true
    }

    static func metrics(_ theme: FontTheme) -> NoteOutlineMetrics {
        NoteOutlineMetrics(body: theme.font(.proportional, size: 14.5), code: theme.font(.monospaced, size: 12.5))
    }

    // MARK: The note, both ways

    /// The block moved: unless it's what was written from here, read again.
    func documentChanged() {
        guard let b = source(), let t = b.text, !b.needsRead else { return }
        let markdown = t.text.string
        guard markdown != written else { return text.refreshCards() }
        let first = written == nil
        var outline = NoteOutlineMarkdown.parse(markdown)
        var rows = outline.rows
        outline.rows = []
        shell = outline
        written = markdown
        // What was folded, and focused on, as it was (by place and words).
        let caret = text.caretPosition
        let folds = NoteOutlineFolds.marks(text.fullRows)
        let focused = text.focus.map { f in (f.before.count, text.fullRows[f.before.count].text) }
        if !first { NoteOutlineFolds.apply(folds, to: &rows) }
        text.focus = nil
        text.load(rows, keepingCaret: !first)
        if let focused, let at = NoteOutlineFolds.nearest(focused.1, to: focused.0, in: text.rows) {
            text.focusOn(fullRow: at)
            text.restoreCaret(caret)
        }
        // A note whose Markdown the outline can't write back as it was is
        // shown, not edited: its first edit would rewrite what it didn't touch.
        let writable = NoteOutlineMarkdown.roundTrips(markdown)
        if text.isEditable != writable { text.isEditable = writable; needsLayout = true }
        updateHeadings()
        showPath()
    }

    /// The rows changed here: written back, only what changed.
    private func rowsChanged() {
        var outline = shell
        outline.rows = text.fullRows
        let markdown = NoteOutlineMarkdown.serialize(outline)
        updateHeadings()
        guard markdown != written, let old = source()?.text?.text.string else { return }
        written = markdown
        apply([Self.edit(from: old, to: markdown)])
    }

    /// One edit turning `old` into `new`: what's between their common head
    /// and tail, cut at characters' edges (offsets in bytes, as a rope
    /// counts them).
    static func edit(from old: String, to new: String) -> TextEdit {
        let a = Array(old.utf8), b = Array(new.utf8)
        var head = 0
        while head < a.count, head < b.count, a[head] == b[head] { head += 1 }
        // Not inside a character: back to where one starts.
        while head > 0, head < a.count, a[head] & 0xC0 == 0x80 { head -= 1 }
        var tail = 0
        while tail < a.count - head, tail < b.count - head, a[a.count - 1 - tail] == b[b.count - 1 - tail] { tail += 1 }
        while tail > 0, a.count - tail < a.count, a[a.count - tail] & 0xC0 == 0x80 { tail -= 1 }
        let inserted = String(decoding: b[head..<(b.count - tail)], as: UTF8.self)
        return TextEdit(TextRange(head, a.count - tail), inserted)
    }

    // MARK: The tile's outline

    /// The note's outline — its headings, and its top-level items each
    /// under the heading before it — as its editor and preview have it too
    /// (`NoteOutlineMarkdown.items`): the tile's ticks, its sidebar, ⌘P.
    private func updateHeadings() {
        var outline = shell
        outline.rows = text.fullRows
        let items = NoteOutlineMarkdown.items(of: outline)
        itemRows = items.map(\.row)
        itemLines = items.map(\.line)
        headings.set(items.map(Outline.Item.init))
        markCurrent()
        markThreads()
    }

    private var itemRows: [Int] = []
    private var itemLines: [Int] = []

    // MARK: Places (§2.5) and threads (§3.12)

    /// The Markdown's lines each row shown stands for (from 0).
    private var shownRowLines: [ClosedRange<Int>] {
        var outline = shell
        outline.rows = text.fullRows
        let all = NoteOutlineMarkdown.rowLines(of: outline)
        let skip = text.focus?.before.count ?? 0
        return Array(all.dropFirst(skip).prefix(text.paragraphRanges.count))
    }

    /// What's here: the rows selected, else the caret's row — as the lines
    /// of the Markdown they are, named by their words.
    var here: Place? {
        let lines = shownRowLines
        guard !lines.isEmpty else { return Place(block: block) }
        let rows = text.selectedRows ?? {
            let r = text.rowIndex(at: text.selectedRange().location)
            return r..<(r + 1)
        }()
        let a = min(rows.lowerBound, lines.count - 1), b = min(max(rows.upperBound - 1, a), lines.count - 1)
        let shown = (text.string as NSString).substring(with: text.paragraphRanges[a])
        let words = shown.prefix { $0 != "\n" && $0 != "\u{2028}" }.trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: "\u{FFFC}")))
        let name = words.isEmpty ? nil : String(words.prefix(60))
        let at: Locator = a == b && lines[a].count == 1 ? .line(lines[a].lowerBound + 1) : .lines(lines[a].lowerBound + 1, lines[b].upperBound + 1)
        return Place(block: block, at: at, name: name)
    }

    /// The places threads are about, as the editor's are found: marked on
    /// the rows they're on (at their right), as those rows are now.
    var threadPlaces: [TextView.Place] = [] { didSet { if threadPlaces != oldValue { markThreads() } } }
    /// A row's thread mark clicked: the Markdown line it's on, and where the mark is (in this view).
    var onThreads: ((Int, NSRect) -> Void)?

    private func markThreads() {
        let lines = shownRowLines
        var marks: [Int: ThreadMark.State] = [:]
        for p in threadPlaces where p.threads > 0 {
            guard let row = lines.firstIndex(where: { $0.contains(p.line) }) else { continue }
            let m = TextView.threadState(p)
            if let old = marks[row] {
                marks[row] = ThreadMark.State(count: old.count + m.count, open: old.open || m.open, unseen: old.unseen || m.unseen)
            } else {
                marks[row] = m
            }
        }
        text.threadMarks = marks
        text.onThreads = { [weak self] row, rect in
            guard let self, lines.indices.contains(row) else { return }
            // The line of the place that's on this row.
            let line = self.threadPlaces.first { $0.threads > 0 && lines[row].contains($0.line) }?.line ?? lines[row].lowerBound
            self.onThreads?(line, self.convert(rect, from: self.text))
        }
    }

    private func goToHeading(_ i: Int) {
        guard itemRows.indices.contains(i) else { return }
        // (Among all the note's rows: out of a focus it isn't in.)
        var row = itemRows[i] - (text.focus?.before.count ?? 0)
        if text.focus != nil, !text.rows.indices.contains(row) {
            text.unfocus(nil)
            row = itemRows[i]
        }
        text.goTo(row: row)
        window?.makeFirstResponder(text)
    }

    /// The item you're at: the last that begins at or above the top of
    /// what shows.
    private func markCurrent() {
        guard let layout = text.layoutManager, let container = text.textContainer, !itemRows.isEmpty else { return headings.current = nil }
        let top = NSPoint(x: 0, y: scroll.contentView.bounds.minY - text.textContainerOrigin.y + 4)
        let glyph = layout.glyphIndex(for: top, in: container)
        let row = text.fullIndex(of: text.rowIndex(at: layout.characterIndexForGlyph(at: glyph)))
        headings.current = itemRows.lastIndex { $0 <= row } ?? 0
    }

    // MARK: Debugging

    /// The rows as they stand, a line each: depth, kind, checkbox, text.
    var debugRows: String {
        text.rows.map { row in
            let kind: String = switch row.kind {
            case .bullet: "-"
            case .ordered: "\(row.number)."
            case let .heading(l): String(repeating: "#", count: l)
            case .paragraph: "¶"
            case .quote: ">"
            case .code: "code"
            case .rule: "rule"
            }
            let box = row.task.map { $0.isDone ? "[x] " : "[ ] " } ?? ""
            return String(repeating: "  ", count: row.depth) + kind + " " + box + row.text.replacingOccurrences(of: "\n", with: "⏎")
                + (row.isFolded ? "  (folded \(row.folded.count))" : "")
        }.joined(separator: "\n")
    }

    /// Debugging: a command, as its key does it ("return", "tab", "backtab",
    /// "check", "up", "down", "fold <row>", "type <text>", "caret <row> <offset>").
    func debug(_ command: String) -> String {
        let words = command.split(separator: " ", maxSplits: 1).map(String.init)
        window?.makeFirstResponder(text)
        switch words.first {
        case "grab":
            // "grab <row>": the mouse down on that row's handle and moved 10
            // points, as posted events: whether it's taken as the handle,
            // and the drag begun.
            guard let layout = text.layoutManager as? NoteOutlineLayoutManager, let storage = text.textStorage, let window,
                  let i = Int(words.count > 1 ? words[1] : ""), text.paragraphRanges.indices.contains(i),
                  let c = layout.handleCenter(of: text.paragraphRanges[i], row: NoteOutlineText.style(storage, at: text.paragraphRanges[i].location).row, origin: text.textContainerOrigin) else { return "no row" }
            let hit = layout.handleHit(at: c, origin: text.textContainerOrigin)
            let at = text.convert(c, to: nil)
            func mouse(_ type: NSEvent.EventType, _ p: NSPoint) -> NSEvent {
                NSEvent.mouseEvent(with: type, location: p, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                                   context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
            }
            NSApp.postEvent(mouse(.leftMouseDragged, NSPoint(x: at.x, y: at.y - 10)), atStart: false)
            NSApp.postEvent(mouse(.leftMouseUp, NSPoint(x: at.x, y: at.y - 10)), atStart: false)
            text.debugDragBegan = nil
            text.mouseDown(with: mouse(.leftMouseDown, at))
            return "handle hit \(hit.map(String.init) ?? "none") · drag \(text.debugDragBegan ?? "not begun")"
        case "handles":
            // Each row's handle, where it's drawn: its center's height in its line.
            guard let layout = text.layoutManager as? NoteOutlineLayoutManager, let storage = text.textStorage else { return "no layout" }
            return text.paragraphRanges.enumerated().map { i, p in
                let row = NoteOutlineText.style(storage, at: p.location).row
                let line = p.location < storage.length ? layout.lineFragmentRect(forGlyphAt: layout.glyphIndexForCharacter(at: p.location), effectiveRange: nil) : .zero
                let c = layout.handleCenter(of: p, row: row, origin: .zero)
                return "\(i) line \(Int(line.minY))+\(Int(line.height)) handle \(c.map { String(format: "%.1f", $0.y - line.minY) } ?? "none")"
            }.joined(separator: "\n")
        case "return": text.insertNewline(nil)
        case "tab": text.insertTab(nil)
        case "backtab": text.insertBacktab(nil)
        case "delete": text.deleteBackward(nil)
        case "check": text.cycleChecklist(nil)
        case "up": text.moveRowsUp(nil)
        case "down": text.moveRowsDown(nil)
        case "fold": if words.count > 1, let r = Int(words[1]) { text.clickHandle(ofRow: r) }
        case "escape": text.cancelOperation(nil)
        case "left": text.moveLeft(nil)
        case "right": text.moveRight(nil)
        case "rowup": text.moveUp(nil)
        case "rowdown": text.moveDown(nil)
        case "extend": text.moveDownAndModifySelection(nil)
        case "space": text.insertText(" ", replacementRange: NSRange(location: NSNotFound, length: 0))
        case "collapseall": text.collapseAll(nil)
        case "expandall": text.expandAll(nil)
        case "copy":
            let pb = NSPasteboard(name: NSPasteboard.Name("com.manifold.debug-outline"))
            pb.clearContents()
            _ = text.writeSelection(to: pb, type: .string)
            return "copied:\n" + (pb.string(forType: .string) ?? "")
        case "move":
            // "move <row> <before row> <depth>": the row and what's under it, dragged there.
            let n = (words.count > 1 ? words[1] : "").split(separator: " ").compactMap { Int($0) }
            if n.count == 3 { text.moveRows(NoteOutlineEditing.block(text.rows, n[0]..<(n[0] + 1)), from: text, to: .init(index: n[1], depth: n[2])) }
        case "type": if words.count > 1 { for ch in words[1] { text.insertText(String(ch), replacementRange: NSRange(location: NSNotFound, length: 0)) } }
        case "do":
            // "do <action>": a menu's command (its selector, less the colon), as chosen.
            guard words.count > 1 else { return "usage: do <selector>" }
            let action = Selector(words[1] + ":")
            guard text.validateUserInterfaceItem(NSMenuItem(title: "", action: action, keyEquivalent: "")) else { return "disabled: \(words[1])" }
            guard NSApp.sendAction(action, to: text, from: nil) else { return "not taken: \(words[1])" }
        case "menu":
            // "menu <row>": that row's menu, as right-clicking it shows it; "menu <row> <title>": that item chosen.
            let n = (words.count > 1 ? words[1] : "").split(separator: " ", maxSplits: 1).map(String.init)
            guard let i = Int(n.first ?? "") else { return "usage: menu <row> [title]" }
            text.restoreCaret(.init(row: i, offset: 0))
            let items = text.rowMenuItems(for: i)
            if n.count > 1 {
                let all = items + items.compactMap(\.submenu).flatMap(\.items)
                guard let item = all.first(where: { $0.title == n[1] }), let action = item.action else { return "no item \(n[1])" }
                NSApp.sendAction(action, to: item.target, from: item)
            } else {
                return items.map { $0.title + ($0.submenu.map { " ▸ " + $0.items.map { ($0.state == .on ? "✓" : "") + $0.title }.joined(separator: ", ") } ?? "") }.joined(separator: "\n")
            }
        case "hover":
            // "hover <row>": the pointer over that row (its ghost bullet shown); "hover" alone, off it.
            text.hoveredRow = words.count > 1 ? Int(words[1]) : nil
            return "hovered \(text.hoveredRow.map(String.init) ?? "none")"
        case "click":
            // "click <row>": that row's handle clicked; "click <row> option": ⌥-clicked.
            let n = (words.count > 1 ? words[1] : "").split(separator: " ").map(String.init)
            guard let i = Int(n.first ?? "") else { return "usage: click <row>" }
            if n.count > 1, n[1] == "option" { text.focusOn(fullRow: text.fullIndex(of: i)) } else { text.clickHandle(ofRow: i) }
        case "pill":
            // "pill <row>": that folded row's pill clicked (where it's drawn, as a click there finds it).
            guard let layout = text.layoutManager as? NoteOutlineLayoutManager, let i = Int(words.count > 1 ? words[1] : ""), text.paragraphRanges.indices.contains(i),
                  let r = layout.foldPill(for: text.paragraphRanges[i], origin: text.textContainerOrigin) else { return "no pill" }
            guard layout.foldPillHit(at: NSPoint(x: r.midX, y: r.midY), origin: text.textContainerOrigin) == i else { return "pill not hit" }
            text.perform("Expand", on: i..<(i + 1), followingCaret: false) { rows, s in NoteOutlineEditing.unfold(&rows, at: s.lowerBound); return s }
        case "paste":
            // "paste <text>": pasted, as from the pasteboard (the general one, put back after).
            let pb = NSPasteboard.general
            let was = pb.string(forType: .string)
            pb.clearContents()
            pb.setString((words.count > 1 ? words[1] : "").replacingOccurrences(of: "\\n", with: "\n"), forType: .string)
            text.paste(nil)
            pb.clearContents()
            if let was { pb.setString(was, forType: .string) }
        case "select":
            // "select <from> <length>": characters selected (from the text's start).
            let n = (words.count > 1 ? words[1] : "").split(separator: " ").compactMap { Int($0) }
            if n.count == 2 { text.setSelectedRange(NSRange(location: n[0], length: n[1])) }
        case "markdown":
            return source()?.text?.text.string ?? "no text"
        case "pasteimage":
            // "pasteimage <path>": a PNG's bytes pasted, as a screenshot copied
            // is (from a pasteboard of its own: the general one untouched).
            guard words.count > 1, let data = FileManager.default.contents(atPath: words[1]) else { return "usage: pasteimage <png>" }
            let pb = NSPasteboard(name: NSPasteboard.Name("com.manifold.debug-outline-image"))
            pb.clearContents()
            pb.setData(data, forType: .png)
            return text.pastePicture(from: pb) ? "pasted" : "not taken"
        case "pictures":
            // Each picture shown, where it's drawn.
            return text.debugPictures
        case "picture":
            // "picture <n> hover|grip <dx> <dy>|own": the nth picture under
            // the pointer (its grip drawn), its grip dragged so far and let
            // go, or its grip twice clicked.
            let n = (words.count > 1 ? words[1] : "").split(separator: " ").map(String.init)
            guard let layout = text.pictureLayout, let storage = text.textStorage, let i = Int(n.first ?? ""),
                  case let all = layout.pictureFrames(in: NSRange(location: 0, length: storage.length), origin: text.textContainerOrigin),
                  all.indices.contains(i) else { return "no picture" }
            let (picture, frame, location) = all[i]
            switch n.count > 1 ? n[1] : "hover" {
            case "hover":
                text.hoverPicture(at: NSPoint(x: frame.midX, y: frame.midY))
                let grip = NoteOutlineTextView.grip(in: frame)
                return "hovered \(text.hoveredPicture.map(String.init) ?? "none") · grip hit \(text.onPictureGrip(NSPoint(x: grip.midX, y: grip.midY)))"
            case "grip":
                let dx = n.count > 2 ? Double(n[2]) ?? 0 : 0, dy = n.count > 3 ? Double(n[3]) ?? 0 : 0
                let width = text.resizePicture(picture, at: location, from: frame, by: CGSize(width: dx, height: dy))
                text.setPictureWidth(width, at: location)
            case "drag", "twice":
                // As the mouse does it: down on the grip, dragged, up (posted events).
                guard let window else { return "no window" }
                let grip = NoteOutlineTextView.grip(in: frame)
                let at = text.convert(NSPoint(x: grip.midX, y: grip.midY), to: nil)
                let dx = n.count > 2 ? Double(n[2]) ?? 0 : 0, dy = n.count > 3 ? Double(n[3]) ?? 0 : 0
                let count = n[1] == "twice" ? 2 : 1
                func mouse(_ type: NSEvent.EventType, _ p: NSPoint) -> NSEvent {
                    NSEvent.mouseEvent(with: type, location: p, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                                       context: nil, eventNumber: 0, clickCount: count, pressure: 1)!
                }
                let to = NSPoint(x: at.x + dx, y: at.y - dy)
                if count == 1 {
                    NSApp.postEvent(mouse(.leftMouseDragged, NSPoint(x: at.x + dx / 2, y: at.y - dy / 2)), atStart: false)
                    NSApp.postEvent(mouse(.leftMouseDragged, to), atStart: false)
                    NSApp.postEvent(mouse(.leftMouseUp, to), atStart: false)
                }
                text.hoverPicture(at: NSPoint(x: frame.midX, y: frame.midY))
                text.mouseDown(with: mouse(.leftMouseDown, at))
            case "own":
                text.setPictureWidth(nil, at: location)
            default: return "usage: picture <n> hover|grip <dx> <dy>|drag <dx> <dy>|twice|own"
            }
            return text.debugPictures + "\n" + (source()?.text?.text.string ?? "")
        case "caret":
            let n = (words.count > 1 ? words[1] : "").split(separator: " ").compactMap { Int($0) }
            if n.count == 2 { text.restoreCaret(.init(row: n[0], offset: n[1])) }
        default: break
        }
        let c = text.caretPosition
        let selected = text.selectedRows.map { " rows \($0.lowerBound)…\($0.upperBound - 1)" } ?? (text.selectedRange().length > 0 ? " text “\((text.string as NSString).substring(with: text.selectedRange()))”" : "")
        let focus = text.focus.map { "\nfocus after \($0.before.count) rows, \($0.after.count) after, path: " + path.debugState } ?? ""
        return "caret \(c.row):\(c.offset)\(selected)\(text.isEditable ? "" : " read only")\(focus)\n" + debugRows
    }
}

// MARK: - Rows as paragraphs

extension NSAttributedString.Key {
    /// The row a paragraph is, as a `NoteRowStyle`: every character of a
    /// paragraph, its line break too, carries the same one.
    static let noteRow = NSAttributedString.Key("ManifoldNoteRow")
    /// Inline Markdown's markup (`**`, a link's brackets and address): kept
    /// in the text, laid out as nothing.
    static let noteHidden = NSAttributedString.Key("ManifoldNoteHidden")
    /// A row that's only a block's embed (`![name](manifold:…)`): its card
    /// (`NoteCard`), drawn under it.
    static let noteCard = NSAttributedString.Key("ManifoldNoteCard")
}

/// A block's card under the row that embeds it (§3.11), as its summary
/// said when the row was styled.
final class NoteCard {
    let block: BlockID
    let place: String?
    let target: String
    let content: SummaryCardContent
    init(block: BlockID, place: String?, target: String, content: SummaryCardContent) {
        self.block = block
        self.place = place
        self.target = target
        self.content = content
    }
    var height: CGFloat { SummaryCard.height(for: content) }
    static let line = try! NSRegularExpression(pattern: #"^\s*!\[[^\]\n]*\]\((manifold:[^)\s]+)\)\s*$"#)
    /// One card, drawn wherever a row shows one.
    static let painter = SummaryCard(SummaryCardContent(id: "", symbol: "doc", summary: BlockSummary(title: "")))
}

/// What a paragraph is: a row, less its text, which is the paragraph's.
/// Immutable, so undo can put an old one back.
final class NoteRowStyle: NSObject {
    let row: NoteRow

    init(_ row: NoteRow) {
        var row = row
        row.text = ""
        self.row = row
    }
}

/// The outline's text: a paragraph a row, each ending in a line break —
/// the last too, so every row has a character to carry its style. Lines
/// within a row are broken with U+2028.
enum NoteOutlineText {
    static let lineSeparator = "\u{2028}"

    static func attributed(_ rows: [NoteRow]) -> NSMutableAttributedString {
        let text = NSMutableAttributedString()
        for row in rows {
            text.append(NSAttributedString(string: row.text.replacingOccurrences(of: "\n", with: lineSeparator) + "\n",
                                           attributes: [.noteRow: NoteRowStyle(row)]))
        }
        return text
    }

    static func paragraphs(_ text: NSString) -> [NSRange] {
        var ranges: [NSRange] = []
        var start = 0
        while start < text.length {
            let found = text.range(of: "\n", options: .literal, range: NSRange(location: start, length: text.length - start))
            let end = found.location == NSNotFound ? text.length : found.location + 1
            ranges.append(NSRange(location: start, length: end - start))
            start = end
        }
        return ranges
    }

    static func style(_ text: NSAttributedString, at location: Int) -> NoteRowStyle {
        guard text.length > 0 else { return NoteRowStyle(.blank) }
        return text.attribute(.noteRow, at: min(location, text.length - 1), effectiveRange: nil) as? NoteRowStyle ?? NoteRowStyle(.blank)
    }

    /// A row's inline spans (`InlineMarkup`): a picture that's `shown` one
    /// thing, hidden whole, drawn under its line; one not (not here, not a
    /// picture) its Markdown.
    static func spans(in text: NSString, range: NSRange, shown: (ImageReference) -> Bool = { _ in false }) -> [InlineSpan] {
        let range = NSIntersectionRange(range, NSRange(location: 0, length: text.length))
        return InlineMarkup.spans(in: text, range: range).map { span in
            guard case let .image(picture) = span.kind, !shown(picture) else { return span }
            var shown = span
            // A block's embed: its name, a link to it, its card drawn under the row.
            if case let .image(reference) = span.kind, reference.source.hasPrefix("manifold:") {
                shown.kind = .link(reference.source)
                shown.content = NSRange(location: span.range.location + 2, length: (reference.alt as NSString).length)
                return shown
            }
            shown.kind = .imageText
            shown.content = span.range
            return shown
        }
    }

    static func rows(_ text: NSAttributedString) -> [NoteRow] {
        let string = text.string as NSString
        return paragraphs(string).map { range in
            var row = style(text, at: range.location).row
            var body = string.substring(with: range)
            if body.hasSuffix("\n") { body.removeLast() }
            row.text = body.replacingOccurrences(of: lineSeparator, with: "\n")
            return row
        }
    }
}

// MARK: - Type and measures

struct NoteOutlineMetrics: Equatable {
    var body: NSFont
    var code: NSFont
    var fontSize: CGFloat { body.pointSize }
    /// How far each level is in.
    var indent: CGFloat { round(fontSize * 1.45) }
    var lineHeightMultiple: CGFloat { 1.18 }
    var rowSpacing: CGFloat { round(fontSize * 0.28) }

    func heading(_ level: Int) -> NSFont {
        let (factor, weight): (CGFloat, NSFont.Weight) = switch level {
        case 1: (1.45, .bold)
        case 2: (1.22, .bold)
        case 3: (1.08, .semibold)
        default: (1, .semibold)
        }
        let size = round(fontSize * factor)
        return NSFontManager.shared.convert(NSFont(descriptor: body.fontDescriptor, size: size) ?? .systemFont(ofSize: size), toHaveTrait: .boldFontMask)
            .withWeight(weight)
    }

    func font(for row: NoteRow) -> NSFont {
        switch row.kind {
        case let .heading(level): heading(level)
        case .code: code
        default: body
        }
    }

    /// Where a row's text starts: a step in for each level, bullet or
    /// none — a list item's marker hangs in the room before it.
    func textIndent(for row: NoteRow) -> CGFloat { indent * CGFloat(row.depth + 1) }
}

private extension NSFont {
    func withWeight(_ weight: NSFont.Weight) -> NSFont {
        let d = fontDescriptor.addingAttributes([.traits: [NSFontDescriptor.TraitKey.weight: weight]])
        return NSFont(descriptor: d, size: pointSize) ?? self
    }
}

// MARK: - Styling

/// Styles each paragraph from its row as the text changes — only
/// attributes, never characters — and keeps each paragraph one row: when an
/// edit joins two, the row that was there first wins.
final class NoteOutlineStyler: NSObject, NSTextStorageDelegate {
    var metrics: NoteOutlineMetrics
    /// Rows folded inside a row an edit swallowed, and where they belong.
    var orphans: [(location: Int, rows: [NoteRow])] = []
    /// Told of every change to the characters, before anything else hears
    /// of it (what's cached of where rows are goes then: an undo sets the
    /// selection before the view hears the text changed).
    var onCharactersEdited: (() -> Void)?

    /// A block's card (a place's in it), for a row that's only its embed.
    var cardFor: ((BlockID, String?) -> SummaryCardContent?)?
    /// A picture by its source, when it's here (nil: not yet, sent for —
    /// or not a picture).
    var pictureFor: ((String) -> NSImage?)?

    init(metrics: NoteOutlineMetrics) { self.metrics = metrics }

    /// Whether a picture is shown as one, not its Markdown.
    func shows(_ picture: ImageReference) -> Bool { pictureFor?(picture.source) != nil }

    /// The card a row's text embeds, if it's only that (and not a picture,
    /// shown as one).
    func card(for text: String) -> NoteCard? {
        guard text.contains("](manifold:"), let cardFor,
              let m = NoteCard.line.firstMatch(in: text, range: NSRange(location: 0, length: (text as NSString).length)) else { return nil }
        let target = (text as NSString).substring(with: m.range(at: 1))
        guard pictureFor?(target) == nil, let (id, place) = BlockID.link(target), let content = cardFor(id, place) else { return nil }
        return NoteCard(block: id, place: place, target: target, content: content)
    }

    func textStorage(_ storage: NSTextStorage, didProcessEditing mask: NSTextStorageEditActions, range edited: NSRange, changeInLength delta: Int) {
        if mask.contains(.editedCharacters) { onCharactersEdited?() }
        guard storage.length > 0 else { return }
        let text = storage.string as NSString
        var range = text.paragraphRange(for: NSRange(location: min(edited.location, text.length), length: min(edited.length, text.length - min(edited.location, text.length))))
        // The rows on each side are spaced by this one: styled again too.
        if NSMaxRange(range) < text.length { range = NSUnionRange(range, text.paragraphRange(for: NSRange(location: NSMaxRange(range), length: 0))) }
        if range.location > 0 { range = NSUnionRange(range, text.paragraphRange(for: NSRange(location: range.location - 1, length: 0))) }
        if mask.contains(.editedCharacters) { unify(storage, in: range, inserted: edited) }
        style(storage, in: range)
    }

    func styleAll(_ storage: NSTextStorage) {
        storage.beginEditing()
        style(storage, in: NSRange(location: 0, length: storage.length))
        storage.endEditing()
    }

    private func unify(_ storage: NSTextStorage, in range: NSRange, inserted: NSRange) {
        let text = storage.string as NSString
        for p in NoteOutlineText.paragraphs(text.substring(with: range) as NSString) {
            let paragraph = NSRange(location: p.location + range.location, length: p.length)
            var styles: [NoteRowStyle] = []
            var winner: NoteRowStyle?
            storage.enumerateAttribute(.noteRow, in: paragraph) { value, run, _ in
                guard let style = value as? NoteRowStyle else { return }
                if !styles.contains(where: { $0 === style }) { styles.append(style) }
                // What was typed takes the row it was typed into.
                let typed = inserted.length > 0 && NSIntersectionRange(run, inserted).length == run.length
                if winner == nil, !typed { winner = style }
            }
            let style = winner ?? styles.last ?? NoteRowStyle(.blank)
            guard styles.count > 1 || styles.first !== style else { continue }
            storage.addAttribute(.noteRow, value: style, range: paragraph)
            for lost in styles where lost !== style && lost.row.isFolded {
                orphans.append((paragraph.location, lost.row.folded.map { var c = $0; c.depth += lost.row.depth; return c }))
            }
        }
    }

    private func style(_ storage: NSTextStorage, in range: NSRange) {
        let text = storage.string as NSString
        for p in NoteOutlineText.paragraphs(text.substring(with: range) as NSString) {
            let paragraph = NSRange(location: p.location + range.location, length: p.length)
            var row = NoteOutlineText.style(storage, at: paragraph.location).row
            row.text = text.substring(with: paragraph).trimmingCharacters(in: .newlines)
            let previous = paragraph.location > 0 ? NoteOutlineText.style(storage, at: paragraph.location - 1).row : nil
            let style = storage.attribute(.noteRow, at: paragraph.location, effectiveRange: nil) as Any
            storage.setAttributes(attributes(for: row, after: previous), range: paragraph)
            storage.addAttribute(.noteRow, value: style, range: paragraph)
            // A code block's fences: there to be edited, not read.
            if row.kind == .code { dimFences(storage, in: paragraph) }
            else if row.kind != .rule { styleInline(storage, in: paragraph, row: row) }
            // A block's card under it: room made below the row.
            if row.kind != .code, let card = card(for: row.text),
               let ps = (storage.attribute(.paragraphStyle, at: paragraph.location, effectiveRange: nil) as? NSParagraphStyle)?.mutableCopy() as? NSMutableParagraphStyle {
                ps.paragraphSpacing += card.height + 8
                storage.addAttributes([.paragraphStyle: ps, .noteCard: card], range: paragraph)
            }
            storage.fixAttributes(in: paragraph)
        }
    }

    /// The row's inline Markdown as it reads (Prism's, after Bike): bold,
    /// italic, struck through, highlighted, code in the code face, links in
    /// the accent (followed by the one rule), tags — the markup around each
    /// kept but laid out as nothing; a picture drawn under its line, its
    /// Markdown hidden whole (greyed when it can't be shown), a comment
    /// hidden whole.
    private func styleInline(_ storage: NSTextStorage, in paragraph: NSRange, row: NoteRow) {
        let text = storage.string as NSString
        let body = NSRange(location: paragraph.location, length: max(0, paragraph.length - 1))
        let base = metrics.font(for: row)
        func font(at location: Int) -> NSFont { storage.attribute(.font, at: location, effectiveRange: nil) as? NSFont ?? base }
        for span in NoteOutlineText.spans(in: text, range: body, shown: shows) {
            let content = span.content
            switch span.kind {
            case .strong:
                storage.addAttribute(.font, value: NSFontManager.shared.convert(font(at: content.location), toHaveTrait: .boldFontMask), range: content)
            case .emphasis:
                let plain = font(at: content.location)
                let italic = NSFontManager.shared.convert(plain, toHaveTrait: .italicFontMask)
                if italic.fontDescriptor.symbolicTraits.contains(.italic) {
                    storage.addAttribute(.font, value: italic, range: content)
                } else {
                    // A face with no italic: slanted.
                    storage.addAttribute(.obliqueness, value: 0.18, range: content)
                }
            case .strikethrough:
                storage.addAttributes([.strikethroughStyle: NSUnderlineStyle.single.rawValue, .foregroundColor: Theme.secondaryText], range: content)
            case .highlight:
                storage.addAttribute(.backgroundColor, value: Self.highlighter, range: content)
            case .code:
                storage.addAttributes([.font: NSFont(descriptor: metrics.code.fontDescriptor, size: round(base.pointSize * 0.9)) ?? metrics.code,
                                       .backgroundColor: NSColor.quaternaryLabelColor.withAlphaComponent(0.18)], range: content)
            case let .link(target), let .url(target):
                if let url = URL(string: target) { storage.addAttribute(.link, value: url, range: content) }
                storage.addAttribute(.foregroundColor, value: Theme.accent, range: content)
            case .wikiLink, .tag:
                storage.addAttribute(.foregroundColor, value: Theme.accent, range: content)
            case .imageText:
                storage.addAttribute(.foregroundColor, value: Theme.secondaryText, range: span.range)
            case let .image(reference):
                if let image = pictureFor?(reference.source) {
                    storage.addAttribute(.notePicture, value: NotePicture(reference: reference, image: image),
                                         range: NSRange(location: span.range.location, length: 1))
                }
            case .comment:
                break
            }
            for run in span.markup { storage.addAttribute(.noteHidden, value: true, range: run) }
        }
        // A block's reference written bare: a link to it.
        for m in Self.reference.matches(in: storage.string, range: body) {
            guard let url = URL(string: text.substring(with: m.range)) else { continue }
            storage.addAttributes([.link: url, .foregroundColor: Theme.accent], range: m.range)
        }
    }

    private static let reference = try! NSRegularExpression(pattern: #"(?<![(\[<"'=/\w])"# + BlockID.referencePattern)

    /// `==text==`'s ground: a highlighter's yellow, the text reading through it.
    static let highlighter = NSColor.themed { $0.code.highlighter }

    private func dimFences(_ storage: NSTextStorage, in paragraph: NSRange) {
        let text = storage.string as NSString
        let body = NSRange(location: paragraph.location, length: max(0, paragraph.length - 1))
        let first = text.range(of: NoteOutlineText.lineSeparator, options: .literal, range: body)
        let last = text.range(of: NoteOutlineText.lineSeparator, options: [.literal, .backwards], range: body)
        let opening = first.location == NSNotFound ? body : NSRange(location: body.location, length: first.location - body.location)
        storage.addAttribute(.foregroundColor, value: Theme.tertiaryText, range: opening)
        if last.location != NSNotFound {
            let closing = NSRange(location: NSMaxRange(last), length: NSMaxRange(body) - NSMaxRange(last))
            let line = text.substring(with: closing).trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("```") || line.hasPrefix("~~~") { storage.addAttribute(.foregroundColor, value: Theme.tertiaryText, range: closing) }
        }
    }

    /// How a row looks, and how far it stands from the one before: rows
    /// evenly, whatever blank lines the Markdown has (in an outline they
    /// say nothing); a heading with room above it.
    func attributes(for row: NoteRow, after previous: NoteRow?) -> [NSAttributedString.Key: Any] {
        let paragraph = NSMutableParagraphStyle()
        let indent = metrics.textIndent(for: row)
        paragraph.firstLineHeadIndent = indent
        paragraph.headIndent = indent
        paragraph.lineHeightMultiple = metrics.lineHeightMultiple
        paragraph.paragraphSpacing = metrics.rowSpacing
        var before: CGFloat = 0
        if case .heading = row.kind { before = round(metrics.fontSize * 0.8) }
        else if row.kind == .paragraph, previous?.kind == .paragraph, !row.gap.isEmpty { before = round(metrics.fontSize * 0.45) }
        else if row.startsGroup(after: previous) { before = round(metrics.fontSize * 0.5) }
        paragraph.paragraphSpacingBefore = previous == nil ? 0 : before
        var a: [NSAttributedString.Key: Any] = [.font: metrics.font(for: row), .paragraphStyle: paragraph, .foregroundColor: Theme.bodyText]
        switch row.kind {
        case .quote: a[.foregroundColor] = Theme.secondaryText
        case .rule: a[.foregroundColor] = NSColor.clear  // drawn; its dashes are there to be edited
        default: break
        }
        if row.task?.isDone == true { a[.foregroundColor] = Theme.secondaryText }
        if row.isStruck {
            a[.strikethroughStyle] = NSUnderlineStyle.single.rawValue
            a[.strikethroughColor] = Theme.tertiaryText
        }
        return a
    }
}

// MARK: - Drawing what isn't typed

/// Draws a row's bullet, number or checkbox in the room before its text,
/// a quote's bar, a rule, the ground under code, and a fold's mark.
final class NoteOutlineLayoutManager: NSLayoutManager {
    weak var view: NoteOutlineTextView?

    enum Handle { case none, ghost, bullet, task(done: Bool, round: Bool), number(String) }

    /// A row's handle — a fold is told by the pill after its words, as
    /// Prism has it, not on the handle.
    static func handle(for row: NoteRow) -> Handle {
        if let task = row.task, row.kind.isListItem { return .task(done: task.isDone, round: row.marker == "+") }
        switch row.kind {
        case .bullet: return .bullet
        case .ordered: return .number("\(row.number)\(row.marker)")
        default: return .none
        }
    }

    /// A row's handle as shown: one with none, the pointer over it, a ghost
    /// of a bullet (not a rule: nothing to fold, nothing to pick up by).
    func shownHandle(for row: NoteRow, at index: Int) -> Handle {
        let h = Self.handle(for: row)
        if case .none = h, index == view?.hoveredRow, row.kind != .rule { return .ghost }
        return h
    }

    /// How many of the checkboxes under each row are checked, of how many
    /// (what's folded in it counted too): a ring round its bullet.
    static func progress(_ rows: [NoteRow]) -> [(done: Int, total: Int)] {
        var under = [(done: Int, total: Int)](repeating: (done: 0, total: 0), count: rows.count)
        var open: [Int] = []
        for (index, row) in rows.enumerated() {
            while let last = open.last, rows[last].depth >= row.depth { open.removeLast() }
            let inside = NoteRow.unfold(row.folded).filter { $0.task != nil }
            let own = (done: inside.filter { $0.task?.isDone == true }.count, total: inside.count)
            let box: (done: Int, total: Int) = row.task.map { (done: $0.isDone ? 1 : 0, total: 1) } ?? (done: 0, total: 0)
            under[index].done += own.done
            under[index].total += own.total
            for ancestor in open {
                under[ancestor].done += own.done + box.done
                under[ancestor].total += own.total + box.total
            }
            open.append(index)
        }
        return under
    }

    override func drawBackground(forGlyphRange glyphsToShow: NSRange, at origin: NSPoint) {
        super.drawBackground(forGlyphRange: glyphsToShow, at: origin)
        guard let storage = textStorage, let view, storage.length > 0 else { return }
        let covered = (storage.string as NSString).paragraphRange(for: characterRange(forGlyphRange: glyphsToShow, actualGlyphRange: nil))
        let metrics = view.metrics
        let width = view.textContainer?.size.width ?? view.bounds.width
        // Rows selected as rows: one block, from the leftmost handle across.
        if let selected = view.selectedRows {
            var block = NSRect.null
            var left = CGFloat.greatestFiniteMagnitude
            let paragraphs = view.paragraphRanges
            for index in selected where index < paragraphs.count {
                let row = NoteOutlineText.style(storage, at: paragraphs[index].location).row
                left = min(left, origin.x + max(0, metrics.textIndent(for: row) - metrics.indent))
                if let frame = frame(of: paragraphs[index], origin: origin, whole: true) { block = block.union(frame) }
            }
            if !block.isNull {
                let rect = NSRect(x: left - 4, y: block.minY, width: origin.x + width - left + 4, height: block.height)
                let active = view.window?.isKeyWindow == true && view.window?.firstResponder === view
                (active ? NSColor.selectedContentBackgroundColor.withAlphaComponent(0.28) : NSColor.unemphasizedSelectedContentBackgroundColor).setFill()
                NSBezierPath(roundedRect: rect, xRadius: 5, yRadius: 5).fill()
            }
        }
        let paragraphs = view.paragraphRanges
        let styles = paragraphs.map { NoteOutlineText.style(storage, at: $0.location).row }
        let progress = styles.contains { $0.task != nil || $0.isFolded } ? Self.progress(styles) : []
        for (index, paragraph) in paragraphs.enumerated() where NSIntersectionRange(paragraph, covered).length > 0 || paragraph.location == covered.location {
            let row = styles[index]
            guard let frame = frame(of: paragraph, origin: origin) else { continue }
            let indent = origin.x + metrics.textIndent(for: row)
            switch row.kind {
            case .code:
                NSColor.quaternaryLabelColor.withAlphaComponent(0.12).setFill()
                let ground = NSRect(x: indent - 6, y: frame.minY - 2, width: origin.x + width - indent + 6, height: frame.height + 4)
                NSBezierPath(roundedRect: ground, xRadius: 5, yRadius: 5).fill()
                // Its language, in the corner.
                let text = storage.string as NSString
                let first = text.substring(with: paragraph).components(separatedBy: NoteOutlineText.lineSeparator)[0]
                let language = first.trimmingCharacters(in: .whitespaces).drop { $0 == "`" || $0 == "~" }.trimmingCharacters(in: .whitespacesAndNewlines)
                if !language.isEmpty {
                    let label = NSAttributedString(string: language, attributes: [.font: NSFont.systemFont(ofSize: round(metrics.code.pointSize * 0.85)),
                                                                                  .foregroundColor: Theme.tertiaryText])
                    let size = label.size()
                    label.draw(at: NSPoint(x: ground.maxX - size.width - 8, y: ground.minY + 4))
                }
            case .quote:
                Theme.tertiaryText.setFill()
                NSBezierPath(roundedRect: NSRect(x: indent - metrics.indent / 2 - 1.5, y: frame.minY, width: 3, height: frame.height), xRadius: 1.5, yRadius: 1.5).fill()
            case .rule:
                NSColor.separatorColor.setFill()
                NSRect(x: indent, y: frame.midY.rounded(), width: origin.x + width - indent, height: 1).fill()
            default: break
            }
            drawHandle(shownHandle(for: row, at: index), row: row, paragraph: paragraph, origin: origin, indent: indent,
                       progress: progress.indices.contains(index) ? progress[index] : nil)
            if row.isFolded, let pill = foldPill(for: paragraph, origin: origin) { Self.drawFoldPill(in: pill) }
            drawPictures(in: paragraph, origin: origin)
            if let card = storage.attribute(.noteCard, at: paragraph.location, effectiveRange: nil) as? NoteCard {
                let r = NSRect(x: indent, y: frame.maxY + 4, width: min(460, origin.x + width - indent), height: card.height)
                let painter = NoteCard.painter
                painter.content = card.content
                painter.frame = NSRect(origin: .zero, size: r.size)
                NSGraphicsContext.saveGraphicsState()
                let move = NSAffineTransform()
                move.translateX(by: r.minX, yBy: r.minY)
                move.concat()
                painter.draw(painter.bounds)
                NSGraphicsContext.restoreGraphicsState()
            }
        }
    }

    /// Where a row's card is drawn, if it shows one.
    func cardRect(of paragraph: NSRange, origin: NSPoint) -> (NoteCard, NSRect)? {
        guard let storage = textStorage, let view, paragraph.location < storage.length,
              let card = storage.attribute(.noteCard, at: paragraph.location, effectiveRange: nil) as? NoteCard,
              let frame = frame(of: paragraph, origin: origin) else { return nil }
        let row = NoteOutlineText.style(storage, at: paragraph.location).row
        let indent = origin.x + view.metrics.textIndent(for: row)
        let width = view.textContainer?.size.width ?? view.bounds.width
        return (card, NSRect(x: indent, y: frame.maxY + 4, width: min(460, origin.x + width - indent), height: card.height))
    }

    /// Where a row's handle is drawn: its middle, in the room before the
    /// text, on the first line.
    func handleCenter(of paragraph: NSRange, row: NoteRow, origin: NSPoint) -> NSPoint? {
        guard let view else { return nil }
        let glyph = glyphIndexForCharacter(at: paragraph.location)
        guard glyph < numberOfGlyphs else { return nil }
        // The baseline from the line's used room and the row's font, not
        // its first glyph's: an empty row's is its line break, set lower.
        let font = view.metrics.font(for: row)
        guard let line = baseline(atGlyph: glyph, font: font) else { return nil }
        let baseline = origin.y + line
        return NSPoint(x: origin.x + view.metrics.textIndent(for: row) - view.metrics.indent / 2, y: baseline - font.xHeight / 2)
    }

    private func drawHandle(_ handle: Handle, row: NoteRow, paragraph: NSRange, origin: NSPoint, indent: CGFloat, progress: (done: Int, total: Int)?) {
        guard let view, let center = handleCenter(of: paragraph, row: row, origin: origin) else { return }
        let font = view.metrics.font(for: row)
        switch handle {
        case .none: break
        case .ghost:
            // Hollow and faint: a hint of a row's handle, not a bullet.
            let dot = max(5, (view.metrics.fontSize * 0.38).rounded())
            let ring = NSBezierPath(ovalIn: NSRect(x: center.x - dot / 2, y: center.y - dot / 2, width: dot, height: dot))
            ring.lineWidth = 1
            Theme.tertiaryText.setStroke()
            ring.stroke()
        case .bullet:
            let dot = max(4, (font.pointSize * 0.34).rounded())
            Theme.secondaryText.setFill()
            NSBezierPath(ovalIn: NSRect(x: center.x - dot / 2, y: center.y - dot / 2, width: dot, height: dot)).fill()
            // Checkboxes under it: how far along they are, round it.
            if let progress, progress.total > 0 {
                let r = (font.pointSize * 0.95).rounded() / 2
                let track = NSBezierPath(ovalIn: NSRect(x: center.x - r, y: center.y - r, width: 2 * r, height: 2 * r))
                track.lineWidth = 1.6
                Theme.tertiaryText.withAlphaComponent(0.35).setStroke()
                track.stroke()
                let arc = NSBezierPath()
                let share = CGFloat(progress.done) / CGFloat(progress.total)
                // From the top, clockwise (the view is flipped).
                arc.appendArc(withCenter: center, radius: r, startAngle: -90, endAngle: -90 + 360 * share, clockwise: false)
                arc.lineWidth = 1.6
                arc.lineCapStyle = .round
                Theme.accent.setStroke()
                if share > 0 { arc.stroke() }
            }
        case let .task(done, round):
            let name = round ? (done ? "checkmark.circle.fill" : "circle") : (done ? "checkmark.square.fill" : "square")
            let config = NSImage.SymbolConfiguration(pointSize: font.pointSize * 0.95, weight: .regular)
                .applying(.init(paletteColors: done ? [.white, Theme.accent] : [Theme.secondaryText]))
            guard let image = NSImage(systemSymbolName: name, accessibilityDescription: done ? "Done" : "To do")?.withSymbolConfiguration(config) else { return }
            let size = image.size
            let middle = center.y + font.xHeight / 2 - font.capHeight / 2
            image.draw(in: NSRect(x: center.x - size.width / 2, y: middle - size.height / 2, width: size.width, height: size.height),
                       from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
        case let .number(label):
            let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.systemDigits(ofSize: font.pointSize, weight: .regular),
                                                             .foregroundColor: Theme.secondaryText]
            let text = NSAttributedString(string: label, attributes: attributes)
            let size = text.size()
            let ascent = (attributes[.font] as! NSFont).ascender
            text.draw(at: NSPoint(x: indent - 6 - size.width, y: center.y + font.xHeight / 2 - ascent))
        }
    }

    /// The rectangle a paragraph's lines take (`whole`: with the room
    /// around them, so neighbours meet).
    func frame(of paragraph: NSRange, origin: NSPoint, whole: Bool = false) -> NSRect? {
        let glyphs = glyphRange(forCharacterRange: NSRange(location: paragraph.location, length: max(1, paragraph.length - 1)), actualCharacterRange: nil)
        guard glyphs.length > 0, glyphs.location < numberOfGlyphs else { return nil }
        var rect = NSRect.null
        enumerateLineFragments(forGlyphRange: glyphs) { fragment, used, _, _, _ in rect = rect.union(whole ? fragment : used) }
        guard !rect.isNull else { return nil }
        return rect.offsetBy(dx: origin.x, dy: origin.y)
    }

    /// The row whose handle is at a point in the view, if any (of those
    /// among some characters: the ones shown): the whole step before its
    /// text, as tall as its first line.
    func handleHit(at point: NSPoint, origin: NSPoint, among characters: NSRange? = nil) -> Int? {
        guard let view, let storage = textStorage else { return nil }
        for (index, paragraph) in view.paragraphRanges.enumerated() {
            if let characters, NSMaxRange(paragraph) < characters.location { continue }
            if let characters, paragraph.location > NSMaxRange(characters) { break }
            let row = NoteOutlineText.style(storage, at: paragraph.location).row
            if case .none = Self.handle(for: row), index != view.hoveredRow || row.kind == .rule { continue }
            let glyph = glyphIndexForCharacter(at: paragraph.location)
            guard glyph < numberOfGlyphs else { break }
            let line = lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil).offsetBy(dx: origin.x, dy: origin.y)
            if line.minY > point.y { break }
            let indent = origin.x + view.metrics.textIndent(for: row)
            if NSRect(x: indent - view.metrics.indent, y: line.minY, width: view.metrics.indent, height: line.height).contains(point) { return index }
        }
        return nil
    }

    /// Where a folded row's pill is: after the words of its last line, on
    /// the middle of their capitals.
    func foldPill(for paragraph: NSRange, origin: NSPoint) -> NSRect? {
        guard let storage = textStorage, paragraph.length > 0 else { return nil }
        let last = glyphIndexForCharacter(at: NSMaxRange(paragraph) - 1)
        guard last < numberOfGlyphs else { return nil }
        let font = storage.attribute(.font, at: paragraph.location, effectiveRange: nil) as? NSFont ?? .systemFont(ofSize: 14)
        guard let baseline = baseline(atGlyph: last, font: font) else { return nil }
        // After the words (the used room's width is theirs, pictures under them or not).
        let used = lineFragmentUsedRect(forGlyphAt: last, effectiveRange: nil)
        let height = (font.capHeight + 8).rounded()
        let width = (height * 1.7).rounded()
        let middle = baseline - font.capHeight / 2
        return NSRect(x: used.maxX + 6 + origin.x, y: (middle - height / 2).rounded() + origin.y, width: width, height: height)
    }

    /// A pill with three dots in it: what's folded away.
    static func drawFoldPill(in rect: NSRect) {
        NSColor.labelColor.withAlphaComponent(0.07).setFill()
        NSBezierPath(roundedRect: rect, xRadius: rect.height / 2, yRadius: rect.height / 2).fill()
        Theme.secondaryText.setFill()
        let dot = max(2.5, (rect.height * 0.17).rounded(.toNearestOrEven))
        let gap = dot * 1.1
        let total = 3 * dot + 2 * gap
        for i in 0..<3 {
            let x = rect.midX - total / 2 + CGFloat(i) * (dot + gap)
            NSBezierPath(ovalIn: NSRect(x: x, y: rect.midY - dot / 2, width: dot, height: dot)).fill()
        }
    }

    /// The folded row whose pill is at a point.
    func foldPillHit(at point: NSPoint, origin: NSPoint) -> Int? {
        guard let view, let storage = textStorage else { return nil }
        for (index, paragraph) in view.paragraphRanges.enumerated() where NoteOutlineText.style(storage, at: paragraph.location).row.isFolded {
            if let pill = foldPill(for: paragraph, origin: origin), pill.insetBy(dx: -4, dy: -4).contains(point) { return index }
        }
        return nil
    }
}

/// Lays out hidden markup as nothing: no ink, no width — a control
/// character of no advance rather than a null glyph (a line starting with
/// null glyphs is measured from the line before it).
final class NoteHiddenGlyphs: NSObject, NSLayoutManagerDelegate {
    func layoutManager(_ layoutManager: NSLayoutManager, shouldGenerateGlyphs glyphs: UnsafePointer<CGGlyph>,
                       properties: UnsafePointer<NSLayoutManager.GlyphProperty>, characterIndexes: UnsafePointer<Int>,
                       font: NSFont, forGlyphRange range: NSRange) -> Int {
        guard let storage = layoutManager.textStorage else { return 0 }
        var any = false
        for i in 0..<range.length where storage.attribute(.noteHidden, at: characterIndexes[i], effectiveRange: nil) != nil { any = true; break }
        guard any else { return 0 }
        var changed = [NSLayoutManager.GlyphProperty](UnsafeBufferPointer(start: properties, count: range.length))
        for i in 0..<range.length where storage.attribute(.noteHidden, at: characterIndexes[i], effectiveRange: nil) != nil {
            changed[i] = .controlCharacter
        }
        layoutManager.setGlyphs(glyphs, properties: changed, characterIndexes: characterIndexes, font: font, forGlyphRange: range)
        return range.length
    }

    func layoutManager(_ layoutManager: NSLayoutManager, shouldUse action: NSLayoutManager.ControlCharacterAction,
                       forControlCharacterAt index: Int) -> NSLayoutManager.ControlCharacterAction {
        layoutManager.textStorage?.attribute(.noteHidden, at: index, effectiveRange: nil) != nil ? .zeroAdvancement : action
    }
}

// MARK: - The editor

/// An outline edited as text, a row a paragraph (Prism's, after Bike): a
/// row always takes its children along — indented, outdented, moved.
final class NoteOutlineTextView: NSTextView {
    var metrics: NoteOutlineMetrics {
        didSet {
            guard metrics != oldValue else { return }
            styler.metrics = metrics
            styler.styleAll(textStorage!)
        }
    }
    let styler: NoteOutlineStyler
    /// Told when the rows changed, by typing or a command.
    var onRowsChanged: (() -> Void)?
    /// Set while the view changes its own text.
    var adjusting = false
    private var loading = false
    /// Its own: ⌘Z in an outline undoes the outline's edits, not the
    /// desk's (whose undo the window's chain reaches first).
    private let undo = UndoManager()
    override var undoManager: UndoManager? { undo }
    /// The rows selected as rows, when they are (Escape, or a selection
    /// reaching past a row), and its anchor and head.
    private(set) var selectedRows: Range<Int>?
    private(set) var rowAnchor = 0
    private(set) var rowHead = 0
    var isSelectingRows: Bool { selectedRows != nil }
    /// How selected text looks, set aside while rows are selected (they
    /// look like rows instead).
    private var textSelectionAttributes: [NSAttributedString.Key: Any] = [:]
    private let hiddenGlyphs = NoteHiddenGlyphs()
    /// The rows being dragged from here, by their bullets.
    var draggedRows: Range<Int>?
    /// Debugging: the last rows begun to be dragged.
    var debugDragBegan: String?
    /// Where dragged rows would go.
    let dropLine = NSView()
    /// A link clicked: followed, by the one rule.
    var onOpen: ((String) -> Void)?
    /// A picture dropped, kept for the note (as an image block): given the
    /// Markdown that shows it.
    var keepImage: ((Data, String, @escaping (String) -> Void) -> Void)?
    /// A block's card (a place's in it), for a row that's only its embed.
    var cardFor: ((BlockID, String?) -> SummaryCardContent?)? {
        get { styler.cardFor }
        set { styler.cardFor = newValue }
    }

    /// The blocks' cards, as their summaries are now: the rows showing one
    /// that changed styled again.
    func refreshCards() {
        guard let storage = textStorage, let cardFor else { return }
        var stale: [NSRange] = []
        storage.enumerateAttribute(.noteCard, in: NSRange(location: 0, length: storage.length)) { value, run, _ in
            guard let card = value as? NoteCard else { return }
            if card.content.differs(from: cardFor(card.block, card.place)) { stale.append(run) }
        }
        guard !stale.isEmpty else { return }
        storage.beginEditing()
        for r in stale { storage.edited(.editedAttributes, range: r, changeInLength: 0) }
        storage.endEditing()
    }
    /// A block dropped in by its link (or reference, card): linked from the note.
    var onLinked: ((BlockID) -> Void)?
    /// The row focused on (Focus In), the rest of the note set aside.
    var focus: NoteOutlineFocus?
    /// Threads on rows shown (by index), marked at their right (ThreadMarks.swift).
    var threadMarks: [Int: ThreadMark.State] = [:] { didSet { if threadMarks != oldValue { needsDisplay = true } } }
    /// A row's mark clicked: the row, and where its mark is.
    var onThreads: ((Int, NSRect) -> Void)?

    /// Where a row's thread mark is: at the right of what's shown, on the
    /// row's first line.
    func threadMarkRect(row: Int) -> NSRect? {
        guard let m = threadMarks[row], let lm = layoutManager, paragraphRanges.indices.contains(row) else { return nil }
        let loc = paragraphRanges[row].location
        guard loc < (textStorage?.length ?? 0) || loc == 0 else { return nil }
        let glyph = lm.glyphIndexForCharacter(at: min(loc, max(0, (textStorage?.length ?? 1) - 1)))
        var line = lm.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
        guard line.height > 0 else { return nil }
        line.origin.y += textContainerOrigin.y
        return ThreadMark.rect(m, right: min(visibleRect.maxX, bounds.maxX), lineTop: line.minY, lineHeight: min(line.height, 26))
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        for (row, m) in threadMarks {
            guard let r = threadMarkRect(row: row), r.intersects(dirtyRect) else { continue }
            ThreadMark.draw(m, in: r)
        }
    }
    /// Told when the focus changed (its path shown over the rows).
    var onFocusChange: (() -> Void)?
    /// The row the pointer is over: a ghost of a bullet before a row with
    /// none, to click (a heading's folds its section) or drag by.
    var hoveredRow: Int? { didSet { if hoveredRow != oldValue { needsDisplay = true } } }
    /// Where the picture under the pointer starts, its grip shown.
    var hoveredPicture: Int?
    /// Expand Selection's steps, to go back along (Contract Selection), and
    /// the selection the last one made.
    var expansions: [OutlineSelection] = []
    var expanded: OutlineSelection?

    init(metrics: NoteOutlineMetrics) {
        self.metrics = metrics
        styler = NoteOutlineStyler(metrics: metrics)
        let storage = NSTextStorage()
        let layout = NoteOutlineLayoutManager()
        storage.addLayoutManager(layout)
        let container = NSTextContainer(size: NSSize(width: 400, height: CGFloat.greatestFiniteMagnitude))
        container.widthTracksTextView = true
        container.lineFragmentPadding = 0
        layout.addTextContainer(container)
        super.init(frame: NSRect(x: 0, y: 0, width: 400, height: 40), textContainer: container)
        layout.view = self
        layout.delegate = hiddenGlyphs
        storage.delegate = styler
        styler.onCharactersEdited = { [weak self] in self?.paragraphCache = nil }
        isRichText = false
        importsGraphics = false
        allowsUndo = true
        usesFindBar = true
        isIncrementalSearchingEnabled = true
        isContinuousSpellCheckingEnabled = true
        drawsBackground = false
        isAutomaticLinkDetectionEnabled = false
        isAutomaticQuoteSubstitutionEnabled = false
        isAutomaticDashSubstitutionEnabled = false
        isAutomaticTextReplacementEnabled = false
        insertionPointColor = Theme.accent
        linkTextAttributes = [.cursor: NSCursor.pointingHand, .foregroundColor: Theme.accent]
        textSelectionAttributes = selectedTextAttributes
        dropLine.wantsLayer = true
        dropLine.layer?.backgroundColor = Theme.accent.cgColor
        dropLine.isHidden = true
        addSubview(dropLine)
        registerForDraggedTypes([Self.rowsType] + Dragged.types)
        load([.blank], keepingCaret: false)
    }

    required init?(coder: NSCoder) { fatalError() }

    // MARK: Rows

    /// Rows on screen, in place of what was there: the caret kept on its
    /// row and place if asked (a change from elsewhere), else at the top.
    func load(_ rows: [NoteRow], keepingCaret: Bool) {
        let caret = keepingCaret ? caretPosition : CaretPosition(row: 0, offset: 0)
        adjusting = true
        loading = true
        textStorage!.setAttributedString(NoteOutlineText.attributed(rows.isEmpty ? [.blank] : rows))
        styler.styleAll(textStorage!)
        loading = false
        adjusting = false
        paragraphCache = nil
        if selectedRows != nil { leaveRowSelection() }
        restoreCaret(caret)
        // Read anew (a change from elsewhere): what was done here before
        // can't be undone over it.
        undo.removeAllActions()
    }

    @objc func undo(_ sender: Any?) { if undo.canUndo { undo.undo() } else { NSSound.beep() } }
    @objc func redo(_ sender: Any?) { if undo.canRedo { undo.redo() } else { NSSound.beep() } }

    override func validateUserInterfaceItem(_ item: NSValidatedUserInterfaceItem) -> Bool {
        if let ok = validateOutline(item) { return ok }
        if item.action == #selector(undo(_:)) { return undo.canUndo }
        if item.action == #selector(redo(_:)) { return undo.canRedo }
        return super.validateUserInterfaceItem(item)
    }

    var rows: [NoteRow] { NoteOutlineText.rows(textStorage!) }

    private var paragraphCache: [NSRange]?
    var paragraphRanges: [NSRange] {
        if let paragraphCache { return paragraphCache }
        let r = NoteOutlineText.paragraphs(textStorage!.string as NSString)
        paragraphCache = r
        return r
    }

    func rowIndex(at location: Int) -> Int {
        let ranges = paragraphRanges
        var low = 0, high = max(0, ranges.count - 1)
        while low < high {
            let middle = (low + high + 1) / 2
            if ranges[middle].location <= location { low = middle } else { high = middle - 1 }
        }
        return low
    }

    func row(at index: Int) -> NoteRow { NoteOutlineText.style(textStorage!, at: paragraphRanges[index].location).row }

    /// The last place a caret can be: before the last line break.
    var lastLocation: Int { max(0, textStorage!.length - 1) }

    override func didChangeText() {
        paragraphCache = nil
        if !adjusting { tidy() }
        super.didChangeText()
        needsDisplay = true
        if !loading { onRowsChanged?() }
    }

    /// What an edit can leave wrong put right: the text ends in a line
    /// break, rows an edit swallowed come back, every row at a depth
    /// Markdown can write.
    private func tidy() {
        adjusting = true
        defer { adjusting = false }
        let storage = textStorage!
        if storage.length == 0 || !storage.string.hasSuffix("\n") {
            let style = storage.length > 0 ? NoteOutlineText.style(storage, at: storage.length - 1) : NoteRowStyle(.blank)
            let selection = selectedRange()
            if shouldChangeText(in: NSRange(location: storage.length, length: 0), replacementString: "\n") {
                storage.append(NSAttributedString(string: "\n", attributes: [.noteRow: style]))
                super.didChangeText()
            }
            setSelectedRange(selection)
        }
        paragraphCache = nil
        let orphans = styler.orphans
        styler.orphans = []
        let before = rows
        var after = before
        for orphan in orphans.reversed() { after.insert(contentsOf: orphan.rows, at: rowIndex(at: min(orphan.location, lastLocation)) + 1) }
        NoteOutlineEditing.normalize(&after)
        if after != before {
            let caret = caretPosition
            replace(before, with: after, actionName: nil)
            restoreCaret(caret)
        }
    }

    /// The rows on screen replaced, only the paragraphs that differ, as one
    /// step to undo.
    func replace(_ before: [NoteRow], with after: [NoteRow], actionName: String?) {
        var prefix = 0
        while prefix < before.count, prefix < after.count, before[prefix] == after[prefix] { prefix += 1 }
        var suffix = 0
        while suffix < before.count - prefix, suffix < after.count - prefix, before[before.count - 1 - suffix] == after[after.count - 1 - suffix] { suffix += 1 }
        let ranges = paragraphRanges
        let start = prefix < ranges.count ? ranges[prefix].location : textStorage!.length
        let end = before.count - suffix > prefix ? NSMaxRange(ranges[before.count - suffix - 1]) : start
        let range = NSRange(location: start, length: end - start)
        let replacement = NoteOutlineText.attributed(Array(after[prefix..<(after.count - suffix)]))
        guard range.length > 0 || replacement.length > 0 else { return }
        let was = adjusting
        adjusting = true
        breakUndoCoalescing()
        if shouldChangeText(in: range, replacementString: replacement.string) {
            textStorage!.replaceCharacters(in: range, with: replacement)
            didChangeText()
        }
        adjusting = was
        if let actionName { undoManager?.setActionName(actionName) }
    }

    func replaceRow(_ index: Int, with row: NoteRow, actionName: String?) {
        var after = rows
        let before = after
        after[index] = row
        replace(before, with: after, actionName: actionName)
    }

    struct CaretPosition { var row: Int; var offset: Int }

    var caretPosition: CaretPosition {
        let location = selectedRange().location
        let row = rowIndex(at: location)
        return CaretPosition(row: row, offset: location - (paragraphRanges.indices.contains(row) ? paragraphRanges[row].location : 0))
    }

    func restoreCaret(_ position: CaretPosition) {
        let ranges = paragraphRanges
        guard !ranges.isEmpty else { return }
        let row = min(max(position.row, 0), ranges.count - 1)
        let offset = min(max(position.offset, 0), ranges[row].length - 1)
        setSelectedRange(NSRange(location: ranges[row].location + offset, length: 0))
    }

    func goTo(row index: Int) {
        restoreCaret(CaretPosition(row: index, offset: 0))
        scrollRangeToVisible(selectedRange())
    }

    /// The rows a command applies to: those selected, or the selection's.
    var targetRows: Range<Int> {
        if let selectedRows { return selectedRows }
        let range = selectedRange()
        return rowIndex(at: range.location)..<(rowIndex(at: max(range.location, NSMaxRange(range) - 1)) + 1)
    }

    /// An outline operation on the targeted rows, as one step to undo, the
    /// caret kept on the rows it was on.
    @discardableResult
    func perform(_ name: String, on selection: Range<Int>? = nil, followingCaret: Bool = true,
                 _ transform: (inout [NoteRow], Range<Int>) -> Range<Int>?) -> Bool {
        let before = rows
        let target = selection ?? targetRows
        let caret = caretPosition
        let wasSelectingRows = isSelectingRows
        var after = before
        guard let result = transform(&after, target) else { NSSound.beep(); return false }
        replace(before, with: after, actionName: name)
        if wasSelectingRows {
            // Rows selected stay selected, where they went.
            if followingCaret { selectRows(anchor: result.lowerBound, head: max(result.lowerBound, result.upperBound - 1)) }
            else { selectRows(anchor: min(rowAnchor, paragraphRanges.count - 1), head: min(rowHead, paragraphRanges.count - 1)) }
            scrollRangeToVisible(selectedRange())
            return true
        }
        if followingCaret {
            restoreCaret(CaretPosition(row: min(result.lowerBound + (caret.row - target.lowerBound), paragraphRanges.count - 1), offset: caret.offset))
        } else {
            restoreCaret(CaretPosition(row: caret.row < target.upperBound ? caret.row : caret.row + after.count - before.count, offset: caret.offset))
        }
        scrollRangeToVisible(selectedRange())
        return true
    }

    override func setSelectedRanges(_ ranges: [NSValue], affinity: NSSelectionAffinity, stillSelecting: Bool) {
        guard let storage = textStorage, storage.length > 0, let first = ranges.first?.rangeValue else {
            return super.setSelectedRanges(ranges, affinity: affinity, stillSelecting: stillSelecting)
        }
        // Never past the last line break: there's no row there.
        var range = ranges.map(\.rangeValue).reduce(first, NSUnionRange)
        let end = min(NSMaxRange(range), lastLocation)
        range.location = min(range.location, lastLocation)
        range.length = max(0, end - range.location)
        if !adjusting {
            // Never within hidden markup: to its edge, the way it was going.
            let old = selectedRange()
            let start = snap(range.location, forward: range.location > old.location)
            let finish = range.length == 0 ? start : snap(NSMaxRange(range), forward: NSMaxRange(range) > NSMaxRange(old))
            range = NSRange(location: start, length: max(0, finish - start))
            // Selecting past a row selects rows.
            let top = rowIndex(at: range.location), bottom = rowIndex(at: max(range.location, NSMaxRange(range) - 1))
            if top != bottom {
                let anchor = selectedRows == nil ? rowIndex(at: selectedRange().location) : rowAnchor
                return selectRows(anchor: anchor, head: anchor == top ? bottom : top, stillSelecting: stillSelecting)
            }
            if selectedRows != nil { leaveRowSelection() }
        }
        let was = selectedRange()
        super.setSelectedRanges([NSValue(range: range)], affinity: affinity, stillSelecting: stillSelecting)
        // A picture selected, or no longer, is ringed or not: drawn again.
        if was != range, let storage = textStorage, [was, range].contains(where: { Self.hasPicture(storage, in: $0) }) { needsDisplay = true }
        typingAttributes = storage.attributes(at: min(paragraphRanges[rowIndex(at: range.location)].location, storage.length - 1), effectiveRange: nil)
            .filter { $0.key != .noteHidden && $0.key != .link }
    }

    // MARK: Rows as rows

    func selectRows(anchor: Int, head: Int, stillSelecting: Bool = false) {
        let count = paragraphRanges.count
        rowAnchor = min(max(anchor, 0), count - 1)
        rowHead = min(max(head, 0), count - 1)
        let picked = min(rowAnchor, rowHead)..<(max(rowAnchor, rowHead) + 1)
        if selectedRows == nil { selectedTextAttributes = [:] }
        selectedRows = picked
        let ranges = paragraphRanges
        let start = ranges[picked.lowerBound].location
        let end = min(NSMaxRange(ranges[picked.upperBound - 1]), lastLocation)
        let was = adjusting
        adjusting = true
        super.setSelectedRanges([NSValue(range: NSRange(location: start, length: max(0, end - start)))], affinity: .downstream, stillSelecting: stillSelecting)
        adjusting = was
        needsDisplay = true
    }

    func leaveRowSelection() {
        selectedRows = nil
        selectedTextAttributes = textSelectionAttributes
        needsDisplay = true
    }

    /// Back to editing text, the caret at a row's end (or start).
    func editText(inRow index: Int, atEnd: Bool = true) {
        leaveRowSelection()
        let paragraph = paragraphRanges[min(index, paragraphRanges.count - 1)]
        setSelectedRange(NSRange(location: atEnd ? NSMaxRange(paragraph) - 1 : paragraph.location, length: 0))
        scrollRangeToVisible(selectedRange())
    }

    func scrollRowToVisible(_ index: Int) {
        guard paragraphRanges.indices.contains(index) else { return }
        scrollRangeToVisible(paragraphRanges[index])
    }

    /// Escape: the caret's row selected as a row; again, back to its text.
    override func cancelOperation(_ sender: Any?) {
        if selectedRows != nil { return editText(inRow: rowHead) }
        let row = rowIndex(at: selectedRange().location)
        selectRows(anchor: row, head: row)
    }

    /// ⌘A: the row's text; again, every row.
    override func selectAll(_ sender: Any?) {
        let row = rowIndex(at: selectedRange().location)
        let paragraph = paragraphRanges[row]
        let text = NSRange(location: paragraph.location, length: paragraph.length - 1)
        if selectedRows == nil, selectedRange() != text, text.length > 0 { setSelectedRange(text) }
        else { selectRows(anchor: 0, head: paragraphRanges.count - 1) }
    }

    override func moveUp(_ sender: Any?) {
        guard selectedRows != nil else { return super.moveUp(sender) }
        if rowHead == 0 { return NSSound.beep() }
        selectRows(anchor: rowHead - 1, head: rowHead - 1)
        scrollRowToVisible(rowHead)
    }

    override func moveDown(_ sender: Any?) {
        guard selectedRows != nil else { return super.moveDown(sender) }
        let last = paragraphRanges.count - 1
        if rowHead == last { return NSSound.beep() }
        selectRows(anchor: rowHead + 1, head: rowHead + 1)
        scrollRowToVisible(rowHead)
    }

    override func moveUpAndModifySelection(_ sender: Any?) {
        if selectedRows != nil { selectRows(anchor: rowAnchor, head: rowHead - 1); return scrollRowToVisible(rowHead) }
        super.moveUpAndModifySelection(sender)
    }

    override func moveDownAndModifySelection(_ sender: Any?) {
        if selectedRows != nil { selectRows(anchor: rowAnchor, head: rowHead + 1); return scrollRowToVisible(rowHead) }
        super.moveDownAndModifySelection(sender)
    }

    /// ← and →: with rows selected, fold and unfold them; in text, a
    /// character, over hidden markup.
    override func moveLeft(_ sender: Any?) {
        if selectedRows != nil { return collapse(sender) }
        if !stepOverMarkup(forward: false) { super.moveLeft(sender) }
    }

    override func moveRight(_ sender: Any?) {
        if selectedRows != nil { return expand(sender) }
        if !stepOverMarkup(forward: true) { super.moveRight(sender) }
    }

    // MARK: Hidden markup

    /// The text of the row a place is in, its line break left out.
    func textRange(ofRowAt location: Int) -> NSRange {
        let paragraph = paragraphRanges[rowIndex(at: location)]
        return NSRange(location: paragraph.location, length: max(0, paragraph.length - 1))
    }

    /// The inline spans of the row a place is in (none in code).
    func spans(atRowOf location: Int) -> [InlineSpan] {
        guard let storage = textStorage, storage.length > 0 else { return [] }
        if case .code = row(at: rowIndex(at: location)).kind { return [] }
        return NoteOutlineText.spans(in: storage.string as NSString, range: textRange(ofRowAt: location), shown: styler.shows)
    }

    private func snap(_ location: Int, forward: Bool) -> Int {
        guard textStorage!.length > 0 else { return location }
        return InlineEditing.snap(location, runs: spans(atRowOf: location).flatMap(\.markup), forward: forward)
    }

    /// A character on within the row, stopping on both sides of hidden
    /// markup; false when the row's edge is that way.
    private func stepOverMarkup(forward: Bool) -> Bool {
        let range = selectedRange()
        guard range.length == 0, textStorage!.length > 0 else { return false }
        let bounds = textRange(ofRowAt: range.location)
        if forward ? range.location >= NSMaxRange(bounds) : range.location <= bounds.location { return false }
        let next = InlineEditing.step(from: range.location, forward: forward, text: textStorage!.string as NSString,
                                      within: bounds, spans: spans(atRowOf: range.location))
        let was = adjusting
        adjusting = true
        setSelectedRange(NSRange(location: next, length: 0))
        adjusting = was
        scrollRangeToVisible(selectedRange())
        return true
    }

    /// The nearest shown character deleted, as Bike does, when hidden
    /// markup is in the way or the character is all a span shows; false
    /// when an ordinary delete will do.
    private func deleteShown(forward: Bool) -> Bool {
        let caret = selectedRange()
        guard caret.length == 0, textStorage!.length > 0 else { return false }
        let bounds = textRange(ofRowAt: caret.location)
        let spans = spans(atRowOf: caret.location)
        let text = textStorage!.string as NSString
        guard !spans.isEmpty, let target = InlineEditing.deletion(at: caret.location, forward: forward, text: text, within: bounds, spans: spans) else { return false }
        let adjacent = forward ? target.location == caret.location : NSMaxRange(target) == caret.location
        if adjacent, target.length == text.rangeOfComposedCharacterSequence(at: target.location).length { return false }
        let after = forward ? caret.location : caret.location - target.length
        let was = adjusting
        adjusting = true
        if shouldChangeText(in: target, replacementString: "") {
            textStorage!.replaceCharacters(in: target, with: "")
            didChangeText()
        }
        adjusting = was
        tidy()
        setSelectedRange(NSRange(location: min(NSMaxRange(target) <= caret.location ? after : caret.location, lastLocation), length: 0))
        return true
    }

    /// Misspellings marked in what's shown, not in hidden markup (a
    /// picture's path, a link's address, a block's id).
    override func setSpellingState(_ value: Int, range: NSRange) {
        guard value != 0, let storage = textStorage, NSMaxRange(range) <= storage.length else { return super.setSpellingState(value, range: range) }
        storage.enumerateAttribute(.noteHidden, in: range) { hidden, piece, _ in
            if hidden == nil { super.setSpellingState(value, range: piece) }
        }
    }

    /// An edit that would take some of a span's markup but not all of it
    /// leaves that markup be, so the span's text keeps its style.
    override func shouldChangeText(inRanges ranges: [NSValue], replacementStrings strings: [String]?) -> Bool {
        guard !adjusting, ranges.count == 1, let replacement = strings?.first, let storage = textStorage else {
            return super.shouldChangeText(inRanges: ranges, replacementStrings: strings)
        }
        let range = ranges[0].rangeValue
        guard range.length > 0, NSMaxRange(range) <= storage.length else { return super.shouldChangeText(inRanges: ranges, replacementStrings: strings) }
        let text = storage.string as NSString
        let spans = NoteOutlineText.spans(in: text, range: text.paragraphRange(for: range), shown: styler.shows)
        let pieces = InlineEditing.deletablePieces(of: range, spans: spans)
        guard pieces != [range] else { return super.shouldChangeText(inRanges: ranges, replacementStrings: strings) }
        var kept = ""
        var location = range.location
        for piece in pieces {
            kept += text.substring(with: NSRange(location: location, length: piece.location - location))
            location = NSMaxRange(piece)
        }
        kept += text.substring(with: NSRange(location: location, length: NSMaxRange(range) - location))
        adjusting = true
        let changed = super.shouldChangeText(inRanges: ranges, replacementStrings: [replacement + kept])
        if changed {
            storage.replaceCharacters(in: range, with: NSAttributedString(string: replacement + kept, attributes: typingAttributes))
            didChangeText()
        }
        adjusting = false
        if changed {
            setSelectedRange(NSRange(location: range.location + (replacement as NSString).length, length: 0))
            tidy()
        }
        return false
    }

    /// A link clicked: followed by the one rule (a note's `manifold:` link
    /// to its block, a web address, a path).
    override func clicked(onLink link: Any, at charIndex: Int) {
        guard let target = (link as? URL)?.absoluteString ?? link as? String else { return }
        onOpen?(target)
    }

    // MARK: Keys

    override func keyDown(with event: NSEvent) {
        let mods = event.modifierFlags.intersection([.shift, .command, .option, .control])
        // ⇧Return: the row goes on, on a line of its own.
        if [36, 76].contains(event.keyCode), mods == .shift { return insertLineBreak(nil) }
        // ⌃⌘↑ ⌃⌘↓ (an editor's line moves): the row among its siblings.
        if mods == [.command, .control], event.keyCode == 126 { return moveRowsUp(nil) }
        if mods == [.command, .control], event.keyCode == 125 { return moveRowsDown(nil) }
        super.keyDown(with: event)
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        // ⌘Return, as Prism has it: a checkbox — open, checked, then a bullet again.
        guard window?.firstResponder === self else { return super.performKeyEquivalent(with: event) }
        let mods = event.modifierFlags.intersection([.shift, .command, .option, .control])
        if [36, 76].contains(event.keyCode), mods == .command { cycleChecklist(nil); return true }
        // Folds (⌘9 and ⌘0 are spaces' here): ⌃⌘ the rows', ⌥⌘ all.
        switch (mods, event.charactersIgnoringModifiers) {
        case ([.command, .control], "9"): collapse(nil); return true
        case ([.command, .control], "0"): expand(nil); return true
        case ([.command, .option], "9"): collapseAll(nil); return true
        case ([.command, .option], "0"): expandAll(nil); return true
        default: break
        }
        return super.performKeyEquivalent(with: event)
    }

    override func insertText(_ string: Any, replacementRange: NSRange) {
        let typed = (string as? NSAttributedString)?.string ?? string as? String ?? ""
        // Rows selected: space checks them off; nothing else is typed over them.
        if selectedRows != nil {
            if typed == " " { toggleDone(nil) } else { NSSound.beep() }
            return
        }
        if typed == " ", replacementRange.location == NSNotFound, selectedRange().length == 0, applySmartRowType() { return }
        super.insertText(string, replacementRange: replacementRange)
    }

    override func insertTab(_ sender: Any?) {
        // In code, a tab is spaces, not a deeper row.
        if case .code = row(at: rowIndex(at: selectedRange().location)).kind {
            return insertText("    ", replacementRange: selectedRange())
        }
        indentRows(sender)
    }

    override func insertBacktab(_ sender: Any?) { outdentRows(sender) }

    override func insertNewline(_ sender: Any?) {
        // Return from rows: a new row after them, to write in.
        if let selectedRows {
            let index = selectedRows.upperBound - 1
            editText(inRow: index)
            return splitRow()
        }
        let index = rowIndex(at: selectedRange().location)
        // (Its text as it is now, not as last styled.)
        let current = rows[index]
        // `---` alone on a row, then Return: a line across.
        if selectedRange().length == 0, current.task == nil, current.kind == .bullet || current.kind == .paragraph,
           ["---", "***", "___"].contains(current.text.trimmingCharacters(in: .whitespaces)) {
            return makeRule(at: index)
        }
        // ``` (a language after it, or not) alone on a row, then Return: a
        // code block, the caret in it.
        let typed = current.text.trimmingCharacters(in: .whitespaces)
        if selectedRange().length == 0, current.task == nil, current.kind == .bullet || current.kind == .paragraph,
           let marker = NoteOutlineMarkdown.fenceMarker(typed) {
            return makeCode(at: index, opening: typed, closing: marker)
        }
        // Past a code block's closing fence: a row after it, to write in.
        if current.kind == .code, selectedRange().length == 0, selectedRange().location == rowEnd(index), Self.closes(current.text) {
            var all = rows
            let before = all
            all.insert(NoteRow(kind: .bullet, depth: current.depth, gap: []), at: index + 1)
            NoteOutlineEditing.normalize(&all)
            replace(before, with: all, actionName: "New Row")
            return restoreCaret(CaretPosition(row: index + 1, offset: 0))
        }
        splitRow()
    }

    override func insertNewlineIgnoringFieldEditor(_ sender: Any?) { insertNewline(sender) }

    override func insertLineBreak(_ sender: Any?) {
        if case .heading = row(at: rowIndex(at: selectedRange().location)).kind { return splitRow() }
        insertText(NoteOutlineText.lineSeparator, replacementRange: selectedRange())
    }

    override func deleteBackward(_ sender: Any?) {
        if selectedRows != nil { return deleteRows(sender) }
        let range = selectedRange()
        if range.length == 0 {
            let index = rowIndex(at: range.location)
            if range.location == paragraphRanges[index].location {
                var row = row(at: index)
                // At the start of a row of some kind, it's a plain row first.
                if row.task != nil || !(row.kind == .bullet || row.kind == .paragraph) {
                    if row.task != nil { row.task = nil; row.marker = "-" } else { row.kind = .bullet; row.marker = "-"; row.spacing = 1 }
                    row.text = rows[index].text
                    replaceRow(index, with: row, actionName: "Change Row Type")
                    setSelectedRange(NSRange(location: paragraphRanges[index].location, length: 0))
                    return
                }
                // An empty row deeper in: out a level first.
                if row.depth > 0, row.text.isEmpty, rows[index].text.isEmpty {
                    outdentRows(sender)
                    return
                }
                if index == 0 { return }
            }
        }
        if !deleteShown(forward: false) { super.deleteBackward(sender) }
    }

    override func deleteForward(_ sender: Any?) {
        if selectedRows != nil { return deleteRows(sender) }
        if selectedRange().length == 0, selectedRange().location >= lastLocation { return }
        if !deleteShown(forward: true) { super.deleteForward(sender) }
    }

    // MARK: Commands

    /// Return: the text after the caret a new row. On an empty list item
    /// deeper in, out a level instead; at the end of a row whose children
    /// show, its first child.
    func splitRow() {
        if selectedRange().length > 0 { insertText("", replacementRange: selectedRange()) }
        let location = selectedRange().location
        let index = rowIndex(at: location)
        let paragraph = paragraphRanges[index]
        var all = rows
        let before = all
        let row = all[index]
        if row.kind == .code {
            // On the closing fence, or on an empty line just before it: out
            // of the block (that line gone), into a row after it.
            let lines = row.text.components(separatedBy: "\n")
            let line = ((row.text as NSString).substring(to: min(location - paragraph.location, (row.text as NSString).length))).components(separatedBy: "\n").count - 1
            let onEmptyLast = line == lines.count - 2 && line > 0 && lines[line].trimmingCharacters(in: .whitespaces).isEmpty
            if Self.closes(row.text), line == lines.count - 1 || onEmptyLast {
                if onEmptyLast { all[index].text = (lines[..<line] + lines[(line + 1)...]).joined(separator: "\n") }
                all.insert(NoteRow(kind: .bullet, depth: row.depth, gap: []), at: index + 1)
                NoteOutlineEditing.normalize(&all)
                replace(before, with: all, actionName: "New Row")
                return restoreCaret(CaretPosition(row: index + 1, offset: 0))
            }
            return insertText(NoteOutlineText.lineSeparator, replacementRange: selectedRange())
        }
        // An empty item: out a level, as lists do; at the top, a plain row.
        if row.text.isEmpty, row.kind.isListItem, !row.isFolded {
            if row.depth > 0 { return outdentRows(nil) }
            if row.task != nil {
                all[index].task = nil
                replace(before, with: all, actionName: "Change Row Type")
                return restoreCaret(CaretPosition(row: index, offset: 0))
            }
        }
        let offset = location - paragraph.location
        let length = paragraph.length - 1
        var next = row
        next.text = ""
        next.folded = []
        next.continuationIndents = nil
        let siblingAbove = NoteOutlineEditing.previousSibling(all, before: index, depth: row.depth).map { all[$0].kind.isListItem } ?? false
        next.gap = !row.gap.isEmpty && siblingAbove ? [""] : []
        if next.task != nil { next.task = .open }
        if next.kind == .ordered { next.number += 1 }
        switch next.kind {
        case .heading, .rule: next = NoteRow(kind: .bullet, depth: row.depth, gap: [""])
        case .quote, .paragraph: break
        default: break
        }
        if offset == 0, length > 0 {
            // At a row's start: a new row above, the text staying with its children.
            all.insert(next, at: index)
            replace(before, with: all, actionName: "New Row")
            restoreCaret(CaretPosition(row: index + 1, offset: 0))
        } else {
            let text = row.text as NSString
            all[index].text = text.substring(to: min(offset, text.length))
            next.text = text.substring(from: min(offset, text.length))
            if offset == length, NoteOutlineEditing.subtreeEnd(all, index) > index + 1 {
                let child = all[index + 1]
                next.depth = child.depth
                if child.kind.isListItem, row.kind.isListItem {
                    next.kind = child.kind
                    next.marker = child.marker
                    next.number = 1
                    next.task = child.task == nil ? nil : .open
                }
                next.gap = child.gap
            }
            all.insert(next, at: index + 1)
            replace(before, with: all, actionName: "New Row")
            restoreCaret(CaretPosition(row: index + 1, offset: 0))
        }
        scrollRangeToVisible(selectedRange())
    }

    /// Markdown typed at a row's start, then a space, sets its kind: `#`s a
    /// heading, `>` a quote, `[ ]` or `[x]` a checkbox, `+` a task, `-` `*`
    /// a bullet, `1.` a numbered item, `---` a line across.
    func applySmartRowType() -> Bool {
        let location = selectedRange().location
        let index = rowIndex(at: location)
        let paragraph = paragraphRanges[index]
        let prefix = (textStorage!.string as NSString).substring(with: NSRange(location: paragraph.location, length: location - paragraph.location))
        var row = rows[index]
        guard row.task == nil, row.kind == .bullet || row.kind == .paragraph, !prefix.isEmpty, prefix.count <= 6 else { return false }
        let rest = String(row.text.dropFirst(prefix.count))
        switch prefix {
        case _ where prefix.allSatisfy({ $0 == "#" }): row.kind = .heading(prefix.count)
        case ">": row.kind = .quote
        case "---", "***", "___" where rest.trimmingCharacters(in: .whitespaces).isEmpty:
            // A line across, a row after it to write in.
            makeRule(at: index)
            return true
        case "+":
            // A task: round, open.
            row.kind = .bullet
            row.marker = "+"
            row.task = .open
        case "[]", "[ ]", "[x]", "[X]", "-[]", "-[ ]":
            row.kind = .bullet
            row.marker = row.marker == "*" ? "*" : "-"
            row.task = prefix.lowercased().contains("x") ? .done(prefix.contains("X") ? "X" : "x") : .open
        case _ where ["-", "*", "+"].contains(prefix) && row.kind == .paragraph:
            row.kind = .bullet
            row.marker = prefix.first!
        default:
            let digits = prefix.dropLast()
            guard let delimiter = prefix.last, delimiter == "." || delimiter == ")", !digits.isEmpty, digits.allSatisfy(\.isNumber),
                  let number = Int(digits) else { return false }
            row.kind = .ordered
            row.marker = delimiter
            row.number = number
        }
        row.spacing = 1
        row.text = rest
        replaceRow(index, with: row, actionName: "Change Row Type")
        restoreCaret(CaretPosition(row: index, offset: 0))
        return true
    }

    func makeCode(at index: Int, opening: String, closing: String) {
        var all = rows
        let before = all
        all[index] = NoteRow(kind: .code, depth: all[index].depth, text: opening + "\n\n" + closing, gap: all[index].gap)
        NoteOutlineEditing.normalize(&all)
        replace(before, with: all, actionName: "Code Block")
        restoreCaret(CaretPosition(row: index, offset: (opening as NSString).length + 1))
    }

    /// Where a row's text ends (before its line break).
    func rowEnd(_ index: Int) -> Int {
        let p = paragraphRanges[index]
        let text = textStorage!.string as NSString
        return NSMaxRange(p) > p.location && text.character(at: NSMaxRange(p) - 1) == 0x0A ? NSMaxRange(p) - 1 : NSMaxRange(p)
    }

    /// Whether a code row's text ends with its closing fence.
    static func closes(_ code: String) -> Bool {
        let lines = code.components(separatedBy: "\n")
        guard lines.count >= 2, let opening = NoteOutlineMarkdown.fenceMarker(lines[0].trimmingCharacters(in: .whitespaces)) else { return false }
        let last = lines[lines.count - 1].trimmingCharacters(in: .whitespaces)
        return last.count >= opening.count && last.allSatisfy { $0 == opening.first }
    }

    func makeRule(at index: Int) {
        var all = rows
        let before = all
        all[index] = NoteRow(kind: .rule, depth: all[index].depth, text: "---", gap: all[index].gap)
        all.insert(NoteRow(kind: .bullet, depth: all[index].depth, gap: [""]), at: index + 1)
        NoteOutlineEditing.normalize(&all)
        replace(before, with: all, actionName: "Horizontal Line")
        restoreCaret(CaretPosition(row: index + 1, offset: 0))
    }

    @objc func indentRows(_ sender: Any?) { perform("Indent") { NoteOutlineEditing.indent(&$0, $1) } }
    @objc func outdentRows(_ sender: Any?) { perform("Outdent") { NoteOutlineEditing.outdent(&$0, $1) } }
    @objc func moveRowsUp(_ sender: Any?) { perform("Move Up") { NoteOutlineEditing.moveUp(&$0, $1) } }
    @objc func moveRowsDown(_ sender: Any?) { perform("Move Down") { NoteOutlineEditing.moveDown(&$0, $1) } }

    /// ⌘Return: a checkbox — open, checked, then a bullet again.
    @objc func cycleChecklist(_ sender: Any?) {
        perform("Checklist Item") { rows, selection in
            NoteOutlineEditing.cycle(.checklist, &rows, selection)
            return selection
        }
    }

    /// Rows selected deleted, with their children.
    @objc func deleteRows(_ sender: Any?) {
        let wasSelectingRows = isSelectingRows
        var landing = 0
        perform("Delete Rows") { rows, selection in
            landing = NoteOutlineEditing.delete(&rows, selection)
            return landing..<(landing + 1)
        }
        if !wasSelectingRows { restoreCaret(CaretPosition(row: landing, offset: 0)) }
    }

    @objc func toggleDone(_ sender: Any?) {
        perform("Toggle Done") { rows, selection in NoteOutlineEditing.toggleDone(&rows, selection); return selection }
    }

    // MARK: Folding

    /// ⌃⌘9 (← with rows selected): the rows' children folded away; ⌃⌘0
    /// (→): back. ⌥⌘9 and ⌥⌘0: every row's.
    @objc func collapse(_ sender: Any?) { fold(name: "Collapse") { rows, i in -NoteOutlineEditing.fold(&rows, at: i) } }
    @objc func expand(_ sender: Any?) { fold(name: "Expand") { rows, i in NoteOutlineEditing.unfold(&rows, at: i) } }
    @objc func collapseAll(_ sender: Any?) {
        fold(name: "Collapse All", selection: 0..<paragraphRanges.count) { rows, i in -NoteOutlineEditing.foldCompletely(&rows, at: i) }
    }
    @objc func expandAll(_ sender: Any?) {
        fold(name: "Expand All", selection: 0..<paragraphRanges.count) { rows, i in NoteOutlineEditing.unfold(&rows, at: i, completely: true) }
    }

    /// Each targeted row with children folded or unfolded, the selection
    /// kept on its rows; `change` says how many rows came on screen, less
    /// how many left it.
    func fold(name: String, selection: Range<Int>? = nil, _ change: (inout [NoteRow], Int) -> Int) {
        perform(name, on: selection, followingCaret: selection == nil) { rows, selection in
            var changed = false
            var upper = selection.upperBound
            var index = selection.lowerBound
            // Only rows at the top of the selection's subtrees: a child folded
            // into its parent is no longer there to fold.
            while index < min(upper, rows.count) {
                let delta = change(&rows, index)
                if delta != 0 { changed = true }
                upper += delta
                index = NoteOutlineEditing.subtreeEnd(rows, index)
            }
            guard changed else { return nil }
            return min(selection.lowerBound, rows.count - 1)..<min(max(upper, selection.lowerBound + 1), rows.count)
        }
    }

    /// A checkbox checks; a bullet with children folds them, or unfolds
    /// (a heading's ghost, its section); one with none, its row selected.
    func clickHandle(ofRow index: Int) {
        let all = rows
        guard all.indices.contains(index) else { return }
        let row = all[index]
        let one = index..<(index + 1)
        if row.task != nil {
            perform("Toggle Done", on: one, followingCaret: false) { rows, s in NoteOutlineEditing.toggleDone(&rows, s); return s }
        } else if row.isFolded {
            perform("Expand", on: one, followingCaret: false) { rows, s in NoteOutlineEditing.unfold(&rows, at: s.lowerBound); return s }
        } else if NoteOutlineEditing.hasChildren(all, index) {
            perform("Collapse", on: one, followingCaret: false) { rows, s in NoteOutlineEditing.fold(&rows, at: s.lowerBound); return s }
        } else {
            selectRows(anchor: index, head: index)
        }
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        // A thread's mark: its threads, as a card there.
        if let onThreads, let row = threadMarks.keys.first(where: { threadMarkRect(row: $0)?.insetBy(dx: -2, dy: -2).contains(point) == true }),
           let r = threadMarkRect(row: row) {
            return onThreads(row, r)
        }
        // A picture's grip: it made larger or smaller.
        if onPictureGrip(point) { return dragPictureGrip(event) }
        // A block's card clicked: followed, as its link is.
        if let layout = layoutManager as? NoteOutlineLayoutManager,
           let card = paragraphRanges.lazy.compactMap({ layout.cardRect(of: $0, origin: self.textContainerOrigin) }).first(where: { $0.1.contains(point) })?.0 {
            onOpen?(card.target)
            return
        }
        // A fold's pill: what's in it shown.
        if let index = (layoutManager as? NoteOutlineLayoutManager)?.foldPillHit(at: point, origin: textContainerOrigin) {
            window?.makeFirstResponder(self)
            perform("Expand", on: index..<(index + 1), followingCaret: false) { rows, s in NoteOutlineEditing.unfold(&rows, at: s.lowerBound); return s }
            return
        }
        if let index = (layoutManager as? NoteOutlineLayoutManager)?.handleHit(at: point, origin: textContainerOrigin) {
            window?.makeFirstResponder(self)
            // ⌥-click: that row focused on.
            if event.modifierFlags.contains(.option) { return focusOn(fullRow: fullIndex(of: index)) }
            // Clicked, a handle does what it does; moved, it carries its row.
            let start = event.locationInWindow
            while let next = window?.nextEvent(matching: [.leftMouseUp, .leftMouseDragged]) {
                if next.type == .leftMouseUp { break }
                if hypot(next.locationInWindow.x - start.x, next.locationInWindow.y - start.y) >= 4 {
                    return beginDraggingRows(from: index, event: event)
                }
            }
            return clickHandle(ofRow: index)
        }
        super.mouseDown(with: event)
    }

    // MARK: Rows dragged by their handles

    /// Rows on the pasteboard, as their Markdown: moved within Manifold
    /// (folded ones with what's folded in them), Markdown anywhere else.
    static let rowsType = NSPasteboard.PasteboardType("com.manifold.outline-rows")

    /// Where dragged rows go: before the row at an index, at a depth.
    struct RowDrop: Equatable { var index: Int; var depth: Int }

    /// The row whose handle the mouse went down on — or the rows selected,
    /// if it's among them — with what's under them, picked up.
    func beginDraggingRows(from index: Int, event: NSEvent) {
        let all = rows
        guard index < all.count else { return }
        debugDragBegan = "rows from \(index)"
        let selection = selectedRows.flatMap { $0.contains(index) ? $0 : nil } ?? index..<(index + 1)
        let block = NoteOutlineEditing.block(all, selection)
        draggedRows = block
        let markdown = markdown(forRows: selection)
        let item = NSPasteboardItem()
        item.setString(markdown, forType: Self.rowsType)
        item.setString(markdown, forType: .string)
        let dragging = NSDraggingItem(pasteboardWriter: item)
        let frame = rowsFrame(block)
        dragging.setDraggingFrame(frame, contents: snapshot(of: frame))
        beginDraggingSession(with: [dragging], event: event, source: self)
    }

    override func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        draggedRows != nil ? (context == .withinApplication ? .move : .copy) : super.draggingSession(session, sourceOperationMaskFor: context)
    }

    override func draggingSession(_ session: NSDraggingSession, willBeginAt screenPoint: NSPoint) {
        DragCursor.began()
        if draggedRows == nil { super.draggingSession(session, willBeginAt: screenPoint) }
    }

    override func draggingSession(_ session: NSDraggingSession, movedTo screenPoint: NSPoint) {
        DragCursor.moved()
        if draggedRows == nil { super.draggingSession(session, movedTo: screenPoint) }
    }

    override func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
        DragCursor.ended()
        if draggedRows == nil { super.draggingSession(session, endedAt: screenPoint, operation: operation) }
        draggedRows = nil
        dropLine.isHidden = true
    }

    /// The rectangle some rows take, from their handles across.
    private func rowsFrame(_ block: Range<Int>) -> NSRect {
        guard let layout = layoutManager, let container = textContainer, !block.isEmpty else { return .zero }
        let ranges = paragraphRanges
        let characters = NSRange(location: ranges[block.lowerBound].location, length: NSMaxRange(ranges[block.upperBound - 1]) - ranges[block.lowerBound].location)
        var rect = NSRect.null
        layout.enumerateLineFragments(forGlyphRange: layout.glyphRange(forCharacterRange: characters, actualCharacterRange: nil)) { f, _, _, _, _ in rect = rect.union(f) }
        guard !rect.isNull else { return .zero }
        rect = rect.offsetBy(dx: textContainerOrigin.x, dy: textContainerOrigin.y)
        let left = textContainerOrigin.x + metrics.textIndent(for: row(at: block.lowerBound)) - metrics.indent
        rect.size.width = min(rect.maxX, textContainerOrigin.x + container.size.width) - left
        rect.origin.x = left
        return rect.integral
    }

    private func snapshot(of rect: NSRect) -> NSImage {
        let image = NSImage(size: rect.size)
        guard rect.width > 0, rect.height > 0, let bitmap = bitmapImageRepForCachingDisplay(in: rect) else { return image }
        cacheDisplay(in: rect, to: bitmap)
        image.addRepresentation(bitmap)
        // On a card of their own, as a thing's pill is (§3.11), so they read
        // over whatever they're dragged across.
        let appearance = effectiveAppearance
        return NSImage(size: rect.size, flipped: false) { bounds in
            appearance.performAsCurrentDrawingAppearance {
                let card = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: Radius.control, yRadius: Radius.control)
                DragPill.fill.setFill()
                card.fill()
                EdgeColor.controlHovered.setStroke()
                card.lineWidth = 0.5
                card.stroke()
                image.draw(in: bounds)
            }
            return true
        }
    }

    private func carriesRows(_ sender: NSDraggingInfo) -> Bool { sender.draggingPasteboard.types?.contains(Self.rowsType) ?? false }

    /// Its own text dragged within it, moved as text is.
    private func ownText(_ sender: NSDraggingInfo) -> Bool { sender.draggingSource as? NSView === self }

    override var acceptableDragTypes: [NSPasteboard.PasteboardType] { [Self.rowsType] + Dragged.types + super.acceptableDragTypes }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        carriesRows(sender) ? rowDragUpdated(sender) : ownText(sender) ? super.draggingEntered(sender) : Dropping.updated(self, sender)
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        carriesRows(sender) ? rowDragUpdated(sender) : ownText(sender) ? super.draggingUpdated(sender) : Dropping.updated(self, sender)
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        dropLine.isHidden = true
        Dropping.exited(self, sender)
        super.draggingExited(sender)
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        carriesRows(sender) ? dropRows(sender) : ownText(sender) ? super.performDragOperation(sender) : Dropping.perform(self, sender)
    }

    // A text view takes a drag from itself for its selected text, moved:
    // it refuses rows (nothing it knows of is being dragged) and, given
    // the chance, takes the selection away after. Rows and things are ours.
    override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool {
        carriesRows(sender) || !ownText(sender) ? true : super.prepareForDragOperation(sender)
    }

    override func concludeDragOperation(_ sender: NSDraggingInfo?) {
        guard let sender, !carriesRows(sender), ownText(sender) else { return }
        super.concludeDragOperation(sender)
    }

    // MARK: The pointer over handles

    /// Over a row's handle (a bullet, a checkbox, a number), the arrow: it's
    /// clicked or dragged, not typed at.
    private func overHandle(_ event: NSEvent) -> Bool {
        guard let layout = layoutManager as? NoteOutlineLayoutManager, let container = textContainer else { return false }
        let point = convert(event.locationInWindow, from: nil)
        let shown = layout.characterRange(forGlyphRange: layout.glyphRange(forBoundingRect: visibleRect, in: container), actualGlyphRange: nil)
        return layout.handleHit(at: point, origin: textContainerOrigin, among: shown) != nil
    }

    /// Over what a click opens — a thread's mark, a block's card, a fold's
    /// pill: the pointing hand.
    private func overClickable(_ event: NSEvent) -> Bool {
        let point = convert(event.locationInWindow, from: nil)
        if threadMarks.keys.contains(where: { threadMarkRect(row: $0)?.insetBy(dx: -2, dy: -2).contains(point) == true }) { return true }
        guard let layout = layoutManager as? NoteOutlineLayoutManager else { return false }
        if layout.foldPillHit(at: point, origin: textContainerOrigin) != nil { return true }
        return paragraphRanges.contains { layout.cardRect(of: $0, origin: textContainerOrigin)?.1.contains(point) == true }
    }

    /// The cursor for where the pointer is, if it's not the text's own.
    private func ownCursor(_ event: NSEvent) -> NSCursor? {
        if onPictureGrip(convert(event.locationInWindow, from: nil)) { return Self.gripCursor }
        if overClickable(event) { return .pointingHand }
        if overHandle(event) { return .arrow }
        return nil
    }

    override func mouseMoved(with event: NSEvent) {
        super.mouseMoved(with: event)
        hoveredRow = row(under: convert(event.locationInWindow, from: nil))
        hoverPicture(at: convert(event.locationInWindow, from: nil))
        // Set on every move, so coming back onto the text from a handle or a
        // grip, it's the I-beam again (not left as theirs).
        if let c = ownCursor(event) { c.set() } else if isUnderPointer, linkTarget(at: convert(event.locationInWindow, from: nil)) == nil { NSCursor.iBeam.set() }
        // A link to a block that's gone says so as the pointer comes onto it.
        ReferenceTip.hover(linkTarget(at: convert(event.locationInWindow, from: nil)), in: self)
    }

    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        hoveredRow = nil
        hoverPicture(at: nil)
    }

    /// Its own, for the pointer leaving it (the ghost bullet goes).
    private var hoverArea: NSTrackingArea?
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverArea { removeTrackingArea(hoverArea) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .mouseMoved, .activeInActiveApp, .inVisibleRect], owner: self)
        addTrackingArea(area)
        hoverArea = area
    }

    /// The row whose lines (and the step before them) a point is on.
    func row(under point: NSPoint) -> Int? {
        guard let layout = layoutManager, let container = textContainer, let storage = textStorage, storage.length > 0 else { return nil }
        let p = NSPoint(x: point.x - textContainerOrigin.x, y: point.y - textContainerOrigin.y)
        guard p.y >= 0, p.y <= layout.usedRect(for: container).maxY else { return nil }
        let glyph = min(layout.glyphIndex(for: p, in: container), max(layout.numberOfGlyphs - 1, 0))
        let fragment = layout.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
        guard fragment.minY <= p.y, p.y <= fragment.maxY + 2 else { return nil }
        return rowIndex(at: layout.characterIndexForGlyph(at: glyph))
    }

    /// The target of the link under a point, if it's on its letters.
    private func linkTarget(at point: NSPoint) -> String? {
        guard let layout = layoutManager, let container = textContainer, let storage = textStorage, storage.length > 0 else { return nil }
        let p = NSPoint(x: point.x - textContainerOrigin.x, y: point.y - textContainerOrigin.y)
        var fraction: CGFloat = 0
        let glyph = layout.glyphIndex(for: p, in: container, fractionOfDistanceThroughGlyph: &fraction)
        guard layout.boundingRect(forGlyphRange: NSRange(location: glyph, length: 1), in: container).contains(p) else { return nil }
        let i = layout.characterIndexForGlyph(at: glyph)
        guard i < storage.length else { return nil }
        let v = storage.attribute(.link, at: i, effectiveRange: nil)
        return (v as? URL)?.absoluteString ?? v as? String
    }

    override func cursorUpdate(with event: NSEvent) {
        if let c = ownCursor(event) { c.set() } else { super.cursorUpdate(with: event) }
    }

    /// A line where rows dragged over would go.
    private func rowDragUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        if let event = NSApp.currentEvent { autoscroll(with: event) }
        let drop = rowDrop(at: convert(sender.draggingLocation, from: nil))
        guard !isInsideDragged(drop, from: sender) else { dropLine.isHidden = true; return [] }
        showDropLine(drop)
        return sender.draggingSource is NoteOutlineTextView ? .move : .copy
    }

    func showDropLine(_ drop: RowDrop) {
        let ranges = paragraphRanges
        let y: CGFloat
        if drop.index < ranges.count { y = rowsFrame(drop.index..<(drop.index + 1)).minY }
        else { y = rowsFrame((ranges.count - 1)..<ranges.count).maxY }
        let x = textContainerOrigin.x + metrics.indent * CGFloat(drop.depth) + metrics.indent / 2
        dropLine.frame = NSRect(x: x, y: y - 1, width: max(20, bounds.width - x - 14), height: 2)
        dropLine.isHidden = false
    }

    /// Rows dropped put in place, taken from where they were.
    private func dropRows(_ sender: NSDraggingInfo) -> Bool {
        dropLine.isHidden = true
        let drop = rowDrop(at: convert(sender.draggingLocation, from: nil))
        guard !isInsideDragged(drop, from: sender) else { return false }
        if let source = sender.draggingSource as? NoteOutlineTextView, let block = source.draggedRows {
            moveRows(block, from: source, to: drop)
            return true
        }
        guard let markdown = sender.draggingPasteboard.string(forType: Self.rowsType) else { return false }
        insertRows(NoteOutlineMarkdown.parse(markdown).rows, at: drop)
        return true
    }

    private func isInsideDragged(_ drop: RowDrop, from sender: NSDraggingInfo) -> Bool {
        guard let source = sender.draggingSource as? NoteOutlineTextView, source === self, let block = draggedRows else { return false }
        return drop.index > block.lowerBound && drop.index < block.upperBound
    }

    /// Where rows dropped at a point go: above or below the row under it,
    /// by which half; as deep as the pointer is far in — no deeper than a
    /// child of the row before, never so shallow as to take the children of
    /// the row after away from it.
    func rowDrop(at point: NSPoint) -> RowDrop {
        let all = rows
        guard let layout = layoutManager, let container = textContainer, textStorage!.length > 0, !all.isEmpty else { return RowDrop(index: 0, depth: 0) }
        let inContainer = NSPoint(x: point.x - textContainerOrigin.x, y: point.y - textContainerOrigin.y)
        let glyph = min(layout.glyphIndex(for: inContainer, in: container), max(layout.numberOfGlyphs - 1, 0))
        let under = rowIndex(at: layout.characterIndexForGlyph(at: glyph))
        let frame = rowsFrame(under..<(under + 1))
        var index = point.y > frame.midY ? under + 1 : under
        if point.y > rowsFrame(all.indices.suffix(1)).maxY { index = all.count }
        let previous = index > 0 ? all[index - 1] : nil
        let deepest = previous.map { $0.depth + ($0.canHaveChildren ? 1 : 0) } ?? 0
        let shallowest = index < all.count && previous.map({ all[index].depth > $0.depth }) == true ? all[index].depth : 0
        let pointed = Int(((inContainer.x - metrics.indent / 2) / metrics.indent).rounded(.down))
        return RowDrop(index: index, depth: min(max(pointed, shallowest), max(deepest, shallowest)))
    }

    /// Rows moved here from a view: this one, or another note's.
    func moveRows(_ block: Range<Int>, from source: NoteOutlineTextView, to drop: RowDrop) {
        guard source !== self else {
            if drop.index > block.lowerBound, drop.index < block.upperBound { return }
            let before = rows
            var after = before
            let moving = Self.takeOut(block, from: &after)
            var index = drop.index
            if index > block.lowerBound { index -= block.count }
            return place(moving, at: RowDrop(index: index, depth: drop.depth), in: &after, before: before)
        }
        let moving = Array(source.rows[block])
        source.removeRows(block)
        insertRows(moving, at: drop)
    }

    func insertRows(_ moving: [NoteRow], at drop: RowDrop) {
        guard !moving.isEmpty else { return }
        let before = rows
        var after = before
        place(moving, at: drop, in: &after, before: before)
    }

    private func place(_ moving: [NoteRow], at drop: RowDrop, in after: inout [NoteRow], before: [NoteRow]) {
        window?.makeFirstResponder(self)
        if selectedRows != nil { leaveRowSelection() }
        let shift = drop.depth - moving[0].depth
        var placed = moving.map { r -> NoteRow in var r = r; r.depth = max(0, r.depth + shift); return r }
        var start = min(drop.index, after.count)
        // The blank lines where they go stay there, above them now.
        placed[0].gap = start < after.count ? after[start].gap : []
        if start < after.count { after[start].gap = [] }
        after.insert(contentsOf: placed, at: start)
        // A note that was only an empty row loses it.
        if after.count == placed.count + 1 {
            let empty = start == 0 ? after.count - 1 : 0
            if after[empty].text.isEmpty, after[empty].folded.isEmpty, after[empty].kind == .bullet {
                after.remove(at: empty)
                if empty < start { start -= 1 }
            }
        }
        NoteOutlineEditing.normalize(&after)
        replace(before, with: after, actionName: "Move Rows")
        selectRows(anchor: start, head: start + placed.count - 1)
    }

    /// Rows taken out, the blank lines before them given to the row that
    /// comes up in their place.
    static func takeOut(_ block: Range<Int>, from rows: inout [NoteRow]) -> [NoteRow] {
        let taken = Array(rows[block])
        rows.removeSubrange(block)
        if let gap = taken.first?.gap, !gap.isEmpty, block.lowerBound < rows.count, rows[block.lowerBound].gap.isEmpty { rows[block.lowerBound].gap = gap }
        return taken
    }

    /// Rows that moved to another note taken out of this one (one left with
    /// none keeps an empty row).
    func removeRows(_ block: Range<Int>) {
        let before = rows
        guard block.upperBound <= before.count else { return }
        if selectedRows != nil { leaveRowSelection() }
        var after = before
        _ = Self.takeOut(block, from: &after)
        if after.isEmpty { after = [.blank] }
        NoteOutlineEditing.normalize(&after)
        replace(before, with: after, actionName: "Move Rows")
    }

    // MARK: Pasteboard

    /// Rows copied as the Markdown they say; within one row, its text.
    override func writeSelection(to pboard: NSPasteboard, type: NSPasteboard.PasteboardType) -> Bool {
        let target = targetRows
        if selectedRows == nil, target.count <= 1 {
            guard type == .string else { return super.writeSelection(to: pboard, type: type) }
            let text = (textStorage!.string as NSString).substring(with: selectedRange())
            return pboard.setString(text.replacingOccurrences(of: NoteOutlineText.lineSeparator, with: "\n"), forType: .string)
        }
        guard type == .string else { return false }
        return pboard.setString(markdown(forRows: target), forType: .string)
    }

    override var writablePasteboardTypes: [NSPasteboard.PasteboardType] { selectedRows != nil ? [.string] : super.writablePasteboardTypes }

    /// Rows and their children as the Markdown they say, from depth 0.
    func markdown(forRows target: Range<Int>) -> String {
        let all = rows
        var picked = Array(all[NoteOutlineEditing.block(all, target)])
        let base = picked.map(\.depth).min() ?? 0
        for i in picked.indices { picked[i].depth -= base }
        if !picked.isEmpty { picked[0].gap = [] }
        return NoteOutlineMarkdown.serialize(NoteOutline(rows: picked))
    }

    /// Markdown of more than a line comes in as rows: in place of an empty
    /// row, or after the rows it was pasted onto.
    override func paste(_ sender: Any?) { paste(sender, plain: false) }

    /// ⌥⇧⌘V, Paste and Match Style: the clipboard's text as text — a
    /// picture on it not kept, an address over words not made their link;
    /// its lines still rows.
    override func pasteAsPlainText(_ sender: Any?) { paste(sender, plain: true) }

    private func paste(_ sender: Any?, plain: Bool) {
        // A picture (a screenshot copied, Preview's, a browser's Copy
        // Image): kept for the note as an image block, and shown — in the
        // caret's row if it's empty, else a row of its own after it.
        if !plain, pastePicture(from: .general) { return }
        if selectedRows == nil, let s = NSPasteboard.general.string(forType: .string) {
            let range = selectedRange()
            // In code: as it is, its lines the block's.
            if case .code = row(at: rowIndex(at: range.location)).kind {
                let t = s.hasSuffix("\n") ? String(s.dropLast()) : s
                return insertText(t.replacingOccurrences(of: "\n", with: NoteOutlineText.lineSeparator), replacementRange: range)
            }
            // An address pasted over words: a link to it, with those words.
            if !plain, range.length > 0, pasteLink(s, over: range) { return }
        }
        guard let s = NSPasteboard.general.string(forType: .string), s.contains("\n") else {
            return plain ? super.pasteAsPlainText(sender) : super.paste(sender)
        }
        let pasted = NoteOutlineMarkdown.parse(s).rows
        guard !pasted.isEmpty else { return plain ? super.pasteAsPlainText(sender) : super.paste(sender) }
        var all = rows
        let before = all
        let target = targetRows
        let current = all[target.lowerBound]
        let at: Int
        if target.count == 1, current.text.isEmpty, !current.isFolded {
            all.remove(at: target.lowerBound)
            at = target.lowerBound
        } else {
            at = NoteOutlineEditing.block(all, target).upperBound
        }
        let base = pasted.map(\.depth).min() ?? 0
        var incoming = pasted.map { r -> NoteRow in var r = r; r.depth = r.depth - base + current.depth; return r }
        incoming[0].gap = []
        all.insert(contentsOf: incoming, at: at)
        NoteOutlineEditing.normalize(&all)
        replace(before, with: all, actionName: "Paste")
        restoreCaret(CaretPosition(row: at + incoming.count - 1, offset: Int.max))
    }
}

extension NoteOutlineTextView {
    /// The picture a pasteboard holds, if a paste is of it, kept and put in.
    func pastePicture(from pb: NSPasteboard) -> Bool {
        guard isEditable, let keepImage, TextView.prefersImage(pb) else { return false }
        let images = TextView.images(on: pb)
        guard !images.isEmpty else { return false }
        for (data, kind) in images { keepImage(data, kind) { [weak self] markdown in self?.putPicture(markdown) } }
        return true
    }

    /// The pictures in a row scrolled into view, all of them, once laid out.
    func showPicture(inRowAt location: Int) {
        DispatchQueue.main.async { [weak self] in
            guard let self, let storage = self.textStorage, location < storage.length else { return }
            let row = self.paragraphRanges[self.rowIndex(at: location)]
            let frames = self.pictureLayout?.pictureFrames(in: row, origin: self.textContainerOrigin).map(\.frame) ?? []
            if let all = frames.reduce(nil, { (u: NSRect?, f) in u?.union(f) ?? f }) { self.scrollToVisible(all.insetBy(dx: 0, dy: -8)) }
        }
    }

    /// A picture's Markdown put in where the caret is: the caret's row,
    /// when it's empty, else a row after it (and what's under it), as deep.
    func putPicture(_ markdown: String) {
        guard isEditable, textStorage!.length > 0 else { return }
        if selectedRows != nil { leaveRowSelection() }
        let index = rowIndex(at: selectedRange().location)
        let all = rows
        guard all.indices.contains(index) else { return }
        defer { showPicture(inRowAt: selectedRange().location) }
        if all[index].text.isEmpty, !all[index].isFolded {
            let r = textRange(ofRowAt: paragraphRanges[index].location)
            setSelectedRange(NSRange(location: r.location, length: 0))
            insertText(markdown, replacementRange: NSRange(location: r.location, length: 0))
            return
        }
        let at = NoteOutlineEditing.block(all, index..<(index + 1)).upperBound
        var row = all[index]
        row.text = markdown
        row.folded = []
        if row.kind == .ordered || row.kind.isListItem { row.task = nil } else { row.kind = .paragraph }
        insertRows([row], at: RowDrop(index: at, depth: all[index].depth))
        restoreCaret(CaretPosition(row: at, offset: Int.max))
    }
}

/// Things dropped on the outline (§3.11), as a note takes them: a block's
/// (a file's, a place's) link, a page's, words, put in where the pointer
/// is; pictures, cards, several things at once as rows of their own where
/// the line shows — ⌃ for the rest.
extension NoteOutlineTextView: DropTaking {
    func dropForms(_ d: Dragged, at p: NSPoint) -> [DropForm] { isEditable ? Dropping.noteForms(d) : [] }

    /// Whether what a plain drop puts in goes as rows (a line shown) rather
    /// than into a row's text (the caret following).
    private func asRows(_ d: Dragged) -> Bool { Dropping.noteForms(d).first == .inline || d.things.count > 1 }

    func dropTrack(_ d: Dragged, at p: NSPoint) {
        if asRows(d) { return showDropLine(rowDrop(at: p)) }
        dropLine.isHidden = true
        let at = characterIndexForInsertion(at: p)
        if selectedRange() != NSRange(location: at, length: 0) { setSelectedRange(NSRange(location: at, length: 0)) }
    }

    func dropPut(_ d: Dragged, as form: DropForm, at p: NSPoint?) {
        dropLine.isHidden = true
        window?.makeFirstResponder(self)
        let at = p.map { characterIndexForInsertion(at: $0) } ?? selectedRange().location
        let drop = p.map { rowDrop(at: $0) } ?? RowDrop(index: paragraphRanges.count, depth: 0)
        let put = { [weak self] (markdown: String, rows: Bool) in
            guard let self else { return }
            if rows { return self.insertRows(NoteOutlineMarkdown.parse(markdown).rows, at: drop) }
            let all = self.string as NSString
            let r = NSRange(location: min(at, all.length), length: 0)
            let char = { (i: Int) -> Character? in i >= 0 && i < all.length ? Character(all.substring(with: NSRange(location: i, length: 1))) : nil }
            let text = [.link, .reference, .path].contains(form) ? Dropping.spaced(markdown, after: char(r.location - 1), before: char(r.location)) : markdown
            self.setSelectedRange(r)
            self.insertText(text, replacementRange: r)
        }
        let keep = keepImage.map { keep in { (data: Data, kind: String) in keep(data, kind) { put($0, true) } } }
        Dropping.noteText(d, as: form, keep: keep, insert: { put($0, form == .inline || $0.contains("\n")) },
                          linked: { [weak self] in self?.onLinked?($0) })
    }
}
