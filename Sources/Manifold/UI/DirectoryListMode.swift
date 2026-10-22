import AppKit
import ManifoldCore

/// A folder as a list (§7.4): name, date modified, size and kind, sorted
/// by any of them (folders kept on top), each folder opening in place into
/// what's in it — the tree under the root — and, under a filter, open on
/// the way to each match. Which folders are open is kept with the tile.
final class DirectoryListMode: NSView, DirectoryMode, DebugDescribing, NSOutlineViewDataSource, NSOutlineViewDelegate, NSMenuDelegate {
    private unowned let owner: DirectoryView
    private let model: DirectoryModel
    private let scroll = ClippingScrollView()
    private let outline = NSOutlineView()
    /// Open folders, relative to the root (without a filter).
    private var expanded: Set<String>
    /// Each folder's shown entries, as last asked for.
    private var cache: [String: [BrowserNode]] = [:]
    private var pendingSelect: String?
    private var restoring = false

    var focusView: NSView { outline }

    init(owner: DirectoryView, model: DirectoryModel) {
        self.owner = owner
        self.model = model
        expanded = Set((owner.keeper.value("expanded") ?? "").split(separator: "\n").map(String.init))
        super.init(frame: .zero)
        let columns: [(String, String, CGFloat, CGFloat)] = [("name", "Name", 260, 140), ("modified", "Date Modified", 160, 90),
                                                             ("size", "Size", 72, 50), ("kind", "Kind", 120, 60)]
        for (id, title, width, min) in columns {
            let c = NSTableColumn(identifier: .init(id))
            c.title = title
            c.width = width
            c.minWidth = min
            c.sortDescriptorPrototype = NSSortDescriptor(key: id, ascending: true)
            if id == "size" { c.headerCell.alignment = .right }
            outline.addTableColumn(c)
        }
        outline.outlineTableColumn = outline.tableColumns[0]
        outline.dataSource = self
        outline.delegate = self
        outline.style = .inset
        outline.rowHeight = 24
        outline.indentationPerLevel = 14
        outline.columnAutoresizingStyle = .noColumnAutoresizing
        // The name column's width is the fit's alone (not widened for deep rows).
        outline.autoresizesOutlineColumn = false
        outline.allowsMultipleSelection = false
        outline.usesAlternatingRowBackgroundColors = false
        outline.backgroundColor = .clear
        outline.target = self
        outline.doubleAction = #selector(doubleClicked)
        // An entry right-clicked: its menu, made then.
        outline.menu = NSMenu()
        outline.menu?.delegate = self
        outline.setDraggingSourceOperationMask([.copy, .link, .generic], forLocal: true)
        outline.setDraggingSourceOperationMask([.copy, .link, .generic], forLocal: false)
        outline.sortDescriptors = [NSSortDescriptor(key: model.sortKey.rawValue, ascending: model.ascending)]
        scroll.documentView = outline
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        addSubview(scroll)
        // A tile resizes in steps as it glides: the columns fitted at each.
        scroll.contentView.postsFrameChangedNotifications = true
        NotificationCenter.default.addObserver(self, selector: #selector(clipResized), name: NSView.frameDidChangeNotification, object: scroll.contentView)
        scroll.watchScrolling { [weak owner] _, y in owner?.keeper.note(["scroll": "\(y)"]) }
    }

    required init?(coder: NSCoder) { fatalError() }

    func destroy() { NotificationCenter.default.removeObserver(self) }

    override func layout() {
        super.layout()
        scroll.frame = bounds
        fitColumns()
    }

    @objc private func clipResized() { fitColumns() }

    /// The name takes what the others leave; narrow, Kind goes, then the date, then the size.
    private func fitColumns() {
        let w = scroll.contentSize.width
        guard w > 0, outline.tableColumns.count == 4 else { return }
        let c = outline.tableColumns
        c[3].isHidden = w < 640
        c[1].isHidden = w < 480
        c[2].isHidden = w < 300
        let others = c.dropFirst().filter { !$0.isHidden }
        // The inset style's margins, either side, and the gaps between.
        let spacing = outline.intercellSpacing.width * CGFloat(others.count + 1) + 44
        c[0].width = max(c[0].minWidth, w - others.reduce(0) { $0 + $1.width } - spacing)
    }

    var shownFolders: [String] { model.filtering ? [] : expanded.map { model.absolute($0) } }

    // MARK: Data

    private func kids(_ item: Any?) -> [BrowserNode] {
        let folder = (item as? BrowserNode)?.path ?? model.root
        if let c = cache[folder] { return c }
        guard let c = model.children(of: folder) else { return [] }
        cache[folder] = c
        return c
    }

    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int { kids(item).count }
    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any { kids(item)[index] }
    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool { (item as? BrowserNode)?.isDirectory == true }

    func outlineView(_ outlineView: NSOutlineView, rowViewForItem item: Any) -> NSTableRowView? { StrongSelectionRowView() }

    func folder(at point: NSPoint) -> String? {
        let row = outline.row(at: outline.convert(point, from: self))
        guard row >= 0, let node = outline.item(atRow: row) as? BrowserNode, node.isDirectory else { return nil }
        return node.path
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        guard outline.clickedRow >= 0, let node = outline.item(atRow: outline.clickedRow) as? BrowserNode, let m = owner.menu(for: node) else { return }
        for item in m.items { m.removeItem(item); menu.addItem(item) }
    }

    func outlineView(_ outlineView: NSOutlineView, pasteboardWriterForItem item: Any) -> NSPasteboardWriting? {
        (item as? BrowserNode).map(owner.pasteboardWriter)
    }

    func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        guard let n = item as? BrowserNode else { return nil }
        let id = tableColumn?.identifier.rawValue ?? "name"
        let cell = outlineView.makeView(withIdentifier: .init("cell-" + id), owner: nil) as? StrongSelectionCellView ?? Self.makeCell(id)
        let f = cell.textField!
        switch id {
        case "name":
            f.stringValue = n.name
            cell.textColor = Theme.text
            cell.imageView?.image = n.icon
        case "modified":
            f.stringValue = n.modifiedText
            cell.textColor = Theme.secondaryText
        case "size":
            f.stringValue = n.sizeText
            cell.textColor = Theme.secondaryText
        default:
            f.stringValue = n.kind
            cell.textColor = Theme.secondaryText
        }
        cell.muted = n.isMuted
        return cell
    }

