import AppKit

/// To the end, at the foot of a scrolled area (as Claude's apps have it):
/// a round button, the same in every view that keeps a reader's place —
/// an agent's conversation, a thread's, the timeline, an editor.
///
/// - the view scrolled away from its end: shown, if `showsWhenAway` (a
///   thread's views, a conversation; not an editor's, where reading the
///   top of a file is the usual) — a down arrow;
/// - the agent at work meanwhile (`working`): its working dots in it, a
///   down caret under the pointer;
/// - something new came below while it was away (an agent's comment, a
///   turn, a file grown on disk): a dot at its shoulder, in the accent —
///   shown then even where it isn't when only away. The view isn't moved
///   for it; what you were reading stays where it was.
///
/// Clicked, the view's scrolled to its end; once it's there, by the button
/// or anyhow, gone, and what was new with it.
final class NewBelowButton: NSView {
    var onClick: (() -> Void)?
    /// Shown whenever the view's away from its end, not only for news.
    var showsWhenAway: Bool
    /// What came below while away (said in its tooltip); nil, nothing new.
    private(set) var news: String?
    /// The agent at work: its dots, not the arrow (the arrow under the pointer).
    var working = false { didSet { if working != oldValue { refresh() } } }
    private let arrow = NSImageView()
    private let dots = StatusGlyph()
    private let dot = NSView()
    private var hovering = false { didSet { if hovering != oldValue { refresh() } } }
    private var area: NSRect = .zero
    private var away = false

    static let height: CGFloat = 32

    init(showsWhenAway: Bool = false) {
        self.showsWhenAway = showsWhenAway
        super.init(frame: NSRect(x: 0, y: 0, width: Self.height, height: Self.height))
        wantsLayer = true
        layer?.cornerRadius = Self.height / 2
        layer?.borderWidth = 0.5
        layer?.masksToBounds = false
        shadow = {
            let s = NSShadow()
            s.shadowColor = NSColor.black.withAlphaComponent(0.18)
            s.shadowBlurRadius = 6
            s.shadowOffset = NSSize(width: 0, height: -1)
            return s
        }()
        arrow.setAccessibilityLabel("To the end")
        arrow.imageScaling = .scaleNone
        dots.look = .working(progress: nil)
        dot.wantsLayer = true
        dot.layer?.cornerRadius = 3.5
        for v in [arrow, dots, dot] as [NSView] { addSubview(v) }
        isHidden = true
        toolTip = "Scroll to the end"
        themed { v in v.tint() }
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

    /// Something new came below, said (`words`, in its tooltip) while the view's away.
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
        let s = Self.height
        let y = superview?.isFlipped == true ? area.maxY - 10 - s : area.minY + 10
        frame = NSRect(x: (area.midX - s / 2).rounded(), y: y, width: s, height: s)
        // At work, not under the pointer: its dots; else the way down — a
        // caret over the dots, an arrow at rest.
        let showDots = working && !hovering
        dots.isHidden = !showDots
        arrow.isHidden = showDots
        arrow.image = Theme.symbol(working ? "chevron.down" : "arrow.down", size: 13, weight: .semibold)
        dot.isHidden = news == nil
        toolTip = news.map { "Scroll to what's new: \($0.lowercased())" } ?? "Scroll to the end"
        tint()
        needsLayout = true
    }

    // In its own appearance, always: called on hover and as it's shown,
    // outside the theme's hook, the colours would otherwise be resolved in
    // whatever appearance was current then — dark, over a light page.
    private func tint() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.backgroundColor = (hovering ? Theme.panel.blended(withFraction: 0.06, of: Theme.text) ?? Theme.panel : Theme.panel).cgColor
            layer?.borderColor = Theme.washLine.cgColor
            arrow.contentTintColor = Theme.text.withAlphaComponent(0.8)
            dot.layer?.backgroundColor = Theme.accent.cgColor
        }
    }

    override func layout() {
        super.layout()
        arrow.frame = bounds
        let g = StatusGlyph.size
        dots.frame = NSRect(x: (bounds.width - g) / 2, y: (bounds.height - g) / 2, width: g, height: g)
        dot.frame = NSRect(x: bounds.maxX - 8, y: isFlipped ? 1 : bounds.maxY - 8, width: 7, height: 7)
    }

    override func updateTrackingAreas() {
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .mouseMoved, .cursorUpdate, .activeAlways, .inVisibleRect], owner: self))
        super.updateTrackingAreas()
    }
    override func mouseEntered(with event: NSEvent) { hovering = true; tint(); NSCursor.pointingHand.set() }
    override func mouseExited(with event: NSEvent) { hovering = false; tint() }
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
