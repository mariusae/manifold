import AppKit
import ManifoldCore
import WebKit
import ManifoldSyntax
import UniformTypeIdentifiers
import PDFKit

extension MainWindowController {
    // MARK: ⌃⇥

    /// ⌃⇥ (⌃⇧⇥ back): this space's tiles — those in the grid and those
    /// docked (§3.1) — the latest settled on first. As ⌘⇥ is: let go
    /// quickly, and it's gone to the one before (back and forth between
    /// two); held a moment, the cards come, each ⌃⇥ a step further, and
    /// letting go of control goes to the one chosen — its card becoming
    /// its tile (a docked one going back where it was). Those passed on the
    /// way aren't settled on; Escape leaves things be. From the menu it's
    /// one step. (⌥⇥ is left unbound.)
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
        let pressed = Date()
        let step = back ? -1 : 1
        if var w = tileWalk {
            // Its key let go unheard (the app left meanwhile): over.
            if tileMonitors.isEmpty || (!NSEvent.modifierFlags.contains(tileWalkKey) && !debugHeld) { endTileWalk(settling: true) } else {
                let n = w.places.count
                w.index = ((w.index + step) % n + n) % n
                tileWalk = w
                tileSwitcher?.column.choose(w.index)
                if tileUnseen != nil {
                    // ⇥ again before the cards showed: no tap — they come at once.
                    w.show.cancel()
                    revealTileSwitcher(settledBy: Date() + Self.switcherHurried)
                } else {
                    // On their way: what's wanted is plain, the rest hurried.
                    GridView.hurry(tileFlights)
                }
                return
            }
        }
        let places = tileTrail(space: selected)
        // Where the walk begins: the focused tile, or (none) before the first.
        let start = places.first.map { $0.tile == arrangement?.focused } == true ? 0 : -1
        guard places.count > (start == 0 ? 1 : 0) else { return NSSound.beep() }
        let n = places.count
        let index = ((start + step) % n + n) % n
        guard NSEvent.modifierFlags.contains(tileWalkKey) || debugHeld else { return go(to: places[index]) }
        // The cards made now, out of sight, shown in a moment if control's
        // still held, and in place when the wait's done.
        let work = DispatchWorkItem { [weak self] in self?.revealTileSwitcher(settledBy: pressed + Self.switcherSettled) }
        tileWalk = (places, index, work)
        watchTileWalk()
        prepareTileSwitcher()
        // From the press, not from when they're made.
        DispatchQueue.main.asyncAfter(deadline: .now() + max(0, (pressed + Self.switcherDelay).timeIntervalSinceNow), execute: work)
    }


    private func watchTileWalk() {
        tileMonitors.append(NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            guard let self else { return event }
            if !event.modifierFlags.contains(self.tileWalkKey) { self.endTileWalk(settling: true) }
            return event
        } as Any)
        tileMonitors.append(NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard event.keyCode == 53 else { return event }
            self?.endTileWalk(settling: false)
            return nil
        } as Any)
        tileLeaving = NotificationCenter.default.addObserver(forName: NSApplication.didResignActiveNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.unchecked { self?.endTileWalk(settling: true) }
        }
    }

    /// Option let go (`settling`), or Escape: let go before the cards
    /// showed, gone to the tile stepped to with nothing shown; after, the
    /// card chosen becomes its tile, and the rest go back to theirs.
    private func endTileWalk(settling: Bool, to chosen: Int? = nil) {
        tileMonitors.forEach(NSEvent.removeMonitor)
        tileMonitors = []
        if let o = tileLeaving { NotificationCenter.default.removeObserver(o) }
        tileLeaving = nil
        debugHeld = false
        guard let w = tileWalk else { return }
        tileWalk = nil
        w.show.cancel()
        let index = chosen ?? w.index
        let target = settling && w.places.indices.contains(index) ? w.places[index] : nil
        guard let (frame, column) = tileSwitcher else {
            if let target { go(to: target) }
            return
        }
        // Let go before the cards were in place (unseen, or unfolding): a
        // tap — put away at once, gone to the tile stepped to.
        if tileUnseen != nil {
            tileUnseen = nil
            tileSwitcher = nil
            landTiles()
            frame.removeFromSuperview()
            if let target { go(to: target) }
            return
        }
        // Unfolding: folded back the way they came, then gone there.
        if !column.cardsShown {
            tileSwitcher = nil
            let flights = tileFlights
            tileFlights = []
            GridView.foldBack(flights, began: tileUnfoldBegan, fading: frame) { [weak self] in
                if let target { self?.go(to: target) }
            }
            return
        }
        tileSwitcher = nil
        landTiles()
        let cards = column.cardPictures(in: root)
        frame.removeFromSuperview()
        let home = arrangement?.focused
        if let target { go(to: target) }
        guard let host = root.layer else { return }
        // Where the space has its tiles now (the one gone to, if another).
        content.layoutSubtreeIfNeeded()
        let tiles = partsInRoot(content.placedParts(), from: content)
        let arriving = target?.tile ?? home
        var items: [GridView.Morph] = []
        for c in cards where c.frame != .zero {
            let card = GridView.Pictured(parts: [(c.frame, c.picture)], ground: c.ground)
            if c.id == arriving {
                // The one chosen (or, let be, the one it began from) becomes its tile.
                content.becomeTile(c.id, from: card, picture: c.picture, at: c.frame, in: root)
            } else if let tile = tiles[c.id] {
                // Back into its tile, here: grown to its size where it is,
                // then across into it, becoming it (as a docked bar comes out).
                let scale = window?.backingScaleFactor ?? 2
                var l: CALayer?
                l = Genie.flight(tile.whole, Genie.image(of: tile, scale: scale), ground: tile.ground, to: c.frame, c.picture, ground: c.ground,
                                 out: true, in: host, over: Motion.spatial * 1.5, scale: scale) { l?.removeFromSuperlayer() }
                if let l { tileFlights.append(l) }
            } else if let place = w.places.first(where: { $0.tile == c.id }), let t = place.tile,
                      let row = dockedSpot(t, in: place.space) {
                // Docked: back into its row in the sidebar, as a bar docks — across, then its size, becoming it.
                let scale = window?.backingScaleFactor ?? 2
                tileFlights.append(Genie.flight(c.frame, c.picture, ground: c.ground, to: row, sidebar.organizationView.picture(of: t, in: root)?.image, ground: nil,
                                                fade: true, corner: Radius.control, in: host, over: Motion.spatial * 1.5, scale: scale))
                _ = card
            } else {
                // Its tile's in another space: gone, sinking a little.
                let l = CALayer()
                l.contents = c.picture
                l.backgroundColor = c.ground
                l.frame = c.frame
                l.cornerRadius = Radius.surface
                l.cornerCurve = .continuous
                l.masksToBounds = true
                l.zPosition = 39
                l.opacity = 0
                host.addSublayer(l)
                let fade = CABasicAnimation(keyPath: "opacity")
                fade.fromValue = 1
                fade.toValue = 0
                let sink = CABasicAnimation(keyPath: "transform.scale")
                sink.fromValue = 1
                sink.toValue = Motion.reduced ? 1 : 0.94
                let g = CAAnimationGroup()
                g.animations = [fade, sink]
                g.duration = Motion.fast
                g.timingFunction = Motion.disappear
                CATransaction.begin()
                CATransaction.setCompletionBlock { l.removeFromSuperlayer() }
                l.add(g, forKey: "gone")
                CATransaction.commit()
                tileFlights.append(l)
            }
        }
        tileFlights += GridView.morph(items, in: host, over: Motion.spatial * 1.5)
    }

    private func landTiles() {
        tileFlights.forEach { $0.removeFromSuperlayer() }
        tileFlights = []
        tileSwitcher?.column.cardsShown = true
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

    /// The cards now (debugging): made, and unfolding as a click's would.
    private func showTileSwitcher() {
        prepareTileSwitcher()
        revealTileSwitcher(settledBy: Date() + Motion.spatial * 1.5)
    }

    /// The cards shown, unfolding to be in place by `settledBy`, if they're
    /// made and not yet seen.
    private func revealTileSwitcher(settledBy: Date) {
        guard let go = tileUnseen else { return }
        tileUnseen = nil
        go(settledBy)
    }

    /// The cards made, over the space, out of sight till they're shown —
    /// the one stepped to chosen; the focused tile to become the first,
    /// the rest to come from their tiles here, or out from under it.
    private func prepareTileSwitcher() {
        guard let w = tileWalk, tileSwitcher == nil, NSEvent.modifierFlags.contains(tileWalkKey) || debugHeld else { return }
        let entries = w.places.compactMap { p -> SummaryCardContent? in
            guard let t = p.tile, let b = hosts.arrangement(p.space)?.placement(t)?.block, var c = cardContent(for: b, view: views[t], id: t) else { return nil }
            // Where it is, if not here.
            if p.space != selected, let a = hosts.arrangement(p.space) { c.age = title(of: a) }
            return c
        }
        guard entries.count == w.places.count else { return endTileWalk(settling: false) }
        let column = CardColumnView(entries: entries, selection: w.index)
        column.onPick = { [weak self] id, _ in
            guard let self, let i = self.tileWalk?.places.firstIndex(where: { $0.tile == id }) else { return }
            self.endTileWalk(settling: true, to: i)
        }
        column.onCancel = { [weak self] in self?.endTileWalk(settling: false) }
        let room = root.convert(content.bounds, from: content).insetBy(dx: 32, dy: 32)
        let width = min(520, room.width)
        let height = min(CardColumnView.height(for: entries.count), room.height, 640)
        // Floating over the space: a shadow under the column.
        let frame = NSView(frame: NSRect(x: room.midX - width / 2, y: room.midY - height / 2, width: width, height: height).integral)
        frame.wantsLayer = true
        Elevation.float.apply(to: frame.layer!)
        frame.layer?.shadowPath = CGPath(roundedRect: frame.bounds, cornerWidth: Radius.surface, cornerHeight: Radius.surface, transform: nil)
        frame.layer?.zPosition = 30
        column.frame = frame.bounds
        column.autoresizingMask = [.width, .height]
        frame.addSubview(column)
        root.addSubview(frame, positioned: .above, relativeTo: stateView ?? stage)
        tileSwitcher = (frame, column)
        column.present(dealt: false)
        // Out of sight till shown; its cards' pictures taken now.
        frame.alphaValue = 0
        guard !Motion.reduced, let host = root.layer else {
            tileUnseen = { [weak self, weak frame] _ in
                guard let self, let frame else { return }
                frame.alphaValue = 1
                self.fadeIn(frame)
            }
            return
        }
        content.layoutSubtreeIfNeeded()
        let tiles = partsInRoot(content.placedParts(), from: content)
        let cards = column.cardPictures(in: root)
        guard let first = cards.first(where: { $0.frame != .zero }) else {
            tileUnseen = { [weak frame] _ in frame?.alphaValue = 1 }
            return
        }
        // Each card a little after the one before, within the time given.
        let stagger = 0.008, staggered = min(Double(cards.count - 1) * stagger, 0.024)
        var items: [GridView.Morph] = []
        // Tiles into their cards as a bar into its row: across at their
        // size, then made the card's, becoming it.
        var flights: [(tile: GridView.Pictured, card: NSRect, picture: CGImage?, ground: CGColor, delay: Double)] = []
        for (i, c) in cards.enumerated() where c.frame != .zero {
            let card = GridView.Pictured(parts: [(c.frame, c.picture)], ground: c.ground)
            let delay = min(Double(i) * stagger, staggered)
            if let tile = tiles[c.id] {
                flights.append((tile, c.frame, c.picture, c.ground, delay))
            } else if let place = w.places.first(where: { $0.tile == c.id }), let t = place.tile,
                      let row = dockedSpot(t, in: place.space) {
                // Docked: out of its row in the sidebar, as a docked bar comes out.
                flights.append((GridView.Pictured(parts: [(row, sidebar.organizationView.picture(of: t, in: root)?.image)], ground: nil),
                                c.frame, c.picture, c.ground, delay))
                _ = card
            } else {
                // Elsewhere: out from under the first.
                items.append(GridView.Morph(from: first.frame, to: c.frame, coming: card, delay: delay))
            }
        }
        column.cardsShown = false
        tileUnseen = { [weak self, weak frame, weak column] settledBy in
            guard let self, let frame, let column, self.tileSwitcher?.column === column else { return }
            frame.alphaValue = 1
            // (A frame allowed for its many flights to be put on screen.)
            let d = max(settledBy.timeIntervalSinceNow - staggered - 1.0 / 60, 0.05) * Motion.slowdown
            self.debugTilesShown = Date()
            self.tileUnfoldBegan = CACurrentMediaTime()
            // The cards shown once every flight's there (the morphs' and the tiles').
            var waiting = flights.count + 1
            var flown: [CALayer] = []
            let arrived = { [weak self, weak column] in
                waiting -= 1
                guard waiting == 0 else { return }
                column?.cardsShown = true
                flown.forEach { $0.removeFromSuperlayer() }
                self?.debugTilesSettled = Date()
            }
            let scale = self.window?.backingScaleFactor ?? 2
            for f in flights {
                let l = Genie.flight(f.tile.whole, Genie.image(of: f.tile, scale: scale), ground: f.tile.ground, to: f.card, f.picture, ground: f.ground,
                                     in: host, over: d, delay: f.delay, scale: scale) { arrived() }
                flown.append(l)
                self.tileFlights.append(l)
            }
            self.tileFlights += GridView.morph(items, in: host, over: d) { arrived() }
            // The column's ground comes in under them.
            if let l = column.layer, let ground = l.backgroundColor {
                let a = CABasicAnimation(keyPath: "backgroundColor")
                a.fromValue = ground.copy(alpha: 0)
                a.toValue = ground
                a.duration = d
                a.timingFunction = Motion.appear
                l.add(a, forKey: "ground")
                let s = CABasicAnimation(keyPath: "shadowOpacity")
                s.fromValue = 0
                s.toValue = frame.layer?.shadowOpacity ?? 0
                s.duration = d
                frame.layer?.add(s, forKey: "ground")
            }
        }
    }


    /// "tilewalk step|back|end|escape|order|pick <n>": ⌃⇥ pressed with
    /// option held, option let go, Escape, a card clicked; or the walk and
    /// ⌃⇥'s order.
    func debugTileWalk(_ arg: String) -> String {
        let w = arg.split(separator: " ").map(String.init)
        switch w.first ?? "" {
        case "step", "back", "space", "spaceback":
            // ("space", "spaceback": the same, as they were once another walk's.)
            debugHeld = true
            if tileWalk == nil { debugTilesPressed = Date(); debugTilesShown = nil; debugTilesSettled = nil }
            walkTiles(back: w.first == "back" || w.first == "spaceback")
        case "again":
            // "tilewalk again <seconds>": ⌃⇥ pressed, then ⇥ again that much later.
            debugHeld = true
            debugTilesPressed = Date(); debugTilesShown = nil; debugTilesSettled = nil
            walkTiles(back: false)
            let after = w.dropFirst().first.flatMap { Double($0) } ?? 0.03
            DispatchQueue.main.asyncAfter(deadline: .now() + max(0, (debugTilesPressed! + after).timeIntervalSinceNow)) { [weak self] in self?.walkTiles(back: false) }
        case "tap":
            // "tilewalk tap <seconds>": ⌃⇥ pressed, control let go that much later.
            // (Timed from the press, as a key let go is, not from when the
            // cards are made.)
            debugHeld = true
            let pressed = Date()
            debugTilesPressed = pressed; debugTilesShown = nil; debugTilesSettled = nil
            walkTiles(back: false)
            let after = w.dropFirst().first.flatMap { Double($0) } ?? 0.08
            DispatchQueue.main.asyncAfter(deadline: .now() + max(0, (pressed + after).timeIntervalSinceNow)) { [weak self] in self?.endTileWalk(settling: true) }
        case "timing":
            // From the first step's press: when the cards were shown, and in place.
            let ms = { (d: Date?) in d.flatMap { d in self.debugTilesPressed.map { String(Int(d.timeIntervalSince($0) * 1000)) } } ?? "-" }
            return "shown \(ms(debugTilesShown)) settled \(ms(debugTilesSettled)) ms"
        case "show": tileWalk.map { _ in showTileSwitcher() }
        case "end": endTileWalk(settling: true)
        case "escape": endTileWalk(settling: false)
        case "pick": if let i = w.dropFirst().first.flatMap({ Int($0) }) { tileSwitcher.map { _ = $0.column.debugPick(i) } }
        default: break
        }
        func name(_ p: Settled) -> String {
            let t = p.tile.flatMap { hosts.arrangement(p.space)?.placement($0)?.block }.flatMap { hosts.block($0)?.summary().title } ?? "-"
            return t + (p.space == selected ? "" : "@" + String(p.space.ulid.suffix(4)))
        }
        let here = selected.map { name(Settled(space: $0, tile: arrangement?.focused)) } ?? "-"
        let docked = Set(arrangement?.docked.map(\.placement.id) ?? [])
        func named(_ p: Settled) -> String { name(p) + (p.tile.map(docked.contains) == true ? "(docked)" : "") }
        return "focused=\(here) walk=\(tileWalk.map { "\($0.index):" + $0.places.map(named).joined(separator: ",") } ?? "-") cards=\(tileSwitcher != nil) order=\(tileTrail().prefix(8).map(named).joined(separator: ",")) space=\(tileTrail(space: selected).prefix(8).map(named).joined(separator: ","))"
    }

    /// ⌃⇥ held, its cards are in place this long after it's pressed:
    /// settled by then, not starting — but long enough that they're seen
    /// coming out of where they are, which says what they are.
    static let switcherSettled: TimeInterval = 0.27
    /// When they start: long enough after the press that a quick tap (let
    /// go within it) switches with nothing seen — at 30 ms most taps
    /// caught the cards; after, they fold back as they came.
    static let switcherDelay: TimeInterval = 0.12
    /// ⇥ pressed again before they showed: no quick switch wanted — they
    /// come at once, in place this long after.
    static let switcherHurried: TimeInterval = 0.06

    /// One workspace to walk: ⌘` as macOS has it, the app's next window
    /// (or, backward, its previous) — Settings, another window.
    func cycleWindows(back: Bool) {
        let windows = NSApp.orderedWindows.filter { $0.isVisible && $0.canBecomeKey && !$0.isMiniaturized }
        guard windows.count > 1, let key = NSApp.keyWindow, let i = windows.firstIndex(of: key) else { return }
        // Ordered front to back: the next is the one behind; backward, the last.
        let next = back ? windows[(i + 1) % windows.count] : windows.last!
        next.makeKeyAndOrderFront(nil)
    }

    /// Which way a space comes in: as the sidebar has them, one below the
    /// space left comes up from below (1), one above down from above (-1);
    /// by the desk's order where either row doesn't show.
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
