import AppKit
import ManifoldCore

/// How the sidebar organizes the graph (DESIGN.md §3.6): the desk's
/// arrangements; files under folders under roots, across hosts; what's
/// linked to the focused block; blocks by day.
enum Organization: String, CaseIterable {
    case desk, files, links, time

    var title: String {
        switch self {
        case .desk: "Desk"
        case .files: "Files"
        case .links: "Links"
        case .time: "Time"
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
    /// How many blocks beneath, shown as a count; nil for none.
    var count: Int?
    /// How long unseen, 0 fresh to 1 long ago: rows fade with it.
    var age: Double?
    var isGroup: Bool
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

protocol OrganizationViewDelegate: AnyObject {
    /// A block's row was clicked: recall it beside what's focused, or in a
    /// column of its own.
    func organizationOpen(_ block: BlockID, newColumn: Bool)
    /// The pointer rests on a row: its card, or none.
    func organizationHover(_ node: OrgNode?, at rect: NSRect, in view: NSView)
    func organizationMenu(for node: OrgNode) -> NSMenu?
}

/// The tree of an organization, as an outline: rows with a symbol, a
/// name, a count, fading with age; groups open and close; a block's row
/// opens it. Expansion is remembered by row id across refreshes.
final class OrganizationView: NSView, NSOutlineViewDataSource, NSOutlineViewDelegate {
    weak var delegate: OrganizationViewDelegate?
    private let scroll = NSScrollView()
    private let outline = NSOutlineView()
    private var roots: [OrgNode] = []
    private var expanded: Set<String> = []
    private var expandedByDefault: Set<String> = []
    private var trackedRow: Int = -1

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
    /// the first time.
    func show(_ nodes: [OrgNode], openByDefault: Set<String> = []) {
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
    }

    private var collapsedByHand: Set<String> = []

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

    func outlineViewItemDidExpand(_ notification: Notification) {
        if let n = notification.userInfo?["NSObject"] as? OrgNode { expanded.insert(n.id); collapsedByHand.remove(n.id) }
    }

    func outlineViewItemDidCollapse(_ notification: Notification) {
        if let n = notification.userInfo?["NSObject"] as? OrgNode { expanded.remove(n.id); collapsedByHand.insert(n.id) }
    }

    func outlineView(_ outlineView: NSOutlineView, shouldSelectItem item: Any) -> Bool {
        (item as? OrgNode)?.block != nil
    }

    func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        guard let node = item as? OrgNode else { return nil }
        let cell = outlineView.makeView(withIdentifier: .init("org"), owner: nil) as? OrgRowView ?? OrgRowView()
        cell.identifier = .init("org")
        cell.show(node)
        return cell
    }

    // MARK: Clicks

    private var lastClickModifiers: NSEvent.ModifierFlags = []

    override func mouseDown(with event: NSEvent) {
        lastClickModifiers = event.modifierFlags
        super.mouseDown(with: event)
    }

    @objc private func rowClicked() {
        let row = outline.clickedRow
        guard row >= 0, let node = outline.item(atRow: row) as? OrgNode else { return }
        if let block = node.block {
            delegate?.organizationOpen(block, newColumn: NSApp.currentEvent?.modifierFlags.contains(.command) ?? false)
        } else if node.hasChildren {
            if outline.isItemExpanded(node) { outline.collapseItem(node) } else { outline.expandItem(node) }
        }
    }

    @objc private func rowDoubleClicked() {
        let row = outline.clickedRow
        guard row >= 0, let node = outline.item(atRow: row) as? OrgNode, node.hasChildren else { return }
        if outline.isItemExpanded(node) { outline.collapseItem(node) } else { outline.expandItem(node) }
    }

    // MARK: Hovering

    override func updateTrackingAreas() {
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self))
        super.updateTrackingAreas()
    }

    override func mouseMoved(with event: NSEvent) {
        let p = outline.convert(event.locationInWindow, from: nil)
        let row = outline.row(at: p)
        guard row != trackedRow else { return }
        trackedRow = row
        if row >= 0, let node = outline.item(atRow: row) as? OrgNode, node.block != nil {
            delegate?.organizationHover(node, at: outline.convert(outline.rect(ofRow: row), to: nil), in: self)
        } else {
            delegate?.organizationHover(nil, at: .zero, in: self)
        }
    }

    override func mouseExited(with event: NSEvent) {
        trackedRow = -1
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
    private var symbol = ""

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
        for v in [icon, name, count, detail] { addSubview(v) }
    }

    required init?(coder: NSCoder) { fatalError() }

