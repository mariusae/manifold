import AppKit

/// What a drop will do, said beside the pointer while a block is
/// ⇧-dragged over somewhere that takes it — "Type its path", "Give its
/// contents", "Link" — so where it lands decides, visibly. Each target
/// says it as the drag moves over it; unsaid for a moment (the drag gone
/// elsewhere, ended), it goes.
final class DropHint: NSView {
    private static var shared: DropHint?
    private var text = ""
    private var expiry: Timer?
    private static let font = UIType.detail

    /// Said over `window`, beside the pointer at `point` (its terms).
    static func say(_ text: String, at point: NSPoint, in window: NSWindow?) {
        guard let window, let content = window.contentView else { return }
        let hint = shared ?? DropHint(frame: .zero)
        shared = hint
        if hint.superview !== content { content.addSubview(hint, positioned: .above, relativeTo: nil) }
        if hint.text != text { hint.text = text; hint.needsDisplay = true }
        let w = ceil((text as NSString).size(withAttributes: [.font: font]).width) + 20, h: CGFloat = 22
        let p = content.convert(point, from: nil)
        var r = NSRect(x: p.x + 14, y: p.y - h - 12, width: w, height: h)
        r.origin.x = min(r.origin.x, content.bounds.maxX - w - 6)
        r.origin.y = max(r.origin.y, 6)
        hint.frame = r.integral
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

    /// A block ⇧-dragged (its link carried, not the tile itself).
    static func isBlockLink(_ pb: NSPasteboard) -> Bool {
        pb.types?.contains(.manifoldBlockLink) == true && pb.string(forType: .manifoldPlacement) == nil
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.zPosition = 100
        layer?.cornerRadius = 7
        layer?.cornerCurve = .continuous
        Elevation.float.apply(to: layer!)
        layer?.borderWidth = 0.5
        themed {
            $0.layer?.backgroundColor = Theme.windowBackground.cgColor
            $0.layer?.borderColor = EdgeColor.control.cgColor
            $0.needsDisplay = true
        }
    }

    required init?(coder: NSCoder) { fatalError() }

    // Not a drop target itself, nor in the pointer's way.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func draw(_ dirtyRect: NSRect) {
        let s = NSAttributedString(string: text, attributes: [.font: Self.font, .foregroundColor: Theme.text])
        let size = s.size()
        s.draw(at: NSPoint(x: (bounds.width - size.width) / 2, y: (bounds.height - size.height) / 2))
    }
}
