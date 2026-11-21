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
        func at(_ b: Block, pinned: Bool) -> Presence {
            let cwd = b.terminal?.cwd ?? b.path ?? b.place
            let where_ = cwd.map { project.holds($0) ? project.relative($0) : $0.abbreviatingHome } ?? ""
            let doing = b.statusRecord?.msg ?? b.terminal?.commands?.last(where: { $0.isRunning })?.text
            var p = Presence(block: b.id, title: Self.linkTitle(b), symbol: Theme.symbolName(for: b),
                             detail: [b.agent?.name, doing, where_.isEmpty ? nil : where_ + "/"].compactMap { $0 }.joined(separator: " · "),
                             here: shownHere.contains(b.id), card: cardContent(for: b.id))
            p.pinned = pinned
            return p
        }
        // What's pinned in it (§2.6): its agents first, what most wants you
        // of them first; then the rest, in the order pinned.
        let pins = pinned(in: project).compactMap { hosts.block($0) }
        let agents = pins.filter { $0.agent != nil }.enumerated().sorted { a, b in
            let (x, y) = (Self.attention(a.element), Self.attention(b.element))
            return x != y ? x > y : a.offset < b.offset
        }.map(\.element)
        for b in agents + pins.filter({ $0.agent == nil }) { out.append(at(b, pinned: true)) }
        let pinnedIDs = Set(pins.map(\.id))
        // Terminals and agents with a shell there, what each is doing.
        for b in client.node.blocks where (b.kind == .terminal || b.kind == .agent) && !pinnedIDs.contains(b.id) {
            guard let t = b.terminal, t.pid != nil || t.dormantSince == nil, let cwd = t.cwd, project.holds(cwd) else { continue }
            out.append(at(b, pinned: false))
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
            for (id, about) in notes.sorted(by: { $0.value < $1.value }) where !pinnedIDs.contains(id) {
                guard let n = client.node.block(id) else { continue }
                out.append(Presence(block: id, title: n.displayTitle, symbol: Theme.symbolName(for: n), detail: "about " + about,
                                    here: shownHere.contains(id), card: cardContent(for: id)))
            }
        }
        // Its latest open threads (§3.12), each its card.
        let open = hosts.threads(inProject: project.root, on: client.host).filter { $0.thread?.resolved != true }
            .sorted { ($0.thread?.lastActivity ?? $0.created) > ($1.thread?.lastActivity ?? $1.created) }
        for t in open.prefix(5) {
            var p = Presence(block: t.id, title: t.thread?.title ?? "A thread", symbol: Theme.symbolName(for: t), detail: "",
                             here: false, card: cardContent(for: t.id))
            p.isThread = true
            out.append(p)
        }
        // Pinned first; then those in the workspace shown, each kind as it was.
        return out.filter(\.pinned) + out.filter { !$0.pinned && $0.here } + out.filter { !$0.pinned && !$0.here }
    }

    /// Things dropped on a project's sidebar: each its block (a file's or a
    /// page's made if it has none), pinned in it.
    func pinDropped(_ addresses: [String], in project: Project) {
        var pinned: [String] = []
        for address in addresses {
            guard let id = pinnable(address), id != project.block else { continue }
            setPinned(id, inProject: project, true)
            pinned.append(hosts.block(id).map { $0.agent != nil ? AgentLook.name(of: $0) : Self.linkTitle($0) } ?? "it")
        }
        if pinned.isEmpty { NSSound.beep() } else { toast.say("Pinned in \(project.name): " + pinned.joined(separator: ", "), .brief) }
    }

    /// The block an address names, to pin: a block's own; a file's or a
    /// folder's block on its host, made if it has none; a page's, made.
    func pinnable(_ address: String) -> BlockID? {
        if let (id, _) = BlockID.link(address), hosts.block(id) != nil { return id }
        if case let .file(h, path, _)? = ManifoldAddress.parse(address) {
            let p = path.count > 1 && path.hasSuffix("/") ? String(path.dropLast()) : path
            if path.hasSuffix("/") { return hosts.directoryBlock(for: p, on: h) }
            let kind = BlockKind.forFile(p)
            if kind == .image || kind == .pdf, let c = hosts.client(h) { return c.mediaBlock(for: p, kind: kind) }
            return hosts.textBlock(for: p, on: h)
        }
        if let url = URL(string: address), ["http", "https"].contains(url.scheme ?? "") {
            if let b = hosts.blocks.first(where: { $0.kind == .web && $0.web?.url == address }) { return b.id }
            return host.newWeb(url: address)
        }
        return nil
    }

    /// How much an agent wants you, for its place in a list: waiting on
    /// you or failed; done and not read; working; idle; asleep.
    static func attention(_ b: Block) -> Int {
        guard agentRuns(b) else { return 0 }
        switch b.statusRecord?.state {
        case .blocked?, .error?: return 4
        case .done? where b.statusRecord?.read != true: return 3
        case .working?: return 2
        default: return 1
        }
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
        case let .newAgentOf(command):
            _ = client.newProjectAgent(root: project.root, command: command)
        case let .pin(addresses):
            pinDropped(addresses, in: project)
        case .threads:
            guard let pb = project.block else { return NSSound.beep() }
            show(pb, lens: .threads, .besideOpener(view.placement), context: "\(project.name)'s threads")
        }
    }

    /// An agent made in a project (§3.12): pinned in it, started with
    /// nothing showing it — its card under the project's Pinned, its name its own.
    @discardableResult
    func newProjectAgent(in project: Project, on client: HostClient) -> BlockID {
        let usual = desk.settings.agentCommand
        let command = AgentCatalog.agent(inCommand: usual) != nil ? usual : "claude"
        return client.newProjectAgent(root: project.root, command: command)
    }

    /// A project's agent's menu, wherever its pill is: show it, rename it,
    /// delete it (with Undo, as any block).
    func projectAgentMenu(_ id: BlockID) -> NSMenu? {
        guard let b = hosts.block(id) else { return nil }
        let name = AgentLook.name(of: b)
        let menu = NSMenu()
        menu.addItem(ClosureMenuItem("Show \(name)", symbol: "rectangle.on.rectangle") { [weak self] in self?.arrive(id, from: nil) })
        menu.addItem(ClosureMenuItem("Rename…", symbol: "character.cursor.ibeam") { [weak self] in self?.renameProjectAgent(id) })
        if let item = threadsItem(id) { menu.addItem(item) }
        if let p = project(pinning: id) {
            menu.addItem(ClosureMenuItem("Unpin from Project “\(p.name)”", symbol: "bookmark.slash") { [weak self] in self?.setPinned(id, inProject: p, false) })
        } else if let s = selected, isPinned(id, in: s) {
            menu.addItem(pinItem(id, in: s))
        }
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

    /// An agent's card (§3.12), wherever an agent is pointed at — its
    /// pill, a row, a reference: the block's card (`showBlockCard`), which
    /// for an agent says what `agentCard` does.
    func showAgentCard(_ id: BlockID, beside rect: NSRect, in window: NSWindow) {
        showBlockCard(id, beside: rect, in: window, delay: 0.35)
    }

    /// What an agent's card says (§3.12): its name; what kind of agent it
    /// is, the project it lives in, the host; and what it's doing — the ask
    /// it's working on (a thread's said as the thread), waiting on you for
    /// what, done or idle with what it was last asked and said, or asleep.
    func agentCard(_ b: Block) -> (title: String, detail: String, body: String) {
        let id = b.id
        let t = b.terminal
        let turn = t?.turns?.last
        let now = Date()
        // What it was asked, a thread's said as the thread, the references in it
        // by their names ("[Quill](manifold:…)" as Quill).
        func named(_ text: String) -> String {
            var out = text.replacingOccurrences(of: #"\[([^\]]+)\]\(manifold:[^)\s]+\)"#, with: "$1", options: .regularExpression)
            for m in TextLinks.bareReference.matches(in: out, range: NSRange(location: 0, length: (out as NSString).length)).reversed() {
                let ref = (out as NSString).substring(with: m.range)
                guard let (bid, _) = BlockID.link(ref), let rb = hosts.block(bid) else { continue }
                out = (out as NSString).replacingCharacters(in: m.range, with: rb.agent != nil ? AgentLook.name(of: rb) : Self.linkTitle(rb))
            }
            return out
        }
        func asked(_ p: String) -> String { Block.oneLine(named(AgentConversation.notification(p) ?? ThreadText.askShown(p) ?? p), max: 200) }
        func ago(_ s: Stamp?) -> String { BlockSummary.since(s, now: now) ?? "" }
        var detail = [b.agent?.name ?? "Agent", (project(holding: id) ?? project(of: id)).map { "in \($0.name)" }].compactMap { $0 }.joined(separator: " · ")
        if id.host != host.host { detail += " · on \(hosts.label(of: id.host))" }
        var lines: [String] = []
        let last = turn.map { "Last asked \(ago($0.began)): \(asked($0.prompt))" }
        let said = turn.flatMap { $0.saidLines(nil).first }.map { "Said: " + Block.oneLine($0, max: 200) }
        if !Self.agentRuns(b) {
            lines.append("Asleep — asked, or shown, it starts again where it left off.")
            lines += [last, said].compactMap { $0 }
        } else {
            let r = b.statusRecord
            switch r?.state {
            case .working?:
                lines.append(turn.map { "Working\($0.isRunning ? " since " + ago($0.began) : ""): " + asked($0.prompt) } ?? "Working")
                if let m = r?.msg, !m.isEmpty, turn.map({ !$0.prompt.hasPrefix(m) }) ?? true { lines.append("Now: " + Block.oneLine(m, max: 160)) }
            case .blocked?:
                lines.append("Waiting on you: " + (r?.msg.map { Block.oneLine($0, max: 160) } ?? "a question"))
                if let turn { lines.append("On: " + asked(turn.prompt)) }
            case .done?:
                lines.append((r?.read == true ? "Done " : "Done, not read — ") + ago(turn?.ended ?? r?.at))
                lines += [turn.map { "Asked: " + asked($0.prompt) }, said].compactMap { $0 }
            case .error?:
                lines.append("Failed" + (r?.msg.map { ": " + Block.oneLine($0, max: 160) } ?? ""))
                if let last { lines.append(last) }
            default:
                lines.append("Idle — ask it in a thread, or click to show it.")
                lines += [last, said].compactMap { $0 }
            }
        }
        return (AgentLook.name(of: b), detail, lines.joined(separator: "\n"))
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
        // Its pins too: a link from its block is its block changing.
        if let changed { hosts.watch(kinds: [.terminal, .agent, .project, .thread], by: view, changed) } else { hosts.unwatchKinds(by: view) }
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
