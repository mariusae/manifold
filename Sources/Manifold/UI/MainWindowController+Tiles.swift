import AppKit
import ManifoldCore
import WebKit
import ManifoldSyntax
import UniformTypeIdentifiers
import PDFKit

extension MainWindowController: NotebookViewDelegate {
    func notebook(_ view: NotebookView, edit: NotebookEdit) {
        hosts.client(of: view.block)?.propose(.editNotebook(block: view.block, edit: edit))
    }

    func notebook(_ view: NotebookView, run cells: [String]) {
        hosts.client(of: view.block)?.propose(.runCells(block: view.block, cells: cells))
    }

    func notebookInterrupt(_ view: NotebookView) {
        hosts.client(of: view.block)?.propose(.interruptNotebook(block: view.block))
    }

    func notebookRestart(_ view: NotebookView) {
        hosts.client(of: view.block)?.propose(.restartNotebook(block: view.block))
    }

    func notebookStart(_ view: NotebookView) {
        guard hosts.block(view.block)?.notebook?.pid == nil else { return }
        hosts.client(of: view.block)?.propose(.startNotebook(block: view.block))
    }

    /// As a terminal's ⌘-click: a path from where the shell is, an address
    /// in the browser, `file:line:column` at that place.
    func notebook(_ view: NotebookView, open target: String) {
        open(target, from: view.placement, as: Self.commandClick(over: false))
    }

    func notebook(_ view: NotebookView, linkedFrom block: BlockID) { link(block, to: view.block) }

    /// A cell's output as an output block, as a terminal's command's is:
    /// the one made for this run of it again, if there is one.
    func notebook(_ view: NotebookView, openOutput cell: NotebookCell) {
        guard let client = hosts.client(of: view.block) else { return }
        let line = cell.source.split(separator: "\n", omittingEmptySubsequences: false).first.map(String.init) ?? ""
        let state = OutputState(source: view.block, line: line, status: cell.status, ran: cell.ran, ended: cell.ended, output: cell.output ?? "")
        let context = "cell \(cell.count.map(String.init) ?? "output")"
        if let b = client.node.blocks.first(where: { $0.kind == .output && $0.output?.source == view.block && $0.output?.line == line && $0.output?.ran == cell.ran }) {
            if b.output != state { client.append([.output(state)], to: .block(b.id)) }
            return show(b.id, lens: .output, .besideOpener(view.placement), context: context)
        }
        let id = BlockID(host: view.block.host)
        client.append([.create(kind: .output, title: nil, path: nil), .output(state)], to: .block(id))
        show(id, lens: .output, .besideOpener(view.placement), context: context)
    }
}

extension MainWindowController: MediaViewDelegate {
    func mediaView(_ view: MediaView, needsBytes progress: @escaping (Int64, Int64?) -> Void, done: @escaping (Data?) -> Void) {
        guard let client = hosts.client(of: view.block) else { return done(nil) }
        client.readBytes(view.block, progress: progress, done: done)
    }

    func mediaViewHostName(_ view: MediaView) -> String? {
        view.block.host == host.host ? nil : hosts.label(of: view.block.host)
    }
}

extension MainWindowController: ProcessViewDelegate {
    func processViewRefresh(_ view: ProcessView) {
        hosts.propose(.processes(block: view.block))
    }

    func processView(_ view: ProcessView, goTo block: BlockID) { arrive(block, from: view.placement) }

    func processView(_ view: ProcessView, signal pid: Int32, _ signal: Int32) {
        hosts.client(of: view.block)?.propose(.signal(pid: pid, signal: signal)) { [weak self] error in
            if let error { self?.window?.title = error }
        }
    }
}