    func show(_ node: OrgNode) {
        if node.symbol != symbol {
            symbol = node.symbol
            icon.image = Theme.symbol(node.symbol, size: 12)
        }
        name.stringValue = node.title
        name.font = .systemFont(ofSize: 13, weight: node.isGroup ? .medium : .regular)
        count.stringValue = node.count.map { "\($0)" } ?? ""
        count.isHidden = node.count == nil
        detail.stringValue = node.detail
        detail.isHidden = node.detail.isEmpty
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
        let nameWidth = max(0, right - 22)
        if detail.isHidden {
            name.frame = NSRect(x: 22, y: (h - 17) / 2, width: nameWidth, height: 17)
        } else {
            let wanted = ceil((name.stringValue as NSString).size(withAttributes: [.font: name.font ?? NSFont.systemFont(ofSize: 13)]).width) + 4
            // The name whole whenever it fits; the detail gets what's left,
            // and goes when that's too little to say anything.
            let nw = min(wanted, nameWidth)
            name.frame = NSRect(x: 22, y: (h - 17) / 2, width: nw, height: 17)
            let dw = nameWidth - nw - 6
            detail.frame = NSRect(x: 22 + nw + 6, y: (h - 15) / 2 - 0.5, width: max(0, dw), height: 15)
            detail.alphaValue = dw < 36 ? 0 : 1
        }
    }
}

/// A block's card, shown while the pointer rests on its row: what it is,
/// where, when it was last seen, and a little of its text.
final class HoverCard: NSObject {
    static let shared = HoverCard()
    private let panel: NSPanel
    private let box = NSView()
    private let title = NSTextField(labelWithString: "")
    private let detail = NSTextField(labelWithString: "")
    private let body = NSTextField(wrappingLabelWithString: "")
    private var pendingShow: DispatchWorkItem?

    private override init() {
        panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 320, height: 100), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        super.init()
        panel.hasShadow = true
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.isFloatingPanel = true
        panel.level = .popUpMenu
        panel.ignoresMouseEvents = true
        box.wantsLayer = true
        box.layer?.cornerRadius = 10
        box.layer?.borderWidth = 0.5
        box.themed {
            $0.layer?.backgroundColor = Theme.panel.cgColor
            $0.layer?.borderColor = Theme.panelBorder.cgColor
        }
        title.font = .systemFont(ofSize: 13, weight: .semibold)
        title.textColor = Theme.text
        title.lineBreakMode = .byTruncatingMiddle
        detail.font = .systemFont(ofSize: 11.5)
        detail.textColor = Theme.secondaryText
        detail.lineBreakMode = .byTruncatingMiddle
        body.font = .systemFont(ofSize: 12)
        body.textColor = Theme.text
        body.maximumNumberOfLines = 8
        for v in [title, detail, body] { box.addSubview(v) }
        panel.contentView = box
    }

    /// Shows the card beside a rect (in window coordinates) after a moment.
    func show(title: String, detail: String, body: String, font: NSFont?, beside rect: NSRect, in window: NSWindow) {
        pendingShow?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.title.stringValue = title
            self.detail.stringValue = detail
            self.body.stringValue = body
            self.body.font = font ?? .systemFont(ofSize: 12)
            self.body.isHidden = body.isEmpty
            let width: CGFloat = 320, pad: CGFloat = 12
            self.body.preferredMaxLayoutWidth = width - 2 * pad
            let bodyHeight = body.isEmpty ? 0 : ceil(self.body.sizeThatFits(NSSize(width: width - 2 * pad, height: 200)).height)
            let height = pad + 17 + 2 + (detail.isEmpty ? 0 : 16) + (body.isEmpty ? 0 : 8 + bodyHeight) + pad
            self.title.frame = NSRect(x: pad, y: height - pad - 17, width: width - 2 * pad, height: 17)
            self.detail.frame = NSRect(x: pad, y: height - pad - 17 - 2 - 16, width: width - 2 * pad, height: 16)
            self.detail.isHidden = detail.isEmpty
            self.body.frame = NSRect(x: pad, y: pad, width: width - 2 * pad, height: bodyHeight)
            var origin = window.convertToScreen(NSRect(origin: NSPoint(x: rect.maxX + 8, y: rect.midY), size: .zero)).origin
            origin.y -= height / 2
            if let screen = window.screen {
                origin.y = max(screen.visibleFrame.minY + 8, min(origin.y, screen.visibleFrame.maxY - height - 8))
                if origin.x + width > screen.visibleFrame.maxX { origin.x = window.convertToScreen(NSRect(origin: NSPoint(x: rect.minX, y: 0), size: .zero)).origin.x - width - 8 }
            }
            self.panel.setFrame(NSRect(origin: origin, size: NSSize(width: width, height: height)), display: true)
            self.panel.orderFront(nil)
        }
        pendingShow = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.45, execute: work)
    }

    func hide() {
        pendingShow?.cancel()
        pendingShow = nil
        panel.orderOut(nil)
    }
}
