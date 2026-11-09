import AppKit
import ManifoldCore
import WebKit
import ManifoldSyntax
import UniformTypeIdentifiers
import PDFKit

extension MainWindowController: DirectoryViewDelegate {
    // MARK: Projects (§2.6)

    func directoryViewProject(_ view: DirectoryView) -> Project? {
        guard let path = hosts.block(view.block)?.path, let desk = hosts.client(view.block.host)?.desk else { return nil }
        return desk.projects.first { $0.root == path || $0.alias == path }
    }

    func directoryViewParentProject(_ view: DirectoryView) -> Project? {
        guard let path = hosts.block(view.block)?.path, let desk = hosts.client(view.block.host)?.desk,
              let p = desk.project(holding: path), p.root != path, p.alias != path else { return nil }
        return p
    }

    func directoryView(_ view: DirectoryView, makeProject: Bool) {
        guard let client = hosts.client(view.block.host), let path = hosts.block(view.block)?.path else { return NSSound.beep() }
        let proposal: Proposal = makeProject
            ? .project(Project(root: path, made: Stamp(wall: Int64(Date().timeIntervalSince1970 * 1000))))
            : .unproject(root: directoryViewProject(view)?.root ?? path)
        client.propose(proposal) { [weak self] error in
            if let error { self?.toast.show(error, action: "OK", for: 6) {} }
        }
    }

    func directoryView(_ view: DirectoryView, gitFor project: Project) -> BlockID? {
        hosts.client(view.block.host)?.projectGitBlock(for: project)
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
        guard let client = hosts.client(view.block.host) else { return nil }
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
        guard let client = hosts.client(view.block.host) else { return done(nil) }
        client.languages(project.root, done: done)
    }

    func directoryView(_ view: DirectoryView, presenceIn project: Project) -> [Presence] {
        guard let client = hosts.client(view.block.host) else { return [] }
        var out: [Presence] = []
        let shownHere = Set(arrangement?.placements.map(\.block) ?? [])
        // Terminals and agents with a shell there, what each is doing.
        for b in client.node.blocks where b.kind == .terminal || b.kind == .agent {
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
        guard let client = hosts.client(view.block.host) else { return NSSound.beep() }
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
                if case .error(let m) = result { self?.toast.show(m, action: "OK", for: 6) {} }
            }
        }
    }

    /// "?text" in a folder's filter: the files under it searched, the
    /// search's tile beside the folder's.
    func directoryView(_ view: DirectoryView, searchContents text: String) {
        guard let client = hosts.client(view.block.host), let root = hosts.block(view.block)?.path else { return }
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

    func directoryView(_ view: DirectoryView, list path: String, done: @escaping ([DirectoryEntry]?) -> Void) {
        guard let client = hosts.client(view.block.host) else { return done(nil) }
        client.listFolder(path, done: done)
    }

    func directoryView(_ view: DirectoryView, tree path: String, done: @escaping ([DirectoryEntry]?, Bool) -> Void) {
        guard let client = hosts.client(view.block.host) else { return done(nil, false) }
        client.listTree(path, done: done)
    }

    func directoryViewIsLocal(_ view: DirectoryView) -> Bool {
        hosts.client(view.block.host)?.transport.isLocal ?? true
    }

    func directoryView(_ view: DirectoryView, receive items: [DroppedItem], into folder: String, moving: Bool) {
        copy(items, into: folder, on: view.block.host, moving: moving)
    }

    func directoryView(_ view: DirectoryView, download path: String, isDirectory: Bool, to url: URL, done: @escaping (String?) -> Void) {
        guard let c = hosts.client(view.block.host) else { return done("the host isn't attached") }
        let item = Transfers.shared.run(url.lastPathComponent, detail: "from \(hosts.label(of: view.block.host)) to \(url.deletingLastPathComponent().lastPathComponent)", symbol: "arrow.down") { progress, finished in
            Transfer.download(path, on: c, to: url, progress: progress, done: finished)
        } then: { error in done(error) }
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
            let alert = NSAlert()
            alert.messageText = existing.count == 1 ? "“\(Self.name(of: existing[0]))” is already in \(folder.lastPathComponent)" : "\(existing.count) items are already in \(folder.lastPathComponent)"
            alert.informativeText = "Replace what's there with what was dropped?"
            alert.addButton(withTitle: "Replace")
            alert.addButton(withTitle: "Leave Them")
            if let window = self.window { alert.beginSheetModal(for: window) { [weak self] r in
                if r == .alertFirstButtonReturn { self?.copy(existing, into: folder, on: target, replacing: true, moving: moving) }
            } }
        }
    }

    /// This Mac's files dropped on another host's terminal: sent to the
    /// shell's folder (each a name of its own there, nothing written over),
    /// their paths there given back to be typed.
    func upload(_ urls: [URL], toShellOf block: BlockID, done: @escaping ([String]) -> Void) {
        guard let c = hosts.client(block.host), let folder = hosts.block(block)?.terminal?.cwd else { return NSSound.beep() }
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
        guard let c = hosts.client(h), let downloads = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first else { return NSSound.beep() }
        var url = downloads.appendingPathComponent(path.lastPathComponent)
        var n = 2
        while FileManager.default.fileExists(atPath: url.path) {
            let ext = path.pathExtension
            url = downloads.appendingPathComponent((path.lastPathComponent as NSString).deletingPathExtension + " \(n)" + (ext.isEmpty ? "" : "." + ext))
            n += 1
        }
        let item = Transfers.shared.run(url.lastPathComponent, detail: "from \(hosts.label(of: h)) to Downloads", symbol: "arrow.down") { progress, done in
            Transfer.download(path, on: c, to: url, replace: false, progress: progress, done: done)
        }
        item.action = ("Show in Finder", { NSWorkspace.shared.activateFileViewerSelecting([url]) })
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
            guard let url else { self?.toast.show("Couldn't fetch \(path.lastPathComponent): \(error ?? "")", action: "OK", for: 10) {}; return }
            self?.toast.show("\(path.lastPathComponent) opened here; saved, it goes back to \(self?.hosts.label(of: h) ?? "its host")", action: "OK", for: 6) {}
            NSWorkspace.shared.open([url], withApplicationAt: app, configuration: config)
        }
        LocalCopies.shared.onSentBack = { [weak self] name, label, error in
            self?.toast.show(error.map { "Couldn't send \(name) back to \(label): \($0)" } ?? "Sent \(name) back to \(label)", action: "OK", for: 4) {}
        }
    }

    /// A file here, as it is; one on another host, fetched afresh (4 MB at
    /// most: a preview, gone past as the selection moves on, and stopped
    /// then) into a folder by host and path, written off the main thread.
    func directoryView(_ view: DirectoryView, localURLFor path: String, done: @escaping (URL?) -> Void) -> () -> Void {
        guard let client = hosts.client(view.block.host) else { done(nil); return {} }
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
