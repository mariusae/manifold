import AppKit
import ManifoldCore
import WebKit
import ManifoldSyntax
import UniformTypeIdentifiers
import PDFKit

extension MainWindowController: DirectoryViewDelegate {
    // MARK: Projects (§2.6)

    func directoryViewProject(_ view: DirectoryView) -> Project? {
        guard let path = hosts.block(view.block)?.path, let desk = hosts.client(of: view.block)?.desk else { return nil }
        return desk.projects.first { $0.root == path || $0.alias == path }
    }

    func directoryViewParentProject(_ view: DirectoryView) -> Project? {
        guard let path = hosts.block(view.block)?.path, let desk = hosts.client(of: view.block)?.desk,
              let p = desk.project(holding: path), p.root != path, p.alias != path else { return nil }
        return p
    }

    func directoryView(_ view: DirectoryView, makeProject: Bool) {
        guard let client = hosts.client(of: view.block), let path = hosts.block(view.block)?.path else { return NSSound.beep() }
        let proposal: Proposal = makeProject
            ? .project(Project(root: path, made: Stamp(wall: Int64(Date().timeIntervalSince1970 * 1000))))
            : .unproject(root: directoryViewProject(view)?.root ?? path)
        client.propose(proposal) { [weak self] error in
            if let error { self?.toast.say(error) }
        }
    }

    func directoryView(_ view: DirectoryView, gitFor project: Project) -> BlockID? {
        hosts.client(of: view.block)?.projectGitBlock(for: project)
    }

    func directoryView(_ view: DirectoryView, block id: BlockID) -> Block? { hosts.block(id) }

    func directoryView(_ view: DirectoryView, indexOf project: Project, done: @escaping (SCIPStatus?, String?) -> Void) {
        hosts.scip(.status(path: project.root.appendingPathComponent(".")), on: view.block.host) { result in
            switch result {
            case .status(let s) where s.root == nil: done(nil, s.message ?? "no indexer for its language")
            case .status(let s): done(s, nil)
            case .error(let m): done(nil, m)
            default: done(nil, nil)
            }
        }
    }

    func directoryView(_ view: DirectoryView, watch block: BlockID, _ changed: @escaping () -> Void) {
        hosts.watch(block, by: view, changed)
    }

    func directoryView(_ view: DirectoryView, search query: SearchQuery, in block: BlockID?) -> BlockID? {
        guard let client = hosts.client(of: view.block) else { return nil }
        if let block, hosts.block(block) != nil {
            hosts.propose(.search(block: block, query: query))
            return block
        }
        return client.newSearch(query)
    }

    func directoryView(_ view: DirectoryView, open found: ProjectSearchView.Found, root: String) {
        let host = view.block.host
        switch found {
        case let .symbol(h):
            open(path: h.path, line: h.line + 1, column: h.character + 1, on: host, from: view.placement, context: h.qualified)
        case let .file(rel):
            open(root.appendingPathComponent(rel), from: view.placement)
        case let .hit(h):
            open(path: h.path, line: h.line, column: h.column, on: host, from: view.placement, context: "“\(h.text.trimmingCharacters(in: .whitespaces).prefix(30))”")
        }
    }

    func directoryView(_ view: DirectoryView, languagesOf project: Project, done: @escaping ([Linguist.Count]?) -> Void) {
        guard let client = hosts.client(of: view.block) else { return done(nil) }
        client.languages(project.root, done: done)
    }

