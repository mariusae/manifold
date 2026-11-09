import AppKit
import ManifoldCore
import WebKit
import ManifoldSyntax
import UniformTypeIdentifiers
import PDFKit

extension MainWindowController {
    // MARK: Making blocks (BlockKinds)

    struct MakeFailure: Error { var message: String }

    /// A block of a kind made (`BlockKinds`, one table for File ▸ New, the
    /// picker and `mani new`), with what it takes if given, on a host,
    /// from a folder — not yet placed. The lens it shows in, and whether
    /// the host makes it later (a notebook: shown once it has).
    func makeBlock(_ kind: BlockKinds.Kind, what: String?, cwd: String?, on h: HostID) throws -> (block: BlockID, lens: Lens, later: Bool) {
        guard let client = hosts.client(h) else { throw MakeFailure(message: "that host isn't attached") }
        let here = cwd ?? NSHomeDirectory()
        switch kind.name {
        case "terminal":
            let t = hosts.newTerminal(on: h, cwd: cwd)
            // Its command typed in once its shell is up.
            if let what { hosts.propose(.input(block: t, text: what + "\r")) }
            return (t, .terminal, false)
        case "agent":
            return (client.newAgent(cwd: cwd, command: what ?? desk.settings.agentCommand), .agent, false)
        case "note":
            return (client.newNote(home: cwd, text: what ?? ""), .editor, false)
        case "web":
            let address = what.map { if case let .page(u) = WebAddress.parse($0) { return u } else { return $0 } } ?? "https://duckduckgo.com"
            // Where the focused block is: another host's, loaded through it (§7.6).
            return (client.newWeb(url: address, viaHost: client.isRemote), .web, false)
        case "search":
            return (client.newSearch(SearchQuery(text: what ?? "", root: here)), .search, false)
        case "folder":
            let path = what.map { ($0 as NSString).expandingTildeInPath }.map { $0.hasPrefix("/") ? $0 : (here as NSString).appendingPathComponent($0) } ?? here
            return (hosts.directoryBlock(for: path, on: h), .directory, false)
        case "notebook":
            let id = BlockID(host: client.host)
            client.propose(.newNotebook(block: id, cwd: cwd))
            return (id, .notebook, true)
        case "git":
            if h == host.host, VCS.repository(of: here) == nil { throw MakeFailure(message: "no repository at \(here.abbreviatingHome)") }
            return (client.gitBlock(for: here), .git, false)
        case "smartlog":
            return (client.smartlogBlock(for: here), .smartlog, false)
        case "process":
            return (client.processBlock(), .process, false)
        default:
            throw MakeFailure(message: "no kind \(kind.name) to make")
        }
    }

    /// File ▸ New's items, by kind (⌥⌘ and its letter): each the action it
    /// always had, so a menu's New Note is linked from the focused block, a
    /// search Find in Files', a repository's block as Source Control finds it.
    static let newActions: [String: Selector] = [
        "terminal": #selector(newTerminalBeside(_:)), "agent": #selector(newAgent(_:)), "note": #selector(newNote(_:)),
        "web": #selector(newWebPage(_:)), "search": #selector(findInFiles(_:)), "folder": #selector(browseFocusedFolder(_:)),
        "notebook": #selector(newShellNotebook(_:)), "git": #selector(showGit(_:)), "smartlog": #selector(showSmartlog(_:)),
        "process": #selector(showProcesses(_:)),
    ]

