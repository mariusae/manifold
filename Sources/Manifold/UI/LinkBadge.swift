import AppKit
import ManifoldCore

/// A link a block has by hand, as its tile's links show it: to a block
/// (outbound, →) or from one (inbound, ←).
struct LinkCard: Equatable {
    /// The edge's id, to break it by.
    var link: String
    var block: BlockID
    var title: String
    var symbol: String
    var outbound: Bool
    /// Not an embed (a note's image), which goes when the note no longer
    /// shows it.
    var breakable = true
}

/// A block's links by hand (§3.5), in its tile's bar: each linked block's
/// own face, a small rounded square with a badge at its corner for the
/// direction (a loop forward, links to; back, linked from) — the most
/// recent in front, two more peeking out behind it. The pointer on them
/// fans them out along the bar; resting on one a moment shows its summary
/// card under the bar, one at a time. A click opens it by the one rule (⌘
/// beside, ⌥ over, ⇧⌘ the system's app); right-clicked, its menu.
final class LinkBadge: NSView {
    /// A link clicked: the block, and the keys held (⌘ beside, ⌥ over,
    /// ⇧⌘ the system's app).
    var onOpen: ((BlockID, NSEvent.ModifierFlags) -> Void)?
    var onBreak: ((String) -> Void)?
    /// The neighborhood map, the big view of the links.
    var onMap: (() -> Void)?
    /// A linked block's summary card, for the preview under the bar.
    var summary: ((BlockID) -> SummaryCardContent?)?
    var cards: [LinkCard] = [] {
        didSet {
            guard cards != oldValue else { return }
            rebuild()
        }
    }

    static let capsuleHeight: CGFloat = 22
    static let chip: CGFloat = 22
    /// Folded, how far each one behind peeks out past the one before.
    static let peek: CGFloat = 4
    /// Fanned out, from one to the next.
    static let step: CGFloat = 26
    /// The most fanned out at once: past that, the last is "+n", the map.
    static let mostShown = 8
    /// The preview's width under the bar.
    static let previewWidth: CGFloat = 280
    /// How long the pointer rests on a face before its card shows: long
    /// enough that sweeping across the bar doesn't flash cards.
    static let previewDelay: TimeInterval = 0.15