    func directoryView(_ view: DirectoryView, presenceIn project: Project) -> [Presence] {
        guard let client = hosts.client(of: view.block) else { return [] }
        var out: [Presence] = []
        let shownHere = Set(arrangement?.placements.map(\.block) ?? [])
        // Terminals and agents with a shell there, what each is doing.
        let own = Set(project.agents ?? [])
        for b in client.node.blocks where (b.kind == .terminal || b.kind == .agent) && !own.contains(b.id) {
            // (Its own agents are pills on its line.)
            guard let t = b.terminal, t.pid != nil || t.dormantSince == nil, let cwd = t.cwd, project.holds(cwd) else { continue }
            let where_ = project.relative(cwd)
            let doing = b.statusRecord?.msg ?? t.commands?.last(where: { $0.isRunning })?.text
            out.append(Presence(block: b.id, title: Self.linkTitle(b), symbol: Theme.symbolName(for: b),
                                detail: [b.agent?.name, doing, where_.isEmpty ? nil : where_ + "/"].compactMap { $0 }.joined(separator: " · "),
                                here: shownHere.contains(b.id), card: cardContent(for: b.id)))
        }
        // Notes about its files: linked to one of them.
        do {
            let graph = client.node.graph
            var notes: [BlockID: String] = [:]
            for f in client.node.blocks where f.kind == .text {
                guard let p = f.path, project.holds(p) else { continue }
                for e in graph.edges(to: f.id) {
                    guard case .link = e.kind, notes[e.from] == nil, let n = client.node.block(e.from), n.isNote else { continue }
                    notes[e.from] = project.relative(p)
                }
            }
            for (id, about) in notes.sorted(by: { $0.value < $1.value }) {
                guard let n = client.node.block(id) else { continue }
                out.append(Presence(block: id, title: n.displayTitle, symbol: Theme.symbolName(for: n), detail: "about " + about,
                                    here: shownHere.contains(id), card: cardContent(for: id)))
            }
        }
        // Those in the workspace shown first, each kind as it was.
        return out.filter(\.here) + out.filter { !$0.here }
    }

    func directoryView(_ view: DirectoryView, popOut search: BlockID) {
        show(search, lens: .search, .besideOpener(view.placement), context: "a search of \(directoryViewProject(view)?.name ?? "the project")")
    }

    func directoryView(_ view: DirectoryView, project: Project, do action: ProjectAction) {
        guard let client = hosts.client(of: view.block) else { return NSSound.beep() }
        switch action {
        case .settings:
            editProject(project, on: client)
        case let .go(block):
            arrive(block, from: view.placement)
        case .openGit:
            let id = client.projectGitBlock(for: project)
            show(id, lens: .git, .besideOpener(view.placement), context: "\(project.name)'s changes")
        case let .openCommit(c, repo):
            let id = client.diffBlock(.commit(repo: repo, sha: c.sha))
            show(id, lens: .diff, .besideOpener(view.placement), context: "a commit in \(project.name)")
        case let .openChange(s, repo):
            let path = repo.appendingPathComponent(s.path)
            if s.workTree == "D" && s.index == " " { return open(path, from: view.placement) }
            let id = client.diffBlock(.sides(old: DiffSide(path: path, revision: "HEAD"), new: DiffSide(path: path)))
            show(id, lens: .diff, .besideOpener(view.placement), context: "a change in \(project.name)")
        case .reindex:
            hosts.scip(.index(path: project.root.appendingPathComponent(".")), on: view.block.host) { [weak self] result in
                if case .error(let m) = result { self?.toast.say(m) }
            }
        case .newAgent:
            _ = newProjectAgent(in: project, on: client)
        case let .showAgent(id):
            arrive(id, from: view.placement)
        case let .renameAgent(id):
            renameProjectAgent(id, from: view.placement)
        case let .deleteAgent(id):
            // As any block's deleting: said, with Undo; gone for good, the
            // project lets go of it (the host, as it discards it).
            deleteBlock(id)
        }
    }

    /// An agent made in a project (§3.12): kept by it, started with
    /// nothing showing it — its pill on the project's line, its name its own.
    @discardableResult
    func newProjectAgent(in project: Project, on client: HostClient) -> BlockID {
        let usual = desk.settings.agentCommand
        let command = AgentCatalog.agent(inCommand: usual) != nil ? usual : "claude"
        return client.newProjectAgent(root: project.root, command: command)
    }

