import AppKit
import ManifoldCore

/// A folder in columns (§7.4), as the Finder's, drawn as the tree is: each
/// folder chosen opens in the next column, the file chosen is previewed
/// after the last, and the rows are the tree's — a type's symbol in its
/// colour, the name in the system font, the soft band chosen (grey in a
/// column without the keyboard), a chevron after a folder. Under the
/// filter, each column keeps only the files matching it and the folders on
/// the way to them, in its own order; the selection, if it's gone, moves
/// to the first match.
final class DirectoryColumnsMode: NSView, DirectoryMode, NSTableViewDataSource, NSTableViewDelegate, NSMenuDelegate {
    private unowned let owner: DirectoryView
    private let model: DirectoryModel
    private let scroll = ClippingScrollView()
    private let strip = FlippedView()
    private var columns: [Column] = []
    private let previewBox = NSView()
    private let preview = FilePreviewView()
    /// The deepest chosen: a folder (its entries the last column) or a
    /// file (previewed after its column); nil, nothing chosen in the root.
    private var chosen: String?
    private var pendingSelect: String?
    private var restoring = false

    static let columnWidth: CGFloat = 220
    static let previewMin: CGFloat = 280

    /// One folder's entries, a list of its own.
    final class Column: NSView {
        let scroll = ColumnScroll()
        let table = ColumnTable()
        var folder = ""
        /// Its entries, in the order shown.
        private(set) var nodes: [BrowserNode] = []
        /// Its rows: under groups, each group's header before its entries
        /// (but the folders', first, with none).
        enum Row { case header(FileGroup), node(BrowserNode) }
        private(set) var rows: [Row] = []

        func show(_ entries: [BrowserNode], grouped: Bool) {
            rows = grouped ? FileGroup.grouped(entries).flatMap { ($0.0 == .folders ? [] : [Row.header($0.0)]) + $0.1.map(Row.node) }
                : entries.map(Row.node)
            nodes = rows.compactMap { if case let .node(n) = $0 { n } else { nil } }
        }

        /// The entry at a row; nil at a header, or past them.
        func node(_ row: Int) -> BrowserNode? {
            guard rows.indices.contains(row), case let .node(n) = rows[row] else { return nil }
            return n
        }

        func row(of path: String) -> Int? {
            rows.firstIndex { if case let .node(n) = $0 { n.path == path } else { false } }
        }

        override init(frame: NSRect) {
            super.init(frame: frame)
            let c = NSTableColumn(identifier: .init("name"))
            table.addTableColumn(c)
            table.headerView = nil
            table.style = .plain
            table.rowHeight = 24
            table.intercellSpacing = NSSize(width: 0, height: 0)
            table.columnAutoresizingStyle = .firstColumnOnlyAutoresizingStyle
            table.allowsEmptySelection = true
            table.allowsMultipleSelection = false
            table.backgroundColor = .clear
            table.setDraggingSourceOperationMask([.copy, .link, .generic], forLocal: true)
            table.setDraggingSourceOperationMask([.copy, .link, .generic], forLocal: false)
            scroll.documentView = table
            scroll.hasVerticalScroller = true
            scroll.autohidesScrollers = true
            scroll.drawsBackground = false
            addSubview(scroll)
        }

        required init?(coder: NSCoder) { fatalError() }

        override func layout() {
            super.layout()
            scroll.frame = NSRect(x: 0, y: 0, width: bounds.width - 1, height: bounds.height)
            table.tableColumns.first?.width = scroll.contentSize.width
        }

        // The hairline at its right, between it and the next.
        override func draw(_ dirtyRect: NSRect) {
            Theme.divider.setFill()
            NSRect(x: bounds.maxX - 1, y: 0, width: 1, height: bounds.height).fill()
        }
    }

    /// A column's list: it scrolls up and down; a gesture sideways (or a
    /// wheel turned with ⇧) goes to the strip of columns it's in, which
    /// scrolls across them — the list took it, and the strip never moved.
    final class ColumnScroll: NSScrollView {
        /// The gesture under way is sideways, as it began.
        private var sideways = false

