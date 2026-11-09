import AppKit
import ManifoldCore

protocol GridDelegate: AnyObject {
    func gridFocus(_ placement: PlacementID)
    /// A block's last picture, kept (a page's, which can't be drawn at once).
    func gridKeptPicture(_ block: BlockID) -> NSImage?
    /// A block's picture, to keep.
    func gridKeep(_ picture: NSImage, of block: BlockID)
    /// A tile as its summary card shows it.
    func gridSummary(_ placement: PlacementID) -> SummaryCardContent?
    /// A linked block's summary card, under the bar's links.
    func gridLinkSummary(_ block: BlockID) -> SummaryCardContent?
    /// A tile gone to by a click on its summary (it's too short for its
    /// content): focused, and grown to show some.
    func gridArrive(_ placement: PlacementID)
    /// A tile down to its summary, or, already there, back as it was.
    func gridShrinkToSummary(_ placement: PlacementID)
    /// A tile dropped at a place in the grid: into column `column` at
    /// index `at`, or a new column at `column`.
    func gridMove(_ placement: PlacementID, column: Int, at: Int, newColumn: Bool)
    /// A block from the sidebar dropped at a place in the grid: brought there.
    func gridBring(_ block: BlockID, column: Int, at: Int, newColumn: Bool)
    /// Things dropped (§3.11) — files, a block, a page, a picture, words —
    /// each a tile of its own where they landed: into column `column` at
    /// `at`, or a new column at `column`.
    func gridOpen(_ dragged: Dragged, column: Int, at: Int, newColumn: Bool)
    /// This Mac's host, whose files can go out as files.
    var gridLocalHost: HostID { get }
    /// Another arrangement dropped: its columns come over at `column`.
    func gridDropArrangement(_ arrangement: BlockID, column: Int)
    func gridCanDrop(_ arrangement: BlockID) -> Bool
    func gridResized(fractions: [Double])
    /// The lines between tiles dragged: the column's heights, a tile
    /// pushed to nothing at 0 (to be docked).
    func gridResized(heights: [PlacementID: Double])
    func gridDragChanged(_ dragging: Bool)
    func gridDragAtLeftEdge()
    /// A tile's pill was clicked: its menu.
    func gridPillMenu(for placement: PlacementID) -> NSMenu?
    /// ⌥-drag (or a bar dropped on another's): the dragged tile in another's
    /// place, that one docked under it.
    func gridCover(_ placement: PlacementID, over target: PlacementID)
    func gridGrow(_ placement: PlacementID)
    func gridFill(_ placement: PlacementID)
    /// A bar ⌥-clicked: its tile all the column but the others' bars.
    func gridSqueeze(_ placement: PlacementID)
    /// ⌥-click: the block's path, folder by folder, each going there.
    func gridPathMenu(for placement: PlacementID) -> NSMenu?
    /// The pill's corner button: the tile maximized over the arrangement,
    /// or restored.
    func gridToggleFull(_ placement: PlacementID)
    /// The bar's ×: the tile taken off (as ⌘W does).
    func gridClose(_ placement: PlacementID)
    /// A tile's × clicked: closed, the pointer onto the × of the tile that
    /// takes its place, to close the next with another click.
    func gridCloseClicked(_ placement: PlacementID)
    /// The bar's dirty dot clicked (the dot given, to put a menu by).
    /// The links' badge asks for the map around the tile's block.
    func gridShowMap(for placement: PlacementID)
    /// A linked block from a tile's badge: gone to; with ⌥, over the tile.
    func gridOpenLink(_ block: BlockID, from placement: PlacementID, modifiers: NSEvent.ModifierFlags)
    /// × on a badge's link: the edge ends.
    func gridBreakLink(_ link: String)
    /// A block ⇧-dragged onto a tile: linked to its block.
    func gridLink(_ block: BlockID, to target: PlacementID)
}

/// The surface (DESIGN.md §3.1): the arrangement as a grid, columns side
/// by side and each column's tiles top to bottom, every tile a block, all
/// visible, as acme tiles its windows. Each tile wears a pill floating
/// over its top, centered, to drag it by and to open its menu; the lines
/// between tiles and columns resize them; one pushed to nothing is
/// docked (§3.1).
final class GridView: NSView, NSDraggingSource {
    /// Told of a tile's view about to go out of sight — collapsed
    /// to its bar, behind a maximized tile — while it still shows: for a
    /// picture of it to keep.
    var onHiding: ((PaneContent) -> Void)?

    /// A tile's view shown or hidden; one about to go, pictured first.
    private func setHidden(_ view: PaneContent, _ hidden: Bool) {
        guard view.isHidden != hidden else { return }
        if hidden, view.window != nil, view.superview != nil { onHiding?(view) }
        view.isHidden = hidden
    }

    struct Tile {
        var shown: Shown
        var view: PaneContent
        /// The block's links by hand (§3.5), for the badge at its upper right.
        var links: [LinkCard] = []
    }
    private var badges: [PlacementID: LinkBadge] = [:]
    /// Each tile's outline, as ticks at its content's upper right (§7.5).
    private var ticks: [PlacementID: OutlineTicks] = [:]

    weak var delegate: GridDelegate?
    private(set) var columns: [[Tile]] = []
    private var fractions: [Double] = []
    private var heights: [PlacementID: Double] = [:]
    private var focused: PlacementID?
    private(set) var full: PlacementID?
    private var pills: [PlacementID: TilePill] = [:]
    /// Pills of tiles gone from the grid, kept (hidden) for when they come
    /// back: the two grids take turns at workspace switches, so a grid
    /// mostly shows again the workspace it showed two switches ago, and a
    /// pill costs more to make than to show again.
    private var sparePills: [PlacementID: TilePill] = [:]
    /// How long a tile takes to glide to a new place or size: on the
    /// travel curve, most of the way in its first third, so the move is
    /// seen, then settling.
    static var glide: TimeInterval { Motion.spatial }
    /// Debugging: grid layouts so far (the debug "layouts").
    static var layouts = 0
    private var columnDividers: [DividerView] = []
    private var rowDividers: [RowDividerView] = []
    private let dropOverlay = DropOverlayView()
    private var drop: DropSlot?
    /// The drop under way covers the tile it's on (⌥-drag).
    private var dropCovers = false
    /// The tile a thing dropped would link, by its title, for the palette.
    private var lastLinkTitle: String?
    /// The drag is a block's link (⇧): dropped, it links to the tile's block.
    /// While a block is dragged anywhere: a catcher over every tile takes
    /// the drag, since a web view would otherwise keep it to itself.
    var dragging = false {
        didSet {
            guard dragging != oldValue else { return }
            if dragging {
                dragCatcher.grid = self
                dragCatcher.frame = bounds
                addSubview(dragCatcher)
            } else {
                dragCatcher.removeFromSuperview()
                hideDrop()
                dropped = false
            }
        }
    }
    /// Dropped here, the drag not yet over: what the drop changes glides
    /// (a tile moved goes from where it was to where it's put), as if
    /// nothing were dragged.
    private var dropped = false
    private let dragCatcher = DragCatcherView()
    /// A ring around the focused tile.
    private let focusRing = FocusRingView()
    /// The tile the focus ring was round at the last layout.
    private var ringFor: PlacementID?

    /// A tile is a card (§3.1): its bar at the top — symbol, name, where it
    /// is, its links and status, maximize and close — and its content
    /// beneath, rounded, with room between cards and around them.
    static let barHeight: CGFloat = 30
    static let gap: CGFloat = 8
    static let inset: CGFloat = 8
    /// A tile shrinks in steps: under this much of its content showing,
    /// its summary card stands in for it, in its body under its bar…
    static let summarizeBelow: CGFloat = 80
    /// …and under this, it's down to its bar alone.
    static let collapseBelow: CGFloat = 24

    var views: [PaneContent] { columns.flatMap { $0.map(\.view) } }

    /// A tile's card: its bar over `body`.
    static func card(of body: NSRect) -> NSRect {
        NSRect(x: body.minX, y: body.minY, width: body.width, height: body.height + barHeight)
    }

    /// A card's body, under its bar.
    static func body(of card: NSRect) -> NSRect {
        NSRect(x: card.minX, y: card.minY, width: card.width, height: max(0, card.height - barHeight))
    }

    /// A card's bar, along its top.
    static func bar(of card: NSRect) -> NSRect {
        NSRect(x: card.minX, y: card.maxY - barHeight, width: card.width, height: barHeight)
    }

    /// A card's body: the content view rounded at the bottom, as every
    /// place that shows a tile (the grid, the overview) has it.
    static func styleBody(_ view: NSView) {
        view.wantsLayer = true
        view.layer?.cornerRadius = Radius.surface
        view.layer?.cornerCurve = .continuous
        view.layer?.maskedCorners = [.layerMinXMinYCorner, .layerMaxXMinYCorner]
        view.layer?.masksToBounds = true
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = .clear
        dropOverlay.isHidden = true
        registerForDraggedTypes([.manifoldArrangement, .manifoldPlacement, .manifoldBlock] + Dragged.types)
    }

    required init?(coder: NSCoder) { fatalError() }


    func show(_ columns: [[Tile]], fractions: [Double], heights: [PlacementID: Double], focused: PlacementID?, full: PlacementID? = nil) {
        // Maximized or restored: where the tile was, to grow or shrink from.
        var zoomFrom: (PlacementID, NSRect)?
        if full != self.full, window != nil, !isHiddenOrHasHiddenAncestor {
            if let f = full, let body = lastFrames[f], body.height > 0 {
                zoomFrom = (f, Self.card(of: body))
            } else if let w = self.full, let v = views.first(where: { $0.placement == w }), !v.isHidden {
                zoomFrom = (w, Self.card(of: v.frame))
            }
        }
        // Known before the layout, which leaves the rest shown under it.
        zooming = zoomFrom?.0
        defer {
            if let (id, from) = zoomFrom {
                layoutSubtreeIfNeeded()
                zoom(id, from: from)
            }
        }
        let incoming = Set(columns.flatMap { $0.map(\.shown.id) })
        for v in views where !incoming.contains(v.placement) && v.superview === self {
            switch departure?(v) ?? .moved {
            case .flown: break
            case .closed: poof(v)
            case .moved: fadeAway(v)
            }
            v.removeFromSuperview()
        }
        for (id, p) in pills where !incoming.contains(id) {
            p.isHidden = true
            pills.removeValue(forKey: id)
            sparePills[id] = p
        }
        if sparePills.count > 64 {
            for (id, p) in sparePills.prefix(sparePills.count - 64) {
                p.removeFromSuperview()
                sparePills.removeValue(forKey: id)
            }
        }
        for (id, b) in badges where !incoming.contains(id) {
            b.removeFromSuperview()
            badges.removeValue(forKey: id)
            badgeRects.removeValue(forKey: id)
        }
        for (id, t) in ticks where !incoming.contains(id) {
            t.removeFromSuperview()
            ticks.removeValue(forKey: id)
        }
        for (id, c) in tileSummaries where !incoming.contains(id) {
            c.removeFromSuperview()
            tileSummaries.removeValue(forKey: id)
        }
        self.columns = columns
        self.fractions = fractions.count == columns.count ? fractions : Array(repeating: 1 / Double(max(columns.count, 1)), count: columns.count)
        self.heights = heights
        self.focused = focused
        self.full = full
        var addedViews = false
        for column in columns {
            for tile in column {
                if tile.view.superview !== self {
                    Self.styleBody(tile.view)
                    addSubview(tile.view)
                    addedViews = true
                }
                let pill = pills[tile.shown.id] ?? {
                    let p = sparePills.removeValue(forKey: tile.shown.id) ?? TilePill()
                    pills[tile.shown.id] = p
                    if p.superview !== self { addSubview(p) }
                    return p
                }()
                let id = tile.shown.id
                pill.show(tile.shown, focused: tile.shown.id == focused, maximized: tile.shown.id == full)
                pill.editsPlace = tile.view.pillEdit != nil
                pill.onToggleFull = { [weak self] in self?.delegate?.gridToggleFull(id) }
                pill.sidebar = tile.view.hasSidebar ? tile.view.sidebarShown : nil
                pill.viewButtons = tile.view.barButtons
                pill.onViewButton = { [weak view = tile.view, weak self] i in
                    guard let view, i < view.barButtons.count else { return }
                    view.barButtons[i].action()
                    self?.barChanged(id)
                }
                pill.onToggleSidebar = { [weak view = tile.view, weak pill] in
                    guard let view else { return }
                    view.toggleSidebar()
                    pill?.sidebar = view.sidebarShown
                }
                pill.onClose = { [weak self] in self?.delegate?.gridCloseClicked(id) }
                // The bar clicked grows the tile, ⌘-clicked fills its column;
                // ⌃-clicked (or its symbol clicked) it's the tile's menu.
                pill.onClick = { [weak self, weak pill] at, mods in
                    guard let self else { return }
                    if mods.contains(.control) {
                        self.delegate?.gridFocus(id)
                        self.showPillMenu(id)
                        return
                    }
                    // The address in a page's pill, clicked, becomes its field;
                    // the tile is focused, not grown. The rest of the bar is
                    // the bar.
                    if let pill, !pill.isEditing, pill.isOnPlace(at), let edit = tile.view.pillEdit, !mods.contains(.command) {
                        self.delegate?.gridFocus(id)
                        pill.beginEditing(edit)
                        return
                    }
                    // The bar clicked grows the tile a step (acme's colgrow),
                    // focused — clicked again, a step more; ⌘-clicked, it
                    // fills its column, the others docked; ⌥-clicked, all
                    // its column but the others' bars, they staying (Maximize
                    // is the corner's). The pointer follows the bar to
                    // where it was clicked, once the tile has grown and moved
                    // it, so a click again grows again.
                    self.delegate?.gridFocus(id)
                    if mods.contains(.command) { self.delegate?.gridFill(id); return }
                    if mods.contains(.option) { self.delegate?.gridSqueeze(id); return }
                    self.pendingWarp = (id, at, self.barTargets[id] ?? pill?.frame ?? .zero, Date())
                    self.delegate?.gridGrow(id)
                }
                pill.onPathClick = { [weak self] in
                    guard let self else { return }
                    self.delegate?.gridFocus(id)
                    if let menu = self.delegate?.gridPathMenu(for: id), let pill = self.pills[id] {
                        let at = NSApp.currentEvent.map { pill.convert($0.locationInWindow, from: nil) } ?? NSPoint(x: pill.bounds.midX, y: 0)
                        menu.popUp(positioning: nil, at: NSPoint(x: at.x, y: at.y - 4), in: pill)
                    }
                }
                pill.onIconClick = { [weak self] _ in
                    guard let self else { return }
                    self.delegate?.gridFocus(id)
                    self.showPillMenu(id)
                }
                // Right-clicked, the title calls up the tile's menu.
                pill.onRightClick = { [weak self] _ in
                    guard let self else { return }
                    self.delegate?.gridFocus(id)
                    self.showPillMenu(id)
                }
                pill.onDragStart = { [weak self, weak pill] event, thing in
                    guard let self, let pill else { return }
                    self.beginDrag(of: id, event: event, from: pill, thing: thing)
                }
                // Its outline, as ticks over its content's upper right.
                if let outline = tile.view.outline {
                    if ticks[id]?.outline !== outline {
                        ticks[id]?.removeFromSuperview()
                        let t = OutlineTicks(outline: outline)
                        ticks[id] = t
                        addSubview(t)
                    }
                } else {
                    ticks[id]?.removeFromSuperview()
                    ticks.removeValue(forKey: id)
                }
                // The block's links, as a badge at the upper right.
                if tile.links.isEmpty {
                    badges[id]?.removeFromSuperview()
                    badges.removeValue(forKey: id)
                    badgeRects.removeValue(forKey: id)
                    pill.linkWanted = 0
                    pill.fanEdge = nil
                } else {
                    let badge = badges[id] ?? {
                        let b = LinkBadge()
                        b.layer?.zPosition = 6
                        badges[id] = b
                        return b
                    }()
                    badge.cards = tile.links
                    pill.linkWanted = badge.capsuleWantedWidth
                    // The bar's buttons or the links' room changed without
                    // the grid laying out (a status come or gone): placed
                    // again where it was, against the bar as it is now.
                    pill.onLinkRoom = { [weak self, weak badge, weak pill] in
                        guard let self, let badge, let pill, !pill.isHidden, let r = self.badgeRects[id] else { return }
                        self.placeBadge(badge, of: id, in: r)
                    }
                    badge.summary = { [weak self] block in self?.delegate?.gridLinkSummary(block) }
                    // Fanned out, the title fades out before the first face.
                    badge.onFanEdge = { [weak pill, weak badge] edge in
                        guard let pill, let badge else { return }
                        pill.fanEdge = edge.map { badge.convert(NSPoint(x: $0, y: 0), to: pill).x }
                    }
                    badge.onOpen = { [weak self] block, mods in self?.delegate?.gridOpenLink(block, from: id, modifiers: mods) }
                    badge.onBreak = { [weak self] link in self?.delegate?.gridBreakLink(link) }
                    badge.onMap = { [weak self] in self?.delegate?.gridShowMap(for: id) }
                    if badge.superview !== self { addSubview(badge, positioned: .above, relativeTo: pill) }
                }
                // One collapsed to its bar stays out of sight, as layout left it:
                // shown here, a sliver of it showed under its bar until the
                // next layout (and blinked with each, typing in a note whose
                // title is in its bar). Behind a maximized tile, out of sight
                // too, once it's grown over them: shown at a render (a
                // status changing, a minute going by), a PDF drew over it.
                let behindFull = full != nil && full != id && zooming != full
                // The maximized tile itself never: collapsed or summarized
                // are as the grid was laid out before it was maximized (its
                // layout then doesn't make them again), so a tile maximized
                // from its bar was hidden at the next render — an empty card.
                setHidden(tile.view, full != id && (pushedOut(id) || collapsed.contains(id) || summarized.contains(id) || behindFull))
                // Its summary standing in for it, said afresh with each render.
                if let card = tileSummaries[id], summarized.contains(id), let s = summaryContent(tile) { card.content = s }
            }
        }
        // The dividers are kept from one render to the next (every
        // keystroke in a note renders): only the count changes views.
        let columnCount = max(0, columns.count - 1)
        while columnDividers.count > columnCount { columnDividers.removeLast().removeFromSuperview() }
        while columnDividers.count < columnCount {
            let d = DividerView()
            addSubview(d)
            columnDividers.append(d)
        }
        for (i, d) in columnDividers.enumerated() {
            d.onDrag = { [weak self] x in self?.dividerDragging = true; self?.dragColumnDivider(i, to: x) }
            d.onEnd = { [weak self] in
                // (A double-click's up: what it evens is kept once it's there.)
                guard let self, self.evening == nil else { return }
                self.dividerDragging = false
                self.delegate?.gridResized(fractions: self.fractions)
            }
            d.onDoubleClick = { [weak self, weak d] in self?.evenColumns(i, line: d) }
        }
        var rows: [(Int, PlacementID, PlacementID)] = []
        for c in columns.indices where shownTiles(c).count > 1 {
            let shown = shownTiles(c)
            for r in 0..<(shown.count - 1) { rows.append((c, shown[r].shown.id, shown[r + 1].shown.id)) }
        }
        while rowDividers.count > rows.count { rowDividers.removeLast().removeFromSuperview() }
        while rowDividers.count < rows.count {
            let d = RowDividerView()
            addSubview(d)
            rowDividers.append(d)
        }
        for (d, (c, above, below)) in zip(rowDividers, rows) {
            d.onDrag = { [weak self] y in self?.dividerDragging = true; self?.dragRowDivider(column: c, above: above, below: below, to: y) }
            d.onEnd = { [weak self] in
                guard let self, self.evening == nil else { return }
                self.dividerDragging = false
                self.delegate?.gridResized(heights: self.heights)
            }
            d.onDoubleClick = { [weak self, weak d] in self?.evenRows(column: c, above: above, below: below, line: d) }
        }
        if subviews.last !== dropOverlay && !dragging { addSubview(dropOverlay) }
        if dragging { addSubview(dropOverlay); addSubview(dragCatcher) }
        // Laid out again only when what places the tiles changed: every
        // render came here (every keystroke in a note), and every tile
        // and pill was placed again.
        let inputs = LayoutInputs(ids: columns.map { $0.map(\.shown.id) }, views: columns.flatMap { $0.map { ObjectIdentifier($0.view) } },
                                  fractions: self.fractions, heights: heights, focused: focused, full: full,
                                  links: columns.flatMap { $0.map { pills[$0.shown.id]?.linkWanted ?? 0 } })
        if inputs != laidOutFor || addedViews || dragging {
            laidOutFor = inputs
            needsLayout = true
        }
    }

