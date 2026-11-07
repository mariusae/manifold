import AppKit
import ManifoldCore

/// The dock as a shelf (§3.1), a view option to try against the sidebar's
/// list (View ▸ Show Dock Shelf): the space's docked tiles along the foot
/// of the grid, in one short row — first those whose status wants you
/// (needs you, failed, done and not read), then as ⌃⇥ would reach them,
/// the latest used first. They take the room there is, one size for all:
/// cards (a title and a line), else chips (a title), else only their
/// symbols — except a tile whose status wants you, which stays a card,
/// edged and tinted in its status's colour. The pointer on one peeks at it
/// (the tile itself, live, over its card, above the shelf), and moved
/// along the shelf, scrubs through them; a click puts it back where it
/// was. The grid gives up the shelf's height while it shows (only while
/// something's docked).
final class DockShelfView: NSView {
    static let height: CGFloat = 60
    static let gap: CGFloat = 6
    static let pad: CGFloat = 7

    /// A docked tile, as the shelf shows it.
    struct Item {
        var content: SummaryCardContent
        var look: StatusGlyph.Look?
        var id: PlacementID { content.id }
        /// Its status wants you: a card always, in its colour.
        var alerting: Bool {
            switch look {
            case .needsYou, .failed(read: false), .done(read: false): true
            default: false
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
    enum Size: Int, CaseIterable { case card, chip, icon }

    /// A card clicked: its tile back where it was.
    var onPick: ((PlacementID) -> Void)?
    /// The pointer on one (its rect in the window), or off the shelf.
    var onHover: ((PlacementID?, NSRect) -> Void)?

    private let scroll = NSScrollView()
    private let strip = FlippedView()
    private let label = NSTextField(labelWithString: "Docked")
    private var items: [Item] = []
    private var views: [DockItemView] = []
    private(set) var size: Size = .card
    private var hovered: Int? {
        didSet {
            guard hovered != oldValue else { return }
            for (i, v) in views.enumerated() { v.hovered = i == hovered }
        }
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.cornerRadius = Radius.surface
        layer?.cornerCurve = .continuous
        layer?.borderWidth = 0.5
        themed { v in
            v.layer?.backgroundColor = Theme.panel.withAlphaComponent(0.7).cgColor
            v.layer?.borderColor = Theme.panelBorder.cgColor
        }
        label.font = UIType.caption
        label.textColor = Theme.secondaryText
        scroll.drawsBackground = false
        scroll.hasHorizontalScroller = true
        scroll.hasVerticalScroller = false
        scroll.autohidesScrollers = true
        scroll.horizontalScrollElasticity = .allowed
        scroll.documentView = strip
        addSubview(label)
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

    /// The width each takes at a size (an alerting one, a card at any).
    private func width(_ item: Item, _ size: Size) -> CGFloat {
        DockItemView.width(item, item.alerting ? .card : size)
    }

    private func total(_ size: Size) -> CGFloat {
        Self.pad * 2 + items.reduce(0) { $0 + width($1, size) } + CGFloat(max(0, items.count - 1)) * Self.gap
    }

    override func layout() {
        super.layout()
        // The word at the left, the tiles after it, one short row.
        label.sizeToFit()
        label.frame.origin = NSPoint(x: Self.pad + 5, y: ((bounds.height - label.frame.height) / 2).rounded())
        let left = label.frame.maxX + 4
        scroll.frame = NSRect(x: left, y: 0, width: max(0, bounds.width - left), height: bounds.height)
        // The biggest size that fits them all; else the least, scrolled.
        let room = scroll.contentSize.width
        size = Size.allCases.first { total($0) <= room } ?? .icon
        strip.frame = NSRect(x: 0, y: 0, width: max(total(size), room), height: scroll.contentSize.height)
        var x = Self.pad
        for (v, item) in zip(views, items) {
            let s: Size = item.alerting ? .card : size
            v.size = s
            let w = width(item, size), h = DockItemView.height(s)
            v.frame = NSRect(x: x, y: ((strip.bounds.height - h) / 2).rounded(), width: w, height: h)
            x += w + Self.gap
        }
    }

    // The tiles are the shelf's to click and hover, not their own.
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

    /// Debugging: the size, and its tiles in order, the hovered marked.
    var debugItems: String {
        "\(size) · " + items.enumerated().map { i, item in
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

/// One docked tile on the shelf, at a size: its summary card; a chip, its
/// symbol and title; or its symbol alone, a dot for its status. One whose
/// status wants you, edged and tinted in its colour.
final class DockItemView: NSView {
    var item: DockShelfView.Item { didSet { card.content = item.content; needsDisplay = true } }
    var size: DockShelfView.Size = .card {
        didSet {
            guard size != oldValue else { return }
            card.isHidden = size != .card
            needsDisplay = true
        }
    }
    var hovered = false { didSet { if hovered != oldValue { card.chosen = hovered; needsDisplay = true } } }
    private let card: SummaryCard

    static func height(_ size: DockShelfView.Size) -> CGFloat { size == .card ? 46 : 30 }

    static func width(_ item: DockShelfView.Item, _ size: DockShelfView.Size) -> CGFloat {
        switch size {
        case .card: return 180
        case .chip:
            let w = (item.content.summary.title as NSString).size(withAttributes: [.font: UIType.label]).width
            return min(150, ceil(w) + 38)
        case .icon: return 30
        }
    }

    init(_ item: DockShelfView.Item) {
        self.item = item
        card = SummaryCard(item.content)
        super.init(frame: .zero)
        addSubview(card)
        wantsLayer = true
        layer?.cornerRadius = Radius.surface
        layer?.cornerCurve = .continuous
        toolTip = item.content.summary.title
    }

    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        card.frame = bounds
        // Its status's colour round it, and a little of it under it.
        let tone = item.tone
        layer?.borderWidth = tone == nil ? 0 : 1.5
        layer?.borderColor = tone?.cgColor
        layer?.backgroundColor = tone?.withAlphaComponent(0.12).cgColor
    }

    override func draw(_ dirtyRect: NSRect) {
        guard size != .card else { return }
        let r = bounds.insetBy(dx: 0.5, dy: 0.5)
        let path = NSBezierPath(roundedRect: r, xRadius: Radius.control + 2, yRadius: Radius.control + 2)
        (hovered ? Theme.accent.withAlphaComponent(0.14) : Theme.panel).setFill()
        path.fill()
        (hovered ? Theme.accent.withAlphaComponent(0.6) : Flat.line).setStroke()
        path.lineWidth = 1
        path.stroke()
        let ink = item.tone ?? Theme.text
        if let image = Theme.symbol(item.content.symbol, size: 12, weight: .medium, color: ink) {
            let s = image.size
            let x = size == .icon ? (bounds.width - s.width) / 2 : 9
            image.draw(in: NSRect(x: x.rounded(), y: ((bounds.height - s.height) / 2).rounded(), width: s.width, height: s.height))
        }
        if size == .chip {
            let title = NSAttributedString(string: item.content.summary.title, attributes: [.font: UIType.label, .foregroundColor: Theme.text])
            title.draw(with: NSRect(x: 28, y: (bounds.height - 16) / 2, width: bounds.width - 34, height: 16),
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
}
