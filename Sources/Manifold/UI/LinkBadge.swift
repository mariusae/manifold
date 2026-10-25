import AppKit
import ManifoldCore

/// A link a block has by hand, as its tile's badge names it: to a block
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

/// A block's links by hand (§3.5), in its tile's bar: the first link's
/// own pill — an arrow for its direction, the block's symbol and name, to
/// click and go to, and an × that breaks the link (one edge, so in both
/// readings at once). More than one, and the pill has sheets behind it,
/// as a stack of paper; the pointer on it fans the rest out below.
final class LinkBadge: NSView {
    /// A link clicked: the block, and the keys held (⌘ beside, ⌥ over,
    /// ⇧⌘ the system's app).
    var onOpen: ((BlockID, NSEvent.ModifierFlags) -> Void)?
    var onBreak: ((String) -> Void)?
    /// Right-clicked: the neighborhood map, the big view of the links.
    var onMap: (() -> Void)?
    var cards: [LinkCard] = [] {
        didSet {
            guard cards != oldValue else { return }
            if cards.map(\.link) == oldValue.map(\.link) {
                // The same links, named afresh (a first line typed): in place.
                for (p, c) in zip([badge] + pills, cards) {
                    if p.title != c.title { p.title = c.title }
                    if p.symbol != c.symbol { p.symbol = c.symbol }
                }
                badge.toolTip = tooltip
                needsLayout = true
            } else {
                rebuild()
            }
        }
    }

    static let capsuleHeight: CGFloat = 22
    static let step: CGFloat = 26
    static let mostWidth: CGFloat = 260
    /// The most of the bar the first link's pill takes.
    static let barWidth: CGFloat = 200

