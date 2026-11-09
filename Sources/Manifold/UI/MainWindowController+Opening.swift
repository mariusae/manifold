import AppKit
import ManifoldCore
import WebKit
import ManifoldSyntax
import UniformTypeIdentifiers
import PDFKit

extension MainWindowController {
    // MARK: Pins (§3.6)

    /// A workspace's pinned blocks, in the order pinned: each a strong link
    /// from the workspace, which keeps it while the workspace is kept.
    func pins(of workspace: BlockID) -> [Edge] {
        let edges = hosts.client(of: workspace)?.node.graph.edges(from: workspace, kind: .link(.pinned)).filter(\.isLive) ?? []
        var seen = Set<BlockID>()
        return edges.sorted { $0.at < $1.at }.filter { seen.insert($0.to).inserted }
    }

    func isPinned(_ block: BlockID, in workspace: BlockID) -> Bool { pins(of: workspace).contains { $0.to == block } }

    /// Pinned in a workspace, or let go of there.
    func setPinned(_ block: BlockID, in workspace: BlockID, _ on: Bool) {
        if on {
            guard !isPinned(block, in: workspace) else { return }
            hosts.link(from: workspace, to: block, kind: .pinned, context: "pinned")
        } else {
            for e in pins(of: workspace) where e.to == block { hosts.propose(.unlink(e.id)) }
        }
        refreshOrganization(now: true)
    }

    /// A pinned block with no tile, chosen in the sidebar: its workspace
    /// shown, the block in a tile there again.
    func recallPinned(_ block: BlockID, in workspace: BlockID) {
        guard let b = hosts.block(block) else { return }
        if let a = hosts.arrangement(workspace), let t = a.placements(of: block).first { return land(on: t.id, in: workspace, a) }
        if selected != workspace { hosts.select(workspace) }
        show(block, lens: b.defaultLens, .here, context: "pinned")
    }

    /// Pin in Workspace: a tile's block (the menu's, from a block's own
    /// menu; else the focused one's) pinned in the workspace shown, or let go of.
    @objc func togglePinInWorkspace(_ sender: Any?) {
        guard let id = selected, let block = pinTarget(sender) else { return NSSound.beep() }
        setPinned(block, in: id, !isPinned(block, in: id))
    }

    func pinTarget(_ sender: Any?) -> BlockID? {
        if let p = (sender as? NSMenuItem)?.representedObject as? PlacementID, let t = arrangement?.placement(p) { return t.block }
        return focusedShown?.placement.block
    }

    /// **Bring here** (§3.1): where a tile is made for a block. Nothing
    /// else makes one.
    enum Where {
        /// Into the active column, as acme places a window: below its
        /// biggest tile, taking the lower half.
        case here
        /// Into a column, the same way.
        case inColumn(Int)
        /// A new column to the right of the focused one.
        case beside
        /// A new column at an index.
        case inNewColumn(Int)
        /// Below the tile that opened it, taking its lower half; the two
        /// are linked.
        case besideOpener(PlacementID)
        /// Over the tile that opened it (⌥ with the click): the tile goes
        /// behind it, as ⌥-drag stacks; the two are linked.
        case over(PlacementID)

        /// Beside the tile that opened it, if one did; else here.
        static func besideOrHere(_ opener: PlacementID?) -> Where { opener.map { .besideOpener($0) } ?? .here }

        /// Where the one rule puts what `opener` opened: beside it (⌘),
        /// over it (⌥), else here.
        static func by(_ d: Disposition, from opener: PlacementID?) -> Where {
            guard let opener else { return .here }
            switch d {
            case .beside: return .besideOpener(opener)
            case .over: return .over(opener)
            case .goTo, .system: return .here
            }
        }
    }

    /// `besideOpener` when there is an opener, else `here`.
    /// Where what a click opens goes: beside the tile clicked in — or,
    /// with ⌥ held (`over`, else read off the click), over it.
    func opener(_ placement: PlacementID?, over: Bool? = nil) -> Where {
        guard let placement else { return .here }
        return (over ?? Self.clickModifiers?.contains(.option) ?? false) ? .over(placement) : .besideOpener(placement)
    }

