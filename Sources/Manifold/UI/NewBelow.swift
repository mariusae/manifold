import AppKit

/// Something new below what shows — added by something else (an agent's
/// comment, an agent's `mani write`, a file grown on disk) while the view
/// was scrolled elsewhere: a small pill at the foot of the scrolled area,
/// an arrow down and what it is ("New"); clicked, the view scrolled to its
/// end, and gone; gone too once the view's scrolled there anyway. The view
/// isn't moved for it — what you were reading stays where it was.
final class NewBelowButton: NSView {
    var onClick: (() -> Void)?
    private let label = NSTextField.label(font: .systemFont(ofSize: 11.5, weight: .semibold), color: Tints.accentText)
    private let arrow = NSImageView()
    private var hovering = false { didSet { if hovering != oldValue { needsDisplay = true } } }

    static let height: CGFloat = 26

    init(_ words: String = "New") {
        super.init(frame: NSRect(x: 0, y: 0, width: 80, height: Self.height))
        wantsLayer = true
        shadow = {
            let s = NSShadow()
            s.shadowColor = NSColor.black.withAlphaComponent(0.18)
            s.shadowBlurRadius = 6
            s.shadowOffset = NSSize(width: 0, height: -1)
            return s
        }()
        label.stringValue = words
        arrow.image = Theme.symbol("arrow.down", size: 10.5, weight: .bold, color: Tints.accentText)
        for v in [arrow, label] as [NSView] { addSubview(v) }
        isHidden = true
        toolTip = "Scroll to what's new"
    }

    required init?(coder: NSCoder) { fatalError() }

    /// Its width for its words.
    var wantedWidth: CGFloat { label.sizeToFit(); return ceil(label.frame.width) + 12 + 12 + 6 + 12 }

    /// Shown (saying `words`, if given), at the foot of `area` (its
    /// superview's terms), centred.
    func show(_ words: String? = nil, over area: NSRect) {
        if let words { label.stringValue = words }
        let w = wantedWidth
        frame = NSRect(x: (area.midX - w / 2).rounded(), y: area.minY + 10, width: w, height: Self.height)
        if superview?.isFlipped == true { frame.origin.y = area.maxY - 10 - Self.height }
        isHidden = false
        needsLayout = true
    }

    func hide() { isHidden = true }

    override func layout() {
        super.layout()
        label.sizeToFit()
        arrow.frame = NSRect(x: 12, y: (bounds.height - 12) / 2, width: 12, height: 12)
        label.frame.origin = NSPoint(x: arrow.frame.maxX + 6, y: ((bounds.height - label.frame.height) / 2).rounded())
    }

    override func draw(_ dirtyRect: NSRect) {
        let r = bounds.insetBy(dx: 0.5, dy: 0.5)
        let capsule = NSBezierPath(roundedRect: r, xRadius: r.height / 2, yRadius: r.height / 2)
        (hovering ? Theme.panel.blended(withFraction: 0.06, of: Theme.text) ?? Theme.panel : Theme.panel).setFill()
        capsule.fill()
        EdgeColor.hairline.setStroke()
        capsule.lineWidth = 1
        capsule.stroke()
    }

    override func updateTrackingAreas() {
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
        super.updateTrackingAreas()
    }
    override func mouseEntered(with event: NSEvent) { hovering = true }
    override func mouseExited(with event: NSEvent) { hovering = false }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .pointingHand) }
    override func mouseDown(with event: NSEvent) {}
    override func mouseUp(with event: NSEvent) {
        guard bounds.contains(convert(event.locationInWindow, from: nil)) else { return }
        hide()
        onClick?()
    }
}
