import AppKit
import ManifoldCore
import WebKit
import ManifoldSyntax
import UniformTypeIdentifiers
import PDFKit

extension MainWindowController {
    // MARK: State views (§3.6)


    /// The surface shows a status group's blocks themselves, live.
    /// ⌘': every block in the workspace at once, as Mission Control shows
    /// windows; again, or ⎋, back to the workspace.
    @objc func showWorkspaceOverview(_ sender: Any?) {
        guard let id = selected, hosts.arrangement(id) != nil else { return NSSound.beep() }
        if stateWorkspace == id { return hideStateView() }
        stateShown = .space(id)
        stateMode = .overview
        stateModeChosen = Self.overviewMode
        presentStateView()
    }


    func showStateView(_ group: StatusGroup) {
        stateShown = .group(group)
        presentStateView()
    }

    /// Overview's mode as last chosen, kept for the next time (and the
    /// next launch): it opens as it was left.
    private static var overviewMode: StateView.Mode? {
        get { UserDefaults.standard.object(forKey: "OverviewMode").flatMap { ($0 as? Int).flatMap(StateView.Mode.init(rawValue:)) } }
        set { UserDefaults.standard.set(newValue?.rawValue, forKey: "OverviewMode") }
    }

    /// Window ▸ Agents (⌃⌘A): Overview, filtered to every agent on every
    /// host — those that need you first — each saying what it's on, for
    /// how long, and what it has changed; clicked, gone to. Again, or ⎋,
    /// back.
    @objc func showAgents(_ sender: Any?) {
        if stateAgents { return hideStateView() }
        stateShown = .agents
        stateMode = .overview
        stateModeChosen = Self.overviewMode
        presentStateView()
    }

    /// The agents: agent blocks, and terminals with an agent at work in
    /// them (or that had turns), by how much they want you.
    func agentBlocks() -> [Block] {
        let all = hosts.blocks.filter { $0.kind == .agent || ($0.kind == .terminal && ($0.agent != nil || $0.terminal?.turns?.isEmpty == false)) }
        func rank(_ b: Block) -> Int {
            switch StatusGlyph.look(of: b) {
            case .needsYou?: 0
            case .working?: 1
            case .failed?: 2
            case .done?: 3
            default: b.terminal?.pid == nil ? 5 : 4
            }
        }
        return all.sorted { (rank($0), -($0.statusRecord?.at.wall ?? 0)) < (rank($1), -($1.statusRecord?.at.wall ?? 0)) }
    }

    /// What an agent's bar says: its name, what it's on (its last turn's
    /// ask), how long that has run or took, and how many files it changed.
    func agentCaption(_ b: Block) -> String {
        var parts = [b.displayTitle]
        if let t = b.terminal?.turns?.last {
            parts.append("“" + String((t.prompt.split(whereSeparator: \.isNewline).first ?? "").prefix(60)) + "”")
            let secs = Double((t.ended?.wall ?? Int64(Date().timeIntervalSince1970 * 1000)) - t.began.wall) / 1000
            parts.append((t.ended == nil ? "for " : "took ") + Notifier.duration(Int64(secs * 1000)))
            if let n = t.files?.count, n > 0 { parts.append("\(n) file\(n == 1 ? "" : "s")") }
        } else if let m = b.statusRecord?.msg {
            parts.append(m)
        }
        return parts.joined(separator: " · ")
    }

    private func presentStateView() {
        // Opening on the space shown: its tiles, as they are, to be seen
        // going to their places in it.
        let fromTiles = stateView == nil && !content.isHidden ? partsInRoot(content.tileParts(), from: content) : [:]
        if stateView == nil {
            let v = StateView()
            v.onOpen = { [weak self] b, mods in
                guard let self else { return }
                self.follow(b, from: self.arrangement?.focused, Disposition(mods), context: "from Overview")
            }
            v.onLeave = { [weak self] in self?.hideStateView() }
            v.onModeChanged = { [weak self] m in
                if self?.stateGroup == nil { Self.overviewMode = m }
                self?.stateModeChosen = m
                if m != .summaries { self?.stateMode = m }
                self?.render()
            }
            // Overview's filter: this space's blocks, or every agent's.
            v.onFilterChanged = { [weak self] i in
                guard let self else { return }
                self.stateShown = i == 1 ? .agents : self.selected.map { .space($0) }
                self.stateMembers = []
                self.render()
            }
            root.addSubview(v, positioned: .above, relativeTo: stage)
            stateView = v
        }
        stateMembers = []
        content.isHidden = true
        layoutViews()
        render()
        window?.makeFirstResponder(stateView)
        if let v = stateView, !fromTiles.isEmpty { flyIn(v, from: fromTiles) }
    }

