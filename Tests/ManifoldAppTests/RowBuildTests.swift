import AppKit
import Testing
import ManifoldCore
@testable import Manifold

// A tile put back from the dock: its row, taken away as the tile pours out
// of it, is the same row under On Screen once the sidebar's made again —
// and the mask that took it away went with it, the row blank there for
// good. It's shown again once the rows have been given since.

@MainActor
private func rows(_ p: PlacementID, docked: Bool) -> [OrgNode] {
    func label(_ t: String) -> OrgNode { let n = OrgNode(id: "label/\(t)", title: t, symbol: ""); n.style = .section; return n }
    let tile = OrgNode(id: "tile/\(p)", title: "Terminal", symbol: "terminal")
    tile.placement = p
    tile.docked = docked
    let other = OrgNode(id: "tile/other", title: "Notes", symbol: "doc")
    return docked ? [label("On Screen"), other, label("Docked"), tile] : [label("On Screen"), other, tile, label("Docked")]
}

@MainActor
@Test func aRowTakenAwayAsItsTileLeavesTheDockIsShownWhereItGoes() async throws {
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 260, height: 400), styleMask: [.titled], backing: .buffered, defer: false)
    let view = OrganizationView(frame: NSRect(x: 0, y: 0, width: 260, height: 400))
    window.contentView?.addSubview(view)
    let p = PlacementID()
    view.show(rows(p, docked: true))
    view.layoutSubtreeIfNeeded()
    // Taken away as the tile pours out of it.
    view.build(p, progress: [1, 0.5, 0], over: 0.05)
    try await Task.sleep(for: .milliseconds(150))
    // The sidebar made again: the tile on screen.
    view.show(rows(p, docked: false))
    view.layoutSubtreeIfNeeded()
    try await Task.sleep(for: .milliseconds(400))
    let line = view.debugRowViews().split(separator: "\n").first { $0.contains(" Terminal ") }
    #expect(line?.contains("mask false") == true, "\(line ?? "no row")")
}
