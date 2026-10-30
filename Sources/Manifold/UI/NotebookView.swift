import AppKit
import ManifoldCore

protocol NotebookViewDelegate: AnyObject {
    func notebook(_ view: NotebookView, edit: NotebookEdit)
    func notebook(_ view: NotebookView, run cells: [String])
    func notebookInterrupt(_ view: NotebookView)
    func notebookRestart(_ view: NotebookView)
    /// The shell started, if it isn't running (the notebook came on screen).
    func notebookStart(_ view: NotebookView)
    /// A path or an address ⌘-clicked in an output.
    func notebook(_ view: NotebookView, open target: String)
    /// A block ⇧-dragged into a cell: its path typed, and linked.
    func notebook(_ view: NotebookView, linkedFrom block: BlockID)
    /// A cell's output, as a block of its own beside the notebook.
    func notebook(_ view: NotebookView, openOutput cell: NotebookCell)
}

/// The shell notebook lens (§7.7): a column of cells, each a command to
/// edit with what its last run printed beneath it, all run in one shell
/// that lives on. ⌘↩ runs a cell; ⇧↩ runs it and goes to the next (made
/// if it's the last); ⌥↩ runs it and makes one below; ⌘. interrupts, and
/// again kills; ↑ and ↓ past a cell's edge go to the next one.
final class NotebookView: NSView, PaneContent, KeepsViewState {
    let keeper = ViewStateKeeper()
    let placement: PlacementID
    let block: BlockID
    weak var delegate: NotebookViewDelegate?
    var source: () -> Block? = { nil }
    var codeFont: NSFont = .monospacedSystemFont(ofSize: 12.5, weight: .regular) {
        didSet { if codeFont != oldValue { cells.values.forEach { $0.font = codeFont }; needsLayout = true } }
    }

    private let header = NSView()
    /// The shell's state, as the sidebar shows a block's: turning while a
    /// cell runs, a moon with no shell; else the shell's symbol.
    private let glyph = StatusGlyph()
    private let shellIcon = NSImageView()
    private let status = NSTextField(labelWithString: "")
    private let runs = ActionCapsule()
    private let tools = ActionCapsule()
    private let scroll = ClippingScrollView()
    private let stack = FlippedView()
    private let addBelow = HoverLink(title: "New Cell", symbol: "plus")
    private var cells: [String: NotebookCellView] = [:]
    private var order: [String] = []
    fileprivate var printableCells: [(source: String, output: String)] {
        order.compactMap { cells[$0] }.map { ($0.editor.string, $0.output.string) }
    }
    /// Cells made here that the host hasn't written yet, and where.
    private var pendingInserts: [String: Int] = [:]
    private var shown: NotebookState?
    private var shownHome: String?
    private var focusedCell: String?
    private var ticker: Timer?

    var focusView: NSView { focusedCell.flatMap { cells[$0]?.editor } ?? order.first.flatMap { cells[$0]?.editor } ?? self }
    var isDead: Bool { false }
    static let headerHeight: CGFloat = 40

    init(placement: PlacementID, block: BlockID) {
        self.placement = placement
        self.block = block
        super.init(frame: .zero)
        wantsLayer = true
        themed { $0.layer?.backgroundColor = Theme.windowBackground.cgColor }
        registerDrops()
        status.lineBreakMode = .byTruncatingMiddle
        shellIcon.image = Theme.symbol(Marks.terminal, size: 12)
        shellIcon.contentTintColor = Theme.secondaryText
        for v in [glyph, shellIcon, status] as [NSView] { header.addSubview(v) }
        runs.actions = [
            .init(symbol: "play.fill", tip: "Run Cell (⌘↩)") { [weak self] _, _ in self?.runFocused() },
            .init(symbol: "forward.end.fill", tip: "Run All Cells") { [weak self] _, _ in self?.runAll() },
            .init(symbol: "stop.fill", tip: "Interrupt (⌘.) — again to stop it for good") { [weak self] _, _ in self?.interrupt() },
        ]
        tools.actions = [
            .init(symbol: "plus", tip: "New Cell Below") { [weak self] _, _ in self?.addCell() },
            .init(symbol: "arrow.clockwise", tip: "Restart Shell") { [weak self] _, _ in self?.restart() },
            .init(symbol: "ellipsis", tip: "More") { [weak self] view, rect in self?.more(from: view, at: rect) },
        ]
        header.addSubview(runs)
        header.addSubview(tools)
        addSubview(header)
        scroll.documentView = stack
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        addSubview(scroll)
        addBelow.clicked = { [weak self] in self?.addAtEnd() }
        stack.addSubview(addBelow)
        scroll.watchScrolling { [weak self] _, y in self?.keeper.note(["scroll": "\(y)"]) }
    }

    required init?(coder: NSCoder) { fatalError() }

