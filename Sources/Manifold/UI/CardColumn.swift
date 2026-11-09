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

    /// Whether a card drawn from `other` would look different from this
    /// one in a note: its summary, its symbol, a picture come or gone.
    func differs(from other: SummaryCardContent?) -> Bool {
        guard let other else { return true }
        return other.summary != summary || other.symbol != symbol || (other.thumbnail == nil) != (thumbnail == nil)
    }
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
