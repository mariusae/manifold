import AppKit
import ManifoldCore

/// The scroll bar of a terminal, an editor, a preview (§3.1): a strip down
/// a view's edge with the content's extent as its length and the part shown
/// as a knob, which drags as a scroll bar's does; a click on the track
/// jumps there. Shown as macOS shows its overlay scroll bars: while the
/// content scrolls or grows, while the pointer is on it, and a moment
/// after. (Where you are in what it holds is the outline's: its ticks at
/// the tile's upper right.)
final class ScrubberView: NSView {
    static let width: CGFloat = 14

    /// Scrolled to a fraction of the content, dragging or clicking the track.
    var onScroll: ((Double) -> Void)?

    /// The content's extent, and the part shown.
    private var total: Double = 1
    private var offset: Double = 0
    private var shown: Double = 1
    private var dragging: (grab: CGFloat, start: Double)?
    private var dragged = false
    /// Faded away after a moment, as an overlay scroll bar is; always
    /// shown when the system's scroll bars are the kind that stay.
    private var fade: Timer?
    private var pointerIn = false

    private func reveal() {
        fade?.invalidate()
        fade = nil
        if alphaValue != 1 {
            layer?.removeAllAnimations()
            alphaValue = 1
        }
        guard NSScroller.preferredScrollerStyle == .overlay, !pointerIn, dragging == nil else { return }
        fade = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.fade = nil
                NSAnimationContext.runAnimationGroup { ctx in
                    ctx.duration = 0.3
                    self.animator().alphaValue = 0
                }
            }
        }
    }

    override var isFlipped: Bool { true }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
    }

    required init?(coder: NSCoder) { fatalError() }

    func update(total: Double, offset: Double, shown: Double) {
        if total != self.total || offset != self.offset || shown != self.shown { reveal() }
        self.total = max(total, 1)
        self.offset = offset
        self.shown = max(shown, 1)
        needsDisplay = true
    }

    override func viewDidMoveToSuperview() {
        super.viewDidMoveToSuperview()
        if superview == nil { fade?.invalidate(); fade = nil } else { reveal() }
    }

    private static let pad: CGFloat = 4

    private func position(_ at: Double) -> CGFloat {
        Self.pad + CGFloat(at / total) * max(1, bounds.height - 2 * Self.pad)
    }

    private func fraction(at y: CGFloat) -> Double {
        Double(min(1, max(0, (y - Self.pad) / max(1, bounds.height - 2 * Self.pad))))
    }

    private var knobRect: NSRect {
        let top = position(offset), bottom = position(offset + shown)
        return NSRect(x: 3, y: top, width: bounds.width - 6, height: max(bottom - top, 12))
    }

    override func draw(_ dirtyRect: NSRect) {
        // The track, a shade off the terminal's ground; the knob over it.
        Theme.scrubberTrack.setFill()
        bounds.fill()
        (dragging != nil ? Theme.handle : Theme.scrubberKnob).setFill()
        NSBezierPath(roundedRect: knobRect, xRadius: Radius.inline, yRadius: Radius.inline).fill()
    }

    // MARK: The pointer

    override func updateTrackingAreas() {
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
        super.updateTrackingAreas()
    }

    override func resetCursorRects() { addCursorRect(bounds, cursor: .arrow) }

    override func mouseEntered(with event: NSEvent) {
        pointerIn = true
        reveal()
    }

    override func mouseExited(with event: NSEvent) {
        pointerIn = false
        reveal()
    }

    override func mouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        dragged = false
        if knobRect.insetBy(dx: 0, dy: -2).contains(p) {
            dragging = (p.y, offset)
            needsDisplay = true
        }
    }

    override func mouseDragged(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        if dragging == nil, !dragged { dragging = (p.y, offset) }
        guard let d = dragging else { return }
        dragged = true
        let rows = Double(p.y - d.grab) / Double(max(1, bounds.height - 2 * Self.pad)) * total
        let target = min(max(d.start + rows, 0), max(total - shown, 0))
        onScroll?(target / max(total - shown, 1))
    }

    override func mouseUp(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        let wasDragging = dragging != nil
        dragging = nil
        needsDisplay = true
        reveal()
        if dragged || wasDragging { return }
        // On the track: the page there, as a scroll bar jumps.
        onScroll?(fraction(at: p.y))
    }
}

/// The headings of a Markdown text, by line: what an outline of it is
/// made of (⌘P, the scrubber).
enum MarkdownOutline {
    struct Heading { var line: Int; var level: Int; var text: String }

    static func headings(in text: String) -> [Heading] {
        var out: [Heading] = []
        var inFence = false
        var line = 0
        for raw in text.split(separator: "\n", omittingEmptySubsequences: false) {
            defer { line += 1 }
            if raw.hasPrefix("```") { inFence.toggle() }
            guard !inFence, raw.hasPrefix("#") else { continue }
            let level = raw.prefix { $0 == "#" }.count
            guard level <= 6, raw.dropFirst(level).first == " " else { continue }
            out.append(Heading(line: line, level: level, text: raw.dropFirst(level).trimmingCharacters(in: .whitespaces)))
        }
        return out
    }
}