    func destroy() {
        ticker?.invalidate()
        cells.values.forEach { $0.flushSource() }
        keeper.flush()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard window != nil else { ticker?.invalidate(); return }
        delegate?.notebookStart(self)
        // A running cell's clock, kept going.
        ticker?.invalidate()
        ticker = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            guard let self, let running = self.shown?.running else { return }
            self.cells[running]?.tick()
        }
    }

    // MARK: The block

    func documentChanged() {
        guard let b = source(), let nb = b.notebook else { return }
        let first = shown == nil
        guard nb != shown || b.home != shownHome else { return }
        shown = nb
        shownHome = b.home
        // The host's order, with what was made here and isn't written yet in its place.
        var ids = nb.cells.map(\.id)
        for (id, _) in pendingInserts where ids.contains(id) { pendingInserts.removeValue(forKey: id) }
        for (id, at) in pendingInserts.sorted(by: { $0.value < $1.value }) { ids.insert(id, at: min(at, ids.count)) }
        for (id, view) in cells where !ids.contains(id) {
            view.removeFromSuperview()
            cells.removeValue(forKey: id)
        }
        for cell in nb.cells {
            let v = cells[cell.id] ?? makeCell(cell.id)
            v.update(cell, running: nb.running == cell.id, queued: nb.queued.contains(cell.id))
        }
        order = ids
        updateHeader()
        layoutCells()
        if first { restore() }
    }

    private func makeCell(_ id: String) -> NotebookCellView {
        let v = NotebookCellView(id: id, font: codeFont)
        v.editor.onLinked = { [weak self] block in
            guard let self else { return }
            self.delegate?.notebook(self, linkedFrom: block)
        }
        v.owner = self
        stack.addSubview(v)
        cells[id] = v
        return v
    }

    private func restore() {
        guard !keeper.restored else { return }
        keeper.restored = true
        if let f = keeper.value("focused"), cells[f] != nil { focusedCell = f }
        cells.values.forEach { $0.focused = $0.id == focusedCell }
        if let y = keeper.double("scroll") { DispatchQueue.main.async { [weak self] in self?.scroll.scrollTo(x: 0, y: y) } }
    }

    /// What a running cell has printed so far, as the host sends it.
    func live(cell: String, output: String) {
        cells[cell]?.showLive(output)
        layoutCells()
        if focusedCell == cell { cells[cell]?.scrollOutputToEnd() }
    }

    /// The shell, where it is and what it's doing, as the folder view's
    /// bar says where it is: the name strong, the rest quiet.
    private func updateHeader() {
        let nb = shown
        let place = source()?.home?.abbreviatingHome ?? "~"
        let name: String
        var doing: String?
        if nb?.pid == nil {
            glyph.look = .inactive
            name = "No shell"
            doing = "a run starts one"
            glyph.toolTip = "The shell has ended: the next run starts a new one"
        } else if let r = nb?.running, let c = nb?.cell(r) {
            glyph.look = .working(progress: nil)
            name = nb?.shell ?? "shell"
            doing = "running \(c.count ?? 0)" + (nb!.queued.isEmpty ? "" : ", \(nb!.queued.count) waiting")
            glyph.toolTip = "Running"
        } else {
            glyph.look = nil
            name = nb?.shell ?? "shell"
        }
        shellIcon.isHidden = glyph.look != nil
        let s = NSMutableAttributedString(string: name, attributes: [.font: NSFont.systemFont(ofSize: 12.5, weight: .semibold), .foregroundColor: Theme.text])
        s.append(NSAttributedString(string: "  " + place, attributes: [.font: NSFont.systemFont(ofSize: 12.5), .foregroundColor: Theme.secondaryText]))
        if let doing {
            s.append(NSAttributedString(string: "  ·  " + doing, attributes: [.font: NSFont.systemFont(ofSize: 12.5), .foregroundColor: Theme.secondaryText]))
        }
        status.attributedStringValue = s
        let stoppable = nb?.running != nil || !(nb?.queued.isEmpty ?? true)
        runs.set(2, enabled: stoppable, tint: stoppable ? Theme.statusError : nil)
    }

    // MARK: Layout

    override func layout() {
        super.layout()
        let w = bounds.width, h = bounds.height
        header.frame = NSRect(x: 0, y: h - Self.headerHeight, width: w, height: Self.headerHeight)
        let mid = Self.headerHeight / 2
        glyph.frame = NSRect(x: 14, y: mid - 8, width: 16, height: 16)
        shellIcon.frame = glyph.frame
        let t = tools.intrinsicContentSize, rn = runs.intrinsicContentSize
        tools.frame = NSRect(x: w - 10 - t.width, y: mid - t.height / 2, width: t.width, height: t.height)
        runs.frame = NSRect(x: tools.frame.minX - 8 - rn.width, y: mid - rn.height / 2, width: rn.width, height: rn.height)
        status.frame = NSRect(x: 36, y: mid - 8, width: max(0, runs.frame.minX - 46), height: 17)
        scroll.frame = NSRect(x: 0, y: 0, width: w, height: max(0, h - Self.headerHeight))
        layoutCells()
    }

    /// The cells down the column, each as tall as it needs.
    func layoutCells() {
        let w = scroll.contentSize.width
        // Not laid out yet: done when it is (not skipped for good).
        guard w > 0 else { needsLayout = true; return }
        var y: CGFloat = 6
        for id in order {
            guard let v = cells[id] else { continue }
            let h = v.height(forWidth: w)
            v.frame = NSRect(x: 0, y: y, width: w, height: h)
            y += h + 16
        }
        let a = addBelow.intrinsicContentSize
        addBelow.frame = NSRect(x: NotebookCellView.gutter + 4, y: y - 2, width: a.width, height: a.height)
        y += 44
        stack.frame = NSRect(x: 0, y: 0, width: w, height: max(y, scroll.contentSize.height))
    }

    // MARK: Cells, from their views

    func cellFocused(_ id: String) {
        guard focusedCell != id else { return }
        focusedCell = id
        cells.values.forEach { $0.focused = $0.id == id }
        keeper.note(["focused": id])
    }

    func cellEdited(_ id: String, source: String) {
        delegate?.notebook(self, edit: .source(id, source))
    }

    func cellResized() { layoutCells() }

    /// A cell laid out taller or shorter than it was given (its output or
    /// its footer come since it was measured): the cells stacked again,
    /// once, after this pass — else its output ran on over those below.
    private var restackPending = false
    func cellOutgrew() {
        guard !restackPending else { return }
        restackPending = true
        DispatchQueue.main.async { [weak self] in
            self?.restackPending = false
            self?.layoutCells()
        }
    }

    enum After { case stay, next, insert }

    /// A cell run: its text sent first, then the run asked for.
    func run(_ id: String, then after: After) {
        cells[id]?.flushSource()
        delegate?.notebook(self, run: [id])
        guard let i = order.firstIndex(of: id) else { return }
        switch after {
        case .stay: break
        case .next:
            if i + 1 < order.count { focus(order[i + 1], atEnd: false) } else { insert(at: i + 1) }
        case .insert: insert(at: i + 1)
        }
    }

    /// A new, empty cell at an index, focused.
    @discardableResult
    func insert(at index: Int, source text: String = "") -> String {
        let id = NotebookCell.newID()
        var cell = NotebookCell(id: id)
        cell.source = text
        pendingInserts[id] = index
        delegate?.notebook(self, edit: .insert(cell, at: index))
        let v = makeCell(id)
        v.update(cell, running: false, queued: false)
        order.insert(id, at: min(index, order.count))
        layoutCells()
        focus(id, atEnd: false)
        return id
    }

    func focus(_ id: String, atEnd: Bool) {
        guard let v = cells[id] else { return }
        window?.makeFirstResponder(v.editor)
        v.editor.setSelectedRange(NSRange(location: atEnd ? (v.editor.string as NSString).length : 0, length: 0))
        cellFocused(id)
        stack.scrollToVisible(v.frame.insetBy(dx: 0, dy: -10))
    }

    /// ↑ from a cell's first line, ↓ from its last.
    func leave(_ id: String, up: Bool) {
        guard let i = order.firstIndex(of: id) else { return }
        let j = up ? i - 1 : i + 1
        guard j >= 0, j < order.count else { return }
        focus(order[j], atEnd: up)
    }

    func move(_ id: String, by delta: Int) {
        guard let i = order.firstIndex(of: id), case let j = i + delta, j >= 0, j < order.count else { return }
        order.swapAt(i, j)
        layoutCells()
        delegate?.notebook(self, edit: .move(id, to: j))
        focus(id, atEnd: false)
    }

    func delete(_ id: String) {
        guard let i = order.firstIndex(of: id) else { return }
        let next = i + 1 < order.count ? order[i + 1] : (i > 0 ? order[i - 1] : nil)
        delegate?.notebook(self, edit: .remove(id))
        pendingInserts.removeValue(forKey: id)
        cells.removeValue(forKey: id)?.removeFromSuperview()
        order.remove(at: i)
        if order.isEmpty { insert(at: 0) } else if let next { focus(next, atEnd: false) }
        layoutCells()
    }

    func clearOutput(_ id: String) { delegate?.notebook(self, edit: .clear(id)) }

    func openOutput(_ id: String) {
        guard let cell = source()?.notebook?.cell(id), cell.output != nil else { return NSSound.beep() }
        delegate?.notebook(self, openOutput: cell)
    }

    func open(_ target: String) { delegate?.notebook(self, open: target) }

    // MARK: The header's buttons and keys

    func runFocused() {
        guard let id = focusedCell ?? order.first else { return }
        run(id, then: .stay)
    }

    func runAll() {
        cells.values.forEach { $0.flushSource() }
        delegate?.notebook(self, run: order.filter { !(cells[$0]?.editor.string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true) })
    }

    func interrupt() { delegate?.notebookInterrupt(self) }

    func restart() { delegate?.notebookRestart(self) }

    // MARK: Drops

    /// A block ⇧-dragged (or a file, a folder's entries) onto the notebook
    /// outside its cells: a new cell at the end with its path, the caret
    /// before it for the command (a cell under the drop takes it itself).
    private func registerDrops() {
        registerForDraggedTypes([.manifoldBlockLink, .fileURL, .manifoldPath])
    }

    private func dropTakes(_ pb: NSPasteboard) -> Bool {
        pb.string(forType: .manifoldPlacement) == nil && (BlockDrop(pb) != nil || TerminalView.dropText(pb) != nil)
    }

    /// What a ⇧-dragged block can be put in a new cell as.
    private static let blockForms: [BlockDrop.Form] = [.path, .reference, .contents]

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard dropTakes(sender.draggingPasteboard) else { return [] }
        if let block = BlockDrop(sender.draggingPasteboard) {
            let plain = block.path != nil ? "A new cell with its path" : "A new cell with its reference"
            DropHint.say(BlockDrop.hint(plain, choices: block.forms(Self.blockForms).count), at: sender.draggingLocation, in: window)
        } else {
            DropHint.say("A new cell with its path", at: sender.draggingLocation, in: window)
        }
        return .copy
    }
    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation { draggingEntered(sender) }
    override func draggingExited(_ sender: NSDraggingInfo?) { DropHint.hush() }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        DropHint.hush()
        return take(sender.draggingPasteboard)
    }

    /// What's dropped outside the cells: a new cell with it.
    func take(_ pb: NSPasteboard) -> Bool {
        // A ⇧-dragged block: its path (or reference), or (⌃) as chosen.
        if let block = BlockDrop(pb) {
            let forms = block.forms(Self.blockForms)
            let put = { [weak self] (form: BlockDrop.Form) in
                block.text(form) { text in
                    guard let self, let text, !text.isEmpty else { return NSSound.beep() }
                    self.newCell(form == .contents ? text : TerminalView.shellQuoted(text), from: block.block)
                }
            }
            if BlockDrop.choosing, forms.count > 1, let window {
                block.choose(forms, at: convert(window.mouseLocationOutsideOfEventStream, from: nil), in: self, put)
            } else {
                put(block.path != nil ? .path : .reference)
            }
            return true
        }
        guard dropTakes(pb), let text = TerminalView.dropText(pb) else { return false }
        newCell(text, from: pb.string(forType: .manifoldBlockLink).flatMap(TextView.blockID(inLink:)))
        return true
    }

    /// A new cell with `text` (the last one, if it's empty), linked from
    /// the block it came from.
    private func newCell(_ text: String, from block: BlockID?) {
        if let last = order.last, let v = cells[last], v.editor.isEditable,
           v.editor.string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            // The last cell's empty (a new notebook's): it, not another.
            window?.makeFirstResponder(v.editor)
            v.editor.insertText(" " + text, replacementRange: NSRange(location: 0, length: (v.editor.string as NSString).length))
            focus(last, atEnd: false)
        } else {
            insert(at: order.count, source: " " + text)
        }
        if let block { delegate?.notebook(self, linkedFrom: block) }
    }

    func addCell() {
        let i = focusedCell.flatMap { order.firstIndex(of: $0) }.map { $0 + 1 } ?? order.count
        insert(at: i)
    }

    private func addAtEnd() { insert(at: order.count) }

    private func more(from view: NSView, at rect: NSRect) {
        let menu = NSMenu()
        for item in cellItems { menu.addItem(item) }
        menu.addItem(ClosureMenuItem("Run All Cells", symbol: "forward.end.fill") { [weak self] in self?.runAll() })
        menu.addItem(ClosureMenuItem("Clear All Outputs", symbol: "eraser") { [weak self] in
            guard let self else { return }
            self.delegate?.notebook(self, edit: .clearAll)
        })
        menu.addItem(.separator())
        menu.addItem(ClosureMenuItem("Interrupt", symbol: "stop.fill", key: ".") { [weak self] in self?.interrupt() })
        menu.addItem(ClosureMenuItem("Restart Shell", symbol: "arrow.clockwise") { [weak self] in self?.restart() })
        menu.popUp(positioning: nil, at: NSPoint(x: rect.minX, y: rect.minY - 4), in: view)
    }

    /// The focused cell's own, with the keys a cell takes: run it (⌘↩,
    /// ⇧↩ to the next), move it (⌥⌘↑ ⌥⌘↓).
    private var cellItems: [NSMenuItem] {
        guard let id = focusedCell else { return [] }
        let run = ClosureMenuItem("Run Cell", symbol: "play.fill", key: "\r") { [weak self] in self?.run(id, then: .stay) }
        let up = ClosureMenuItem("Move Cell Up", symbol: "arrow.up", key: String(UnicodeScalar(NSUpArrowFunctionKey)!)) { [weak self] in self?.move(id, by: -1) }
        let down = ClosureMenuItem("Move Cell Down", symbol: "arrow.down", key: String(UnicodeScalar(NSDownArrowFunctionKey)!)) { [weak self] in self?.move(id, by: 1) }
        up.keyEquivalentModifierMask = [.command, .option]
        down.keyEquivalentModifierMask = [.command, .option]
        return [run, up, down, .separator()]
    }

    var pillItems: [NSMenuItem] {
        cellItems + [ClosureMenuItem("Run All Cells", symbol: "forward.end.fill") { [weak self] in self?.runAll() },
         ClosureMenuItem("Interrupt", symbol: "stop.fill", key: ".") { [weak self] in self?.interrupt() },
         ClosureMenuItem("Restart Shell", symbol: "arrow.clockwise") { [weak self] in self?.restart() },
         ClosureMenuItem("Clear All Outputs", symbol: "eraser") { [weak self] in
             guard let self else { return }
             self.delegate?.notebook(self, edit: .clearAll)
         }]
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard let r = window?.firstResponder as? NSView, r.isDescendant(of: self) else { return super.performKeyEquivalent(with: event) }
        let mods = event.modifierFlags.intersection([.command, .shift, .option, .control])
        if mods == .command, event.charactersIgnoringModifiers == "." {
            interrupt()
            return true
        }
        // The cell's keys with ⌘ go before the menus' (⌘↩ is Edit or View there).
        if let editor = r as? CellEditor, let cell = editor.cellView {
            let isReturn = event.keyCode == 36 || event.keyCode == 76
            if isReturn, mods == .command {
                run(cell.id, then: .stay)
                return true
            }
            if mods == [.command, .option], event.keyCode == 126 || event.keyCode == 125 {
                move(cell.id, by: event.keyCode == 126 ? -1 : 1)
                return true
            }
        }
        return super.performKeyEquivalent(with: event)
    }

    // MARK: Debugging

    /// "", "run <i>", "type <i> <text>", "add", "stop", "restart", "focus <i>",
    /// "click <i> <text>" (⌘-click on that text in cell i's output).
    func debug(_ arg: String) -> String {
        let w = arg.split(separator: " ", maxSplits: 2).map(String.init)
        func cell(_ s: String) -> String? { Int(s).flatMap { $0 < order.count ? order[$0] : nil } }
        switch w.first {
        case "run": if w.count > 1, let c = cell(w[1]) { run(c, then: .stay) }
        case "runall": runAll()
        case "type":
            if w.count > 2, let c = cell(w[1]), let v = cells[c] {
                v.editor.string = w[2].replacingOccurrences(of: "\\n", with: "\n")
                v.editor.didChangeText()
            }
        case "add": addCell()
        case "stop": interrupt()
        case "restart": restart()
        case "focus": if w.count > 1, let c = cell(w[1]) { focus(c, atEnd: true) }
        case "click":
            if w.count > 2, let c = cell(w[1]) { return cells[c]?.output.debugClick(w[2]) ?? "no cell" }
        case "delete": if w.count > 1, let c = cell(w[1]) { delete(c) }
        case "openoutput": if w.count > 1, let c = cell(w[1]) { openOutput(c) }
        case "key":
            // "key cmd|shift|opt return", "key cmd .": through the app as typed, menus first.
            guard w.count > 2, let window else { break }
            var mods: NSEvent.ModifierFlags = []
            if w[1].contains("cmd") { mods.insert(.command) }
            if w[1].contains("shift") { mods.insert(.shift) }
            if w[1].contains("opt") { mods.insert(.option) }
            let (chars, code): (String, UInt16) = w[2] == "return" ? ("\r", 36) : (w[2], 47)
            if let e = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: mods, timestamp: ProcessInfo.processInfo.systemUptime,
                                        windowNumber: window.windowNumber, context: nil, characters: chars,
                                        charactersIgnoringModifiers: chars, isARepeat: false, keyCode: code) {
                // As AppKit offers a key: the views' equivalents, the menus, then the responder.
                if window.performKeyEquivalent(with: e) { return "taken by a view's key equivalent" }
                if NSApp.mainMenu?.performKeyEquivalent(with: e) == true { return "taken by the menus" }
                window.firstResponder?.keyDown(with: e)
                return "to \(window.firstResponder.map { String(describing: type(of: $0)) } ?? "nothing")'s keyDown"
            }
        default: break
        }
        var lines = [status.stringValue]
        for (i, id) in order.enumerated() {
            guard let v = cells[id] else { continue }
            lines.append("[\(i)] \(v.debugSummary)")
        }
        return lines.joined(separator: "\n")
    }
}