    private static func makeCell(_ id: String) -> StrongSelectionCellView {
        let c = StrongSelectionCellView()
        c.identifier = .init("cell-" + id)
        let f = NSTextField(labelWithString: "")
        f.font = .systemFont(ofSize: id == "name" ? 13 : 12)
        f.lineBreakMode = id == "name" ? .byTruncatingMiddle : .byTruncatingTail
        f.alignment = id == "size" ? .right : .left
        f.translatesAutoresizingMaskIntoConstraints = false
        c.addSubview(f)
        c.textField = f
        if id == "name" {
            let i = NSImageView()
            i.imageScaling = .scaleProportionallyUpOrDown
            i.translatesAutoresizingMaskIntoConstraints = false
            c.addSubview(i)
            c.imageView = i
            NSLayoutConstraint.activate([
                i.leadingAnchor.constraint(equalTo: c.leadingAnchor, constant: 2),
                i.centerYAnchor.constraint(equalTo: c.centerYAnchor),
                i.widthAnchor.constraint(equalToConstant: 18),
                i.heightAnchor.constraint(equalToConstant: 18),
                f.leadingAnchor.constraint(equalTo: i.trailingAnchor, constant: 6),
            ])
        } else {
            f.leadingAnchor.constraint(equalTo: c.leadingAnchor, constant: 4).isActive = true
        }
        NSLayoutConstraint.activate([
            f.trailingAnchor.constraint(equalTo: c.trailingAnchor, constant: -4),
            f.centerYAnchor.constraint(equalTo: c.centerYAnchor),
        ])
        return c
    }

    // MARK: Sorting, opening, selecting

    func outlineView(_ outlineView: NSOutlineView, sortDescriptorsDidChange oldDescriptors: [NSSortDescriptor]) {
        guard let d = outlineView.sortDescriptors.first, let key = d.key.flatMap(DirectoryModel.SortKey.init) else { return }
        owner.sortChanged(key, ascending: d.ascending)
    }

    @objc private func doubleClicked() {
        guard outline.clickedRow >= 0, let n = outline.item(atRow: outline.clickedRow) as? BrowserNode else { return }
        owner.open(n)
    }

    func outlineViewSelectionDidChange(_ notification: Notification) {
        guard !restoring else { return }
        pendingSelect = nil
        owner.selectionChanged(selectedPath)
    }

    func outlineViewItemDidExpand(_ notification: Notification) {
        guard !restoring, !model.filtering, let n = notification.userInfo?["NSObject"] as? BrowserNode else { return }
        expanded.insert(model.relative(n.path))
        noteExpanded()
    }

