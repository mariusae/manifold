import AppKit
import ManifoldCore

/// A note as an outline (§7.9): its Markdown edited as Bike 2 edits an
/// outline — Weft's editor, ported (`OutlinerView` over the engine,
/// `NoteEditor`) — written back to the block as it changes, only what
/// changed; another's edit read in, the caret, folds and focus kept. Around
/// it what every tile has: its outline (headings, top-level items) for the
/// ticks, the sidebar and ⌘P; find; threads marked on the rows they're
/// about; the path to the row focused on.
final class OutlineNoteView: NSView, PaneContent {
    let placement: PlacementID
    let block: BlockID
    var source: () -> Block? = { nil }
    /// Edits to the block's text, as an editor makes them.
    var apply: ([TextEdit]) -> Void = { _ in }
    /// A link in it clicked: followed, by the one rule.
    var onOpen: ((String) -> Void)?
    /// A block dropped in by its link: linked from the note.
    var onLinked: ((BlockID) -> Void)? { didSet { outliner.onLinked = onLinked } }
    /// A picture dropped, kept for the note: given the Markdown that shows it.
    var keepImage: ((Data, String, @escaping (String) -> Void) -> Void)? { didSet { outliner.keepImage = keepImage } }
    /// A block's card (a place's in it), for a row that's only its embed.
    var cardFor: ((BlockID, String?) -> SummaryCardContent?)?
    /// A picture by its source (a note's own relative to its file), when
    /// it's here; nil sends for it, `picturesArrived` after.
    var pictureFor: ((String) -> NSImage?)?
    /// What a block a link names is called, and its symbol: how its link reads.
    var blockLook: ((BlockID) -> (title: String, symbol: String)?)? { didSet { outliner.refreshLinks() } }
    /// Pictures sent for came: shown.
    func picturesArrived() { outliner.restyle() }
    var theme: FontTheme { didSet { if theme != oldValue { outliner.theme = Self.look(theme) } } }

    private let outliner: OutlinerView
    private let path = NoteOutlinePath()
    /// Find (⌘F): the pill over the rows, as every tile's.
    private lazy var finder: FindHost = {
        let f = FindHost(view: self, target: self)
        f.area = { [weak self] in self?.outliner.frame ?? .zero }
        return f
    }()
    private lazy var textSearch = TextViewSearch(outliner.textView)
    /// The matches found again a moment after an edit.
    private let findAgain = Debouncer()
    /// The Markdown last read or written: the block's, unless it changed elsewhere since.
    private var written: String?
    private let headings = Outline()

    var focusView: NSView { outliner.firstResponderView }
    /// What takes things dropped on it.
    var dropTarget: DropTaking { outliner.textView }
    var isDead: Bool { false }
    var outline: Outline? { headings }
    /// The outline's ticks down the right, left of the scroll bar: the rows run under them.
    private lazy var strip: ScrollStrip = {
        let s = ScrollStrip(outline: headings, scroll: outliner.scrollView, ownsScrollBar: false)
        s.tops = { [weak self] in self?.itemTops() ?? [] }
        s.strip.preview = { [weak self] i in self?.itemWords(i) ?? [] }
        return s
    }()

    /// Its folds, in the tile's menu.
    /// A note's: back to prose.
    var barButtons: [BarButton] { OutlineToggle.button(for: block, in: self, outline: true) }

    var pillItems: [NSMenuItem] {
        [ClosureMenuItem("Collapse All", symbol: "arrow.down.right.and.arrow.up.left") { [weak self] in _ = self?.outliner.run(.foldAll) },
         ClosureMenuItem("Expand All", symbol: "arrow.up.left.and.arrow.down.right") { [weak self] in _ = self?.outliner.run(.unfoldAll) },
         .separator()]
    }

    /// ⌘↩ from the menu (a primary action): the caret's row a checkbox, checked, a bullet again.
    func cycleChecklist() { _ = outliner.run(.cycleChecklist) }

    /// The outliner's look in the font theme's faces: its editing face for
    /// words, its monospaced one for code.
    static func look(_ theme: FontTheme) -> OutlinerTheme {
        var look = OutlinerTheme(font: theme.font(.proportional, size: 14.5), mono: theme.font(.monospaced, size: 12.5))
        look.highlight = NoteOutlineStyler.highlighter
        return look
    }

