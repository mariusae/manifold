import AppKit
import ManifoldCore

/// A state view (DESIGN.md §3.6): a status group's blocks themselves, live,
/// in the surface — as a **list**, stacked down one scrolling column as
/// Prism's column of notes is, each under its pill; or an **overview**,
/// all of them in one grid at once, as Mission Control lays out windows;
/// or as **summaries**, a summary card each (what more than ten shows by
/// itself, live views of so many being small and dear). Nothing is placed;
/// a block clicked is gone to, ⌘-clicked brought to the arrangement last
/// shown. Overview's filter: this space's blocks, or every agent.
final class StateView: NSView {
    enum Mode: Int { case list, overview, summaries }

    struct Item {
        var shown: Shown
        /// Live, in the list and the overview; none as summaries.
        var view: PaneContent?
        var summary: SummaryCardContent?
    }

    var onGoTo: ((BlockID) -> Void)?
    var onBring: ((BlockID) -> Void)?
    var onLeave: (() -> Void)?
    var onModeChanged: ((Mode) -> Void)?
    /// Overview's filter chosen: 0 this space, 1 the agents.
    var onFilterChanged: ((Int) -> Void)?

    private let header = NSView()
    private let title = NSTextField(labelWithString: "")
    private let count = NSTextField(labelWithString: "")
    private let modes = FlatSegments(symbols: ["list.bullet", "square.grid.2x2", "rectangle.grid.1x2"])
    private let filter = FlatSegments(titles: ["This Space", "Agents"], font: .systemFont(ofSize: 12))
    private var cards: [BlockID: SummaryCard] = [:]
    private let leave = IconButton(symbol: "xmark", size: 12, weight: .medium, target: nil, action: nil)
    private let scroll = ClippingScrollView()
    private let document = FlippedView()
    private var items: [Item] = []
    private var pills: [BlockID: TilePill] = [:]
    private(set) var mode: Mode = .list

    static let headerHeight: CGFloat = 44
    static let listHeight: CGFloat = 440
    static let cellWidth: CGFloat = 400
    static let cellHeight: CGFloat = 300
    static let margin: CGFloat = 16

    override init(frame: NSRect) {
        super.init(frame: frame)
        // Over the window's wash, as the grid is: the cards as the grid has them.
        wantsLayer = true
        layer?.backgroundColor = .clear
        header.wantsLayer = true
        header.layer?.backgroundColor = .clear
        addSubview(header)
        title.font = .systemFont(ofSize: 15, weight: .semibold)
        title.textColor = Theme.text
        count.font = .systemFont(ofSize: 12)
        count.textColor = Theme.secondaryText
        modes.setToolTip("List", forSegment: 0)
        modes.setToolTip("Overview", forSegment: 1)
        modes.setToolTip("Summaries", forSegment: 2)
        modes.selectedSegment = 0
        modes.onChange = { [weak self] _ in self?.modeChosen() }
        filter.onChange = { [weak self] i in self?.onFilterChanged?(i) }
        leave.target = self
        leave.action = #selector(leaveClicked)
        leave.toolTip = "Back to the Space (⎋)"
        for v in [title, count, filter, modes, leave] { header.addSubview(v) }
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.documentView = document
        scroll.contentView.drawsBackground = false
        addSubview(scroll)
    }

    required init?(coder: NSCoder) { fatalError() }

    var views: [PaneContent] { items.compactMap(\.view) }