    func outlineViewItemDidCollapse(_ notification: Notification) {
        guard !restoring, !model.filtering, let n = notification.userInfo?["NSObject"] as? BrowserNode else { return }
        let rel = model.relative(n.path)
        expanded = expanded.filter { $0 != rel && !$0.hasPrefix(rel + "/") }
        noteExpanded()
    }

    private func noteExpanded() { owner.keeper.note(["expanded": expanded.sorted().joined(separator: "\n")]) }

    var selectedPath: String? {
        outline.selectedRow >= 0 ? (outline.item(atRow: outline.selectedRow) as? BrowserNode)?.path : nil
    }

    func select(_ path: String?) {
        guard let path, path != model.root else {
            outline.deselectAll(nil)
            return
        }
        // The folders on the way opened, as far as they're listed.
        var chain: [String] = []
        var dir = path.deletingLastPathComponent
        while dir.count > model.root.count, dir.hasPrefix(model.root) {
            chain.insert(dir, at: 0)
            dir = dir.deletingLastPathComponent
        }
        restoring = true
        for d in chain {
            guard let n = model.existingNode(d), outline.row(forItem: n) >= 0 else { break }
            if !outline.isItemExpanded(n) {
                outline.expandItem(n)
                if !model.filtering { expanded.insert(model.relative(d)) }
            }
        }
        restoring = false
        if !model.filtering { noteExpanded() }
        if let n = model.existingNode(path), case let row = outline.row(forItem: n), row >= 0 {
            outline.selectRowIndexes([row], byExtendingSelection: false)
            outline.scrollRowToVisible(row)
            pendingSelect = nil
        } else {
            pendingSelect = path
        }
    }

    // MARK: Changes

    func folderChanged(_ folder: String) {
        cache.removeValue(forKey: folder)
        if folder == model.root { return reloadAll() }
        let keep = pendingSelect ?? selectedPath
        restoring = true
        if let n = model.existingNode(folder), outline.row(forItem: n) >= 0 {
            outline.reloadItem(n, reloadChildren: true)
        } else {
            restoring = false
            return
        }
        openAsKept()
        restoring = false
        select(keep)
    }

    func reloadAll() {
        let keep = pendingSelect ?? selectedPath
        cache.removeAll()
        restoring = true
        outline.reloadData()
        openAsKept()
        restoring = false
        select(keep)
        // The scroll as it was left, the first time.
        if !scrollRestored, outline.numberOfRows > 0 {
            scrollRestored = true
            if let y = owner.keeper.double("scroll") {
                DispatchQueue.main.async { [weak self] in
                    // No further than the rows go now (fewer may be open than when it was kept).
                    guard let self else { return }
                    let most = max(0, self.outline.frame.height - self.scroll.contentView.bounds.height)
                    self.scroll.scrollTo(x: 0, y: min(y, most))
                }
            }
        }
    }

    private var scrollRestored = false

    /// The folders opened as they were left; under a filter, those leading
    /// to a match (and those the filter opened, closed again after it).
    private func openAsKept() {
        var i = 0
        while i < outline.numberOfRows {
            if let n = outline.item(atRow: i) as? BrowserNode, n.isDirectory {
                let rel = model.relative(n.path)
                let open = model.filtering ? model.leadsToMatch(rel) : expanded.contains(rel)
                if open, !outline.isItemExpanded(n) { outline.expandItem(n) }
                if !open, outline.isItemExpanded(n), !model.filtering { outline.collapseItem(n) }
            }
            i += 1
        }
    }

    var debugRows: String {
        "widths " + outline.tableColumns.map { "\($0.identifier.rawValue)=\(Int($0.width))\($0.isHidden ? "(hidden)" : "")" }.joined(separator: " ")
            + " outline \(Int(outline.frame.width)) clip \(Int(scroll.contentSize.width)) spacing \(outline.intercellSpacing.width)\n" + (0..<min(outline.numberOfRows, 60)).compactMap { r -> String? in
            guard let n = outline.item(atRow: r) as? BrowserNode else { return nil }
            let level = outline.level(forRow: r)
            let mark = n.isDirectory ? (outline.isItemExpanded(n) ? "▾ " : "▸ ") : "  "
            return String(repeating: "  ", count: level) + mark + n.name + (outline.selectedRow == r ? "  ◀" : "")
        }.joined(separator: "\n")
    }
}
