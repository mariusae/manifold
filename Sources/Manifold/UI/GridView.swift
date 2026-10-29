import AppKit
import ManifoldCore

/// A view only it can draw (a page, in its own process): a picture of it
/// comes a moment later, from it.
protocol Snapshotting: AnyObject {
    func snapshot(_ done: @escaping (NSImage?) -> Void)
}

protocol GridDelegate: AnyObject {
    func gridFocus(_ placement: PlacementID)
    /// A block's last picture, kept (a page's, which can't be drawn at once).
    func gridKeptPicture(_ block: BlockID) -> NSImage?
    /// A block's picture, to keep.
    func gridKeep(_ picture: NSImage, of block: BlockID)
    /// A stack about to fan out: its tile grown to hold the fan, if it's
    /// short of it. True when it was (the fan waits for the tile to settle).
    func gridRoomForFan(_ top: PlacementID) -> Bool
    /// A tile as its summary card shows it (a stack's column).
    func gridSummary(_ placement: PlacementID) -> SummaryCardContent?
    /// A linked block's summary card, under the bar's links.
    func gridLinkSummary(_ block: BlockID) -> SummaryCardContent?
    /// A tile gone to by a click on its summary (it's too short for its
    /// content): focused, and grown to show some.
    func gridArrive(_ placement: PlacementID)
    /// A tile down to its summary, or, already there, back as it was.
    func gridShrinkToSummary(_ placement: PlacementID)
    /// A fan opened from ⌃⇥ taken over by the pointer: letting go of control no
    /// longer settles it (a click does).
    func gridSwitcherFollowsPointer()
    /// A tile dropped at a place in the grid: into column `column` at
    /// index `at`, or a new column at `column`.
    func gridMove(_ placement: PlacementID, column: Int, at: Int, newColumn: Bool, alone: Bool)
    /// A block from the sidebar dropped at a place in the grid: brought there.
    func gridBring(_ block: BlockID, column: Int, at: Int, newColumn: Bool)
    /// Files dropped from outside: opened where they landed.
    func gridOpenFiles(_ paths: [String], column: Int, at: Int, newColumn: Bool)
    /// This Mac's host, whose files can go out as files.
    var gridLocalHost: HostID { get }
    /// Something from another app dropped on the grid: a web address, an
    /// image, text — made a block of its own where it lands.
    func gridOpenDropped(_ thing: GridView.Dropped, column: Int, at: Int, newColumn: Bool)
    /// Entries dragged from a folder's tile, on its host (another's too).
    func gridOpenPaths(_ paths: [(host: HostID, path: String, isDirectory: Bool)], column: Int, at: Int, newColumn: Bool)
    /// Another arrangement dropped: its columns come over at `column`.
    func gridDropArrangement(_ arrangement: BlockID, column: Int)
    func gridCanDrop(_ arrangement: BlockID) -> Bool
    func gridResized(fractions: [Double])
    /// The lines between tiles dragged: the column's heights, after the
    /// tiles pushed down to nothing went into the stacks of the tiles
    /// below them (each `(tile, behind)`).
    func gridResized(heights: [PlacementID: Double], stashed: [(PlacementID, PlacementID)])
    func gridDragChanged(_ dragging: Bool)
    func gridDragAtLeftEdge()
    /// A tile's pill was clicked: its menu.
    func gridPillMenu(for placement: PlacementID) -> NSMenu?
    /// A stashed tile's pill was clicked: it comes back (§3.1).
    func gridUnstash(_ placement: PlacementID)
    /// Clicked where it peeks out (a tab, a card, its bar above the
    /// stack): it takes the top of its stack, the tile that showed going
    /// behind it.
    func gridSwap(_ placement: PlacementID)
    /// ⌥-drag: the dragged tile over another, which goes into the stack behind it.
    /// `alone`: ⌘-drag, or a fanned pill's drag — the tile without its stack.
    func gridCover(_ placement: PlacementID, over target: PlacementID, alone: Bool)
    func gridStash(_ placement: PlacementID, behind: PlacementID, alone: Bool)
    func gridGrow(_ placement: PlacementID)
    func gridFill(_ placement: PlacementID)
    /// ⌥-click: the block's path, folder by folder, each going there.
    func gridPathMenu(for placement: PlacementID) -> NSMenu?
    /// The pill's corner button: the tile maximized over the arrangement,
    /// or restored.
    func gridToggleFull(_ placement: PlacementID)
    /// The bar's ×: the tile taken off (as ⌘W does).
    func gridClose(_ placement: PlacementID)
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
/// between tiles and columns resize them. A column one tile fills keeps
/// the others **stashed**: not laid out, their pills bunched in a small
/// stack under the filling tile's, fanned out while the pointer is over
/// them, each clicked to come back.
final class GridView: NSView, NSDraggingSource {
    /// Told of a tile's view about to go out of sight — stacked, collapsed
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
    private var full: PlacementID?
    private var pills: [PlacementID: TilePill] = [:]
    /// Pills of tiles gone from the grid, kept (hidden) for when they come
    /// back: the two grids take turns at workspace switches, so a grid
    /// mostly shows again the workspace it showed two switches ago, and a
    /// pill costs more to make than to show again.
    private var sparePills: [PlacementID: TilePill] = [:]
    /// How long a tile takes to glide to a new place or size.
    static var glide: TimeInterval { Motion.base }
    /// Debugging: grid layouts so far (the debug "layouts").
    static var layouts = 0
    private var columnDividers: [DividerView] = []
    private var rowDividers: [RowDividerView] = []
    private let dropOverlay = DropOverlayView()
    private var drop: (column: Int, at: Int, rect: NSRect, newColumn: Bool, onto: PlacementID?)?
    /// The drop under way covers the tile it's on (⌥-drag).
    private var dropCovers = false
    /// The drag is a block's link (⇧): dropped, it links to the tile's block.
    private var dropLinks = false
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
            }
        }
    }
    private let dragCatcher = DragCatcherView()
    /// A ring around the focused tile.
    private let focusRing = FocusRingView()
    /// The column whose stack of stashed pills is fanned out, under the pointer.
    /// The shown tile whose stack is fanned out under its pill.
    private var fanned: PlacementID? = nil

    /// What a tile's content leaves at its top: nothing — the bar is above
    /// it, not over it (kept for the views that asked).
    static let band: CGFloat = 0
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
        // The sheets' layers take their colours as laid out: laid out again
        // when light and dark switch.
        themed { $0.needsLayout = true }
        dropOverlay.isHidden = true
        registerForDraggedTypes([.manifoldArrangement, .manifoldPlacement, .manifoldBlock, .manifoldBlockLink, .fileURL, .manifoldPath, .URL, .string, .png, .tiff] + Promises.types)
    }

    required init?(coder: NSCoder) { fatalError() }

    /// What another app drags that the grid makes a block of.
    enum Dropped {
        /// Files another app promises (Photos, Mail): opened once written.
        case promised([NSFilePromiseReceiver])
        case web(URL)
        case image(Data, String)
        case text(String)
    }

    /// A web address, an image or text from another app (none of ours, no
    /// files): what it becomes.
    static func dropped(_ pb: NSPasteboard) -> Dropped? {
        let ours: [NSPasteboard.PasteboardType] = [.manifoldPlacement, .manifoldBlock, .manifoldArrangement, .manifoldBlockLink, .manifoldPath, .fileURL]
        guard !(pb.types ?? []).contains(where: ours.contains) else { return nil }
        let promised = Promises.receivers(pb)
        if !promised.isEmpty { return .promised(promised) }
        if let url = (pb.readObjects(forClasses: [NSURL.self]) as? [URL])?.first, url.scheme == "http" || url.scheme == "https" { return .web(url) }
        if let png = pb.data(forType: .png) { return .image(png, "png") }
        if let tiff = pb.data(forType: .tiff), let rep = NSBitmapImageRep(data: tiff), let png = rep.representation(using: .png, properties: [:]) { return .image(png, "png") }
        if let s = pb.string(forType: .string)?.trimmingCharacters(in: .whitespacesAndNewlines), !s.isEmpty {
            if !s.contains(" "), !s.contains("\n"), let url = URL(string: s), url.scheme == "http" || url.scheme == "https" { return .web(url) }
            return .text(s)
        }
        return nil
    }
    private var dropOther: Dropped?

    /// A folder's entries being dragged, on their host.
    private static func droppedPaths(_ pb: NSPasteboard) -> [(host: HostID, path: String, isDirectory: Bool)] {
        guard pb.string(forType: .manifoldBlockLink) == nil else { return [] }
        return (pb.pasteboardItems ?? []).compactMap { item in
            let f = item.string(forType: .manifoldPath)?.split(separator: "\t", omittingEmptySubsequences: false) ?? []
            guard f.count == 3 else { return nil }
            return (HostID(String(f[0])), String(f[1]), f[2] == "d")
        }
    }

    /// Files from the Finder (or anywhere) being dragged: their paths.
    private static func droppedFiles(_ pb: NSPasteboard) -> [String] {
        guard pb.string(forType: .manifoldPlacement) == nil, pb.string(forType: .manifoldBlock) == nil, pb.string(forType: .manifoldArrangement) == nil,
              pb.string(forType: .manifoldBlockLink) == nil,
              let urls = pb.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] else { return [] }
        return urls.map(\.path)
    }
    private var dropFiles = false

    func show(_ columns: [[Tile]], fractions: [Double], heights: [PlacementID: Double], focused: PlacementID?, full: PlacementID? = nil) {
        // Maximized or restored: where the tile was, to grow or shrink from.
        var zoomFrom: (PlacementID, NSRect)?
        if full != self.full, window != nil, !isHiddenOrHasHiddenAncestor {
            if let f = full, let body = lastFrames[f], body.height > 0 {
                zoomFrom = (f, NSRect(x: body.minX, y: body.minY, width: body.width, height: body.height + Self.barHeight))
            } else if let w = self.full, let v = views.first(where: { $0.placement == w }), !v.isHidden {
                zoomFrom = (w, NSRect(x: v.frame.minX, y: v.frame.minY, width: v.frame.width, height: v.frame.height + Self.barHeight))
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
            fadeAway(v)
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
                if tile.view.superview !== self, !held(tile.shown.id) {
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
                let stashed = isStashed(id)
                pill.show(tile.shown, focused: tile.shown.id == focused, maximized: tile.shown.id == full, stashed: stashed)
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
                pill.onClose = { [weak self] in self?.delegate?.gridClose(id) }
                // The bar clicked grows the tile, ⌘-clicked fills its column;
                // ⌃-clicked (or its symbol clicked) it's the tile's menu.
                // A bar peeking out above its stack, clicked, comes to the
                // top; ⌘-clicked, it comes out of the stack.
                pill.onClick = { [weak self, weak pill] at, mods in
                    guard let self else { return }
                    if stashed {
                        self.fanned = nil
                        if mods.contains(.command) { self.delegate?.gridUnstash(id) } else { self.delegate?.gridSwap(id) }
                        return
                    }
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
                    // fills its column (Maximize is the corner's). The pointer follows the bar to
                    // where it was clicked, once the tile has grown and moved
                    // it, so a click again grows again.
                    self.delegate?.gridFocus(id)
                    if mods.contains(.command) { self.delegate?.gridFill(id); return }
                    self.pendingWarp = (id, at, self.barTargets[id] ?? pill?.frame ?? .zero, Date())
                    self.delegate?.gridGrow(id)
                }
                pill.onPathClick = { [weak self] in
                    guard let self, !stashed else { return }
                    self.delegate?.gridFocus(id)
                    if let menu = self.delegate?.gridPathMenu(for: id), let pill = self.pills[id] {
                        let at = NSApp.currentEvent.map { pill.convert($0.locationInWindow, from: nil) } ?? NSPoint(x: pill.bounds.midX, y: 0)
                        menu.popUp(positioning: nil, at: NSPoint(x: at.x, y: at.y - 4), in: pill)
                    }
                }
                pill.onIconClick = { [weak self] mods in
                    guard let self else { return }
                    if stashed {
                        // As anywhere in a stack: to the top; ⌘, out of it.
                        self.fanned = nil
                        if mods.contains(.command) {
                            self.delegate?.gridUnstash(id)
                        } else {
                            self.delegate?.gridSwap(id)
                        }
                        return
                    }
                    self.delegate?.gridFocus(id)
                    self.showPillMenu(id)
                }
                // Right-clicked, the title calls up the tile's menu.
                pill.onRightClick = { [weak self] _ in
                    guard let self, !stashed else { return }
                    self.delegate?.gridFocus(id)
                    self.showPillMenu(id)
                }
                // Its stack's button (or its sheets, clicked): the stack
                // behind it fanned out.
                pill.onFan = { [weak self] in self?.fanOut(id) }
                // Over its stack button, the tiles behind rise as tabs at once.
                pill.onFanHover = { [weak self] inside in
                    guard let self else { return }
                    self.hoveringSheets = inside ? id : nil
                    if inside { self.showPeek(id) } else { self.leavePeekSoon() }
                }
                // A fanned pill drags its tile out alone; the top's takes
                // the stack along, unless ⌘ is held.
                pill.onDragStart = { [weak self, weak pill] event in
                    guard let self, let pill else { return }
                    self.beginDrag(of: id, event: event, from: pill)
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
                    pill.onLinkRoom = { [weak badge] room in badge?.capsuleLimit = room }
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
                // Not a view the switcher holds: it shows in its card. One
                // collapsed to its bar stays out of sight, as layout left it:
                // shown here, a sliver of it showed under its bar until the
                // next layout (and blinked with each, typing in a note whose
                // title is in its bar).
                if !held(id) { setHidden(tile.view, stashed || collapsed.contains(id) || summarized.contains(id)) }
                // Its summary standing in for it, said afresh with each render.
                if let card = tileSummaries[id], summarized.contains(id), let s = summaryContent(tile) { card.content = s }
            }
        }
        if let f = fanned, !columns.flatMap({ $0 }).contains(where: { $0.shown.id == f }) { fanned = nil }
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
            d.onEnd = { [weak self] in self?.dividerDragging = false; self?.delegate?.gridResized(fractions: self?.fractions ?? []) }
            // (Kept when the click's up comes, as a drag's end is.)
            d.onDoubleClick = { [weak self] in self?.evenColumns(i) }
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
                guard let self else { return }
                self.dividerDragging = false
                let stashed = self.stashedDown
                self.stashedDown = []
                self.dividerBelow = [:]
                self.delegate?.gridResized(heights: self.heights, stashed: stashed)
            }
            d.onDoubleClick = { [weak self] in self?.evenRows(column: c, above: above, below: below) }
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

    private func isStashed(_ id: PlacementID) -> Bool { heights[id] == 0 }
    private func shownTiles(_ c: Int) -> [Tile] { columns[c].filter { !isStashed($0.shown.id) } }
    private func stashedTiles(_ c: Int) -> [Tile] { columns[c].filter { isStashed($0.shown.id) } }

    /// A column's shown tiles, each with the stack behind it: the stashed
    /// tiles that follow it in the column (those before the first shown
    /// tile are behind it).
    private func stacks(_ c: Int) -> [(top: Tile, behind: [Tile])] {
        var out: [(top: Tile, behind: [Tile])] = []
        var early: [Tile] = []
        for t in columns[c] {
            if isStashed(t.shown.id) {
                if out.isEmpty { early.append(t) } else { out[out.count - 1].behind.append(t) }
            } else {
                out.append((t, early))
                early = []
            }
        }
        return out
    }

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

    /// Debugging: the tile's stack fanned out, as its sheets clicked
    /// would; what came up.
    func debugRightClick(_ placement: PlacementID) -> String {
        guard let pill = pills[placement] else { return "no pill" }
        guard full == nil, stacks(columns.indices.first { columns[$0].contains { $0.shown.id == placement } } ?? 0)
            .contains(where: { $0.top.shown.id == placement && !$0.behind.isEmpty }) else { return "no stack" }
        pill.onFan?()
        layoutSubtreeIfNeeded()
        return switcher.map { "switcher over \(NSStringFromRect($0.frame)), bar hidden \(pill.isHidden)" } ?? "nothing"
    }

    /// The stack behind `top` fanned out, the choice following the pointer.
    private func fanOut(_ top: PlacementID) {
        guard full == nil else { return }
        delegate?.gridFocus(top)
        openStackSwitcher(top, followingPointer: true)
    }

    /// Debugging: the first stack's sheets clicked (or, `drag`, dragged
    /// down 30 points), the events sent to them as the window would.
    func debugClickSheets(drag: Bool) -> String {
        guard let t = sheetTargets.first, let window else { return "no sheets" }
        let r = t.convert(t.bounds, to: nil)
        let at = NSPoint(x: r.midX, y: r.midY)
        func event(_ type: NSEvent.EventType, _ p: NSPoint) -> NSEvent? {
            NSEvent.mouseEvent(with: type, location: p, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                               windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)
        }
        let before = heights
        if let e = event(.leftMouseDown, at) { t.mouseDown(with: e) }
        if drag { for dy in stride(from: 5, through: 30, by: 5) { if let e = event(.leftMouseDragged, NSPoint(x: at.x, y: at.y - CGFloat(dy))) { t.mouseDragged(with: e) } } }
        if let e = event(.leftMouseUp, drag ? NSPoint(x: at.x, y: at.y - 30) : at) { t.mouseUp(with: e) }
        layoutSubtreeIfNeeded()
        return "switcher \(switcher.map { NSStringFromRect($0.frame) } ?? "none"); heights \(before == heights ? "same" : "changed")"
    }

    /// Debugging: the first stack's sheets hovered — their tabs risen — or,
    /// `off`, left.
    /// Debugging: the focused (else first) stack's sheets hovered — the
    /// tabs rising after the dwell — or, `button`, its stack button
    /// (at once); or left.
    func debugPeek(_ on: Bool, button: Bool = false) -> String {
        let focusedTarget = sheetTargets.first { $0.top == focused }
        guard let t = focusedTarget ?? sheetTargets.first, let top = t.top else { return "no sheets" }
        guard on else {
            (button ? pills[top]?.onFanHover : t.onHover)?(false)
            hidePeek()
            return "left"
        }
        if let p = peek { return "already up over \(p.top)" }
        if button { pills[top]?.onFanHover?(true) } else { t.onHover?(true) }
        return peek.map { "peek over \($0.top): \(NSStringFromRect($0.frame))" } ?? "rising in \(Self.peekDwellTime)s"
    }

    /// Debugging: whether the tabs are up.
    var debugPeekUp: String { peek.map { "up over \($0.top)" } ?? "none" }

    /// Debugging: tab `i` of the tabs up clicked.
    func debugPeekPick(_ i: Int) -> String { peek?.debugPick(i) ?? "no tabs up" }

    /// Debugging: where each stack's sheets take a click.
    var debugSheetTargets: String {
        let tiles = columns.flatMap { $0 }
        return sheetTargets.map { t in
            let title = tiles.first { $0.shown.id == t.top }?.shown.title ?? "?"
            // In the window's coordinates from the top left (as `click` takes them).
            let r = t.convert(t.bounds, to: nil)
            let top = (window?.contentView?.bounds.height ?? 0) - r.midY
            return "\(title) center \(Int(r.midX)) \(Int(top)) size \(Int(r.width))x\(Int(r.height))"
        }.joined(separator: "\n")
    }

    /// Debugging: the open column's cards, the chosen marked.
    var debugColumn: String { switcher?.debugCards ?? "no column" }

    /// Debugging: the open switcher's pointer resting on card `i`.
    func debugSwitcherHover(_ i: Int) -> String { switcher?.debugHover(i) ?? "no switcher" }
    func debugSwitcherPointer() -> String {
        guard let s = switcher else { return "no switcher" }
        s.debugPointerMoves()
        return "following the pointer: \(s.followsPointer), watching clicks: \(switcherMonitor != nil)"
    }

    func debugSwitcherPick(_ i: Int) -> String { switcher?.debugPick(i) ?? "no switcher" }

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
        let stashed = stashedDown
        stashedDown = []
        dividerBelow = [:]
        delegate?.gridResized(heights: heights, stashed: stashed)
        return "stashed \(stashed.count)"
    }

    /// Debugging: each tile's dirty dot: hidden, grey or amber.
    var debugDirty: String {
        columns.flatMap { $0 }.map { t in "\(t.shown.title): \(pills[t.shown.id]?.debugDirty ?? "-")" }.joined(separator: "\n")
    }

    /// Debugging: each tile's view, as laid out: its frame, whether it's
    /// hidden (and its layer), and its bar's.
    var debugTiles: String {
        columns.flatMap { $0 }.map { t in
            let v = t.view
            let p = pills[t.shown.id]
            return "\(t.shown.title): view=\(NSStringFromRect(v.frame)) hidden=\(v.isHidden) layerHidden=\(v.layer?.isHidden ?? false) stashed=\(isStashed(t.shown.id)) bar=\(p.map { NSStringFromRect($0.frame) } ?? "-") collapsedBar=\(p?.collapsed ?? false) summarized=\(summarized.contains(t.shown.id))"
        }.joined(separator: "\n")
    }

    var debugPills: String {
        columns.flatMap { $0 }.map { t in
            let p = pills[t.shown.id]
            let order = p.flatMap { subviews.firstIndex(of: $0) }.map(String.init) ?? "-"
            let viewOrder = subviews.firstIndex(of: t.view).map(String.init) ?? "-"
            let caret = t.view.caretRectInWindow.map { NSStringFromRect($0) } ?? "none"
            let capsule = p.map { NSStringFromRect($0.convert($0.capsule(in: $0), to: nil)) } ?? "-"
            return "\(t.shown.title): hidden=\(p?.isHidden ?? true) behind=\(p?.behind ?? 0) frame=\(p.map { NSStringFromRect($0.frame) } ?? "-") z=\(order) view z=\(viewOrder) caret=\(caret) capsule=\(capsule) \(p?.debugEdit ?? "")"
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
        guard let i = subviews.firstIndex(of: v), let j = subviews.firstIndex(of: other) else {
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
    /// tile shorter than its band; a stashed tile's is empty.
    private func tileFrames(column c: Int, in f: NSRect) -> [NSRect] {
        let all = columns[c]
        let shown = tileFramesShown(column: c, in: f)
        var next = 0
        return all.map { tile in
            if isStashed(tile.shown.id) { return .zero }
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
        if let full, let tile = columns.flatMap({ $0 }).first(where: { $0.shown.id == full }) {
            // One tile over everything; the rest wait behind it — once it's
            // grown over them.
            if zooming != full {
                for t in columns.flatMap({ $0 }) where t.shown.id != full {
                    setHidden(t.view, true)
                    pills[t.shown.id]?.isHidden = true
                    badges[t.shown.id]?.isHidden = true
                    ticks[t.shown.id]?.available = false
                }
                for d in columnDividers + rowDividers { d.isHidden = true }
            }
            tile.view.isHidden = false
            let r = bounds.insetBy(dx: Self.inset, dy: Self.inset)
            tile.view.frame = NSRect(x: r.minX, y: r.minY, width: r.width, height: r.height - Self.barHeight)
            placeTicks(of: tile, in: tile.view.frame, shown: true)
            focusRing.isHidden = true
            if let pill = pills[full] {
                pill.isHidden = false
                pill.behind = 0
                pill.collapsed = false
                pill.frame = NSRect(x: r.minX, y: r.maxY - Self.barHeight, width: r.width, height: Self.barHeight)
                keep(pill, above: tile.view)
            }
            if let badge = badges[full] { placeBadge(badge, of: full, in: r) }
            if let badge = badges[full], let pill = pills[full] { keep(badge, above: pill) }
            return
        }
        for t in columns.flatMap({ $0 }) where !held(t.shown.id) {
            let stashed = isStashed(t.shown.id)
            // Hidden if stashed; shown or not, by whether it's collapsed,
            // below — not shown here first and hidden again there, which
            // pictured it and told the terminal it was seen at every layout.
            if stashed { setHidden(t.view, true) }
            // A stashed tile's pill stays as it is — hidden behind the
            // top's, or out in the fan: shown here, it would be drawn over
            // the top pill for a frame, until the gather hid it again.
            if !stashed { pills[t.shown.id]?.isHidden = false }
            pills[t.shown.id]?.behind = 0
            badges[t.shown.id]?.isHidden = stashed
            ticks[t.shown.id]?.available = !stashed
        }
        for d in columnDividers + rowDividers { d.isHidden = false }
        let frames = columnFrames()
        var rowIndex = 0
        // Tiles glide to new places when the grid itself didn't change
        // size (a tile placed, closed, grown or stashed); a resize or a
        // divider dragged lays out at once.
        let gliding = bounds == lastLayoutBounds && !dragging && !dividerDragging && !isSwitching && !Motion.reduced
        lastLayoutBounds = bounds
        var frameNow: [PlacementID: NSRect] = [:]
        var collapsedNow: Set<PlacementID> = []
        var summarizedNow: Set<PlacementID> = []
        func settle(_ view: NSView, _ frame: NSRect, was: NSRect?) {
            if gliding, let was, was != .zero, was != frame, !view.isHidden {
                // A tile's content takes its new size at once and glides to
                // its place: sized at every step, a terminal would resize its
                // shell at each (over the network, on another host), an
                // editor lay its text out again at each.
                let resized = view is PaneContent && was.size != frame.size
                if resized { view.setFrameSize(frame.size) }
                NSAnimationContext.runAnimationGroup { ctx in
                    ctx.duration = Self.glide
                    ctx.timingFunction = Motion.appear
                    if resized { view.animator().setFrameOrigin(frame.origin) } else { view.animator().frame = frame }
                }
            } else {
                view.frame = frame
            }
        }
        for (c, f) in frames.enumerated() {
            let tiles = tileFrames(column: c, in: f)
            var shownIndex = 0
            var top: NSRect?
            // Each stack: its sheets' edges above the top's card; its
            // tiles hang as cards over it when they or its bar's stack
            // button are clicked. Said to the bars first: a bar with a stack
            // has its button, which the links' pill is placed before.
            for stack in stacks(c) {
                guard let topPill = pills[stack.top.shown.id] else { continue }
                topPill.behind = stack.behind.count
                topPill.toolTip = stack.behind.isEmpty ? nil
                    : "\(stack.behind.count) behind this tile — click the sheets above it, or its stack button, to see \(stack.behind.count == 1 ? "it" : "them")"
                for tile in stack.behind { pills[tile.shown.id]?.isHidden = true }
            }
            for (i, tile) in columns[c].enumerated() {
                guard !isStashed(tile.shown.id) else { continue }
                let r = tiles[i]
                let body = NSRect(x: r.minX, y: r.minY, width: r.width, height: max(0, r.height - Self.barHeight))
                let held = held(tile.shown.id)
                let was = lastFrames[tile.shown.id]
                // Too little of its content under the bar to be worth
                // showing: its summary card in its place; less than a line
                // of that, the tile is collapsed to its bar, a pill.
                let collapsed = body.height < Self.collapseBelow
                let summarized = !collapsed && body.height < Self.summarizeBelow
                if collapsed { collapsedNow.insert(tile.shown.id) }
                if summarized { summarizedNow.insert(tile.shown.id) }
                frameNow[tile.shown.id] = collapsed ? NSRect(x: r.minX, y: r.maxY - Self.barHeight, width: r.width, height: 0) : body
                // Gone to or from its summary card (a divider dragged, a
                // neighbour grown): the one crosses over to the other.
                if !held, !collapsed, was != nil, summarized != self.summarized.contains(tile.shown.id), !self.collapsed.contains(tile.shown.id),
                   let leaving = summarized ? tile.view : tileSummaries[tile.shown.id], !leaving.isHidden {
                    crossFade(from: leaving, to: body)
                }
                if !held {
                    settle(tile.view, body, was: was)
                    setHidden(tile.view, collapsed || summarized)
                }
                if summarized, !held, let content = summaryContent(tile) {
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
                placeTicks(of: tile, in: body, shown: !held && !collapsed && !summarized)
                // The switcher over the whole tile, its bar put away meanwhile.
                if held, let s = switcher, s.topID == tile.shown.id { s.frame = r }
                if top == nil { top = r }
                if let pill = pills[tile.shown.id] {
                    pill.collapsed = collapsed
                    let bar = NSRect(x: r.minX, y: r.maxY - Self.barHeight, width: r.width, height: Self.barHeight)
                    barTargets[tile.shown.id] = bar
                    settle(pill, bar, was: was.map { NSRect(x: $0.minX, y: $0.maxY, width: $0.width, height: Self.barHeight) })
                    if !held { keep(pill, above: tile.view) }
                    pill.isHidden = held
                }
                if let badge = badges[tile.shown.id] {
                    placeBadge(badge, of: tile.shown.id, in: r)
                    if held { badge.isHidden = true }
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
            _ = top
        }
        // Tiles placed since the last layout come in where they land (not
        // one come up from its stack: that's a swap, ⌃⇥'s, at once).
        if gliding, !lastFrames.isEmpty {
            for t in columns.flatMap({ $0 }) where frameNow[t.shown.id] != nil && lastFrames[t.shown.id] == nil && !placed.contains(t.shown.id) && !held(t.shown.id) {
                comeIn([t.view, pills[t.shown.id], tileSummaries[t.shown.id]].compactMap { $0 }.filter { !$0.isHidden })
            }
        }
        placed = Set(columns.flatMap { $0 }.map(\.shown.id))
        lastFrames = frameNow
        self.collapsed = collapsedNow
        self.summarized = summarizedNow
        for (id, c) in tileSummaries where !summarizedNow.contains(id) || held(id) { c.isHidden = true }
        if dragging { dragCatcher.frame = bounds }
        // The focus ring: around the focused tile, over everything (once a
        // tile shrinking back to its place is there).
        if let focused, zooming == nil, let t = columns.flatMap({ $0 }).first(where: { $0.shown.id == focused }), !isStashed(focused) {
            focusRing.isHidden = false
            let body = frameNow[focused] ?? t.view.frame
            let card = NSRect(x: body.minX, y: body.minY, width: body.width, height: body.height + Self.barHeight)
            if focusRing.frame != card {
                focusRing.frame = card
                focusRing.needsDisplay = true
            }
            if let p = pills[focused] { keep(focusRing, above: p) }
        } else {
            focusRing.isHidden = true
        }
        for (i, d) in columnDividers.enumerated() {
            d.frame = NSRect(x: frames[i].maxX, y: 0, width: Self.gap, height: bounds.height)
        }
        layoutSheets()
        layoutShadows(Array(frameNow.values))
        warpIfGrown()
        // A tile chosen in the switcher, once it's the top again: grown
        // from its card into its place.
        if let m = pendingArrival {
            if Date().timeIntervalSince(m.at) > 1 { land() } else if frameNow[m.id].map({ $0.height > 0 }) == true, !isStashed(m.id) {
                pendingArrival = nil
                arrive(m.id, card: m.card, from: m.from, in: m.host)
            }
        }
    }

    // MARK: Coming and going

    /// A tile placed comes in where it lands — fading in, from a little
    /// smaller — as its neighbours glide aside for it (only fading, with
    /// Reduce motion).
    /// Every tile at the last layout, shown or in a stack.
    private var placed: Set<PlacementID> = []

    private func comeIn(_ parts: [NSView]) {
        guard let card = parts.map(\.frame).reduce(nil, { (r: NSRect?, f: NSRect) in r.map { $0.union(f) } ?? f }) else { return }
        let c = CGPoint(x: card.midX, y: card.midY), k = Motion.reduced ? 1 : 0.94
        for v in parts {
            guard let l = v.layer else { continue }
            let o = v.frame.origin
            let fade = CABasicAnimation(keyPath: "opacity")
            fade.fromValue = 0
            fade.toValue = 1
            let grow = CABasicAnimation(keyPath: "transform")
            grow.fromValue = CATransform3DScale(CATransform3DMakeTranslation(c.x - o.x - (c.x - o.x) * k, c.y - o.y - (c.y - o.y) * k, 0), k, k, 1)
            grow.toValue = CATransform3DIdentity
            let g = CAAnimationGroup()
            g.animations = [fade, grow]
            g.duration = Motion.spatial
            g.timingFunction = Motion.appear
            l.add(g, forKey: "comeIn")
        }
    }

    /// Crossing over to it: fading in over what it takes the place of.
    private func fadeIn(_ v: NSView) {
        guard let l = v.layer else { return }
        let a = CABasicAnimation(keyPath: "opacity")
        a.fromValue = 0
        a.toValue = 1
        a.duration = Motion.base
        a.timingFunction = Motion.appear
        l.add(a, forKey: "fadeIn")
    }

    /// What a tile showed (its content, or its summary card) over what it
    /// shows now, fading: a picture of it, its top at the tile's top as
    /// the tile is now, so a divider dragged meanwhile takes nothing with it.
    private func crossFade(from v: NSView, to body: NSRect) {
        guard window != nil, !isHiddenOrHasHiddenAncestor, zooming == nil, v.bounds.width > 20, v.bounds.height > 1,
              let host = layer, let picture = Self.ghostPicture(of: v) else { return }
        let g = CALayer()
        g.contents = picture
        g.contentsGravity = .top
        g.contentsScale = window?.backingScaleFactor ?? 2
        if let own = v.layer?.backgroundColor, own.alpha > 0 { g.backgroundColor = own.copy(alpha: 1) } else {
            v.effectiveAppearance.performAsCurrentDrawingAppearance { g.backgroundColor = Theme.windowBackground.withAlphaComponent(1).cgColor }
        }
        g.frame = body
        g.cornerRadius = v.layer?.cornerRadius ?? 0
        g.maskedCorners = v.layer?.maskedCorners ?? []
        g.masksToBounds = true
        g.zPosition = 15
        g.opacity = 0
        host.addSublayer(g)
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 1
        fade.toValue = 0
        fade.duration = Motion.spatial
        fade.timingFunction = Motion.disappear
        CATransaction.begin()
        CATransaction.setCompletionBlock { g.removeFromSuperlayer() }
        g.add(fade, forKey: "crossFade")
        CATransaction.commit()
    }

    /// A tile closed (or moved away): a picture of it where it was, fading
    /// and shrinking a little, as its neighbours glide into the room it
    /// leaves — what went, seen going. Its view goes at once, as before.
    func fadeAway(_ v: PaneContent) {
        let bar = pills[v.placement]
        guard window != nil, !isHiddenOrHasHiddenAncestor, !isSwitching, !v.isHidden, let host = layer else { return }
        var ghosts: [CALayer] = []
        for part in [v as NSView, bar].compactMap({ $0 }) where !part.isHidden && part.bounds.width > 20 {
            guard let image = Self.ghostPicture(of: part) else { continue }
            let g = CALayer()
            g.contents = image
            g.contentsGravity = .resize
            // Its ground is its layer's, which a drawing of it leaves out
            // (a body's, else the window's it's set on) —
            // Whole, as the tile was over what's behind it now.
            if let own = part.layer?.backgroundColor, own.alpha > 0 { g.backgroundColor = own.copy(alpha: 1) } else {
                part.effectiveAppearance.performAsCurrentDrawingAppearance { g.backgroundColor = Theme.windowBackground.withAlphaComponent(1).cgColor }
            }
            g.frame = part.frame
            g.cornerRadius = part.layer?.cornerRadius ?? 0
            g.maskedCorners = part.layer?.maskedCorners ?? []
            g.masksToBounds = true
            g.zPosition = 30
            ghosts.append(g)
        }
        guard !ghosts.isEmpty else { return }
        let card = ghosts.map(\.frame).reduce(ghosts[0].frame) { $0.union($1) }
        let c = CGPoint(x: card.midX, y: card.midY), k: CGFloat = Motion.reduced ? 1 : 0.96
        CATransaction.begin()
        CATransaction.setCompletionBlock { ghosts.forEach { $0.removeFromSuperlayer() } }
        for g in ghosts {
            host.addSublayer(g)
            g.opacity = 0
            let fade = CABasicAnimation(keyPath: "opacity")
            fade.fromValue = 1
            fade.toValue = 0
            // Shrunk about the tile's middle, its parts with it.
            let o = g.position
            let shrink = CABasicAnimation(keyPath: "transform")
            shrink.fromValue = CATransform3DIdentity
            shrink.toValue = CATransform3DScale(CATransform3DMakeTranslation((c.x - o.x) * (1 - k), (c.y - o.y) * (1 - k), 0), k, k, 1)
            let grp = CAAnimationGroup()
            grp.animations = [fade, shrink]
            grp.duration = Motion.base
            grp.timingFunction = Motion.disappear
            g.add(grp, forKey: "fadeAway")
        }
        CATransaction.commit()
    }

    /// A tile's picture, for its ghost: a terminal's surface as it is,
    /// anything else drawn at the screen's scale.
    static func ghostPicture(of v: NSView) -> Any? {
        if let surface = v.layer?.contents, CFGetTypeID(surface as CFTypeRef) == IOSurfaceGetTypeID() { return surface }
        if v is TerminalView, let image = HoverCard.surfacePicture(of: v) { return image.cgImage(forProposedRect: nil, context: nil, hints: nil) }
        let scale = v.window?.backingScaleFactor ?? 2
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(v.bounds.width * scale), pixelsHigh: Int(v.bounds.height * scale),
                                         bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                         bytesPerRow: 0, bitsPerPixel: 0) else { return nil }
        rep.size = v.bounds.size
        v.cacheDisplay(in: v.bounds, to: rep)
        return rep.cgImage
    }

    /// Pictures of a thing as it shows — a tile's body and bar, a card —
    /// where each is, on its ground (what's behind its drawing: its
    /// layer's colour, else the window's).
    struct Pictured {
        var parts: [(NSRect, Any?)]
        var ground: CGColor?
        var whole: NSRect { parts.dropFirst().reduce(parts.first?.0 ?? .zero) { $0.union($1.0) } }
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
        for t in columns.flatMap({ $0 }) {
            guard let b = t.shown.block?.id, out[b] == nil, let body = shownBody(t) else { continue }
            out[b] = pictured(body, pills[t.shown.id])
        }
        return out
    }

    /// Each tile in view, by its placement, as `tileParts` has them.
    func placedParts() -> [PlacementID: Pictured] {
        var out: [PlacementID: Pictured] = [:]
        for t in columns.flatMap({ $0 }) {
            guard let body = shownBody(t) else { continue }
            out[t.shown.id] = pictured(body, pills[t.shown.id])
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

    /// The sheet `level` deep (1–3) above a bar, as the sheets are drawn.
    private static func sheetRect(above bar: NSRect, level: Int) -> NSRect {
        let level = CGFloat(min(max(level, 1), 3))
        let inset = level * sheetStep.inset, rise = level * sheetStep.rise
        return NSRect(x: bar.minX + inset, y: bar.maxY - Radius.surface, width: bar.width - 2 * inset, height: Radius.surface + rise)
    }

    /// Each tile in a stack in view, by its block, and the sheet above its
    /// stack's top it's in (the nearest the first, the deepest past three).
    func sheetPlaces() -> [BlockID: NSRect] {
        var out: [BlockID: NSRect] = [:]
        for c in columns.indices {
            for stack in stacks(c) {
                guard let bar = pills[stack.top.shown.id], !bar.isHidden, shownBody(stack.top) != nil else { continue }
                for (i, t) in stack.behind.enumerated() {
                    guard let b = t.shown.block?.id, out[b] == nil else { continue }
                    out[b] = Self.sheetRect(above: bar.frame, level: i + 1)
                }
            }
        }
        return out
    }

    /// What shows of a tile under its bar: its content, or its summary card.
    private func shownBody(_ t: Tile) -> NSView? {
        guard !isStashed(t.shown.id) else { return nil }
        if !t.view.isHidden, t.view.frame.height > 0 { return t.view }
        if summarized.contains(t.shown.id), let c = tileSummaries[t.shown.id], !c.isHidden { return c }
        return nil
    }

    /// A tile in view's body and bar, by its block (a block's first), and
    /// its focus ring if it has it.
    func tileViews(of block: BlockID) -> [NSView] {
        guard let t = columns.flatMap({ $0 }).first(where: { $0.shown.block?.id == block && shownBody($0) != nil }), let body = shownBody(t) else { return [] }
        return [body] + (pills[t.shown.id].map { [$0] } ?? []) + (t.shown.id == focused && !focusRing.isHidden ? [focusRing] : [])
    }

    // MARK: Morphing

    /// One thing becoming another where it goes — a tile its card, a card
    /// its tile, a sheet pulled out into its card: its outline travels and
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
        /// about as wide as it, ⌃⇥'s and ⌥⇥'s): this much of its width — seen
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
        // Those pulled out of a stack go under the one in front of them.
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
                // Out of a sheet's edge: what it says only once there's
                // room for it, not cut to a sliver of its top line.
                fade(coming, [0, 0, 1], [0, 0.1, 0.35], delay: m.delay)
                // Its ground over the sheet only as it leaves it.
                fade(c, [0, 1], [0, 0.12], delay: m.delay)
            } else if let leaving, m.to.height < 30 {
                // Into one: gone before it's a sliver, the real sheet left.
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

    /// A tile maximized grows from its place to the whole grid, the rest
    /// staying under it till it's there; restored, it shrinks back to its
    /// place over them. Laid out where it ends at once (a terminal resized
    /// once, not at every step) and its layers carried from where it was:
    /// Core Animation's, so nothing is laid out on the way. With Reduce
    /// motion, it fades in where it ends.
    private var zooming: PlacementID?
    private func zoom(_ id: PlacementID, from source: NSRect) {
        guard let tile = columns.flatMap({ $0 }).first(where: { $0.shown.id == id }) else {
            zooming = nil
            return needsLayout = true
        }
        let body = tile.view.frame
        let dest = NSRect(x: body.minX, y: body.minY, width: body.width, height: body.height + Self.barHeight)
        guard source.width > 1, source.height > 1, dest.width > 1, dest.height > 1, source != dest else {
            zooming = nil
            needsLayout = true
            return
        }
        let parts: [(NSView, CALayer)] = ([tile.view, pills[id], badges[id]] as [NSView?]).compactMap { v in v.flatMap { v in v.layer.map { (v, $0) } } }
        zooming = id
        CATransaction.begin()
        CATransaction.setCompletionBlock { [weak self] in
            for (_, l) in parts { l.zPosition = 0 }
            guard let self, self.zooming == id else { return }
            self.zooming = nil
            self.needsLayout = true
        }
        let k = CGSize(width: source.width / dest.width, height: source.height / dest.height)
        for (i, (v, l)) in parts.enumerated() {
            l.zPosition = 20 + CGFloat(i)
            let a: CABasicAnimation
            if Motion.reduced {
                a = CABasicAnimation(keyPath: "opacity")
                a.fromValue = 0
                a.toValue = 1
                a.duration = Motion.base
            } else {
                // Each part's own corner is where the layer's drawn from:
                // carried to where it was, as a part of the tile was.
                let o = v.frame.origin
                let t = CGPoint(x: source.minX + (o.x - dest.minX) * k.width - o.x, y: source.minY + (o.y - dest.minY) * k.height - o.y)
                a = CABasicAnimation(keyPath: "transform")
                a.fromValue = CATransform3DScale(CATransform3DMakeTranslation(t.x, t.y, 0), k.width, k.height, 1)
                a.toValue = CATransform3DIdentity
                a.duration = Motion.spatial * 1.25
                a.timingFunction = Motion.travel
            }
            l.add(a, forKey: "zoom")
        }
        CATransaction.commit()
    }

    /// A soft shadow under each card in the light, none in the dark
    /// (where the cards are lighter than the wash already).
    private func layoutShadows(_ bodies: [NSRect]) {
        let dark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        let wanted = dark || full != nil ? [] : bodies.filter { $0 != .zero }
        while shadowLayers.count > wanted.count { shadowLayers.removeLast().removeFromSuperlayer() }
        while shadowLayers.count < wanted.count {
            let l = CAShapeLayer()
            l.zPosition = -10
            Elevation.tile.apply(to: l)
            layer?.insertSublayer(l, at: 0)
            shadowLayers.append(l)
        }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for (l, body) in zip(shadowLayers, wanted) {
            let card = NSRect(x: body.minX, y: body.minY, width: body.width, height: body.height + Self.barHeight)
            let path = CGPath(roundedRect: card, cornerWidth: Radius.surface, cornerHeight: Radius.surface, transform: nil)
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
    private func evenColumns(_ i: Int) {
        guard i + 1 < fractions.count else { return }
        let pair = fractions[i] + fractions[i + 1]
        fractions[i] = pair / 2
        fractions[i + 1] = pair / 2
        needsLayout = true
    }

    /// The line between two tiles in a column double-clicked: the two
    /// share their height evenly.
    func evenRows(column c: Int, above a: PlacementID, below b: PlacementID) {
        guard c < columns.count else { return }
        let n = Double(max(shownTiles(c).count, 1))
        let pair = (heights[a] ?? 1 / n) + (heights[b] ?? 1 / n)
        heights[a] = pair / 2
        heights[b] = pair / 2
        needsLayout = true
    }

    /// Tiles a line's drag pushed down into the stack of the tile below,
    /// each with that tile, to be told when the drag ends.
    private var stashedDown: [(PlacementID, PlacementID)] = []
    /// The tile a line's drag goes on against, for one pushed into the
    /// stack below it: it's after that tile now.
    private var dividerBelow: [PlacementID: PlacementID] = [:]

    /// The line between two tiles dragged: the two share their room by
    /// where it is. Pushed past a tile's least height, that tile goes into
    /// a stack (its room to the other side): pushed up, the stack of the
    /// tile above it; pushed down, the stack of the tile below it, if any.
    /// The line goes on against the next, until all above or below are
    /// stashed and the tile that grew has the column, the others behind it.
    private func dragRowDivider(column c: Int, above a0: PlacementID, below b0: PlacementID, to y: CGFloat) {
        guard c < columns.count else { return }
        var b0 = b0
        while let next = dividerBelow[b0] { b0 = next }
        let column = columns[c]
        guard let ia = column.firstIndex(where: { $0.shown.id == a0 }), let ib = column.firstIndex(where: { $0.shown.id == b0 }) else { return }
        let aboves = column[...ia].filter { !isStashed($0.shown.id) }
        let belows = column[ib...].filter { !isStashed($0.shown.id) }
        guard let a = aboves.last?.shown.id, let b = belows.first?.shown.id else { return }
        let f = columnFrames()[c]
        let frames = tileFrames(column: c, in: f)
        guard let ra = column.firstIndex(where: { $0.shown.id == a }), let rb = column.firstIndex(where: { $0.shown.id == b }) else { return }
        let minHeight = Self.band + 24
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
            // Into the stack of the tile below, its own stack with it, as
            // the model's stash will have it.
            if let next = column[(rb + 1)...].first(where: { !isStashed($0.shown.id) })?.shown.id {
                let stack = column[(rb + 1)...].prefix { isStashed($0.shown.id) }
                var moved = columns[c]
                let carried = [column[rb]] + stack
                moved.removeAll { t in carried.contains { $0.shown.id == t.shown.id } }
                if let n = moved.firstIndex(where: { $0.shown.id == next }) { moved.insert(contentsOf: carried, at: n + 1) }
                columns[c] = moved
                stashedDown.append((b, next))
                dividerBelow[b] = next
            }
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
        guard let focused, let tile = columns.flatMap({ $0 }).first(where: { $0.shown.id == focused }),
              let edit = tile.view.pillEdit, let pill = pills[focused] else { return false }
        pill.beginEditing(edit)
        return true
    }

    // MARK: Hovering a stack

    override func updateTrackingAreas() {
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
        super.updateTrackingAreas()
    }

    /// The pointer over the grid itself does nothing.
    override func mouseMoved(with event: NSEvent) {}

    // MARK: Dragging tiles

    /// Whether the tile drag under way began with ⌥ (or ⌥ is held now):
    /// dropped on a tile, it covers it, the tile going behind it.
    private var coverDrag = false
    /// Whether the tile drag under way began with ⌘: the tile leaves its
    /// stack behind (a fanned pill's tile has none to bring).
    private var aloneDrag = false

    /// `alone`: the tile without its stack, whatever's held (one dragged
    /// out of a stack's fan).
    private func beginDrag(of placement: PlacementID, event: NSEvent, from view: NSView, alone: Bool = false) {
        let item = NSPasteboardItem()
        let shown = columns.flatMap { $0 }.first { $0.shown.id == placement }?.shown
        coverDrag = event.modifierFlags.contains(.option)
        aloneDrag = alone || event.modifierFlags.contains(.command)
        if event.modifierFlags.contains(.shift) {
            // ⇧-drag: not the tile but what it stands for — its path (a
            // terminal's folder, a page's address) — for wherever text or
            // files are taken: a terminal types it, an editor inserts it.
            // With ⌥ too, the link alone: nothing typed or put in.
            let linkOnly = event.modifierFlags.contains(.option)
            guard let block = shown?.block else { return }
            if linkOnly {
                item.setString("1", forType: .manifoldLinkOnly)
            } else if let text = block.path ?? block.web?.url ?? block.terminal?.cwd ?? block.place {
                // (A block with none — a command's output, a search — goes
                // as its link alone: an agent takes what it holds.)
                item.setString(text, forType: .string)
                // A file's URL too — not a folder's: a web view in the drag's
                // way takes a dragged folder for a file list and reads it.
                var isDir: ObjCBool = false
                if text.hasPrefix("/"), FileManager.default.fileExists(atPath: text, isDirectory: &isDir), !isDir.boolValue {
                    item.setString(URL(fileURLWithPath: text).absoluteString, forType: .fileURL)
                }
            }
            // And the block as a link a note takes: [title](manifold:id).
            // Not as a block: the grid takes no ⇧-drag, the views under it do.
            let title = block.displayTitle.replacingOccurrences(of: "]", with: "\\]")
            item.setString("[\(title)](manifold:\(block.id.description))", forType: .manifoldBlockLink)
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
        let dragItem = NSDraggingItem(pasteboardWriter: item)
        let image = BlockDragImage.make(for: shown)
        let p = view.convert(event.locationInWindow, from: nil)
        dragItem.setDraggingFrame(NSRect(x: p.x - 24, y: p.y - image.size.height / 2, width: image.size.width,
                                         height: image.size.height), contents: image)
        if !pathDrag { delegate?.gridDragChanged(true) }
        view.beginDraggingSession(with: [dragItem], event: event, source: self)
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

    /// Debugging: the focused tile's ticks, and its outline.
    func debugTicks(_ id: PlacementID) -> OutlineTicks? { ticks[id] }
    /// Debugging: a tile's pill.
    func debugPill(_ id: PlacementID) -> TilePill? { pills[id] }

    /// A tile's own buttons changed (a page could go back, or loads): its bar
    /// shows them as they are.
    func barChanged(_ id: PlacementID) {
        guard let view = columns.flatMap({ $0 }).first(where: { $0.shown.id == id })?.view else { return }
        pills[id]?.viewButtons = view.barButtons
    }

    /// A tile's own sidebar shown or put away: its bar's button says so.
    func sidebarChanged(_ id: PlacementID) {
        guard let view = columns.flatMap({ $0 }).first(where: { $0.shown.id == id })?.view else { return }
        pills[id]?.sidebar = view.hasSidebar ? view.sidebarShown : nil
    }

    /// A tile's menu, under the pointer, as a menu is.
    private func showPillMenu(_ id: PlacementID) {
        guard let menu = delegate?.gridPillMenu(for: id), let pill = pills[id] else { return }
        let at = NSApp.currentEvent.map { pill.convert($0.locationInWindow, from: nil) } ?? NSPoint(x: pill.bounds.midX, y: 0)
        menu.popUp(positioning: nil, at: NSPoint(x: at.x, y: at.y - 4), in: pill)
    }

    private func placeBadge(_ badge: LinkBadge, of id: PlacementID, in r: NSRect) {
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

    /// Whether the drag under way is a ⇧-drag of a block's path.
    private var pathDrag = false

    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        if pathDrag { return [.copy, .link, .generic] }
        // ⌥ copies to another workspace (as a file is copied); out of the
        // app, a file is copied.
        return context == .withinApplication ? [.move, .copy] : [.copy]
    }

    func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
        if !pathDrag { delegate?.gridDragChanged(false) }
        pathDrag = false
        aloneDrag = false
        coverDrag = false
    }

    /// On a tile's pill: into the stack behind it (a placement, not the
    /// one dragged). Near a column's side: a new column there. Else between
    /// two tiles (or above the first, below the last) of the column under
    /// the pointer.
    private func dropTarget(at point: NSPoint, dragged: PlacementID?) -> (column: Int, at: Int, rect: NSRect, newColumn: Bool, onto: PlacementID?)? {
        let frames = columnFrames()
        guard !frames.isEmpty else { return (0, 0, bounds, true, nil) }
        if dragged != nil, coverDrag || NSEvent.modifierFlags.contains(.option) {
            // ⌥: onto the tile under the pointer, whole — its shape the sign.
            for c in columns.indices {
                for (i, t) in columns[c].enumerated() where !isStashed(t.shown.id) && t.shown.id != dragged && !t.view.isHidden {
                    if t.view.frame.contains(point) { return (c, i, t.view.frame, false, t.shown.id) }
                }
            }
        }
        if dragged != nil {
            for c in columns.indices {
                for (i, t) in columns[c].enumerated() where !isStashed(t.shown.id) && t.shown.id != dragged {
                    guard let pill = pills[t.shown.id], !pill.isHidden else { continue }
                    let capsule = pill.capsule(in: self).insetBy(dx: -4, dy: -4)
                    if capsule.contains(point) { return (c, i + 1, capsule, false, t.shown.id) }
                }
            }
        }
        for (c, f) in frames.enumerated() where point.x >= f.minX && point.x <= f.maxX + Self.gap {
            let edge = min(f.width * 0.2, 80)
            if point.x < f.minX + edge {
                return (c, 0, NSRect(x: f.minX, y: f.minY, width: f.width / 2, height: f.height), true, nil)
            }
            if point.x > f.maxX - edge {
                return (c + 1, 0, NSRect(x: f.midX, y: f.minY, width: f.width / 2, height: f.height), true, nil)
            }
            let tiles = tileFrames(column: c, in: f)
            for (i, r) in tiles.enumerated() where point.y >= r.minY && point.y <= r.maxY {
                if point.y > r.midY {
                    return (c, i, NSRect(x: r.minX, y: r.midY, width: r.width, height: r.height / 2), false, nil)
                }
                return (c, i + 1, NSRect(x: r.minX, y: r.minY, width: r.width, height: r.height / 2), false, nil)
            }
            return (c, tiles.count, f, false, nil)
        }
        return nil
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation { draggingUpdated(sender) }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        let point = convert(sender.draggingLocation, from: nil)
        if convert(point, to: nil).x < 8 { delegate?.gridDragAtLeftEdge() }
        let pb = sender.draggingPasteboard
        // (Not a pill's own ⌥⇧-drag, its file already a tile here.)
        if !pathDrag, !Self.droppedFiles(pb).isEmpty || !Self.droppedPaths(pb).isEmpty, let target = dropTarget(at: point, dragged: nil) {
            // Files from outside: opened where they land, as a block is brought.
            showDrop(target.rect)
            drop = target
            dropFiles = true
            dropLinks = false
            return .copy
        }
        dropFiles = false
        dropOther = nil
        if !pathDrag, let thing = Self.dropped(pb), let target = dropTarget(at: point, dragged: nil) {
            // From another app: a page, a picture, words — a block of its own where it lands.
            showDrop(target.rect)
            drop = target
            dropOther = thing
            dropLinks = false
            return .copy
        }
        if pb.string(forType: .manifoldPlacement) == nil, pb.string(forType: .manifoldBlock) == nil,
           let link = pb.string(forType: .manifoldBlockLink), let block = TextView.blockID(inLink: link) {
            // ⇧-drag: a block's link, over a tile whose view didn't take it
            // (one that types or inserts it takes it first): linked to the
            // tile's block, its whole shape the sign.
            guard let t = tile(at: point), t.shown.block?.id != block else { hideDrop(); return [] }
            DropHint.say("Link to “\(t.shown.title)”", at: sender.draggingLocation, in: window)
            showDrop(t.view.frame)
            drop = (0, 0, t.view.frame, false, t.shown.id)
            dropLinks = true
            return .link
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
        // copied here; one of this workspace's is covered or stacked.
        return sender.draggingSourceOperationMask.contains(.move) ? .move : .copy
    }

    override func draggingExited(_ sender: NSDraggingInfo?) { hideDrop() }
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

    // MARK: ⌃⇥

    private var switcher: StackColumnView?
    /// The tiles whose views the switcher holds: the grid leaves them be.
    private var switching: Set<PlacementID> = []
    /// Tiles whose views are lent out (to a hover card, live): left be
    /// until they're given back.
    private var lent: Set<PlacementID> = []

    /// A tile whose view is elsewhere for now: in the switcher's cards, or lent.
    private func held(_ id: PlacementID) -> Bool { switching.contains(id) || lent.contains(id) }

    /// A tile's view lent out (it's out of sight: stacked, collapsed).
    func lend(_ id: PlacementID) { lent.insert(id) }

    /// A lent view back in the grid, out of sight as it was.
    func takeBack(_ id: PlacementID, view: NSView) {
        guard lent.remove(id) != nil else { return }
        if view.superview !== self, tile(id) != nil {
            view.removeFromSuperview()
            addSubview(view, positioned: .below, relativeTo: subviews.first)
        }
        needsLayout = true
    }
    var isSwitching: Bool { switcher != nil || fanWaiting }
    /// The fan asked for, waiting on its tile to grow; and ⌃⇥'s steps meanwhile.
    private var fanWaiting = false
    private var fanSteps = 0

    private var switcherMonitor: Any?

    /// The stack under `top` as cards hanging over its tile, if it has one:
    /// from ⌃⇥, the choice then stepped along; from a right-click on its
    /// title, the choice following the pointer, from the top. Either way a
    /// card clicked comes to the top, and one dragged comes out of the stack
    /// as a block dragged does (the fan closing, the rest as they were).
    @discardableResult
    /// `steps`: the choice that far down the column (up, negative) from
    /// the first, as it opens — pictured so, not moved after.
    func openStackSwitcher(_ top: PlacementID, followingPointer: Bool, roomMade: Bool = false, steps: Int = 0) -> Bool {
        guard switcher == nil, !fanWaiting else { return true }
        guard let c = columns.indices.first(where: { columns[$0].contains { $0.shown.id == top } }),
              let stack = stacks(c).first(where: { $0.top.shown.id == top }), !stack.behind.isEmpty else { return false }
        // A stack too short to fan out (down to its bar, say) grows first,
        // and fans out once it has.
        if !roomMade, delegate?.gridRoomForFan(top) == true {
            fanWaiting = true
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.glide) { [weak self] in
                guard let self else { return }
                self.fanWaiting = false
                let steps = self.fanSteps
                self.fanSteps = 0
                _ = self.openStackSwitcher(top, followingPointer: followingPointer, roomMade: true, steps: steps)
            }
            return true
        }
        land()
        layoutSubtreeIfNeeded()
        let body = stack.top.view.frame
        // The top first, then those behind it, nearest first: each as its
        // summary card, in place of the tile, its bar too.
        let order = [stack.top] + stack.behind
        let entries = order.map { t in
            delegate?.gridSummary(t.shown.id) ?? SummaryCardContent(id: t.shown.id, symbol: t.shown.symbol,
                                                                     summary: t.shown.block?.summary() ?? BlockSummary(title: t.shown.title))
        }
        let s = StackColumnView(entries: entries, selection: ((steps % entries.count) + entries.count) % entries.count)
        s.frame = NSRect(x: body.minX, y: body.minY, width: body.width, height: body.height + Self.barHeight)
        s.layer?.zPosition = 20
        s.followsPointer = followingPointer
        // A card clicked comes to the top; ⌘-clicked, it comes out of the
        // stack (as ⌘ takes a stack's top alone when dragged).
        s.onPick = { [weak self] id, mods in
            if mods.contains(.command) { self?.settleStackSwitcher(takingOut: id) } else { self?.settleStackSwitcher(to: id) }
        }
        s.onDragOut = { [weak self] id, event in
            guard let self else { return }
            self.settleStackSwitcher(cancel: true)
            self.beginDrag(of: id, event: event, from: self, alone: true)
        }
        s.onCancel = { [weak self] in self?.settleStackSwitcher(cancel: true) }
        // From ⌃⇥, the pointer over the cards: as from the sheets after.
        s.onFollowsPointer = { [weak self] in
            guard let self else { return }
            self.watchSwitcherClicks()
            self.delegate?.gridSwitcherFollowsPointer()
        }
        // The tile as it is, and the pile behind it, to be seen becoming the
        // cards (a page's picture a moment coming: the column out of sight
        // till then).
        addSubview(s)
        switcher = s
        needsLayout = true
        s.present(dealt: false)
        s.alphaValue = 0
        picturing(shownBody(stack.top) ?? stack.top.view, pills[top], wait: 0.12) { [weak self, weak s] tile in
            guard let self, let s, self.switcher === s, !s.isClosing else { return }
            s.alphaValue = 1
            // The tile itself out of sight under the column: its picture
            // is what's seen going (it was seen fading under the column's
            // ground coming in).
            for v in [shownBody(stack.top), stack.top.view, self.pills[top], top == self.focused ? self.focusRing : nil].compactMap({ $0 }) where v.alphaValue > 0 {
                v.alphaValue = 0
                self.unseen.append(v)
            }
            self.unfold(s, tile: tile)
        }
        if followingPointer { watchSwitcherClicks() }
        return true
    }

    // MARK: ⌃⇥, seen

    /// Pictures on their way, and the tiles kept out of sight meanwhile:
    /// all put back at once when the next ⌃⇥ comes before they're done,
    /// never one flight under another.
    private var flying: [CALayer] = []
    private var unseen: [NSView] = []

    /// Debugging: each picture on its way, where it is this moment, and
    /// what it holds (each's scale and opacity).
    var debugFlights: String { Self.describe(flying) }

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
        switcher?.cardsShown = true
    }

    /// How much of its width a tile's picture keeps, become its card.
    static let cardShrink: CGFloat = 0.6

    /// The switcher opening, as Overview opens: the tile becomes its card,
    /// its picture shrinking as it goes, and the rest of its stack slide
    /// out from under it, each a whole card showing what it is all the way,
    /// down to its place (only cross-fading where they end, with Reduce
    /// motion). The cards themselves show once theirs are there.
    private func unfold(_ s: StackColumnView, tile: Pictured) {
        guard let host = layer else { return }
        let whole = tile.whole
        let cards = s.cardPictures(in: self)
        // Where the first card is: the stack's top, which the rest come
        // out from under.
        let first = cards.first.map(\.frame).flatMap { $0 == .zero ? nil : $0 } ?? whole
        var items: [Morph] = []
        for (i, c) in cards.enumerated() where c.frame != .zero {
            let card = Pictured(parts: [(c.frame, c.picture)], ground: c.ground)
            if i == 0 {
                items.append(Morph(from: whole, to: c.frame, leaving: tile, coming: card, z: 10, shrink: Self.cardShrink))
            } else {
                // Whole, from under the first, where the stack's top is.
                let under = NSRect(x: c.frame.minX, y: first.maxY - c.frame.height, width: c.frame.width, height: c.frame.height)
                items.append(Morph(from: under, to: c.frame, coming: card, delay: Double(i - 1) * 0.02, z: -CGFloat(i)))
            }
        }
        guard !items.isEmpty else { return }
        s.cardsShown = false
        let d = Motion.spatial * 1.5
        flying += Self.morph(items, in: host, over: d) { [weak s] in s?.cardsShown = true }
    }

    /// A tile chosen in the switcher, waiting to be laid out where it goes,
    /// and its card as it was, where it was: it becomes its tile from there.
    /// `host`: where the card is and becomes it (its terms), if not here —
    /// over a space sliding in, the place it slides to.
    private var pendingArrival: (id: PlacementID, card: Pictured?, from: NSRect, at: Date, host: NSView?)?

    /// The tile chosen is laid out: its card becomes it, and the stack's
    /// tiles show again once it's there.
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
            self.flying += Self.morph([Morph(from: r, to: to, leaving: card, coming: shown, shrink: Self.cardShrink)], in: host, over: Motion.spatial * 1.5) { [weak self] in
                guard let self, self.landingAt == landing else { return }
                self.unseen.forEach { $0.alphaValue = 1 }
                self.unseen = []
                // Landed: the rest put by with it, so none is drawn over
                // the tile once it's there (they're where the sheets are).
                held.forEach { $0.removeFromSuperlayer() }
                self.flying.forEach { $0.removeFromSuperlayer() }
                self.flying = []
            }
            held.filter { $0.name == "waiting" }.forEach { $0.removeFromSuperlayer() }
        }
    }

    /// Debugging: the last tile arrived at's picture.
    var debugArrival: AnyObject?

    /// The arrival under way: a later one (or `land`) puts it by.
    private var landingAt: Date?

    /// Escape, or a click away from the cards, lets the stack be.
    private func watchSwitcherClicks() {
        guard switcherMonitor == nil else { return }
        switcherMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .leftMouseDown, .rightMouseDown]) { [weak self] event in
            guard let self, let s = self.switcher, event.window === self.window else { return event }
            if event.type == .keyDown {
                guard event.keyCode == 53 else { return event }
                self.settleStackSwitcher(cancel: true)
                return nil
            }
            if !s.frame.contains(self.convert(event.locationInWindow, from: nil)) { self.settleStackSwitcher(cancel: true) }
            return event
        }
    }

    /// ⌃⇥: the stack under `top` as cards over its tile, opened if it
    /// isn't, and the choice moved a step down (back: up). False when the
    /// tile has no stack.
    func stepStackSwitcher(_ top: PlacementID, back: Bool) -> Bool {
        let step = back ? -1 : 1
        if fanWaiting { fanSteps += step; return true }
        if let s = switcher { s.move(step); return true }
        return openStackSwitcher(top, followingPointer: false, steps: step)
    }

    /// The switcher closes on `id` (nil: the card chosen; `cancel`: the
    /// top as it was), which comes forward to fill the tile; the views go
    /// back to the grid, and the stack is told which is its top now.
    func settleStackSwitcher(to id: PlacementID? = nil, cancel: Bool = false, takingOut out: PlacementID? = nil) {
        guard let s = switcher, !s.isClosing else { return }
        if let switcherMonitor { NSEvent.removeMonitor(switcherMonitor) }
        switcherMonitor = nil
        let top = s.topID
        let chosen = cancel || out != nil ? top : (id ?? s.selectedID)
        // The cards back where they go: the others into the sheets above
        // the tile, the chosen one held where it is till its tile is laid
        // out, then becoming it; the stack's tiles out of sight meanwhile
        // (a second at most).
        land()
        let cards = s.cardPictures(in: self)
        s.close(on: chosen)
        s.tearDown(keeping: chosen, in: self)
        s.removeFromSuperview()
        if switcher === s { switcher = nil }
        let tileRect = s.frame
        let bar = NSRect(x: tileRect.minX, y: tileRect.maxY - Self.barHeight, width: tileRect.width, height: Self.barHeight)
        var items: [Morph] = []
        var level = 0
        let at = Date()
        pendingArrival = (chosen, nil, tileRect, at, nil)
        // The column's ground stays under the cards till the tile's there,
        // not the backdrop through a tile out of sight.
        if let host = layer, let ground = s.layer?.backgroundColor {
            let plate = CALayer()
            plate.name = "plate"
            plate.backgroundColor = ground
            plate.frame = tileRect
            plate.cornerRadius = Radius.surface
            plate.cornerCurve = .continuous
            plate.zPosition = 30
            host.addSublayer(plate)
            flying.append(plate)
        }
        // The rest slide back up under the stack's top, whole, as the one
        // chosen grows over them.
        let head = cards.first.map(\.frame).flatMap { $0 == .zero ? nil : $0 }
        for c in cards {
            let card = Pictured(parts: [(c.frame, c.picture)], ground: c.ground)
            if c.id == chosen {
                guard c.frame != .zero else { continue }
                pendingArrival = (chosen, card, c.frame, at, nil)
                hold(c.picture, ground: c.ground, at: c.frame, in: self)
                continue
            }
            level += 1
            guard c.frame != .zero else { continue }
            let under = head.map { NSRect(x: c.frame.minX, y: $0.maxY - c.frame.height, width: c.frame.width, height: c.frame.height) } ?? Self.sheetRect(above: bar, level: level)
            items.append(Morph(from: c.frame, to: under, leaving: card, z: -CGFloat(level)))
        }
        // Kept where they end till the chosen tile's landed over them.
        if let host = layer { flying += Self.morph(items, in: host, over: Motion.spatial * 1.5, keeping: true) }
        for id in Set([chosen, top]) {
            for v in [tile(id)?.view, pills[id]].compactMap({ $0 }) {
                v.alphaValue = 0
                unseen.append(v)
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
            guard let self, self.pendingArrival?.at == at else { return }
            self.land()
        }
        // The views back in the grid, as they'll be once the stack has its
        // new top: the chosen one showing, the rest behind it.
        for id in switching {
            guard let t = tile(id) else { continue }
            if t.view.superview !== self { addSubview(t.view) }
            t.view.isHidden = id != chosen
        }
        switching = []
        needsLayout = true
        if chosen != top { delegate?.gridSwap(chosen) }
        if let out, out != top { delegate?.gridUnstash(out) }
    }

    /// A card held where it is till its tile is laid out.
    private func hold(_ picture: CGImage?, ground: CGColor, at r: NSRect, in view: NSView) {
        guard let host = view.layer else { return }
        let w = CALayer()
        w.name = "waiting"
        w.contents = picture
        w.backgroundColor = ground
        w.frame = r
        w.cornerRadius = Radius.surface
        w.cornerCurve = .continuous
        w.masksToBounds = true
        w.zPosition = 40
        host.addSublayer(w)
        flying.append(w)
    }

    /// A card chosen elsewhere (⌥⇥'s), where it is in `view`'s terms,
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

    private func tile(_ id: PlacementID) -> Tile? { columns.flatMap { $0 }.first { $0.shown.id == id } }

    /// The shown tile under a point.
    private func tile(at point: NSPoint) -> Tile? {
        for c in columns.indices {
            // The tile, its bar too (a link dropped on a tile's name links to it).
            for t in columns[c] where !isStashed(t.shown.id) && !t.view.isHidden
                && (t.view.frame.contains(point) || pills[t.shown.id].map { !$0.isHidden && $0.frame.contains(point) } == true) { return t }
        }
        return nil
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        DropHint.hush()
        defer { hideDrop() }
        guard let target = drop else { return false }
        let pb = sender.draggingPasteboard
        if let thing = dropOther {
            dropOther = nil
            delegate?.gridOpenDropped(thing, column: target.column, at: target.at, newColumn: target.newColumn)
            return true
        }
        if dropFiles {
            dropFiles = false
            // A folder's entries on their host, another's too; else files.
            let paths = Self.droppedPaths(pb)
            if !paths.isEmpty {
                delegate?.gridOpenPaths(paths, column: target.column, at: target.at, newColumn: target.newColumn)
                return true
            }
            let files = Self.droppedFiles(pb)
            guard !files.isEmpty else { return false }
            delegate?.gridOpenFiles(files, column: target.column, at: target.at, newColumn: target.newColumn)
            return true
        }
        if dropLinks {
            guard let onto = target.onto, let link = pb.string(forType: .manifoldBlockLink), let block = TextView.blockID(inLink: link) else { return false }
            delegate?.gridLink(block, to: onto)
            return true
        }
        if let placement = pb.string(forType: .manifoldPlacement) {
            if let onto = target.onto {
                if dropCovers { delegate?.gridCover(placement, over: onto, alone: aloneDrag) } else { delegate?.gridStash(placement, behind: onto, alone: aloneDrag) }
            } else {
                delegate?.gridMove(placement, column: target.column, at: target.at, newColumn: target.newColumn, alone: aloneDrag)
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
        dropLinks = false
    }

    /// The sheets behind a card with a stack (§3.1): each a rounded sheet
    /// a little narrower than the one before, risen a few points above the
    /// card, the rest of it beneath — layers under the cards, as a stack
    /// of paper. Laid out with the cards.
    private var sheetLayers: [CAShapeLayer] = []
    /// Where the sheets above each stacked tile's bar take a click.
    private var sheetTargets: [SheetsTarget] = []

    private func layoutSheetTargets(_ targets: [(PlacementID, NSRect)]) {
        while sheetTargets.count > targets.count { sheetTargets.removeLast().removeFromSuperview() }
        while sheetTargets.count < targets.count {
            let t = SheetsTarget()
            t.onClick = { [weak self, weak t] in
                guard let self, let top = t?.top else { return }
                self.hidePeek()
                self.fanOut(top)
            }
            // Over the sheets — the gap between tiles, where a drag resizes
            // — they rise only once the pointer rests there, no button
            // down: passing through to the line between the tiles, they don't.
            t.onHover = { [weak self, weak t] inside in
                guard let self else { return }
                self.hoveringSheets = inside ? t?.top : nil
                self.peekDwell?.cancel()
                guard inside, let top = t?.top else { return self.leavePeekSoon() }
                let work = DispatchWorkItem { [weak self] in
                    guard let self, self.hoveringSheets == top, NSEvent.pressedMouseButtons == 0 else { return }
                    self.showPeek(top)
                }
                self.peekDwell = work
                DispatchQueue.main.asyncAfter(deadline: .now() + Self.peekDwellTime, execute: work)
            }
            // A press there is the resize's: no tabs over it.
            t.onPress = { [weak self] in
                self?.peekDwell?.cancel()
                self?.hidePeek()
            }
            // Dragged, it's the line between the tiles that moves.
            t.divider = { [weak self, weak t] in
                guard let self, let t else { return nil }
                return self.rowDividers.first { !$0.isHidden && $0.frame.intersects(t.frame.insetBy(dx: 0, dy: -2)) }
            }
            sheetTargets.append(t)
        }
        // Over the line between the tiles, which is where they show.
        let above = subviews.lastIndex { $0 is RowDividerView } ?? -1
        for (t, (id, rect)) in zip(sheetTargets, targets) {
            t.top = id
            t.frame = rect
            if t.superview !== self || (subviews.firstIndex(of: t) ?? -1) < above { addSubview(t, positioned: .above, relativeTo: nil) }
        }
    }
    /// A shadow under each card, in the light (§3.1): the cards lifted a
    /// little off the wash.
    private var shadowLayers: [CAShapeLayer] = []
    /// Where each tile was laid out last, so a tile that moves (placed,
    /// closed, grown, stashed) glides there, while a window resized or
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

    /// Each stack's depth as the sheets were last laid out: a stack that
    /// formed or grew since has its sheets drop into place.
    private var sheetDepths: [PlacementID: Int]?
    /// The tabs the sheets rise into while the pointer is over them.
    private var peek: StackPeek?

    /// Sheets stepped in and risen per level: within the gap between tiles
    /// (three deep at most), so a stack takes no room a tile alone doesn't.
    private static let sheetStep: (inset: CGFloat, rise: CGFloat) = (9, 3)

    private func layoutSheets() {
        var wanted: [(NSRect, Int, PlacementID)] = []
        var targets: [(PlacementID, NSRect)] = []
        var depths: [PlacementID: Int] = [:]
        for (id, pill) in pills where !pill.isHidden && pill.behind > 0 && fanned != id && switcher?.topID != id {
            let bar = pill.frame
            depths[id] = pill.behind
            for level in stride(from: min(pill.behind, 3), through: 1, by: -1) {
                let inset = CGFloat(level) * Self.sheetStep.inset
                let rise = CGFloat(level) * Self.sheetStep.rise
                wanted.append((NSRect(x: bar.minX + inset, y: bar.maxY - Radius.surface, width: bar.width - 2 * inset, height: Radius.surface + rise), level, id))
            }
            // What shows of the sheets above the bar takes a click — a
            // little taller than they are, to be hit.
            let rise = CGFloat(min(pill.behind, 3)) * Self.sheetStep.rise
            targets.append((id, NSRect(x: bar.minX + 6, y: bar.maxY, width: bar.width - 12, height: max(8, rise + 3))))
        }
        // Stacks formed or grown since the last layout (not at the first).
        let grown: Set<PlacementID> = sheetDepths.map { old in Set(depths.filter { $0.value > (old[$0.key] ?? 0) }.keys) } ?? []
        sheetDepths = depths
        if let p = peek, depths[p.top] == nil || fanned == p.top { hidePeek() }
        layoutSheetTargets(targets)
        while sheetLayers.count > wanted.count { sheetLayers.removeLast().removeFromSuperlayer() }
        while sheetLayers.count < wanted.count {
            let l = CAShapeLayer()
            l.lineWidth = 0.5
            layer?.insertSublayer(l, at: 0)
            sheetLayers.append(l)
        }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        // Under the cards, and the nearer sheet (the wider) over the farther:
        // each stack's are wanted farthest first, and laid in that order,
        // bottommost first (a zPosition alone left the farthest on top).
        for (i, l) in sheetLayers.enumerated() where layer?.sublayers?.firstIndex(of: l) != i {
            l.removeFromSuperlayer()
            layer?.insertSublayer(l, at: UInt32(i))
        }
        effectiveAppearance.performAsCurrentDrawingAppearance {
            for (l, (rect, level, _)) in zip(sheetLayers, wanted) {
                let path = CGPath(roundedRect: rect, cornerWidth: Radius.surface, cornerHeight: Radius.surface, transform: nil)
                l.path = path
                l.fillColor = Theme.sheet(level: level).cgColor
                // Each a card of its own: an edge, and a shadow on the one
                // beneath.
                l.strokeColor = EdgeColor.control.cgColor
                l.shadowPath = path
                l.shadowColor = NSColor.black.cgColor
                l.shadowOpacity = 0.18
                l.shadowRadius = 1.5
                l.shadowOffset = CGSize(width: 0, height: 0.5)
            }
        }
        CATransaction.commit()
        // A stack just formed (or grown): its sheets drop into place, the
        // deepest last, so it's seen being made.
        for (l, (_, level, id)) in zip(sheetLayers, wanted) where grown.contains(id) {
            let drop = CABasicAnimation(keyPath: "transform.translation.y")
            drop.fromValue = Motion.distance(10)
            drop.toValue = 0
            let fade = CABasicAnimation(keyPath: "opacity")
            fade.fromValue = 0
            fade.toValue = 1
            let group = CAAnimationGroup()
            group.animations = [drop, fade]
            group.duration = Motion.spatial
            group.beginTime = CACurrentMediaTime() + Double(level - 1) * 0.05 * Motion.slowdown
            group.fillMode = .backwards
            group.timingFunction = Motion.settle
            l.add(group, forKey: "drop")
        }
    }

    /// The pointer over a stack's sheets: they rise into tabs, one for each
    /// tile behind (its symbol and title), nearest first — over what's
    /// above, laid out as nothing; gone as it leaves. A click still fans.
    private func showPeek(_ top: PlacementID) {
        guard fanned != top, let pill = pills[top], !pill.isHidden,
              let stack = columns.indices.lazy.compactMap({ c in self.stacks(c).first { $0.top.shown.id == top } }).first,
              !stack.behind.isEmpty else { return hidePeek() }
        if peek?.top == top { return }
        hidePeek()
        let p = StackPeek(top: top, tiles: stack.behind.map { ($0.shown.id, $0.shown.title, $0.shown.block.map { Theme.symbolName(for: $0) } ?? Theme.symbolName(for: $0.shown.placement.lens, path: $0.shown.path)) })
        p.frame = p.frame(over: pill.frame, within: bounds)
        // A tab clicked: its tile to the top, as a fanned card picked;
        // ⌘-clicked, out of the stack.
        p.onPick = { [weak self] id, mods in
            self?.hidePeek()
            if mods.contains(.command) { self?.delegate?.gridUnstash(id) } else { self?.delegate?.gridSwap(id) }
        }
        // Dragged: the tile out of the stack, as a fanned card dragged.
        p.onDragOut = { [weak self] id, event in
            guard let self else { return }
            self.hidePeek()
            self.beginDrag(of: id, event: event, from: self, alone: true)
        }
        p.onMore = { [weak self] in
            self?.hidePeek()
            self?.fanOut(top)
        }
        p.onHover = { [weak self] inside in if !inside { self?.leavePeekSoon() } }
        addSubview(p, positioned: .above, relativeTo: nil)
        peek = p
        p.rise()
    }

    /// The sheets (or stack button) hovered now, if any (the tabs stay
    /// while either is).
    private var hoveringSheets: PlacementID?
    /// The tabs to rise once the pointer has rested on the sheets.
    private var peekDwell: DispatchWorkItem?
    private static let peekDwellTime: TimeInterval = 0.5

    /// The pointer gone from the sheets or the tabs: the tabs go too, a
    /// moment later, unless it's come onto the other.
    private func leavePeekSoon() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { [weak self] in
            guard let self, let p = self.peek, !p.hovered, self.hoveringSheets != p.top else { return }
            self.hidePeek()
        }
    }

    private func hidePeek() {
        peek?.fall()
        peek = nil
    }
}

/// The dot in a tile's bar for a text with unsaved edits: grey, or amber
/// when the file also changed on disk beneath them. Clicked, it saves, or
/// (amber) asks which of the two to keep.
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
        layer?.borderWidth = 0.5
        themed {
            $0.layer?.backgroundColor = Theme.accent.withAlphaComponent(0.12).cgColor
            $0.layer?.borderColor = Theme.accent.withAlphaComponent(0.35).cgColor
        }
        icon.image = Theme.symbol("server.rack", size: 9, weight: .semibold)
        icon.contentTintColor = Theme.accent
        label.font = UIType.caption
        label.textColor = Tints.accentText
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
    var onDragStart: ((NSEvent) -> Void)?
    private let glass = NSView()
    private let icon = NSImageView()
    private let name = NSTextField(labelWithString: "")
    private let glyph = StatusGlyph()
    /// The block's host, when it isn't the workspace's (§8).
    private let hostPill = HostPill()
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
    /// Right-clicked: the stack behind the tile, called up (or its menu).
    var onRightClick: ((NSEvent) -> Void)?
    /// What the links' pill takes of the bar, left of the buttons.
    /// What the links' pill wants of the bar, its sheets included; what
    /// it's given is `linkGiven`, after the shrinkage below.
    var linkWanted: CGFloat = 0 { didSet { if linkWanted != oldValue { needsLayout = true } } }
    private(set) var linkGiven: CGFloat = 0 { didSet { if linkGiven != oldValue { onLinkRoom?(linkGiven) } } }
    /// The links' room changed as the bar laid out (it was resized): for
    /// the capsule, which the grid placed, to take it at once.
    var onLinkRoom: ((CGFloat) -> Void)?
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
    private var focused = false
    private var maximized = false
    /// How many stashed tiles are bunched behind this tile (§3.1): the
    /// grid draws their edges above the bar; the bar says how many.
    var behind = 0 { didSet { if behind != oldValue { needsLayout = true; superview?.needsLayout = true } } }
    private let subtitle = NSTextField(labelWithString: "")
    private let close = IconButton(symbol: "xmark", size: 9, weight: .semibold, target: nil, action: nil)
    /// With tiles behind it: the stack fanned out.
    private let fanButton = IconButton(symbol: "square.stack", size: 10, weight: .medium, target: nil, action: nil)
    /// How many are behind, on the stack button's corner, as a badge on an icon.
    private let fanCount = CountBadge()
    var onFan: (() -> Void)?
    /// The pointer come over the stack button (true) or gone.
    var onFanHover: ((Bool) -> Void)?
    /// The view's own sidebar (an outline, a PDF's pages), shown or not;
    /// nil, a view without one: no button.
    private let sidebarButton = IconButton(symbol: "sidebar.left", size: 10, weight: .medium, target: nil, action: nil)
    var sidebar: Bool? {
        didSet {
            guard sidebar != oldValue else { return }
            sidebarButton.contentTintColor = sidebar == true ? Theme.accent : Theme.secondaryText
            sidebarButton.toolTip = sidebar == true ? "Hide Outline (⌥⌘S)" : "Show Outline (⌥⌘S)"
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
    /// What the bar's right end takes now, its status, tag and dot included.
    var rightTaken: CGFloat {
        var w: CGFloat = 10
        if !close.isHidden { w += 22 }
        if !corner.isHidden { w += 22 }
        if !sidebarButton.isHidden { w += 22 }
        if !fanButton.isHidden { w += 22 }
        w += CGFloat(ownButtons.filter { !$0.isHidden }.count) * 22
        if !glyph.isHidden { w += StatusGlyph.size + 8 }
        return w
    }

    /// The bar's frame in `view`'s coordinates (what a drop on it stashes behind).
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
        fanButton.target = self
        fanButton.action = #selector(fanClicked)
        fanButton.onHover = { [weak self] inside in self?.onFanHover?(inside) }
        fanButton.isHidden = true
        fanCount.isHidden = true
        editor.isBordered = false
        editor.drawsBackground = false
        editor.focusRingType = .none
        editor.font = UIType.detail
        editor.cell?.usesSingleLineMode = true
        editor.cell?.lineBreakMode = .byTruncatingTail
        editor.delegate = self
        editor.isHidden = true
        for v in [icon, name, subtitle, glyph, fanButton, fanCount, sidebarButton, corner, close, editor, hostPill] { addSubview(v) }
        hostPill.isHidden = true
        themed { $0.updateColors() }
    }

    @objc private func closeClicked() { onClose?() }
    @objc private func fanClicked() { onFan?() }

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

    private var stashed = false

    /// The symbol the icon shows, so it's set only when it changes.
    private var symbolName = ""

    /// Shown afresh on every render (each keystroke in a note is one):
    /// only what differs is touched, or the images and labels would be
    /// redone each time and seen to blink.
    func show(_ shown: Shown, focused: Bool, maximized: Bool = false, stashed: Bool = false) {
        if self.maximized != maximized || corner.image == nil {
            self.maximized = maximized
            corner.image = Theme.symbol(maximized ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right", size: 9, weight: .semibold)
            corner.toolTip = maximized ? "Restore (⇧⌘↩)" : "Maximize (⇧⌘↩)"
        }
        self.stashed = stashed
        if corner.isHidden != stashed { corner.isHidden = stashed }
        // A page: its site's icon, once seen; else the kind's symbol.
        if let favicon = shown.block?.web.flatMap({ Favicons.image(forPage: $0.url) }) {
            if icon.image !== favicon { icon.image = favicon }
            symbolName = ""
        } else if symbolName != shown.symbol {
            symbolName = shown.symbol
            icon.image = Theme.symbol(shown.symbol, size: 11)
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
        showRest(shown, stashed: stashed, focused: focused)
    }

    /// What the bar was last shown for: its subtitle made again as the tile
    /// collapses or opens.
    private var lastShown: Shown?

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

    private func showRest(_ shown: Shown, stashed: Bool, focused: Bool) {
        if close.isHidden != stashed { close.isHidden = stashed }
        let look: StatusGlyph.Look? = shown.offline ? .offline : StatusGlyph.look(of: shown.block)
        if glyph.block != shown.block?.id { glyph.block = shown.block?.id }
        if glyph.look != look { glyph.look = look }
        if glyph.isHidden != (look == nil) { glyph.isHidden = look == nil }
        let tip = shown.offline ? "Its host can't be reached: as last seen" : StatusGlyph.tooltip(shown.block)
        if glyph.toolTip != tip { glyph.toolTip = tip }
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
            glass.layer?.borderColor = (hovered ? EdgeColor.accentStrong : EdgeColor.subtle).cgColor
        }
        glass.layer?.borderWidth = hovered ? 1.5 : 0
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
        x += 22
        // Shrinkage (§3.1): as the bar narrows, what's on it gives way in
        // order, so the name keeps at least a little room — the place
        // goes first (below), then the links' pill shrinks to its arrow
        // and symbol, then to its arrow alone, then maximize goes, then
        // the pill altogether; the × and the status stay, and last the
        // name itself is cut.
        let showClose = !stashed && showsButtons
        var showCorner = !stashed && showsButtons
        var showSidebar = showCorner && sidebar != nil
        var showFan = showCorner && behind > 0 && !maximized
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
            if showFan { used += 22 }
            if showOwn { used += ownWidth }
            if !glyph.isHidden { used += StatusGlyph.size + 8 }
            return bounds.width - used
        }
        // The view's own buttons go first of all: what the tile is matters more.
        if spare() < nameNeed, showOwn { showOwn = false }
        if spare() < nameNeed, linkWanted > 0 { linkRoom = min(linkRoom, Self.linkCompact + 14) }
        if spare() < nameNeed, linkWanted > 0 { linkRoom = min(linkRoom, Self.linkMinimal + 14) }
        if spare() < nameNeed, showSidebar { showSidebar = false }
        if spare() < nameNeed, showFan { showFan = false }
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
        fanButton.isHidden = !showFan
        fanCount.isHidden = !showFan
        if showFan {
            fanButton.frame = NSRect(x: right - 16, y: (h - 16) / 2, width: 16, height: 16)
            // The count on its lower right, over the icon's corner.
            fanCount.stringValue = behind > 9 ? "9+" : "\(behind)"
            let w: CGFloat = behind > 9 ? 14 : 10
            fanCount.frame = NSRect(x: fanButton.frame.maxX - w + 3, y: fanButton.frame.minY - 3, width: w, height: 10)
            fanButton.toolTip = "Show the \(behind == 1 ? "tile" : "\(behind) tiles") behind this one (⌃⇥)"
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
        if !glyph.isHidden {
            glyph.frame = NSRect(x: right - StatusGlyph.size, y: (h - StatusGlyph.size) / 2, width: StatusGlyph.size, height: StatusGlyph.size)
            right -= StatusGlyph.size + 8
        }
        // The links' pill sits before the dot and the buttons: the name stops short of it.
        right -= linkRoom
        let th = ceil(name.intrinsicContentSize.height)
        let wanted = nameWanted
        let hostRoom = showHost ? hostWidth + 8 : 0
        let nw = min(wanted, max(0, right - x - hostRoom))
        name.frame = NSRect(x: x - 2, y: ((h - th) / 2).rounded() - 0.5, width: nw, height: th)
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

    /// The open hand over the bar, which drags; the pointing hand over
    /// what's clicked on it — the symbol (the menu), maximize and close;
    /// the I-beam over an address to edit.
    private var cursorSpots: [(NSRect, NSCursor)] {
        var spots: [(NSRect, NSCursor)] = [(icon.frame.insetBy(dx: -8, dy: -6), .pointingHand)]
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

    override func mouseDown(with event: NSEvent) { downAt = event.locationInWindow }

    override func rightMouseDown(with event: NSEvent) {
        if let onRightClick { onRightClick(event) } else { super.rightMouseDown(with: event) }
    }

    override func mouseDragged(with event: NSEvent) {
        guard let start = downAt else { return }
        let p = event.locationInWindow
        guard hypot(p.x - start.x, p.y - start.y) > 4 else { return }
        downAt = nil
        onDragStart?(event)
    }

    override func mouseUp(with event: NSEvent) {
        if downAt != nil {
            let p = convert(event.locationInWindow, from: nil)
            // Clicks in a row are clicks each (two quick ones grow twice);
            // the corner maximizes.
            if event.modifierFlags.contains(.shift) { onPathClick?() }
            else if icon.convert(icon.bounds, to: self).insetBy(dx: -8, dy: -6).contains(p) { onIconClick?(event.modifierFlags) } else { onClick?(p, event.modifierFlags) }
        }
        downAt = nil
    }
}

/// What shows of a stack's sheets above its top tile's bar: clicked, the
/// stack fans out; dragged, the line between the tiles under it moves.
final class SheetsTarget: NSView {
    var top: PlacementID?
    var onClick: (() -> Void)?
    /// The pointer come over the sheets (true) or gone (false).
    var onHover: ((Bool) -> Void)?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self))
    }

    override func mouseEntered(with event: NSEvent) { onHover?(true) }
    override func mouseExited(with event: NSEvent) { onHover?(false) }
    var divider: (() -> RowDividerView?)?
    /// Pressed: before it's known to be a click or a drag.
    var onPress: (() -> Void)?
    private var downAt: NSPoint?
    private var moved = false
    private var dragging: RowDividerView?

    override func resetCursorRects() { addCursorRect(bounds, cursor: .pointingHand) }
    override func mouseDown(with event: NSEvent) {
        onPress?()
        downAt = event.locationInWindow
        moved = false
        dragging = nil
    }

    override func mouseDragged(with event: NSEvent) {
        if !moved, let at = downAt, hypot(event.locationInWindow.x - at.x, event.locationInWindow.y - at.y) > 3 {
            moved = true
            dragging = divider?()
            dragging?.mouseDown(with: event)
            if dragging != nil { NSCursor.resizeUpDown.set() }
        }
        dragging?.mouseDragged(with: event)
    }

    override func mouseUp(with event: NSEvent) {
        if let d = dragging { d.mouseUp(with: event) } else if downAt != nil, !moved { onClick?() }
        downAt = nil
        moved = false
        dragging = nil
    }
}

/// The grab area over the line between two tiles in a column: dragged,
/// it moves; double-clicked, the two share their room evenly.
final class RowDividerView: NSView {
    var onDrag: ((CGFloat) -> Void)?
    var onEnd: (() -> Void)?
    var onDoubleClick: (() -> Void)?

    override func resetCursorRects() { addCursorRect(bounds, cursor: .resizeUpDown) }
    override func mouseDown(with event: NSEvent) { if event.clickCount == 2 { onDoubleClick?() } }

    override func mouseDragged(with event: NSEvent) {
        guard let superview else { return }
        onDrag?(superview.convert(event.locationInWindow, from: nil).y)
    }

    override func mouseUp(with event: NSEvent) { onEnd?() }
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
        guard Thread.isMainThread, MainActor.assumeIsolated({ NSApp.isActive }) else { return }
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

    override func mouseDown(with event: NSEvent) { if event.clickCount == 2 { onDoubleClick?() } }

    override func mouseDragged(with event: NSEvent) {
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

/// A stack's tiles as tabs risen above its sheets while the pointer is over
/// them (§3.1): one per tile behind, nearest lowest and widest, each its
/// symbol and title, the rest counted past four. Drawn over whatever is
/// above, taking no room. A tab clicked brings its tile to the top; dragged,
/// it takes the tile out of the stack, to be dropped where you like; the
/// count clicked fans the stack.
final class StackPeek: NSView {
    let top: PlacementID
    private let tiles: [(id: PlacementID, title: String, symbol: String)]
    private static let tabHeight: CGFloat = 20, shown = 4
    var onPick: ((PlacementID, NSEvent.ModifierFlags) -> Void)?
    var onDragOut: ((PlacementID, NSEvent) -> Void)?
    var onMore: (() -> Void)?
    /// The pointer come onto the tabs (true) or gone from them (false).
    var onHover: ((Bool) -> Void)?
    private(set) var hovered = false
    private var hoveredTab: Int? { didSet { if hoveredTab != oldValue { needsDisplay = true } } }
    private var downAt: (tab: Int, point: NSPoint)?

    init(top: PlacementID, tiles: [(PlacementID, String, String)]) {
        self.top = top
        self.tiles = tiles.map { (id: $0.0, title: $0.1, symbol: $0.2) }
        super.init(frame: .zero)
        wantsLayer = true
        alphaValue = 0
    }

    required init?(coder: NSCoder) { fatalError() }

    private var rows: Int { min(tiles.count, Self.shown) + (tiles.count > Self.shown ? 1 : 0) }

    /// Where it goes: just above a bar, as wide as it — or, with no room
    /// above (a tile at the top of its column), hanging just below it, over
    /// the tile's top.
    private(set) var below = false
    func frame(over bar: NSRect, within bounds: NSRect) -> NSRect {
        let h = CGFloat(rows) * (Self.tabHeight - 2) + 4
        below = bar.maxY + 1 + h > bounds.maxY
        return NSRect(x: bar.minX, y: below ? bar.minY - 1 - h : bar.maxY + 1, width: bar.width, height: h)
    }

    /// Each row's tab: nearest at the bar, the rest away from it, each
    /// stepped in.
    private func tabRect(_ i: Int) -> NSRect {
        let inset = 6 + CGFloat(i) * 9
        let offset = 2 + CGFloat(i) * (Self.tabHeight - 2)
        let y = below ? bounds.height - Self.tabHeight - offset : offset
        return NSRect(x: inset, y: y, width: bounds.width - 2 * inset, height: Self.tabHeight)
    }

    /// The tab at a point: the nearest one wins where they overlap.
    private func tab(at p: NSPoint) -> Int? { (0..<rows).first { tabRect($0).contains(p) } }

    /// Not in the gap above the bar, where a press resizes, whatever's
    /// over it.
    override func hitTest(_ point: NSPoint) -> NSView? {
        guard let superview else { return nil }
        let p = convert(point, from: superview)
        if !below, p.y < GridView.gap { return nil }
        return tab(at: p) != nil ? self : nil
    }

    func rise() {
        let end = frame
        setFrameOrigin(NSPoint(x: end.minX, y: end.minY + Motion.distance(below ? 6 : -6)))
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = Motion.base
            ctx.timingFunction = Motion.appear
            animator().alphaValue = 1
            animator().setFrameOrigin(end.origin)
        }
    }

    func fall() {
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = Motion.fast
            animator().alphaValue = 0
        }, completionHandler: { [weak self] in self?.removeFromSuperview() })
    }

    // MARK: Pointer

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .mouseMoved, .activeInKeyWindow, .inVisibleRect], owner: self))
    }

    override func mouseEntered(with event: NSEvent) {
        hovered = true
        hoveredTab = tab(at: convert(event.locationInWindow, from: nil))
        onHover?(true)
    }

    override func mouseMoved(with event: NSEvent) { hoveredTab = tab(at: convert(event.locationInWindow, from: nil)) }

    override func mouseExited(with event: NSEvent) {
        hovered = false
        hoveredTab = nil
        onHover?(false)
    }

    override func resetCursorRects() {
        for i in 0..<rows { addCursorRect(tabRect(i), cursor: .pointingHand) }
    }

    override func mouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        downAt = tab(at: p).map { ($0, p) }
    }

    override func mouseDragged(with event: NSEvent) {
        guard let down = downAt, down.tab < min(tiles.count, Self.shown) else { return }
        let p = convert(event.locationInWindow, from: nil)
        guard hypot(p.x - down.point.x, p.y - down.point.y) > 3 else { return }
        downAt = nil
        onDragOut?(tiles[down.tab].id, event)
    }

    override func mouseUp(with event: NSEvent) {
        guard let down = downAt else { return }
        downAt = nil
        if down.tab < min(tiles.count, Self.shown) { onPick?(tiles[down.tab].id, event.modifierFlags) } else { onMore?() }
    }

    override func draw(_ dirtyRect: NSRect) {
        var labels = tiles.prefix(Self.shown).map { (title: $0.title, symbol: $0.symbol) }
        if tiles.count > Self.shown { labels.append((title: "\(tiles.count - Self.shown) more", symbol: "ellipsis")) }
        // Farthest first, so the nearer tabs overlap the ones behind them.
        for (i, t) in labels.enumerated().reversed() {
            let r = tabRect(i)
            let path = NSBezierPath(roundedRect: r, xRadius: Radius.surface, yRadius: Radius.surface)
            NSGraphicsContext.saveGraphicsState()
            Elevation.resting.shadow.set()
            Theme.sheet(level: i + 1).setFill()
            path.fill()
            NSGraphicsContext.restoreGraphicsState()
            // The one under the pointer, lit as a hovered row is (twice: on
            // a sheet's grey, once doesn't show).
            if hoveredTab == i {
                Theme.hover.setFill()
                path.fill()
                path.fill()
            }
            (hoveredTab == i ? EdgeColor.controlHovered : EdgeColor.control).setStroke()
            path.lineWidth = 0.5
            path.stroke()
            var x = r.minX + 10
            // The symbol in the secondary text's color, as the bar's own is.
            // An agent's mark is an image of its own, drawn as it is.
            if let image = Theme.symbol(t.symbol, size: 10, weight: .medium, color: Theme.secondaryText) {
                let size = image.size
                image.draw(in: NSRect(x: x, y: r.midY - size.height / 2, width: size.width, height: size.height))
                x += size.width + 6
            }
            let label = NSAttributedString(string: t.title, attributes: [.font: UIType.caption, .foregroundColor: Theme.text])
            let room = r.maxX - 10 - x
            let size = label.size()
            label.draw(with: NSRect(x: x, y: r.midY - size.height / 2, width: max(0, room), height: size.height), options: [.truncatesLastVisibleLine, .usesLineFragmentOrigin])
        }
    }

    /// Debugging: tab `i` clicked, as the pointer would.
    func debugPick(_ i: Int) -> String {
        guard i < min(tiles.count, Self.shown) else { onMore?(); return "more" }
        onPick?(tiles[i].id, [])
        return "picked \(tiles[i].title)"
    }
}

/// A count in a lozenge (a stack's, on its bar's fan button): the figures
/// centred in it both ways, by their own height, not the line's.
final class CountBadge: NSView {
    var stringValue = "" { didSet { if stringValue != oldValue { needsDisplay = true } } }
    private static let font = NSFont.monospacedDigitSystemFont(ofSize: 8, weight: .bold)

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.cornerRadius = 5
        layer?.borderWidth = 0.5
        themed {
            $0.layer?.backgroundColor = Theme.sheet(level: 2).cgColor
            $0.layer?.borderColor = EdgeColor.control.cgColor
            $0.needsDisplay = true
        }
    }

    required init?(coder: NSCoder) { fatalError() }

    override func draw(_ dirtyRect: NSRect) {
        let text = NSAttributedString(string: stringValue, attributes: [.font: Self.font, .foregroundColor: Theme.text])
        // The figures' own box (cap height, baseline up), set in the middle.
        let baseline = (bounds.height - Self.font.capHeight) / 2
        text.draw(at: NSPoint(x: (bounds.width - text.size().width) / 2, y: baseline + Self.font.descender))
    }
}
