import AppKit
import ManifoldCore

/// How the sidebar organizes the graph (DESIGN.md §3.6): the desk's
/// arrangements and their columns; files under folders under roots,
/// across hosts; what's linked to the focused block; blocks by day.
enum Organization: String, CaseIterable {
    case desk, files, links, time, status

    var title: String {
        switch self {
        case .desk: "Workspaces"
        case .files: "Files"
        case .links: "Links"
        case .time: "Time"
        case .status: "Status"
        }
    }

    var symbol: String {
        switch self {
        case .desk: "rectangle.3.group"
        case .files: "folder"
        case .links: "link"
        case .time: "clock"
        case .status: "checkmark.circle"
        }
    }
}

/// A row of an organization: a block, or a grouping of them (a folder, a
/// day, an edge kind), with what's under it — given, or made when opened.
final class OrgNode {
    let id: String
    var block: BlockID?
    var title: String
    var symbol: String
    var detail: String
    /// A small symbol before the detail, in its grey: stashed, maximized.
    var detailSymbol: String?
    /// How many blocks beneath, shown as a count; nil for none.
    var count: Int?
    /// How long unseen, 0 fresh to 1 long ago: rows fade with it.
    var age: Double?
    var isGroup: Bool
    /// Set off from the rest: the selected arrangement, the focused column.
    var emphasis = false
    /// Not on any workspace now (Files): after the ones that are, in a
    /// dimmer face.
    var dimmed = false
    /// What the block is doing (§3.7), shown as a glyph.
    var look: StatusGlyph.Look?
    /// A word at the right, before the glyph: how long ago.
    var trailing: String?
    var tooltip: String?
    /// On the desk: the arrangement this row is, or is a column of.
    var arrangement: BlockID?
    /// On the desk: which column of its arrangement, and the placement shown.
    var column: Int?
    var placement: PlacementID?
    /// A row that does something rather than opening a block (New…).
    var action: (() -> Void)?
    private var given: [OrgNode]
    var loadChildren: (() -> [OrgNode])?
    private var loaded = false

    init(id: String, block: BlockID? = nil, title: String, symbol: String, detail: String = "", count: Int? = nil, age: Double? = nil,
         isGroup: Bool = false, children: [OrgNode] = [], loadChildren: (() -> [OrgNode])? = nil) {
        self.id = id
        self.block = block
        self.title = title
        self.symbol = symbol
        self.detail = detail
        self.count = count
        self.age = age
        self.isGroup = isGroup
        self.given = children
        self.loadChildren = loadChildren
    }

    var children: [OrgNode] {
        if !loaded, let load = loadChildren {
            loaded = true
            given = load()
        }
        return given
    }

    var hasChildren: Bool { !given.isEmpty || (loadChildren != nil && !loaded) }
}

/// What's being dragged over the sidebar.
enum OrgDragItem {
    case block(BlockID)
    case placement(PlacementID)
    case arrangement(BlockID)

    init?(_ pb: NSPasteboard) {
        if let a = pb.string(forType: .manifoldArrangement).flatMap(BlockID.init(string:)) { self = .arrangement(a) }
        else if let p = pb.string(forType: .manifoldPlacement) { self = .placement(p) }
        else if let b = pb.string(forType: .manifoldBlock).flatMap(BlockID.init(string:)) { self = .block(b) }
        else { return nil }
    }
}

protocol OrganizationViewDelegate: AnyObject {
    /// A row was clicked: show its block here, or beside (§3.1); go to
    /// an arrangement; focus a column.
    func organizationOpen(_ node: OrgNode, newColumn: Bool)
    /// A row was double-clicked; true if that meant something (naming an
    /// arrangement), else the row opens or closes.
    func organizationActivate(_ node: OrgNode) -> Bool
    /// The pointer rests on a row: its card, or none.
    func organizationHover(_ node: OrgNode?, at rect: NSRect, in view: NSView)
    func organizationMenu(for node: OrgNode) -> NSMenu?
    /// Something dragged onto a row, or between the rows under `node`
    /// (nil for the top level) at `index`.
    func organizationCanDrop(_ item: OrgDragItem, onto node: OrgNode?, at index: Int) -> Bool
    func organizationDrop(_ item: OrgDragItem, onto node: OrgNode?, at index: Int) -> Bool
    func organizationDragChanged(_ dragging: Bool)
}

