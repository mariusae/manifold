import AppKit
import ManifoldCore

protocol ColumnsDelegate: AnyObject {
    /// Whether a dragged arrangement may be dropped into the shown one.
    func contentCanDrop(_ arrangement: BlockID) -> Bool
    func contentDrop(_ arrangement: BlockID, on target: ColumnsView.DropTarget)
    func contentResized(_ fractions: [Double])
    /// A column's block was dropped somewhere.
    func contentMovePane(_ placement: PlacementID, to target: ColumnsView.DropTarget)
    /// A block from the sidebar was dropped somewhere: shown there.
    func contentShowBlock(_ block: BlockID, at target: ColumnsView.DropTarget)
    /// A block is being dragged, or has stopped being.
    func contentPaneDragChanged(_ dragging: Bool)
    /// Something is being dragged along the window's left edge.
    func contentDragAtLeftEdge()
}

/// The surface (DESIGN.md §3.1): an arrangement's columns side by side,
/// each showing one block. Nothing of a column's past is drawn.
final class ColumnsView: NSView, NSDraggingSource {
    struct Column {
        /// The placement shown.
        var id: PlacementID
        var view: PaneContent
    }

    enum DropTarget: Equatable {
        /// A new column at this index.
        case column(Int)
        /// Into this column: shown there, what it showed joining its past.
        case into(Int)
    }

    weak var delegate: ColumnsDelegate?
    private(set) var columns: [Column] = []
    var views: [PaneContent] { columns.map(\.view) }
    private var fractions: [Double] = []
    private var focused: PlacementID?
    private var dividers: [DividerView] = []
    private var bands: [GrabBandView] = []
    private let focusBar = NSView()
    private let dropOverlay = DropOverlayView()
    private var dropTarget: DropTarget?

