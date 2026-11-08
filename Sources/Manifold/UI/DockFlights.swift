import AppKit
import ManifoldCore

/// Docking seen (§3.1): a tile docked shrinks into its row in the sidebar,
/// and one undocked grows back out of it; a tile closed goes in a puff
/// (the grid's), one moved to another space fades as it goes.
extension MainWindowController {
    // MARK: Flying

    /// Tiles going down into the dock (their pictures as they were in the
    /// grid) and coming back up out of it (from their rows in the
    /// sidebar), in the root's terms.
    struct DockFlights {
        var down: [PlacementID: GridView.Pictured] = [:]
        var up: [PlacementID: NSRect] = [:]
    }

    /// Where a docked tile (or one in another space) is to be seen, in the
    /// root's terms: its row in the sidebar (its section's, till its own
    /// is made) — nil, the sidebar not showing.
    func dockedSpot(_ id: PlacementID, in space: BlockID) -> NSRect? {
        sidebar.organizationView.row(of: id, in: space, in: root)
    }

    /// Before the grid shows `a`: what's to fly, if the space is the one
    /// last seen — only with the sidebar showing, somewhere to fly to;
    /// else the grid sees it go as any move.
    func dockFlights(before a: ArrangementState) -> DockFlights? {
        let now = Set(a.docked.map(\.placement.id))
        let seen = dockSeen
        dockSeen = (selected, now)
        guard let space = selected, stateView == nil, !Motion.reduced, let seen, seen.space == space, seen.docked != now else { return nil }
        var f = DockFlights()
        let down = now.subtracting(seen.docked)
        if !down.isEmpty, sidebar.organizationView.row(of: down.first!, in: space, in: root) != nil {
            let parts = content.placedParts()
            for id in down {
                guard let p = parts[id] else { continue }
                f.down[id] = GridView.Pictured(parts: p.parts.map { (root.convert($0.0, from: content), $0.1) }, ground: p.ground)
            }
        }
        for id in seen.docked.subtracting(now) where a.locate(id) != nil {
            if let row = sidebar.organizationView.row(of: id, in: space, in: root) { f.up[id] = row }
        }
        return f.down.isEmpty && f.up.isEmpty ? nil : f
    }

    /// How a tile leaving the grid is seen to go: flown, docked with
    /// somewhere to fly to; in a puff, closed (gone from the desk, or on
    /// its way); else moved.
    func departure(of v: PaneContent, flown f: DockFlights?) -> GridView.Departure {
        if f?.down[v.placement] != nil { return .flown }
        if recentlyClosed.contains(v.block) { return .closed }
        let onDesk = allWorkspaces.contains { hosts.arrangement($0)?.placement(v.placement) != nil }
        return onDesk ? .moved : .closed
    }

    /// After: each flown — a tile shrinking into its row in the sidebar, or
    /// growing out of it, what it's becoming coming in on the way — the
    /// tile itself showing once it's there.
    func flyDock(_ f: DockFlights?) {
        guard let f, let host = root.layer, let a = arrangement, let space = selected else { return }
        content.layoutSubtreeIfNeeded()
        var items: [GridView.Morph] = []
        var landing: [NSView] = []
        if !f.down.isEmpty { refreshOrganization(now: true) }
        for (id, tile) in f.down {
            if let row = sidebar.organizationView.row(of: id, in: space, in: root) {
                items.append(GridView.Morph(from: tile.whole, to: row, leaving: tile))
            }
        }
        if !f.up.isEmpty {
            let parts = content.placedParts()
            for (id, from) in f.up {
                guard let p = parts[id], let b = a.placement(id)?.block else { continue }
                let tile = GridView.Pictured(parts: p.parts.map { (root.convert($0.0, from: content), $0.1) }, ground: p.ground)
                items.append(GridView.Morph(from: from, to: tile.whole, coming: tile))
                landing += content.tileViews(of: b)
            }
        }
        guard !items.isEmpty else { return }
        let d = Motion.spatial * 1.4
        GridView.morph(items, in: host, over: d)
        for v in landing {
            guard let l = v.layer else { continue }
            let x = CAKeyframeAnimation(keyPath: "opacity")
            x.values = [0, 0]
            x.keyTimes = [0, 1]
            x.duration = d
            l.add(x, forKey: "landing")
        }
    }
}