/// One cell: its run count (a spinner while it runs), its command in an
/// editor that grows with it, what it printed (its own scroll past a
/// screenful), and how it ended.
final class NotebookCellView: NSView, NSTextViewDelegate {
    let id: String
    weak var owner: NotebookView?
    let editor = CellEditor()
    private let box = NSView()
    let output = OutputTextView()
    private let outputScroll = ClippingScrollView()
    private let count = NSTextField(labelWithString: "")
    private let queuedIcon = NSImageView()
    private let play = HoverIcon(symbol: "play.fill", tip: "Run (⌘↩)")
    private let menuButton = HoverIcon(symbol: "ellipsis", tip: "Cell")
    /// The focused cell's mark, as a selected row's in the sidebar.
    private let bar = NSView()
    private let glyph = StatusGlyph()
    private let footer = NSTextField(labelWithString: "")
    private var cell = NotebookCell(id: "")
    private var running = false
    private var queued = false
    private var hovered = false { didSet { refreshChrome() } }
    private var pendingSource: String?
    private var sendWork: DispatchWorkItem?
    private var renderedOutput: String?
    private var liveOutput: String?
    var font: NSFont { didSet { editor.font = font; renderedOutput = nil; render() } }
    var focused = false { didSet { refreshChrome() } }

    static let gutter: CGFloat = 48
    /// Where text starts in the command's box and in the output alike.
    static let textInset: CGFloat = 8
    static let maxOutputHeight: CGFloat = 420

