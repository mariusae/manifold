import AppKit
import ManifoldCore

protocol GridDelegate: AnyObject {
    func gridFocus(_ placement: PlacementID)
    /// A stack about to fan out: its tile grown to hold the fan, if it's
    /// short of it. True when it was (the fan waits for the tile to settle).
    func gridRoomForFan(_ top: PlacementID) -> Bool
    /// A tile dropped at a place in the grid: into column `column` at
    /// index `at`, or a new column at `column`.
    func gridMove(_ placement: PlacementID, column: Int, at: Int, newColumn: Bool, alone: Bool)
    /// A block from the sidebar dropped at a place in the grid: brought there.
    func gridBring(_ block: BlockID, column: Int, at: Int, newColumn: Bool)
    /// Files dropped from outside: opened where they landed.
    func gridOpenFiles(_ paths: [String], column: Int, at: Int, newColumn: Bool)
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
    /// ⌥-clicked: it takes the top of its stack, the tile that showed
    /// going behind it.
    func gridSwap(_ placement: PlacementID)
    /// ⌥-click on a shown tile's pill: the first tile behind it takes its place.
    func gridSwapNext(_ placement: PlacementID)
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
    func gridOpenLink(_ block: BlockID, from placement: PlacementID, over: Bool)
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
    struct Tile {
        var shown: Shown
        var view: PaneContent
        /// The block's links by hand (§3.5), for the badge at its upper right.
        var links: [LinkCard] = []
    }
    private var badges: [PlacementID: LinkBadge] = [:]

    weak var delegate: GridDelegate?
    private(set) var columns: [[Tile]] = []
    private var fractions: [Double] = []
    private var heights: [PlacementID: Double] = [:]
    private var focused: PlacementID?
    private var full: PlacementID?
    private var pills: [PlacementID: TilePill] = [:]
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
    static let corner: CGFloat = 10

    var views: [PaneContent] { columns.flatMap { $0.map(\.view) } }

    /// A card's body: the content view rounded at the bottom, as every
    /// place that shows a tile (the grid, the overview) has it.
    static func styleBody(_ view: NSView) {
        view.wantsLayer = true
        view.layer?.cornerRadius = corner
        view.layer?.cornerCurve = .continuous
        view.layer?.maskedCorners = [.layerMinXMinYCorner, .layerMaxXMinYCorner]
        view.layer?.masksToBounds = true
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = .clear
        dropOverlay.isHidden = true
        registerForDraggedTypes([.manifoldArrangement, .manifoldPlacement, .manifoldBlock, .manifoldBlockLink, .fileURL])
    }

    required init?(coder: NSCoder) { fatalError() }

