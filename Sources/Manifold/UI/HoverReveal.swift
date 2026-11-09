import AppKit

/// Controls that show only while the pointer is on part of a view — a
/// tile's header, its strip — fading in as it comes and out as it goes
/// (Dia's way); at rest, only what says where things are.
final class HoverReveal: NSObject {
    private weak var view: NSView?
    private let controls: () -> [NSView]
    private var area: NSTrackingArea?
    /// The pointer is on the part watched.
    private(set) var hovered = false
    /// Shown whether or not the pointer's there (a copy's check, saying it took).
    var pinned: () -> Bool = { false }

    /// Over `view`, revealing `controls`.
    init(in view: NSView, _ controls: @escaping () -> [NSView]) {
        self.view = view
        self.controls = controls
    }

    private var shows: Bool { hovered || pinned() }

    /// Watches `rect` (the view's terms) from now — called as the view lays
    /// out — the controls shown or not as they should be, at once.
    func track(_ rect: NSRect) {
        guard let view else { return }
        if area?.rect != rect {
            if let area { view.removeTrackingArea(area) }
            let a = NSTrackingArea(rect: rect, options: [.mouseEnteredAndExited, .activeInActiveApp], owner: self)
            view.addTrackingArea(a)
            area = a
        }
        for v in controls() { v.alphaValue = shows ? 1 : 0 }
    }

    @objc(mouseEntered:) func mouseEntered(with event: NSEvent) { set(true) }
    @objc(mouseExited:) func mouseExited(with event: NSEvent) { set(false) }

    private func set(_ on: Bool) {
        guard on != hovered else { return }
        hovered = on
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = Motion.fast
            for v in controls() { v.animator().alphaValue = shows ? 1 : 0 }
        }
    }
}
