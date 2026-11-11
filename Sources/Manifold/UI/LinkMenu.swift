import AppKit
import ManifoldCore
import Quartz

/// What a ⌘-right-clicked thing is, for the items about it every such menu
/// has (`aboutItems`): its place, if it has one (a file at a line, a name
/// in a block); how it's written in a note, and how to an agent.
struct LinkSubject {
    var place: Place?
    /// Said in a note's link, and for an address, the address itself.
    var label: String
    /// What an agent's told to look at: an address, a path and its line,
    /// a name and where it is.
    var forAgent: String
    /// An address: linked to as it is, no block of its own.
    var address: String?
    /// Where an agent asked about it, none in the space, starts.
    var cwd: String?
}

extension MainWindowController {
    /// What can be done with a link ⌘-right-clicked in a tile (an address,
    /// a path, `path:line`): each way a ⌘-click opens it, its click said
    /// beside it — beside the tile (a page, as a web page), over it, in the
    /// system's app — then copied, what every such menu has (`aboutItems`),
    /// and a file's Quick Look and folder.
    func linkMenu(_ target: String, from placement: PlacementID?, on given: HostID? = nil) -> NSMenu {
        let menu = NSMenu()
        let address = Self.isAddress(target)
        let on = given ?? placement.flatMap { shown($0)?.placement.block.host } ?? host.host
        let local = on == host.host
        // The file it names, its line and column left off (an address: none).
        let location = address ? nil : FileLocation.split(target)
        let path = address ? nil : (location?.path ?? target)
        func item(_ title: String, _ symbol: String, click: String? = nil, _ run: @escaping () -> Void) {
            menu.addItem(Self.menuItem(title, symbol, click: click, run))
        }

        item(address ? "Open as Web Page" : "Open", "arrow.up.forward.square", click: "⌘-click") { [weak self] in self?.open(target, from: placement, as: .beside) }
        item("Open Over", "square.on.square", click: "⌥⌘-click") { [weak self] in self?.open(target, from: placement, as: .over) }
        item("Open in \(Self.systemApp(for: target, path: local ? path : nil) ?? "Default App")", "arrow.up.right.square",
             click: "⇧⌘-click") { [weak self] in self?.open(target, from: placement, as: .system) }
        menu.addItem(.separator())
        if address {
            item("Copy Address", "doc.on.doc") { NSPasteboard.copy(target) }
        } else if let path {
            item("Copy Path", "doc.on.doc") { NSPasteboard.copy(path) }
            if location?.line != nil { item("Copy Path and Line", "text.line.first.and.arrowtriangle.forward") { NSPasteboard.copy(target) } }
            item("Copy Name", "textformat") { NSPasteboard.copy((path as NSString).lastPathComponent) }
        }
        let subject: LinkSubject
        if address {
            subject = LinkSubject(place: nil, label: target, forAgent: target, address: target,
                                  cwd: placement.flatMap { shown($0)?.block?.place })
        } else {
            let p = path ?? target
            let line = location?.line
            subject = LinkSubject(place: Place(file: p, on: on, at: line.map { .line($0) }),
                                  label: (p as NSString).lastPathComponent + (line.map { ":\($0)" } ?? ""),
                                  forAgent: target, address: nil, cwd: (p as NSString).deletingLastPathComponent)
        }
        aboutItems(subject, from: placement, to: menu)
        if let path {
            menu.addItem(.separator())
            item("Quick Look", "eye") { [weak self] in self?.quickLook(path, on: on) }
            // Shown chosen in Manifold's folders: its own folder's, its
            // project's (a project made, else its repository); and, this
            // Mac's, in the Finder.
            let folder = (path as NSString).deletingLastPathComponent
            if !folder.isEmpty {
                item("Reveal in Folder", "folder") { [weak self] in self?.reveal(path, in: folder, on: on, from: placement) }
                let project = projectRoot(from: folder, on: on)
                if project != folder, folder.hasPrefix(project) {
                    item("Reveal in Project", Theme.projectSymbol) { [weak self] in self?.reveal(path, in: project, on: on, from: placement) }
                }
            }
            if local {
                item("Reveal in Finder", "magnifyingglass") {
                    NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: (path as NSString).expandingTildeInPath)])
                }
            }
        }
        return menu
    }

    /// What a link ⌘ marks carries dragged: a block's (a reference), the
    /// block at its place; an address, the address; a file, the file at its
    /// line — a link where links are taken, the file elsewhere (another
    /// host's fetched as it's dropped).
    func linkDrag(_ target: String, from placement: PlacementID?, on given: HostID?) -> NSPasteboardWriting? {
        let on = given ?? placement.flatMap { shown($0)?.placement.block.host } ?? host.host
        if target.hasPrefix("manifold:"), let (b, fragment) = BlockID.link(target) {
            return Drags.place?(Place(block: b, at: fragment.flatMap { Locator(fragment: $0) }), nil)
        }
        if Self.isAddress(target) { return URL(string: target).map { $0 as NSURL } }
        let location = FileLocation.split(target)
        let path = location?.path ?? target
        return Drags.writer(Drags.place?(Place(file: path, on: on, at: location?.line.map { .line($0) }), nil))
    }

    /// A file shown chosen in a folder's tile (a project's): gone to where
    /// one shows the folder, else beside; the folders on the way opened.
    func reveal(_ path: String, in root: String, on host: HostID, from placement: PlacementID?) {
        let block = hosts.directoryBlock(for: root, on: host)
        // Shown already: gone to; else a tile beside (the block may be new,
        // not known here yet — shown as it comes).
        if isPlaced(block) {
            goTo(block, near: placement)
        } else {
            show(block, lens: .directory, .besideOrHere(placement), context: "revealed \((path as NSString).lastPathComponent)")
        }
        // Its view made at the render (a folder new to the host, once the
        // host has made its block): told then.
        retry(66, every: 0.15) { [weak self] in
            guard let v = self?.views.values.lazy.compactMap({ $0 as? DirectoryView }).first(where: { $0.block == block }) else { return false }
            v.reveal(path)
            return true
        }
    }

    /// A menu item that runs `run`, its symbol, and the click that does the
    /// same said under its title.
    static func menuItem(_ title: String, _ symbol: String, click: String? = nil, _ run: @escaping () -> Void) -> NSMenuItem {
        let i = ClosureMenuItem(title, symbol: symbol, run)
        if let click, #available(macOS 14.4, *) { i.subtitle = click }
        return i
    }

    /// What every ⌘-right-click menu has, about the thing: a link to it
    /// copied (a pill where it's pasted in a note), a link to it put in a
    /// note (a new one, or one in this space), an agent asked about it.
    func aboutItems(_ s: LinkSubject, from placement: PlacementID?, to menu: NSMenu) {
        menu.addItem(.separator())
        if let place = s.place {
            menu.addItem(Self.menuItem("Copy as Link", "link") { [weak self] in
                self?.resolve(place) { r in
                    guard let self, let r else { return NSSound.beep() }
                    self.copyLink(to: r.block, fragment: r.at?.fragment)
                }
            })
        }
        let notes = NSMenu()
        notes.addItem(Self.menuItem("New Note", "square.and.pencil") { [weak self] in self?.addToNote(nil, s, from: placement) })
        var seen = Set<BlockID>()
        let inSpace = (arrangement?.placements ?? []).compactMap { p in hosts.block(p.block).flatMap { $0.isNote ? $0 : nil } }
            .filter { seen.insert($0.id).inserted }
        if !inSpace.isEmpty { notes.addItem(.separator()) }
        for n in inSpace {
            notes.addItem(Self.menuItem(Self.linkTitle(n), Theme.noteSymbol) { [weak self] in self?.addToNote(n.id, s, from: placement) })
        }
        let add = NSMenuItem(title: "Add to Note", action: nil, keyEquivalent: "")
        add.setSymbol("note.text.badge.plus", size: 12)
        add.submenu = notes
        menu.addItem(add)
        menu.addItem(Self.menuItem("Ask Agent About This", "sparkle") { [weak self] in self?.askAgentAbout(s) })
    }

    /// A link to the thing put in a note — a new one beside the tile, or
    /// at the end of one in the space — as a line of its own.
    func addToNote(_ note: BlockID?, _ s: LinkSubject, from placement: PlacementID?) {
        let write = { [weak self] (link: String) in
            guard let self else { return }
            if let note, let b = self.hosts.block(note), let text = b.text {
                let end = text.text.count
                let before = end == 0 || text.text.string.hasSuffix("\n") ? "" : "\n"
                self.hosts.append(.edit([TextEdit(TextRange(end, end), before + link + "\n")]), to: .block(note))
                self.toast.show("Added to \(Self.linkTitle(b))", action: "Show", for: 4) { [weak self] in self?.arrive(note, from: placement) }
            } else {
                let client = self.hosts.client(self.focusedHost) ?? self.host
                let n = client.newNote(home: s.cwd, text: link + "\n\n")
                self.show(n, lens: .editor, self.opener(placement), context: "a note about \(s.label)")
            }
        }
        if let address = s.address { return write("[\(s.label)](\(address))") }
        guard let place = s.place else { return NSSound.beep() }
        resolve(place) { r in
            guard let r else { return NSSound.beep() }
            write("[\(s.label.replacingOccurrences(of: "]", with: "\\]"))](\(Self.address(r.block, anchor: r.at?.fragment)))")
        }
    }

    /// An agent asked about the thing: the space's agent most lately used
    /// has it typed into its prompt, not sent — the question's yours to
    /// finish — and is gone to; with none, a new one beside, told to look
    /// at it and wait for the question.
    func askAgentAbout(_ s: LinkSubject) {
        if let agent = agentForAsking() {
            hosts.propose(.input(block: agent, text: s.forAgent + " "))
            arrive(agent, from: nil)
            toast.say("\(s.label) is in \(hosts.block(agent)?.displayTitle ?? "the agent")'s prompt: ask away")
            return
        }
        guard let client = hosts.client(focusedHost) else { return NSSound.beep() }
        let prompt = "Have a look at \(s.forAgent). I'll ask you about it next; for now, just say in a line what it is."
        let agent = client.newAgent(cwd: s.cwd, command: desk.settings.agentCommand + " " + prompt.shellQuoted)
        show(agent, lens: .agent, .here, context: "asked about \(s.label)")
    }

    /// A file shown in Quick Look's panel: this Mac's as it is; another
    /// host's, a copy fetched first (not too big a one).
    func quickLook(_ path: String, on: HostID) {
        let p = (path as NSString).expandingTildeInPath
        if on == host.host { return QuickLooker.shared.show(URL(fileURLWithPath: p)) }
        guard let client = hosts.client(on) else { return NSSound.beep() }
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("manifold-quicklook-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let local = dir.appendingPathComponent((p as NSString).lastPathComponent)
        var data = Data()
        toast.say("Fetching \((p as NSString).lastPathComponent)…")
        client.readFile(p, limit: 64 << 20, onData: { data.append($0) }) { [weak self] error in
            if let error { self?.toast.say("Couldn't look at it: \(error)"); return }
            do {
                try data.write(to: local)
                QuickLooker.shared.show(local)
            } catch {
                self?.toast.say("Couldn't look at it: \(error.localizedDescription)")
            }
        }
    }

    /// Whether a link's an address (a scheme and what follows), not a file.
    static func isAddress(_ target: String) -> Bool { TerminalLinks.Link(range: 0..<0, target: target).path == nil }

    /// The app the system opens a link in (⇧⌘-click): an address's
    /// browser, a file of this Mac's app (a folder's, the Finder); nil if
    /// it can't be said (another host's file).
    static func systemApp(for target: String, path: String?) -> String? {
        let url: URL?
        if isAddress(target) {
            url = URL(string: target)
        } else if let path {
            let p = (path as NSString).expandingTildeInPath
            url = FileManager.default.fileExists(atPath: p) ? URL(fileURLWithPath: p) : nil
        } else {
            url = nil
        }
        guard let url, let app = NSWorkspace.shared.urlForApplication(toOpen: url) else { return nil }
        return FileManager.default.displayName(atPath: app.path).replacingOccurrences(of: ".app", with: "")
    }
}