    /// At a tile's upper right: kept for the grid, which places it in the bar.
    var fansDown = false
    private var chips: [Chip] = []
    /// Past `mostShown`, the rest as one: the map.
    private let more = Chip()
    private var fanned = false { didSet { if fanned != oldValue { needsLayout = true; if !fanned { hidePreview() } } } }
    private var preview: Preview?
    private var previewed: Int?
    private var previewWork: DispatchWorkItem?

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        // The faces' badges reach past its frame.
        clipsToBounds = false
        layer?.masksToBounds = false
        more.isMore = true
        more.onClick = { [weak self] _ in self?.onMap?() }
        more.isHidden = true
        addSubview(more)
    }

    required init?(coder: NSCoder) { fatalError() }

    // MARK: Size, as the bar gives it

    /// What the bar gives the folded stack; under its own width, it hides.
    var capsuleLimit: CGFloat = .infinity { didSet { if capsuleLimit != oldValue { isHidden = capsuleLimit < foldedWidth; needsLayout = true } } }
    /// The folded stack's width: one face, and the edges of two more.
    var foldedWidth: CGFloat { cards.isEmpty ? 0 : Self.chip + CGFloat(min(cards.count, 3) - 1) * Self.peek }
    /// What it takes of the bar, folded.
    var capsuleWantedWidth: CGFloat { foldedWidth }
    /// How much room it wants: fanned out along the bar.
    var wantedSize: NSSize {
        let n = min(cards.count, Self.mostShown)
        return NSSize(width: max(foldedWidth, Self.chip + CGFloat(max(n - 1, 0)) * Self.step), height: Self.capsuleHeight)
    }

    // MARK: Faces

    private func rebuild() {
        hidePreview()
        for c in chips { c.removeFromSuperview() }
        chips = cards.prefix(Self.mostShown).map { card in
            let c = Chip()
            c.symbol = card.symbol
            c.outbound = card.outbound
            c.toolTip = (card.breakable ? (card.outbound ? "Links to " : "Linked from ") : (card.outbound ? "Shows " : "Shown in ")) + card.title
            c.onClick = { [weak self] mods in self?.onOpen?(card.block, mods) }
            c.onMenu = { [weak self, weak c] in if let c { self?.showMenu(for: card, from: c) } }
            c.onDragStart = { [weak self, weak c] event in if let self, let c { self.drag(card.block, from: c, event) } }
            return c
        }
        // The most recent on top of the ones behind it: added last, just
        // under "+n".
        for c in chips.reversed() { addSubview(c, positioned: .below, relativeTo: more) }
        if cards.count > Self.mostShown { more.moreCount = cards.count - Self.mostShown + 1 }
        needsLayout = true
    }

    override func layout() {
        super.layout()
        let right = bounds.maxX
        let y = (bounds.height - Self.chip) / 2
        // Fanned: as many as fit, the last "+n" if there are more.
        let fit = max(1, Int((bounds.width - Self.chip) / Self.step) + 1)
        let overflow = cards.count > min(fit, Self.mostShown)
        let shown = overflow ? min(fit, Self.mostShown) - 1 : chips.count
        let foldedLeft = right - foldedWidth
        for (i, c) in chips.enumerated() {
            let folded = NSRect(x: foldedLeft + CGFloat(min(i, 2)) * Self.peek, y: y, width: Self.chip, height: Self.chip)
            let open = NSRect(x: right - Self.chip - CGFloat(i) * Self.step, y: y, width: Self.chip, height: Self.chip)
            let target = fanned ? open : folded
            // Folded, the front on top (by the views' order), two edges
            // behind it, the rest out of sight.
            c.depth = fanned ? 0 : min(i, 2)
            let visible = fanned ? i < shown : i < 3
            if visible, c.isHidden { c.frame = folded; c.isHidden = false }
            if !visible { if !c.isHidden { c.isHidden = true }; c.frame = folded; continue }
            if c.frame != target {
                NSAnimationContext.runAnimationGroup { ctx in
                    ctx.duration = Motion.base
                    ctx.timingFunction = fanned ? Motion.appear : Motion.disappear
                    ctx.allowsImplicitAnimation = true
                    c.frame = target
                }
            }
        }
        more.isHidden = !(fanned && overflow)
        if overflow {
            more.moreCount = cards.count - shown
            more.frame = NSRect(x: right - Self.chip - CGFloat(shown) * Self.step, y: y, width: Self.chip, height: Self.chip)
        }
        for c in chips + [more] { window?.invalidateCursorRects(for: c) }
    }

    // MARK: The pointer

    /// Only the faces take the mouse; between them, the bar does.
    override func hitTest(_ point: NSPoint) -> NSView? {
        let p = convert(point, from: superview)
        for v in [more] + chips where !v.isHidden && v.frame.contains(p) { return v }
        return nil
    }

    override func updateTrackingAreas() {
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds.insetBy(dx: 0, dy: -6), options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways], owner: self))
        super.updateTrackingAreas()
    }

    override func mouseMoved(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        let live = chips.filter { !$0.isHidden }
        if !fanned, live.contains(where: { $0.frame.insetBy(dx: -3, dy: -4).contains(p) }) { fanned = true }
        guard fanned else { return }
        // Off the faces (and the gaps between them): folded again.
        let span = (live + (more.isHidden ? [] : [more])).reduce(NSRect.null) { $0.union($1.frame) }.insetBy(dx: -6, dy: -8)
        if !span.contains(p) { fanned = false; return }
        let under = chips.firstIndex { !$0.isHidden && $0.frame.insetBy(dx: -2, dy: -4).contains(p) }
        for (i, c) in chips.enumerated() { c.hovered = i == under }
        more.hovered = !more.isHidden && more.frame.contains(p)
        if let under { hover(under) }
    }

    override func mouseExited(with event: NSEvent) {
        fanned = false
        for c in chips { c.hovered = false }
        more.hovered = false
    }

    /// A face under the pointer: its card, once it has rested a moment —
    /// or at once, when a card shows already (moving along the faces).
    private func hover(_ i: Int) {
        guard i != previewed || preview == nil else { return }
        previewWork?.cancel()
        if preview != nil { return showPreview(i) }
        let work = DispatchWorkItem { [weak self] in self?.showPreview(i) }
        previewWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.previewDelay, execute: work)
    }

    // MARK: The card under the bar

    private func showPreview(_ i: Int) {
        guard fanned, i < chips.count, i < cards.count, let host = superview,
              let content = summary?(cards[i].block) else { return }
        previewed = i
        let p = preview ?? {
            let p = Preview()
            host.addSubview(p, positioned: .above, relativeTo: nil)
            preview = p
            return p
        }()
        p.card.content = content
        let h = SummaryCard.height(for: content) + 2
        // Under the bar, beneath the face, kept inside what holds it.
        let chip = chips[i].convert(chips[i].bounds, to: host)
        var x = chip.midX - Self.previewWidth / 2
        x = min(max(x, host.bounds.minX + 6), host.bounds.maxX - Self.previewWidth - 6)
        let gap: CGFloat = 8
        let y = host.isFlipped ? chip.maxY + gap : chip.minY - gap - h
        let target = NSRect(x: x, y: y, width: Self.previewWidth, height: h)
        if p.frame.isEmpty || p.alphaValue == 0 {
            p.frame = target
            p.alphaValue = 0
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = Motion.fast
                ctx.timingFunction = Motion.appear
                p.animator().alphaValue = 1
            }
        } else {
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = Motion.fast
                ctx.timingFunction = Motion.travel
                p.animator().frame = target
            }
        }
    }

    private func hidePreview() {
        previewWork?.cancel()
        previewWork = nil
        previewed = nil
        guard let p = preview else { return }
        preview = nil
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = Motion.fast
            ctx.timingFunction = Motion.disappear
            p.animator().alphaValue = 0
        }, completionHandler: { p.removeFromSuperview() })
    }

    override func viewWillMove(toSuperview newSuperview: NSView?) {
        if newSuperview == nil { hidePreview() }
        super.viewWillMove(toSuperview: newSuperview)
    }

    // MARK: Menu, and dragging out

    /// A face's menu: the one rule's three ways, the link broken, the map.
    private func showMenu(for card: LinkCard, from chip: NSView) {
        hidePreview()
        let menu = NSMenu()
        menu.addItem(ClosureMenuItem("Go To", symbol: "arrow.right.circle") { [weak self] in self?.onOpen?(card.block, []) })
        menu.addItem(ClosureMenuItem("Show Beside", symbol: "rectangle.split.1x2") { [weak self] in self?.onOpen?(card.block, .command) })
        menu.addItem(ClosureMenuItem("Show Over", symbol: "square.stack") { [weak self] in self?.onOpen?(card.block, .option) })
        menu.addItem(.separator())
        if card.breakable {
            menu.addItem(ClosureMenuItem("Remove Link", symbol: "link.badge.plus") { [weak self] in self?.onBreak?(card.link) })
        }
        menu.addItem(ClosureMenuItem("Show the Neighborhood Map", symbol: "point.3.connected.trianglepath.dotted") { [weak self] in self?.onMap?() })
        guard let event = NSApp.currentEvent else { return }
        NSMenu.popUpContextMenu(menu, with: event, for: chip)
    }

    /// A face dragged: the block, to bring where it's dropped; with ⇧ what
    /// it stands for (its path, its link), as a tile's bar is.
    private func drag(_ block: BlockID, from view: NSView, _ event: NSEvent) {
        hidePreview()
        guard let item = Drags.block?(block, event.modifierFlags) else { return }
        let drag = NSDraggingItem(pasteboardWriter: item)
        let picture = NSImage(size: view.bounds.size)
        if let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
            view.cacheDisplay(in: view.bounds, to: rep)
            picture.addRepresentation(rep)
        }
        drag.setDraggingFrame(view.bounds, contents: picture)
        dragIsPath = event.modifierFlags.contains(.shift)
        view.beginDraggingSession(with: [drag], event: event, source: self)
    }

    private var dragIsPath = false

    // MARK: Debugging

    /// Debugging: the fan, as the pointer resting on the stack would open it.
    func debugFan(_ open: Bool) { fanned = open }
    var debugTitles: [String] { cards.prefix(chips.count).map { ($0.outbound ? "→ " : "← ") + $0.title } }
    /// How many faces peek out behind the front one, folded.
    var debugSheets: Int { fanned ? 0 : max(0, min(cards.count, 3) - 1) }
    var debugGeometry: String { chips.filter { !$0.isHidden }.map { NSStringFromRect($0.frame) }.joined(separator: " ") }
    /// Debugging: the front face's middle, in the window from its top left.
    var debugCapsuleCenter: NSPoint? {
        guard let first = chips.first, let frameView = window?.contentView?.superview else { return nil }
        let r = first.convert(first.bounds, to: nil)
        return NSPoint(x: r.midX, y: frameView.bounds.height - r.midY)
    }
    /// Debugging: the nth link broken, as its menu's Remove Link does.
    func debugBreak(_ n: Int) -> Bool {
        guard n < cards.count, cards[n].breakable else { return false }
        onBreak?(cards[n].link)
        return true
    }
    /// Debugging: the nth face's card shown, as resting on it does; its title.
    func debugPreview(_ n: Int) -> String {
        fanned = true
        layoutSubtreeIfNeeded()
        showPreview(n)
        return preview.map { "card: \($0.card.content.summary.title) at \(NSStringFromRect($0.frame))" } ?? "no card"
    }

    // MARK: A face

    /// One linked block: its symbol on a small rounded square, and a badge
    /// at its lower right for the direction. Or, as `isMore`, "+n".
    final class Chip: NSView {
        var onClick: ((NSEvent.ModifierFlags) -> Void)?
        var onMenu: (() -> Void)?
        var onDragStart: ((NSEvent) -> Void)?
        var symbol = "link" { didSet { icon.image = Theme.symbol(symbol, size: 12) } }
        var outbound = true { didSet { badgeIcon.image = Theme.symbol(outbound ? "arrow.uturn.forward" : "arrow.uturn.backward", size: 6.5, weight: .bold) } }
        var isMore = false { didSet { icon.isHidden = isMore; badge.isHidden = isMore; label.isHidden = !isMore } }
        var moreCount = 0 { didSet { label.stringValue = "+\(moreCount)"; toolTip = "\(moreCount) more — the Neighborhood Map" } }
        /// Folded behind the front one (1, 2), only its edge showing: nothing
        /// on it, in a stack's sheet greys, as a tile's sheets are.
        var depth = 0 {
            didSet {
                guard depth != oldValue else { return }
                icon.isHidden = depth > 0 || isMore
                badge.isHidden = depth > 0 || isMore
                colour()
            }
        }
        private func colour() {
            effectiveAppearance.performAsCurrentDrawingAppearance {
                layer?.backgroundColor = (depth > 0 ? Theme.sheet(level: depth) : LinkCapsule.fill).cgColor
                layer?.borderColor = (hovered ? EdgeColor.accentStrong : depth > 0 ? EdgeColor.control : LinkCapsule.edge).cgColor
            }
        }
        var hovered = false {
            didSet {
                guard hovered != oldValue else { return }
                colour()
                layer?.borderWidth = hovered ? 1.5 : LinkCapsule.edgeWidth
            }
        }
        private let icon = NSImageView()
        private let badge = NSView()
        private let badgeIcon = NSImageView()
        private let label = NSTextField(labelWithString: "")
        private var downAt: NSPoint?

        override init(frame: NSRect) {
            super.init(frame: frame)
            wantsLayer = true
            layer?.cornerRadius = Radius.control
            layer?.cornerCurve = .continuous
            layer?.borderWidth = LinkCapsule.edgeWidth
            layer?.masksToBounds = false
            icon.contentTintColor = Theme.secondaryText
            icon.image = Theme.symbol(symbol, size: 12)
            badge.wantsLayer = true
            badge.layer?.cornerRadius = 5.5
            badge.layer?.borderWidth = LinkCapsule.edgeWidth
            badgeIcon.contentTintColor = Theme.secondaryText
            badgeIcon.image = Theme.symbol("arrow.uturn.forward", size: 6.5, weight: .bold)
            badge.addSubview(badgeIcon)
            label.font = UIType.count
            label.textColor = Theme.secondaryText
            label.alignment = .center
            label.isHidden = true
            themed {
                $0.colour()
                $0.badge.layer?.backgroundColor = LinkCapsule.fill.cgColor
                $0.badge.layer?.borderColor = LinkCapsule.edge.cgColor
            }
            addSubview(icon)
            addSubview(label)
            addSubview(badge)
        }

        required init?(coder: NSCoder) { fatalError() }

        override func layout() {
            super.layout()
            let s: CGFloat = 13
            icon.frame = NSRect(x: (bounds.width - s) / 2, y: (bounds.height - s) / 2, width: s, height: s)
            // The badge at the lower right, a little past the corner.
            badge.frame = NSRect(x: bounds.maxX - 8, y: -3, width: 11, height: 11)
            badgeIcon.frame = badge.bounds.insetBy(dx: 2, dy: 2)
            let lh = ceil(label.intrinsicContentSize.height)
            label.frame = NSRect(x: 0, y: (bounds.height - lh) / 2, width: bounds.width, height: lh)
        }

        override func resetCursorRects() { addCursorRect(bounds, cursor: .pointingHand) }
        /// A click in a window not yet active goes to the link too.
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
        override func mouseDown(with event: NSEvent) { downAt = event.locationInWindow }
        override func rightMouseDown(with event: NSEvent) { onMenu?() }
        override func mouseDragged(with event: NSEvent) {
            guard let start = downAt, onDragStart != nil else { return }
            let p = event.locationInWindow
            guard hypot(p.x - start.x, p.y - start.y) > 4 else { return }
            downAt = nil
            onDragStart?(event)
        }
        override func mouseUp(with event: NSEvent) {
            defer { downAt = nil }
            guard downAt != nil, bounds.contains(convert(event.locationInWindow, from: nil)) else { return }
            // ⌃-click is a right-click, on the Mac: the menu.
            if event.modifierFlags.contains(.control) { return onMenu?() ?? () }
            onClick?(event.modifierFlags)
        }
    }

    /// The card under the bar: a summary card, which the pointer passes
    /// through (it's a look, not a place to click).
    final class Preview: NSView {
        let card = SummaryCard(SummaryCardContent(id: "", symbol: "doc", summary: BlockSummary(title: "")))
        override init(frame: NSRect) {
            super.init(frame: frame)
            wantsLayer = true
            card.autoresizingMask = [.width, .height]
            card.frame = bounds
            addSubview(card)
            layer?.zPosition = 20
        }
        required init?(coder: NSCoder) { fatalError() }
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }
}

extension LinkBadge: NSDraggingSource {
    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        dragIsPath ? [.copy, .link, .generic] : (context == .withinApplication ? [.copy, .move] : [])
    }
}
