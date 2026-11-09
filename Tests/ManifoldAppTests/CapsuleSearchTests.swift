import AppKit
import Testing
@testable import Manifold

// The outline's filter: what's typed starts after the glass, as the
// placeholder does — it ran under it while typed.

@MainActor
@Test func aFiltersWordsBeingTypedStartAfterItsGlass() throws {
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 100), styleMask: [.titled], backing: .buffered, defer: false)
    let field = NSSearchField(frame: NSRect(x: 10, y: 40, width: 220, height: 22))
    let cell = CapsuleSearchCell(textCell: "")
    field.cell = cell
    field.isEditable = true
    field.font = UIType.field
    field.isBezeled = false
    field.isBordered = false
    window.contentView?.addSubview(field)
    let glass = cell.searchButtonRect(forBounds: field.bounds)
    #expect(cell.drawingRect(forBounds: field.bounds).minX >= glass.maxX)
    #expect(window.makeFirstResponder(field))
    let editor = try #require(field.currentEditor())
    let frame = editor.convert(editor.bounds, to: field)
    #expect(frame.minX >= glass.maxX, "the words being typed began at \(frame.minX), under the glass (to \(glass.maxX))")
    // Where they're drawn, not typed elsewhere.
    #expect(frame.minX == cell.drawingRect(forBounds: field.bounds).minX)
}
