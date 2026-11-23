import AppKit
import ManifoldCore

/// The outliner's text view: TextKit 1, so that its layout manager
/// (`OutlinerLayoutManager`) can draw each row's marks. What is typed in
/// it is handed to its `OutlinerView`, which hands it to the note's
/// engine and has the view show what the engine answers; what's clicked,
/// carried and keyed — handles, boxes, links, rows dragged, rows chosen
/// (Esc), Bike 2's keys — is this view's. A port of Weft's Mac editor
/// (prism's `NoteTextView`).
final class OutlinerTextView: NSTextView {
    weak var owner: OutlinerView?
    /// How far down the app's own block views reach.
    var blocksBottom: CGFloat = 0
    private var pressed: (point: CGPoint, link: OutlinerLink?, task: Int?)?
    /// The little window asking where a link should lead, and the words it is for.
    private var linkPrompt: NSPopover?
    private var linkRange = NSRange(location: 0, length: 0)

    var outlinerLayout: OutlinerLayoutManager? { layoutManager as? OutlinerLayoutManager }

    static func make() -> OutlinerTextView {
        let storage = NSTextStorage()
        let manager = OutlinerLayoutManager()
        let container = NSTextContainer(size: CGSize(width: 400, height: CGFloat.greatestFiniteMagnitude))
        container.widthTracksTextView = true
        container.lineFragmentPadding = 0
        manager.addTextContainer(container)
        storage.addLayoutManager(manager)
        let view = OutlinerTextView(frame: CGRect(x: 0, y: 0, width: 400, height: 20), textContainer: container)
        view.drawsBackground = false
        view.isRichText = false
        view.importsGraphics = false
        // Undo is the note's own: it puts structure back, which text alone cannot.
        view.allowsUndo = false
        view.isVerticallyResizable = true
        view.isHorizontallyResizable = false
        view.autoresizingMask = [.width]
        view.maxSize = CGSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        view.isAutomaticQuoteSubstitutionEnabled = false
        view.isAutomaticDashSubstitutionEnabled = false
        view.isAutomaticTextReplacementEnabled = false
        view.isAutomaticSpellingCorrectionEnabled = false
        view.isAutomaticLinkDetectionEnabled = false
        view.usesFindBar = false
        // Pictures taken when dropped, besides what a text view takes.
        view.registerForDraggedTypes(view.acceptableDragTypes)
        return view
    }

    private var outlineLines: [BodyLine] { owner?.bodyLayout.lines ?? [] }

    // MARK: The pointer