extension MainWindowController: GitViewDelegate {
    /// What an agent changed (§7.5): its repository's working tree now
    /// against the tree as it started, every file it touched, new ones
    /// too — a diff block of its own, linked from the agent.
    func showAgentChanges(_ agent: BlockID, _ snap: TreeSnapshot, beside placement: PlacementID) {
        guard let client = hosts.client(of: agent) else { return NSSound.beep() }
        let name = hosts.block(agent)?.displayTitle ?? "the agent"
        let subject = DiffSubject.since(repo: snap.repo, tree: snap.tree, title: "Changes by \(name) in \(snap.repo.lastPathComponent)")
        let diff = client.diffBlock(subject)
        hosts.link(from: agent, to: diff, kind: .opened, context: "changes since it started")
        show(diff, lens: .diff, .besideOpener(placement), context: "changes since it started")
    }

    /// A diff's file, right-clicked: the file as the diff's two sides have
    /// it, each read-only as a block of its own (Open This Version), the
    /// file's changes alone, and the file as it is now.
    func diffView(_ view: DiffView, menuFor path: String) -> NSMenu? {
        guard let subject = hosts.block(view.block)?.diff?.subject else { return nil }
        let name = path.lastPathComponent
        var sides: (repo: String, old: String?, new: String?)?
        switch subject {
        case let .commit(repo, sha): sides = (repo, sha + "^", sha)
        case let .trees(repo, from, to, _): sides = (repo, from, to)
        case let .since(repo, tree, _): sides = (repo, tree, nil)
        case let .uncommitted(repo): sides = (repo, "HEAD", nil)
        case let .sides(old, new): sides = (git(old.path) ?? path.deletingLastPathComponent, old.revision, new.revision)
        default: break
        }
        let menu = NSMenu()
        // The rows chosen (or the one right-clicked) commented on (§3.12).
        let comment = ClosureMenuItem("Comment on These Rows…", symbol: "text.bubble") { [weak self] in self?.commentHere(nil) }
        comment.keyEquivalent = "m"
        comment.keyEquivalentModifierMask = [.command, .option]
        menu.addItem(comment)
        // The threads made in this diff handed to an agent at once (§3.12).
        let made = hosts.threads.filter { $0.thread?.about?.diff?.block == view.block && $0.thread?.resolved != true }.map(\.id)
        if !made.isEmpty {
            menu.addItem(ClosureMenuItem("Hand \(made.count) Open Thread\(made.count == 1 ? "" : "s") Here to an Agent", symbol: "sparkle") { [weak self] in
                self?.addressThreads(made)
            })
        }
        menu.addItem(.separator())
        if let s = sides {
            for (rev, label) in [(s.new, "Open This Version"), (s.old, "Open the Version Before")] {
                guard let rev else { continue }
                menu.addItem(ClosureMenuItem(label, symbol: "clock.arrow.circlepath") { [weak self] in
                    self?.showRevision(path, repo: s.repo, revision: rev, from: view)
                })
            }
            if let old = s.old, !(subject.isSides) {
                menu.addItem(ClosureMenuItem("This File's Changes Alone", symbol: "plusminus") { [weak self] in
                    guard let self, let client = self.hosts.client(of: view.block) else { return }
                    let d = client.diffBlock(.sides(old: DiffSide(path: path, revision: old), new: DiffSide(path: path, revision: s.new)))
                    self.show(d, lens: .diff, .besideOpener(view.placement), context: name)
                })
            }
        }
        menu.addItem(ClosureMenuItem("Open the File", symbol: "doc") { [weak self] in self?.diffView(view, open: path, line: 1) })
        return menu
    }

    /// A git repository a path is in, here (for a diff of two sides' revisions).
    private func git(_ path: String) -> String? {
        var dir = path.deletingLastPathComponent
        while !dir.isEmpty, dir != "/" {
            if FileManager.default.fileExists(atPath: dir + "/.git") { return dir }
            dir = dir.deletingLastPathComponent
        }
        return nil
    }

    /// A file as a revision has it: a read-only block of its own, beside.
    func showRevision(_ path: String, repo: String, revision: String, from view: PaneContent) {
        let short = revision.hasSuffix("^") ? String(revision.dropLast().prefix(7)) + "^" : String(revision.prefix(7))
        let title = "\(path.lastPathComponent) @ \(short)"
        let id = BlockID(host: view.block.host)
        guard let client = hosts.client(of: view.block) else { return NSSound.beep() }
        client.propose(.showRevision(block: id, repo: repo, path: path, revision: revision, title: title)) { [weak self] error in
            guard let self else { return }
            if let error { return self.toast.say(error) }
            self.showWhenMade(id, lens: .output, place: .besideOpener(view.placement), context: "version \(short)", what: "that version")
        }
    }

