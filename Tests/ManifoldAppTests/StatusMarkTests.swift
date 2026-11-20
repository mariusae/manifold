import AppKit
import Testing
@testable import Manifold

// One glyph for a status wherever a name is (§3.7): hollow at work, filled
// when there's something for you, nothing once seen — no words, no shimmer.
@Test func aStatusIsAGlyphOrNothing() {
    #expect(StatusMark(.working(progress: nil)).glyph == .working(progress: nil))
    #expect(StatusMark(.working(progress: 40)).glyph == .working(progress: 40))
    #expect(StatusMark(.needsYou).glyph == .needsYou)
    #expect(StatusMark(.done(read: false)).glyph == .done(read: false))
    #expect(StatusMark(.failed(read: false)).glyph == .failed(read: false))
    #expect(StatusMark(.unseen).glyph == .unseen)
    // Seen: nothing.
    #expect(StatusMark(.done(read: true)).glyph == nil)
    #expect(StatusMark(.failed(read: true)).glyph == nil)
    #expect(StatusMark(nil).glyph == nil)
    // Asleep: a moon, the name dim.
    let asleep = StatusMark(.inactive)
    #expect(asleep.glyph == .inactive && asleep.dim)
    #expect(!StatusMark(.needsYou).dim)
}

// A folded project shows what's most pressing in it.
@Test func whatNeedsYouOutranksWhatsDoneOrAtWork() {
    let looks: [StatusGlyph.Look] = [.inactive, .working(progress: nil), .done(read: false), .unseen, .failed(read: false), .needsYou]
    let order = looks.sorted { MainWindowController.urgency($0) < MainWindowController.urgency($1) }
    #expect(order.first == .needsYou)
    #expect(order[1] == .failed(read: false))
    #expect(MainWindowController.urgency(.done(read: false)) < MainWindowController.urgency(.working(progress: nil)))
    #expect(order.last == .inactive)
}