        override init(frame: NSRect) {
            super.init(frame: frame)
            clipsToBounds = true
            horizontalScrollElasticity = .none
        }

        required init?(coder: NSCoder) { fatalError() }

        override func scrollWheel(with event: NSEvent) {
            // Its direction taken as it starts (a trackpad's), else at each
            // turn (a wheel's); its momentum goes the same way.
            if event.phase == .began || (event.phase == [] && event.momentumPhase == []) {
                sideways = abs(event.scrollingDeltaX) > abs(event.scrollingDeltaY)
            }
            if sideways, let strip = enclosingScrollView { strip.scrollWheel(with: event) } else { super.scrollWheel(with: event) }
        }
    }

    var focusView: NSView { columns[min(focusedColumn, max(0, columns.count - 1))].table }
    var opensFoldersHere: Bool { true }

    init(owner: DirectoryView, model: DirectoryModel) {
        self.owner = owner
        self.model = model
        super.init(frame: .zero)
        scroll.documentView = strip
        scroll.hasHorizontalScroller = true
        scroll.hasVerticalScroller = false
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        addSubview(scroll)
        preview.makePage = { [weak owner] path, source in owner?.makePage(path, source: source) }
        preview.resolve = { [weak owner] path, done in
            guard let owner else { done(nil); return {} }
            return owner.resolve(path, done: done)
        }
        previewBox.addSubview(preview)
        strip.addSubview(previewBox)
        chosen = nil
        columns = [makeColumn()]
        columns[0].folder = model.root
    }

    required init?(coder: NSCoder) { fatalError() }

    func destroy() { preview.close() }

    private func makeColumn() -> Column {
        let c = Column()
        c.table.dataSource = self
        c.table.delegate = self
        c.table.target = self
        c.table.doubleAction = #selector(doubleClicked(_:))
        c.table.menu = NSMenu()
        c.table.menu?.delegate = self
        c.table.onSlash = { [unowned owner] in owner.focusFilter() }
        c.table.onArrow = { [weak self, unowned c] right in self?.arrow(right: right, from: c) }
        strip.addSubview(c)
        return c
    }

    // MARK: Layout

    private var previewShown: Bool { chosen.flatMap(model.existingNode)?.isDirectory == false }

    override func layout() {
        super.layout()
        scroll.frame = bounds
        place()
    }

    /// The columns side by side, then the preview: as wide as what's left
    /// in view, at least `previewMin`.
    private func place() {
        let h = scroll.contentSize.height
        let w = Self.columnWidth
        for (i, c) in columns.enumerated() { c.frame = NSRect(x: CGFloat(i) * w, y: 0, width: w, height: h) }
        let used = CGFloat(columns.count) * w
        let pw = previewShown ? max(Self.previewMin, scroll.contentSize.width - used) : 0
        previewBox.isHidden = pw == 0
        previewBox.frame = NSRect(x: used, y: 0, width: pw, height: h)
        preview.frame = previewBox.bounds.insetBy(dx: 12, dy: 12)
        strip.frame = NSRect(x: 0, y: 0, width: max(used + pw, scroll.contentSize.width), height: h)
    }

    /// The last column (and the preview) in view.
    private func scrollToEnd() {
        place()
        let r = previewShown ? previewBox.frame : (columns.last?.frame ?? .zero)
        strip.scrollToVisible(r)
    }

    // MARK: Data

    /// A folder's entries in its column: under the filter, those it keeps.
    /// Nil while the folder is being listed.
    private func entries(_ folder: String) -> [BrowserNode]? {
        model.children(of: folder)?.filter { model.keeps($0.path) }
    }

    private func column(of table: NSTableView) -> Column? { columns.first { $0.table === table } }

    func numberOfRows(in tableView: NSTableView) -> Int { column(of: tableView)?.rows.count ?? 0 }

    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? { SelectionRowView() }

