import AppKit

/// A thread's mark where it was made (§3.12), the same in every tile: a
/// small badge at the right edge of its line, over whatever text is
/// there — a bubble, and how many when more than one; on the accent, white,
/// while one has something not seen; outlined in the accent while one is
/// open; grey once all are resolved. Clicked, its threads, as a card.
/// The text editor, the outline and the diff draw it (`draw`) and find it
/// under a click (`rect`); a tile of another kind marks its place its own
/// way (a terminal's command, a PDF's page) as it can.
enum ThreadMark {
    struct State: Equatable {
        var count: Int
        var open: Bool
        var unseen: Bool
    }

    static let height: CGFloat = 16
    /// In from the right edge it's at.
    static let inset: CGFloat = 14

    private static let countFont = NSFont.monospacedDigitSystemFont(ofSize: 9.5, weight: .semibold)

    static func size(_ s: State) -> NSSize {
        let count = s.count > 1 ? ceil(("\(s.count)" as NSString).size(withAttributes: [.font: countFont]).width) + 3 : 0
        return NSSize(width: 22 + count, height: height)
    }

    /// Where it is for a line: its right edge `right` (in from it), centred
    /// on the line's first row.
    static func rect(_ s: State, right: CGFloat, lineTop: CGFloat, lineHeight: CGFloat) -> NSRect {
        let size = size(s)
        return NSRect(x: (right - inset - size.width).rounded(), y: (lineTop + (lineHeight - size.height) / 2).rounded(), width: size.width, height: size.height)
    }

    /// Drawn in `r` (in a flipped view, or not: it's symmetric but for its
    /// symbol, drawn upright either way).
    static func draw(_ s: State, in r: NSRect) {
        let capsule = NSBezierPath(roundedRect: r.insetBy(dx: 0.5, dy: 0.5), xRadius: r.height / 2, yRadius: r.height / 2)
        let ink: NSColor
        if s.unseen {
            Theme.accent.setFill()
            capsule.fill()
            ink = .white
        } else {
            Theme.panel.setFill()
            capsule.fill()
            (s.open ? Theme.accent.withAlphaComponent(0.75) : Flat.line).setStroke()
            capsule.lineWidth = 1
            capsule.stroke()
            ink = s.open ? Theme.accent : Theme.tertiaryText
        }
        let symbol = s.open || s.unseen ? "text.bubble.fill" : "checkmark.bubble"
        if let image = NSImage(systemSymbolName: symbol, accessibilityDescription: "Thread")?
            .withSymbolConfiguration(.init(pointSize: 8.5, weight: .semibold).applying(.init(paletteColors: [ink]))) {
            let ir = NSRect(x: r.minX + 6, y: r.midY - 4.5, width: 10, height: 9)
            image.draw(in: ir, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
        }
        if s.count > 1 {
            let n = NSAttributedString(string: "\(s.count)", attributes: [.font: countFont, .foregroundColor: ink])
            let size = n.size()
            n.draw(at: NSPoint(x: r.minX + 18, y: r.midY - size.height / 2))
        }
    }
}