    /// A project's agents, as the pills on its line show them.
    func directoryView(_ view: DirectoryView, agentsOf project: Project) -> [ProjectAgentChip] {
        (project.agents ?? []).compactMap { id in hosts.block(id).map { agentChip($0, in: project) } }
    }

    /// The agents of every project the space shown reaches (§3.12) — one a
    /// tile of it shows, or something from inside it — project by project,
    /// in the space's order, as the pills at the sidebar's foot show them.
    func spaceAgentChips() -> [ProjectAgentChip] {
        guard let id = selected, let a = hosts.arrangement(id) else { return [] }
        var seen: Set<String> = [], out: [ProjectAgentChip] = []
        for p in a.placements {
            guard let proj = project(of: p.block), seen.insert("\(p.block.host)|\(proj.root)").inserted else { continue }
            out += agents(of: proj, on: p.block.host).map { agentChip($0, in: proj) }
        }
        return out
    }

    /// A project's agent's menu, wherever its pill is: show it, rename it,
    /// delete it (with Undo, as any block).
    func projectAgentMenu(_ id: BlockID) -> NSMenu? {
        guard let b = hosts.block(id) else { return nil }
        let name = AgentLook.name(of: b)
        let menu = NSMenu()
        menu.addItem(ClosureMenuItem("Show \(name)", symbol: "rectangle.on.rectangle") { [weak self] in self?.arrive(id, from: nil) })
        menu.addItem(ClosureMenuItem("Rename…", symbol: "character.cursor.ibeam") { [weak self] in self?.renameProjectAgent(id) })
        menu.addItem(.separator())
        menu.addItem(ClosureMenuItem("Delete \(name)", symbol: "trash") { [weak self] in self?.deleteBlock(id) })
        return menu
    }

    /// Its tile, and its name edited in its bar.
    func renameProjectAgent(_ id: BlockID, from placement: PlacementID? = nil) {
        arrive(id, from: placement)
        DispatchQueue.main.async { [weak self] in
            guard let self, let p = self.arrangement?.placements.first(where: { $0.block == id }) else { return }
            self.gridRenameAgent(p.id)
        }
    }

    /// A project's agent as its pill shows it (§3.12): its name and colour,
    /// what most wants you of it, whether it's asleep.
    func agentChip(_ b: Block, in project: Project?) -> ProjectAgentChip {
        ProjectAgentChip(id: b.id, name: AgentLook.name(of: b), color: AgentLook.color(of: b) ?? Theme.accent,
                         status: StatusGlyph.look(of: b), asleep: !Self.agentRuns(b),
                         detail: AgentLook.description(of: b), project: project?.name ?? "")
    }

    /// "?text" in a folder's filter: the files under it searched, the
    /// search's tile beside the folder's.
    func directoryView(_ view: DirectoryView, searchContents text: String) {
        guard let client = hosts.client(of: view.block), let root = hosts.block(view.block)?.path else { return }
        let id = client.newSearch(SearchQuery(text: text, root: root))
        show(id, lens: .search, .besideOpener(view.placement), context: "search in \(root.lastPathComponent)")
    }

    func directoryView(_ view: DirectoryView, open path: String, isDirectory: Bool) {
        let block = hosts.directoryBlock(for: path, on: view.block.host)
        let d = Self.disposition ?? .goTo
        if isDirectory, d == .system, view.block.host == host.host {
            NSWorkspace.shared.open(URL(fileURLWithPath: path))
        } else if isDirectory, d == .over {
            // ⌥: the folder's listing over this one.
            showOver(block, lens: .directory, over: view.placement, context: "subfolder")
        } else if isDirectory, d != .goTo {
            // ⌘: the folder's listing beside this one, which stays.
            show(block, lens: .directory, .besideOpener(view.placement), context: "subfolder")
        } else if isDirectory {
            // A folder takes the listing's place, in the same tile; the one
            // it was is the tile's to go back to (⌘[).
            goOn(view.placement, from: view.block, to: block, lens: .directory)
        } else {
            open(path, from: view.placement)
        }
    }