    /// `filter`: Overview's (0 this space, 1 the agents), or none for a
    /// status group's view.
    func show(_ items: [Item], title: String, mode: Mode, filter chosen: Int? = nil) {
        let incoming = Set(items.map(\.shown.placement.block))
        let live = Set(items.filter { $0.view != nil }.map(\.shown.placement.block))
        for v in document.subviews.compactMap({ $0 as? PaneContent }) where !live.contains(v.block) { v.removeFromSuperview() }
        for (id, p) in pills where !incoming.contains(id) || mode == .summaries {
            p.removeFromSuperview()
            pills.removeValue(forKey: id)
        }
        for (id, c) in cards where !incoming.contains(id) || mode != .summaries {
            c.removeFromSuperview()
            cards.removeValue(forKey: id)
        }
        self.items = items
        self.mode = mode
        modes.selectedSegment = mode.rawValue
        filter.isHidden = chosen == nil
        if let chosen { filter.selectedSegment = chosen }
        self.title.stringValue = title
        count.stringValue = items.isEmpty ? "nothing here" : "\(items.count) block\(items.count == 1 ? "" : "s")"
        for item in items {
            let block = item.shown.placement.block
            if mode == .summaries, let content = item.summary {
                // A summary card: clicked, gone to; ⌘-clicked, brought here.
                let card = cards[block] ?? {
                    let c = SummaryCard(content)
                    c.onClick = { [weak self] in
                        if NSApp.currentEvent?.modifierFlags.contains(.command) == true { self?.onBring?(block) } else { self?.onGoTo?(block) }
                    }
                    cards[block] = c
                    document.addSubview(c)
                    return c
                }()
                card.content = content
                continue
            }
            guard let view = item.view else { continue }
            if view.superview !== document {
                GridView.styleBody(view)
                document.addSubview(view)
            }
            let pill = pills[block] ?? {
                let p = TilePill()
                p.showsButtons = false
                pills[block] = p
                document.addSubview(p)
                return p
            }()
            pill.show(item.shown, focused: false)
            pill.onClick = { [weak self] _, mods in
                if mods.contains(.command) { self?.onBring?(block) } else { self?.onGoTo?(block) }
            }
            pill.onDragStart = nil
        }
        needsLayout = true
    }

    func clear() {
        for v in views { v.removeFromSuperview() }
        pills.values.forEach { $0.removeFromSuperview() }
        pills = [:]
        cards.values.forEach { $0.removeFromSuperview() }
        cards = [:]
        items = []
    }

