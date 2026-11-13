import AppKit
import ManifoldCore
import WebKit
import ManifoldSyntax
import UniformTypeIdentifiers
import PDFKit

extension MainWindowController {
    // MARK: ⌃⇥

    /// ⌃⇥ (⌃⇧⇥ back): this space's tiles — those in the grid and those
    /// docked (§3.1) — the latest settled on first. Each step shows the
    /// next as it would be gone to, in the grid itself: the focus ring and
    /// the sidebar's row on it — a docked one in its column where it would
    /// come back, the others parting for it (and closing again as the walk
    /// goes past). Letting go of control settles there, the ring glowing as
    /// an arrival's does; a quick tap goes back and forth between two.
    /// Those passed on the way aren't settled on; Escape leaves things be.
    /// From the menu it's one step.
    @objc func walkSpaceTiles(_ sender: Any?) { walkTiles(back: false) }
    @objc func walkSpaceTilesBack(_ sender: Any?) { walkTiles(back: true) }


    /// The tiles of the trail, the latest first, from where the window is:
    /// those settled on here, then the hosts' trail, then the rest of this
    /// space — its grid's, then its docked, the latest docked first. Each
    /// tile once, and only one still on the desk; with `space`, only its.
    func tileTrail(space: BlockID? = nil) -> [Settled] {
        var home: [PlacementID: BlockID] = [:]
        for w in allWorkspaces where space == nil || space == w {
            for p in hosts.arrangement(w)?.placements ?? [] where !recentlyClosed.contains(p.block) && !stacked.contains(p.id) { home[p.id] = w }
        }
        var out: [Settled] = []
        var seen: Set<PlacementID> = []
        func add(_ p: PlacementID?) {
            guard let p, let w = home[p], seen.insert(p).inserted else { return }
            out.append(Settled(space: w, tile: p))
        }
        add(arrangement?.focused)
        for s in settled { add(s.tile) }
        for s in trailSteps().reversed() { add(s.placement) }
        for c in arrangement?.columns ?? [] { for p in c { add(p.id) } }
        for d in (arrangement?.docked ?? []).reversed() { add(d.placement.id) }
        return Array(out.prefix(Self.tileWalkLimit))
    }

    static let tileWalkLimit = 24

    private func walkTiles(back: Bool) {
        let step = back ? -1 : 1
        if tileWalk != nil {
            // Its key let go unheard (the app left meanwhile): over.
            if tileHold == nil || (!NSEvent.modifierFlags.contains(tileWalkKey) && !debugHeld) { endTileWalk(settling: true) } else {
                tileWalk?.step(step)
                previewWalk()
                return
            }
        }
        guard let space = selected else { return NSSound.beep() }
        let places = tileTrail(space: space)
        // Where the walk begins: the focused tile, or (none) before the first.
        let start = places.first.map { $0.tile == arrangement?.focused } == true ? 0 : -1
        guard places.count > (start == 0 ? 1 : 0) else { return NSSound.beep() }
        let n = places.count
        let index = ((start + step) % n + n) % n
        guard NSEvent.modifierFlags.contains(tileWalkKey) || debugHeld else { return go(to: places[index]) }
        tileWalk = TileWalk(space: space, places: places, index: index)
        tileHold = ModifierHold(tileWalkKey, released: { [weak self] in self?.endTileWalk(settling: true) },
                                escaped: { [weak self] in self?.endTileWalk(settling: false) })
        previewWalk()
    }

    /// The walk's tile shown as it would be gone to — focused (the ring,
    /// the sidebar's row), and docked or behind a maximized tile, in its
    /// column where it would come back, the others parting for it — in the
    /// grid only: nothing's gone to yet (the space as it is, kept).
    private func previewWalk() {
        guard let w = tileWalk, let preview = walkPreview else { return }
        // Shown in its column where it is, not flown out of the dock.
        dockSeen = (w.space, Set(preview.docked.map(\.placement.id)))
        render()
        refreshOrganization(now: true)
    }

    /// The walk over, nothing gone to and nothing drawn here: its space
    /// no longer shown (the render that found so draws what is).
    func dropTileWalk() {
        tileHold?.stop()
        tileHold = nil
        debugHeld = false
        tileWalk = nil
    }

    /// Control let go (`settling`): gone to the tile walked to, as the grid
    /// shows it already, the ring glowing on it. Escape: the space as it
    /// was, the others closing back over a docked one shown.
    private func endTileWalk(settling: Bool) {
        let walk = tileWalk
        dropTileWalk()
        guard let w = walk else { return }
        if settling, w.places.indices.contains(w.index) { return go(to: w.places[w.index]) }
        if let space = selected, let a = hosts.arrangement(space) { dockSeen = (space, Set(a.docked.map(\.placement.id))) }
        render()
        refreshOrganization(now: true)
    }