    init(id: String, font: NSFont) {
        self.id = id
        self.font = font
        super.init(frame: .zero)
        box.wantsLayer = true
        box.layer?.cornerRadius = 8
        box.layer?.cornerCurve = .continuous
        addSubview(box)
        bar.wantsLayer = true
        bar.layer?.cornerRadius = Radius.hair
        addSubview(bar)
        editor.font = font
        editor.textColor = Theme.codeText
        editor.insertionPointColor = Theme.codeText
        editor.isRichText = false
        editor.allowsUndo = true
        editor.isAutomaticQuoteSubstitutionEnabled = false
        editor.isAutomaticDashSubstitutionEnabled = false
        editor.isAutomaticTextReplacementEnabled = false
        editor.isAutomaticSpellingCorrectionEnabled = false
        editor.isContinuousSpellCheckingEnabled = false
        editor.drawsBackground = false
        editor.textContainerInset = NSSize(width: Self.textInset, height: 8)
        editor.textContainer?.widthTracksTextView = true
        editor.delegate = self
        editor.cellView = self
        box.addSubview(editor)
        // The run's number, as the editor numbers its lines.
        count.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        count.textColor = Theme.codeLineNumber
        count.alignment = .right
        addSubview(count)
        queuedIcon.image = Theme.symbol("clock", size: 11)
        queuedIcon.contentTintColor = Theme.secondaryText
        queuedIcon.toolTip = "Waiting to run"
        addSubview(queuedIcon)
        play.clicked = { [weak self] _ in self?.playClicked() }
        menuButton.clicked = { [weak self] view in self?.menuClicked(from: view) }
        addSubview(play)
        addSubview(menuButton)
        addSubview(glyph)
        output.isEditable = false
        output.isSelectable = true
        output.drawsBackground = false
        output.textContainerInset = NSSize(width: Self.textInset, height: 2)
        output.textContainer?.widthTracksTextView = true
        output.isVerticallyResizable = true
        output.isHorizontallyResizable = false
        output.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        output.opened = { [weak self] target in self?.owner?.open(target) }
        outputScroll.documentView = output
        outputScroll.drawsBackground = false
        outputScroll.hasVerticalScroller = true
        outputScroll.autohidesScrollers = true
        output.autoresizingMask = [.width]
        addSubview(outputScroll)
        footer.font = UIType.footnote
        footer.textColor = Theme.secondaryText
        addSubview(footer)
        refreshChrome()
    }

