import AppKit

/// A tile's own sidebar (§7.5), at its left, as Preview's is: its view's
/// outline as a list to steer by — a Markdown text's headings, a PDF's
/// table of contents — each clicked to go there, the one you're in
/// marked; and, for a PDF, its pages as thumbnails, the other page of the
/// sidebar. What it lists, what a click does, an entry's menu and what it
/// carries dragged out are all the outline's.
final class TileSidebar: NSView, NSTableViewDataSource, NSTableViewDelegate, NSMenuDelegate {
    typealias Entry = Outline.Item

    enum Page: String { case contents, pages }

    static let width: CGFloat = 220
    let outline: Outline
    var onPageChange: ((Page) -> Void)?

    func tableView(_ tableView: NSTableView, pasteboardWriterForRow row: Int) -> NSPasteboardWriting? {
        entries.indices.contains(row) ? outline.dragItem(row, modifiers: Drags.modifiers) : nil
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        guard entries.indices.contains(table.clickedRow), let m = outline.menuFor?(table.clickedRow) else { return }
        for item in m.items { m.removeItem(item); menu.addItem(item) }
    }

    private(set) var entries: [Entry] = []
    private let scroll = ClippingScrollView()
    private let table = NSTableView()
    private let empty = NSTextField(labelWithString: "")
    private let tabs: NSSegmentedControl?
    private let pagesView: NSView?
    /// Being marked from the view's scrolling: not a pick.
    private var marking = false

    private(set) var page: Page = .contents

    /// `pages`: a view of the document's pages (a PDF's thumbnails), the
    /// sidebar's other page; `emptyText`, what the list says with nothing in it.
    init(outline: Outline, pages: NSView? = nil, emptyText: String = "No headings") {
        self.outline = outline
        pagesView = pages
        tabs = pages == nil ? nil : NSSegmentedControl(images: ["list.bullet.indent", "rectangle.grid.1x2"].compactMap { Theme.symbol($0, size: 12) },
                                                       trackingMode: .selectOne, target: nil, action: nil)
        super.init(frame: .zero)
        wantsLayer = true
        themed { $0.layer?.backgroundColor = Theme.panel.cgColor }
        let c = NSTableColumn(identifier: .init("entry"))
        table.addTableColumn(c)
        table.headerView = nil
        table.target = self
        table.action = #selector(rowClicked)
        table.dataSource = self
        table.delegate = self
        table.rowHeight = 24
        table.style = .plain
        table.intercellSpacing = NSSize(width: 0, height: 0)
        table.backgroundColor = .clear
        table.selectionHighlightStyle = .regular
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        addSubview(scroll)
        empty.stringValue = emptyText
        empty.font = .systemFont(ofSize: 12)
        empty.textColor = Theme.secondaryText
        empty.alignment = .center
        addSubview(empty)
        if let tabs {
            tabs.controlSize = .small
            tabs.segmentStyle = .automatic
            tabs.target = self
            tabs.action = #selector(tabChosen)
            tabs.setToolTip("Table of Contents", forSegment: 0)
            tabs.setToolTip("Pages", forSegment: 1)
            for i in 0..<2 { tabs.setWidth(34, forSegment: i) }
            tabs.selectedSegment = 0
            addSubview(tabs)
        }
        if let pagesView { addSubview(pagesView) }
        if outline.draggable {
            table.setDraggingSourceOperationMask([.copy, .link, .generic], forLocal: true)
            table.setDraggingSourceOperationMask([.copy, .link, .generic], forLocal: false)
        }
        if outline.menuFor != nil {
            table.menu = NSMenu()
            table.menu?.delegate = self
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

    override func layout() {
        super.layout()
        var top = bounds.height
        if let tabs {
            tabs.sizeToFit()
            tabs.frame = NSRect(x: ((bounds.width - tabs.frame.width) / 2).rounded(), y: top - 8 - tabs.frame.height,
                                width: tabs.frame.width, height: tabs.frame.height)
            top = tabs.frame.minY - 6
        }
        let body = NSRect(x: 0, y: 0, width: bounds.width - 1, height: max(0, top))
        scroll.frame = body
        pagesView?.frame = body
        empty.frame = NSRect(x: 8, y: body.midY - 10, width: body.width - 16, height: 20)
    }

    override func draw(_ dirtyRect: NSRect) {
        Theme.divider.setFill()
        NSRect(x: bounds.width - 1, y: 0, width: 1, height: bounds.height).fill()
    }

    func show(page: Page) {
        let p = pagesView == nil ? .contents : page
        self.page = p
        tabs?.selectedSegment = p == .contents ? 0 : 1
        scroll.isHidden = p != .contents
        pagesView?.isHidden = p != .pages
        empty.isHidden = p != .contents || !entries.isEmpty
    }

    @objc private func tabChosen() {
        show(page: tabs?.selectedSegment == 1 ? .pages : .contents)
        onPageChange?(page)
    }

    /// The list afresh, if it changed.
    private func set(_ fresh: [Entry]) {
        guard fresh != entries else { return }
        entries = fresh
        table.reloadData()
        empty.isHidden = page != .contents || !entries.isEmpty
    }

    /// The entry you're in, marked and kept in sight.
    private var current: Int? {
        didSet {
            guard current != oldValue else { return }
            marking = true
            defer { marking = false }
            if let current, entries.indices.contains(current) {
                table.selectRowIndexes([current], byExtendingSelection: false)
                table.scrollRowToVisible(current)
            } else {
                table.deselectAll(nil)
            }
        }
    }

    @objc private func rowClicked() {
        let row = table.clickedRow
        guard entries.indices.contains(row) else { return }
        outline.pick(row)
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 36, entries.indices.contains(table.selectedRow) {
            outline.pick(table.selectedRow)
        } else {
            super.keyDown(with: event)
        }
    }

    func numberOfRows(in tableView: NSTableView) -> Int { entries.count }
    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? { SelectionRowView() }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let cell = tableView.makeView(withIdentifier: .init("entry"), owner: nil) as? OutlineLensRow ?? {
            let r = OutlineLensRow()
            r.identifier = .init("entry")
            return r
        }()
        let e = entries[row]
        cell.show(OutlineLensView.Entry(id: row, line: e.code ? nil : 0, title: e.title, detail: e.detail, level: e.level, failed: e.failed, running: e.running))
        return cell
    }

    /// Debugging: the entries, the one marked starred.
    var debugEntries: String {
        "page \(page.rawValue)\n" + entries.enumerated().map { "\($0.offset == current ? "*" : " ")\(String(repeating: "  ", count: $0.element.level))\($0.element.title)" }.joined(separator: "\n")
    }

    func debugPick(_ i: Int) -> String {
        guard entries.indices.contains(i) else { return "no entry \(i) of \(entries.count)" }
        outline.pick(i)
        return "picked \(entries[i].title)"
    }
}
