import AppKit
import Testing
@testable import Manifold

// The outline strip (§3.1, §7.5): an outline's items as marks down a view's
// edge, as many as fit, the most telling — and magnified around the
// pointer, the room that opens given to the items there.

/// A document: ten sections under three top-level headings, each
/// heading followed by its subsections.
private func document() -> [StripItem] {
    var out: [StripItem] = [], at = 0.0
    for top in 0..<3 {
        out.append(StripItem(level: 0, start: at, size: 100)); at += 100
        for _ in 0..<(top == 1 ? 12 : 6) {
            out.append(StripItem(level: top == 2 ? 2 : 1, start: at, size: 60)); at += 60
        }
    }
    return out
}

private func total(_ items: [StripItem]) -> Double { (items.last.map { $0.start + $0.size }) ?? 1 }

@Test func atRestAStripShowsAsManyAsFitTopLevelFirst() {
    let items = document()
    let rest = StripLayout.rest(items, total: total(items), focus: 0.5, policy: .document, budget: 8)
    #expect(rest.count == 8)
    #expect(rest == rest.sorted())
    // Every top-level heading is among them, wherever it is.
    for (i, item) in items.enumerated() where item.level == 0 { #expect(rest.contains(i)) }
}

@Test func aTerminalsLatestCommandsAndItsFailuresAreKept() {
    var items = (0..<40).map { StripItem(start: Double($0 * 10), size: 10) }
    items[3].failed = true
    let rest = StripLayout.rest(items, total: 400, focus: 1, policy: .recent, budget: 8)
    // The last few, and the early one that failed.
    #expect(rest.contains(39) && rest.contains(38) && rest.contains(37))
    #expect(rest.contains(3))
    #expect(!rest.contains(10))
}

@Test func restingMarksAreWhereTheirItemsAreAndAPitchApart() {
    let items = document()
    let rest = StripLayout.rest(items, total: total(items), focus: 0.5, policy: .document, budget: 10)
    let marks = StripLayout.place(items, rest: rest, total: total(items), height: 300)
    for (a, b) in zip(marks, marks.dropFirst()) { #expect(b.y - a.y >= StripLayout.pitch - 0.01) }
    #expect(marks.allSatisfy { $0.y >= StripLayout.pad - 0.01 && $0.y <= 300 - StripLayout.pad + 0.01 })
    // The last top-level heading is about where it is on the page.
    let last = items.lastIndex { $0.level == 0 }!
    let y = marks.first { $0.index == last }!.y
    let expected = StripLayout.pad + CGFloat(items[last].start / total(items)) * (300 - 2 * StripLayout.pad)
    #expect(abs(y - expected) < 30)
}

@Test func theLensKeepsItsEndsAndWhereItIs() {
    for p in [0.0, 0.3, 0.5, 0.9, 1.0] {
        #expect(abs(StripLayout.fisheye(0, at: p, by: 2) - 0) < 1e-9)
        #expect(abs(StripLayout.fisheye(1, at: p, by: 2) - 1) < 1e-9)
        #expect(abs(StripLayout.fisheye(p, at: p, by: 2) - p) < 1e-9)
    }
    // Monotone: order kept.
    let xs = stride(from: 0.0, through: 1.0, by: 0.05).map { StripLayout.fisheye($0, at: 0.4, by: 3) }
    #expect(xs == xs.sorted())
}

@Test func theMarkUnderThePointerStaysAsTheStripMagnifies() {
    let items = document()
    let rest = StripLayout.rest(items, total: total(items), focus: 0.5, policy: .document, budget: 10)
    let calm = StripLayout.place(items, rest: rest, total: total(items), height: 300)
    let under = calm[4]
    let p = Double((under.y - StripLayout.pad) / (300 - 2 * StripLayout.pad))
    let lit = StripLayout.place(items, rest: rest, total: total(items), height: 300, pointer: p, magnification: 2.6)
    let moved = lit.first { $0.index == under.index }!
    #expect(abs(moved.y - under.y) < 4, "\(under.y) → \(moved.y)")
    #expect(moved.scale > 1.5)
}

@Test func theRoomTheLensOpensIsGivenToItemsThereOnly() {
    let items = document()
    let rest = StripLayout.rest(items, total: total(items), focus: 0, policy: .document, budget: 8)
    let calm = StripLayout.place(items, rest: rest, total: total(items), height: 300)
    // The pointer over the long middle section, most of whose subsections didn't fit.
    let p = 0.5
    let lit = StripLayout.place(items, rest: rest, total: total(items), height: 300, pointer: p, magnification: 2.6)
    let extra = lit.filter(\.extra)
    #expect(!extra.isEmpty)
    #expect(Set(calm.map(\.index)).isSubset(of: Set(lit.map(\.index))))
    // All near the pointer.
    let py = StripLayout.pad + CGFloat(p) * (300 - 2 * StripLayout.pad)
    #expect(extra.allSatisfy { abs($0.y - py) < 120 })
    // In order, and never on top of one another.
    #expect(lit.map(\.index) == lit.map(\.index).sorted())
    for (a, b) in zip(lit, lit.dropFirst()) { #expect(b.y - a.y >= StripLayout.minPitch - 0.01) }
}

@Test func marksDontTradePlacesForAFewPoints() {
    let items = document()
    let t = total(items)
    let a = StripLayout.rest(items, total: t, focus: 0.40, policy: .document, budget: 9)
    let b = StripLayout.rest(items, total: t, focus: 0.41, policy: .document, budget: 9, previous: Set(a))
    #expect(a == b)
}

// Its chevrons, as claude.ai's strip has its ⌃: to the item before where
// you are (the start of the one you're in, if you're well into it), and
// to the one after; none where there's nowhere to go.
@MainActor
@Test func theChevronsGoToTheItemBeforeAndAfter() {
    let outline = Outline()
    outline.set((0..<6).map { Outline.Item(title: "Section \($0)") })
    var picked: [Int] = []
    outline.onPick = { picked.append($0) }
    let strip = OutlineStripView(outline: outline, policy: .document)
    strip.frame = NSRect(x: 0, y: 0, width: OutlineStripView.width, height: 300)
    strip.set((0..<6).map { StripItem(start: Double($0 * 100), size: 100) })
    // At the start of section 2.
    strip.update(total: 600, offset: 200, shown: 100)
    outline.current = 2
    strip.layoutSubtreeIfNeeded()
    #expect(strip.previousTarget == 1)
    #expect(strip.nextTarget == 3)
    strip.go(.up)
    strip.go(.down)
    #expect(picked == [1, 3])
    // Well into section 2: ⌃ goes back to its start first.
    strip.update(total: 600, offset: 250, shown: 100)
    #expect(strip.previousTarget == 2)
    // At the first, nothing before; at the last, nothing after.
    strip.update(total: 600, offset: 0, shown: 100)
    outline.current = 0
    #expect(strip.previousTarget == nil)
    outline.current = 5
    strip.update(total: 600, offset: 500, shown: 100)
    #expect(strip.nextTarget == nil)
}

// The strip takes half the view's height, in its middle: its marks, its
// knob and its chevrons all within it.
@MainActor
@Test func theStripIsHalfTheViewInItsMiddle() {
    let outline = Outline()
    outline.set((0..<60).map { Outline.Item(title: "Item \($0)", level: $0 % 5 == 0 ? 0 : 1) })
    let strip = OutlineStripView(outline: outline, policy: .document)
    strip.frame = NSRect(x: 0, y: 0, width: OutlineStripView.width, height: 600)
    strip.set((0..<60).map { StripItem(level: $0 % 5 == 0 ? 0 : 1, start: Double($0 * 10), size: 10) })
    strip.update(total: 600, offset: 0, shown: 100)
    strip.layoutSubtreeIfNeeded()
    #expect(strip.track.top == 150 && strip.track.height == 300)
    #expect(!strip.marks.isEmpty)
    #expect(strip.marks.allSatisfy { $0.y >= 150 && $0.y <= 450 })
    #expect(strip.marks.count == StripLayout.budget(height: 300))
    // A short view: at least 120 points of it.
    strip.frame.size.height = 180
    strip.layoutSubtreeIfNeeded()
    #expect(strip.track.height == 120 && strip.track.top == 30)
}
