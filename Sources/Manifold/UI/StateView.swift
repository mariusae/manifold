import AppKit
import ManifoldCore

/// A state view (DESIGN.md §3.6): a status group's blocks themselves, live,
/// in the surface — as a **list**, stacked down one scrolling column as
/// Prism's column of notes is, each under its pill; or an **overview**,
/// all of them in one grid at once, as Mission Control lays out windows.
/// Nothing is placed; a block clicked is gone to, ⌘-clicked brought to
/// the arrangement last shown.
final class StateView: NSView {
    enum Mode: Int { case list, overview }

    struct Item {
        var shown: Shown
        var view: PaneContent
    }

    var onGoTo: ((BlockID) -> Void)?
    var onBring: ((BlockID) -> Void)?
    var onLeave: (() -> Void)?
    var onModeChanged: ((Mode) -> Void)?

    private let header = NSView()
    private let title = NSTextField(labelWithString: "")
    private let count = NSTextField(labelWithString: "")
    private let modes = FlatSegments(symbols: ["list.bullet", "square.grid.2x2"])
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
        modes.selectedSegment = 0
        modes.onChange = { [weak self] _ in self?.modeChosen() }
        leave.target = self
        leave.action = #selector(leaveClicked)
        leave.toolTip = "Back to the Workspace (⎋)"
        for v in [title, count, modes, leave] { header.addSubview(v) }
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.documentView = document
        scroll.contentView.drawsBackground = false
        addSubview(scroll)
    }

    required init?(coder: NSCoder) { fatalError() }

    var views: [PaneContent] { items.map(\.view) }

    func show(_ items: [Item], title: String, mode: Mode) {
        let incoming = Set(items.map(\.shown.placement.block))
        for v in views where !incoming.contains(v.block) && v.superview === document { v.removeFromSuperview() }
        for (id, p) in pills where !incoming.contains(id) {
            p.removeFromSuperview()
            pills.removeValue(forKey: id)
        }
        self.items = items
        self.mode = mode
        modes.selectedSegment = mode.rawValue
        self.title.stringValue = title
        count.stringValue = items.isEmpty ? "nothing here" : "\(items.count) block\(items.count == 1 ? "" : "s")"
        for item in items {
            if item.view.superview !== document {
                GridView.styleBody(item.view)
                document.addSubview(item.view)
            }
            let block = item.shown.placement.block
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
        scroll.frame = NSRect(x: 0, y: 0, width: bounds.width, height: bounds.height - Self.headerHeight)
        let width = scroll.contentSize.width
        let m = Self.margin
        var y: CGFloat = m
        switch mode {
        case .list:
            for item in items {
                let block = item.shown.placement.block
                // A card as the grid lays one out: the bar at the top, the content beneath.
                item.view.frame = NSRect(x: m, y: y + GridView.barHeight, width: width - 2 * m, height: Self.listHeight - GridView.barHeight)
                if let pill = pills[block] {
                    pill.frame = NSRect(x: m, y: y, width: width - 2 * m, height: GridView.barHeight)
                    document.addSubview(pill, positioned: .above, relativeTo: item.view)
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
                item.view.frame = NSRect(x: x, y: top + GridView.barHeight, width: cell.width, height: cell.height - GridView.barHeight)
                if let pill = pills[block] {
                    pill.frame = NSRect(x: x, y: top, width: cell.width, height: GridView.barHeight)
                    document.addSubview(pill, positioned: .above, relativeTo: item.view)
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