    func directoryView(_ view: DirectoryView, history direction: Int) -> Bool {
        walkTrail(view.placement, of: view.block, lens: .directory, direction)
    }

    func directoryViewRefresh(_ view: DirectoryView) {
        hosts.propose(.listDirectory(view.block))
    }

    func directoryView(_ view: DirectoryView, watch folders: Set<String>, changed: @escaping (Set<String>) -> Void) -> Bool {
        guard let client = hosts.client(of: view.block), client.isConnected, client.watchesFolders else { return false }
        client.watchFolders(for: view, folders, changed: changed)
        return true
    }

    func directoryViewUnwatch(_ view: DirectoryView) {
        hosts.client(of: view.block)?.unwatchFolders(for: view)
    }

    func directoryView(_ view: DirectoryView, watchPresence changed: (() -> Void)?) {
        if let changed { hosts.watch(kinds: [.terminal, .agent], by: view, changed) } else { hosts.unwatchKinds(by: view) }
    }

    func directoryView(_ view: DirectoryView, list path: String, done: @escaping ([DirectoryEntry]?) -> Void) {
        guard let client = hosts.client(of: view.block) else { return done(nil) }
        client.listFolder(path, done: done)
    }

    func directoryView(_ view: DirectoryView, tree path: String, done: @escaping ([DirectoryEntry]?, Bool) -> Void) {
        guard let client = hosts.client(of: view.block) else { return done(nil, false) }
        client.listTree(path, done: done)
    }

    func directoryViewIsLocal(_ view: DirectoryView) -> Bool {
        hosts.client(of: view.block)?.transport.isLocal ?? true
    }

    func directoryView(_ view: DirectoryView, receive items: [DroppedItem], into folder: String, moving: Bool) {
        copy(items, into: folder, on: view.block.host, moving: moving)
    }

    func directoryView(_ view: DirectoryView, download path: String, isDirectory: Bool, to url: URL, done: @escaping (String?) -> Void) {
        fetch(path, on: view.block.host, to: url, then: done)
    }

    /// Another host's file or folder fetched to `url`, going in the
    /// transfers, Show in Finder once it's in; `then` with what went
    /// wrong, if anything.
    func fetch(_ path: String, on h: HostID, to url: URL, replace: Bool = true, then: ((String?) -> Void)? = nil) {
        guard let c = hosts.client(h) else { then?("the host isn't attached"); return }
        let into = url.deletingLastPathComponent()
        let detail = "from \(hosts.label(of: h)) to " + (into.lastPathComponent == "Downloads" ? "Downloads" : into.lastPathComponent)
        let item = Transfers.shared.run(url.lastPathComponent, detail: detail, symbol: "arrow.down") { progress, finished in
            Transfer.download(path, on: c, to: url, replace: replace, progress: progress, done: finished)
        } then: { error in then?(error) }
        item.action = ("Show in Finder", { NSWorkspace.shared.activateFileViewerSelecting([url]) })
    }

