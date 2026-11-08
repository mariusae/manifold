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
    /// Its status by its title (`StatusMark`): the title shimmering while
    /// it works, a pill when it needs you.
    var mark: StatusMark? = nil
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
    var content: SummaryCardContent { didSet { needsDisplay = true; needsLayout = true } }
    private let shimmering = CardTitle()
    private lazy var shimmer = Shimmer(shimmering)
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
    var onClick: (() -> Void)? { didSet { window?.invalidateCursorRects(for: self) } }
    // Standing in for a tile, clicked: the pointing hand.
    override func resetCursorRects() { if onClick != nil { addCursorRect(bounds, cursor: .pointingHand) } }
    override func cursorUpdate(with event: NSEvent) { (onClick != nil ? NSCursor.pointingHand : NSCursor.arrow).set() }

    override func mouseDown(with event: NSEvent) {
        guard let onClick else { return super.mouseDown(with: event) }
        onClick()
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { onClick != nil }

    init(_ content: SummaryCardContent) {
        self.content = content
        super.init(frame: .zero)
        wantsLayer = true
        // The title, while it shimmers, is drawn by a view of its own (a
        // mask is a layer's): over where the card would draw it.
        shimmering.isHidden = true
        addSubview(shimmering)
        // In a tile, on the body's ground, light or dark.
        themed { $0.layer?.backgroundColor = $0.inTile ? Theme.windowBackground.cgColor : nil }
    }

    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }

    static let fill = NSColor.themed { $0.chrome.stack }

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
            // Chosen: a grey band and a darker edge, not the accent's.
            Theme.text.withAlphaComponent(0.05).setFill()
            path.fill()
            let ring = NSBezierPath(roundedRect: card.insetBy(dx: 0.75, dy: 0.75), xRadius: Radius.surface - 0.5, yRadius: Radius.surface - 0.5)
            ring.lineWidth = 1.5
            Theme.text.withAlphaComponent(0.35).setStroke()
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
        let top = card.minY + 10
        if inTile {
            drawLines(s, x: card.minX + pad, right: right, top: top - 2, room: Int((card.height - 8) / 16))
            return
        }
        // The symbol, the title, where it is; at the right, the age in a
        // pill, the status's pill, the note.
        let head = headline(card: card, right: right)
        if let image = Theme.symbol(content.symbol, size: UIType.symbolSize, weight: .medium, color: Theme.secondaryText) {
            let size = image.size
            image.draw(in: NSRect(x: card.minX + pad, y: top + 9 - size.height / 2, width: size.width, height: size.height), from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
        }
        if let age = content.age, let r = head.age { AgeBadge.draw(age, in: r) }
        if let kind = content.mark?.pill, let r = head.pill { StatusPill.draw(kind, in: r) }
        if let note = head.noteText, let at = head.note {
            // The status shown by the pill or the shimmer, the note is only
            // when, in grey.
            let ink = content.mark.map { $0.pill != nil || $0.shimmer } == true ? Theme.secondaryText : toneColor(s.tone)
            NSAttributedString(string: note, attributes: [.font: UIType.detail, .foregroundColor: ink]).draw(at: at)
        }
        if !head.shimmers { head.title.draw(with: head.titleRect, options: [.truncatesLastVisibleLine, .usesLineFragmentOrigin]) }
        let x = head.titleRect.minX
        // Its lines, under the title, set in from the symbol.
        drawLines(s, x: x, right: right, top: top + 21, room: 3, note: false)
        drawProgress(s, in: card, pad: pad)
    }

    /// Where the title goes, and what's at its right: the age's pill, the
    /// status's, the note — for drawing, and for the title's own view
    /// while it shimmers.
    private func headline(card: NSRect, right: CGFloat)
        -> (title: NSAttributedString, titleRect: NSRect, age: NSRect?, pill: NSRect?, note: NSPoint?, noteText: String?, shimmers: Bool) {
        let s = content.summary
        let pad: CGFloat = 12, top = card.minY + 10
        let x = card.minX + pad + (Theme.symbol(content.symbol, size: UIType.symbolSize, weight: .medium) == nil ? 0 : 22)
        var titleRight = right
        var age: NSRect?, pill: NSRect?, note: NSPoint?
        if let a = content.age {
            let size = AgeBadge.size(a)
            age = NSRect(x: titleRight - size.width, y: top, width: size.width, height: size.height)
            titleRight = age!.minX - 8
        }
        if let kind = content.mark?.pill {
            let size = StatusPill.size(kind)
            pill = NSRect(x: titleRight - size.width, y: top + 1, width: size.width, height: size.height)
            titleRight = pill!.minX - 8
        }
        // "running", "working": the shimmer or the pill says so.
        let shows = content.mark.map { $0.pill != nil || $0.shimmer } == true
        let noteText = shows && ["running", "working", "searching"].contains(s.note ?? "") ? nil : s.note
        if let n = noteText {
            let w = NSAttributedString(string: n, attributes: [.font: UIType.detail]).size().width
            note = NSPoint(x: titleRight - w, y: top + 1)
            titleRight -= w + 10
        }
        let title = NSMutableAttributedString(string: s.title, attributes: [.font: UIType.title, .foregroundColor: Theme.text])
        if let place = s.place, !place.isEmpty {
            title.append(NSAttributedString(string: "  " + place, attributes: [.font: UIType.detail, .foregroundColor: Theme.tertiaryText]))
        }
        let rect = NSRect(x: x, y: top, width: max(0, titleRight - x), height: 18)
        // Shimmering only on screen: a card painted into a picture (a
        // pill's, a link's) draws its title as ever.
        return (title, rect, age, pill, note, noteText, content.mark?.shimmer == true && !inTile && window != nil)
    }

    /// The picture's room at the right, as `draw` leaves it.
    private var titleRoomRight: CGFloat {
        let card = inTile ? bounds : bounds.insetBy(dx: 1, dy: 1)
        var right = card.maxX - 12
        if let thumb = content.thumbnail, thumb.size.width > 0, card.height > 36 {
            let h = min(card.height, SummaryCard.height) - 2 * 10
            right = card.maxX - 10 - min(h * thumb.size.width / thumb.size.height, card.width * 0.32) - 10
        }
        return right
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        needsLayout = true
        needsDisplay = true
    }

    override func layout() {
        super.layout()
        let card = inTile ? bounds : bounds.insetBy(dx: 1, dy: 1)
        let head = headline(card: card, right: titleRoomRight)
        shimmering.isHidden = !head.shimmers
        shimmering.text = head.title
        shimmering.frame = head.titleRect
        shimmer.on = head.shimmers
        shimmer.layout()
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

/// A card's title while it shimmers: drawn as the card draws it, in a
/// view of its own for the mask.
final class CardTitle: NSView {
    var text = NSAttributedString() { didSet { if text != oldValue { needsDisplay = true } } }
    override var isFlipped: Bool { true }
    override func draw(_ dirtyRect: NSRect) { text.draw(with: bounds, options: [.truncatesLastVisibleLine, .usesLineFragmentOrigin]) }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

/// A switcher's tiles (⌥⇥, ⌃⇥) as a column of their summary cards, the
/// latest settled on first, scrolled through, the one chosen ringed. ⇥
/// moves the choice; once the pointer moves over the cards, it chooses
/// what it's over; a card clicked is gone to.
final class CardColumnView: NSView {
    private(set) var cards: [SummaryCard]
    /// The card chosen, by its place in the column (0, the top).
    private(set) var selection: Int
    private let scroll = NSScrollView()
    private let document = FlippedView()
    var onPick: ((PlacementID, NSEvent.ModifierFlags) -> Void)?
    var onCancel: (() -> Void)?
    /// The card under the pointer is the one chosen, once the pointer
    /// moves over the cards.
    private var followsPointer = false
    private var pointerSeenAt: NSPoint?
    private var downAt: Int?
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

    /// As tall as `count` cards in a column want.
    static func height(for count: Int) -> CGFloat { margin * 2 + CGFloat(count) * (SummaryCard.height + gap) - gap }

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

    /// Each card where it is in `view`'s terms (.zero where the column
    /// cuts it off), with a picture of it as it's drawn, on its ground.
    func cardPictures(in view: NSView) -> [(id: PlacementID, frame: NSRect, picture: CGImage?, ground: CGColor)] {
        layoutSubtreeIfNeeded()
        let shown = convert(bounds, to: view)
        return cards.map { c in
            let f = c.convert(c.bounds, to: view)
            // Out of view: no picture (it isn't flown), none drawn.
            guard shown.contains(f) else { return (c.content.id, .zero, nil, GridView.ground(of: c)) }
            var picture: CGImage?
            let scale = window?.backingScaleFactor ?? 2
            if let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(c.bounds.width * scale), pixelsHigh: Int(c.bounds.height * scale),
                                          bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                          bytesPerRow: 0, bitsPerPixel: 0) {
                rep.size = c.bounds.size
                c.cacheDisplay(in: c.bounds, to: rep)
                picture = rep.cgImage
            }
            return (c.content.id, f, picture, GridView.ground(of: c))
        }
    }

    /// The cards themselves out of sight (their pictures on their way in).
    var cardsShown = true { didSet { document.isHidden = !cardsShown } }

    /// Opens: the cards fanned out from under the top, one after another —
    /// or, `dealt` false, shown as they are.
    func present(dealt: Bool = true) {
        layoutSubtreeIfNeeded()
        guard dealt else { return reveal(selection) }
        alphaValue = 0
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = Motion.fast
            animator().alphaValue = 1
        }
        // Fanned out from under the top card, each from where the one
        // before it is, the nearest first.
        for (i, c) in cards.enumerated() {
            guard let l = c.layer else { continue }
            l.zPosition = -CGFloat(i)
            let deal = CABasicAnimation(keyPath: "transform.translation.y")
            deal.fromValue = Motion.distance(-CGFloat(i) * (c.frame.height + Self.gap))
            deal.toValue = 0
            let fade = CABasicAnimation(keyPath: "opacity")
            fade.fromValue = i == 0 ? 0.6 : 0
            fade.toValue = 1
            let g = CAAnimationGroup()
            g.animations = [deal, fade]
            g.duration = Motion.spatial * 1.25
            g.beginTime = CACurrentMediaTime() + Double(i) * 0.03 * Motion.slowdown
            g.fillMode = .backwards
            g.timingFunction = Motion.travel
            l.add(g, forKey: "deal")
        }
        reveal(selection)
    }

    func choose(_ i: Int) {
        guard cards.indices.contains(i), i != selection else { return }
        cards[selection].chosen = false
        selection = i
        cards[i].chosen = true
        reveal(i)
    }

    private func reveal(_ i: Int) {
        guard cards.indices.contains(i) else { return }
        document.scrollToVisible(cards[i].frame.insetBy(dx: 0, dy: -Self.margin))
    }

    // MARK: Pointer

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseMoved, .mouseEnteredAndExited, .cursorUpdate, .activeAlways, .inVisibleRect], owner: self))
    }

    /// Over the cards, the pointing hand: each is a place to click — set on
    /// every move too, as what's under the column (a terminal, a text)
    /// hears the pointer's moves through it and would set its own.
    override func cursorUpdate(with event: NSEvent) { setCursor(event) }
    override func mouseEntered(with event: NSEvent) { setCursor(event) }

    /// The hand over a card; between them (a click there lets it go), the arrow.
    private func setCursor(_ event: NSEvent) {
        guard isUnderPointer else { return }
        (card(at: event.locationInWindow) != nil ? NSCursor.pointingHand : NSCursor.arrow).set()
    }

    private func card(at windowPoint: NSPoint) -> Int? {
        let p = document.convert(windowPoint, from: nil)
        return cards.firstIndex { $0.frame.contains(p) }
    }

    override func mouseMoved(with event: NSEvent) {
        setCursor(event)
        if !followsPointer {
            // The pointer moved over the cards is the pointer wanted.
            guard let seen = pointerSeenAt else { pointerSeenAt = event.locationInWindow; return }
            guard hypot(event.locationInWindow.x - seen.x, event.locationInWindow.y - seen.y) > 6 else { return }
            followsPointer = true
        }
        if let i = card(at: event.locationInWindow) { choose(i) }
    }

    override func mouseDown(with event: NSEvent) {
        guard let i = card(at: event.locationInWindow) else { onCancel?(); return }
        downAt = i
    }

    override func mouseUp(with event: NSEvent) {
        guard let i = downAt else { return }
        downAt = nil
        onPick?(cards[i].content.id, event.modifierFlags)
    }

    // MARK: Debugging

    func debugPick(_ i: Int) -> String {
        guard cards.indices.contains(i) else { return "no card \(i)" }
        onPick?(cards[i].content.id, [])
        return "picked \(cards[i].content.summary.title)"
    }
}