    init(placement: PlacementID, block: BlockID, theme: FontTheme) {
        self.placement = placement
        self.block = block
        self.theme = theme
        outliner = OutlinerView(editor: NoteEditor(source: ""), theme: Self.look(theme))
        super.init(frame: .zero)
        wantsLayer = true
        themed { $0.layer?.backgroundColor = Theme.windowBackground.cgColor }
        outliner.contentInset = NSSize(width: 16, height: 14)
        outliner.onChange = { [weak self] markdown in self?.edited(markdown) }
        outliner.onFollow = { [weak self] target in self?.onOpen?(target) }
        outliner.onFocusChanged = { [weak self] in
            self?.showPath()
            self?.markCurrent()
        }
        outliner.onLaidOut = { [weak self] in
            // Rows shown change with folds and focus, the Markdown not.
            self?.mapRows()
            self?.strip.refill()
            self?.placeThreadMarks()
            self?.markCurrent()
        }
        outliner.linkTitle = { [weak self] address in self?.look(of: address)?.title }
        outliner.linkSymbol = { [weak self] address in self?.look(of: address)?.symbol }
        outliner.blockView = { [weak self] b in self?.view(for: b) }
        outliner.textView.onFind = { [weak self] sender in self?.finder.perform(sender) }
        path.onStep = { [weak self] step in
            guard let self else { return }
            let trail = self.outliner.editor.focusTrail.count
            if let step, step < trail { self.outliner.focusOut(levels: trail - step) } else { self.outliner.unfocus() }
            self.window?.makeFirstResponder(self.outliner.firstResponderView)
        }
        addSubview(outliner)
        addSubview(strip.strip)
        addSubview(path)
        headings.onPick = { [weak self] i in self?.goToItem(i) }
        // An entry's place: its line in the Markdown, as the editor's are.
        headings.block = block
        headings.placeFor = { [weak self] i in
            guard let lines = self?.items.map(\.line), lines.indices.contains(i) else { return nil }
            return .line(lines[i] + 1)
        }
        outliner.scrollView.contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(self, selector: #selector(scrolled), name: NSView.boundsDidChangeNotification, object: outliner.scrollView.contentView)
    }

    required init?(coder: NSCoder) { fatalError() }

    func destroy() { NotificationCenter.default.removeObserver(self) }

    @objc private func scrolled() { markCurrent() }

    override func layout() {
        super.layout()
        // The path to the row focused on, over the rows.
        let barShown = outliner.editor.isFocused
        path.isHidden = !barShown
        let bar: CGFloat = barShown ? NoteOutlinePath.height : 0
        path.frame = NSRect(x: 14, y: bounds.height - bar - 4, width: max(0, bounds.width - 28), height: bar)
        outliner.frame = NSRect(x: 0, y: 0, width: bounds.width, height: bounds.height - (barShown ? bar + 4 : 0))
        strip.place(outliner.frame)
        finder.layout(in: outliner.frame)
    }

    /// The focus's path shown, over the rows.
    private func showPath() {
        let editor = outliner.editor
        if editor.isFocused {
            let name = source()?.displayTitle ?? "Note"
            let steps = editor.focusTrail.enumerated().map { (text: $0.element, index: $0.offset) } + (editor.focusLabel.map { [(text: $0, index: editor.focusTrail.count)] } ?? [])
            path.show(note: name, ancestors: steps, fontSize: outliner.theme.size)
        }
        needsLayout = true
    }

    // MARK: The note, both ways

    /// The block moved: unless it's what was written from here, read again.
    func documentChanged() {
        guard let b = source(), let t = b.text, !b.needsRead else { return }
        let markdown = t.text.string
        guard markdown != written else { return }
        written = markdown
        outliner.load(markdown: markdown)
        noteChanged()
        showPath()
    }

    /// Written here: back to the block, only what changed.
    private func edited(_ markdown: String) {
        noteChanged()
        if finder.pill != nil { findAgain.schedule(after: 0.3) { [weak self] in self?.finder.refresh() } }
        guard markdown != written, let old = source()?.text?.text.string else { return }
        written = markdown
        apply([Self.edit(from: old, to: markdown)])
    }

    /// One edit turning `old` into `new`: what's between their common head
    /// and tail, cut at characters' edges (offsets in bytes, as a rope counts them).
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

    // MARK: Links, pictures and cards

    /// A `manifold:` address's block, as it reads: its title and symbol.
    private func look(of address: String) -> (title: String, symbol: String)? {
        guard address.hasPrefix("manifold:"), let (id, _) = BlockID.link(address) else { return nil }
        return blockLook?(id)
    }

    /// What's drawn in place of a row of pictures: the pictures, or — a
    /// block embedded (`![name](manifold:…)`) — its card; nothing (the row
    /// as it's written) for code, or a picture not here yet.
    private func view(for b: OutlinerBlock) -> NSView? {
        guard b.info == OutlinerBlock.picture, let pictures = OutlinerPicture.all(line: b.source), !pictures.isEmpty else { return nil }
        let room = max(b.room, 120)
        let stack = TopDownView()
        var y: CGFloat = 0
        for p in pictures {
            if p.address.hasPrefix("manifold:"), let (id, place) = BlockID.link(p.address) {
                guard let content = cardFor?(id, place) else { return nil }
                let card = SummaryCard(content)
                let address = p.address
                card.onClick = { [weak self] in self?.onOpen?(address) }
                let h = SummaryCard.height(for: content)
                card.frame = NSRect(x: 0, y: y, width: min(room, 420), height: h)
                stack.addSubview(card)
                y += h + 6
                continue
            }
            guard let image = pictureFor?(p.address) else { return nil }
            var size = image.size
            if let w = p.width { size = CGSize(width: w, height: p.height ?? w * size.height / max(size.width, 1)) }
            if size.width > room { size = CGSize(width: room, height: room * size.height / max(size.width, 1)) }
            let v = NSImageView(frame: NSRect(x: 0, y: y, width: size.width, height: size.height))
            v.image = image
            v.imageScaling = .scaleProportionallyUpOrDown
            v.wantsLayer = true
            v.layer?.cornerRadius = Radius.inline
            v.layer?.masksToBounds = true
            v.toolTip = p.alt.isEmpty ? p.address : p.alt
            stack.addSubview(v)
            y += size.height + 6
        }
        stack.frame = NSRect(x: 0, y: 0, width: room, height: max(y - 6, 1))
        return stack
    }

    // MARK: The tile's outline

    /// The note's outline — its headings, and its top-level items each
    /// under the heading before it — as its editor and preview have it too
    /// (`NoteOutlineMarkdown.items`): the tile's ticks, its sidebar, ⌘P.
    private func noteChanged() {
        let markdown = outliner.editor.markdown
        let found = NoteOutlineMarkdown.items(in: markdown)
        items = found
        headings.set(found.map(Outline.Item.init))
        mapRows()
        strip.refill()
        markCurrent()
        placeThreadMarks()
    }

    /// The note's items, each with the Markdown line it's on (from 0).
    private var items: [NoteOutlineItem] = []
    /// The Markdown's lines each row shown stands for (from 0), by row.
    private var rowLines: [ClosedRange<Int>?] = []

    private func mapRows() { rowLines = (0..<outliner.rowCount).map { outliner.editor.markdownLines(ofRow: $0) } }

    /// The row shown that a Markdown line is in, if any: the last that starts at or before it.
    private func row(ofLine line: Int) -> Int? {
        if let exact = rowLines.firstIndex(where: { $0?.contains(line) == true }) { return exact }
        return rowLines.lastIndex { ($0?.lowerBound ?? .max) <= line }
    }

    /// Where each item's row is (one not shown, outside a focus: at the top or the end).
    private func itemTops() -> [(y: CGFloat, level: Int)] {
        let height = outliner.textView.frame.height
        return items.map { item in
            guard let r = row(ofLine: item.line), let rect = outliner.rect(ofRow: r) else {
                return ((rowLines.first??.lowerBound ?? 0) > item.line ? 0 : height, item.level)
            }
            return (rect.minY, item.level)
        }
    }

    /// The rows under an item, as words: what the strip's card says.
    private func itemWords(_ i: Int) -> [String] {
        guard items.indices.contains(i), let first = row(ofLine: items[i].line) else { return [] }
        let end = i + 1 < items.count ? (row(ofLine: items[i + 1].line) ?? outliner.rowCount) : outliner.rowCount
        var out: [String] = []
        for r in (first + 1)..<max(end, first + 1) {
            guard let w = outliner.words(ofRow: r)?.trimmingCharacters(in: .whitespaces), !w.isEmpty else { continue }
            out.append(w)
            if out.count == 4 { break }
        }
        return out
    }

    private func goToItem(_ i: Int) {
        guard items.indices.contains(i) else { return }
        let line = items[i].line
        // Out of a focus it isn't in; to its row (or the fold it's under).
        if outliner.editor.isFocused, !rowLines.contains(where: { $0?.contains(line) == true }) { outliner.unfocus() }
        if let r = row(ofLine: line), let rect = outliner.rect(ofRow: r), let start = outliner.rowStart(r) {
            outliner.setCaret(start)
            outliner.textView.scrollToVisible(rect.insetBy(dx: 0, dy: -40))
        }
        window?.makeFirstResponder(outliner.firstResponderView)
    }

    /// The item you're at: the last that begins at or above the top of what shows.
    private func markCurrent() {
        guard !items.isEmpty else { return headings.current = nil }
        let top = NSPoint(x: 0, y: outliner.scrollView.contentView.bounds.minY + 4)
        guard let r = outliner.row(at: top), let line = rowLines.indices.contains(r) ? rowLines[r]?.lowerBound : nil else { return }
        headings.current = items.lastIndex { $0.line <= line } ?? 0
    }

    // MARK: Places (§2.5) and threads (§3.12)

    /// What's here: the rows chosen, else the caret's row — as the lines of
    /// the Markdown they are, named by their words.
    var here: Place? {
        guard let rows = outliner.hereRows, let a = rowLines.indices.contains(rows.lowerBound) ? rowLines[rows.lowerBound] : nil else { return Place(block: block) }
        let b = (rowLines.indices.contains(rows.upperBound) ? rowLines[rows.upperBound] : nil) ?? a
        let words = (outliner.words(ofRow: rows.lowerBound) ?? "").trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: "\u{FFFC}")))
        let name = words.isEmpty ? nil : String(words.prefix(60))
        let at: Locator = a.lowerBound == b.upperBound ? .line(a.lowerBound + 1) : .lines(a.lowerBound + 1, b.upperBound + 1)
        return Place(block: block, at: at, name: name)
    }

    /// The places threads are about, as the editor's are found: marked on
    /// the rows they're on (at their right), as those rows are now.
    var threadPlaces: [TextView.Place] = [] { didSet { if threadPlaces != oldValue { placeThreadMarks() } } }
    /// A row's thread mark clicked: the Markdown line it's on, and where the mark is (in this view).
    var onThreads: ((Int, NSRect) -> Void)?
    private var threadMarks: [ThreadMarkView] = []

    /// A mark at the right of each row a thread is about.
    private func placeThreadMarks() {
        var marks: [Int: (state: ThreadMark.State, line: Int)] = [:]
        for p in threadPlaces where p.threads > 0 {
            guard let row = rowLines.firstIndex(where: { $0?.contains(p.line) == true }) else { continue }
            let m = TextView.threadState(p)
            if let old = marks[row] {
                marks[row] = (ThreadMark.State(count: old.state.count + m.count, open: old.state.open || m.open, unseen: old.state.unseen || m.unseen), old.line)
            } else {
                marks[row] = (m, p.line)
            }
        }
        let text = outliner.textView
        while threadMarks.count > marks.count { threadMarks.removeLast().removeFromSuperview() }
        while threadMarks.count < marks.count {
            let v = ThreadMarkView()
            text.addSubview(v)
            threadMarks.append(v)
        }
        for (v, (row, m)) in zip(threadMarks, marks.sorted { $0.key < $1.key }) {
            guard let rect = outliner.rect(ofRow: row) else { v.isHidden = true; continue }
            let size = ThreadMark.size(m.state)
            v.isHidden = false
            v.state = m.state
            v.frame = NSRect(x: text.bounds.width - size.width - 8, y: rect.minY + (min(rect.height, 22) - size.height) / 2, width: size.width, height: size.height)
            v.onClick = { [weak self, weak v] in
                guard let self, let v else { return }
                self.onThreads?(m.line, self.convert(v.bounds, from: v))
            }
        }
    }

    // MARK: Debugging

    /// The rows as they stand.
    var debugRows: String { outliner.debugState }

    /// Debugging: the outline driven as its keys do ("state" and the rest
    /// of `OutlinerView.debug`), or "here", "items", "threads", "path".
    func debug(_ command: String) -> String {
        switch command {
        case "here": return here.map { "\($0.at?.fragment ?? "-") \($0.name ?? "")" } ?? "none"
        case "items": return items.map { "\($0.line + 1) \($0.title)" }.joined(separator: "\n")
        case "threads": return threadMarks.filter { !$0.isHidden }.map { "\(Int($0.frame.minY)) \($0.state.count)" }.joined(separator: "\n")
        case "path": return path.isHidden ? "hidden" : path.debugState
        default:
            window?.makeFirstResponder(outliner.firstResponderView)
            return outliner.debug(command)
        }
    }
}

