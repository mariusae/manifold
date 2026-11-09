import AppKit
import ManifoldCore
import WebKit
import ManifoldSyntax
import UniformTypeIdentifiers
import PDFKit

extension MainWindowController {
    // MARK: The space's outline, indexed (⌘P)


    /// The selected space's index, brought up to date: a tile's rows taken
    /// again only if its outline changed since (its items, or which outline
    /// it is), and then only those that changed; each tile's title as it is.
    @discardableResult
    func syncOutlineIndex() -> OutlineIndex<PlacementID, Outline.Item>? {
        guard let space = selected, let a = hosts.arrangement(space) else { return nil }
        let index = outlineIndexes[space] ?? OutlineIndex()
        outlineIndexes[space] = index
        if outlineIndexes.count > 4 {
            for k in outlineIndexes.keys where k != space && !allWorkspaces.contains(k) { outlineIndexes[k] = nil }
        }
        var present = Set<PlacementID>()
        for p in a.placements {
            present.insert(p.id)
            let title = hosts.block(p.block)?.displayTitle ?? ""
            let outline = views[p.id]?.outline
            let signature = outline.map { "\($0.serial).\($0.generation)" } ?? "-"
            guard index.signature(of: p.id) as? String != signature else {
                index.setTitle(p.id, title)
                continue
            }
            index.update(p.id, title: title, rows: outline?.items ?? [], signature: signature) {
                $0.detail.isEmpty ? $0.title : $0.title + " " + $0.detail
            }
            if let outline, !outline.indexed {
                // Its changes to the index as they come (a burst, once).
                outline.indexed = true
                outline.watch(self) { [weak self, weak outline] in
                    guard let self, let outline, !self.outlineSyncPending,
                          self.outlineIndexes[space]?.signature(of: p.id) as? String != "\(outline.serial).\(outline.generation)" else { return }
                    self.outlineSyncPending = true
                    DispatchQueue.main.async { [weak self] in
                        self?.outlineSyncPending = false
                        self?.syncOutlineIndex()
                    }
                }
            }
        }
        index.retain(present)
        return index
    }

    /// Where ⌘P begins in the space's rows: at the focused tile, or under
    /// it the item you're at in its outline — counted, not made.
    func spaceOutlineStart(_ a: ArrangementState) -> Int? {
        guard let index = syncOutlineIndex(), let focused = a.focused else { return nil }
        var row = 0
        for p in a.columns.joined() where hosts.block(p.block) != nil {
            if p.id == focused { return row + (views[p.id]?.outline?.current.map { $0 + 1 } ?? 0) }
            row += 1 + index.rows(of: p.id).count
        }
        return nil
    }

    /// ⌘P's rows for a query: the space's tiles by column, each with those
    /// of its outline's items holding every word of it (in the item, or the
    /// tile's name) — a text's headings, a source file's symbols, a
    /// terminal's commands, an agent's turns, a PDF's contents, a diff's
    /// files — found in the index; and the tile itself, if its name, its
    /// place, what runs in it or what that reports holds them. With nothing
    /// asked, the space's outline as it lies; asked, ranked by how well each
    /// matches (`OutlineIndex.score`: the row named exactly first), the
    /// shorter first, then as they lie.
    func spaceOutlineRows(_ a: ArrangementState, query: String) -> [FinderItem] {
        guard let index = syncOutlineIndex() else { return [] }
        let order = a.columns.joined().map(\.id)
        var found: [PlacementID: [Int]] = [:]
        for hit in index.find(query, in: order) { found[hit.tile] = hit.items }
        let words = query.lowercased().split(whereSeparator: \.isWhitespace).map(String.init)
        let ranking = !words.isEmpty
        var scores: [Int] = []
        // Which items are of the focused block's project (§2.6): first among equals.
        var inProject: [Bool] = []
        let project = focusedProject()
        let running = runningPrograms()
        var items: [FinderItem] = []
        for (c, column) in a.columns.enumerated() {
            for p in column {
                guard let b = hosts.block(p.block) else { continue }
                let ours = project.map { Self.block(b, isIn: $0) } ?? false
                let id = p.id
                var notes: [String] = []
                if a.columns.count > 1 { notes.append("column \(c + 1)") }
                if a.isDocked(p.id) { notes.append("docked") }
                if p.id == a.focused { notes.append("focused") }
                // Where it is; and for a terminal, what runs in it and what
                // that reports — searched by too.
                var detail = [b.place?.abbreviatingHome ?? ""]
                detail += running[b.id] ?? []
                if let r = b.statusRecord {
                    if let app = r.app { detail.append(app) }
                    if let msg = r.msg, !msg.isEmpty { detail.append(msg) }
                }
                let tileDetail = detail.filter { !$0.isEmpty }.joined(separator: " · ")
                let haystack = (b.displayTitle + " " + tileDetail).lowercased()
                if words.allSatisfy({ haystack.contains($0) }) {
                    items.append(FinderItem(symbol: Theme.symbolName(for: b), title: b.displayTitle, detail: tileDetail,
                                            note: notes.joined(separator: " · "), run: { [weak self] in self?.arrive(atTile: id) }))
                    // (Found by its place or what runs in it, not its name: below those named.)
                    if ranking { scores.append(max(OutlineIndex<PlacementID, Outline.Item>.score(b.displayTitle, query: query), 150)); inProject.append(ours) }
                }
                let rows = index.rows(of: id)
                let name = b.displayTitle
                guard let hits = found[id] else { continue }
                items.reserveCapacity(items.count + hits.count)
                for i in hits where rows.indices.contains(i) {
                    let item = rows[i]
                    // (Found by its tile's name alone: below those that say it.)
                    if ranking { scores.append(max(OutlineIndex<PlacementID, Outline.Item>.score(item.title, query: query), 100)); inProject.append(ours) }
                    items.append(FinderItem(symbol: item.code ? "chevron.forward" : "number", title: item.title,
                                            detail: item.detail.isEmpty ? name : name.isEmpty ? item.detail : name + " · " + item.detail,
                                            note: item.running ? "running" : item.failed ? "failed" : "", level: ranking ? 0 : item.level + 1,
                                            run: { [weak self] in
                        guard let self else { return }
                        self.arrive(atTile: id)
                        self.views[id]?.outline?.pick(i)
                    }))
                }
            }
        }
        guard ranking, scores.count == items.count else { return items }
        return items.indices.sorted { x, y in
            if scores[x] != scores[y] { return scores[x] > scores[y] }
            if inProject[x] != inProject[y] { return inProject[x] }
            if items[x].title.count != items[y].title.count { return items[x].title.count < items[y].title.count }
            return x < y
        }.map { items[$0] }
    }

