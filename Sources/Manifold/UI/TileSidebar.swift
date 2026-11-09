import AppKit

/// A tile's own sidebar (§7.5), at its left, as Preview's is: its view's
/// outline as a list to steer by — a Markdown text's headings, a PDF's
/// table of contents — each clicked to go there, the one you're in
/// marked; and, for a PDF, its pages as thumbnails, the other page of the
/// sidebar. What it lists, what a click does, an entry's menu and what it
/// carries dragged out are all the outline's. A field at its top filters
/// it (⇧⌘P goes there): the entries with every word typed, flat.
final class TileSidebar: NSView, NSTableViewDataSource, NSTableViewDelegate, NSMenuDelegate, NSSearchFieldDelegate {
    typealias Entry = Outline.Item

    enum Page: String { case contents, pages }

    /// How wide, in every tile: as one was last dragged to (its right
    /// edge), within a share of its tile.
    static var width: CGFloat {
        get { UserDefaults.standard.object(forKey: "TileSidebarWidth").map { CGFloat(($0 as? Double) ?? 220) } ?? 220 }
        set {
            UserDefaults.standard.set(Double(min(max(newValue, 140), 560).rounded()), forKey: "TileSidebarWidth")
            NotificationCenter.default.post(name: widthChanged, object: nil)
        }
    }
    static let widthChanged = Notification.Name("TileSidebarWidthChanged")
    /// Its width in a tile this wide.
    static func width(in tile: CGFloat) -> CGFloat { min(width, (tile * 0.6).rounded()) }
    /// Its right edge: a hairline, and a handle to drag it wider or narrower.
    private let edge = CALayer()
    private let handle = ResizeHandleView()
    let outline: Outline
    var onPageChange: ((Page) -> Void)?

    func tableView(_ tableView: NSTableView, pasteboardWriterForRow row: Int) -> NSPasteboardWriting? {
        Drags.writer(rows.indices.contains(row) ? outline.dragItem(rows[row]) : nil)
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        guard rows.indices.contains(table.clickedRow), let m = outline.menuFor?(rows[table.clickedRow]) else { return }
        for item in m.items { m.removeItem(item); menu.addItem(item) }
    }

    /// The outline's entries, all; and those listed (filtered, the ones
    /// with every word typed), as indices into them.
    private(set) var entries: [Entry] = []
    private var rows: [Int] = []
    private let search = NSSearchField()
    /// Searching from ⇧⌘P: told when it's over (an entry gone to, or
    /// Escape), for the tile to take the keyboard back.
    private var onSearchEnd: (() -> Void)?
    private var filtering: Bool { !search.stringValue.trimmingCharacters(in: .whitespaces).isEmpty }
    private let scroll = ClippingScrollView()
    private let table = FlatTable(column: "entry", rowHeight: TileMetrics.nameRow)
    private let empty = NSTextField.label(color: Theme.secondaryText, align: .center)
    private let tabs: FlatSegments?
    private let pagesView: NSView?
    /// Being marked from the view's scrolling: not a pick.
    private var marking = false

    private(set) var page: Page = .contents