    override func layout() {
        super.layout()
        header.frame = NSRect(x: 0, y: bounds.height - Self.headerHeight, width: bounds.width, height: Self.headerHeight)
        let h = Self.headerHeight
        title.sizeToFit()
        title.frame = NSRect(x: Self.margin, y: (h - title.frame.height) / 2, width: min(title.frame.width, bounds.width / 2), height: title.frame.height)
        count.sizeToFit()
        count.frame = NSRect(x: title.frame.maxX + 10, y: (h - count.frame.height) / 2, width: count.frame.width, height: count.frame.height)
        leave.frame = NSRect(x: bounds.width - Self.margin - 20, y: (h - 20) / 2, width: 20, height: 20)
        let mw = modes.intrinsicContentSize.width
        modes.frame = NSRect(x: leave.frame.minX - 12 - mw, y: (h - Flat.buttonHeight) / 2, width: mw, height: Flat.buttonHeight)
        let fw = filter.intrinsicContentSize.width
        filter.frame = NSRect(x: modes.frame.minX - 16 - fw, y: (h - Flat.buttonHeight) / 2, width: fw, height: Flat.buttonHeight)
        scroll.frame = NSRect(x: 0, y: 0, width: bounds.width, height: bounds.height - Self.headerHeight)
        let width = scroll.contentSize.width
        let m = Self.margin
        var y: CGFloat = m
        switch mode {
        case .summaries:
            // Cards in as many columns as fit, each as tall as a card.
            let columns = max(1, Int((width - m) / (340 + m)))
            let w = ((width - CGFloat(columns + 1) * m) / CGFloat(columns)).rounded(.down)
            for (i, item) in items.enumerated() {
                guard let card = cards[item.shown.placement.block] else { continue }
                let row = i / columns, col = i % columns
                card.frame = NSRect(x: m + CGFloat(col) * (w + m), y: m + CGFloat(row) * (SummaryCard.height + m), width: w, height: SummaryCard.height)
                y = card.frame.maxY + m
            }
        case .list:
            for item in items {
                let block = item.shown.placement.block
                guard let view = item.view else { continue }
                // A card as the grid lays one out: the bar at the top, the content beneath.
                view.frame = NSRect(x: m, y: y + GridView.barHeight, width: width - 2 * m, height: Self.listHeight - GridView.barHeight)
                if let pill = pills[block] {
                    pill.frame = NSRect(x: m, y: y, width: width - 2 * m, height: GridView.barHeight)
                    document.addSubview(pill, positioned: .above, relativeTo: view)
                }
                y += Self.listHeight + m
            }
        case .overview:
            let (columns, cell) = Self.overviewGrid(count: items.count, in: NSSize(width: width, height: scroll.contentSize.height), margin: m)
            let rows = (items.count + columns - 1) / max(columns, 1)
            // The grid in the middle of the room, each row's cards centered.
            let gridHeight = CGFloat(rows) * cell.height + CGFloat(max(rows - 1, 0)) * m
            let top0 = max(m, (scroll.contentSize.height - gridHeight) / 2)
            for (i, item) in items.enumerated() {
                let block = item.shown.placement.block
                let row = i / columns, col = i % columns
                let inRow = row == rows - 1 ? items.count - row * columns : columns
                let rowWidth = CGFloat(inRow) * cell.width + CGFloat(inRow - 1) * m
                let x = (width - rowWidth) / 2 + CGFloat(col) * (cell.width + m)
                let top = top0 + CGFloat(row) * (cell.height + m)
                item.view?.frame = NSRect(x: x, y: top + GridView.barHeight, width: cell.width, height: cell.height - GridView.barHeight)
                if let pill = pills[block], let view = item.view {
                    pill.frame = NSRect(x: x, y: top, width: cell.width, height: GridView.barHeight)
                    document.addSubview(pill, positioned: .above, relativeTo: view)
                }
                y = max(y, top + cell.height + m)
            }
        }
        document.frame = NSRect(x: 0, y: 0, width: width, height: max(y, scroll.contentSize.height))
    }

    /// The overview's cards (§3.6), as Mission Control fits windows to the
    /// screen: as many columns as give the cards the most of the room with
    /// all of them in it at once, each the same, from about square to
    /// twice as wide as tall; so many that they'd be small, and they keep
    /// a least size and the room scrolls.
    static func overviewGrid(count: Int, in room: NSSize, margin m: CGFloat) -> (columns: Int, cell: NSSize) {
        guard count > 0, room.width > 0, room.height > 0 else { return (1, NSSize(width: cellWidth, height: cellHeight)) }
        let widest: CGFloat = 2, narrowest: CGFloat = 1.1
        var best = (columns: 1, cell: NSSize.zero)
        for columns in 1...count {
            let rows = (count + columns - 1) / columns
            let w = (room.width - CGFloat(columns + 1) * m) / CGFloat(columns)
            let h = (room.height - CGFloat(rows + 1) * m) / CGFloat(rows)
            guard w > 0, h > 0 else { continue }
            let cw = min(w, h * widest), ch = min(h, cw / narrowest)
            if cw * ch > best.cell.width * best.cell.height { best = (columns, NSSize(width: cw.rounded(.down), height: ch.rounded(.down))) }
        }
        let least = NSSize(width: 240, height: 180)
        guard best.cell.width < least.width else { return best }
        let columns = max(1, Int((room.width - m) / (least.width + m)))
        return (columns, NSSize(width: ((room.width - CGFloat(columns + 1) * m) / CGFloat(columns)).rounded(.down), height: least.height))
    }

    @objc private func modeChosen() {
        mode = Mode(rawValue: modes.selectedSegment) ?? .list
        needsLayout = true
        onModeChanged?(mode)
    }

    @objc private func leaveClicked() { onLeave?() }

    override var acceptsFirstResponder: Bool { true }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { onLeave?() } else { super.keyDown(with: event) }
    }

}