/// Quick Look's panel, for one file at a time.
final class QuickLooker: NSObject, QLPreviewPanelDataSource {
    static let shared = QuickLooker()
    private(set) var url: URL?

    func show(_ url: URL) {
        self.url = url
        guard let panel = QLPreviewPanel.shared() else { return }
        panel.dataSource = self
        panel.reloadData()
        panel.makeKeyAndOrderFront(nil)
    }

    func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int { url == nil ? 0 : 1 }
    func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> QLPreviewItem! { url as NSURL? }
}

/// The link menu (`MainWindowController.linkMenu`) for what's right-clicked
/// in a list or a row — a file, a file at a line, an address — as ⌘-right-
/// click has it in a terminal or an editor: the window says how to make it.
enum LinkMenus {
    static var make: ((_ target: String, _ from: PlacementID?, _ on: HostID?) -> NSMenu?)?
    /// A block's file, if it's one's (a file's text, a folder): what a row
    /// of the block has as its link.
    static var pathOf: ((BlockID) -> String?)?

    /// What a link carries dragged (⌘ held, the link pressed and moved):
    /// the window says how to make it.
    static var drag: ((_ target: String, _ from: PlacementID?, _ on: HostID?) -> NSPasteboardWriting?)?

    /// Debugging: what a drag carries — each type, and what's written as it.
    static func describe(_ writer: NSPasteboardWriting) -> String {
        let board = NSPasteboard(name: NSPasteboard.Name("manifold.debug.drag"))
        return writer.writableTypes(for: board).map { type in
            let v = writer.pasteboardPropertyList(forType: type)
            let s = (v as? String) ?? (v as? Data).flatMap { String(data: $0, encoding: .utf8) } ?? v.map { "\($0)" } ?? "-"
            return type.rawValue + ": " + String(s.prefix(200))
        }.joined(separator: "\n")
    }

