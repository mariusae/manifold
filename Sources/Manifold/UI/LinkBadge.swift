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
/// own face, a small rounded square with a chevron in it for the
/// direction (right, links to; left, linked from) — the most
/// recent in front, two more peeking out behind it. The pointer on them
/// fans them out along the bar, the title fading out before the first;
/// resting on one a moment shows its summary card under the bar, one at a
/// time. More than fit, the last is a stack of the rest, scrubbed through
/// by the pointer over the title. A click opens a link by the one rule (⌘
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
    /// Fanned out: where the fan begins (its left, in this view), for the
    /// bar's title to fade out before it; nil, folded again.
    var onFanEdge: ((CGFloat?) -> Void)?
    private var reportedEdge: CGFloat??
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
    /// The most fanned out one by one: past that, the rest are a stack.
    static let mostShown = 8
    /// Left of a stack, the least room kept to scrub through it.
    static let scrubRoom: CGFloat = 90
    /// The preview's width under the bar.
    static let previewWidth: CGFloat = 280
    /// How long the pointer rests on a face before its card shows: long
    /// enough that sweeping across the bar doesn't flash cards.
    static let previewDelay: TimeInterval = 0.15

    /// At a tile's upper right: kept for the grid, which places it in the bar.
    var fansDown = false
    /// A face for each of the first links (one by one when fanned out).
    private var chips: [Chip] = []
    /// The rest, once they don't fit one by one: the face scrubbed to, and
    /// two edges behind it.
    private let stackFront = Chip()
    private let stackBack = [Chip(), Chip()]
    /// Fanned out: how many one by one; the rest are the stack's.
    private var singles = 0
    private var overflow: Bool { fanned && singles < cards.count }
    /// Which of the stack's links is in front of it (0, the most recent).
    private var scrubbed = 0
    /// Where the pointer scrubs through the stack: the bar left of it.
    private var scrubRect = NSRect.null
    private var fanned = false {
        didSet {
            guard fanned != oldValue else { return }
            needsLayout = true
            if !fanned { hidePreview(); scrubbed = 0 }
        }
    }
    private var preview: Preview?
    private var previewed: Int?
    private var previewWork: DispatchWorkItem?
    private var downAt: NSPoint?

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        // The faces' badges reach past its frame.
        clipsToBounds = false
        layer?.masksToBounds = false
        for (i, c) in stackBack.enumerated() { c.depth = i + 1; c.isHidden = true; addSubview(c) }
        stackFront.isHidden = true
        stackFront.onClick = { [weak self] mods in self?.openScrubbed(mods) }
        stackFront.onMenu = { [weak self] in self?.menuScrubbed() }
        addSubview(stackFront)
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
            dress(c, card)
            c.onClick = { [weak self] mods in self?.onOpen?(card.block, mods) }
            c.onMenu = { [weak self, weak c] in if let c { self?.showMenu(for: card, from: c) } }
            c.onDragStart = { [weak self, weak c] event in if let self, let c { self.drag(card.block, from: c, event) } }
            return c
        }
        // The most recent on top of the ones behind it: added last, just
        // under the stack (which is never over them).
        for c in chips.reversed() { addSubview(c, positioned: .below, relativeTo: stackBack[1]) }
        scrubbed = 0
        needsLayout = true
    }

    private func dress(_ c: Chip, _ card: LinkCard) {
        c.symbol = card.symbol
        c.outbound = card.outbound
        c.toolTip = (card.breakable ? (card.outbound ? "Links to " : "Linked from ") : (card.outbound ? "Shows " : "Shown in ")) + card.title
    }

    override func layout() {
        super.layout()
        let right = bounds.maxX
        let y = (bounds.height - Self.chip) / 2
        // Fanned: all one by one if they fit; else as many as leave room
        // to scrub, and a stack of the rest.
        let all = Self.chip + CGFloat(max(cards.count - 1, 0)) * Self.step
        if cards.count <= Self.mostShown, all <= bounds.width {
            singles = cards.count
        } else {
            let fit = Int((bounds.width - Self.chip - Self.scrubRoom) / Self.step)
            singles = max(0, min(Self.mostShown - 1, fit, cards.count - 1))
        }
        let foldedLeft = right - foldedWidth
        for (i, c) in chips.enumerated() {
            let folded = NSRect(x: foldedLeft + CGFloat(min(i, 2)) * Self.peek, y: y, width: Self.chip, height: Self.chip)
            let open = NSRect(x: right - Self.chip - CGFloat(i) * Self.step, y: y, width: Self.chip, height: Self.chip)
            let target = fanned ? open : folded
            // Folded, the front on top (by the views' order), two edges
            // behind it, the rest out of sight.
            c.depth = fanned ? 0 : min(i, 2)
            let visible = fanned ? i < singles : i < 3
            if visible, c.isHidden { c.frame = folded; c.isHidden = false }
            if !visible { if !c.isHidden { c.isHidden = true }; c.frame = folded; continue }
            move(c, to: target)
        }
        // The stack of the rest, in the next place along, its edges toward
        // where it's scrubbed (the older, farther left).
        let stackAt = NSRect(x: right - Self.chip - CGFloat(singles) * Self.step, y: y, width: Self.chip, height: Self.chip)
        let rest = cards.count - singles
        stackFront.isHidden = !overflow
        for (j, b) in stackBack.enumerated() {
            b.isHidden = !overflow || rest <= j + 1
            b.frame = stackAt.offsetBy(dx: -CGFloat(j + 1) * Self.peek, dy: 0)
        }
        if overflow {
            stackFront.frame = stackAt
            scrubbed = min(scrubbed, rest - 1)
            dress(stackFront, cards[singles + scrubbed])
            scrubRect = NSRect(x: bounds.minX, y: 0, width: stackAt.maxX - bounds.minX, height: bounds.height)
        } else {
            scrubRect = .null
        }
        for c in chips + [stackFront] { window?.invalidateCursorRects(for: c) }
        // Where the fan now begins, for the title to give way to it.
        var edge: CGFloat?
        if fanned {
            let backs = overflow ? stackBack.filter { !$0.isHidden }.map(\.frame.minX) : []
            let ones = singles > 0 ? [right - Self.chip - CGFloat(singles - 1) * Self.step] : []
            edge = ((overflow ? [stackAt.minX] : []) + backs + ones).min()
        }
        if reportedEdge != .some(edge) {
            reportedEdge = .some(edge)
            onFanEdge?(edge)
        }
    }

    private func move(_ c: Chip, to target: NSRect) {
        guard c.frame != target else { return }
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = Motion.base
            ctx.timingFunction = fanned ? Motion.appear : Motion.disappear
            ctx.allowsImplicitAnimation = true
            c.frame = target
        }
    }

    // MARK: The pointer

    /// The faces take the mouse; fanned with a stack, so does the bar left
    /// of it, where the stack is scrubbed; elsewhere, the bar does.
    override func hitTest(_ point: NSPoint) -> NSView? {
        let p = convert(point, from: superview)
        for v in [stackFront] + chips where !v.isHidden && v.frame.contains(p) { return v }
        if overflow, scrubRect.contains(p) { return self }
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
        if !fanned, live.contains(where: { $0.frame.insetBy(dx: -3, dy: -4).contains(p) }) { fanned = true; layoutSubtreeIfNeeded() }
        guard fanned else { return }
        // Off the faces, the gaps between them and the scrubbing: folded again.
        var span = (chips.filter { !$0.isHidden } + (overflow ? [stackFront] : [])).reduce(NSRect.null) { $0.union($1.frame) }
        if overflow { span = span.union(scrubRect) }
        if !span.insetBy(dx: -6, dy: -8).contains(p) { fanned = false; return }
        if overflow, p.x <= stackFront.frame.maxX {
            // Scrubbing: from the stack leftward, further back.
            let rest = cards.count - singles
            let t = (stackFront.frame.maxX - p.x) / max(1, stackFront.frame.maxX - scrubRect.minX)
            let k = min(rest - 1, max(0, Int(t * CGFloat(rest))))
            if k != scrubbed { scrubbed = k; dress(stackFront, cards[singles + k]) }
            for c in chips { c.hovered = false }
            stackFront.hovered = true
            hover(singles + k, at: p.x)
            return
        }
        stackFront.hovered = false
        let under = chips.firstIndex { !$0.isHidden && $0.frame.insetBy(dx: -2, dy: -4).contains(p) }
        for (i, c) in chips.enumerated() { c.hovered = i == under }
        if let under { hover(under, at: chips[under].frame.midX) }
    }

    override func mouseExited(with event: NSEvent) {
        fanned = false
        for c in chips + [stackFront] { c.hovered = false }
    }

    // The bar left of a stack, clicked: the link scrubbed to.
    override func mouseDown(with event: NSEvent) { downAt = event.locationInWindow }
    override func mouseUp(with event: NSEvent) {
        defer { downAt = nil }
        guard downAt != nil else { return }
        if event.modifierFlags.contains(.control) { return menuScrubbed() }
        openScrubbed(event.modifierFlags)
    }
    override func rightMouseDown(with event: NSEvent) { menuScrubbed() }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    private var scrubbedCard: LinkCard? { overflow && singles + scrubbed < cards.count ? cards[singles + scrubbed] : nil }
    private func openScrubbed(_ mods: NSEvent.ModifierFlags) { if let c = scrubbedCard { onOpen?(c.block, mods) } }
    private func menuScrubbed() { if let c = scrubbedCard { showMenu(for: c, from: stackFront) } }

    /// A face under the pointer: its card, once it has rested a moment —
    /// or at once, when a card shows already (moving along the faces, or
    /// scrubbing).
    private func hover(_ i: Int, at x: CGFloat) {
        if preview != nil { return showPreview(i, at: x) }
        guard i != previewed else { return }
        previewWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.showPreview(i, at: x) }
        previewWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.previewDelay, execute: work)
    }

    // MARK: The card under the bar

    /// Link `i`'s card under the bar, beneath `x` (in this view).
    private func showPreview(_ i: Int, at x: CGFloat) {
        guard fanned, i < cards.count, let host = superview else { return }
        let same = i == previewed && preview != nil
        if !same {
            guard let content = summary?(cards[i].block) else { return }
            let p = preview ?? {
                let p = Preview()
                host.addSubview(p, positioned: .above, relativeTo: nil)
                preview = p
                return p
            }()
            p.card.content = content
            previewed = i
        }
        guard let p = preview else { return }
        let h = SummaryCard.height(for: p.card.content) + 2
        // Under the bar, beneath the face (or the pointer, scrubbing), kept
        // inside what holds it.
        let anchor = convert(NSPoint(x: x, y: bounds.midY), to: host)
        let bar = convert(bounds, to: host)
        var left = anchor.x - Self.previewWidth / 2
        left = min(max(left, host.bounds.minX + 6), host.bounds.maxX - Self.previewWidth - 6)
        let gap: CGFloat = 8
        let top = host.isFlipped ? bar.maxY + gap : bar.minY - gap - h
        let target = NSRect(x: left, y: top, width: Self.previewWidth, height: h)
        if p.alphaValue == 0 || p.frame.isEmpty {
            p.frame = target
            p.alphaValue = 0
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = Motion.fast
                ctx.timingFunction = Motion.appear
                p.animator().alphaValue = 1
            }
        } else {
            // Following the pointer: no lag behind it.
            p.frame = target
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
    func debugFan(_ open: Bool) { fanned = open; layoutSubtreeIfNeeded() }
    var debugTitles: [String] {
        let one = cards.prefix(fanned ? singles : chips.count).map { ($0.outbound ? "→ " : "← ") + $0.title }
        return overflow ? one + ["[stack of \(cards.count - singles)]"] : one
    }
    /// How many faces peek out behind the front one, folded.
    var debugSheets: Int { fanned ? 0 : max(0, min(cards.count, 3) - 1) }
    var debugGeometry: String {
        (chips + [stackFront]).filter { !$0.isHidden }.map { NSStringFromRect($0.frame) }.joined(separator: " ")
            + (overflow ? " scrub \(NSStringFromRect(scrubRect))" : "")
    }
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
    /// Debugging: the nth face's card shown, as resting on it does.
    func debugPreview(_ n: Int) -> String {
        debugFan(true)
        guard n < chips.count else { return "no face \(n)" }
        showPreview(n, at: chips[n].frame.midX)
        return preview.map { "card: \($0.card.content.summary.title) at \(NSStringFromRect($0.frame))" } ?? "no card"
    }
    /// Debugging: the pointer at a fraction (0 by the stack, 1 at the
    /// bar's left) of the scrubbing: which link is in front, and its card.
    func debugScrub(_ fraction: CGFloat) -> String {
        debugFan(true)
        guard overflow else { return "no stack (\(singles) of \(cards.count) fit)" }
        let x = stackFront.frame.maxX - fraction * (stackFront.frame.maxX - scrubRect.minX) - 0.5
        let rest = cards.count - singles
        let k = min(rest - 1, max(0, Int(((stackFront.frame.maxX - x) / (stackFront.frame.maxX - scrubRect.minX)) * CGFloat(rest))))
        scrubbed = k
        dress(stackFront, cards[singles + k])
        showPreview(singles + k, at: x)
        return "\(singles) one by one; stack of \(rest), at \(k): \(cards[singles + k].title)"
    }

    // MARK: A face

    /// One linked block: its symbol on a small rounded square, a chevron
    /// in it on the side it points — right, links to; left, linked from.
    final class Chip: NSView {
        var onClick: ((NSEvent.ModifierFlags) -> Void)?
        var onMenu: (() -> Void)?
        var onDragStart: ((NSEvent) -> Void)?
        var symbol = "link" { didSet { icon.image = Theme.symbol(symbol, size: 12) } }
        var outbound = true { didSet { chevron.image = Self.chevron(outbound); needsLayout = true } }
        private static func chevron(_ outbound: Bool) -> NSImage? { Theme.symbol(outbound ? "chevron.right" : "chevron.left", size: 8, weight: .bold) }
        /// Folded behind the front one (1, 2), only its edge showing: nothing
        /// on it, in a stack's sheet greys, as a tile's sheets are.
        var depth = 0 {
            didSet {
                guard depth != oldValue else { return }
                icon.isHidden = depth > 0
                chevron.isHidden = depth > 0
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
        private let chevron = NSImageView()
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
            // The direction in the text's own colour, stronger than the symbol.
            chevron.contentTintColor = Theme.text
            chevron.image = Self.chevron(outbound)
            themed { $0.colour() }
            addSubview(icon)
            addSubview(chevron)
        }

        required init?(coder: NSCoder) { fatalError() }

        override func layout() {
            super.layout()
            let s: CGFloat = 12, c: CGFloat = 5
            // The symbol and the chevron side by side, the chevron on the
            // side it points, the two together centred.
            let left = (bounds.width - s - c - 1) / 2
            let iy = (bounds.height - s) / 2, cy = (bounds.height - 8) / 2
            if outbound {
                icon.frame = NSRect(x: left, y: iy, width: s, height: s)
                chevron.frame = NSRect(x: left + s + 1, y: cy, width: c, height: 8)
            } else {
                chevron.frame = NSRect(x: left, y: cy, width: c, height: 8)
                icon.frame = NSRect(x: left + c + 1, y: iy, width: s, height: s)
            }
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