    /// `pages`: a view of the document's pages (a PDF's thumbnails), the
    /// sidebar's other page; `emptyText`, what the list says with nothing in it.
    init(outline: Outline, pages: NSView? = nil, emptyText: String = "No headings") {
        self.outline = outline
        self.emptyText = emptyText
        pagesView = pages
        tabs = pages == nil ? nil : FlatSegments(symbols: ["list.bullet.indent", "rectangle.grid.1x2"])
        super.init(frame: .zero)
        wantsLayer = true
        // Its ground: the panel's, fading into its tile's toward the edge
        // they share, so the two are of a piece, with no step between them.
        layer?.addSublayer(ground)
        ground.startPoint = CGPoint(x: 0, y: 0.5)
        ground.endPoint = CGPoint(x: 1, y: 0.5)
        ground.locations = [0, 0.45, 1]
        ground.actions = ["frame": NSNull(), "bounds": NSNull(), "position": NSNull(), "colors": NSNull()]
        // Set off from its tile by a hairline at its edge, over the ground.
        edge.actions = ["frame": NSNull(), "bounds": NSNull(), "position": NSNull(), "backgroundColor": NSNull()]
        layer?.addSublayer(edge)
        // (Again a turn later: its tile's colour may be set after its own.)
        themed { v in
            v.shadeGround()
            DispatchQueue.main.async { [weak v] in v?.shadeGround() }
            v.edge.backgroundColor = Theme.divider.cgColor
        }
        table.target = self
        table.action = #selector(rowClicked)
        // Several entries chosen (⌘-, ⇧-click), not gone to: dragged together.
        table.allowsMultipleSelection = true
        table.dataSource = self
        table.delegate = self
        scroll.hold(table)
        addSubview(scroll)
        empty.stringValue = emptyText
        addSubview(empty)
        if let tabs {
            tabs.onChange = { [weak self] _ in self?.tabChosen() }
            tabs.setToolTip("Table of Contents", forSegment: 0)
            tabs.setToolTip("Pages", forSegment: 1)
            tabs.selectedSegment = 0
            addSubview(tabs)
        }
        if let pagesView { addSubview(pagesView) }
        search.cell = CapsuleSearchCell(textCell: "")
        search.isEditable = true
        search.isSelectable = true
        search.placeholderString = "Filter"
        search.controlSize = .small
        search.font = UIType.field
        search.focusRingType = .none
        // A quiet grey capsule, as the other fields and chips are; no bezel.
        search.isBezeled = false
        search.isBordered = false
        search.drawsBackground = false
        search.wantsLayer = true
        search.layer?.cornerRadius = 11
        search.themed { $0.layer?.backgroundColor = Theme.text.withAlphaComponent(0.06).cgColor }
        search.delegate = self
        search.sendsSearchStringImmediately = true
        addSubview(search)
        if outline.draggable {
            table.setDraggingSourceOperationMask([.copy, .link, .generic], forLocal: true)
            table.setDraggingSourceOperationMask([.copy, .link, .generic], forLocal: false)
        }
        if outline.menuFor != nil {
            table.menu = NSMenu()
            table.menu?.delegate = self
        }
        handle.onDrag = { [weak self] x in
            guard let self else { return }
            Self.width = self.convert(NSPoint(x: x, y: 0), from: nil).x
        }
        addSubview(handle)
        NotificationCenter.default.addObserver(forName: Self.widthChanged, object: nil, queue: .main) { [weak self] _ in
            self?.superview?.needsLayout = true
        }
        show(page: .contents)
        outline.watch(self) { [weak self] in self?.outlineChanged() }
        outlineChanged()
    }

    private func outlineChanged() {
        set(outline.items)
        current = outline.current
    }

    required init?(coder: NSCoder) { fatalError() }

    private let ground = CAGradientLayer()

    /// The ground shaded again: the panel's into its tile's (the layer
    /// colour of the view it's in, as that's set now — an editor's page
    /// as it's viewed or edited, a terminal's paper).
    func shadeGround() {
        var panel = Theme.panel.cgColor, edge = panel
        effectiveAppearance.performAsCurrentDrawingAppearance {
            panel = Theme.panel.cgColor
            edge = superview.map(GridView.ground(of:)) ?? Theme.windowBackground.withAlphaComponent(1).cgColor
        }
        ground.colors = [panel, panel, edge]
    }

    override func viewDidMoveToSuperview() {
        super.viewDidMoveToSuperview()
        shadeGround()
    }

    override func layout() {
        super.layout()
        ground.frame = bounds
        shadeGround()
        edge.frame = NSRect(x: bounds.width - 1, y: 0, width: 1, height: bounds.height)
        handle.frame = NSRect(x: bounds.width - 6, y: 0, width: 6, height: bounds.height)
        var top = bounds.height
        if let tabs {
            tabs.sizeToFit()
            tabs.frame = NSRect(x: ((bounds.width - tabs.frame.width) / 2).rounded(), y: top - 8 - tabs.frame.height,
                                width: tabs.frame.width, height: tabs.frame.height)
            top = tabs.frame.minY - 6
        }
        search.isHidden = page != .contents
        if !search.isHidden {
            search.frame = NSRect(x: 8, y: top - 8 - 22, width: bounds.width - 17, height: 22)
            top = search.frame.minY - 6
        }
        let body = NSRect(x: 0, y: 0, width: bounds.width - 1, height: max(0, top))
        scroll.frame = body
        pagesView?.frame = body
        empty.frame = NSRect(x: 8, y: body.midY - 10, width: body.width - 16, height: 20)
    }

