import AppKit
import ManifoldCore

/// A reference that leads nowhere, said by the pointer (§3.11): over a
/// `manifold:` link whose block is gone — deleted, collected, on a host
/// not here — a line beside the pointer says what it was and why, before
/// it's clicked; clicked anyway (or followed from elsewhere), the same
/// line, for a moment. One, shared, over the window's content; not in
/// the pointer's way.
@MainActor final class ReferenceTip: NSView {
    /// Why a reference to a block leads nowhere, nil if it doesn't
    /// (`Hosts.whyMissing`); given by the window.
    static var whyMissing: ((BlockID) -> String?)?

    private static var shared: ReferenceTip?
    private let label = NSTextField(labelWithString: "")
    /// The view whose link it's for, while hovered: gone from under the
    /// pointer, it goes.
    private weak var owner: NSView?
    private var expiry: Timer?
    private var monitor: Any?

    /// The pointer over a link to `target` in `view` (nil: over none): the
    /// line shown if it leads nowhere, else put away.
    static func hover(_ target: String?, in view: NSView) {
        guard let target, target.hasPrefix("manifold:"), let (id, _) = BlockID.link(target), let why = whyMissing?(id) else {
            if shared?.owner === view, shared?.expiry == nil { hide() }
            return
        }
        show(why, in: view.window, owner: view, for: nil)
    }

    /// `text` said by the pointer for a few seconds: a reference that
    /// leads nowhere, clicked.
    static func say(_ text: String, in window: NSWindow?) {
        show(text, in: window, owner: nil, for: 4)
    }

    static func hide() {
        guard let tip = shared else { return }
        tip.expiry?.invalidate()
        tip.expiry = nil
        tip.owner = nil
        tip.isHidden = true
        if let m = tip.monitor { NSEvent.removeMonitor(m) }
        tip.monitor = nil
    }

    /// Debugging: what it says, if shown.
    static var debugState: String {
        guard let t = shared, !t.isHidden else { return "hidden" }
        return t.label.stringValue
    }

    private static func show(_ text: String, in window: NSWindow?, owner: NSView?, for seconds: Double?) {
        guard let window, let content = window.contentView else { return }
        let tip = shared ?? ReferenceTip(frame: .zero)
        shared = tip
        if tip.superview !== content { content.addSubview(tip, positioned: .above, relativeTo: nil) }
        tip.owner = owner
        if tip.label.stringValue != text { tip.label.stringValue = text }
        let size = tip.label.intrinsicContentSize
        // (A field wants a little past its letters, or it cuts them.)
        let w = min(ceil(size.width) + 24, 440), h = ceil(size.height) + 10
        // Below the pointer's arrow and to its right, as a tooltip sits;
        // kept in the window.
        let p = content.convert(window.mouseLocationOutsideOfEventStream, from: nil)
        var r = NSRect(x: p.x + 4, y: p.y - 22 - h, width: w, height: h)
        if r.minY < 6 { r.origin.y = p.y + 14 }
        r.origin.x = max(6, min(r.origin.x, content.bounds.maxX - w - 6))
        tip.frame = r.integral
        tip.label.frame = NSRect(x: 10, y: 5, width: w - 18, height: h - 10)
        tip.isHidden = false
        tip.expiry?.invalidate()
        tip.expiry = seconds.map { s in
            Timer.scheduledTimer(withTimeInterval: s, repeats: false) { _ in MainActor.assumeIsolated { hide() } }
        }
        // Put away by a click, a key, a scroll, or the pointer leaving the
        // view it's for.
        if tip.monitor == nil {
            tip.monitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .keyDown, .scrollWheel, .mouseMoved]) { event in
                MainActor.assumeIsolated {
                    guard let tip = shared, !tip.isHidden else { return }
                    if event.type == .mouseMoved {
                        guard let owner = tip.owner, let w = owner.window else { return }
                        let p = owner.convert(w.mouseLocationOutsideOfEventStream, from: nil)
                        if !owner.visibleRect.contains(p) || owner.isHiddenOrHasHiddenAncestor { hide() }
                    } else {
                        // (A click's own line is said after its press.)
                        hide()
                    }
                }
                return event
            }
        }
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        Flat.float(self)
        layer?.cornerRadius = Radius.control
        // Over the palette and the drop's badge too.
        layer?.zPosition = 140
        label.font = .systemFont(ofSize: 12)
        label.textColor = Theme.text
        label.lineBreakMode = .byTruncatingTail
        addSubview(label)
    }

    required init?(coder: NSCoder) { fatalError() }

    // Not in the pointer's way.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}
