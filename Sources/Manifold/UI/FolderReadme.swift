import AppKit
import ManifoldCore

/// A folder's README under its listing (§7.4), as GitHub shows one: its
/// name on a bar, the page rendered below it. A click on the bar collapses
/// it to the bar alone (and opens it again); dragged, the bar sets how
/// much of the tile the page takes.
final class FolderReadme: NSView {
    static let barHeight: CGFloat = 30
    private let bar = Bar()
    private let chevron = NSImageView()
    private let icon = NSImageView()
    private let title = NSTextField(labelWithString: "")
    private(set) var page: MarkdownView?
    /// The bar clicked.
    var onToggle: (() -> Void)?
    /// The bar dragged: the panel's height asked for, and when the drag's
    /// done (to keep).
    var onResize: ((CGFloat, _ done: Bool) -> Void)?

    var collapsed = false { didSet { apply() } }

    /// The bar as `collapsed` has it (set in init too, where didSet isn't called).
    private func apply() {
        do {
            chevron.image = Theme.symbol(collapsed ? "chevron.right" : "chevron.down", size: 10, weight: .semibold)
            page?.isHidden = collapsed
            bar.resizes = !collapsed
            window?.invalidateCursorRects(for: bar)
            bar.toolTip = collapsed ? "Show the README" : "Hide the README (drag to resize)"
            needsLayout = true
        }
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        themed { $0.layer?.backgroundColor = Theme.windowBackground.cgColor }
        chevron.contentTintColor = Theme.secondaryText
        icon.image = Theme.symbol("doc.text", size: 12, weight: .regular)
        icon.contentTintColor = Theme.secondaryText
        title.font = UIType.label
        title.textColor = Theme.text
        title.lineBreakMode = .byTruncatingMiddle
        for v in [chevron, icon, title] { bar.addSubview(v) }
        addSubview(bar)
        bar.onClick = { [weak self] in self?.onToggle?() }
        bar.onDrag = { [weak self] dy, done in
            guard let self else { return }
            self.onResize?(self.frame.height + dy, done)
        }
        apply()
    }

    required init?(coder: NSCoder) { fatalError() }

    /// The README's name, and its page (made once, by the tile).
    func show(name: String, page make: () -> MarkdownView?) {
        title.stringValue = name
        if page == nil, let p = make() {
            addSubview(p)
            page = p
            p.isHidden = collapsed
        }
        needsLayout = true
    }

    override func layout() {
        super.layout()
        let w = bounds.width, h = bounds.height
        bar.frame = NSRect(x: 0, y: h - Self.barHeight, width: w, height: Self.barHeight)
        // A hairline over the bar, between it and the listing.
        bar.topLine.frame = NSRect(x: 0, y: Self.barHeight - 1, width: w, height: 1)
        chevron.frame = NSRect(x: 10, y: (Self.barHeight - 14) / 2, width: 14, height: 14)
        icon.frame = NSRect(x: chevron.frame.maxX + 4, y: (Self.barHeight - 16) / 2, width: 16, height: 16)
        title.sizeToFit()
        title.frame = NSRect(x: icon.frame.maxX + 6, y: ((Self.barHeight - title.frame.height) / 2).rounded(),
                             width: max(0, w - icon.frame.maxX - 18), height: title.frame.height)
        page?.frame = NSRect(x: 0, y: 0, width: w, height: max(0, h - Self.barHeight))
    }

    /// The bar: clicked, it toggles; dragged (open), it resizes.
    private final class Bar: NSView {
        var onClick: (() -> Void)?
        var onDrag: ((CGFloat, Bool) -> Void)?
        var resizes = true
        let topLine = NSView()
        private var start: NSPoint?
        private var dragged = false

        override init(frame: NSRect) {
            super.init(frame: frame)
            topLine.wantsLayer = true
            topLine.themed { $0.layer?.backgroundColor = Theme.divider.cgColor }
            addSubview(topLine)
        }

        required init?(coder: NSCoder) { fatalError() }

        override func resetCursorRects() {
            if resizes { addCursorRect(bounds, cursor: .resizeUpDown) }
        }

        override func mouseDown(with event: NSEvent) {
            start = event.locationInWindow
            dragged = false
        }

        override func mouseDragged(with event: NSEvent) {
            guard resizes, let s = start else { return }
            let dy = event.locationInWindow.y - s.y
            guard dragged || abs(dy) > 3 else { return }
            dragged = true
            start = event.locationInWindow
            onDrag?(dy, false)
        }

        override func mouseUp(with event: NSEvent) {
            if dragged { onDrag?(0, true) } else { onClick?() }
            start = nil
            dragged = false
        }
    }
}
