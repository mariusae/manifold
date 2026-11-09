import AppKit

/// The one look of a popover over the window — a menu (the footer's),
/// ⌘`'s cards and a space's peek, the thread overlay, the host picker, the
/// @ list: frosted, rounded, a hairline round it, one deep shadow. What it
/// draws itself it draws in `drawContent` (on a canvas over the frost — a
/// view's own drawing would be under it); its subviews go over both. The
/// frost and the canvas let clicks through to it.
class PopoverView: NSView {
    static let radius: CGFloat = 12

    private let ground = Ground()
    private let canvas = Canvas()

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.cornerRadius = Self.radius
        layer?.cornerCurve = .continuous
        layer?.masksToBounds = false
        shadow = NSShadow()
        layer?.shadowOpacity = 0.28
        layer?.shadowRadius = 20
        layer?.shadowOffset = NSSize(width: 0, height: -8)
        ground.material = .popover
        ground.blendingMode = .withinWindow
        ground.state = .active
        ground.wantsLayer = true
        ground.layer?.cornerRadius = Self.radius
        ground.layer?.cornerCurve = .continuous
        ground.layer?.masksToBounds = true
        ground.layer?.borderWidth = 0.5
        canvas.owner = self
        addSubview(ground)
        addSubview(canvas)
        themed { $0.ground.layer?.borderColor = Flat.line.cgColor }
    }

    required init?(coder: NSCoder) { fatalError() }

    /// In a window of its own (the @ list's panel), the frost is of what's
    /// behind the window and the window casts the shadow; over the window's
    /// content, of what's under it, and its own.
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        let own = window?.contentView === self
        ground.blendingMode = own ? .behindWindow : .withinWindow
        layer?.shadowOpacity = own ? 0 : 0.28
    }

    /// What it draws itself, over the frost (in its own coordinates).
    func drawContent(_ dirtyRect: NSRect) {}

    override var needsDisplay: Bool {
        didSet { if needsDisplay { canvas.needsDisplay = true } }
    }

    override func setNeedsDisplay(_ invalidRect: NSRect) {
        super.setNeedsDisplay(invalidRect)
        canvas.setNeedsDisplay(invalidRect)
    }

    override func layout() {
        super.layout()
        ground.frame = bounds
        canvas.frame = bounds
    }

    private final class Ground: NSVisualEffectView {
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }

    private final class Canvas: NSView {
        weak var owner: PopoverView?
        override var isFlipped: Bool { owner?.isFlipped ?? false }
        override func draw(_ dirtyRect: NSRect) { owner?.drawContent(dirtyRect) }
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }
}