    /// What the tiles were last placed for.
    private struct LayoutInputs: Equatable {
        var ids: [[PlacementID]]
        var views: [ObjectIdentifier]
        var fractions: [Double]
        var heights: [PlacementID: Double]
        var focused: PlacementID?
        var full: PlacementID?
        var links: [CGFloat]
    }
    private var laidOutFor: LayoutInputs?
    /// The tiles the last layout collapsed to their bars (less than a line
    /// under them): their content stays hidden between layouts, as renders
    /// (every keystroke) come and go.
    private var collapsed: Set<PlacementID> = []
    /// The tiles the last layout summarized (too short for their content,
    /// tall enough for a line or more of their summary), and the cards
    /// standing in for their content.
    private var summarized: Set<PlacementID> = []
    private var tileSummaries: [PlacementID: SummaryCard] = [:]

    func clear() {
        show([], fractions: [], heights: [:], focused: nil)
    }

    /// A placement's view, if on screen.
    func view(of placement: PlacementID) -> PaneContent? {
        views.first { $0.placement == placement }
    }

    // MARK: Geometry

    /// Pushed to nothing by a line's drag (a share of 0, till the drag
    /// ends and it's docked): not laid out.
    private func pushedOut(_ id: PlacementID) -> Bool { heights[id] == 0 }
    private func shownTiles(_ c: Int) -> [Tile] { columns[c].filter { !pushedOut($0.shown.id) } }

    /// Debugging: each tile's pill — hidden, dodging, alpha, frame, order.
    /// Debugging: the tile's view put back on top, as a view made afresh
    /// for it (a terminal's, a placeholder's real one) is, and laid out.
    func debugReadd(_ placement: PlacementID) -> String {
        guard let v = view(of: placement) else { return "no view" }
        addSubview(v)
        needsLayout = true
        layoutSubtreeIfNeeded()
        return "re-added"
    }

