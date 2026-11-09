import AppKit
import ManifoldCore
import WebKit
import ManifoldSyntax
import UniformTypeIdentifiers
import PDFKit

extension MainWindowController {
    // MARK: Back and forward, by focus


    /// A move of focus takes the pen (§8.2): for the block, and the
    /// workspace it sits in. (The host writes the trail from the focus
    /// and the workspaces seen; nothing is kept here.)
    func noteTrailFocus() {
        let place = (selected, arrangement?.focused)
        guard place.0 != lastFocusPlace?.0 || place.1 != lastFocusPlace?.1 else { return }
        lastFocusPlace = place
        noteNavFocus()
        if tileWalk == nil { settleHere() }
        // Only a move made here: another attachment's, come in from the
        // host (it's the workspace's focus too), took the pens back from it
        // — two clients on one workspace trading them at every move.
        guard hosts.focusMovedHere else { return }
        if let b = focusedShown?.placement.block { hosts.own(b) }
        if let w = selected { hosts.own(w) }
    }

    /// Every host's trail, merged by time, oldest first.
    func trailSteps() -> [Step] {
        var steps: [Step] = []
        for c in hosts.all {
            let g = c.node.graph
            for i in 0..<g.stepCount { if let s = g.step(at: i) { steps.append(s) } }
        }
        return steps.sorted { $0.at < $1.at }
    }
}

extension MainWindowController {
    // MARK: The block navigation stack (§3.5)

    /// A place in the stack: a tile in its workspace, its block, and where
    /// in the block it was.
    struct NavEntry {
        var workspace: BlockID?
        var placement: PlacementID?
        var block: BlockID
        var location: NavLocation?

        func same(as e: NavEntry) -> Bool {
            guard placement == e.placement, block == e.block else { return false }
            switch (location, e.location) {
            case let (a?, b?): return a.near(b)
            default: return true
            }
        }
    }


    /// The current entry, kept up with where its view is now.
    private func refreshNavCurrent() {
        guard navStack.indices.contains(navCursor), let p = navStack[navCursor].placement, let v = views[p] else { return }
        if let loc = v.navLocation { navStack[navCursor].location = loc }
    }

    /// `refresh`: the current entry first brought up to where its view is
    /// (not after a jump, where that's where it landed, not where it was).
    private func pushNav(_ e: NavEntry, refresh: Bool = true) {
        if refresh { refreshNavCurrent() }
        if navStack.indices.contains(navCursor), navStack[navCursor].same(as: e) {
            navStack[navCursor] = e
            return
        }
        if navCursor + 1 < navStack.count { navStack.removeSubrange((navCursor + 1)...) }
        navStack.append(e)
        if navStack.count > 300 { navStack.removeFirst(navStack.count - 300) }
        navCursor = navStack.count - 1
    }

    /// Focus moved to another tile: a new place.
    private func noteNavFocus() {
        guard !navigating, let f = focusedShown else { return }
        pushNav(NavEntry(workspace: selected, placement: f.id, block: f.placement.block, location: views[f.id]?.navLocation))
    }

