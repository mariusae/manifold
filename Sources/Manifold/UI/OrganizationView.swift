import AppKit
import ManifoldCore

/// How the sidebar organizes the graph (DESIGN.md §3.6): the workspaces
/// and their tiles; files under folders under roots, across hosts; and
/// the list over them (Recently Closed).
enum Organization: String, CaseIterable {
    case desk, files
    /// The list at the sidebar's foot (§4): what's closed and not yet
    /// collected.
    case closed
    /// The focused block's properties (⌥⌘I): what it is, where it is,
    /// what keeps it, its links and history, and what can be done with it.
    case inspector

    var title: String {
        switch self {
        case .desk: "Spaces"
        case .files: "Files"
        case .closed: "Recently Closed"
        case .inspector: "Inspector"
        }
    }

    var symbol: String {
        switch self {
        case .desk: Theme.spaceSymbol
        case .files: "folder"
        case .closed: "clock.arrow.circlepath"
        case .inspector: "info.circle"
        }
    }
}

/// What the sidebar can be narrowed to (§3.6), whichever organization it
/// shows: each a test of a block. The rows it admits stay, with the way
/// to each — its host, its space, its folders, a stacked tile's stack —
/// and the rest go (`OrgNode.filtered`).
enum SidebarFilter: String, CaseIterable {
    /// Blocks with a status (§3.7): working, needing you, done or failed.
    case status

    var title: String {
        switch self {
        case .status: "Blocks with a Status"
        }
    }
    /// The bar's button, off and on.
    func image(on: Bool) -> NSImage {
        switch self {
        case .status: Lighthouse.image(on: on)
        }
    }
    /// Said where there's nothing it admits.
    var nothing: String {
        switch self {
        case .status: "No block has a status"
        }
    }