    /// ⌘↩: the focused text between being edited and viewed — Markdown
    /// rendered (a note's too), anything else as it is on the grey of a
    /// page of code — in the same tile.
    /// ⌘↩, the tile's own thing to do: a text from editing to viewing or
    /// back; a notebook's cell run; an outline's row a checkbox, checked,
    /// a bullet again. (Those two take the key themselves; this is the
    /// menu's, titled by it.)
    @objc func toggleEditPreview(_ sender: Any?) {
        guard let f = focusedShown else { return }
        if let n = views[f.id] as? NotebookView { return n.runFocused() }
        if let o = views[f.id] as? OutlineNoteView { return o.cycleChecklist() }
        toggleMode(f.id)
    }

    /// Tile ▸ Interrupt (⌘.): a notebook's running cell stopped.
    @objc func interruptTile(_ sender: Any?) {
        guard let f = focusedShown, let n = views[f.id] as? NotebookView else { return NSSound.beep() }
        n.interrupt()
    }

    /// A text's tile from editing to viewing or back, in place: what was
    /// at its top still there, the caret (from an editor) and the tile's
    /// font going along.
    func toggleMode(_ id: PlacementID) {
        guard let a = arrangement, let p = a.placement(id), p.lens.isText, hosts.block(p.block)?.kind == .text else { return }
        let other: Lens = p.lens == .editor ? .preview : .editor
        let carry = { [weak self] (top: Double?) in
            guard let self, let a = self.arrangement, a.placement(id) != nil else { return }
            let fresh = ULID.make()
            var events: [Event] = []
            if let e = self.views[id] as? EditorView { events.append(.selection(placement: fresh, ranges: e.textView.selections.map(\.range))) }
            let kept = (self.hosts.block(p.block)?.views?[id] ?? [:]).filter { ["font", "markdown"].contains($0.key) }
            if !kept.isEmpty { events.append(.view(placement: fresh, kept)) }
            if !events.isEmpty { self.hosts.append(events, to: .block(p.block)) }
            if let top { self.pendingTopLines[fresh] = top }
            self.replace(id, with: p.block, lens: other, as: fresh)
        }
        if let e = views[id] as? EditorView { carry(e.topLine) }
        else if let m = views[id] as? MarkdownView { m.topLine(carry) }
        else { carry(nil) }
    }

    /// Edit ▸ Edit as Outline (⌥⌘↩): a note — any Markdown text — as an
    /// outline to edit, in the same tile; again, back to its editor.
    @objc func toggleOutliner(_ sender: Any?) {
        guard let f = focusedShown, canOutline(f) else { return NSSound.beep() }
        toggleOutliner(tile: f.id)
    }

    /// A tile of this space's text as an outline, or back to its editor.
    func toggleOutliner(tile id: PlacementID) {
        guard let p = arrangement?.placement(id), canOutline(hosts.block(p.block), lens: p.lens) else { return NSSound.beep() }
        let fresh = ULID.make()
        replace(id, with: p.block, lens: p.lens == .outliner ? .editor : .outliner, as: fresh)
    }

    /// Whether a tile's text can be an outline: a note, or a Markdown file.
    func canOutline(_ f: Shown) -> Bool { canOutline(f.block, lens: f.lens) }

    private func canOutline(_ b: Block?, lens: Lens) -> Bool {
        guard let b, b.kind == .text, lens.isText || lens == .outliner else { return false }
        return Lens.viewRendering(for: b.path) == .markdown
    }