    required init?(coder: NSCoder) { fatalError() }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self))
    }

    override func mouseEntered(with event: NSEvent) { hovered = true }
    override func mouseExited(with event: NSEvent) { hovered = false }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        renderedOutput = nil
        render()
        refreshChrome()
    }

    /// The focused cell: the accent's bar at its left and a light ring,
    /// as a focused tile is ringed; under the pointer, a hairline.
    private func refreshChrome() {
        // Layers' colours, as the view's appearance has them (light or dark).
        effectiveAppearance.performAsCurrentDrawingAppearance {
            box.layer?.backgroundColor = Theme.codePage.cgColor
            box.layer?.borderColor = (focused ? EdgeColor.accentSoft : Theme.divider).cgColor
            bar.layer?.backgroundColor = Flat.mark.cgColor
        }
        box.layer?.borderWidth = focused || hovered ? 1 : 0
        bar.isHidden = !focused
        let showPlay = (hovered || focused) && !running && !queued
        play.isHidden = !showPlay
        count.isHidden = showPlay || queued
        queuedIcon.isHidden = !queued
        menuButton.isHidden = !(hovered || focused)
    }

    // MARK: State

    func update(_ c: NotebookCell, running r: Bool, queued q: Bool) {
        let outputChanged = c.output != cell.output || c.ended != cell.ended
        cell = c
        running = r
        queued = q
        // The editor keeps what's typed in it: the host's text only when
        // nothing typed here is on its way, and it isn't being typed in.
        if pendingSource == nil, editor.string != c.source, editor.window?.firstResponder !== editor {
            editor.string = c.source
        }
        if !r { liveOutput = nil }
        if outputChanged || !r { render() }
        count.stringValue = c.count.map(String.init) ?? ""
        count.toolTip = c.count.map { "Run \($0) in this notebook" }
        tick()
        refreshChrome()
        needsLayout = true
    }

    func showLive(_ text: String) {
        liveOutput = text
        render()
    }

    /// The footer: the status's glyph, as the sidebar draws it (turning,
    /// a check, a red one), then how it ended, how long it took, when.
    func tick() {
        var words: [String] = []
        footer.textColor = Theme.secondaryText
        if running {
            glyph.look = .working(progress: nil)
            words.append("Running")
            if let ran = cell.ran { words.append(Self.duration(Date().timeIntervalSince(ran.date))) }
        } else if queued {
            glyph.look = nil
            words.append("Waiting to run")
        } else if let ended = cell.ended {
            let ok = cell.status == 0
            glyph.look = ok ? .done(read: true) : .failed(read: true)
            if let s = cell.status { words.append(ok ? "Done" : s == 130 ? "Interrupted" : "Exit \(s)") } else { words.append("The shell ended") }
            if let ran = cell.ran { words.append(Self.duration(ended.date.timeIntervalSince(ran.date))) }
            words.append(Age.ago(ended))
            if cell.truncated == true { words.append("the last megabyte kept") }
            // Failed in red; stopped by hand, quietly.
            if !ok, cell.status != 130 { footer.textColor = Theme.statusError.withAlphaComponent(0.85) }
        } else {
            glyph.look = nil
        }
        footer.stringValue = words.joined(separator: " · ")
        glyph.isHidden = glyph.look == nil
    }

    static func duration(_ t: TimeInterval) -> String {
        if t < 1 { return String(format: "%.0f ms", t * 1000) }
        if t < 60 { return String(format: "%.1f s", t) }
        return "\(Int(t) / 60) min \(Int(t) % 60) s"
    }

    private func render() {
        let text = running ? (liveOutput ?? cell.output ?? "") : (cell.output ?? "")
        guard text != renderedOutput else { return }
        renderedOutput = text
        // A long output: its end, as a terminal would show it.
        let shown = text.utf8.count > 200_000 ? String(text.suffix(150_000)) : text
        var trimmed = shown
        while trimmed.hasSuffix("\n") || trimmed.hasSuffix("\r") { trimmed.removeLast() }
        let rendered = ANSIText.render(trimmed, font: font, palette: TerminalPalette.current(for: self))
        output.textStorage?.setAttributedString(rendered)
        output.scanLinks()
        needsLayout = true
        owner?.cellResized()
    }

    func scrollOutputToEnd() {
        output.scrollToEndOfDocument(nil)
    }

    private var hasOutput: Bool { !(output.textStorage?.length == 0) }

    // MARK: Layout

    private func editorHeight(_ width: CGFloat) -> CGFloat {
        guard let lm = editor.layoutManager, let tc = editor.textContainer else { return 30 }
        // Sized only when the width changed: each cell is measured at every
        // key typed in any, and a size set lays its text out again.
        let size = NSSize(width: max(10, width - 2 * editor.textContainerInset.width), height: .greatestFiniteMagnitude)
        if tc.containerSize != size { tc.containerSize = size }
        lm.ensureLayout(for: tc)
        let used = lm.usedRect(for: tc).height
        let line = font.ascender - font.descender + font.leading
        return max(line, ceil(used)) + 2 * editor.textContainerInset.height
    }

    private func outputHeight(_ width: CGFloat) -> CGFloat {
        guard hasOutput, let lm = output.layoutManager, let tc = output.textContainer else { return 0 }
        let size = NSSize(width: max(10, width - 2 * output.textContainerInset.width), height: .greatestFiniteMagnitude)
        if tc.containerSize != size { tc.containerSize = size }
        lm.ensureLayout(for: tc)
        return min(Self.maxOutputHeight, ceil(lm.usedRect(for: tc).height) + 2 * output.textContainerInset.height)
    }

    func height(forWidth w: CGFloat) -> CGFloat {
        let inner = w - Self.gutter - 18
        let oh = outputHeight(inner)
        let footerHeight: CGFloat = footer.stringValue.isEmpty ? 0 : 20
        return editorHeight(inner) + (oh > 0 ? 8 + oh : 0) + (footerHeight > 0 ? 4 + footerHeight : 0)
    }

    override var isFlipped: Bool { true }

    override func layout() {
        super.layout()
        let x = Self.gutter, inner = bounds.width - Self.gutter - 18
        let eh = editorHeight(inner)
        box.frame = NSRect(x: x, y: 0, width: inner, height: eh)
        editor.frame = box.bounds
        bar.frame = NSRect(x: 8, y: 4, width: Flat.markWidth, height: max(0, eh - 8))
        let firstLine = 8 + (font.ascender - font.descender + font.leading) / 2
        count.frame = NSRect(x: 12, y: firstLine - 8, width: x - 22, height: 15)
        queuedIcon.frame = NSRect(x: x - 26, y: firstLine - 8, width: 16, height: 16)
        play.frame = NSRect(x: x - 30, y: firstLine - 11, width: 22, height: 22)
        menuButton.frame = NSRect(x: box.frame.maxX - 28, y: 4, width: 22, height: 22)
        let oh = outputHeight(inner)
        outputScroll.isHidden = oh == 0
        outputScroll.frame = NSRect(x: x, y: eh + 8, width: inner, height: oh)
        output.frame.size.width = outputScroll.contentSize.width
        output.sizeToFit()
        let fy = eh + (oh > 0 ? 8 + oh : 0) + 4
        let textX = x + Self.textInset + 5
        glyph.frame = NSRect(x: textX - 1, y: fy + 2, width: 14, height: 14)
        footer.frame = NSRect(x: glyph.isHidden ? textX : textX + 19, y: fy + 1, width: inner - 30, height: 16)
        if abs(height(forWidth: bounds.width) - bounds.height) > 1 { owner?.cellOutgrew() }
    }

    // MARK: Editing

    func textDidChange(_ notification: Notification) {
        pendingSource = editor.string
        sendWork?.cancel()
        let w = DispatchWorkItem { [weak self] in self?.flushSource() }
        sendWork = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35, execute: w)
        owner?.cellResized()
    }

    /// What's typed sent to the host, now.
    func flushSource() {
        sendWork?.cancel()
        sendWork = nil
        guard let s = pendingSource else { return }
        pendingSource = nil
        owner?.cellEdited(id, source: s)
    }

    func editorFocused() { owner?.cellFocused(id) }

    private func playClicked() { owner?.run(id, then: .stay) }

    private func menuClicked(from view: NSView) {
        let menu = NSMenu()
        cellMenuItems().forEach(menu.addItem)
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: view.bounds.height + 4), in: view)
    }

    /// A right-click anywhere on the cell (but in its text): the cell's menu.
    override func menu(for event: NSEvent) -> NSMenu? {
        let menu = NSMenu()
        cellMenuItems().forEach(menu.addItem)
        return menu
    }

    /// What can be done to the cell, for its "…" and right-click menus.
    func cellMenuItems() -> [NSMenuItem] {
        guard let owner else { return [] }
        let menu = NSMenu()
        menu.addItem(ClosureMenuItem("Run Cell", symbol: "play.fill") { owner.run(self.id, then: .stay) })
        menu.addItem(.separator())
        menu.addItem(ClosureMenuItem("Insert Cell Above", symbol: "arrow.up.to.line") { [weak self] in
            guard let self, let i = owner.indexOf(self.id) else { return }
            owner.insert(at: i)
        })
        menu.addItem(ClosureMenuItem("Insert Cell Below", symbol: "arrow.down.to.line") { [weak self] in
            guard let self, let i = owner.indexOf(self.id) else { return }
            owner.insert(at: i + 1)
        })
        menu.addItem(ClosureMenuItem("Move Up", symbol: "chevron.up") { owner.move(self.id, by: -1) })
        menu.addItem(ClosureMenuItem("Move Down", symbol: "chevron.down") { owner.move(self.id, by: 1) })
        menu.addItem(.separator())
        menu.addItem(ClosureMenuItem("Copy Output", symbol: "doc.on.doc") { [weak self] in
            guard let self else { return }
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(self.output.string, forType: .string)
        })
        menu.addItem(ClosureMenuItem("Open as Block", symbol: "rectangle.portrait.on.rectangle.portrait") { owner.openOutput(self.id) })
        menu.addItem(ClosureMenuItem("Clear Output", symbol: "eraser") { owner.clearOutput(self.id) })
        menu.addItem(.separator())
        menu.addItem(ClosureMenuItem("Delete Cell", symbol: "trash") { owner.delete(self.id) })
        let items = menu.items
        menu.removeAllItems()
        return items
    }

    var debugSummary: String {
        let state = running ? "running" : queued ? "queued" : ""
        return "[\(count.stringValue)] \(state) $ \(editor.string.replacingOccurrences(of: "\n", with: "⏎")) | \(footer.stringValue)"
            + " | y \(Int(frame.minY)) h \(Int(frame.height)) needs \(Int(height(forWidth: frame.width)))\n    "
            + output.string.replacingOccurrences(of: "\n", with: "\n    ").prefix(600)
    }
}

