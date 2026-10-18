import AppKit
import ManifoldCore

/// A card of a block's neighborhood: the block, how it's connected, and
/// what made the connection.
struct FootCard {
    var block: BlockID
    var title: String
    var symbol: String
    /// The context the edge was made with, or how often for the trail.
    var detail: String
    var at: Stamp?
}

/// One bunch at a block's foot: an edge kind and direction, how many,
/// and its cards, newest first.
struct FootBunch {
    enum Role { case openedFrom, openedHere, found, sources, derived, placedIn, before, after, mentions }
    var role: Role
    var title: String
    var symbol: String
    var cards: [FootCard]
    var count: Int { cards.count }
}

/// The neighborhood at a block's foot (DESIGN.md §3.5), shown along the
/// bottom of its sheet when the pointer comes near: a capsule per edge
/// kind — opened from · 3, opened here · 5, placed in · 2, before,
/// after — each dealt out upward as cards when hovered, with the context
/// the edge was made with and its age. A card clicked recalls its block
/// beside this one; ⌘-clicked, in a column of its own.
final class FootView: NSView {
    var bunches: [FootBunch] = [] { didSet { needsLayout = true; needsDisplay = true; if hovered.map({ $0 >= bunches.count }) ?? false { hovered = nil } } }
    var onOpen: ((BlockID, _ newColumn: Bool) -> Void)?
    /// Dealt out or gathered: the owner lays it out again, taller or not.
    var onSpread: (() -> Void)?
    var onHoverChanged: ((Bool) -> Void)?

    static let capsuleHeight: CGFloat = 22
    static let cardHeight: CGFloat = 46
    static let cardWidth: CGFloat = 300
    static let margin: CGFloat = 8

    private var hovered: Int? { didSet { if hovered != oldValue { spread() } } }
    private var hoveredCard: Int? { didSet { if hoveredCard != oldValue { needsDisplay = true } } }
    private var dealt: CGFloat = 0
    private var target: CGFloat = 0
    private var link: CADisplayLink?
    private var lastTick: CFTimeInterval = 0

    override var isFlipped: Bool { false }

    /// The capsule row's width, and the height the dealt-out cards need.
    var isSpread: Bool { target == 1 || dealt > 0.01 }

    var size: NSSize {
        let rowWidth = capsuleFrames(at: 0).last?.maxX ?? 0
        let cards = hovered.map { bunches[$0].cards.count } ?? 0
        let cardsHeight = cards == 0 ? 0 : CGFloat(min(cards, 8)) * Self.cardHeight + 10
        let width = max(rowWidth + Self.margin, isSpread ? min(Self.cardWidth, max(bounds.width, 100) - 2 * Self.margin) + 2 * Self.margin : 0)
        return NSSize(width: width, height: Self.capsuleHeight + 2 * Self.margin + (isSpread ? cardsHeight : 0))
    }

    private static let font = NSFont.systemFont(ofSize: 11.5, weight: .medium)

    /// Where each capsule is along the bottom.
    private func capsuleFrames(at y: CGFloat) -> [NSRect] {
        var x = Self.margin
        return bunches.map { b in
            let text = NSAttributedString(string: "\(b.title) · \(b.count)", attributes: [.font: Self.font])
            let w = ceil(text.size().width) + 36
            defer { x += w + 6 }
            return NSRect(x: x, y: y + Self.margin, width: w, height: Self.capsuleHeight)
        }
    }

    /// Where a dealt-out card is, above its capsule: the newest nearest.
    /// As wide as a card may be here: the sheet's width, less margins.
    private var cardWidth: CGFloat { min(Self.cardWidth, bounds.width - 2 * Self.margin) }

