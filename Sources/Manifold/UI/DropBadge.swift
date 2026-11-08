import AppKit

/// What a drop will do, shown while a thing is dragged over somewhere
/// that takes it (§3.11): a badge, the symbol of what a drop does there —
/// the palette's for it. A drag of Manifold's own wears it on its pill, at
/// the corner by the pointer (`DragPill.wear`); one from elsewhere (the
/// Finder's) has it beside the pointer, where the system's + would be.
/// Each target shows it as the drag moves over it, so it's always what
/// dropping now would do; unshown for a moment (the drag gone elsewhere,
/// ended), it goes.
final class DropBadge: NSView {
    private static var shared: DropBadge?
    private var symbol = ""
    private var expiry: Timer?
    static let size: CGFloat = 20
    /// Room around for the shadow.
    private static let room: CGFloat = 5

    /// `symbol` shown over `window`, beside the pointer at `point` (its terms).
    static func show(_ symbol: String, at point: NSPoint, in window: NSWindow?) {
        guard let window, let content = window.contentView else { return }
        let badge = shared ?? DropBadge(frame: .zero)
        shared = badge
        if badge.superview !== content { content.addSubview(badge, positioned: .above, relativeTo: nil) }
        if badge.symbol != symbol {
            badge.symbol = symbol
            badge.needsDisplay = true
        }
        let p = content.convert(point, from: nil)
        // Below the pointer's arrow, to its right, where the system's badge sits.
        var r = NSRect(x: p.x + 8, y: p.y - size - 10, width: size, height: size)
        r.origin.x = min(r.origin.x, content.bounds.maxX - size - 6)
        r.origin.y = max(r.origin.y, 6)
        badge.frame = r.insetBy(dx: -room, dy: -room).integral
        badge.isHidden = false
        badge.expiry?.invalidate()
        badge.expiry = Timer.scheduledTimer(withTimeInterval: 0.35, repeats: false) { _ in
            MainActor.unchecked { badge.isHidden = true }
        }
    }

    /// `symbol` shown for the drag `sender` over `view` — on its pill if
    /// it's one of ours, else beside the pointer; nil, taken off.
    static func show(_ symbol: String?, for sender: NSDraggingInfo, over view: NSView) {
        if DragPill.wear(symbol, sender, over: view) { return hush() }
        if let symbol { show(symbol, at: sender.draggingLocation, in: view.window) } else { hush() }
    }

    /// Unshown at once (dropped, or the target let go of the drag).
    static func hush() {
        shared?.expiry?.invalidate()
        shared?.isHidden = true
    }

    /// Debugging: the symbol shown, if any.
    static var debugState: String {
        guard let b = shared, !b.isHidden else { return "hidden" }
        return b.symbol
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
        Self.draw(symbol, at: NSPoint(x: bounds.midX, y: bounds.midY))
    }

    /// `symbol`'s badge drawn centered at `c`: the tint (as deep as white on
    /// it needs), ringed in white as the system's badge is, so it reads
    /// over anything; grey where nothing can be done.
    static func draw(_ symbol: String, at c: NSPoint) {
        let b = size
        let circle = NSBezierPath(ovalIn: NSRect(x: c.x - b / 2, y: c.y - b / 2, width: b, height: b))
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
            image.draw(in: NSRect(x: c.x - s.width / 2, y: c.y - s.height / 2, width: s.width, height: s.height))
        }
    }
}