    /// ⌘N: the New Block picker — the kinds, each with its letter
    /// (⌥⌘ and it makes one without the picker), narrowed as its letter or
    /// name is typed, then what it takes after a space ("w example.com",
    /// "search TODO", "t make test"), as `mani new` reads its words: ↩
    /// makes the first, so ⌘N ↩ is a terminal and ⌘N N ↩ a note. ↩ makes it
    /// below the focused tile, ⇧↩ in a new column (as ⇧ with ⌥⌘ does),
    /// ⌘↩ below it and linked, ⌥↩ over it.
    @objc func newBlockPicker(_ sender: Any?) {
        let provider: (String) -> [FinderItem] = { [weak self] query in
            guard let self else { return [] }
            // "@devbox" anywhere: made on that host (a connected one whose
            // label starts so); else on the focused tile's.
            let words = query.split(separator: " ", omittingEmptySubsequences: false).map(String.init)
            let named = words.first { $0.hasPrefix("@") }.map { String($0.dropFirst()).lowercased() }
            let rest = words.filter { !$0.hasPrefix("@") }.joined(separator: " ")
            let here = self.focusedHost
            let connected = self.hosts.all.filter { $0.link == .connected }.map(\.host)
            // The focused tile's host first, then this Mac, then the rest.
            let ordered = [here] + ([self.host.host] + connected).filter { $0 != here }
            var seen = Set<HostID>()
            let all = ordered.filter { connected.contains($0) || $0 == self.host.host }.filter { seen.insert($0).inserted }
            let picked = named.map { n in all.filter { self.hosts.label(of: $0).lowercased().hasPrefix(n) } }
            let (word, what) = BlockKinds.parse(rest)
            // A kind typed: on every host (the focused tile's first); nothing
            // typed, each kind once, on the focused tile's.
            let kindHosts = picked ?? (word.isEmpty ? [here] : all)
            let on = { (h: HostID) in h == here && picked == nil ? "" : " on " + self.hosts.label(of: h) }
            var items: [FinderItem] = []
            for k in BlockKinds.matching(word) {
                for h in kindHosts {
                    let with = k.what == nil ? nil : what
                    let key = h == here ? k.key.map { "⌥⌘" + $0.uppercased() } ?? "" : ""
                    let then = k.what.map { with == nil ? "then: \($0)" : "" } ?? ""
                    items.append(FinderItem(symbol: k.symbol, title: "New " + k.title + on(h) + (with.map { " — " + $0 } ?? ""), detail: k.help,
                                            note: [key, then].filter { !$0.isEmpty }.joined(separator: " · "),
                                            run: { [weak self] in self?.makeFromPicker(k, with, on: h) }))
                }
            }
            // A space, on any host: its terminal in the focused folder, on
            // the focused tile's host; at home elsewhere.
            let w = word.lowercased()
            if w.isEmpty || ["space", "workspace"].contains(where: { $0.hasPrefix(w) }) {
                for h in picked ?? all {
                    items.append(FinderItem(symbol: "plus.rectangle.on.rectangle", title: "New Space" + (h == here && picked == nil ? "" : " on " + self.hosts.label(of: h)),
                                            detail: "a space of its own, with a terminal", note: h == here ? "⌘T" : "",
                                            run: { [weak self] in
                        guard let self else { return }
                        self.newWorkspace(on: h, cwd: h == here ? self.focusedCwd : nil)
                    }))
                }
            }
            return items
        }
        finder.showOutline(Finder.OutlineScope(provider: provider, start: nil,
                                               placeholder: "New…  (t, n, w example.com, @host)",
                                               hint: "Make a block", keys: "↩ Here    ⇧↩ New Column    ⌘↩ Beside    ⌥↩ Over    ⎋ Close"),
                           over: window)
    }

    func makeFromPicker(_ kind: BlockKinds.Kind, _ what: String?, on h: HostID? = nil) {
        let f = arrangement?.focused
        let h = h ?? focusedHost
        // ⇧↩ alone: a new column, as ⇧ with ⌥⌘ and a kind's letter.
        let event = NSApp.currentEvent
        let newColumn = event?.type == .keyDown && event?.isReturn == true && event?.keyMods == .shift
        var place = Where.by(Self.disposition ?? .goTo, from: f)
        if newColumn { place = .beside }
        do {
            let from = focusedShown?.block
            // The focused folder, on its own host; another's home.
            let made = try makeBlock(kind, what: what, cwd: h == focusedHost ? focusedCwd : nil, on: h)
            // A note is about what was focused, as ⌥⌘N's is.
            if kind.name == "note", let b = from, b.kind != .arrangement { hosts.link(from: b.id, to: made.block, kind: .linked, context: "new note") }
            if made.later { showWhenMade(made.block, lens: made.lens, place: place, what: "the " + kind.title.lowercased()) }
            else { show(made.block, lens: made.lens, place, context: "new " + kind.name) }
        } catch let f as MakeFailure {
            toast.say(f.message)
        } catch {}
    }

