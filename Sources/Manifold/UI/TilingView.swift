import AppKit
import ManifoldCore

protocol TilingDelegate: AnyObject {
    func tilingFocus(_ placement: PlacementID)
    func tilingMove(_ placement: PlacementID, column: Int, at: Int, newColumn: Bool)
    func tilingDropArrangement(_ arrangement: BlockID, column: Int)
    func tilingCanDrop(_ arrangement: BlockID) -> Bool
    func tilingResized(fractions: [Double])
    func tilingResized(heights: [PlacementID: Double])
    func tilingDragChanged(_ dragging: Bool)
    func tilingDragAtLeftEdge()
}

/// The tiling lens: every placement visible, the columns side by side and
/// each column's placements top to bottom, as acme tiles its windows. Each
/// has a thin title bar to grab it by; the lines between them resize.
final class TilingView: NSView, NSDraggingSource {
    struct Tile {
        var shown: Shown
        var view: PaneContent
    }

    weak var delegate: TilingDelegate?
    private(set) var columns: [[Tile]] = []
    private var fractions: [Double] = []
    private var heights: [PlacementID: Double] = [:]
    private var focused: PlacementID?
    private var headers: [PlacementID: TileHeader] = [:]
    private var columnDividers: [DividerView] = []
    private var rowDividers: [RowDividerView] = []
    private let dropOverlay = DropOverlayView()
    private var drop: (column: Int, at: Int, rect: NSRect, newColumn: Bool)?

    static let headerHeight: CGFloat = 22
    static let gap: CGFloat = 1