    static let dividerWidth: CGFloat = 1
    /// The band at the top of a column that its block is dragged by.
    static let grabBand: CGFloat = 6
    static let cornerRadius: CGFloat = 5

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        themed { $0.layer?.backgroundColor = Theme.windowBackground.cgColor }
        focusBar.wantsLayer = true
        focusBar.layer?.backgroundColor = Theme.accent.cgColor
        dropOverlay.isHidden = true
        registerForDraggedTypes([.manifoldArrangement, .manifoldPlacement, .manifoldBlock])
    }

    required init?(coder: NSCoder) { fatalError() }

    func show(_ columns: [Column], fractions: [Double], focused: PlacementID?) {
        let views = columns.map(\.view)
        if views.map(ObjectIdentifier.init) != self.views.map(ObjectIdentifier.init) {
            // (Only those still here: one may have gone on to another
            // arrangement shown beside this one, sliding in.)
            for v in self.views where !views.contains(where: { $0 === v }) && v.superview === self {
                v.removeFromSuperview()
            }
            dividers.forEach { $0.removeFromSuperview() }
            dividers = (0..<max(0, views.count - 1)).map { i in
                let d = DividerView()
                d.onDrag = { [weak self] x in self?.dragDivider(i, to: x) }
                d.onEnd = { [weak self] in self?.dividerDragEnded() }
                return d
            }
            dividers.forEach { addSubview($0) }
        }
        for v in views where v.superview !== self { addSubview(v, positioned: .below, relativeTo: dividers.first) }
        self.columns = columns
        self.fractions = fractions.count == columns.count
            ? fractions : Array(repeating: 1 / Double(max(columns.count, 1)), count: columns.count)
        self.focused = focused

        bands.forEach { $0.removeFromSuperview() }
        bands = columns.indices.map { i in
            let band = GrabBandView()
            band.onDragStart = { [weak self, weak band] event in
                guard let self, let band, i < self.columns.count else { return }
                self.beginDrag(of: self.columns[i].id, event: event, from: band)
            }
            addSubview(band)
            return band
        }
        addSubview(focusBar)
        addSubview(dropOverlay)
        needsLayout = true
        needsDisplay = true
    }

    func clear() {
        for v in views { v.removeFromSuperview() }
        show([], fractions: [], focused: nil)
    }

    /// Where a column is, in this view's coordinates.
    func frame(ofColumn i: Int) -> NSRect? {
        i < columns.count ? columnFrames()[i] : nil
    }

    /// A placement's view, if on screen.
    func view(of placement: PlacementID) -> PaneContent? {
        views.first { $0.placement == placement }
    }

    private func columnFrames() -> [NSRect] {
        let n = columns.count
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
        let frames = columnFrames()
        for (i, f) in frames.enumerated() {
            let view = columns[i].view
            view.frame = f
            if let layer = view.layer {
                layer.cornerRadius = 0
                layer.masksToBounds = false
            }
        }
        for (i, d) in dividers.enumerated() {
            d.frame = NSRect(x: frames[i].maxX - 3, y: 0, width: Self.dividerWidth + 6, height: bounds.height)
        }
        for (i, band) in bands.enumerated() where i < frames.count {
            let f = frames[i]
            band.frame = NSRect(x: f.minX, y: f.maxY - Self.grabBand, width: f.width, height: Self.grabBand)
        }
        if columns.count > 1, let i = columns.firstIndex(where: { $0.id == focused }) {
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
        for f in columnFrames().dropLast() {
            NSRect(x: f.maxX, y: 0, width: Self.dividerWidth, height: bounds.height).fill()
        }
    }

    // MARK: Dragging a column's block

    private func beginDrag(of placement: PlacementID, event: NSEvent, from view: NSView) {
        let item = NSPasteboardItem()
        item.setString(placement, forType: .manifoldPlacement)
        let dragItem = NSDraggingItem(pasteboardWriter: item)
        let image = BlockDragImage.make(for: paneInfo(placement))
        let p = view.convert(event.locationInWindow, from: nil)
        dragItem.setDraggingFrame(NSRect(x: p.x - 24, y: p.y - image.size.height / 2, width: image.size.width,
                                         height: image.size.height), contents: image)
        delegate?.contentPaneDragChanged(true)
        view.beginDraggingSession(with: [dragItem], event: event, source: self)
    }

    /// What's known of a placement shown here, for its drag image.
    var paneInfo: (PlacementID) -> Shown? = { _ in nil }

    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        context == .withinApplication ? .move : []
    }

    func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
        delegate?.contentPaneDragChanged(false)
    }

    // MARK: Resizing

    private func dragDivider(_ i: Int, to x: CGFloat) {
        let frames = columnFrames()
        let minWidth: CGFloat = 120
        let left = frames[i].minX, right = frames[i + 1].maxX
        let split = min(max(x, left + minWidth), right - minWidth)
        let usable = bounds.width - CGFloat(columns.count - 1) * Self.dividerWidth
        let pair = fractions[i] + fractions[i + 1]
        fractions[i] = (split - left) / usable
        fractions[i + 1] = pair - fractions[i]
        needsLayout = true
        needsDisplay = true
    }

    private func dividerDragEnded() { delegate?.contentResized(fractions) }

    // MARK: Dropping

    /// The outer part of a column on either side makes a new column there;
    /// its middle shows the block in it.
    private func dropTarget(at point: NSPoint) -> (DropTarget, NSRect)? {
        let frames = columnFrames()
        guard !frames.isEmpty else { return (.column(0), bounds) }
        for (i, f) in frames.enumerated() where point.x >= f.minX && point.x <= f.maxX + Self.dividerWidth {
            let edge = f.width * 0.3
            if point.x < f.minX + edge {
                return (.column(i), NSRect(x: f.minX, y: f.minY, width: f.width / 2, height: f.height))
            }
            if point.x > f.maxX - edge {
                return (.column(i + 1), NSRect(x: f.midX, y: f.minY, width: f.width / 2, height: f.height))
            }
            return (.into(i), f)
        }
        return nil
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation { draggingUpdated(sender) }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        let point = convert(sender.draggingLocation, from: nil)
        // The sidebar can't be hovered open mid-drag; the window's edge does it.
        if convert(point, to: nil).x < 8 { delegate?.contentDragAtLeftEdge() }
        let pb = sender.draggingPasteboard
        let isPane = pb.string(forType: .manifoldPlacement) != nil || pb.string(forType: .manifoldBlock) != nil
        let tab = pb.string(forType: .manifoldArrangement).flatMap(BlockID.init(string:))
        guard isPane || (tab != nil && delegate?.contentCanDrop(tab!) == true),
              let (target, rect) = dropTarget(at: point) else {
            hideDrop()
            return []
        }
        if dropTarget != target || dropOverlay.isHidden {
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = dropOverlay.isHidden ? 0 : 0.12
                dropOverlay.animator().frame = rect
            }
            dropOverlay.isHidden = false
        }
        dropTarget = target
        return .move
    }

    override func draggingExited(_ sender: NSDraggingInfo?) { hideDrop() }

    override func draggingEnded(_ sender: NSDraggingInfo) { hideDrop() }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        defer { hideDrop() }
        guard let target = dropTarget else { return false }
        let pb = sender.draggingPasteboard
        if let pane = pb.string(forType: .manifoldPlacement) {
            delegate?.contentMovePane(pane, to: target)
            return true
        }
        if pb.string(forType: .manifoldArrangement) == nil, let block = pb.string(forType: .manifoldBlock).flatMap(BlockID.init(string:)) {
            delegate?.contentShowBlock(block, at: target)
            return true
        }
        guard let tab = pb.string(forType: .manifoldArrangement).flatMap(BlockID.init(string:)) else { return false }
        delegate?.contentDrop(tab, on: target)
        return true
    }

    private func hideDrop() {
        dropOverlay.isHidden = true
        dropTarget = nil
    }
}

/// Where a dragged block would land: half a column, for a new column; the
/// whole column, to be shown in it.
final class DropOverlayView: NSView {
    override func draw(_ dirtyRect: NSRect) {
        Theme.dropHighlight.setFill()
        bounds.fill()
        Theme.accent.withAlphaComponent(0.5).setStroke()
        NSBezierPath(rect: bounds.insetBy(dx: 0.5, dy: 0.5)).stroke()
    }
}

/// The thin band along the top of a column that its block is dragged by.
final class GrabBandView: NSView {
    var onDragStart: ((NSEvent) -> Void)?
    private var downAt: NSPoint?

    override func resetCursorRects() { addCursorRect(bounds, cursor: .openHand) }

    override func mouseDown(with event: NSEvent) { downAt = event.locationInWindow }

    override func mouseDragged(with event: NSEvent) {
        guard let start = downAt else { return }
        let p = event.locationInWindow
        if hypot(p.x - start.x, p.y - start.y) > 4 {
            downAt = nil
            onDragStart?(event)
        }
    }

    override func mouseUp(with event: NSEvent) { downAt = nil }
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
            let path = NSBezierPath(roundedRect: card, xRadius: ColumnsView.cornerRadius, yRadius: ColumnsView.cornerRadius)
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