    /// A block deleted (§4): every tile of it taken off at once, in every
    /// space, and a toast with Undo counting down; when it's run out, every
    /// link to it and from it broken, on every host, pins too, and the
    /// block itself gone — its log, its session, its entry in the registry.
    /// Undo (or ⇧⌘T, or the block placed again any other way meanwhile)
    /// puts its tiles back and nothing more is done. Nothing is asked
    /// first: what it would lose (a note's words, unsaved edits, a job) is
    /// said in the toast, given longer. What only it reached isn't deleted
    /// with it: unreached then, it's in Recently Closed, and collected after
    /// the grace unless something reaches it again.
    func deleteBlock(_ block: BlockID) {
        guard let b = hosts.block(block), b.kind != .arrangement else { return NSSound.beep() }
        var loses: [String] = []
        if b.isNote, !(b.text?.text.string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true) { loses.append("its text") }
        else if b.text?.isDirty == true { loses.append("its unsaved edits") }
        if b.terminal?.busy == true { loses.append(b.kind == .agent ? "the agent at work in it" : "the job running in it") }
        let title = b.displayTitle
        // Its tiles, in every space, each remembered as a tile closed is
        // (Undo and ⇧⌘T put them back).
        var tiles = 0
        for ws in allWorkspaces {
            guard let a = hosts.arrangement(ws) else { continue }
            let placed = a.placements(of: block)
            for p in placed { noteClosing(p.id, in: ws) }
            tiles += placed.count
            if !placed.isEmpty { hosts.append(placed.map { .remove($0.id) }, to: .block(ws)) }
        }
        // What it alone reached, which goes to Recently Closed with it.
        let alone = hosts.reachable().subtracting(hosts.reachable(without: block)).subtracting([block]).count
        var text = "Deleted “\(title)”"
        if !loses.isEmpty { text += ", " + loses.joined(separator: " and ") }
        if alone > 0 { text += alone == 1 ? "; 1 block only it reached to Recently Closed" : "; \(alone) blocks only it reached to Recently Closed" }
        toast.show(text, action: "Undo", for: loses.isEmpty ? 4 : 6, countdown: true, then: { [weak self] in
            self?.deleteNow(block)
        }) { [weak self] in
            self?.reopenClosed(block: block, tiles: tiles)
        }
        layoutViews()
    }

    /// The deletion, its time up: unless it was placed again meanwhile.
    private func deleteNow(_ block: BlockID) {
        guard hosts.block(block) != nil, !isPlaced(block) else { return }
        // Not to be brought back by ⇧⌘T any more.
        closedStack.removeAll { if case let .tile(_, _, _, p, _) = $0 { return p.block == block } else { return false } }
        // Its links, both ways, wherever they're kept.
        var links = Set<String>()
        for c in hosts.all {
            for e in c.node.graph.edges(from: block) + c.node.graph.edges(to: block) where e.isLive {
                if case .link = e.kind { links.insert(e.id) }
            }
        }
        for l in links { hosts.propose(.unlink(l)) }
        hosts.propose(.discard(block))
        layoutViews()
    }

    /// Debugging: the toast's time up now, what waits on it done.
    func debugToastFinish() { toast.hide() }
    func debugToastPicture(_ path: String) -> String { toast.debugPicture(to: path) }

    /// Whatever waits on a toast's time, done now (the app quitting).
    func finishPending() { toast.finishPending() }

    /// ⇧⌘W: the workspace removed — the only way one goes (§4); what only
    /// it kept is collected after the grace, reopened meanwhile by ⇧⌘T.
    @objc func closeTab(_ sender: Any?) {
        guard let id = selected else { return }
        closeSpace(id)
    }

    /// A space removed, as ⇧⌘W removes the one shown (`mani close` names one).
    func closeSpace(_ id: BlockID) {
        let before = hosts.reachable()
        let name = hosts.arrangement(id).map { title(of: $0) } ?? "Untitled"
        removeFromDesk(id)
        afterClosing(reachedBefore: before, space: name)
    }

    /// Every workspace on every host, in the sidebar's order.
    var allWorkspaces: [BlockID] { hosts.all.flatMap { $0.desk.order } }

