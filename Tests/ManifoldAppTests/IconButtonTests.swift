import AppKit
import Testing
@testable import Manifold

// A button made with what a click does (`IconButton(_:tip:_:)`, as each
// sidebar row's × is) does it when clicked: set in its initializer,
// `onClick`'s didSet never ran, and its target and action were nil.
@MainActor
@Test func anIconButtonMadeWithAClickDoesItWhenClicked() {
    var clicked = 0
    let b = IconButton("xmark", tip: "Close Tile") { clicked += 1 }
    #expect(b.target === b)
    #expect(b.action != nil)
    // As a click does: its action sent to its target (with no app running
    // in a test, by hand).
    func click(_ b: IconButton) { if let t = b.target as? NSObject, let a = b.action { t.perform(a, with: b) } }
    click(b)
    #expect(clicked == 1)
    let close = IconButton.close { clicked += 1 }
    click(close)
    #expect(clicked == 2)
}
