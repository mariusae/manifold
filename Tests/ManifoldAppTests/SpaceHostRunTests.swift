import AppKit
import Testing
import ManifoldCore
@testable import Manifold

// Another machine's spaces in the strip are underlined in its colour, row
// by row: a host that begins at a row's start is still told apart (a
// hairline before it was dropped there).

@MainActor
@Test func aRemoteHostsSpacesAreUnderlinedOnEachRowTheyreOn() {
    let far = HostID("far"), near = HostID("near")
    // Narrow: four squares to a row.
    let s = SpaceStripView(frame: NSRect(x: 0, y: 0, width: 4 * (SpaceStripView.side + SpaceStripView.gap) + SpaceStripView.inset + 12,
                                         height: SpaceStripView.height))
    func chip(_ i: Int, _ host: HostID?, first: Bool) -> SpaceStripView.Chip {
        .init(id: BlockID(), title: "s\(i)", symbol: nil, letter: "S", color: .systemBlue, current: false, status: nil,
              hostBreak: first, remote: host)
    }
    // This Mac's three, then far's four (wrapping), then near's one.
    let chips = (0..<3).map { chip($0, nil, first: false) }
        + (0..<4).map { chip(3 + $0, far, first: $0 == 0) }
        + [chip(7, near, first: true)]
    s.show(chips)
    s.layoutSubtreeIfNeeded()
    let runs = s.hostRuns()
    // This Mac's aren't underlined; far's on each row it's on; near's its own.
    #expect(runs.map(\.host) == [far, far, near])
    #expect(runs[0].rect.minY < runs[1].rect.minY)
    #expect(runs[1].rect.minY == runs[2].rect.minY)
    let colors = SpaceStripView.colors(for: [far, near])
    #expect(colors[far] != colors[near])
}

// Each host's line stands off whatever it's on — every theme's wash, its
// pools, its panel — by its lightness, not its hue alone: seen by anyone,
// colour-blind too.
@MainActor
@Test func everyHostsLineStandsOffEveryThemesGround() {
    for palette in Palette.all {
        for dark in [false, true] {
            for i in SpaceStripView.hostPalette.indices {
                let line = SpaceStripView.lineColor(i, palette: palette, dark: dark)
                for ground in SpaceStripView.grounds(palette, dark: dark) {
                    let c = Tints.contrast(line, ground)
                    #expect(c >= 3, "host \(i)'s line on \(palette.id) \(dark ? "dark" : "light"): \(c):1")
                }
            }
        }
    }
}

// Each host's line is told from every other's — in every theme, by day
// and by night, as drawn — by anyone: typical eyes, and those that don't
// tell red from green (protanopia, deuteranopia) or blue from yellow
// (tritanopia).
@MainActor
@Test func everyHostsLineIsToldFromEveryOtherByAnyone() {
    let n = SpaceStripView.hostPalette.count
    for palette in Palette.all {
        for dark in [false, true] {
            let lines = (0..<n).map { SpaceStripView.lineColor($0, palette: palette, dark: dark) }
            for vision in ColorVision.allCases {
                for i in 0..<n {
                    for j in (i + 1)..<n {
                        let d = vision.difference(lines[i], lines[j])
                        #expect(d >= ColorVision.apart, "hosts \(i) and \(j) on \(palette.id) \(dark ? "dark" : "light"), \(vision): \(d)")
                    }
                }
            }
        }
    }
}

// The simulation itself: red and green, far apart to typical eyes, all
// but the same to a deuteranope's; blue and yellow apart to both.
@Test func colorVisionSeesRedAndGreenAsADeuteranopeDoes() {
    let red = NSColor(srgbRed: 0.8, green: 0.25, blue: 0.2, alpha: 1), green = NSColor(srgbRed: 0.45, green: 0.5, blue: 0.15, alpha: 1)
    #expect(ColorVision.typical.difference(red, green) > 0.15)
    #expect(ColorVision.deuteranopia.difference(red, green) < 0.06)
    #expect(ColorVision.deuteranopia.difference(.systemBlue, .systemYellow) > 0.3)
    #expect(ColorVision.typical.difference(red, red) < 1e-6)
}

// The line sits clear of a chosen square's ring.
@MainActor
@Test func aLineSitsClearOfAChosenSquaresRing() {
    // The ring: 2 out from the square, 1.5 wide.
    #expect(SpaceStripView.underlineDrop > 2 + 0.75 + 1.5)
    // And clear of the next row.
    #expect(SpaceStripView.underlineDrop + SpaceStripView.underlineWidth + 3 <= SpaceStripView.gap + SpaceStripView.underlineRoom)
}

// A square dragged among the strip's is put among its host's — its
// section — and no further: dragged onto another host's, it stays at its
// own host's end. Let go somewhere else, it says where: before which.
@MainActor
@Test func aSquareIsReorderedOnlyAmongItsHostsSquares() {
    let here = HostID("here"), far = HostID("far")
    let s = SpaceStripView(frame: NSRect(x: 0, y: 0, width: 400, height: SpaceStripView.height))
    func chip(_ host: HostID, _ i: Int, first: Bool) -> SpaceStripView.Chip {
        .init(id: BlockID(host: host), title: "\(host)\(i)", symbol: nil, letter: "S", color: .systemBlue, current: false, status: nil,
              hostBreak: first && host == far, remote: host == far ? far : nil)
    }
    let chips = (0..<3).map { chip(here, $0, first: $0 == 0) } + (0..<2).map { chip(far, $0, first: $0 == 0) }
    s.show(chips)
    s.layoutSubtreeIfNeeded()
    var moved: [(BlockID, BlockID?)] = []
    s.onReorder = { moved.append(($0, $1)) }
    // The first of here's onto the third: before none (here's last).
    _ = s.debugReorder(0, to: 2)
    #expect(s.chips.map(\.title) == ["here1", "here2", "here0", "far0", "far1"])
    #expect(moved.count == 1 && moved[0].0 == chips[0].id && moved[0].1 == nil)
    // Onto far's squares: still here's, at its end.
    _ = s.debugReorder(1, to: 4)
    #expect(s.chips.map(\.title) == ["here1", "here0", "here2", "far0", "far1"])
    // far's second before its first; the break stays with far's first square.
    _ = s.debugReorder(4, to: 3)
    #expect(s.chips.map(\.title).suffix(2) == ["far1", "far0"])
    #expect(s.chips[3].hostBreak && !s.chips[4].hostBreak)
    #expect(moved.last?.0 == chips[4].id && moved.last?.1 == chips[3].id)
}