/// A row's thread mark, over the outline's text: drawn as the editor's
/// are, clicked for its threads.
private final class ThreadMarkView: NSView {
    var state = ThreadMark.State(count: 0, open: false, unseen: false) { didSet { needsDisplay = true } }
    var onClick: (() -> Void)?
    override var isFlipped: Bool { true }
    override func draw(_ dirtyRect: NSRect) { ThreadMark.draw(state, in: bounds) }
    override func mouseDown(with event: NSEvent) { onClick?() }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .pointingHand) }
}

/// A stack laid out from the top.
private final class TopDownView: NSView {
    override var isFlipped: Bool { true }
}

/// The highlighter's colour (`==words==`), the editors' and previews' alike.
enum NoteOutlineStyler {
    static let highlighter = NSColor.themed { $0.code.highlighter }
}

/// The path to the row focused on, over the rows: the note, then each row
/// it's under, then the row; a step clicked focuses there.
final class NoteOutlinePath: NSView {
    static let height: CGFloat = 24
    /// A step clicked: nil for the whole note, else its place in the trail.
    var onStep: ((Int?) -> Void)?
    private let stack = NSStackView()

    override init(frame: NSRect) {
        super.init(frame: frame)
        stack.orientation = .horizontal
        stack.spacing = 2
        stack.alignment = .centerY
        addSubview(stack)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        stack.frame = bounds
    }