    func directoryView(_ view: DirectoryView, menuFor path: String, isDirectory: Bool) -> NSMenu? {
        let on = view.block.host
        let menu = NSMenu()
        menu.addItem(ClosureMenuItem("Open", symbol: "arrow.up.forward.app") { [weak self, weak view] in
            guard let view else { return }
            self?.directoryView(view, open: path, isDirectory: isDirectory)
        })
        if let (block, lens) = pathBlock(path, isDirectory: isDirectory, on: on) {
            menu.addItem(ClosureMenuItem("Open Beside", symbol: "rectangle.split.2x1") { [weak self, weak view] in
                guard let view else { return }
                self?.show(block, lens: lens, .besideOpener(view.placement), context: isDirectory ? "subfolder" : "in the folder")
            })
        }
        menu.addItem(.separator())
        if isDirectory {
            menu.addItem(ClosureMenuItem("Find in This Folder…", symbol: "magnifyingglass") { [weak self, weak view] in
                self?.findInFolder(path, on: on, from: view?.placement)
            })
        }
        if !isDirectory { menu.addItem(openWithItem(path, on: on)) }
        if on == host.host {
            menu.addItem(ClosureMenuItem("Reveal in Finder", symbol: "folder") {
                NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
            })
        } else {
            menu.addItem(ClosureMenuItem("Download", symbol: "arrow.down.circle") { [weak self] in self?.download(path, on: on) })
        }
        menu.addItem(ClosureMenuItem("Copy Path", symbol: "doc.on.clipboard") {
            NSPasteboard.copy(path)
        })
        return menu
    }

    func directoryView(_ view: DirectoryView, make path: String, isDirectory: Bool, done: @escaping (String?) -> Void) {
        guard let c = hosts.client(of: view.block) else { toast.say("The host isn't attached."); return done("not attached") }
        let said = { [weak self] (error: String?) in
            if error == "exists" { self?.toast.say("“\(path.lastPathComponent)” is there already.") } else if let error { self?.toast.say(error) }
            done(error)
        }
        if isDirectory {
            // (Made with those on the way; one there already, left as it is.)
            return c.propose(.makeFolder(path: path)) { error in DispatchQueue.main.async { said(error) } }
        }
        // A file: an empty one sent up, made only if there's none there
        // (as a dropped one is), then opened to be written in.
        let empty = FileManager.default.temporaryDirectory.appendingPathComponent("manifold-new-\(UUID().uuidString)")
        guard FileManager.default.createFile(atPath: empty.path, contents: nil) else { return said("couldn't make a file here to send") }
        Transfer.upload(empty, to: path, on: c, replace: false) { [weak self, weak view] error in
            try? FileManager.default.removeItem(at: empty)
            said(error)
            guard error == nil, let self, let view else { return }
            self.open(path, from: view.placement)
        }
    }

    func directoryView(_ view: DirectoryView, rename path: String, to: String, done: @escaping (String?) -> Void) {
        guard let c = hosts.client(of: view.block) else { toast.say("The host isn't attached."); return done("not attached") }
        c.propose(.movePath(from: path, to: to, replace: false)) { [weak self] error in
            DispatchQueue.main.async {
                if error == "exists" { self?.toast.say("There's a “\(to.lastPathComponent)” there already.") } else if let error { self?.toast.say(error) }
                done(error)
            }
        }
    }

    func directoryView(_ view: DirectoryView, trash paths: [String], done: @escaping (String?) -> Void) {
        guard let c = hosts.client(of: view.block) else { toast.say("The host isn't attached."); return done("not attached") }
        let on = view.block.host
        let trash = on == host.host ? "the Trash" : hosts.label(of: on) + "'s trash"
        let what = paths.count == 1 ? "“\(paths[0].lastPathComponent)”" : "\(paths.count) items"
        c.propose(.trashPaths(paths: paths)) { [weak self] error in
            DispatchQueue.main.async {
                if let error { self?.toast.say(error) } else { self?.toast.say("Moved \(what) to \(trash).") }
                done(error)
            }
        }
    }