    /// A table's rows' menu: the link menu for the row right-clicked, if
    /// `target` says what it goes to (a path, `path:line`, an address);
    /// else none. `from`: the tile it's in and its host.
    static func attach(to table: NSTableView, target: @escaping (Int) -> String?, from: @escaping (Int) -> (PlacementID?, HostID?)) {
        let filler = Filler(table: table, target: target, from: from)
        let menu = NSMenu()
        menu.delegate = filler
        table.menu = menu
        objc_setAssociatedObject(table, &fillerKey, filler, .OBJC_ASSOCIATION_RETAIN)
    }

    /// A menu of a thing's own with the link menu's items after its own
    /// (a separator between), those it has already — by title — left out.
    static func append(_ target: String, from: PlacementID?, on host: HostID?, to menu: NSMenu, skipping: Set<String> = []) {
        guard let made = make?(target, from, host) else { return }
        let have = Set(menu.items.map(\.title)).union(skipping)
        var extra = made.items.filter { $0.isSeparatorItem || !have.contains($0.title) }
        while extra.first?.isSeparatorItem == true { extra.removeFirst() }
        while extra.last?.isSeparatorItem == true { extra.removeLast() }
        guard !extra.isEmpty else { return }
        if menu.items.last.map({ !$0.isSeparatorItem }) == true { menu.addItem(.separator()) }
        for i in extra { made.removeItem(i); menu.addItem(i) }
    }

