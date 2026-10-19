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
    private let modes = NSSegmentedControl(labels: ["List", "Overview"], trackingMode: .selectOne, target: nil, action: nil)
    private let leave = IconButton(symbol: "xmark", size: 12, weight: .medium, target: nil, action: nil)
    private let scroll = NSScrollView()
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
        wantsLayer = true
        themed { $0.layer?.backgroundColor = Theme.divider.cgColor }
        header.wantsLayer = true
        header.themed { $0.layer?.backgroundColor = Theme.windowBackground.cgColor }
        addSubview(header)
        title.font = .systemFont(ofSize: 15, weight: .semibold)
        title.textColor = Theme.text
        count.font = .systemFont(ofSize: 12)
        count.textColor = Theme.secondaryText
        modes.segmentStyle = .capsule
        modes.controlSize = .small
        modes.font = .systemFont(ofSize: 11)
        modes.selectedSegment = 0
        modes.target = self
        modes.action = #selector(modeChosen)
        leave.target = self
        leave.action = #selector(leaveClicked)
        leave.toolTip = "Back to the Arrangement (⎋)"
        for v in [title, count, modes, leave] { header.addSubview(v) }
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.scrollerStyle = .overlay
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
            if item.view.superview !== document { document.addSubview(item.view) }
            let block = item.shown.placement.block
            let pill = pills[block] ?? {
                let p = TilePill()
                pills[block] = p
                document.addSubview(p)
                return p
            }()
            pill.show(item.shown, focused: false)
            pill.onClick = { [weak self] in
                if NSApp.currentEvent?.modifierFlags.contains(.command) == true { self?.onBring?(block) } else { self?.onGoTo?(block) }
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
        modes.frame = NSRect(x: leave.frame.minX - 12 - 150, y: (h - 22) / 2, width: 150, height: 22)
        scroll.frame = NSRect(x: 0, y: 0, width: bounds.width, height: bounds.height - Self.headerHeight)
        let width = scroll.contentSize.width
        let m = Self.margin
        var y: CGFloat = m
        switch mode {
        case .list:
            for item in items {
                let block = item.shown.placement.block
                item.view.frame = NSRect(x: m, y: y, width: width - 2 * m, height: Self.listHeight)
                if let pill = pills[block] {
                    pill.frame = NSRect(x: m, y: y, width: width - 2 * m, height: GridView.band)
                    document.addSubview(pill, positioned: .above, relativeTo: item.view)
                }
                y += Self.listHeight + m
            }
        case .overview:
            let columns = max(1, Int((width - m) / (Self.cellWidth + m)))
            let cw = (width - m - CGFloat(columns) * m) / CGFloat(columns)
            for (i, item) in items.enumerated() {
                let block = item.shown.placement.block
                let x = m + CGFloat(i % columns) * (cw + m)
                let top = m + CGFloat(i / columns) * (Self.cellHeight + m)
                item.view.frame = NSRect(x: x, y: top, width: cw, height: Self.cellHeight)
                if let pill = pills[block] {
                    pill.frame = NSRect(x: x, y: top, width: cw, height: GridView.band)
                    document.addSubview(pill, positioned: .above, relativeTo: item.view)
                }
                y = max(y, top + Self.cellHeight + m)
            }
        }
        document.frame = NSRect(x: 0, y: 0, width: width, height: max(y, scroll.contentSize.height))
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

    override func draw(_ dirtyRect: NSRect) {
        Theme.divider.setFill()
        bounds.fill()
    }
}