    func directoryView(_ view: DirectoryView, menuFor entries: [(path: String, isDirectory: Bool)]) -> NSMenu? {
        let on = view.block.host, n = entries.count
        let menu = NSMenu()
        menu.addItem(ClosureMenuItem("Open \(n) Items Beside", symbol: "rectangle.split.2x1") { [weak self, weak view] in
            guard let self, let view else { return }
            self.openBeside(entries, on: on, from: view.placement)
        })
        menu.addItem(.separator())
        if on == host.host {
            menu.addItem(ClosureMenuItem("Reveal \(n) Items in Finder", symbol: "folder") {
                NSWorkspace.shared.activateFileViewerSelecting(entries.map { URL(fileURLWithPath: $0.path) })
            })
        } else {
            menu.addItem(ClosureMenuItem("Download \(n) Items", symbol: "arrow.down.circle") { [weak self] in
                for e in entries { self?.download(e.path, on: on) }
            })
        }
        menu.addItem(ClosureMenuItem("Copy \(n) Paths", symbol: "doc.on.clipboard") {
            NSPasteboard.copy(entries.map(\.path).joined(separator: "\n"))
        })
        return menu
    }

    /// Files and folders opened beside a tile: a column of their own to
    /// its right, each under the one before, as several dropped on the
    /// grid are; one Manifold doesn't open, in its own app (this Mac's).
    func openBeside(_ entries: [(path: String, isDirectory: Bool)], on: HostID, from placement: PlacementID) {
        var slot = (column: (arrangement?.columnIndex(of: placement) ?? 0) + 1, at: 0, newColumn: true)
        for e in entries {
            guard let (block, lens) = pathBlock(e.path, isDirectory: e.isDirectory, on: on) else {
                if on == host.host { NSWorkspace.shared.open(URL(fileURLWithPath: e.path)) }
                continue
            }
            // (One with a tile here already is gone to, not placed: the next takes its slot.)
            let had = arrangement?.tile(of: block, lens: lens) != nil
            place(block, lens: lens, column: slot.column, at: slot.at, newColumn: slot.newColumn)
            if !had { slot = (slot.column, slot.newColumn ? 1 : slot.at + 1, false) }
        }
    }

    // MARK: Files between hosts

    /// Files and folders put in a folder on a host: this Mac's, another
    /// app's (a promised file), or entries of any host's — copied within
    /// the host by the host, or straight from one host to the other. All
    /// of them one row at the bottom of the sidebar, with how far they've
    /// got (§8); what's there already is asked about, once for all, before
    /// it's written over.
    func copy(_ items: [DroppedItem], into folder: String, on target: HostID, replacing: Bool = false, moving: Bool = false) {
        guard let c = hosts.client(target) else { return NSSound.beep() }
        let label = hosts.label(of: target) + ":" + Self.shortPlace(folder)
        let jobs: [Transfer.Job] = items.map { item in
            let dest = folder + "/" + Self.name(of: item)
            return { [weak self] progress, done in
                switch item {
                case let .promised(r):
                    // Written here by the app that has it, then sent up.
                    Promises.receive([r]) { urls in
                        guard !urls.isEmpty else { return done("the file never came") }
                        let ups: [Transfer.Job] = urls.map { u in
                            { p, d in Transfer.upload(u, to: folder + "/" + u.lastPathComponent, on: c, replace: replacing, progress: p, done: d) }
                        }
                        Transfer.batch(ups, progress: progress) { results in done(results.compactMap { $0 }.first) }
                    }
                    return nil
                case let .local(url):
                    return Transfer.upload(url, to: dest, on: c, replace: replacing, progress: progress, done: done)
                case let .entry(host, path, _) where moving && host == target:
                    // Within the host: moved there, as the Finder moves within a disk.
                    c.propose(.movePath(from: path, to: dest, replace: replacing)) { error in done(error) }
                    return nil
                case let .entry(host, path, _):
                    guard let source = self?.hosts.client(host) else { done("its host isn't attached"); return nil }
                    return Transfer.copy(path, on: source, to: dest, on: c, replace: replacing, progress: progress, done: done)
                }
            }
        }
        let sources = Set(items.compactMap { if case let .entry(h, _, _) = $0 { return h } else { return nil } })
        let from = sources.count == 1 && sources.first != target ? hosts.label(of: sources.first!) + " → " : ""
        var results: [String?] = []
        Transfers.shared.run(items.count == 1 ? Self.name(of: items[0]) : "\(items.count) items",
                             detail: (moving ? "moving to " : from.isEmpty ? "to " : from) + label,
                             symbol: moving ? "arrow.right" : sources.isEmpty ? "arrow.up" : "doc.on.doc") { progress, done in
            Transfer.batch(jobs, progress: progress) { r in
                results = r
                // "Already there" isn't a failure of the whole: asked about below.
                done(r.compactMap { $0 }.first { $0 != "exists" })
            }
        } then: { [weak self] _ in
            guard let self else { return }
            self.hosts.propose(.listDirectory(self.hosts.directoryBlock(for: folder, on: target)))
            let existing = zip(items, results).filter { $0.1 == "exists" }.map(\.0)
            guard !existing.isEmpty else { return }
            self.confirm(existing.count == 1 ? "“\(Self.name(of: existing[0]))” is already in \(folder.lastPathComponent)" : "\(existing.count) items are already in \(folder.lastPathComponent)",
                         "Replace what's there with what was dropped?", button: "Replace", cancel: "Leave Them") { [weak self] in
                self?.copy(existing, into: folder, on: target, replacing: true, moving: moving)
            }
        }
    }

