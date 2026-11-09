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
        /// Down to their bars: the bar flown to its row, then made its size.
        var bars: [PlacementID: GridView.Pictured] = [:]
        var up: [PlacementID: NSRect] = [:]
    }

    /// Where a docked tile (or one in another space) is to be seen, in the
    /// root's terms: its row in the sidebar (its section's, till its own
    /// is made) — nil, the sidebar not showing.
    func dockedSpot(_ id: PlacementID, in space: BlockID) -> NSRect? {
        sidebar.organizationView.row(of: id, in: space, in: root)
    }

    /// Before the grid shows `a`: what's to fly, if the space is the one
    /// last seen — into its row in the sidebar, or, the sidebar put away,
    /// into the window's left edge, where it slides out from.
    func dockFlights(before a: ArrangementState) -> DockFlights? {
        let now = Set(a.docked.map(\.placement.id))
        let seen = dockSeen
        dockSeen = (selected, now)
        guard let space = selected, stateView == nil, !Motion.reduced, let seen, seen.space == space, seen.docked != now else { return nil }
        var f = DockFlights()
        let down = now.subtracting(seen.docked)
        if !down.isEmpty {
            let parts = content.placedParts(), bars = content.placedBars()
            for id in down where !stacked.contains(id) {
                if let p = parts[id] { f.down[id] = p.converted(from: content, to: root) } else if let b = bars[id] { f.bars[id] = b.converted(from: content, to: root) }
                if let body = f.down[id]?.parts.first?.1 { dockedPictures[id] = body }
            }
        }
        dockedPictures = dockedPictures.filter { now.contains($0.key) || seen.docked.contains($0.key) }
        for id in seen.docked.subtracting(now) where a.locate(id) != nil && !stacked.contains(id) {
            f.up[id] = sidebar.organizationView.row(of: id, in: space, in: root) ?? .zero
        }
        return f.down.isEmpty && f.bars.isEmpty && f.up.isEmpty ? nil : f
    }

    /// A row's right end, where a tile pours into it.
    static func slotEnd(_ row: NSRect) -> NSRect {
        let w = min(row.width, row.height * 1.4)
        return NSRect(x: row.maxX - w - 6, y: row.minY, width: w, height: row.height)
    }

    /// A tile's picture where it was, held over what comes in its place
    /// till that has drawn, then faded.
    private func holdPicture(of v: PaneContent) {
        guard let view = v as? NSView, let host = root.layer, view.window != nil, let picture = GridView.ghostPicture(of: view) else { return }
        let l = Ghost.layer(picture, at: root.convert(view.bounds, from: view), ground: nil, z: 44)
        host.addSublayer(l)
        Ghost.fadeOut(l, over: Motion.fast, delay: 0.15, key: "held")
    }

    /// Where a tile docks to with the sidebar put away: a sliver at the
    /// window's left edge, level with it.
    private func edgeSpot(_ tile: NSRect) -> NSRect {
        NSRect(x: root.bounds.minX + 2, y: tile.midY - 10, width: 6, height: 20)
    }

    /// How a tile leaving the grid is seen to go: flown, docked with
    /// somewhere to fly to; in a puff, closed (gone from the desk, or on
    /// its way); else moved.
    /// A tile (or a block) dropped on a space's square in the strip: sent
    /// there, docked — moved, or with ⌥ copied — the window staying here; a
    /// tile of the grid's flying into the square as it goes.
    func dropOnSpace(_ item: OrgDragItem, space: BlockID, copy: Bool, square: NSRect) -> Bool {
        guard space != selected, let (block, from) = dragged(item), let b = hosts.block(block), b.kind != .arrangement else { return false }
        let lens = from?.placement.lens ?? Lens.default(for: b.kind, path: b.path)
        let before = Set(hosts.arrangement(space)?.placements.map(\.id) ?? [])
        show(block, lens: lens, .here, in: space)
        if let placed = hosts.arrangement(space)?.placements.first(where: { $0.block == block && !before.contains($0.id) }) {
            hosts.append([.dock(placed.id, heir: nil)], to: .block(space))
        }
        guard let from, !copy else { return true }
        if from.arrangement == selected, !Motion.reduced, let host = root.layer, let p = content.placedParts()[from.placement.id] {
            flownAway.insert(from.placement.id)
            Genie.run(p.converted(from: content, to: root), target: square, restoring: false, in: host, scale: root.backingScale)
        }
        takeOut(from.placement.id, of: from.arrangement)
        return true
    }

    func departure(of v: PaneContent, flown f: DockFlights?) -> GridView.Departure {
        // Going under an $EDITOR: gone as it takes its place, nothing seen.
        if stacked.contains(v.placement) { return .flown }
        // An $EDITOR done: off the stack at once, its picture held a moment
        // over what's under it while that draws.
        if let under = stackTops.removeValue(forKey: v.placement) {
            stacked.remove(under)
            holdPicture(of: v)
            return .flown
        }
        if f?.down[v.placement] != nil || f?.bars[v.placement] != nil || flownAway.remove(v.placement) != nil { return .flown }
        if recentlyClosed.contains(v.block) { return .closed }
        // Still on the desk — this tile, or its block in another space's
        // (moved there) — it's moved; else closed.
        let onDesk = allWorkspaces.contains { w in
            guard let a = hosts.arrangement(w) else { return false }
            return a.placement(v.placement) != nil || (w != selected && a.placements.contains { $0.block == v.block })
        }
        return onDesk ? .moved : .closed
    }

    /// After: each flown, as the Dock's genie — a tile drawn down into its
    /// row in the sidebar, or poured back out of it — the tile itself
    /// showing once it's there.
    func flyDock(_ f: DockFlights?) {
        guard let f, let host = root.layer, let a = arrangement, let space = selected else { return }
        content.layoutSubtreeIfNeeded()
        var landing: [NSView] = []
        let scale = root.backingScale
        let d = Genie.duration
        let rows = sidebar.organizationView
        let tint = Theme.accent.cgColor
        // The sidebar's edge: a tile's row built up as much of it as is past.
        let edge = root.convert(sidebar.bounds, from: sidebar).maxX
        // Into its row: a gap opening for the row as the tile pours into
        // its right end, the row marked, what it says built up from the
        // left as the tile gets there.
        if !f.down.isEmpty || !f.bars.isEmpty {
            rows.glide(over: d * 0.75, opening: Set(f.down.keys).union(f.bars.keys)) { refreshOrganization(now: true) }
        }
        // A tile down to its bar: the bar flown to its row, then made its
        // size, becoming the row on the way.
        for (id, bar) in f.bars {
            if let row = rows.row(of: id, in: space, in: root) {
                Genie.fly(bar, to: row, rowPicture: rows.picture(of: id, in: root)?.image, tint: tint, in: host, over: d, scale: scale)
                rows.markLanding(id, tint: tint, arriving: true, over: d)
                rows.wipe(id, in: true, after: d * 0.6, over: d * 0.4)
            } else {
                Genie.fly(bar, to: edgeSpot(bar.whole), tint: tint, in: host, over: d, scale: scale)
            }
        }
        for (id, tile) in f.down {
            if let row = rows.row(of: id, in: space, in: root) {
                let arrival = Genie.run(tile, target: Self.slotEnd(row), restoring: false, in: host, scale: scale, tint: tint, boundary: edge)
                rows.markLanding(id, tint: tint, arriving: true, over: d)
                if let arrival, arrival.count > 1 { rows.build(id, progress: arrival, over: d) }
            } else {
                Genie.run(tile, target: edgeSpot(tile.whole), restoring: false, in: host, scale: scale, tint: tint)
            }
        }
        // Out of it: the reverse — what the row says taken away as the tile
        // pours out (a bar becoming itself again as it flies out), then the
        // sidebar made again, the rows closing up the slot it leaves.
        var closing = false
        if !f.up.isEmpty {
            let parts = content.placedParts(), bars = content.placedBars()
            for (id, from) in f.up {
                guard let b = a.placement(id)?.block else { continue }
                let inSidebar = from != .zero
                if let p = parts[id] {
                    var tile = p.converted(from: content, to: root)
                    // As it went, not as it is (nothing drawn yet, maybe).
                    if let kept = dockedPictures.removeValue(forKey: id), !tile.parts.isEmpty { tile.parts[0].1 = kept }
                    let arrival = Genie.run(tile, target: inSidebar ? Self.slotEnd(from) : edgeSpot(tile.whole), restoring: true, in: host,
                                            scale: scale, tint: tint, boundary: inSidebar ? edge : nil)
                    guard arrival != nil else { continue }
                    landing += content.tileViews(of: b)
                    if inSidebar, let arrival, arrival.count > 1 {
                        rows.markLanding(id, tint: tint, arriving: false, over: d)
                        rows.build(id, progress: arrival, over: d)
                        closing = true
                    }
                } else if let bar = bars[id] {
                    let bar = bar.converted(from: content, to: root)
                    let picture = inSidebar ? rows.picture(of: id, in: root)?.image : nil
                    Genie.fly(bar, to: inSidebar ? from : edgeSpot(bar.whole), out: true, rowPicture: picture, tint: tint, in: host, over: d, scale: scale)
                    if let v = content.bar(of: id) { landing.append(v) }
                    if inSidebar {
                        rows.markLanding(id, tint: tint, arriving: false, over: d)
                        rows.wipe(id, in: false, after: 0, over: d * 0.4)
                        closing = true
                    }
                }
            }
        }
        if closing {
            let wait = d * 0.5
            sidebarHeldUntil = max(sidebarHeldUntil, CACurrentMediaTime() + wait + 0.2)
            DispatchQueue.main.asyncAfter(deadline: .now() + wait) { [weak self] in
                guard let self else { return }
                self.sidebarHeldUntil = 0
                self.sidebar.organizationView.glide(over: d * 0.5) { self.refreshOrganization(now: true) }
            }
        }
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