/// The tree of an organization, as an outline: rows with a symbol, a
/// name, a count, fading with age; groups open and close; a block's row
/// opens it. Expansion is remembered by row id across refreshes. Rows
/// drag (a block, and an arrangement or placement where the row is one)
/// and take drops.
/// An outline whose chevron, clicked with ⇧ (or ⌥, as outlines have it),
/// opens or closes the whole subtree.
final class DeepOutlineView: NSOutlineView {
    /// Only while a ⇧-click is being handled: not for every expansion
    /// made while ⇧ happens to be down (a ⇧-drag, ⇧⌘N), which on a tree
    /// whose children are made as they're reached (Links) would go on
    /// for ever.
    private var deep = false

    override func mouseDown(with event: NSEvent) {
        deep = event.modifierFlags.contains(.shift)
        defer { deep = false }
        super.mouseDown(with: event)
    }

    override func expandItem(_ item: Any?, expandChildren: Bool) { super.expandItem(item, expandChildren: expandChildren || deep) }
    override func collapseItem(_ item: Any?, collapseChildren: Bool) { super.collapseItem(item, collapseChildren: collapseChildren || deep) }
}

final class OrganizationView: NSView, NSOutlineViewDataSource, NSOutlineViewDelegate {
    weak var delegate: OrganizationViewDelegate?
    private let scroll = NSScrollView()
    private let outline = DeepOutlineView()
    private var roots: [OrgNode] = []
    private var expanded: Set<String> = []
    private var expandedByDefault: Set<String> = []
    private var collapsedByHand: Set<String> = []
    private var trackedRow: Int = -1
    private var selecting = false

    override init(frame: NSRect) {
        super.init(frame: frame)
        let column = NSTableColumn(identifier: .init("row"))
        column.resizingMask = .autoresizingMask
        outline.addTableColumn(column)
        outline.outlineTableColumn = column
        outline.headerView = nil
        outline.rowHeight = 26
        outline.indentationPerLevel = 14
        outline.style = .sourceList
        outline.selectionHighlightStyle = .regular
        outline.floatsGroupRows = false
        outline.dataSource = self
        outline.delegate = self
        outline.target = self
        outline.action = #selector(rowClicked)
        outline.doubleAction = #selector(rowDoubleClicked)
        outline.menu = NSMenu()
        outline.menu?.delegate = self
        outline.backgroundColor = .clear
        outline.registerForDraggedTypes([.manifoldArrangement, .manifoldPlacement, .manifoldBlock])
        outline.setDraggingSourceOperationMask(.move, forLocal: true)
        outline.draggingDestinationFeedbackStyle = .regular
        scroll.documentView = outline
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.scrollerStyle = .overlay
        addSubview(scroll)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        scroll.frame = bounds
        outline.tableColumns[0].width = scroll.contentSize.width
        outline.sizeLastColumnToFit()
    }

    /// Shows a tree; rows open as they were, or as `openByDefault` says
    /// the first time; the row `selected` is highlighted.
    func show(_ nodes: [OrgNode], openByDefault: Set<String> = [], selected: String? = nil) {
        roots = nodes
        expandedByDefault = openByDefault
        outline.reloadData()
        func expandAll(_ list: [OrgNode]) {
            for n in list where expanded.contains(n.id) || (expandedByDefault.contains(n.id) && !collapsedByHand.contains(n.id)) {
                outline.expandItem(n)
                expandAll(n.children)
            }
        }
        expandAll(nodes)
        selecting = true
        defer { selecting = false }
        if let selected, let row = (0..<outline.numberOfRows).first(where: { (outline.item(atRow: $0) as? OrgNode)?.id == selected }) {
            outline.selectRowIndexes([row], byExtendingSelection: false)
        } else {
            outline.deselectAll(nil)
        }
    }

