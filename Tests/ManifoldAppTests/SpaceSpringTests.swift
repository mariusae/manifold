import AppKit
import Testing
import ManifoldCore
@testable import Manifold

// Anything dragged and held over a space's square springs it open, as the
// Finder springs a folder: the square flashes twice, then its space.

@MainActor
private func strip() -> (SpaceStripView, [BlockID]) {
    let s = SpaceStripView(frame: NSRect(x: 0, y: 0, width: 300, height: SpaceStripView.height))
    let ids = [BlockID(), BlockID()]
    s.show(ids.enumerated().map { i, id in
        SpaceStripView.Chip(id: id, title: "s\(i)", symbol: nil, letter: "S", color: .systemBlue, current: i == 0, status: nil, hostBreak: false)
    })
    s.layoutSubtreeIfNeeded()
    return (s, ids)
}

@MainActor
@Test func aSpaceHeldOverFlashesTwiceThenOpens() async throws {
    let (s, ids) = strip()
    var sprung: [BlockID] = []
    s.onSpring = { sprung.append($0) }
    s.debugSpring(1)
    var seen: [String] = []
    let end = Date().addingTimeInterval((OrganizationView.springDelay ?? 0.5) + 1.2)
    while Date() < end, sprung.isEmpty {
        let now = s.debugFlashing
        if seen.last != now { seen.append(now) }
        try await Task.sleep(for: .milliseconds(10))
    }
    #expect(seen.filter { $0 != "not flashing" } == ["flashing 1 lit", "flashing 1 dark", "flashing 1 lit", "flashing 1 dark"])
    #expect(sprung == [ids[1]])
    #expect(s.debugFlashing == "not flashing")
}

@MainActor
@Test func aSpaceLeftBeforeItOpensDoesnt() async throws {
    let (s, _) = strip()
    var sprung = 0
    s.onSpring = { _ in sprung += 1 }
    s.debugSpring(1)
    try await Task.sleep(for: .milliseconds(100))
    s.draggingExited(nil)
    try await Task.sleep(for: .seconds((OrganizationView.springDelay ?? 0.5) + 0.6))
    #expect(sprung == 0)
    #expect(s.debugFlashing == "not flashing")
}
