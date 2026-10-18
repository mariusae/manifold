import AppKit
import ManifoldCore

protocol TabContentDelegate: AnyObject {
    /// Whether a dragged arrangement may be dropped into the shown one.
    func contentCanDrop(_ arrangement: BlockID) -> Bool
    func contentDrop(_ arrangement: BlockID, on target: TabContentView.DropTarget)
    func contentResized(_ fractions: [Double])
    /// A placement beneath the top of its stack was picked.
    func contentRaise(_ placement: PlacementID)
    /// A placement (a sheet) was dropped here.
    func contentMovePane(_ placement: PlacementID, to target: TabContentView.DropTarget)
    /// A placement is being dragged, or has stopped being.
    func contentPaneDragChanged(_ dragging: Bool)
    /// The neighborhood at a block's foot: what to show, if anything.
    func contentFoot(for placement: PlacementID) -> [FootBunch]
    /// A card at a foot was clicked: recall its block beside the placement.
    func contentFootOpen(_ block: BlockID, beside placement: PlacementID, newColumn: Bool)
    /// Something is being dragged along the window's left edge.
    func contentDragAtLeftEdge()
}

/// The stacks lens: an arrangement's columns side by side, each showing the
/// top of its stack, with the edges of the sheets beneath peeking out above
/// it.
final class TabContentView: NSView, NSDraggingSource {
    struct ColumnContent {
        /// The column's bottom placement, which stays with it.
        var id: PlacementID
        var view: PaneContent
        /// The placements beneath the top, nearest first.
        var beneath: [Shown]
    }

    enum DropTarget: Equatable {
        /// A new column at this index.
        case column(Int)
        /// On top of this column's stack.
        case stack(Int)
    }

    weak var delegate: TabContentDelegate?
    private(set) var columns: [ColumnContent] = []
    var panes: [PaneContent] { columns.map(\.view) }
    private var fractions: [Double] = []
    private var focused: PlacementID?
    private var dividers: [DividerView] = []
    private var strips: [StackStripView] = []
    private let focusBar = NSView()
    private let dropOverlay = DropOverlayView()
    private var dropTarget: DropTarget?
    private var stackList: StackListView?

