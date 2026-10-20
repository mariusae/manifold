import AppKit
import ManifoldCore

protocol GridDelegate: AnyObject {
    func gridFocus(_ placement: PlacementID)
    /// A tile dropped at a place in the grid: into column `column` at
    /// index `at`, or a new column at `column`.
    func gridMove(_ placement: PlacementID, column: Int, at: Int, newColumn: Bool, alone: Bool)
    /// A block from the sidebar dropped at a place in the grid: brought there.
    func gridBring(_ block: BlockID, column: Int, at: Int, newColumn: Bool)
    /// Another arrangement dropped: its columns come over at `column`.
    func gridDropArrangement(_ arrangement: BlockID, column: Int)
    func gridCanDrop(_ arrangement: BlockID) -> Bool
    func gridResized(fractions: [Double])
    func gridResized(heights: [PlacementID: Double])
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
    private var fanned: PlacementID? { didSet { if fanned != oldValue { needsLayout = true } } }

    /// The band at a tile's top that its pill floats in; the content runs
    /// underneath it.
    static let band: CGFloat = 32
    static let gap: CGFloat = 1

    var views: [PaneContent] { columns.flatMap { $0.map(\.view) } }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        themed { $0.layer?.backgroundColor = Theme.divider.cgColor }
        dropOverlay.isHidden = true
        registerForDraggedTypes([.manifoldArrangement, .manifoldPlacement, .manifoldBlock, .manifoldBlockLink])
    }

    required init?(coder: NSCoder) { fatalError() }

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
                if tile.view.superview !== self { addSubview(tile.view) }
                let pill = pills[tile.shown.id] ?? {
                    let p = TilePill()
                    pills[tile.shown.id] = p
                    addSubview(p)
                    return p
                }()
                let id = tile.shown.id
                let stashed = isStashed(id)
                pill.show(tile.shown, focused: tile.shown.id == focused, maximized: tile.shown.id == full, stashed: stashed)
                pill.onToggleFull = { [weak self] in self?.delegate?.gridToggleFull(id) }
                // The capsule clicked grows the tile, ⌘-clicked fills the
                // column (a stashed one comes back); the symbol clicked is
                // the tile's menu.
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
                    // A pill with something to edit (a page's address) becomes
                    // its field; the tile is focused, not grown.
                    if let pill, !pill.isEditing, let edit = tile.view.pillEdit, !mods.contains(.command) {
                        self.delegate?.gridFocus(id)
                        pill.beginEditing(edit)
                        return
                    }
                    // Where in the capsule the click was: the pointer follows
                    // the pill there once the tile has grown and moved it.
                    let offset = pill.map { p -> NSPoint in
                        let c = p.capsule(in: p)
                        return NSPoint(x: at.x - c.minX, y: at.y - c.minY)
                    }
                    self.delegate?.gridFocus(id)
                    if mods.contains(.command) {
                        self.delegate?.gridFill(id)
                    } else {
                        self.delegate?.gridGrow(id)
                    }
                    if let offset {
                        DispatchQueue.main.async { [weak self] in
                            guard let self, let pill = self.pills[id], let window = pill.window, !pill.isHidden else { return }
                            self.layoutSubtreeIfNeeded()
                            let c = pill.capsule(in: pill)
                            let p = pill.convert(NSPoint(x: c.minX + offset.x, y: c.minY + offset.y), to: nil)
                            Pointer.warp(to: window.convertPoint(toScreen: p))
                        }
                    }
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
                    if let menu = self.delegate?.gridPillMenu(for: id), let pill = self.pills[id] {
                        // Under the pointer, as a menu is.
                        let at = NSApp.currentEvent.map { pill.convert($0.locationInWindow, from: nil) } ?? NSPoint(x: pill.bounds.midX, y: 0)
                        menu.popUp(positioning: nil, at: NSPoint(x: at.x, y: at.y - 4), in: pill)
                    }
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
                } else {
                    let badge = badges[id] ?? {
                        let b = LinkBadge()
                        b.layer?.zPosition = 6
                        badges[id] = b
                        return b
                    }()
                    badge.cards = tile.links
                    badge.onOpen = { [weak self] block, over in self?.delegate?.gridOpenLink(block, from: id, over: over) }
                    badge.onBreak = { [weak self] link in self?.delegate?.gridBreakLink(link) }
                    if badge.superview !== self { addSubview(badge, positioned: .above, relativeTo: pill) }
                }
                tile.view.isHidden = stashed
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
            d.onDrag = { [weak self] x in self?.dragColumnDivider(i, to: x) }
            d.onEnd = { [weak self] in self?.delegate?.gridResized(fractions: self?.fractions ?? []) }
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
            d.onDrag = { [weak self] y in self?.dragRowDivider(column: c, above: above, below: below, to: y) }
            d.onEnd = { [weak self] in self?.delegate?.gridResized(heights: self?.heights ?? [:]) }
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
    func debugBadge(_ placement: PlacementID, _ arg: String) -> String {
        guard let b = badges[placement] else { return "no badge" }
        b.debugFan(true)
        b.layoutSubtreeIfNeeded()
        let words = arg.split(separator: " ")
        if words.first == "break", let n = words.dropFirst().first.flatMap({ Int($0) }) {
            return b.debugBreak(n) ? "broke \(n)" : "no such link"
        }
        return b.debugTitles.joined(separator: " | ")
    }

    var debugPills: String {
        columns.flatMap { $0 }.map { t in
            let p = pills[t.shown.id]
            let order = p.flatMap { subviews.firstIndex(of: $0) }.map(String.init) ?? "-"
            let viewOrder = subviews.firstIndex(of: t.view).map(String.init) ?? "-"
            let caret = t.view.caretRectInWindow.map { NSStringFromRect($0) } ?? "none"
            let capsule = p.map { NSStringFromRect($0.convert($0.capsule(in: $0), to: nil)) } ?? "-"
            return "\(t.shown.title): hidden=\(p?.isHidden ?? true) dodging=\(p?.dodging ?? false) alpha=\(p?.alphaValue ?? 0) z=\(order) view z=\(viewOrder) caret=\(caret) capsule=\(capsule)"
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
        let usable = bounds.width - CGFloat(n - 1) * Self.gap
        var x: CGFloat = 0
        return fractions.enumerated().map { i, f in
            let w = i == n - 1 ? bounds.width - x : (usable * f).rounded()
            defer { x += w + Self.gap }
            return NSRect(x: x, y: 0, width: w, height: bounds.height)
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
        var hs = shares.map { max(Self.band, (usable * CGFloat($0)).rounded()) }
        // Over by the minimums: taken from the tallest.
        var over = hs.reduce(0, +) - usable
        while over > 0, let i = hs.indices.max(by: { hs[$0] < hs[$1] }), hs[i] > Self.band {
            let take = min(over, hs[i] - Self.band)
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
            if let badge = badges[full] { placeBadge(badge, in: bounds) }
            for d in columnDividers + rowDividers { d.isHidden = true }
            tile.view.isHidden = false
            tile.view.frame = bounds
            focusRing.isHidden = true
            if let pill = pills[full] {
                pill.isHidden = false
                pill.behind = 0
                pill.frame = NSRect(x: 0, y: bounds.height - Self.band, width: bounds.width, height: Self.band)
                keep(pill, above: tile.view)
            }
            return
        }
        for t in columns.flatMap({ $0 }) {
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
        for (c, f) in frames.enumerated() {
            let tiles = tileFrames(column: c, in: f)
            var shownIndex = 0
            var top: NSRect?
            for (i, tile) in columns[c].enumerated() {
                guard !isStashed(tile.shown.id) else { continue }
                let r = tiles[i]
                tile.view.frame = r
                if top == nil { top = r }
                if let pill = pills[tile.shown.id] {
                    pill.frame = NSRect(x: r.minX, y: r.maxY - Self.band, width: r.width, height: Self.band)
                    keep(pill, above: tile.view)
                }
                if let badge = badges[tile.shown.id] { placeBadge(badge, in: r) }
                if shownIndex > 0, rowIndex < rowDividers.count {
                    rowDividers[rowIndex].frame = NSRect(x: r.minX, y: r.maxY - 2, width: r.width, height: Self.gap + 4)
                    rowIndex += 1
                }
                shownIndex += 1
            }
            // Each stack's pills: a few edges peeking out beside the pill of
            // the tile they're behind, or fanned out below it.
            _ = top
            for stack in stacks(c) where !stack.behind.isEmpty {
                guard let topPill = pills[stack.top.shown.id] else { continue }
                let band = topPill.frame
                let open = fanned == stack.top.shown.id
                // Fanned out, the stack is on show: no edges behind the top.
                topPill.behind = open ? 0 : stack.behind.count
                for (i, tile) in stack.behind.enumerated() {
                    guard let pill = pills[tile.shown.id] else { continue }
                    // Gathered, the top pill draws their edges; fanned, they
                    // come out from behind it, packed close, each a step
                    // down — and go back in the same way.
                    let target = band.offsetBy(dx: 0, dy: -CGFloat(i + 1) * (TilePill.height + 2))
                    keep(pill, above: topPill)
                    pill.alphaValue = 1
                    if open {
                        if pill.isHidden {
                            pill.frame = band
                            pill.isHidden = false
                            NSAnimationContext.runAnimationGroup { ctx in
                                ctx.duration = 0.16
                                ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
                                pill.animator().frame = target
                            }
                        } else if pill.frame != target, pill.layer?.animationKeys()?.isEmpty ?? true {
                            pill.frame = target
                        }
                    } else if !pill.isHidden {
                        let id = tile.shown.id
                        NSAnimationContext.runAnimationGroup({ ctx in
                            ctx.duration = 0.12
                            ctx.timingFunction = CAMediaTimingFunction(name: .easeIn)
                            pill.animator().frame = band
                        }, completionHandler: { [weak self, weak pill] in
                            guard let self, let pill, self.fanned != stack.top.shown.id, self.isStashed(id) else { return }
                            pill.isHidden = true
                        })
                    }
                }
            }
        }
        if dragging { dragCatcher.frame = bounds }
        // The focus ring: around the focused tile, over everything.
        if let focused, let t = columns.flatMap({ $0 }).first(where: { $0.shown.id == focused }), !isStashed(focused) {
            focusRing.isHidden = false
            if focusRing.frame != t.view.frame {
                focusRing.frame = t.view.frame
                focusRing.needsDisplay = true
            }
            if let p = pills[focused] { keep(focusRing, above: p) }
        } else {
            focusRing.isHidden = true
        }
        for (i, d) in columnDividers.enumerated() {
            d.frame = NSRect(x: frames[i].maxX - 3, y: 0, width: Self.gap + 6, height: bounds.height)
        }
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

    /// The line between two tiles dragged: the two share their room by
    /// where it is. Pushed past a tile's least height, that tile goes into
    /// the stack (its room to the other side), and the line goes on
    /// against the next, until all above or below are stashed and the
    /// tile that grew has the column, the others behind it.
    private func dragRowDivider(column c: Int, above a0: PlacementID, below b0: PlacementID, to y: CGFloat) {
        guard c < columns.count else { return }
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

    /// The pointer over a stack (the pill of the tile it's behind, or the
    /// fanned-out pills) fans it out; elsewhere gathers it in.
    override func mouseMoved(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        var over: PlacementID?
        search: for c in columns.indices {
            for stack in stacks(c) where !stack.behind.isEmpty {
                guard let topPill = pills[stack.top.shown.id] else { continue }
                var zone = topPill.capsule(in: self).insetBy(dx: -8, dy: -4)
                if fanned == stack.top.shown.id {
                    for t in stack.behind { if let pill = pills[t.shown.id] { zone = zone.union(pill.capsule(in: self).insetBy(dx: -8, dy: -4)) } }
                }
                if zone.contains(p) { over = stack.top.shown.id; break search }
            }
        }
        fanned = over
        // In a fan, the pill under the pointer is marked: the one a click takes.
        var under: PlacementID?
        if let over, let stack = columns.indices.lazy.flatMap({ self.stacks($0) }).first(where: { $0.top.shown.id == over }) {
            for t in [stack.top] + stack.behind {
                if let pill = pills[t.shown.id], !pill.isHidden, pill.capsule(in: self).contains(p) { under = t.shown.id; break }
            }
        }
        if hoveredPill != under {
            if let h = hoveredPill { pills[h]?.hovered = false }
            hoveredPill = under
            if let under { pills[under]?.hovered = true }
        }
    }

    /// The fanned pill the pointer is on, if any.
    private var hoveredPill: PlacementID?

    override func mouseExited(with event: NSEvent) {
        fanned = nil
        if let h = hoveredPill { pills[h]?.hovered = false }
        hoveredPill = nil
    }

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

    /// A tile's note badge: at its lower right, in from the scroll bar's
    /// column and the edge, with room above for its fan.
    private func placeBadge(_ badge: LinkBadge, in r: NSRect) {
        badge.isHidden = false
        badge.fansDown = true
        let size = badge.wantedSize
        let w = min(size.width, max(r.width - 40, 60))
        let h = min(size.height, r.height - 12)
        // Its capsule on the pill's line: both centred in the band.
        let capsuleTop = r.maxY - (Self.band - TilePill.height) / 2 - (TilePill.height - LinkBadge.capsuleHeight) / 2
        badge.frame = NSRect(x: r.maxX - ScrubberView.width - 10 - w, y: capsuleTop - h, width: w, height: h)
    }

    /// Whether the drag under way is a ⇧-drag of a block's path.
    private var pathDrag = false

    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        if pathDrag { return .copy }
        return context == .withinApplication ? .move : []
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
        return .move
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

    /// A stack switched (⌘E): the new top's view slides in from `dir`'s
    /// side over the old top's, which slides out the other way, both
    /// kept to the tile by masks that hold still as the layers move.
    func slideTile(outgoing: PaneContent, incoming id: PlacementID, from dir: CGFloat) {
        layoutSubtreeIfNeeded()
        guard let tile = columns.flatMap({ $0 }).first(where: { $0.shown.id == id }),
              let inLayer = tile.view.layer, let outLayer = outgoing.layer else { return }
        let frame = tile.view.frame
        outgoing.frame = frame
        outgoing.isHidden = false
        keep(tile.view, above: outgoing)
        let w = frame.width
        let ease = CAMediaTimingFunction(controlPoints: 0.2, 0.8, 0.25, 1)
        func masked(_ layer: CALayer) -> CALayer {
            let m = CALayer()
            m.backgroundColor = NSColor.black.cgColor
            m.frame = layer.bounds
            layer.mask = m
            return m
        }
        let inMask = masked(inLayer), outMask = masked(outLayer)
        let leaving = outgoing.placement
        CATransaction.begin()
        CATransaction.setCompletionBlock { [weak self, weak outgoing] in
            for l in [inLayer, outLayer] {
                l.removeAnimation(forKey: "manifold.slide")
                l.mask = nil
            }
            if let self, let outgoing, self.isStashed(leaving) { outgoing.isHidden = true }
        }
        let move = { (layer: CALayer, mask: CALayer, from: CGFloat, to: CGFloat) in
            let a = CABasicAnimation(keyPath: "transform")
            a.fromValue = CATransform3DMakeTranslation(from, 0, 0)
            a.toValue = CATransform3DMakeTranslation(to, 0, 0)
            a.duration = 0.22
            a.timingFunction = ease
            a.fillMode = .forwards
            a.isRemovedOnCompletion = false
            layer.add(a, forKey: "manifold.slide")
            // The mask holds the tile's place while the layer moves under it.
            let b = CABasicAnimation(keyPath: "position.x")
            b.fromValue = mask.position.x - from
            b.toValue = mask.position.x - to
            b.duration = 0.22
            b.timingFunction = ease
            b.fillMode = .forwards
            b.isRemovedOnCompletion = false
            mask.add(b, forKey: "manifold.slide")
        }
        move(inLayer, inMask, dir * w, 0)
        move(outLayer, outMask, 0, -dir * w)
        CATransaction.commit()
    }

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

    override func draw(_ dirtyRect: NSRect) {
        Theme.divider.setFill()
        bounds.fill()
    }
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
    private let dirty = NSView()
    private let corner = IconButton(symbol: "arrow.up.left.and.arrow.down.right", size: 9, weight: .semibold, target: nil, action: nil)
    /// A field in the name's place while the pill edits something (a
    /// page's address): the pill widens to show it.
    private let editor = NSTextField()
    private var edit: PillEdit?
    var isEditing: Bool { edit != nil }
    var onToggleFull: (() -> Void)?
    private var downAt: NSPoint?
    private var focused = false
    private var maximized = false
    /// How many stashed tiles are bunched under this pill (§3.1): their
    /// edges peek out at its right, level with it, as Prism's sheets do.
    var behind = 0 { didSet { if behind != oldValue { needsLayout = true; needsDisplay = true } } }

    static let height: CGFloat = 24
    /// Every pill the same width, within its tile.
    static let width: CGFloat = 220
    /// Edges shown at most, and how far each peeks out.
    private static let mostBehind = 3
    private static let step: CGFloat = 6

    private var edges: Int { min(behind, Self.mostBehind) }

    /// The capsule's frame, the edges behind it included, in `view`'s coordinates.
    func capsule(in view: NSView) -> NSRect {
        var r = glass.frame
        r.size.width += CGFloat(edges) * Self.step
        return convert(r, to: view)
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        glass.wantsLayer = true
        glass.layer?.cornerRadius = Self.height / 2
        glass.layer?.cornerCurve = .continuous
        glass.layer?.borderWidth = 0.5
        glass.layer?.shadowOpacity = 0.14
        glass.layer?.shadowRadius = 5
        glass.layer?.shadowOffset = CGSize(width: 0, height: -1.5)
        glass.themed {
            $0.layer?.backgroundColor = Theme.panel.cgColor
            $0.layer?.shadowColor = NSColor.black.cgColor
        }
        addSubview(glass)
        icon.contentTintColor = Theme.secondaryText
        name.font = .systemFont(ofSize: 11.5, weight: .medium)
        name.textColor = Theme.text
        name.lineBreakMode = .byTruncatingTail
        name.alignment = .center
        dirty.wantsLayer = true
        dirty.layer?.cornerRadius = 3
        dirty.themed { $0.layer?.backgroundColor = Theme.secondaryText.cgColor }
        dirty.isHidden = true
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
        for v in [icon, name, glyph, dirty, corner, editor] { addSubview(v) }
        themed { $0.updateColors() }
    }

    // MARK: Editing in place

    /// The pill becomes a field for `e`, as wide as the tile allows, the
    /// text selected to type over.
    func beginEditing(_ e: PillEdit) {
        edit = e
        editor.stringValue = e.text
        editor.placeholderString = e.placeholder
        editor.textColor = Theme.text
        name.isHidden = true
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
            endEditing()
            if !text.isEmpty { commit?(text) }
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
        if name.stringValue != title { name.stringValue = title }
        if dirty.isHidden == shown.isDirty { dirty.isHidden = !shown.isDirty }
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
            glass.layer?.borderColor = (hovered ? Theme.accent.withAlphaComponent(0.9) : focused ? Theme.accent.withAlphaComponent(0.5) : Theme.cardBorder).cgColor
        }
        glass.layer?.borderWidth = hovered ? 1.5 : 0.5
        name.font = .systemFont(ofSize: 11.5, weight: focused || hovered ? .semibold : .medium)
        name.textColor = focused || hovered ? Theme.text : Theme.secondaryText
        icon.contentTintColor = focused || hovered ? Theme.text : Theme.secondaryText
        restingAlpha = focused ? 1 : 0.72
        if !dodging { alphaValue = restingAlpha }
    }

    /// As wide as its title needs, within bounds: never past half the
    /// tile (so what's under the band stays reachable at the sides), nor
    /// wider than `width`, nor narrower than fits an icon and a few words.
    private var pillWidth: CGFloat {
        var chrome: CGFloat = 10 + 22 + 12 + 8
        if !stashed { chrome += 18 }
        if !glyph.isHidden { chrome += StatusGlyph.size + 6 }
        if !dirty.isHidden { chrome += 12 }
        let wanted = ceil(name.intrinsicContentSize.width) + chrome
        let most = max(min(Self.width, bounds.width * 0.5), 110)
        // Editing, it widens for what's typed: most of the tile.
        if isEditing { return min(max(wanted, 560), bounds.width - 24) }
        return min(max(wanted, 110), most, bounds.width - 24)
    }

    /// Only the capsule is the pill (its corner button included); the
    /// rest is the tile beneath.
    /// How it shows when the text cursor isn't under it: the focused
    /// tile's plain, the others' a little lighter.
    private var restingAlpha: CGFloat = 0.88
    /// Out of the text cursor's way: faded, and taking no clicks.
    var dodging = false {
        didSet {
            guard dodging != oldValue else { return }
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.15
                animator().alphaValue = dodging ? 0 : restingAlpha
            }
        }
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        // Hidden (another tile maximized over this one) or out of the
        // cursor's way: nothing here. An override doesn't get AppKit's
        // own check for hidden views.
        guard !isHidden, !dodging else { return nil }
        let p = convert(point, from: superview)
        guard glass.frame.contains(p) else { return nil }
        return super.hitTest(point) ?? self
    }

    override func layout() {
        super.layout()
        let h = Self.height
        let w = pillWidth
        let y = ((bounds.height - h) / 2).rounded()
        // Centered with the edges behind it counted in.
        glass.frame = NSRect(x: ((bounds.width - w - CGFloat(edges) * Self.step) / 2).rounded(), y: y, width: w, height: h)
        var x = glass.frame.minX + 10
        icon.frame = NSRect(x: x, y: y + (h - 14) / 2, width: 16, height: 14)
        x += 22
        var right = glass.frame.maxX - 12
        corner.isHidden = stashed
        if !corner.isHidden {
            corner.frame = NSRect(x: right - 14, y: y + (h - 16) / 2, width: 16, height: 16)
            right -= 18
        }
        if !glyph.isHidden {
            glyph.frame = NSRect(x: right - StatusGlyph.size, y: y + (h - StatusGlyph.size) / 2, width: StatusGlyph.size, height: StatusGlyph.size)
            right -= StatusGlyph.size + 6
        }
        if !dirty.isHidden {
            dirty.frame = NSRect(x: right - 6, y: y + (h - 6) / 2, width: 6, height: 6)
            right -= 12
        }
        let th = ceil(name.intrinsicContentSize.height)
        name.frame = NSRect(x: x - 2, y: y + ((h - th) / 2).rounded() - 0.5, width: max(0, right - x + 4), height: th)
        let eh = ceil(editor.intrinsicContentSize.height)
        editor.frame = NSRect(x: x - 2, y: y + ((h - eh) / 2).rounded(), width: max(0, right - x + 4), height: eh)
    }

    override func resetCursorRects() { addCursorRect(glass.frame, cursor: .openHand) }

    override func mouseDown(with event: NSEvent) { downAt = event.locationInWindow }

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
            if event.modifierFlags.contains(.shift) { onPathClick?() }
            else if icon.convert(icon.bounds, to: self).insetBy(dx: -8, dy: -6).contains(p) { onIconClick?(event.modifierFlags) } else { onClick?(p, event.modifierFlags) }
        }
        downAt = nil
    }

    /// The edges of the stashed tiles' pills, the furthest first, each a
    /// step to the right of the one before it, level with the capsule.
    override func draw(_ dirtyRect: NSRect) {
        guard edges > 0 else { return }
        for level in stride(from: edges, through: 1, by: -1) {
            let rect = glass.frame.offsetBy(dx: CGFloat(level) * Self.step, dy: 0).insetBy(dx: 0.5, dy: 0.5)
            let path = NSBezierPath(roundedRect: rect, xRadius: rect.height / 2, yRadius: rect.height / 2)
            Theme.sheet(level: level).setFill()
            path.fill()
            Theme.text.withAlphaComponent(0.1).setStroke()
            path.lineWidth = 1
            path.stroke()
        }
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

/// The pointer, moved by us: to a point in screen coordinates (AppKit's,
/// from the bottom left of the main screen).
enum Pointer {
    static func warp(to screen: NSPoint) {
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
        let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.75, dy: 0.75), xRadius: 3, yRadius: 3)
        path.lineWidth = 1.5
        Theme.accent.withAlphaComponent(0.3).setStroke()
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
        registerForDraggedTypes([.manifoldArrangement, .manifoldPlacement, .manifoldBlock])
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