    func hideStateView() {
        guard let v = stateView else { return }
        // Its cards, as they are, to be seen going back to their tiles.
        let fromCards = partsInRoot(v.cellParts(), from: v)
        v.clear()
        v.removeFromSuperview()
        stateView = nil
        stateShown = nil
        stateModeChosen = nil
        content.isHidden = false
        render()
        if !fromCards.isEmpty { flyOut(from: fromCards) }
    }
}

extension MainWindowController {
    // MARK: Overview, as Mission Control does

    /// Only fading in (with Reduce motion).
    func fadeIn(_ v: NSView) {
        guard let l = v.layer else { return }
        let a = CABasicAnimation(keyPath: "opacity")
        a.fromValue = 0
        a.toValue = 1
        a.duration = Motion.base
        l.add(a, forKey: "fadeIn")
    }

    func partsInRoot<K>(_ parts: [K: GridView.Pictured], from view: NSView) -> [K: GridView.Pictured] {
        parts.mapValues { p in GridView.Pictured(parts: p.parts.map { (root.convert($0.0, from: view), $0.1) }, ground: p.ground) }
    }

    /// Overview opening, as Mission Control does: each tile in the space
    /// becomes its card where the card is — its outline going there, what
    /// it shows scaled to its width, the card coming in on the way; the
    /// rest of Overview fades in.
    private func flyIn(_ v: StateView, from tiles: [BlockID: GridView.Pictured]) {
        guard !Motion.reduced, let host = root.layer else { return fadeIn(v) }
        var items: [GridView.Morph] = []
        var flown: [BlockID] = []
        for (block, card) in partsInRoot(v.cellParts(), from: v) {
            guard let tile = tiles[block] else { continue }
            items.append(GridView.Morph(from: tile.whole, to: card.whole, leaving: tile, coming: card))
            flown.append(block)
        }
        guard !items.isEmpty else { return fadeIn(v) }
        let d = Motion.spatial * 1.5
        GridView.morph(items, in: host, over: d)
        fade(v, over: d)
        for block in flown {
            for part in v.cellViews(of: block) { show(part, from: 1, over: d) }
        }
    }

    /// Overview closing: each card becomes its tile again, where the tile
    /// is (as the space has it now); the rest of the space fades in.
    private func flyOut(from cards: [BlockID: GridView.Pictured]) {
        guard !content.isHidden else { return }
        guard !Motion.reduced, let host = root.layer else { return fadeIn(content) }
        content.layoutSubtreeIfNeeded()
        let tiles = partsInRoot(content.tileParts(), from: content)
        var items: [GridView.Morph] = []
        var flown: [BlockID] = []
        for (block, card) in cards {
            guard let tile = tiles[block] else { continue }
            items.append(GridView.Morph(from: card.whole, to: tile.whole, leaving: card, coming: tile))
            flown.append(block)
        }
        guard !items.isEmpty else { return fadeIn(content) }
        let d = Motion.spatial * 1.5
        GridView.morph(items, in: host, over: d)
        fade(content, over: d)
        for block in flown {
            for part in content.tileViews(of: block) { show(part, from: 1, over: d) }
        }
    }

    /// A view faded in over a flight.
    private func fade(_ v: NSView, over d: Double) {
        guard let l = v.layer else { return }
        let a = CABasicAnimation(keyPath: "opacity")
        a.fromValue = 0
        a.toValue = 1
        a.duration = d
        a.timingFunction = Motion.appear
        l.add(a, forKey: "fadeIn")
    }

    /// A view out of sight till `from` of the way through a flight, then
    /// fading in by its end (at once, at its end).
    private func show(_ v: NSView, from: Double, over d: Double) {
        guard let l = v.layer else { return }
        let a = CAKeyframeAnimation(keyPath: "opacity")
        a.values = from >= 1 ? [0, 0] : [0, 0, 1]
        a.keyTimes = from >= 1 ? [0, 1] : [0, NSNumber(value: from), 1]
        a.duration = d
        l.add(a, forKey: "landing")
    }


    func debugStateView(mode: StateView.Mode) {
        guard let stateView else { return }
        stateView.debugChoose(mode)
    }

    /// The state view's placement ids: a block's, not an arrangement's.
    static func statePlacement(_ block: BlockID) -> PlacementID { "state:\(block)" }


    func organizationTree(_ org: Organization) -> ([OrgNode], Set<String>) {
        switch org {
        case .desk: return deskTree()
        case .files: return filesTree()
        case .closed: return closedTree()
        case .threads: return ([], []) // the timeline, not a tree
        }
    }


