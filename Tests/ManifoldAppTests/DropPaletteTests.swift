import AppKit
import Testing
@testable import Manifold

// The drop palette (the forms a drop can take) goes when its drag does,
// however the drag ended — it stayed on the window, stuck, when a drag was
// given up while it was open, or just as it was about to open.

@MainActor
private final class Target: NSView, DropTaking {
    func dropForms(_ d: Dragged, at p: NSPoint) -> [DropForm] { [.text, .path] }
    func dropPut(_ d: Dragged, as form: DropForm, at p: NSPoint?) {}
}

@MainActor
private func setUp() -> (NSWindow, Target, NSPasteboard) {
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 400), styleMask: [.titled], backing: .buffered, defer: true)
    let target = Target(frame: NSRect(x: 0, y: 0, width: 600, height: 400))
    window.contentView?.addSubview(target)
    let pb = NSPasteboard(name: NSPasteboard.Name("test.drop.\(UUID().uuidString)"))
    pb.clearContents()
    pb.setString("some words", forType: .string)
    return (window, target, pb)
}

// One palette, shared: these mustn't run beside each other (the first's
// palette, open while it waits, would be the second's).
@MainActor
@Suite(.serialized) struct DropPaletteTests {

@Test func thePaletteGoesWhenItsDragEndsHoweverItEnded() async throws {
    let (window, target, pb) = setUp()
    _ = window
    var going = true
    DropPalette.dragGoing = { going }
    defer { DropPalette.dragGoing = { NSEvent.pressedMouseButtons & 1 != 0 }; DropPalette.close() }
    DropPalette.open(over: target, pb, at: NSPoint(x: 300, y: 200))
    #expect(DropPalette.isOpen)
    // Given up (⎋, let go where nothing takes it): no word to the palette.
    going = false
    try await Task.sleep(for: .milliseconds(400))
    #expect(!DropPalette.isOpen, "the palette stayed after its drag was over")
}

@Test func thePaletteDoesntOpenOnceTheDragIsOver() {
    let (window, target, pb) = setUp()
    _ = window
    DropPalette.dragGoing = { false }
    defer { DropPalette.dragGoing = { NSEvent.pressedMouseButtons & 1 != 0 }; DropPalette.close() }
    // A rest's timer firing just after the drag was given up.
    DropPalette.open(over: target, pb, at: NSPoint(x: 300, y: 200))
    #expect(!DropPalette.isOpen)
    // Debugging opens it with no drag at all, and it stays for its look.
    DropPalette.open(over: target, pb, at: NSPoint(x: 300, y: 200), watching: false)
    #expect(DropPalette.isOpen)
}
}