    /// The one rule for opening anything (DESIGN §12) — a link, a capsule,
    /// a row, a hit: plain goes to it, ⌘ opens it beside, ⌥ (⌥⌘) over,
    /// ⇧⌘ in the system's app.
    enum Disposition {
        case goTo, beside, over, system

        init(_ flags: NSEvent.ModifierFlags) {
            if flags.isSuperset(of: [.command, .shift]) { self = .system }
            else if flags.contains(.option) { self = .over }
            else if flags.contains(.command) { self = .beside }
            else { self = .goTo }
        }
    }

    /// What the event in hand says: a click's modifiers, or ↩'s (⌘↩
    /// beside, ⌥↩ over); nil for anything else — a menu's key.
    static var disposition: Disposition? {
        if let flags = clickModifiers { return Disposition(flags) }
        guard let e = NSApp.currentEvent, e.type == .keyDown, e.isReturn else { return nil }
        return Disposition(e.modifierFlags)
    }

    /// Whether a tile shows the block, in any space.
    func isPlaced(_ block: BlockID) -> Bool {
        allWorkspaces.contains { hosts.arrangement($0)?.placements(of: block).isEmpty == false }
    }

    /// A web block a tile shows at the address, in any space: one of this
    /// Mac's, or of another host's loaded through it or not as asked.
    func placedPage(_ url: URL, on h: HostID? = nil, viaHost: Bool = false) -> BlockID? {
        let h = h ?? host.host
        for arr in allWorkspaces {
            guard let a = hosts.arrangement(arr) else { continue }
            for t in a.placements where t.block.host == h {
                if let w = hosts.block(t.block)?.web, w.url == url.absoluteString, w.viaHost == viaHost { return t.block }
            }
        }
        return nil
    }

    /// A block opened from a tile (or from nowhere) as `d` says: gone to
    /// where a tile shows it, in any space — else beside the tile; beside;
    /// over; to the system's app. A space is gone to whatever's held.
    func follow(_ block: BlockID, lens: Lens? = nil, from placement: PlacementID?, _ d: Disposition,
                kind: LinkKind = .opened, context: String? = nil) {
        guard let b = hosts.block(block) else { return sayMissing(block) }
        if b.kind == .arrangement { return d == .system ? NSSound.beep() : goTo(block) }
        let lens = lens ?? b.defaultLens
        switch d {
        case .system:
            openInSystem(block)
        case .over:
            show(block, lens: lens, placement.map { .over($0) } ?? .here, kind: kind, context: context)
        case .goTo where isPlaced(block):
            if let placement { linkFollowed(from: placement, to: block, kind: kind, context: context) }
            goTo(block, near: placement)
        case .goTo, .beside:
            show(block, lens: lens, .besideOrHere(placement), kind: kind, context: context)
        }
    }

