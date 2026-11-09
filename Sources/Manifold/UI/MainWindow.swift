import AppKit
import ManifoldCore
import WebKit
import ManifoldSyntax
import UniformTypeIdentifiers
import PDFKit

final class MainWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }

    // ⌘Z and ⇧⌘Z that no view took (an editor takes its own): the
    // workspace's undo (§3.1). The window would otherwise answer them
    // with its own, empty, undo manager.
    @objc func undo(_ sender: Any?) { (windowController as? MainWindowController)?.undo(sender) }
    @objc func redo(_ sender: Any?) { (windowController as? MainWindowController)?.redo(sender) }

    // The title bar is hidden, but AppKit still treats the strip above the
    // content layout rect as one: a click there moves the window with any
    // twitch of the mouse, and a double click zooms it. Claiming the whole
    // window for content leaves no such strip; the sidebar's header moves
    // the window instead. (Ghostty does the same for its hidden title bar.)
    override var contentLayoutRect: CGRect {
        var rect = super.contentLayoutRect
        rect.origin.y = 0
        rect.size.height = frame.height
        return rect
    }

    // Even so, a second click in a row up there (⌥-clicks walking a
    // stack whose bar is at the window's top, clicks growing a tile) is
    // taken for a double click on the title bar and never reaches the
    // bar: on a tile's bar, which takes every click as one, it goes as one.
    override func sendEvent(_ event: NSEvent) {
        if [.leftMouseDown, .leftMouseUp].contains(event.type), event.clickCount > 1,
           event.locationInWindow.y > frame.height - 40, onTileBar(event.locationInWindow),
           let single = NSEvent.mouseEvent(with: event.type, location: event.locationInWindow, modifierFlags: event.modifierFlags,
                                           timestamp: event.timestamp, windowNumber: event.windowNumber, context: nil,
                                           eventNumber: event.eventNumber, clickCount: 1, pressure: event.pressure) {
            return super.sendEvent(single)
        }
        super.sendEvent(event)
    }

    private func onTileBar(_ p: NSPoint) -> Bool {
        guard let content = contentView, var v = content.hitTest(content.superview?.convert(p, from: nil) ?? p) else { return false }
        while true {
            if v is TilePill { return true }
            guard let up = v.superview else { return false }
            v = up
        }
    }
}

/// The window's content view; watches the mouse for the sidebar.
final class RootView: NSView {
    var onMouseMoved: ((NSPoint) -> Void)?
    var onMouseExitedWindow: (() -> Void)?
    var onLayout: (() -> Void)?

    override func updateTrackingAreas() {
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                       owner: self))
        super.updateTrackingAreas()
    }

    override func mouseMoved(with event: NSEvent) {
        onMouseMoved?(convert(event.locationInWindow, from: nil))
    }

    /// A cursor update no view under the pointer took (one with a cursor
    /// rect, where the pointer's at its edge) stops here, the arrow: passed
    /// on, it went to the title bar over the window's top, which hands it
    /// to the view under the pointer again, and round — under the title
    /// bar (the sidebar's edge, a tile's bar), until the stack ran out.
    override func cursorUpdate(with event: NSEvent) { NSCursor.arrow.set() }

    override func mouseExited(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        // Leaving through the left edge is how you reach the sidebar when the
        // window is against the side of the screen.
        if p.x <= 0 { onMouseMoved?(NSPoint(x: 0, y: p.y)) } else { onMouseExitedWindow?() }
    }

    override func layout() {
        super.layout()
        onLayout?()
    }
}
