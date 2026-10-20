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
    /// Put away: shown faded.
    var archived = false
}

/// A block's links by hand (§3.5): a small capsule at the tile's upper
/// right with a link's symbol and how many there are. The pointer on it
/// fans the links out below, each a capsule with an arrow for its
/// direction, the block's symbol and name, to click and go to, and an ×
/// that breaks the link — one edge, so in both readings at once. One link
/// alone opens on a click.
final class LinkBadge: NSView {
    /// A link clicked: the block, and whether ⌥ was held (over the tile).
    var onOpen: ((BlockID, Bool) -> Void)?
    var onBreak: ((String) -> Void)?
    var cards: [LinkCard] = [] {
        didSet {
            guard cards != oldValue else { return }
            if cards.map(\.link) == oldValue.map(\.link) {
                // The same links, named afresh (a first line typed): in place.
                for (p, c) in zip(pills, cards) {
                    if p.title != c.title { p.title = c.title }
                    if p.symbol != c.symbol { p.symbol = c.symbol }
                    p.alphaValue = c.archived ? 0.5 : 1
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

    /// At a tile's upper right the fan opens downward.
    var fansDown = false { didSet { if fansDown != oldValue { needsLayout = true } } }
    private let badge = Capsule()
    private var pills: [Capsule] = []
    private var fanned = false { didSet { if fanned != oldValue { needsLayout = true } } }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        badge.symbol = "link"
        badge.onClick = { [weak self] over in
            guard let self else { return }
            if self.cards.count == 1, let c = self.cards.first { self.onOpen?(c.block, over) } else { self.fanned.toggle() }
        }
        addSubview(badge)
    }

    required init?(coder: NSCoder) { fatalError() }

    private var tooltip: String {
        if cards.count == 1, let c = cards.first { return (c.outbound ? "Links to " : "Linked from ") + c.title }
        return "\(cards.count) links"
    }

    /// How much of the tile it needs: the capsule, and room for the fan.
    var wantedSize: NSSize {
        let widest = max(badge.wantedWidth, pills.map(\.wantedWidth).max() ?? 0)
        return NSSize(width: min(widest, Self.mostWidth), height: Self.capsuleHeight + CGFloat(cards.count) * Self.step + 4)
    }

    private func rebuild() {
        for p in pills { p.removeFromSuperview() }
        pills = cards.map { card in
            let p = Capsule()
            p.direction = card.outbound ? "arrow.right" : "arrow.left"
            p.symbol = card.symbol
            p.title = card.title
            p.toolTip = card.outbound ? "Links to it" : "Linked from it"
            p.alphaValue = card.archived ? 0.5 : 1
            p.isHidden = true
            let block = card.block, link = card.link
            p.onClick = { [weak self] over in self?.onOpen?(block, over) }
            p.onBreak = { [weak self] in self?.onBreak?(link) }
            addSubview(p)
            return p
        }
        badge.title = cards.count == 1 ? "" : "\(cards.count)"
        badge.toolTip = tooltip
        needsLayout = true
    }

    override func layout() {
        super.layout()
        let w = bounds.width
        let bw = min(badge.wantedWidth, w)
        let capsuleY = fansDown ? bounds.height - Self.capsuleHeight : 0
        badge.frame = NSRect(x: w - bw, y: capsuleY, width: bw, height: Self.capsuleHeight)
        for (i, p) in pills.enumerated() {
            let pw = min(p.wantedWidth, w)
            let y = fansDown ? capsuleY - 4 - CGFloat(i + 1) * Self.step + (Self.step - Self.capsuleHeight) : Self.capsuleHeight + 4 + CGFloat(i) * Self.step
            let target = NSRect(x: w - pw, y: y, width: pw, height: Self.capsuleHeight)
            if fanned {
                if p.isHidden {
                    p.frame = badge.frame
                    p.isHidden = false
                    NSAnimationContext.runAnimationGroup { ctx in
                        ctx.duration = 0.16
                        ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
                        p.animator().frame = target
                    }
                } else if p.layer?.animationKeys()?.isEmpty ?? true {
                    p.frame = target
                }
            } else if !p.isHidden {
                NSAnimationContext.runAnimationGroup({ ctx in
                    ctx.duration = 0.12
                    p.animator().frame = self.badge.frame
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
        let over = ([badge] + pills).contains { !$0.isHidden && $0.frame.insetBy(dx: -6, dy: -4).contains(p) }
        if over { fanned = true } else if fanned, !badge.frame.insetBy(dx: -10, dy: -10).contains(p) { fanned = false }
        // The capsule under the pointer is ringed: the one a click takes.
        for c in [badge] + pills { c.hovered = !c.isHidden && c.frame.contains(p) }
    }

    override func mouseExited(with event: NSEvent) {
        fanned = false
        for c in [badge] + pills { c.hovered = false }
    }

    /// Debugging: the fan, as the pointer resting on the badge would open it.
    func debugFan(_ open: Bool) { fanned = open }
    var debugTitles: [String] { pills.map { ($0.direction == "arrow.right" ? "→ " : "← ") + $0.title } }
    /// Debugging: the × of the nth fanned link, as clicked.
    func debugBreak(_ n: Int) -> Bool {
        guard n < pills.count else { return false }
        pills[n].onBreak?()
        return true
    }

    /// A small opaque capsule: an arrow for the direction, a symbol, a
    /// few words, and an × to break the link.
    final class Capsule: NSView {
        /// Clicked: whether ⌥ was held.
        var onClick: ((Bool) -> Void)?
        /// With this set, an × at the right end, to call.
        var onBreak: (() -> Void)? { didSet { close.isHidden = onBreak == nil; needsLayout = true } }
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
                    layer?.borderColor = (hovered ? Theme.accent.withAlphaComponent(0.9) : Theme.panelBorder).cgColor
                }
                layer?.borderWidth = hovered ? 1.5 : 0.5
            }
        }
        var symbol = "link" { didSet { icon.image = Theme.symbol(symbol, size: 10) } }
        var title = "" { didSet { label.stringValue = title; needsLayout = true } }

        override init(frame: NSRect) {
            super.init(frame: frame)
            wantsLayer = true
            layer?.cornerRadius = LinkBadge.capsuleHeight / 2
            layer?.cornerCurve = .continuous
            layer?.borderWidth = 0.5
            themed {
                $0.layer?.backgroundColor = Theme.panel.cgColor
                $0.layer?.borderColor = Theme.panelBorder.cgColor
            }
            arrow.contentTintColor = Theme.secondaryText
            arrow.isHidden = true
            icon.image = Theme.symbol(symbol, size: 10)
            icon.contentTintColor = Theme.secondaryText
            label.font = .systemFont(ofSize: 11, weight: .medium)
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
            var x: CGFloat = 9
            if !arrow.isHidden {
                arrow.frame = NSRect(x: x, y: (h - 10) / 2, width: 10, height: 10)
                x += arrowWidth
            }
            icon.frame = NSRect(x: x, y: (h - 12) / 2, width: 14, height: 12)
            x += 20
            let right = bounds.width - 10 - closeWidth
            if !close.isHidden { close.frame = NSRect(x: bounds.width - 10 - 12, y: (h - 12) / 2, width: 12, height: 12) }
            let lh = ceil(label.intrinsicContentSize.height)
            label.frame = NSRect(x: x, y: ((h - lh) / 2).rounded(), width: max(right - x, 0), height: lh)
            label.isHidden = title.isEmpty
        }

        /// Where the × takes a click: its end of the capsule.
        private var closeRect: NSRect { NSRect(x: bounds.width - 10 - closeWidth, y: 0, width: closeWidth + 10, height: bounds.height) }

        override func resetCursorRects() { addCursorRect(bounds, cursor: .pointingHand) }
        override func mouseDown(with event: NSEvent) {}
        override func mouseUp(with event: NSEvent) {
            let p = convert(event.locationInWindow, from: nil)
            guard bounds.contains(p) else { return }
            if onBreak != nil, closeRect.contains(p) { onBreak?() } else { onClick?(event.modifierFlags.contains(.option)) }
        }
    }
}
