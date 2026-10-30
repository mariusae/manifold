import AppKit

/// What a drop will do, shown beside the pointer while a thing is dragged
/// over somewhere that takes it (§3.11): a badge where the system's +
/// would be, the symbol of what a drop does there — the palette's for it
/// — and beside it in words, "Type its path", "Give the agent what it
/// holds", "Open it here". Each target says it as the drag moves over it,
/// so it's always what dropping now would do; unsaid for a moment (the
/// drag gone elsewhere, ended), it goes.
final class DropHint: NSView {
    private static var shared: DropHint?
    private var text: String?
    private var symbol: String?
    private var expiry: Timer?
    private static let font = UIType.detail
    static let badge: CGFloat = 20
    private static let height: CGFloat = 22
    /// Room around for the shadow.
    private static let room: CGFloat = 5

    /// Said over `window`, beside the pointer at `point` (its terms): the
    /// badge with `symbol`, the words `text` after it.
    static func say(_ text: String?, symbol: String? = nil, at point: NSPoint, in window: NSWindow?) {
        guard let window, let content = window.contentView, text != nil || symbol != nil else { return }
        let hint = shared ?? DropHint(frame: .zero)
        shared = hint
        if hint.superview !== content { content.addSubview(hint, positioned: .above, relativeTo: nil) }
        if hint.text != text || hint.symbol != symbol {
            hint.text = text
            hint.symbol = symbol
            hint.needsDisplay = true
        }
        let words = text.map { ceil(($0 as NSString).size(withAttributes: [.font: font]).width) + 20 } ?? 0
        let w = (symbol != nil ? badge : 0) + (symbol != nil && text != nil ? 4 : 0) + words, h = height
        let p = content.convert(point, from: nil)
        // Below the pointer's arrow, to its right, where the system's badge sits.
        var r = NSRect(x: p.x + 8, y: p.y - h - 10, width: w, height: h)
        r.origin.x = min(r.origin.x, content.bounds.maxX - w - 6)
        r.origin.y = max(r.origin.y, 6)
        hint.frame = r.insetBy(dx: -room, dy: -room).integral
        hint.isHidden = false
        hint.expiry?.invalidate()
        hint.expiry = Timer.scheduledTimer(withTimeInterval: 0.35, repeats: false) { _ in
            MainActor.assumeIsolated { hint.isHidden = true }
        }
    }

    /// Unsaid at once (dropped, or the target let go of the drag).
    static func hush() {
        shared?.expiry?.invalidate()
        shared?.isHidden = true
    }

    /// Debugging: what it says, if shown.
    static var debugState: String {
        guard let h = shared, !h.isHidden else { return "hidden" }
        return "[\(h.symbol ?? "")] \(h.text ?? "")"
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        // Over the palette too.
        layer?.zPosition = 130
        themed { $0.needsDisplay = true }
    }

    required init?(coder: NSCoder) { fatalError() }

    // Not a drop target itself, nor in the pointer's way.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func draw(_ dirtyRect: NSRect) {
        let inner = bounds.insetBy(dx: Self.room, dy: Self.room)
        var x = inner.minX
        if let symbol {
            // The badge: the tint (as deep as white on it needs), ringed in
            // white as the system's is, so it reads over anything.
            let b = Self.badge
            let circle = NSBezierPath(ovalIn: NSRect(x: x, y: inner.midY - b / 2, width: b, height: b))
            NSGraphicsContext.saveGraphicsState()
            Elevation.resting.shadow.set()
            (symbol == Dropping.refused ? NSColor.systemGray : Tints.accentFill).setFill()
            circle.fill()
            NSGraphicsContext.restoreGraphicsState()
            NSColor.white.setStroke()
            circle.lineWidth = 1.5
            circle.stroke()
            if let image = Theme.symbol(symbol, size: 10, weight: .bold, color: .white) {
                let s = image.size
                image.draw(in: NSRect(x: x + (b - s.width) / 2, y: inner.midY - s.height / 2, width: s.width, height: s.height))
            }
            x += b + 4
        }
        guard let text else { return }
        let pill = NSBezierPath(roundedRect: NSRect(x: x, y: inner.midY - Self.height / 2, width: inner.maxX - x, height: Self.height),
                                xRadius: 7, yRadius: 7)
        NSGraphicsContext.saveGraphicsState()
        Elevation.resting.shadow.set()
        Theme.windowBackground.setFill()
        pill.fill()
        NSGraphicsContext.restoreGraphicsState()
        EdgeColor.control.setStroke()
        pill.lineWidth = 0.5
        pill.stroke()
        let s = NSAttributedString(string: text, attributes: [.font: Self.font, .foregroundColor: Theme.text])
        let size = s.size()
        s.draw(at: NSPoint(x: x + (inner.maxX - x - size.width) / 2, y: inner.midY - size.height / 2))
    }
}