    /// A block's text as Search reads it — a text's, a notebook's cells,
    /// an output's, escapes taken out — made again only when it changed.
    func searchText(for b: Block) -> SearchText? {
        let key: String
        if let t = b.text { key = "t\(t.version)" }
        else if let nb = b.notebook { key = "n\(nb.runs)/\(nb.cells.count)/\(nb.cells.reduce(0) { $0 + $1.source.utf8.count + ($1.output?.utf8.count ?? 0) })" }
        else if let o = b.output { key = "o\(o.output.utf8.count)/\(o.ended != nil)" }
        else { return nil }
        if let st = searchTexts[b.id], st.key == key { return st }
        func plain(_ s: String) -> String {
            s.replacingOccurrences(of: "\u{1b}\\][^\u{07}\u{1b}]*(\u{07}|\u{1b}\\\\)", with: "", options: .regularExpression)
                .replacingOccurrences(of: "\u{1b}\\[[0-9;?]*[ -/]*[@-~]", with: "", options: .regularExpression)
        }
        let text: String
        if let t = b.text { text = t.text.string }
        else if let nb = b.notebook { text = plain(nb.cells.map { "$ " + $0.source + "\n" + ($0.output ?? "") }.joined(separator: "\n")) }
        else if let o = b.output { text = o.plain ? o.output : plain(o.output) }
        else { return nil }
        let st = SearchText(key: key, text: text)
        if searchTexts.count > 4 * max(hosts.blocks.count, 64) { searchTexts = searchTexts.filter { hosts.block($0.key) != nil } }
        searchTexts[b.id] = st
        return st
    }

    /// A text block gone to, at a line: its editor here focused there, or
    /// one brought here.
    func goToLine(_ line: Int, in block: BlockID) {
        guard let b = hosts.block(block) else { return }
        if let a = arrangement, let p = a.placements(of: block).first(where: { $0.lens == .editor }), let e = views[p.id] as? EditorView {
            arrive(atTile: p.id)
            e.select(line: line)
            return
        }
        // Shown as a page here: the page scrolled to the line.
        if let a = arrangement, let p = a.placements(of: block).first(where: { $0.lens == .preview }), let m = views[p.id] as? MarkdownView {
            arrive(atTile: p.id)
            m.reveal(line: line)
            return
        }
        pendingJump = (b.path ?? "", line, nil)
        show(block, lens: .editor, .here)
        if b.path == nil {
            // A note has no path to jump by: its editor, once made, goes there.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
                guard let self, let p = self.arrangement?.placements(of: block).first(where: { $0.lens == .editor }), let e = self.views[p.id] as? EditorView else { return }
                e.select(line: line)
            }
        }
        warpPointerToFocus()
    }

    /// What's closed and not yet collected on a host (§4): what exists
    /// and nothing reaches — the last seen first.
    func closedItems(on c: HostClient, reachable: Set<BlockID>) -> [Block] {
        let far = Stamp(wall: 0, logical: 0, host: c.host)
        // Not a diff only ever shown in a git tile's pane: never seen
        // since it was made, it was never closed.
        return c.node.blocks.filter { !reachable.contains($0.id) && $0.id.host == c.host && ($0.kind != .diff || c.node.graph.seenSinceMade($0.id)) }
            .sorted { (c.node.graph.seen($0.id) ?? far) > (c.node.graph.seen($1.id) ?? far) }
    }

    /// Rows of blocks and workspaces under their hosts (when there is
    /// more than one), each brought back by a click.
    func hostedRows(_ make: (HostClient) -> [OrgNode], prefix: String) -> ([OrgNode], Set<String>) {
        var open: Set<String> = []
        var byHost: [(HostClient, [OrgNode])] = []
        for c in hosts.ordered {
            let rows = make(c)
            if !rows.isEmpty { byHost.append((c, rows)) }
        }
        if byHost.isEmpty { return ([OrgNode(id: "\(prefix):none", title: "Nothing here", symbol: "circle.dashed")], []) }
        if byHost.count == 1 { return (byHost[0].1, open) }
        let roots = byHost.map { c, rows -> OrgNode in
            let id = "\(prefix):host:\(c.host.raw)"
            open.insert(id)
            let n = OrgNode(id: id, title: hosts.label(of: c.host), symbol: c.isRemote ? "server.rack" : "laptopcomputer", isGroup: true, children: rows)
            n.style = .host
            return n
        }
        return (roots, open)
    }

    /// Recently Closed (§4), the list: what exists and nothing reaches,
    /// dimmed, each brought back by a click, until collected.
}

/// The groups of the Status organization and the state views (§3.6).
enum StatusGroup: Int, CaseIterable {
    case needsYou, done, failed, working, inactive

    init(_ look: StatusGlyph.Look) {
        switch look {
        case .needsYou: self = .needsYou
        case .done: self = .done
        case .failed: self = .failed
        case .working, .busy: self = .working
        case .inactive, .connecting, .offline, .quiet, .watching: self = .inactive
        }
    }

    var title: String {
        switch self {
        case .needsYou: "Needs you"
        case .done: "Done"
        case .failed: "Failed"
        case .working: "Working"
        case .inactive: "Inactive"
        }
    }
}
