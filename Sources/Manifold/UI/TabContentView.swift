import AppKit

protocol TabContentDelegate: AnyObject {
    /// Whether a dragged tab may be dropped into the shown tab.
    func contentCanDrop(_ tab: UUID) -> Bool
    /// A tab was dropped to become pane `index` of the shown tab.
    func contentDrop(_ tab: UUID, at index: Int)
    func contentResized(_ fractions: [Double])
}

/// Shows the selected tab: its panes side by side.
final class TabContentView: NSView {
    weak var delegate: TabContentDelegate?
    private(set) var panes: [TerminalView] = []
    private var fractions: [Double] = []
    private var focused: UUID?
    private var dividers: [DividerView] = []
    private let focusBar = NSView()
    private let dropOverlay = NSView()
    private var dropIndex: Int?

    static let dividerWidth: CGFloat = 1

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = Theme.windowBackground.cgColor
        focusBar.wantsLayer = true
        focusBar.layer?.backgroundColor = Theme.accent.cgColor
        dropOverlay.wantsLayer = true
        dropOverlay.layer?.backgroundColor = Theme.dropHighlight.cgColor
        dropOverlay.layer?.borderColor = Theme.accent.withAlphaComponent(0.5).cgColor
        dropOverlay.layer?.borderWidth = 1
        dropOverlay.isHidden = true
        registerForDraggedTypes([.manifoldTab])
    }

    required init?(coder: NSCoder) { fatalError() }

    func show(_ views: [TerminalView], fractions: [Double], focused: UUID?) {
        if views.map(ObjectIdentifier.init) != panes.map(ObjectIdentifier.init) {
            for v in panes where !views.contains(where: { $0 === v }) { v.removeFromSuperview() }
            for v in views where v.superview !== self { addSubview(v) }
            panes = views
            dividers.forEach { $0.removeFromSuperview() }
            dividers = (0..<max(0, views.count - 1)).map { i in
                let d = DividerView()
                d.onDrag = { [weak self] x in self?.dragDivider(i, to: x) }
                d.onEnd = { [weak self] in self?.dividerDragEnded() }
                return d
            }
            dividers.forEach { addSubview($0) }
        }
        self.fractions = fractions.count == views.count ? fractions : Array(repeating: 1 / Double(max(views.count, 1)), count: views.count)
        self.focused = focused
        addSubview(focusBar)
        addSubview(dropOverlay)
        needsLayout = true
        needsDisplay = true
    }

    private func paneFrames() -> [NSRect] {
        let n = panes.count
        guard n > 0 else { return [] }
        let usable = bounds.width - CGFloat(n - 1) * Self.dividerWidth
        var x: CGFloat = 0
        return fractions.enumerated().map { i, f in
            let w = i == n - 1 ? bounds.width - x : (usable * f).rounded()
            defer { x += w + Self.dividerWidth }
            return NSRect(x: x, y: 0, width: w, height: bounds.height)
        }
    }

    override func layout() {
        super.layout()
        let frames = paneFrames()
        for (v, f) in zip(panes, frames) { v.frame = f }
        for (i, d) in dividers.enumerated() {
            d.frame = NSRect(x: frames[i].maxX - 3, y: 0, width: Self.dividerWidth + 6, height: bounds.height)
        }
        if panes.count > 1, let i = panes.firstIndex(where: { $0.pane == focused }) {
            focusBar.isHidden = false
            focusBar.frame = NSRect(x: frames[i].minX, y: 0, width: frames[i].width, height: 2)
        } else {
            focusBar.isHidden = true
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        Theme.windowBackground.setFill()
        bounds.fill()
        Theme.divider.setFill()
        for f in paneFrames().dropLast() {
            NSRect(x: f.maxX, y: 0, width: Self.dividerWidth, height: bounds.height).fill()
        }
    }

    // MARK: Resizing

    private func dragDivider(_ i: Int, to x: CGFloat) {
        let frames = paneFrames()
        let minWidth: CGFloat = 120
        let left = frames[i].minX, right = frames[i + 1].maxX
        let split = min(max(x, left + minWidth), right - minWidth)
        let usable = bounds.width - CGFloat(panes.count - 1) * Self.dividerWidth
        let pair = fractions[i] + fractions[i + 1]
        fractions[i] = (split - left) / usable
        fractions[i + 1] = pair - fractions[i]
        needsLayout = true
        needsDisplay = true
    }

    private func dividerDragEnded() { delegate?.contentResized(fractions) }

    // MARK: Dropping tabs

    private func dropTarget(at point: NSPoint) -> (index: Int, rect: NSRect)? {
        let frames = paneFrames()
        guard !frames.isEmpty else { return (0, bounds) }
        for (i, f) in frames.enumerated() where point.x >= f.minX && point.x <= f.maxX + Self.dividerWidth {
            let leftHalf = point.x < f.midX
            let half = NSRect(x: leftHalf ? f.minX : f.midX, y: f.minY, width: f.width / 2, height: f.height)
            return (leftHalf ? i : i + 1, half)
        }
        return nil
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation { draggingUpdated(sender) }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard let str = sender.draggingPasteboard.string(forType: .manifoldTab), let tab = UUID(uuidString: str),
              delegate?.contentCanDrop(tab) == true,
              let target = dropTarget(at: convert(sender.draggingLocation, from: nil)) else {
            hideDrop()
            return []
        }
        dropIndex = target.index
        if dropOverlay.isHidden || dropOverlay.frame != target.rect {
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = dropOverlay.isHidden ? 0 : 0.12
                dropOverlay.animator().frame = target.rect
            }
            dropOverlay.isHidden = false
        }
        return .move
    }

    override func draggingExited(_ sender: NSDraggingInfo?) { hideDrop() }

    override func draggingEnded(_ sender: NSDraggingInfo) { hideDrop() }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        defer { hideDrop() }
        guard let str = sender.draggingPasteboard.string(forType: .manifoldTab), let tab = UUID(uuidString: str),
              let index = dropIndex else { return false }
        delegate?.contentDrop(tab, at: index)
        return true
    }

    private func hideDrop() {
        dropOverlay.isHidden = true
        dropIndex = nil
    }
}

/// The grab area over the line between two panes.
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
