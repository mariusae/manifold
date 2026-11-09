import AppKit

/// A view that knows when the pointer's on it — checked again when it
/// moves out from under a still pointer, is hidden, or goes to another
/// window (no exit comes then to say so) — and redraws when that changes.
class HoverView: NSView {
    private(set) var hovering = false {
        didSet {
            guard hovering != oldValue else { return }
            needsDisplay = true
            hoverChanged()
        }
    }
    /// The pointer come over it (true) or gone (false).
    var onHover: ((Bool) -> Void)?
    /// When it's tracked: always (the default: a panel that doesn't take
    /// key), or only while its window's key.
    var tracking: NSTrackingArea.Options = .activeAlways

    /// Said when `hovering` changes (after it has).
    func hoverChanged() { onHover?(hovering) }

    override func updateTrackingAreas() {
        trackingAreas.filter { $0.owner === self && $0.userInfo?["hover"] != nil }.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, tracking, .inVisibleRect], owner: self, userInfo: ["hover": true]))
        super.updateTrackingAreas()
        recheckHover()
    }

    override func mouseEntered(with event: NSEvent) {
        if event.trackingArea?.userInfo?["hover"] != nil { hovering = true } else { super.mouseEntered(with: event) }
    }

    override func mouseExited(with event: NSEvent) {
        if event.trackingArea?.userInfo?["hover"] != nil { hovering = false } else { super.mouseExited(with: event) }
    }

    override func setFrameOrigin(_ newOrigin: NSPoint) {
        super.setFrameOrigin(newOrigin)
        recheckHover()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        recheckHover()
    }

    override func viewDidHide() {
        super.viewDidHide()
        recheckHover()
    }

    override func viewDidUnhide() {
        super.viewDidUnhide()
        recheckHover()
    }

    private func recheckHover() {
        guard hovering else { return }
        guard let window, !isHiddenOrHasHiddenAncestor else { hovering = false; return }
        if !bounds.contains(convert(window.mouseLocationOutsideOfEventStream, from: nil)) { hovering = false }
    }
}

/// A `HoverView` that's clicked: the pointing hand over it (set here, not
/// passed on, or the window's arrow would win), pressed while the button's
/// down, and `onClick` when it's let go inside (or as it goes down).
class ClickView: HoverView {
    var onClick: (() -> Void)?
    var isEnabled = true { didSet { needsDisplay = true; window?.invalidateCursorRects(for: self) } }
    /// The pointing hand over it (off: whatever's under it says).
    var handCursor = true
    /// Clicked the moment the button goes down, not when it's let go
    /// inside (a run, a link, a chip: what's pressed is chosen at once).
    var firesOnDown = false
    private(set) var pressed = false { didSet { if pressed != oldValue { needsDisplay = true } } }

    /// What a click does: `onClick`, unless a subclass says otherwise.
    func clicked() { onClick?() }

    override func resetCursorRects() {
        if handCursor, isEnabled { addCursorRect(bounds, cursor: .pointingHand) } else { super.resetCursorRects() }
    }

    override func cursorUpdate(with event: NSEvent) {
        if handCursor, isEnabled { NSCursor.pointingHand.set() } else { super.cursorUpdate(with: event) }
    }

    override func mouseDown(with event: NSEvent) {
        guard isEnabled else { return }
        if firesOnDown { clicked() } else { pressed = true }
    }

    override func mouseDragged(with event: NSEvent) {
        guard isEnabled else { return }
        pressed = bounds.contains(convert(event.locationInWindow, from: nil))
    }

    override func mouseUp(with event: NSEvent) {
        let was = pressed
        pressed = false
        if was, bounds.contains(convert(event.locationInWindow, from: nil)) { clicked() }
    }
}
