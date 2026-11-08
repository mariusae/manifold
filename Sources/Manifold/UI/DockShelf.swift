import AppKit
import ManifoldCore

/// The dock as a shelf (§3.1), a view option to try against the sidebar's
/// list (View ▸ Show Dock Shelf): the space's docked tiles along the foot
/// of the grid, in one short row, centred — first those whose status wants
/// you (needs you, failed, done and not read), then as ⌃⇥ would reach them,
/// the latest used first. Each is a chip, its symbol and title, as wide as
/// that wants; short of room, the chips give up the ends of their titles,
/// then show their symbols alone — but for one whose status wants you,
/// which stays a chip with its status's pill, tinted. No bar of its own:
/// they float on the window's ground, each its own shadow, lifted under
/// the pointer, which peeks at the tile (itself, live, above the shelf) and,
/// moved along, scrubs through them; a click puts it back where it was.
/// The grid gives up the shelf's height while it shows (only while
/// something's docked). Docking flies a tile down into its chip, and
/// undocking back out of it.
final class DockShelfView: NSView {
    static let height: CGFloat = 44
    static let gap: CGFloat = 6
    static let pad: CGFloat = 7

    /// A docked tile, as the shelf shows it.
    struct Item {
        var content: SummaryCardContent
        var look: StatusGlyph.Look?
        var id: PlacementID { content.id }
        /// Its status wants you: a chip always, its pill on it, tinted.
        var alerting: Bool { pill != nil }
        var pill: StatusPill.Kind? {
            switch look {
            case .needsYou: content.mark?.pill ?? .needs(StatusPill.words(nil))
            case .failed(read: false): .failed
            case .done(read: false): .done
            default: nil
            }
        }
        var tone: NSColor? {
            switch look {
            case .needsYou: Status.attention
            case .failed(read: false): Status.failed
            case .done(read: false): Status.done
            default: nil
            }
        }
    }

    /// How much of each shows, by the room there is.
    enum Size { case chip, icon }

    /// A chip clicked: its tile back where it was.
    var onPick: ((PlacementID) -> Void)?
    /// The pointer on one (its rect in the window), or off the shelf.
    var onHover: ((PlacementID?, NSRect) -> Void)?

    private let scroll = NSScrollView()
    private let strip = FlippedView()
    private var items: [Item] = []
    private var views: [DockItemView] = []
    private(set) var size: Size = .chip
    /// The widest a plain chip is let be, as the room allows.
    private var cap = DockItemView.widest
    private var hovered: Int? {
        didSet {
            guard hovered != oldValue else { return }
            for (i, v) in views.enumerated() { v.hovered = i == hovered }
        }
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        scroll.drawsBackground = false
        scroll.hasHorizontalScroller = true
        scroll.hasVerticalScroller = false
        scroll.autohidesScrollers = true
        scroll.horizontalScrollElasticity = .allowed
        scroll.documentView = strip
        addSubview(scroll)
    }

    required init?(coder: NSCoder) { fatalError() }

    /// Its tiles, in order.
    func show(_ new: [Item]) {
        if new.map(\.id) == items.map(\.id) {
            items = new
            for (v, i) in zip(views, new) { v.item = i }
            needsLayout = true
            return
        }
        items = new
        views.forEach { $0.removeFromSuperview() }
        views = new.map { DockItemView($0) }
        views.forEach { strip.addSubview($0) }
        hovered = nil
        needsLayout = true
    }

    /// The width each takes, at a size and a plain chip's widest.
    private func width(_ item: Item, _ size: Size, cap: CGFloat) -> CGFloat {
        if item.alerting { return DockItemView.natural(item) }
        return size == .icon ? DockItemView.iconWidth : min(cap, DockItemView.natural(item))
    }

    private func total(_ size: Size, cap: CGFloat) -> CGFloat {
        items.reduce(0) { $0 + width($1, size, cap: cap) } + CGFloat(max(0, items.count - 1)) * Self.gap
    }

    override func layout() {
        super.layout()
        scroll.frame = bounds
        let room = scroll.contentSize.width - 2 * Self.pad
        // Chips as wide as they'd be; else narrower, their titles cut, to a
        // point; else symbols alone (scrolled, if even they don't fit).
        size = .chip
        cap = DockItemView.widest
        while total(.chip, cap: cap) > room, cap > DockItemView.narrowest { cap -= 2 }
        if total(.chip, cap: cap) > room { size = .icon }
        let used = total(size, cap: cap)
        strip.frame = NSRect(x: 0, y: 0, width: max(used + 2 * Self.pad, scroll.contentSize.width), height: scroll.contentSize.height)
        var x = ((strip.bounds.width - used) / 2).rounded()
        let h = DockItemView.height
        for (v, item) in zip(views, items) {
            v.size = item.alerting ? .chip : size
            let w = width(item, size, cap: cap)
            v.frame = NSRect(x: x, y: ((strip.bounds.height - h) / 2).rounded(), width: w, height: h)
            x += w + Self.gap
        }
    }

