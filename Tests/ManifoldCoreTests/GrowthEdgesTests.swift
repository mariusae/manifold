import Foundation
import Testing
@testable import ManifoldCore

// Which way a click grows a tile, as `growing` takes the room: from below
// first (its bottom edge down), then from above (its top edge up).
@Test func aTileGrowsTheWayItsNeighboursGiveRoom() {
    // Room below: down only.
    #expect(ArrangementState.growthEdges([0.3, 0.3, 0.4], at: 0).map { [$0.down, $0.up] } == [true, false])
    // The last: up only.
    #expect(ArrangementState.growthEdges([0.3, 0.3, 0.4], at: 2).map { [$0.down, $0.up] } == [false, true])
    // The one below down to a sliver already: from above.
    #expect(ArrangementState.growthEdges([0.5, 0.46, 0.04], at: 1).map { [$0.down, $0.up] } == [false, true])
    // Below gives a little, above the rest: both.
    #expect(ArrangementState.growthEdges([0.5, 0.4, 0.1], at: 1).map { [$0.down, $0.up] } == [true, true])
    // Alone in its column: it can't.
    #expect(ArrangementState.growthEdges([1], at: 0) == nil)
}