    /// A terminal scrolled to one of its commands, once its tile is up and
    /// it has found the command's row (a moment, for a tile just made).
    /// A place in a block, once its tile is up: a line (in a preview, the
    /// line's place on the page), a PDF's page.
    /// `attempt` until it says it's done — every `every` seconds, at most
    /// `tries` times more: for what comes a moment after it's asked for (a
    /// tile just made, a PDF's document, a terminal's command).
    func retry(_ tries: Int = 20, every: TimeInterval = 0.15, _ attempt: @escaping () -> Bool) {
        guard !attempt(), tries > 0 else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + every) { [weak self] in self?.retry(tries - 1, every: every, attempt) }
    }

    /// A tile showing a block on screen now (not hidden), as a kind of view.
    func shownView<T>(of block: BlockID, as: T.Type = PaneContent.self) -> T? {
        content.views.lazy.filter { $0.block == block && !$0.isHiddenOrHasHiddenAncestor }.compactMap { $0 as? T }.first
    }

    /// A place in a block, gone to in its tile once it's shown.
    func goToPlace(_ place: NavLocation, in block: BlockID) {
        retry { [weak self] in
            guard let self, let v = self.shownView(of: block) else { return false }
            if case let .line(n) = place, let m = v as? MarkdownView { m.reveal(line: n); return true }
            // A PDF's document comes a moment after its tile.
            if case .page = place, let m = v as? MediaView, m.navLocation == nil { return false }
            v.go(to: place)
            return true
        }
    }

    /// A terminal's command, gone to once its tile's shown.
    func goToCommand(_ id: Int, in block: BlockID) {
        retry { [weak self] in self?.shownView(of: block, as: TerminalView.self)?.go(toCommand: id) == true }
    }

    /// Go to a block from a click: where it is — or, with ⌥ held, over
    /// the tile clicked in.
    func arrive(_ block: BlockID, from placement: PlacementID?, over: Bool? = nil) {
        if over ?? Self.clickModifiers?.contains(.option) ?? false, let placement, let b = hosts.block(block), b.kind != .arrangement {
            show(block, lens: b.defaultLens, .over(placement), context: "followed")
        } else {
            goTo(block)
        }
    }

    /// A block's link followed from a tile (a terminal's, an output's, a
    /// page's): the tile's block linked to it, unless they're linked already
    /// (a note's mention of it).
    func linkFollowed(from placement: PlacementID?, to block: BlockID, kind: LinkKind = .opened, context: String? = nil) {
        guard let from = placement.flatMap({ shown($0)?.placement.block }), from != block else { return }
        let linked = hosts.all.contains { $0.node.graph.edges(from: from).contains { $0.to == block && $0.isLive && $0.kind != .placed } }
        if !linked { hosts.link(from: from, to: block, kind: kind, context: context ?? "followed") }
    }

    /// A tile over another (⌥-drag, ⌥-click): in its place and room, the
    /// other docked under it (back when it's taken off), and focused.
    func cover(_ tile: PlacementID, over target: PlacementID) {
        guard let a = arrangement, tile != target, a.locate(target) != nil else { return }
        var events = a.replacing(target, with: tile)
        if a.full == target { events.append(.full(tile)) }
        appendToSelected(events)
        warpPointerToFocus()
    }

    /// Brings a block into the selected arrangement (or `arrangement`): a
    /// tile of it already there is focused instead.
    /// `exact`: a tile of the block through the other text lens (edited,
    /// viewed) doesn't count; one is made beside it.
    func show(_ block: BlockID, lens: Lens, _ place: Where, kind: LinkKind = .opened, context: String? = nil, in arrangement: BlockID? = nil,
              exact: Bool = false) {
        hideStateView()
        // ⌥⇧⌘ and a kind's letter: a new column, wherever its kind goes.
        var place = inNewColumn ? Where.beside : place
        inNewColumn = false
        // Beside or over the tile that asked for it: in that tile's space,
        // whichever is shown now (an answer come after you've gone on to
        // another space stays where it was asked for).
        let opener: PlacementID? = switch place { case .besideOpener(let p), .over(let p): p; default: nil }
        let home = opener.flatMap(spaceHolding)
        if let home, home != selected, case .over(let p) = place { place = .besideOpener(p) }
        let id = arrangement ?? home ?? arrangementForPlacing()
        guard let a = hosts.arrangement(id) else { return }
        let fresh = { ULID.make() }
        let events: [Event]
        switch place {
        case .here:
            events = a.bringing(block, lens: lens, inColumn: a.focusedColumn ?? a.columns.count, newPlacement: fresh)
        case .inColumn(let c):
            events = a.bringing(block, lens: lens, inColumn: c, newPlacement: fresh)
        case .beside:
            events = a.bringing(block, lens: lens, inNewColumnAt: (a.focusedColumn ?? a.columns.count - 1) + 1, newPlacement: fresh)
        case .inNewColumn(let i):
            events = a.bringing(block, lens: lens, inNewColumnAt: i, newPlacement: fresh)
        case .besideOpener(let p):
            guard let c = a.columnIndex(of: p), let from = a.placement(p)?.block else {
                return show(block, lens: lens, .here, kind: kind, context: context, in: id)
            }
            events = a.bringing(block, lens: lens, inColumn: c, below: p, exact: exact, newPlacement: fresh)
            hosts.link(from: from, to: block, kind: kind, context: context)
        case .over(let p):
            // A tile of the block already here moves over the opener (as
            // ⌥-drag would take it there); else one is made over it.
            if let t = a.tile(of: block, lens: lens) {
                if t.id != p, let from = a.placement(p)?.block {
                    cover(t.id, over: p)
                    hosts.link(from: from, to: block, kind: kind, context: context)
                }
            } else {
                showOver(block, lens: lens, over: p, kind: kind, context: context)
            }
            return
        }
        // A tile of the block already there, collapsed to its bar: grown.
        hosts.append(showingSome(events, in: a), to: .block(id))
        // The pointer follows to what's shown (§3.1), as after a go-to.
        if id == selected { warpPointerToFocus() }
    }

    /// A block **over** a tile (§3.1): placed where the tile is, with the
    /// tile docked under it, so it takes the tile's room until it is
    /// taken off (⌘W), when the tile comes back — `$EDITOR` over the
    /// terminal that ran it, a preview over its editor. A tile of the
    /// block already there is focused instead, unless `again`: then the
    /// block gets a second tile, over the opener (an `$EDITOR` that must
    /// end when its own tile is taken off).
    @discardableResult
    func showOver(_ block: BlockID, lens: Lens, over opener: PlacementID, again: Bool = false, stack: Bool = false, kind: LinkKind = .opened, context: String? = nil) -> PlacementID? {
        hideStateView()
        guard let a = arrangement, let (c, i) = a.locate(opener), let from = a.placement(opener)?.block else {
            show(block, lens: lens, .here, kind: kind, context: context)
            return arrangement?.tile(of: block, lens: lens)?.id
        }
        if !again, let t = a.tile(of: block, lens: lens) {
            // Already here: gone to, as anything already here is.
            arrive(atTile: t.id)
            return t.id
        }
        let p = Placement(block: block, lens: lens)
        if stack {
            stacked.insert(opener)
            stackTops[p.id] = opener
        }
        var events: [Event] = [.place(p, column: c, at: i + 1), .dock(opener, heir: p.id), .focus(p.id)]
        // Over a maximized tile, it's the maximized one now.
        if a.full == opener { events.append(.full(p.id)) }
        appendToSelected(events)
        if from != block { hosts.link(from: from, to: block, kind: kind, context: context) }
        warpPointerToFocus()
        return p.id
    }

    /// A tile's block replaced in place — a listing gone into a folder, a
    /// preview gone to another page: the same tile, as a browser's window
    /// is; Go Back comes back along the trail. Maximized, it stays so.
    func replace(_ placement: PlacementID, with block: BlockID, lens: Lens, as id: PlacementID? = nil) {
        guard let a = arrangement, let (c, i) = a.locate(placement) else { return }
        let p = id.map { Placement(id: $0, block: block, lens: lens) } ?? Placement(block: block, lens: lens)
        // The column's heights as they were, the new tile in the old one's
        // place: the remove and the place in between hand room about
        // (to the next tile, from the one above), and the tile would
        // otherwise come back a different size, its neighbours moved.
        var heights: [PlacementID: Double] = [:]
        for t in a.columns[c] { heights[t.id == placement ? p.id : t.id] = a.height(of: t.id) }
        appendToSelected([.remove(placement), .place(p, column: c, at: i), .heights(heights), .focus(p.id)]
                         + (a.full == placement ? [.full(p.id)] : []))
    }

    /// A tile gone on to another block in its place — a listing into a
    /// folder, a preview to another page — what it showed kept on its
    /// trail, to come back to (⌘[).
    func goOn(_ placement: PlacementID, from block: BlockID, to next: BlockID, lens: Lens) {
        let p = Placement(block: next, lens: lens)
        var h = trails.removeValue(forKey: placement) ?? (back: [], forward: [])
        h.back.append(block)
        h.forward = []
        trails[p.id] = h
        replace(placement, with: next, lens: lens, as: p.id)
    }

    /// ⌘[ (-1) or ⌘] (1) in a tile that goes on in its place: along its
    /// trail; false at either end.
    func walkTrail(_ placement: PlacementID, of block: BlockID, lens: Lens, _ direction: Int) -> Bool {
        guard var h = trails[placement] else { return false }
        let to: BlockID
        if direction < 0 {
            guard let b = h.back.popLast() else { return false }
            h.forward.append(block)
            to = b
        } else {
            guard let f = h.forward.popLast() else { return false }
            h.back.append(block)
            to = f
        }
        guard hosts.block(to) != nil else { return false }
        let next = Placement(block: to, lens: lens)
        trails.removeValue(forKey: placement)
        trails[next.id] = h
        replace(placement, with: to, lens: lens, as: next.id)
        return true
    }

    /// Opens a file to edit: from a terminal, beside it; else here.
    func edit(_ path: String) {
        let on = focusedHost
        guard on != host.host || Self.isEditable(path) else {
            NSWorkspace.shared.open(URL(fileURLWithPath: path))
            return
        }
        let block = hosts.textBlock(for: path, on: on)
        show(block, lens: .editor, focusedShown?.lens == .terminal ? opener(focusedShown?.id) : .here, context: "edit \(path.lastPathComponent)")
    }

    /// Find in Files…: a search block on the focused block's host, under
    /// where it is (a terminal's directory, a file's folder) — its tile's
    /// path field to change, and Expand to Project to widen it to the
    /// repository — starting from the editor's selection; placed beside
    /// what's focused.
    @objc func findInFiles(_ sender: Any?) {
        let on = focusedHost
        let root = focusedCwd ?? NSHomeDirectory()
        var text = ""
        if let tv = window?.firstResponder as? TextView {
            let selected = tv.selectedText
            if !selected.isEmpty, !selected.contains("\n") { text = selected }
        }
        guard let client = hosts.client(on) else { return }
        let block = client.newSearch(SearchQuery(text: text, root: root))
        // Linked from where it was asked, by what was looked for.
        show(block, lens: .search, .besideOrHere(focusedShown?.id), context: text.isEmpty ? "find in files" : "find “\(text)”")
    }

    /// Find in This Folder: a search under a folder (a folder tile's, an
    /// entry's), beside it, its words to type.
    func findInFolder(_ path: String, on h: HostID, from placement: PlacementID?) {
        guard let client = hosts.client(h) else { return NSSound.beep() }
        let block = client.newSearch(SearchQuery(text: "", root: path))
        show(block, lens: .search, .besideOrHere(placement), context: "find in \(path.lastPathComponent)")
    }

    /// New Agent: a terminal running the agent command (the settings'),
    /// where the focused block is, beside it.
    @objc func newAgent(_ sender: Any?) { launchAgent(desk.settings.agentCommand) }

    /// An agent block running `command`, where the focused block is, on
    /// its host, beside it.
    func launchAgent(_ command: String) {
        guard let client = hosts.client(focusedHost) else { return }
        show(client.newAgent(cwd: focusedCwd, command: command), lens: .agent, .here)
    }

    /// Launch Agent Here: one item for each known agent the focused
    /// block's host has (it's asked to look again, for next time).
    func agentMenuItems() -> [NSMenuItem] {
        let on = focusedHost
        guard let client = hosts.client(on) else { return [] }
        if client.isConnected { client.propose(.indexAgents) }
        let agents = AgentCatalog.agents(among: client.desk.agents)
        guard !agents.isEmpty else {
            let none = NSMenuItem(title: "No Agents Found on \(hosts.label(of: on))", action: nil, keyEquivalent: "")
            none.isEnabled = false
            return [none]
        }
        return agents.map { a in ClosureMenuItem(a.name, symbol: "sparkle") { [weak self] in self?.launchAgent(a.command) } }
    }

    /// Processes: the focused block's host's process list, beside it.
    @objc func showProcesses(_ sender: Any?) {
        guard let client = hosts.client(focusedHost) else { return }
        show(client.processBlock(), lens: .process, .here)
    }

    /// Git for This Project: the git block for the repository the focused
    /// block is in, placed beside it.
    @objc func showGit(_ sender: Any?) {
        let on = focusedHost
        guard let client = hosts.client(on) else { return }
        let path = focusedCwd ?? NSHomeDirectory()
        var shown: BlockID?
        // In a project (§2.6): its own changes and commits.
        let block = (client.project(holding: path).map { p in { client.projectGitBlock(for: p, done: $0) } } ?? { client.gitBlock(for: path, done: $0) }) { [weak self] error in
            // The host couldn't make it (no repository there): its tile,
            // waiting for a block that won't come, goes, and says why.
            guard let self, let error, let block = shown else { return }
            if let a = self.arrangement, let t = a.tile(of: block, lens: .git) { self.appendToSelected([.remove(t.id)]) }
            self.notify("No source control here", error)
        }
        shown = block
        show(block, lens: .git, .here)
    }

    /// Interactive Smartlog (⌥⌘L): Sapling's, for the repository the focused
    /// block is in, as a block of its own (§7.6) — the one there is, else
    /// a new one; if there's no Sapling there, its tile says why.
    @objc func showSmartlog(_ sender: Any?) {
        let on = focusedHost
        guard let client = hosts.client(on) else { return NSSound.beep() }
        let path = focusedShown?.path ?? focusedCwd ?? NSHomeDirectory()
        let block = client.smartlogBlock(for: path)
        show(block, lens: .smartlog, .besideOrHere(focusedShown?.id), context: "smartlog")
    }

    /// Compare with Last Commit: the focused file against HEAD, beside it.
    @objc func compareWithHead(_ sender: Any?) {
        guard let f = focusedShown, let path = f.path, f.lens == .editor || f.lens == .preview,
              let client = hosts.client(of: f.placement.block) else { return }
        let block = client.diffBlock(.sides(old: DiffSide(path: path, revision: "HEAD"), new: DiffSide(path: path)))
        show(block, lens: .diff, .besideOpener(f.id), context: "Compare with Last Commit")
    }

    /// Opens a file at a place (line and column from 1) beside the
    /// placement that opened it, on the host the placement's block is on.
    /// Opens a file at a place (line and column from 1), as the click or
    /// ↩ says (`as`, else read off the event; plain goes to it), from the
    /// placement that opened it, on the host the placement's block is on.
    func open(path: String, line: Int, column: Int?, on: HostID, from: PlacementID?, as d: Disposition? = nil,
              kind: LinkKind = .opened, context: String? = nil) {
        let d = d ?? Self.disposition ?? .goTo
        if d != .system { pendingJump = (path, line, column) }
        let block = hosts.textBlock(for: path, on: on)
        follow(block, lens: Lens.default(for: .text, path: path), from: from, d, kind: kind, context: context ?? "\(path.lastPathComponent):\(line)")
        warpPointerToFocus()
    }

    func openDirectory(_ path: String, from: PlacementID?, as d: Disposition? = nil, context: String? = nil) {
        let on = from.flatMap { shown($0)?.placement.block.host } ?? focusedHost
        let block = hosts.directoryBlock(for: path, on: on)
        follow(block, lens: .directory, from: from, d ?? Self.disposition ?? .goTo, context: context)
    }

    /// Whether a terminal tile is an agent's: its turns are its outline
    /// (ticks), not a shell's commands (dots).
    func isAgent(_ p: Placement) -> Bool {
        guard let b = hosts.block(p.block) else { return p.lens == .agent }
        return p.lens == .agent || b.kind == .agent || b.agent != nil || b.terminal?.turns?.isEmpty == false
    }

    /// A web page kept as a file, by its name.
    static func isHTML(_ path: String) -> Bool {
        ["html", "htm", "xhtml"].contains(path.pathExtension.lowercased())
    }

    /// An image or a PDF, by its name.
    static func mediaKind(_ path: String) -> BlockKind? {
        switch path.pathExtension.lowercased() {
        case "png", "jpg", "jpeg", "gif", "heic", "heif", "tif", "tiff", "bmp", "webp", "svg", "icns": return .image
        case "pdf": return .pdf
        default: return nil
        }
    }

    /// Text, and not too big to edit.
    static func isEditable(_ path: String) -> Bool {
        let size = (try? FileManager.default.attributesOfItem(atPath: path))?[.size] as? Int ?? 0
        return size < 32 << 20 && TextFile.isText(path)
    }

    /// ⌥⌘P: the focused text block the other way round, in place — its
    /// preview as an editor, its editor as a preview (Markdown only).
    /// Editor and preview share the block, so an edit shows live.
    /// ⌘P: the workspace as a hierarchy, as Prism's Move to Heading is —
    /// its tiles by column, and the headings of the text in them, set in
    /// under their tile; those whose words have every word of the query.
    /// ↩ goes to a tile, or to a heading in its editor or preview.
    /// ⇧⌘P: the focused tile's outline — a text's headings or symbols, a
    /// terminal's commands, a PDF's contents, a diff's files — filtered
    /// in its sidebar; again, the sidebar's filter left.
    @objc func searchOutline(_ sender: Any?) {
        guard let f = arrangement?.focused else { return NSSound.beep() }
        searchOutline(of: f)
    }

    /// ⇧⌘P: the tile's own outline, its sidebar (shown if it wasn't, put
    /// away again after), filtered by what's typed in the field at its
    /// top (kept from the last time), the pointer there — ↩ goes to the
    /// entry chosen, Escape clears then leaves, ⇧⌘P again leaves. A tile
    /// with an outline but no sidebar: ⌘P, on its outline.
    func searchOutline(of placement: PlacementID) {
        // Already there: ⇧⌘P again leaves it.
        if let view = views[placement], let s = view.sidebarView ?? Self.tileSidebar(in: view), s.isSearching {
            return s.endSearch()
        }
        if let view = views[placement], view.hasSidebar {
            let wasShown = view.sidebarShown
            if !wasShown {
                view.toggleSidebar()
                content.sidebarChanged(placement)
            }
            view.layoutSubtreeIfNeeded()
            if let sidebar = view.sidebarView ?? Self.tileSidebar(in: view) {
                // After the focus settles (a tile focused takes the keyboard).
                DispatchQueue.main.async { [weak self, weak view, weak sidebar] in
                    guard let self, let sidebar else { return }
                    sidebar.beginSearch { [weak self, weak view] in
                        guard let self, let view else { return }
                        if !wasShown, view.sidebarShown {
                            view.toggleSidebar()
                            self.content.sidebarChanged(placement)
                        }
                        self.focus(placement)
                    }
                    if let window = self.window {
                        let r = window.convertToScreen(sidebar.searchFrame)
                        Pointer.warp(to: NSPoint(x: r.minX + 24, y: r.midY))
                    }
                }
                return
            }
        }
        // No sidebar: ⌘P, on this tile's outline.
        focus(placement)
        goToTile(nil)
    }

    /// A tile's outline as rows for ⌘P: nested as it is while all of it
    /// shows; found (by the space's index), flat.
    private func tileOutlineItems(_ placement: PlacementID, _ view: PaneContent, _ outline: Outline, _ query: String) -> [FinderItem] {
        guard let index = syncOutlineIndex() else { return [] }
        let rows = index.rows(of: placement)
        // (Not by its title: the tile's own outline is found by its own words.)
        var found = query.isEmpty ? Array(rows.indices) : index.find(query, in: [placement], titles: false).first?.items ?? []
        let words = !query.trimmingCharacters(in: .whitespaces).isEmpty
        // Asked, ranked as the space's are (the item named exactly first).
        if words {
            let score = Dictionary(found.filter { rows.indices.contains($0) }.map { ($0, OutlineIndex<PlacementID, Outline.Item>.score(rows[$0].title, query: query)) },
                                   uniquingKeysWith: { a, _ in a })
            found.sort { x, y in
                let a = score[x] ?? 0, b = score[y] ?? 0
                if a != b { return a > b }
                let la = rows.indices.contains(x) ? rows[x].title.count : 0, lb = rows.indices.contains(y) ? rows[y].title.count : 0
                return la != lb ? la < lb : x < y
            }
        }
        return found.compactMap { i -> FinderItem? in
            guard rows.indices.contains(i) else { return nil }
            let item = rows[i]
            return FinderItem(symbol: view is TerminalView ? "chevron.right" : item.code ? "curlybraces" : "number", title: item.title, detail: item.detail, note: "",
                              level: words ? 0 : item.level, run: { outline.pick(i) })
        }
    }

    /// A tile's own sidebar, wherever its view keeps it.
    static func tileSidebar(in view: NSView) -> TileSidebar? {
        (view as? TileSidebar) ?? view.subviews.lazy.compactMap { tileSidebar(in: $0) }.first
    }

    /// Debugging: the first process tile.
    /// Debugging: a process tile, the one in view if there is one.
    var debugProcessView: ProcessView? {
        let all = views.values.compactMap { $0 as? ProcessView }
        return all.first { $0.window != nil && !$0.isHiddenOrHasHiddenAncestor } ?? all.first
    }

    /// Debugging: ⇧⌘P's field in the focused tile's sidebar, typed into or keyed.
    func debugOutlineSearch(_ what: String) -> String {
        guard let f = arrangement?.focused, let v = views[f] else { return "nothing focused" }
        if what == "open" { searchOutline(of: f); return "opened" }
        return (v.sidebarView ?? Self.tileSidebar(in: v))?.debugSearch(what) ?? "no sidebar"
    }

    @objc func goToTile(_ sender: Any?) {
        // Open already (the tile's or the space's): the other.
        if finder.opener == .outline, finder.widens { return finder.widen() }
        guard let a = arrangement, !a.isEmpty else { return NSSound.beep() }
        // It begins where you are: the focused tile, and in a text, the
        // heading the caret is under, or the one at the top of a preview.
        // What runs in each terminal is asked for afresh (the process
        // lists are kept only while shown), and the items are made again
        // for each query, so a program just started is found by its name.
        for c in hosts.all where c.isConnected {
            let pb = c.node.blocks.first { $0.kind == .process }?.id ?? BlockID(host: c.host)
            hosts.propose(.processes(block: pb))
        }
        // The focused tile's own outline first, if it has one; ⇥ widens it
        // to the whole space's (and back).
        let tile: Finder.OutlineScope? = a.focused.flatMap { f in self.views[f].map { (f, $0) } }.flatMap { f, view in
            guard let outline = view.outline, !outline.items.isEmpty else { return nil }
            return Finder.OutlineScope(provider: { query in self.tileOutlineItems(f, view, outline, query) }, start: outline.current,
                                       placeholder: "Go to in this tile…", hint: "This tile", reach: .tile)
        }
        // Each query looked up in the space's index (kept as outlines
        // change), not the outlines gone through again.
        let space = Finder.OutlineScope(provider: { [weak self] query in
            guard let self, let a = self.arrangement else { return [] }
            return self.spaceOutlineRows(a, query: query)
        }, start: spaceOutlineStart(a), placeholder: "Go to…", hint: "The space", reach: .space)
        if let tile { finder.showOutline(tile, wider: space, over: window) } else { finder.showOutline(space, over: window) }
    }

    /// The outline, and the row to begin at: the focused tile's, or under
    /// it the heading at `currentLine` (a line from 1 in its editor; or,
    /// negative, minus one more than the index of the heading at the top
    /// of its preview).
    /// What runs in each terminal (the process trees under the shells,
    /// §7.5), so a terminal is found by its program — "claude" — too.
    func runningPrograms() -> [BlockID: [String]] {
        var running: [BlockID: [String]] = [:]
        for pb in hosts.blocks where pb.kind == .process {
            var shells = Set<BlockID>()
            for e in pb.processes?.entries ?? [] {
                guard let under = e.block else { continue }
                // The first process under a block is its shell; the rest run in it.
                guard shells.contains(under) else { shells.insert(under); continue }
                let name = (e.path ?? e.command.split(separator: " ").first.map(String.init) ?? "").lastPathComponent
                if !name.isEmpty, !(running[under]?.contains(name) ?? false) { running[under, default: []].append(name) }
            }
        }
        return running
    }
}