    /// A row view's: shown where it was right-clicked.
    static func popUp(_ target: String?, from: PlacementID?, on host: HostID?, with event: NSEvent, for view: NSView) -> Bool {
        guard let target, let menu = make?(target, from, host) else { return false }
        show(menu, with: event, in: view)
        return true
    }

    /// A menu of ours at the pointer — popped up, not as a context menu,
    /// which AppKit adds its own to over a view that takes text (AutoFill,
    /// Services).
    static func show(_ menu: NSMenu, with event: NSEvent, in view: NSView) {
        menu.popUp(positioning: nil, at: view.convert(event.locationInWindow, from: nil), in: view)
    }

    private static var fillerKey = 0

    /// Debugging: the titles the menu of a table under `view` has for its
    /// row `row`, as a right-click there would make it.
    static func debugTitles(in view: NSView, row: Int) -> String {
        func tables(_ v: NSView) -> [NSTableView] { ((v as? NSTableView).map { [$0] } ?? []) + v.subviews.flatMap(tables) }
        guard let table = tables(view).first(where: { objc_getAssociatedObject($0, &fillerKey) != nil }),
              let filler = objc_getAssociatedObject(table, &fillerKey) as? Filler else { return "no list with a link menu" }
        guard let t = filler.target(row) else { return "row \(row): no link" }
        let (placement, host) = filler.from(row)
        guard let made = make?(t, placement, host) else { return "no menu" }
        return t + "\n" + made.items.map { $0.isSeparatorItem ? "---" : $0.title }.joined(separator: "\n")
    }

    private final class Filler: NSObject, NSMenuDelegate {
        weak var table: NSTableView?
        let target: (Int) -> String?
        let from: (Int) -> (PlacementID?, HostID?)

        init(table: NSTableView, target: @escaping (Int) -> String?, from: @escaping (Int) -> (PlacementID?, HostID?)) {
            self.table = table
            self.target = target
            self.from = from
        }

        func menuNeedsUpdate(_ menu: NSMenu) {
            menu.removeAllItems()
            guard let table, table.clickedRow >= 0, let t = target(table.clickedRow) else { return }
            let (placement, host) = from(table.clickedRow)
            guard let made = LinkMenus.make?(t, placement, host) else { return }
            for item in made.items { made.removeItem(item); menu.addItem(item) }
        }
    }
}
