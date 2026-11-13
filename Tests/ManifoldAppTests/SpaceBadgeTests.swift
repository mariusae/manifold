import AppKit
import Testing
@testable import Manifold

// A space's badge reads on every colour a space can be: its symbol 4.5:1
// off its disc, the disc still the space's colour, deepened or lightened.
@MainActor
@Test func everySpaceColoursBadgeReads() {
    for appearance in [NSAppearance(named: .aqua)!, NSAppearance(named: .darkAqua)!] {
        appearance.performAsCurrentDrawingAppearance {
            for (name, color) in SpaceLook.colors {
                let (disc, glyph) = SpaceSquare.badgeColors(color)
                let c = Tints.contrast(disc, glyph)
                #expect(c >= 4.5, "\(name) in \(appearance.name.rawValue): \(c):1")
            }
        }
    }
}