    static let dividerWidth: CGFloat = 1
    /// Sheets shown at most, however deep the stack.
    static let maxSheets = 3
    /// How much of each sheet beneath shows above the one in front of it.
    static let sheetHeight: CGFloat = 10
    /// How far into the top card the sheets' click target reaches (its
    /// padding, above any text).
    static let stripReach: CGFloat = 8
    /// The corner radius of every sheet in a stack, the top one included.
    static let sheetRadius: CGFloat = 5
    /// The band at the top of a single pane that it's dragged by.
    static let grabBand: CGFloat = 6
    /// The hairline around sheets.
    static func sheetEdge(hovered: Bool) -> NSColor { Theme.sheetEdge(hovered: hovered) }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        themed { $0.layer?.backgroundColor = Theme.windowBackground.cgColor }
        focusBar.wantsLayer = true
        focusBar.layer?.backgroundColor = Theme.accent.cgColor
        dropOverlay.isHidden = true
        registerForDraggedTypes([.manifoldArrangement, .manifoldPlacement])
    }

    required init?(coder: NSCoder) { fatalError() }

    /// Each column's foot, shown while the pointer is near the bottom of
    /// its sheet or on the foot itself.
    private var feet: [Int: FootView] = [:]
    private var footNear: Int?
    private var hideFootWork: DispatchWorkItem?

    func show(_ columns: [ColumnContent], fractions: [Double], focused: PlacementID?) {
        let views = columns.map(\.view)
        // A column whose top changed: the new top comes forward out of the
        // stack, and the old one, if it went beneath, sinks back into it.
        var arriving: [PaneContent] = []
        var leaving: [(view: PaneContent, below: PaneContent)] = []
        for column in columns {
            guard let before = self.columns.first(where: { $0.id == column.id }), before.view !== column.view else { continue }
            // Already brought to the top (by the stack switcher): no more
            // to show, and the old top is out of sight.
            if quietArrivals.contains(ObjectIdentifier(column.view)) {
                before.view.removeFromSuperview()
                continue
            }
            arriving.append(column.view)
            if column.beneath.contains(where: { $0.id == before.view.placement }) {
                leaving.append((before.view, column.view))
            }
        }
        if views.map(ObjectIdentifier.init) != panes.map(ObjectIdentifier.init) {
            // (Only those still here: one may have gone on to another tab
            // shown beside this one, sliding in.)
            for v in panes where !views.contains(where: { $0 === v }) && !leaving.contains(where: { $0.view === v })
                && v.superview === self {
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
        // Views lent out (to the stack switcher, say) come back.
        for v in views where v.superview !== self { addSubview(v, positioned: .below, relativeTo: dividers.first) }
        quietArrivals = []
        self.columns = columns
        self.fractions = fractions.count == columns.count
            ? fractions : Array(repeating: 1 / Double(max(columns.count, 1)), count: columns.count)
        self.focused = focused

        strips.forEach { $0.removeFromSuperview() }
        // Each column's top sheet is dragged by its top edge: in a stack,
        // the band of sheet edges; alone, a thin band at its top.
        strips = columns.enumerated().map { i, column in
            let strip = StackStripView()
            strip.column = i
            strip.stacked = !column.beneath.isEmpty
            strip.onHover = { [weak self] hovering in self?.stripHovered(i, hovering) }
            // A click raises the sheet beneath; on a lone sheet, it focuses it.
            strip.onClick = { [weak self] in
                guard let self, i < self.columns.count else { return }
                self.hideStackList()
                self.delegate?.contentRaise(self.columns[i].beneath.first?.id ?? self.columns[i].view.placement)
            }
            strip.onDragStart = { [weak self, weak strip] event in
                guard let self, let strip, i < self.columns.count else { return }
                self.beginDrag(of: self.columns[i].view.placement, event: event, from: strip)
            }
            addSubview(strip)
            return strip
        }
        if let list = stackList, !columns.indices.contains(list.column) || columns[list.column].beneath.isEmpty {
            hideStackList()
        }
        addSubview(focusBar)
        addSubview(dropOverlay)
        if let stackList { addSubview(stackList) }
        for (i, foot) in feet {
            if i < columns.count { addSubview(foot) } else { foot.removeFromSuperview() }
        }
        feet = feet.filter { $0.key < columns.count }
        refreshFeet()
        needsLayout = true
        needsDisplay = true

        if !arriving.isEmpty {
            layoutSubtreeIfNeeded()
            for (view, top) in leaving { sinkIntoStack(view, below: top) }
            for view in arriving { riseFromStack(view) }
        }
    }

    // MARK: Moving through a stack

    private var quietArrivals: Set<ObjectIdentifier> = []

    /// `view`, about to become its column's top, is already in place (the
    /// stack switcher left it there): it comes without being animated in.
    func arriveQuietly(_ view: NSView) {
        quietArrivals.insert(ObjectIdentifier(view))
    }

    private static let stackAnimation = "manifold.stack"

    /// The new top slides down out from under the sheet edges as it appears.
    /// Only the layer moves, so a terminal isn't resized along the way.
    private func riseFromStack(_ view: NSView) {
        guard let layer = view.layer else { return }
        let move = CABasicAnimation(keyPath: "transform")
        move.fromValue = CATransform3DMakeTranslation(0, 22, 0)
        move.toValue = CATransform3DIdentity
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 0.0
        fade.toValue = 1.0
        let group = CAAnimationGroup()
        group.animations = [move, fade]
        group.duration = 0.26
        group.timingFunction = CAMediaTimingFunction(controlPoints: 0.2, 0.9, 0.3, 1)
        layer.add(group, forKey: Self.stackAnimation)
    }

    /// The old top sinks and fades behind the new one, then leaves.
    private func sinkIntoStack(_ view: PaneContent, below top: NSView) {
        if view.superview !== self { addSubview(view) }
        addSubview(view, positioned: .below, relativeTo: top)
        guard let layer = view.layer else {
            view.removeFromSuperview()
            return
        }
        CATransaction.begin()
        CATransaction.setCompletionBlock { [weak self, weak view] in
            guard let self, let view else { return }
            view.layer?.removeAnimation(forKey: Self.stackAnimation)
            if !self.panes.contains(where: { $0 === view }) { view.removeFromSuperview() }
        }
        let move = CABasicAnimation(keyPath: "transform")
        move.toValue = CATransform3DMakeTranslation(0, -14, 0)
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.toValue = 0.0
        let group = CAAnimationGroup()
        group.animations = [move, fade]
        group.duration = 0.2
        group.timingFunction = CAMediaTimingFunction(name: .easeIn)
        group.fillMode = .forwards
        group.isRemovedOnCompletion = false
        layer.add(group, forKey: Self.stackAnimation)
        CATransaction.commit()
    }

    /// Where a column is, in this view's coordinates.
    func frame(ofColumn i: Int) -> NSRect? {
        i < columns.count ? columnFrames()[i] : nil
    }

    /// Room above a column's top card for the sheets beneath: the same for
    /// every column, as much as the deepest stack needs, so their top cards
    /// line up however many sheets each has beneath.
    private func sheetInset(_ i: Int) -> CGFloat {
        let n = columns.map { min($0.beneath.count, Self.maxSheets) }.max() ?? 0
        return n == 0 ? 0 : CGFloat(n) * Self.sheetHeight + 2
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
            let inset = sheetInset(i)
            let view = columns[i].view
            view.frame = NSRect(x: f.minX, y: 0, width: f.width, height: f.height - inset)
            // The top of a stack is a sheet too: round its top corners.
            if let layer = view.layer {
                let stacked = inset > 0
                layer.cornerRadius = stacked ? Self.sheetRadius : 0
                layer.maskedCorners = [.layerMinXMaxYCorner, .layerMaxXMaxYCorner]
                layer.masksToBounds = stacked
            }
        }
        for (i, d) in dividers.enumerated() {
            d.frame = NSRect(x: frames[i].maxX - 3, y: 0, width: Self.dividerWidth + 6, height: bounds.height)
        }
        for (i, foot) in feet where i < frames.count {
            let f = frames[i]
            let size = foot.size
            foot.frame = NSRect(x: f.minX, y: 0, width: min(max(size.width, f.width), f.width), height: min(size.height, f.height - sheetInset(i)))
        }
        for strip in strips where strip.column < frames.count {
            let f = frames[strip.column]
            if strip.stacked {
                let inset = sheetInset(strip.column)
                strip.frame = NSRect(x: f.minX, y: f.maxY - inset - Self.stripReach, width: f.width,
                                     height: inset + Self.stripReach)
                strip.cardTop = Self.stripReach
            } else {
                // Lowered to line up with stacks beside it, it's edged as they are.
                let top = f.maxY - sheetInset(strip.column)
                strip.frame = NSRect(x: f.minX, y: top - Self.grabBand, width: f.width, height: Self.grabBand)
                strip.cardTop = top < f.maxY ? Self.grabBand : 0
            }
        }
        if columns.count > 1, let i = columns.firstIndex(where: { $0.view.placement == focused }) {
            focusBar.isHidden = false
            focusBar.frame = NSRect(x: frames[i].minX, y: 0, width: frames[i].width, height: 2)
        } else {
            focusBar.isHidden = true
        }
        if let list = stackList, list.column < frames.count {
            list.frame = stackListFrame(list, in: frames[list.column])
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        Theme.windowBackground.setFill()
        bounds.fill()
        let frames = columnFrames()
        Theme.divider.setFill()
        for f in frames.dropLast() {
            NSRect(x: f.maxX, y: 0, width: Self.dividerWidth, height: bounds.height).fill()
        }
        // The sheets beneath each stacked column's top card, like the edges
        // of a stack of paper: drawn deepest first, each a little narrower,
        // with the nearer ones tucked over the ones behind.
        for (i, f) in frames.enumerated() {
            let n = min(columns[i].beneath.count, Self.maxSheets)
            guard n > 0 else { continue }
            let hovered = strips.first { $0.column == i }?.hovering == true || stackList?.column == i
            let cardTop = f.maxY - sheetInset(i)
            for level in (0..<n).reversed() {
                let inset = 6 + CGFloat(level) * 6
                let top = cardTop + CGFloat(level + 1) * Self.sheetHeight
                let sheet = NSRect(x: f.minX + inset, y: cardTop - 6, width: f.width - 2 * inset, height: top - (cardTop - 6))
                let path = NSBezierPath(roundedRect: sheet, xRadius: Self.sheetRadius, yRadius: Self.sheetRadius)
                Theme.sheet(level: level).setFill()
                path.fill()
                Self.sheetEdge(hovered: hovered).setStroke()
                path.lineWidth = 0.5
                path.stroke()
            }
            // Behind the top sheet, whose own edge the strip above it draws.
            Theme.windowBackground.setFill()
            NSRect(x: f.minX, y: 0, width: f.width, height: cardTop).fill()
        }
    }

    // MARK: The foot of a sheet

    /// Each shown foot's bunches again: the graph may have changed.
    func refreshFeet() {
        for (i, foot) in feet where i < columns.count {
            foot.bunches = delegate?.contentFoot(for: columns[i].view.placement) ?? []
        }
        needsLayout = true
    }

    private func showFoot(_ i: Int) {
        guard i < columns.count else { return }
        hideFootWork?.cancel()
        if let foot = feet[i] {
            foot.isHidden = false
            return
        }
        let bunches = delegate?.contentFoot(for: columns[i].view.placement) ?? []
        guard !bunches.isEmpty else { return }
        let foot = FootView()
        foot.bunches = bunches
        foot.onOpen = { [weak self] block, newColumn in
            guard let self, i < self.columns.count else { return }
            self.delegate?.contentFootOpen(block, beside: self.columns[i].view.placement, newColumn: newColumn)
        }
        foot.onSpread = { [weak self] in self?.needsLayout = true }
        foot.onHoverChanged = { [weak self] inside in
            if inside { self?.hideFootWork?.cancel() } else { self?.scheduleHideFoot(i) }
        }
        feet[i] = foot
        addSubview(foot)
        foot.alphaValue = 0
        needsLayout = true
        layoutSubtreeIfNeeded()
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.12
            foot.animator().alphaValue = 1
        }
    }

    private func scheduleHideFoot(_ i: Int) {
        hideFootWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.footNear != i else { return }
            self.hideFoot(i)
        }
        hideFootWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35, execute: work)
    }

    private func hideFoot(_ i: Int) {
        guard let foot = feet[i] else { return }
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.12
            foot.animator().alphaValue = 0
        }, completionHandler: { [weak self, weak foot] in
            guard let foot, foot.alphaValue == 0 else { return }
            foot.removeFromSuperview()
            if self?.feet[i] === foot { self?.feet.removeValue(forKey: i) }
        })
    }

    /// The pointer within reach of a column's bottom edge brings its foot
    /// up; gone from there and from the foot, it goes.
    override func mouseMoved(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        let frames = columnFrames()
        let near = frames.firstIndex { $0.contains(p) && p.y < 36 }
        if near != footNear {
            if let old = footNear, feet[old] != nil { scheduleHideFoot(old) }
            footNear = near
            if let near { showFoot(near) }
        }
        super.mouseMoved(with: event)
    }

    override func mouseExited(with event: NSEvent) {
        if let old = footNear { scheduleHideFoot(old) }
        footNear = nil
        super.mouseExited(with: event)
    }

    override func updateTrackingAreas() {
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self))
        super.updateTrackingAreas()
    }

    // MARK: The list of what's beneath

    /// Shows a column's list as hovering its sheets would (for DebugControl).
    func debugPeek(_ column: Int) { showStackList(column) }

    /// Shows a column's foot, a bunch dealt out, as the pointer would (for DebugControl).
    func debugFoot(_ column: Int, bunch: Int?) -> String {
        showFoot(column)
        guard let foot = feet[column] else { return "nothing at the foot" }
        foot.alphaValue = 1
        if let bunch { foot.debugSpread(bunch) }
        layoutSubtreeIfNeeded()
        return foot.bunches.map { "\($0.title) · \($0.count): " + $0.cards.map { "\($0.title) [\($0.detail)]" }.joined(separator: ", ") }.joined(separator: "\n")
    }

    private var hideListWork: DispatchWorkItem?

    private func stripHovered(_ i: Int, _ hovering: Bool) {
        needsDisplay = true
        if hovering {
            hideListWork?.cancel()
            showStackList(i)
        } else {
            scheduleHideStackList()
        }
    }

    private func showStackList(_ i: Int) {
        guard i < columns.count, !columns[i].beneath.isEmpty else { return }
        if stackList?.column == i { return }
        hideStackList()
        let list = StackListView(column: i, panes: columns[i].beneath)
        list.onPick = { [weak self] pane in
            self?.hideStackList()
            self?.delegate?.contentRaise(pane)
        }
        list.onDragStart = { [weak self, weak list] pane, event in
            guard let self, let list else { return }
            self.beginDrag(of: pane, event: event, from: list)
        }
        list.onHover = { [weak self] hovering in
            if hovering { self?.hideListWork?.cancel() } else { self?.scheduleHideStackList() }
        }
        addSubview(list)
        stackList = list
        list.frame = stackListFrame(list, in: columnFrames()[i])
        list.alphaValue = 0
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.1
            list.animator().alphaValue = 1
        }
        needsDisplay = true
    }

    private func stackListFrame(_ list: StackListView, in f: NSRect) -> NSRect {
        let size = list.fittingSize
        let w = min(max(size.width, 180), f.width - 16)
        let top = f.maxY - sheetInset(list.column) - 4
        return NSRect(x: f.midX - w / 2, y: top - size.height, width: w, height: size.height).integral
    }

    private func scheduleHideStackList() {
        hideListWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.hideStackList() }
        hideListWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15, execute: work)
    }

    private func hideStackList() {
        hideListWork?.cancel()
        stackList?.removeFromSuperview()
        stackList = nil
        needsDisplay = true
    }

    // MARK: Dragging sheets

    private func beginDrag(of pane: PlacementID, event: NSEvent, from view: NSView) {
        let item = NSPasteboardItem()
        item.setString(pane, forType: .manifoldPlacement)
        let dragItem = NSDraggingItem(pasteboardWriter: item)
        let image = SheetDragImage.make(for: paneInfo(pane))
        let p = view.convert(event.locationInWindow, from: nil)
        dragItem.setDraggingFrame(NSRect(x: p.x - 24, y: p.y - image.size.height / 2, width: image.size.width,
                                         height: image.size.height), contents: image)
        stackList?.isHidden = true
        delegate?.contentPaneDragChanged(true)
        view.beginDraggingSession(with: [dragItem], event: event, source: self)
    }

    /// What's known of a placement shown here, for its drag image.
    var paneInfo: (PlacementID) -> Shown? = { _ in nil }

    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        context == .withinApplication ? .move : []
    }

    func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
        hideStackList()
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

    // MARK: Dropping tabs

    /// The outer part of a column on either side makes a new column there;
    /// its middle stacks onto it.
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
            return (.stack(i), f)
        }
        return nil
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation { draggingUpdated(sender) }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        let point = convert(sender.draggingLocation, from: nil)
        // The sidebar can't be hovered open mid-drag; the window's edge does it.
        if convert(point, to: nil).x < 8 { delegate?.contentDragAtLeftEdge() }
        let pb = sender.draggingPasteboard
        let isPane = pb.string(forType: .manifoldPlacement) != nil
        let tab = pb.string(forType: .manifoldArrangement).flatMap(BlockID.init(string:))
        guard isPane || (tab != nil && delegate?.contentCanDrop(tab!) == true),
              let (target, rect) = dropTarget(at: point) else {
            hideDrop()
            return []
        }
        if dropTarget != target || dropOverlay.isHidden {
            if case .stack = target { dropOverlay.stacking = true } else { dropOverlay.stacking = false }
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
        guard let tab = pb.string(forType: .manifoldArrangement).flatMap(BlockID.init(string:)) else { return false }
        delegate?.contentDrop(tab, on: target)
        return true
    }

    private func hideDrop() {
        dropOverlay.isHidden = true
        dropTarget = nil
    }
}