    /// `remember`: for ⇧⌘T — every space removed is, empty or not, but
    /// one whose tiles went to another (dropped on it).
    func removeFromDesk(_ id: BlockID, remember: Bool = true) {
        let all = allWorkspaces
        guard let i = all.firstIndex(of: id) else { return }
        if remember, let client = hosts.client(of: id), let j = client.desk.order.firstIndex(of: id) {
            closedStack.append(.workspace(id, index: j))
        }
        hosts.client(of: id)?.removeWorkspace(id)
        if selected == id {
            let rest = all.filter { $0 != id }
            hosts.select(rest.isEmpty ? nil : rest[min(i, rest.count - 1)])
        }
    }

    /// The host's own resets, for a menu of something on it: Reset Server
    /// (a remote's) and Reset Graph — as items, in a host's own menu, or
    /// as a submenu named for the host, in any other.
    /// `ownRow`: for the host's own row in the sidebar, the only place
    /// Reset Graph is offered (it forgets every link, past undoing).
    func hostItems(_ host: HostID, ownRow: Bool = false) -> [NSMenuItem] {
        let label = hosts.label(of: host)
        var items: [NSMenuItem] = []
        if let c = hosts.client(host), c.isRemote {
            // Its ports brought here: one asked for, those forwarded (each stopped).
            let fwd = ClosureMenuItem("Forward a Port from \(label)…", symbol: "arrow.left.arrow.right") { [weak self] in self?.askForwardPort(host) }
            fwd.isEnabled = c.isConnected
            items.append(fwd)
            for f in c.forwards.forwards.values.filter({ !$0.hidden }).sorted(by: { $0.remote < $1.remote }) {
                let local = f.local.map(String.init) ?? "…"
                let open = ClosureMenuItem("localhost:\(local) → \(label):\(f.remote)", symbol: "network") { [weak self] in
                    self?.openWeb(URL(string: "http://localhost:\(local)/")!, place: .here, here: true)
                }
                let stop = NSMenu()
                stop.addItem(ClosureMenuItem("Open", symbol: "safari") { [weak self] in
                    self?.openWeb(URL(string: "http://localhost:\(local)/")!, place: .here, here: true)
                })
                stop.addItem(ClosureMenuItem("Stop Forwarding", symbol: "xmark") { c.forwards.stop(f.remote) })
                open.submenu = stop
                items.append(open)
            }
            items.append(ClosureMenuItem("Clear Website Data for \(label)…", symbol: "trash") { [weak self] in self?.clearWebsiteData(host) })
            items.append(ClosureMenuItem("Reset Server on \(label)…", symbol: "arrow.triangle.2.circlepath") { [weak self] in self?.resetServer(host) })
        }
        if hosts.client(host)?.isRemote == false {
            // This Mac's own (another host's are in its own menu).
            items.append(ClosureMenuItem("Preferences for \(label)…", symbol: "gearshape") { [weak self] in self?.editPreferences(host) })
            if hosts.client(host)?.keepsEnvironment == true {
                items.append(ClosureMenuItem("Add Environment Variable…", symbol: "dollarsign.square") { [weak self] in self?.addEnvironmentVariable(host) })
            }
            items.append(ClosureMenuItem("Clear Website Data for \(label)…", symbol: "trash") { [weak self] in self?.clearWebsiteData(host) })
        }
        if ownRow {
            let graph = ClosureMenuItem("Reset Graph on \(label)…", symbol: "point.3.connected.trianglepath.dotted") { [weak self] in self?.resetGraph(host) }
            graph.isEnabled = hosts.client(host)?.isConnected == true
            items.append(.separator())
            items.append(graph)
            let delete = ClosureMenuItem("Delete Session on \(label)…", symbol: "trash") { [weak self] in self?.deleteSession(host) }
            delete.isEnabled = hosts.client(host)?.link == .connected
            items.append(delete)
        }
        return items
    }

    func hostSubmenu(_ host: HostID) -> NSMenuItem {
        let sub = NSMenu()
        for item in hostItems(host) { sub.addItem(item) }
        let item = NSMenuItem(title: hosts.label(of: host), action: nil, keyEquivalent: "")
        item.setSymbol("server.rack", size: 12)
        item.submenu = sub
        return item
    }