    func admits(_ block: Block) -> Bool {
        switch self {
        case .status:
            switch StatusGlyph.look(of: block) {
            case .working?, .needsYou?, .done?, .failed?: true
            default: false
            }
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
    /// A picture in place of the symbol: a page's site's icon.
    var image: NSImage?
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
    /// In a stack (on the desk): its rows share a faint ground, the top's
    /// first; and one behind the top, set in and dimmer, as out of sight.
    var stack: SelectionRowView.Grouped?
    var behind = false
    /// The same tile shown twice (pinned at the top, and in its stack):
    /// the placement both rows are for, so the one lights with the other.
    var twin: PlacementID?
    /// What the block is doing (§3.7), shown by its name (`StatusMark`).
    var look: StatusGlyph.Look?
    /// What it needs, when it's blocked: the pill's word.
    var blocked: BlockedKind?
    /// A text edited and unsaved: a dot after the name, as on its bar —
    /// amber when the file changed on disk under the edits.
    var dirty = false
    var stale = false
    /// A word at the right, before the pill: how long ago.
    var trailing: String?
    var tooltip: String?
    /// A host's ping times lately, drawn by its name (`Sparkline`).
    var pings: (() -> Sparkline.Pings)?
    /// A tooltip made as it's about to show, over the whole row, for
    /// what changes by the second (how long a host has been connecting).
    var liveTooltip: (() -> String)?
    /// How the row is set: a host's heading, a section's label (a
    /// workspace, a group), a block's row, or a hairline between rows (a
    /// workspace's pinned tiles and the rest).
    enum Style { case host, section, row, divider }
    var style: Style = .row
    /// On the desk: the arrangement this row is, or is a column of.
    var arrangement: BlockID?
    /// On the desk: which column of its arrangement, and the placement shown.
    var column: Int?
    var placement: PlacementID?
    /// A row that does something rather than opening a block (New…).
    var action: (() -> Void)?
    /// What the row puts on the clipboard, a copy button beside it (the
    /// inspector's references, ids, paths).
    var copies: String?
    fileprivate var given: [OrgNode]
    var loadChildren: (() -> [OrgNode])?
    fileprivate var loaded = false

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

    /// The children given, never loading any.
    fileprivate var givenChildren: [OrgNode] { given }

    /// The rows `keep` says to, and the way to each: a row stays if it's
    /// kept or anything under it is; a tile behind in a stack keeps its
    /// stack's top, the two outlined together as the stack is; a hairline
    /// stays only between rows that do; a row's count is of the rows
    /// under it admitted. Rows made for one showing: their children are
    /// pruned in place.
    static func filtered(_ nodes: [OrgNode], keep: (OrgNode) -> Bool) -> [OrgNode] {
        var admitted = 0
        return filtered(nodes, keep: keep, admitted: &admitted)
    }

    private static func filtered(_ nodes: [OrgNode], keep: (OrgNode) -> Bool, admitted: inout Int) -> [OrgNode] {
        var kept = [Bool](repeating: false, count: nodes.count)
        for (i, n) in nodes.enumerated() {
            let own = n.style != .divider && keep(n)
            if own { admitted += 1 }
            if n.hasChildren {
                var under = 0
                n.given = filtered(n.children, keep: keep, admitted: &under)
                n.loadChildren = nil
                n.loaded = true
                if n.count != nil { n.count = under }
                admitted += under
            }
            kept[i] = n.style != .divider && (own || !n.given.isEmpty)
        }
        // Each row's stack (its index among the stacks here), and a kept
        // row behind its top keeps the top.
        var stackOf = [Int?](repeating: nil, count: nodes.count)
        var top: Int?, count = 0
        for (i, n) in nodes.enumerated() {
            guard let s = n.stack else { top = nil; continue }
            if s.first || top == nil { top = i; count += 1 }
            stackOf[i] = count
            if kept[i], let t = top { kept[t] = true }
        }
        // A hairline between kept rows.
        for (i, n) in nodes.enumerated() where n.style == .divider {
            kept[i] = kept[..<i].contains(true) && kept[(i + 1)...].contains(true)
        }
        let out = nodes.indices.filter { kept[$0] }
        // Stacks outlined again around what's left of each: a top alone
        // isn't a stack (a tile alone behind is, as it was).
        for (k, i) in out.enumerated() {
            guard let s = stackOf[i] else { continue }
            let first = k == 0 || stackOf[out[k - 1]] != s
            let last = k == out.count - 1 || stackOf[out[k + 1]] != s
            nodes[i].stack = first && last && !nodes[i].behind ? nil : SelectionRowView.Grouped(first: first, last: last)
        }
        return out.map { nodes[$0] }
    }

    /// Every row under these that has rows under it.
    static func groups(_ nodes: [OrgNode]) -> Set<String> {
        var ids: Set<String> = []
        for n in nodes where !n.given.isEmpty {
            ids.insert(n.id)
            ids.formUnion(groups(n.given))
        }
        return ids
    }

    /// Whether it would draw as another does: what its row shows.
    fileprivate func looksLike(_ o: OrgNode) -> Bool {
        title == o.title && symbol == o.symbol && detail == o.detail && detailSymbol == o.detailSymbol && count == o.count
            && age == o.age && emphasis == o.emphasis && dimmed == o.dimmed && look == o.look && trailing == o.trailing
            && tooltip == o.tooltip && (pings == nil) == (o.pings == nil) && (liveTooltip == nil) == (o.liveTooltip == nil)
            && dirty == o.dirty && stale == o.stale && image === o.image && stack == o.stack && behind == o.behind && twin == o.twin
    }

    /// Takes another's values (the same row made again), its children
    /// left to the caller.
    func take(_ o: OrgNode) {
        block = o.block; title = o.title; symbol = o.symbol; detail = o.detail; detailSymbol = o.detailSymbol
        count = o.count; age = o.age; isGroup = o.isGroup; emphasis = o.emphasis; dimmed = o.dimmed; look = o.look
        trailing = o.trailing; tooltip = o.tooltip; pings = o.pings; liveTooltip = o.liveTooltip; style = o.style
        dirty = o.dirty; stale = o.stale; image = o.image; stack = o.stack; behind = o.behind; twin = o.twin
        arrangement = o.arrangement; column = o.column; placement = o.placement; action = o.action
    }
}

/// What's being dragged over the sidebar.
enum OrgDragItem {
    case block(BlockID)
    case placement(PlacementID)
    case arrangement(BlockID)
    /// A host's row, to reorder the hosts.
    case host(HostID)

    init?(_ pb: NSPasteboard) {
        if let h = pb.string(forType: .manifoldHost) { self = .host(HostID(h)) }
        else if let a = pb.string(forType: .manifoldArrangement).flatMap(BlockID.init(string:)) { self = .arrangement(a) }
        else if let p = pb.string(forType: .manifoldPlacement) { self = .placement(p) }
        else if let b = pb.string(forType: .manifoldBlock).flatMap(BlockID.init(string:)) { self = .block(b) }
        else { return nil }
    }
}

protocol OrganizationViewDelegate: AnyObject {
    /// A row ⇧-dragged: not the block to move but what it stands for (its
    /// path, its file, its link), as a tile's ⇧-dragged pill is.
    func organizationPathItem(for block: BlockID, modifiers: NSEvent.ModifierFlags) -> NSPasteboardItem?
    /// Files dropped on a workspace's row: opened in that workspace.
    func organizationOpen(files: [String], in workspace: BlockID)
    /// A row was clicked: show its block here, or beside (§3.1); go to
    /// an arrangement; focus a column.
    func organizationOpen(_ node: OrgNode, modifiers: NSEvent.ModifierFlags)
    /// A host's row was clicked: the inspector shows the host (as it
    /// shows the focused tile, until the focus moves).
    func organizationInspect(host: String)
    /// A row was double-clicked; true if that meant something (naming an
    /// arrangement), else the row opens or closes.
    func organizationActivate(_ node: OrgNode) -> Bool
    /// The pointer rests on a row: its card, or none.
    func organizationHover(_ node: OrgNode?, at rect: NSRect, in view: NSView)
    func organizationMenu(for node: OrgNode) -> NSMenu?
    /// Something dragged onto a row, or between the rows under `node`
    /// (nil for the top level) at `index`.
    func organizationCanDrop(_ item: OrgDragItem, onto node: OrgNode?, at index: Int) -> Bool
    /// `copy`: ⌥ held — a block dragged to another workspace is shown
    /// there too, not taken from where it was.
    func organizationDrop(_ item: OrgDragItem, onto node: OrgNode?, at index: Int, copy: Bool) -> Bool
    func organizationDragChanged(_ dragging: Bool)
    /// A drag rested on a workspace's row: that workspace, opened, so the
    /// block can be dropped where it's wanted in it (a folder sprung open).
    func organizationSpring(_ node: OrgNode)
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
    /// Flat: no room kept for a chevron, every row from the left edge.
    var flat = false

    /// Flat, a chevron only on a section with rows under it (a workspace's
    /// label), small, at the left: closed by hand, it stays closed.
    override func frameOfOutlineCell(atRow row: Int) -> NSRect {
        guard flat else { return super.frameOfOutlineCell(atRow: row) }
        guard let n = item(atRow: row) as? OrgNode, n.style == .section, n.hasChildren else { return .zero }
        let r = rect(ofRow: row)
        return NSRect(x: 4, y: r.minY + (r.height - 12) / 2, width: 12, height: 12)
    }

    override func frameOfCell(atColumn column: Int, row: Int) -> NSRect {
        guard flat, column == 0 else { return super.frameOfCell(atColumn: column, row: row) }
        // Set in from the row's highlight (the source list's own inset), so
        // a symbol sits inside it with room, as the text does at the right.
        let r = rect(ofRow: row)
        // A host's heading sits out at the left, under it its workspaces and blocks.
        let x: CGFloat = (item(atRow: row) as? OrgNode)?.style == .host ? 0 : 14
        return NSRect(x: x, y: r.minY, width: max(0, bounds.width - 14 - x), height: r.height)
    }

    /// A drag gone from the rows, or let go on them.
    var onDragGone: (() -> Void)?
    override func draggingExited(_ sender: NSDraggingInfo?) {
        super.draggingExited(sender)
        onDragGone?()
    }

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
    private let scroll = ClippingScrollView()
    private let outline = DeepOutlineView()
    private var roots: [OrgNode] = []
    private var expanded: Set<String> = []
    private var expandedByDefault: Set<String> = []
    /// Rows closed by hand: remembered (the client's state keeps them).
    var collapsedByHand: Set<String> = []
    /// While a filter shows: what was open and closed by hand before it.
    private var unfiltered: (open: Set<String>, closed: Set<String>)?
    var onCollapsedChanged: ((Set<String>) -> Void)?
    private var trackedRow: Int = -1
    private var selecting = false
    /// Flat (§3.5): no chevrons and no indentation — sections (hosts,
    /// workspaces, groups) are labels that open and close when clicked,
    /// and a block's row has two lines when it has something to say.
    var flat = false {
        didSet {
            if flat != oldValue {
                outline.indentationPerLevel = flat ? 0 : 14
                outline.flat = flat
            }
        }
    }

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
        // Things too (words, links, pictures), only to spring spaces open.
        outline.registerForDraggedTypes([.manifoldArrangement, .manifoldPlacement, .manifoldBlock, .manifoldHost] + Dragged.types)
        outline.setDraggingSourceOperationMask(.move, forLocal: true)
        outline.draggingDestinationFeedbackStyle = .regular
        outline.onDragGone = { [weak self] in self?.stopSpring() }
        scroll.documentView = outline
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        addSubview(scroll)
        // The host's heading, kept at the top while its rows scroll under it.
        scroll.wantsLayer = true
        stickyHost.isHidden = true
        stickyHost.onClick = { [weak self] in self?.revealStickyHost() }
        addSubview(stickyHost)
        scroll.contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(forName: NSView.boundsDidChangeNotification, object: scroll.contentView, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.updateStickyHost() }
        }
    }

    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        scroll.frame = bounds
        outline.tableColumns[0].width = scroll.contentSize.width
        outline.sizeLastColumnToFit()
        updateStickyHost()
    }

    // MARK: The host's heading, kept at the top

    /// The heading of the host whose rows are at the top, kept there while
    /// they're scrolled past it, so which host they're on always shows; the
    /// next host's heading pushes it up as it comes. The sidebar may be clear
    /// over the window's backdrop, so the heading can't cover the rows under
    /// it: they fade out there instead (a mask on the list).
    private let stickyHost = StickyHostView()
    private let stickyMask = CAGradientLayer()
    private var stickyRow = -1

    private func updateStickyHost(again: Bool = false) {
        let top = scroll.contentView.bounds.minY
        let first = outline.row(at: NSPoint(x: 1, y: top + 1))
        // The host the top row is under, its own row scrolled past.
        var hostRow = -1
        if first >= 0 {
            var item = outline.item(atRow: first)
            while let n = item as? OrgNode {
                if n.style == .host { hostRow = outline.row(forItem: n); break }
                item = outline.parent(forItem: n)
            }
        }
        guard hostRow >= 0, let host = outline.item(atRow: hostRow) as? OrgNode, outline.rect(ofRow: hostRow).minY < top - 0.5 else {
            stickyRow = -1
            if !stickyHost.isHidden { stickyHost.isHidden = true }
            if scroll.layer?.mask != nil { scroll.layer?.mask = nil }
            return
        }
        stickyRow = hostRow
        let h = outline.rect(ofRow: hostRow).height
        // The next host's heading, come within a heading of the top, pushes it up.
        var push: CGFloat = 0
        let shown = outline.rows(in: scroll.contentView.documentVisibleRect)
        for r in max(first + 1, shown.location)..<min(outline.numberOfRows, NSMaxRange(shown) + 1) {
            guard (outline.item(atRow: r) as? OrgNode)?.style == .host else { continue }
            push = max(0, h - (outline.rect(ofRow: r).minY - top))
            break
        }
        stickyHost.show(host, flat: flat, again: again)
        stickyHost.frame = NSRect(x: 0, y: bounds.maxY - h + push, width: max(0, outline.bounds.width - 14), height: h)
        stickyHost.isHidden = false
        // The rows under it faded out: clear as far as its bottom edge, then
        // in over a few points.
        guard let layer = scroll.layer else { return }
        let H = max(layer.bounds.height, 1), band = max(0, h - push), fade: CGFloat = 8
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        stickyMask.frame = layer.bounds
        stickyMask.colors = [NSColor.clear.cgColor, NSColor.clear.cgColor, NSColor.black.cgColor, NSColor.black.cgColor]
        stickyMask.locations = [0, NSNumber(value: Double(band / H)), NSNumber(value: Double(min(1, (band + fade) / H))), 1]
        // From the top down: the list's layer is flipped (its y goes down,
        // as its view's does), and the mask is drawn in its terms.
        let down = layer.contentsAreFlipped()
        stickyMask.startPoint = CGPoint(x: 0.5, y: down ? 0 : 1)
        stickyMask.endPoint = CGPoint(x: 0.5, y: down ? 1 : 0)
        if layer.mask !== stickyMask { layer.mask = stickyMask }
        CATransaction.commit()
    }

    /// The kept heading clicked: its host's own row scrolled back to the top.
    private func revealStickyHost() {
        guard stickyRow >= 0 else { return }
        if let node = stickyHost.node, node.id.hasPrefix("host:") { delegate?.organizationInspect(host: String(node.id.dropFirst(5))) }
        scroll.contentView.scroll(to: NSPoint(x: 0, y: outline.rect(ofRow: stickyRow).minY))
        scroll.reflectScrolledClipView(scroll.contentView)
    }

    /// "sticky": the heading kept at the top, if any; "sticky <y>": the list
    /// scrolled to y first.
    func debugSticky(_ arg: String) -> String {
        if let y = Double(arg) {
            scroll.contentView.scroll(to: NSPoint(x: 0, y: y))
            scroll.reflectScrolledClipView(scroll.contentView)
        }
        guard !stickyHost.isHidden else { return "none (scrolled to \(Int(scroll.contentView.bounds.minY)))" }
        if arg == "mask" {
            // Where the mask is clear, in the list's own terms: a point near its
            // top and one near its bottom, each converted to the mask's layer.
            guard let layer = scroll.layer, let mask = layer.mask as? CAGradientLayer else { return "no mask" }
            return "flipped view \(scroll.isFlipped) layer \(layer.isGeometryFlipped) contentsFlipped \(layer.contentsAreFlipped()) mask \(mask.isGeometryFlipped) height \(layer.bounds.height) "
                + "start \(mask.startPoint) locations \(mask.locations ?? [])"
        }
        return "\(stickyHost.debugState) at y \(Int(stickyHost.frame.minY)) of \(Int(bounds.height)) (scrolled to \(Int(scroll.contentView.bounds.minY)))"
    }

    /// Shows a tree; rows open as they were, or as `openByDefault` says
    /// the first time; the row `selected` is highlighted. `openAll`: every
    /// row open, whatever was closed by hand (a filter's: the way to each
    /// row it admits shown whole).
    func show(_ nodes: [OrgNode], openByDefault: Set<String> = [], selected: String? = nil, openAll: Bool = false) {
        // Opened for a filter, then as it was: what was open and closed
        // before kept aside, and back after (nothing opened or closed
        // while filtered is remembered).
        if openAll, unfiltered == nil {
            unfiltered = (expanded, collapsedByHand)
            collapsedByHand = []
        } else if !openAll, let (open, closed) = unfiltered {
            unfiltered = nil
            expanded = open
            collapsedByHand = closed
            roots = []
        }
        let openByDefault = openAll ? OrgNode.groups(nodes) : openByDefault
        // The same rows in the same places (most of what comes, as the
        // sidebar is made again after each change): the new values taken
        // over and only the rows that look different redrawn — a reload
        // re-expands every open group, row by row.
        if !roots.isEmpty, openByDefault == expandedByDefault, Self.sameShape(roots, nodes) {
            var changed: [OrgNode] = []
            Self.takeOver(roots, from: nodes, changed: &changed)
            for n in changed {
                outline.reloadItem(n, reloadChildren: false)
                let row = outline.row(forItem: n)
                guard row >= 0 else { continue }
                outline.noteHeightOfRows(withIndexesChanged: [row])
                // The row's view stays: its mark (the current workspace's) set again.
                (outline.rowView(atRow: row, makeIfNecessary: false) as? SelectionRowView)?.marked = n.style == .section && n.emphasis && n.arrangement != nil
            }
            select(selected)
            // The kept heading as its host's row now says (its pings, its state).
            if !stickyHost.isHidden { updateStickyHost(again: true) }
            return
        }
        // Rows come or gone (a file opened, a tile closed): those rows put
        // in or taken out, the rest kept as they are and given their new
        // values — a reload made every row shown again, its view and its
        // layout (some 50 ms a file opened).
        if !roots.isEmpty, openByDefault == expandedByDefault, mergeable(roots, nodes) {
            var changed: [OrgNode] = [], inserted: [OrgNode] = []
            outline.beginUpdates()
            merge(nodes, into: nil, changed: &changed, inserted: &inserted)
            func expandNew(_ list: [OrgNode]) {
                for n in list where expanded.contains(n.id) || (expandedByDefault.contains(n.id) && !collapsedByHand.contains(n.id)) {
                    outline.expandItem(n)
                    expandNew(n.children)
                }
            }
            expandNew(inserted)
            outline.endUpdates()
            for n in changed {
                outline.reloadItem(n, reloadChildren: false)
                let row = outline.row(forItem: n)
                guard row >= 0 else { continue }
                outline.noteHeightOfRows(withIndexesChanged: [row])
                (outline.rowView(atRow: row, makeIfNecessary: false) as? SelectionRowView)?.marked = n.style == .section && n.emphasis && n.arrangement != nil
            }
            select(selected)
            DispatchQueue.main.async { [weak self] in self?.updateStickyHost() }
            return
        }
        roots = nodes
        expandedByDefault = openByDefault
        // Where it was scrolled to, kept: reloaded, its rows are closed for
        // a moment, the list short, and it would be back at the top.
        let scrolled = scroll.contentView.bounds.origin
        defer {
            scroll.contentView.scroll(to: scrolled)
            scroll.reflectScrolledClipView(scroll.contentView)
        }
        outline.reloadData()
        func expandAll(_ list: [OrgNode]) {
            for n in list where expanded.contains(n.id) || (expandedByDefault.contains(n.id) && !collapsedByHand.contains(n.id)) {
                outline.expandItem(n)
                expandAll(n.children)
            }
        }
        // As one change: each group opened alone has the outline measure
        // every row again (groups × rows, 30 ms and more for a full desk).
        outline.beginUpdates()
        expandAll(nodes)
        outline.endUpdates()
        select(selected)
        DispatchQueue.main.async { [weak self] in self?.updateStickyHost() }
    }

    /// The row `selected` highlighted, or none.
    // MARK: Going to a space

    /// A space's row, where it shows (the outline's terms, top down).
    func spaceRow(_ id: BlockID) -> NSRect? {
        for r in 0..<outline.numberOfRows {
            if let n = outline.item(atRow: r) as? OrgNode, n.style == .section, n.arrangement == id { return outline.rect(ofRow: r) }
        }
        return nil
    }

    /// A tile's row (its space's, the space folded), in `view`'s terms —
    /// if it's in sight: the sidebar shown and the row not scrolled away.
    func row(of placement: PlacementID, in space: BlockID, in view: NSView) -> NSRect? {
        guard window != nil, !isHiddenOrHasHiddenAncestor else { return nil }
        var found: NSRect?
        for r in 0..<outline.numberOfRows {
            guard let n = outline.item(atRow: r) as? OrgNode else { continue }
            if n.placement == placement, n.arrangement == nil || n.arrangement == space { found = outline.rect(ofRow: r); break }
            if found == nil, n.style == .section, n.arrangement == space { found = outline.rect(ofRow: r) }
        }
        guard let r = found, scroll.contentView.documentVisibleRect.intersects(r) else { return nil }
        let shown = view.convert(r, from: outline)
        return view.bounds.intersects(shown) ? shown : nil
    }

    /// Going from one space to another: a band in the tint glides from the
    /// one's row to the other's, as the window's grids slide past, and
    /// fades there — where you've gone, in the list you went by. With less
    /// motion asked for, it only lights there.
    func travel(from old: BlockID?, to new: BlockID) {
        guard window != nil, !isHiddenOrHasHiddenAncestor, let end = spaceRow(new) else { return }
        // Sprung open by a drag: its own band is there already.
        if let s = sprung, s.space == new, -s.at.timeIntervalSinceNow < 2 { sprung = nil; return }
        traveller?.removeFromSuperview()
        let band = TravelBand()
        traveller = band
        outline.addSubview(band)
        let start = old.flatMap(spaceRow) ?? end
        band.frame = Motion.reduced ? end : start
        band.alphaValue = 1
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = start == end ? 0 : Motion.spatial
            ctx.timingFunction = Motion.travel
            band.animator().frame = end
        }, completionHandler: { [weak band] in
            NSAnimationContext.runAnimationGroup({ ctx in
                ctx.duration = 0.6 * Motion.slowdown
                ctx.timingFunction = Motion.disappear
                band?.animator().alphaValue = 0
            }, completionHandler: { [weak self, weak band] in
                band?.removeFromSuperview()
                if self?.traveller === band { self?.traveller = nil }
            })
        })
    }
    private var traveller: TravelBand?

    /// Debugging: where the band is, if it's on its way.
    var debugTraveller: String {
        guard let t = traveller else { return "none" }
        let f = t.layer?.presentation()?.frame ?? t.frame
        return "band y=\(Int(f.minY)) h=\(Int(f.height)) alpha=\(String(format: "%.2f", t.layer?.presentation()?.opacity ?? Float(t.alphaValue)))"
    }

    /// Rows scrolled into view, the last one given surely (a ⌘` walk's
    /// space, and its focused tile under it if they fit).
    func reveal(_ ids: String?...) {
        for id in ids.compactMap({ $0 }) {
            guard let row = (0..<outline.numberOfRows).first(where: { (outline.item(atRow: $0) as? OrgNode)?.id == id }) else { continue }
            outline.scrollRowToVisible(row)
        }
    }

    private func select(_ selected: String?) {
        selecting = true
        defer { selecting = false }
        if let selected, let row = (0..<outline.numberOfRows).first(where: { (outline.item(atRow: $0) as? OrgNode)?.id == selected }) {
            if outline.selectedRow != row { outline.selectRowIndexes([row], byExtendingSelection: false) }
        } else if outline.selectedRow >= 0 {
            outline.deselectAll(nil)
        }
    }

    /// Two trees of the same rows, in the same places, none loading its
    /// children as it's opened.
    private static func sameShape(_ a: [OrgNode], _ b: [OrgNode]) -> Bool {
        guard a.count == b.count else { return false }
        for (x, y) in zip(a, b) {
            guard x.id == y.id, x.style == y.style, x.isGroup == y.isGroup, x.loadChildren == nil, y.loadChildren == nil,
                  sameShape(x.givenChildren, y.givenChildren) else { return false }
        }
        return true
    }

    /// Whether `new` can be merged into `old` row by row: no rows loaded
    /// when opened, no id twice among siblings, and every row kept (by its
    /// id) of the same style and kind.
    private func mergeable(_ old: [OrgNode], _ new: [OrgNode]) -> Bool {
        let oldIDs = old.map(\.id), newIDs = new.map(\.id)
        guard Set(oldIDs).count == oldIDs.count, Set(newIDs).count == newIDs.count else { return false }
        let byID = Dictionary(uniqueKeysWithValues: old.map { ($0.id, $0) })
        for n in new {
            guard n.loadChildren == nil else { return false }
            if let o = byID[n.id] {
                guard o.loadChildren == nil, o.style == n.style, o.isGroup == n.isGroup, mergeable(o.givenChildren, n.givenChildren) else { return false }
            }
        }
        return true
    }

    /// `new` merged into the children of `parent` (the roots for nil): the
    /// rows gone taken out, the new put in — the outline told of each as
    /// it happens — and those kept given their new values, the ones that
    /// look different noted in `changed`, all the way down.
    private func merge(_ new: [OrgNode], into parent: OrgNode?, changed: inout [OrgNode], inserted: inout [OrgNode]) {
        var current = parent?.given ?? roots
        func set(_ list: [OrgNode]) { if let parent { parent.given = list } else { roots = list } }
        let diff = new.map(\.id).difference(from: current.map(\.id))
        for case let .remove(offset, _, _) in diff.removals.reversed() {
            current.remove(at: offset)
            set(current)
            outline.removeItems(at: [offset], inParent: parent, withAnimation: [])
        }
        for case let .insert(offset, _, _) in diff.insertions {
            current.insert(new[offset], at: offset)
            set(current)
            outline.insertItems(at: [offset], inParent: parent, withAnimation: [])
            inserted.append(new[offset])
        }
        for (o, n) in zip(current, new) where o !== n {
            if !o.looksLike(n) { changed.append(o) }
            o.take(n)
            merge(n.givenChildren, into: o, changed: &changed, inserted: &inserted)
        }
    }

    private static func takeOver(_ old: [OrgNode], from new: [OrgNode], changed: inout [OrgNode]) {
        for (o, n) in zip(old, new) {
            if !o.looksLike(n) { changed.append(o) }
            o.take(n)
            takeOver(o.givenChildren, from: n.givenChildren, changed: &changed)
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
    // Flat, the chevron is hidden by its frame (DeepOutlineView), not by
    // saying it shouldn't show: that makes the outline refuse to collapse.

    func outlineView(_ outlineView: NSOutlineView, heightOfRowByItem item: Any) -> CGFloat {
        guard let n = item as? OrgNode else { return 26 }
        switch n.style {
        case .host: return 30
        case .section: return 24
        case .row: return flat && !n.detail.isEmpty ? 40 : 26
        case .divider: return 9
        }
    }

    func outlineView(_ outlineView: NSOutlineView, rowViewForItem item: Any) -> NSTableRowView? {
        let v = SelectionRowView()
        // The current workspace's label wears a bar at its left edge.
        if let n = item as? OrgNode {
            v.marked = n.style == .section && n.emphasis && n.arrangement != nil
            v.grouped = n.stack
            // A twin's hover lights the other row of the same tile.
            if let twin = n.twin {
                v.onHover = { [weak self, weak v] on in self?.echo(twin, except: v, on) }
            }
        }
        return v
    }

    /// The other rows of a twin lit (or not) with the one hovered.
    private func echo(_ twin: PlacementID, except row: SelectionRowView?, _ on: Bool) {
        for r in 0..<outline.numberOfRows {
            guard let n = outline.item(atRow: r) as? OrgNode, n.twin == twin,
                  let v = outline.rowView(atRow: r, makeIfNecessary: false) as? SelectionRowView, v !== row else { continue }
            v.echo = on
        }
    }

    func outlineViewItemDidExpand(_ notification: Notification) {
        DispatchQueue.main.async { [weak self] in self?.updateStickyHost() }
        if let n = notification.userInfo?["NSObject"] as? OrgNode {
            expanded.insert(n.id)
            if collapsedByHand.remove(n.id) != nil, unfiltered == nil { onCollapsedChanged?(collapsedByHand) }
        }
    }

    func outlineViewItemDidCollapse(_ notification: Notification) {
        DispatchQueue.main.async { [weak self] in self?.updateStickyHost() }
        if let n = notification.userInfo?["NSObject"] as? OrgNode {
            expanded.remove(n.id)
            collapsedByHand.insert(n.id)
            if unfiltered == nil { onCollapsedChanged?(collapsedByHand) }
        }
    }

    func outlineView(_ outlineView: NSOutlineView, shouldSelectItem item: Any) -> Bool {
        guard let n = item as? OrgNode else { return false }
        return n.style == .row && (n.block != nil || n.action != nil)
    }

    func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        guard let node = item as? OrgNode else { return nil }
        let cell = outlineView.makeView(withIdentifier: .init("org"), owner: nil) as? OrgRowView ?? OrgRowView()
        cell.identifier = .init("org")
        cell.flat = flat
        cell.show(node)
        return cell
    }

    // MARK: Clicks

    @objc private func rowClicked() {
        let row = outline.clickedRow
        guard row >= 0, let node = outline.item(atRow: row) as? OrgNode else { return }
        if let action = node.action {
            action()
        } else if node.style == .section, node.block != nil, node.arrangement != nil, node.column == nil {
            // A workspace's label: gone to. (Its chevron opens and closes it.)
            delegate?.organizationOpen(node, modifiers: NSApp.currentEvent?.modifierFlags ?? [])
        } else if node.style != .row, node.hasChildren {
            // A host's heading, a group's label: clicked, it opens or closes
            // (a host's shown in the inspector too).
            if node.style == .host, node.id.hasPrefix("host:") { delegate?.organizationInspect(host: String(node.id.dropFirst(5))) }
            if outline.isItemExpanded(node) { outline.collapseItem(node) } else { outline.expandItem(node) }
        } else if node.block != nil {
            delegate?.organizationOpen(node, modifiers: NSApp.currentEvent?.modifierFlags ?? [])
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
        // A host's row drags the host, to put it elsewhere among them.
        if let node = item as? OrgNode, node.style == .host, node.id.hasPrefix("host:") {
            let pb = NSPasteboardItem()
            pb.setString(String(node.id.dropFirst(5)), forType: .manifoldHost)
            return pb
        }
        guard let node = item as? OrgNode, let block = node.block else { return nil }
        // ⇧: what it stands for, for a terminal, an editor, a note, a tile, the Finder.
        let mods = NSEvent.modifierFlags
        if mods.contains(.shift) {
            pathDrag = true
            return delegate?.organizationPathItem(for: block, modifiers: mods)
        }
        pathDrag = false
        let pb = NSPasteboardItem()
        pb.setString(block.description, forType: .manifoldBlock)
        if let a = node.arrangement, node.column == nil { pb.setString(a.description, forType: .manifoldArrangement) }
        if let p = node.placement { pb.setString(p, forType: .manifoldPlacement) }
        return pb
    }

    /// The drag under way is a ⇧-drag (a path, a link): the views under the
    /// grid take it, so the grid's catcher stays out of the way.
    private var pathDrag = false

    func outlineView(_ outlineView: NSOutlineView, draggingSession session: NSDraggingSession, willBeginAt screenPoint: NSPoint, forItems draggedItems: [Any]) {
        HoverCard.shared.hide()
        if !pathDrag { delegate?.organizationDragChanged(true) }
        DragPill.dress(session, from: outlineView, at: screenPoint)
        DragCursor.began()
    }

    func outlineView(_ outlineView: NSOutlineView, draggingSession session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
        DragCursor.ended()
        stopSpring()
        delegate?.organizationDragChanged(false)
        pathDrag = false
    }

    func outlineView(_ outlineView: NSOutlineView, draggingSession session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        if pathDrag { return [.copy, .link, .generic] }
        return context == .withinApplication ? [.move, .copy] : []
    }

    /// This Mac's files dragged (from the Finder, a folder's tile): their
    /// paths, if no block is.
    private static func files(_ pb: NSPasteboard) -> [String] {
        guard OrgDragItem(pb) == nil, let d = Dragged(pb), d.things.allSatisfy({ $0.block == nil }) else { return [] }
        return d.things.compactMap { $0.file?.host == Drags.localHost ? $0.file?.path : nil }
    }

    func outlineView(_ outlineView: NSOutlineView, validateDrop info: NSDraggingInfo, proposedItem item: Any?, proposedChildIndex index: Int) -> NSDragOperation {
        springUnder(info)
        // Files onto a workspace's row: opened there.
        if !Self.files(info.draggingPasteboard).isEmpty {
            guard let node = item as? OrgNode, node.arrangement != nil, node.column == nil, index == NSOutlineViewDropOnItemIndex else { return [] }
            return .copy
        }
        guard let drag = OrgDragItem(info.draggingPasteboard) else { return [] }
        let node = item as? OrgNode
        guard delegate?.organizationCanDrop(drag, onto: node, at: index) == true else { return [] }
        let isBlock: Bool
        switch drag {
        case .block, .placement: isBlock = true
        case .arrangement, .host: isBlock = false
        }
        // ⌥: the plus by the pointer, as when copying a file.
        return isBlock && Self.copying(info) ? .copy : .move
    }

    func outlineView(_ outlineView: NSOutlineView, acceptDrop info: NSDraggingInfo, item: Any?, childIndex index: Int) -> Bool {
        stopSpring()
        let files = Self.files(info.draggingPasteboard)
        if !files.isEmpty, let node = item as? OrgNode, let w = node.arrangement {
            delegate?.organizationOpen(files: files, in: w)
            return true
        }
        guard let drag = OrgDragItem(info.draggingPasteboard) else { return false }
        return delegate?.organizationDrop(drag, onto: item as? OrgNode, at: index, copy: Self.copying(info)) ?? false
    }

    /// Whether a drag copies: ⌥ held (the source then offers only a copy).
    static func copying(_ info: NSDraggingInfo) -> Bool {
        NSEvent.modifierFlags.contains(.option) || info.draggingSourceOperationMask == .copy
    }

    // MARK: Spring-loaded spaces

    private var springNode: String?
    private var springWork: DispatchWorkItem?
    private var springBand: SpringBand?
    /// A space just sprung open: its band already marks it, so the band
    /// that goes from space to space doesn't come to it too (`travel`).
    private var sprung: (space: BlockID, at: Date)?
    /// Debugging: a drag held over the rows, whatever the mouse does.
    var debugHeld = false

    /// How long a drag rests on a space's row before the space opens: the
    /// system's spring-loading delay (Accessibility ▸ Pointer Control), as
    /// Finder's folders have it; nil with spring-loading turned off there.
    static var springDelay: TimeInterval? {
        let d = UserDefaults.standard
        if d.object(forKey: "com.apple.springing.enabled") as? Bool == false { return nil }
        return max(0.1, d.object(forKey: "com.apple.springing.delay") as? Double ?? 0.5)
    }

    /// A drag over the rows, whatever it carries (a tile, a file, words, a
    /// link): resting on another space's row, a band in the tint fills the
    /// row from the left, blinks, and the space opens under it, as Finder
    /// springs a folder open — to be dropped where it's wanted in it. Not
    /// while spaces or hosts are being reordered.
    private func springUnder(_ info: NSDraggingInfo) {
        switch OrgDragItem(info.draggingPasteboard) {
        case .arrangement?, .host?: return stopSpring()
        default: break
        }
        let row = outline.row(at: outline.convert(info.draggingLocation, from: nil))
        guard row >= 0, let node = outline.item(atRow: row) as? OrgNode else { return stopSpring() }
        springLoad(node, row: row)
    }

    private func springLoad(_ node: OrgNode, row: Int) {
        // A space's row (the one shown wears emphasis), not a column's.
        guard node.arrangement != nil, node.column == nil, !node.emphasis, let delay = Self.springDelay else { return stopSpring() }
        guard springNode != node.id else { return }
        stopSpring()
        springNode = node.id
        let band = SpringBand(frame: outline.rect(ofRow: row))
        outline.addSubview(band)
        springBand = band
        band.charge(over: delay)
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.springNode == node.id, self.stillOver(node) else { self?.stopSpring(); return }
            band.blink { [weak self] in
                guard let self, self.springNode == node.id, self.stillOver(node) else { self?.stopSpring(); return }
                self.springNode = nil
                self.springWork = nil
                self.springBand = nil
                if let a = node.arrangement { self.sprung = (a, Date()) }
                self.delegate?.organizationSpring(node)
                band.fade(over: 0.6 * Motion.slowdown)
            }
        }
        springWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    /// The drag still on, over that row.
    private func stillOver(_ node: OrgNode) -> Bool {
        if debugHeld { return true }
        guard NSEvent.pressedMouseButtons & 1 != 0, let window else { return false }
        let row = outline.row(at: outline.convert(window.mouseLocationOutsideOfEventStream, from: nil))
        return row >= 0 && (outline.item(atRow: row) as? OrgNode)?.id == node.id
    }

    /// The drag gone from the row (or the rows, or let go): its band goes.
    private func stopSpring() {
        springNode = nil
        springWork?.cancel()
        springWork = nil
        springBand?.fade(over: Motion.fast)
        springBand = nil
    }

    /// Debugging: a drag resting on row `row` (held, whatever the mouse
    /// does, until "off"), or how its band is.
    func debugSpring(_ arg: String) -> String {
        if arg == "off" { debugHeld = false; stopSpring(); return "off" }
        if let row = Int(arg), row >= 0, row < outline.numberOfRows, let node = outline.item(atRow: row) as? OrgNode {
            debugHeld = true
            springLoad(node, row: row)
        }
        guard let band = springBand else { return "none" }
        return "band \(springNode ?? "-") \(band.debugState)"
    }

    // MARK: Debugging aids

    /// The rows as shown, one per line: depth, id, title.
    func debugRows() -> String {
        (0..<outline.numberOfRows).compactMap { row in
            guard let n = outline.item(atRow: row) as? OrgNode else { return nil }
            return "\(row) \(String(repeating: "  ", count: outline.level(forRow: row)))\(n.id) | \(n.title)\(n.detail.isEmpty ? "" : " · " + n.detail)\(n.dimmed ? " [dim]" : "")\(n.look.map { " [\($0)]" } ?? "")\(n.dirty ? " [dirty]" : "")\(n.image != nil ? " [icon]" : "")\(n.stack.map { " [stack\($0.first ? " first" : "")\($0.last ? " last" : "")]" } ?? "")\(n.behind ? " [behind]" : "")"
        }.joined(separator: "\n")
    }

    /// As the pointer moving onto the row (-1: off every row), through the
    /// same path a real move takes.
    func debugHover(row: Int) -> String {
        let p = row >= 0 ? NSPoint(x: outline.rect(ofRow: row).midX, y: outline.rect(ofRow: row).midY) : NSPoint(x: -100, y: -100)
        // Row -2: the host's heading kept at the top.
        let at = row == Self.stickyRow ? convert(NSPoint(x: stickyHost.frame.midX, y: stickyHost.frame.midY), to: nil) : outline.convert(p, to: nil)
        guard let e = NSEvent.mouseEvent(with: .mouseMoved, location: at, modifierFlags: [],
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

    /// As the chevron closing a row: remembered as closed by hand.
    func debugCollapse(row: Int) -> String {
        guard let node = outline.item(atRow: row) as? OrgNode else { return "no row" }
        outline.collapseItem(node)
        return "collapsed, \(outline.numberOfRows) rows; by hand: \(collapsedByHand.sorted())"
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
        if node.block != nil { delegate?.organizationOpen(node, modifiers: command ? [.command] : []); return "opened" }
        if node.style == .host, node.id.hasPrefix("host:") { delegate?.organizationInspect(host: String(node.id.dropFirst(5))) }
        if node.hasChildren {
            let was = outline.isItemExpanded(node)
            if was { outline.collapseItem(node) } else { outline.expandItem(node) }
            return "toggled: was \(was) now \(outline.isItemExpanded(node)) rows \(outline.numberOfRows) expanded=\(expanded.contains(node.id)) byHand=\(collapsedByHand.contains(node.id)) default=\(expandedByDefault.contains(node.id))"
        }
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

    /// What `trackedRow` is while the pointer's on the kept heading.
    private static let stickyRow = -2

    override func mouseMoved(with event: NSEvent) {
        // The host's heading kept at the top: as its own row, its card shown.
        if !stickyHost.isHidden, stickyHost.frame.contains(convert(event.locationInWindow, from: nil)), let node = stickyHost.node {
            guard trackedRow != Self.stickyRow else { return }
            trackedRow = Self.stickyRow
            hoverReveal(row: -1)
            stickyHost.hovered = true
            delegate?.organizationHover(node, at: convert(stickyHost.frame, to: nil), in: self)
            return
        }
        stickyHost.hovered = false
        let p = outline.convert(event.locationInWindow, from: nil)
        let row = outline.row(at: p)
        guard row != trackedRow else { return }
        trackedRow = row
        hoverReveal(row: row)
        // A block's row has its card; a host's, its machine and its link.
        if row >= 0, let node = outline.item(atRow: row) as? OrgNode, node.block != nil || node.pings != nil || node.id.hasPrefix("host:") {
            delegate?.organizationHover(node, at: outline.convert(outline.rect(ofRow: row), to: nil), in: self)
        } else {
            delegate?.organizationHover(nil, at: .zero, in: self)
        }
    }

    override func mouseExited(with event: NSEvent) {
        trackedRow = -1
        stickyHost.hovered = false
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

/// Says a row's live tooltip when AppKit asks, as it's about to show.
private final class LiveTip: NSObject, NSViewToolTipOwner {
    var text: (() -> String)?

    func view(_ view: NSView, stringForToolTip tag: NSView.ToolTipTag, point: NSPoint, userData data: UnsafeMutableRawPointer?) -> String {
        text?() ?? ""
    }
}

/// A count in a capsule, its digits centred both ways.
final class CountPill: NSView {
    static let height = Pill.height
    var stringValue = "" { didSet { if stringValue != oldValue { needsDisplay = true } } }
    var wantedWidth: CGFloat { Pill.size(stringValue).width }
    override func draw(_ dirtyRect: NSRect) { Pill.draw(stringValue, in: bounds) }
}

/// A row: symbol, name, a count in a pill, a detail in grey; faded by age.
/// A host's heading kept at the top of the sidebar (`updateStickyHost`):
/// its row's own view, as the list sets it; clicked, its row is scrolled to.
final class StickyHostView: NSView {
    var onClick: (() -> Void)?
    private let row = OrgRowView()
    private var shown: OrgNode?

    override init(frame: NSRect) {
        super.init(frame: frame)
        addSubview(row)
    }

    required init?(coder: NSCoder) { fatalError() }

    /// The host's row it's a copy of.
    var node: OrgNode? { shown }
    /// Under the pointer, as its row would be: the same band.
    var hovered = false { didSet { if hovered != oldValue { needsDisplay = true } } }

    override func draw(_ dirtyRect: NSRect) {
        guard hovered else { return }
        Theme.hover.setFill()
        Flat.rowBand(bounds).fill()
    }

    /// `again`: its row's values changed in place (the same node, taken over).
    func show(_ node: OrgNode, flat: Bool, again: Bool = false) {
        row.flat = flat
        if again || node !== shown { row.show(node) }
        shown = node
    }

    override func layout() {
        super.layout()
        row.frame = bounds
    }

    // The heading's own parts (its sparkline's tip) aside, a click is the
    // heading's.
    override func hitTest(_ point: NSPoint) -> NSView? {
        frame.contains(point) ? self : nil
    }

    override func mouseDown(with event: NSEvent) {}
    override func mouseUp(with event: NSEvent) {
        if bounds.contains(convert(event.locationInWindow, from: nil)) { onClick?() }
    }

    var debugState: String { shown.map { "host \($0.title)" } ?? "nothing" }
}

final class OrgRowView: NSTableCellView {
    private let icon = NSImageView()
    private let name = NSTextField(labelWithString: "")
    private let count = CountPill()
    private let detail = NSTextField(labelWithString: "")
    private let detailIcon = NSImageView()
    private let glyph = StatusGlyph()
    private let pill = StatusPillView()
    private lazy var shimmer = Shimmer(name)
    private let trailing = NSTextField(labelWithString: "")
    private let sparkline = Sparkline()
    /// The hairline a divider row is.
    private let rule = FlatDivider()
    private var symbol = ""
    private var detailSymbol = ""
    private var node: OrgNode?
    /// Set by the outline: flat rows have two lines when there's a detail.
    var flat = false
    private let tipOwner = LiveTip()
    private var liveTipTag: NSView.ToolTipTag?

    override init(frame: NSRect) {
        super.init(frame: frame)
        icon.contentTintColor = Theme.secondaryText
        name.font = UIType.row
        name.textColor = Theme.text
        name.lineBreakMode = .byTruncatingTail
        name.cell?.truncatesLastVisibleLine = true
        detail.font = UIType.footnote
        detail.textColor = Theme.secondaryText
        detail.lineBreakMode = .byTruncatingTail
        trailing.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        trailing.textColor = Theme.secondaryText
        trailing.alignment = .right
        detailIcon.contentTintColor = Theme.secondaryText
        detailIcon.isHidden = true
        for v in [icon, name, count, detail, detailIcon, trailing, glyph, pill, sparkline, rule] { addSubview(v) }
        rule.isHidden = true
    }

    required init?(coder: NSCoder) { fatalError() }

    func show(_ node: OrgNode) {
        self.node = node
        // A divider: the hairline alone.
        let divider = node.style == .divider
        rule.isHidden = !divider
        for v in [icon, name, count, detail, detailIcon, trailing, glyph, pill, sparkline] as [NSView] where divider { v.isHidden = true }
        if divider {
            shimmer.on = false
            toolTip = nil
            needsLayout = true
            return
        }
        icon.isHidden = false
        name.isHidden = false
        // The status by the name (`StatusMark`): a pill only when it needs
        // you, the name shimmering while it works.
        let mark = StatusMark(node.look, kind: node.blocked)
        glyph.block = node.block
        glyph.look = mark.glyph
        glyph.isHidden = mark.glyph == nil
        glyph.toolTip = node.liveTooltip == nil ? node.tooltip : nil
        pill.kind = node.style == .section ? nil : mark.pill
        pill.toolTip = node.liveTooltip == nil ? node.tooltip : nil
        shimmer.on = mark.shimmer && node.style != .section
        sparkline.pings = node.pings
        sparkline.isHidden = node.pings == nil
        trailing.stringValue = node.trailing ?? ""
        trailing.isHidden = node.trailing == nil
        trailing.textColor = Theme.secondaryText
        if let image = node.image {
            symbol = ""
            icon.image = image
        } else if node.symbol != symbol {
            symbol = node.symbol
            icon.image = Theme.symbol(node.symbol, size: 12)
        }
        name.stringValue = node.title
        switch node.style {
        case .host:
            name.font = UIType.title
            name.textColor = Theme.text
        case .section:
            name.font = .systemFont(ofSize: 11.5, weight: .semibold)
            name.textColor = node.emphasis ? Theme.text : Theme.secondaryText
        case .row, .divider:
            name.font = .systemFont(ofSize: 13, weight: node.emphasis ? .semibold : node.isGroup ? .medium : .regular)
            name.textColor = node.dimmed || node.behind || mark.dim ? Theme.secondaryText : Theme.text
        }
        // Edited and unsaved: the bar's dot after the name.
        if node.dirty, let font = name.font, let color = name.textColor {
            let s = NSMutableAttributedString(string: node.title + " •", attributes: [.font: font, .foregroundColor: color])
            s.addAttribute(.foregroundColor, value: node.stale ? StatusGlyph.amber : Theme.secondaryText,
                           range: NSRange(location: (node.title as NSString).length + 1, length: 1))
            name.attributedStringValue = s
        }
        icon.isHidden = node.style == .section
        icon.contentTintColor = node.emphasis ? Theme.text : Theme.secondaryText
        icon.alphaValue = node.dimmed ? 0.6 : 1
        // Its row's ground, if it's in a stack (a row reused keeps the last).
        (superview as? SelectionRowView)?.grouped = node.stack
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
        tipOwner.text = node.liveTooltip
        // A block's row has its card (the title, and more) for a tooltip.
        toolTip = node.liveTooltip != nil || node.block != nil ? nil : node.detail.isEmpty ? node.title : node.title + " — " + node.detail
        placeLiveTip()
        needsLayout = true
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        placeLiveTip()
    }

    override func viewDidMoveToSuperview() {
        super.viewDidMoveToSuperview()
        if let node { (superview as? SelectionRowView)?.grouped = node.stack }
    }

    /// The live tooltip's rect is the row's, kept so as it resizes.
    private func placeLiveTip() {
        if let liveTipTag { removeToolTip(liveTipTag) }
        liveTipTag = tipOwner.text == nil ? nil : addToolTip(bounds, owner: tipOwner, userData: nil)
    }

    override func layout() {
        super.layout()
        // The shimmer fitted to the name, wherever it was put.
        defer { shimmer.layout() }
        let h = bounds.height
        if let node, node.style == .divider {
            rule.frame = NSRect(x: 22, y: (h / 2).rounded(), width: max(0, bounds.width - 26), height: 1)
            return
        }
        if let node, node.style == .section {
            // A label across: the name in its grey, a count at the right.
            var right = bounds.width - 4
            if !count.isHidden {
                let w = count.wantedWidth
                count.frame = NSRect(x: right - w, y: ((h - CountPill.height) / 2).rounded(), width: w, height: CountPill.height)
                right -= w + 6
            }
            glyph.isHidden = true
            pill.isHidden = true
            // "1 needs you", in amber, at the right.
            if !trailing.isHidden {
                let w = ceil((trailing.stringValue as NSString).size(withAttributes: [.font: trailing.font!]).width) + 2
                trailing.frame = NSRect(x: right - w, y: (h - 15) / 2, width: w, height: 15)
                trailing.textColor = StatusGlyph.amber
                right -= w + 8
            }
            let wanted = ceil((name.stringValue as NSString).size(withAttributes: [.font: name.font!]).width) + 4
            let nw = min(wanted, max(0, right - 4))
            name.frame = NSRect(x: 4, y: (h - 15) / 2, width: nw, height: 15)
            detail.frame = NSRect(x: 4 + nw + 6, y: (h - 15) / 2, width: max(0, right - nw - 10), height: 15)
            detail.alphaValue = 1
            detailIcon.isHidden = true
            return
        }
        // The status at the right of the name's line, as apex sets it:
        // how long ago, then the pill (or a glyph) at the edge.
        func statusAtRight(_ right: inout CGFloat, y: CGFloat) {
            if !pill.isHidden {
                let s = pill.wanted
                pill.frame = NSRect(x: right - s.width - 1, y: y + (17 - s.height) / 2, width: s.width, height: s.height)
                right -= s.width + 7
            }
            if !glyph.isHidden {
                glyph.frame = NSRect(x: right - StatusGlyph.size - 2, y: y + (17 - StatusGlyph.size) / 2, width: StatusGlyph.size, height: StatusGlyph.size)
                right -= StatusGlyph.size + 8
            }
            if !trailing.isHidden {
                let w = ceil((trailing.stringValue as NSString).size(withAttributes: [.font: trailing.font!]).width) + 2
                trailing.frame = NSRect(x: right - w, y: y + 0.5, width: w, height: 15)
                right -= w + 8
            }
            if !sparkline.isHidden {
                sparkline.frame = NSRect(x: right - Sparkline.width, y: y + (17 - Sparkline.height) / 2, width: Sparkline.width, height: Sparkline.height)
                right -= Sparkline.width + 8
            }
        }
        if let node, flat, node.style == .row, !detail.isHidden {
            // Two lines: the name with the status at its right, then what
            // the status says beneath, aligned with the name.
            let ix: CGFloat = 0
            icon.frame = NSRect(x: 2 + ix, y: h - 20 + 1, width: 16, height: 14)
            var right = bounds.width - 4
            if !count.isHidden {
                let w = count.wantedWidth
                count.frame = NSRect(x: right - w, y: (h - 21 + (17 - CountPill.height) / 2).rounded(), width: w, height: CountPill.height)
                right -= w + 6
            }
            statusAtRight(&right, y: h - 21)
            name.frame = NSRect(x: 22 + ix, y: h - 21, width: max(0, right - 22 - ix), height: 17)
            var x: CGFloat = 22 + ix
            if !detailIcon.isHidden {
                detailIcon.frame = NSRect(x: x, y: 4.5, width: 13, height: 12)
                x += 16
            }
            detail.frame = NSRect(x: x, y: 3, width: max(0, bounds.width - 6 - x), height: 15)
            detail.alphaValue = 1
            glyph.alphaValue = 1
            detailIcon.alphaValue = 1
            return
        }
        let ix: CGFloat = 0
        icon.frame = NSRect(x: 2 + ix, y: (h - 14) / 2, width: node?.style == .host ? 18 : 16, height: 14)
        var right = bounds.width - 4
        if !count.isHidden {
            let w = count.wantedWidth
            count.frame = NSRect(x: right - w, y: ((h - CountPill.height) / 2).rounded(), width: w, height: CountPill.height)
            right -= w + 6
        }
        statusAtRight(&right, y: (h - 17) / 2)
        let nameWidth = max(0, right - 22 - ix)
        if detail.isHidden {
            name.frame = NSRect(x: 22 + ix, y: (h - 17) / 2, width: nameWidth, height: 17)
        } else {
            let wanted = ceil((name.stringValue as NSString).size(withAttributes: [.font: name.font ?? UIType.row]).width) + 4
            // The name whole whenever it fits; the detail gets what's left,
            // and goes when that's too little to say anything.
            let nw = min(wanted, nameWidth)
            name.frame = NSRect(x: 22 + ix, y: (h - 17) / 2, width: nw, height: 17)
            var x = 22 + ix + nw + 6
            var dw = nameWidth - nw - 6
            if !detailIcon.isHidden {
                detailIcon.frame = NSRect(x: x, y: (h - 12) / 2, width: 13, height: 12)
                x += 16
                dw -= 16
            }
            detail.frame = NSRect(x: x, y: (h - 15) / 2 - 0.5, width: max(0, dw), height: 15)
            let shown = dw >= 36
            detail.alphaValue = shown ? 1 : 0
            glyph.alphaValue = 1
            detailIcon.alphaValue = shown ? 1 : 0
        }
    }
}

/// A drag resting on a space's row (`springLoad`): the row's band in the
/// tint, filling from the left as the moment passes; full, it blinks
/// twice, as a folder Finder springs open does, and the space comes in.
/// With less motion asked for, it lights at once and doesn't blink.
private final class SpringBand: NSView {
    private let fill = CALayer()
    private let ground = CALayer()

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        let band = bounds.insetBy(dx: 6, dy: 1)
        for l in [ground, fill] {
            l.cornerRadius = Radius.control
            l.cornerCurve = .continuous
            l.anchorPoint = .zero
            l.frame = band
            layer?.addSublayer(l)
        }
        ground.backgroundColor = Theme.accent.withAlphaComponent(0.1).cgColor
        fill.backgroundColor = Theme.accent.withAlphaComponent(0.22).cgColor
        ground.masksToBounds = true
    }
    required init?(coder: NSCoder) { fatalError() }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    /// The fill across the row over `duration`, eased in, so it
    /// quickens to the spring.
    func charge(over duration: TimeInterval) {
        guard !Motion.reduced else { return }
        let a = CABasicAnimation(keyPath: "bounds.size.width")
        a.fromValue = fill.cornerRadius * 2
        a.toValue = fill.bounds.width
        a.duration = duration
        a.timingFunction = CAMediaTimingFunction(name: .easeIn)
        fill.add(a, forKey: "charge")
    }

    func blink(then done: @escaping () -> Void) {
        guard !Motion.reduced else { return done() }
        CATransaction.begin()
        CATransaction.setCompletionBlock(done)
        let a = CAKeyframeAnimation(keyPath: "opacity")
        a.values = [1, 0.2, 1, 0.2, 1]
        a.keyTimes = [0, 0.25, 0.5, 0.75, 1]
        a.duration = 0.24 * Motion.slowdown
        layer?.add(a, forKey: "blink")
        CATransaction.commit()
    }

    func fade(over duration: TimeInterval) {
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = duration
            ctx.timingFunction = Motion.disappear
            animator().alphaValue = 0
        }, completionHandler: { [weak self] in self?.removeFromSuperview() })
    }

    var debugState: String {
        let w = fill.presentation()?.bounds.width ?? fill.bounds.width
        return "fill=\(Int(w))/\(Int(fill.bounds.width)) alpha=\(String(format: "%.2f", layer?.presentation()?.opacity ?? 1))"
    }
}

/// The band that goes from space to space (`OrganizationView.travel`): a
/// row band in the tint, taking no clicks.
private final class TravelBand: NSView {
    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
    }
    required init?(coder: NSCoder) { fatalError() }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func draw(_ dirtyRect: NSRect) {
        Theme.accent.withAlphaComponent(0.22).setFill()
        Flat.rowBand(bounds).fill()
    }
}
