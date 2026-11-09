import Foundation
import Testing
import ManifoldCore
@testable import Manifold

// I-3, M21 (STATE-MACHINES.md): ⌃⇥'s walk belongs to the space it began
// in, and shows that space as it is now.

private typealias Walk = MainWindowController.TileWalk

private func space(_ tiles: Placement...) -> ArrangementState {
    var a = ArrangementState()
    for (i, t) in tiles.enumerated() { a.apply(.place(t, column: i, at: 0)) }
    return a
}

private func noArrival(_ t: PlacementID, _ a: ArrangementState) -> [Event] { [.focus(t)] }

@Test func aWalksPreviewIsOfItsOwnSpaceOnly() {
    let t1 = Placement(block: BlockID(), lens: .terminal), t2 = Placement(block: BlockID(), lens: .terminal)
    let a = space(t1, t2), mine = BlockID(), other = BlockID()
    let walk = Walk(space: mine, places: [.init(space: mine, tile: t1.id), .init(space: mine, tile: t2.id)], index: 0)
    // Its own space: the tile walked to focused, the space itself untouched.
    #expect(a.focused == t2.id)
    #expect(walk.preview(of: mine, a, arriving: noArrival)?.focused == t1.id)
    // Another space shown (an agent's mani open, a space gone): nothing of
    // the walk drawn into it.
    #expect(walk.preview(of: other, a, arriving: noArrival) == nil)
}

@Test func aWalksPreviewFollowsItsSpaceAsItChanges() {
    let t1 = Placement(block: BlockID(), lens: .terminal), t2 = Placement(block: BlockID(), lens: .terminal)
    var a = space(t1, t2)
    let mine = BlockID()
    let walk = Walk(space: mine, places: [.init(space: mine, tile: t1.id)], index: 0)
    #expect(walk.preview(of: mine, a, arriving: noArrival) != nil)
    // The tile walked to closed meanwhile: no preview of the space as it was.
    a.apply(.remove(t1.id))
    #expect(walk.preview(of: mine, a, arriving: noArrival) == nil)
}

@Test func aWalkStepsRoundItsPlacesBothWays() {
    let mine = BlockID()
    var walk = Walk(space: mine, places: (0..<3).map { _ in .init(space: mine, tile: PlacementID()) }, index: 0)
    walk.step(-1)
    #expect(walk.index == 2)
    walk.step(1)
    walk.step(1)
    #expect(walk.index == 1)
}