    /// A view about to jump within its block: where it is noted first, and
    /// where it lands once it has.
    private func noteJump(_ view: PaneContent) {
        guard !navigating else { return }
        let here = NavEntry(workspace: selected, placement: view.placement, block: view.block, location: view.navLocation)
        if navStack.indices.contains(navCursor), navStack[navCursor].placement == view.placement {
            navStack[navCursor].location = here.location
        } else {
            pushNav(here)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self, weak view] in
            guard let self, let view, !self.navigating else { return }
            self.pushNav(NavEntry(workspace: self.selected, placement: view.placement, block: view.block, location: view.navLocation), refresh: false)
        }
    }

    /// ⌃- (or the mouse's back button): the place before, in another block
    /// or this one, the pointer following.
    @objc func navigateBack(_ sender: Any?) { walkNav(-1) }
    /// ⌃⇧- (or the mouse's forward button): forward again.
    @objc func navigateForward(_ sender: Any?) { walkNav(1) }

    private func walkNav(_ direction: Int) {
        refreshNavCurrent()
        var i = navCursor + direction
        while navStack.indices.contains(i) {
            if go(toNav: navStack[i]) {
                navCursor = i
                return
            }
            // Gone (its tile and block both): passed over, and forgotten.
            navStack.remove(at: i)
            if i < navCursor { navCursor -= 1 }
            if direction < 0 { i -= 1 }
        }
        NSSound.beep()
    }

    /// Goes to an entry: its tile if it's still anywhere (its workspace
    /// shown, back from the dock, focused), else its block wherever it is;
    /// then the place in it.
    private func go(toNav e: NavEntry) -> Bool {
        navigating = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in self?.navigating = false }
        var target: PlacementID?
        if let pid = e.placement, let w = e.workspace, allWorkspaces.contains(w), let a = hosts.arrangement(w), a.placement(pid) != nil {
            land(on: pid, in: w, a)
            target = pid
        } else if hosts.block(e.block) != nil {
            goTo(e.block)
        } else {
            navigating = false
            return false
        }
        render()
        lastFocusPlace = (selected, arrangement?.focused)
        warpPointerToFocus()
        if let loc = e.location {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
                guard let self, let p = target ?? self.arrangement?.focused, let v = self.views[p] else { return }
                v.go(to: loc)
            }
        }
        return true
    }


    func watchHistoryButtons() {
        NavJumps.willJump = { [weak self] view in self?.noteJump(view) }
        // A line of a text, referred to: its anchor (§2.5) — the declaration
        // or heading there, kept as the text moves — not the line's number.
        Drags.copyLink = { [weak self] place in self?.copyLink(to: place) }
        Drags.localHost = host.host
        // A view waiting on another host says how much has come from it.
        BusyNote.link = { [weak self] h in
            guard let self, let c = self.hosts.client(h), c.isRemote else { return nil }
            return (self.hosts.label(of: h), c.bytesIn)
        }
        // Another host's file dropped in the Finder: fetched there, shown
        // going in the transfers as a folder's download is.
        Drags.fetch = { [weak self] f, url, done in
            guard let self, let c = self.hosts.client(f.host) else { return done("the host isn't attached") }
            let item = Transfers.shared.run(url.lastPathComponent, detail: "from \(self.hosts.label(of: f.host)) to \(url.deletingLastPathComponent().lastPathComponent)",
                                            symbol: "arrow.down") { progress, finished in
                Transfer.download(f.path, on: c, to: url, progress: progress, done: finished)
            } then: { error in done(error) }
            item.action = ("Show in Finder", { NSWorkspace.shared.activateFileViewerSelecting([url]) })
        }
        MarkdownStyle.placeName = { [weak self] id, anchor in self?.hosts.block(id)?.anchors?[anchor].map(Anchoring.name(of:)) }
        Drags.place = { [weak self] place, selected in self?.dragItem(place, selected: selected) }
        Drags.anchor = { [weak self] id, at, unsure in
            guard let self else { return at }
            var p = Place(block: id, at: at)
            p.unsure = unsure
            return await self.resolve(p)?.at ?? at
        }
        Drags.contents = { [weak self] id, at, done in
            guard let self else { return done(nil) }
            self.fetchContents(id, at: at, done)
        }
        Drags.resolve = { [weak self] f in self?.pathBlock(f.path, isDirectory: f.isDirectory, on: f.host)?.0 }
        Drags.opens = { [weak self] f in self?.pathOpens(f.path, isDirectory: f.isDirectory, on: f.host) ?? true }
        // (One already made is named as it is, not read again.)
        Drags.commitBlock = { [weak self] c in
            guard let client = self?.hosts.client(c.host) else { return nil }
            let subject = DiffSubject.commit(repo: c.repo, sha: c.sha)
            return client.node.blocks.first { $0.kind == .diff && $0.diff?.subject == subject }?.id ?? client.diffBlock(subject)
        }
        Drags.symbol = { [weak self] id in self?.hosts.block(id).map(Theme.symbolName(for:)) }
        ReferenceTip.whyMissing = { [weak self] id in self?.hosts.whyMissing(id) }
        Drags.keepImage = { [weak self] data, kind, note, insert in self?.keepImage(data, kind: kind, for: note, insert: insert) }
        Drags.block = { [weak self] id, mods in
            guard let self else { return nil }
            if mods.contains(.shift) { return Drags.item(self.dragThing(id)) }
            // Plain: the block, to bring where it's dropped (nothing a text
            // view would take for text to put in).
            let item = NSPasteboardItem()
            item.setString(id.description, forType: .manifoldBlock)
            return item
        }
        // ⌃- and ⌃⇧- go back and forward, ⌃⇥ and ⌃⇧⇥ walk the space's
        // tiles, ⌘` and ⇧⌘` the workspaces, here, before anything
        // else sees them — whatever has the keyboard, or nothing (a
        // workspace's row clicked, its tile not taking it, where AppKit's
        // own going round the views took ⌃⇥ before the menu).
        navKeysMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, event.window === self.window, [27, 48, 50].contains(event.keyCode) else { return event }
            let mods = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            if event.keyCode == 50 {
                guard mods == .command || mods == [.command, .shift] else { return event }
                if mods.contains(.shift) { self.switchSpaceBack(nil) } else { self.switchSpace(nil) }
                return nil
            }
            guard mods == .control || mods == [.control, .shift] else { return event }
            // ⌃- in a terminal is the terminal's (undo, to a shell or Emacs).
            if event.keyCode == 27, self.window?.firstResponder is TerminalView { return event }
            if event.keyCode == 48 {
                if mods.contains(.shift) { self.walkSpaceTilesBack(nil) } else { self.walkSpaceTiles(nil) }
            } else if mods.contains(.shift) {
                self.navigateForward(nil)
            } else {
                self.navigateBack(nil)
            }
            return nil
        }
        historyButtonsMonitor = NSEvent.addLocalMonitorForEvents(matching: .otherMouseDown) { [weak self] event in
            guard let self, (event.window ?? NSApp.keyWindow) === self.window else { return event }
            switch event.buttonNumber {
            // A page's or a folder's own history where the tile has one;
            // else the block navigation stack.
            case 3: if !NSApp.sendAction(#selector(WebView.goBack(_:)), to: nil, from: self) { self.navigateBack(nil) }; return nil
            case 4: if !NSApp.sendAction(#selector(WebView.goForward(_:)), to: nil, from: self) { self.navigateForward(nil) }; return nil
            default: return event
            }
        }
    }

    /// Debugging: the backdrop's light — at "HH:MM" today, or "now" again.
    func debugSun(_ arg: String) -> String {
        let hm = arg.split(separator: ":").compactMap { Int($0) }
        if arg == "now" { backdrop.clock = nil }
        else if hm.count == 2 { backdrop.clock = Calendar.current.date(bySettingHour: hm[0], minute: hm[1], second: 0, of: Date()) }
        let c = backdrop.cast, p = Daylight.place()
        return String(format: "at %.2f,%.2f elevation %.1f° %.0f K cast r%.3f g%.3f b%.3f", p.latitude, p.longitude, c.elevation, c.kelvin, c.red, c.green, c.blue)
    }

    /// Debugging: the block navigation stack's last places, the one at marked.
    func debugHistory() -> String {
        let first = max(0, navStack.count - 30)
        return navStack[first...].enumerated().map { k, e in
            let i = first + k
            let loc = e.location.map { " @\($0)" } ?? ""
            return "\(i == navCursor ? ">" : " ")\(i) \(hosts.block(e.block)?.displayTitle ?? "?")\(loc)"
        }.joined(separator: "\n")
    }
}