    /// Forward a Port…: which of the host's, asked; forwarded, and opened.
    private func askForwardPort(_ h: HostID) {
        let alert = NSAlert()
        alert.messageText = "Forward a port from \(hosts.label(of: h))"
        alert.informativeText = "A server listening on the host's own localhost is reached on this Mac's, at the same port when it's free here."
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 120, height: 24))
        field.placeholderString = "3000"
        alert.accessoryView = field
        alert.addButton(withTitle: "Forward")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn, let port = Int(field.stringValue.trimmingCharacters(in: .whitespaces)), (1...65535).contains(port) else { return }
        forward(port, on: h) { [weak self] local in
            guard let local else { return }
            self?.openWeb(URL(string: "http://localhost:\(local)/")!, place: .here, here: true)
        }
    }

    /// A port of another host's brought here: said so (a toast), and the
    /// port here given back.
    func forward(_ port: Int, on h: HostID, done: @escaping (Int?) -> Void) {
        guard let c = hosts.client(h) else { return done(nil) }
        // Under way, a moment in: said, so the click isn't taken for nothing.
        var finished = false
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            guard let self, !finished else { return }
            self.toast.say("Forwarding \(port) from \(self.hosts.label(of: h))…", .long)
        }
        c.forwards.forward(port) { [weak self] local in
            finished = true
            guard let self else { return }
            if let local {
                let same = local == port ? "" : " (\(port) is taken here)"
                self.toast.show("\(self.hosts.label(of: h)):\(port) forwarded to localhost:\(local)\(same)", action: "Stop", for: 6) { c.forwards.stop(port) }
            } else {
                self.toast.say("Couldn't forward \(port) from \(self.hosts.label(of: h))", .long)
            }
            done(local)
        }
    }

    /// Resets a host's graph, once asked: every link and the trail gone.
    /// Delete Session (issue #1), once asked — what goes counted, and for
    /// This Mac its name typed: the host's session gone for good, every file
    /// Manifold keeps there (logs, notes, terminals' history, indexes, the
    /// pictures kept for notes, the server installed there); what other
    /// hosts link to or place of it taken off. Then: another host's,
    /// forgotten here; This Mac's, Manifold starts afresh. Files of the
    /// user's own stay.
    private func deleteSession(_ host: HostID) {
        guard let c = hosts.client(host), let window else { return }
        let label = hosts.label(of: host)
        let blocks = c.node.blocks.filter { $0.id.host == host }
        let spaces = blocks.filter { $0.kind == .arrangement }.count
        let notes = blocks.filter { $0.isNote && !($0.text?.text.string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true) }.count
        let shells = blocks.filter { $0.terminal?.pid != nil }.count
        func n(_ k: Int, _ one: String) -> String { "\(k) \(one)\(k == 1 ? "" : "s")" }
        let alert = NSAlert()
        alert.alertStyle = .critical
        alert.messageText = c.isRemote ? "Delete the session on \(label) for good?" : "Delete This Mac's session for good?"
        alert.informativeText = "Its \(n(spaces, "space")) and every block on them go — \(n(notes, "note")) (kept nowhere else), \(n(shells, "running shell")), terminals' history, indexes, logs — and every file Manifold keeps "
            + (c.isRemote ? "on \(label), its server too; then it's forgotten here." : "on this Mac for it; Manifold then starts afresh, as on its first launch (other hosts stay attached).")
            + " Links and tiles of it on other hosts are taken off. Files of your own — opened, saved, in your folders — stay. This can't be undone."
        alert.addButton(withTitle: "Delete")
        alert.addButton(withTitle: "Cancel")
        alert.buttons[0].hasDestructiveAction = true
        // This Mac's: its name typed first.
        var typed: NSTextField?
        if !c.isRemote {
            let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
            field.placeholderString = "Type \(label) to delete"
            alert.accessoryView = field
            alert.buttons[0].isEnabled = false
            typed = field
            NotificationCenter.default.addObserver(forName: NSControl.textDidChangeNotification, object: field, queue: .main) { [weak alert] _ in
                MainActor.unchecked { alert?.buttons.first?.isEnabled = field.stringValue == label }
            }
            alert.window.initialFirstResponder = field
        }
        alert.beginSheetModal(for: window) { [weak self] response in
            guard let self, response == .alertFirstButtonReturn, typed.map({ $0.stringValue == label }) ?? true else { return }
            if let id = self.selected, id.host == host {
                let rest = self.allWorkspaces.filter { $0.host != host }
                self.hosts.select(rest.first)
            }
            self.hosts.deleteSession(host)
        }
    }

    /// A session's deletion said back (by this Mac, another, or on the host):
    /// another host's, forgotten here; This Mac's, Manifold starts afresh.
    func sessionErased(_ c: HostClient, by: String?) {
        let label = hosts.label(of: c.host)
        if c.isRemote {
            hosts.detach(c.host)
            refreshOrganization(now: true)
            toast.say("The session on \(label) was deleted" + (by.map { $0 == HostClient.machine ? "" : " (on \($0))" } ?? " (on the host)"), .long)
            return
        }
        // This Mac's: what the app kept of it goes too — its window's
        // state, the pages' history and icons, their website data, its
        // logs — and Manifold starts again, a new session.
        WebStores.clear(through: nil) {
            let fm = FileManager.default
            let dir = Paths.directory
            for name in ["client.json", "web-history.json", "favicons"] { try? fm.removeItem(at: dir.appendingPathComponent(name)) }
            try? fm.removeItem(at: fm.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/Manifold"))
            // Started again once this one has gone (its server is already):
            // the same program, with what it was started with.
            guard let exe = Bundle.main.executablePath else { return NSApp.terminate(nil) }
            let relaunch = Process()
            relaunch.executableURL = URL(fileURLWithPath: "/bin/sh")
            relaunch.arguments = ["-c", "sleep 1.5; exec \"$0\" \"$@\"", exe] + Array(CommandLine.arguments.dropFirst())
            try? relaunch.run()
            NSLog("pid %d: started again as %d, quitting", getpid(), relaunch.processIdentifier)
            NSApp.terminate(nil)
        }
    }

    private func resetGraph(_ host: HostID) {
        confirm("Reset the graph on \(hosts.label(of: host))?",
                "Every link between the host's blocks is forgotten — opened from, found by, mentions, compared, made by hand — and the trail of where you went, before and after. What's on each space stays. This can't be undone.",
                button: "Reset", destructive: true) { [weak self] in
            self?.hosts.resetGraph(on: host) { [weak self] error in
                if let error { NSLog("reset graph on %@: %@", host.raw, error) }
                self?.refreshOrganization(now: true)
            }
        }
    }

    /// What pages loaded through a host keep (cookies and sign-ins, what
    /// sites store, caches), or this Mac's pages, forgotten once asked —
    /// it can't be undone — and those pages loaded again, signed out.
    func clearWebsiteData(_ host: HostID) {
        let label = hosts.label(of: host)
        let through = hosts.client(host)?.isRemote == true ? host : nil
        let info = (through == nil
            ? "Pages loaded from This Mac forget their cookies and sign-ins, what sites keep, and their caches. Pages loaded through other hosts keep theirs."
            : "Pages loaded through \(label) forget their cookies and sign-ins, what sites keep, and their caches. Pages loaded from This Mac keep theirs.")
            + " This can't be undone."
        confirm("Clear website data for \(label)?", info, button: "Clear", destructive: true) {
            WebStores.clear(through: through) { [weak self] in
                guard let self else { return }
                for case let w as WebView in self.views.values where w.through == through { w.reloadPage(nil) }
                self.toast.say("Website data cleared for \(label)", .brief)
            }
        }
    }

    /// Resets a host's server, once asked: put there afresh and restarted.
    private func resetServer(_ host: HostID) {
        confirm("Reset the server on \(hosts.label(of: host))?",
                "Manifold installs its server there again, whatever is there now, and restarts it. Every shell on the host ends; its terminals start new ones, each in its folder. Blocks and spaces stay.",
                button: "Reset") { [weak self] in self?.hosts.resetServer(host) }
    }

    /// Detaches from a host, once asked: it's forgotten here, and a
    /// workspace of its shown gives way to one elsewhere.
    func detach(_ host: HostID) {
        confirm("Detach from \(hosts.label(of: host))?",
                "Manifold forgets the host and won't attach to it again at start. Its server, shells and blocks stay there; attach to it again to have them back.",
                button: "Detach") { [weak self] in self?.detachNow(host) }
    }

    private func detachNow(_ host: HostID) {
        if let id = selected, id.host == host {
            let all = allWorkspaces
            let rest = all.filter { $0.host != host }
            let i = all.firstIndex(of: id) ?? 0
            hosts.select(rest.isEmpty ? nil : rest[min(i, rest.count - 1)])
        }
        hosts.detach(host)
    }

    @objc func renameTab(_ sender: Any?) {
        if let id = selected { renameSpace(id) }
    }

    /// File ▸ Name Note…: the focused note's name, in its pill.
    @objc func nameFocusedNote(_ sender: Any?) {
        if let f = focusedShown { nameNote(f.id) }
    }

    /// A note named in its tile's pill, as it is — nothing saved: the
    /// name is the block's title, kept in its log, until a file's name
    /// takes over, no longer following its first line. Emptied, it's
    /// called by its first line again (as the host titles an unnamed note).
    func nameNote(_ placement: PlacementID) {
        guard let a = arrangement, let p = a.placement(placement), let b = hosts.block(p.block), b.isNote else { return }
        focus(placement)
        let block = p.block
        let firstLine = b.titleIsFirstLine == true ? b.title : nil
        content.editPill(placement, PillEdit(text: b.title ?? "", placeholder: "Name this note", overName: true) { [weak self] name in
            // Left as its first line says: still its first line's, not a name.
            guard name != firstLine else { return }
            self?.hosts.append(.title(name.isEmpty ? nil : name), to: .block(block))
        })
    }

    @objc func togglePinnedSidebar(_ sender: Any?) { sidebarTogglePinned() }

    /// The appearance changed as `change` says (Settings' and debugging's).
    func changeAppearance(_ change: (inout Appearance) -> Void) {
        var a = hosts.state.appearance
        change(&a)
        hosts.setAppearance(a)
    }

    @objc func validateMenuItem(_ item: NSMenuItem) -> Bool {
        switch item.action {
        case #selector(togglePinInWorkspace(_:)):
            // Named for what it will do to its tile's block.
            guard let id = selected, let block = pinTarget(item) else { item.title = "Pin in Space"; return false }
            let on = isPinned(block, in: id)
            item.title = on ? "Unpin" : "Pin in Space"
            item.image = Theme.symbol(on ? "pin.slash" : "pin", size: 13)
            return true
        case #selector(nextInInbox(_:)):
            return !inboxOrder().isEmpty
        case #selector(printTile(_:)):
            return focusedView is Printable
        case #selector(goToLineOrAddress(_:)):
            // Named for what it will do in the focused tile.
            let v = focusedView
            if v is EditorView { item.title = "Go to Line…"; return true }
            item.title = v?.pillEdit != nil ? "Edit Address" : "Go to Line…"
            return v?.pillEdit != nil
        case #selector(toggleTileSidebar(_:)):
            guard let v = arrangement?.focused.flatMap({ views[$0] }), v.hasSidebar else { item.title = "Show Outline"; return false }
            item.title = v.sidebarShown ? "Hide Outline" : "Show Outline"
            return true
        case #selector(toggleOutliner(_:)):
            guard let f = focusedShown, canOutline(f) else { item.title = "Edit as Outline"; return false }
            item.title = f.lens == .outliner ? "Edit as Text" : "Edit as Outline"
            return true
        case #selector(interruptTile(_:)):
            return focusedShown.map { views[$0.id] is NotebookView } ?? false
        case #selector(toggleEditPreview(_:)), #selector(editPreviewBeside(_:)):
            let primary = item.action == #selector(toggleEditPreview(_:))
            if primary, let f = focusedShown, views[f.id] is NotebookView { item.title = "Run Cell"; return true }
            if primary, let f = focusedShown, views[f.id] is OutlineNoteView { item.title = "Toggle Checkbox"; return true }
            item.title = primary ? "Edit or View" : "Edit or View Beside"
            guard let f = focusedShown, f.lens.isText, f.block?.kind == .text else { return false }
            let viewing = f.lens == .preview
            item.title = item.action == #selector(toggleEditPreview(_:)) ? (viewing ? "Edit" : "View") : (viewing ? "Edit Beside" : "View Beside")
            return true
        case #selector(nameFocusedNote(_:)):
            return focusedShown?.block?.isNote == true
        case #selector(togglePinnedSidebar(_:)):
            item.title = pinned ? "Let Sidebar Slide Out" : "Keep Sidebar Shown"
        // The Tile menu named, as the tile's own menu is, for what the item
        // will do — and offered only where it can.
        case #selector(toggleMaximize(_:)):
            guard let a = arrangement, let f = a.focused else { item.title = "Maximize"; return false }
            item.title = a.full == f ? "Restore" : "Maximize"
        case #selector(shrinkToSummary(_:)):
            guard let a = arrangement, a.full == nil, let f = a.focused, contentHeight(of: f, in: a) != nil else {
                item.title = "Shrink to Summary"
                return false
            }
            item.title = isSummarized(f) ? "Show Content" : "Shrink to Summary"
        case #selector(growTile(_:)), #selector(fillColumn(_:)), #selector(fillColumnKeepingBars(_:)):
            return arrangement?.focused != nil
        case #selector(saveAndClose(_:)):
            return focusedShown.map { $0.block?.kind == .text } ?? false
        case #selector(deleteFocusedBlock(_:)):
            return focusedShown.map { $0.block?.kind != .arrangement } ?? false
        case #selector(dockTile(_:)):
            guard let a = arrangement, let f = a.focused else { return false }
            return a.locate(f) != nil
        case #selector(walkSpaceTiles(_:)), #selector(walkSpaceTilesBack(_:)):
            return (arrangement?.placements.count ?? 0) > 1
        case #selector(reopenClosed(_:)):
            return !closedStack.isEmpty
        case #selector(navigateBack(_:)):
            return !navStack.isEmpty
        case #selector(navigateForward(_:)):
            return navCursor < navStack.count - 1
        case #selector(selectTabByNumber(_:)):
            return item.tag == 9 ? !allWorkspaces.isEmpty : item.tag <= allWorkspaces.count
        case #selector(compareWithHead(_:)):
            guard let f = focusedShown else { return false }
            return f.path != nil && (f.lens == .editor || f.lens == .preview)
        case #selector(showFileHistory(_:)):
            item.state = history != nil ? .on : .off
            return history != nil || focusedShown?.kind == .text
        case #selector(browseFocusedFolder(_:)):
            return focusedCwd != nil
        // Views that come and go: checked while they're up.
        case #selector(showWorkspaceOverview(_:)):
            item.state = stateWorkspace != nil && !stateAgents ? .on : .off
        case #selector(showAgents(_:)):
            item.state = stateAgents ? .on : .off
        case #selector(showNeighborhood(_:)):
            item.state = neighborhoodView != nil ? .on : .off
        case #selector(organizeByDesk(_:)):
            item.state = organization == .desk ? .on : .off
        case #selector(organizeByFiles(_:)):
            item.state = organization == .files ? .on : .off
        case #selector(organizeByThreads(_:)):
            item.state = organization == .threads ? .on : .off
        case #selector(toggleInspector(_:)):
            item.state = inspector?.isVisible == true ? .on : .off
        default:
            break
        }
        return true
    }

    @objc func nextTab(_ sender: Any?) { stepTab(1) }
    @objc func previousTab(_ sender: Any?) { stepTab(-1) }

    private func stepTab(_ d: Int) {
        let order = allWorkspaces
        guard !order.isEmpty else { return }
        let i = selected.flatMap { order.firstIndex(of: $0) } ?? 0
        show(arrangement: order[(i + d + order.count) % order.count])
    }

    /// Selects an arrangement, which slides in over the one shown.
    private func show(arrangement id: BlockID) {
        guard id != selected else { return }
        hosts.select(id)
    }

    var debugFlights: String { GridView.describe(tileFlights) }


    /// Where the window is now, settled on: the latest place on its trail.
    func settleHere() {
        guard let space = selected else { return }
        let here = Settled(space: space, tile: hosts.arrangement(space)?.focused)
        settled.removeAll { $0 == here || ($0.space == space && $0.tile == nil) }
        settled.insert(here, at: 0)
        if settled.count > 200 { settled.removeLast() }
    }
}