    func debugBadge(_ placement: PlacementID, _ arg: String) -> String {
        guard let b = badges[placement] else { return "no badge" }
        b.debugFan(false)
        b.layoutSubtreeIfNeeded()
        let folded = b.debugSheets
        if arg == "fold" { return "folded, sheets \(folded)" + (b.debugCapsuleCenter.map { " at \(Int($0.x)) \(Int($0.y))" } ?? "") }
        if arg == "geometry" { return b.debugGeometry }
        b.debugFan(true)
        b.layoutSubtreeIfNeeded()
        let words = arg.split(separator: " ")
        if words.first == "break", let n = words.dropFirst().first.flatMap({ Int($0) }) {
            return b.debugBreak(n) ? "broke \(n)" : "no such link"
        }
        if words.first == "preview", let n = words.dropFirst().first.flatMap({ Int($0) }) { return b.debugPreview(n) }
        // "badge click n": the nth face clicked, as the pointer does — a
        // press and a release posted at its middle, hit-tested by the window.
        if words.first == "click", let n = words.dropFirst().first.flatMap({ Int($0) }), let window, let p = b.debugChipCenter(n) {
            let hit = window.contentView?.hitTest(window.contentView!.convert(p, from: nil))
            for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                if let e = NSEvent.mouseEvent(with: type, location: p, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                              windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: type == .leftMouseDown ? 1 : 0) {
                    NSApp.postEvent(e, atStart: false)
                }
            }
            return "clicked at \(Int(p.x)) \(Int(p.y)), over \(hit.map { String(describing: type(of: $0)) } ?? "nothing")"
        }
        if arg == "fanned" { return "badge \(NSStringFromRect(b.frame)): " + b.debugGeometry + " · bar's fan edge \(pills[placement]?.fanEdge.map { "\(Int($0))" } ?? "none")" }
        if words.first == "scrub", let f = words.dropFirst().first.flatMap({ Double($0) }) { return b.debugScrub(CGFloat(f)) }
        return b.debugTitles.joined(separator: " | ") + " (sheets \(folded) folded)"
    }

    /// Debugging: the line under column `c`'s `r`th shown tile dragged
    /// down past the next one's least height, and let go.
    func debugPushDown(column c: Int, row r: Int) -> String {
        guard c < columns.count else { return "no such column" }
        let shown = shownTiles(c)
        guard r + 1 < shown.count, let ib = columns[c].firstIndex(where: { $0.shown.id == shown[r + 1].shown.id }) else { return "no such line" }
        let frames = tileFrames(column: c, in: columnFrames()[c])
        dragRowDivider(column: c, above: shown[r].shown.id, below: shown[r + 1].shown.id, to: frames[ib].minY + 1)
        let out = heights.filter { $0.value == 0 }.count
        delegate?.gridResized(heights: heights)
        return "docked \(out)"
    }

    /// Debugging: each tile's dirty dot: hidden, grey or amber.
    var debugDirty: String {
        tiles.map { t in "\(t.shown.title): \(pills[t.shown.id]?.debugDirty ?? "-")" }.joined(separator: "\n")
    }

    /// Debugging: each tile's view, as laid out: its frame, whether it's
    /// hidden (and its layer), and its bar's.
    var debugTiles: String {
        tiles.map { t in
            let v = t.view
            let p = pills[t.shown.id]
            return "\(t.shown.title): view=\(NSStringFromRect(v.frame)) hidden=\(v.isHidden) layerHidden=\(v.layer?.isHidden ?? false) bar=\(p.map { NSStringFromRect($0.frame) } ?? "-") collapsedBar=\(p?.collapsed ?? false) summarized=\(summarized.contains(t.shown.id))"
        }.joined(separator: "\n")
    }

    var debugPills: String {
        tiles.map { t in
            let p = pills[t.shown.id]
            let order = p.flatMap { subviews.firstIndex(of: $0) }.map(String.init) ?? "-"
            let viewOrder = subviews.firstIndex(of: t.view).map(String.init) ?? "-"
            let caret = t.view.caretRectInWindow.map { NSStringFromRect($0) } ?? "none"
            let capsule = p.map { NSStringFromRect($0.convert($0.capsule(in: $0), to: nil)) } ?? "-"
            return "\(t.shown.title): hidden=\(p?.isHidden ?? true) frame=\(p.map { NSStringFromRect($0.frame) } ?? "-") z=\(order) view z=\(viewOrder) caret=\(caret) capsule=\(capsule) \(p?.debugEdit ?? "")"
        }.joined(separator: "\n")
    }

    /// A view above another in the order, put there only when it isn't:
    /// re-adding a layer-backed view at every layout flashes it.
    /// A tile's summary card, as its delegate makes it (a terminal's
    /// screen, a page's picture) or, failing that, from its block alone.
    /// Under its bar, so without its title — unless the bar names it
    /// otherwise (an untitled note, which the card calls by its first
    /// line): then that line comes first, as what it holds.
    private func summaryContent(_ tile: Tile) -> SummaryCardContent? {
        guard var c = delegate?.gridSummary(tile.shown.id)
            ?? tile.shown.block.map({ SummaryCardContent(id: tile.shown.id, symbol: tile.shown.symbol, summary: $0.summary()) }) else { return nil }
        if let b = tile.shown.block, b.kind == .text, let t = b.text, c.summary.title != tile.shown.title {
            c.summary.lines = Block.firstLines(t.text.string, skipping: "", count: 3)
        }
        return c
    }

    private func keep(_ v: NSView, above other: NSView) {
        // The subviews read once (each read is the whole list bridged), by
        // identity (not isEqual:, a message a view): per tile, a layout.
        let all = subviews
        guard let i = all.firstIndex(where: { $0 === v }), let j = all.firstIndex(where: { $0 === other }) else {
            addSubview(v, positioned: .above, relativeTo: other)
            return
        }
        if i < j { addSubview(v, positioned: .above, relativeTo: other) }
    }

    private func columnFrames() -> [NSRect] {
        let n = columns.count
        guard n > 0 else { return [] }
        let usable = bounds.width - 2 * Self.inset - CGFloat(n - 1) * Self.gap
        var x: CGFloat = Self.inset
        return fractions.enumerated().map { i, f in
            let w = i == n - 1 ? bounds.width - Self.inset - x : (usable * f).rounded()
            defer { x += w + Self.gap }
            return NSRect(x: x, y: Self.inset, width: w, height: bounds.height - 2 * Self.inset)
        }
    }

    /// Each tile's frame in a column, band included, top to bottom; no
    /// tile shorter than its band; one pushed out's is empty.
    private func tileFrames(column c: Int, in f: NSRect) -> [NSRect] {
        let all = columns[c]
        let shown = tileFramesShown(column: c, in: f)
        var next = 0
        return all.map { tile in
            if pushedOut(tile.shown.id) { return .zero }
            defer { next += 1 }
            return next < shown.count ? shown[next] : .zero
        }
    }

    private func tileFramesShown(column c: Int, in f: NSRect) -> [NSRect] {
        let tiles = shownTiles(c)
        guard !tiles.isEmpty else { return [] }
        var shares = tiles.map { heights[$0.shown.id] ?? 1 / Double(tiles.count) }
        let sum = shares.reduce(0, +)
        if sum > 0 { shares = shares.map { $0 / sum } }
        let usable = f.height - CGFloat(tiles.count - 1) * Self.gap
        var hs = shares.map { max(Self.barHeight, (usable * CGFloat($0)).rounded()) }
        // Over by the minimums: taken from the tallest.
        var over = hs.reduce(0, +) - usable
        while over > 0, let i = hs.indices.max(by: { hs[$0] < hs[$1] }), hs[i] > Self.barHeight {
            let take = min(over, hs[i] - Self.barHeight)
            hs[i] -= take
            over -= take
        }
        var y = f.maxY
        var out: [NSRect] = []
        for (i, h) in hs.enumerated() {
            let height = i == tiles.count - 1 ? y - f.minY : h
            out.append(NSRect(x: f.minX, y: y - height, width: f.width, height: height))
            y -= height + Self.gap
        }
        return out
    }

    override func layout() {
        Self.layouts += 1
        super.layout()
        // Tiles glide to new places when the grid itself didn't change
        // size (a tile placed, closed, grown, moved or docked); a resize
        // or a divider dragged lays out at once.
        let mayGlide = bounds == lastLayoutBounds && (!dragging || dropped) && !dividerDragging && !Motion.reduced
        // Where what goes with each tile shows now, to be carried from.
        let shownBefore = mayGlide ? companionsShown() : [:]
        lastCompanionsShown = shownBefore
        defer { carryCompanions(from: shownBefore, gliding: mayGlide) }
        if let full, let tile = tile(full) {
            // One tile over everything; the rest wait behind it — once it's
            // grown over them.
            if zooming != full {
                for t in tiles where t.shown.id != full {
                    setHidden(t.view, true)
                    pills[t.shown.id]?.isHidden = true
                    badges[t.shown.id]?.isHidden = true
                    // A summarized tile's card too (it showed over the maximized one).
                    tileSummaries[t.shown.id]?.isHidden = true
                    ticks[t.shown.id]?.available = false
                }
                for d in columnDividers + rowDividers { d.isHidden = true }
            }
            tile.view.isHidden = false
            // Its own card too, if it was short enough for one: the tile
            // shows whole now (restored that short, the card comes back).
            tileSummaries[full]?.isHidden = true
            let r = bounds.insetBy(dx: Self.inset, dy: Self.inset)
            tile.view.frame = Self.body(of: r)
            placeTicks(of: tile, in: tile.view.frame, shown: true)
            focusRing.isHidden = true
            if let pill = pills[full] {
                pill.isHidden = false
                pill.collapsed = false
                pill.frame = Self.bar(of: r)
                keep(pill, above: tile.view)
            }
            if let badge = badges[full] { placeBadge(badge, of: full, in: r) }
            if let badge = badges[full], let pill = pills[full] { keep(badge, above: pill) }
            return
        }
        for t in tiles {
            let out = pushedOut(t.shown.id)
            // Hidden if pushed out; shown or not, by whether it's collapsed,
            // below — not shown here first and hidden again there, which
            // pictured it and told the terminal it was seen at every layout.
            if out { setHidden(t.view, true) }
            pills[t.shown.id]?.isHidden = out
            badges[t.shown.id]?.isHidden = out
            ticks[t.shown.id]?.available = !out
        }
        for d in columnDividers + rowDividers { d.isHidden = false }
        let frames = columnFrames()
        var rowIndex = 0
        let gliding = mayGlide
        lastLayoutBounds = bounds
        var frameNow: [PlacementID: NSRect] = [:]
        var collapsedNow: Set<PlacementID> = []
        var summarizedNow: Set<PlacementID> = []
        // The tile moved (the focused one, by keys or dropped), else the one
        // that goes farthest, to go over the rest.
        var traveller: (id: PlacementID, was: NSRect, distance: CGFloat)?
        func settle(_ view: NSView, _ frame: NSRect, was: NSRect?) {
            if gliding, let was, was != .zero, was != frame, !view.isHidden {
                if let tile = view as? PaneContent {
                    // The whole card, its edges and place at once, as one
                    // thing moved, whether or not its size changes.
                    let distance = hypot(frame.midX - was.midX, frame.maxY - was.maxY)
                    if distance > Self.travelsOver, traveller?.id != focused, tile.placement == focused || distance > (traveller?.distance ?? 0) {
                        traveller = (tile.placement, was, distance)
                    }
                    slide(view, to: frame)
                } else if let pill = view as? TilePill {
                    slide(pill, to: frame)
                } else {
                    NSAnimationContext.runAnimationGroup { ctx in
                        ctx.duration = Self.glide
                        ctx.timingFunction = Motion.travel
                        view.animator().frame = frame
                    }
                }
            } else {
                view.frame = frame
            }
        }
        for (c, f) in frames.enumerated() {
            let tiles = tileFrames(column: c, in: f)
            var shownIndex = 0
            for (i, tile) in columns[c].enumerated() {
                guard !pushedOut(tile.shown.id) else { continue }
                let r = tiles[i]
                let body = Self.body(of: r)
                let was = lastFrames[tile.shown.id]
                // Too little of its content under the bar to be worth
                // showing: its summary card in its place; less than a line
                // of that, the tile is collapsed to its bar, a pill.
                let collapsed = body.height < Self.collapseBelow
                let summarized = !collapsed && body.height < Self.summarizeBelow
                if collapsed { collapsedNow.insert(tile.shown.id) }
                if summarized { summarizedNow.insert(tile.shown.id) }
                frameNow[tile.shown.id] = collapsed ? Self.body(of: Self.bar(of: r)) : body
                // Gone to or from its summary card (a divider dragged, a
                // neighbour grown): the one crosses over to the other.
                if !collapsed, was != nil, summarized != self.summarized.contains(tile.shown.id), !self.collapsed.contains(tile.shown.id),
                   let leaving = summarized ? tile.view : tileSummaries[tile.shown.id], !leaving.isHidden {
                    crossFade(from: leaving, to: body)
                }
                settle(tile.view, body, was: was)
                setHidden(tile.view, collapsed || summarized)
                if summarized, let content = summaryContent(tile) {
                    let card = tileSummaries[tile.shown.id] ?? {
                        let c = SummaryCard(content)
                        c.inTile = true
                        Self.styleBody(c)
                        // Square under its bar, rounded at the bottom: the
                        // card is flipped, its layer with it.
                        c.layer?.maskedCorners = [.layerMinXMaxYCorner, .layerMaxXMaxYCorner]
                        let id = tile.shown.id
                        c.onClick = { [weak self] in self?.delegate?.gridArrive(id) }
                        tileSummaries[tile.shown.id] = c
                        return c
                    }()
                    card.content = content
                    card.frame = body
                    card.isHidden = false
                    keep(card, above: tile.view)
                }
                placeTicks(of: tile, in: body, shown: !collapsed && !summarized)
                if let pill = pills[tile.shown.id] {
                    pill.collapsed = collapsed
                    let bar = Self.bar(of: r)
                    barTargets[tile.shown.id] = bar
                    settle(pill, bar, was: was.map { Self.bar(of: Self.card(of: $0)) })
                    keep(pill, above: tile.view)
                }
                if let badge = badges[tile.shown.id] {
                    placeBadge(badge, of: tile.shown.id, in: r)
                    // Over its bar for clicks too, not only drawn over it: a
                    // view put back on top takes its bar up above it again.
                    if let pill = pills[tile.shown.id] { keep(badge, above: pill) }
                }
                if shownIndex > 0, rowIndex < rowDividers.count {
                    rowDividers[rowIndex].frame = NSRect(x: r.minX, y: r.maxY, width: r.width, height: Self.gap)
                    rowIndex += 1
                }
                shownIndex += 1
            }
        }
        // Tiles placed since the last layout come in where they land.
        var cameIn: Set<PlacementID> = []
        if gliding, !lastFrames.isEmpty {
            for t in tiles where frameNow[t.shown.id] != nil && lastFrames[t.shown.id] == nil && !placed.contains(t.shown.id) {
                comeIn([t.view, pills[t.shown.id], tileSummaries[t.shown.id]].compactMap { $0 }.filter { !$0.isHidden })
                cameIn.insert(t.shown.id)
            }
        }
        placed = Set(tiles.map(\.shown.id))
        if let t = traveller { raise(t.id, from: Self.card(of: t.was), among: shownBefore) }
        let wasFrames = lastFrames
        lastFrames = frameNow
        self.collapsed = collapsedNow
        self.summarized = summarizedNow
        for (id, c) in tileSummaries where !summarizedNow.contains(id) { c.isHidden = true }
        if dragging { dragCatcher.frame = bounds }
        // The focus ring: around the focused tile, over everything (once a
        // tile shrinking back to its place is there).
        if let focused, zooming == nil, let t = tile(focused), !pushedOut(focused) {
            focusRing.isHidden = false
            let body = frameNow[focused] ?? t.view.frame
            let card = Self.card(of: body)
            if focusRing.frame != card {
                // With its tile as it glides; to another (the one left
                // focused by a tile closed), from where that one was.
                if gliding, ringFor == focused, focusRing.frame != .zero {
                    focusRing.glide(to: card)
                } else if gliding, ringFor != nil, let was = wasFrames[focused], was.height > 0 {
                    focusRing.glide(to: card, from: Self.card(of: was))
                } else {
                    focusRing.frame = card
                }
                focusRing.needsDisplay = true
            }
            ringFor = focused
            // Round a tile coming in, coming in with it.
            if cameIn.contains(focused) { comeIn([focusRing]) }
            if let p = pills[focused] { keep(focusRing, above: p) }
        } else {
            focusRing.isHidden = true
            ringFor = nil
        }
        for (i, d) in columnDividers.enumerated() {
            d.frame = NSRect(x: frames[i].maxX, y: 0, width: Self.gap, height: bounds.height)
        }
        layoutShadows(frameNow, gliding: gliding)
        warpIfGrown()
        // A tile chosen in the switcher (⌃⇥), once it's laid out:
        // grown from its card into its place.
        if let m = pendingArrival {
            if Date().timeIntervalSince(m.at) > 1 { land() } else if frameNow[m.id].map({ $0.height > 0 }) == true, !pushedOut(m.id) {
                pendingArrival = nil
                arrive(m.id, card: m.card, from: m.from, in: m.host)
            }
        }
    }

    // MARK: Coming and going

    /// A tile placed comes in where it lands — growing from smaller,
    /// seen at once — as its neighbours' edges slide aside for it (only
    /// fading, with Reduce motion).
    /// Every tile at the last layout.
    private var placed: Set<PlacementID> = []

    private func comeIn(_ parts: [NSView]) {
        // Seen at once, there before it's grown: the growing is what shows
        // it coming, not a fade.
        Ghost.burst(parts.compactMap(\.layer), scale: Motion.reduced ? 1 : 0.86, over: Self.glide, fade: Self.glide * 0.4,
                    fading: Motion.appear, moving: Motion.travel, coming: true, key: "comeIn")
    }

    /// A tile's content resized as its neighbours come, go or grow: sized
    /// at once — at every step, a terminal would resize its shell at each
    /// (over the network, on another host), an editor lay its text out
    /// again at each — while its edges glide from where they show now to
    /// where they go, what it shows held at its top left, cut off or
    /// uncovered as they pass: a neighbour's edge seen sliding, not the
    /// tile jumping to its size.
    /// Layers sliding, their own gravity and ground, given back as they stop.
    private var sliding: [ObjectIdentifier: (gravity: CALayerContentsGravity, ground: CGColor?)] = [:]

    /// `start`: from there (in the grid), not from where it shows.
    private func slide(_ view: NSView, to frame: NSRect, from start: NSRect? = nil) {
        guard let l = view.layer else { view.frame = frame; return }
        let now = l.presentation() ?? l
        var size = now.bounds.size, position = now.position
        if let start {
            size = start.size
            position = CGPoint(x: start.minX + l.anchorPoint.x * start.width, y: start.minY + l.anchorPoint.y * start.height)
        }
        view.frame = frame
        if let pill = view as? TilePill {
            // A bar: its own parts slide their edges, not its drawing.
            pill.layoutSubtreeIfNeeded()
            pill.slideEdges(from: size.width, over: Self.glide, Motion.travel)
        }
        let to = l.bounds
        // Its top where its content's is (a layer's y runs up).
        let from = CGRect(x: 0, y: l.isGeometryFlipped ? 0 : to.height - size.height, width: size.width, height: size.height)
        // Its own drawing (a terminal's surface, drawn at its new size a
        // moment later) held, not stretched, on its ground: where it's
        // bigger than that drawing, not a hole.
        let key = ObjectIdentifier(l)
        if l.contents != nil, sliding[key] == nil, !(view is TilePill) {
            sliding[key] = (l.contentsGravity, l.backgroundColor)
            l.contentsGravity = l.isGeometryFlipped ? .bottomLeft : .topLeft
            if (l.backgroundColor?.alpha ?? 0) == 0 {
                let ground = view is TerminalView ? TerminalPalette.current(for: view).background : Theme.windowBackground.withAlphaComponent(1)
                view.effectiveAppearance.performAsCurrentDrawingAppearance { l.backgroundColor = ground.cgColor }
            }
        }
        let bounds = CABasicAnimation(keyPath: "bounds")
        bounds.fromValue = NSValue(rect: from)
        bounds.toValue = NSValue(rect: to)
        let move = CABasicAnimation(keyPath: "position")
        move.fromValue = NSValue(point: position)
        move.toValue = NSValue(point: l.position)
        let g = CAAnimationGroup()
        g.animations = [bounds, move]
        g.duration = Self.glide
        g.timingFunction = Motion.travel
        CATransaction.begin()
        CATransaction.setCompletionBlock { [weak self, weak l] in
            guard let self, let l, l.animation(forKey: "slide") == nil, let was = self.sliding.removeValue(forKey: key) else { return }
            l.contentsGravity = was.gravity
            l.backgroundColor = was.ground
        }
        l.add(g, forKey: "slide")
        CATransaction.commit()
    }

    /// What goes with a tile without being it — a terminal's dots, scroll
    /// bar and glow beside it, the tile's ticks, its badge, its summary
    /// card — and the lines between tiles: everything in the grid but the
    /// tiles, their bars and what glides or shows on its own.
    private func isCompanion(_ v: NSView) -> Bool {
        !(v is PaneContent || v is TilePill || v === focusRing || v === dragCatcher || v === dropOverlay)
    }

    /// Where each companion shows this moment (part way, if carried).
    private func companionsShown() -> [ObjectIdentifier: NSRect] {
        var out: [ObjectIdentifier: NSRect] = [:]
        for v in subviews where isCompanion(v) {
            if let l = v.layer { out[ObjectIdentifier(v)] = (l.presentation() ?? l).frame }
        }
        return out
    }

    /// Where they showed as the last layout began (a tile maximized takes
    /// those that showed on it over the rest).
    private var lastCompanionsShown: [ObjectIdentifier: NSRect] = [:]
    /// Companions' frames as last laid out: one carried only when it's
    /// laid out somewhere else, not again at every layout on the way.
    private var companionFrames: [ObjectIdentifier: NSRect] = [:]

    /// Each companion laid out somewhere new, carried there from where it
    /// showed, its top left going as its tile's edges go (they all glide
    /// on the one curve), its size where it ends — not jumping ahead of
    /// its tile, sliding.
    private func carryCompanions(from shown: [ObjectIdentifier: NSRect], gliding: Bool) {
        var now: [ObjectIdentifier: NSRect] = [:]
        for v in subviews where isCompanion(v) {
            guard let l = v.layer else { continue }
            let key = ObjectIdentifier(v), to = l.frame
            now[key] = to
            guard gliding, !v.isHidden, let was = shown[key], was != .zero, companionFrames[key] != to else { continue }
            let dx = was.minX - to.minX, dy = was.maxY - to.maxY
            guard abs(dx) > 0.5 || abs(dy) > 0.5 else { continue }
            let a = CABasicAnimation(keyPath: "position")
            a.fromValue = NSValue(point: NSPoint(x: l.position.x + dx, y: l.position.y + dy))
            a.toValue = NSValue(point: l.position)
            a.duration = Self.glide
            a.timingFunction = Motion.travel
            l.add(a, forKey: "carry")
        }
        companionFrames = now
    }

    /// How far a tile goes before it's taken over the rest on its way.
    static let travelsOver: CGFloat = 40

    /// Layers raised over the rest, with where they were.
    private var raised: [ObjectIdentifier: (layer: CALayer, z: CGFloat)] = [:]
    private var raisedFor = 0

    /// A tile moved goes over the rest on its way, as a card picked up
    /// and put down — its bar, badge and companions (those that showed
    /// on it, `card`) and its ring with it — and back among them there.
    private func raise(_ id: PlacementID, from card: NSRect, among shown: [ObjectIdentifier: NSRect], by lift: CGFloat = 10, for duration: TimeInterval = GridView.glide) {
        guard let tile = tile(id) else { return }
        var views: [NSView] = [tile.view]
        if let p = pills[id] { views.append(p) }
        if let b = badges[id] { views.append(b) }
        if focused == id { views.append(focusRing) }
        views += subviews.filter { v in isCompanion(v) && !(v is DividerView || v is RowDividerView) && shown[ObjectIdentifier(v)].map { card.contains(NSPoint(x: $0.midX, y: $0.midY)) } == true }
        lower()
        for l in views.compactMap(\.layer) where raised[ObjectIdentifier(l)] == nil {
            raised[ObjectIdentifier(l)] = (l, l.zPosition)
            l.zPosition += lift
        }
        raisedFor += 1
        let n = raisedFor
        DispatchQueue.main.asyncAfter(deadline: .now() + duration) { [weak self] in
            guard let self, self.raisedFor == n else { return }
            self.lower()
        }
    }

    private func lower() {
        for (_, r) in raised { r.layer.zPosition = r.z }
        raised = [:]
    }

    /// What a tile showed (its content, or its summary card) over what it
    /// shows now, fading: a picture of it, its top at the tile's top as
    /// the tile is now, so a divider dragged meanwhile takes nothing with it.
    private func crossFade(from v: NSView, to body: NSRect) {
        guard window != nil, !isHiddenOrHasHiddenAncestor, zooming == nil, v.bounds.width > 20, v.bounds.height > 1,
              let host = layer, let g = Ghost.picture(of: v, at: body, z: 15, gravity: .top) else { return }
        host.addSublayer(g)
        Ghost.fadeOut(g, over: Motion.spatial, timing: Motion.disappear, key: "crossFade")
    }

    /// How a tile leaves the grid: closed (gone from the desk), flown
    /// somewhere by its window's controller (docked, into the shelf or its
    /// row), or moved (to another space).
    enum Departure { case closed, flown, moved }
    /// Asked of each tile leaving as the grid's shown; moved, unasked.
    var departure: ((PaneContent) -> Departure)?

    /// A tile closed: gone in a puff — its picture swelling a little as it
    /// fades, a small cloud bursting where it was and drifting apart, as
    /// the Dock's poof. With less motion, only faded.
    func poof(_ v: PaneContent) {
        guard !Motion.reduced, let ghosts = ghosts(of: v), let host = layer, let card = Ghost.union(ghosts.map(\.frame)) else { return fadeAway(v) }
        ghosts.forEach(host.addSublayer)
        Ghost.burst(ghosts, scale: 1.05, over: Motion.spatial * 0.5, fading: Motion.appear, moving: Motion.appear, key: "poof")
        Self.puff(in: host, over: card, appearance: effectiveAppearance)
    }

    /// The cloud: soft puffs born over the middle of `r` at once, swelling,
    /// drifting out and fading.
    static func puff(in host: CALayer, over r: NSRect, appearance: NSAppearance) {
        let e = CAEmitterLayer()
        e.frame = host.bounds
        e.zPosition = 31
        e.emitterPosition = CGPoint(x: r.midX, y: r.midY)
        e.emitterShape = .rectangle
        e.emitterMode = .volume
        e.emitterSize = CGSize(width: min(r.width * 0.5, 260), height: min(r.height * 0.4, 120))
        e.renderMode = .unordered
        let side = min(max(min(r.width, r.height) * 0.22, 34), 90)
        let cell = CAEmitterCell()
        cell.contents = puffImage
        var ink = NSColor.white.cgColor
        appearance.performAsCurrentDrawingAppearance { ink = Theme.secondaryText.withAlphaComponent(0.55).cgColor }
        cell.color = ink
        cell.birthRate = 260
        cell.lifetime = Float(0.36 * Motion.slowdown)
        cell.lifetimeRange = Float(0.1 * Motion.slowdown)
        cell.velocity = side * 2.4 / Motion.slowdown
        cell.velocityRange = side * 1.5 / Motion.slowdown
        cell.emissionRange = .pi * 2
        cell.scale = side / 64 * 0.45
        cell.scaleRange = side / 64 * 0.2
        cell.scaleSpeed = side / 64 * 2.1 / Motion.slowdown
        cell.alphaSpeed = Float(-2.8 / Motion.slowdown)
        cell.spin = 0.6
        cell.spinRange = 1.5
        e.emitterCells = [cell]
        e.beginTime = CACurrentMediaTime()
        host.addSublayer(e)
        // A burst: born for a moment only, gone once the last has faded.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.04 * Motion.slowdown) { e.birthRate = 0 }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.7 * Motion.slowdown) { e.removeFromSuperlayer() }
    }

    /// A soft round puff, white, for tinting.
    private static let puffImage: CGImage? = {
        let n = 64
        guard let ctx = CGContext(data: nil, width: n, height: n, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
              let g = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: [CGColor(gray: 1, alpha: 1), CGColor(gray: 1, alpha: 0.5), CGColor(gray: 1, alpha: 0)] as CFArray,
                                 locations: [0, 0.45, 1]) else { return nil }
        let c = CGPoint(x: n / 2, y: n / 2)
        ctx.drawRadialGradient(g, startCenter: c, startRadius: 0, endCenter: c, endRadius: CGFloat(n) / 2, options: [])
        return ctx.makeImage()
    }()

    /// Pictures of a tile's body and bar, where they are, each on its
    /// ground, for it to be seen going.
    private func ghosts(of v: PaneContent) -> [CALayer]? {
        let bar = pills[v.placement]
        guard window != nil, !isHiddenOrHasHiddenAncestor else { return nil }
        // Its body, or (too short for it) the summary in its place; its bar.
        let body: NSView? = v.isHidden ? tileSummaries[v.placement] : v
        var ghosts: [CALayer] = []
        // Each on its ground, which a drawing of it leaves out: whole, as
        // the tile was over what's behind it now.
        for part in [body, bar].compactMap({ $0 }) where !part.isHidden && part.superview === self && part.bounds.width > 20 {
            if let g = Ghost.picture(of: part, z: 30) { ghosts.append(g) }
        }
        return ghosts.isEmpty ? nil : ghosts
    }

    /// A tile moved away: a picture of it where it was, shrinking and
    /// fading, as its neighbours' edges slide into the room it leaves —
    /// what went, seen going. Its view goes at once, as before.
    func fadeAway(_ v: PaneContent) {
        guard let ghosts = ghosts(of: v), let host = layer else { return }
        ghosts.forEach(host.addSublayer)
        // Shrinking at once about the tile's middle, its parts with it,
        // seen going as it shrinks; faded out by the time its neighbours
        // have taken most of its room.
        Ghost.burst(ghosts, scale: Motion.reduced ? 1 : 0.86, over: Self.glide * 0.6, fading: Motion.appear, moving: Motion.travel, key: "fadeAway")
    }

    /// A tile's picture, for its ghost: a terminal's surface as it is,
    /// anything else drawn at the screen's scale.
    static func ghostPicture(of v: NSView) -> Any? {
        if let surface = v.layer?.contents, CFGetTypeID(surface as CFTypeRef) == IOSurfaceGetTypeID() { return surface }
        if v is TerminalView, let image = HoverCard.surfacePicture(of: v) { return image.cgImage(forProposedRect: nil, context: nil, hints: nil) }
        return v.bitmap()?.cgImage
    }

    /// Pictures of a thing as it shows — a tile's body and bar, a card —
    /// where each is, on its ground (what's behind its drawing: its
    /// layer's colour, else the window's).
    struct Pictured {
        var parts: [(NSRect, Any?)]
        var ground: CGColor?
        var whole: NSRect { Ghost.union(parts.map(\.0)) ?? .zero }

        /// As it shows in `to`'s terms, from `from`'s.
        func converted(from: NSView, to: NSView) -> Pictured {
            Pictured(parts: parts.map { (to.convert($0.0, from: from), $0.1) }, ground: ground)
        }
    }

    /// What's behind a view's drawing, opaque.
    static func ground(of v: NSView) -> CGColor {
        if let own = v.layer?.backgroundColor, own.alpha > 0 { return own.copy(alpha: 1) ?? own }
        var c = NSColor.windowBackgroundColor.cgColor
        v.effectiveAppearance.performAsCurrentDrawingAppearance { c = Theme.windowBackground.withAlphaComponent(1).cgColor }
        return c
    }

    /// Each tile in view, by its block (a block's first), its body then its
    /// bar, where they are (the grid's terms) with pictures of them: for
    /// Overview's cards to be seen coming from them, and going back.
    func tileParts() -> [BlockID: Pictured] {
        var out: [BlockID: Pictured] = [:]
        for t in tiles {
            guard let b = t.shown.block?.id, out[b] == nil, let body = shownBody(t) else { continue }
            out[b] = pictured(body, pills[t.shown.id])
        }
        return out
    }

    /// Each tile in view, by its placement, as `tileParts` has them.
    func placedParts() -> [PlacementID: Pictured] {
        var out: [PlacementID: Pictured] = [:]
        for t in tiles {
            guard let body = shownBody(t) else { continue }
            out[t.shown.id] = pictured(body, pills[t.shown.id])
        }
        return out
    }

    /// Each tile down to its bar (nothing of it shown under it), its bar
    /// where it is (the grid's terms) with a picture of it.
    func placedBars() -> [PlacementID: Pictured] {
        var out: [PlacementID: Pictured] = [:]
        for t in tiles where shownBody(t) == nil {
            guard let bar = pills[t.shown.id], !bar.isHidden, bar.frame.height > 0 else { continue }
            let alpha = bar.alphaValue
            bar.alphaValue = 1
            out[t.shown.id] = Pictured(parts: [(bar.frame, Self.ghostPicture(of: bar))], ground: Self.ground(of: bar))
            bar.alphaValue = alpha
        }
        return out
    }

    /// `page`: a page's picture, from it; else, for a page, its last kept
    /// (if it was the same shape), which a drawing of it would leave blank.
    private func pictured(_ body: NSView, _ bar: NSView?, page: CGImage? = nil) -> Pictured {
        // As it'll show, though it's out of sight meanwhile (a drawing of a
        // view takes its opacity).
        func picture(_ v: NSView) -> Any? {
            let alpha = v.alphaValue
            v.alphaValue = 1
            defer { v.alphaValue = alpha }
            return Self.ghostPicture(of: v)
        }
        var shown: Any? = page
        if shown == nil, body is Snapshotting {
            if let b = (body as? PaneContent)?.block, let kept = delegate?.gridKeptPicture(b), kept.size.width > 0, body.bounds.height > 0,
               abs(kept.size.height / kept.size.width - body.bounds.height / body.bounds.width) < 0.03 {
                shown = kept.cgImage(forProposedRect: nil, context: nil, hints: nil)
            }
        } else if shown == nil {
            shown = picture(body)
        }
        var parts: [(NSRect, Any?)] = [(body.frame, shown)]
        if let bar, !bar.isHidden { parts.append((bar.frame, picture(bar))) }
        return Pictured(parts: parts, ground: Self.ground(of: body))
    }

    /// `pictured`, a page's from the page itself — `done` once it's come,
    /// or after `wait` at most (then as `pictured` has it), kept for later.
    private func picturing(_ body: NSView, _ bar: NSView?, wait: Double = 0.25, _ done: @escaping (Pictured) -> Void) {
        guard let page = body as? Snapshotting else { return done(pictured(body, bar)) }
        var called = false
        page.snapshot { [weak self, weak body, weak bar] image in
            guard let self, let body, !called else { return }
            called = true
            if let image, let b = (body as? PaneContent)?.block { self.delegate?.gridKeep(image, of: b) }
            done(self.pictured(body, bar, page: image?.cgImage(forProposedRect: nil, context: nil, hints: nil)))
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + wait) { [weak self, weak body, weak bar] in
            guard let self, let body, !called else { return }
            called = true
            done(self.pictured(body, bar))
        }
    }

    /// What shows of a tile under its bar: its content, or its summary card.
    private func shownBody(_ t: Tile) -> NSView? {
        guard !pushedOut(t.shown.id) else { return nil }
        if !t.view.isHidden, t.view.frame.height > 0 { return t.view }
        if summarized.contains(t.shown.id), let c = tileSummaries[t.shown.id], !c.isHidden { return c }
        return nil
    }

    /// A tile in view's body and bar, by its block (a block's first), and
    /// its focus ring if it has it.
    /// A tile's bar, where it shows.
    func bar(of placement: PlacementID) -> NSView? { pills[placement] }

    func tileViews(of block: BlockID) -> [NSView] {
        guard let t = tiles.first(where: { $0.shown.block?.id == block && shownBody($0) != nil }), let body = shownBody(t) else { return [] }
        return [body] + (pills[t.shown.id].map { [$0] } ?? []) + (t.shown.id == focused && !focusRing.isHidden ? [focusRing] : [])
    }

    // MARK: Morphing

    /// One thing becoming another where it goes — a tile its card, a card
    /// its tile, a sidebar row's tile out into its card: its outline travels and
    /// changes shape, and what it shows is scaled to its width, from its
    /// top (cut below, never stretched), what it was giving way to what it
    /// becomes on the way.
    struct Morph {
        var from: NSRect, to: NSRect
        var leaving: Pictured? = nil
        var coming: Pictured? = nil
        var delay: Double = 0
        /// Over (positive) or under the rest: a pile's order.
        var z: CGFloat = 0
        /// What a picture shows at the far smaller end (a tile become a card
        /// about as wide as it, ⌃⇥'s): this much of its width — seen
        /// to shrink as it goes, as Overview's tiles do, rather than only
        /// be cut off from below.
        var shrink: CGFloat = 1
    }

    /// Morphs over `host` (its terms, y up), the pictures taken away once
    /// they're there. Only cross-fading where they end, with Reduce motion.
    @discardableResult
    /// `keeping`: left where they end, for the caller to take away (what
    /// waits on something else to land over it).
    static func morph(_ items: [Morph], in host: CALayer, over d: Double, keeping: Bool = false, done: @escaping () -> Void = {}) -> [CALayer] {
        var made: [CALayer] = []
        CATransaction.begin()
        CATransaction.setCompletionBlock {
            if !keeping { made.forEach { $0.removeFromSuperlayer() } }
            done()
        }
        let now = CACurrentMediaTime()
        // Those coming out of something (nothing leaving) go under the one in front of them.
        let items = items.filter { $0.leaving == nil } + items.filter { $0.leaving != nil }
        func animate(_ l: CALayer, _ key: String, _ a: Any, _ b: Any, delay: Double) {
            let x = CABasicAnimation(keyPath: key)
            x.fromValue = a
            x.toValue = b
            x.duration = d
            x.timingFunction = Motion.travel
            x.beginTime = now + delay * Motion.slowdown
            x.fillMode = .backwards
            l.add(x, forKey: "morph." + key)
        }
        func fade(_ l: CALayer, _ values: [Float], _ times: [NSNumber], delay: Double) {
            let x = CAKeyframeAnimation(keyPath: "opacity")
            x.values = values
            x.keyTimes = times
            x.duration = d
            x.beginTime = now + delay * Motion.slowdown
            x.fillMode = .backwards
            l.add(x, forKey: "morph.opacity")
        }
        for m in items where m.to.width > 1 && m.to.height > 1 && m.from.width > 1 && m.from.height > 1 {
            let from = Motion.reduced ? m.to : m.from
            let c = CALayer()
            c.frame = m.to
            c.masksToBounds = true
            c.cornerRadius = Radius.surface
            c.cornerCurve = .continuous
            c.zPosition = 40 + m.z
            host.addSublayer(c)
            made.append(c)
            animate(c, "position", CGPoint(x: from.midX, y: from.midY), CGPoint(x: m.to.midX, y: m.to.midY), delay: m.delay)
            animate(c, "bounds.size", from.size, m.to.size, delay: m.delay)
            // Opaque all over, what it shows not reaching every edge (a
            // tile fitted into its card): nothing behind seen through it.
            let grounds = [m.leaving?.ground, m.coming?.ground].compactMap { $0 }
            c.backgroundColor = grounds.last
            if grounds.count == 2 { animate(c, "backgroundColor", grounds[0], grounds[1], delay: m.delay) }
            // Each picture hung from the shape's top left, as wide as it.
            func hang(_ p: Pictured) -> CALayer {
                let r = p.whole
                let g = CALayer()
                g.anchorPoint = CGPoint(x: 0, y: 1)
                g.bounds = CGRect(origin: .zero, size: r.size)
                g.position = CGPoint(x: 0, y: m.to.height)
                g.backgroundColor = p.ground
                g.transform = CATransform3DMakeScale(m.to.width / r.width, m.to.width / r.width, 1)
                for (f, picture) in p.parts where picture != nil {
                    let l = CALayer()
                    l.contents = picture
                    l.contentsGravity = .resize
                    l.frame = f.offsetBy(dx: -r.minX, dy: -r.minY)
                    g.addSublayer(l)
                }
                c.addSublayer(g)
                func scale(_ shape: NSRect) -> CGFloat { shape.width / r.width * (shape.height < r.height / 2 ? m.shrink : 1) }
                g.transform = CATransform3DMakeScale(scale(m.to), scale(m.to), 1)
                animate(g, "position.y", from.height, m.to.height, delay: m.delay)
                animate(g, "transform.scale", scale(from), scale(m.to), delay: m.delay)
                return g
            }
            let leaving = m.leaving.map(hang)
            // What it becomes over what it was, coming in on the way; what
            // it was going once that's there.
            let coming = m.coming.map(hang)
            if let coming, let leaving {
                fade(coming, [0, 0, 1], [0, 0.2, 0.75], delay: m.delay)
                fade(leaving, [1, 1, 0], [0, 0.75, 1], delay: m.delay)
                leaving.opacity = 0
            } else if let coming, from.height < 22 {
                // Out of something slim (a row): what it says only once
                // there's room for it, not cut to a sliver of its top line.
                fade(coming, [0, 0, 1], [0, 0.1, 0.35], delay: m.delay)
                // Its ground over what it's out of only as it leaves it.
                fade(c, [0, 1], [0, 0.12], delay: m.delay)
            } else if let leaving, m.to.height < 30 {
                // Into one: gone before it's a sliver, the real one left.
                fade(leaving, [1, 1, 0], [0, 0.6, 0.85], delay: m.delay)
                leaving.opacity = 0
                fade(c, [1, 1, 0], [0, 0.8, 1], delay: m.delay)
                c.opacity = 0
            }
        }
        CATransaction.commit()
        return made
    }

    // MARK: Arriving

    /// Arrived at a tile (a link followed, a block gone to): its focus
    /// ring swells and glows and settles back, the eye led to where it's
    /// gone — the one ring, not another (a maximized tile, which has none,
    /// has one for the while).
    func markArrival(_ id: PlacementID) {
        guard id == focused, window != nil, !isHiddenOrHasHiddenAncestor else { return }
        if full == id {
            let r = FocusRingView(frame: bounds.insetBy(dx: Self.inset, dy: Self.inset))
            addSubview(r)
            r.pulse()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6 * Motion.slowdown) { r.removeFromSuperview() }
        } else if !focusRing.isHidden {
            focusRing.pulse()
        }
    }

    // MARK: Maximizing

    /// A tile maximized slides its edges out from its place to the whole
    /// grid, the rest staying under it till it's there; restored, they
    /// slide back in to its place over them — what it shows held at its
    /// top left, cut off or uncovered as they go, never stretched, as any
    /// tile moving. Laid out where it ends at once (a terminal resized
    /// once, not at every step) and its layers carried from where it was:
    /// Core Animation's, so nothing is laid out on the way. With Reduce
    /// motion, it fades in where it ends.
    private var zooming: PlacementID?
    private func zoom(_ id: PlacementID, from source: NSRect) {
        guard let tile = tile(id) else {
            zooming = nil
            return needsLayout = true
        }
        let body = tile.view.frame
        let dest = Self.card(of: body)
        guard source.width > 1, source.height > 1, dest.width > 1, dest.height > 1, source != dest else {
            zooming = nil
            needsLayout = true
            return
        }
        zooming = id
        CATransaction.begin()
        CATransaction.setCompletionBlock { [weak self] in
            guard let self, self.zooming == id else { return }
            self.zooming = nil
            self.needsLayout = true
        }
        if Motion.reduced {
            for l in ([tile.view, pills[id], badges[id]] as [NSView?]).compactMap({ $0?.layer }) {
                Ghost.fadeIn(l, over: Motion.base, key: "zoom")
            }
        } else {
            // Over the rest on the way, the bar and what goes with the
            // tile too; the body's edges and the bar's from where it was.
            raise(id, from: source, among: lastCompanionsShown, by: 20)
            slide(tile.view, to: body, from: Self.body(of: source))
            if let pill = pills[id] {
                slide(pill, to: pill.frame, from: Self.bar(of: source))
            }
        }
        CATransaction.commit()
    }

    /// A soft shadow under each card in the light, none in the dark
    /// (where the cards are lighter than the wash already).
    private func layoutShadows(_ bodies: [PlacementID: NSRect], gliding: Bool) {
        let dark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        let wanted = dark || full != nil ? [:] : bodies.filter { $0.value != .zero }
        for (id, l) in shadowLayers where wanted[id] == nil {
            l.removeFromSuperlayer()
            shadowLayers.removeValue(forKey: id)
        }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for (id, body) in wanted {
            let l = shadowLayers[id] ?? {
                let l = CAShapeLayer()
                l.zPosition = -10
                Elevation.tile.apply(to: l)
                layer?.insertSublayer(l, at: 0)
                shadowLayers[id] = l
                return l
            }()
            // In the theme's shade of its ground.
            let shade = Palette.current.backdrop.tileShadow
            l.shadowColor = shade.color.cgColor
            l.shadowOpacity = Float(shade.opacity)
            let card = Self.card(of: body)
            let path = CGPath(roundedRect: card, cornerWidth: Radius.surface, cornerHeight: Radius.surface, transform: nil)
            // Gliding with its card, from where it shows.
            if gliding, let was = (l.presentation() ?? l).path, was != path {
                for key in ["path", "shadowPath"] {
                    let a = CABasicAnimation(keyPath: key)
                    a.fromValue = key == "path" ? was : (l.presentation() ?? l).shadowPath ?? was
                    a.toValue = path
                    a.duration = Self.glide
                    a.timingFunction = Motion.travel
                    l.add(a, forKey: key)
                }
            }
            l.path = path
            l.shadowPath = path
            l.fillColor = NSColor.black.withAlphaComponent(0.001).cgColor
        }
        CATransaction.commit()
    }

    private func dragColumnDivider(_ i: Int, to x: CGFloat) {
        let frames = columnFrames()
        let minWidth: CGFloat = 120
        let left = frames[i].minX, right = frames[i + 1].maxX
        let split = min(max(x, left + minWidth), right - minWidth)
        let usable = bounds.width - CGFloat(columns.count - 1) * Self.gap
        let pair = fractions[i] + fractions[i + 1]
        fractions[i] = (split - left) / usable
        fractions[i + 1] = pair - fractions[i]
        needsLayout = true
    }

    /// The line between two columns double-clicked: the two share their
    /// width evenly (gliding there).
    private func evenColumns(_ i: Int, line: NSView? = nil) {
        guard i + 1 < fractions.count, evening == nil else { return }
        let pair = fractions[i] + fractions[i + 1], from = fractions[i]
        glideLine(line, vertical: true, step: { [weak self] t in
            guard let self, i + 1 < self.fractions.count else { return }
            self.fractions[i] = from + (pair / 2 - from) * t
            self.fractions[i + 1] = pair - self.fractions[i]
        }, done: { [weak self] in
            guard let self else { return }
            self.delegate?.gridResized(fractions: self.fractions)
        })
    }

    /// The line between two tiles in a column double-clicked: the two
    /// share their height evenly.
    func evenRows(column c: Int, above a: PlacementID, below b: PlacementID, line: NSView? = nil) {
        guard c < columns.count, evening == nil else { return }
        let n = Double(max(shownTiles(c).count, 1))
        let from = heights[a] ?? 1 / n
        let pair = from + (heights[b] ?? 1 / n)
        glideLine(line, vertical: false, step: { [weak self] t in
            guard let self else { return }
            self.heights[a] = from + (pair / 2 - from) * t
            self.heights[b] = pair - self.heights[a]!
        }, done: { [weak self] in
            guard let self else { return }
            self.delegate?.gridResized(heights: self.heights)
        })
    }

    /// Debugging: the focused tile dropped at a slot while its drag is
    /// still under way (the drag over a moment later), as a tile's drag
    /// drops it.
    func debugDropFocused(column: Int, at: Int, newColumn: Bool) -> String {
        guard let f = focused else { return "nothing focused" }
        dragging = true
        dropped = true
        delegate?.gridMove(f, column: column, at: at, newColumn: newColumn)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in self?.dragging = false }
        return "dropped"
    }

    /// Debugging: the line after column `i` double-clicked.
    func debugEvenColumns(_ i: Int) -> String {
        guard columnDividers.indices.contains(i) else { return "no line \(i)" }
        evenColumns(i, line: columnDividers[i])
        return "evening"
    }
    var debugFractions: String { fractions.map { String(format: "%.3f", $0) }.joined(separator: " ") + (evening != nil ? " (evening)" : "") }

    /// Evening two tiles' room, under way: stepped as a drag would move the
    /// line, the pointer riding on it.
    private var evening: Timer?

    /// A line moved to where `step` takes it (given 0…1, eased), over a
    /// glide, laid out at each step as a drag lays out (the tiles sized
    /// as it goes, not jumping and sliding); the pointer, on the line,
    /// carried with it across (`vertical`: a line between columns); then
    /// `done`, to keep where it ended.
    private func glideLine(_ line: NSView?, vertical: Bool, step: @escaping (Double) -> Void, done: @escaping () -> Void) {
        let carry = { [weak self, weak line] in
            guard let self, let line, let window = self.window, !line.isHidden else { return }
            let mid = window.convertToScreen(line.convert(line.bounds, to: nil))
            let now = NSEvent.mouseLocation
            Pointer.warp(to: vertical ? NSPoint(x: mid.midX, y: now.y) : NSPoint(x: now.x, y: mid.midY))
        }
        guard !Motion.reduced else {
            step(1)
            needsLayout = true
            layoutSubtreeIfNeeded()
            carry()
            return done()
        }
        let start = CACurrentMediaTime(), duration = max(Self.glide, 0.18)
        dividerDragging = true
        let timer = Timer(timeInterval: 1.0 / 60, repeats: true) { [weak self] timer in
            MainActor.unchecked {
                guard let self else { return timer.invalidate() }
                let x = min((CACurrentMediaTime() - start) / duration, 1)
                // Eased out: quick, then settling.
                step(1 - pow(1 - x, 3))
                self.needsLayout = true
                self.layoutSubtreeIfNeeded()
                carry()
                guard x >= 1 else { return }
                timer.invalidate()
                self.evening = nil
                self.dividerDragging = false
                done()
            }
        }
        evening = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    /// The line between two tiles dragged: the two share their room by
    /// where it is. Pushed past a tile's least height, that tile is pushed
    /// out (its room to the other side; a share of 0, docked when the drag
    /// ends, §3.1), and the line goes on against the next, until all above
    /// or below are out and the tile that grew has the column.
    private func dragRowDivider(column c: Int, above a0: PlacementID, below b0: PlacementID, to y: CGFloat) {
        guard c < columns.count else { return }
        let column = columns[c]
        guard let ia = column.firstIndex(where: { $0.shown.id == a0 }), let ib = column.firstIndex(where: { $0.shown.id == b0 }) else { return }
        let aboves = column[...ia].filter { !pushedOut($0.shown.id) }
        let belows = column[ib...].filter { !pushedOut($0.shown.id) }
        guard let a = aboves.last?.shown.id, let b = belows.first?.shown.id else { return }
        let f = columnFrames()[c]
        let frames = tileFrames(column: c, in: f)
        guard let ra = column.firstIndex(where: { $0.shown.id == a }), let rb = column.firstIndex(where: { $0.shown.id == b }) else { return }
        let minHeight: CGFloat = 24
        let top = frames[ra].maxY, bottom = frames[rb].minY
        let n = Double(max(shownTiles(c).count, 1))
        func share(_ id: PlacementID) -> Double { heights[id] ?? 1 / n }
        if y > top - minHeight {
            heights[b] = share(b) + share(a)
            heights[a] = 0
            needsLayout = true
            return dragRowDivider(column: c, above: a0, below: b0, to: y)
        }
        if y < bottom + minHeight {
            heights[a] = share(a) + share(b)
            heights[b] = 0
            needsLayout = true
            return dragRowDivider(column: c, above: a0, below: b0, to: y)
        }
        let split = min(max(y, bottom + minHeight), top - minHeight)
        let pair = share(a) + share(b)
        let total = top - bottom
        heights[a] = pair * Double((top - split) / total)
        heights[b] = pair - heights[a]!
        needsLayout = true
    }

    /// Whether some pill is a field just now, the keyboard in it.
    var isEditingPill: Bool { pills.values.contains { $0.isEditing } }

    /// A tile's pill as a field for `edit` (a note's name).
    func editPill(_ id: PlacementID, _ edit: PillEdit) {
        pills[id]?.beginEditing(edit)
    }

    /// ⌘L: the focused tile's pill edits what its view offers, if anything.
    func editFocusedPill() -> Bool {
        guard let focused, let tile = tile(focused),
              let edit = tile.view.pillEdit, let pill = pills[focused] else { return false }
        pill.beginEditing(edit)
        return true
    }

    override func updateTrackingAreas() {
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
        super.updateTrackingAreas()
    }

    /// The pointer over the grid itself does nothing.
    override func mouseMoved(with event: NSEvent) {}

    // MARK: Dragging tiles

    /// Whether the tile drag under way began with ⌥ (or ⌥ is held now):
    /// dropped on a tile, it takes its place, that tile docked under it.
    private var coverDrag = false

    /// `thing`: what it stands for, whatever's held (dragged by its bar's
    /// icon).
    private func beginDrag(of placement: PlacementID, event: NSEvent, from view: NSView, thing: Bool = false) {
        let item = NSPasteboardItem()
        let shown = tile(placement)?.shown
        coverDrag = event.modifierFlags.contains(.option)
        if thing || event.modifierFlags.contains(.shift) {
            // ⇧-drag, or by the icon: not the tile but the thing it is
            // (§3.11) — its link for a note, its path for a shell, a tile
            // of it elsewhere.
            guard let block = shown?.block, let thing = Drags.block?(block.id, [.shift]) else { return }
            for t in thing.types {
                if let d = thing.data(forType: t) { item.setData(d, forType: t) }
            }
            pathDrag = true
        } else {
            item.setString(placement, forType: .manifoldPlacement)
            // Out of the window (the Finder, Mail): a file here goes as its file.
            var dir: ObjCBool = false
            if let path = shown?.block?.path, shown?.block?.id.host == delegate?.gridLocalHost,
               FileManager.default.fileExists(atPath: path, isDirectory: &dir), !dir.boolValue {
                item.setString(URL(fileURLWithPath: path).absoluteString, forType: .fileURL)
            }
            pathDrag = false
        }
        // Another host's file or folder: promised, as its folder's rows are —
        // the Finder gets it, fetched when it's dropped. (In Manifold the
        // item goes on as it was: a tile moved, or a thing, from host to host.)
        var writer: NSPasteboardWriting = item
        if let b = shown?.block, let path = b.path, b.id.host != delegate?.gridLocalHost {
            writer = Drags.promise(of: .init(host: b.id.host, path: path, isDirectory: b.kind == .directory), carrying: item) ?? item
        }
        let dragItem = NSDraggingItem(pasteboardWriter: writer)
        let image = BlockDragImage.make(for: shown)
        let p = view.convert(event.locationInWindow, from: nil)
        dragItem.setDraggingFrame(NSRect(x: p.x - 24, y: p.y - image.size.height / 2, width: image.size.width,
                                         height: image.size.height), contents: image)
        if !pathDrag { delegate?.gridDragChanged(true) }
        let session = view.beginDraggingSession(with: [dragItem], event: event, source: self)
        DragPill.dress(session, from: view, at: NSEvent.mouseLocation)
    }

    /// A tile's outline ticks at its content's upper right, in from the
    /// scroll bar, over the content (they take no room of their own).
    private func placeTicks(of tile: Tile, in body: NSRect, shown: Bool) {
        guard let t = ticks[tile.shown.id] else { return }
        let size = OutlineTicks.size
        t.frame = NSRect(x: body.maxX - ScrubberView.width - size.width - 2, y: body.maxY - tile.view.outlineInset - size.height - 6,
                         width: size.width, height: size.height)
        // Not while finding: the find pill's there, doing the same job.
        t.available = shown && body.height >= 3 * size.height && !FindHost.isFinding(tile.view)
        keep(t, above: tile.view)
    }

    /// Debugging: a point a drop at slot `at` of column `column` would be
    /// made at (the upper part of the tile it goes before; below the last).
    func debugSlotPoint(column c: Int, at: Int) -> NSPoint {
        let frames = columnFrames()
        guard frames.indices.contains(c) else { return .zero }
        let tiles = tileFrames(column: c, in: frames[c])
        guard let last = tiles.last else { return NSPoint(x: frames[c].midX, y: frames[c].midY) }
        return at < tiles.count ? NSPoint(x: frames[c].midX, y: tiles[at].maxY - 3) : NSPoint(x: frames[c].midX, y: last.minY + 3)
    }

    /// Debugging: the focused tile's ticks, and its outline.
    func debugTicks(_ id: PlacementID) -> OutlineTicks? { ticks[id] }
    /// Debugging: a tile's pill.
    func debugPill(_ id: PlacementID) -> TilePill? { pills[id] }

    /// A tile's own buttons changed (a page could go back, or loads): its bar
    /// shows them as they are.
    func barChanged(_ id: PlacementID) {
        guard let view = tile(id)?.view else { return }
        pills[id]?.viewButtons = view.barButtons
    }

    /// A tile's own sidebar shown or put away: its bar's button says so.
    func sidebarChanged(_ id: PlacementID) {
        guard let view = tile(id)?.view else { return }
        pills[id]?.sidebar = view.hasSidebar ? view.sidebarShown : nil
    }

    /// A tile's menu, under the pointer, as a menu is.
    private func showPillMenu(_ id: PlacementID) {
        guard let menu = delegate?.gridPillMenu(for: id), let pill = pills[id] else { return }
        let at = NSApp.currentEvent.map { pill.convert($0.locationInWindow, from: nil) } ?? NSPoint(x: pill.bounds.midX, y: 0)
        menu.popUp(positioning: nil, at: NSPoint(x: at.x, y: at.y - 4), in: pill)
    }

    /// The tile's frame each links' badge was last placed against.
    private var badgeRects: [PlacementID: NSRect] = [:]

    private func placeBadge(_ badge: LinkBadge, of id: PlacementID, in r: NSRect) {
        badgeRects[id] = r
        badge.isHidden = false
        badge.fansDown = true
        // The bar has settled what room the pill gets and what else shows.
        pills[id]?.layoutSubtreeIfNeeded()
        let size = badge.wantedSize
        // From after the tile's symbol to the buttons: the faces fan out
        // over the title, and a stack of more is scrubbed across it.
        let left = r.minX + 32
        let w = max(r.maxX - (pills[id]?.rightTaken ?? TilePill.rightChrome) - 8 - left, min(size.width, 60))
        let h = min(size.height, r.height - 12)
        // Its faces in the bar, before the bar's buttons; its frame as wide
        // as they fan out, leftward over the title.
        let capsuleTop = r.maxY - (Self.barHeight - LinkBadge.capsuleHeight) / 2
        let taken = pills[id]?.rightTaken ?? TilePill.rightChrome
        let given = pills[id]?.linkGiven ?? .infinity
        badge.capsuleLimit = given
        badge.isHidden = given < badge.foldedWidth
        badge.frame = NSRect(x: r.maxX - taken - 8 - w, y: capsuleTop - h, width: w, height: h)
    }

    /// Whether the drag under way is a tile's ⇧-drag: the block as a thing (§3.11).
    private var pathDrag = false

    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        if pathDrag { return [.copy, .link, .generic] }
        // ⌥ copies to another workspace (as a file is copied); out of the
        // app, a file is copied.
        return context == .withinApplication ? [.move, .copy] : [.copy]
    }

    func draggingSession(_ session: NSDraggingSession, willBeginAt screenPoint: NSPoint) { DragCursor.began() }
    func draggingSession(_ session: NSDraggingSession, movedTo screenPoint: NSPoint) { DragCursor.moved() }

    func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
        DragCursor.ended()
        if !pathDrag { delegate?.gridDragChanged(false) }
        pathDrag = false
        coverDrag = false
    }

    /// Where a drop lands: at `at` in column `column` — a new column
    /// there, if `newColumn` — or on the tile `onto`; `rect` shows it.
    private struct DropSlot {
        var column: Int
        var at: Int
        var rect: NSRect
        var newColumn = false
        var onto: PlacementID?
    }

    /// On a tile's pill (or, ⌥, the tile): in its place, it docked under
    /// the one dropped (a placement, not the one dragged). Near a column's
    /// side: a new column there. Else between two tiles (or above the
    /// first, below the last) of the column under the pointer.
    private func dropTarget(at point: NSPoint, dragged: PlacementID?) -> DropSlot? {
        let frames = columnFrames()
        guard !frames.isEmpty else { return DropSlot(column: 0, at: 0, rect: bounds, newColumn: true) }
        if dragged != nil, coverDrag || NSEvent.modifierFlags.contains(.option) {
            // ⌥: onto the tile under the pointer, whole — its shape the sign.
            for c in columns.indices {
                for (i, t) in columns[c].enumerated() where t.shown.id != dragged && !t.view.isHidden {
                    if t.view.frame.contains(point) { return DropSlot(column: c, at: i, rect: t.view.frame, onto: t.shown.id) }
                }
            }
        }
        if dragged != nil {
            for c in columns.indices {
                for (i, t) in columns[c].enumerated() where t.shown.id != dragged {
                    guard let pill = pills[t.shown.id], !pill.isHidden else { continue }
                    let capsule = pill.capsule(in: self).insetBy(dx: -4, dy: -4)
                    if capsule.contains(point) { return DropSlot(column: c, at: i + 1, rect: capsule, onto: t.shown.id) }
                }
            }
        }
        for (c, f) in frames.enumerated() where point.x >= f.minX && point.x <= f.maxX + Self.gap {
            let edge = min(f.width * 0.2, 80)
            if point.x < f.minX + edge {
                return DropSlot(column: c, at: 0, rect: NSRect(x: f.minX, y: f.minY, width: f.width / 2, height: f.height), newColumn: true)
            }
            if point.x > f.maxX - edge {
                return DropSlot(column: c + 1, at: 0, rect: NSRect(x: f.midX, y: f.minY, width: f.width / 2, height: f.height), newColumn: true)
            }
            let tiles = tileFrames(column: c, in: f)
            for (i, r) in tiles.enumerated() where point.y >= r.minY && point.y <= r.maxY {
                if point.y > r.midY {
                    return DropSlot(column: c, at: i, rect: NSRect(x: r.minX, y: r.midY, width: r.width, height: r.height / 2))
                }
                return DropSlot(column: c, at: i + 1, rect: NSRect(x: r.minX, y: r.minY, width: r.width, height: r.height / 2))
            }
            return DropSlot(column: c, at: tiles.count, rect: f)
        }
        return nil
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation { draggingUpdated(sender) }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        let point = convert(sender.draggingLocation, from: nil)
        if convert(point, to: nil).x < 8 { delegate?.gridDragAtLeftEdge() }
        let pb = sender.draggingPasteboard
        // A thing (§3.11): opened where it lands, or linked to the tile it's over.
        if Dragged(pb) != nil {
            let op = Dropping.updated(self, sender)
            if op.isEmpty { hideDrop() }
            return op
        }
        let isBlock = pb.string(forType: .manifoldPlacement) != nil || pb.string(forType: .manifoldBlock) != nil
        let arrangement = pb.string(forType: .manifoldArrangement).flatMap(BlockID.init(string:))
        guard isBlock || (arrangement != nil && delegate?.gridCanDrop(arrangement!) == true),
              let target = dropTarget(at: point, dragged: pb.string(forType: .manifoldPlacement)) else {
            hideDrop()
            return []
        }
        showDrop(target.rect)
        drop = target
        dropCovers = target.onto != nil && (coverDrag || NSEvent.modifierFlags.contains(.option))
        // ⌥ leaves only a copy on offer: a tile from another workspace is
        // copied here; one of this workspace's takes another's place.
        return sender.draggingSourceOperationMask.contains(.move) ? .move : .copy
    }

    /// The drag gone from it (nil: a view in it, or the palette, has it now).
    override func draggingExited(_ sender: NSDraggingInfo?) {
        hideDrop()
        if let sender { DropBadge.show(nil, for: sender, over: self) }
    }
    override func draggingEnded(_ sender: NSDraggingInfo) { hideDrop() }

    private func showDrop(_ rect: NSRect) {
        if drop?.rect != rect || dropOverlay.isHidden {
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = dropOverlay.isHidden || Motion.reduced ? 0 : Motion.fast
                dropOverlay.animator().frame = rect
            }
            dropOverlay.isHidden = false
        }
    }

    // MARK: A card becoming its tile (⌃⇥)

    /// Pictures on their way, and the tiles kept out of sight meanwhile:
    /// all put back at once when the next switch comes before they're
    /// done, never one flight under another.
    private var flying: [CALayer] = []
    private var unseen: [NSView] = []


    static func describe(_ flying: [CALayer]) -> String {
        flying.compactMap { l in
            guard l.superlayer != nil else { return nil }
            let p = l.presentation() ?? l
            let inner = (l.sublayers ?? []).map { g in
                let q = g.presentation() ?? g
                let pictures = (g.sublayers ?? []).filter { $0.contents != nil }.count
                return "scale=\(String(format: "%.2f", q.transform.m11)) opacity=\(String(format: "%.2f", q.opacity)) pictures=\(pictures)"
            }
            return "\(l.name ?? "morph") \(p.frame.integral) [\(inner.joined(separator: "; "))]"
        }.joined(separator: "\n")
    }

    private func land() {
        landingAt = nil
        flying.forEach { $0.removeFromSuperlayer() }
        flying = []
        unseen.forEach { $0.alphaValue = 1 }
        unseen = []
        pendingArrival = nil
    }

    /// Flights sent back the way they came, `speed` times as fast, from
    /// where they've got to; `view` fading out meanwhile. Then they're put
    /// away, `view` taken out, and `done`.
    static func foldBack(_ flights: [CALayer], began: CFTimeInterval?, fading view: NSView, speed: Double = 4, done: @escaping () -> Void) {
        let now = CACurrentMediaTime()
        var back: TimeInterval = 0
        for l in flights {
            let t = l.convertTime(now, from: nil)
            if let began { back = max(back, (t - began) / speed) }
            l.timeOffset = t
            l.beginTime = now
            l.speed = Float(-speed)
        }
        back = min(max(back, 0), 0.12)
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = back
            view.animator().alphaValue = 0
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + back) {
            flights.forEach { $0.removeFromSuperlayer() }
            view.removeFromSuperview()
            done()
        }
    }

    /// Where a tile's × is, in the window's terms (laid out as it ends, not
    /// as it moves there); nil if it has none showing.
    func closeButtonInWindow(_ id: PlacementID) -> NSPoint? {
        layoutSubtreeIfNeeded()
        guard let pill = pills[id], !pill.isHidden, let r = pill.closeButtonFrame else { return nil }
        let f = pill.convert(r, to: nil)
        return NSPoint(x: f.midX, y: f.midY)
    }

    /// Flights hurried the rest of their way, their time carried on from
    /// where they are, so nothing jumps.
    static func hurry(_ layers: [CALayer]) {
        let now = CACurrentMediaTime()
        for l in layers where l.speed == 1 {
            l.timeOffset = l.convertTime(now, from: nil)
            l.beginTime = now
            l.speed = 4
        }
    }

    /// A tile chosen in a switcher, waiting to be laid out where it goes,
    /// and its card as it was, where it was: it becomes its tile from there.
    /// `host`: where the card is and becomes it (its terms), if not here —
    /// over a space sliding in, the place it slides to.
    private var pendingArrival: (id: PlacementID, card: Pictured?, from: NSRect, at: Date, host: NSView?)?

    /// The tile chosen is laid out: its card becomes it.
    private func arrive(_ id: PlacementID, card: Pictured?, from r: NSRect, in over: NSView? = nil) {
        guard let t = tile(id), let host = (over ?? self).layer else { return land() }
        // Drawn as it'll be first: it was out of sight till now.
        let body = shownBody(t) ?? t.view
        body.layoutSubtreeIfNeeded()
        body.displayIfNeeded()
        // A page's picture comes from the page, a moment later: the card
        // held where it is meanwhile.
        let landing = Date()
        landingAt = landing
        picturing(body, pills[id]) { [weak self] shown in
            guard let self, self.landingAt == landing else { return }
            self.debugArrival = shown.parts.first?.1.map { $0 as AnyObject }
            let to = over.map { self.convert(shown.whole, to: $0) } ?? shown.whole
            let held = self.flying.filter { $0.name == "waiting" || $0.name == "plate" }
            // As a bar comes out of its row: the card grown to the tile's
            // size where it is, then across into its place, becoming it.
            let scale = self.backingScale
            self.flying.append(Genie.flight(to, Genie.image(of: shown, scale: scale), ground: shown.ground, to: r, card?.parts.first?.1, ground: card?.ground,
                                            out: true, in: host, over: Motion.morph, scale: scale) { [weak self] in
                guard let self, self.landingAt == landing else { return }
                self.unseen.forEach { $0.alphaValue = 1 }
                self.unseen = []
                // Landed: the rest put by with it, so none is drawn over
                // the tile once it's there.
                held.forEach { $0.removeFromSuperlayer() }
                self.flying.forEach { $0.removeFromSuperlayer() }
                self.flying = []
            })
            held.filter { $0.name == "waiting" }.forEach { $0.removeFromSuperlayer() }
        }
    }

    /// Debugging: the last tile arrived at's picture.
    var debugArrival: AnyObject?

    /// The arrival under way: a later one (or `land`) puts it by.
    private var landingAt: Date?

    /// A card held where it is till its tile is laid out.
    private func hold(_ picture: CGImage?, ground: CGColor, at r: NSRect, in view: NSView) {
        guard let host = view.layer else { return }
        let w = Ghost.layer(picture, at: r, ground: ground, z: 40)
        w.name = "waiting"
        w.cornerRadius = Radius.surface
        w.cornerCurve = .continuous
        host.addSublayer(w)
        flying.append(w)
    }

    /// A card chosen elsewhere (⌃⇥'s), where it is in `view`'s terms,
    /// becoming tile `id` once the tile's laid out where it goes — the tile
    /// out of sight till then (a second at most).
    func becomeTile(_ id: PlacementID, from card: GridView.Pictured, picture: CGImage?, at r: NSRect, in view: NSView) {
        land()
        let at = Date()
        hold(picture, ground: card.ground ?? .clear, at: r, in: view)
        pendingArrival = (id, card, r, at, view)
        // Its focus ring with it: waiting for its tile.
        for v in [tile(id)?.view, pills[id], tileSummaries[id], id == focused ? focusRing : nil].compactMap({ $0 }) {
            v.alphaValue = 0
            unseen.append(v)
        }
        needsLayout = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
            guard let self, self.pendingArrival?.at == at else { return }
            self.land()
        }
    }

    /// Every tile, column by column.
    private var tiles: [Tile] { columns.flatMap { $0 } }

    private func tile(_ id: PlacementID) -> Tile? { tiles.first { $0.shown.id == id } }

    /// The shown tile under a point.
    private func tile(at point: NSPoint) -> Tile? {
        for c in columns.indices {
            // The tile, its bar too (a link dropped on a tile's name links to it).
            for t in columns[c] where !pushedOut(t.shown.id) && !t.view.isHidden
                && (t.view.frame.contains(point) || pills[t.shown.id].map { !$0.isHidden && $0.frame.contains(point) } == true) { return t }
        }
        return nil
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        DropBadge.hush()
        defer { hideDrop() }
        dropped = true
        let pb = sender.draggingPasteboard
        if Dragged(pb) != nil { return Dropping.perform(self, sender) }
        guard let target = drop else { return false }
        if let placement = pb.string(forType: .manifoldPlacement) {
            if let onto = target.onto {
                delegate?.gridCover(placement, over: onto)
            } else {
                delegate?.gridMove(placement, column: target.column, at: target.at, newColumn: target.newColumn)
            }
            return true
        }
        if let arrangement = pb.string(forType: .manifoldArrangement).flatMap(BlockID.init(string:)) {
            delegate?.gridDropArrangement(arrangement, column: target.newColumn ? target.column : target.column + 1)
            return true
        }
        if let block = pb.string(forType: .manifoldBlock).flatMap(BlockID.init(string:)) {
            delegate?.gridBring(block, column: target.column, at: target.at, newColumn: target.newColumn)
            return true
        }
        return false
    }

    private func hideDrop() {
        dropOverlay.isHidden = true
        drop = nil
        dropCovers = false
    }

    /// A shadow under each card, in the light (§3.1): the cards lifted a
    /// little off the wash.
    private var shadowLayers: [PlacementID: CAShapeLayer] = [:]
    /// Where each tile was laid out last, so a tile that moves (placed,
    /// closed, grown, docked) glides there, while a window resized or
    /// a divider dragged lays out at once.
    private var lastFrames: [PlacementID: NSRect] = [:]
    private var lastLayoutBounds: NSRect = .zero
    private var dividerDragging = false
    /// Where each tile's bar was laid out last (where it is going, while it glides).
    private var barTargets: [PlacementID: NSRect] = [:]
    /// A bar clicked to grow its tile: the pointer goes where it was on
    /// the bar once the grow has moved the bar (§3.1), so a click again
    /// grows again. Given up after a moment if nothing moved.
    private var pendingWarp: (id: PlacementID, at: NSPoint, from: NSRect, since: Date)?

    private func warpIfGrown() {
        guard let w = pendingWarp else { return }
        guard let bar = barTargets[w.id], let window else { pendingWarp = nil; return }
        if bar != w.from {
            pendingWarp = nil
            let p = convert(NSPoint(x: bar.minX + w.at.x, y: bar.minY + w.at.y), to: nil)
            Pointer.warp(to: window.convertPoint(toScreen: p))
        } else if Date().timeIntervalSince(w.since) > 1 {
            pendingWarp = nil
        }
    }
}