    /// Files from the Finder (or anywhere) being dragged: their paths.
    private static func droppedFiles(_ pb: NSPasteboard) -> [String] {
        guard pb.string(forType: .manifoldPlacement) == nil, pb.string(forType: .manifoldBlock) == nil, pb.string(forType: .manifoldArrangement) == nil,
              let urls = pb.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] else { return [] }
        return urls.map(\.path)
    }
    private var dropFiles = false

    func show(_ columns: [[Tile]], fractions: [Double], heights: [PlacementID: Double], focused: PlacementID?, full: PlacementID? = nil) {
        let incoming = Set(columns.flatMap { $0.map(\.shown.id) })
        for v in views where !incoming.contains(v.placement) && v.superview === self { v.removeFromSuperview() }
        for (id, p) in pills where !incoming.contains(id) {
            p.removeFromSuperview()
            pills.removeValue(forKey: id)
        }
        for (id, b) in badges where !incoming.contains(id) {
            b.removeFromSuperview()
            badges.removeValue(forKey: id)
        }
        self.columns = columns
        self.fractions = fractions.count == columns.count ? fractions : Array(repeating: 1 / Double(max(columns.count, 1)), count: columns.count)
        self.heights = heights
        self.focused = focused
        self.full = full
        for column in columns {
            for tile in column {
                if tile.view.superview !== self, !switching.contains(tile.shown.id) {
                    Self.styleBody(tile.view)
                    addSubview(tile.view)
                }
                let pill = pills[tile.shown.id] ?? {
                    let p = TilePill()
                    pills[tile.shown.id] = p
                    addSubview(p)
                    return p
                }()
                let id = tile.shown.id
                let stashed = isStashed(id)
                pill.show(tile.shown, focused: tile.shown.id == focused, maximized: tile.shown.id == full, stashed: stashed)
                pill.editsPlace = tile.view.pillEdit != nil
                pill.onToggleFull = { [weak self] in self?.delegate?.gridToggleFull(id) }
                pill.onClose = { [weak self] in self?.delegate?.gridClose(id) }
                // The bar clicked grows the tile, ⌘-clicked fills the
                // column (a stashed one comes back); the symbol clicked is
                // the tile's menu; the corner maximizes.
                pill.onClick = { [weak self, weak pill] at, mods in
                    guard let self else { return }
                    if stashed {
                        self.fanned = nil
                        if mods.contains(.option) {
                            self.delegate?.gridSwap(id)
                        } else {
                            self.delegate?.gridUnstash(id)
                        }
                        return
                    }
                    // ⌥-click on a shown tile's pill: the next in its stack takes its place.
                    if mods.contains(.option) {
                        self.delegate?.gridSwapNext(id)
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
                    // focused; ⌘-clicked, the tile fills its column. The
                    // pointer follows the bar to where it was clicked, once
                    // the tile has grown and moved it, so a click again
                    // grows again.
                    self.pendingWarp = (id, at, self.barTargets[id] ?? pill?.frame ?? .zero, Date())
                    self.delegate?.gridFocus(id)
                    if mods.contains(.command) { self.delegate?.gridFill(id) } else { self.delegate?.gridGrow(id) }
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
                        self.fanned = nil
                        if mods.contains(.option) {
                            self.delegate?.gridSwap(id)
                        } else {
                            self.delegate?.gridUnstash(id)
                        }
                        return
                    }
                    self.delegate?.gridFocus(id)
                    self.showPillMenu(id)
                }
                // Right-clicked, the title calls up the stack behind the
                // tile; with none, the tile's menu.
                pill.onRightClick = { [weak self] _ in
                    guard let self, !stashed else { return }
                    self.delegate?.gridFocus(id)
                    if self.full != nil || !self.openStackSwitcher(id, followingPointer: true) { self.showPillMenu(id) }
                }
                // A fanned pill drags its tile out alone; the top's takes
                // the stack along, unless ⌘ is held.
                pill.onDragStart = { [weak self, weak pill] event in
                    guard let self, let pill else { return }
                    self.beginDrag(of: id, event: event, from: pill)
                }
                // The block's links, as a badge at the upper right.
                if tile.links.isEmpty {
                    badges[id]?.removeFromSuperview()
                    badges.removeValue(forKey: id)
                    pill.linkWanted = 0
                } else {
                    let badge = badges[id] ?? {
                        let b = LinkBadge()
                        b.layer?.zPosition = 6
                        badges[id] = b
                        return b
                    }()
                    badge.cards = tile.links
                    pill.linkWanted = badge.capsuleWantedWidth
                    badge.onOpen = { [weak self] block, over in self?.delegate?.gridOpenLink(block, from: id, over: over) }
                    badge.onBreak = { [weak self] link in self?.delegate?.gridBreakLink(link) }
                    badge.onMap = { [weak self] in self?.delegate?.gridShowMap(for: id) }
                    if badge.superview !== self { addSubview(badge, positioned: .above, relativeTo: pill) }
                }
                // Not a view the switcher holds: it shows in its card.
                if !switching.contains(id) { tile.view.isHidden = stashed }
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
        }
        addSubview(dropOverlay)
        if dragging { addSubview(dragCatcher) }
        needsLayout = true
    }

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

    /// Debugging: the tile's title right-clicked; what came up.
    func debugRightClick(_ placement: PlacementID) -> String {
        guard let pill = pills[placement] else { return "no pill" }
        guard full == nil, stacks(columns.indices.first { columns[$0].contains { $0.shown.id == placement } } ?? 0)
            .contains(where: { $0.top.shown.id == placement && !$0.behind.isEmpty }) else { return "no stack: the menu" }
        pill.onRightClick?(NSEvent())
        layoutSubtreeIfNeeded()
        return switcher.map { "switcher over \(NSStringFromRect($0.frame)), bar hidden \(pill.isHidden)" } ?? "nothing"
    }

    /// Debugging: the open switcher's pointer resting on card `i`.
    func debugSwitcherHover(_ i: Int) -> String { switcher?.debugHover(i) ?? "no switcher" }

    func debugBadge(_ placement: PlacementID, _ arg: String) -> String {
        guard let b = badges[placement] else { return "no badge" }
        b.debugFan(false)
        b.layoutSubtreeIfNeeded()
        let folded = b.debugSheets
        if arg == "fold" { return "folded, sheets \(folded)" + (b.debugCapsuleCenter.map { " at \(Int($0.x)) \(Int($0.y))" } ?? "") }
        b.debugFan(true)
        b.layoutSubtreeIfNeeded()
        let words = arg.split(separator: " ")
        if words.first == "break", let n = words.dropFirst().first.flatMap({ Int($0) }) {
            return b.debugBreak(n) ? "broke \(n)" : "no such link"
        }
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
        super.layout()
        if let full, let tile = columns.flatMap({ $0 }).first(where: { $0.shown.id == full }) {
            // One tile over everything; the rest wait behind it.
            for t in columns.flatMap({ $0 }) where t.shown.id != full {
                t.view.isHidden = true
                pills[t.shown.id]?.isHidden = true
                badges[t.shown.id]?.isHidden = true
            }
            for d in columnDividers + rowDividers { d.isHidden = true }
            tile.view.isHidden = false
            let r = bounds.insetBy(dx: Self.inset, dy: Self.inset)
            tile.view.frame = NSRect(x: r.minX, y: r.minY, width: r.width, height: r.height - Self.barHeight)
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
        for t in columns.flatMap({ $0 }) where !switching.contains(t.shown.id) {
            let stashed = isStashed(t.shown.id)
            t.view.isHidden = stashed
            // A stashed tile's pill stays as it is — hidden behind the
            // top's, or out in the fan: shown here, it would be drawn over
            // the top pill for a frame, until the gather hid it again.
            if !stashed { pills[t.shown.id]?.isHidden = false }
            pills[t.shown.id]?.behind = 0
            badges[t.shown.id]?.isHidden = stashed
        }
        for d in columnDividers + rowDividers { d.isHidden = false }
        let frames = columnFrames()
        var rowIndex = 0
        // Tiles glide to new places when the grid itself didn't change
        // size (a tile placed, closed, grown or stashed); a resize or a
        // divider dragged lays out at once.
        let gliding = bounds == lastLayoutBounds && !dragging && !dividerDragging && !isSwitching
        lastLayoutBounds = bounds
        var frameNow: [PlacementID: NSRect] = [:]
        func settle(_ view: NSView, _ frame: NSRect, was: NSRect?) {
            if gliding, let was, was != .zero, was != frame, !view.isHidden {
                NSAnimationContext.runAnimationGroup { ctx in
                    ctx.duration = 0.18
                    ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
                    view.animator().frame = frame
                }
            } else {
                view.frame = frame
            }
        }
        for (c, f) in frames.enumerated() {
            let tiles = tileFrames(column: c, in: f)
            var shownIndex = 0
            var top: NSRect?
            for (i, tile) in columns[c].enumerated() {
                guard !isStashed(tile.shown.id) else { continue }
                let r = tiles[i]
                let body = NSRect(x: r.minX, y: r.minY, width: r.width, height: max(0, r.height - Self.barHeight))
                let held = switching.contains(tile.shown.id)
                let was = lastFrames[tile.shown.id]
                // Less than a line of content under the bar: the tile is
                // collapsed to its bar, a pill, its content out of sight.
                let collapsed = body.height < 20
                frameNow[tile.shown.id] = collapsed ? NSRect(x: r.minX, y: r.maxY - Self.barHeight, width: r.width, height: 0) : body
                if !held {
                    settle(tile.view, body, was: was)
                    if tile.view.isHidden != collapsed { tile.view.isHidden = collapsed }
                }
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
            // Each stack: its sheets' edges above the top's card; its
            // tiles hang as cards over it when its title is right-clicked.
            _ = top
            for stack in stacks(c) {
                guard let topPill = pills[stack.top.shown.id] else { continue }
                topPill.behind = stack.behind.count
                topPill.toolTip = stack.behind.isEmpty ? nil
                    : "\(stack.behind.count) behind this tile — right-click its title to see \(stack.behind.count == 1 ? "it" : "them")"
                for tile in stack.behind { pills[tile.shown.id]?.isHidden = true }
            }
        }
        lastFrames = frameNow
        if dragging { dragCatcher.frame = bounds }
        // The focus ring: around the focused tile, over everything.
        if let focused, let t = columns.flatMap({ $0 }).first(where: { $0.shown.id == focused }), !isStashed(focused) {
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
            l.shadowColor = NSColor.black.cgColor
            l.shadowOpacity = 0.10
            l.shadowRadius = 10
            l.shadowOffset = CGSize(width: 0, height: -4)
            layer?.insertSublayer(l, at: 0)
            shadowLayers.append(l)
        }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for (l, body) in zip(shadowLayers, wanted) {
            let card = NSRect(x: body.minX, y: body.minY, width: body.width, height: body.height + Self.barHeight)
            let path = CGPath(roundedRect: card, cornerWidth: Self.corner, cornerHeight: Self.corner, transform: nil)
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

    // MARK: The pill out of the cursor's way

    private var caretTimer: Timer?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        caretTimer?.invalidate()
        caretTimer = nil
        guard window != nil else { return }
        let t = Timer(timeInterval: 0.2, repeats: true) { [weak self] _ in self?.dodgeCarets() }
        RunLoop.main.add(t, forMode: .common)
        caretTimer = t
    }

    /// A pill over the line the text cursor is on fades out, so what is
    /// typed there can be seen; it comes back when the cursor moves on.
    private func dodgeCarets() {
        // The bar sits above the content now, never over the text cursor.
        for p in pills.values where p.dodging { p.dodging = false }
        return
        guard window != nil else { return }
        for column in columns {
            for tile in column {
                // Maximized, only that tile's pill is there to dodge.
                if let full, tile.shown.id != full { continue }
                guard let pill = pills[tile.shown.id] else { continue }
                // A stashed tile's pill never dodges (its cursor is out of
                // sight): one that was dodging when stashed comes back,
                // or it would be lost — unseen in the fan, taking no clicks.
                if isStashed(tile.shown.id) { pill.dodging = false; continue }
                // Only the focused tile's pill dodges: nothing is being
                // typed under the others, and their names are what you
                // find them by.
                if tile.shown.id != focused || pill.isEditing { pill.dodging = false; continue }
                guard !pill.isHidden else { continue }
                var away = false
                if let caret = tile.view.caretRectInWindow {
                    let capsule = pill.convert(pill.capsule(in: pill), to: nil)
                    away = caret.minY < capsule.maxY && caret.maxY > capsule.minY
                    // Unless the pointer is where the pill would be: then it shows.
                    if away, let window, capsule.insetBy(dx: -8, dy: -6).contains(window.mouseLocationOutsideOfEventStream) { away = false }
                }
                pill.dodging = away
            }
        }
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

    private func beginDrag(of placement: PlacementID, event: NSEvent, from view: NSView) {
        let item = NSPasteboardItem()
        let shown = columns.flatMap { $0 }.first { $0.shown.id == placement }?.shown
        coverDrag = event.modifierFlags.contains(.option)
        aloneDrag = event.modifierFlags.contains(.command)
        if event.modifierFlags.contains(.shift) {
            // ⇧-drag: not the tile but what it stands for — its path (a
            // terminal's folder, a page's address) — for wherever text or
            // files are taken: a terminal types it, an editor inserts it.
            guard let block = shown?.block, let text = block.path ?? block.web?.url ?? block.terminal?.cwd ?? block.place else { return }
            item.setString(text, forType: .string)
            // A file's URL too — not a folder's: a web view in the drag's
            // way takes a dragged folder for a file list and reads it.
            var isDir: ObjCBool = false
            if text.hasPrefix("/"), FileManager.default.fileExists(atPath: text, isDirectory: &isDir), !isDir.boolValue {
                item.setString(URL(fileURLWithPath: text).absoluteString, forType: .fileURL)
            }
            // And the block as a link a note takes: [title](manifold:id).
            // Not as a block: the grid takes no ⇧-drag, the views under it do.
            let title = block.displayTitle.replacingOccurrences(of: "]", with: "\\]")
            item.setString("[\(title)](manifold:\(block.id.description))", forType: .manifoldBlockLink)
            pathDrag = true
        } else {
            item.setString(placement, forType: .manifoldPlacement)
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
        let w = min(size.width, max(r.width - 40, 60))
        let h = min(size.height, r.height - 12)
        // Its capsule in the bar, before the bar's buttons, as wide as the
        // bar gave it (shrunk to its arrow when the bar is narrow).
        let capsuleTop = r.maxY - (Self.barHeight - LinkBadge.capsuleHeight) / 2
        let taken = pills[id]?.rightTaken ?? TilePill.rightChrome
        let given = pills[id]?.linkGiven ?? .infinity
        badge.capsuleLimit = given
        badge.isHidden = given == 0
        badge.frame = NSRect(x: r.maxX - taken - 8 - w, y: capsuleTop - h, width: w, height: h)
    }

    /// Whether the drag under way is a ⇧-drag of a block's path.
    private var pathDrag = false

    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        if pathDrag { return .copy }
        // ⌥ copies to another workspace (as a file is copied).
        return context == .withinApplication ? [.move, .copy] : []
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
        if !Self.droppedFiles(pb).isEmpty, let target = dropTarget(at: point, dragged: nil) {
            // Files from outside: opened where they land, as a block is brought.
            showDrop(target.rect)
            drop = target
            dropFiles = true
            dropLinks = false
            return .copy
        }
        dropFiles = false
        if pb.string(forType: .manifoldPlacement) == nil, pb.string(forType: .manifoldBlock) == nil,
           let link = pb.string(forType: .manifoldBlockLink), let block = TextView.blockID(inLink: link) {
            // ⇧-drag: a block's link, over a tile whose view didn't take it
            // (one that types or inserts it takes it first): linked to the
            // tile's block, its whole shape the sign.
            guard let t = tile(at: point), t.shown.block?.id != block else { hideDrop(); return [] }
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
                ctx.duration = dropOverlay.isHidden ? 0 : 0.12
                dropOverlay.animator().frame = rect
            }
            dropOverlay.isHidden = false
        }
    }

    // MARK: ⌘E

    private var switcher: StackSwitcherView?
    /// The tiles whose views the switcher holds: the grid leaves them be.
    private var switching: Set<PlacementID> = []
    var isSwitching: Bool { switcher != nil || fanWaiting }
    /// The fan asked for, waiting on its tile to grow; and ⌘E's steps meanwhile.
    private var fanWaiting = false
    private var fanSteps = 0

    /// The switcher was opened by a right-click: it follows the pointer,
    /// and what's clicked comes out (⌥: takes the top).
    private var switcherByPointer = false
    private var switcherMonitor: Any?

    /// The stack under `top` as cards hanging over its tile, if it has one:
    /// from ⌘E, the choice then stepped along; from a right-click on its
    /// title, the choice following the pointer, from the top.
    @discardableResult
    func openStackSwitcher(_ top: PlacementID, followingPointer: Bool, roomMade: Bool = false) -> Bool {
        guard switcher == nil, !fanWaiting else { return true }
        guard let c = columns.indices.first(where: { columns[$0].contains { $0.shown.id == top } }),
              let stack = stacks(c).first(where: { $0.top.shown.id == top }), !stack.behind.isEmpty else { return false }
        // A stack too short to fan out (down to its bar, say) grows first,
        // and fans out once it has.
        if !roomMade, delegate?.gridRoomForFan(top) == true {
            fanWaiting = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.24) { [weak self] in
                guard let self else { return }
                self.fanWaiting = false
                let steps = self.fanSteps
                self.fanSteps = 0
                guard self.openStackSwitcher(top, followingPointer: followingPointer, roomMade: true) else { return }
                if steps != 0 { self.switcher?.move(steps) }
            }
            return true
        }
        layoutSubtreeIfNeeded()
        let body = stack.top.view.frame
        let order = Array(stack.behind.reversed()) + [stack.top]
        let s = StackSwitcherView(entries: order.map { .init(id: $0.shown.id, title: $0.shown.title, symbol: $0.shown.symbol, view: $0.view) },
                                  contentSize: body.size, selection: order.count - 1)
        // Over the tile's bar too: the cards hang where it was.
        s.frame = NSRect(x: body.minX, y: body.minY, width: body.width, height: body.height + Self.barHeight)
        s.layer?.zPosition = 20
        s.followsPointer = followingPointer
        s.onPick = { [weak self] id, mods in
            guard let self else { return }
            if self.switcherByPointer && !mods.contains(.option) { self.settleStackSwitcher(bringingOut: id) } else { self.settleStackSwitcher(to: id) }
        }
        s.onCancel = { [weak self] in self?.settleStackSwitcher(cancel: true) }
        switching = Set(order.map(\.shown.id))
        switcherByPointer = followingPointer
        addSubview(s)
        switcher = s
        needsLayout = true
        s.present()
        if followingPointer {
            // Escape, or a click away from the cards, lets the stack be.
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
        return true
    }

    /// ⌘E: the stack under `top` as cards over its tile, opened if it
    /// isn't, and the choice moved a step down (back: up). False when the
    /// tile has no stack.
    func stepStackSwitcher(_ top: PlacementID, back: Bool) -> Bool {
        guard openStackSwitcher(top, followingPointer: false) else { return false }
        if fanWaiting { fanSteps += back ? 1 : -1 } else { switcher?.move(back ? 1 : -1) }
        return true
    }

    /// The switcher closes on `id` (nil: the card chosen; `cancel`: the
    /// top as it was), which comes forward to fill the tile; the views go
    /// back to the grid, and the stack is told which is its top now. With
    /// `bringingOut`, the top stays and that tile comes out of the stack
    /// on its own, as clicking it in the stack does.
    func settleStackSwitcher(to id: PlacementID? = nil, cancel: Bool = false, bringingOut: PlacementID? = nil) {
        guard let s = switcher, !s.isClosing else { return }
        if let switcherMonitor { NSEvent.removeMonitor(switcherMonitor) }
        switcherMonitor = nil
        let top = s.topID
        let chosen = cancel || bringingOut != nil ? top : (id ?? s.selectedID)
        s.dismiss(to: chosen) { [weak self, weak s] in
            guard let self, let s else { return }
            s.tearDown(keeping: chosen, in: self)
            s.removeFromSuperview()
            if self.switcher === s { self.switcher = nil }
            // The views back in the grid, as they'll be once the stack has
            // its new top: the chosen one showing, the rest behind it.
            for id in self.switching {
                guard let t = self.tile(id) else { continue }
                if t.view.superview !== self { self.addSubview(t.view) }
                t.view.isHidden = id != chosen
            }
            self.switching = []
            self.switcherByPointer = false
            self.needsLayout = true
            if let out = bringingOut, out != top { self.delegate?.gridUnstash(out) }
            else if chosen != top { self.delegate?.gridSwap(chosen) }
        }
    }

    private func tile(_ id: PlacementID) -> Tile? { columns.flatMap { $0 }.first { $0.shown.id == id } }

    /// The shown tile under a point.
    private func tile(at point: NSPoint) -> Tile? {
        for c in columns.indices {
            for t in columns[c] where !isStashed(t.shown.id) && !t.view.isHidden && t.view.frame.contains(point) { return t }
        }
        return nil
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        defer { hideDrop() }
        guard let target = drop else { return false }
        let pb = sender.draggingPasteboard
        if dropFiles {
            dropFiles = false
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

    private func layoutSheets() {
        var wanted: [(NSRect, Int)] = []
        for (id, pill) in pills where !pill.isHidden && pill.behind > 0 && fanned != id {
            let bar = pill.frame
            for level in stride(from: min(pill.behind, 3), through: 1, by: -1) {
                let inset = CGFloat(level) * 6
                let rise = CGFloat(level) * 3
                wanted.append((NSRect(x: bar.minX + inset, y: bar.maxY - Self.corner, width: bar.width - 2 * inset, height: Self.corner + rise), level))
            }
        }
        while sheetLayers.count > wanted.count { sheetLayers.removeLast().removeFromSuperlayer() }
        while sheetLayers.count < wanted.count {
            let l = CAShapeLayer()
            l.lineWidth = 0.5
            layer?.insertSublayer(l, at: 0)
            sheetLayers.append(l)
        }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        effectiveAppearance.performAsCurrentDrawingAppearance {
            for (l, (rect, level)) in zip(sheetLayers, wanted) {
                // Under the cards, and the nearer sheet (the wider) over the
                // farther, whichever layer each got.
                l.zPosition = -CGFloat(level)
                l.path = CGPath(roundedRect: rect, cornerWidth: Self.corner, cornerHeight: Self.corner, transform: nil)
                l.fillColor = Theme.sheet(level: level).cgColor
                l.strokeColor = Theme.text.withAlphaComponent(0.18).cgColor
            }
        }
        CATransaction.commit()
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
            toolTip = host.map { "On \($0), not this workspace's host" }
            needsLayout = true
        }
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.cornerRadius = 9
        layer?.cornerCurve = .continuous
        layer?.borderWidth = 0.5
        themed {
            $0.layer?.backgroundColor = Theme.accent.withAlphaComponent(0.12).cgColor
            $0.layer?.borderColor = Theme.accent.withAlphaComponent(0.35).cgColor
        }
        icon.image = Theme.symbol("server.rack", size: 9, weight: .semibold)
        icon.contentTintColor = Theme.accent
        label.font = .systemFont(ofSize: 11, weight: .semibold)
        label.textColor = Theme.accent
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
    var isEditing: Bool { edit != nil }
    var onToggleFull: (() -> Void)?
    var onClose: (() -> Void)?
    /// Right-clicked: the stack behind the tile, called up (or its menu).
    var onRightClick: ((NSEvent) -> Void)?
    /// What the links' pill takes of the bar, left of the buttons.
    /// What the links' pill wants of the bar, its sheets included; what
    /// it's given is `linkGiven`, after the shrinkage below.
    var linkWanted: CGFloat = 0 { didSet { if linkWanted != oldValue { needsLayout = true } } }
    private(set) var linkGiven: CGFloat = 0
    /// The links' pill shrunk: the arrow and the symbol; the arrow alone.
    static let linkCompact: CGFloat = 50
    static let linkMinimal: CGFloat = 30
    /// The least the name is shown at, before anything else gives way.
    static let nameMinimum: CGFloat = 56
    /// The tile shrunk to its bar alone: the bar rounded all round, a pill.
    var collapsed = false {
        didSet {
            guard collapsed != oldValue else { return }
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
    private let count = NSTextField(labelWithString: "")
    private let close = IconButton(symbol: "xmark", size: 9, weight: .semibold, target: nil, action: nil)

    static let height: CGFloat = GridView.barHeight
    /// What the bar's right end takes: close, maximize, and room.
    static let rightChrome: CGFloat = 54
    /// What the bar's right end takes now, its status, tag and dot included.
    var rightTaken: CGFloat {
        var w: CGFloat = 10
        if !close.isHidden { w += 22 }
        if !corner.isHidden { w += 22 }
        if !glyph.isHidden { w += StatusGlyph.size + 8 }
        return w
    }

    /// The bar's frame in `view`'s coordinates (what a drop on it stashes behind).
    func capsule(in view: NSView) -> NSRect { convert(bounds, to: view) }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        glass.wantsLayer = true
        glass.layer?.cornerRadius = GridView.corner
        glass.layer?.cornerCurve = .continuous
        glass.layer?.maskedCorners = [.layerMinXMaxYCorner, .layerMaxXMaxYCorner]
        glass.layer?.borderWidth = 0
        glass.themed { $0.layer?.backgroundColor = Theme.panel.cgColor }
        addSubview(glass)
        icon.contentTintColor = Theme.secondaryText
        name.font = .systemFont(ofSize: 12.5, weight: .semibold)
        name.textColor = Theme.text
        name.lineBreakMode = .byTruncatingTail
        name.alignment = .left
        subtitle.font = .systemFont(ofSize: 11.5)
        subtitle.textColor = Theme.secondaryText
        subtitle.lineBreakMode = .byTruncatingMiddle
        count.font = .monospacedDigitSystemFont(ofSize: 10.5, weight: .medium)
        count.textColor = Theme.secondaryText
        count.alignment = .center
        count.wantsLayer = true
        count.layer?.cornerRadius = 7
        count.themed { $0.layer?.backgroundColor = Theme.hover.cgColor }
        count.isHidden = true
        close.target = self
        close.action = #selector(closeClicked)
        close.toolTip = "Close (⌘W)"
        corner.target = self
        corner.action = #selector(cornerClicked)
        corner.toolTip = "Maximize"
        editor.isBordered = false
        editor.drawsBackground = false
        editor.focusRingType = .none
        editor.font = .systemFont(ofSize: 11.5)
        editor.cell?.usesSingleLineMode = true
        editor.cell?.lineBreakMode = .byTruncatingTail
        editor.delegate = self
        editor.isHidden = true
        for v in [icon, name, subtitle, count, glyph, corner, close, editor, hostPill] { addSubview(v) }
        hostPill.isHidden = true
        themed { $0.updateColors() }
    }

    @objc private func closeClicked() { onClose?() }

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
        if window?.firstResponder === editor.currentEditor() { window?.makeFirstResponder(nil) }
        editor.isHidden = true
        name.isHidden = false
        needsLayout = true
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        switch selector {
        case #selector(insertNewline(_:)):
            let text = editor.stringValue.trimmingCharacters(in: .whitespaces)
            let commit = edit?.commit
            // A name may be emptied (a note Untitled again); an address not.
            let emptied = edit?.overName == true
            endEditing()
            if !text.isEmpty || emptied { commit?(text) }
            return true
        case #selector(cancelOperation(_:)):
            endEditing()
            return true
        default:
            return false
        }
    }

    func controlTextDidEndEditing(_ obj: Notification) {
        // The keyboard went elsewhere: the pill is itself again.
        DispatchQueue.main.async { [weak self] in self?.endEditing() }
    }

    @objc private func cornerClicked() { onToggleFull?() }

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
        if symbolName != shown.symbol {
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
        // Where it is, after the name, in grey: a folder, an address.
        let place = (shown.block?.web?.url ?? shown.block?.place?.abbreviatingHome) ?? ""
        // Not when the name already says it (a terminal named for its
        // folder) — but a page's address always, being what's clicked to
        // type another.
        let tail = String(shown.title.drop(while: { $0 == "…" }))
        let said = place == shown.title || place == shown.path?.abbreviatingHome || (!tail.isEmpty && place.hasSuffix(tail))
        let where_ = said && shown.block?.web == nil ? "" : place
        if subtitle.stringValue != where_ { subtitle.stringValue = where_ }
        // From another host than the workspace's: the host in its pill.
        if hostPill.host != shown.foreignHost { hostPill.host = shown.foreignHost; needsLayout = true }
        if close.isHidden != stashed { close.isHidden = stashed }
        let look: StatusGlyph.Look? = shown.offline ? .offline : StatusGlyph.look(of: shown.block)
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
            glass.layer?.borderColor = (hovered ? Theme.accent.withAlphaComponent(0.9) : Theme.cardBorder).cgColor
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
        var linkRoom: CGFloat = linkWanted > 0 ? linkWanted + 14 : 0
        let nameWanted = ceil(name.intrinsicContentSize.width) + 4
        let nameNeed = min(nameWanted, Self.nameMinimum)
        var showHost = hostPill.host != nil
        let hostWidth = hostPill.wantedWidth
        func spare() -> CGFloat {
            var used = x + 10 + linkRoom + (showHost ? hostWidth + 8 : 0)
            if showClose { used += 22 }
            if showCorner { used += 22 }
            if !glyph.isHidden { used += StatusGlyph.size + 8 }
            return bounds.width - used
        }
        if spare() < nameNeed, linkWanted > 0 { linkRoom = min(linkRoom, Self.linkCompact + 14) }
        if spare() < nameNeed, linkWanted > 0 { linkRoom = min(linkRoom, Self.linkMinimal + 14) }
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
        count.isHidden = true
        let sh = ceil(subtitle.intrinsicContentSize.height)
        subtitle.frame = NSRect(x: sx, y: ((h - sh) / 2).rounded() - 0.5, width: max(0, right - sx), height: sh)
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
    override func resetCursorRects() {
        var spots: [(NSRect, NSCursor)] = [(icon.frame.insetBy(dx: -8, dy: -6), .pointingHand)]
        for b in [corner, close] where !b.isHidden { spots.append((b.frame, .pointingHand)) }
        if let r = placeRect { spots.append((r, .iBeam)) }
        spots.sort { $0.0.minX < $1.0.minX }
        var x: CGFloat = 0
        for (r, cursor) in spots {
            if r.minX > x { addCursorRect(NSRect(x: x, y: 0, width: r.minX - x, height: bounds.height), cursor: .openHand) }
            addCursorRect(r.intersection(bounds), cursor: cursor)
            x = max(x, r.maxX)
        }
        if x < bounds.width { addCursorRect(NSRect(x: x, y: 0, width: bounds.width - x, height: bounds.height), cursor: .openHand) }
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

/// The grab area over the line between two tiles in a column.
final class RowDividerView: NSView {
    var onDrag: ((CGFloat) -> Void)?
    var onEnd: (() -> Void)?

    override func resetCursorRects() { addCursorRect(bounds, cursor: .resizeUpDown) }
    override func mouseDown(with event: NSEvent) {}

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
        guard let main = NSScreen.screens.first else { return }
        CGWarpMouseCursorPosition(CGPoint(x: screen.x, y: main.frame.maxY - screen.y))
        CGAssociateMouseAndMouseCursorPosition(1)
    }
}

/// A ring around the focused tile (§3.1): drawn, taking no clicks.
final class FocusRingView: NSView {
    override init(frame: NSRect) {
        super.init(frame: frame)
        // Not layer-backed: drawn by AppKit whenever its frame changes, so
        // nothing stale is stretched over a resized tile.
    }

    required init?(coder: NSCoder) { fatalError() }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    // Drawn afresh at each size (the sidebar coming or going resizes
    // every tile), not stretched from the last.
    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 1), xRadius: GridView.corner, yRadius: GridView.corner)
        path.lineWidth = 2
        Theme.accent.withAlphaComponent(0.6).setStroke()
        path.stroke()
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
        Theme.accent.withAlphaComponent(0.5).setStroke()
        NSBezierPath(rect: bounds.insetBy(dx: 0.5, dy: 0.5)).stroke()
    }
}

final class DividerView: NSView {
    var onDrag: ((CGFloat) -> Void)?
    var onEnd: (() -> Void)?

    override func resetCursorRects() { addCursorRect(bounds, cursor: .resizeLeftRight) }

    override func mouseDown(with event: NSEvent) {}

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
            if let icon = Theme.symbol(pane?.symbol ?? "apple.terminal", size: 13) {
                let tinted = icon.copy() as! NSImage
                tinted.isTemplate = true
                NSGraphicsContext.current?.saveGraphicsState()
                tinted.draw(in: NSRect(x: 12, y: (rect.height - 16) / 2, width: 16, height: 16))
                NSGraphicsContext.current?.restoreGraphicsState()
            }
            let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: Theme.text]
            let text = NSAttributedString(string: title, attributes: attrs)
            text.draw(with: NSRect(x: 36, y: (rect.height - 17) / 2 + 3, width: rect.width - 46, height: 17),
                      options: [.truncatesLastVisibleLine, .usesLineFragmentOrigin])
            return true
        }
    }
}