    func gitView(_ view: GitView, openDiff subject: DiffSubject) {
        guard let client = hosts.client(of: view.block) else { return }
        let block = client.diffBlock(subject)
        var context = ""
        switch subject {
        case let .sides(_, new):
            if let file = hosts.client(of: view.block)?.textBlock(path: new.path) {
                hosts.link(from: block, to: file.id, kind: .opened, context: "HEAD → working tree")
            }
            context = new.path.lastPathComponent
        case let .commit(_, sha): context = String(sha.prefix(7))
        case .uncommitted: context = "uncommitted"
        case .versions, .patch, .since, .trees: break
        }
        show(block, lens: .diff, opener(view.placement), context: context)
    }

    func gitView(_ view: GitView, open path: String) {
        open(path: path, line: 1, column: nil, on: view.block.host, from: view.placement, context: path.lastPathComponent)
    }

    func gitViewRefresh(_ view: GitView) {
        hosts.propose(.refreshGit(block: view.block))
    }

    func gitView(_ view: GitView, indexStatus done: @escaping (SCIPStatus?) -> Void) {
        guard let b = hosts.block(view.block), let repo = b.path else { return done(nil) }
        // A project's (§2.6): its own folder's index.
        let root = b.git?.scope.map { repo.appendingPathComponent($0) } ?? repo
        hosts.scip(.status(path: root.appendingPathComponent(".")), on: view.block.host) { result in
            if case .status(let s) = result, s.state != .none { done(s) } else { done(nil) }
        }
    }

    /// The pane's diff: its block made (or found) on the repository's
    /// host, shown in the git tile's place — what it opens goes beside it.
    /// Never placed, it isn't Recently Closed's (`closedItems`).
    func gitView(_ view: GitView, previewFor subject: DiffSubject) -> DiffView? {
        guard let client = hosts.client(of: view.block) else { return nil }
        let id = client.diffBlock(subject)
        let d = DiffView(placement: view.placement, block: id, theme: hosts.state.appearance.theme)
        d.delegate = self
        d.source = { [weak self] in self?.hosts.block(id) }
        return d
    }
}

extension MainWindowController: DiffViewDelegate {
    func diffView(_ view: DiffView, open path: String, line: Int) {
        open(path: path, line: line, column: nil, on: view.block.host, from: view.placement, context: "\(path.lastPathComponent):\(line)")
    }

    /// A diff shown again is compared again — but not when it was a moment
    /// ago: a view made afresh for a block just compared leaves it be.
    func diffViewReload(_ view: DiffView) {
        if let last = diffReloaded[view.block], Date().timeIntervalSince(last) < 5 { return }
        diffReloaded[view.block] = Date()
        hosts.propose(.reloadDiff(block: view.block))
    }

    /// A patch's file's new side: as its commit left it, else as it is in
    /// the working tree — read from the diff's host.
    func diffView(_ view: DiffView, textOf file: String, done: @escaping (String?) -> Void) {
        guard let c = hosts.client(of: view.block), let subject = hosts.block(view.block)?.diff?.subject else { return done(nil) }
        switch subject {
        case let .commit(repo, sha):
            c.fileHistory(.text(file: repo.appendingPathComponent(file), path: file, revision: sha)) { result in
                if case let .text(t) = result { done(t) } else { done(nil) }
            }
        case let .uncommitted(root), let .patch(root, _), let .since(root, _, _), let .trees(root, _, nil, _):
            var data = Data()
            c.readFile(root.appendingPathComponent(file), limit: 8 << 20, onData: { data.append($0) }) { error in
                done(error == nil ? String(decoding: data, as: UTF8.self) : nil)
            }
        default:
            done(nil)
        }
    }
}

