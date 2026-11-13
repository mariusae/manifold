import AppKit
import ManifoldCore
import WebKit
import ManifoldSyntax
import UniformTypeIdentifiers
import PDFKit

extension MainWindowController {
    // MARK: Finding and opening

    func debugFinder(_ query: String) -> [String] { finder.debugQuery(query) }
    func debugFinderPicture(_ path: String) -> String { finder.debugPicture(path) }
    func debugFinderTime(_ query: String) -> String {
        if query == "open" {
            let start = Date()
            let (c, _) = finderCorpus()
            return String(format: "snapshot of %d in %.1f ms", c.count, Date().timeIntervalSince(start) * 1000)
        }
        if query.hasPrefix("blocks ") {
            let q = String(query.dropFirst(7)), start = Date()
            let n = finderBlockItems(q, everywhere: true).count
            return String(format: "%d rows in %.1f ms", n, Date().timeIntervalSince(start) * 1000)
        }
        return finder.debugTime(query)
    }
    func debugFinderChoose() { finder.debugChoose() }
    var debugFinderReach: String { finder.isShowing ? finder.debugReach : "closed" }
    func debugSearchOutline(_ query: String) -> String {
        guard let f = arrangement?.focused, views[f]?.outline != nil else { return "no outline" }
        if !finder.isShowing { searchOutline(of: f) }
        return finder.debugQuery(query).joined(separator: "\n")
    }
    /// "wsoutline [query]": ⌘P typed in; "wsoutline tab": its other scope;
    /// "wsoutline time <query>": how long the query took, and how many rows.
    func debugWorkspaceOutline(_ query: String) -> String {
        if query.isEmpty { goToTile(nil); return "opened" }
        if query == "tab" { finder.debugSwitchOutline(); return "switched" }
        if query == "selected" { return finder.debugSelected }
        if query.hasPrefix("find "), let a = arrangement, let index = syncOutlineIndex() {
            // The index's part alone: looked up, and the rows made.
            let q = String(query.dropFirst(5))
            let order = a.columns.joined().map(\.id)
            let t0 = DispatchTime.now().uptimeNanoseconds
            let hits = index.find(q, in: order).reduce(0) { $0 + $1.items.count }
            let t1 = DispatchTime.now().uptimeNanoseconds
            let rows = spaceOutlineRows(a, query: q).count
            let t2 = DispatchTime.now().uptimeNanoseconds
            return String(format: "index %.2f ms (%d), rows %.2f ms (%d), %d rows indexed", Double(t1 - t0) / 1e6, hits, Double(t2 - t1) / 1e6, rows, index.count)
        }
        if query.hasPrefix("time ") {
            let q = String(query.dropFirst(5))
            let t0 = DispatchTime.now().uptimeNanoseconds
            let rows = finder.debugQueryCount(q)
            let ms = Double(DispatchTime.now().uptimeNanoseconds - t0) / 1e6
            return String(format: "%.2f ms, %d rows", ms, rows)
        }
        return finder.debugQuery(query).joined(separator: "\n")
    }
    func debugFinderScope(_ n: Int) { finder.debugScope(n) }
    func debugFinderKinds(_ arg: String) -> String {
        switch arg {
        case "tab": finder.debugTab()
        case "back": finder.debugBackspace()
        case let a where a.hasPrefix("click "): finder.debugClickCount(String(a.dropFirst(6)))
        default: break
        }
        return finder.debugKinds()
    }
    func debugFinderMove(_ by: Int) { finder.debugMove(by) }


    /// The project the focused block is in: its repository's root (git
    /// or Sapling), else its own folder.
    func projectRoot(from cwd: String?, on: HostID) -> String {
        let root = cwd ?? NSHomeDirectory()
        // A project made one (§2.6), on any host.
        if let p = hosts.client(on)?.project(holding: root) { return p.root }
        guard on == host.host else { return root }
        return VCS.repository(of: root)?.root ?? root
    }