    private var tracking: NSTrackingArea?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self)
        addTrackingArea(area)
        tracking = area
    }

    /// What the pointer is over, as far as its shape goes.
    private enum Under { case text, link, handle, box, block, elsewhere }
    private var under: Under = .text

    /// Says what the pointer is over: the text view is told of every move
    /// across its frame — also of those over the app's own views inside it,
    /// a picture — and none of those is text.
    private func whatIsUnder(_ event: NSEvent) -> Under {
        guard let window, let content = window.contentView else { return .elsewhere }
        let hit = content.hitTest(content.superview?.convert(event.locationInWindow, from: nil) ?? event.locationInWindow)
        guard let hit else { return .elsewhere }
        if hit !== self { return hit.isDescendant(of: self) ? .block : .elsewhere }
        guard let manager = outlinerLayout, let container = textContainer else { return .text }
        let point = containerPoint(event)
        // What is clicked — a handle, a box, a fold's pill: a hand, as over a link.
        if manager.task(at: point, in: container) != nil || manager.foldPill(at: point) != nil || manager.mark(at: point) != nil { return .handle }
        // Rows chosen are taken hold of, not written in: an arrow.
        if let chosen = rowsChosen, let row = manager.row(at: point, in: container), (min(chosen.anchor, chosen.head)...max(chosen.anchor, chosen.head)).contains(row) { return .box }
        return manager.link(at: point, in: container) != nil ? .link : .text
    }

    /// Sets the pointer's shape for what it is over. Says whether the text is under it.
    @discardableResult
    private func point(_ event: NSEvent) -> Bool {
        let now = whatIsUnder(event)
        defer { under = now }
        switch now {
        case .text:
            NSCursor.iBeam.set()
            return true
        case .link, .handle:
            NSCursor.pointingHand.set()
        case .box:
            NSCursor.arrow.set()
        case .block:
            if under != now { NSCursor.arrow.set() }
        case .elsewhere:
            NSCursor.arrow.set()
        }
        return false
    }

    override func cursorUpdate(with event: NSEvent) {
        if point(event) { super.cursorUpdate(with: event) }
    }

    override func mouseMoved(with event: NSEvent) {
        if point(event) { super.mouseMoved(with: event) }
    }

    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        if under == .text || under == .link || under == .handle { NSCursor.arrow.set() }
        under = .elsewhere
    }

    /// The pointer's shape is set as it moves (see `point`), from what is truly under it.
    override func resetCursorRects() {}

    override func setFrameSize(_ newSize: NSSize) {
        let was = frame.width
        super.setFrameSize(newSize)
        guard let owner, owner.hasBlocks, abs(newSize.width - was) > 0.5 else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self, let owner = self.owner, abs(self.bounds.width - owner.blocksPlacedFor) > 0.5 else { return }
            owner.restyle()
        }
    }

    func containerPoint(_ event: NSEvent) -> CGPoint {
        let point = convert(event.locationInWindow, from: nil)
        return CGPoint(x: point.x - textContainerOrigin.x, y: point.y - textContainerOrigin.y)
    }

    // MARK: Clicks

    override func mouseDown(with event: NSEvent) {
        rowPress = nil
        guard let manager = outlinerLayout, let container = textContainer else {
            leaveRows()
            return super.mouseDown(with: event)
        }
        let point = containerPoint(event)
        // On rows chosen: they are taken hold of, to carry — or, let go where they are, let be.
        if let chosen = rowsChosen, let row = manager.row(at: point, in: container), (min(chosen.anchor, chosen.head)...max(chosen.anchor, chosen.head)).contains(row) {
            rowPress = (row, point, true)
            return
        }
        leaveRows()
        // A row's handle: clicked, it folds the row or unfolds it; dragged, it carries the row.
        if let row = manager.mark(at: point) {
            rowPress = (row, point, false)
            return
        }
        // A folded row's pill: unfolded.
        if let row = manager.foldPill(at: point) {
            owner?.perform(.unfold, onRows: [row])
            return
        }
        let task = manager.task(at: point, in: container)
        let link = task == nil ? manager.link(at: point, in: container) : nil
        if task != nil || link != nil {
            // Followed on the way up, if the pointer has not gone anywhere.
            pressed = (point, link, task)
            return
        }
        pressed = nil
        super.mouseDown(with: event)
    }

    override func mouseUp(with event: NSEvent) {
        if let press = rowPress {
            rowPress = nil
            if press.chosen {
                leaveRows()
            } else {
                clickHandle(ofRow: press.row, option: event.modifierFlags.contains(.option))
            }
            return
        }
        guard let pressed else { return super.mouseUp(with: event) }
        self.pressed = nil
        let point = containerPoint(event)
        guard hypot(point.x - pressed.point.x, point.y - pressed.point.y) < 4 else { return }
        if let task = pressed.task {
            owner?.perform(.toggleCheckbox, at: task)
        } else if let link = pressed.link {
            owner?.follow(link)
        }
    }

    /// A row's handle clicked: the row folded, or unfolded; ⌥-clicked, the
    /// row and everything under it, folded or shown — as Bike's handle.
    func clickHandle(ofRow row: Int, option: Bool) {
        guard outlineLines.indices.contains(row) else { return }
        if option {
            owner?.perform(outlineLines[row].isFolded ? .unfoldCompletely : .foldCompletely, onRows: [row])
        } else {
            owner?.perform(.toggleFold, onRows: [row])
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        ContentText.unsmoothed()
        super.draw(dirtyRect)
        outlinerLayout?.drawEmptyRow(at: textContainerOrigin)
        if let tail, showsCaret {
            indicator.color.setFill()
            NSBezierPath(rect: tail).fill()
        }
    }

    // MARK: The caret
    //
    // The system's own caret, as a text view of TextKit 2 has it — thicker,
    // in the accent, fading as it blinks — where this view's would be. The
    // text view still says where (`drawInsertionPoint`), and when there is
    // one at all (`updateInsertionPointStateAndRestartTimer`); it draws
    // nothing of its own. Beside it, at an edge of formatting, a tail toward
    // the words what is typed joins: Bike's typing affinity.

    private lazy var indicator: NSTextInsertionIndicator = {
        let indicator = NSTextInsertionIndicator(frame: .zero)
        indicator.displayMode = .hidden
        addSubview(indicator)
        return indicator
    }()

    /// Where, beside the caret, a tail says which side's formatting what is typed joins.
    private var tail: NSRect?

    /// Whether there is a caret to show: the view writing in a window that is
    /// being written in, nothing selected, and the caret not put away.
    private var showsCaret: Bool {
        guard let window, window.isKeyWindow, window.firstResponder === self, isEditable else { return false }
        return selectedRange().length == 0 && (insertionPointColor?.alphaComponent ?? 0) > 0
    }

    private func showCaret() {
        let shown = showsCaret
        indicator.color = insertionPointColor.flatMap { $0.alphaComponent > 0 ? $0 : nil } ?? (owner?.theme.accent ?? .controlAccentColor)
        indicator.displayMode = shown ? .automatic : .hidden
        if !shown, let old = tail {
            tail = nil
            setNeedsDisplay(old)
        }
    }

    override func updateInsertionPointStateAndRestartTimer(_ restartFlag: Bool) {
        super.updateInsertionPointStateAndRestartTimer(restartFlag)
        showCaret()
    }

    override var insertionPointColor: NSColor? {
        didSet { if window != nil { showCaret() } }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        NotificationCenter.default.removeObserver(self, name: NSWindow.didBecomeKeyNotification, object: nil)
        NotificationCenter.default.removeObserver(self, name: NSWindow.didResignKeyNotification, object: nil)
        guard let window else { return }
        for name in [NSWindow.didBecomeKeyNotification, NSWindow.didResignKeyNotification] {
            NotificationCenter.default.addObserver(self, selector: #selector(keyChanged), name: name, object: window)
        }
    }

    @objc private func keyChanged() { showCaret() }

    /// The caret is as tall as the words it stands among, and no taller:
    /// a line's box also holds the room left under it before the next,
    /// which a caret drawn the whole box's height would hang down into.
    override func drawInsertionPoint(in rect: NSRect, color: NSColor, turnedOn flag: Bool) {
        var rect = rect
        let font = (typingAttributes[.font] as? NSFont) ?? owner?.theme.body ?? .systemFont(ofSize: NSFont.systemFontSize)
        let tall = (font.ascender - font.descender).rounded(.up) + 2
        if rect.height > tall { rect.size.height = tall }
        // The system's caret stands where this one would have, centred on its line.
        let width = max(indicator.intrinsicContentSize.width, 2)
        let frame = NSRect(x: (rect.minX + rect.width / 2 - width / 2).rounded(), y: rect.minY, width: width, height: rect.height)
        if indicator.frame != frame { indicator.frame = frame }
        showCaret()
        // At an edge of formatting, a tail toward the words what is typed joins — Bike's typing affinity.
        // Drawn steady, under the system's caret, which blinks on its own.
        let at = selectedRange().location
        var wanted: NSRect?
        if showsCaret, isMarkup(at - 1) != isMarkup(at) {
            let joinsAfter = isMarkup(at - 1)
            wanted = NSRect(x: joinsAfter ? frame.maxX : frame.minX - 3, y: frame.maxY - 2, width: 3, height: 2)
        }
        if wanted != tail {
            if let old = tail { setNeedsDisplay(old) }
            tail = wanted
            if let wanted { setNeedsDisplay(wanted) }
        }
    }

    override func setNeedsDisplay(_ rect: NSRect, avoidAdditionalLayout flag: Bool) {
        // What a taller caret left behind is cleared with it.
        super.setNeedsDisplay(rect.insetBy(dx: -4, dy: -4), avoidAdditionalLayout: flag)
    }

    // MARK: Rows carried by the pointer
    //
    // A row is taken by its handle — or its box, or, chosen with others
    // (Esc), anywhere on them — and carried: within the note, to another
    // place and depth in it; or to another outliner's note. A line shows
    // where it would go. Carried anywhere else — another app — it is its Markdown.

    /// What says rows are being carried, on the pasteboard, beside their Markdown.
    static let rowsType = NSPasteboard.PasteboardType("com.manifold.outliner.rows")
    /// The rows being carried, and the view they are carried from.
    private static var carried: (rows: [Int], markdown: String)?
    private static weak var carriedFrom: OutlinerTextView?
    /// A press on a handle, or on rows chosen: a click or a carry, by what comes next.
    private var rowPress: (row: Int, point: CGPoint, chosen: Bool)?

    override func mouseDragged(with event: NSEvent) {
        let point = containerPoint(event)
        var row = rowPress?.row
        var from = rowPress?.point
        // A task is carried by its box, as a row by its handle.
        if row == nil, let pressed, let task = pressed.task, let manager = outlinerLayout {
            row = manager.lines.firstIndex { $0.start == task }
            from = pressed.point
        }
        guard let row, let from else { return super.mouseDragged(with: event) }
        guard hypot(point.x - from.x, point.y - from.y) >= 4 else { return }
        rowPress = nil
        pressed = nil
        carry(row: row, with: event)
    }

    private func carry(row: Int, with event: NSEvent) {
        guard let owner, let manager = outlinerLayout else { return }
        var rows = [row]
        if let chosen = rowsChosen, (min(chosen.anchor, chosen.head)...max(chosen.anchor, chosen.head)).contains(row) {
            rows = Array(min(chosen.anchor, chosen.head)...max(chosen.anchor, chosen.head))
        }
        let markdown = owner.editor.markdownOf(rows: rows)
        guard !markdown.isEmpty else { return }
        let item = NSPasteboardItem()
        item.setString(markdown, forType: .string)
        item.setString("rows", forType: Self.rowsType)
        let dragging = NSDraggingItem(pasteboardWriter: item)
        // What is carried is shown as it stands: the rows.
        var rect = rows.reduce(CGRect.null) { $0.union(manager.rect(ofRow: $1)) }
        rect = rect.offsetBy(dx: textContainerOrigin.x, dy: textContainerOrigin.y).intersection(bounds)
        guard !rect.isEmpty else { return }
        let image = NSImage(size: rect.size)
        if let picture = bitmapImageRepForCachingDisplay(in: rect) {
            cacheDisplay(in: rect, to: picture)
            image.addRepresentation(picture)
        }
        dragging.setDraggingFrame(rect, contents: image)
        Self.carried = (rows, markdown)
        Self.carriedFrom = self
        beginDraggingSession(with: [dragging], event: event, source: self)
    }

    override func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        Self.carriedFrom === self ? [.move, .copy] : super.draggingSession(session, sourceOperationMaskFor: context)
    }

    override func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
        if Self.carriedFrom === self {
            Self.carried = nil
            Self.carriedFrom = nil
            return
        }
        super.draggingSession(session, endedAt: screenPoint, operation: operation)
    }

    /// Where rows carried over this note would be put down, at a point of
    /// the view: before which row, how deep, and where the line that says
    /// so is drawn. `own`: the rows are this note's, being moved.
    func rowsDrop(at place: CGPoint, rows carried: [Int], own: Bool) -> (before: Int, depth: Int, y: CGFloat, x: CGFloat)? {
        guard let owner, let manager = outlinerLayout else { return nil }
        let point = CGPoint(x: place.x - textContainerOrigin.x, y: place.y - textContainerOrigin.y)
        let lines = manager.lines
        let step = max(manager.theme.step, 1)
        // Before the first row whose middle is under the pointer; after the last, past them all.
        let before = lines.indices.first { point.y < manager.rect(ofRow: $0).midY } ?? lines.count
        // As deep as the rows it comes between — or as the pointer says, by the column it is over:
        // further out, or one step in under the row above.
        let depthOf = { (index: Int) in lines.indices.contains(index) ? max(lines[index].depth - 1, 0) : 0 }
        let (above, beside) = (depthOf(before - 1), before < lines.count ? depthOf(before) : depthOf(before - 1))
        let column = max(Int(point.x / step), 0)
        var depth = column <= beside || (before > 0 && column == above + 1) ? column : beside
        if lines.isEmpty { depth = 0 } else {
            guard let held = owner.editor.dropDepth(rows: own ? carried : [], before: before, depth: depth) else { return nil }
            depth = held
        }
        let y = before < lines.count ? manager.rect(ofRow: before).minY : (lines.isEmpty ? 0 : manager.rect(ofRow: lines.count - 1).maxY)
        return (before, depth, y, CGFloat(depth) * step)
    }

    private func rowsDrop(_ sender: any NSDraggingInfo) -> (before: Int, depth: Int, y: CGFloat, x: CGFloat)? {
        guard sender.draggingPasteboard.availableType(from: [Self.rowsType]) != nil, let carried = Self.carried else { return nil }
        return rowsDrop(at: convert(sender.draggingLocation, from: nil), rows: carried.rows, own: Self.carriedFrom === self)
    }

    private func showDrop(_ sender: any NSDraggingInfo) -> Bool {
        guard let manager = outlinerLayout else { return false }
        let drop = rowsDrop(sender)
        manager.dropLine = drop.map { ($0.y, $0.x) }
        needsDisplay = true
        return drop != nil
    }

    private var carriesRows: Bool { Self.carried != nil }

    /// Rows carried are moved — or, with ⌥ held, copied: as the Finder does.
    private func operation(_ sender: any NSDraggingInfo) -> NSDragOperation {
        sender.draggingSourceOperationMask.contains(.move) ? .move : .copy
    }

    /// Its own words dragged within it: the text system's to move.
    private func ownText(_ sender: any NSDraggingInfo) -> Bool { (sender.draggingSource as? NSTextView) === self }

    /// What Manifold carries — a block's link, a file, a page, a picture,
    /// words from elsewhere — is taken as a note takes it (`Dropping`,
    /// `dropForms`); rows carried and its own words, as the outliner does.
    private func manifolds(_ sender: any NSDraggingInfo) -> Bool { !carriesRows && !ownText(sender) && owner != nil }

    override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation {
        if manifolds(sender) { return Dropping.updated(self, sender) }
        guard carriesRows, owner != nil else { return super.draggingEntered(sender) }
        return showDrop(sender) ? operation(sender) : []
    }

    override func draggingUpdated(_ sender: any NSDraggingInfo) -> NSDragOperation {
        if manifolds(sender) { return Dropping.updated(self, sender) }
        guard carriesRows, owner != nil else { return super.draggingUpdated(sender) }
        return showDrop(sender) ? operation(sender) : []
    }


    override func prepareForDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        // Rows are this view's to take, whatever the text system makes of what is carried.
        if carriesRows, owner != nil { return rowsDrop(sender) != nil }
        return super.prepareForDragOperation(sender)
    }

    override func concludeDragOperation(_ sender: (any NSDraggingInfo)?) {
        if carriesRows { return }
        super.concludeDragOperation(sender)
    }

    override func draggingExited(_ sender: (any NSDraggingInfo)?) {
        outlinerLayout?.dropLine = nil
        needsDisplay = true
        if let sender, manifolds(sender) { return Dropping.exited(self, sender) }
        if !carriesRows { super.draggingExited(sender) }
    }

    override func draggingEnded(_ sender: any NSDraggingInfo) {
        outlinerLayout?.dropLine = nil
        needsDisplay = true
        super.draggingEnded(sender)
    }

    /// Puts rows carried down where the line was. From another note, they
    /// are written here and then taken out there; within this one, moved.
    private func drop(rows sender: any NSDraggingInfo) -> Bool? {
        guard carriesRows, owner != nil else { return nil }
        guard let drop = rowsDrop(sender), let carried = Self.carried else { return false }
        outlinerLayout?.dropLine = nil
        needsDisplay = true
        return put(rows: carried.rows, of: Self.carriedFrom, before: drop.before, depth: drop.depth, copying: operation(sender) == .copy)
    }

    /// Puts rows of a note's — this one's, or another's — before a row
    /// here, at a depth: what letting go of rows carried does. Says
    /// whether they were put.
    @discardableResult
    func put(rows: [Int], of source: OutlinerTextView?, before: Int, depth: Int, copying: Bool = false) -> Bool {
        guard let owner, let source, let from = source.owner, !rows.isEmpty else { return false }
        if source === self, !copying {
            leaveRows()
            return owner.moveRows(rows, before: before, depth: depth)
        }
        let markdown = from.editor.markdownOf(rows: rows)
        guard !markdown.isEmpty, owner.insertRows(markdown, before: before, depth: depth) else { return false }
        // Copied: where they came from, they stay.
        if copying { return true }
        // Taken out where they came from, once this note has them — and only if they
        // are still what was carried.
        DispatchQueue.main.async { [weak source] in
            guard let from = source?.owner, from.editor.markdownOf(rows: rows) == markdown else { return }
            source?.leaveRows()
            from.perform(.deleteRows, onRows: rows)
        }
        window?.makeFirstResponder(self)
        return true
    }

    // MARK: Focus

    override func becomeFirstResponder() -> Bool {
        let became = super.becomeFirstResponder()
        if became { DispatchQueue.main.async { [weak self] in self?.owner?.editingChanged(true) } }
        return became
    }

    override func resignFirstResponder() -> Bool {
        let resigned = super.resignFirstResponder()
        if resigned {
            leaveRows()
            setSelectedRange(NSRange(location: selectedRange().location, length: 0))
            DispatchQueue.main.async { [weak self] in self?.owner?.editingChanged(false) }
        }
        return resigned
    }

    // MARK: Rows chosen
    //
    // Esc chooses the row the caret is in: the whole row, marked across the
    // note's width. ↑ and ↓ then choose the row above or below — with ⇧,
    // more of them — and what is done is done to the rows: Tab and ⇧Tab set
    // them in and out, ⌫ deletes them, ⌃⌘↑ and ⌃⌘↓ carry them, ⌘C copies
    // them as Markdown, Space checks their boxes. Return, a click, or ← →
    // go back to writing; Esc again goes back to the caret where it was.

    /// The rows chosen, from the one first chosen to the one gone to
    /// since: lines of the outline, counted from the first. Nothing,
    /// while the note is written in.
    private(set) var rowsChosen: (anchor: Int, head: Int)?
    /// Where the caret was when rows came to be chosen: where Esc goes back to.
    private var caretBeforeRows: Int?
    /// What Expand Selection went through, the last on top: what Contract Selection goes back to.
    private var expansions: [Chosen] = []

    /// A selection, as Expand Selection steps through them: words, or rows.
    enum Chosen: Equatable {
        case words(NSRange)
        case rows(Int, Int)
    }

    var isChoosingRows: Bool { rowsChosen != nil }

    /// The rows chosen, first to last.
    var chosenRows: ClosedRange<Int>? {
        rowsChosen.map { min($0.anchor, $0.head)...max($0.anchor, $0.head) }
    }

    func row(at location: Int) -> Int? {
        let lines = outlineLines
        return lines.lastIndex { $0.start <= location } ?? (lines.isEmpty ? nil : 0)
    }

    /// Chooses rows: the text they cover is what is selected, so that
    /// what is done to a selection is done to them.
    func chooseRows(anchor: Int, head: Int) {
        let lines = outlineLines
        guard !lines.isEmpty else { return leaveRows() }
        let (anchor, head) = (min(max(anchor, 0), lines.count - 1), min(max(head, 0), lines.count - 1))
        rowsChosen = (anchor, head)
        let (first, last) = (lines[min(anchor, head)], lines[max(anchor, head)])
        setSelectedRange(NSRange(location: first.start, length: last.end - first.start))
        // The rows are marked whole; the words in them are not marked again, and there is no caret.
        selectedTextAttributes = [:]
        insertionPointColor = .clear
        outlinerLayout?.chosen = first.start...last.end
        scrollRangeToVisible(NSRange(location: lines[head].start, length: 0))
        needsDisplay = true
    }

    /// The rows the selection covers now, chosen: after something was done to them.
    private func chooseSelectedRows() {
        let selection = selectedRange()
        guard rowsChosen != nil, let first = row(at: selection.location), let last = row(at: max(NSMaxRange(selection) - (selection.length > 0 ? 1 : 0), selection.location)) else { return }
        chooseRows(anchor: first, head: max(last, first))
    }

    /// Back to writing: the caret where `at` says, or left as it is.
    func leaveRows(caretAt at: Int? = nil) {
        guard rowsChosen != nil else { return }
        rowsChosen = nil
        caretBeforeRows = nil
        outlinerLayout?.chosen = nil
        selectedTextAttributes = [.backgroundColor: Tints.textSelection]
        insertionPointColor = Tints.caret
        if let at { setSelectedRange(NSRange(location: min(at, textStorage?.length ?? at), length: 0)) }
        needsDisplay = true
    }

    private func stepRows(_ step: Int, extending: Bool) {
        guard let chosen = rowsChosen else { return }
        let head = chosen.head + step
        chooseRows(anchor: extending ? chosen.anchor : head, head: head)
    }

    /// ⇧↑ and ⇧↓, as Bike 2's: words are chosen within a row only — to its
    /// start, or its end — then the row is chosen whole, then the rows
    /// before it, or after.
    override func moveUpAndModifySelection(_ sender: Any?) {
        if isChoosingRows { return stepRows(-1, extending: true) }
        guard let (index, line) = selectionRow() else { return super.moveUpAndModifySelection(sender) }
        let selection = selectedRange()
        if selection.location > line.content {
            return setSelectedRange(NSRange(location: line.content, length: NSMaxRange(selection) - line.content))
        }
        caretBeforeRows = caretBeforeRows ?? NSMaxRange(selection)
        chooseRows(anchor: index, head: index)
    }

    override func moveDownAndModifySelection(_ sender: Any?) {
        if isChoosingRows { return stepRows(1, extending: true) }
        guard let (index, line) = selectionRow() else { return super.moveDownAndModifySelection(sender) }
        let selection = selectedRange()
        if NSMaxRange(selection) < line.end {
            return setSelectedRange(NSRange(location: selection.location, length: line.end - selection.location))
        }
        caretBeforeRows = caretBeforeRows ?? selection.location
        chooseRows(anchor: index, head: index)
    }

    /// ⇧← and ⇧→ go no further than the row's words.
    override func moveLeftAndModifySelection(_ sender: Any?) {
        if isChoosingRows { return }
        if let (_, line) = selectionRow(), selectedRange().location <= line.content { return }
        super.moveLeftAndModifySelection(sender)
    }

    override func moveRightAndModifySelection(_ sender: Any?) {
        if isChoosingRows { return }
        if let (_, line) = selectionRow(), NSMaxRange(selectedRange()) >= line.end { return }
        super.moveRightAndModifySelection(sender)
    }

    /// Whether a line is code, where what is typed is typed as it is.
    static func isCode(_ line: BodyLine) -> Bool {
        switch line.kind {
        case .code, .fence: return true
        default: return false
        }
    }

    /// The row the selection is in — when it is all in one.
    private func selectionRow() -> (Int, BodyLine)? {
        let lines = outlineLines
        let selection = selectedRange()
        guard let index = row(at: selection.location), lines.indices.contains(index), NSMaxRange(selection) <= lines[index].end else { return nil }
        return (index, lines[index])
    }

    // With rows chosen, ← → ⌥← ⌥→ go back to writing — at the first row's
    // start, or the last's end; ⌘↑ ⌘↓ choose the first or the last row,
    // ⇧⌘↑ ⇧⌘↓ the rows to there.

    private func leaveRows(atStart: Bool) {
        guard let chosen = rowsChosen else { return }
        let lines = outlineLines
        let (first, last) = (min(chosen.anchor, chosen.head), max(chosen.anchor, chosen.head))
        guard lines.indices.contains(first), lines.indices.contains(last) else { return leaveRows() }
        leaveRows(caretAt: atStart ? lines[first].content : lines[last].end)
    }

    override func moveLeft(_ sender: Any?) { if isChoosingRows { leaveRows(atStart: true) } else { super.moveLeft(sender) } }
    override func moveRight(_ sender: Any?) { if isChoosingRows { leaveRows(atStart: false) } else { super.moveRight(sender) } }
    override func moveWordLeft(_ sender: Any?) { if isChoosingRows { leaveRows(atStart: true) } else { super.moveWordLeft(sender) } }
    override func moveWordRight(_ sender: Any?) { if isChoosingRows { leaveRows(atStart: false) } else { super.moveWordRight(sender) } }
    override func moveToBeginningOfParagraph(_ sender: Any?) { if isChoosingRows { leaveRows(atStart: true) } else { super.moveToBeginningOfParagraph(sender) } }
    override func moveToEndOfParagraph(_ sender: Any?) { if isChoosingRows { leaveRows(atStart: false) } else { super.moveToEndOfParagraph(sender) } }
    override func moveParagraphBackwardAndModifySelection(_ sender: Any?) { if isChoosingRows { leaveRows(atStart: true) } else { super.moveParagraphBackwardAndModifySelection(sender) } }
    override func moveParagraphForwardAndModifySelection(_ sender: Any?) { if isChoosingRows { leaveRows(atStart: false) } else { super.moveParagraphForwardAndModifySelection(sender) } }

    override func moveToBeginningOfDocument(_ sender: Any?) {
        if isChoosingRows { return chooseRows(anchor: 0, head: 0) }
        super.moveToBeginningOfDocument(sender)
    }

    override func moveToEndOfDocument(_ sender: Any?) {
        let last = outlineLines.count - 1
        if isChoosingRows { return chooseRows(anchor: last, head: last) }
        super.moveToEndOfDocument(sender)
    }

    override func moveToBeginningOfDocumentAndModifySelection(_ sender: Any?) {
        if let chosen = rowsChosen { return chooseRows(anchor: chosen.anchor, head: 0) }
        super.moveToBeginningOfDocumentAndModifySelection(sender)
    }

    override func moveToEndOfDocumentAndModifySelection(_ sender: Any?) {
        if let chosen = rowsChosen { return chooseRows(anchor: chosen.anchor, head: outlineLines.count - 1) }
        super.moveToEndOfDocumentAndModifySelection(sender)
    }

    /// ⌘A: every row, chosen as rows.
    override func selectAll(_ sender: Any?) {
        let lines = outlineLines
        guard !lines.isEmpty else { return super.selectAll(sender) }
        if !isChoosingRows { caretBeforeRows = selectedRange().location }
        chooseRows(anchor: 0, head: lines.count - 1)
    }

    // MARK: Expand and contract selection
    //
    // ⌃⇧⌘→: the word, the sentence, the row's words, the row, its branch,
    // its parent's branch, and on out. ⌃⇧⌘← goes back a step.

    private var chosenNow: Chosen {
        if let chosen = rowsChosen { return .rows(min(chosen.anchor, chosen.head), max(chosen.anchor, chosen.head)) }
        return .words(selectedRange())
    }

    private func choose(_ chosen: Chosen) {
        switch chosen {
        case .words(let range):
            leaveRows()
            setSelectedRange(range)
        case .rows(let first, let last):
            if !isChoosingRows { caretBeforeRows = selectedRange().location }
            chooseRows(anchor: first, head: last)
        }
    }

    /// The rows a row's branch shows: it, and every row after it deeper than it.
    private func branch(of index: Int, in lines: [BodyLine]) -> ClosedRange<Int> {
        var last = index
        while last + 1 < lines.count, lines[last + 1].depth > lines[index].depth { last += 1 }
        return index...last
    }

    /// What Expand Selection goes to from a selection.
    private func expanded(from chosen: Chosen) -> Chosen? {
        let lines = outlineLines
        let text = string as NSString
        switch chosen {
        case .words(let range):
            guard let index = row(at: range.location), lines.indices.contains(index) else { return nil }
            let line = lines[index]
            let words = NSRange(location: line.content, length: line.end - line.content)
            // The word, then the sentence, then the row's words: each the first that holds more than is chosen.
            var steps: [NSRange] = [selectionRange(forProposedRange: NSRange(location: range.location, length: max(range.length, 0)), granularity: .selectByWord)]
            text.enumerateSubstrings(in: words, options: [.bySentences, .substringNotRequired]) { _, sentence, _, stop in
                if NSIntersectionRange(sentence, range).length > 0 || (range.length == 0 && NSLocationInRange(range.location, sentence)) {
                    steps.append(sentence)
                    stop.pointee = true
                }
            }
            steps.append(words)
            if let next = steps.first(where: { NSUnionRange($0, range) == $0 && $0 != range && NSIntersectionRange($0, words) == $0 }) { return .words(next) }
            return .rows(index, index)
        case .rows(let first, let last):
            let whole = branch(of: first, in: lines)
            if whole.upperBound > last || first != whole.lowerBound { return .rows(whole.lowerBound, max(whole.upperBound, last)) }
            // Out to the parent's branch.
            guard let parent = (0..<first).last(where: { lines[$0].depth < lines[first].depth }) else {
                return lines.isEmpty || (first == 0 && last == lines.count - 1) ? nil : .rows(0, lines.count - 1)
            }
            return .rows(parent, branch(of: parent, in: lines).upperBound)
        }
    }

    func expandSelection() {
        let now = chosenNow
        guard !outlineLines.isEmpty, let next = expanded(from: now) else { return NSSound.beep() }
        if expansions.last != now { expansions = [] }
        expansions.append(now)
        choose(next)
        expansions.append(next)
    }

    func contractSelection() {
        // Back a step only from where expanding left it.
        guard expansions.count >= 2, expansions.last == chosenNow else { return NSSound.beep() }
        expansions.removeLast()
        let back = expansions.removeLast()
        choose(back)
        if !expansions.isEmpty { expansions.append(back) }
    }

    /// ⌃W, ⌃S: the word, or the sentence, the caret is in.
    func selectWord() {
        setSelectedRange(selectionRange(forProposedRange: selectedRange(), granularity: .selectByWord))
    }

    func selectSentence() {
        guard let (_, line) = selectionRow() else { return }
        let words = NSRange(location: line.content, length: line.end - line.content)
        let at = selectedRange().location
        (string as NSString).enumerateSubstrings(in: words, options: [.bySentences, .substringNotRequired]) { _, sentence, _, stop in
            if NSLocationInRange(at, sentence) || NSMaxRange(sentence) == at {
                self.setSelectedRange(sentence)
                stop.pointee = true
            }
        }
    }

    // MARK: Typing

    override func insertBacktab(_ sender: Any?) {
        _ = owner?.perform(.outdent)
        chooseSelectedRows()
    }

    override func insertText(_ string: Any, replacementRange: NSRange) {
        // Typed with rows chosen: Space checks the tasks among them off, or opens them again; nothing else is typed.
        if let chosen = rowsChosen {
            guard (string as? String) == " " || (string as? NSAttributedString)?.string == " " else { return }
            let lines = outlineLines
            let tasks = (min(chosen.anchor, chosen.head)...max(chosen.anchor, chosen.head)).filter { index in
                guard lines.indices.contains(index), case .item(_, let done, _) = lines[index].kind else { return false }
                return done != nil
            }
            if tasks.isEmpty || owner?.perform(.toggleCheckbox, onRows: tasks) != true { return }
            chooseRows(anchor: chosen.anchor, head: chosen.head)
            return
        }
        if let typed = (string as? String) ?? (string as? NSAttributedString)?.string, let (_, line) = selectionRow(), !Self.isCode(line) {
            let selection = selectedRange()
            // ' " [ { ( typed over words chosen in a row: the words wrapped, and still chosen — as Bike's.
            let pairs: [String: String] = ["'": "'", "\"": "\"", "[": "]", "{": "}", "(": ")"]
            if selection.length > 0, let close = pairs[typed], replacementRange.location == NSNotFound || replacementRange == selection {
                let words = (self.string as NSString).substring(with: selection)
                super.insertText(typed + words + close, replacementRange: selection)
                setSelectedRange(NSRange(location: selection.location + (typed as NSString).length, length: selection.length))
                return
            }
            // A quote typed, curled: opening after a space or a row's start, else closing.
            if selection.length == 0, typed == "'" || typed == "\"" {
                let before = selection.location > line.content ? (self.string as NSString).substring(with: NSRange(location: selection.location - 1, length: 1)) : ""
                let opening = before.isEmpty || before.rangeOfCharacter(from: .whitespaces.union(CharacterSet(charactersIn: "([{“‘"))) != nil
                let curled = typed == "'" ? (opening ? "‘" : "’") : (opening ? "“" : "”")
                return super.insertText(curled, replacementRange: replacementRange)
            }
        }
        super.insertText(string, replacementRange: replacementRange)
    }

    override func copy(_ sender: Any?) {
        // Rows chosen are copied as they are written: their bullets and boxes with them.
        if let rows = chosenRows, let markdown = owner?.markdown(ofRows: Array(rows)) {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(markdown, forType: .string)
            return
        }
        super.copy(sender)
    }

    /// Words chosen, copied, cut or dragged: as the Markdown they are, links
    /// and pictures and all — the view shows only their words.
    override func writeSelection(to board: NSPasteboard, types: [NSPasteboard.PasteboardType]) -> Bool {
        let selection = selectedRange()
        guard !outlineLines.isEmpty, !isChoosingRows, selection.length > 0, let owner else { return super.writeSelection(to: board, types: types) }
        let markdown = owner.editor.markdownBetween(start: selection.location, end: NSMaxRange(selection))
        board.declareTypes([.string], owner: nil)
        return board.setString(markdown, forType: .string)
    }

    override func cut(_ sender: Any?) {
        guard isChoosingRows else { return super.cut(sender) }
        copy(sender)
        deleteBackward(sender)
    }

    override func insertNewline(_ sender: Any?) {
        // Return, with rows chosen: a new row after them, as Return at the last one's end makes, written in.
        if let chosen = rowsChosen {
            let lines = outlineLines
            leaveRows(caretAt: lines.indices.contains(max(chosen.anchor, chosen.head)) ? lines[max(chosen.anchor, chosen.head)].end : nil)
            if owner?.perform(.newline) != true { NSSound.beep() }
            return
        }
        if owner?.perform(.newline) != true { super.insertNewline(sender) }
    }

    override func insertTab(_ sender: Any?) {
        // In an outline Tab only ever indents: a row that cannot go in stays, and no tab is typed.
        if owner?.perform(.indent) != true, !isChoosingRows, outlineLines.isEmpty { super.insertTab(sender) }
        chooseSelectedRows()
    }

    /// ⇧↩ and ⌥↩ split a row as ↩ does: an outline has no line breaks within rows.
    override func insertLineBreak(_ sender: Any?) {
        if outlineLines.isEmpty { super.insertLineBreak(sender) } else { insertNewline(sender) }
    }

    override func insertNewlineIgnoringFieldEditor(_ sender: Any?) {
        if outlineLines.isEmpty { super.insertNewlineIgnoringFieldEditor(sender) } else { insertNewline(sender) }
    }

    override func moveUp(_ sender: Any?) {
        if isChoosingRows { return stepRows(-1, extending: false) }
        super.moveUp(sender)
    }

    override func moveDown(_ sender: Any?) {
        if isChoosingRows { return stepRows(1, extending: false) }
        super.moveDown(sender)
    }

    override func deleteBackward(_ sender: Any?) {
        // Rows chosen are deleted whole; the row that takes their place is chosen.
        if let chosen = rowsChosen {
            let at = min(chosen.anchor, chosen.head)
            if owner?.perform(.deleteRows) == true {
                let left = outlineLines.count
                if left == 0 { leaveRows(caretAt: 0) } else { chooseRows(anchor: min(at, left - 1), head: min(at, left - 1)) }
            }
            return
        }
        if owner?.perform(.deleteBackward) == true { return }
        if deleteOverMarkup(forward: false) { return }
        super.deleteBackward(sender)
    }

    override func deleteForward(_ sender: Any?) {
        if isChoosingRows { return deleteBackward(sender) }
        if deleteOverMarkup(forward: true) { return }
        super.deleteForward(sender)
    }

    // MARK: Markdown never seen
    //
    // A row's Markdown — `**`, a link's brackets and address — is in the
    // text but never seen, as Bike's rich text has none. The caret never
    // stops inside it: each run of it is a boundary, crossed with one
    // press, which is the caret's side — Bike's typing affinity: before it,
    // what is typed joins the words before; after it, the words after.
    // Delete steps over it; a link shown by its title goes whole.

    func isMarkup(_ at: Int) -> Bool {
        guard let storage = textStorage, at >= 0, at < storage.length else { return false }
        return storage.attribute(.outlinerMarkup, at: at, effectiveRange: nil) != nil
    }

    /// The run of hidden Markdown a place is strictly inside of.
    private func markupRun(around at: Int) -> (start: Int, end: Int)? {
        guard isMarkup(at - 1), isMarkup(at) else { return nil }
        var (start, end) = (at - 1, at)
        while isMarkup(start - 1) { start -= 1 }
        while isMarkup(end) { end += 1 }
        return (start, end)
    }

    override func setSelectedRanges(_ ranges: [NSValue], affinity: NSSelectionAffinity, stillSelecting: Bool) {
        let old = selectedRange()
        // Never inside a link shown as its title: it is one thing, before or after it.
        let ranges = ranges.map { value in NSValue(range: textStorage.map { OutlinerStyler.outsideWholes(in: $0, value.rangeValue, from: old) } ?? value.rangeValue) }
        guard !outlineLines.isEmpty, !isChoosingRows else { return super.setSelectedRanges(ranges, affinity: affinity, stillSelecting: stillSelecting) }
        let snapped = ranges.map { value -> NSValue in
            var range = value.rangeValue
            if range.length == 0 {
                // Out of hidden Markdown, the way the caret was going.
                if let run = markupRun(around: range.location) { range.location = range.location > old.location ? run.end : run.start }
            } else {
                if let run = markupRun(around: range.location) { range = NSRange(location: run.start, length: NSMaxRange(range) - run.start) }
                if let run = markupRun(around: NSMaxRange(range)) { range.length = run.end - range.location }
            }
            return NSValue(range: range)
        }
        super.setSelectedRanges(snapped, affinity: affinity, stillSelecting: stillSelecting)
        // What is typed takes the look of the words it joins, never the hidden Markdown's.
        let caret = selectedRange()
        if caret.length == 0, isMarkup(caret.location - 1), let storage = textStorage {
            let from = caret.location < storage.length && !isMarkup(caret.location) ? caret.location : nil
            var attributes = from.map { storage.attributes(at: $0, effectiveRange: nil) } ?? [:]
            attributes[.outlinerMarkup] = nil
            attributes[.outlinerLabel] = nil
            if from == nil, let theme = owner?.theme { attributes = OutlinerStyler(theme: theme).baseAttributes }
            typingAttributes = attributes
        }
    }

    /// Delete beside hidden Markdown: the character past it — or a link
    /// shown by its title, whole — and not the Markdown. Says whether it
    /// did anything.
    private func deleteOverMarkup(forward: Bool) -> Bool {
        let selection = selectedRange()
        guard !outlineLines.isEmpty, selection.length == 0, let storage = textStorage else { return false }
        var at = selection.location
        if forward { while isMarkup(at) { at += 1 } } else { while isMarkup(at - 1) { at -= 1 } }
        guard at != selection.location else { return false }
        let text = storage.string as NSString
        // At a row's start, past Markdown that begins it: what Delete does there.
        if !forward, let index = row(at: at), outlineLines[index].content == at {
            setSelectedRange(NSRange(location: at, length: 0))
            if owner?.perform(.deleteBackward) != true { super.deleteBackward(nil) }
            return true
        }
        let character = forward ? at : at - 1
        guard character >= 0, character < text.length, text.character(at: character) != 10 else { return false }
        var target = text.rangeOfComposedCharacterSequence(at: character)
        if storage.attribute(.outlinerLabel, at: character, effectiveRange: nil) != nil {
            // A link shown by its title: the link, whole, with its brackets.
            var whole = NSRange()
            _ = storage.attribute(.outlinerLink, at: character, longestEffectiveRange: &whole, in: NSRange(location: 0, length: storage.length))
            var (start, end) = (whole.location, NSMaxRange(whole))
            while isMarkup(start - 1) { start -= 1 }
            while isMarkup(end) { end += 1 }
            target = NSRange(location: start, length: end - start)
        }
        guard shouldChangeText(in: target, replacementString: "") else { return true }
        insertText("", replacementRange: target)
        return true
    }

    override func cancelOperation(_ sender: Any?) {
        let lines = outlineLines
        guard !lines.isEmpty, !hasMarkedText() else {
            leaveRows()
            return
        }
        // Esc goes between writing and rows chosen, as Bike's does: back to the caret where it was.
        if let chosen = rowsChosen {
            let (first, last) = (lines[min(chosen.anchor, chosen.head)], lines[max(chosen.anchor, chosen.head)])
            let kept = caretBeforeRows.flatMap { $0 >= first.start && $0 <= last.end ? $0 : nil }
            let at = kept ?? lines[min(chosen.head, lines.count - 1)].end
            return leaveRows(caretAt: at)
        }
        let selection = selectedRange()
        guard let first = row(at: selection.location), let last = row(at: max(NSMaxRange(selection) - (selection.length > 0 ? 1 : 0), selection.location)) else { return }
        caretBeforeRows = selection.location
        chooseRows(anchor: first, head: last)
    }

    // MARK: Keys

    override func keyDown(with event: NSEvent) {
        let flags = event.modifierFlags.intersection([.command, .shift, .option, .control])
        // ⌃W, ⌃S: the word, the sentence.
        if flags == [.control], !outlineLines.isEmpty, let key = event.charactersIgnoringModifiers?.lowercased(), key == "w" || key == "s" {
            leaveRows()
            return key == "w" ? selectWord() : selectSentence()
        }
        // Bike's keys with ⌃⌥ and no ⌘ — the row alone, promote and demote — are no menu's: taken here.
        if !flags.contains(.command), flags.isSuperset(of: [.control, .option]), !outlineLines.isEmpty,
           let command = Self.command(flags: flags, key: event.charactersIgnoringModifiers?.lowercased() ?? "", special: event.specialKey) {
            if !perform(keyed: command) { NSSound.beep() }
            return
        }
        super.keyDown(with: event)
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard window?.firstResponder === self else { return super.performKeyEquivalent(with: event) }
        let flags = event.modifierFlags.intersection([.command, .shift, .option, .control])
        let key = event.charactersIgnoringModifiers?.lowercased() ?? ""
        if key == "z", flags == [.command] {
            owner?.undo()
            return true
        }
        if key == "z", flags == [.command, .shift] {
            owner?.redo()
            return true
        }
        if key == "k", flags == [.command, .option] {
            askLink()
            return true
        }
        // ⌥⌘→ shows only the caret's row and what is under it — Bike's focus in; ⌥⌘← shows more again.
        if event.specialKey == .rightArrow, flags == [.command, .option] {
            if owner?.focusIn() != true { NSSound.beep() }
            return true
        }
        if event.specialKey == .leftArrow, flags == [.command, .option] {
            if owner?.focusOut() != true { NSSound.beep() }
            return true
        }
        // ⌘A in an outline: every row, chosen as rows.
        if key == "a", flags == [.command], !outlineLines.isEmpty {
            selectAll(nil)
            return true
        }
        if flags == [.command, .control, .shift], !outlineLines.isEmpty, event.specialKey == .rightArrow || event.specialKey == .leftArrow {
            if event.specialKey == .rightArrow { expandSelection() } else { contractSelection() }
            return true
        }
        guard let command = Self.command(flags: flags, key: key, special: event.specialKey) else { return super.performKeyEquivalent(with: event) }
        let done = perform(keyed: command)
        // A fold with nothing to fold leaves its key to whoever wants it.
        return done || !Self.outlineOnly.contains(command) || super.performKeyEquivalent(with: event)
    }

    /// A command its keys gave, and where the selection then is, as Bike has
    /// it: writing in a row put in, joined or grouped; the copy chosen as
    /// rows; after rows deleted, the next row chosen; else as it was.
    func perform(keyed command: EditCommand) -> Bool {
        let done = owner?.perform(command) ?? false
        guard done else { return false }
        switch command {
        case .insertBelow, .insertAbove, .insertChild, .group, .joinRows:
            leaveRows()
        case .duplicateRows, .deleteRows:
            if let at = row(at: selectedRange().location) { chooseRows(anchor: at, head: at) }
        default:
            // Done to rows chosen: they are chosen still, wherever they went.
            chooseSelectedRows()
        }
        return true
    }

    /// The commands only an outline has, whose keys are let by when there is nothing for them to do.
    private static let outlineOnly: Set<EditCommand> = [.fold, .unfold, .foldCompletely, .unfoldCompletely, .foldAll, .unfoldAll, .foldByLevel, .unfoldByLevel, .foldAllByLevel, .unfoldAllByLevel, .moveDoneToBottom]

    /// Bike 2's keys, as its menus and key maps have them.
    static func command(flags: NSEvent.ModifierFlags, key: String, special: NSEvent.SpecialKey?) -> EditCommand? {
        switch (flags, key) {
        case ([.command], "b"): return .bold
        case ([.command], "i"): return .italic
        case ([.command, .shift], "h"): return .highlight
        case ([.command, .shift], "c"): return .code
        // With ⇧, the keys say what they say shifted: - is _.
        case ([.command, .shift], "-"), ([.command, .shift], "_"): return .strikethrough
        case ([.command, .shift], "k"): return .deleteRows
        case ([.control, .option], "k"): return .deleteRowOnly
        case ([.command], "d"): return .duplicateRows
        case ([.command, .option], "g"): return .group
        case ([.command, .shift], "8"), ([.command, .shift], "*"): return .bullet
        case ([.command, .shift], "l"): return .cycleChecklist
        case ([.command, .control], "l"): return .toggleTask
        case ([.command], "9"): return .fold
        case ([.command], "0"): return .unfold
        case ([.command, .option], "9"): return .foldByLevel
        case ([.command, .option], "0"): return .unfoldByLevel
        case ([.command, .control, .option], "9"): return .foldAllByLevel
        case ([.command, .control, .option], "0"): return .unfoldAllByLevel
        case ([.command, .control], "9"): return .foldAll
        case ([.command, .control], "0"): return .unfoldAll
        case ([.command, .control, .shift], "d"): return .moveDoneToBottom
        default: break
        }
        if special == .carriageReturn || special == .enter || key == "\r" {
            if flags == [.command] { return .insertBelow }
            if flags == [.command, .shift] { return .insertAbove }
            if flags == [.command, .option] { return .insertChild }
        }
        if special == .delete || special == .backspace || key == "\u{7F}" || key == "\u{8}", flags == [.command, .control] { return .joinRows }
        let arrows: [NSEvent.SpecialKey: Int] = [.upArrow: 0, .downArrow: 1, .rightArrow: 2, .leftArrow: 3]
        guard let special, let arrow = arrows[special] else { return nil }
        switch flags {
        case [.command, .control]: return [EditCommand.moveUp, .moveDown, .indent, .outdent][arrow]
        case [.command, .control, .option]: return [EditCommand.moveUpKeepingLevel, .moveDownKeepingLevel, nil, nil][arrow]
        case [.control, .option]: return [EditCommand.moveUpRowOnly, .moveDownRowOnly, .indentRowOnly, .outdentRowOnly][arrow]
        case [.control, .option, .shift]: return [nil, nil, EditCommand.demoteSiblings, .promoteChildren][arrow]
        default: return nil
        }
    }

    // MARK: Undo, as the menu asks it

    @objc func undo(_ sender: Any?) { owner?.undo() }
    @objc func redo(_ sender: Any?) { owner?.redo() }

    override func validateUserInterfaceItem(_ item: any NSValidatedUserInterfaceItem) -> Bool {
        switch item.action {
        case #selector(undo(_:)): return owner?.editor.canUndo ?? false
        case #selector(redo(_:)): return owner?.editor.canRedo ?? false
        case #selector(paste(_:)) where isEditable && NSPasteboard.general.availableType(from: PasteboardImages.types + [.fileURL]) != nil: return true
        case #selector(performTextFinderAction(_:)) where onFind != nil: return true
        default:
            if let ok = validateOutline(item) { return ok }
            return super.validateUserInterfaceItem(item)
        }
    }

    /// ⌘F and the rest of find: the tile's find pill (`OutlineNoteView`'s), not the text view's bar.
    var onFind: ((Any?) -> Void)?

    override func performTextFinderAction(_ sender: Any?) {
        if let onFind { onFind(sender) } else { super.performTextFinderAction(sender) }
    }

    // MARK: Pictures, and an address, pasted and dropped

    /// An address pasted onto words links them; pictures pasted are the
    /// app's to keep, and are written where the caret is; anything else
    /// is pasted as ever (Markdown, which the note reads as rows).
    override func paste(_ sender: Any?) {
        let board = NSPasteboard.general
        if selectedRange().length > 0, let words = board.string(forType: .string), owner?.link(to: words) == true { return }
        if owner?.pastePictures(from: board, at: nil) == true { return }
        super.paste(sender)
    }

    /// A picture can be pasted, though the text view holds only words:
    /// said so, or Paste is greyed out whenever what was copied is a picture.
    override var readablePasteboardTypes: [NSPasteboard.PasteboardType] {
        super.readablePasteboardTypes + PasteboardImages.types.filter { !super.readablePasteboardTypes.contains($0) }
    }

    override var acceptableDragTypes: [NSPasteboard.PasteboardType] {
        super.acceptableDragTypes + ([Self.rowsType] + PasteboardImages.types + [.fileURL]).filter { !super.acceptableDragTypes.contains($0) }
    }

    /// Pictures dropped: the app's to keep, and written where they were let go.
    override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        if manifolds(sender) { return Dropping.perform(self, sender) }
        if let dropped = drop(rows: sender) { return dropped }
        let at = characterIndexForInsertion(at: convert(sender.draggingLocation, from: nil))
        if owner?.pastePictures(from: sender.draggingPasteboard, at: at) == true { return true }
        return super.performDragOperation(sender)
    }

    // MARK: A link, asked for

    /// ⌥⌘K: asks where the words selected should lead, and links them
    /// there; with nothing selected, writes the address itself.
    func askLink() {
        guard let window, linkPrompt == nil else { return }
        let range = selectedRange()
        var anchor = convert(window.convertFromScreen(firstRect(forCharacterRange: range, actualRange: nil)), from: nil)
        anchor.size.width = max(anchor.width, 1)
        let field = NSTextField(frame: NSRect(x: 12, y: 10, width: 300, height: 24))
        field.placeholderString = "Link to — https://… or manifold:…"
        field.bezelStyle = .roundedBezel
        field.target = self
        field.action = #selector(linkEntered(_:))
        // An address already copied is most likely the one meant.
        if let copied = NSPasteboard.general.string(forType: .string)?.trimmingCharacters(in: .whitespacesAndNewlines),
           NoteEditor.webAddress(copied) != nil || OutlinerLink.isManifold(copied) { field.stringValue = copied }
        let holder = NSViewController()
        holder.view = NSView(frame: NSRect(x: 0, y: 0, width: 324, height: 44))
        holder.view.addSubview(field)
        let prompt = NSPopover()
        prompt.contentViewController = holder
        prompt.behavior = .transient
        prompt.delegate = self
        linkPrompt = prompt
        linkRange = range
        prompt.show(relativeTo: anchor, of: self, preferredEdge: .maxY)
        prompt.contentViewController?.view.window?.makeFirstResponder(field)
    }

    @objc private func linkEntered(_ field: NSTextField) {
        var address = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let range = linkRange
        linkPrompt?.close()
        guard !address.isEmpty else { return }
        // Written without its scheme, as addresses are said.
        if NoteEditor.webAddress(address) == nil, !OutlinerLink.isManifold(address), !address.contains("://") { address = "https://" + address }
        window?.makeFirstResponder(self)
        setSelectedRange(range)
        if range.length > 0 {
            if owner?.link(to: address) != true { NSSound.beep() }
        } else {
            insertText("<\(address)>", replacementRange: range)
        }
    }
}

extension OutlinerTextView: NSPopoverDelegate {
    func popoverDidClose(_ notification: Notification) {
        if (notification.object as? NSPopover) === linkPrompt { linkPrompt = nil }
    }
}
