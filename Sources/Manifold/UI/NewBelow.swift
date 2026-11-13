import AppKit

/// To the end, at the foot of a scrolled area. Two things it says:
///
/// - the view's scrolled away from its end (where a thread's newest comment
///   is): a round button, an arrow down, to go back there — shown whenever
///   it's away, if `showsWhenAway` (a thread's views; not an editor's, where
///   reading the top of a file is the usual, not being away);
/// - something new came below while it was away — added by something else
///   (an agent's comment, an agent's `mani write`, a file grown on disk): the
///   same button grown into a pill, the arrow and what it is ("New
///   comments"), in the accent. The view isn't moved for it; what you were
///   reading stays where it was.
///
/// Clicked, the view's scrolled to its end; once it's there, by the button
/// or anyhow, gone, and what was new with it.
final class NewBelowButton: NSView {
    var onClick: (() -> Void)?
    /// Shown whenever the view's away from its end, not only for news.
    var showsWhenAway: Bool
    /// What came below while away, said beside the arrow; nil, nothing new.
    private(set) var news: String?
    private let label = NSTextField.label(font: .systemFont(ofSize: 11.5, weight: .semibold), color: Tints.accentText)
    private let arrow = NSImageView()
    private var hovering = false { didSet { if hovering != oldValue { needsDisplay = true } } }
    private var area: NSRect = .zero
    private var away = false

    static let height: CGFloat = 30

    init(showsWhenAway: Bool = false) {
        self.showsWhenAway = showsWhenAway
        super.init(frame: NSRect(x: 0, y: 0, width: Self.height, height: Self.height))
        wantsLayer = true
        shadow = {
            let s = NSShadow()
            s.shadowColor = NSColor.black.withAlphaComponent(0.22)
            s.shadowBlurRadius = 8
            s.shadowOffset = NSSize(width: 0, height: -1)
            return s
        }()
        arrow.image = NSImage(systemSymbolName: "arrow.down", accessibilityDescription: "To the end")?
            .withSymbolConfiguration(.init(pointSize: 13, weight: .semibold))
        arrow.imageScaling = .scaleNone
        for v in [arrow, label] as [NSView] { addSubview(v) }
        isHidden = true
        toolTip = "Scroll to the end"
        themed { v in v.needsDisplay = true; v.tint() }
    }

    required init?(coder: NSCoder) { fatalError() }

    /// Where it sits — the foot of `area` (its superview's terms), centred —
    /// and whether the view's `away` from its end. Called as the view scrolls
    /// and is laid out; at its end, gone, and its news with it.
    func place(over area: NSRect, away: Bool) {
        self.area = area
        self.away = away
        if !away { news = nil }
        refresh()
    }

    /// Something new came below, said (`words`) while the view's away.
    func announce(_ words: String) {
        news = words
        refresh()
    }

    /// Gone, and its news, till the view's away again.
    func hide() {
        news = nil
        isHidden = true
    }

    private func refresh() {
        let shown = away && (news != nil || showsWhenAway)
        isHidden = !shown
        guard shown else { return }
        label.stringValue = news ?? ""
        label.isHidden = news == nil
        label.sizeToFit()
        let w = news == nil ? Self.height : ceil(label.frame.width) + 12 + 14 + 6 + 14
        let y = superview?.isFlipped == true ? area.maxY - 12 - Self.height : area.minY + 12
        frame = NSRect(x: (area.midX - w / 2).rounded(), y: y, width: w, height: Self.height)
        tint()
        toolTip = news == nil ? "Scroll to the end" : "Scroll to what's new"
        needsLayout = true
        needsDisplay = true
    }

    private func tint() {
        arrow.contentTintColor = news == nil ? Theme.text.withAlphaComponent(0.8) : Tints.accentText
        label.textColor = Tints.accentText
    }

    override func layout() {
        super.layout()
        if news == nil {
            arrow.frame = bounds
        } else {
            arrow.frame = NSRect(x: 12, y: 0, width: 14, height: bounds.height)
            label.frame.origin = NSPoint(x: arrow.frame.maxX + 6, y: ((bounds.height - label.frame.height) / 2).rounded())
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        let r = bounds.insetBy(dx: 0.5, dy: 0.5)
        let capsule = NSBezierPath(roundedRect: r, xRadius: r.height / 2, yRadius: r.height / 2)
        let panel = Theme.panel.withAlphaComponent(1)
        let ground = (panel.blended(withFraction: hovering ? 0.14 : 0.07, of: Theme.text) ?? panel).withAlphaComponent(0.94)
        ground.setFill()
        capsule.fill()
        (news == nil ? EdgeColor.hairline : Tints.accentText.withAlphaComponent(0.45)).setStroke()
        capsule.lineWidth = 1
        capsule.stroke()
    }

    override func updateTrackingAreas() {
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .mouseMoved, .cursorUpdate, .activeAlways, .inVisibleRect], owner: self))
        super.updateTrackingAreas()
    }
    override func mouseEntered(with event: NSEvent) { hovering = true; NSCursor.pointingHand.set() }
    override func mouseExited(with event: NSEvent) { hovering = false }
    // The pointing hand over it — set again as the pointer moves, after the
    // move's been handled, since the text it sits over (a comment's, an
    // editor's) sets its I-beam as the pointer moves, too.
    override func mouseMoved(with event: NSEvent) {
        NSCursor.pointingHand.set()
        DispatchQueue.main.async { [weak self] in
            MainActor.unchecked { if self?.hovering == true, self?.isHidden == false { NSCursor.pointingHand.set() } }
        }
    }
    override func cursorUpdate(with event: NSEvent) { NSCursor.pointingHand.set() }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .pointingHand) }
    override func mouseDown(with event: NSEvent) {}
    override func mouseUp(with event: NSEvent) {
        guard bounds.contains(convert(event.locationInWindow, from: nil)) else { return }
        hide()
        onClick?()
    }

    /// Its state, for the debug readouts.
    var debugState: String { isHidden ? "hidden" : news.map { "shown (\($0))" } ?? "shown (to end)" }
}