/// The host a block lives on, when that isn't its workspace's host: a
/// capsule after the name — a server's symbol and the host's name — the
/// same on every kind of block.
final class HostPill: NSView {
    private let icon = NSImageView()
    private let label = NSTextField(labelWithString: "")
    var host: String? {
        didSet {
            guard host != oldValue else { return }
            label.stringValue = host ?? ""
            toolTip = host.map { "On \($0), not this space's host" }
            needsLayout = true
        }
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.cornerRadius = Radius.capsule(Self.height)
        layer?.cornerCurve = .continuous
        // A quiet grey capsule, as the chips are (not the accent's).
        themed { $0.layer?.backgroundColor = Theme.text.withAlphaComponent(0.07).cgColor }
        icon.image = Theme.symbol("server.rack", size: 9, weight: .semibold)
        icon.contentTintColor = Theme.secondaryText
        label.font = UIType.caption
        label.textColor = Theme.secondaryText
        label.lineBreakMode = .byTruncatingTail
        addSubview(icon)
        addSubview(label)
    }

    required init?(coder: NSCoder) { fatalError() }

    static let height: CGFloat = 18
    var wantedWidth: CGFloat { 7 + 12 + 3 + min(120, ceil(label.intrinsicContentSize.width) + 4) + 7 }

    override func layout() {
        super.layout()
        let h = bounds.height
        icon.frame = NSRect(x: 7, y: (h - 11) / 2, width: 12, height: 11)
        let lh = ceil(label.intrinsicContentSize.height)
        label.frame = NSRect(x: 22, y: ((h - lh) / 2).rounded(), width: max(0, bounds.width - 22 - 7), height: lh)
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

/// A tile's pill (§3.1), as Prism names the note at the top of its
/// column: a small opaque capsule of one width floating centered over the
/// tile's top, the content running underneath and showing nothing
/// through, with the block's symbol, its name (cut to fit) and its status
/// glyph. Dragged, it moves the tile; clicked, the tile's menu. Only the
/// capsule takes the mouse; around it, the tile does.
final class TilePill: NSView, NSTextFieldDelegate {
    /// Clicked, with where in the pill (its coordinates).
    /// Clicked: where, and with which modifiers held (the click's own,
    /// not whatever event the app last saw).
    var onClick: ((NSPoint, NSEvent.ModifierFlags) -> Void)?
    var onIconClick: ((NSEvent.ModifierFlags) -> Void)?
    /// ⌥-clicked: the path menu.
    var onPathClick: (() -> Void)?
    /// Dragged: the tile, or (from the icon) the thing it stands for.
    var onDragStart: ((NSEvent, _ thing: Bool) -> Void)?
    private let glass = NSView()
    private let icon = NSImageView()
    /// The icon's handle, folded out under the pointer (`IconHandle`).
    private let handle = IconHandle()
    private let name = NSTextField(labelWithString: "")
    private let glyph = StatusGlyph()
    /// The status in a word, when it needs you (`StatusMark`).
    private let statusPill = StatusPillView()
    /// The name shimmering while the block works.
    private lazy var shimmer = Shimmer(name)
    /// The block's host, when it isn't the workspace's (§8).
    private let hostPill = HostPill()
    /// On the icon, when it's over another in a pure stack ($EDITOR's):
    /// the only sign the other's there.
    private let stackBadge: NSImageView = {
        let v = NSImageView()
        v.image = Theme.symbol("doc.fill", size: 7, weight: .bold)
        v.contentTintColor = Theme.secondaryText
        v.wantsLayer = true
        v.layer?.cornerRadius = 5.5
        v.themed { $0.layer?.backgroundColor = Theme.panel.cgColor }
        v.isHidden = true
        v.toolTip = "Editing: closing the editor brings the terminal back"
        return v
    }()
    private let corner = IconButton(symbol: "arrow.up.left.and.arrow.down.right", size: 9, weight: .semibold, target: nil, action: nil)
    /// A field over the place while the pill edits it (a page's
    /// address), the name left as it is; over the name too when there's
    /// no room after it.
    private let editor = NSTextField()
    /// Whether the place (the grey after the name) is there to edit: a
    /// click on it edits, the I-beam over it says so.
    var editsPlace = false { didSet { if editsPlace != oldValue { window?.invalidateCursorRects(for: self) } } }
    private var edit: PillEdit?
    /// Completing what's typed (an address, as Chrome's bar does): what was
    /// typed (the inline completion aside), the completions under the field,
    /// and the one chosen — the first, the default, unless ↑↓ moved.
    private var typed = ""
    private var completions: [PillSuggestion] = []
    private var chosen = 0
    var isEditing: Bool { edit != nil }
    var onToggleFull: (() -> Void)?
    var onClose: (() -> Void)?
    /// Right-clicked: the tile's menu.
    var onRightClick: ((NSEvent) -> Void)?
    /// What the links' pill takes of the bar, left of the buttons.
    /// What the links' pill wants of the bar, its faces included; what
    /// it's given is `linkGiven`, after the shrinkage below.
    var linkWanted: CGFloat = 0 { didSet { if linkWanted != oldValue { needsLayout = true } } }
    private(set) var linkGiven: CGFloat = 0
    /// The links' room, or the buttons right of it, changed as the bar
    /// laid out (resized, a button shown, a status come or gone): for the
    /// capsule, which the grid places, to be placed again at once.
    var onLinkRoom: (() -> Void)?
    /// What `onLinkRoom` was last told: the buttons' width and the links' room.
    private var linkRoomSaid: (CGFloat, CGFloat) = (0, 0)
    /// Where the links fanned out over the bar begin (in the bar): the
    /// title and the place show up to there, fading out before it; nil,
    /// all of them.
    var fanEdge: CGFloat? { didSet { if fanEdge != oldValue { fadeForFan() } } }

    /// The title, the place and the host's chip, masked to fade out before
    /// the fan — only where the fan is over them.
    private func fadeForFan() {
        let fade: CGFloat = 22
        CATransaction.begin()
        CATransaction.setAnimationDuration(Motion.base)
        for v in [name, subtitle, hostPill] as [NSView] {
            v.wantsLayer = true
            guard let layer = v.layer else { continue }
            guard let edge = fanEdge.map({ $0 - 6 - v.frame.minX }), edge < v.bounds.width, !v.isHidden else {
                layer.mask = nil
                continue
            }
            let mask = (layer.mask as? CAGradientLayer) ?? CAGradientLayer()
            mask.startPoint = CGPoint(x: 0, y: 0.5)
            mask.endPoint = CGPoint(x: 1, y: 0.5)
            mask.colors = [NSColor.black.cgColor, NSColor.black.cgColor, NSColor.clear.cgColor, NSColor.clear.cgColor]
            let w = max(v.bounds.width, 1)
            let end = max(0, min(1, edge / w)), start = max(0, min(1, (edge - fade) / w))
            mask.locations = [0, NSNumber(value: Double(start)), NSNumber(value: Double(end)), 1]
            mask.frame = v.bounds
            layer.mask = mask
        }
        CATransaction.commit()
    }

    /// The links' pill shrunk: the arrow and the symbol; the arrow alone.
    static let linkCompact: CGFloat = 50
    static let linkMinimal: CGFloat = 30
    /// The least the name is shown at, before anything else gives way.
    static let nameMinimum: CGFloat = 56
    /// The tile shrunk to its bar alone: the bar rounded all round, a pill.
    var collapsed = false {
        didSet {
            guard collapsed != oldValue else { return }
            if let shown = lastShown { updateSubtitle(shown) }
            glass.layer?.maskedCorners = collapsed
                ? [.layerMinXMinYCorner, .layerMaxXMinYCorner, .layerMinXMaxYCorner, .layerMaxXMaxYCorner]
                : [.layerMinXMaxYCorner, .layerMaxXMaxYCorner]
        }
    }
    /// Maximize and close shown; off where the bar only names the tile.
    var showsButtons = true { didSet { if showsButtons != oldValue { needsLayout = true } } }
    private var downAt: NSPoint?
    /// The press was on the icon: a drag from it is the thing's.
    private var downOnIcon = false
    private var focused = false
    private var maximized = false
    private let subtitle = NSTextField(labelWithString: "")
    private let close = IconButton(symbol: "xmark", size: 9, weight: .semibold, target: nil, action: nil)
    /// The view's own sidebar (an outline, a PDF's pages), shown or not;
    /// nil, a view without one: no button.
    private let sidebarButton = IconButton(symbol: "sidebar.left", size: 10, weight: .medium, target: nil, action: nil)
    var sidebar: Bool? {
        didSet {
            guard sidebar != oldValue else { return }
            sidebarButton.contentTintColor = sidebar == true ? Theme.accent : Theme.secondaryText
            sidebarButton.toolTip = sidebar == true ? "Hide Outline (⌘/)" : "Show Outline (⌘/)"
            needsLayout = true
            // Its button come or gone (a view's outline arrived): the links'
            // pill, which the grid places before the buttons, placed again.
            if (sidebar == nil) != (oldValue == nil) { superview?.needsLayout = true }
        }
    }
    var onToggleSidebar: (() -> Void)?

    /// The view's own buttons (a page's back, forward and reload), before
    /// the bar's: as they look, the first to go when the bar is narrow.
    var viewButtons: [BarButton] = [] {
        didSet {
            guard viewButtons != oldValue else { return }
            while ownButtons.count < viewButtons.count {
                let b = IconButton(symbol: "circle", size: 10, weight: .medium, target: self, action: #selector(ownButtonClicked(_:)))
                addSubview(b)
                ownButtons.append(b)
            }
            for (i, b) in ownButtons.enumerated() {
                guard i < viewButtons.count else { b.isHidden = true; continue }
                let spec = viewButtons[i]
                b.tag = i
                b.image = Theme.symbol(spec.symbol, size: 11, weight: .medium)
                b.toolTip = spec.tooltip
                b.isEnabled = spec.enabled
                b.contentTintColor = spec.enabled ? Theme.secondaryText : Theme.secondaryText.withAlphaComponent(0.35)
            }
            needsLayout = true
            if viewButtons.count != oldValue.count { superview?.needsLayout = true }
        }
    }
    var onViewButton: ((Int) -> Void)?
    private var ownButtons: [IconButton] = []

    @objc private func ownButtonClicked(_ sender: NSButton) { onViewButton?(sender.tag) }

    static let height: CGFloat = GridView.barHeight
    /// What the bar's right end takes: close, maximize, and room.
    static let rightChrome: CGFloat = 54
    /// What the bar's right end takes now: its buttons (the links' pill
    /// is left of them, the status left of that).
    var rightTaken: CGFloat {
        var w: CGFloat = 10
        if !close.isHidden { w += 22 }
        if !corner.isHidden { w += 22 }
        if !sidebarButton.isHidden { w += 22 }
        let own = ownButtons.filter { !$0.isHidden }.count
        if own > 0 { w += CGFloat(own) * 22 + 4 }
        return w
    }

    /// The bar's frame in `view`'s coordinates (what a drop on it takes the place of).
    func capsule(in view: NSView) -> NSRect { convert(bounds, to: view) }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        glass.wantsLayer = true
        glass.layer?.cornerRadius = Radius.surface
        glass.layer?.cornerCurve = .continuous
        glass.layer?.maskedCorners = [.layerMinXMaxYCorner, .layerMaxXMaxYCorner]
        glass.layer?.borderWidth = 0
        glass.themed { $0.layer?.backgroundColor = Theme.panel.cgColor }
        addSubview(glass)
        icon.contentTintColor = Theme.secondaryText
        name.font = UIType.title
        name.textColor = Theme.text
        name.lineBreakMode = .byTruncatingTail
        name.alignment = .left
        subtitle.font = UIType.detail
        subtitle.textColor = Theme.secondaryText
        subtitle.lineBreakMode = .byTruncatingMiddle
        close.target = self
        close.action = #selector(closeClicked)
        close.toolTip = "Close (⌘W)"
        corner.target = self
        corner.action = #selector(cornerClicked)
        corner.toolTip = "Maximize"
        sidebarButton.target = self
        sidebarButton.action = #selector(sidebarClicked)
        sidebarButton.isHidden = true
        editor.isBordered = false
        editor.drawsBackground = false
        editor.focusRingType = .none
        editor.font = UIType.detail
        editor.cell?.usesSingleLineMode = true
        editor.cell?.lineBreakMode = .byTruncatingTail
        editor.delegate = self
        editor.isHidden = true
        handle.onIn = { [weak self] in self?.icon.isHidden = false }
        for v in [handle, icon, name, subtitle, glyph, statusPill, sidebarButton, corner, close, editor, hostPill, stackBadge] { addSubview(v) }
        hostPill.isHidden = true
        themed { $0.updateColors() }
    }

    @objc private func closeClicked() { onClose?() }
    /// Its × (in its own terms), if it shows one.
    var closeButtonFrame: NSRect? { close.isHidden ? nil : close.frame }

    /// Laid out at its new width, shown sliding there from `width` as its
    /// tile's edges slide: its glass's right edge going with the tile's,
    /// the buttons at its right riding on it, what's at its left staying.
    func slideEdges(from width: CGFloat, over duration: TimeInterval, _ timing: CAMediaTimingFunction) {
        let d = width - bounds.width
        guard abs(d) > 0.5 else { return }
        func animate(_ l: CALayer, _ key: String, from: Any, to: Any) {
            let a = CABasicAnimation(keyPath: key)
            a.fromValue = from
            a.toValue = to
            a.duration = duration
            a.timingFunction = timing
            l.add(a, forKey: "slideEdges." + key)
        }
        if let l = glass.layer {
            animate(l, "bounds.size.width", from: l.bounds.width + d, to: l.bounds.width)
            animate(l, "position.x", from: l.position.x + l.anchorPoint.x * d, to: l.position.x)
        }
        for v in subviews where v !== glass && !v.isHidden && v.frame.minX > bounds.midX {
            guard let l = v.layer else { continue }
            animate(l, "position.x", from: l.position.x + d, to: l.position.x)
        }
    }

    var debugDirty: String { !isDirty ? "clean" : isStale ? "amber" : "grey" }
    private var isDirty = false
    private var isStale = false

    // MARK: Editing in place

    /// The pill becomes a field for `e`, as wide as the tile allows, the
    /// text selected to type over.
    func beginEditing(_ e: PillEdit) {
        edit = e
        editor.stringValue = e.text
        editor.placeholderString = e.placeholder
        editor.textColor = Theme.text
        editor.font = e.overName ? name.font : subtitle.font
        subtitle.isHidden = true
        editor.isHidden = false
        needsLayout = true
        layoutSubtreeIfNeeded()
        window?.makeFirstResponder(editor)
        editor.currentEditor()?.selectAll(nil)
    }

    func endEditing() {
        guard edit != nil else { return }
        edit = nil
        closeCompletions()
        typed = ""
        if window?.firstResponder === editor.currentEditor() { window?.makeFirstResponder(nil) }
        editor.isHidden = true
        name.isHidden = false
        needsLayout = true
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        let listing = !completions.isEmpty
        switch selector {
        case #selector(moveDown(_:)), #selector(insertTab(_:)) where listing:
            choose(min(chosen + 1, completions.count - 1))
            return true
        case #selector(moveUp(_:)), #selector(insertBacktab(_:)) where listing:
            choose(max(chosen - 1, 0))
            return true
        case #selector(deleteBackward(_:)), #selector(deleteForward(_:)):
            // ⇧⌫ (⇧⌦): the chosen completion forgotten, as Chrome does.
            guard listing, NSApp.currentEvent?.modifierFlags.contains(.shift) == true else { return false }
            return forgetChosen()
        case #selector(insertNewline(_:)) where listing:
            // The completion chosen, if the field still says it; else what's in it.
            let c = completions[chosen]
            if c.run != nil || textView.string == c.fill || c.fillsOnly { return commitCompletion(chosen) }
            fallthrough
        case #selector(insertNewline(_:)):
            let text = editor.stringValue.trimmingCharacters(in: .whitespaces)
            let commit = edit?.commit
            // A name may be emptied (a note Untitled again); an address not.
            let emptied = edit?.overName == true
            endEditing()
            if !text.isEmpty || emptied { commit?(text) }
            return true
        case #selector(cancelOperation(_:)):
            // The first ⎋ closes the completions (and drops the inline one);
            // the second leaves the field.
            if listing {
                textView.string = typed
                closeCompletions()
                return true
            }
            endEditing()
            return true
        default:
            return false
        }
    }

    // MARK: Completions

    func controlTextDidChange(_ obj: Notification) {
        guard edit?.suggest != nil, let tv = editor.currentEditor() as? NSTextView else { return }
        let s = tv.string
        // Completed inline only typing on (not deleting, which takes the
        // completion away and leaves it away).
        let forward = s.count > typed.count && s.lowercased().hasPrefix(typed.lowercased())
        typed = s
        complete(inline: forward)
    }

    /// The completions for what's typed, the first chosen; with `inline`,
    /// the first completed in the field, the rest selected.
    private func complete(inline: Bool) {
        guard let suggest = edit?.suggest, let window else { return }
        completions = typed.trimmingCharacters(in: .whitespaces).isEmpty ? [] : suggest(typed)
        chosen = 0
        guard !completions.isEmpty else { return closeCompletions() }
        if inline, let first = completions.first, first.inline, first.fill.lowercased().hasPrefix(typed.lowercased()),
           first.fill.count > typed.count, let tv = editor.currentEditor() as? NSTextView {
            let rest = String(first.fill.dropFirst(typed.count))
            tv.string = typed + rest
            tv.setSelectedRange(NSRange(location: (typed as NSString).length, length: (rest as NSString).length))
        }
        var r = editor.convert(editor.bounds, to: nil)
        r.origin.x -= 8
        r.size.width = max(r.width + 16, 380)
        let q = typed.lowercased()
        let rows = completions.enumerated().map { i, c -> FloatingList.Row in
            let found = (c.title.lowercased() as NSString).range(of: q)
            return FloatingList.Row(title: c.title, detail: c.detail, symbol: c.symbol,
                                    action: { [weak self] in _ = self?.commitCompletion(i) },
                                    bold: found.location == NSNotFound || q.isEmpty ? nil : found)
        }
        FloatingList.shared.show(rows, for: self, in: window, place: .below(r), sticky: true)
        FloatingList.shared.choose(0)
    }

    /// ↑↓: another completion chosen, and in the field — the first, what
    /// was typed and its inline completion, as it was.
    private func choose(_ i: Int) {
        guard let tv = editor.currentEditor() as? NSTextView, completions.indices.contains(i) else { return }
        chosen = i
        FloatingList.shared.choose(i)
        let c = completions[i]
        if i == 0, c.inline, c.fill.lowercased().hasPrefix(typed.lowercased()) {
            tv.string = c.fill
            tv.setSelectedRange(NSRange(location: (typed as NSString).length, length: (c.fill as NSString).length - (typed as NSString).length))
        } else {
            tv.string = c.run != nil ? typed : c.fill
            tv.setSelectedRange(NSRange(location: (tv.string as NSString).length, length: 0))
        }
    }

    /// A completion chosen (⏎, or clicked): a name to type on from goes in
    /// the field; anything else is done.
    private func commitCompletion(_ i: Int) -> Bool {
        guard completions.indices.contains(i) else { return true }
        let c = completions[i]
        if c.fillsOnly, let tv = editor.currentEditor() as? NSTextView {
            tv.string = c.fill
            tv.setSelectedRange(NSRange(location: (c.fill as NSString).length, length: 0))
            typed = c.fill
            complete(inline: false)
            return true
        }
        let commit = edit?.commit
        endEditing()
        if let run = c.run { run() } else { commit?(c.commitText ?? c.fill) }
        return true
    }

    /// The chosen completion forgotten (a page from the history), the rest
    /// completed again.
    private func forgetChosen() -> Bool {
        guard completions.indices.contains(chosen), let remove = completions[chosen].remove,
              let tv = editor.currentEditor() as? NSTextView else { return false }
        remove()
        tv.string = typed
        complete(inline: false)
        return true
    }

    private func closeCompletions() {
        completions = []
        chosen = 0
        FloatingList.shared.hide(for: self)
    }

    /// Debugging: the field and its completions, the chosen one starred.
    var debugCompletions: String {
        let field = (editor.currentEditor() as? NSTextView).map { "field “\($0.string)” selected \(NSStringFromRange($0.selectedRange()))" } ?? "not editing"
        return field + "\n" + completions.enumerated().map { "\($0.offset == chosen ? "*" : " ")\($0.element.symbol) \($0.element.title)\($0.element.detail.isEmpty ? "" : " — " + $0.element.detail)" }.joined(separator: "\n")
    }

    /// Debugging: typed into the field, as keys would.
    func debugType(_ text: String) {
        guard let tv = editor.currentEditor() as? NSTextView else { return }
        tv.insertText(text, replacementRange: tv.selectedRange())
    }

    /// Debugging: a key in the field ("down", "up", "tab", "return", "escape", "delete", "shiftdelete").
    func debugKey(_ key: String) {
        guard let tv = editor.currentEditor() as? NSTextView else { return }
        if key == "shiftdelete" { _ = forgetChosen(); return }
        let selector: Selector = switch key {
        case "down": #selector(NSResponder.moveDown(_:))
        case "up": #selector(NSResponder.moveUp(_:))
        case "tab": #selector(NSResponder.insertTab(_:))
        case "return": #selector(NSResponder.insertNewline(_:))
        case "escape": #selector(NSResponder.cancelOperation(_:))
        default: #selector(NSResponder.deleteBackward(_:))
        }
        if !control(editor, textView: tv, doCommandBy: selector) { tv.doCommand(by: selector) }
    }

    func controlTextDidEndEditing(_ obj: Notification) {
        // The keyboard went elsewhere: the pill is itself again.
        DispatchQueue.main.async { [weak self] in self?.endEditing() }
    }

    @objc private func cornerClicked() { onToggleFull?() }
    @objc private func sidebarClicked() { onToggleSidebar?() }

    required init?(coder: NSCoder) { fatalError() }

    /// The symbol the icon shows, so it's set only when it changes.
    private var symbolName = ""

    /// Shown afresh on every render (each keystroke in a note is one):
    /// only what differs is touched, or the images and labels would be
    /// redone each time and seen to blink.
    func show(_ shown: Shown, focused: Bool, maximized: Bool = false) {
        stackBadge.isHidden = shown.stackedOver == nil
        // Shown again as it was — every render, a keystroke's in another
        // tile too — nothing to do: its block the same (by its version),
        // its place and state, the minute (what it says can be an age).
        let key = ShowKey(placement: shown.placement, version: shown.version, offline: shown.offline, foreignHost: shown.foreignHost,
                          caption: shown.caption, focused: focused, maximized: maximized, collapsed: collapsed,
                          minute: Int(Date().timeIntervalSince1970 / 60), favicon: shown.block?.web.flatMap { Favicons.image(forPage: $0.url) })
        if key == lastKey, shown.block != nil { return }
        lastKey = key
        if self.maximized != maximized || corner.image == nil {
            self.maximized = maximized
            corner.image = Theme.symbol(maximized ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right", size: 9, weight: .semibold)
            corner.toolTip = maximized ? "Restore (⇧⌘↩)" : "Maximize (⇧⌘↩)"
        }
        // A page: its site's icon, once seen; else the kind's symbol.
        if let favicon = shown.block?.web.flatMap({ Favicons.image(forPage: $0.url) }) {
            if icon.image !== favicon { icon.image = favicon }
            symbolName = ""
        } else if symbolName != shown.symbol {
            symbolName = shown.symbol
            icon.image = Theme.symbol(shown.symbol, size: IconHandle.markSize)
        }
        let title = shown.title + (shown.isDormant ? "  (dormant)" : "")
        // Edited and unsaved: a dot after the name, amber when the file
        // changed on disk under the edits (the menu says what to do).
        let stale = shown.block?.text?.stale == true
        if name.stringValue != title || isDirty != shown.isDirty || isStale != stale {
            isDirty = shown.isDirty
            isStale = stale
            if shown.isDirty {
                let s = NSMutableAttributedString(string: title + " •", attributes: [.font: name.font!, .foregroundColor: name.textColor!])
                s.addAttribute(.foregroundColor, value: stale ? StatusGlyph.amber : Theme.secondaryText, range: NSRange(location: title.count + 1, length: 1))
                name.attributedStringValue = s
            } else {
                name.stringValue = title
            }
            name.toolTip = shown.isDirty ? (stale ? "Edited, and the file changed on disk — the menu says which to keep" : "Edited — ⌘S saves") : nil
        }
        lastShown = shown
        updateSubtitle(shown)
        // From another host than the workspace's: the host in its pill.
        if hostPill.host != shown.foreignHost { hostPill.host = shown.foreignHost; needsLayout = true }
        showRest(shown, focused: focused)
    }

    /// What the bar was last shown for: its subtitle made again as the tile
    /// collapses or opens.
    private var lastShown: Shown?

    private struct ShowKey: Equatable {
        var placement: Placement
        var version: Int
        var offline: Bool
        var foreignHost: String?
        var caption: String?
        var focused, maximized, collapsed: Bool
        var minute: Int
        var favicon: NSImage?
    }
    private var lastKey: ShowKey?

    /// After the name, in grey: where it is — or, the tile down to its bar,
    /// what its summary card says first (a terminal's last command and how
    /// it ended, a note's first line), its content being out of sight.
    private func updateSubtitle(_ shown: Shown) {
        if collapsed, let s = shown.block?.summary() {
            let line = (s.lines.prefix(2) + [s.note].compactMap { $0 }).joined(separator: " · ")
            if subtitle.stringValue != line { subtitle.stringValue = line; needsLayout = true }
            return
        }
        // Where it is, after the name, in grey: a folder, an address.
        let place = (shown.block?.web?.url ?? shown.block?.place?.abbreviatingHome) ?? ""
        // Not when the name already says it (a terminal named for its
        // folder) — but a page's address always, being what's clicked to
        // type another.
        let tail = String(shown.title.drop(while: { $0 == "…" }))
        let said = place == shown.title || place == shown.path?.abbreviatingHome || (!tail.isEmpty && place.hasSuffix(tail))
        let where_ = said && shown.block?.web == nil ? "" : place
        if subtitle.stringValue != where_ { subtitle.stringValue = where_; needsLayout = true }
    }

    private func showRest(_ shown: Shown, focused: Bool) {
        // The status by the name (`StatusMark`): a pill only when it needs
        // you, the name shimmering while it works, dim when inactive.
        let mark = shown.offline ? StatusMark(.offline) : StatusMark(of: shown.block)
        if glyph.block != shown.block?.id { glyph.block = shown.block?.id }
        if glyph.look != mark.glyph { glyph.look = mark.glyph }
        if glyph.isHidden != (mark.glyph == nil) { glyph.isHidden = mark.glyph == nil }
        let pill: StatusPill.Kind? = shown.stackedOver != nil ? .note("Editing") : mark.pill
        if statusPill.kind != pill { statusPill.kind = pill }
        shimmer.on = mark.shimmer
        let fade: CGFloat = mark.dim ? 0.6 : 1
        if name.alphaValue != fade { name.alphaValue = fade }
        let tip = shown.offline ? "Its host can't be reached: as last seen" : StatusGlyph.tooltip(shown.block)
        if glyph.toolTip != tip { glyph.toolTip = tip }
        if statusPill.toolTip != tip { statusPill.toolTip = tip }
        if self.focused != focused {
            self.focused = focused
            updateColors()
        }
        needsLayout = true
    }

    /// Under the pointer in a fan: the one a click would take, marked
    /// with the accent around it.
    var hovered = false { didSet { if hovered != oldValue { updateColors() } } }

    private func updateColors() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            glass.layer?.borderColor = (hovered ? Theme.text.withAlphaComponent(0.3) : EdgeColor.subtle).cgColor
        }
        glass.layer?.borderWidth = hovered ? 1 : 0
        name.textColor = focused || hovered ? Theme.text : Theme.secondaryText
        icon.contentTintColor = focused || hovered ? Theme.text : Theme.secondaryText
    }

    /// Kept for the grid's asking: the bar is above the content, never
    /// over the text cursor, so it never gets out of the way.
    var dodging = false

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard !isHidden else { return nil }
        let p = convert(point, from: superview)
        guard bounds.contains(p) else { return nil }
        return super.hitTest(point) ?? self
    }