extension NotebookView {
    func indexOf(_ id: String) -> Int? { order.firstIndex(of: id) }
}

/// A cell's command: ⌘↩, ⇧↩ and ⌥↩ run it; ↑ and ↓ past its edges go to
/// the cells beside it; ⌥⌘↑ and ⌥⌘↓ move it.
final class CellEditor: NSTextView {
    weak var cellView: NotebookCellView?

    /// Dropped on a cell, as on a terminal: files and folders by their
    /// paths, quoted for the shell; a ⇧-dragged block, its path (and the
    /// link to it noted).
    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        if isEditable, DropHint.isBlockLink(sender.draggingPasteboard) {
            DropHint.say("Put its path in this cell", at: sender.draggingLocation, in: window)
        }
        return super.draggingUpdated(sender)
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        DropHint.hush()
        super.draggingExited(sender)
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        DropHint.hush()
        let pb = sender.draggingPasteboard
        guard isEditable, let text = TerminalView.dropText(pb) else { return super.performDragOperation(sender) }
        let at = characterIndexForInsertion(at: convert(sender.draggingLocation, from: nil))
        window?.makeFirstResponder(self)
        setSelectedRange(NSRange(location: at, length: 0))
        insertText(text, replacementRange: NSRange(location: at, length: 0))
        if let link = pb.string(forType: .manifoldBlockLink), let block = TextView.blockID(inLink: link) { onLinked?(block) }
        return true
    }

    /// A block dropped in, its link noted (the notebook mentions it).
    var onLinked: ((BlockID) -> Void)?

    /// Empty: what to do, in the placeholder's grey.
    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard string.isEmpty, let font else { return }
        let hint = NSAttributedString(string: "Command — ⌘↩ runs it", attributes: [.font: font, .foregroundColor: NSColor.placeholderTextColor])
        hint.draw(at: NSPoint(x: textContainerOrigin.x + (textContainer?.lineFragmentPadding ?? 5), y: textContainerOrigin.y))
    }

    override func didChangeText() {
        super.didChangeText()
        if string.count <= 1 { needsDisplay = true }
    }

    /// The text's menu, the cell's after it.
    override func menu(for event: NSEvent) -> NSMenu? {
        let menu = super.menu(for: event) ?? NSMenu()
        if let items = cellView?.cellMenuItems(), !items.isEmpty {
            menu.addItem(.separator())
            items.forEach(menu.addItem)
        }
        return menu
    }

    override func becomeFirstResponder() -> Bool {
        let ok = super.becomeFirstResponder()
        if ok { cellView?.editorFocused() }
        return ok
    }

    override func keyDown(with event: NSEvent) {
        let mods = event.modifierFlags.intersection([.command, .shift, .option, .control])
        guard let cellView, let owner = cellView.owner else { return super.keyDown(with: event) }
        let isReturn = event.keyCode == 36 || event.keyCode == 76
        if isReturn, mods == .shift { return owner.run(cellView.id, then: .next) }
        if isReturn, mods == .option { return owner.run(cellView.id, then: .insert) }
        super.keyDown(with: event)
    }

    override func moveUp(_ sender: Any?) {
        if onFirstLine, let cellView { cellView.owner?.leave(cellView.id, up: true) } else { super.moveUp(sender) }
    }

    override func moveDown(_ sender: Any?) {
        if onLastLine, let cellView { cellView.owner?.leave(cellView.id, up: false) } else { super.moveDown(sender) }
    }

    private var onFirstLine: Bool {
        let s = string as NSString
        return selectedRange().length == 0 && s.lineRange(for: NSRange(location: 0, length: 0)).upperBound > selectedRange().location
            || s.length == 0
    }

    private var onLastLine: Bool {
        let s = string as NSString
        let loc = selectedRange().location
        return selectedRange().length == 0 && s.range(of: "\n", range: NSRange(location: loc, length: s.length - loc)).location == NSNotFound
    }
}