    func tableView(_ tableView: NSTableView, isGroupRow row: Int) -> Bool { isHeader(tableView, row) }

    /// A header isn't chosen: clicked, what was chosen stays; come to by
    /// the arrows, the entry past it is.
    func tableView(_ tableView: NSTableView, selectionIndexesForProposedSelection proposed: IndexSet) -> IndexSet {
        guard proposed.count == 1, let p = proposed.first, let c = column(of: tableView), c.node(p) == nil else { return proposed }
        let mouse: Set<NSEvent.EventType> = [.leftMouseDown, .leftMouseDragged, .leftMouseUp, .rightMouseDown, .otherMouseDown]
        if let e = NSApp.currentEvent, mouse.contains(e.type) { return tableView.selectedRowIndexes }
        let past = p > tableView.selectedRow ? p + 1 : p - 1
        return c.node(past) != nil ? [past] : tableView.selectedRowIndexes
    }

    /// A header's height: air above it, but for the first.
    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
        isHeader(tableView, row) ? (row == 0 ? 26 : 40) : 24
    }

    private func isHeader(_ tableView: NSTableView, _ row: Int) -> Bool {
        guard let c = column(of: tableView), c.rows.indices.contains(row), case .header = c.rows[row] else { return false }
        return true
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard let c = column(of: tableView), c.rows.indices.contains(row) else { return nil }
        guard let n = c.node(row) else {
            guard case let .header(g) = c.rows[row] else { return nil }
            let cell = tableView.makeView(withIdentifier: ColumnHeaderCell.id, owner: nil) as? ColumnHeaderCell ?? ColumnHeaderCell()
            cell.label.stringValue = g.title
            return cell
        }
        let cell = tableView.makeView(withIdentifier: ColumnCell.id, owner: nil) as? ColumnCell ?? ColumnCell()
        // The letters a filter matched, in a file's name.
        var bold: [Int] = []
        if model.filtering, !n.isDirectory {
            let rel = model.relative(n.path)
            let start = rel.count - n.name.count
            bold = (model.matchedAt[rel] ?? []).filter { $0 >= start }.map { $0 - start }
        }
        cell.show(n, bold: bold)
        return cell
    }

    func tableView(_ tableView: NSTableView, typeSelectStringFor tableColumn: NSTableColumn?, row: Int) -> String? {
        column(of: tableView)?.node(row)?.name
    }

    func tableView(_ tableView: NSTableView, pasteboardWriterForRow row: Int) -> NSPasteboardWriting? {
        column(of: tableView)?.node(row).map(owner.pasteboardWriter)
    }

    func tableView(_ tableView: NSTableView, draggingSession session: NSDraggingSession, willBeginAt screenPoint: NSPoint, forRowIndexes rowIndexes: IndexSet) {
        DragPill.dress(session, from: tableView, at: screenPoint)
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        guard let c = columns.first(where: { $0.table.menu === menu }), let n = c.node(c.table.clickedRow),
              let m = owner.menu(for: n) else { return }
        for item in m.items { m.removeItem(item); menu.addItem(item) }
    }

    func folder(at point: NSPoint) -> String? {
        // A folder's row: into it; anywhere else in a column, its folder.
        guard let c = columns.first(where: { $0.bounds.contains($0.convert(point, from: self)) }) else { return nil }
        if let n = c.node(c.table.row(at: c.table.convert(point, from: self))), n.isDirectory { return n.path }
        return c.folder
    }

    var shownFolders: [String] { columns.map(\.folder).filter { $0 != model.root } }

    // MARK: Choosing

    var selectedPath: String? { chosen }
    var selectedNode: BrowserNode? { chosen.flatMap(model.existingNode) }

    /// The column with the chosen entry in it: the keyboard's.
    private var focusedColumn: Int {
        guard let chosen else { return 0 }
        return columns.firstIndex { $0.folder == chosen.deletingLastPathComponent } ?? max(0, columns.count - 1)
    }

    /// The folders a column each: the root, and each folder on the way
    /// to the chosen entry — that too, if it's a folder.
    private func trail() -> [String] {
        var t = [model.root]
        guard let chosen else { return t }
        var f = model.root
        let parts = model.relative(chosen).split(separator: "/").map(String.init)
        for (i, part) in parts.enumerated() {
            f = f.appendingPathComponent(part)
            if i < parts.count - 1 || model.existingNode(f)?.isDirectory == true { t.append(f) }
        }
        return t
    }

    /// The columns made over for the chosen entry: each listing its folder,
    /// the next on the way chosen in it; those past the trail gone. A
    /// column whose folder isn't listed yet waits (it's asked for), and
    /// what was chosen past it waits too.
    private func rebuild(reloading: Set<String> = []) {
        let t = trail()
        restoring = true
        defer { restoring = false }
        var kept = t.count
        for (i, folder) in t.enumerated() {
            let c = i < columns.count ? columns[i] : { let c = makeColumn(); columns.append(c); return c }()
            if c.folder != folder || reloading.contains(folder) || c.nodes.isEmpty {
                c.folder = folder
                c.show(entries(folder) ?? [], grouped: model.useGroups)
                c.table.reloadData()
            }
            let next = i + 1 < t.count ? t[i + 1] : (chosen != folder ? chosen : nil)
            if let next, let row = c.row(of: next) {
                c.table.selectRowIndexes([row], byExtendingSelection: false)
                c.table.scrollRowToVisible(row)
            } else {
                c.table.deselectAll(nil)
                // Gone from its folder (or not let through the filter):
                // chosen no further than this column's folder.
                if let next, model.children(of: folder) != nil, !c.nodes.contains(where: { $0.path == next }) {
                    chosen = folder == model.root ? nil : folder
                    kept = i + 1
                    break
                }
            }
        }
        if columns.count > kept {
            for extra in columns.dropFirst(kept) { extra.removeFromSuperview() }
            columns.removeSubrange(kept...)
        }
        preview.show(previewShown ? selectedNode : nil)
        scrollToEnd()
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        guard !restoring, let table = notification.object as? NSTableView, let c = column(of: table) else { return }
        let n = c.node(table.selectedRow)
        choose(n?.path ?? (c.folder == model.root ? nil : c.folder))
    }

    private func choose(_ path: String?) {
        guard path != chosen else { return }
        chosen = path
        pendingSelect = nil
        rebuild()
        owner.selectionChanged(chosen)
    }

    /// Double-clicked, a file or a folder opens, as its menu's Open does
    /// (a folder in this tile; ⌘ beside, ⌥ over).
    @objc private func doubleClicked(_ sender: NSTableView) {
        guard let n = column(of: sender)?.node(sender.clickedRow) else { return }
        owner.open(n)
    }

    /// → into the folder chosen (its first entry chosen), ← back to the
    /// folder this column lists.
    private func arrow(right: Bool, from c: Column) {
        guard let i = columns.firstIndex(where: { $0 === c }) else { return }
        if right {
            guard let n = c.node(c.table.selectedRow), n.isDirectory else { return }
            toggle(n)
        } else {
            guard i > 0 else { return }
            choose(c.folder)
            window?.makeFirstResponder(columns[i - 1].table)
        }
    }

    /// A folder opened in the next column, its first entry chosen there.
    func toggle(_ n: BrowserNode) {
        guard n.isDirectory else { return }
        if chosen != n.path { choose(n.path) }
        guard let i = columns.firstIndex(where: { $0.folder == n.path }) else { return }
        if let first = columns[i].nodes.first { choose(first.path) }
        window?.makeFirstResponder(columns[i].table)
    }

    func select(_ path: String?) {
        guard let path, path != model.root else {
            chosen = nil
            return rebuild()
        }
        // Each folder on the way listed, for its column; one not yet: the
        // choice waits for it (`folderChanged`), as far as it can go meanwhile.
        var ready = true
        var f = path.deletingLastPathComponent
        var chain: [String] = []
        while f.count >= model.root.count, f.hasPrefix(model.root) {
            chain.insert(f, at: 0)
            if f == model.root { break }
            f = f.deletingLastPathComponent
        }
        model.prefetch(chain)
        for d in chain where model.children(of: d) == nil { ready = false }
        if ready, model.existingNode(path) != nil {
            pendingSelect = nil
            chosen = path
        } else {
            pendingSelect = ready ? nil : path
            chosen = chain.last { model.children(of: $0) != nil && $0 != model.root && model.existingNode($0) != nil }
        }
        rebuild()
        owner.selectionChanged(pendingSelect ?? chosen)
    }

    /// The first entry; under the filter, the first match in the columns'
    /// own order (folders first, by name), not the best ranked.
    func selectFirst() {
        if model.filtering {
            let grouped = model.useGroups
            if let first = model.matchedFiles.min(by: { Self.inColumnOrder($0, $1, grouped: grouped) }) { select(model.absolute(first)) }
        } else if let first = entries(model.root)?.first {
            select(first.path)
        }
    }

    /// Two relative paths in the order columns show them: at the first
    /// place they part, a folder before a file, else (under groups) by
    /// group, else by name.
    static func inColumnOrder(_ a: String, _ b: String, grouped: Bool = false) -> Bool {
        let pa = a.split(separator: "/"), pb = b.split(separator: "/")
        for i in 0..<min(pa.count, pb.count) where pa[i] != pb[i] {
            let fa = i < pa.count - 1, fb = i < pb.count - 1
            if fa != fb { return fa }
            if grouped, !fa {
                let ga = FileGroup.of(String(pa[i]), isDirectory: false), gb = FileGroup.of(String(pb[i]), isDirectory: false)
                if ga != gb { return ga < gb }
            }
            return String(pa[i]).standardCompare(String(pb[i]))
        }
        return pa.count < pb.count
    }

    // MARK: Changes

    func folderChanged(_ folder: String) {
        guard columns.contains(where: { $0.folder == folder }) || pendingSelect != nil else { return }
        if let p = pendingSelect { return select(p) }
        rebuild(reloading: [folder])
    }

    /// Everything listed again — under a new filter, what it keeps. A
    /// selection it lets through stays; else the first match is chosen.
    func reloadAll() {
        let reloading = Set(columns.map(\.folder))
        if model.filtering, !model.isLoadingTree, chosen.map({ !model.matchedFiles.contains(model.relative($0)) }) ?? true,
           !model.matchedFiles.isEmpty {
            for c in columns { c.show([], grouped: false) }
            selectFirst()
            return
        }
        if let p = pendingSelect { return select(p) }
        rebuild(reloading: reloading)
    }

    // MARK: Debugging

    var debugRows: String {
        columns.enumerated().map { i, c -> String in
            let rows = c.rows.prefix(20).enumerated().map { r, row -> String in
                guard case let .node(n) = row else { if case let .header(g) = row { return "‹\(g.title)›" }; return "" }
                return (c.table.selectedRow == r ? "[" : "") + n.name + (n.isDirectory ? "/" : "") + (c.table.selectedRow == r ? "]" : "")
            }
            return "column \(i) \(model.relative(c.folder).isEmpty ? "." : model.relative(c.folder)): " + rows.joined(separator: " ")
                + (c.rows.count > 20 ? " … (\(c.nodes.count))" : "")
        }.joined(separator: "\n")
            + "\npreview " + (previewBox.isHidden ? "none" : "\(preview.node?.name ?? "nothing") \(Int(previewBox.frame.width)) wide")
            + " · keyboard in column \(focusedColumn) · strip \(Int(strip.frame.width)) in \(Int(scroll.contentSize.width))"
    }
}