    func show(page: Page) {
        let p = pagesView == nil ? .contents : page
        self.page = p
        tabs?.selectedSegment = p == .contents ? 0 : 1
        scroll.isHidden = p != .contents
        pagesView?.isHidden = p != .pages
        empty.isHidden = p != .contents || !rows.isEmpty
        needsLayout = true
    }

    @objc private func tabChosen() {
        show(page: tabs?.selectedSegment == 1 ? .pages : .contents)
        onPageChange?(page)
    }

    /// The list afresh, if it changed.
    private func set(_ fresh: [Entry]) {
        guard fresh != entries else { return }
        entries = fresh
        refilter()
    }

    /// The rows for what's typed: all, nested, with nothing; else those
    /// with every word in their title or detail, flat.
    private func refilter() {
        let words = search.stringValue.lowercased().split(whereSeparator: \.isWhitespace).map(String.init)
        // The outline narrowed, wherever it shows (its ticks too).
        outline.filter = words
        rows = entries.indices.filter { i in words.allSatisfy { (entries[i].title + " " + entries[i].detail).lowercased().contains($0) } }
        table.reloadData()
        empty.stringValue = words.isEmpty ? emptyText : "Nothing matches"
        empty.isHidden = page != .contents || !rows.isEmpty
        if filtering, isSearching {
            // The first found chosen, for ↩.
            if !rows.isEmpty { select(0) }
        } else {
            markCurrent()
        }
    }

    private let emptyText: String

    /// The entry you're in, marked and kept in sight.
    private var current: Int? {
        didSet { if current != oldValue, !isSearching { markCurrent() } }
    }

    /// The entry you're in marked — filtered, the nearest listed at or
    /// before it (a file whose changes the filter hides) — unless the
    /// field has the keyboard, its first found chosen for ↩.
    private func markCurrent() {
        if let current, let row = rows.lastIndex(where: { $0 <= current }) ?? (rows.first == current ? 0 : nil) { select(row) } else {
            marking = true
            table.deselectAll(nil)
            marking = false
        }
    }

    private func select(_ row: Int) {
        marking = true
        defer { marking = false }
        table.selectRowIndexes([row], byExtendingSelection: false)
        table.scrollRowToVisible(row)
    }

    @objc private func rowClicked() {
        let row = table.clickedRow
        guard rows.indices.contains(row), table.selectedRowIndexes.count < 2,
              NSApp.currentEvent?.modifierFlags.intersection([.command, .shift]).isEmpty != false else { return }
        let i = rows[row]
        if onSearchEnd != nil { endSearch() }
        outline.pick(i)
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 36, rows.indices.contains(table.selectedRow) {
            outline.pick(rows[table.selectedRow])
        } else {
            super.keyDown(with: event)
        }
    }

    // MARK: Filtering

    /// Whether the field has the keyboard (⇧⌘P again leaves it).
    var isSearching: Bool { onSearchEnd != nil && search.currentEditor() != nil && window?.firstResponder === search.currentEditor() }

    /// ⇧⌘P: the keyboard in the field, what's in it kept and chosen;
    /// `ended` when an entry is gone to, Escape leaves, or ⇧⌘P again.
    func beginSearch(ended: @escaping () -> Void) {
        onSearchEnd = ended
        show(page: .contents)
        layoutSubtreeIfNeeded()
        window?.makeFirstResponder(search)
        search.currentEditor()?.selectAll(nil)
    }

    /// Where the field is, in the window: for the pointer to go to.
    var searchFrame: NSRect { search.convert(search.bounds, to: nil) }

    /// The search over, what's typed kept (the filter stands until it's
    /// cleared, with Escape or the field's ×).
    func endSearch() {
        let ended = onSearchEnd
        onSearchEnd = nil
        ended?()
        markCurrent()
    }