    // MARK: Data

    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        (item as? OrgNode)?.children.count ?? roots.count
    }

    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        ((item as? OrgNode)?.children ?? roots)[index]
    }

    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
        (item as? OrgNode)?.hasChildren ?? false
    }

    func outlineView(_ outlineView: NSOutlineView, isGroupItem item: Any) -> Bool { false }

    func outlineView(_ outlineView: NSOutlineView, rowViewForItem item: Any) -> NSTableRowView? { SelectionRowView() }

    func outlineViewItemDidExpand(_ notification: Notification) {
        if let n = notification.userInfo?["NSObject"] as? OrgNode { expanded.insert(n.id); collapsedByHand.remove(n.id) }
    }

    func outlineViewItemDidCollapse(_ notification: Notification) {
        if let n = notification.userInfo?["NSObject"] as? OrgNode { expanded.remove(n.id); collapsedByHand.insert(n.id) }
    }

    func outlineView(_ outlineView: NSOutlineView, shouldSelectItem item: Any) -> Bool {
        guard let n = item as? OrgNode else { return false }
        return n.block != nil || n.action != nil
    }

    func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        guard let node = item as? OrgNode else { return nil }
        let cell = outlineView.makeView(withIdentifier: .init("org"), owner: nil) as? OrgRowView ?? OrgRowView()
        cell.identifier = .init("org")
        cell.show(node)
        return cell
    }

    // MARK: Clicks

    @objc private func rowClicked() {
        let row = outline.clickedRow
        guard row >= 0, let node = outline.item(atRow: row) as? OrgNode else { return }
        if let action = node.action {
            action()
        } else if node.block != nil {
            delegate?.organizationOpen(node, newColumn: NSApp.currentEvent?.modifierFlags.contains(.command) ?? false)
        } else if node.hasChildren {
            if outline.isItemExpanded(node) { outline.collapseItem(node) } else { outline.expandItem(node) }
        }
    }

    @objc private func rowDoubleClicked() {
        let row = outline.clickedRow
        guard row >= 0, let node = outline.item(atRow: row) as? OrgNode else { return }
        if delegate?.organizationActivate(node) == true { return }
        guard node.hasChildren else { return }
        if outline.isItemExpanded(node) { outline.collapseItem(node) } else { outline.expandItem(node) }
    }

    // MARK: Dragging

    func outlineView(_ outlineView: NSOutlineView, pasteboardWriterForItem item: Any) -> NSPasteboardWriting? {
        guard let node = item as? OrgNode, let block = node.block else { return nil }
        let pb = NSPasteboardItem()
        pb.setString(block.description, forType: .manifoldBlock)
        if let a = node.arrangement, node.column == nil { pb.setString(a.description, forType: .manifoldArrangement) }
        if let p = node.placement { pb.setString(p, forType: .manifoldPlacement) }
        return pb
    }

    func outlineView(_ outlineView: NSOutlineView, draggingSession session: NSDraggingSession, willBeginAt screenPoint: NSPoint, forItems draggedItems: [Any]) {
        HoverCard.shared.hide()
        delegate?.organizationDragChanged(true)
    }

    func outlineView(_ outlineView: NSOutlineView, draggingSession session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
        delegate?.organizationDragChanged(false)
    }

    func outlineView(_ outlineView: NSOutlineView, validateDrop info: NSDraggingInfo, proposedItem item: Any?, proposedChildIndex index: Int) -> NSDragOperation {
        guard let drag = OrgDragItem(info.draggingPasteboard) else { return [] }
        let node = item as? OrgNode
        return delegate?.organizationCanDrop(drag, onto: node, at: index) == true ? .move : []
    }

    func outlineView(_ outlineView: NSOutlineView, acceptDrop info: NSDraggingInfo, item: Any?, childIndex index: Int) -> Bool {
        guard let drag = OrgDragItem(info.draggingPasteboard) else { return false }
        return delegate?.organizationDrop(drag, onto: item as? OrgNode, at: index) ?? false
    }

    // MARK: Debugging aids

    /// The rows as shown, one per line: depth, id, title.
    func debugRows() -> String {
        (0..<outline.numberOfRows).compactMap { row in
            guard let n = outline.item(atRow: row) as? OrgNode else { return nil }
            return "\(row) \(String(repeating: "  ", count: outline.level(forRow: row)))\(n.id) | \(n.title)\(n.detail.isEmpty ? "" : " · " + n.detail)\(n.dimmed ? " [dim]" : "")"
        }.joined(separator: "\n")
    }

    /// As the pointer moving onto the row (-1: off every row), through the
    /// same path a real move takes.
    func debugHover(row: Int) -> String {
        let p = row >= 0 ? NSPoint(x: outline.rect(ofRow: row).midX, y: outline.rect(ofRow: row).midY) : NSPoint(x: -100, y: -100)
        guard let e = NSEvent.mouseEvent(with: .mouseMoved, location: outline.convert(p, to: nil), modifierFlags: [],
                                         timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window?.windowNumber ?? 0,
                                         context: nil, eventNumber: 0, clickCount: 0, pressure: 0) else { return "no event" }
        mouseMoved(with: e)
        return "hovered \(trackedRow)"
    }

    /// The row's context menu: its titles, or the item named chosen.
    func debugMenu(row: Int, choose: String) -> String {
        guard let node = outline.item(atRow: row) as? OrgNode, let menu = delegate?.organizationMenu(for: node) else { return "no menu" }
        if choose.isEmpty { return menu.items.map { $0.isSeparatorItem ? "---" : $0.title }.joined(separator: "\n") }
        guard let item = menu.items.first(where: { $0.title == choose }) as? ClosureMenuItem else { return "no such item" }
        item.debugRun()
        return "chose \(choose)"
    }

    func debugExpand(row: Int, deep: Bool = false) -> String {
        guard let node = outline.item(atRow: row) as? OrgNode else { return "no row" }
        outline.expandItem(node, expandChildren: deep)
        return "expanded, \(outline.numberOfRows) rows"
    }

    /// As a click (or ⌘-click, or double-click) on a row would do.
    func debugClick(row: Int, command: Bool, double: Bool) -> String {
        guard row >= 0, row < outline.numberOfRows, let node = outline.item(atRow: row) as? OrgNode else { return "no such row" }
        if double {
            if delegate?.organizationActivate(node) == true { return "activated" }
            if node.hasChildren { if outline.isItemExpanded(node) { outline.collapseItem(node) } else { outline.expandItem(node) } }
            return "toggled"
        }
        if let action = node.action { action(); return "ran" }
        if node.block != nil { delegate?.organizationOpen(node, newColumn: command); return "opened" }
        if node.hasChildren { if outline.isItemExpanded(node) { outline.collapseItem(node) } else { outline.expandItem(node) }; return "toggled" }
        return "nothing"
    }

    // MARK: Hovering

    override func updateTrackingAreas() {
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self))
        super.updateTrackingAreas()
    }

    /// A Recent group (Files) opened by the pointer resting on it, closed
    /// again when the pointer moves off it and what it holds.
    private var hoverOpened: OrgNode?
    private var hoverWork: DispatchWorkItem?

    private func hoverReveal(row: Int) {
        let node = row >= 0 ? outline.item(atRow: row) as? OrgNode : nil
        if let opened = hoverOpened {
            var within = false
            var n: Any? = node
            while let cur = n as? OrgNode { if cur === opened { within = true; break }; n = outline.parent(forItem: cur) }
            if !within {
                outline.collapseItem(opened)
                hoverOpened = nil
            }
        }
        hoverWork?.cancel()
        guard let node, node.id.hasPrefix("recent:"), !outline.isItemExpanded(node) else { return }
        let work = DispatchWorkItem { [weak self, weak node] in
            guard let self, let node, self.trackedRow == row else { return }
            self.outline.expandItem(node)
            self.hoverOpened = node
        }
        hoverWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: work)
    }

    override func mouseMoved(with event: NSEvent) {
        let p = outline.convert(event.locationInWindow, from: nil)
        let row = outline.row(at: p)
        guard row != trackedRow else { return }
        trackedRow = row
        hoverReveal(row: row)
        if row >= 0, let node = outline.item(atRow: row) as? OrgNode, node.block != nil {
            delegate?.organizationHover(node, at: outline.convert(outline.rect(ofRow: row), to: nil), in: self)
        } else {
            delegate?.organizationHover(nil, at: .zero, in: self)
        }
    }

    override func mouseExited(with event: NSEvent) {
        trackedRow = -1
        hoverWork?.cancel()
        if let opened = hoverOpened {
            outline.collapseItem(opened)
            hoverOpened = nil
        }
        delegate?.organizationHover(nil, at: .zero, in: self)
    }
}