    /// This Mac's files dropped on another host's terminal: sent to the
    /// shell's folder (each a name of its own there, nothing written over),
    /// their paths there given back to be typed.
    func upload(_ urls: [URL], toShellOf block: BlockID, done: @escaping ([String]) -> Void) {
        guard let c = hosts.client(of: block), let folder = hosts.block(block)?.terminal?.cwd else { return NSSound.beep() }
        let label = hosts.label(of: block.host) + ":" + Self.shortPlace(folder)
        c.listFolder(folder) { entries in
            var taken = Set((entries ?? []).map(\.name))
            let dests: [String] = urls.map { u in
                let name = Self.freeName(u.lastPathComponent, taken: taken)
                taken.insert(name)
                return folder + "/" + name
            }
            let jobs: [Transfer.Job] = zip(urls, dests).map { u, dest in
                { p, d in Transfer.upload(u, to: dest, on: c, replace: false, progress: p, done: d) }
            }
            var results: [String?] = []
            Transfers.shared.run(urls.count == 1 ? urls[0].lastPathComponent : "\(urls.count) items", detail: "to \(label)", symbol: "arrow.up") { progress, finished in
                Transfer.batch(jobs, progress: progress) { r in
                    results = r
                    finished(r.compactMap { $0 }.first)
                }
            } then: { _ in
                // The paths of those that went, typed.
                done(zip(dests, results).filter { $0.1 == nil }.map(\.0))
            }
        }
    }

    /// A folder as a row has room for it: from home, else its last two
    /// folders.
    static func shortPlace(_ folder: String) -> String {
        let p = folder.abbreviatingHome
        guard p.count > 28 else { return p }
        let parts = p.split(separator: "/")
        return "…/" + parts.suffix(2).joined(separator: "/")
    }

    /// A name not among `taken`: as it is, else "name 2.ext", "name 3.ext"…
    static func freeName(_ name: String, taken: Set<String>) -> String {
        guard taken.contains(name) else { return name }
        let ext = name.pathExtension, base = (name as NSString).deletingPathExtension
        var n = 2
        while true {
            let candidate = base + " \(n)" + (ext.isEmpty ? "" : "." + ext)
            if !taken.contains(candidate) { return candidate }
            n += 1
        }
    }

    private static func name(of item: DroppedItem) -> String {
        switch item {
        case let .local(url): url.lastPathComponent
        case let .entry(_, path, _): path.lastPathComponent
        case let .promised(r): r.fileNames.first ?? "file"
        }
    }

