import AppKit
import ManifoldCore

/// What a summary card shows of a tile: its summary, its block's symbol,
/// and a picture of it, for a kind a picture says more of.
struct SummaryCardContent {
    var id: PlacementID
    var symbol: String
    var summary: BlockSummary
    var thumbnail: NSImage?
    /// How long since it was seen, in a pill at the far right (⌘O's).
    var age: String? = nil
}

/// How long ago, in a pill (`Pill`).
enum AgeBadge {
    static func size(_ text: String) -> NSSize { Pill.size(text) }
    static func draw(_ text: String, in r: NSRect) { Pill.draw(text, in: r) }
}

/// An `AgeBadge` as a view, for a row laid out by views.
final class AgePill: NSView {
    var text: String? { didSet { if text != oldValue { needsDisplay = true; superview?.needsLayout = true } } }
    var wanted: NSSize? { text.map(AgeBadge.size) }
    override func draw(_ dirtyRect: NSRect) { if let text { AgeBadge.draw(text, in: bounds) } }
}

/// A tile as a card in a few lines (§3.1), one look for every kind: its
/// symbol, title and where it is, a note at the right (when, or its state,
/// in its tone's color), two or three lines of what it holds, a picture at
/// the right for a page or a PDF, a thin bar for progress. Chosen, ringed in
/// the accent.
final class SummaryCard: NSView {
    var content: SummaryCardContent { didSet { needsDisplay = true } }
    var chosen = false { didSet { if chosen != oldValue { needsDisplay = true } } }
    /// Set in something that's a card already (a hover card): no card of
    /// its own drawn, only what it says.
    var plain = false
    /// In a tile's body, the tile too short for its content (its bar
    /// naming it): its lines alone, from the top, as many as fit, the note
    /// at the right of the first, on the body's own ground.
    var inTile = false {
        didSet {
            guard inTile != oldValue else { return }
            plain = inTile
            effectiveAppearance.performAsCurrentDrawingAppearance { layer?.backgroundColor = inTile ? Theme.windowBackground.cgColor : nil }
            needsDisplay = true
        }
    }
    static let height: CGFloat = 88

    /// As tall as what it says: its title and its lines (a picture keeps
    /// it at full height) — where cards needn't line up, as a stack's do.
    static func height(for content: SummaryCardContent) -> CGFloat {
        if content.thumbnail != nil { return height }
        let lines = min(3, content.summary.lines.count)
        return min(height, 10 + 21 + CGFloat(lines) * 16 + 8)
    }
    /// Clicked, where it stands in for its tile; elsewhere a click is its
    /// container's.
    var onClick: (() -> Void)?

    override func mouseDown(with event: NSEvent) {
        guard let onClick else { return super.mouseDown(with: event) }
        onClick()
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { onClick != nil }

    init(_ content: SummaryCardContent) {
        self.content = content
        super.init(frame: .zero)
        wantsLayer = true
        // In a tile, on the body's ground, light or dark.
        themed { $0.layer?.backgroundColor = $0.inTile ? Theme.windowBackground.cgColor : nil }
    }

    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }

    private static let fill = NSColor.dynamic(NSColor(white: 0.995, alpha: 1), NSColor(white: 0.2, alpha: 1))

