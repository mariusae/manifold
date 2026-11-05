import AppKit
import ManifoldSyntax

/// The definitions the top of an editor's text is inside of, pinned over
/// it (§7.1): each one's first line, as the text has it, while that line's
/// scrolled out of view — so where you are reads at a glance. A click goes
/// to the definition.
final class PinnedDefinitions: NSView {
    weak var textView: TextView?
    /// What's pinned: each one's first line, outermost first.
    private(set) var lines: [Int] = []
    /// Where the text's scrolled to across (the pinned lines with it).
    private var dx: CGFloat = 0
    var background: NSColor = Theme.windowBackground { didSet { needsDisplay = true } }
    var onPick: ((Int) -> Void)?
    /// At most this many, the innermost kept.
    static let most = 3

    override var isFlipped: Bool { true }

    /// Pinned again for the text's view at `visible` (its visible rect).
    /// Returns the height it takes.
    @discardableResult
    func update(visible: NSRect) -> CGFloat {
        guard let tv = textView else { return 0 }
        let h = tv.rowHeight
        // Those the line under the pinned ones is inside of: as many as
        // pinned, the line under them found again.
        var found: [Int] = []
        for _ in 0...Self.most {
            let n = tv.line(atY: visible.minY + CGFloat(found.count) * h + 1)
            let next = Array(tv.enclosing(line: n).map { tv.text.line(at: $0.range.start) }.suffix(Self.most))
            if next == found { break }
            found = next
        }
        // Only those whose first line is above the view's top.
        found = found.filter { tv.top(ofLine: $0) < visible.minY + 1 }
        if found != lines || dx != visible.minX {
            lines = found
            dx = visible.minX
            needsDisplay = true
        }
        isHidden = lines.isEmpty
        return CGFloat(lines.count) * h
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let tv = textView, let ctx = NSGraphicsContext.current?.cgContext else { return }
        background.setFill()
        bounds.fill()
        let h = tv.rowHeight
        for (i, n) in lines.enumerated() {
            tv.drawFirstRow(ofLine: n, at: CGFloat(i) * h, dx: -dx, in: ctx)
        }
        // A hairline under them, as the text's between definitions.
        let px = 1 / max(window?.backingScaleFactor ?? 2, 1)
        tv.textColor.withAlphaComponent(0.14).setFill()
        NSRect(x: 0, y: bounds.height - px, width: bounds.width, height: px).fill()
    }

    override func mouseDown(with event: NSEvent) {
        guard let tv = textView else { return }
        let p = convert(event.locationInWindow, from: nil)
        let i = Int(p.y / tv.rowHeight)
        if lines.indices.contains(i) { onPick?(lines[i]) }
    }

    override func resetCursorRects() { addCursorRect(bounds, cursor: .pointingHand) }
}