/// Where a dragged tab would land: half a column, for a new column; the
/// whole column, with sheets drawn at its top, for its stack.
final class DropOverlayView: NSView {
    var stacking = false { didSet { needsDisplay = true } }

    override func draw(_ dirtyRect: NSRect) {
        let inset: CGFloat = stacking ? 10 : 0
        let body = NSRect(x: 0, y: 0, width: bounds.width, height: bounds.height - inset)
        Theme.dropHighlight.setFill()
        body.fill()
        Theme.accent.withAlphaComponent(0.5).setStroke()
        NSBezierPath(rect: body.insetBy(dx: 0.5, dy: 0.5)).stroke()
        guard stacking else { return }
        for level in 0..<2 {
            let x = 8 + CGFloat(level) * 7
            let sheet = NSRect(x: x, y: body.maxY + 1 + CGFloat(level) * 4, width: bounds.width - 2 * x, height: 3)
            Theme.accent.withAlphaComponent(0.55 - Double(level) * 0.2).setFill()
            NSBezierPath(roundedRect: sheet, xRadius: 1.5, yRadius: 1.5).fill()
        }
    }
}

/// The band of sheet edges above a stacked column: hovering lists what's
/// beneath, clicking raises the nearest.
final class StackStripView: NSView {
    var column = 0
    /// Whether there are sheets beneath (else it's just the grab band).
    var stacked = true { didSet { needsDisplay = true; window?.invalidateCursorRects(for: self) } }
    var onHover: ((Bool) -> Void)?
    var onClick: (() -> Void)?
    var onDragStart: ((NSEvent) -> Void)?
    private var downAt: NSPoint?
    private(set) var hovering = false { didSet { needsDisplay = true } }
    /// Where the top sheet begins, up from the strip's bottom.
    var cardTop: CGFloat = 0 { didSet { needsDisplay = true } }