    /// At a tile's upper right the fan opens downward.
    var fansDown = false { didSet { if fansDown != oldValue { needsLayout = true } } }
    /// The first link, in the bar.
    private let badge = Capsule()
    /// The rest, fanned out.
    private var pills: [Capsule] = []
    /// The sheets peeking out behind the first link's pill, for the rest.
    private var sheets: [CAShapeLayer] = []
    private var fanned = false { didSet { if fanned != oldValue { needsLayout = true } } }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        // Its sheets' layers coloured as laid out: again when light and dark switch.
        themed { $0.needsLayout = true }
        // The sheets rise above the pill, out of the view's frame.
        clipsToBounds = false
        layer?.masksToBounds = false
        badge.breaksOnHover = true
        badge.onClick = { [weak self] mods in
            guard let self, let c = self.cards.first else { return }
            self.onOpen?(c.block, mods)
        }
        badge.onMenu = { [weak self] in self?.showMenu() }
        badge.onDragStart = { [weak self] event in
            guard let self, let c = self.cards.first else { return }
            self.drag(c.block, from: self.badge, event)
        }
        addSubview(badge)
    }

    required init?(coder: NSCoder) { fatalError() }

    /// A link's pill dragged: the block, to bring where it's dropped; with
    /// ⇧ what it stands for (its path, its link), as a tile's pill is.
    private func drag(_ block: BlockID, from view: NSView, _ event: NSEvent) {
        guard let item = Drags.block?(block, event.modifierFlags) else { return }
        let drag = NSDraggingItem(pasteboardWriter: item)
        // The pill itself, under the pointer.
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

    /// The capsule's menu: the map, and the link broken.
    private func showMenu() {
        let menu = NSMenu()
        menu.addItem(ClosureMenuItem("Show the Neighborhood Map", symbol: "point.3.connected.trianglepath.dotted") { [weak self] in self?.onMap?() })
        if let c = cards.first, c.breakable {
            menu.addItem(ClosureMenuItem("Break the Link", symbol: "xmark") { [weak self] in self?.onBreak?(c.link) })
        }
        guard let event = NSApp.currentEvent else { return }
        NSMenu.popUpContextMenu(menu, with: event, for: badge)
    }

    private var tooltip: String {
        guard let c = cards.first else { return "" }
        let first = (c.outbound ? "Links to " : "Linked from ") + c.title
        return cards.count == 1 ? first : first + ", and \(cards.count - 1) more"
    }

    /// The most the bar gives the first link's pill, its sheets aside:
    /// shrunk, it shows its arrow and symbol, then its arrow alone.
    var capsuleLimit: CGFloat = .infinity { didSet { if capsuleLimit != oldValue { needsLayout = true } } }
    /// The first link's pill's width, as the bar has room for it.
    /// The bar's limit counts the sheets beside the capsule, as its wanted
    /// width does: the capsule gets what's left of it (else, narrowed, it
    /// ran over the tile's name by the sheets' width).
    var capsuleWidth: CGFloat { min(min(badge.wantedWidth, Self.barWidth), bounds.width - sheetRoom, capsuleLimit - sheetRoom) }
    /// What the first link's pill would take of the bar, its sheets included.
    var capsuleWantedWidth: CGFloat { min(badge.wantedWidth, Self.barWidth) + sheetRoom }
    /// The room the sheets take to the pill's right (kept while fanned, so the pill stays put).
    private var sheetRoom: CGFloat { CGFloat(min(pills.count, 2)) * Self.sheetStep }
    static let sheetStep: CGFloat = 4

    /// How much of the tile it needs: the pill, and room for the fan.
    var wantedSize: NSSize {
        let widest = max(capsuleWantedWidth, (pills.map(\.wantedWidth).max() ?? 0) + sheetRoom)
        return NSSize(width: min(widest, Self.mostWidth), height: Self.capsuleHeight + CGFloat(pills.count) * Self.step + 4)
    }

    private func configure(_ p: Capsule, _ card: LinkCard) {
        p.direction = card.outbound ? "arrow.right" : "arrow.left"
        p.symbol = card.symbol
        p.title = card.title
    }

    private func rebuild() {
        for p in pills { p.removeFromSuperview() }
        if let first = cards.first {
            configure(badge, first)
            badge.onBreak = first.breakable ? { [weak self] in
                guard let self, let c = self.cards.first else { return }
                self.onBreak?(c.link)
            } : nil
        }
        pills = cards.dropFirst().map { card in
            let p = Capsule()
            configure(p, card)
            p.toolTip = card.breakable ? (card.outbound ? "Links to it" : "Linked from it") : (card.outbound ? "Shows it" : "Shown in it")
            p.isHidden = true
            let block = card.block, link = card.link
            p.onClick = { [weak self] mods in self?.onOpen?(block, mods) }
            p.onBreak = card.breakable ? { [weak self] in self?.onBreak?(link) } : nil
            p.onDragStart = { [weak self, weak p] event in
                guard let self, let p else { return }
                self.drag(block, from: p, event)
            }
            addSubview(p)
            return p
        }
        badge.toolTip = tooltip
        if pills.isEmpty { fanned = false }
        needsLayout = true
    }

    override func layout() {
        super.layout()
        let w = bounds.width
        let bw = capsuleWidth
        let capsuleY = fansDown ? bounds.height - Self.capsuleHeight : 0
        // Its sheets to its right, the stack ending where a lone pill would.
        let right = w - sheetRoom
        // Fanned out, every pill (the first too) as wide as the widest, so
        // the stack reads as one; folded, the first as the bar has room for.
        let common = min(max(bw, pills.map(\.wantedWidth).max() ?? 0), right)
        let first = NSRect(x: right - (fanned ? common : bw), y: capsuleY, width: fanned ? common : bw, height: Self.capsuleHeight)
        if badge.frame != first {
            if badge.frame.isEmpty || !(badge.layer?.animationKeys()?.isEmpty ?? true) {
                badge.frame = first
            } else {
                NSAnimationContext.runAnimationGroup { ctx in
                    ctx.duration = Motion.base
                    ctx.timingFunction = Motion.appear
                    badge.animator().frame = first
                }
            }
        }
        // Where the first pill is going, not where it is mid-animation:
        // the sheets and the folding pills go by that.
        layoutSheets(around: first)
        for (i, p) in pills.enumerated() {
            let pw = common
            let y = fansDown ? capsuleY - 4 - CGFloat(i + 1) * Self.step + (Self.step - Self.capsuleHeight) : Self.capsuleHeight + 4 + CGFloat(i) * Self.step
            let target = NSRect(x: right - pw, y: y, width: pw, height: Self.capsuleHeight)
            if fanned {
                if p.isHidden {
                    p.frame = first
                    p.isHidden = false
                    NSAnimationContext.runAnimationGroup { ctx in
                        ctx.duration = Motion.base
                        ctx.timingFunction = Motion.appear
                        p.animator().frame = target
                    }
                } else if p.layer?.animationKeys()?.isEmpty ?? true {
                    p.frame = target
                }
            } else if !p.isHidden {
                NSAnimationContext.runAnimationGroup({ ctx in
                    ctx.duration = Motion.fast
                    p.animator().frame = first
                }, completionHandler: { [weak self, weak p] in
                    guard let self, let p, !self.fanned else { return }
                    p.isHidden = true
                    self.window?.invalidateCursorRects(for: p)
                })
            }
        }
        // The capsules moved: their cursor rects (the pointing hand) with them.
        for c in [badge] + pills { window?.invalidateCursorRects(for: c) }
    }

    /// Behind the first link's pill, one sheet for each further link (two
    /// at most), each peeking out a little further to its right and a
    /// little shorter than the one before, as a stack of cards; gone while
    /// the rest are fanned out.
    private func layoutSheets(around first: NSRect) {
        let wanted = fanned ? 0 : min(pills.count, 2)
        while sheets.count > wanted { sheets.removeLast().removeFromSuperlayer() }
        while sheets.count < wanted {
            let l = CAShapeLayer()
            l.lineWidth = 0.5
            layer?.insertSublayer(l, below: badge.layer)
            sheets.append(l)
        }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        effectiveAppearance.performAsCurrentDrawingAppearance {
            for (i, l) in sheets.enumerated() {
                let level = CGFloat(i + 1)
                let r = first.insetBy(dx: 0, dy: 1.5 * level).offsetBy(dx: Self.sheetStep * level, dy: 0)
                l.zPosition = -level
                l.path = CGPath(roundedRect: r, cornerWidth: r.height / 2, cornerHeight: r.height / 2, transform: nil)
                l.fillColor = Theme.sheet(level: i + 1).cgColor
                l.strokeColor = EdgeColor.control.cgColor
            }
        }
        CATransaction.commit()
    }

    /// Only the capsules take the mouse; between them, the tile does.
    override func hitTest(_ point: NSPoint) -> NSView? {
        let p = convert(point, from: superview)
        for v in [badge] + pills where !v.isHidden && v.frame.contains(p) { return v.hitTest(point) ?? v }
        return nil
    }

    override func updateTrackingAreas() {
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
        super.updateTrackingAreas()
    }

    override func mouseMoved(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        if !pills.isEmpty {
            let over = ([badge] + pills).contains { !$0.isHidden && $0.frame.insetBy(dx: -6, dy: -4).contains(p) }
            if over { fanned = true } else if fanned, !badge.frame.insetBy(dx: -10, dy: -10).contains(p) { fanned = false }
        }
        // The capsule under the pointer is ringed: the one a click takes.
        for c in [badge] + pills { c.hovered = !c.isHidden && c.frame.contains(p) }
    }

    override func mouseExited(with event: NSEvent) {
        fanned = false
        for c in [badge] + pills { c.hovered = false }
    }

    /// Debugging: the fan, as the pointer resting on the pill would open it.
    func debugFan(_ open: Bool) { fanned = open && !pills.isEmpty }
    var debugTitles: [String] { ([badge] + pills).map { ($0.direction == "arrow.right" ? "→ " : "← ") + $0.title } }
    var debugSheets: Int { sheets.count }
    /// Debugging: the first pill's frame and each sheet's, in the badge.
    var debugGeometry: String {
        "pill \(NSStringFromRect(badge.frame)) sheets " + sheets.map { NSStringFromRect($0.path?.boundingBox ?? .zero) }.joined(separator: " ")
    }
    /// Debugging: the first link's pill's middle, in the window from its top left.
    var debugCapsuleCenter: NSPoint? {
        guard let frameView = window?.contentView?.superview else { return nil }
        let r = badge.convert(badge.bounds, to: nil)
        return NSPoint(x: r.midX, y: frameView.bounds.height - r.midY)
    }
    /// Debugging: the × of the nth link (the first in the bar), as clicked.
    func debugBreak(_ n: Int) -> Bool {
        let all = [badge] + pills
        guard n < all.count else { return false }
        all[n].onBreak?()
        return true
    }

    /// A small opaque capsule: an arrow for the direction, a symbol, a
    /// few words, and an × to break the link.
    final class Capsule: NSView {
        /// Clicked: whether ⌥ was held.
        var onClick: ((NSEvent.ModifierFlags) -> Void)?
        /// Dragged a little: what to do with the drag (a stack's pill comes out).
        var onDragStart: ((NSEvent) -> Void)?
        /// Right-clicked: its menu.
        var onMenu: (() -> Void)?
        private var downAt: NSPoint?
        /// With this set, an × at the right end, to call.
        var onBreak: (() -> Void)? { didSet { updateClose(); needsLayout = true } }
        /// The × only under the pointer (in a tile's bar, beside the tile's own ×); its room kept.
        var breaksOnHover = false { didSet { updateClose() } }
        private func updateClose() { close.isHidden = onBreak == nil || compact || (breaksOnHover && !hovered) }
        /// Too narrow for words: the arrow and the symbol, or the arrow alone.
        private var compact = false
        private let arrow = NSImageView()
        private let icon = NSImageView()
        private let label = NSTextField(labelWithString: "")
        private let close = NSImageView()
        var direction: String? { didSet { arrow.image = direction.flatMap { Theme.symbol($0, size: 9, weight: .semibold) }; arrow.isHidden = direction == nil; needsLayout = true } }
        /// Under the pointer: ringed in the accent, as a fanned pill is.
        var hovered = false {
            didSet {
                guard hovered != oldValue else { return }
                effectiveAppearance.performAsCurrentDrawingAppearance {
                    layer?.borderColor = (hovered ? EdgeColor.accentStrong : EdgeColor.hairline).cgColor
                }
                layer?.borderWidth = hovered ? 1.5 : LinkCapsule.edgeWidth
                updateClose()
            }
        }
        var symbol = "link" { didSet { icon.image = Theme.symbol(symbol, size: 10) } }
        var title = "" { didSet { label.stringValue = title; needsLayout = true } }

        override init(frame: NSRect) {
            super.init(frame: frame)
            wantsLayer = true
            layer?.cornerRadius = LinkBadge.capsuleHeight / 2
            layer?.cornerCurve = .continuous
            layer?.borderWidth = LinkCapsule.edgeWidth
            themed {
                $0.layer?.backgroundColor = LinkCapsule.fill.cgColor
                $0.layer?.borderColor = LinkCapsule.edge.cgColor
            }
            arrow.contentTintColor = Theme.secondaryText
            arrow.isHidden = true
            icon.image = Theme.symbol(symbol, size: 10)
            icon.contentTintColor = Theme.secondaryText
            label.font = LinkCapsule.font
            label.textColor = Theme.text
            label.lineBreakMode = .byTruncatingTail
            label.maximumNumberOfLines = 1
            close.image = Theme.symbol("xmark", size: 8, weight: .bold)
            close.contentTintColor = Theme.secondaryText
            close.isHidden = true
            close.toolTip = "Break the link"
            addSubview(arrow)
            addSubview(icon)
            addSubview(label)
            addSubview(close)
        }

        required init?(coder: NSCoder) { fatalError() }

        private var arrowWidth: CGFloat { direction == nil ? 0 : 14 }
        private var closeWidth: CGFloat { onBreak == nil ? 0 : 18 }

        var wantedWidth: CGFloat {
            let text = title.isEmpty ? 0 : ceil(label.intrinsicContentSize.width) + 12
            return 10 + arrowWidth + 14 + text + closeWidth + 10
        }

        override func layout() {
            super.layout()
            let h = bounds.height
            let w = bounds.width
            // Shrinkage: under the room for a word of the title, the words
            // go; under the room for the symbol, the symbol goes too, and
            // the arrow sits in the middle alone.
            let wordRoom = 10 + arrowWidth + 20 + 24
            compact = w < wordRoom
            updateClose()
            if w < 44 {
                let only = direction == nil ? icon : arrow
                only.frame = NSRect(x: (w - 12) / 2, y: (h - 12) / 2, width: 12, height: 12)
                arrow.isHidden = direction == nil
                icon.isHidden = direction != nil
                label.isHidden = true
                return
            }
            arrow.isHidden = direction == nil
            icon.isHidden = false
            var x: CGFloat = compact ? (w - (arrowWidth + 14)) / 2 : 9
            if !arrow.isHidden {
                arrow.frame = NSRect(x: x, y: (h - 10) / 2, width: 10, height: 10)
                x += arrowWidth
            }
            icon.frame = NSRect(x: x, y: (h - 12) / 2, width: 14, height: 12)
            x += 20
            if compact { label.isHidden = true; return }
            let right = w - 10 - closeWidth
            if onBreak != nil { close.frame = NSRect(x: w - 10 - 12, y: (h - 12) / 2, width: 12, height: 12) }
            let lh = ceil(label.intrinsicContentSize.height)
            label.frame = NSRect(x: x, y: ((h - lh) / 2).rounded(), width: max(right - x, 0), height: lh)
            label.isHidden = title.isEmpty
        }

        /// Where the × takes a click: its end of the capsule.
        private var closeRect: NSRect { NSRect(x: bounds.width - 10 - closeWidth, y: 0, width: closeWidth + 10, height: bounds.height) }

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
            guard downAt != nil else { return }
            let p = convert(event.locationInWindow, from: nil)
            guard bounds.contains(p) else { return }
            if onBreak != nil, closeRect.contains(p) { onBreak?() } else { onClick?(event.modifierFlags) }
        }
    }
}

extension LinkBadge: NSDraggingSource {
    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        dragIsPath ? [.copy, .link, .generic] : (context == .withinApplication ? [.copy, .move] : [])
    }
}