    private func toneColor(_ tone: BlockSummary.Tone) -> NSColor {
        switch tone {
        case .plain: Theme.secondaryText
        case .running: Status.runningText
        case .done: Status.done
        case .failed: Status.failed
        case .attention: Status.attention
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        let s = content.summary
        if inTile { Theme.windowBackground.setFill(); bounds.fill() }
        let card = inTile ? bounds : bounds.insetBy(dx: 1, dy: 1)
        let path = NSBezierPath(roundedRect: card, xRadius: Radius.surface, yRadius: Radius.surface)
        if !plain {
        NSGraphicsContext.saveGraphicsState()
        Elevation.resting.shadow.set()
        Self.fill.setFill()
        path.fill()
        NSGraphicsContext.restoreGraphicsState()
        if chosen {
            Theme.accent.withAlphaComponent(0.08).setFill()
            path.fill()
            let ring = NSBezierPath(roundedRect: card.insetBy(dx: 0.75, dy: 0.75), xRadius: Radius.surface - 0.5, yRadius: Radius.surface - 0.5)
            ring.lineWidth = 1.5
            EdgeColor.accentStrong.setStroke()
            ring.stroke()
        } else {
            EdgeColor.subtle.setStroke()
            path.lineWidth = 0.5
            path.stroke()
        }
        }
        let pad: CGFloat = 12
        // A picture at the right, its corners rounded.
        var right = card.maxX - pad
        if let thumb = content.thumbnail, thumb.size.width > 0, card.height > 36 {
            let h = min(card.height, SummaryCard.height) - 2 * 10
            let w = min(h * thumb.size.width / thumb.size.height, card.width * 0.32)
            let r = NSRect(x: card.maxX - 10 - w, y: card.minY + 10, width: w, height: h)
            NSGraphicsContext.saveGraphicsState()
            NSBezierPath(roundedRect: r, xRadius: Radius.control, yRadius: Radius.control).addClip()
            thumb.draw(in: r, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
            NSGraphicsContext.restoreGraphicsState()
            Theme.text.withAlphaComponent(0.12).setStroke()
            let border = NSBezierPath(roundedRect: r, xRadius: Radius.control, yRadius: Radius.control)
            border.lineWidth = 0.5
            border.stroke()
            right = r.minX - 10
        }
        var x = card.minX + pad
        let top = card.minY + 10
        if inTile {
            drawLines(s, x: x, right: right, top: top - 2, room: Int((card.height - 8) / 16))
            return
        }
        // The symbol, the title, where it is; the note at the right.
        let config = NSImage.SymbolConfiguration(pointSize: UIType.symbolSize, weight: .medium)
            .applying(NSImage.SymbolConfiguration(paletteColors: [Theme.secondaryText]))
        if let image = NSImage(systemSymbolName: content.symbol, accessibilityDescription: nil)?.withSymbolConfiguration(config) ?? Theme.symbol(content.symbol, size: UIType.symbolSize) {
            let size = image.size
            image.draw(in: NSRect(x: x, y: top + 9 - size.height / 2, width: size.width, height: size.height), from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
            x += 22
        }
        // Its age in a pill at the far right; the note before it.
        var titleRight = right
        if let age = content.age {
            let size = AgeBadge.size(age)
            let r = NSRect(x: titleRight - size.width, y: top, width: size.width, height: size.height)
            AgeBadge.draw(age, in: r)
            titleRight = r.minX - 8
        }
        var noteWidth: CGFloat = 0
        if let note = s.note {
            let n = NSAttributedString(string: note, attributes: [.font: UIType.detail, .foregroundColor: toneColor(s.tone)])
            noteWidth = n.size().width
            n.draw(at: NSPoint(x: titleRight - noteWidth, y: top + 1))
            noteWidth += 10
        }
        let titleRoom = titleRight - noteWidth - x
        let title = NSMutableAttributedString(string: s.title, attributes: [.font: UIType.title, .foregroundColor: Theme.text])
        if let place = s.place, !place.isEmpty {
            title.append(NSAttributedString(string: "  " + place, attributes: [.font: UIType.detail, .foregroundColor: Theme.tertiaryText]))
        }
        title.draw(with: NSRect(x: x, y: top, width: max(0, titleRoom), height: 18), options: [.truncatesLastVisibleLine, .usesLineFragmentOrigin])
        // Its lines, under the title, set in from the symbol.
        drawLines(s, x: x, right: right, top: top + 21, room: 3, note: false)
        drawProgress(s, in: card, pad: pad)
    }

    /// Its lines, `room` of them at most, from `top` — in a tile, the
    /// note at the right of the first.
    private func drawLines(_ s: BlockSummary, x: CGFloat, right: CGFloat, top: CGFloat, room: Int, note: Bool = true) {
        let style = NSMutableParagraphStyle()
        style.lineBreakMode = .byTruncatingTail
        var noteWidth: CGFloat = 0
        if note, let n = s.note {
            let a = NSAttributedString(string: n, attributes: [.font: UIType.detail, .foregroundColor: toneColor(s.tone)])
            noteWidth = a.size().width + 10
            a.draw(at: NSPoint(x: right - a.size().width, y: top + 1))
        }
        for (i, line) in s.lines.prefix(max(0, min(3, room))).enumerated() {
            let a = NSAttributedString(string: line, attributes: [
                .font: s.code ? FontTheme.code(11.5) : UIType.body, .foregroundColor: i == 0 ? Theme.text.withAlphaComponent(0.85) : Theme.secondaryText,
                .paragraphStyle: style,
            ])
            let r = i == 0 ? right - noteWidth : right
            a.draw(with: NSRect(x: x, y: top + CGFloat(i) * 16, width: max(0, r - x), height: 16), options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
        }
        if inTile { drawProgress(s, in: bounds, pad: 12) }
    }

    private func drawProgress(_ s: BlockSummary, in card: NSRect, pad: CGFloat) {
        if let p = s.progress {
            Flat.progress(in: NSRect(x: card.minX + pad, y: card.maxY - 5, width: card.width - 2 * pad, height: 2), fraction: p)
        }
    }
}

/// A stack fanned out (§3.1), as iOS opens a stack of notifications: in
/// place of its tile, a column of its tiles as summary cards — the top
/// first, then those behind, nearest first — scrolled through, the one
/// chosen ringed. ⌃⇥ moves the choice, the pointer chooses what it's over;
/// a card clicked comes to the top, one dragged comes out of the stack.
final class StackColumnView: NSView {
    private(set) var cards: [SummaryCard]
    /// The card chosen, by its place in the column (0, the top).
    private(set) var selection: Int
    private let scroll = NSScrollView()
    private let document = FlippedView()
    var onPick: ((PlacementID, NSEvent.ModifierFlags) -> Void)?
    var onDragOut: ((PlacementID, NSEvent) -> Void)?
    var onCancel: (() -> Void)?
    /// The card under the pointer is the one chosen (opened from the sheets
    /// or the button; from ⌃⇥, once the pointer moves over the cards).
    var followsPointer = false
    var onFollowsPointer: (() -> Void)?
    private var pointerSeenAt: NSPoint?
    private(set) var isClosing = false
    private var downAt: (card: Int, point: NSPoint)?
    private static let gap: CGFloat = 8, margin: CGFloat = 10

    /// `entries` top first.
    init(entries: [SummaryCardContent], selection: Int = 0) {
        cards = entries.map(SummaryCard.init)
        self.selection = selection
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = Radius.surface
        layer?.masksToBounds = true
        themed { $0.layer?.backgroundColor = Theme.windowBackground.blended(withFraction: 0.04, of: Theme.text)?.cgColor }
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.documentView = document
        addSubview(scroll)
        for c in cards { document.addSubview(c) }
        cards[selection].chosen = true
    }

    required init?(coder: NSCoder) { fatalError() }

    var selectedID: PlacementID { cards[selection].content.id }
    /// The tile that was the stack's top: the first card.
    var topID: PlacementID { cards[0].content.id }

    override func layout() {
        super.layout()
        scroll.frame = bounds
        let w = bounds.width - 2 * Self.margin
        for (i, c) in cards.enumerated() {
            c.frame = NSRect(x: Self.margin, y: Self.margin + CGFloat(i) * (SummaryCard.height + Self.gap), width: w, height: SummaryCard.height)
        }
        let h = Self.margin * 2 + CGFloat(cards.count) * (SummaryCard.height + Self.gap) - Self.gap
        document.frame = NSRect(x: 0, y: 0, width: bounds.width, height: max(h, bounds.height))
    }

    // MARK: Showing

    /// Opens: the cards dealt down from the top, one after another.
    func present() {
        layoutSubtreeIfNeeded()
        alphaValue = 0
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = Motion.fast
            animator().alphaValue = 1
        }
        for (i, c) in cards.enumerated() {
            guard let l = c.layer else { continue }
            let deal = CABasicAnimation(keyPath: "transform.translation.y")
            deal.fromValue = -CGFloat(i) * (SummaryCard.height + Self.gap) * 0.6
            deal.toValue = 0
            let fade = CABasicAnimation(keyPath: "opacity")
            fade.fromValue = i == 0 ? 1 : 0
            fade.toValue = 1
            let g = CAAnimationGroup()
            g.animations = [deal, fade]
            g.duration = Motion.spatial
            g.beginTime = CACurrentMediaTime() + Double(i) * 0.025
            g.fillMode = .backwards
            g.timingFunction = Motion.travel
            l.add(g, forKey: "deal")
        }
        reveal(selection)
    }

    /// Moves the choice along: down the column (deeper in the stack) for
    /// positive steps, round the ends.
    func move(_ delta: Int) {
        guard !isClosing else { return }
        choose(((selection + delta) % cards.count + cards.count) % cards.count)
    }

    func choose(_ i: Int) {
        guard !isClosing, cards.indices.contains(i), i != selection else { return }
        cards[selection].chosen = false
        selection = i
        cards[i].chosen = true
        reveal(i)
    }

    private func reveal(_ i: Int) {
        guard cards.indices.contains(i) else { return }
        document.scrollToVisible(cards[i].frame.insetBy(dx: 0, dy: -Self.margin))
    }

    /// Closes on `id` (the chosen card), then calls `done`.
    func dismiss(to id: PlacementID, done: @escaping () -> Void) {
        isClosing = true
        if let i = cards.firstIndex(where: { $0.content.id == id }) {
            cards[selection].chosen = false
            selection = i
            cards[i].chosen = true
        }
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = Motion.fast
            animator().alphaValue = 0
        }, completionHandler: done)
    }

    /// No views are held: nothing to give back.
    func tearDown(keeping: PlacementID? = nil, in column: NSView? = nil) {}

    // MARK: Pointer

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseMoved, .activeAlways, .inVisibleRect], owner: self))
    }

    private func card(at windowPoint: NSPoint) -> Int? {
        let p = document.convert(windowPoint, from: nil)
        return cards.firstIndex { $0.frame.contains(p) }
    }

    override func mouseMoved(with event: NSEvent) {
        guard !isClosing else { return }
        if !followsPointer {
            // From ⌃⇥: the pointer moved over the cards is the pointer wanted.
            guard let seen = pointerSeenAt else { pointerSeenAt = event.locationInWindow; return }
            guard hypot(event.locationInWindow.x - seen.x, event.locationInWindow.y - seen.y) > 6 else { return }
            followsPointer = true
            onFollowsPointer?()
        }
        if let i = card(at: event.locationInWindow) { choose(i) }
    }

    override func mouseDown(with event: NSEvent) {
        guard !isClosing else { return }
        guard let i = card(at: event.locationInWindow) else { onCancel?(); return }
        downAt = (i, event.locationInWindow)
    }

    override func mouseDragged(with event: NSEvent) {
        guard let down = downAt, hypot(event.locationInWindow.x - down.point.x, event.locationInWindow.y - down.point.y) > 3 else { return }
        downAt = nil
        onDragOut?(cards[down.card].content.id, event)
    }

    override func mouseUp(with event: NSEvent) {
        guard let down = downAt else { return }
        downAt = nil
        onPick?(cards[down.card].content.id, event.modifierFlags)
    }

    // MARK: Debugging

    func debugPick(_ i: Int) -> String {
        guard cards.indices.contains(i) else { return "no card \(i)" }
        onPick?(cards[i].content.id, [])
        return "picked \(cards[i].content.summary.title)"
    }

    func debugPointerMoves() {
        followsPointer = true
        onFollowsPointer?()
    }

    func debugHover(_ i: Int) -> String {
        guard cards.indices.contains(i) else { return "no card \(i)" }
        followsPointer = true
        choose(i)
        return "chosen \(cards[i].content.summary.title)"
    }

    /// Debugging: the cards, a line each, the chosen marked.
    var debugCards: String {
        cards.enumerated().map { i, c in
            let s = c.content.summary
            return (i == selection ? "*" : " ") + " \(s.title) [\(s.note ?? "")] " + s.lines.joined(separator: " | ") + (c.content.thumbnail == nil ? "" : " (picture)")
        }.joined(separator: "\n")
    }
}