/// A cell's output: read-only, and with ⌘ held, paths and addresses in it
/// underlined under the pointer and opened when clicked — as in a
/// terminal; a file's `:line:column` kept for where to open it.
final class OutputTextView: NSTextView {
    var opened: (String) -> Void = { _ in }
    private var hoverRange: NSRange?

    /// Nothing to find ahead of time: what's under the pointer is read
    /// when ⌘ is held (kept as a hook, for when links are marked).
    func scanLinks() { clearHover() }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for t in trackingAreas where t.owner === self { removeTrackingArea(t) }
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self))
    }

    override func mouseMoved(with event: NSEvent) {
        super.mouseMoved(with: event)
        hover(event)
    }

    override func flagsChanged(with event: NSEvent) {
        super.flagsChanged(with: event)
        hover(event)
    }

    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        clearHover()
    }

    private func hover(_ event: NSEvent) {
        guard event.modifierFlags.contains(.command), let window else { return clearHover() }
        let p = convert(window.mouseLocationOutsideOfEventStream, from: nil)
        guard let r = target(at: p)?.range else { return clearHover() }
        guard r != hoverRange else { return NSCursor.pointingHand.set() }
        clearHover()
        hoverRange = r
        layoutManager?.addTemporaryAttributes([.underlineStyle: NSUnderlineStyle.single.rawValue, .foregroundColor: Tints.accentText], forCharacterRange: r)
        NSCursor.pointingHand.set()
    }

    private func clearHover() {
        guard let r = hoverRange else { return }
        hoverRange = nil
        layoutManager?.removeTemporaryAttribute(.underlineStyle, forCharacterRange: r)
        layoutManager?.removeTemporaryAttribute(.foregroundColor, forCharacterRange: r)
        NSCursor.iBeam.set()
    }

    override func mouseDown(with event: NSEvent) {
        if event.modifierFlags.contains(.command), let t = target(at: convert(event.locationInWindow, from: nil)) {
            clearHover()
            return opened(t.text)
        }
        super.mouseDown(with: event)
    }

    /// The path or address under a point: the run of characters around it
    /// that aren't spaces, quotes or brackets, with trailing punctuation
    /// left off; only something that looks like one (a scheme, a slash,
    /// a name with an extension, `~`).
    func target(at p: NSPoint) -> (text: String, range: NSRange)? {
        guard let lm = layoutManager, let tc = textContainer else { return nil }
        let q = NSPoint(x: p.x - textContainerOrigin.x, y: p.y - textContainerOrigin.y)
        var fraction: CGFloat = 0
        let g = lm.glyphIndex(for: q, in: tc, fractionOfDistanceThroughGlyph: &fraction)
        guard g < lm.numberOfGlyphs, lm.boundingRect(forGlyphRange: NSRange(location: g, length: 1), in: tc).insetBy(dx: -2, dy: -2).contains(q) else { return nil }
        return Self.token(in: string, at: lm.characterIndexForGlyph(at: g))
    }

    static func token(in string: String, at index: Int) -> (text: String, range: NSRange)? {
        let s = string as NSString
        guard index < s.length else { return nil }
        let stops = CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: "\"'`<>()[]{}|,;"))
        func stop(_ i: Int) -> Bool { s.substring(with: NSRange(location: i, length: 1)).unicodeScalars.allSatisfy { stops.contains($0) } }
        guard !stop(index) else { return nil }
        var a = index, b = index
        while a > 0, !stop(a - 1) { a -= 1 }
        while b + 1 < s.length, !stop(b + 1) { b += 1 }
        var range = NSRange(location: a, length: b - a + 1)
        var text = s.substring(with: range)
        while let last = text.last, ".:!?".contains(last) {
            text.removeLast()
            range.length -= 1
        }
        guard !text.isEmpty else { return nil }
        let looksLikeOne = text.contains("://") || text.contains("/") || text.hasPrefix("~")
            || text.range(of: #"^[\w.-]+\.[A-Za-z0-9]{1,8}(:\d+(:\d+)?)?$"#, options: .regularExpression) != nil
        return looksLikeOne ? (text, range) : nil
    }

    /// Debugging: a ⌘-click on the first place the text appears.
    func debugClick(_ text: String) -> String {
        let r = (string as NSString).range(of: text)
        guard r.location != NSNotFound, let t = Self.token(in: string, at: r.location) else { return "no link at \"\(text)\"" }
        opened(t.text)
        return "opened \(t.text)"
    }
}

/// Buttons gathered in a capsule, as a Mac toolbar groups them (and as
/// the folder view's modes sit): each a symbol, lit under the pointer,
/// pressed darker, dimmed when it can't be used.
final class ActionCapsule: NSView {
    struct Action {
        var symbol: String
        var tip: String
        var enabled = true
        var tint: NSColor?
        /// Told the capsule and the segment's rect, to hang a menu from.
        var perform: (NSView, NSRect) -> Void

        init(symbol: String, tip: String, perform: @escaping (NSView, NSRect) -> Void) {
            self.symbol = symbol
            self.tip = tip
            self.perform = perform
        }
    }

    var actions: [Action] = [] { didSet { needsDisplay = true; invalidateIntrinsicContentSize(); needsLayout = true } }
    private var hovered: Int? { didSet { if hovered != oldValue { needsDisplay = true } } }
    private var pressed: Int? { didSet { if pressed != oldValue { needsDisplay = true } } }
    private let segment = NSSize(width: 30, height: 24)
    private let inset: CGFloat = 3

    func set(_ i: Int, enabled: Bool, tint: NSColor? = nil) {
        guard i < actions.count, actions[i].enabled != enabled || actions[i].tint != tint else { return }
        actions[i].enabled = enabled
        actions[i].tint = tint
        window?.invalidateCursorRects(for: self)
    }

