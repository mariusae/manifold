import AppKit
import ManifoldCore

protocol ListLensDelegate: AnyObject {
    func listFocus(_ placement: PlacementID)
    func listMove(_ placement: PlacementID, column: Int, at: Int)
    func listRemove(_ placement: PlacementID)
}

/// The list lens: one row per placement (its kind, title, where it is, and
/// its state), the arrangement's table of contents; the chosen row's block
/// shows beneath the list, live.
final class ListLensView: NSView {
    weak var delegate: ListLensDelegate?
    private let scroll = NSScrollView()
    private let list = FlippedView()
    private var rows: [ListRow] = []
    private var columns: [[Shown]] = []
    private var focused: PlacementID?
    private var shownView: PaneContent?
    private let divider = NSView()
    private static let rowHeight: CGFloat = 36
    /// The list's share of the height.
    private var split: CGFloat = 0.38

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        themed { $0.layer?.backgroundColor = Theme.windowBackground.cgColor }
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.scrollerStyle = .overlay
        scroll.documentView = list
        addSubview(scroll)
        divider.wantsLayer = true
        divider.themed { $0.layer?.backgroundColor = Theme.divider.cgColor }
        addSubview(divider)
    }

    required init?(coder: NSCoder) { fatalError() }

    var views: [PaneContent] { shownView.map { [$0] } ?? [] }

    func show(_ columns: [[Shown]], focused: PlacementID?, view: PaneContent?) {
        self.columns = columns
        self.focused = focused
        rows.forEach { $0.removeFromSuperview() }
        rows = []
        for (c, column) in columns.enumerated() {
            for (i, shown) in column.enumerated() {
                let row = ListRow(shown: shown, column: c, index: i, selected: shown.id == focused)
                row.onClick = { [weak self] in self?.delegate?.listFocus(shown.id) }
                row.onRemove = { [weak self] in self?.delegate?.listRemove(shown.id) }
                list.addSubview(row)
                rows.append(row)
            }
        }
        if let old = shownView, old !== view, old.superview === self { old.removeFromSuperview() }
        shownView = view
        if let view, view.superview !== self { addSubview(view) }
        needsLayout = true
    }

    override func layout() {
        super.layout()
        let listHeight = shownView == nil ? bounds.height : (bounds.height * split).rounded()
        scroll.frame = NSRect(x: 0, y: bounds.height - listHeight, width: bounds.width, height: listHeight)
        divider.frame = NSRect(x: 0, y: bounds.height - listHeight - 1, width: bounds.width, height: 1)
        shownView?.frame = NSRect(x: 0, y: 0, width: bounds.width, height: max(0, bounds.height - listHeight - 1))
        let width = scroll.contentSize.width
        var y: CGFloat = 8
        var lastColumn = -1
        for row in rows {
            if row.column != lastColumn, lastColumn >= 0 { y += 8 }
            lastColumn = row.column
            row.frame = NSRect(x: 12, y: y, width: width - 24, height: Self.rowHeight)
            y += Self.rowHeight + 2
        }
        list.frame = NSRect(x: 0, y: 0, width: width, height: max(y + 8, scroll.contentSize.height))
    }
}

final class ListRow: NSView {
    let column: Int
    let index: Int
    var onClick: (() -> Void)?
    var onRemove: (() -> Void)?
    private let icon = NSImageView()
    private let title = NSTextField(labelWithString: "")
    private let detail = NSTextField(labelWithString: "")
    private let state = NSTextField(labelWithString: "")
    private lazy var removeButton = IconButton(symbol: "xmark", target: self, action: #selector(removeClicked))
    private var hovering = false { didSet { updateColors() } }
    private let selected: Bool

    init(shown: Shown, column: Int, index: Int, selected: Bool) {
        self.column = column
        self.index = index
        self.selected = selected
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 8
        layer?.cornerCurve = .continuous
        icon.image = Theme.symbol(shown.symbol, size: 14)
        icon.contentTintColor = Theme.secondaryText
        title.stringValue = shown.title
        title.font = .systemFont(ofSize: 13, weight: selected ? .semibold : .regular)
        title.textColor = Theme.text
        title.lineBreakMode = .byTruncatingTail
        detail.stringValue = shown.place?.abbreviatingHome ?? ""
        detail.font = .systemFont(ofSize: 11.5)
        detail.textColor = Theme.secondaryText
        detail.lineBreakMode = .byTruncatingMiddle
        var flags: [String] = []
        if shown.isDirty { flags.append("edited") }
        if shown.isDormant { flags.append("dormant") }
        if shown.block?.terminal?.busy == true { flags.append("running") }
        state.stringValue = flags.joined(separator: " · ")
        state.font = .systemFont(ofSize: 11)
        state.textColor = Theme.secondaryText
        state.alignment = .right
        removeButton.toolTip = "Take Off This Arrangement"
        removeButton.isHidden = true
        for v in [icon, title, detail, state, removeButton] { addSubview(v) }
        themed { $0.updateColors() }
    }

    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        let h = bounds.height
        icon.frame = NSRect(x: 10, y: (h - 18) / 2, width: 18, height: 18)
        removeButton.frame = NSRect(x: bounds.width - 28, y: (h - 20) / 2, width: 20, height: 20)
        state.frame = NSRect(x: bounds.width - 160, y: (h - 15) / 2, width: 126, height: 15)
        title.frame = NSRect(x: 38, y: h / 2, width: bounds.width - 210, height: 16)
        detail.frame = NSRect(x: 38, y: h / 2 - 15, width: bounds.width - 210, height: 14)
    }

    private func updateColors() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.backgroundColor = selected ? Theme.selected.cgColor : (hovering ? Theme.hover.cgColor : NSColor.clear.cgColor)
        }
        removeButton.isHidden = !hovering
    }

    override func updateTrackingAreas() {
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
        super.updateTrackingAreas()
    }

    override func mouseEntered(with event: NSEvent) { hovering = true }
    override func mouseExited(with event: NSEvent) { hovering = false }
    override func mouseDown(with event: NSEvent) {}
    override func mouseUp(with event: NSEvent) {
        if bounds.contains(convert(event.locationInWindow, from: nil)) { onClick?() }
    }

    @objc private func removeClicked() { onRemove?() }
}