extension OrganizationView: NSMenuDelegate {
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let row = outline.clickedRow
        guard row >= 0, let node = outline.item(atRow: row) as? OrgNode, let items = delegate?.organizationMenu(for: node) else { return }
        for item in items.items { items.removeItem(item); menu.addItem(item) }
    }
}

/// A row: symbol, name, a count in a pill, a detail in grey; faded by age.
final class OrgRowView: NSTableCellView {
    private let icon = NSImageView()
    private let name = NSTextField(labelWithString: "")
    private let count = NSTextField(labelWithString: "")
    private let detail = NSTextField(labelWithString: "")
    private let detailIcon = NSImageView()
    private let glyph = StatusGlyph()
    private let trailing = NSTextField(labelWithString: "")
    private var symbol = ""
    private var detailSymbol = ""

    override init(frame: NSRect) {
        super.init(frame: frame)
        icon.contentTintColor = Theme.secondaryText
        name.font = .systemFont(ofSize: 13)
        name.textColor = Theme.text
        name.lineBreakMode = .byTruncatingTail
        name.cell?.truncatesLastVisibleLine = true
        count.font = .monospacedDigitSystemFont(ofSize: 10.5, weight: .medium)
        count.textColor = Theme.secondaryText
        count.alignment = .center
        count.wantsLayer = true
        count.layer?.cornerRadius = 7
        count.themed { $0.layer?.backgroundColor = Theme.hover.cgColor }
        detail.font = .systemFont(ofSize: 11)
        detail.textColor = Theme.secondaryText
        detail.lineBreakMode = .byTruncatingTail
        trailing.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        trailing.textColor = Theme.secondaryText
        trailing.alignment = .right
        detailIcon.contentTintColor = Theme.secondaryText
        detailIcon.isHidden = true
        for v in [icon, name, count, detail, detailIcon, trailing, glyph] { addSubview(v) }
    }