    // The chips are the shelf's to click and hover, not their own — and
    // only where one is: between them, what's behind (the grid's ground).
    override func hitTest(_ point: NSPoint) -> NSView? {
        guard !isHidden, frame.contains(point) else { return nil }
        return self
    }

    private func item(at event: NSEvent) -> Int? {
        let p = strip.convert(event.locationInWindow, from: nil)
        return views.firstIndex { $0.frame.insetBy(dx: -Self.gap / 2, dy: -6).contains(p) }
    }

    override func updateTrackingAreas() {
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .mouseMoved, .activeAlways, .inVisibleRect], owner: self))
        super.updateTrackingAreas()
    }

    override func mouseMoved(with event: NSEvent) { hover(item(at: event)) }
    override func mouseEntered(with event: NSEvent) { hover(item(at: event)) }
    override func mouseExited(with event: NSEvent) { hover(nil) }
    override func scrollWheel(with event: NSEvent) {
        scroll.scrollWheel(with: event)
        hover(item(at: event))
    }

    private func hover(_ i: Int?) {
        hovered = i
        guard let i else { return onHover?(nil, .zero) ?? () }
        onHover?(items[i].id, views[i].convert(views[i].bounds, to: nil))
    }

    override func mouseDown(with event: NSEvent) {}
    override func mouseUp(with event: NSEvent) {
        guard let i = item(at: event) else { return }
        onHover?(nil, .zero)
        onPick?(items[i].id)
    }

    /// A tile's chip, for it to be flown to or from.
    func chip(_ id: PlacementID) -> NSView? {
        views.first { $0.item.id == id && $0.superview != nil }
    }

    /// Its chip, pictured, where it is in `view`'s terms.
    func pictured(_ id: PlacementID, in view: NSView) -> GridView.Pictured? {
        guard let v = views.first(where: { $0.item.id == id }), v.bounds.width > 0 else { return nil }
        let hovered = v.hovered
        v.hovered = false
        defer { v.hovered = hovered }
        v.displayIfNeeded()
        return GridView.Pictured(parts: [(view.convert(v.bounds, from: v), GridView.ghostPicture(of: v))], ground: v.ground.cgColor)
    }

    /// Debugging: the size, and its tiles in order, the hovered marked.
    var debugItems: String {
        "\(size)\(size == .chip ? " ≤\(Int(cap))" : "") · " + items.enumerated().map { i, item in
            (hovered == i ? ">" : " ") + item.content.summary.title + (item.alerting ? " [\(item.look.map { "\($0)" } ?? "")]" : "")
        }.joined(separator: " | ")
    }

    /// Debugging: the pointer on tile `i` (nil, off the shelf), or tile `i` clicked.
    func debugHover(_ i: Int?) {
        guard let i, items.indices.contains(i) else { return hover(nil) }
        hover(i)
    }
    func debugPick(_ i: Int) {
        guard items.indices.contains(i) else { return }
        onPick?(items[i].id)
    }
}

/// One docked tile on the shelf: a chip, its symbol and title (cut short
/// as it must), else its symbol alone, a dot at its corner while it works.
/// One whose status wants you, its status's pill after its title and a
/// tint of its colour — the one way it's told. Each floats: a shadow
/// under it (kept within the shelf's margin, which clips), lifted under
/// the pointer — brighter, its shadow deeper, not in the accent (that's
/// where the keyboard is).
final class DockItemView: NSView {
    var item: DockShelfView.Item { didSet { toolTip = item.content.summary.title; needsDisplay = true } }
    var size: DockShelfView.Size = .chip { didSet { if size != oldValue { needsDisplay = true } } }
    var hovered = false {
        didSet {
            guard hovered != oldValue else { return }
            needsDisplay = true
            lift()
        }
    }

    static let height: CGFloat = 30
    static let iconWidth: CGFloat = 30
    /// A plain chip's widest, and narrowest before it's a symbol alone.
    static let widest: CGFloat = 170
    static let narrowest: CGFloat = 84
    private static let radius: CGFloat = Radius.control + 2
    private static let titleX: CGFloat = 28

