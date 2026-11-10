import AppKit
import Testing
@testable import Manifold

// The outline strip (§3.1, §7.5), as claude.ai has its conversation's: a
// column of evenly spaced ticks beside the scroll bar, their heights how
// much their items span (against the rest of the view's), those of what
// shows lit; which have ticks doesn't change as you scroll.

/// A document: three top-level headings, each followed by its
/// subsections (the middle one with twelve).
private func document() -> [StripItem] {
    var out: [StripItem] = [], at = 0.0
    for top in 0..<3 {
        out.append(StripItem(level: 0, start: at, size: 100)); at += 100
        for _ in 0..<(top == 1 ? 12 : 6) {
            out.append(StripItem(level: 1, start: at, size: 60)); at += 60
        }
    }
    return out
}

@Test func aPageShowsTheDeepestLevelWhoseEveryHeadingFits() {
    let items = document()
    // All 27 fit: all of them.
    #expect(StripLayout.chosen(items, policy: .document, fit: 30).count == items.count)
    // They don't: the subsections dropped, every top-level heading kept.
    let top = StripLayout.chosen(items, policy: .document, fit: 20)
    #expect(top == items.indices.filter { items[$0].level == 0 })
}

@Test func tooFewToSayAnythingTakesTheNextLevelScrolled() {
    // A title and forty sections under it: the sections, not the title alone.
    let items = [StripItem(level: 0, start: 0, size: 4000)] + (0..<40).map { StripItem(level: 1, start: Double($0 * 100), size: 100) }
    #expect(StripLayout.chosen(items, policy: .document, fit: 20).count == 41)
    #expect(StripLayout.column(count: 41, track: 240).scrolls)
}

@Test func aTerminalsCommandsAllHaveTicks() {
    let items = (0..<40).map { StripItem(start: Double($0 * 10), size: 10) }
    #expect(StripLayout.chosen(items, policy: .recent, fit: 8).count == 40)
}

@Test func heightsAreAgainstTheRestOfTheView() {
    // The same sections, ten times bigger: the same heights.
    let sizes = [10.0, 40, 200, 1000, 30]
    #expect(StripLayout.heights(sizes) == StripLayout.heights(sizes.map { $0 * 10 }))
    let h = StripLayout.heights(sizes)
    #expect(h.min() == 0 && h.max() == 3)
    // Order kept: a bigger one never shorter.
    for (a, b) in zip(sizes, h) { for (c, d) in zip(sizes, h) where a < c { #expect(b <= d) } }
    // All alike: all the middling height.
    #expect(Set(StripLayout.heights([5, 5, 5])) == [1])
}

@Test func whatShowsIsLitItsChildrenWithItWhenTheyWereDropped() {
    let items = document()
    let ticks = items.indices.filter { items[$0].level == 0 }
    // The view on the middle heading's subsections: its tick lit, alone.
    let middle = items[ticks[1]]
    let lit = StripLayout.lit(items, ticks: ticks, offset: middle.start + 200, shown: 100, total: 2000)
    #expect(lit == [1])
}

@Test func theColumnFollowsWhatShowsMovingAsLittleAsItCan() {
    #expect(StripLayout.follow(first: 0, keep: 25...26, shows: 10, count: 40) == 17)
    #expect(StripLayout.follow(first: 17, keep: 20...21, shows: 10, count: 40) == 17)
    #expect(StripLayout.follow(first: 17, keep: 3...3, shows: 10, count: 40) == 3)
    // More shows than fits: its start.
    #expect(StripLayout.follow(first: 0, keep: 5...30, shows: 10, count: 40) == 5)
}

@Test func thePointerWidensTheTicksNearIt() {
    #expect(abs(StripLayout.swollen(0) - StripLayout.swell) < 1e-6)
    #expect(StripLayout.swollen(StripLayout.pitch) > StripLayout.swollen(3 * StripLayout.pitch))
    #expect(StripLayout.swollen(8 * StripLayout.pitch) < 1.01)
}

// The strip's column: evenly spaced, in the middle of the view, within
// two thirds of it; chevrons only while it scrolls, which scroll it.
@MainActor
@Test func theColumnIsEvenlySpacedInTheMiddle() {
    let outline = Outline()
    outline.set((0..<6).map { Outline.Item(title: "Section \($0)") })
    let strip = OutlineStripView(outline: outline, policy: .document)
    strip.frame = NSRect(x: 0, y: 0, width: OutlineStripView.width + OutlineStripView.lane, height: 600)
    strip.set((0..<6).map { StripItem(start: Double($0 * 100), size: Double(50 + $0 * 100)) })
    strip.update(total: 600, offset: 200, shown: 100)
    strip.layoutSubtreeIfNeeded()
    #expect(strip.ticks.count == 6)
    for (a, b) in zip(strip.ticks, strip.ticks.dropFirst()) { #expect(abs(b.y - a.y - StripLayout.pitch) < 0.01) }
    let middle = (strip.ticks.first!.y + strip.ticks.last!.y) / 2
    #expect(abs(middle - 300) <= 1)
    #expect(strip.ticks.filter(\.lit).map(\.index) == [2])
    #expect(strip.debugState.hasPrefix("up - down -"))
}

@MainActor
@Test func aColumnWithMoreThanFitsScrollsByItsChevrons() {
    let outline = Outline()
    outline.set((0..<60).map { Outline.Item(title: "Command \($0)") })
    var picked: [Int] = []
    outline.onPick = { picked.append($0) }
    let strip = OutlineStripView(outline: outline, policy: .recent)
    strip.frame = NSRect(x: 0, y: 0, width: OutlineStripView.width + OutlineStripView.lane, height: 300)
    strip.set((0..<60).map { StripItem(start: Double($0 * 10), size: 10) })
    // At the end: the latest shown, more above.
    strip.update(total: 600, offset: 560, shown: 40)
    strip.layoutSubtreeIfNeeded()
    let shows = strip.ticks.count
    #expect(shows == StripLayout.column(count: 60, track: strip.track.height).shows)
    #expect(strip.track.height == 200)
    #expect(strip.ticks.last?.index == 59)
    #expect(strip.debugState.hasPrefix("up + down -"))
    strip.go(.up)
    #expect(strip.ticks.last!.index < 59)
    #expect(strip.debugState.hasPrefix("up + down +"))
    // Scrolled by hand, it stays where it was put till what shows moves.
    strip.update(total: 600, offset: 560, shown: 40)
    #expect(strip.ticks.last!.index < 59)
    strip.update(total: 600, offset: 570, shown: 30)
    #expect(strip.ticks.last?.index == 59)
    _ = strip.debug("pick 7")
    #expect(picked == [7])
}