    /// The top sheet's edge, drawn here, over it, as it's the pane's own
    /// view below: a hairline over its rounded top, like the sheets'.
    override func draw(_ dirtyRect: NSRect) {
        guard stacked || cardTop > 0 else { return }
        let r = TabContentView.sheetRadius
        let w = bounds.width, top = cardTop - 0.25
        let edge = NSBezierPath()
        edge.move(to: NSPoint(x: 0.25, y: 0))
        edge.line(to: NSPoint(x: 0.25, y: top - r))
        edge.appendArc(withCenter: NSPoint(x: r + 0.25, y: top - r), radius: r, startAngle: 180, endAngle: 90, clockwise: true)
        edge.line(to: NSPoint(x: w - r - 0.25, y: top))
        edge.appendArc(withCenter: NSPoint(x: w - r - 0.25, y: top - r), radius: r, startAngle: 90, endAngle: 0, clockwise: true)
        edge.line(to: NSPoint(x: w - 0.25, y: 0))
        edge.lineWidth = 0.5
        TabContentView.sheetEdge(hovered: hovering).setStroke()
        edge.stroke()
    }

    override func updateTrackingAreas() {
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
        super.updateTrackingAreas()
    }

    override func resetCursorRects() { addCursorRect(bounds, cursor: stacked ? .pointingHand : .openHand) }