    /// Goes to a place: its space shown, its tile back from the dock (or
    /// from behind a maximized one) and focused, the pointer on it.
    func go(to p: Settled) {
        guard let t = p.tile, let a = hosts.arrangement(p.space), a.placement(t) != nil else { return NSSound.beep() }
        if stateView != nil { hideStateView() }
        land(on: t, in: p.space, a)
        render()
        warpPointerToFocus()
    }

    /// "tilewalk step|back|end|escape|tap [s]|order": ⌃⇥ pressed with
    /// control held, control let go, Escape, a quick tap; or the walk and
    /// ⌃⇥'s order.
    func debugTileWalk(_ arg: String) -> String {
        let w = arg.split(separator: " ").map(String.init)
        switch w.first ?? "" {
        case "step", "back", "space", "spaceback":
            debugHeld = true
            walkTiles(back: w.first == "back" || w.first == "spaceback")
        case "tap":
            // "tilewalk tap <seconds>": ⌃⇥ pressed, control let go that much later.
            debugHeld = true
            walkTiles(back: false)
            let after = w.dropFirst().first.flatMap { Double($0) } ?? 0.08
            DispatchQueue.main.asyncAfter(deadline: .now() + after) { [weak self] in self?.endTileWalk(settling: true) }
        case "end": endTileWalk(settling: true)
        case "escape": endTileWalk(settling: false)
        default: break
        }
        func name(_ p: Settled) -> String {
            let t = p.tile.flatMap { hosts.arrangement(p.space)?.placement($0)?.block }.flatMap { hosts.block($0)?.summary().title } ?? "-"
            return t + (p.space == selected ? "" : "@" + String(p.space.ulid.suffix(4)))
        }
        let here = selected.map { name(Settled(space: $0, tile: walkPreview?.focused ?? arrangement?.focused)) } ?? "-"
        let docked = Set(arrangement?.docked.map(\.placement.id) ?? [])
        func named(_ p: Settled) -> String { name(p) + (p.tile.map(docked.contains) == true ? "(docked)" : "") }
        return "focused=\(here) walk=\(tileWalk.map { "\($0.index):" + $0.places.map(named).joined(separator: ",") + " in \(hosts.block($0.space)?.displayTitle ?? "?")" } ?? "-") previewing=\(walkPreview != nil) order=\(tileTrail(space: selected).prefix(8).map(named).joined(separator: ","))"
    }

    /// One workspace to walk: ⌘` (and ⌥⇥) as macOS has it, the app's next window
    /// (or, backward, its previous) — Settings, another window.
    func cycleWindows(back: Bool) {
        let windows = NSApp.orderedWindows.filter { $0.isVisible && $0.canBecomeKey && !$0.isMiniaturized }
        guard windows.count > 1, let key = NSApp.keyWindow, let i = windows.firstIndex(of: key) else { return }
        // Ordered front to back: the next is the one behind; backward, the last.
        let next = back ? windows[(i + 1) % windows.count] : windows.last!
        next.makeKeyAndOrderFront(nil)
    }

    /// Which way one space is from another: as the strip has them, left to
    /// right (1, the other's to the right).
    func slideDirection(from a: BlockID, to b: BlockID) -> CGFloat {
        let strip = sidebar.spaces.chips.map(\.id)
        if let i = strip.firstIndex(of: a), let j = strip.firstIndex(of: b), i != j { return j > i ? 1 : -1 }
        let order = allWorkspaces
        guard let i = order.firstIndex(of: a), let j = order.firstIndex(of: b) else { return 1 }
        return j >= i ? 1 : -1
    }