    /// As wide as all it says wants: its symbol, its title, its pill.
    static func natural(_ item: DockShelfView.Item) -> CGFloat {
        let title = ceil((item.content.summary.title as NSString).size(withAttributes: [.font: UIType.label]).width)
        let pill = item.pill.map { StatusPill.size($0).width + 8 } ?? 0
        let w = titleX + title + pill + 10
        return item.alerting ? min(w, 260) : w
    }

    init(_ item: DockShelfView.Item) {
        self.item = item
        super.init(frame: .zero)
        wantsLayer = true
        layer?.masksToBounds = false
        layer?.shadowColor = NSColor.black.cgColor
        lift()
        toolTip = item.content.summary.title
    }

    required init?(coder: NSCoder) { fatalError() }

    /// Its shadow: floating, or lifted under the pointer.
    private func lift() {
        guard let l = layer else { return }
        l.shadowOpacity = hovered ? 0.32 : 0.18
        l.shadowRadius = hovered ? 6 : 4
        l.shadowOffset = CGSize(width: 0, height: hovered ? -3 : -2)
    }

    override func layout() {
        super.layout()
        layer?.shadowPath = CGPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), cornerWidth: Self.radius, cornerHeight: Self.radius, transform: nil)
    }

    /// Its fill: the panel's, a little of its status's colour in it, a
    /// little brighter under the pointer — opaque, its shadow under it.
    var ground: NSColor {
        var c = Theme.panel.usingColorSpace(.sRGB) ?? Theme.panel
        if let tone = item.tone { c = c.blended(withFraction: 0.16, of: tone) ?? c }
        if hovered { c = c.blended(withFraction: 0.08, of: Theme.text) ?? c }
        return c
    }

    override func draw(_ dirtyRect: NSRect) {
        let r = bounds.insetBy(dx: 0.5, dy: 0.5)
        let path = NSBezierPath(roundedRect: r, xRadius: Self.radius, yRadius: Self.radius)
        ground.setFill()
        path.fill()
        (item.tone?.withAlphaComponent(0.35) ?? Flat.line).setStroke()
        path.lineWidth = 0.5
        path.stroke()
        if let image = Theme.symbol(item.content.symbol, size: 12, weight: .medium, color: hovered ? Theme.text : Theme.secondaryText) {
            let s = image.size
            let x = size == .icon ? (bounds.width - s.width) / 2 : 9
            image.draw(in: NSRect(x: x.rounded(), y: ((bounds.height - s.height) / 2).rounded(), width: s.width, height: s.height))
        }
        if size == .chip {
            var right = bounds.width - 10
            if let pill = item.pill {
                let ps = StatusPill.size(pill)
                let pr = NSRect(x: right - ps.width, y: ((bounds.height - ps.height) / 2).rounded(), width: ps.width, height: ps.height)
                StatusPill.draw(pill, in: pr)
                right = pr.minX - 8
            }
            let title = NSAttributedString(string: item.content.summary.title, attributes: [.font: UIType.label, .foregroundColor: Theme.text])
            title.draw(with: NSRect(x: Self.titleX, y: ((bounds.height - 16) / 2).rounded(), width: max(0, right - Self.titleX), height: 16),
                       options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
        }
        // Working: a dot at its corner, as its row's glyph says it.
        if case .working = item.look {
            Status.runningText.setFill()
            NSBezierPath(ovalIn: NSRect(x: bounds.width - 9, y: bounds.height - 9, width: 5, height: 5)).fill()
        }
    }
}

extension MainWindowController {
    private static let dockShelfKey = "DockShelf"

    /// The dock shown as a shelf at the grid's foot, too (a view option, to
    /// try against the sidebar's list alone).
    var dockShelfOn: Bool { UserDefaults.standard.bool(forKey: Self.dockShelfKey) }

    @objc func toggleDockShelf(_ sender: Any?) {
        UserDefaults.standard.set(!dockShelfOn, forKey: Self.dockShelfKey)
        refreshDockShelf()
    }

    /// Whether the shelf takes room now: on, and something here docked.
    private var dockShelfShows: Bool { dockShelfOn && !(arrangement?.docked.isEmpty ?? true) && stateView == nil }

    /// Where the grid goes: the stage, less the shelf at its foot.
    var gridFrame: NSRect {
        var r = stage.bounds
        if dockShelfShows {
            let h = DockShelfView.height + GridView.inset
            r.origin.y += h
            r.size.height -= h
        }
        return r
    }