    override var intrinsicContentSize: NSSize {
        NSSize(width: segment.width * CGFloat(actions.count) + 2 * inset, height: segment.height + 2 * inset)
    }

    func rect(_ i: Int) -> NSRect {
        NSRect(x: inset + CGFloat(i) * segment.width, y: inset, width: segment.width, height: segment.height)
    }

    private func index(at p: NSPoint) -> Int? { actions.indices.first { rect($0).contains(p) } }

    override func draw(_ dirtyRect: NSRect) {
        Theme.text.withAlphaComponent(0.06).setFill()
        NSBezierPath(roundedRect: bounds, xRadius: bounds.height / 2, yRadius: bounds.height / 2).fill()
        for (i, a) in actions.enumerated() {
            let r = rect(i)
            if a.enabled, i == pressed || i == hovered {
                (i == pressed ? Theme.selection : Theme.hover).setFill()
                NSBezierPath(roundedRect: r, xRadius: r.height / 2, yRadius: r.height / 2).fill()
            }
            guard let image = Theme.symbol(a.symbol, size: 12, weight: .medium) else { continue }
            let ink = a.enabled ? (a.tint ?? Theme.text.withAlphaComponent(0.78)) : Theme.secondaryText.withAlphaComponent(0.35)
            image.tinted(ink).draw(in: NSRect(x: r.midX - image.size.width / 2, y: r.midY - image.size.height / 2,
                                              width: image.size.width, height: image.size.height))
        }
    }

    override func layout() {
        super.layout()
        removeAllToolTips()
        for (i, a) in actions.enumerated() { addToolTip(rect(i), owner: a.tip as NSString, userData: nil) }
    }

    override func resetCursorRects() {
        for (i, a) in actions.enumerated() where a.enabled { addCursorRect(rect(i), cursor: .pointingHand) }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow], owner: self))
    }

    override func mouseMoved(with event: NSEvent) { hovered = index(at: convert(event.locationInWindow, from: nil)) }
    override func mouseExited(with event: NSEvent) { hovered = nil }

    override func mouseDown(with event: NSEvent) {
        guard let i = index(at: convert(event.locationInWindow, from: nil)), actions[i].enabled else { return }
        pressed = i
        // Tracked to the mouse's release, as a button is: let go outside, nothing.
        while let next = window?.nextEvent(matching: [.leftMouseDragged, .leftMouseUp]) {
            let inside = rect(i).contains(convert(next.locationInWindow, from: nil))
            if next.type == .leftMouseUp {
                pressed = nil
                if inside { actions[i].perform(self, rect(i)) }
                return
            }
            pressed = inside ? i : nil
        }
    }

    /// Debugging: an action pressed.
    func debugPress(_ i: Int) {
        guard i < actions.count, actions[i].enabled else { return }
        actions[i].perform(self, rect(i))
    }
}

/// A quiet link of a control: a symbol and a word in the secondary colour,
/// the text's own under the pointer.
final class HoverLink: NSView {
    var clicked: () -> Void = {}
    private let title: String
    private let symbol: String
    private var hovered = false { didSet { if hovered != oldValue { needsDisplay = true } } }

    init(title: String, symbol: String) {
        self.title = title
        self.symbol = symbol
        super.init(frame: .zero)
    }

    required init?(coder: NSCoder) { fatalError() }

    private var label: NSAttributedString {
        NSAttributedString(string: title, attributes: [.font: UIType.label,
                                                       .foregroundColor: hovered ? Theme.text : Theme.secondaryText])
    }

    override var intrinsicContentSize: NSSize { NSSize(width: ceil(label.size().width) + 30, height: 24) }

    override func draw(_ dirtyRect: NSRect) {
        if hovered {
            Theme.hover.setFill()
            NSBezierPath(roundedRect: bounds, xRadius: bounds.height / 2, yRadius: bounds.height / 2).fill()
        }
        let ink = hovered ? Theme.text : Theme.secondaryText
        if let image = Theme.symbol(symbol, size: 10, weight: .semibold) {
            image.tinted(ink).draw(in: NSRect(x: 9, y: (bounds.height - image.size.height) / 2, width: image.size.width, height: image.size.height))
        }
        let l = label
        l.draw(at: NSPoint(x: 23, y: (bounds.height - l.size().height) / 2))
    }

    override func resetCursorRects() { addCursorRect(bounds, cursor: .pointingHand) }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeInKeyWindow], owner: self))
    }

    override func mouseEntered(with event: NSEvent) { hovered = true }
    override func mouseExited(with event: NSEvent) { hovered = false }
    override func mouseUp(with event: NSEvent) {
        if bounds.contains(convert(event.locationInWindow, from: nil)) { clicked() }
    }
    override func mouseDown(with event: NSEvent) {}
}

/// A symbol that's a button: a soft circle under the pointer, darker
/// pressed, the pointing hand over it.
final class HoverIcon: NSView {
    var clicked: (NSView) -> Void = { _ in }
    private let symbol: String
    private var hovered = false { didSet { if hovered != oldValue { needsDisplay = true } } }
    private var pressed = false { didSet { if pressed != oldValue { needsDisplay = true } } }

    init(symbol: String, tip: String) {
        self.symbol = symbol
        super.init(frame: .zero)
        toolTip = tip
    }

    required init?(coder: NSCoder) { fatalError() }

    override func draw(_ dirtyRect: NSRect) {
        if hovered || pressed {
            (pressed ? Theme.selection : Theme.hover).setFill()
            NSBezierPath(ovalIn: bounds).fill()
        }
        guard let image = Theme.symbol(symbol, size: 10, weight: .semibold) else { return }
        image.tinted(hovered ? Theme.text : Theme.secondaryText).draw(in: NSRect(x: bounds.midX - image.size.width / 2, y: bounds.midY - image.size.height / 2,
                                                                               width: image.size.width, height: image.size.height))
    }

    override func resetCursorRects() { addCursorRect(bounds, cursor: .pointingHand) }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeInKeyWindow], owner: self))
    }

    override func mouseEntered(with event: NSEvent) { hovered = true }
    override func mouseExited(with event: NSEvent) { hovered = false }
    override func mouseDown(with event: NSEvent) { pressed = true }
    override func mouseUp(with event: NSEvent) {
        pressed = false
        if bounds.contains(convert(event.locationInWindow, from: nil)) { clicked(self) }
    }
}

extension NotebookView: Printable {
    /// Each cell, its command and what it printed, in order.
    func printOperation() -> NSPrintOperation? {
        let text = printableCells.map { c in
            "$ " + c.source.replacingOccurrences(of: "\n", with: "\n  ") + (c.output.isEmpty ? "" : "\n" + c.output)
        }.joined(separator: "\n\n")
        return TextPrint.operation(text, title: source()?.displayTitle ?? "Shell Notebook", font: TextPrint.codeFont)
    }
}