    private var font: NSFont = UIType.caption

    func show(note: String, ancestors: [(text: String, index: Int)], fontSize: CGFloat) {
        stack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        font = NSFont.systemFont(ofSize: round(fontSize * 0.82), weight: .medium)
        let name = Self.plain(note)
        stack.addArrangedSubview(step(name, symbol: "chevron.left", index: nil))
        // The note's own title heading is the note, already first.
        for (i, ancestor) in ancestors.enumerated() {
            let text = Self.plain(ancestor.text)
            guard !text.isEmpty, !(i == 0 && text.caseInsensitiveCompare(name) == .orderedSame) else { continue }
            let separator = NSTextField.label("›", font: font, color: Theme.tertiaryText)
            stack.addArrangedSubview(separator)
            stack.addArrangedSubview(step(text, symbol: nil, index: ancestor.index))
        }
        needsLayout = true
    }

    private func step(_ title: String, symbol: String?, index: Int?) -> NSButton {
        let button = NSButton(title: title, target: self, action: #selector(stepped(_:)))
        button.isBordered = false
        button.font = font
        button.contentTintColor = Theme.secondaryText
        button.tag = index ?? -1
        button.lineBreakMode = .byTruncatingTail
        if let symbol {
            button.image = Theme.symbol(symbol, size: font.pointSize, weight: .semibold)
            button.imagePosition = .imageLeading
        }
        button.toolTip = index == nil ? "Unfocus: the whole note" : "Focus on “\(title)”"
        button.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return button
    }

    /// Words as they read: a link by its text, not its brackets.
    static func plain(_ text: String) -> String {
        InlineMarkup.plainText(text).replacingOccurrences(of: "[[", with: "").replacingOccurrences(of: "]]", with: "")
    }

    @objc private func stepped(_ sender: NSButton) { onStep?(sender.tag < 0 ? nil : sender.tag) }

    var debugState: String {
        stack.arrangedSubviews.compactMap { ($0 as? NSButton)?.title ?? ($0 as? NSTextField)?.stringValue }.joined(separator: " ")
    }
}

extension OutlineNoteView: Replaceable {
    func search(_ query: String, caseSensitive: Bool, done: @escaping (Int?) -> Void) {
        textSearch.search(query, caseSensitive: caseSensitive, done: done)
    }

    func findNext(forward: Bool) { textSearch.findNext(forward: forward) }

    func endSearch() {
        findAgain.cancel()
        textSearch.end()
        window?.makeFirstResponder(outliner.firstResponderView)
    }

    func textForFind(_ done: @escaping (String?) -> Void) { done(textSearch.selectedText) }

    /// The match gone to, replaced as typing it would; the pill then finds the rest again.
    func replaceCurrent(with replacement: String) {
        let text = outliner.textView
        guard text.isEditable, let r = textSearch.currentMatch else { return NSSound.beep() }
        text.setSelectedRange(r)
        text.insertText(replacement, replacementRange: r)
    }

    /// Every match replaced, the last first (so the others stay where they were found).
    func replaceAll(with replacement: String) {
        let found = textSearch.found
        let text = outliner.textView
        guard text.isEditable, !found.isEmpty else { return NSSound.beep() }
        for r in found.reversed() {
            text.setSelectedRange(r)
            text.insertText(replacement, replacementRange: r)
        }
        finder.refresh()
    }
}