extension MainWindowController: SearchViewDelegate {
    func searchView(_ view: SearchView, run query: SearchQuery) {
        if query.relation != nil { return runRelation(query, in: view.block) }
        if query.symbol != nil, let client = hosts.client(of: view.block) {
            client.append([.title("“\(query.text)”")], to: .block(view.block))
        }
        hosts.propose(.search(block: view.block, query: query))
    }

    /// A symbol's search asked as a relation (§2.5) — its references, or
    /// its callers — of the project's index, here; the hits written into
    /// the search block, as the host writes a text search's.
    func runRelation(_ q: SearchQuery, in block: BlockID) {
        guard let client = hosts.client(of: block), let relation = q.relation, let symbol = q.symbol, let path = q.symbolPath else { return }
        let title = (relation == "callers" ? "Callers of" : "References to") + " “\(q.text)”"
        client.append([.title(title), .search(q, at: client.clock.now())], to: .block(block))
        Task { @MainActor [weak self] in
            guard let self else { return }
            let scope = ManiDesk.Scope(self.maniDesk, ManiRequest(verb: relation, flags: [:], args: [], cwd: path.deletingLastPathComponent, here: nil),
                                       ManiDesk.Asker(host: block.host, id: 0, client: 0))
            do {
                let hits = try await self.maniDesk.relationHits(relation, symbol: symbol, path: path, host: block.host, scope)
                // Still what was asked (not asked again meanwhile).
                guard self.hosts.block(block)?.search?.query == q else { return }
                client.append([.hits(hits, done: true, truncated: false, error: nil)], to: .block(block))
            } catch {
                let message = (error as? ManiDesk.Failure)?.message ?? "\(error)"
                client.append([.hits([], done: true, truncated: false, error: message)], to: .block(block))
            }
        }
    }

    /// A symbol's search, made and shown beside a tile: its relation asked.
    func showRelation(_ relation: String, symbol: String, name: String, path: String, on host: HostID, from placement: PlacementID) {
        guard let client = hosts.client(host) else { return }
        var q = SearchQuery(text: name, caseSensitive: true, root: projectRoot(from: path.deletingLastPathComponent, on: host))
        q.relation = relation
        q.symbol = symbol
        q.symbolPath = path
        let id = BlockID(host: host)
        client.append([.create(kind: .search, title: nil, path: nil)], to: .block(id))
        runRelation(q, in: id)
        show(id, lens: .search, .besideOpener(placement), context: (relation == "callers" ? "callers of " : "references to ") + name)
    }

    func searchView(_ view: SearchView, open hit: SearchHit) {
        open(path: hit.path, line: hit.line, column: hit.column, on: view.block.host, from: view.placement,
             kind: .opened, context: hit.text.trimmingCharacters(in: .whitespaces))
    }

    func searchViewCancel(_ view: SearchView) {
        hosts.propose(.cancelSearch(block: view.block))
    }

    /// A file's text for the preview: 4 MB at most, and not a binary one.
    func searchView(_ view: SearchView, read path: String, done: @escaping (String?) -> Void) {
        guard let client = hosts.client(of: view.block) else { return done(nil) }
        client.readBytes(path: path, limit: 4 << 20) { data in
            guard let data, !data.prefix(8192).contains(0) else { return done(nil) }
            done(String(decoding: data, as: UTF8.self))
        }
    }

    func searchView(_ view: SearchView, open path: String, line: Int) {
        open(path: path, line: line, column: 1, on: view.block.host, from: view.placement, kind: .opened, context: nil)
    }
}

extension MainWindowController: OutputViewDelegate {
    func output(_ view: OutputView, showSource source: BlockID, command: Int) {
        arrive(source, from: view.placement, over: false)
        goToCommand(command, in: source)
    }
}

extension MainWindowController: PanelViewDelegate {
    func panel(_ view: PanelView, event: [String: Any], changed: [String: String], run: String?) {
        maniDesk.panelEvent(view.block, event: event, changed: changed, run: run)
    }
}