/// A column's list: ← and → go between columns; / (or ⇥) to the filter.
final class ColumnTable: NSTableView {
    var onSlash: (() -> Void)?
    var onArrow: ((Bool) -> Void)?

    override func keyDown(with event: NSEvent) {
        let mods = event.modifierFlags.intersection([.command, .control, .option, .shift])
        if mods.isEmpty, event.charactersIgnoringModifiers == "/" || event.keyCode == 48, let onSlash { return onSlash() }
        if mods.isEmpty, event.keyCode == 124 { return onArrow?(true) ?? () }
        if mods.isEmpty, event.keyCode == 123 { return onArrow?(false) ?? () }
        super.keyDown(with: event)
    }
}

/// A group's header in a column, as the Finder's: its name, small and
/// grey, at the foot of its row (the air above it parting it from the
/// group before).
final class ColumnHeaderCell: NSTableCellView {
    static let id = NSUserInterfaceItemIdentifier("column-header")
    let label = NSTextField(labelWithString: "")

    init() {
        super.init(frame: .zero)
        identifier = Self.id
        label.font = NSFont.systemFont(ofSize: 11, weight: .semibold)
        label.textColor = Theme.secondaryText
        label.lineBreakMode = .byTruncatingTail
        addSubview(label)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        label.frame = NSRect(x: 12, y: 4, width: max(0, bounds.width - 20), height: 15)
    }
}

