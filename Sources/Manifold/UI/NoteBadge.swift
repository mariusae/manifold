import AppKit
import ManifoldCore

/// A note about a block, as its tile's badge names it.
struct NoteCard: Equatable {
    var id: BlockID
    var title: String
}

/// The notes about a block (§3.5): a small capsule at the tile's lower
/// right with a note's symbol and how many there are. The pointer on it
/// fans the notes out above it, each a capsule with its first words, to
/// click and go to; one note alone opens on a click.
final class NoteBadge: NSView {
    var onOpen: ((BlockID) -> Void)?
    var cards: [NoteCard] = [] {
        didSet {
            guard cards != oldValue else { return }
            if cards.map(\.id) == oldValue.map(\.id) {
                // The same notes, named afresh (a first line typed): in place.
                for (p, c) in zip(pills, cards) where p.title != c.title { p.title = c.title }
                badge.toolTip = cards.count == 1 ? cards[0].title : "\(cards.count) notes"
                needsLayout = true
            } else {
                rebuild()
            }
        }
    }

    static let capsuleHeight: CGFloat = 22
    static let step: CGFloat = 26
    static let mostWidth: CGFloat = 240

    private let badge = Capsule()
    private var pills: [Capsule] = []
    private var fanned = false { didSet { if fanned != oldValue { needsLayout = true } } }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        badge.symbol = "note.text"
        badge.onClick = { [weak self] in
            guard let self else { return }
            if self.cards.count == 1, let c = self.cards.first { self.onOpen?(c.id) } else { self.fanned.toggle() }
        }
        addSubview(badge)
    }

    required init?(coder: NSCoder) { fatalError() }

    /// How much of the tile it needs: the capsule, and room above for
    /// the fan.
    var wantedSize: NSSize {
        let widest = max(badge.wantedWidth, pills.map(\.wantedWidth).max() ?? 0)
        return NSSize(width: min(widest, Self.mostWidth), height: Self.capsuleHeight + CGFloat(cards.count) * Self.step + 4)
    }

    private func rebuild() {
        for p in pills { p.removeFromSuperview() }
        pills = cards.map { card in
            let p = Capsule()
            p.symbol = "note.text"
            p.title = card.title
            p.isHidden = true
            let id = card.id
            p.onClick = { [weak self] in self?.onOpen?(id) }
            addSubview(p)
            return p
        }
        badge.title = cards.count == 1 ? "" : "\(cards.count)"
        badge.toolTip = cards.count == 1 ? cards[0].title : "\(cards.count) notes"
        needsLayout = true
    }

    override func layout() {
        super.layout()
        let w = bounds.width
        let bw = min(badge.wantedWidth, w)
        badge.frame = NSRect(x: w - bw, y: 0, width: bw, height: Self.capsuleHeight)
        for (i, p) in pills.enumerated() {
            let pw = min(p.wantedWidth, w)
            let target = NSRect(x: w - pw, y: Self.capsuleHeight + 4 + CGFloat(i) * Self.step, width: pw, height: Self.capsuleHeight)
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
                })
            }
        }
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
    }

    override func mouseExited(with event: NSEvent) { fanned = false }

    /// Debugging: the fan, as the pointer resting on the badge would open it.
    func debugFan(_ open: Bool) { fanned = open }
    var debugTitles: [String] { pills.map(\.title) }

    /// A small opaque capsule: a symbol and a few words.
    final class Capsule: NSView {
        var onClick: (() -> Void)?
        private let icon = NSImageView()
        private let label = NSTextField(labelWithString: "")
        var symbol = "note.text" { didSet { icon.image = Theme.symbol(symbol, size: 10) } }
        var title = "" { didSet { label.stringValue = title; needsLayout = true } }

        override init(frame: NSRect) {
            super.init(frame: frame)
            wantsLayer = true
            layer?.cornerRadius = NoteBadge.capsuleHeight / 2
            layer?.cornerCurve = .continuous
            layer?.borderWidth = 0.5
            themed {
                $0.layer?.backgroundColor = Theme.panel.cgColor
                $0.layer?.borderColor = Theme.panelBorder.cgColor
            }
            icon.image = Theme.symbol(symbol, size: 10)
            icon.contentTintColor = Theme.secondaryText
            label.font = .systemFont(ofSize: 11, weight: .medium)
            label.textColor = Theme.text
            label.lineBreakMode = .byTruncatingTail
            label.maximumNumberOfLines = 1
            addSubview(icon)
            addSubview(label)
        }

        required init?(coder: NSCoder) { fatalError() }

        var wantedWidth: CGFloat {
            let text = title.isEmpty ? 0 : ceil(label.intrinsicContentSize.width) + 12
            return 10 + 14 + text + 10
        }

        override func layout() {
            super.layout()
            let h = bounds.height
            icon.frame = NSRect(x: 9, y: (h - 12) / 2, width: 14, height: 12)
            let lh = ceil(label.intrinsicContentSize.height)
            label.frame = NSRect(x: 29, y: ((h - lh) / 2).rounded(), width: max(bounds.width - 39, 0), height: lh)
            label.isHidden = title.isEmpty
        }

        override func resetCursorRects() { addCursorRect(bounds, cursor: .pointingHand) }
        override func mouseDown(with event: NSEvent) {}
        override func mouseUp(with event: NSEvent) {
            if bounds.contains(convert(event.locationInWindow, from: nil)) { onClick?() }
        }
    }
}