    var views: [PaneContent] { columns.flatMap { $0.map(\.view) } }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        themed { $0.layer?.backgroundColor = Theme.divider.cgColor }
        dropOverlay.isHidden = true
        registerForDraggedTypes([.manifoldArrangement, .manifoldPlacement])
    }

    required init?(coder: NSCoder) { fatalError() }

    func show(_ columns: [[Tile]], fractions: [Double], heights: [PlacementID: Double], focused: PlacementID?) {
        let incoming = Set(columns.flatMap { $0.map(\.shown.id) })
        for v in views where !incoming.contains(v.placement) && v.superview === self { v.removeFromSuperview() }
        for (id, h) in headers where !incoming.contains(id) {
            h.removeFromSuperview()
            headers.removeValue(forKey: id)
        }
        self.columns = columns
        self.fractions = fractions.count == columns.count ? fractions : Array(repeating: 1 / Double(max(columns.count, 1)), count: columns.count)
        self.heights = heights
        self.focused = focused
        for column in columns {
            for tile in column {
                if tile.view.superview !== self { addSubview(tile.view) }
                let header = headers[tile.shown.id] ?? {
                    let h = TileHeader()
                    headers[tile.shown.id] = h
                    addSubview(h)
                    return h
                }()
                header.configure(tile.shown, focused: tile.shown.id == focused)
                let id = tile.shown.id
                header.onClick = { [weak self] in self?.delegate?.tilingFocus(id) }
                header.onDragStart = { [weak self, weak header] event in
                    guard let self, let header else { return }
                    self.beginDrag(of: id, event: event, from: header)
                }
            }
        }
        columnDividers.forEach { $0.removeFromSuperview() }
        columnDividers = (0..<max(0, columns.count - 1)).map { i in
            let d = DividerView()
            d.onDrag = { [weak self] x in self?.dragColumnDivider(i, to: x) }
            d.onEnd = { [weak self] in self?.delegate?.tilingResized(fractions: self?.fractions ?? []) }
            addSubview(d)
            return d
        }
        rowDividers.forEach { $0.removeFromSuperview() }
        rowDividers = []
        for (c, column) in columns.enumerated() where column.count > 1 {
            for r in 0..<(column.count - 1) {
                let d = RowDividerView()
                d.onDrag = { [weak self] y in self?.dragRowDivider(column: c, row: r, to: y) }
                d.onEnd = { [weak self] in self?.delegate?.tilingResized(heights: self?.heights ?? [:]) }
                addSubview(d)
                rowDividers.append(d)
            }
        }
        addSubview(dropOverlay)
        needsLayout = true
    }

    // MARK: Geometry

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

    /// Each tile's frame in a column, header included, top to bottom.
    private func tileFrames(column c: Int, in f: NSRect) -> [NSRect] {
        let tiles = columns[c]
        guard !tiles.isEmpty else { return [] }
        let shares = tiles.map { heights[$0.shown.id] ?? 1 / Double(tiles.count) }
        let sum = shares.reduce(0, +)
        let usable = f.height - CGFloat(tiles.count - 1) * Self.gap
        var y = f.maxY
        var out: [NSRect] = []
        for (i, share) in shares.enumerated() {
            let h = i == tiles.count - 1 ? y - f.minY : (usable * CGFloat(share / sum)).rounded()
            out.append(NSRect(x: f.minX, y: y - h, width: f.width, height: h))
            y -= h + Self.gap
        }
        return out
    }

    override func layout() {
        super.layout()
        let frames = columnFrames()
        var rowIndex = 0
        for (c, f) in frames.enumerated() {
            let tiles = tileFrames(column: c, in: f)
            for (i, tile) in columns[c].enumerated() {
                let r = tiles[i]
                headers[tile.shown.id]?.frame = NSRect(x: r.minX, y: r.maxY - Self.headerHeight, width: r.width, height: Self.headerHeight)
                tile.view.frame = NSRect(x: r.minX, y: r.minY, width: r.width, height: max(0, r.height - Self.headerHeight))
                if i > 0, rowIndex < rowDividers.count {
                    rowDividers[rowIndex].frame = NSRect(x: r.minX, y: r.maxY - 2, width: r.width, height: Self.gap + 4)
                    rowIndex += 1
                }
            }
        }
        for (i, d) in columnDividers.enumerated() {
            d.frame = NSRect(x: frames[i].maxX - 3, y: 0, width: Self.gap + 6, height: bounds.height)
        }
    }

    /// Where a tile is, for the switcher and the like.
    func frame(of placement: PlacementID) -> NSRect? {
        views.first { $0.placement == placement }?.frame
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

    private func dragRowDivider(column c: Int, row r: Int, to y: CGFloat) {
        let f = columnFrames()[c]
        let frames = tileFrames(column: c, in: f)
        let minHeight = Self.headerHeight + 40
        let top = frames[r].maxY, bottom = frames[r + 1].minY
        let split = min(max(y, bottom + minHeight), top - minHeight)
        let tiles = columns[c]
        let a = tiles[r].shown.id, b = tiles[r + 1].shown.id
        let ha = heights[a] ?? 1 / Double(tiles.count), hb = heights[b] ?? 1 / Double(tiles.count)
        let pair = ha + hb
        let total = (top - bottom)
        heights[a] = pair * Double((top - split) / total)
        heights[b] = pair - heights[a]!
        needsLayout = true
    }

    // MARK: Dragging tiles

    private func beginDrag(of placement: PlacementID, event: NSEvent, from view: NSView) {
        let item = NSPasteboardItem()
        item.setString(placement, forType: .manifoldPlacement)
        let dragItem = NSDraggingItem(pasteboardWriter: item)
        let shown = columns.flatMap { $0 }.first { $0.shown.id == placement }?.shown
        let image = SheetDragImage.make(for: shown)
        let p = view.convert(event.locationInWindow, from: nil)
        dragItem.setDraggingFrame(NSRect(x: p.x - 24, y: p.y - image.size.height / 2, width: image.size.width,
                                         height: image.size.height), contents: image)
        delegate?.tilingDragChanged(true)
        view.beginDraggingSession(with: [dragItem], event: event, source: self)
    }

    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        context == .withinApplication ? .move : []
    }

    func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
        delegate?.tilingDragChanged(false)
    }

    /// Near a column's side: a new column there. Else between two tiles (or
    /// above the first, below the last) of the column under the pointer.
    private func dropTarget(at point: NSPoint) -> (column: Int, at: Int, rect: NSRect, newColumn: Bool)? {
        let frames = columnFrames()
        guard !frames.isEmpty else { return (0, 0, bounds, true) }
        for (c, f) in frames.enumerated() where point.x >= f.minX && point.x <= f.maxX + Self.gap {
            let edge = min(f.width * 0.2, 80)
            if point.x < f.minX + edge {
                return (c, 0, NSRect(x: f.minX, y: f.minY, width: f.width / 2, height: f.height), true)
            }
            if point.x > f.maxX - edge {
                return (c + 1, 0, NSRect(x: f.midX, y: f.minY, width: f.width / 2, height: f.height), true)
            }
            let tiles = tileFrames(column: c, in: f)
            for (i, r) in tiles.enumerated() where point.y >= r.minY && point.y <= r.maxY {
                if point.y > r.midY {
                    return (c, i, NSRect(x: r.minX, y: r.midY, width: r.width, height: r.height / 2), false)
                }
                return (c, i + 1, NSRect(x: r.minX, y: r.minY, width: r.width, height: r.height / 2), false)
            }
            return (c, tiles.count, f, false)
        }
        return nil
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation { draggingUpdated(sender) }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        let point = convert(sender.draggingLocation, from: nil)
        if convert(point, to: nil).x < 8 { delegate?.tilingDragAtLeftEdge() }
        let pb = sender.draggingPasteboard
        let isPlacement = pb.string(forType: .manifoldPlacement) != nil
        let arrangement = pb.string(forType: .manifoldArrangement).flatMap(BlockID.init(string:))
        guard isPlacement || (arrangement != nil && delegate?.tilingCanDrop(arrangement!) == true),
              let target = dropTarget(at: point) else {
            hideDrop()
            return []
        }
        if drop?.rect != target.rect || dropOverlay.isHidden {
            dropOverlay.stacking = false
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = dropOverlay.isHidden ? 0 : 0.12
                dropOverlay.animator().frame = target.rect
            }
            dropOverlay.isHidden = false
        }
        drop = target
        return .move
    }

    override func draggingExited(_ sender: NSDraggingInfo?) { hideDrop() }
    override func draggingEnded(_ sender: NSDraggingInfo) { hideDrop() }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        defer { hideDrop() }
        guard let target = drop else { return false }
        let pb = sender.draggingPasteboard
        if let placement = pb.string(forType: .manifoldPlacement) {
            delegate?.tilingMove(placement, column: target.column, at: target.at, newColumn: target.newColumn)
            return true
        }
        guard let arrangement = pb.string(forType: .manifoldArrangement).flatMap(BlockID.init(string:)) else { return false }
        delegate?.tilingDropArrangement(arrangement, column: target.newColumn ? target.column : target.column + 1)
        return true
    }

    private func hideDrop() {
        dropOverlay.isHidden = true
        drop = nil
    }

    /// The column index a new-column drop at `column` means: past the end
    /// when it's to the right of the last.
    static func insertionColumn(_ target: Int, of count: Int) -> Int { min(target, count) }

    override func draw(_ dirtyRect: NSRect) {
        Theme.divider.setFill()
        bounds.fill()
    }
}