    override func mouseEntered(with event: NSEvent) {
        guard stacked else { return }
        hovering = true
        onHover?(true)
    }

    override func mouseExited(with event: NSEvent) {
        guard hovering else { return }
        hovering = false
        onHover?(false)
    }

    // A click raises the sheet beneath; a drag moves the top one.
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
}

/// What's beneath a stack's top, nearest first; picking one raises it.
final class StackListView: NSView {
    let column: Int
    var onPick: ((PlacementID) -> Void)?
    var onDragStart: ((PlacementID, NSEvent) -> Void)?
    var onHover: ((Bool) -> Void)?
    private let rows: [PaletteRowView]
    private let ids: [PlacementID]
    private static let rowHeight: CGFloat = 28

    init(column: Int, panes: [Shown]) {
        self.column = column
        ids = panes.map(\.id)
        rows = panes.map { pane in
            PaletteRowView(item: PaletteItem(symbol: pane.symbol, title: pane.title,
                                             subtitle: "", run: {}))
        }
        super.init(frame: .zero)
        wantsLayer = true
        themed {
            $0.layer?.backgroundColor = Theme.panel.cgColor
            $0.layer?.borderColor = Theme.panelBorder.cgColor
        }
        layer?.cornerRadius = 9
        layer?.cornerCurve = .continuous
        layer?.borderWidth = 0.5
        shadow = {
            let s = NSShadow()
            s.shadowColor = NSColor(white: 0, alpha: 0.16)
            s.shadowBlurRadius = 12
            s.shadowOffset = NSSize(width: 0, height: -3)
            return s
        }()
        for (i, row) in rows.enumerated() {
            row.onHover = { [weak self] in self?.highlight(i) }
            row.onClick = { [weak self] in
                guard let self else { return }
                self.onPick?(self.ids[i])
            }
            row.onDragStart = { [weak self] event in
                guard let self else { return }
                self.onDragStart?(self.ids[i], event)
            }
            addSubview(row)
        }
    }