    private func cardFrame(_ i: Int, in bunch: Int) -> NSRect {
        let capsule = capsuleFrames(at: 0)[bunch]
        let width = cardWidth
        let x = max(Self.margin, min(capsule.minX, bounds.width - width - Self.margin))
        let home = NSRect(x: capsule.minX, y: capsule.minY, width: capsule.width, height: capsule.height)
        let outY = capsule.maxY + 8 + CGFloat(i) * Self.cardHeight
        let out = NSRect(x: x, y: outY, width: width, height: Self.cardHeight - 4)
        let stagger: CGFloat = 0.3 * CGFloat(i) / CGFloat(max(min(bunches[bunch].cards.count, 8) - 1, 1))
        let f = max(0, min(1, (dealt - stagger) / (1 - stagger)))
        let e = f * f * (3 - 2 * f)
        return NSRect(x: home.minX + (out.minX - home.minX) * e, y: home.minY + (out.minY - home.minY) * e,
                      width: home.width + (out.width - home.width) * e, height: home.height + (out.height - home.height) * e)
    }

    // MARK: Dealing out

    private func spread() {
        target = hovered == nil ? 0 : 1
        if hovered != nil { onSpread?() }
        run()
    }

    private func run() {
        guard link == nil, window != nil else { return }
        let link = displayLink(target: self, selector: #selector(tick(_:)))
        link.add(to: .main, forMode: .common)
        self.link = link
        lastTick = 0
    }

    @objc private func tick(_ link: CADisplayLink) {
        let now = link.timestamp
        let dt = lastTick == 0 ? 1.0 / 60 : min(now - lastTick, 1.0 / 20)
        lastTick = now
        dealt += (target - dealt) * CGFloat(1 - exp(-dt * (target > dealt ? 14 : 18)))
        if abs(dealt - target) < 0.003 {
            dealt = target
            link.invalidate()
            self.link = nil
            if target == 0 { onSpread?() }
        }
        needsDisplay = true
    }

    override func removeFromSuperview() {
        link?.invalidate()
        link = nil
        super.removeFromSuperview()
    }

    // MARK: Drawing

    override func draw(_ dirtyRect: NSRect) {
        let frames = capsuleFrames(at: 0)
        for (i, b) in bunches.enumerated() {
            let r = frames[i]
            let path = NSBezierPath(roundedRect: r, xRadius: r.height / 2, yRadius: r.height / 2)
            NSGraphicsContext.saveGraphicsState()
            let shadow = NSShadow()
            shadow.shadowColor = NSColor.black.withAlphaComponent(0.12)
            shadow.shadowBlurRadius = 4
            shadow.shadowOffset = NSSize(width: 0, height: -1)
            shadow.set()
            (i == hovered ? Theme.selected : Theme.panel).setFill()
            path.fill()
            NSGraphicsContext.restoreGraphicsState()
            Theme.panelBorder.setStroke()
            path.lineWidth = 0.5
            path.stroke()
            if let icon = Theme.symbol(b.symbol, size: 10, weight: .semibold) {
                let tinted = icon.copy() as! NSImage
                tinted.isTemplate = true
                NSGraphicsContext.saveGraphicsState()
                Theme.secondaryText.set()
                tinted.draw(in: NSRect(x: r.minX + 10, y: r.midY - 6, width: 12, height: 12), from: .zero, operation: .sourceOver, fraction: 0.8)
                NSGraphicsContext.restoreGraphicsState()
            }
            let text = NSAttributedString(string: "\(b.title) · \(b.count)", attributes: [.font: Self.font, .foregroundColor: Theme.text])
            let h = ceil(text.size().height)
            text.draw(at: NSPoint(x: r.minX + 27, y: r.midY - h / 2))
        }
        guard let hovered, hovered < bunches.count, dealt > 0.01 else { return }
        let cards = Array(bunches[hovered].cards.prefix(8))
        let named = dealt > 0.6
        for (i, card) in cards.enumerated().reversed() {
            let r = cardFrame(i, in: hovered)
            let lifted = named && i == hoveredCard
            let path = NSBezierPath(roundedRect: r, xRadius: named ? 8 : r.height / 2, yRadius: named ? 8 : r.height / 2)
            NSGraphicsContext.saveGraphicsState()
            let shadow = NSShadow()
            shadow.shadowColor = NSColor.black.withAlphaComponent(0.14)
            shadow.shadowBlurRadius = 6
            shadow.shadowOffset = NSSize(width: 0, height: -2)
            shadow.set()
            (lifted ? Theme.selected : Theme.panel).setFill()
            path.fill()
            NSGraphicsContext.restoreGraphicsState()
            Theme.panelBorder.setStroke()
            path.lineWidth = 0.5
            path.stroke()
            guard named else { continue }
            let inner = r.insetBy(dx: 12, dy: 6)
            if let icon = Theme.symbol(card.symbol, size: 11) {
                let tinted = icon.copy() as! NSImage
                tinted.isTemplate = true
                NSGraphicsContext.saveGraphicsState()
                Theme.secondaryText.set()
                tinted.draw(in: NSRect(x: inner.minX, y: inner.maxY - 15, width: 14, height: 13), from: .zero, operation: .sourceOver, fraction: 0.9)
                NSGraphicsContext.restoreGraphicsState()
            }
            let truncating = NSMutableParagraphStyle()
            truncating.lineBreakMode = .byTruncatingTail
            var titleText = card.title
            if let at = card.at { titleText += "   " }
            let title = NSMutableAttributedString(string: titleText, attributes: [.font: NSFont.systemFont(ofSize: 12.5, weight: .semibold), .foregroundColor: Theme.text, .paragraphStyle: truncating])
            if let at = card.at {
                title.append(NSAttributedString(string: Self.ago(at), attributes: [.font: NSFont.systemFont(ofSize: 11), .foregroundColor: Theme.secondaryText, .paragraphStyle: truncating]))
            }
            title.draw(with: NSRect(x: inner.minX + 20, y: inner.maxY - 16, width: inner.width - 20, height: 16), options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
            let detail = NSAttributedString(string: card.detail, attributes: [.font: NSFont.systemFont(ofSize: 11.5), .foregroundColor: Theme.secondaryText, .paragraphStyle: truncating])
            detail.draw(with: NSRect(x: inner.minX + 20, y: inner.minY, width: inner.width - 20, height: 15), options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
        }
    }

    static let relative: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .short
        return f
    }()

    static func ago(_ stamp: Stamp) -> String {
        let d = stamp.date
        if Date().timeIntervalSince(d) < 60 { return "just now" }
        return relative.localizedString(for: d, relativeTo: Date())
    }

    /// Dealt out at once, for a script's picture.
    func debugSpread(_ bunch: Int) {
        guard bunch < bunches.count else { return }
        hovered = bunch
        link?.invalidate()
        link = nil
        dealt = 1
        target = 1
        onSpread?()
        needsDisplay = true
    }

    // MARK: The pointer

    override func updateTrackingAreas() {
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .mouseMoved, .activeAlways, .inVisibleRect], owner: self))
        super.updateTrackingAreas()
    }

    private func capsule(at p: NSPoint) -> Int? { capsuleFrames(at: 0).firstIndex { $0.contains(p) } }

    private func card(at p: NSPoint) -> Int? {
        guard let hovered, dealt > 0.6 else { return nil }
        return (0..<min(bunches[hovered].cards.count, 8)).first { cardFrame($0, in: hovered).contains(p) }
    }

    /// Only the capsules and cards are its own; between them, the sheet's.
    override func hitTest(_ point: NSPoint) -> NSView? {
        let local = convert(point, from: superview)
        return capsule(at: local) != nil || card(at: local) != nil ? self : nil
    }

    override func mouseEntered(with event: NSEvent) { onHoverChanged?(true) }

    override func mouseMoved(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        if let c = capsule(at: p) { hovered = c }
        hoveredCard = card(at: p)
        if hoveredCard != nil || capsule(at: p) != nil { NSCursor.pointingHand.set() }
    }

    override func mouseExited(with event: NSEvent) {
        hoveredCard = nil
        hovered = nil
        onHoverChanged?(false)
    }

    override func resetCursorRects() {
        for r in capsuleFrames(at: 0) { addCursorRect(r, cursor: .pointingHand) }
    }

    override func mouseDown(with event: NSEvent) {}

    override func mouseUp(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        if let i = card(at: p), let hovered {
            let card = bunches[hovered].cards[i]
            onOpen?(card.block, event.modifierFlags.contains(.command))
        } else if let c = capsule(at: p) {
            hovered = c
        }
    }
}