    override func layout() {
        super.layout()
        let h = bounds.height
        glass.frame = bounds
        var x: CGFloat = 10
        icon.frame = NSRect(x: x, y: (h - 14) / 2, width: 16, height: 14)
        handle.frame = icon.frame
        stackBadge.frame = NSRect(x: icon.frame.maxX - 6, y: icon.frame.minY - 4, width: 11, height: 11)
        if iconSpot != trackedSpot { updateTrackingAreas() }
        x += 22
        // Shrinkage (§3.1): as the bar narrows, what's on it gives way in
        // order, so the name keeps at least a little room — the place
        // goes first (below), then the links' pill shrinks to its arrow
        // and symbol, then to its arrow alone, then maximize goes, then
        // the pill altogether; the × and the status stay, and last the
        // name itself is cut.
        let showClose = showsButtons
        var showCorner = showsButtons
        var showSidebar = showCorner && sidebar != nil
        var showOwn = showCorner && !viewButtons.isEmpty
        let ownWidth = CGFloat(viewButtons.count) * 22 + 4
        var linkRoom: CGFloat = linkWanted > 0 ? linkWanted + 14 : 0
        let nameWanted = ceil(name.intrinsicContentSize.width) + 4
        let nameNeed = min(nameWanted, Self.nameMinimum)
        var showHost = hostPill.host != nil
        let hostWidth = hostPill.wantedWidth
        func spare() -> CGFloat {
            var used = x + 10 + linkRoom + (showHost ? hostWidth + 8 : 0)
            if showClose { used += 22 }
            if showCorner { used += 22 }
            if showSidebar { used += 22 }
            if showOwn { used += ownWidth }
            if !glyph.isHidden { used += StatusGlyph.size + 8 }
            if !statusPill.isHidden { used += statusPill.wanted.width + 8 }
            return bounds.width - used
        }
        // The view's own buttons go first of all: what the tile is matters more.
        if spare() < nameNeed, showOwn { showOwn = false }
        if spare() < nameNeed, linkWanted > 0 { linkRoom = min(linkRoom, Self.linkCompact + 14) }
        if spare() < nameNeed, linkWanted > 0 { linkRoom = min(linkRoom, Self.linkMinimal + 14) }
        if spare() < nameNeed, showSidebar { showSidebar = false }
        // The status's word gives way to a dot in its color before the
        // name gives way to it.
        statusPill.compact = false
        if spare() < nameNeed, !statusPill.isHidden { statusPill.compact = true }
        if spare() < nameNeed, showCorner { showCorner = false }
        // Narrower still, the pill goes altogether: the symbol and a bit of
        // the name say what the tile is; the links are a hover away in the
        // sidebar.
        if spare() < nameNeed, linkRoom > 0 { linkRoom = 0 }
        // Last of all, the host's pill: what's on another host says so
        // while there's any room to.
        if spare() < nameNeed, showHost { showHost = false }
        linkGiven = linkRoom > 0 ? linkRoom - 14 : 0
        var right = bounds.width - 10
        close.isHidden = !showClose
        if !close.isHidden {
            close.frame = NSRect(x: right - 16, y: (h - 16) / 2, width: 16, height: 16)
            right -= 22
        }
        corner.isHidden = !showCorner
        if !corner.isHidden {
            corner.frame = NSRect(x: right - 16, y: (h - 16) / 2, width: 16, height: 16)
            right -= 22
        }
        sidebarButton.isHidden = !showSidebar
        if showSidebar {
            sidebarButton.frame = NSRect(x: right - 16, y: (h - 16) / 2, width: 16, height: 16)
            right -= 22
        }
        // The view's own, a little apart from the bar's.
        for (i, b) in ownButtons.enumerated() {
            b.isHidden = !showOwn || i >= viewButtons.count
        }
        if showOwn {
            right -= 4
            for b in ownButtons.prefix(viewButtons.count).reversed() {
                b.frame = NSRect(x: right - 16, y: (h - 16) / 2, width: 16, height: 16)
                right -= 22
            }
        }
        if !pointerIn { showButtons(animated: false) }
        // The links' pill sits before the buttons (the grid puts it there,
        // by `rightTaken`); the status before it, by the name, whatever
        // else shows.
        right -= linkRoom
        if !statusPill.isHidden {
            let s = statusPill.wanted
            statusPill.frame = NSRect(x: right - s.width, y: ((h - s.height) / 2).rounded(), width: s.width, height: s.height)
            right -= s.width + 8
        }
        if !glyph.isHidden {
            glyph.frame = NSRect(x: right - StatusGlyph.size, y: (h - StatusGlyph.size) / 2, width: StatusGlyph.size, height: StatusGlyph.size)
            right -= StatusGlyph.size + 8
        }
        let th = ceil(name.intrinsicContentSize.height)
        let wanted = nameWanted
        let hostRoom = showHost ? hostWidth + 8 : 0
        let nw = min(wanted, max(0, right - x - hostRoom))
        name.frame = NSRect(x: x - 2, y: ((h - th) / 2).rounded() - 0.5, width: nw, height: th)
        shimmer.layout()
        var sx = x - 2 + nw + 8
        hostPill.isHidden = !showHost
        if showHost {
            hostPill.frame = NSRect(x: sx - 2, y: ((h - HostPill.height) / 2).rounded(), width: hostWidth, height: HostPill.height)
            sx += hostWidth + 6
        }
        let sh = ceil(subtitle.intrinsicContentSize.height)
        subtitle.frame = NSRect(x: sx, y: ((h - sh) / 2).rounded() - 0.5, width: max(0, right - sx), height: sh)
        if fanEdge != nil { fadeForFan() }
        if isEditing {
            // Over the address, where it was; over the name when the
            // address would have too little room.
            subtitle.isHidden = true
            let roomy = edit?.overName != true && right - sx >= 160
            name.isHidden = !roomy
            let ex = roomy ? sx - 2 : x - 2
            let eh = ceil(editor.intrinsicContentSize.height)
            editor.frame = NSRect(x: ex, y: ((h - eh) / 2).rounded(), width: max(0, right - ex), height: eh)
        } else {
            subtitle.isHidden = subtitle.stringValue.isEmpty || right - sx < 40
        }
        window?.invalidateCursorRects(for: self)
        let said = (rightTaken, linkGiven)
        if said != linkRoomSaid {
            linkRoomSaid = said
            onLinkRoom?()
        }
    }

