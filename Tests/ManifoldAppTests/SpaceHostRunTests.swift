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

// The line sits clear of a chosen square's ring.
@MainActor
@Test func aLineSitsClearOfAChosenSquaresRing() {
    // The ring: 2 out from the square, 1.5 wide.
    #expect(SpaceStripView.underlineDrop > 2 + 0.75 + 1.5)
    // And clear of the next row.
    #expect(SpaceStripView.underlineDrop + SpaceStripView.underlineWidth + 3 <= SpaceStripView.gap + SpaceStripView.underlineRoom)
}