    func layoutDockShelf() {
        dockShelf.isHidden = !dockShelfShows
        guard !dockShelf.isHidden else { return }
        let i = GridView.inset
        dockShelf.frame = NSRect(x: i, y: i, width: max(0, stage.bounds.width - 2 * i), height: DockShelfView.height)
    }

    /// The shelf as the space's dock is now; the grid laid out again if it
    /// came or went.
    func refreshDockShelf() {
        if dockShelf.superview == nil {
            stage.addSubview(dockShelf)
            dockShelf.onPick = { [weak self] id in self?.arrive(atTile: id) }
            dockShelf.onHover = { [weak self] id, rect in
                guard let self, let window = self.window else { return }
                guard let id, let b = self.arrangement?.placement(id)?.block, let block = self.hosts.block(b) else { return HoverCard.shared.hide() }
                self.peekDocked(id, block, beside: rect, in: window)
            }
        }
        let shows = dockShelfShows
        if shows, let a = arrangement {
            dockShelf.show(dockShelfOrder(a).compactMap { d in
                guard let c = cardContent(for: d.placement.block, view: views[d.placement.id], id: d.placement.id) else { return nil }
                return DockShelfView.Item(content: c, look: StatusGlyph.look(of: hosts.block(d.placement.block)))
            })
        }
        if shows == dockShelf.isHidden || (shows && dockShelf.frame.width != stage.bounds.width - 2 * GridView.inset) {
            layoutDockShelf()
            content.frame = gridFrame
        }
    }

    /// The shelf's order: those whose status wants you first (needs you,
    /// failed, done and not read), then as ⌃⇥ would reach them — the latest
    /// used first — then the latest docked.
    private func dockShelfOrder(_ a: ArrangementState) -> [DockedTile] {
        let trail = tileTrail(space: selected).compactMap(\.tile)
        func urgency(_ d: DockedTile) -> Int {
            switch StatusGlyph.look(of: hosts.block(d.placement.block)) {
            case .needsYou: 0
            case .failed(read: false): 1
            case .done(read: false): 2
            default: 3
            }
        }
        let latest = Array(a.docked.reversed())
        func rank(_ d: DockedTile) -> (Int, Int, Int) {
            (urgency(d), trail.firstIndex(of: d.placement.id) ?? Int.max, latest.firstIndex { $0.placement.id == d.placement.id } ?? 0)
        }
        return latest.sorted { rank($0) < rank($1) }
    }

    /// A docked tile peeked at from the shelf: its own view, live (a
    /// terminal still running), lent to the card over it — out of the grid,
    /// nothing else shows it — else the block's card as the sidebar shows it.
    private func peekDocked(_ id: PlacementID, _ block: Block, beside rect: NSRect, in window: NSWindow) {
        guard let v = views[id], !(v.superview is GridView) else {
            return showBlockCard(block.id, beside: rect, in: window, delay: 0.25, above: true)
        }
        let size = v.frame.size.width > 40 && v.frame.size.height > 40 ? v.frame.size : NSSize(width: 720, height: 440)
        HoverCard.shared.show(key: "dock/" + id, title: block.displayTitle, detail: "", body: "", font: nil,
                              summary: cardContent(for: block.id, view: v, id: id),
                              lend: { HoverCard.LiveLoan(view: v, size: size) { $0.removeFromSuperview() } },
                              beside: rect, in: window, delay: 0.25, above: true)
    }

    /// Debugging the shelf: `shelf` its cards; `shelf on|off`; `shelf hover <i>|off`; `shelf pick <i>`.
    func debugShelf(_ arg: String) -> String {
        let w = arg.split(separator: " ").map(String.init)
        switch w.first {
        case "on", "off": if (w[0] == "on") != dockShelfOn { toggleDockShelf(nil) }
        case "hover": dockShelf.debugHover(w.dropFirst().first.flatMap { Int($0) })
        case "pick": if let i = w.dropFirst().first.flatMap({ Int($0) }) { dockShelf.debugPick(i) }
        default: break
        }
        return "\(dockShelfOn ? "on" : "off")\(dockShelf.isHidden ? " hidden" : " shown \(NSStringFromRect(dockShelf.frame))") · grid \(NSStringFromRect(content.frame)) · \(dockShelf.debugItems)"
    }

    // MARK: Flying

    /// Tiles going down into the dock (their pictures as they were in the
    /// grid) and coming back up out of it (from where: a chip on the
    /// shelf, pictured, else a row in the sidebar), in the root's terms.
    struct DockFlights {
        var down: [PlacementID: GridView.Pictured] = [:]
        var up: [PlacementID: (from: NSRect, chip: GridView.Pictured?)] = [:]
    }