    /// The place, where it's to edit (a page's address), as far as its
    /// text goes: there a click edits it.
    private var placeRect: NSRect? {
        guard editsPlace, !isEditing, !subtitle.isHidden else { return nil }
        let f = subtitle.frame
        let w = min(f.width, ceil(subtitle.intrinsicContentSize.width) + 4)
        return NSRect(x: f.minX - 4, y: 0, width: w + 8, height: bounds.height)
    }

    /// Debugging: where the place to edit is, and the field and name while editing (window coordinates).
    var debugEdit: String {
        func w(_ r: NSRect) -> String { NSStringFromRect(convert(r, to: nil)) }
        return "place=\(placeRect.map(w) ?? "-") editing=\(isEditing)" + (isEditing ? " editor=\(w(editor.frame)) name=\(name.isHidden ? "hidden" : w(name.frame)) text=\(editor.stringValue)" : "")
    }

    /// Whether a point (the pill's coordinates) is on the place to edit.
    func isOnPlace(_ p: NSPoint) -> Bool { placeRect?.contains(p) ?? false }

    /// Where the icon takes the pointer: clicked, its menu; dragged, the
    /// thing the tile stands for.
    private var iconSpot: NSRect { icon.frame.insetBy(dx: -8, dy: -6) }
    private var trackedSpot: NSRect?