/// A tile's title bar: its icon and title; drag it to move the tile.
final class TileHeader: NSView {
    var onClick: (() -> Void)?
    var onDragStart: ((NSEvent) -> Void)?
    private let icon = NSImageView()
    private let title = NSTextField(labelWithString: "")
    private let dot = NSView()
    private var downAt: NSPoint?
    private var focused = false

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        icon.contentTintColor = Theme.secondaryText
        title.font = .systemFont(ofSize: 11.5, weight: .medium)
        title.textColor = Theme.text
        title.lineBreakMode = .byTruncatingTail
        dot.wantsLayer = true
        dot.layer?.cornerRadius = 3
        dot.themed { $0.layer?.backgroundColor = Theme.secondaryText.cgColor }
        dot.isHidden = true
        for v in [icon, title, dot] { addSubview(v) }
        themed { $0.updateColors() }
    }

    required init?(coder: NSCoder) { fatalError() }

    func configure(_ shown: Shown, focused: Bool) {
        icon.image = Theme.symbol(shown.symbol, size: 11)
        title.stringValue = shown.title + (shown.isDormant ? "  (dormant)" : "")
        dot.isHidden = !shown.isDirty
        self.focused = focused
        updateColors()
        needsLayout = true
    }

    private func updateColors() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.backgroundColor = (focused ? Theme.switcherHeader : Theme.sheet(level: 0)).cgColor
        }
        title.font = .systemFont(ofSize: 11.5, weight: focused ? .semibold : .medium)
    }

    override func layout() {
        super.layout()
        let h = bounds.height
        icon.frame = NSRect(x: 8, y: (h - 14) / 2, width: 16, height: 14)
        title.sizeToFit()
        let tw = min(title.frame.width, bounds.width - 50)
        title.frame = NSRect(x: 28, y: ((h - title.frame.height) / 2).rounded(), width: tw, height: title.frame.height)
        dot.frame = NSRect(x: 28 + tw + 8, y: (h - 6) / 2, width: 6, height: 6)
    }

    override func resetCursorRects() { addCursorRect(bounds, cursor: .openHand) }

    override func mouseDown(with event: NSEvent) { downAt = event.locationInWindow }

    override func mouseDragged(with event: NSEvent) {
        guard let start = downAt else { return }
        let p = event.locationInWindow
        guard hypot(p.x - start.x, p.y - start.y) > 4 else { return }
        downAt = nil
        onDragStart?(event)
    }

    override func mouseUp(with event: NSEvent) {
        if downAt != nil { onClick?() }
        downAt = nil
    }

    override func draw(_ dirtyRect: NSRect) {
        Theme.divider.setFill()
        NSRect(x: 0, y: 0, width: bounds.width, height: 0.5).fill()
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