    /// Edit as Outline, or Edit as Text, for a menu: the tile turned, if
    /// it's one here; else the text opened so, here.
    func outlinerItem(_ block: BlockID, tile: PlacementID?) -> NSMenuItem? {
        let b = hosts.block(block)
        if let tile, let p = arrangement?.placement(tile) {
            guard canOutline(b, lens: p.lens) else { return nil }
            let outline = p.lens == .outliner
            return ClosureMenuItem(outline ? "Edit as Text" : "Edit as Outline", symbol: outline ? "doc.text" : "list.bullet.indent") { [weak self] in
                self?.toggleOutliner(tile: tile)
            }
        }
        guard canOutline(b, lens: .editor) else { return nil }
        return ClosureMenuItem("Edit as Outline", symbol: "list.bullet.indent") { [weak self] in self?.show(block, lens: .outliner, .here) }
    }

    /// ⌃⌘↩: the other mode beside this one, both in view.
    @objc func editPreviewBeside(_ sender: Any?) {
        guard let f = focusedShown, f.lens.isText, f.block?.kind == .text else { return }
        let other: Lens = f.lens == .preview ? .editor : .preview
        show(f.placement.block, lens: other, .besideOpener(f.id), kind: .opened, context: other == .editor ? "edited beside" : "viewed beside", exact: true)
    }