/// A column's row, as the tree's: a file's type as a small symbol in its
/// colour (a folder's, in grey), the name — shortened in the middle, the
/// letters a filter matched in bold — and a chevron after a folder.
final class ColumnCell: NSTableCellView {
    static let id = NSUserInterfaceItemIdentifier("column-cell")
    private let icon = NSImageView()
    private let label = NSTextField(labelWithString: "")
    private let chevron = NSImageView()

    init() {
        super.init(frame: .zero)
        identifier = Self.id
        icon.imageScaling = .scaleProportionallyDown
        chevron.imageScaling = .scaleProportionallyDown
        label.lineBreakMode = .byTruncatingMiddle
        for v in [icon, label, chevron] { addSubview(v) }
    }

    required init?(coder: NSCoder) { fatalError() }

    func show(_ n: BrowserNode, bold: [Int]) {
        let fade: CGFloat = n.isMuted ? 0.5 : 1
        let g = n.isDirectory ? (symbol: "folder", color: Theme.secondaryText) : TreeCell.glyph(n.name)
        icon.image = Theme.symbol(g.symbol, size: 12, weight: .medium)?.tinted(g.color.withAlphaComponent(fade))
        chevron.image = n.isDirectory ? Theme.symbol("chevron.right", size: 10, weight: .semibold)?.tinted(Theme.tertiaryText) : nil
        let p = NSMutableParagraphStyle()
        p.lineBreakMode = .byTruncatingMiddle
        let text = NSMutableAttributedString(string: n.name, attributes: [
            .font: UIType.row, .foregroundColor: n.isMuted ? Theme.tertiaryText : Theme.text, .paragraphStyle: p,
        ])
        let length = (n.name as NSString).length
        for i in bold {
            guard let r = n.name.index(n.name.startIndex, offsetBy: i, limitedBy: n.name.endIndex), r < n.name.endIndex else { continue }
            let range = NSRange(r...r, in: n.name)
            if range.location + range.length <= length { text.addAttribute(.font, value: NSFont.systemFont(ofSize: 13, weight: .bold), range: range) }
        }
        label.attributedStringValue = text
        needsLayout = true
    }

    override func layout() {
        super.layout()
        let h = bounds.height
        icon.frame = NSRect(x: 10, y: (h - 14) / 2, width: 14, height: 14)
        chevron.frame = NSRect(x: bounds.width - 20, y: (h - 10) / 2, width: 10, height: 10)
        let x: CGFloat = 30
        label.frame = NSRect(x: x, y: (h - 17) / 2, width: max(0, chevron.frame.minX - 4 - x), height: 17)
    }
}

private extension Array {
    /// The element at `i`, if there's one there (a row of -1, say).
    subscript(safe i: Int) -> Element? { indices.contains(i) ? self[i] : nil }
}