    required init?(coder: NSCoder) { fatalError() }

    func show(_ node: OrgNode) {
        glyph.look = node.look
        glyph.isHidden = node.look == nil
        glyph.toolTip = node.tooltip
        trailing.stringValue = node.trailing ?? ""
        trailing.isHidden = node.trailing == nil
        if node.symbol != symbol {
            symbol = node.symbol
            icon.image = Theme.symbol(node.symbol, size: 12)
        }
        name.stringValue = node.title
        name.font = .systemFont(ofSize: 13, weight: node.emphasis ? .semibold : node.isGroup ? .medium : .regular)
        name.textColor = node.dimmed ? Theme.secondaryText : Theme.text
        icon.contentTintColor = node.emphasis ? Theme.text : Theme.secondaryText
        icon.alphaValue = node.dimmed ? 0.6 : 1
        count.stringValue = node.count.map { "\($0)" } ?? ""
        count.isHidden = node.count == nil
        detail.stringValue = node.detail
        detail.isHidden = node.detail.isEmpty
        if (node.detailSymbol ?? "") != detailSymbol {
            detailSymbol = node.detailSymbol ?? ""
            detailIcon.image = detailSymbol.isEmpty ? nil : Theme.symbol(detailSymbol, size: 10)
        }
        detailIcon.isHidden = detailSymbol.isEmpty
        alphaValue = 1 - 0.45 * (node.age ?? 0)
        toolTip = node.detail.isEmpty ? node.title : node.title + " — " + node.detail
        needsLayout = true
    }

    override func layout() {
        super.layout()
        let h = bounds.height
        icon.frame = NSRect(x: 2, y: (h - 14) / 2, width: 16, height: 14)
        var right = bounds.width - 4
        if !count.isHidden {
            let w = max(20, ceil((count.stringValue as NSString).size(withAttributes: [.font: count.font!]).width) + 10)
            count.frame = NSRect(x: right - w, y: (h - 15) / 2, width: w, height: 15)
            right -= w + 6
        }
        // The status glyph goes before the detail (what the status says)
        // when there is one; at the right otherwise.
        let glyphLeads = !glyph.isHidden && !detail.isHidden
        if !glyph.isHidden, !glyphLeads {
            glyph.frame = NSRect(x: right - StatusGlyph.size - 2, y: (h - StatusGlyph.size) / 2, width: StatusGlyph.size, height: StatusGlyph.size)
            right -= StatusGlyph.size + 8
        }
        if !trailing.isHidden {
            let w = ceil((trailing.stringValue as NSString).size(withAttributes: [.font: trailing.font!]).width) + 2
            trailing.frame = NSRect(x: right - w, y: (h - 15) / 2 - 0.5, width: w, height: 15)
            right -= w + 8
        }
        let nameWidth = max(0, right - 22)
        if detail.isHidden {
            name.frame = NSRect(x: 22, y: (h - 17) / 2, width: nameWidth, height: 17)
        } else {
            let wanted = ceil((name.stringValue as NSString).size(withAttributes: [.font: name.font ?? NSFont.systemFont(ofSize: 13)]).width) + 4
            // The name whole whenever it fits; the detail gets what's left,
            // and goes when that's too little to say anything.
            let nw = min(wanted, nameWidth)
            name.frame = NSRect(x: 22, y: (h - 17) / 2, width: nw, height: 17)
            var x = 22 + nw + 6
            var dw = nameWidth - nw - 6
            if glyphLeads {
                glyph.frame = NSRect(x: x, y: (h - StatusGlyph.size) / 2, width: StatusGlyph.size, height: StatusGlyph.size)
                x += StatusGlyph.size + 4
                dw -= StatusGlyph.size + 4
            } else if !detailIcon.isHidden {
                detailIcon.frame = NSRect(x: x, y: (h - 12) / 2, width: 13, height: 12)
                x += 16
                dw -= 16
            }
            detail.frame = NSRect(x: x, y: (h - 15) / 2 - 0.5, width: max(0, dw), height: 15)
            let shown = dw >= 36
            detail.alphaValue = shown ? 1 : 0
            glyph.alphaValue = glyphLeads && !shown ? 0 : 1
            detailIcon.alphaValue = shown ? 1 : 0
        }
    }
}