    /// Another host's file or folder, fetched to Downloads (a name of its
    /// own if one's there), shown in the Finder when it's in.
    func download(_ path: String, on h: HostID) {
        guard hosts.client(h) != nil, let downloads = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first else { return NSSound.beep() }
        let taken = Set((try? FileManager.default.contentsOfDirectory(atPath: downloads.path)) ?? [])
        fetch(path, on: h, to: downloads.appendingPathComponent(Self.freeName(path.lastPathComponent, taken: taken)), replace: false)
    }

    /// Open With ▸: the apps that open the file, its default first; on
    /// another host, a copy opened here and sent back when it's saved.
    func openWithItem(_ path: String, on h: HostID) -> NSMenuItem {
        let local = h == host.host
        let item = NSMenuItem(title: local ? "Open With" : "Open Locally With", action: nil, keyEquivalent: "")
        item.setSymbol("arrow.up.right.square", size: 12)
        let menu = NSMenu()
        let type = UTType(filenameExtension: path.pathExtension) ?? .data
        let ws = NSWorkspace.shared
        var apps = ws.urlsForApplications(toOpen: type)
        if let def = ws.urlForApplication(toOpen: type) { apps.removeAll { $0 == def }; apps.insert(def, at: 0) }
        for (i, app) in apps.prefix(20).enumerated() {
            let name = FileManager.default.displayName(atPath: app.path).replacingOccurrences(of: ".app", with: "")
            let entry = ClosureMenuItem(i == 0 ? "\(name) (default)" : name, symbol: nil) { [weak self] in self?.openWith(app, path, on: h) }
            entry.image = ws.icon(forFile: app.path)
            entry.image?.size = NSSize(width: 16, height: 16)
            menu.addItem(entry)
            if i == 0, apps.count > 1 { menu.addItem(.separator()) }
        }
        if apps.isEmpty { menu.addItem(NSMenuItem(title: "No App Opens It", action: nil, keyEquivalent: "")) }
        item.submenu = menu
        return item
    }

    func openWith(_ app: URL, _ path: String, on h: HostID) {
        let config = NSWorkspace.OpenConfiguration()
        guard h != host.host else {
            NSWorkspace.shared.open([URL(fileURLWithPath: path)], withApplicationAt: app, configuration: config)
            return
        }
        guard let c = hosts.client(h) else { return NSSound.beep() }
        LocalCopies.shared.open(path, on: c, label: hosts.label(of: h)) { [weak self] url, error in
            guard let url else { self?.toast.say("Couldn't fetch \(path.lastPathComponent): \(error ?? "")", .long); return }
            self?.toast.say("\(path.lastPathComponent) opened here; saved, it goes back to \(self?.hosts.label(of: h) ?? "its host")")
            NSWorkspace.shared.open([url], withApplicationAt: app, configuration: config)
        }
        LocalCopies.shared.onSentBack = { [weak self] name, label, error in
            self?.toast.say(error.map { "Couldn't send \(name) back to \(label): \($0)" } ?? "Sent \(name) back to \(label)", .brief)
        }
    }

    /// A file here, as it is; one on another host, fetched afresh (4 MB at
    /// most: a preview, gone past as the selection moves on, and stopped
    /// then) into a folder by host and path, written off the main thread.
    func directoryView(_ view: DirectoryView, localURLFor path: String, done: @escaping (URL?) -> Void) -> () -> Void {
        guard let client = hosts.client(of: view.block) else { done(nil); return {} }
        if client.transport.isLocal { done(URL(fileURLWithPath: path)); return {} }
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("manifold-previews/\(view.block.host.raw)" + path.deletingLastPathComponent)
        let url = dir.appendingPathComponent(path.lastPathComponent)
        return client.readBytes(path: path, limit: 4 << 20) { data in
            guard let data else { return done(nil) }
            DispatchQueue.global(qos: .userInitiated).async {
                try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                let written = (try? data.write(to: url)) != nil
                DispatchQueue.main.async { done(written ? url : nil) }
            }
        }
    }
}