    // The pointer on the icon: its handle folds out, to be taken. On the
    // bar: its buttons come (§3.1, as Dia's tabs' ×), gone again after.
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        trackedSpot = iconSpot
        addTrackingArea(NSTrackingArea(rect: iconSpot, options: [.mouseEnteredAndExited, .activeInActiveApp], owner: self, userInfo: ["icon": true]))
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect], owner: self, userInfo: ["bar": true]))
    }

    override func mouseEntered(with event: NSEvent) {
        if event.trackingArea?.userInfo?["bar"] != nil { return pointerIn = true }
        setHandle(NSEvent.pressedMouseButtons == 0)
    }
    override func mouseExited(with event: NSEvent) {
        if event.trackingArea?.userInfo?["bar"] != nil { return pointerIn = false }
        setHandle(false)
    }

    /// The pointer on the bar: its buttons shown; else only its icon,
    /// name and status. Their room is kept, so nothing moves as they come.
    var pointerIn = false { didSet { if pointerIn != oldValue { showButtons(animated: true) } } }
    /// Buttons always shown: a tile's controls stay visible (hidden till
    /// hovered, they moved the links' pill and hid what could be done).
    static var buttonsAlways = true

    private func showButtons(animated: Bool) {
        let a: CGFloat = pointerIn || Self.buttonsAlways ? 1 : 0
        let all = [close, corner, sidebarButton] + ownButtons
        guard animated, !Motion.reduced else { for b in all { b.alphaValue = a }; return }
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = Motion.fast
            for b in all { b.animator().alphaValue = a }
        }
    }

    private func setHandle(_ out: Bool) {
        guard handle.out != out else { return }
        handle.set(out: out, image: icon.image, tint: icon.contentTintColor, mark: symbolName)
        if out { icon.isHidden = true }
    }

    /// Debugging: the icon's handle folded out or in, and how it is.
    func debugHandle(_ arg: String) -> String {
        if arg == "on" || arg == "off" { setHandle(arg == "on") }
        return handle.debugState
    }

    /// The open hand over the bar, which drags, and over the icon, which
    /// drags what the tile stands for (and clicked, its menu); the
    /// pointing hand over maximize and close; the I-beam over an address
    /// to edit.
    private var cursorSpots: [(NSRect, NSCursor)] {
        var spots: [(NSRect, NSCursor)] = [(iconSpot, .openHand)]
        for b in [corner, close] where !b.isHidden { spots.append((b.frame, .pointingHand)) }
        if let r = placeRect { spots.append((r, .iBeam)) }
        return spots.sorted { $0.0.minX < $1.0.minX }
    }

    override func resetCursorRects() {
        let spots = cursorSpots
        var x: CGFloat = 0
        for (r, cursor) in spots {
            if r.minX > x { addCursorRect(NSRect(x: x, y: 0, width: r.minX - x, height: bounds.height), cursor: .openHand) }
            addCursorRect(r.intersection(bounds), cursor: cursor)
            x = max(x, r.maxX)
        }
        if x < bounds.width { addCursorRect(NSRect(x: x, y: 0, width: bounds.width - x, height: bounds.height), cursor: .openHand) }
    }

    // Set here, by where the pointer is, not passed on: a bar at the
    // window's top is under the title bar, which gave an update passed on
    // back to the bar, round until the stack ran out.
    override func cursorUpdate(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        (cursorSpots.first { $0.0.contains(p) }?.1 ?? .openHand).set()
    }

    override func mouseDown(with event: NSEvent) {
        downAt = event.locationInWindow
        downOnIcon = iconSpot.contains(convert(event.locationInWindow, from: nil))
    }

    override func rightMouseDown(with event: NSEvent) {
        if let onRightClick { onRightClick(event) } else { super.rightMouseDown(with: event) }
    }

    override func mouseDragged(with event: NSEvent) {
        guard let start = downAt else { return }
        let p = event.locationInWindow
        guard hypot(p.x - start.x, p.y - start.y) > 4 else { return }
        downAt = nil
        // Taken: the handle goes back in; what's dragged is the pill.
        setHandle(false)
        onDragStart?(event, downOnIcon)
    }

    override func mouseUp(with event: NSEvent) {
        if downAt != nil {
            let p = convert(event.locationInWindow, from: nil)
            // Clicks in a row are clicks each (two quick ones grow twice);
            // the corner maximizes.
            if event.modifierFlags.contains(.shift) { onPathClick?() }
            else if iconSpot.contains(p) { onIconClick?(event.modifierFlags) } else { onClick?(p, event.modifierFlags) }
        }
        downAt = nil
    }
}