    func controlTextDidChange(_ obj: Notification) { refilter() }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        switch selector {
        case #selector(NSResponder.moveDown(_:)), #selector(NSResponder.moveUp(_:)):
            guard !rows.isEmpty else { return true }
            let step = selector == #selector(NSResponder.moveDown(_:)) ? 1 : -1
            select(min(max((table.selectedRow < 0 ? -1 : table.selectedRow) + step, 0), rows.count - 1))
        case #selector(NSResponder.insertNewline(_:)):
            guard rows.indices.contains(table.selectedRow) else { return true }
            // The search over first (the sidebar put away, if it was for
            // this), then gone to: going re-renders the tile.
            let i = rows[table.selectedRow]
            endSearch()
            outline.pick(i)
        case #selector(NSResponder.cancelOperation(_:)):
            // Escape: what's typed cleared, then, again, the field left.
            if filtering { search.stringValue = ""; refilter() } else { endSearch() }
        default:
            return false
        }
        return true
    }

    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }
    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? { SelectionRowView() }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let cell = tableView.makeView(withIdentifier: .init("entry"), owner: nil) as? OutlineRow ?? {
            let r = OutlineRow()
            r.identifier = .init("entry")
            return r
        }()
        let e = entries[rows[row]]
        cell.show(OutlineEntry(id: row, line: e.code ? nil : 0, title: e.title, detail: e.detail, level: filtering ? 0 : e.level, failed: e.failed, running: e.running, path: e.path))
        return cell
    }

    /// Debugging: the entries, the one marked starred.
    var debugEntries: String {
        "page \(page.rawValue)" + (filtering ? " filter \"\(search.stringValue)\"" : "") + "\n"
            + rows.enumerated().map { row, i in
                "\(i == current ? "*" : " ")\(row == table.selectedRow ? ">" : " ")\(String(repeating: "  ", count: filtering ? 0 : entries[i].level))\(entries[i].title)"
            }.joined(separator: "\n")
    }

    /// Debugging: rows chosen together, and what dragging them writes.
    func debugChoose(_ picks: [Int]) -> String {
        table.selectRowIndexes(IndexSet(picks.filter(rows.indices.contains)), byExtendingSelection: false)
        let writers = table.selectedRowIndexes.compactMap { tableView(table, pasteboardWriterForRow: $0).map(Drags.plain) as? NSPasteboardItem }
        return writers.map { $0.string(forType: .string) ?? "?" }.joined(separator: "\n")
    }

    func debugPick(_ i: Int) -> String {
        guard rows.indices.contains(i) else { return "no entry \(i) of \(rows.count)" }
        outline.pick(rows[i])
        return "picked \(entries[rows[i]].title)"
    }

    /// Debugging: typed into the field, or a key in it ("down", "return", "escape").
    func debugSearch(_ what: String) -> String {
        switch what {
        case "down", "up", "return", "escape":
            let sel = [ "down": #selector(NSResponder.moveDown(_:)), "up": #selector(NSResponder.moveUp(_:)),
                        "return": #selector(NSResponder.insertNewline(_:)), "escape": #selector(NSResponder.cancelOperation(_:)) ][what]!
            _ = control(search, textView: NSTextView(), doCommandBy: sel)
        default:
            search.stringValue = what
            refilter()
        }
        return debugEntries + "\nfirst responder in field: \(search.currentEditor() != nil && window?.firstResponder === search.currentEditor())"
    }
}

/// A search field's cell for a field without its bezel: what's typed kept
/// between the magnifying glass and the ⓧ (unbezeled, AppKit lays the
/// text over the glass), and in the middle of its height.
final class CapsuleSearchCell: NSSearchFieldCell {
    /// The words' room: after the glass, before the ×, a line high, in the
    /// middle — the same whether they're drawn or being typed (the field
    /// editor is put where `searchTextRect` says: left as the cell's own,
    /// it ran under the glass).
    private func wordsRect(_ r: NSRect) -> NSRect {
        let glass = searchButtonRect(forBounds: r), clear = cancelButtonRect(forBounds: r)
        let left = glass.maxX + 2, right = clear.isEmpty ? r.maxX - 6 : clear.minX - 2
        let line = ceil(NSLayoutManager().defaultLineHeight(for: font ?? UIType.field))
        let height = min(r.height, max(line, 16))
        return NSRect(x: left, y: (r.midY - height / 2).rounded(), width: max(0, right - left), height: height)
    }
    override func drawingRect(forBounds r: NSRect) -> NSRect { wordsRect(r) }
    override func searchTextRect(forBounds r: NSRect) -> NSRect { wordsRect(r) }
    override func select(withFrame r: NSRect, in view: NSView, editor: NSText, delegate: Any?, start: Int, length: Int) {
        super.select(withFrame: wordsRect(r), in: view, editor: editor, delegate: delegate, start: start, length: length)
    }
    override func edit(withFrame r: NSRect, in view: NSView, editor: NSText, delegate: Any?, event: NSEvent?) {
        super.edit(withFrame: wordsRect(r), in: view, editor: editor, delegate: delegate, event: event)
    }
}