    /// Where a docked tile (or one in another space) is to be seen, in the
    /// root's terms: its chip on the shelf, else its row in the sidebar
    /// (its space's, till its own is made) — nil, neither showing.
    func dockedSpot(_ id: PlacementID, in space: BlockID) -> NSRect? {
        if space == selected, !dockShelf.isHidden, let chip = dockShelf.chip(id) { return root.convert(chip.bounds, from: chip) }
        return sidebar.organizationView.row(of: id, in: space, in: root)
    }

    /// Before the grid shows `a`: what's to fly, if the space is the one
    /// last seen — down only where there's somewhere to fly to (the shelf,
    /// or the sidebar showing); else the grid sees it go as any move.
    func dockFlights(before a: ArrangementState) -> DockFlights? {
        let now = Set(a.docked.map(\.placement.id))
        let seen = dockShelfSeen
        dockShelfSeen = (selected, now)
        guard let space = selected, stateView == nil, !Motion.reduced, let seen, seen.space == space, seen.docked != now else { return nil }
        var f = DockFlights()
        let down = now.subtracting(seen.docked)
        if !down.isEmpty, dockShelfOn || sidebar.organizationView.row(of: down.first!, in: space, in: root) != nil {
            let parts = content.placedParts()
            for id in down {
                guard let p = parts[id] else { continue }
                f.down[id] = GridView.Pictured(parts: p.parts.map { (root.convert($0.0, from: content), $0.1) }, ground: p.ground)
            }
        }
        for id in seen.docked.subtracting(now) where a.locate(id) != nil {
            if let chip = dockShelf.isHidden ? nil : dockShelf.pictured(id, in: root) {
                f.up[id] = (chip.whole, chip)
            } else if let row = sidebar.organizationView.row(of: id, in: space, in: root) {
                f.up[id] = (row, nil)
            }
        }
        return f.down.isEmpty && f.up.isEmpty ? nil : f
    }

    /// How a tile leaving the grid is seen to go: flown, docked with
    /// somewhere to fly to; in a puff, closed (gone from the desk, or on
    /// its way); else moved.
    func departure(of v: PaneContent, flown f: DockFlights?) -> GridView.Departure {
        if f?.down[v.placement] != nil { return .flown }
        if recentlyClosed.contains(v.block) { return .closed }
        let onDesk = allWorkspaces.contains { hosts.arrangement($0)?.placement(v.placement) != nil }
        return onDesk ? .moved : .closed
    }

    /// After: each flown — a tile shrinking into its chip (or its row, the
    /// shelf off), a chip growing into its tile (or out of its row), what
    /// it's becoming coming in on the way — the chip or the tile itself
    /// showing once it's there.
    func flyDock(_ f: DockFlights?) {
        guard let f, let host = root.layer, let a = arrangement, let space = selected else { return }
        content.layoutSubtreeIfNeeded()
        dockShelf.layoutSubtreeIfNeeded()
        var items: [GridView.Morph] = []
        var landing: [NSView] = []
        if !f.down.isEmpty, !dockShelfOn { refreshOrganization(now: true) }
        for (id, tile) in f.down {
            if dockShelfOn, let chip = dockShelf.pictured(id, in: root), let v = dockShelf.chip(id) {
                items.append(GridView.Morph(from: tile.whole, to: chip.whole, leaving: tile, coming: chip))
                landing.append(v)
            } else if let row = sidebar.organizationView.row(of: id, in: space, in: root) {
                items.append(GridView.Morph(from: tile.whole, to: row, leaving: tile))
            }
        }
        if !f.up.isEmpty {
            let parts = content.placedParts()
            for (id, from) in f.up {
                guard let p = parts[id], let b = a.placement(id)?.block else { continue }
                let tile = GridView.Pictured(parts: p.parts.map { (root.convert($0.0, from: content), $0.1) }, ground: p.ground)
                items.append(GridView.Morph(from: from.from, to: tile.whole, leaving: from.chip, coming: tile))
                landing += content.tileViews(of: b)
            }
        }
        guard !items.isEmpty else { return }
        let d = Motion.spatial * 1.4
        GridView.morph(items, in: host, over: d)
        for v in landing {
            guard let l = v.layer else { continue }
            let x = CAKeyframeAnimation(keyPath: "opacity")
            x.values = [0, 0]
            x.keyTimes = [0, 1]
            x.duration = d
            l.add(x, forKey: "landing")
        }
    }
}