/// A tile's icon, as a handle (`TilePill`): under the pointer it swings
/// out of the bar toward you, hinged at its left edge as a door is, in a
/// little perspective, and grows a little — so it shows past the hand
/// that's over it — settling with a slight overshoot, a short shadow
/// falling on the bar from the edge that lifts — nothing lit behind it;
/// the pose says it can be taken (dragged, the thing the tile stands
/// for). A mark of our own unfolds as it swings, each its own way (a
/// terminal's prompt steps in as a window draws itself round it; a note's
/// corner peels further up), so even a slight one has something to turn
/// (`Marks.parts`). It swings back, and folds, when the pointer goes or
/// the drag begins. The icon is drawn here while it's out (its own view's
/// layer is AppKit's, not to be turned), the view hidden. With less
/// motion asked for, it doesn't turn: its shadow comes, as if lifted, and
/// a mark unfolds without moving there.
final class IconHandle: NSView {
    private let face = CALayer()
    /// A mark's strokes, while it's one of ours: moved between rest and unfolded.
    private var strokes: [(layer: CAShapeLayer, part: Marks.Part)] = []
    private(set) var out = false
    /// Which swing is the latest: one replaced ends too, and mustn't
    /// put the icon back mid-swing.
    private var swings = 0
    /// Back in the bar: the icon's own view to show again.
    var onIn: (() -> Void)?

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        var perspective = CATransform3DIdentity
        perspective.m34 = -1 / 90
        layer?.sublayerTransform = perspective
        face.anchorPoint = CGPoint(x: 0, y: 0.5)
        face.contentsGravity = .center
        face.shadowColor = NSColor.black.cgColor
        face.shadowRadius = 1.5
        face.shadowOffset = CGSize(width: 1.5, height: -1)
        face.shadowOpacity = 0
        face.isHidden = true
        layer?.addSublayer(face)
    }
    required init?(coder: NSCoder) { fatalError() }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    /// Swung out: its right edge toward you, about 40°, and a fifth larger.
    private static let swung = CATransform3DScale(CATransform3DMakeRotation(-.pi * 40 / 180, 0, 1, 0), 1.2, 1.2, 1)

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        face.bounds = CGRect(origin: .zero, size: bounds.size)
        face.position = CGPoint(x: 0, y: bounds.midY)
        CATransaction.commit()
    }

    /// The size and weight the bar's icons are drawn at, a mark's strokes too.
    static let markSize: CGFloat = 11

    /// Out, showing `image` as the icon's view does (a symbol in `tint`);
    /// `mark`, the symbol's name, unfolds if it's one of ours.
    func set(out: Bool, image: NSImage?, tint: NSColor?, mark: String? = nil) {
        guard out != self.out else { return }
        self.out = out
        if out, let mark, let tint, makeStrokes(mark, tint: tint) {
            face.contents = nil
        } else if out {
            removeStrokes()
            // Drawn now, at the screen's scale and in this appearance, and
            // put in place without Core Animation's fade: given an image to
            // resolve later, it showed a frame or two large and too light.
            let scale = backingScale
            let drawn = image.flatMap { render($0, tint: tint, scale: scale) }
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            face.contentsScale = scale
            face.contents = drawn
            CATransaction.commit()
        }
        let reduced = Motion.reduced
        let to = out && !reduced ? Self.swung : CATransform3DIdentity
        let from = face.presentation()?.transform ?? face.transform
        let fromShadow = face.presentation()?.shadowOpacity ?? face.shadowOpacity
        let d = out ? Motion.spatial : Motion.base
        swings += 1
        let swing = swings
        CATransaction.begin()
        CATransaction.setCompletionBlock { [weak self] in
            guard let self, !self.out, self.swings == swing else { return }
            self.face.isHidden = true
            self.onIn?()
        }
        CATransaction.setDisableActions(true)
        face.isHidden = false
        face.transform = to
        face.shadowOpacity = out ? 0.5 : 0
        for (layer, part) in strokes {
            let path = out ? part.out : part.rest
            if !reduced {
                let a = CABasicAnimation(keyPath: "path")
                a.fromValue = layer.presentation()?.path ?? layer.path
                a.toValue = path
                a.duration = d
                a.timingFunction = out ? Motion.settle : Motion.disappear
                layer.add(a, forKey: "unfold")
                if part.drawsOn || part.fills {
                    let key = part.drawsOn ? "strokeEnd" : "opacity"
                    let shown = CABasicAnimation(keyPath: key)
                    shown.fromValue = layer.presentation()?.value(forKeyPath: key) ?? layer.value(forKeyPath: key)
                    shown.duration = d
                    shown.timingFunction = out ? Motion.appear : Motion.disappear
                    layer.add(shown, forKey: "shown")
                }
            }
            layer.path = path
            if part.drawsOn { layer.strokeEnd = out ? 1 : 0 }
            if part.fills { layer.opacity = out ? 1 : 0 }
        }
        let turn = CABasicAnimation(keyPath: "transform")
        turn.fromValue = from
        turn.toValue = to
        turn.duration = d
        turn.timingFunction = out ? Motion.settle : Motion.disappear
        face.add(turn, forKey: "swing")
        let shadow = CABasicAnimation(keyPath: "shadowOpacity")
        shadow.fromValue = fromShadow
        shadow.duration = d
        face.add(shadow, forKey: "shadow")
        CATransaction.commit()
    }

    /// A mark of ours as strokes in the face, at rest — as its image draws
    /// it, so nothing jumps as the face takes over from the icon's view;
    /// false for any other symbol.
    private func makeStrokes(_ mark: String, tint: NSColor) -> Bool {
        let box = Marks.box(Self.markSize)
        let r = CGRect(x: (bounds.width - box.width) / 2, y: (bounds.height - box.height) / 2, width: box.width, height: box.height)
        guard let parts = Marks.parts(mark, size: Self.markSize, weight: .regular, in: r) else { return false }
        removeStrokes()
        var color = tint.cgColor
        effectiveAppearance.performAsCurrentDrawingAppearance { color = tint.cgColor }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for part in parts {
            let l = CAShapeLayer()
            l.frame = face.bounds
            l.path = part.rest
            l.lineWidth = Marks.stroke(Self.markSize, .regular)
            l.lineCap = .round
            l.lineJoin = .round
            if part.fills {
                l.fillColor = color.copy(alpha: 0.3)
                l.strokeColor = nil
                l.opacity = 0
            } else {
                l.fillColor = nil
                l.strokeColor = color
            }
            if part.drawsOn { l.strokeEnd = 0 }
            l.contentsScale = backingScale
            face.addSublayer(l)
            strokes.append((l, part))
        }
        CATransaction.commit()
        return true
    }

    private func removeStrokes() {
        strokes.forEach { $0.layer.removeFromSuperlayer() }
        strokes = []
    }

    /// The icon as its view shows it: a symbol in `tint`, a picture as it is.
    private func render(_ image: NSImage, tint: NSColor?, scale: CGFloat) -> CGImage? {
        let size = image.size
        guard size.width > 0, size.height > 0,
              let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int((size.width * scale).rounded(.up)), pixelsHigh: Int((size.height * scale).rounded(.up)),
                                         bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)
        else { return nil }
        rep.size = size
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        effectiveAppearance.performAsCurrentDrawingAppearance {
            let r = NSRect(origin: .zero, size: size)
            image.draw(in: r)
            if image.isTemplate, let tint {
                tint.set()
                r.fill(using: .sourceAtop)
            }
        }
        NSGraphicsContext.restoreGraphicsState()
        return rep.cgImage
    }

    var debugState: String {
        let p = face.presentation() ?? face
        // The turn, from the transform's x scale: cos of the angle (by the growth).
        let grown = hypot(Double(p.transform.m11), Double(p.transform.m13))
        let angle = acos(max(-1, min(1, Double(p.transform.m11) / max(grown, 0.001)))) * 180 / .pi
        return "\(out ? "out" : "in") turned=\(Int(angle.rounded()))° grown=\(String(format: "%.2f", grown)) shadow=\(String(format: "%.2f", p.shadowOpacity)) shown=\(!face.isHidden)"
            + (strokes.isEmpty ? "" : " strokes=\(strokes.count) drawn=\(String(format: "%.2f", strokes.compactMap { $0.part.drawsOn ? ($0.layer.presentation() ?? $0.layer).strokeEnd : nil }.first ?? -1))")
    }
}

/// The grab area over the line between two tiles in a column: dragged,
/// it moves; double-clicked, the two share their room evenly.
final class RowDividerView: NSView {
    var onDrag: ((CGFloat) -> Void)?
    var onEnd: (() -> Void)?
    var onDoubleClick: (() -> Void)?

    override func resetCursorRects() { addCursorRect(bounds, cursor: .resizeUpDown) }
    // Its own, not the window's arrow (a cursor update unanswered goes up to it).
    override func cursorUpdate(with event: NSEvent) { NSCursor.resizeUpDown.set() }
    override func mouseDown(with event: NSEvent) {
        NSCursor.resizeUpDown.set()
        if event.clickCount == 2 { onDoubleClick?() }
    }

    override func mouseDragged(with event: NSEvent) {
        guard let superview else { return }
        // Held the whole drag, the pointer gone past the line where it stops.
        NSCursor.resizeUpDown.set()
        onDrag?(superview.convert(event.locationInWindow, from: nil).y)
    }

    override func mouseUp(with event: NSEvent) {
        onEnd?()
        window?.invalidateCursorRects(for: self)
    }
}

extension NSView {
    /// Whether the pointer is over this view with nothing over it there
    /// (the sidebar floating out, say): tracking areas don't know what
    /// covers them, so a view sets the cursor only when it's really the
    /// one under the pointer.
    var isUnderPointer: Bool {
        guard let window, let content = window.contentView else { return false }
        var v = content.hitTest(content.convert(window.mouseLocationOutsideOfEventStream, from: nil))
        while let x = v {
            if x === self { return true }
            v = x.superview
        }
        return false
    }
}

/// The pointer, moved by us: to a point in screen coordinates (AppKit's,
/// from the bottom left of the main screen).
enum Pointer {
    /// MANIFOLD_NO_WARP set: the pointer is left where it is (a scripted
    /// instance, driven while someone else has the mouse).
    static let held = ProcessInfo.processInfo.environment["MANIFOLD_NO_WARP"] != nil

    /// Debugging: where the pointer was last sent, in screen coordinates.
    nonisolated(unsafe) static var lastWarp: NSPoint?

    static func warp(to screen: NSPoint) {
        lastWarp = screen
        guard !held else { return }
        // Only Manifold's to move while it's the app in front: a warp
        // asked for a moment before (once a tile's laid out), or by `mani`
        // from elsewhere, isn't taken from whatever's in front now.
        guard Thread.isMainThread, MainActor.unchecked({ NSApp.isActive }) else { return }
        guard let main = NSScreen.screens.first else { return }
        CGWarpMouseCursorPosition(CGPoint(x: screen.x, y: main.frame.maxY - screen.y))
        CGAssociateMouseAndMouseCursorPosition(1)
    }
}

/// A ring around the focused tile (§3.1): drawn, taking no clicks.
final class FocusRingView: NSView {
    private let ring = CAShapeLayer()

    override init(frame: NSRect) {
        super.init(frame: frame)
        // Its ring a shape, drawn afresh at each size (the sidebar coming or
        // going resizes every tile), never stretched from the last; and
        // swelling, glowing, when a tile is arrived at.
        wantsLayer = true
        layer?.masksToBounds = false
        ring.fillColor = nil
        ring.lineWidth = 2
        ring.shadowOffset = .zero
        ring.shadowRadius = 8
        ring.shadowOpacity = 0
        layer?.addSublayer(ring)
        reshape()
        themed { v in
            v.ring.strokeColor = EdgeColor.accentStrong.cgColor
            v.ring.shadowColor = EdgeColor.accentStrong.cgColor
        }
    }

    required init?(coder: NSCoder) { fatalError() }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        reshape()
    }

    private func reshape() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        ring.frame = bounds
        ring.path = CGPath(roundedRect: bounds.insetBy(dx: 1, dy: 1), cornerWidth: Radius.surface, cornerHeight: Radius.surface, transform: nil)
        CATransaction.commit()
    }

    /// Moved with its tile as the tile glides there (`GridView.glide`):
    /// placed at once, its ring carried from where it shows now.
    /// `from`: where to carry it from instead, in its superview's terms.
    func glide(to frame: NSRect, from start: NSRect? = nil) {
        let was = self.frame
        let now = start.map { $0.offsetBy(dx: -frame.minX, dy: -frame.minY) }
            ?? (ring.presentation() ?? ring).frame.offsetBy(dx: was.minX - frame.minX, dy: was.minY - frame.minY)
        self.frame = frame
        let from = CGRect(origin: .zero, size: now.size)
        let bounds = CABasicAnimation(keyPath: "bounds")
        bounds.fromValue = NSValue(rect: from)
        let position = CABasicAnimation(keyPath: "position")
        position.fromValue = NSValue(point: CGPoint(x: now.midX, y: now.midY))
        let path = CABasicAnimation(keyPath: "path")
        path.fromValue = CGPath(roundedRect: from.insetBy(dx: 1, dy: 1), cornerWidth: Radius.surface, cornerHeight: Radius.surface, transform: nil)
        let g = CAAnimationGroup()
        g.animations = [bounds, position, path]
        g.duration = GridView.glide
        g.timingFunction = Motion.travel
        ring.add(g, forKey: "glide")
    }

    /// Arrived at: the ring itself swells and glows, and settles back.
    func pulse() {
        let width = CAKeyframeAnimation(keyPath: "lineWidth")
        width.values = [2, 5, 2]
        let glow = CAKeyframeAnimation(keyPath: "shadowOpacity")
        glow.values = [0, 0.9, 0]
        let g = CAAnimationGroup()
        // Swelling isn't travel: kept with Reduce motion, as fades are.
        g.animations = [width, glow]
        for case let k as CAKeyframeAnimation in g.animations ?? [] {
            k.keyTimes = [0, 0.3, 1]
            k.timingFunctions = [Motion.appear, Motion.settle]
        }
        g.duration = 0.6 * Motion.slowdown
        ring.add(g, forKey: "pulse")
    }
}

/// Over the whole grid while something is dragged: takes the drag for
/// the grid, so a tile that is a drop target itself (a web view) doesn't
/// keep it. Gone as soon as the drag ends.
final class DragCatcherView: NSView {
    weak var grid: GridView?

    override init(frame: NSRect) {
        super.init(frame: frame)
        registerForDraggedTypes([.manifoldArrangement, .manifoldPlacement, .manifoldBlock, .fileURL])
    }

    required init?(coder: NSCoder) { fatalError() }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation { grid?.draggingEntered(sender) ?? [] }
    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation { grid?.draggingUpdated(sender) ?? [] }
    override func draggingExited(_ sender: NSDraggingInfo?) { grid?.draggingExited(sender) }
    override func draggingEnded(_ sender: NSDraggingInfo) { grid?.draggingEnded(sender) }
    override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool { true }
    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool { grid?.performDragOperation(sender) ?? false }
}

/// Where a dragged block would land: half a column, for a new column;
/// half a tile, above or below it.
final class DropOverlayView: NSView {
    override func draw(_ dirtyRect: NSRect) {
        Theme.dropHighlight.setFill()
        bounds.fill()
        EdgeColor.accentSoft.setStroke()
        NSBezierPath(rect: bounds.insetBy(dx: 0.5, dy: 0.5)).stroke()
    }
}

/// The grab area between two columns: dragged, it moves; double-clicked,
/// the two share their width evenly.
final class DividerView: NSView {
    var onDrag: ((CGFloat) -> Void)?
    var onEnd: (() -> Void)?
    var onDoubleClick: (() -> Void)?

    override func resetCursorRects() { addCursorRect(bounds, cursor: .resizeLeftRight) }
    override func cursorUpdate(with event: NSEvent) { NSCursor.resizeLeftRight.set() }

    override func mouseDown(with event: NSEvent) { if event.clickCount == 2 { onDoubleClick?() } }

    override func mouseDragged(with event: NSEvent) {
        NSCursor.resizeLeftRight.set()
        guard let superview else { return }
        onDrag?(superview.convert(event.locationInWindow, from: nil).x)
    }

    override func mouseUp(with event: NSEvent) { onEnd?() }
}

/// What follows the cursor when a block is dragged: a small card with its
/// icon and title.
enum BlockDragImage {
    static func make(for pane: Shown?) -> NSImage {
        let title = pane?.title ?? "Block"
        let font = NSFont.systemFont(ofSize: 13, weight: .medium)
        let textWidth = ceil((title as NSString).size(withAttributes: [.font: font]).width)
        let size = NSSize(width: min(max(textWidth + 52, 140), 320), height: 34)
        return NSImage(size: size, flipped: false) { rect in
            let card = rect.insetBy(dx: 1, dy: 1)
            let path = NSBezierPath(roundedRect: card, xRadius: 17, yRadius: 17)
            Theme.windowBackground.withAlphaComponent(0.96).setFill()
            path.fill()
            Theme.sheetEdge(hovered: true).setStroke()
            path.lineWidth = 1
            path.stroke()
            if let icon = Theme.symbol(pane?.symbol ?? Marks.terminal, size: 13) {
                icon.tinted(Theme.secondaryText).draw(in: icon.centered(in: NSRect(x: 12, y: (rect.height - 16) / 2, width: 16, height: 16)))
            }
            let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: Theme.text]
            let text = NSAttributedString(string: title, attributes: attrs)
            text.draw(with: NSRect(x: 36, y: (rect.height - 17) / 2 + 3, width: rect.width - 46, height: 17),
                      options: [.truncatesLastVisibleLine, .usesLineFragmentOrigin])
            return true
        }
    }
}

/// Things dropped on the grid (§3.11) — between tiles, or over a tile whose
/// view doesn't take them: a tile of its own where it lands (a file
/// opened, a page, a picture, a note of words, a block brought); a
/// block's own over a tile, the tile linked to it — ⌃ for the other.
extension GridView: DropTaking {
    /// The tile a drop at `p` would link, if what's dragged can be linked to and isn't it.
    private func linkTarget(_ d: Dragged, at p: NSPoint) -> Tile? {
        guard d.offers(.linkTile), let t = tile(at: p) else { return nil }
        return d.things.contains { $0.block != nil && $0.block == t.shown.block?.id } ? nil : t
    }

    func dropForms(_ d: Dragged, at p: NSPoint) -> [DropForm] {
        let onto = linkTarget(d, at: p)
        let slot = dropTarget(at: p, dragged: nil)
        if onto != nil, d.things.allSatisfy({ $0.block != nil }) { return [.linkTile] + (slot != nil ? [.open] : []) }
        return (slot != nil ? [.open] : []) + (onto != nil ? [.linkTile] : [])
    }

    func dropLabel(_ form: DropForm, _ d: Dragged) -> String? {
        form == .linkTile ? lastLinkTitle.map { "Link “\($0)” to It" } : nil
    }

    /// Where it lands shown: the slot it opens in, or the whole tile linked.
    func dropTrack(_ d: Dragged, at p: NSPoint) {
        let forms = dropForms(d, at: p)
        if forms.first == .linkTile, let t = linkTarget(d, at: p) {
            lastLinkTitle = t.shown.title
            showDrop(t.view.frame)
            drop = DropSlot(column: 0, at: 0, rect: t.view.frame, onto: t.shown.id)
        } else if let slot = dropTarget(at: p, dragged: nil) {
            lastLinkTitle = linkTarget(d, at: p)?.shown.title
            showDrop(slot.rect)
            drop = slot
        }
    }

    func dropPut(_ d: Dragged, as form: DropForm, at p: NSPoint?) {
        let p = p ?? NSPoint(x: bounds.midX, y: bounds.midY)
        switch form {
        case .linkTile:
            guard let t = linkTarget(d, at: p) else { return NSSound.beep() }
            for thing in d.things {
                if let b = thing.named() { delegate?.gridLink(b, to: t.shown.id) }
            }
        default:
            guard let slot = dropTarget(at: p, dragged: nil) else { return NSSound.beep() }
            delegate?.gridOpen(d, column: slot.column, at: slot.at, newColumn: slot.newColumn)
        }
    }
}