    required init?(coder: NSCoder) { fatalError() }

    override var fittingSize: NSSize {
        let widest = rows.map { $0.fittingWidth }.max() ?? 160
        return NSSize(width: widest + 12, height: CGFloat(rows.count) * Self.rowHeight + 10)
    }

    override var isFlipped: Bool { true }

    override func layout() {
        super.layout()
        for (i, row) in rows.enumerated() {
            row.frame = NSRect(x: 5, y: 5 + CGFloat(i) * Self.rowHeight, width: bounds.width - 10, height: Self.rowHeight)
        }
    }

    private func highlight(_ i: Int) {
        for (j, row) in rows.enumerated() { row.highlighted = i == j }
    }

    override func updateTrackingAreas() {
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
        super.updateTrackingAreas()
    }

    override func mouseEntered(with event: NSEvent) { onHover?(true) }

    override func mouseExited(with event: NSEvent) {
        highlight(-1)
        onHover?(false)
    }
}

/// The grab area over the line between two columns.
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

/// What follows the cursor when a sheet is dragged: a small sheet with the
/// pane's icon and title.
enum SheetDragImage {
    static func make(for pane: Shown?) -> NSImage {
        let title = pane?.title ?? "Sheet"
        let font = NSFont.systemFont(ofSize: 13, weight: .medium)
        let textWidth = ceil((title as NSString).size(withAttributes: [.font: font]).width)
        let size = NSSize(width: min(max(textWidth + 52, 140), 320), height: 34)
        return NSImage(size: size, flipped: false) { rect in
            let card = rect.insetBy(dx: 1, dy: 1)
            let path = NSBezierPath(roundedRect: card, xRadius: TabContentView.sheetRadius, yRadius: TabContentView.sheetRadius)
            Theme.windowBackground.withAlphaComponent(0.96).setFill()
            path.fill()
            TabContentView.sheetEdge(hovered: true).setStroke()
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
