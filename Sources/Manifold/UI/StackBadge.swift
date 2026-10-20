import AppKit
import ManifoldCore

/// A stashed tile, as the stack badge names it.
struct StackCard: Equatable {
    var id: PlacementID
    var title: String
    var symbol: String
}

/// The stack behind a tile (§3.1), as a badge in the card's bar: a
/// capsule with a stack's symbol and how many. The pointer on it fans the
/// stashed tiles out below as rounded pills, each its symbol and name:
/// clicked, one comes out (⌥-click: it takes the top); dragged, it comes
/// out alone, wherever it's dropped.
final class StackBadge: NSView {
    var onPick: ((PlacementID, NSEvent.ModifierFlags) -> Void)?
    var onDrag: ((PlacementID, NSEvent, NSView) -> Void)?
    var cards: [StackCard] = [] {
        didSet {
            guard cards != oldValue else { return }
            if cards.map(\.id) == oldValue.map(\.id) {
                for (p, c) in zip(pills, cards) {
                    if p.title != c.title { p.title = c.title }
                    if p.symbol != c.symbol { p.symbol = c.symbol }
                }
                badge.title = "\(cards.count)"
                needsLayout = true
            } else {
                rebuild()
            }
        }
    }

    static let capsuleHeight: CGFloat = 22
    static let step: CGFloat = 26
    static let mostWidth: CGFloat = 260

    private let badge = LinkBadge.Capsule()
    private var pills: [LinkBadge.Capsule] = []
    private var fanned = false { didSet { if fanned != oldValue { needsLayout = true } } }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        badge.symbol = "square.stack"
        badge.toolTip = "The stack behind this tile"
        badge.onClick = { [weak self] _ in self?.fanned.toggle() }
        addSubview(badge)
    }

    required init?(coder: NSCoder) { fatalError() }

    /// How much of the tile it needs: the capsule, and room below for the fan.
    var wantedSize: NSSize {
        let widest = max(badge.wantedWidth, pills.map(\.wantedWidth).max() ?? 0)
        return NSSize(width: min(widest, Self.mostWidth), height: Self.capsuleHeight + CGFloat(cards.count) * Self.step + 4)
    }

    private func rebuild() {
        for p in pills { p.removeFromSuperview() }
        pills = cards.map { card in
            let p = LinkBadge.Capsule()
            p.symbol = card.symbol
            p.title = card.title
            p.toolTip = "Click to bring it out; ⌥-click to put it on top; drag to take it elsewhere"
            p.isHidden = true
            let id = card.id
            p.onClick = { [weak self] over in self?.onPick?(id, over ? [.option] : []) }
            p.onDragStart = { [weak self, weak p] event in
                guard let self, let p else { return }
                self.fanned = false
                self.onDrag?(id, event, p)
            }
            addSubview(p)
            return p
        }
        badge.title = "\(cards.count)"
        needsLayout = true
    }

    override func layout() {
        super.layout()
        let w = bounds.width
        let bw = min(badge.wantedWidth, w)
        let capsuleY = bounds.height - Self.capsuleHeight
        badge.frame = NSRect(x: w - bw, y: capsuleY, width: bw, height: Self.capsuleHeight)
        for (i, p) in pills.enumerated() {
            let pw = min(p.wantedWidth, w)
            let y = capsuleY - 4 - CGFloat(i + 1) * Self.step + (Self.step - Self.capsuleHeight)
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
        for c in [badge] + pills { c.hovered = !c.isHidden && c.frame.contains(p) }
    }

    override func mouseExited(with event: NSEvent) {
        fanned = false
        for c in [badge] + pills { c.hovered = false }
    }

    func debugFan(_ open: Bool) { fanned = open }
    var debugTitles: [String] { pills.map(\.title) }
}