    /// The arrangement about to be shown (`content`, its grid shown) slides
    /// in over the one shown — from the right for `dir` 1 (the next in the
    /// strip), from the left for -1 — whose grid slides out the other way,
    /// both live. Only their layers
    /// move, so nothing is laid out again on the way. With less motion
    /// asked for, the one fades in over the other.
    func slide(_ dir: CGFloat, leaving old: GridView) {
        finishSlide()
        let frame = content.frame
        content.layer?.zPosition = 1
        old.layer?.zPosition = 0
        guard let incoming = content.layer, let leaving = old.layer else { return old.isHidden = true }
        slidingAway = old
        sliding = true
        stage.layer?.masksToBounds = true
        CATransaction.begin()
        CATransaction.setCompletionBlock { [weak self] in self?.finishSlide() }
        func animate(_ layer: CALayer, _ keyPath: String, _ from: Any, _ to: Any, _ duration: TimeInterval, _ ease: CAMediaTimingFunction) {
            let a = CABasicAnimation(keyPath: keyPath)
            a.fromValue = from
            a.toValue = to
            a.duration = duration
            a.timingFunction = ease
            a.fillMode = .forwards
            a.isRemovedOnCompletion = false
            layer.add(a, forKey: "manifold.slide")
        }
        if Motion.reduced {
            animate(incoming, "opacity", 0, 1, Motion.base, Motion.appear)
        } else {
            let w = frame.width
            animate(incoming, "transform", CATransform3DMakeTranslation(dir * w, 0, 0), CATransform3DIdentity, Motion.spatial, Motion.travel)
            animate(leaving, "transform", CATransform3DIdentity, CATransform3DMakeTranslation(-dir * w, 0, 0), Motion.spatial, Motion.travel)
        }
        CATransaction.commit()
    }

    /// The grid slid away is hidden (its tiles kept, for coming back to) —
    /// unless it's the one shown again since.
    private func finishSlide() {
        guard sliding else { return }
        sliding = false
        stage.layer?.masksToBounds = false
        content.layer?.removeAnimation(forKey: "manifold.slide")
        if let g = slidingAway {
            g.layer?.removeAnimation(forKey: "manifold.slide")
            if g !== content { g.isHidden = true }
        }
        slidingAway = nil
    }

    func setUp(_ g: GridView) {
        g.delegate = self
        // A tile going out of sight (docked, to its bar): pictured now,
        // as it still shows — collapsed to its bar it has no size to be
        // pictured at later. Behind one maximized it keeps its size, so
        // it's pictured when a card wants it (a page now: its snapshot
        // comes later, and a hidden page may give none) — pictured here,
        // every tile a maximize hid was drawn whole in its turn.
        g.onHiding = { [weak self, weak g] view in
            if g?.full == nil || view is WebView || view is MarkdownView { self?.rememberPicture(of: view) }
        }
    }

    /// A workspace's grid: its own, kept, if it has one; else one made (or
    /// taken from the workspace used longest ago, whose tiles leave the
    /// window) — `liveGrids` at most.
    func grid(for id: BlockID?) -> GridView {
        guard let id else { return blankGrid }
        gridOrder.removeAll { $0 == id }
        gridOrder.insert(id, at: 0)
        if let g = grids[id] { return g }
        let g: GridView
        if grids.count >= Self.liveGrids,
           let oldest = gridOrder.dropFirst().last(where: { grids[$0] != nil && grids[$0] !== content && grids[$0] !== slidingAway }),
           let taken = grids.removeValue(forKey: oldest) {
            gridOrder.removeAll { $0 == oldest }
            taken.clear()
            g = taken
        } else {
            g = GridView()
            setUp(g)
            stage.addSubview(g)
        }
        g.frame = stage.bounds
        grids[id] = g
        return g
    }

    /// Workspaces gone from the desk let go of their grids.
    func pruneGrids() {
        let live = Set(allWorkspaces)
        for (id, g) in grids where !live.contains(id) && g !== content && g !== slidingAway {
            g.clear()
            g.removeFromSuperview()
            grids.removeValue(forKey: id)
            gridOrder.removeAll { $0 == id }
        }
    }

    /// Tiles pictured for their cards, a second after the last switch and
    /// one a turn after that (each a whole drawing of the tile: tens of
    /// milliseconds for an editor, in the switch's wake it was most of its
    /// cost); another switch first, and they wait for it instead.
    func picture(_ leaving: [PaneContent]) {
        picturing += 1
        let round = picturing
        func next(_ rest: ArraySlice<PaneContent>, after delay: TimeInterval) {
            guard let v = rest.first else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                guard let self, self.picturing == round else { return }
                if v.window != nil { self.rememberPicture(of: v, evenHidden: true) }
                next(rest.dropFirst(), after: 0.05)
            }
        }
        next(leaving[...], after: 1)
    }

    /// ⌘1 to ⌘8: the strip's squares in order (as their badges number
    /// them with ⌘ held); ⌘9 the last.
    @objc func selectTabByNumber(_ sender: NSMenuItem) {
        let order = sidebar.spaces.chips.isEmpty ? allWorkspaces : sidebar.spaces.chips.map(\.id)
        guard !order.isEmpty else { return }
        let n = sender.tag
        let i = n == 9 ? order.count - 1 : n - 1
        if i < order.count { hosts.select(order[i]) }
    }
}