    /// A block given to the system's app: a page's address to the browser,
    /// a file of this Mac to what opens it; else a beep.
    func openInSystem(_ id: BlockID) {
        guard let b = hosts.block(id) else { return NSSound.beep() }
        // A page of another host's own localhost, loaded through it: there
        // at its port forwarded here.
        if b.web?.viaHost == true, id.host != host.host, let address = b.web?.url,
           let url = URL(string: address), let h = url.host, WebAddress.isLoopback(h) {
            forward(url.port ?? (url.scheme == "https" ? 443 : 80), on: id.host) { local in
                guard let local, var parts = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return }
                parts.host = "localhost"
                parts.port = local
                if let here = parts.url { NSWorkspace.shared.open(here) }
            }
            return
        }
        if let address = b.web?.url, let url = URL(string: address) { NSWorkspace.shared.open(url); return }
        if let path = b.path, id.host == host.host { NSWorkspace.shared.open(URL(fileURLWithPath: path)); return }
        NSSound.beep()
    }

    static var clickModifiers: NSEvent.ModifierFlags? {
        guard let e = NSApp.currentEvent, [.leftMouseUp, .leftMouseDown, .otherMouseUp, .rightMouseUp].contains(e.type) else { return nil }
        return e.modifierFlags
    }

    /// `over`: ⌥ was held (else read off the click): what opens goes over
    /// the tile, not beside it.
    /// Schemes an address has without "//" after them.
    static let schemesWithoutSlashes: Set<String> = ["mailto", "tel", "sms", "facetime", "maps", "news", "data", "about"]

    func open(_ target: String, from placement: PlacementID?, here: Bool? = nil, over: Bool? = nil, as given: Disposition? = nil) {
        // As the click (or ↩) says, by the one rule; plain goes to it.
        var d = given ?? (over == true ? .over : Self.disposition ?? .goTo)
        if over == false, d == .over { d = .beside }
        let place: Where = placement.map { d == .over ? .over($0) : .besideOpener($0) } ?? .here
        // A link to a block (manifold:host/ulid, as a note's pill is): go to
        // it — and to a place in it, if the link names one (#command=7).
        if target.hasPrefix("manifold:"), let (b, fragment) = BlockID.link(target) {
            if hosts.whyMissing(b) != nil { return sayMissing(b) }
            follow(b, from: placement, d, context: "followed")
            if d == .system { return }
            linkFollowed(from: placement, to: b)
            if let fragment { goTo(fragment, in: b) }
            return
        }
        // An address: a scheme and "//" (or one that goes without, as
        // mailto: does) — not `README.md:781`, whose "README.md" a URL
        // would take for a scheme.
        if let url = URL(string: target), let scheme = url.scheme, scheme.count > 1, scheme != "file",
           target.contains("://") || Self.schemesWithoutSlashes.contains(scheme.lowercased()) {
            let inWeb = here ?? (d != .system)
            // A page named on another host (a remote terminal's dev server,
            // its own localhost; a site on a network only it is on) is a
            // web block of that host's, loaded through it (§7.6) — unless
            // it's from a page of the host's loaded from here, as that is.
            let from = placement.flatMap { shown($0)?.placement.block.host } ?? host.host
            let remote = from != host.host && (scheme == "http" || scheme == "https")
            let viaHost = remote && placement.flatMap { shown($0)?.block?.web?.viaHost } != false
            // Plain: to a page already showing the address, in any space.
            if inWeb, d == .goTo, let page = placedPage(url, on: from, viaHost: viaHost) {
                linkFollowed(from: placement, to: page)
                return goTo(page, near: placement)
            }
            // To the system's browser, a server on the host's own localhost
            // at its port forwarded here.
            if remote, !inWeb, let h = url.host, WebAddress.isLoopback(h) {
                let port = url.port ?? (scheme == "https" ? 443 : 80)
                forward(port, on: from) { local in
                    guard let local, var parts = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return }
                    parts.host = "localhost"
                    parts.port = local
                    if let here = parts.url { NSWorkspace.shared.open(here) }
                }
                return
            }
            openWeb(url, place: place, here: inWeb, context: target, on: remote ? from : nil, viaHost: viaHost)
            return
        }
        let base = placement.flatMap { shown($0)?.block }.flatMap { $0.terminal?.cwd ?? $0.place }
        let on = placement.flatMap { shown($0)?.placement.block.host } ?? host.host
        if on != host.host {
            // Another host's file: it says what it is.
            openRemote(target, on: on, base: base, from: placement, as: d)
            return
        }
        func resolve(_ text: String) -> String {
            var path = text.hasPrefix("file://") ? (URL(string: text)?.path ?? text) : text
            path = (path as NSString).expandingTildeInPath
            if !path.hasPrefix("/"), let base {
                path = (base as NSString).appendingPathComponent(path)
            }
            return URL(fileURLWithPath: path).standardizedFileURL.path
        }
        var path = resolve(target)
        var isDir: ObjCBool = false
        if !FileManager.default.fileExists(atPath: path, isDirectory: &isDir) {
            // grep's and compilers' path:line:column: the file, at that place.
            guard let location = FileLocation.split(target), let line = location.line,
                  case let base = resolve(location.path),
                  FileManager.default.fileExists(atPath: base, isDirectory: &isDir), !isDir.boolValue,
                  Self.isEditable(base) else {
                NSSound.beep()
                return
            }
            pendingJump = (base, line, location.column)
            follow(hosts.textBlock(for: base, on: on), lens: Lens.default(for: .text, path: base), from: placement, d, context: target)
            return
        }
        path = URL(fileURLWithPath: path).standardizedFileURL.path
        // ⇧⌘: a file or folder of this Mac to the system's app (Finder's).
        if on == host.host, d == .system {
            NSWorkspace.shared.open(URL(fileURLWithPath: path))
            return
        }
        if let (block, lens) = pathBlock(path, isDirectory: isDir.boolValue, on: on) {
            follow(block, lens: lens, from: placement, d, context: target)
        } else {
            NSWorkspace.shared.open(URL(fileURLWithPath: path))
        }
    }

    /// The block a file or folder shows as, made if there's none yet, and
    /// the lens it opens in; nil for a file of this machine Manifold leaves
    /// to another app. Another host's file is told by its name alone.
    func pathBlock(_ path: String, isDirectory: Bool, on: HostID) -> (BlockID, Lens)? {
        let local = on == host.host
        if isDirectory { return (hosts.directoryBlock(for: path, on: on), .directory) }
        if Lens.isMarkdown(path) { return (hosts.textBlock(for: path, on: on), .preview) }
        if Self.isHTML(path), local { return (host.webBlock(forFile: path), .web) }
        // A PDF is one even when it's plain text inside; an image that's
        // text (an SVG) is edited here.
        if let kind = Self.mediaKind(path), let client = hosts.client(on), !local || kind == .pdf || !Self.isEditable(path) {
            return (client.mediaBlock(for: path, kind: kind), kind == .pdf ? .pdf : .image)
        }
        if !local || Self.isEditable(path) { return (hosts.textBlock(for: path, on: on), Lens.default(for: .text, path: path)) }
        return nil
    }

    /// Whether `pathBlock` would open a file, without opening it: asked
    /// as a drag moves, so what it reads of a file here is kept a while.
    func pathOpens(_ path: String, isDirectory: Bool, on: HostID) -> Bool {
        let local = on == host.host
        if isDirectory || Lens.isMarkdown(path) || !local || Self.isHTML(path) { return true }
        if let kind = Self.mediaKind(path), kind == .pdf || kind == .image { return true }
        if let (opens, when) = opensKnown[path], when.timeIntervalSinceNow > -30 { return opens }
        let opens = Self.isEditable(path)
        opensKnown[path] = (opens, Date())
        return opens
    }


    /// An address typed (in a page's bar) opened in a web tile:
    /// an attached host's name, with a port (`anotherone:8080`) or in a whole
    /// address (`http://anotherone:8080/`), is that host's own localhost — the
    /// port forwarded here first; anything else as it is.
    func openAddress(_ typed: String, place: Where) {
        let q = typed.trimmingCharacters(in: .whitespaces)
        var target: (host: HostID, port: Int, scheme: String, rest: String)?
        switch WebAddress.parse(q) {
        case let .hostPort(name, port, rest):
            if let h = hostNamedInAddress(name) { target = (h, port, "http", rest) } else if let u = URL(string: "http://\(name):\(port)\(rest)") {
                return openWeb(u, place: place, here: true, context: q)
            }
        case let .page(address):
            guard let url = URL(string: address) else { return }
            if let name = url.host, url.scheme == "http" || url.scheme == "https", let h = hostNamedInAddress(name) {
                var rest = url.path.isEmpty ? "/" : url.path
                if let qs = url.query { rest += "?" + qs }
                target = (h, url.port ?? (url.scheme == "https" ? 443 : 80), url.scheme ?? "http", rest)
            } else {
                return openWeb(url, place: place, here: true, context: q)
            }
        case let .search(words):
            guard let u = URL(string: "https://duckduckgo.com/?q=" + (words.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? words)) else { return }
            return openWeb(u, place: place, here: true, context: q)
        }
        guard let target else { return }
        forward(target.port, on: target.host) { [weak self] local in
            guard let local, let u = URL(string: "\(target.scheme)://localhost:\(local)\(target.rest)") else { return }
            self?.openWeb(u, place: place, here: true, context: q)
        }
    }

    /// The attached host an address names (its label), connected or not.
    func hostNamedInAddress(_ name: String) -> HostID? {
        let n = name.lowercased()
        return hosts.all.first { !$0.transport.isLocal && hosts.label(of: $0.host).lowercased().replacingOccurrences(of: " ", with: "-") == n }?.host
    }

    /// An address: in the web lens (where `here` says), else the system's
    /// browser. A web block of this Mac's, or of the host given, loaded
    /// through it if `viaHost` (§7.6).
    func openWeb(_ url: URL, place: Where, here: Bool, context: String? = nil, on h: HostID? = nil, viaHost: Bool = false) {
        if (url.scheme == "http" || url.scheme == "https") && here {
            let client = h.flatMap { hosts.client($0) } ?? host
            show(client.newWeb(url: url.absoluteString, viaHost: viaHost && client.isRemote), lens: .web, place, context: context ?? url.absoluteString)
        } else {
            NSWorkspace.shared.open(url)
        }
    }

    /// Opens a path on another host: a folder if it ends in a slash, or if
    /// the host lists it as one (asked: it can't be looked at from here);
    /// a picture or a PDF by its name; else text, Markdown by its name;
    /// `path:line:column` as from this host.
    private func openRemote(_ target: String, on: HostID, base: String?, from: PlacementID?, as d: Disposition) {
        var text = target
        var line: Int?, column: Int?
        if let loc = FileLocation.split(target), loc.line != nil {
            text = loc.path
            line = loc.line
            column = loc.column
        }
        var path = text.hasPrefix("file://") ? (URL(string: text)?.path ?? text) : text
        if !path.hasPrefix("/") && !path.hasPrefix("~"), let base { path = base.appendingPathComponent(path) }
        if path.hasSuffix("/") {
            follow(hosts.directoryBlock(for: String(path.dropLast()), on: on), lens: .directory, from: from, d, context: target)
        } else if let kind = Self.mediaKind(path), let client = hosts.client(on) {
            follow(client.mediaBlock(for: path, kind: kind), lens: kind == .pdf ? .pdf : .image, from: from, d, context: target)
        } else if line == nil, let client = hosts.client(on) {
            // No slash: a folder if the host can list it (/home/marius), else
            // a file — as when it can't be asked.
            var asked = path
            if asked == "~" || asked.hasPrefix("~/"), let home = client.home { asked = home + asked.dropFirst() }
            client.listFolder(asked) { [weak self] entries in
                guard let self else { return }
                if entries != nil {
                    self.follow(self.hosts.directoryBlock(for: path, on: on), lens: .directory, from: from, d, context: target)
                } else {
                    self.follow(self.hosts.textBlock(for: path, on: on), lens: Lens.default(for: .text, path: path), from: from, d, context: target)
                }
            }
        } else {
            if let line { pendingJump = (path, line, column) }
            follow(hosts.textBlock(for: path, on: on), lens: Lens.default(for: .text, path: path), from: from, d, context: target)
        }
    }


    private func settings() -> SettingsWindow {
        if let w = settingsWindow { return w }
        let w = SettingsWindow()
        w.source.appearance = { [weak self] in self?.hosts.state.appearance ?? Appearance() }
        w.source.setAppearance = { [weak self] a in self?.hosts.setAppearance(a) }
        w.source.settings = { [weak self] in self?.desk.settings ?? Settings() }
        w.source.setSettings = { [weak self] s in
            TerminalView.copyOnSelect = s.copyOnSelect
            self?.host.setSettings(s)
        }
        // Language servers: what runs for which files, and how each is doing.
        w.languageServers.source = { [weak self] in self?.desk.settings.languageServers ?? LanguageServerConfig.defaults }
        w.languageServers.states = { [weak self] in
            guard let self else { return [:] }
            var out: [String: String] = [:]
            for c in self.hosts.all {
                for (key, state) in c.languageServerStates { out[self.hosts.label(of: c.host) + ": " + key] = state }
            }
            return out
        }
        w.languageServers.onChange = { [weak self] configs in
            guard let self else { return }
            var s = self.desk.settings
            s.languageServers = configs
            self.host.setSettings(s)
        }
        // And for one host: its own, as its preferences (§7.2).
        w.languageServers.hosts = { [weak self] in
            guard let self else { return [] }
            return self.hosts.all.map { ($0.host, self.hosts.label(of: $0.host)) }
        }
        w.languageServers.preferences = { [weak self] h in self?.hosts.client(h)?.desk.preferences }
        w.languageServers.setPreferences = { [weak self] h, p, done in self?.hosts.setPreferences(p, on: h, done: done) }
        // Remoting: the providers that reach hosts (§8), kept in the hosts file.
        w.remoting.source = { HostsFile.load().providers }
        w.remoting.onChange = { providers in
            var file = HostsFile.load()
            file.providers = providers
            file.save()
        }
        w.remoting.onAttach = { [weak self] in self?.attachToHost(nil) }
        settingsWindow = w
        return w
    }

    @objc func showSettings(_ sender: Any?) { settings().show() }
    @objc func showLanguageServers(_ sender: Any?) { settings().show(.languageServers) }

    /// Settings ▸ Language Servers, set for one host.
    func showLanguageServers(for host: HostID) {
        let w = settings()
        w.languageServers.loadViewIfNeeded()
        w.languageServers.select(host)
        w.show(.languageServers)
    }
    @objc func showRemoting(_ sender: Any?) { settings().show(.remoting) }

    /// Debugging: Settings — "show [pane]", "tint <name>", or nothing: its state.
    func debugSettings(_ arg: String) -> String {
        let words = arg.split(separator: " ").map(String.init)
        switch words.first {
        case "show":
            let pane = words.count > 1 ? SettingsWindow.Pane.allCases.first { "\($0)".lowercased() == words[1].lowercased() } : nil
            settings().show(pane)
        case "close": settingsWindow?.close()
        case "lsp":
            // "settings lsp [all | host <name> | <language> <column> <text> | root <markers> | clear]".
            let w = settings()
            w.show(.languageServers)
            return w.languageServers.debug(words.dropFirst().joined(separator: " "))
        case "advanced":
            // "settings advanced on|off": advanced typography, as its checkbox.
            settings().show()
            settings().appearance.debugSetAdvanced(words.dropFirst().first == "on")
        case "type":
            // "settings type <role> [family=<name with _ for spaces>] [size=n] [weight=n] [leading=n]
            // [tracking=n] [features=a,b] [measure=n] [gap=n]": custom typography, as the pane sets it.
            let w = settings()
            w.show(.typography)
            guard words.count > 1, let role = FontRole(rawValue: words[1]) else { return w.typography.debugState }
            w.typography.debugSet(role: role) { s in
                for kv in words.dropFirst(2) {
                    let parts = kv.split(separator: "=", maxSplits: 1).map(String.init)
                    guard parts.count == 2 else { continue }
                    let v = parts[1]
                    switch parts[0] {
                    case "family": s.family = v == "system" ? "" : v.replacingOccurrences(of: "_", with: " ")
                    case "size": s.size = Double(v) ?? s.size
                    case "weight": s.weight = Int(v) ?? s.weight
                    case "leading": s.lineHeight = Double(v) ?? s.lineHeight
                    case "tracking": s.tracking = Double(v) ?? s.tracking
                    case "features": s.features = v.replacingOccurrences(of: ",", with: ", ")
                    case "measure": s.measure = Double(v) ?? s.measure
                    case "gap": s.paragraphSpacing = Double(v) ?? s.paragraphSpacing
                    default: break
                    }
                }
            }
            return w.typography.debugState
        case "tint":
            guard words.count > 1, let t = Tint(rawValue: words[1]) else { return "tints: \(Tint.allCases.map(\.rawValue).joined(separator: " "))" }
            settings().appearance.loadViewIfNeeded()
            settings().appearance.debugPickTint(t)
        case "colortheme":
            guard words.count > 1, Palette.all.contains(where: { $0.id == words[1] }) else { return "themes: \(Palette.all.map(\.id).joined(separator: " "))" }
            settings().appearance.loadViewIfNeeded()
            settings().appearance.debugPickColorTheme(words[1])
        default: break
        }
        return settingsWindow?.debugState ?? "no settings window"
    }

    func debugRemoting(_ arg: String) -> String {
        guard let r = settingsWindow?.remoting, r.isViewLoaded else { return "no remoting window" }
        if arg == "add" { r.debugAdd() }
        return r.debugRows
    }

    /// Attach to Host…: a destination, as ssh takes them, or
    /// `provider:name` for a `manifold-remote-<provider>` on the PATH.
    @objc func attachToHost(_ sender: Any?) {
        guard let window else { return }
        let alert = NSAlert()
        alert.messageText = "Attach to a Host"
        alert.informativeText = "A provider (Settings ▸ Remoting configures them) and a destination it understands. Manifold installs its server there, in ~/.manifold/bin, if it isn't already."
        let providers = HostsFile.load().providers
        let box = NSView(frame: NSRect(x: 0, y: 0, width: 300, height: 28))
        let popup = NSPopUpButton(frame: NSRect(x: 0, y: 2, width: 110, height: 24), pullsDown: false)
        popup.addItems(withTitles: providers.map(\.name))
        popup.controlSize = .small
        let field = NSTextField(frame: NSRect(x: 118, y: 2, width: 182, height: 24))
        field.placeholderString = "user@host"
        box.addSubview(popup)
        box.addSubview(field)
        alert.accessoryView = box
        alert.addButton(withTitle: "Attach")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field
        alert.beginSheetModal(for: window) { [weak self] response in
            guard let self, response == .alertFirstButtonReturn else { return }
            let target = field.stringValue.trimmingCharacters(in: .whitespaces)
            let provider = popup.titleOfSelectedItem ?? "ssh"
            // `provider:target` typed in the field says the provider itself.
            let dest = Destination(target).flatMap { $0.provider != "ssh" || provider == "ssh" ? $0 : nil } ?? Destination(provider: provider, target: target)
            guard !dest.target.isEmpty else { return }
            self.attach(dest)
        }
    }

    /// Project Settings… (§2.6): which indexer makes its index (or none),
    /// with what command, and whether its working copy moving indexes it
    /// again — kept in its host's desk, for every Mac attached.
    func editProject(_ project: Project, on client: HostClient) {
        guard let window else { return }
        let alert = NSAlert()
        alert.messageText = "\(project.name) Settings"
        alert.informativeText = "How \(project.root.abbreviatingHome) is indexed on \(hosts.label(of: client.host)). Automatic picks the indexer by the markers at its root (Cargo.toml, go.mod, package.json…), else by its files' language."
        let box = FlippedView(frame: NSRect(x: 0, y: 0, width: 340, height: 104))
        let popup = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 340, height: 26), pullsDown: false)
        let ids = SCIPIndexer.defaults.map(\.id)
        popup.addItems(withTitles: ["Automatic"] + ids + ["None"])
        popup.selectItem(withTitle: project.indexer.map { $0 == "none" ? "None" : $0 } ?? "Automatic")
        let command = NSTextField(frame: NSRect(x: 0, y: 36, width: 340, height: 24))
        command.placeholderString = "The indexer's own command; {out} the index's file"
        command.stringValue = project.indexCommand ?? ""
        command.font = .systemMono(ofSize: 11, weight: .regular)
        let again = NSButton(checkboxWithTitle: "Index again when the working copy moves", target: nil, action: nil)
        again.frame = NSRect(x: 0, y: 72, width: 340, height: 22)
        again.state = project.reindexOnCheckout == false ? .off : .on
        for v in [popup, command, again] { box.addSubview(v) }
        alert.accessoryView = box
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")
        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertFirstButtonReturn else { return }
            var p = project
            let chosen = popup.titleOfSelectedItem ?? "Automatic"
            p.indexer = chosen == "Automatic" ? nil : chosen == "None" ? "none" : chosen
            let c = command.stringValue.trimmingCharacters(in: .whitespaces)
            p.indexCommand = c.isEmpty ? nil : c
            p.reindexOnCheckout = again.state == .on ? nil : false
            guard p != project else { return }
            client.propose(.project(p)) { error in
                if let error { self?.toast.say(error) }
            }
        }
    }

    /// A host's own preferences, as every Mac attached to it shares them:
    /// its shell here; its language servers in Settings' table, set for it.
    /// The host says if it can't do as asked.
    func editPreferences(_ host: HostID) {
        guard let window, let c = hosts.client(host) else { return }
        let prefs = c.desk.preferences
        let alert = NSAlert()
        alert.messageText = "Preferences for \(hosts.label(of: host))"
        alert.informativeText = "Every Mac attached to the host shares these."
        let w: CGFloat = 420
        let box = NSView(frame: NSRect(x: 0, y: 0, width: w, height: 76))
        func label(_ text: String, y: CGFloat, small: Bool = false) {
            let l = NSTextField(wrappingLabelWithString: text)
            l.font = small ? UIType.footnote : .systemFont(ofSize: 13, weight: .medium)
            l.textColor = small ? .secondaryLabelColor : .labelColor
            let h = l.sizeThatFits(NSSize(width: w, height: 200)).height
            l.frame = NSRect(x: 0, y: y, width: w, height: h)
            box.addSubview(l)
        }
        // The shell new terminals start.
        label("Shell", y: 54)
        let shell = NSTextField(frame: NSRect(x: 0, y: 26, width: w, height: 24))
        shell.placeholderString = "Login shell"
        shell.stringValue = prefs.shell ?? ""
        box.addSubview(shell)
        label("A name on the host's PATH, or a path. Shells already running keep theirs.", y: 4, small: true)
        alert.accessoryView = box
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")
        // Its language servers: the table, set for this host.
        alert.addButton(withTitle: "Language Servers…")
        alert.window.initialFirstResponder = shell
        alert.beginSheetModal(for: window) { [weak self] response in
            guard let self, response != .alertSecondButtonReturn else { return }
            var p = prefs
            let typed = shell.stringValue.trimmingCharacters(in: .whitespaces)
            p.shell = typed.isEmpty ? nil : typed
            if p != prefs {
                self.hosts.setPreferences(p, on: host) { [weak self] error in
                    guard let self, let error else { return }
                    self.preferencesRefused(host, error)
                }
            }
            if response == .alertThirdButtonReturn { self.showLanguageServers(for: host) }
        }
    }

    /// A new variable for a host (§8.6): its inspector shown, a row in
    /// its Environment to type it in.
    func addEnvironmentVariable(_ host: HostID) {
        inspect(.host(host.raw), open: true)
        refreshInspector(now: true)
        inspector?.list.startAdding(in: "insp:host-environment")
    }

    private func preferencesRefused(_ host: HostID, _ why: String) {
        guard let window else { return }
        let failed = NSAlert()
        failed.messageText = "\(hosts.label(of: host)) kept its preferences"
        failed.informativeText = why
        failed.beginSheetModal(for: window)
    }

    func attach(_ dest: Destination) {
        hosts.attach(dest) { [weak self] result in
            guard let self else { return }
            switch result {
            case .success(let h):
                // The workspace lives on that host, as its terminal does.
                self.newWorkspace(on: h, cwd: nil)
            case .failure(let error):
                let failed = NSAlert()
                failed.messageText = "Couldn't attach to \(dest)"
                failed.informativeText = "\(error)"
                if let window = self.window { failed.beginSheetModal(for: window) } else { failed.runModal() }
            }
        }
    }


    /// The block a path opens as, and how it's shown: a folder as a
    /// listing, an HTML file or an address as a page, a PDF or picture as
    /// itself, text in an editor (with `wait`, $EDITOR's, Markdown too);
    /// `made` if there was none for it before.
    func blockAndLens(forPath path: String, on: HostID, wait: Bool) -> (block: BlockID, lens: Lens, made: Bool) {
        if WebAddress.looksLikeURL(path) { return (host.newWeb(url: path), .web, true) }
        let isDir = path.hasSuffix("/") || on == host.host && (try? FileManager.default.attributesOfItem(atPath: path))?[.type] as? FileAttributeType == .typeDirectory
        let media = Self.mediaKind(path)
        let html = Self.isHTML(path) && on == host.host
        let known = hosts.blocks.contains { $0.id.host == on && $0.path == path }
        let block = isDir ? hosts.directoryBlock(for: path, on: on)
            : html ? host.webBlock(forFile: path)
            : media.flatMap { kind in hosts.client(on)?.mediaBlock(for: path, kind: kind) } ?? hosts.textBlock(for: path, on: on)
        let lens: Lens = isDir ? .directory
            : html ? .web : media == .pdf ? .pdf : media == .image ? .image : (wait ? .editor : Lens.default(for: .text, path: path))
        return (block, lens, !known)
    }

    /// Fonts came or went: what's set in them set again — the views, the
    /// terminals, Settings' list of themes.
    func fontsChanged() {
        for case let v as FollowsFontTheme in views.values { v.fontThemeChanged() }
        GhosttyRuntime.shared.reapply()
        settingsWindow?.refresh(tables: false)
    }

    /// A `mani` command for the app (`ManiDesk`).
    func maniCommand(on: HostID, id: Int, client: Int, _ request: ManiRequest) {
        maniDesk.handle(request, from: ManiDesk.Asker(host: on, id: id, client: client))
    }

    func maniCommandEnded(on: HostID, id: Int, client: Int) {
        maniDesk.ended(ManiDesk.Asker(host: on, id: id, client: client))
    }

    /// A block the host made for a command (`mani diff`): shown beside
    /// the block the command ran in, else here, and the command answered.
    func showRequest(on: HostID, id: Int, client: Int, block: BlockID, beside: BlockID?) {
        let besidePlacement = beside.flatMap { b in
            allWorkspaces.lazy.compactMap { self.hosts.arrangement($0)?.placements.first { $0.block == b } }.first
        }
        if let besidePlacement, let aid = allWorkspaces.first(where: { hosts.arrangement($0)?.placement(besidePlacement.id) != nil }), aid != selected {
            hosts.select(aid)
        }
        let lens = hosts.block(block).map { Lens.default(for: $0.kind, path: $0.path) } ?? .diff
        show(block, lens: lens, besidePlacement.map { .besideOpener($0.id) } ?? .here, context: "asked from the shell")
        hosts.propose(.openDone(id: id, client: client), on: on)
        NSApp.activate()
    }

    /// Answers `open --wait` commands whose placements have all gone, and
    /// discards the blocks they made that nothing else took up.
    func checkOpenWaits() {
        guard !openWaits.isEmpty else { return }
        let present = Set(allWorkspaces.compactMap { hosts.arrangement($0) }.flatMap { $0.placements.map(\.id) })
        let placedBlocks = Set(allWorkspaces.compactMap { hosts.arrangement($0) }.flatMap { $0.placements.map(\.block) })
        openWaits.removeAll { wait in
            if wait.placements.allSatisfy({ !present.contains($0) }) {
                hosts.propose(.commandReply(id: wait.id, client: wait.client, ManiReply(status: 0)), on: wait.host)
                for b in wait.made where !placedBlocks.contains(b) && hosts.block(b)?.text?.isDirty != true {
                    hosts.propose(.discard(b))
                }
                return true
            }
            return false
        }
    }

    @objc func restartServer(_ sender: Any?) {
        let alert = NSAlert()
        alert.messageText = "Restart Manifold's server?"
        alert.informativeText = "Everything is kept. Each shell starts again in the same directory, under its recent output; programs running in them are ended."
        alert.addButton(withTitle: "Restart Server")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        HostClient.stopServer()
    }

    @objc func stopServer(_ sender: Any?) {
        let alert = NSAlert()
        alert.messageText = "Quit and end all sessions?"
        alert.informativeText = "Every shell in Manifold will be closed. Everything is kept, and terminals start fresh shells next time."
        alert.addButton(withTitle: "End Sessions and Quit")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        HostClient.stopServer()
        NSApp.terminate(nil)
    }

    /// Names an arrangement (§3.3): what it's called, in place of what it holds.
    func renameSpace(_ id: BlockID) {
        guard let window, let a = hosts.arrangement(id) else { return }
        let alert = NSAlert()
        alert.messageText = "Name This Space"
        alert.informativeText = "Called this in place of what it holds (its blocks' folder). Empty, it's named for that again."
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 240, height: 24))
        field.stringValue = a.title ?? ""
        field.placeholderString = title(of: a)
        alert.accessoryView = field
        alert.addButton(withTitle: "Name")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field
        alert.beginSheetModal(for: window) { [weak self] response in
            guard let self else { return }
            if response == .alertFirstButtonReturn {
                self.hosts.append(.title(field.stringValue), to: .block(id))
            }
            self.render()
        }
    }
}