    /// The lines that hold a query, as one excerpt: trimmed, run together.
    static func excerpt(_ lines: [String]) -> String {
        lines.prefix(6).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }.joined(separator: "  ·  ")
    }

    /// A place in a block's outline (§7.5) as Find in Blocks finds it,
    /// read from the block itself, so every terminal and note is found,
    /// shown or not: a command a terminal ran, a Markdown heading.
    struct OutlinePlace {
        var title: String
        var lower: String
        /// Where in the block: a command, a heading's line.
        var place: Locator
        var detail: String
        var note: String
        var at: Stamp?
    }

    /// A block's outline, as its tile's would be, without its tile: a
    /// terminal's commands (an agent's outline is its turns, found as
    /// turns), a note's or Markdown file's headings. Nil for a block whose
    /// outline only its tile knows (a source file's symbols, a PDF's
    /// contents, a page's headings).
    private func outlinePlaces(of b: Block) -> [OutlinePlace]? {
        let key: String
        switch b.kind {
        case .terminal:
            guard let t = b.terminal, b.agent == nil || (t.turns ?? []).isEmpty else { return nil }
            key = "c\(t.commands?.count ?? 0)/\(t.commands?.last?.ended != nil)"
        case .text:
            guard let t = b.text, b.path.map(Lens.isMarkdown) ?? true else { return nil }
            key = "t\(t.version)"
        default:
            return nil
        }
        if let known = outlinePlaceCache[b.id], known.key == key { return known.places }
        var places: [OutlinePlace] = []
        if let t = b.terminal {
            // The latest first; a command run again, once (its latest).
            var seen = Set<String>()
            for c in (t.commands ?? []).reversed() {
                let text = c.text.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !text.isEmpty, seen.insert(text).inserted else { continue }
                let ran = (c.cwd ?? t.cwd)?.abbreviatingHome ?? "~"
                let how = c.ended == nil ? "" : c.status.map { $0 == 0 ? "" : "exit \($0)" } ?? ""
                places.append(OutlinePlace(title: text, lower: text.lowercased(), place: .command(c.id),
                                           detail: "\(b.displayTitle) · \(ran)", note: how, at: c.at))
            }
        } else if let t = b.text {
            let place = b.path.map { $0.deletingLastPathComponent.abbreviatingHome } ?? "Note"
            for h in MarkdownOutline.headings(in: t.text.string) {
                places.append(OutlinePlace(title: h.text, lower: h.text.lowercased(), place: .line(h.line + 1),
                                           detail: "\(b.displayTitle) · \(place)", note: "heading", at: nil))
            }
        }
        if outlinePlaceCache.count > 4 * max(hosts.blocks.count, 64) { outlinePlaceCache = outlinePlaceCache.filter { hosts.block($0.key) != nil } }
        outlinePlaceCache[b.id] = (key, places)
        return places
    }

    /// Find in Blocks' outline rows: every place in an outline whose title
    /// holds the query — this space's blocks first, then the rest; then
    /// the outlines only a tile knows, the desk's — each going to the
    /// place itself, as its tile's outline would.
    private func finderOutlineItems(_ q: String, everywhere: Bool) -> [FinderItem] {
        var items: [FinderItem] = []
        var seen = Set<BlockID>()
        let here = arrangement?.placements.map(\.block) ?? []
        for id in here + (everywhere ? hosts.blocks.map(\.id) : []) where seen.insert(id).inserted {
            guard let b = hosts.block(id), let places = outlinePlaces(of: b) else { continue }
            let symbol = Theme.symbolName(for: b), kinds = FindKinds.of(b)
            for p in places where p.lower.contains(q) {
                let link = "manifold:\(id.description)#\(p.place.fragment)", at = p.place, title = p.title
                items.append(FinderItem(symbol: symbol, title: p.title, detail: p.detail, note: p.note,
                                        age: p.at.map { Age.short($0) }.flatMap { $0 == "now" ? nil : $0 },
                                        run: { [weak self] in self?.open(link, from: self?.arrangement?.focused) },
                                        drag: { Drags.place?(Place(block: id, at: at, name: title), nil) }, kinds: kinds))
                if items.count >= 100 { return items }
            }
        }
        // A tile's own outline, for what only it knows: gone to through a
        // link where an item has a place (a symbol's line, a PDF's page),
        // else picked in its tile, this space's.
        let shown = (arrangement?.placements.map(\.id) ?? []) + (everywhere ? views.keys.sorted { $0.description < $1.description } : [])
        var tiles = Set<PlacementID>(), outlined = Set<BlockID>()
        for pid in shown where tiles.insert(pid).inserted {
            guard let view = views[pid], !(view is TerminalView), let o = view.outline, !o.items.isEmpty,
                  let b = hosts.block(view.block), outlinePlaces(of: b) == nil, outlined.insert(b.id).inserted else { continue }
            let symbol = Theme.symbolName(for: b), kinds = FindKinds.of(b)
            let inThisSpace = arrangement?.placement(pid) != nil
            for (i, item) in o.items.enumerated() where item.title.lowercased().contains(q) {
                let at = o.placeFor?(i)
                guard at != nil || inThisSpace else { continue }
                let id = b.id, title = item.title
                items.append(FinderItem(symbol: symbol, title: item.title, detail: b.displayTitle + (item.detail.isEmpty ? "" : " · " + item.detail),
                                        note: item.code ? "symbol" : "heading",
                                        run: { [weak self, weak o] in
                                            guard let self else { return }
                                            if let at { return self.open("manifold:\(id.description)#\(at.fragment)", from: self.arrangement?.focused) }
                                            self.arrive(atTile: pid)
                                            o?.pick(i)
                                        },
                                        drag: { Drags.place?(Place(block: id, at: at, name: title), nil) }, kinds: kinds))
                if items.count >= 150 { return items }
            }
        }
        return items
    }

    /// "In Blocks" (⇧⌘O): the places in the blocks' outlines that hold the
    /// query (finderOutlineItems); then the texts of the blocks — the
    /// selected workspace's first, then every other note and file kept as
    /// a block — a row each, its name, where it is, the lines that hold
    /// the query marked, going to the first of them; then agents' turns.
    /// `everywhere`: every space's blocks (⇧⌘O again), not only this one's.
    func finderBlockItems(_ query: String, everywhere: Bool) -> [FinderItem] {
        guard !query.isEmpty else { return [] }
        let q = query.lowercased()
        let needle = Array(q.utf8)
        let places = finderOutlineItems(q, everywhere: everywhere)
        var items: [FinderItem] = []
        var seen = Set<BlockID>()
        let here = arrangement.map { a in a.placements.map { ($0.block, Optional($0.id)) } } ?? []
        let rest = everywhere ? hosts.blocks.filter { $0.kind == .text }.map { ($0.id, PlacementID?.none) } : []
        for (blockID, placement) in here + rest where seen.insert(blockID).inserted {
            // Each text read through as made once per version (`SearchText`),
            // not lowercased afresh, line by line, at every key.
            guard let b = hosts.block(blockID), b.text != nil, let st = searchText(for: b) else { continue }
            let hits = st.lines(matching: needle, limit: 10_000)
            guard let at = hits.first else { continue }
            let matches = hits.prefix(6).map { String(st.lines[$0 - 1]) }
            let count = hits.count, block = b.id
            let place = b.path.map { $0.deletingLastPathComponent.abbreviatingHome } ?? (b.place.map { "Note · " + $0.abbreviatingHome } ?? "Note")
            items.append(FinderItem(symbol: Theme.symbolName(for: b), title: b.displayTitle, detail: place,
                                    note: count == 1 ? "line \(at)" : "\(count) lines",
                                    run: { [weak self] in
                                        guard let self else { return }
                                        let d = Self.disposition ?? .goTo
                                        if d == .goTo, let id = placement, self.arrangement?.placement(id) != nil, let e = self.views[id] as? EditorView {
                                            self.arrive(atTile: id)
                                            e.select(line: at)
                                            return
                                        }
                                        if d != .system { self.pendingJump = (b.path ?? "", at, nil) }
                                        self.follow(block, lens: Lens.default(for: .text, path: b.path), from: self.arrangement?.focused, d, context: "found in ⌘O")
                                        self.warpPointerToFocus()
                                    },
                                    excerpt: Self.excerpt(matches), marked: query,
                                    drag: { Drags.block?(block, Drags.modifiers) }, block: block,
                                    kinds: FindKinds.of(b)))
            if items.count >= 100 { break }
        }
        // Agents' turns: what was asked and what each said (this space's agents', unless everywhere).
        let hereBlocks = Set(here.map(\.0))
        for block in hosts.blocks where everywhere || hereBlocks.contains(block.id) {
            for turn in (block.terminal?.turns ?? []).reversed() {
                let said = [turn.prompt, turn.message ?? ""].joined(separator: "\n")
                guard said.lowercased().contains(q) else { continue }
                let lines = said.split(separator: "\n").map(String.init).filter { $0.lowercased().contains(q) }
                let first = turn.headline ?? "Turn"
                let agentID = block.id, turnID = turn.id
                items.append(FinderItem(symbol: "text.bubble", title: String(first.prefix(120)), detail: "Turn of \(block.displayTitle) · \(Age.short(turn.began))",
                                        note: (turn.files?.count).map { "\($0) file\($0 == 1 ? "" : "s")" } ?? "",
                                        run: { [weak self] in
                                            guard let self else { return }
                                            self.showTurn(turnID, of: agentID, place: .by(Self.disposition ?? .goTo, from: self.arrangement?.focused))
                                        },
                                        excerpt: Self.excerpt(lines), marked: query, kinds: ["turn"]))
                if items.count >= 150 { return places + items }
            }
        }
        return places + items
    }

    /// ⌘O: blocks, spaces and files by name (§3.5) — in this space first
    /// (its tiles, what was closed from it, its projects' files); ⌘O again,
    /// in every space.
    @objc func openDocument(_ sender: Any?) {
        // Open already: a step wider (or back).
        if finder.opener == .names { return finder.widen() }
        let (corpus, actions) = finderCorpus()
        // Each project's files: those of the space's tiles' projects now,
        // the rest of the desk's once it's widened. Those open as blocks
        // already are found as blocks.
        var files: [FinderFiles] = []
        var known: Set<String> = []
        let focused = focusedProject()
        for (on, project, inSpace) in finderProjects() {
            guard let client = hosts.client(on) else { continue }
            let nearest = focused.map { $0.0 == on && $0.1.root == project.root } == true
            files.append(FinderFiles(root: project.root, host: on, inSpace: inSpace, key: on.raw + ":" + project.root, list: { done in
                client.listTree(project.root) { entries, _ in done((entries ?? []).filter { !$0.isDirectory }.map(\.name)) }
            }, distance: nearest ? 2 : inSpace ? 4 : 6, note: "in \(project.name)"))
            known.formUnion(client.node.blocks.compactMap { $0.kind == .text || $0.kind == .image || $0.kind == .pdf ? $0.path : nil })
        }
        finder.show(corpus: corpus, actions: actions, files: files, knownPaths: known, scope: .names,
                    reach: selected == nil ? .all : .space, placeholder: "Open…", over: window)
    }

    /// The projects (§2.6) the desk's tiles are in, each once: whether it's
    /// one of the space shown's; the focused tile's first.
    private func finderProjects() -> [(HostID, Project, Bool)] {
        var out: [(HostID, Project, Bool)] = []
        var seen = Set<String>()
        func add(_ block: BlockID, inSpace: Bool) {
            guard let b = hosts.block(block), let place = b.place, let p = hosts.client(of: block)?.project(holding: place) else { return }
            if seen.insert(block.host.raw + ":" + p.root).inserted { out.append((block.host, p, inSpace)) }
        }
        if let f = focusedShown?.placement.block { add(f, inSpace: true) }
        for p in arrangement?.placements ?? [] { add(p.block, inSpace: true) }
        for ws in allWorkspaces where ws != selected {
            for p in hosts.arrangement(ws)?.placements ?? [] { add(p.block, inSpace: false) }
        }
        return out
    }

    /// ⌃⌘P: the nearest project — the one the focused tile is in (§2.6),
    /// else its repository's root, else its folder — its homepage gone to
    /// where it's shown, else opened beside.
    @objc func goToNearestProject(_ sender: Any?) {
        guard let f = focusedShown, let b = hosts.block(f.placement.block), let place = b.place else { return NSSound.beep() }
        let on = f.placement.block.host
        let root = focusedProject()?.1.root ?? projectRoot(from: place, on: on)
        // The project itself focused: nowhere nearer to go.
        guard !(b.kind == .directory && b.path == root) else { return NSSound.beep() }
        let id = hosts.directoryBlock(for: root, on: on)
        let shownHere = arrangement?.placements.contains { $0.block == id } == true
        openDirectory(root, from: f.placement.id, as: Self.disposition ?? (shownHere ? .goTo : .beside), context: "its project")
    }

    /// The project the focused tile's block is in (§2.6), on its host.
    func focusedProject() -> (HostID, Project)? {
        guard let f = focusedShown?.placement.block, let b = hosts.block(f), let place = b.place,
              let p = hosts.client(f.host)?.project(holding: place) else { return nil }
        return (f.host, p)
    }

    /// Whether a block is in a project: where it is (a file's folder, a
    /// terminal's directory) under its root, on its host.
    static func block(_ b: Block, isIn project: (HostID, Project)) -> Bool {
        b.id.host == project.0 && (b.place.map(project.1.holds) ?? false)
    }

    /// ⇧⌘O: lines in blocks' texts and outlines — this space's; ⇧⌘O
    /// again, every space's.
    @objc func findInBlocks(_ sender: Any?) {
        if finder.opener == .blocks { return finder.widen() }
        let (corpus, actions) = finderCorpus()
        finder.show(corpus: corpus, actions: actions, files: [], scope: .blocks, reach: selected == nil ? .all : .space,
                    placeholder: "Find in blocks…", over: window)
    }

    /// What `@` in a thread's composer can name: ⌘O's blocks (not agents' turns).
    func finderCorpusForMentions() -> ([FinderCandidate], [() -> Void]) {
        let (corpus, actions) = finderCorpus()
        return (corpus.filter { $0.block != nil && !$0.kinds.contains("turn") }, actions)
    }

    /// What the finder finds by name (§3.5), taken once as it opens: every
    /// block and workspace, each with what it's called (and words as good:
    /// its kind, the agent at work in it), what's around it, how far it is
    /// from the focused block and how lately seen. Ranked off the main
    /// thread as you type (FinderRanking).
    /// What nothing keeps (§4) comes last, marked recent.
    private func finderCorpus() -> ([FinderCandidate], [() -> Void]) {
        var corpus: [FinderCandidate] = []
        var actions: [() -> Void] = []
        let near = focusedShown.map { hosts.distances(from: $0.placement.block, limit: 6) } ?? [:]
        let focusedBlock = focusedShown?.placement.block
        let here = Set(arrangement?.placements.map(\.block) ?? [])
        let onDesk = Set(allWorkspaces.compactMap { hosts.arrangement($0) }.flatMap { $0.placements.map(\.block) })
        let reachable = hosts.reachable()
        var joinedAt: [BlockID: Int64] = [:]
        if let f = focusedBlock {
            let n = hosts.neighborhood(of: f)
            for es in n.outbound.values { for e in es { joinedAt[e.to] = max(joinedAt[e.to] ?? 0, e.at.wall) } }
            for es in n.inbound.values { for e in es { joinedAt[e.from] = max(joinedAt[e.from] ?? 0, e.at.wall) } }
            for t in n.before + n.after { joinedAt[t.block] = max(joinedAt[t.block] ?? 0, t.last.wall) }
        }
        let running = runningPrograms()
        // The focused block's project (§2.6): its blocks before what's elsewhere.
        let project = focusedProject()
        // What's this space's (found at ⌘O's nearer reach): its tiles, its
        // pins, and what was closed from it and not yet collected.
        var ofSpace = here
        if let ws = selected {
            ofSpace.formUnion(pins(of: ws).map(\.to))
            for c in closedStack { if case let .tile(w, _, _, p, _, _) = c, w == ws { ofSpace.insert(p.block) } }
            // Its threads (§3.12), by their titles, shown as tiles or not.
            ofSpace.formUnion(hosts.threads(inSpace: ws).map(\.id))
        }
        // Where each block in another space is: said of it, every space looked in.
        var elsewhere: [BlockID: String] = [:]
        for ws in allWorkspaces where ws != selected {
            guard let a = hosts.arrangement(ws) else { continue }
            let name = title(of: a)
            for p in a.placements where elsewhere[p.block] == nil { elsewhere[p.block] = name }
        }
        for block in hosts.blocks where block.kind != .process {
            guard let entry = hosts.registryEntry(block.id) else { continue }
            let remote = block.id.host != host.host ? " on \(hosts.label(of: block.id.host))" : ""
            var title = block.displayTitle
            let programs = running[block.id] ?? []
            let agent = block.agent
            var secondary: String
            var detail: String
            var note = ""
            switch block.kind {
            case .arrangement:
                // A workspace by its name; what it holds is found as itself.
                guard let a = block.arrangement else { continue }
                title = self.title(of: a)
                secondary = ""
                detail = a.isNamed ? "Space · \(a.placements.count) blocks" : "Space, unnamed · \(a.placements.count) blocks"
            case .text:
                secondary = block.path ?? ""
                detail = block.path.map { ($0 as NSString).deletingLastPathComponent.abbreviatingHome } ?? "Note"
                note = block.text?.isDirty == true ? "edited" : ""
            case .terminal:
                secondary = (block.terminal?.cwd ?? "") + " " + programs.joined(separator: " ")
                detail = "Terminal in \(block.terminal?.cwd?.abbreviatingHome ?? "~")" + (agent.map { " · " + $0.name } ?? (programs.isEmpty ? "" : " · " + programs.prefix(3).joined(separator: ", ")))
                note = block.terminal?.dormantSince != nil && block.terminal?.pid == nil ? "dormant" : (block.terminal?.busy == true ? "running" : "")
            case .directory:
                secondary = block.path ?? ""
                detail = "Folder"
            case .search:
                secondary = block.search?.query?.root ?? ""
                detail = "Search in \(block.search?.query?.root.abbreviatingHome ?? "")"
            case .image, .pdf:
                secondary = block.path ?? ""
                detail = block.kind == .pdf ? "PDF" : "Image"
            case .process:
                continue
            case .agent:
                secondary = "agent " + (block.terminal?.cwd ?? "") + " " + programs.joined(separator: " ")
                detail = "\(agent?.name ?? "Agent") in \(block.terminal?.cwd?.abbreviatingHome ?? "~")"
                note = block.terminal?.pid == nil ? "ended" : ""
            case .git:
                secondary = "git " + (block.path ?? "")
                detail = "Git, \(block.path?.abbreviatingHome ?? "")"
            case .smartlog:
                secondary = "smartlog isl sapling " + (block.path ?? "")
                detail = "Interactive Smartlog, \(block.path?.abbreviatingHome ?? "")"
            case .diff:
                secondary = "diff " + (block.path ?? "")
                detail = "Diff, \(block.path?.deletingLastPathComponent.abbreviatingHome ?? "")"
            case .web:
                secondary = block.web?.url ?? ""
                detail = block.web?.url ?? "Web page"
            case .notebook:
                let sources = (block.notebook?.cells ?? []).prefix(20).map(\.source).joined(separator: " ")
                secondary = "notebook shell " + (block.place ?? "") + " " + sources
                detail = "Shell notebook in \(block.place?.abbreviatingHome ?? "~")"
                note = block.notebook?.running != nil ? "running" : ""
            case .output:
                secondary = "output " + (block.place ?? "")
                detail = "Output" + (block.output?.status.map { $0 == 0 ? ", ok" : ", exit \($0)" } ?? "") + (block.place.map { " · " + $0.abbreviatingHome } ?? "")
            case .ui:
                secondary = "panel ui form " + (block.place ?? "")
                detail = "Panel" + (block.place.map { " · " + $0.abbreviatingHome } ?? "")
            case .thread:
                let t = block.thread
                secondary = "thread comment " + (t?.comments.compactMap(\.comment).joined(separator: " ").prefix(400) ?? "")
                detail = "Thread" + (t?.about?.title.map { " · " + $0 } ?? "") + (t?.resolved == true ? " · resolved" : "")
            }
            if let r = block.statusRecord, r.wantsAttention {
                note = r.state == .blocked ? "needs you" : r.state == .done ? "done, not read yet" : "failed"
            }
            // How far from where you are: here is nearest, then by the
            // graph; what nothing reaches comes last of all.
            var distance = near[block.id] ?? 50
            if !reachable.contains(block.id) {
                note = "recent"
                distance = 100
            } else if block.kind == .arrangement {
                if allWorkspaces.contains(block.id) { distance = min(distance, 2) }
            } else if here.contains(block.id) {
                // The project's (§2.6) before the rest of the space's.
                distance = block.id == focusedBlock ? 1000 : project.map { Self.block(block, isIn: $0) } == true ? 0 : 1
                if note.isEmpty { note = block.id == focusedBlock ? "here, focused" : "here" }
            } else if let d = near[block.id], d > 0 {
                if note.isEmpty { note = d == 1 ? "linked" : "near" }
                if let project, Self.block(block, isIn: project) { distance = min(distance, 2) }
            } else if let project, Self.block(block, isIn: project) {
                distance = min(distance, 2)
                if note.isEmpty { note = "in \(project.1.name)" }
            } else if onDesk.contains(block.id) {
                distance = min(distance, 3)
            }
            // In another space: which.
            if block.kind != .arrangement, !ofSpace.contains(block.id), let space = elsewhere[block.id], note.isEmpty || note == "linked" || note == "near" { note = "in \(space)" }
            // How long since it was seen, in a pill — none for just now.
            let seen = Age.short(entry.lastSeen)
            let age = seen == "now" ? nil : seen
            // Words as good as the title's own: the kind ("terminal", "note"),
            // and the agent at work in it ("claude", "Claude Code").
            let kindWord = block.kind == .text ? (block.path == nil ? "Note" : "File") : block.kind.defaultTitle
            let agentWords = agent.map { " " + $0.command + " " + $0.name } ?? ""
            secondary += " " + block.id.host.raw
            let id = block.id
            // What its summary says is found too: often the best of what
            // it holds (a terminal's last command, an agent's last words).
            let summary = block.kind == .arrangement ? "" : block.summary().lines.joined(separator: " ")
            var candidate = FinderCandidate(symbol: Theme.symbolName(for: block), title: title, detail: detail + remote, note: note, age: age,
                                            name: title + " " + kindWord + agentWords, aliases: agent.map { [$0.command, $0.name] } ?? [], around: secondary,
                                            summary: summary,
                                            distance: distance, recency: max(entry.lastSeen.wall, joinedAt[block.id] ?? 0), action: actions.count, block: block.id,
                                            kinds: FindKinds.of(block.kind, path: block.path, agent: agent != nil))
            // The desk's other spaces, as places to go, are found from here
            // too (what they hold isn't); this one isn't listed in itself.
            candidate.inSpace = block.kind == .arrangement ? block.id != selected && allWorkspaces.contains(block.id) : ofSpace.contains(block.id)
            // A space by what it's called, not by its letters scattered
            // through a long name (a folder's path).
            candidate.byNameOnly = block.kind == .arrangement
            corpus.append(candidate)
            actions.append { [weak self] in self?.recall(id) }
        }
        // Agents' turns (§3.8), by what was asked: found as the turn, which
        // opens as its own block.
        for block in hosts.blocks {
            for turn in block.terminal?.turns ?? [] {
                let first = turn.headline ?? ""
                guard !first.isEmpty else { continue }
                let agentID = block.id, turnID = turn.id
                let files = (turn.files ?? []).prefix(3).joined(separator: ", ")
                var candidate = FinderCandidate(symbol: "text.bubble", title: String(first.prefix(120)),
                                                detail: "Turn of \(block.displayTitle)" + (files.isEmpty ? "" : " · " + files),
                                                note: "", age: Age.short(turn.began) == "now" ? nil : Age.short(turn.began), name: first + " turn " + turn.agent,
                                                around: (turn.repo ?? "") + " " + (turn.files ?? []).joined(separator: " "),
                                                distance: 60, recency: turn.began.wall, action: actions.count, kinds: ["turn"])
                // An agent's here: its turns are this space's.
                candidate.inSpace = here.contains(block.id)
                corpus.append(candidate)
                actions.append { [weak self] in self?.showTurn(turnID, of: agentID, place: .here) }
            }
        }
        return (corpus, actions)
    }

    /// Chosen in the finder: gone to; with ⌘ held on ⏎, beside the focused
    /// tile; with ⌥, over it (the rule, §3.1).
    func recall(_ id: BlockID) {
        let d = Self.disposition ?? .goTo
        // Nothing focused to open beside or over: gone to, or brought here.
        guard arrangement?.focused != nil || d == .system else { return goTo(id) }
        follow(id, from: arrangement?.focused, d, context: "chosen in ⌘O")
    }

    /// After a go-to (⌘O, ⌘P, a found line): the pointer moves to what was
    /// gone to — the text cursor if the tile has one, else the tile's
    /// middle — a moment later, once it is laid out.
    func warpPointerToFocus() {
        // Once laid out; and again once the layout's animation (a tile
        // coming out of a stack, a column resettling) has ended.
        for delay in [0.08, 0.32] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                guard let self, let a = self.arrangement, let f = a.focused, let view = self.views[f] else { return }
                self.warpPointer(to: view)
                // Arrived at another tile: it's marked, once. (Gone somewhere
                // in the tile already focused, it isn't.)
                if delay < 0.1, Date().timeIntervalSince(self.focusMovedAt) < 0.6 { self.content.markArrival(f) }
            }
        }
    }

    /// The pointer to a view's text cursor, or its middle, now.
    func warpPointer(to view: PaneContent) {
        guard let window, let rect = pointerTarget(in: view) else { return }
        let screen = window.convertToScreen(rect)
        Pointer.warp(to: NSPoint(x: screen.midX + 2, y: screen.midY))
    }

    /// Where in the window the pointer goes for a view: its text cursor,
    /// if that's in sight in the view, else the middle of what shows of
    /// it. (A cursor scrolled out of sight is somewhere over the tiles
    /// around it: the pointer would land in another tile.)
    func pointerTarget(in view: PaneContent) -> NSRect? {
        guard let window, view.window === window else { return nil }
        let shown = view.convert(view.visibleRect, to: nil)
        guard !shown.isEmpty else { return nil }
        var rect = view.caretRectInWindow.flatMap { shown.contains(NSPoint(x: $0.midX, y: $0.midY)) ? $0 : nil } ?? shown
        if rect.width > 40 || rect.height > 40 { rect = NSRect(x: rect.midX - 1, y: rect.midY - 1, width: 2, height: 2) }
        return rect
    }

    /// Debugging: where the pointer would go for the focused tile, and
    /// whose tile that is, without moving it.
    func debugPointerTarget() -> String {
        guard let a = arrangement, let f = a.focused, let view = views[f], let r = pointerTarget(in: view) else { return "none" }
        let p = content.convert(NSPoint(x: r.midX, y: r.midY), from: nil)
        let over = content.views.first { !$0.isHidden && $0.superview === content && $0.frame.contains(p) }
        let name = over.flatMap { v in a.placement(v.placement).flatMap { hosts.block($0.block)?.displayTitle } } ?? "no tile"
        var raw = "no caret"
        if let c = view.caretRectInWindow {
            let q = content.convert(NSPoint(x: c.midX, y: c.midY), from: nil)
            let at = content.views.first { !$0.isHidden && $0.superview === content && $0.frame.contains(q) }
            raw = "caret over " + (at.flatMap { v in a.placement(v.placement).flatMap { hosts.block($0.block)?.displayTitle } } ?? "no tile")
        }
        return "over \(name)\(over?.placement == f ? " (the focused one)" : ""); \(raw)"
    }

    /// An editor's line, or a preview's heading, is in view: the pointer
    /// goes there (a go-to that had to wait for a load or a layout).
    func editorDidReveal(_ view: EditorView) {
        DispatchQueue.main.async { [weak self] in self?.warpPointer(to: view) }
    }

    func markdownViewDidReveal(_ view: MarkdownView) {
        DispatchQueue.main.async { [weak self] in self?.warpPointer(to: view) }
    }

    /// **Go to** (§3.1): the block where it already is — a tile here is
    /// focused; else the arrangement it is in, the one most recently
    /// settled on first, is selected and its tile focused; else, placed
    /// nowhere, it is brought here.
    /// `near`: of the block's tiles here, the one in that tile's stack
    /// first (brought to its top), then its column's — not whichever comes
    /// first (another of the block's tiles elsewhere, focused for nothing).
    func goTo(_ id: BlockID, near: PlacementID? = nil) {
        guard let block = hosts.block(id) else { return sayMissing(id) }
        hideStateView()
        warpPointerToFocus()
        if block.kind == .arrangement { return hosts.select(id) }
        if let a = arrangement, let t = nearest(a.placements(of: id), to: near, in: a), let here = selected {
            // Here already: out of its stack, from behind a maximized
            // tile, and focused.
            return land(on: t.id, in: here, a)
        }
        let recent = hosts.recentWorkspaces()
        let order = recent + allWorkspaces.filter { !recent.contains($0) }
        for arr in order where arr != selected {
            if let a = hosts.arrangement(arr), let t = a.placements(of: id).first { return land(on: t.id, in: arr, a) }
        }
        show(id, lens: block.defaultLens, .here)
    }

    /// Of a block's tiles, the one nearest `near`: in its column, then the
    /// first in the grid, then the first.
    private func nearest(_ tiles: [Placement], to near: PlacementID?, in a: ArrangementState) -> Placement? {
        guard let near, tiles.count > 1 else { return tiles.first }
        if let c = a.locate(near)?.column, let t = tiles.first(where: { a.locate($0.id)?.column == c }) { return t }
        return tiles.first
    }
}
