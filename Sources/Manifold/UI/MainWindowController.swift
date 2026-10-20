import AppKit
import WebKit
import ManifoldCore

/// The window: the selected arrangement filling it, the sidebar (the desk)
/// floating over its left edge when the mouse goes there (or docked, when
/// pinned), the palette, and the finder.
final class MainWindowController: NSWindowController, NSWindowDelegate {
    let hosts: Hosts
    /// This machine's host: the desk and settings are its.
    var host: HostClient { hosts.local }
    private let root = RootView()
    private let glass = NSVisualEffectView()
    private let backdrop = BackdropView()
    /// The arrangement shown; and the one it replaced, while it slides away.
    private var content = GridView()
    private var outgoing = GridView()
    /// The arrangement `content` shows, and which way the next one to be
    /// shown slides in (1 from the right, -1 from the left), if it does.
    private var shownArrangement: BlockID?
    private var pendingSlide: CGFloat?
    private var sliding = false
    /// ⌃⇥'s walk, while control is held: the arrangements in the order it
    /// began with, and how far along it is.
    private var walk: (ids: [BlockID], index: Int)?
    private var walkMonitors: [Any] = []
    /// ⌘E's switcher, while ⌘ is held: what ends it.
    private var stackMonitors: [Any] = []
    private let sidebar = SidebarView()
    private var palette: CommandPaletteView?
    /// Each placement's view, for every arrangement on the desk.
    private var views: [PlacementID: PaneContent] = [:]
    private var seenTimer: Timer?
    private var lastSeenSent = Date.distantPast
    private var lastSeenSet: Set<BlockID> = []

    /// A place to go in a file being opened: done once its editor is shown.
    private var pendingJump: (path: String, line: Int, column: Int?)?
    /// Tiles ⌘↩ made, each with the line the tile it replaced had at its top.
    private var pendingTopLines: [PlacementID: Double] = [:]
    private var languageServersWindow: LanguageServersWindow?
    private var clickMonitor: Any?
    /// Blocks whose terminal just closed; they get a new one after a moment
    /// if their shell is still there (the server was restarted, not the
    /// shell ended).
    private var recentlyClosed: Set<BlockID> = []
    private var sidebarShown = false
    private var draggingTab = false
    private var hideWork: DispatchWorkItem?
    private var saveFrameWork: DispatchWorkItem?

    /// The sidebar's width while its handle is being dragged.
    private var resizingWidth: CGFloat?

    private var desk: DeskState { host.desk }
    private var sidebarWidth: CGFloat {
        let w = resizingWidth ?? hosts.state.window.sidebarWidth.map { CGFloat($0) } ?? Theme.sidebarWidth
        return min(max(w, Theme.sidebarWidthRange.lowerBound), Theme.sidebarWidthRange.upperBound)
    }
    private var selected: BlockID? { hosts.state.selected }
    private var arrangement: ArrangementState? { hosts.arrangement(selected) }
    private var pinned: Bool { hosts.state.window.sidebarPinned }

    init(hosts: Hosts) {
        self.hosts = hosts
        let window = MainWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1100, height: 720),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered, defer: false)
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.titlebarSeparatorStyle = .none
        window.backgroundColor = .clear
        window.isOpaque = false
        window.isMovableByWindowBackground = false
        window.minSize = NSSize(width: 480, height: 300)
        window.tabbingMode = .disallowed
        window.isRestorable = false
        super.init(window: window)
        window.delegate = self

        root.frame = window.contentLayoutRect
        window.contentView = root
        // Under everything: what's behind the window, blurred, and over
        // that the wash of colour the cards and the sidebar sit on.
        glass.material = .underWindowBackground
        glass.blendingMode = .behindWindow
        glass.state = .active
        root.addSubview(glass)
        backdrop.alphaValue = 0.96
        root.addSubview(backdrop)
        root.addSubview(content)
        root.addSubview(sidebar)
        root.onMouseMoved = { [weak self] p in self?.mouseMoved(to: p) }
        root.onMouseExitedWindow = { [weak self] in self?.scheduleHide() }
        root.onLayout = { [weak self] in
            self?.layoutViews()
            self?.layoutTrafficLights()
        }
        sidebar.delegate = self
        sidebar.organizationView.delegate = self
        for c in [content, outgoing] { c.delegate = self }
        sidebar.isHidden = true

        if let f = hosts.state.window.frame, f.count == 4 {
            let frame = NSRect(x: f[0], y: f[1], width: f[2], height: f[3])
            if NSScreen.screens.contains(where: { $0.visibleFrame.intersects(frame) }) {
                window.setFrame(frame, display: false)
            } else {
                window.center()
            }
        } else {
            window.center()
        }
        setTrafficLights(visible: pinned, animated: false)
        watchClicks()
        watchHistoryButtons()
        seenTimer = Timer.scheduledTimer(withTimeInterval: 15, repeats: true) { [weak self] _ in
            self?.noteSeen(force: true)
            self?.collect()
        }
        hosts.onTerminalEnded = { [weak self] block in self?.terminalEnded(block) }
        hosts.onHistory = { [weak self] shard, base, entries in self?.historyArrived(shard, base?.state.block, entries) }
        hosts.onOpen = { [weak self] host, id, client, paths, beside, wait in
            self?.openRequest(on: host, id: id, client: client, paths: paths, beside: beside, wait: wait)
        }
        hosts.onShow = { [weak self] host, id, client, block, beside in
            self?.showRequest(on: host, id: id, client: client, block: block, beside: beside)
        }
        hosts.onLanguageServer = { [weak self] _, _, _, _ in self?.languageServersWindow?.refresh() }
        hosts.onGutter = { [weak self] block in
            guard let self else { return }
            for case let e as EditorView in self.views.values where e.block == block { e.gutterChanged() }
        }
        hosts.onDiagnostics = { [weak self] block in
            guard let self else { return }
            for case let e as EditorView in self.views.values where e.block == block { e.diagnosticsChanged() }
        }
        for name in [NSWindow.didBecomeKeyNotification, NSWindow.didResignKeyNotification,
                     NSWindow.didResizeNotification, NSWindow.didExitFullScreenNotification] {
            NotificationCenter.default.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in
                self?.layoutTrafficLights()
                DispatchQueue.main.async { self?.layoutTrafficLights() }
                // The keyboard goes back to the focused placement.
                if name == NSWindow.didBecomeKeyNotification { DispatchQueue.main.async { self?.render() } }
            }
        }
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.screensDidWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { self?.render() }
        }
    }

    required init?(coder: NSCoder) { fatalError() }

    // MARK: Rendering

    /// What's known of a placement on the desk.
    private func shown(_ id: PlacementID) -> Shown? {
        for a in allWorkspaces.compactMap({ hosts.arrangement($0) }) {
            if let p = a.placement(id) { return shown(p) }
        }
        if id.hasPrefix("state:"), let b = BlockID(string: String(id.dropFirst(6))), let block = hosts.block(b) {
            return Shown(placement: Placement(id: id, block: b, lens: Lens.default(for: block.kind, path: block.path)), block: block)
        }
        return nil
    }

    /// The focused tile at the last render: a focus that moved takes the
    /// keyboard with it; one that didn't follows the keyboard.
    private var lastFocused: PlacementID?

    func render() {
        guard let window else { return }
        if finder.isShowing, finder.scope == .contents { finder.refreshResults() }
        sidebar.pinned = pinned
        if pinned && !sidebarShown { showSidebar(animated: false) }

        // Views for placements no longer on the desk go (a state view's stay
        // while it's up: its blocks are settled before any view is made,
        // since making one can render again).
        var stateBlocks = stateGroup.map { statusGroups("")[$0] ?? [] } ?? []
        var stateLenses: [BlockID: Lens] = [:]
        if stateGroup == nil, let w = stateWorkspace, let a = hosts.arrangement(w) {
            // ⌘': the workspace's blocks, each as its tile shows it.
            for p in a.placements where stateLenses[p.block] == nil {
                guard let b = hosts.block(p.block) else { continue }
                stateLenses[p.block] = p.lens
                stateBlocks.append((b, b.statusRecord, b.statusRecord?.at ?? b.created))
            }
        }
        if stateGroup != nil || stateWorkspace != nil {
            // Membership sticks while the view is up: a block that leaves
            // the state for a moment (a diff reloading, a repository
            // refreshing) keeps its place rather than its view being torn
            // down and made again; new arrivals come first.
            let current = Set(stateBlocks.map(\.0.id))
            let staying = stateMembers.filter { !current.contains($0) }.compactMap { id -> (Block, StatusRecord?, Stamp)? in
                guard let b = hosts.block(id) else { return nil }
                return (b, b.statusRecord, b.statusRecord?.at ?? b.created)
            }
            let arrivals = stateBlocks.filter { !stateMembers.contains($0.0.id) }
            let kept = stateMembers.compactMap { id in stateBlocks.first { $0.0.id == id } ?? staying.first { $0.0.id == id } }
            stateBlocks = arrivals + kept
            stateMembers = stateBlocks.map(\.0.id)
        }
        var onDesk = Set(allWorkspaces.compactMap { hosts.arrangement($0) }.flatMap { $0.placements.map(\.id) })
        onDesk.formUnion(stateBlocks.map { Self.statePlacement($0.0.id) })
        for (id, view) in views where !onDesk.contains(id) {
            view.removeFromSuperview()
            view.destroy()
            views.removeValue(forKey: id)
        }

        if selected != shownArrangement {
            if let dir = pendingSlide, shownArrangement != nil, selected != nil { slide(from: dir) }
            shownArrangement = selected
        }
        pendingSlide = nil
        if walk == nil, let id = selected, hosts.state.settled.first != id {
            hosts.settle(id)
        }

        if let a = arrangement {
            // The grid (§3.1): every tile, in its column, top to bottom.
            let tiles = a.columns.map { column in
                column.filter { !recentlyClosed.contains($0.block) }.map { p -> GridView.Tile in
                    let shown = self.shown(p)
                    return GridView.Tile(shown: shown, view: view(for: shown), links: links(of: p.block))
                }
            }.filter { !$0.isEmpty }
            content.show(tiles, fractions: a.fractions, heights: a.heights, focused: a.focused, full: a.full)
            window.title = title(of: a)
            // The keyboard may be in no view at all (the window's, after
            // the view it was in went, as a closed editor's does).
            let responder = window.firstResponder as? NSView
            // Nor while a pill is a field (a note being named, an address typed).
            if palette == nil, stateView == nil, history == nil, neighborhoodView == nil, !content.isEditingPill,
               let focused = a.focused, let view = views[focused], view.superview != nil,
               !(responder?.isDescendant(of: view) ?? false) {
                // Not while something is over the window with the keyboard.
                if focused == lastFocused, let responder,
                   let typing = views.first(where: { $0.value.superview != nil && !$0.value.isHidden && responder.isDescendant(of: $0.value) })?.key,
                   a.placement(typing) != nil, !a.isStashed(typing) {
                    // The tile focus didn't move but the keyboard is in
                    // another tile (typing went on there): the focus follows
                    // it, rather than the keyboard being taken from under
                    // the typing.
                    focus(typing)
                } else {
                    // The focus moved (a go-to, a click, a new tile): the
                    // keyboard goes with it.
                    window.makeFirstResponder(view.focusView)
                }
            }
            lastFocused = a.focused
            for case let t as TerminalView in views.values { t.syncFocus(); t.processesChanged() }
            for case let m as MarkdownView in views.values { m.textChanged() }
            for case let e as EditorView in views.values { e.documentChanged(); e.refreshPills() }
            for case let t as OutlineLensView in views.values { t.documentChanged() }
            for case let d as DirectoryView in views.values { d.documentChanged() }
            for case let w as WebView in views.values { w.documentChanged() }
            for case let s as SearchView in views.values { s.documentChanged() }
            for case let g as GitView in views.values { g.documentChanged() }
            for case let m as MediaView in views.values { m.documentChanged() }
            for case let pv as ProcessView in views.values { pv.documentChanged() }
            for case let d as DiffView in views.values { d.documentChanged() }
        } else {
            content.clear()
            window.title = "Manifold"
        }
        if let stateView, stateGroup != nil || stateWorkspace != nil {
            let items = stateBlocks.map { block, _, _ -> StateView.Item in
                let lens = stateLenses[block.id] ?? Lens.default(for: block.kind, path: block.path)
                let p = Placement(id: Self.statePlacement(block.id), block: block.id, lens: lens)
                let shown = Shown(placement: p, block: block)
                return StateView.Item(shown: shown, view: view(for: shown))
            }
            let title = stateGroup?.title ?? "Overview"
            stateView.show(items, title: title, mode: stateMode)
            window.title = title
        }
        noteSeen(force: false)
        noteEditing()
        checkOpenWaits()
        noteTrailFocus()
        attend()
        refreshOrganization()

        layoutViews()

        // A line to go to in a file just opened: once its editor has
        // loaded and is laid out, so the line can be scrolled into view.
        if let jump = pendingJump,
           let editor = content.views.compactMap({ $0 as? EditorView }).first(where: { $0.path == jump.path }), editor.isLoaded {
            pendingJump = nil
            editor.select(line: jump.line, column: jump.column)
        } else if let jump = pendingJump, let page = content.views.compactMap({ $0 as? MarkdownView }).first(where: { $0.path == jump.path }) {
            pendingJump = nil
            page.reveal(line: jump.line)
        }

        if allWorkspaces.isEmpty && host.hasState {
            showPalette(dismissable: false)
        } else if let palette, !palette.dismissable {
            palette.dismissable = true
            hidePalette()
        }
    }

    /// An arrangement's title: its name, else what's focused in it.
    private func title(of a: ArrangementState) -> String {
        if a.isNamed { return a.title! }
        if let f = a.focusedPlacement, let b = hosts.block(f.block) { return b.displayTitle }
        return "Untitled"
    }

    /// What to say of a host whose block can't be shown: being reached,
    /// unreachable (and why), or not attached at all; and whether a
    /// button to attach makes sense.
    private func hostStanding(_ host: HostID) -> (String, Bool) {
        let known = HostsFile.load().destination(of: host) != nil
        guard let c = hosts.client(host) else { return ("Not attached to that host.", known) }
        switch c.link {
        case .connecting: return ("Connecting…", false)
        case .connected: return ("Waiting for its blocks…", false)
        case .unreachable(let why): return ("Can't be reached now" + (why.map { ": " + $0.prefix(120) } ?? "") + ". Tried again every so often.", known)
        }
    }

    /// A placement's block as seen from here: offline when its host is
    /// attached but can't be reached now.
    private func shown(_ p: Placement) -> Shown {
        Shown(placement: p, block: hosts.block(p.block), offline: hosts.client(p.block.host) != nil && !hosts.isReachable(p.block.host))
    }

    /// A text tile's font: the one its pill's menu chose; else, for code
    /// (by its extension), fixed width, being edited or viewed; else the
    /// theme's choice.
    private func editorFont(for p: Placement, path: String?) -> EditorFont {
        if let chosen = viewState(of: p)["font"].flatMap(EditorFont.init(rawValue:)) { return chosen }
        return Lens.viewRendering(for: path) == .code ? .monospaced : hosts.state.appearance.editorFont
    }

    /// What a block was last left at through a lens (its scroll, its
    /// selection, how it was set), kept beside each tile's own: a tile made
    /// for it again — recalled after it was closed, brought to another
    /// workspace — starts there.
    static func lastViewKey(_ lens: Lens) -> PlacementID { "last:" + lens.rawValue }

    /// A tile's view state: its own, over what its block was last left at
    /// through its lens.
    private func viewState(of p: Placement) -> [String: String] {
        let views = hosts.block(p.block)?.views
        return (views?[Self.lastViewKey(p.lens)] ?? [:]).merging(views?[p.id] ?? [:]) { _, own in own }
    }

    /// Keeps a tile's view state, and the block's last through its lens.
    private func keepViewState(_ values: [String: String], of p: Placement) {
        hosts.append([.view(placement: p.id, values), .view(placement: Self.lastViewKey(p.lens), values)], to: .block(p.block))
    }

    private func view(for shown: Shown) -> PaneContent {
        let p = shown.placement
        if shown.block == nil {
            // On a host we aren't attached to (§8): a placeholder that says
            // so, until the host is, when it is made again.
            let (note, canAttach) = hostStanding(p.block.host)
            if let v = views[p.id] as? PlaceholderView { v.set(note: note, canAttach: canAttach); return v }
            views[p.id]?.removeFromSuperview()
            let v = PlaceholderView(placement: p.id, block: p.block, label: hosts.label(of: p.block.host))
            v.set(note: note, canAttach: canAttach)
            v.known = { [weak self] in self?.hosts.block(p.block) != nil }
            v.onAttach = { [weak self] in
                guard let self, let dest = HostsFile.load().destination(of: p.block.host) else { return }
                self.attach(dest)
            }
            views[p.id] = v
            return v
        }
        if let v = views[p.id] {
            if v is PlaceholderView {
                // The block is known now: its view is made below.
                v.removeFromSuperview()
                views[p.id] = nil
            } else {
            if let m = v as? MarkdownView {
                m.theme = hosts.state.appearance.theme
                m.show(block: p.block, path: shown.path ?? "")
            }
            if let e = v as? EditorView {
                e.offline = shown.offline
                e.richMarkdown = viewState(of: p)["markdown"] != "raw"
                e.home = hosts.block(p.block)?.place
                e.noteName = hosts.block(p.block).flatMap { $0.isNote ? $0.title : nil }
                e.isRemote = p.block.host != host.host
                e.font = editorFont(for: p, path: shown.path)
                e.theme = hosts.state.appearance.theme
                e.undoLimit = desk.settings.undoDepth
                e.viewing = p.lens == .preview
            }
            if let d = v as? DiffView { d.theme = hosts.state.appearance.theme }
            if let t = v as? TerminalView { t.commands = hosts.block(p.block)?.terminal?.commands ?? [] }
            if !v.isDead { return v }
            v.removeFromSuperview()
            v.destroy()
            }
        }
        let v: PaneContent
        switch p.lens {
        case .terminal, .agent:
            let t = TerminalView(placement: p.id, block: p.block, command: HostClient.attachCommand(block: p.block))
            t.delegate = self
            t.commands = hosts.block(p.block)?.terminal?.commands ?? []
            TerminalView.copyOnSelect = desk.settings.copyOnSelect
            v = t
        case .image, .pdf:
            let m = MediaView(placement: p.id, block: p.block, kind: p.lens)
            m.delegate = self
            m.source = { [weak self] in self?.hosts.block(p.block) }
            v = m
        case .process:
            let pv = ProcessView(placement: p.id, block: p.block)
            pv.delegate = self
            pv.source = { [weak self] in self?.hosts.block(p.block) }
            pv.blockTitle = { [weak self] in self?.hosts.block($0)?.displayTitle }
            pv.blockArchived = { [weak self] in self?.hosts.block($0)?.isArchived == true }
            v = pv
        case .outline:
            // An outline block shows its subject's commands or headings;
            // an older outline placed as a lens on the block itself still does.
            let tv = OutlineLensView(placement: p.id, block: p.block)
            tv.delegate = self
            let subject = hosts.block(p.block)?.outline?.subject ?? p.block
            tv.subject = subject
            tv.source = { [weak self] in self?.hosts.block(subject) }
            v = tv
        case .preview where Lens.viewRendering(for: shown.path) == .markdown:
            let m = MarkdownView(placement: p.id, block: p.block, path: shown.path ?? "", theme: hosts.state.appearance.theme)
            m.delegate = self
            m.source = { [weak self] in
                guard let t = self?.hosts.block(p.block)?.text else { return nil }
                return (t.text.string, t.version)
            }
            v = m
        case .directory:
            let d = DirectoryView(placement: p.id, block: p.block)
            d.delegate = self
            d.source = { [weak self] in self?.hosts.block(p.block) }
            v = d
        case .git:
            let g = GitView(placement: p.id, block: p.block)
            g.delegate = self
            g.source = { [weak self] in self?.hosts.block(p.block) }
            v = g
        case .diff:
            let d = DiffView(placement: p.id, block: p.block, theme: hosts.state.appearance.theme)
            d.delegate = self
            d.source = { [weak self] in self?.hosts.block(p.block) }
            v = d
        case .search:
            let s = SearchView(placement: p.id, block: p.block)
            s.delegate = self
            s.source = { [weak self] in self?.hosts.block(p.block) }
            v = s
        case .web:
            let w = WebView(placement: p.id, block: p.block)
            w.delegate = self
            w.source = { [weak self] in self?.hosts.block(p.block) }
            v = w
        default:
            let e = EditorView(placement: p.id, block: p.block, path: shown.path ?? "",
                               font: editorFont(for: p, path: shown.path),
                               theme: hosts.state.appearance.theme)
            e.delegate = self
            e.onToggleFont = { [weak self] kind in self?.keepViewState(["font": kind.rawValue], of: p) }
            e.blockLook = { [weak self] id in
                guard let b = self?.hosts.block(id) else { return nil }
                return PillLook(title: b.displayTitle, symbol: Theme.symbolName(for: b.kind, path: b.path), status: StatusGlyph.look(of: b), archived: b.isArchived)
            }
            e.richMarkdown = viewState(of: p)["markdown"] != "raw"
            e.onToggleMarkdown = { [weak self] rich in self?.keepViewState(["markdown": rich ? "rich" : "raw"], of: p) }
            // Viewed, not edited: a file that isn't Markdown, on its grey.
            e.viewing = p.lens == .preview
            v = e
        }
        // The other mode's top line, when ⌘↩ made this tile.
        if let line = pendingTopLines.removeValue(forKey: p.id) {
            (v as? EditorView)?.scroll(toTopLine: line)
            (v as? MarkdownView)?.scroll(toTopLine: line)
        }
        if let k = v as? KeepsViewState {
            // The placement as made (its block and lens never change): a
            // tile's last state is still kept as it's taken away.
            k.keeper.load = { [weak self] in self?.viewState(of: p) ?? [:] }
            k.keeper.save = { [weak self] values in self?.keepViewState(values, of: p) }
        }
        views[p.id] = v
        return v
    }

    /// A click in a placement focuses it. Terminals say so themselves; the
    /// others' views (a web view, say) don't, so clicks are watched here.
    private func watchClicks() {
        clickMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
            guard let self, event.window === self.window, self.palette == nil else { return event }
            // Not clicks on the sidebar, floating over the placements.
            if self.sidebarShown && self.sidebar.frame.contains(self.root.convert(event.locationInWindow, from: nil)) {
                return event
            }
            let p = self.content.convert(event.locationInWindow, from: nil)
            if let v = self.content.views.first(where: { !$0.isHidden && $0.superview != nil && $0.frame.contains(p) }), !(v is TerminalView),
               self.arrangement?.focused != v.placement {
                self.focus(v.placement)
            }
            return event
        }
    }

    private func layoutViews() {
        let b = root.bounds
        glass.frame = b
        backdrop.frame = b
        let w = sidebarWidth, inset = Theme.sidebarInset
        let sidebarFrame = NSRect(x: sidebarShown ? inset : -w - 20, y: inset, width: w, height: b.height - 2 * inset)
        if sidebar.layer?.animationKeys()?.isEmpty ?? true { sidebar.frame = sidebarFrame }
        let left = pinned ? w + 2 * inset : 0
        content.frame = NSRect(x: left, y: 0, width: b.width - left, height: b.height)
        stateView?.frame = content.frame
        if sliding { outgoing.frame = content.frame }
        palette?.frame = b
        history?.frame = b
    }

    // MARK: Status (§3.7)

    /// The last done or failed record attended to: which block, and the
    /// record's stamp, so one isn't proposed twice while the host answers.
    private var attended: (BlockID, Stamp)?

    /// The focused block, while the window is key, is attended to: what
    /// it had done, or failed at, is read — whether you came to it done
    /// or it finished while you were looking. The Dock badge counts the
    /// blocks waiting on you, or done.
    private func attend() {
        if window?.isKeyWindow == true, let b = focusedShown?.placement.block,
           let r = hosts.block(b)?.statusRecord, r.state == .done || r.state == .error, r.read != true,
           attended.map({ $0.0 != b || $0.1 != r.at }) ?? true {
            attended = (b, r.at)
            hosts.propose(.attend(b))
        }
        let waiting = hosts.blocks.filter { $0.statusRecord?.wantsAttention ?? false }.count
        let badge = waiting == 0 ? "" : "\(waiting)"
        if NSApp.dockTile.badgeLabel != badge { NSApp.dockTile.badgeLabel = badge }
    }

    // MARK: Seen, and collection

    /// Tells the host what's on screen, so it knows what's unseen.
    /// Every file placed in an arrangement on the desk is open with its
    /// host's language server.
    private func noteEditing() {
        var ids: Set<BlockID> = []
        for id in allWorkspaces {
            guard let a = hosts.arrangement(id) else { continue }
            for p in a.placements where p.lens == .editor || p.lens == .preview {
                if let b = hosts.block(p.block), b.kind == .text, b.path != nil { ids.insert(p.block) }
            }
        }
        hosts.setEditing(ids)
    }

    private func noteSeen(force: Bool) {
        guard window?.isVisible == true, window?.isMiniaturized == false, let a = arrangement, let id = selected else { return }
        var seen = Set(a.visible.map(\.block))
        seen.insert(id)
        if seen != lastSeenSet || force || Date().timeIntervalSince(lastSeenSent) > 14 {
            lastSeenSet = seen
            lastSeenSent = Date()
            hosts.propose(.seen(Array(seen)))
        }
    }

    /// An arrangement is what you made it (§3.1): nothing in it is tidied
    /// away. An unnamed one left empty leaves the desk (§4); the host sees
    /// to terminals' dormancy.
    private func collect() {
        for c in hosts.all where c.isConnected {
            var order = c.desk.order
            for id in c.desk.order {
                guard let a = hosts.arrangement(id), !a.isNamed, a.isEmpty, id != selected else { continue }
                order.removeAll { $0 == id }
            }
            if order != c.desk.order { c.setWorkspaceOrder(order) }
        }
    }

    func debugCollect(agingBy minutes: Double) { collect() }

    @objc func setTextHistory(_ sender: NSMenuItem) {
        var s = desk.settings
        s.textHistoryDays = sender.tag
        host.setSettings(s)
    }

    @objc func setTranscriptHistory(_ sender: NSMenuItem) {
        var s = desk.settings
        s.terminalHistoryDays = sender.tag
        host.setSettings(s)
    }

    @objc func setUndoDepth(_ sender: NSMenuItem) {
        var s = desk.settings
        s.undoDepth = sender.tag
        host.setSettings(s)
    }

    @objc func setTerminalDormancy(_ sender: NSMenuItem) {
        var s = desk.settings
        s.terminalDormantAfterHours = sender.tag
        host.setSettings(s)
    }

    /// A terminal's shell ended (not for dormancy): its placements go, as a
    /// closed window's would; the block stays, with its transcript.
    /// ⇧⌘W: the focused block archived (§3.7) — put away as it is, its
    /// tiles gone from every workspace, to be recalled from the sidebar's
    /// Archived section; a terminal's shell ends and isn't started again.
    @objc func archiveFocused(_ sender: Any?) {
        guard let b = focusedShown?.block else { return NSSound.beep() }
        hosts.propose(.archive(b.id, true))
        withdraw(b.id)
    }

    /// ⇧⌘I: the focused block into the inbox, or out of it (§3.7).
    @objc func toggleInbox(_ sender: Any?) {
        guard let b = focusedShown?.block else { return NSSound.beep() }
        hosts.propose(.inbox(b.id, !b.isInInbox))
    }

    /// The menu's verbs for a block's being: archive or unarchive; into
    /// the inbox or out of it.
    private func keepingItems(for b: Block) -> [NSMenuItem] {
        [ClosureMenuItem(b.isArchived ? "Unarchive" : "Archive", symbol: b.isArchived ? "archivebox.fill" : "archivebox", key: b.isArchived ? "" : "W") { [weak self] in
            self?.hosts.propose(.archive(b.id, !b.isArchived))
            if !b.isArchived { self?.withdraw(b.id) }
        }, ClosureMenuItem(b.isInInbox ? "Remove from Inbox" : "Add to Inbox", symbol: b.isInInbox ? "tray.and.arrow.up" : "tray.and.arrow.down", key: "I") { [weak self] in
            self?.hosts.propose(.inbox(b.id, !b.isInInbox))
        }]
    }

    private func terminalEnded(_ block: BlockID) { withdraw(block) }

    /// A block's tiles taken off every workspace (its shell ended, or it
    /// was archived); an unnamed workspace left empty goes too.
    private func withdraw(_ block: BlockID) {
        for id in allWorkspaces {
            guard let a = hosts.arrangement(id) else { continue }
            for p in a.placements(of: block) { hosts.append(.remove(p.id), to: .block(id)) }
        }
        if let a = arrangement, a.isEmpty, let id = selected, !a.isNamed {
            hosts.client(of: id)?.removeWorkspace(id)
            hosts.select(allWorkspaces.first { $0 != id })
        }
        discardIfUnplaced(block)
    }

    // MARK: Sidebar

    /// How far past its edge the mouse may stray before the floating sidebar
    /// goes, and how long after that it goes.
    private static let sidebarSlack: CGFloat = 8
    private static let sidebarHideDelay: TimeInterval = 0.1

    private func mouseMoved(to p: NSPoint) {
        guard !pinned, palette == nil || palette?.dismissable == true else { return }
        if p.x <= 6 && p.y >= 0 && p.y <= root.bounds.height {
            hideWork?.cancel()
            showSidebar(animated: true)
        } else if sidebarShown && p.x > sidebar.frame.maxX + Self.sidebarSlack {
            scheduleHide()
        } else if sidebarShown && sidebar.frame.insetBy(dx: -Self.sidebarSlack, dy: -Self.sidebarSlack).contains(p) {
            hideWork?.cancel()
        }
    }

    private func showSidebar(animated: Bool) {
        guard !sidebarShown else { return }
        sidebarShown = true
        sidebar.isHidden = false
        root.addSubview(sidebar, positioned: .above, relativeTo: content)
        if let palette { root.addSubview(palette, positioned: .above, relativeTo: sidebar) }
        let target = NSRect(x: Theme.sidebarInset, y: Theme.sidebarInset, width: sidebarWidth,
                            height: root.bounds.height - 2 * Theme.sidebarInset)
        if animated {
            sidebar.frame = target.offsetBy(dx: -24, dy: 0)
            sidebar.alphaValue = 0
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.16
                ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
                sidebar.animator().frame = target
                sidebar.animator().alphaValue = 1
            }
        } else {
            sidebar.frame = target
            sidebar.alphaValue = 1
        }
        setTrafficLights(visible: true, animated: animated)
    }

    private func scheduleHide() {
        guard sidebarShown, !pinned, !draggingTab, resizingWidth == nil else { return }
        hideWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.hideSidebar() }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.sidebarHideDelay, execute: work)
    }

    /// Hides the floating sidebar, unless something's still using it; `force`
    /// hides it even with the mouse over it (when asked to by ⌃⌘S).
    private func hideSidebar(force: Bool = false) {
        guard sidebarShown, !pinned, !draggingTab, resizingWidth == nil,
              NSApp.modalWindow == nil, window?.attachedSheet == nil else { return }
        // Not while a menu from it is open, or the mouse is back over it.
        if let window, !force {
            let p = root.convert(window.mouseLocationOutsideOfEventStream, from: nil)
            if sidebar.frame.insetBy(dx: -Self.sidebarSlack, dy: -Self.sidebarSlack).contains(p) && window.isKeyWindow
                && NSEvent.pressedMouseButtons == 0 && root.bounds.contains(p) { return }
        }
        sidebarShown = false
        let target = sidebar.frame.offsetBy(dx: -24, dy: 0)
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.14
            ctx.timingFunction = CAMediaTimingFunction(name: .easeIn)
            sidebar.animator().frame = target
            sidebar.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            guard let self, !self.sidebarShown else { return }
            self.sidebar.isHidden = true
        })
        setTrafficLights(visible: false, animated: true)
    }

    /// The window buttons' centers, relative to the close button's, as
    /// AppKit spaces them.
    private var buttonOffsets: [CGFloat]?

    /// Puts the window buttons on the sidebar's top row, level with its
    /// other button and as far in from the edge. AppKit puts them back
    /// whenever it lays out the title bar, so this runs after each layout.
    func layoutTrafficLights() {
        guard let window, !window.styleMask.contains(.fullScreen) else { return }
        let buttons = [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton]
            .compactMap { window.standardWindowButton($0) }
        guard buttons.count == 3, let container = buttons[0].superview else { return }
        let offsets = buttonOffsets ?? buttons.map { $0.frame.midX - buttons[0].frame.midX }
        buttonOffsets = offsets
        let inset = Theme.sidebarInset
        let centerY = window.frame.height - inset - SidebarView.headerHeight / 2
        for (b, dx) in zip(buttons, offsets) {
            let c = container.convert(NSPoint(x: inset + 20 + dx, y: centerY), from: nil)
            let origin = NSPoint(x: (c.x - b.frame.width / 2).rounded(), y: (c.y - b.frame.height / 2).rounded())
            if b.frame.origin != origin { b.setFrameOrigin(origin) }
        }
    }

    private func setTrafficLights(visible: Bool, animated: Bool) {
        for type in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
            guard let b = window?.standardWindowButton(type) else { continue }
            if animated {
                NSAnimationContext.runAnimationGroup { ctx in
                    ctx.duration = 0.14
                    b.animator().alphaValue = visible ? 1 : 0
                }
            } else {
                b.alphaValue = visible ? 1 : 0
            }
            b.isEnabled = visible
        }
    }

    // MARK: Debugging aids

    var debugFocusedBlock: BlockID? { focusedShown?.placement.block }
    var debugFocusedMarkdown: MarkdownView? { focusedShown.flatMap { views[$0.id] as? MarkdownView } }
    var debugFocusedView: NSView? { focusedShown.flatMap { views[$0.id] } }
    var debugFocusedWebView: WKWebView? {
        guard let v = debugFocusedView else { return nil }
        func find(_ v: NSView) -> WKWebView? { (v as? WKWebView) ?? v.subviews.lazy.compactMap(find).first }
        return find(v)
    }

    var debugFocusedPlacement: Shown? { focusedShown }
    var debugOrganization: OrganizationView { sidebar.organizationView }
    /// Runs the first palette item whose title starts with `prefix`.
    func debugRunPaletteItem(_ prefix: String) -> String {
        guard let item = paletteItems().first(where: { $0.title.hasPrefix(prefix) }) else { return "no item" }
        item.run()
        return "ran \(item.title)"
    }
    /// A pointer move, handed to the surface as its tracking area would.
    /// A synthesized move: to the grid (its stacks), and to whatever view
    /// is under the point that takes moves of its own (a scrubber).
    func debugHover(_ event: NSEvent) {
        content.mouseMoved(with: event)
        guard let root = window?.contentView, let hit = root.hitTest(root.convert(event.locationInWindow, from: nil)) else { return }
        var v: NSView? = hit
        while let view = v, view !== content {
            if view is ScrubberView || view is ScrubTip || view is LinkBadge || view is StackSwitcherView { view.mouseMoved(with: event); break }
            if let badge = view.superview as? LinkBadge { badge.mouseMoved(with: event); break }
            v = view.superview
        }
    }

    var debugFocusedTerminal: TerminalView? { arrangement?.focused.flatMap { views[$0] as? TerminalView } }
    var debugFocusedEditor: EditorView? { arrangement?.focused.flatMap { views[$0] as? EditorView } }

    func debugSidebar(show: Bool) {
        if show { showSidebar(animated: false) } else { hideWork?.cancel(); hideSidebar() }
    }

    var debugPills: String { content.debugPills }
    var debugDirty: String { content.debugDirty }
    func debugPushDown(column: Int, row: Int) -> String { content.debugPushDown(column: column, row: row) }
    func debugDirtyClick() -> String {
        guard let f = focusedShown else { return "nothing focused" }
        gridDirtyClicked(f.id, from: content)
        return "ok"
    }

    /// Debugging: the focused text's top line (from 0), as ⌘↩ carries it.
    func debugTopLine() -> String {
        guard let f = focusedShown else { return "nothing focused" }
        if let e = views[f.id] as? EditorView { return String(format: "editor%@ %.2f caret %d", e.viewing ? " viewing" : "", e.topLine, e.caretLine) }
        guard let m = views[f.id] as? MarkdownView else { return "not a text" }
        var line: Double?? = nil
        m.topLine { line = .some($0) }
        let deadline = Date().addingTimeInterval(2)
        while line == nil, Date() < deadline { RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.02)) }
        return String(format: "page %.2f", (line ?? nil) ?? -1)
    }
    func debugSwitcherHover(_ i: Int) -> String { content.debugSwitcherHover(i) }

    var debugSurface: NSView? { content }

    func debugReadd() -> String {
        guard let f = arrangement?.focused else { return "nothing focused" }
        return content.debugReadd(f)
    }

    func debugRightClick() -> String {
        guard let f = arrangement?.focused else { return "nothing focused" }
        return content.debugRightClick(f)
    }

    func debugBadge(_ arg: String) -> String {
        guard let f = arrangement?.focused else { return "nothing focused" }
        return content.debugBadge(f, arg)
    }

    func debugStack(swap: Bool, index: Int = 0) -> String {
        guard let a = arrangement, let f = a.focused, let (c, _) = a.locate(f) else { return "nothing focused" }
        // The stack as the fan shows it: those stashed above the first
        // shown tile count as behind it, then those under the tile.
        let behind = a.columns[c].filter { a.isStashed($0.id) && a.tile(behind: $0.id)?.id == f }
        if swap, index < behind.count { gridSwap(behind[index].id) }
        guard let b = arrangement else { return "gone" }
        return b.columns[c].map { "\($0.id == b.focused ? "*" : " ")\(hosts.block($0.block)?.displayTitle ?? "?")#\($0.id.suffix(4)) \(Int((b.heights[$0.id] ?? 0) * 100))%" }.joined(separator: " | ")
    }

    func debugDescribe() -> String {
        var out = "selected \(selected.map(\.description) ?? "none") theme \(hosts.state.appearance.theme.rawValue)\n"
        if let a = arrangement {
            for (c, column) in a.columns.enumerated() {
                out += "column \(c): " + column.map { p in
                    let b = hosts.block(p.block)
                    let mark = p.id == a.focused ? "*" : ""
                    return "\(p.lens.rawValue)=\(b?.displayTitle ?? "?")\(mark) \(Int((a.heights[p.id] ?? 0) * 100))%"
                }.joined(separator: " | ") + "\n"
            }
        }
        out += "desk: " + allWorkspaces.map { hosts.arrangement($0).map { title(of: $0) } ?? "?" }.joined(separator: ", ")
        return out
    }

    // MARK: Palette

    private func showPalette(dismissable: Bool = true) {
        if let palette {
            palette.dismissable = palette.dismissable && dismissable
            return
        }
        let p = CommandPaletteView(frame: root.bounds)
        p.dismissable = dismissable
        p.onDismiss = { [weak self] in self?.hidePalette() }
        root.addSubview(p, positioned: .above, relativeTo: nil)
        palette = p
        p.present(items: paletteItems(), in: window)
    }

    private func hidePalette() {
        guard let palette, palette.dismissable else { return }
        palette.removeFromSuperview()
        self.palette = nil
        render()
    }

    private func paletteItems() -> [PaletteItem] {
        var items: [PaletteItem] = []
        if arrangement != nil {
            items.append(PaletteItem(symbol: "rectangle.split.2x1", title: "New Terminal Beside", subtitle: "⌘N") { [weak self] in
                self?.newTerminalBeside(nil)
            })
        }
        items.append(PaletteItem(symbol: "apple.terminal", title: "New Terminal in a New Workspace", subtitle: "⌥⌘T") { [weak self] in
            self?.newTerminal(nil)
        })
        items.append(PaletteItem(symbol: "note.text", title: "New Note", subtitle: "⇧⌘N") { [weak self] in
            self?.newNote(nil)
        })
        if let f = focusedShown, f.block?.isNote == true {
            items.append(PaletteItem(symbol: "pencil", title: "Name This Note…", subtitle: "Action") { [weak self] in
                self?.nameNote(f.id)
            })
        }
        if arrangement != nil {
            items.append(PaletteItem(symbol: "pencil", title: "Name This Workspace…", subtitle: "⇧⌘R") { [weak self] in
                self?.renameTab(nil)
            })
            items.append(PaletteItem(symbol: "clock.arrow.circlepath", title: "History of This Workspace", subtitle: "⌘Y") { [weak self] in
                self?.showHistory(nil)
            })
        }
        items.append(PaletteItem(symbol: "magnifyingglass", title: "Find Anything…", subtitle: "⌘O") { [weak self] in
            self?.openDocument(nil)
        })
        for client in hosts.all where client.isRemote {
            let h = client.host
            let state = client.isConnected ? "connected" : "offline"
            items.append(PaletteItem(symbol: "server.rack", title: "New Terminal on \(hosts.label(of: h)) in a New Workspace", subtitle: state) { [weak self] in
                // The workspace lives on that host, as its terminal does.
                self?.newWorkspace(on: h, cwd: nil)
            })
            if client.link == .connected {
                items.append(PaletteItem(symbol: "gearshape", title: "Preferences for \(hosts.label(of: h))…", subtitle: "shell") { [weak self] in
                    self?.editPreferences(h)
                })
            }
            items.append(PaletteItem(symbol: "server.rack", title: "Detach from \(hosts.label(of: h))…", subtitle: state) { [weak self] in
                self?.detach(h)
            })
        }
        for (dest, error) in hosts.errors {
            items.append(PaletteItem(symbol: "exclamationmark.triangle", title: "\(dest): \(error)", subtitle: "Attach failed") { [weak self] in
                self?.attachToHost(nil)
            })
        }
        items.append(PaletteItem(symbol: "server.rack", title: "Attach to Host…", subtitle: "ssh user@host, or provider:name") { [weak self] in
            self?.attachToHost(nil)
        })
        items.append(PaletteItem(symbol: "magnifyingglass", title: "Find in Files…", subtitle: "⇧⌘F") { [weak self] in
            self?.findInFiles(nil)
        })
        if let f = focusedShown, f.kind == .text {
            items.append(PaletteItem(symbol: "clock.arrow.circlepath", title: "History of This File…", subtitle: "⌥⌘Y") { [weak self] in
                self?.showFileHistory(nil)
            })
        }
        items.append(PaletteItem(symbol: "point.3.connected.trianglepath.dotted", title: "Show the Neighborhood Map", subtitle: "Action") { [weak self] in
            self?.showNeighborhood(nil)
        })
        items.append(PaletteItem(symbol: "sparkles", title: "New Agent Here", subtitle: "⌥⌘A") { [weak self] in
            self?.newAgent(nil)
        })
        for a in AgentCatalog.agents(among: hosts.client(focusedHost)?.desk.agents ?? []) {
            items.append(PaletteItem(symbol: "sparkles", title: "Launch \(a.name) Here", subtitle: a.command) { [weak self] in
                self?.launchAgent(a.command)
            })
        }
        items.append(PaletteItem(symbol: "cpu", title: "Processes on \(hosts.label(of: focusedHost))", subtitle: "Action") { [weak self] in
            self?.showProcesses(nil)
        })
        items.append(PaletteItem(symbol: "arrow.triangle.branch", title: "Source Control for This Project", subtitle: "⌥⌘G") { [weak self] in
            self?.showGit(nil)
        })
        if let f = focusedShown, f.lens == .editor || f.lens == .preview, f.path != nil {
            items.append(PaletteItem(symbol: "arrow.left.arrow.right", title: "Compare with Last Commit", subtitle: "⌥⌘D") { [weak self] in
                self?.compareWithHead(nil)
            })
        }
        items.append(PaletteItem(symbol: "globe", title: "New Web Page", subtitle: "Action") { [weak self] in
            guard let self else { return }
            self.show(self.host.newWeb(url: "https://duckduckgo.com"), lens: .web, .beside)
        })
        // The text shown, the other way: edit what's viewed, view what's edited.
        if let f = focusedShown, f.lens.isText, f.block?.kind == .text, let a = arrangement, let column = a.columnIndex(of: f.id) {
            let viewing = f.lens == .preview
            items.append(PaletteItem(symbol: viewing ? "pencil.line" : "eye", title: viewing ? "Edit This" : "View This", subtitle: "⌘↩") { [weak self] in
                self?.toggleEditPreview(nil)
            })
            items.append(PaletteItem(symbol: viewing ? "pencil.line" : "eye", title: viewing ? "Edit This Beside" : "View This Beside", subtitle: "⌥⇧⌘P") { [weak self] in
                self?.editPreviewBeside(nil)
            })
            _ = column
            if let dir = f.block?.place {
                items.append(PaletteItem(symbol: "folder", title: "Show Enclosing Folder", subtitle: dir.abbreviatingHome) { [weak self] in
                    self?.openDirectory(dir, from: f.id)
                })
            }
        }
        if let f = focusedShown, f.lens == .terminal, let cwd = f.block?.terminal?.cwd {
            items.append(PaletteItem(symbol: "folder", title: "Show This Folder", subtitle: cwd.abbreviatingHome) { [weak self] in
                self?.openDirectory(cwd, from: f.id)
            })
        }
        // What's linked to the focused block, both ways (§6.2).
        if let f = focusedShown {
            let links = hosts.links
            var related: [(BlockID, String)] = []
            for l in links where l.to == f.placement.block && related.count < 6 { related.append((l.from, "opened this")) }
            for l in links where l.from == f.placement.block && related.count < 12 { related.append((l.to, "opened from this")) }
            for (id, how) in related {
                guard let b = hosts.block(id) else { continue }
                items.append(PaletteItem(symbol: Theme.symbolName(for: b.kind, path: b.path), title: b.displayTitle,
                                         subtitle: "Related · \(how)") { [weak self] in self?.recall(id) })
            }
        }
        for id in allWorkspaces {
            guard let a = hosts.arrangement(id) else { continue }
            let focused = a.focusedPlacement.flatMap { hosts.block($0.block) }
            let place = focused?.place.map { $0.abbreviatingHome } ?? ""
            items.append(PaletteItem(symbol: a.columns.count > 1 ? "rectangle.split.2x1" : (focused.map { Theme.symbolName(for: $0.kind, path: $0.path) } ?? "rectangle.3.group"),
                                     title: title(of: a), subtitle: a.isNamed ? "Named · \(place)" : place) { [weak self] in
                self?.hosts.select(id)
            })
        }
        return items
    }

    // MARK: Commands

    private var focusedShown: Shown? {
        guard let a = arrangement, let p = a.focusedPlacement else { return nil }
        return Shown(placement: p, block: hosts.block(p.block))
    }

    private var focusedCwd: String? {
        guard let f = focusedShown else { return nil }
        return f.block?.terminal?.cwd ?? f.block?.place
    }

    /// The host the focused block is on: where new terminals and files go.
    private var focusedHost: HostID { focusedShown?.placement.block.host ?? host.host }

    /// Changes the selected arrangement.
    private func appendToSelected(_ events: [Event]) {
        guard let id = selected else { return }
        hosts.append(events, to: .block(id))
    }

    // MARK: Undo (§3.1)

    /// Each workspace's states before this client's changes to it, the
    /// latest last; and what undoing put aside, for redo.
    private var undone: [BlockID: [ArrangementState]] = [:]
    private var redone: [BlockID: [ArrangementState]] = [:]
    private var restoring = false

    /// A workspace is about to change: its state kept (a hundred deep),
    /// what was set aside for redo let go.
    func noteWorkspaceChange(_ id: BlockID, before: ArrangementState, events: [Event]) {
        guard !restoring else { return }
        undone[id, default: []].append(before)
        if undone[id]!.count > 100 { undone[id]!.removeFirst() }
        redone[id] = []
    }

    /// ⌘Z, when nothing else takes it (an editor undoes its own text):
    /// the selected workspace as it was before its last change, put back
    /// in one entry; ⇧⌘Z the other way.
    @objc func undo(_ sender: Any?) { restore(from: &undone, to: &redone) }
    @objc func redo(_ sender: Any?) { restore(from: &redone, to: &undone) }

    private func restore(from: inout [BlockID: [ArrangementState]], to: inout [BlockID: [ArrangementState]]) {
        guard let id = selected, let now = hosts.arrangement(id), var stack = from[id], let state = stack.popLast() else { return NSSound.beep() }
        from[id] = stack
        to[id, default: []].append(now)
        restoring = true
        hosts.append([.restore(state)], to: .block(id))
        restoring = false
    }

    /// An arrangement to put things in: the selected one, or a new one.
    private func arrangementForPlacing() -> BlockID {
        if let id = selected, hosts.arrangement(id) != nil { return id }
        let id = host.newArrangement()
        hosts.select(id)
        return id
    }

    @objc func newTab(_ sender: Any?) { showPalette() }

    /// ⌥⌘T (and the first thing at launch): a new terminal in a new
    /// workspace — both on the focused block's host, so a workspace begun
    /// from a remote block lives there, for every Mac attached to that
    /// host to see.
    @objc func newTerminal(_ sender: Any?) {
        newWorkspace(on: focusedHost, cwd: focusedCwd)
    }

    /// A new workspace on a host, with a terminal in it (at `cwd`, else
    /// home), after the selected workspace if that's on the same host.
    @discardableResult
    func newWorkspace(on h: HostID, cwd: String?) -> BlockID? {
        guard let client = hosts.client(h) else { return nil }
        let a = client.newArrangement(after: selected?.host == h ? selected : nil)
        let t = hosts.newTerminal(on: h, cwd: cwd)
        hosts.append(.place(Placement(block: t, lens: .terminal), column: 0, at: 0), to: .block(a))
        hosts.select(a)
        return a
    }

    /// ⌘N: a new terminal beside the focused block, in a new column
    /// (§3.1), where the focused block is.
    /// ⌘N: a new terminal in the active column, as acme and apex place a
    /// window — below the column's biggest tile, taking its lower half.
    @objc func newTerminalBeside(_ sender: Any?) {
        guard let a = arrangement, !a.isEmpty else { return newTerminal(nil) }
        let t = hosts.newTerminal(on: focusedHost, cwd: focusedCwd)
        show(t, lens: .terminal, .here)
    }

    /// ⌥⌘N: a new terminal in a new column beside the focused one.
    @objc func newTerminalInNewColumn(_ sender: Any?) {
        guard let a = arrangement, !a.isEmpty else { return newTerminal(nil) }
        let t = hosts.newTerminal(on: focusedHost, cwd: focusedCwd)
        show(t, lens: .terminal, .beside)
    }

    /// Moves a whole column to another index.
    private func reorderColumn(from: Int, to: Int) {
        guard let a = arrangement, from < a.columns.count, from != to else { return }
        appendToSelected([.moveColumn(from: from, to: to)])
    }

    /// ⇧⌘N: a new note beside the focused block.
    /// ⇧⌘N: a note on the focused block's host, at home in its folder.
    /// ⇧⌘N: a note — about the focused block (§3.5): the block linked to
    /// the note, as if ⇧-dragged into it, so the block wears it and the
    /// note knows its subject.
    @objc func newNote(_ sender: Any?) {
        let client = hosts.client(focusedHost) ?? host
        let note = client.newNote(home: focusedCwd)
        if let f = focusedShown, let b = f.block, b.kind != .arrangement {
            hosts.link(from: b.id, to: note, kind: .linked, context: b.displayTitle)
        }
        show(note, lens: .editor, .here)
    }

    /// The links a block has by hand (§3.5), for its badge: what it links
    /// to (→) and what links to it (←), each by its title.
    private func links(of block: BlockID) -> [LinkCard] {
        // Straight from the graphs' edges: this runs for every tile on
        // every render.
        var seen = Set<BlockID>()
        var cards: [LinkCard] = []
        for c in hosts.all {
            for e in c.node.graph.edges(from: block, kind: .link(.linked)) where e.isLive {
                guard seen.insert(e.to).inserted, let b = hosts.block(e.to) else { continue }
                cards.append(LinkCard(link: e.id, block: e.to, title: Self.linkTitle(b), symbol: Theme.symbolName(for: b.kind, path: b.path), outbound: true, archived: b.isArchived))
            }
        }
        for c in hosts.all {
            for e in c.node.graph.edges(to: block, kind: .link(.linked)) where e.isLive {
                guard seen.insert(e.from).inserted, let b = hosts.block(e.from) else { continue }
                cards.append(LinkCard(link: e.id, block: e.from, title: Self.linkTitle(b), symbol: Theme.symbolName(for: b.kind, path: b.path), outbound: false, archived: b.isArchived))
            }
        }
        return cards
    }

    /// A linked block's name on a badge: a note by its title or first words.
    private static func linkTitle(_ b: Block) -> String { b.kind == .text && b.path == nil ? noteTitle(b) : b.displayTitle }

    /// A block ⇧-dragged onto another: linked, from it to the target.
    func link(_ block: BlockID, to target: BlockID) {
        guard block != target else { return }
        hosts.link(from: block, to: target, kind: .linked, context: hosts.block(block)?.displayTitle)
    }

    /// Debugging: typed into the focused editor, as keys would be.
    func debugType(_ text: String) -> String {
        guard let e = debugFocusedEditor else { return "no editor focused" }
        e.debugType(text)
        return "typed \(text.count)"
    }

    /// Debugging: a block ⇧-dragged into the focused editor, dropped at its caret.
    func debugDrop(_ block: BlockID) -> String {
        guard let e = debugFocusedEditor, let b = hosts.block(block) else { return "no editor focused, or no such block" }
        let pb = NSPasteboard(name: NSPasteboard.Name("com.manifold.debug-drop"))
        pb.clearContents()
        pb.setString("[\(b.displayTitle)](manifold:\(block.description))", forType: .manifoldBlockLink)
        pb.setString(b.path ?? b.terminal?.cwd ?? "", forType: .string)
        return e.debugDrop(pb) ? "dropped" : "refused"
    }

    /// What to call a note: its title, else its first line, else "Note".
    static func noteTitle(_ b: Block) -> String {
        if let t = b.title, !t.isEmpty { return t }
        if let first = b.text?.text.string.split(separator: "\n").first(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty }) {
            return String(first.trimmingCharacters(in: CharacterSet(charactersIn: "# ")).prefix(60))
        }
        return b.displayTitle
    }

    /// A linked block from a tile's badge: gone to where it is; placed
    /// nowhere, opened beside the tile.
    func gridOpenLink(_ block: BlockID, from placement: PlacementID, over: Bool) {
        let placed = allWorkspaces.contains { hosts.arrangement($0)?.placements(of: block).isEmpty == false }
        if over, let b = hosts.block(block), b.kind != .arrangement {
            show(block, lens: Lens.default(for: b.kind, path: b.path), .over(placement))
        } else if placed, let b = hosts.block(block) {
            goTo(b.id)
        } else if let b = hosts.block(block) {
            show(block, lens: Lens.default(for: b.kind, path: b.path), .besideOpener(placement), kind: .opened)
        }
    }

    /// × on a badge's link: the edge ends, in both readings at once.
    func gridBreakLink(_ link: String) { hosts.propose(.unlink(link)) }

    /// A tile's dirty dot clicked: its text saved. Changed on disk under
    /// the edits too, a choice: the file as it is now, or the edits over it.
    func gridDirtyClicked(_ placement: PlacementID, from view: NSView) {
        guard let p = arrangement?.placement(placement), let t = hosts.block(p.block)?.text, t.isDirty else { return }
        focus(placement)
        guard t.stale else { return save(p.block, from: placement) }
        let menu = NSMenu()
        menu.addItem(ClosureMenuItem("Reload from Disk, Losing the Edits", symbol: "arrow.clockwise") { [weak self] in
            self?.hosts.propose(.readFile(p.block))
        })
        menu.addItem(ClosureMenuItem("Overwrite with the Edits", symbol: "square.and.arrow.down") { [weak self] in
            self?.save(p.block, from: placement)
        })
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: -4), in: view)
    }

    /// Saves a text block: through an editor on it (this tile's first),
    /// which keeps its own count of what's saved and names a note's file;
    /// else straight to its file.
    private func save(_ block: BlockID, from placement: PlacementID) {
        let editors = views.values.compactMap { $0 as? EditorView }.filter { $0.block == block }
        if let e = editors.first(where: { $0.placement == placement }) ?? editors.first { return e.saveDocument(nil) }
        guard let b = hosts.block(block), b.path != nil, let t = b.text else { return NSSound.beep() }
        hosts.propose(.writeFile(block, version: t.version, text: t.text.string))
    }

    /// The bar's ×: the tile taken off, as ⌘W takes the focused one.
    func gridClose(_ placement: PlacementID) {
        guard let a = arrangement, let id = selected, let block = a.placement(placement)?.block else { return }
        hosts.append([.remove(placement)], to: .block(id))
        discardIfUnplaced(block)
        if hosts.arrangement(id)?.isEmpty == true, !a.isNamed { removeFromDesk(id) }
    }

    func gridLink(_ block: BlockID, to target: PlacementID) {
        guard let t = shown(target)?.block else { return }
        link(block, to: t.id)
    }

    /// ⌘L: the focused tile's pill edits what it offers (a page's address).
    @objc func editAddress(_ sender: Any?) {
        if !content.editFocusedPill() { NSSound.beep() }
    }

    /// Open Folder…: a folder chosen, browsed beside the focused block.
    @objc func openFolder(_ sender: Any?) {
        guard let window else { return }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Browse"
        if let cwd = focusedCwd { panel.directoryURL = URL(fileURLWithPath: cwd) }
        panel.beginSheetModal(for: window) { [weak self] response in
            guard let self, response == .OK, let url = panel.url else { return }
            self.show(self.host.directoryBlock(for: url.path), lens: .directory, .here)
        }
    }

    /// Browse This Folder: the focused block's folder, beside it.
    @objc func browseFocusedFolder(_ sender: Any?) {
        guard let cwd = focusedCwd, let client = hosts.client(focusedHost) else { return NSSound.beep() }
        show(client.directoryBlock(for: cwd), lens: .directory, .here)
    }

    /// ⌘W: the focused block leaves its column, which shows what it showed
    /// before (its block stays, to be found again); an unnamed arrangement
    /// left empty leaves the desk.
    @objc func closePaneOrTab(_ sender: Any?) {
        if palette != nil, palette?.dismissable == true { return hidePalette() }
        guard let a = arrangement, let id = selected else { return }
        if let f = a.focused {
            // Taken off, a tile's room goes to the first of the stack
            // behind it, if there is one, which comes back where it was
            // and takes the focus (the model's doing); else to the next.
            let block = a.placement(f)?.block
            hosts.append([.remove(f)], to: .block(id))
            if let block { discardIfUnplaced(block) }
        }
        if hosts.arrangement(id)?.isEmpty == true, !a.isNamed {
            removeFromDesk(id)
        }
    }

    /// ⇧⌘W: the arrangement leaves the desk.
    @objc func closeTab(_ sender: Any?) {
        if let id = selected { removeFromDesk(id) }
    }

    /// Every workspace on every host, in the sidebar's order.
    private var allWorkspaces: [BlockID] { hosts.all.flatMap { $0.desk.order } }

    private func removeFromDesk(_ id: BlockID) {
        let all = allWorkspaces
        guard let i = all.firstIndex(of: id) else { return }
        hosts.client(of: id)?.removeWorkspace(id)
        if selected == id {
            let rest = all.filter { $0 != id }
            hosts.select(rest.isEmpty ? nil : rest[min(i, rest.count - 1)])
        }
    }

    /// Detaches from a host, once asked: it's forgotten here, and a
    /// workspace of its shown gives way to one elsewhere.
    private func detach(_ host: HostID) {
        let alert = NSAlert()
        alert.messageText = "Detach from \(hosts.label(of: host))?"
        alert.informativeText = "Manifold forgets the host and won't attach to it again at start. Its server, shells and blocks stay there; attach to it again to have them back."
        alert.addButton(withTitle: "Detach")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        if let id = selected, id.host == host {
            let all = allWorkspaces
            let rest = all.filter { $0.host != host }
            let i = all.firstIndex(of: id) ?? 0
            hosts.select(rest.isEmpty ? nil : rest[min(i, rest.count - 1)])
        }
        hosts.detach(host)
    }

    @objc func renameTab(_ sender: Any?) {
        if let id = selected { rename(id) }
    }

    /// File ▸ Name Note…: the focused note's name, in its pill.
    @objc func nameFocusedNote(_ sender: Any?) {
        if let f = focusedShown { nameNote(f.id) }
    }

    /// A note named in its tile's pill, as it is — nothing saved: the
    /// name is the block's title, kept in its log, until a file's name
    /// takes over. Emptied, it's Untitled again.
    func nameNote(_ placement: PlacementID) {
        guard let a = arrangement, let p = a.placement(placement), let b = hosts.block(p.block), b.isNote else { return }
        focus(placement)
        let block = p.block
        content.editPill(placement, PillEdit(text: b.title ?? "", placeholder: "Name this note", overName: true) { [weak self] name in
            self?.hosts.append(.title(name.isEmpty ? nil : name), to: .block(block))
        })
    }

    @objc func togglePinnedSidebar(_ sender: Any?) { sidebarTogglePinned() }

    @objc func setColorScheme(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let scheme = ColorScheme(rawValue: raw) else { return }
        var a = hosts.state.appearance
        a.colorScheme = scheme
        hosts.setAppearance(a)
    }

    @objc func setTheme(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let theme = FontTheme(rawValue: raw) else { return }
        var a = hosts.state.appearance
        a.theme = theme
        hosts.setAppearance(a)
    }

    @objc func setEditorFont(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let font = EditorFont(rawValue: raw) else { return }
        var a = hosts.state.appearance
        a.editorFont = font
        hosts.setAppearance(a)
    }

    @objc func setContrastCorrection(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let mode = ContrastCorrection(rawValue: raw) else { return }
        var a = hosts.state.appearance
        a.contrastCorrection = mode
        hosts.setAppearance(a)
    }

    @objc func validateMenuItem(_ item: NSMenuItem) -> Bool {
        switch item.action {
        case #selector(setTerminalDormancy(_:)):
            item.state = item.tag == desk.settings.terminalDormantAfterHours ? .on : .off
        case #selector(toggleEditPreview(_:)), #selector(editPreviewBeside(_:)):
            guard let f = focusedShown, f.lens.isText, f.block?.kind == .text else { return false }
            let viewing = f.lens == .preview
            item.title = item.action == #selector(toggleEditPreview(_:)) ? (viewing ? "Edit" : "View") : (viewing ? "Edit Beside" : "View Beside")
            return true
        case #selector(setTextHistory(_:)):
            item.state = item.tag == desk.settings.textHistoryDays ? .on : .off
        case #selector(setTranscriptHistory(_:)):
            item.state = item.tag == desk.settings.terminalHistoryDays ? .on : .off
        case #selector(setUndoDepth(_:)):
            item.state = item.tag == desk.settings.undoDepth ? .on : .off
        case #selector(setColorScheme(_:)):
            item.state = (item.representedObject as? String) == hosts.state.appearance.colorScheme.rawValue ? .on : .off
        case #selector(setTheme(_:)):
            item.state = (item.representedObject as? String) == hosts.state.appearance.theme.rawValue ? .on : .off
        case #selector(setEditorFont(_:)):
            item.state = (item.representedObject as? String) == hosts.state.appearance.editorFont.rawValue ? .on : .off
        case #selector(setContrastCorrection(_:)):
            item.state = (item.representedObject as? String) == hosts.state.appearance.contrastCorrection.rawValue ? .on : .off
        case #selector(nameFocusedNote(_:)):
            return focusedShown?.block?.isNote == true
        case #selector(togglePinnedSidebar(_:)):
            item.title = pinned ? "Hide Sidebar" : "Show Sidebar"
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
        show(arrangement: order[(i + d + order.count) % order.count], slidingFrom: CGFloat(d))
    }

    /// Selects an arrangement, which slides in from `dir`'s side over the
    /// one shown.
    private func show(arrangement id: BlockID, slidingFrom dir: CGFloat) {
        guard id != selected else { return }
        pendingSlide = dir
        hosts.select(id)
    }

    // MARK: ⌃⇥

    /// ⌃⇥ (⌃⇧⇥ back): with control held, a walk through the arrangements
    /// most recently settled on first, each shown at once sliding in from
    /// the right (from the left, going back); letting go of control settles
    /// on the one come to. The ones passed on the way aren't settled on;
    /// Escape goes back to where the walk began.
    @objc func walkTabs(_ sender: Any?) { walkTabs(back: false) }
    @objc func walkTabsBack(_ sender: Any?) { walkTabs(back: true) }

    private func walkTabs(back: Bool) {
        let live = Set(allWorkspaces)
        if walk == nil {
            guard let current = selected, allWorkspaces.count > 1 else { return }
            var order = [current]
            for id in hosts.state.settled + allWorkspaces where live.contains(id) && !order.contains(id) { order.append(id) }
            walk = (order, 0)
            if NSEvent.modifierFlags.contains(.control) { watchWalk() }
        }
        guard var w = walk else { return }
        w.ids = w.ids.filter { live.contains($0) }
        guard w.ids.count > 1 else { return endWalk(settling: true) }
        let n = w.ids.count
        w.index = ((back ? w.index - 1 : w.index + 1) % n + n) % n
        walk = w
        show(arrangement: w.ids[w.index], slidingFrom: back ? -1 : 1)
        // From the menu, without control held, it's one step and settled.
        if walkMonitors.isEmpty { endWalk(settling: true) }
    }

    private func watchWalk() {
        walkMonitors.append(NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            if !event.modifierFlags.contains(.control) { self?.endWalk(settling: true) }
            return event
        } as Any)
        walkMonitors.append(NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard event.keyCode == 53 else { return event }
            self?.endWalk(settling: false)
            return nil
        } as Any)
    }

    private func endWalk(settling: Bool) {
        walkMonitors.forEach(NSEvent.removeMonitor)
        walkMonitors = []
        guard let w = walk else { return }
        walk = nil
        if settling {
            hosts.append(.settled(w.ids[w.index]), to: .desk(host.host))
        } else if let home = w.ids.first {
            show(arrangement: home, slidingFrom: -1)
        }
    }

    // MARK: ⌘E

    /// ⌘E (⇧⌘E back): with ⌘ held, the focused tile's stack as a file of
    /// cards over its tile — the top drops flat to the bottom and the one
    /// beneath stands up in front, leaning back, the title bars of the
    /// rest behind it; each E flips the next one down, scrolling works
    /// too, and letting go of ⌘ brings the chosen one forward to the top
    /// (Escape leaves things be). From the menu it's one step. Without a
    /// stack, ⌘E finds the word at hand, as the Find menu has it.
    @objc func walkStack(_ sender: Any?) { walkStack(back: false) }
    @objc func walkStackBack(_ sender: Any?) { walkStack(back: true) }

    private func walkStack(back: Bool) {
        guard let a = arrangement, let f = a.focused else { return findWordAtHand() }
        if content.isSwitching {
            _ = content.stepStackSwitcher(f, back: back)
            return
        }
        guard !a.isStashed(f), content.stepStackSwitcher(f, back: back) else { return findWordAtHand() }
        if NSEvent.modifierFlags.contains(.command) {
            watchStackWalk()
        } else {
            // From the menu: one step, seen, then settled on.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in self?.content.settleStackSwitcher() }
        }
    }

    private func watchStackWalk() {
        stackMonitors.append(NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            if !event.modifierFlags.contains(.command) { self?.endStackWalk(settling: true) }
            return event
        } as Any)
        stackMonitors.append(NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard event.keyCode == 53 else { return event }
            self?.endStackWalk(settling: false)
            return nil
        } as Any)
    }

    private func endStackWalk(settling: Bool) {
        stackMonitors.forEach(NSEvent.removeMonitor)
        stackMonitors = []
        content.settleStackSwitcher(cancel: !settling)
    }

    /// Find Word at Hand, as the Find menu's item does it.
    private func findWordAtHand() {
        let item = NSMenuItem()
        item.tag = NSTextFinder.Action.setSearchString.rawValue
        NSApp.sendAction(#selector(NSTextView.performTextFinderAction(_:)), to: nil, from: item)
    }

    /// The arrangement about to be shown slides in from `dir`'s side over
    /// the one shown, which slides out the other way, both live. Only their
    /// layers move, so nothing is laid out again on the way.
    private func slide(from dir: CGFloat) {
        finishSlide()
        let frame = content.frame
        swap(&content, &outgoing)
        content.frame = frame
        root.addSubview(content, positioned: .above, relativeTo: outgoing)
        guard let incoming = content.layer, let leaving = outgoing.layer else { return finishSlide() }
        sliding = true
        CATransaction.begin()
        CATransaction.setCompletionBlock { [weak self] in self?.finishSlide() }
        let ease = CAMediaTimingFunction(controlPoints: 0.2, 0.8, 0.25, 1)
        let move = { (layer: CALayer, from: CGFloat, to: CGFloat) in
            let a = CABasicAnimation(keyPath: "transform")
            a.fromValue = CATransform3DMakeTranslation(from, 0, 0)
            a.toValue = CATransform3DMakeTranslation(to, 0, 0)
            a.duration = 0.22
            a.timingFunction = ease
            a.fillMode = .forwards
            a.isRemovedOnCompletion = false
            layer.add(a, forKey: "manifold.slide")
        }
        move(incoming, dir * frame.width, 0)
        move(leaving, 0, -dir * frame.width)
        CATransaction.commit()
    }

    /// The arrangement slid away lets go of its views and goes.
    private func finishSlide() {
        guard sliding else { return }
        sliding = false
        content.layer?.removeAnimation(forKey: "manifold.slide")
        outgoing.layer?.removeAnimation(forKey: "manifold.slide")
        outgoing.clear()
        outgoing.removeFromSuperview()
    }

    @objc func selectTabByNumber(_ sender: NSMenuItem) {
        let order = allWorkspaces
        guard !order.isEmpty else { return }
        let n = sender.tag
        let i = n == 9 ? order.count - 1 : n - 1
        if i < order.count { hosts.select(order[i]) }
    }

    // MARK: Tiles

    @objc func nextTile(_ sender: Any?) { stepPane(1) }
    @objc func previousTile(_ sender: Any?) { stepPane(-1) }

    private func stepPane(_ d: Int) {
        guard let a = arrangement, a.visible.count > 1 else { return }
        let visible = a.visible
        let i = visible.firstIndex { $0.id == a.focused } ?? 0
        focus(visible[(i + d + visible.count) % visible.count].id)
    }

    /// Focuses a tile of the selected arrangement.
    func focus(_ placement: PlacementID) {
        guard let a = arrangement, a.placement(placement) != nil, a.focused != placement || a.isStashed(placement) else { return }
        appendToSelected(revealing(placement, in: a))
    }

    /// What brings a tile into view and focus: a maximized other tile
    /// gives way, a stashed one comes back (as its tile's lower half),
    /// and it is focused.
    private func revealing(_ placement: PlacementID, in a: ArrangementState) -> [Event] { a.revealing(placement) }

    /// Grow (acme's colgrow): the focused tile takes a step from its
    /// neighbors; with ⇧, as much of its column as can be.
    @objc func growTile(_ sender: Any?) {
        guard let a = arrangement, let f = a.focused else { return }
        appendToSelected(a.growing(f, whole: NSApp.currentEvent?.modifierFlags.contains(.shift) == true))
    }

    @objc func fillColumn(_ sender: Any?) {
        guard let a = arrangement, let f = a.focused else { return }
        appendToSelected(a.growing(f, whole: true))
    }

    // MARK: Organizations (§3.6)

    private var organizationWork: DispatchWorkItem?
    /// The block the Links organization is centered on, when not the focused.
    private var linksCenter: BlockID?

    var organization: Organization {
        Organization(rawValue: hosts.state.window.organization ?? "") ?? .desk
    }

    @objc func organizeByDesk(_ sender: Any?) { setOrganization(.desk) }
    @objc func organizeByFiles(_ sender: Any?) { setOrganization(.files) }
    @objc func organizeByLinks(_ sender: Any?) { setOrganization(.links) }
    @objc func organizeByTime(_ sender: Any?) { setOrganization(.time) }
    @objc func organizeByStatus(_ sender: Any?) { setOrganization(.status) }
    @objc func organizeByInbox(_ sender: Any?) { setOrganization(.inbox) }

    func setOrganization(_ org: Organization, show: Bool = true) {
        var state = hosts.state.window
        state.organization = org.rawValue
        if state != hosts.state.window { hosts.setWindow(state) }
        sidebar.setOrganization(org)
        if show, !sidebarShown { showSidebar(animated: true) }
        refreshOrganization(now: true)
    }

    /// The sidebar's tree again, a moment after the last change (the
    /// desk's sooner: it follows the focus).
    func refreshOrganization(now: Bool = false) {
        let org = organization
        if sidebar.organization != org { sidebar.setOrganization(org) }
        organizationWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            let filter = self.sidebar.filterText.lowercased()
            let (nodes, open) = self.organizationTree(org, filter: filter)
            let selected = org == .desk ? self.deskSelectedRow : nil
            // The counts: what needs you, what's working, and what's done
            // or failed and not yet read — one attended to is counted no more.
            let g = self.statusGroups("")
            let unread = (g[.done] ?? []).filter { $0.1?.read != true }.count + (g[.failed] ?? []).filter { $0.1?.read != true }.count
            self.sidebar.setCounts(needsYou: g[.needsYou]?.count ?? 0, working: g[.working]?.count ?? 0, done: unread)
            // Flat, with sections, where rows are blocks by place or state;
            // a tree with chevrons where the nesting is the point (folders, links).
            self.sidebar.organizationView.flat = [.desk, .inbox, .status].contains(org)
            self.sidebar.organizationView.show(nodes, openByDefault: open, selected: selected)
        }
        organizationWork = work
        if now { work.perform() } else { DispatchQueue.main.asyncAfter(deadline: .now() + (org == .desk ? 0.05 : 0.2), execute: work) }
    }

    /// The desk row for the focused tile of the selected arrangement.
    private var deskSelectedRow: String? {
        guard let id = selected, let a = hosts.arrangement(id) else { return nil }
        if let f = a.focusedPlacement { return "arr/\(id)/tile/\(f.id)" }
        return "arr/\(id)"
    }

    private static func age(_ stamp: Stamp?) -> Double? {
        guard let stamp else { return nil }
        let hours = Date().timeIntervalSince(stamp.date) / 3600
        return min(1, max(0, (hours - 1) / 167))
    }

    private func node(for block: Block, id: String? = nil, detail: String? = nil) -> OrgNode {
        let seen = hosts.client(of: block.id)?.node.graph.seen(block.id)
        let n = OrgNode(id: id ?? block.id.description, block: block.id, title: block.displayTitle,
                        symbol: Theme.symbolName(for: block.kind, path: block.path), detail: detail ?? "", age: Self.age(seen))
        n.look = StatusGlyph.look(of: block)
        n.tooltip = StatusGlyph.tooltip(block)
        n.trailing = StatusGlyph.at(of: block).map(Age.short)
        return n
    }

    /// Status (§3.7): blocks by what they are doing — needs you, done,
    /// failed, working, inactive — the unread first in each, each row
    /// with how long ago at the right. Nothing idle, there being nothing
    /// to say of it.
    /// Every block with something to say, by status group, the unread
    /// first and the newest next.
    private func statusGroups(_ filter: String) -> [StatusGroup: [(Block, StatusRecord?, Stamp)]] {
        var groups: [StatusGroup: [(Block, StatusRecord?, Stamp)]] = [:]
        for c in hosts.all {
            for b in c.node.blocks where !b.isArchived {
                guard let look = StatusGlyph.look(of: b) else { continue }
                let r = b.statusRecord
                guard matches(filter, [b.displayTitle, b.path, r?.msg, r?.app]) else { continue }
                let at = r?.at ?? b.terminal?.dormantSince ?? b.created
                groups[StatusGroup(look), default: []].append((b, r, at))
            }
        }
        return groups.mapValues { items in
            items.sorted { a, b in
                let ua = a.1?.wantsAttention ?? false, ub = b.1?.wantsAttention ?? false
                return ua != ub ? ua : a.2 > b.2
            }
        }
    }

    /// Inbox (§3.7): the blocks whose status came to need attention and
    /// haven't been taken out by hand — by host, then by the workspace
    /// they're in, each with what it said and how long ago.
    private func inboxTree(_ filter: String) -> ([OrgNode], Set<String>) {
        var nodes: [OrgNode] = []
        var open: Set<String> = []
        for c in hosts.all {
            let blocks = c.node.blocks.filter { $0.isInInbox && !$0.isArchived && matches(filter, [$0.displayTitle, $0.path, $0.statusRecord?.msg, $0.statusRecord?.app]) }
            guard !blocks.isEmpty else { continue }
            // Which workspace holds each, the first that does; the rest elsewhere.
            var byWorkspace: [(BlockID?, [Block])] = []
            for b in blocks.sorted(by: { ($0.statusRecord?.at ?? $0.created) > ($1.statusRecord?.at ?? $1.created) }) {
                let w = allWorkspaces.first { hosts.arrangement($0)?.placements(of: b.id).isEmpty == false }
                if let i = byWorkspace.firstIndex(where: { $0.0 == w }) { byWorkspace[i].1.append(b) } else { byWorkspace.append((w, [b])) }
            }
            let hid = "inbox:host:\(c.host.raw)"
            let sections = byWorkspace.map { w, items -> OrgNode in
                let title = w.flatMap { hosts.arrangement($0) }.map { self.title(of: $0) } ?? "Elsewhere"
                let sid = hid + "/" + (w?.description ?? "elsewhere")
                let rows = items.map { b -> OrgNode in
                    let r = b.statusRecord
                    var words: [String] = []
                    if let app = r?.app { words.append(app) }
                    if let msg = r?.msg, !msg.isEmpty { words.append(msg) } else if let t = r?.title, !t.isEmpty { words.append(t) }
                    if words.isEmpty, let s = StatusGlyph.summary(b) { words.append(s) }
                    let n = node(for: b, id: sid + "/" + b.id.description, detail: words.joined(separator: " · "))
                    n.trailing = Age.short(r?.at ?? b.created)
                    n.emphasis = r?.wantsAttention ?? false
                    n.age = nil
                    return n
                }
                let s = OrgNode(id: sid, block: w, title: title, symbol: "rectangle.3.group", count: rows.count, isGroup: true, children: rows)
                s.style = .section
                s.arrangement = w
                open.insert(sid)
                return s
            }
            let h = OrgNode(id: hid, title: hosts.label(of: c.host), symbol: c.isRemote ? "server.rack" : "laptopcomputer", count: blocks.count, isGroup: true, children: sections)
            h.style = .host
            open.insert(hid)
            nodes.append(h)
        }
        if nodes.isEmpty { return ([OrgNode(id: "none", title: "Nothing to attend to", symbol: "tray")], []) }
        return (nodes, open)
    }

    private func statusTree(_ filter: String) -> ([OrgNode], Set<String>) {
        let groups = statusGroups(filter)
        var open: Set<String> = []
        let nodes = StatusGroup.allCases.compactMap { group -> OrgNode? in
            guard let items = groups[group] else { return nil }
            let (title, symbol) = (group.title, group.symbol)
            let id = "status:\(group)"
            if group != .inactive { open.insert(id) }
            let children = items.map { block, r, at -> OrgNode in
                var words: [String] = []
                if let app = r?.app { words.append(app) }
                if let msg = r?.msg, !msg.isEmpty { words.append(msg) } else if let t = r?.title, !t.isEmpty { words.append(t) }
                let n = node(for: block, id: id + "/" + block.id.description, detail: words.joined(separator: " · "))
                n.trailing = Age.short(at)
                n.emphasis = r?.wantsAttention ?? false
                n.age = group == .inactive ? 0.6 : nil
                return n
            }
            let n = OrgNode(id: id, title: title, symbol: symbol, count: items.count, isGroup: true, children: children)
            n.style = .section
            // The group's row opens it in the surface as a state view (§3.6).
            n.action = { [weak self] in self?.showStateView(group) }
            n.emphasis = stateGroup == group
            return n
        }
        if nodes.isEmpty { return ([OrgNode(id: "none", title: "Nothing is doing anything", symbol: "circle.dashed")], []) }
        return (nodes, open)
    }

    // MARK: State views (§3.6)

    private var stateView: StateView?
    private var stateGroup: StatusGroup?
    private var stateMode: StateView.Mode = .list

    /// The surface shows a status group's blocks themselves, live.
    /// ⌘': every block in the workspace at once, as Mission Control shows
    /// windows; again, or ⎋, back to the workspace.
    @objc func showWorkspaceOverview(_ sender: Any?) {
        guard let id = selected, hosts.arrangement(id) != nil else { return NSSound.beep() }
        if stateWorkspace == id { return hideStateView() }
        stateGroup = nil
        stateWorkspace = id
        stateMode = .overview
        presentStateView()
    }

    /// The workspace shown as an overview (⌘'), if one is.
    private var stateWorkspace: BlockID?

    func showStateView(_ group: StatusGroup) {
        stateGroup = group
        stateWorkspace = nil
        presentStateView()
    }

    private func presentStateView() {
        if stateView == nil {
            let v = StateView()
            v.onGoTo = { [weak self] b in self?.goTo(b) }
            v.onBring = { [weak self] b in
                guard let self, let block = self.hosts.block(b) else { return }
                self.hideStateView()
                self.show(b, lens: Lens.default(for: block.kind, path: block.path), .here)
            }
            v.onLeave = { [weak self] in self?.hideStateView() }
            v.onModeChanged = { [weak self] m in self?.stateMode = m }
            root.addSubview(v, positioned: .above, relativeTo: content)
            stateView = v
        }
        stateMembers = []
        content.isHidden = true
        layoutViews()
        render()
        window?.makeFirstResponder(stateView)
    }

    func hideStateView() {
        guard let v = stateView else { return }
        v.clear()
        v.removeFromSuperview()
        stateView = nil
        stateGroup = nil
        stateWorkspace = nil
        content.isHidden = false
        render()
    }

    /// The blocks the state view shows, in order, while it's up.
    private var stateMembers: [BlockID] = []
    /// When each diff was last compared at a view's asking.
    private var diffReloaded: [BlockID: Date] = [:]

    func debugStateView(mode: StateView.Mode) {
        stateMode = mode
        render()
    }

    /// The state view's placement ids: a block's, not an arrangement's.
    private static func statePlacement(_ block: BlockID) -> PlacementID { "state:\(block)" }

    private func matches(_ filter: String, _ texts: [String?]) -> Bool {
        filter.isEmpty || texts.contains { $0?.lowercased().contains(filter) ?? false }
    }

    func organizationTree(_ org: Organization, filter: String) -> ([OrgNode], Set<String>) {
        switch org {
        case .desk: return deskTree(filter)
        case .files: return filesTree(filter)
        case .links: return linksTree(filter)
        case .time: return timeTree(filter)
        case .status: return statusTree(filter)
        case .inbox: return inboxTree(filter)
        }
    }

    /// Workspaces (§3.6): every attached host's, under its host when there
    /// is more than one, each expanding to its tiles in order (by column,
    /// top to bottom), the selected one open and the focused tile marked:
    /// the table of contents of the screen.
    /// The current workspace folded in the sidebar, by a click on its
    /// label: only what peeks out shows, until clicked again.
    private var deskFolded = false

    /// Whether a tile peeks out of a folded workspace (§3.5): it has a
    /// status to attend to or to watch — working, needs you, done, failed.
    private func peeks(_ b: Block?) -> Bool {
        switch StatusGlyph.look(of: b) {
        case .working, .needsYou, .done, .failed: true
        default: false
        }
    }

    private func deskTree(_ filter: String) -> ([OrgNode], Set<String>) {
        var open: Set<String> = []
        func workspace(_ id: BlockID) -> OrgNode? {
            guard let a = hosts.arrangement(id) else { return nil }
            let aid = "arr/\(id)"
            // The current workspace whole; the others folded to the tiles
            // that peek out (as apex folds them), unless there's a filter.
            let whole = (id == selected && !deskFolded) || !filter.isEmpty
            var tiles: [OrgNode] = []
            for (c, column) in a.columns.enumerated() {
                for p in column {
                    let b = hosts.block(p.block)
                    let title = b?.displayTitle ?? "On \(hosts.label(of: p.block.host))"
                    guard matches(filter, [title, b?.path]) else { continue }
                    guard whole || peeks(b) else { continue }
                    // Its status, in words, with the glyph before them; else
                    // its state — stashed, maximized — as a small symbol.
                    var notes: [String] = []
                    if let status = StatusGlyph.summary(b) { notes.append(status) }
                    if b == nil { notes.append("not attached") }
                    if b?.text?.isDirty == true { notes.append("edited") }
                    let n = OrgNode(id: "\(aid)/tile/\(p.id)", block: p.block, title: title,
                                    symbol: b.map { Theme.symbolName(for: $0.kind, path: $0.path) } ?? "questionmark.square.dashed",
                                    detail: notes.joined(separator: " · "))
                    if a.isStashed(p.id) { n.detailSymbol = "tray.and.arrow.down" } else if a.full == p.id { n.detailSymbol = "arrow.up.left.and.arrow.down.right" }
                    n.look = StatusGlyph.look(of: b); n.tooltip = StatusGlyph.tooltip(b)
                    n.trailing = StatusGlyph.at(of: b).map(Age.short)
                    n.arrangement = id
                    n.column = c
                    n.placement = p.id
                    n.emphasis = id == selected && p.id == a.focused
                    tiles.append(n)
                }
            }
            let titleMatches = matches(filter, [title(of: a)])
            guard filter.isEmpty || titleMatches || !tiles.isEmpty else { return nil }
            let focused = a.focusedPlacement.flatMap { hosts.block($0.block) }
            let n = OrgNode(id: aid, block: id, title: title(of: a),
                            symbol: a.placements.count > 1 ? "rectangle.split.2x1" : focused.map { Theme.symbolName(for: $0.kind, path: $0.path) } ?? "rectangle.3.group",
                            detail: a.isNamed ? "kept" : "", count: a.placements.count > 1 ? a.placements.count : nil, children: tiles)
            n.arrangement = id
            n.style = .section
            n.emphasis = id == selected
            let needing = a.placements.filter { StatusGlyph.look(of: hosts.block($0.block)) == .needsYou }.count
            if needing > 0 { n.trailing = needing == 1 ? "1 needs you" : "\(needing) need you" }
            if !tiles.isEmpty { open.insert(aid) }
            return n
        }
        // Each host's workspaces, in its desk's order, with any of its that
        // this desk has taken up.
        var byHost: [(HostClient, [OrgNode])] = []
        for c in hosts.ordered {
            var ids = c.desk.order.filter { $0.host == c.host }
            for id in allWorkspaces where id.host == c.host && !ids.contains(id) { ids.append(id) }
            var nodes = ids.compactMap(workspace)
            // Workspaces off the desk — kept by name, or just taken off —
            // under Recent, the last seen first, opened by hovering (or
            // outright with a filter); one chosen comes back onto the desk.
            let onDesk = Set(ids)
            let far = Stamp(wall: 0, logical: 0, host: c.host)
            let off = c.node.blocks.filter { $0.kind == .arrangement && !onDesk.contains($0.id) && !($0.arrangement?.isEmpty ?? true) }
                .sorted { (c.node.graph.seen($0.id) ?? far) > (c.node.graph.seen($1.id) ?? far) }
                .prefix(40)
            let recent = off.compactMap { workspace($0.id) }
            // Archived blocks (§3.7): put away, under their own section,
            // the last seen first, each recalled as it was by a click.
            let archived = c.node.blocks.filter { $0.isArchived && $0.kind != .arrangement && matches(filter, [$0.displayTitle, $0.path]) }
                .sorted { (c.node.graph.seen($0.id) ?? far) > (c.node.graph.seen($1.id) ?? far) }
                .prefix(40)
            if !archived.isEmpty {
                let rid = "archived:desk:\(c.host.raw)"
                let rows = archived.map { b -> OrgNode in
                    let n = node(for: b, id: rid + "/" + b.id.description, detail: b.place?.abbreviatingHome ?? "")
                    n.dimmed = true
                    n.trailing = (c.node.graph.seen(b.id)).map(Age.short)
                    return n
                }
                let group = OrgNode(id: rid, title: "Archived", symbol: "archivebox", count: rows.count, isGroup: true, children: rows)
                group.style = .section
                group.dimmed = true
                nodes.append(group)
            }
            if !recent.isEmpty {
                let rid = "recent:desk:\(c.host.raw)"
                for n in recent { n.dimmed = true; n.emphasis = false; open.remove(n.id) }
                let group = OrgNode(id: rid, title: "Recent", symbol: "clock", count: recent.count, isGroup: true, children: recent)
                group.style = .section
                group.dimmed = true
                if !filter.isEmpty { open.insert(rid) }
                nodes.append(group)
            }
            byHost.append((c, nodes))
        }
        guard byHost.count > 1 else { return (byHost.first?.1 ?? [], open) }
        let roots = byHost.map { c, nodes -> OrgNode in
            let id = "host:\(c.host.raw)"
            open.insert(id)
            let n = OrgNode(id: id, title: hosts.label(of: c.host), symbol: c.isRemote ? "server.rack" : "laptopcomputer", count: nodes.count, isGroup: true, children: nodes)
            n.style = .host
            hostStanding(n, c)
            return n
        }
        return (roots, open)
    }

    /// Files: each host's sparse tree, roots open.
    private func filesTree(_ filter: String) -> ([OrgNode], Set<String>) {
        var open: Set<String> = []
        // What is on a workspace now comes first in every folder; the rest
        // after, dimmed — a folder with something active among its blocks
        // counts as active.
        let placed = Set(allWorkspaces.compactMap { hosts.arrangement($0) }.flatMap { $0.placements.map(\.block) })
        var active: [ObjectIdentifier: Bool] = [:]
        func convert(_ f: FileNode) -> OrgNode? {
            let made = f.children.compactMap(convert)
            var children = made.filter { active[ObjectIdentifier($0)] == true }
            // The rest — not on any workspace now — under Recent, which
            // opens when the pointer rests on it (or with a filter).
            let rest = made.filter { active[ObjectIdentifier($0)] != true }
            if !rest.isEmpty {
                let recentID = "recent:\(f.host.raw):\(f.path)"
                let recent = OrgNode(id: recentID, title: "Recent", symbol: "clock", count: rest.count, isGroup: true, children: rest)
                recent.dimmed = true
                if !filter.isEmpty { open.insert(recentID) }
                children.append(recent)
            }
            let block = f.block.flatMap { hosts.block($0) }
            if !filter.isEmpty, children.isEmpty, !matches(filter, [f.name, f.path]) { return nil }
            let id = "file:\(f.host.raw):\(f.path)"
            let isActive = f.block.map { placed.contains($0) } ?? false || children.contains { active[ObjectIdentifier($0)] == true }
            if f.isFolder {
                if !filter.isEmpty { open.insert(id) }
                let node = OrgNode(id: id, block: f.block, title: f.name, symbol: f.kind == .git ? "arrow.triangle.branch" : "folder",
                               detail: "", count: children.isEmpty ? nil : f.count, age: Self.age(f.latest), isGroup: true, children: children)
                if f.block == nil {
                    // A folder with no listing yet: clicked, it's listed on
                    // its host (the disclosure, or a double-click, opens it).
                    let path = f.path, on = f.host
                    node.action = { [weak self] in self?.openDirectory(path, on: on) }
                }
                node.dimmed = !isActive
                active[ObjectIdentifier(node)] = isActive
                return node
            }
            let edited = block?.text?.isDirty == true ? "edited" : ""
            if f.isPlace, let block {
                // At the folder, not a file in it: by its own title (a
                // terminal whose title is only its folder says "Terminal").
                let shown = block.displayTitle
                let title = block.terminal != nil && (shown.hasPrefix("~") || shown.hasPrefix("/")) ? block.kind.defaultTitle : shown
                if !filter.isEmpty, !matches(filter, [title, f.path]) { return nil }
                let node = OrgNode(id: "place:\(block.id)", block: f.block, title: title, symbol: Theme.symbolName(for: block.kind, path: block.path),
                                   detail: edited, age: Self.age(f.latest))
                node.look = StatusGlyph.look(of: block)
                node.trailing = StatusGlyph.at(of: block).map(Age.short)
                node.dimmed = !isActive
                active[ObjectIdentifier(node)] = isActive
                return node
            }
            let node = OrgNode(id: id, block: f.block, title: f.name, symbol: block.map { Theme.symbolName(for: $0.kind, path: $0.path) } ?? "doc",
                               detail: edited, age: Self.age(f.latest))
            node.dimmed = !isActive
            active[ObjectIdentifier(node)] = isActive
            return node
        }
        var roots: [OrgNode] = []
        let clients = hosts.ordered
        for c in clients {
            let home = c.transport.isLocal ? NSHomeDirectory() : nil
            var tree = c.node.graph.fileTree(host: c.host, home: home ?? c.home).compactMap(convert)
            if tree.isEmpty, let home = home ?? c.home, filter.isEmpty {
                // Nothing of the host yet: its home folder, to start from.
                let n = OrgNode(id: "file:\(c.host.raw):\(home)", title: "~", symbol: "house", isGroup: false)
                n.action = { [weak self] in self?.openDirectory(home, on: c.host) }
                tree = [n]
            }
            if clients.count > 1 {
                let id = "host:\(c.host.raw)"
                open.insert(id)
                let n = OrgNode(id: id, title: hosts.label(of: c.host), symbol: "desktopcomputer",
                                count: tree.reduce(0) { $0 + ($1.count ?? 0) }, isGroup: true, children: tree)
                hostStanding(n, c)
                roots.append(n)
            } else {
                roots += tree
                for r in tree { open.insert(r.id) }
            }
        }
        return (roots, open)
    }

    /// A host's row says how it stands (§8): a spinner while being
    /// reached, a slashed ring when it can't be, dimmed; clicked, its
    /// home folder opens there.
    private func hostStanding(_ n: OrgNode, _ c: HostClient) {
        switch c.link {
        case .connected:
            break
        case .connecting:
            n.look = .connecting
            n.detail = "connecting…"
            // The step under way and how long so far, as of the hover.
            n.liveTooltip = { [weak c] in c?.stepDescription ?? "Connecting…" }
            n.dimmed = true
        case .unreachable(let why):
            n.look = .offline
            n.detail = "unreachable"
            let when = c.nextTry.map { " · trying again in \(max(Int($0.timeIntervalSinceNow.rounded()), 0)) s" } ?? ""
            n.tooltip = (why.map { "Can't be reached: \($0)" } ?? "Can't be reached now") + when
            n.dimmed = true
        }
        // Its row opens and closes its workspaces; its home folder is in its menu.
        if false, c.isRemote || c.home != nil {
            let host = c.host
            n.action = { [weak self] in
                guard let self, let home = self.hosts.client(host)?.home ?? (host == self.host.host ? NSHomeDirectory() : nil) else { return }
                self.openDirectory(home, on: host)
            }
        }
    }

    /// A folder listed on its host, beside what's focused.
    func openDirectory(_ path: String, on host: HostID) {
        show(hosts.directoryBlock(for: path, on: host), lens: .directory, .here)
    }

    /// Links: around the focused block (or the one looked at), by edge kind.
    private func linksTree(_ filter: String) -> ([OrgNode], Set<String>) {
        guard let center = linksCenter ?? focusedShown?.placement.block, let b = hosts.block(center) else {
            return ([OrgNode(id: "none", title: "Nothing focused", symbol: "circle.dashed")], [])
        }
        var open: Set<String> = ["center"]
        // Children are made as they're reached, so the walk must end: a
        // few bunches deep, and never back to a block on the way here.
        let deepest = 4
        func bunches(of block: BlockID, prefix: String) -> [OrgNode] {
            let path = prefix.split(separator: "/")
            guard path.count / 2 < deepest else { return [] }
            let onTheWay = Set(path.compactMap { BlockID(string: String($0)) }) .union([center])
            return footBunches(of: block).compactMap { bunch -> OrgNode? in
                let cards = bunch.cards.filter { !onTheWay.contains($0.block) && matches(filter, [$0.title, $0.detail]) }
                guard !cards.isEmpty else { return nil }
                let id = "\(prefix)/\(bunch.title)"
                open.insert(id)
                let children = cards.map { card -> OrgNode in
                    let cid = "\(id)/\(card.block)"
                    let node = OrgNode(id: cid, block: card.block, title: card.title, symbol: card.symbol,
                                       detail: card.detail + (card.at.map { " · " + Age.ago($0) } ?? ""), age: Self.age(card.at))
                    node.look = StatusGlyph.look(of: hosts.block(card.block))
                    // An archived block, linked to: faded, as put away.
                    node.dimmed = hosts.block(card.block)?.isArchived == true
                    node.loadChildren = { bunches(of: card.block, prefix: cid) }
                    return node
                }
                return OrgNode(id: id, title: bunch.title, symbol: bunch.symbol, count: cards.count, isGroup: true, children: children)
            }
        }
        let root = node(for: b, id: "center", detail: linksCenter != nil ? "looked at" : "focused")
        let groups = bunches(of: center, prefix: "center")
        return ([root] + groups, open)
    }

    /// Time: blocks by the day they were last seen, today first.
    private func timeTree(_ filter: String) -> ([OrgNode], Set<String>) {
        var byDay: [Date: [(Block, Stamp)]] = [:]
        let cal = Calendar.current
        for c in hosts.all {
            for b in c.node.blocks where !b.isArchived && (b.kind != .arrangement || b.arrangement?.isNamed == true) {
                guard let seen = c.node.graph.seen(b.id) else { continue }
                guard matches(filter, [b.displayTitle, b.path]) else { continue }
                byDay[cal.startOfDay(for: seen.date), default: []].append((b, seen))
            }
        }
        let f = DateFormatter()
        f.dateStyle = .medium
        let today = cal.startOfDay(for: Date())
        var open: Set<String> = []
        let days = byDay.keys.sorted(by: >).prefix(60).map { day -> OrgNode in
            let items = byDay[day]!.sorted { $0.1 > $1.1 }
            let title: String
            if day == today { title = "Today" } else if let y = cal.date(byAdding: .day, value: -1, to: today), day == y { title = "Yesterday" } else { title = f.string(from: day) }
            let id = "day:\(day.timeIntervalSince1970)"
            if day == today || !filter.isEmpty { open.insert(id) }
            let children = items.map { block, seen in
                node(for: block, id: id + "/" + block.id.description, detail: DateFormatter.localizedString(from: seen.date, dateStyle: .none, timeStyle: .short))
            }
            return OrgNode(id: id, title: title, symbol: "calendar", count: items.count, isGroup: true, children: children)
        }
        return (Array(days), open)
    }

    // MARK: The neighborhood, in graph form

    private var neighborhoodView: NeighborhoodView?

    /// ⌥⌘N: the sidebar on Links, around the focused block.
    @objc func showLinks(_ sender: Any?) {
        linksCenter = nil
        setOrganization(.links)
    }

    /// The neighborhood map: the focused block's neighborhood to distance
    /// 2 as a picture, to look around and walk; ⌘-click or ⏎ goes to a block.
    @objc func showNeighborhood(_ sender: Any?) {
        guard neighborhoodView == nil else { return hideNeighborhood() }
        guard let center = focusedShown?.placement.block ?? selected else { return }
        let v = NeighborhoodView(frame: root.bounds)
        v.source = { [weak self] id in self?.neighborhoodModel(of: id) ?? NeighborhoodModel(center: id, nodes: [], edges: []) }
        v.onClose = { [weak self] in self?.hideNeighborhood() }
        v.onGo = { [weak self] id in
            self?.hideNeighborhood()
            self?.recall(id)
        }
        root.addSubview(v, positioned: .above, relativeTo: nil)
        neighborhoodView = v
        v.layoutSubtreeIfNeeded()
        v.center(on: center)
    }

    private func hideNeighborhood() {
        neighborhoodView?.removeFromSuperview()
        neighborhoodView = nil
        if let f = arrangement?.focused { focus(f) }
        render()
    }

    func debugNeighborhood(settle: Bool) -> String {
        if neighborhoodView == nil { showNeighborhood(nil) }
        guard let v = neighborhoodView else { return "nothing focused" }
        if settle { v.settleForScript() }
        guard let center = focusedShown?.placement.block ?? selected else { return "" }
        let m = neighborhoodModel(of: center)
        return m.nodes.map { "\($0.distance) \($0.title)" }.joined(separator: "\n") + "\n" + m.edges.map { "\($0.label): \($0.from.ulid.suffix(4)) → \($0.to.ulid.suffix(4))" }.joined(separator: "\n")
    }

    /// The neighborhood to distance 2: the nearest few dozen by when
    /// their edges were made, each outer node behind the inner one it hangs
    /// off; how many more each has is counted.
    func neighborhoodModel(of center: BlockID) -> NeighborhoodModel {
        var nodes: [GraphNode] = []
        var edges: [GraphEdge] = []
        var more: [BlockID: Int] = [:]
        var have: Set<BlockID> = [center]
        func node(_ id: BlockID, distance: Int) -> GraphNode? {
            guard let b = hosts.block(id) else { return nil }
            let detail: String = switch b.kind {
            case .arrangement: "Workspace"
            case .terminal: b.terminal?.cwd?.abbreviatingHome ?? "Terminal"
            default: b.path?.deletingLastPathComponent.abbreviatingHome ?? b.kind.defaultTitle
            }
            return GraphNode(id: id, title: b.displayTitle, symbol: Theme.symbolName(for: b.kind, path: b.path), detail: detail,
                             distance: distance, isArrangement: b.kind == .arrangement)
        }
        func addEdge(_ e: GraphEdge) {
            if !edges.contains(where: { $0.from == e.from && $0.to == e.to && $0.kind == e.kind }) { edges.append(e) }
        }
        /// A block's edges, as (other, edge), newest first; the trail's as
        /// kind-less edges.
        func around(_ id: BlockID) -> [(BlockID, GraphEdge)] {
            let n = hosts.neighborhood(of: id)
            var out: [(Stamp, BlockID, GraphEdge)] = []
            for (k, es) in n.outbound { for e in es { out.append((e.at, e.to, GraphEdge(from: e.from, to: e.to, kind: k, context: e.context, at: e.at))) } }
            for (k, es) in n.inbound { for e in es { out.append((e.at, e.from, GraphEdge(from: e.from, to: e.to, kind: k, context: e.context, at: e.at))) } }
            for t in n.before where t.block != id { out.append((t.last, t.block, GraphEdge(from: t.block, to: id, kind: nil, context: t.count == 1 ? "once" : "\(t.count) times", at: t.last))) }
            for t in n.after where t.block != id { out.append((t.last, t.block, GraphEdge(from: id, to: t.block, kind: nil, context: t.count == 1 ? "once" : "\(t.count) times", at: t.last))) }
            return out.sorted { $0.0 > $1.0 }.map { ($0.1, $0.2) }
        }
        guard let c = node(center, distance: 0) else { return NeighborhoodModel(center: center, nodes: [], edges: []) }
        nodes.append(c)
        let inner = around(center)
        var ring1: [BlockID] = []
        for (other, e) in inner {
            if !have.contains(other), ring1.count < 20, let n = node(other, distance: 1) {
                have.insert(other)
                ring1.append(other)
                nodes.append(n)
            }
            if have.contains(other) { addEdge(e) } else { more[center, default: 0] += 1 }
        }
        var total2 = 0
        for id in ring1 {
            var count = 0
            for (other, e) in around(id) {
                if other == center { continue }
                if have.contains(other) {
                    addEdge(e)
                } else if count < 6, total2 < 40, let n = node(other, distance: 2) {
                    have.insert(other)
                    nodes.append(n)
                    addEdge(e)
                    count += 1
                    total2 += 1
                } else {
                    more[id, default: 0] += 1
                }
            }
        }
        return NeighborhoodModel(center: center, nodes: nodes, edges: edges, more: more)
    }

    // MARK: Back and forward, by focus

    /// A place focus was, in this client's history: a tile in a workspace.
    private struct FocusPlace: Equatable {
        var workspace: BlockID
        var placement: PlacementID
        var block: BlockID
    }

    /// Where focus has been, this client's alone (§8.2), oldest first:
    /// every move to a tile or a workspace, across workspaces, that
    /// wasn't going back or forward.
    private var focusHistory: [FocusPlace] = []
    /// While going back and forward: the place gone to, by its index.
    private var historyCursor: Int?
    private var navigatingHistory = false
    private var lastFocusPlace: FocusPlace?
    private var settleWork: DispatchWorkItem?
    private var settleMonitor: Any?
    static let historyLimit = 500

    /// The place focus is now, if a tile is focused.
    private var currentFocusPlace: FocusPlace? {
        guard let w = selected, let a = hosts.arrangement(w), let f = a.focused, let p = a.placement(f) else { return nil }
        return FocusPlace(workspace: w, placement: f, block: p.block)
    }

    /// A move of focus is noted: a new place in the history, unless it's
    /// going back or forward that moved it.
    private func noteTrailFocus() {
        let place = currentFocusPlace
        if place != lastFocusPlace {
            lastFocusPlace = place
            if !navigatingHistory, let place {
                // Moved elsewhere while going back: where it had gone is
                // settled on first, so back comes to it again.
                if historyCursor != nil { settle() }
                record(place)
            }
            // Focusing takes the pen (§8.2): for the block, and the
            // workspace it sits in.
            if let b = focusedShown?.placement.block { hosts.own(b) }
            if let w = selected { hosts.own(w) }
        }
    }

    private func record(_ place: FocusPlace) {
        if focusHistory.last != place { focusHistory.append(place) }
        if focusHistory.count > Self.historyLimit { focusHistory.removeFirst(focusHistory.count - Self.historyLimit) }
    }

    /// ⌘[ (or the mouse's back button): where focus was before, across
    /// workspaces, the pointer following.
    @objc func goBack(_ sender: Any?) { walkHistory(-1) }
    /// ⌘] (or the mouse's forward button): forward again, as far as where
    /// going back began.
    @objc func goForward(_ sender: Any?) { walkHistory(1) }

    private func walkHistory(_ direction: Int) {
        guard !focusHistory.isEmpty else { return NSSound.beep() }
        var i = (historyCursor ?? focusHistory.count - 1) + direction
        let here = currentFocusPlace
        while focusHistory.indices.contains(i) {
            let place = focusHistory[i]
            if place != here, go(to: place) {
                historyCursor = i
                awaitSettling()
                return
            }
            i += direction
        }
        NSSound.beep()
    }

    /// Goes to a place: its workspace, the tile out of its stack (or from
    /// behind a maximized one) and focused; the tile gone, its block
    /// wherever it is; nothing left of either, false.
    private func go(to place: FocusPlace) -> Bool {
        navigatingHistory = true
        defer { navigatingHistory = false }
        if let a = hosts.arrangement(place.workspace), allWorkspaces.contains(place.workspace), a.placement(place.placement) != nil {
            if selected != place.workspace { hosts.select(place.workspace) }
            if a.focused != place.placement || a.isStashed(place.placement) || (a.full != nil && a.full != place.placement) {
                hosts.append(a.revealing(place.placement), to: .block(place.workspace))
            }
        } else if hosts.block(place.block) != nil {
            goTo(place.block)
        } else {
            return false
        }
        render()
        lastFocusPlace = currentFocusPlace
        warpPointerToFocus()
        return true
    }

    /// After going back or forward, staying put (a couple of seconds), a
    /// key typed or a click settles on where it went: it's a new place in
    /// the history, and back from there goes where it was before.
    private func awaitSettling() {
        settleWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.settle() }
        settleWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 2, execute: work)
        guard settleMonitor == nil else { return }
        settleMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .leftMouseDown, .rightMouseDown]) { [weak self] event in
            guard let self, (event.window ?? NSApp.keyWindow) === self.window else { return event }
            // Not the keys that go back and forward themselves.
            if event.type == .keyDown, event.modifierFlags.contains(.command), ["[", "]"].contains(event.charactersIgnoringModifiers ?? "") { return event }
            self.settle()
            return event
        }
    }

    private func settle() {
        settleWork?.cancel()
        settleWork = nil
        if let settleMonitor { NSEvent.removeMonitor(settleMonitor) }
        settleMonitor = nil
        guard historyCursor != nil else { return }
        historyCursor = nil
        if let place = currentFocusPlace { record(place) }
    }

    /// The mouse's back and forward buttons (3 and 4), wherever it is in
    /// the window: back and forward by focus.
    private var historyButtonsMonitor: Any?
    private func watchHistoryButtons() {
        historyButtonsMonitor = NSEvent.addLocalMonitorForEvents(matching: .otherMouseDown) { [weak self] event in
            guard let self, (event.window ?? NSApp.keyWindow) === self.window else { return event }
            switch event.buttonNumber {
            case 3: self.goBack(nil); return nil
            case 4: self.goForward(nil); return nil
            default: return event
            }
        }
    }

    /// Debugging: the backdrop's light — at "HH:MM" today, or "now" again.
    func debugSun(_ arg: String) -> String {
        let hm = arg.split(separator: ":").compactMap { Int($0) }
        if arg == "now" { backdrop.clock = nil }
        else if hm.count == 2 { backdrop.clock = Calendar.current.date(bySettingHour: hm[0], minute: hm[1], second: 0, of: Date()) }
        let c = backdrop.cast, p = Daylight.place()
        return String(format: "at %.2f,%.2f elevation %.1f° %.0f K cast r%.3f g%.3f b%.3f", p.latitude, p.longitude, c.elevation, c.kelvin, c.red, c.green, c.blue)
    }

    /// Debugging: the history, the place gone to marked.
    func debugHistory() -> String {
        focusHistory.enumerated().map { i, p in
            "\(i == historyCursor ? ">" : " ")\(i) \(hosts.block(p.block)?.displayTitle ?? "?") in \(hosts.arrangement(p.workspace).map(title(of:)) ?? "?")"
        }.joined(separator: "\n")
    }

    // MARK: Finding and opening

    func debugFinder(_ query: String) -> [String] { finder.debugQuery(query) }
    func debugFinderChoose() { finder.debugChoose() }
    func debugFinderScope(_ n: Int) { finder.debugScope(n) }
    func debugFinderMove(_ by: Int) { finder.debugMove(by) }

    private lazy var finder: Finder = {
        let f = Finder()
        f.search = { [weak self] query, files, scope in
            guard let self else { return [] }
            switch scope {
            case .names: return self.finderItems(query, files: files)
            case .contents: return self.finderContentItems(query)
            case .blocks: return self.finderBlockItems(query)
            }
        }
        f.onQueryChanged = { [weak self] query, scope in self?.finderQueryChanged(query, scope) }
        return f
    }()

    /// The search block ⌘O's "In Files" scope asks the host through: one,
    /// kept, asked again as the query changes.
    private var finderSearch: BlockID?
    private var finderSearchWork: DispatchWorkItem?

    /// The project the focused block is in: its repository's root (git
    /// or Sapling), else its own folder.
    private func projectRoot(from cwd: String?, on: HostID) -> String {
        let root = cwd ?? NSHomeDirectory()
        guard on == host.host else { return root }
        return VCS.repository(of: root)?.root ?? root
    }

    /// "In Files": the host looks, a moment after the typing pauses.
    private func finderQueryChanged(_ query: String, _ scope: Finder.Scope) {
        finderSearchWork?.cancel()
        guard scope == .contents, query.count >= 2 else { return }
        let work = DispatchWorkItem { [weak self] in
            guard let self, let client = self.hosts.client(self.focusedHost) else { return }
            let q = SearchQuery(text: query, root: self.projectRoot(from: self.focusedCwd, on: self.focusedHost))
            if let id = self.finderSearch, self.hosts.block(id) != nil, id.host == client.host {
                client.propose(.search(block: id, query: q))
            } else {
                self.finderSearch = client.newSearch(q)
            }
        }
        finderSearchWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2, execute: work)
    }

    /// "In Files": what the host has found so far, each line going to its
    /// place in the file.
    private func finderContentItems(_ query: String) -> [FinderItem] {
        guard query.count >= 2, let id = finderSearch, let s = hosts.block(id)?.search, s.query?.text == query else { return [] }
        let on = id.host
        var items: [FinderItem] = s.hits.prefix(200).map { hit in
            FinderItem(symbol: Finder.symbol(forFile: hit.path.lastPathComponent), title: hit.text.trimmingCharacters(in: .whitespaces),
                       detail: "\(hit.path.abbreviatingHome):\(hit.line)", note: "",
                       run: { [weak self] in
                           guard let self else { return }
                           self.open(path: hit.path, line: hit.line, column: hit.column, on: on, from: self.focusedShown?.placement.id, kind: .found, context: query)
                       })
        }
        if s.running || s.truncated || s.error != nil || !s.hits.isEmpty {
            items.append(FinderItem(symbol: "magnifyingglass", title: s.running ? "Looking…" : s.error ?? "\(s.hits.count)\(s.truncated ? "+" : "") lines", detail: "As a search block", note: "",
                                    run: { [weak self] in self?.show(id, lens: .search, .here) }))
        }
        return items
    }

    /// "In Blocks": lines holding the query in the texts of the selected
    /// workspace's blocks, each going to the block and the line.
    private func finderBlockItems(_ query: String) -> [FinderItem] {
        guard !query.isEmpty, let a = arrangement else { return [] }
        let q = query.lowercased()
        var items: [FinderItem] = []
        var seen = Set<BlockID>()
        for p in a.placements where seen.insert(p.block).inserted {
            guard let b = hosts.block(p.block), let text = b.text?.text.string else { continue }
            var line = 0
            for raw in text.split(separator: "\n", omittingEmptySubsequences: false) {
                line += 1
                guard raw.lowercased().contains(q) else { continue }
                let at = line, id = p.id, block = b.id
                items.append(FinderItem(symbol: Theme.symbolName(for: b.kind, path: b.path), title: raw.trimmingCharacters(in: .whitespaces),
                                        detail: "\(b.displayTitle):\(at)", note: "",
                                        run: { [weak self] in
                                            guard let self else { return }
                                            if self.arrangement?.placement(id) != nil, self.hosts.block(block)?.kind == .text {
                                                if let e = self.views[id] as? EditorView {
                                                    self.focus(id)
                                                    e.select(line: at)
                                                    self.warpPointerToFocus()
                                                    return
                                                }
                                            }
                                            self.pendingJump = (b.path ?? "", at, nil)
                                            self.show(block, lens: Lens.default(for: .text, path: b.path), .here)
                                            self.warpPointerToFocus()
                                        }))
                if items.count >= 300 { return items }
            }
        }
        return items
    }

    /// ⌘O: the finder, over everything, and the files where the focused
    /// placement is.
    @objc func openDocument(_ sender: Any?) {
        let root = focusedCwd ?? NSHomeDirectory()
        // The hosts' process trees, listed afresh, so they can be found too.
        for c in hosts.all where c.isConnected { _ = c.processBlock() }
        finder.show(root: root, over: window)
    }

    private func finderItems(_ query: String, files: [String]) -> [FinderItem] {
        // Each thing found is placed in a tier — here (on this workspace),
        // near (linked to the focused block, or on the desk), elsewhere,
        // archived; files and processes below blocks — and within its tier
        // ranked by how well the query names it, then by recency (§3.5).
        var scored: [(score: Int, recency: Int64, item: FinderItem)] = []
        let known = Set(hosts.blocks.filter { $0.id.host == host.host }.compactMap(\.path))
        let near = focusedShown.map { hosts.distances(from: $0.placement.block, limit: 3) } ?? [:]
        let focusedBlock = focusedShown?.placement.block
        let here = Set(arrangement?.placements.map(\.block) ?? [])
        let onDesk = Set(allWorkspaces.compactMap { hosts.arrangement($0) }.flatMap { $0.placements.map(\.block) })
        var joinedAt: [BlockID: Int64] = [:]
        if let f = focusedBlock {
            let n = hosts.neighborhood(of: f)
            for es in n.outbound.values { for e in es { joinedAt[e.to] = max(joinedAt[e.to] ?? 0, e.at.wall) } }
            for es in n.inbound.values { for e in es { joinedAt[e.from] = max(joinedAt[e.from] ?? 0, e.at.wall) } }
            for t in n.before + n.after { joinedAt[t.block] = max(joinedAt[t.block] ?? 0, t.last.wall) }
        }
        let running = runningPrograms()
        for block in hosts.blocks {
            guard let entry = hosts.registryEntry(block.id) else { continue }
            let remote = block.id.host != host.host ? " on \(hosts.label(of: block.id.host))" : ""
            let title = block.displayTitle
            let programs = running[block.id] ?? []
            let secondary: String
            let detail: String
            var note = ""
            switch block.kind {
            case .arrangement:
                // A workspace by its own name; what it holds is found as itself.
                guard let a = block.arrangement, a.isNamed || !a.isEmpty else { continue }
                secondary = ""
                detail = a.isNamed ? "Workspace · \(a.placements.count) blocks" : "Workspace, unnamed · \(a.placements.count) blocks"
                note = allWorkspaces.contains(block.id) ? "on the desk" : ""
            case .text:
                secondary = block.path ?? ""
                detail = block.path.map { ($0 as NSString).deletingLastPathComponent.abbreviatingHome } ?? "Note"
                note = block.text?.isDirty == true ? "edited" : ""
            case .terminal:
                secondary = (block.terminal?.cwd ?? "") + " " + programs.joined(separator: " ")
                detail = "Terminal in \(block.terminal?.cwd?.abbreviatingHome ?? "~")" + (programs.isEmpty ? "" : " · " + programs.prefix(3).joined(separator: ", "))
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
                secondary = "processes"
                detail = "Processes"
            case .agent:
                secondary = "agent " + (block.terminal?.cwd ?? "") + " " + programs.joined(separator: " ")
                detail = "Agent in \(block.terminal?.cwd?.abbreviatingHome ?? "~")" + (programs.isEmpty ? "" : " · " + programs.prefix(3).joined(separator: ", "))
                note = block.terminal?.pid == nil ? "ended" : ""
            case .git:
                secondary = "git " + (block.path ?? "")
                detail = "Git, \(block.path?.abbreviatingHome ?? "")"
            case .diff:
                secondary = "diff " + (block.path ?? "")
                detail = "Diff, \(block.path?.deletingLastPathComponent.abbreviatingHome ?? "")"
            case .outline:
                continue
            case .web:
                secondary = block.web?.url ?? ""
                detail = block.web?.url ?? "Web page"
            }
            // The kind's name is as good as a word of the title: "terminal"
            // finds the terminals, "note" the notes.
            let kindWord = block.kind == .text ? (block.path == nil ? "Note" : "File") : block.kind.defaultTitle
            let match = FileFinder.nameMatch(query, title: title + " " + kindWord, secondary: secondary + " " + block.id.host.raw)
            guard match > 0 else { continue }
            if let r = block.statusRecord, r.wantsAttention {
                note = r.state == .blocked ? "needs you" : r.state == .done ? "done, not read yet" : "failed"
            }
            let tier: Int
            if block.isArchived {
                tier = 1
                note = "archived"
            } else if block.kind == .arrangement {
                tier = allWorkspaces.contains(block.id) ? 4 : 2
            } else if here.contains(block.id) {
                tier = 5
                if note.isEmpty { note = block.id == focusedBlock ? "here, focused" : "here" }
            } else if let d = near[block.id], d > 0 {
                tier = 4
                if note.isEmpty { note = d == 1 ? "linked" : "near" }
            } else if onDesk.contains(block.id) {
                tier = 4
            } else {
                // On no workspace: chosen, it is brought back rather than
                // gone to.
                tier = 3
                if note.isEmpty, block.kind != .arrangement { note = "recent" }
            }
            // How long since it was last seen, after the note.
            let seen = Age.short(entry.lastSeen)
            note = note.isEmpty ? seen : note + " · " + seen
            // A weak match — the query's letters in order in the title, or
            // only in what's around the block — gets no tier above
            // elsewhere: being here doesn't make it what you meant.
            let placed = match < 400 ? min(tier, 2) : tier
            // The focused block is where you are: last among those here.
            let score = placed * 1000 + match - (block.id == focusedBlock ? 300 : 0)
            let id = block.id
            let kind = block.kind
            let path = block.path
            scored.append((score, max(entry.lastSeen.wall, joinedAt[block.id] ?? 0), FinderItem(
                symbol: Theme.symbolName(for: kind, path: path), title: title, detail: detail + remote, note: note,
                run: { [weak self] in self?.recall(id) })))
        }
        // The processes under a terminal's or agent's shell (§7.5): found by
        // command or path, each going to its block.
        if !query.isEmpty {
            for block in hosts.blocks where block.kind == .process {
                let remote = block.id.host != host.host ? " on \(hosts.label(of: block.id.host))" : ""
                for e in block.processes?.entries ?? [] {
                    guard let under = e.block, hosts.block(under)?.isArchived != true else { continue }
                    let m = FileFinder.nameMatch(query, title: e.command, secondary: e.path ?? "")
                    guard m > 0 else { continue }
                    let command = e.command.count > 100 ? String(e.command.prefix(100)) + "…" : e.command
                    scored.append((2000 + m, block.processes?.listedAt?.wall ?? 0, FinderItem(
                        symbol: "cpu", title: command, detail: (e.path?.abbreviatingHome ?? "pid \(e.pid)") + remote,
                        note: hosts.block(under)?.displayTitle ?? "", run: { [weak self] in self?.goTo(under) })))
                }
            }
        }
        // Files not yet blocks: below the blocks; the system's temporary
        // folders lowest of all, being mostly scratch.
        for file in files where !known.contains(file) {
            let name = (file as NSString).lastPathComponent
            let m = FileFinder.nameMatch(query, title: name, secondary: file)
            guard m > 0 else { continue }
            let scratch = file.hasPrefix("/tmp/") || file.hasPrefix("/private/tmp/") || file.hasPrefix("/private/var/folders/")
            scored.append(((scratch ? 1000 : 2000) + m, 0, FinderItem(symbol: Finder.symbol(forFile: name), title: name,
                                                         detail: (file as NSString).deletingLastPathComponent.abbreviatingHome, note: "file",
                                                         run: { [weak self] in self?.open(file, from: nil) })))
        }
        scored.sort { a, b in
            if a.score != b.score { return a.score > b.score }
            return a.recency > b.recency
        }
        var items = Array(scored.prefix(60).map(\.item))
        if query.hasPrefix("http://") || query.hasPrefix("https://") || (query.contains(".") && !query.contains(" ") && !query.contains("/") && query.split(separator: ".").last.map({ $0.count >= 2 && $0.allSatisfy(\.isLetter) }) == true) {
            let url = query.contains("://") ? query : "https://" + query
            items.insert(FinderItem(symbol: "globe", title: url, detail: "Open as a web page", note: "web",
                                    run: { [weak self] in self?.open(url, from: self?.focusedShown?.id) }), at: 0)
        }
        return items
    }

    /// Recall, from the finder: an arrangement onto the desk and selected;
    /// any other block gone to.
    func recall(_ id: BlockID) { goTo(id) }

    /// After a go-to (⌘O, ⌘\, a found line): the pointer moves to what was
    /// gone to — the text cursor if the tile has one, else the tile's
    /// middle — a moment later, once it is laid out.
    func warpPointerToFocus() {
        // Once laid out; and again once the layout's animation (a tile
        // coming out of a stack, a column resettling) has ended.
        for delay in [0.08, 0.32] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                guard let self, let a = self.arrangement, let f = a.focused, let view = self.views[f] else { return }
                self.warpPointer(to: view)
            }
        }
    }

    /// The pointer to a view's text cursor, or its middle, now.
    func warpPointer(to view: PaneContent) {
        guard !Pointer.held, let window, let rect = pointerTarget(in: view) else { return }
        let screen = window.convertToScreen(rect)
        // Core Graphics counts from the main display's top left.
        guard let main = NSScreen.screens.first else { return }
        let point = CGPoint(x: screen.midX + 2, y: main.frame.maxY - screen.midY)
        CGWarpMouseCursorPosition(point)
        CGAssociateMouseAndMouseCursorPosition(1)
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
    func goTo(_ id: BlockID) {
        guard let block = hosts.block(id) else { return }
        hideStateView()
        warpPointerToFocus()
        if block.kind == .arrangement { return hosts.select(id) }
        if let a = arrangement, let t = a.placements(of: id).first, let here = selected {
            // Here already: out of its stack, from behind a maximized
            // tile, and focused.
            return hosts.append(revealing(t.id, in: a), to: .block(here))
        }
        let order = hosts.state.settled + allWorkspaces.filter { !hosts.state.settled.contains($0) }
        for arr in order where arr != selected {
            if let a = hosts.arrangement(arr), let t = a.placements(of: id).first {
                hosts.select(arr)
                hosts.append(revealing(t.id, in: a), to: .block(arr))
                return
            }
        }
        show(id, lens: Lens.default(for: block.kind, path: block.path), .here)
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
    }

    /// `besideOpener` when there is an opener, else `here`.
    /// Where what a click opens goes: beside the tile clicked in — or,
    /// with ⌥ held (`over`, else read off the click), over it.
    private func opener(_ placement: PlacementID?, over: Bool? = nil) -> Where {
        guard let placement else { return .here }
        return (over ?? Self.clickModifiers?.contains(.option) ?? false) ? .over(placement) : .besideOpener(placement)
    }

    /// Go to a block from a click: where it is — or, with ⌥ held, over
    /// the tile clicked in.
    func arrive(_ block: BlockID, from placement: PlacementID?, over: Bool? = nil) {
        if over ?? Self.clickModifiers?.contains(.option) ?? false, let placement, let b = hosts.block(block), b.kind != .arrangement {
            show(block, lens: Lens.default(for: b.kind, path: b.path), .over(placement))
        } else {
            goTo(block)
        }
    }

    /// A tile over another (⌥-drag, ⌥-click): moved to just after it, the
    /// other stashed behind it, and focused; out of its own stack first.
    func cover(_ tile: PlacementID, over target: PlacementID, alone: Bool = false) {
        guard let a = arrangement, tile != target, let (c, _) = a.locate(target) else { return }
        var events: [Event] = a.isStashed(tile) ? a.unstashing(tile) : alone ? a.leavingAlone(tile) : []
        var column = a.columns[c]
        column.removeAll { $0.id == tile }
        guard let i = column.firstIndex(where: { $0.id == target }) else { return }
        events += [.move(tile, column: c, at: i + 1), .stash(target, behind: tile), .focus(tile)]
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
        let id = arrangement ?? arrangementForPlacing()
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
                return show(block, lens: lens, .here, kind: kind, context: context)
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
        hosts.append(events, to: .block(id))
        // The pointer follows to what's shown (§3.1), as after a go-to.
        if id == selected { warpPointerToFocus() }
    }

    /// A block **over** a tile (§3.1): placed where the tile is, with the
    /// tile stashed behind it, so it takes the tile's room until it is
    /// taken off (⌘W), when the tile comes back — `$EDITOR` over the
    /// terminal that ran it, a preview over its editor. A tile of the
    /// block already there is focused instead, unless `again`: then the
    /// block gets a second tile, over the opener (an `$EDITOR` that must
    /// end when its own tile is taken off).
    @discardableResult
    func showOver(_ block: BlockID, lens: Lens, over opener: PlacementID, again: Bool = false, kind: LinkKind = .opened, context: String? = nil) -> PlacementID? {
        hideStateView()
        guard let a = arrangement, let (c, i) = a.locate(opener), let from = a.placement(opener)?.block else {
            show(block, lens: lens, .here, kind: kind, context: context)
            return arrangement?.tile(of: block, lens: lens)?.id
        }
        if !again, let t = a.tile(of: block, lens: lens) {
            focus(t.id)
            warpPointerToFocus()
            return t.id
        }
        let p = Placement(block: block, lens: lens)
        var events: [Event] = [.place(p, column: c, at: i + 1), .stash(opener, behind: p.id), .focus(p.id)]
        // Over a maximized tile, it's the maximized one now.
        if a.full == opener { events.append(.full(p.id)) }
        appendToSelected(events)
        if from != block { hosts.link(from: from, to: block, kind: kind, context: context) }
        warpPointerToFocus()
        return p.id
    }

    /// A tile's block replaced in place — a listing gone into a folder, a
    /// preview gone to another page: the same tile, as a browser's window
    /// is; Go Back comes back along the trail.
    private func replace(_ placement: PlacementID, with block: BlockID, lens: Lens, as id: PlacementID? = nil) {
        guard let a = arrangement, let (c, i) = a.locate(placement) else { return }
        let p = id.map { Placement(id: $0, block: block, lens: lens) } ?? Placement(block: block, lens: lens)
        // The column's heights as they were, the new tile in the old one's
        // place: the remove and the place in between hand room about
        // (to the next tile, from the one above), and the tile would
        // otherwise come back a different size, its neighbours moved.
        var heights: [PlacementID: Double] = [:]
        for t in a.columns[c] { heights[t.id == placement ? p.id : t.id] = a.height(of: t.id) }
        appendToSelected([.remove(placement), .place(p, column: c, at: i), .heights(heights), .focus(p.id)])
    }

    /// Opens a file to edit: from a terminal, beside it; else here.
    func edit(_ path: String) {
        let on = focusedHost
        guard on != host.host || Self.isEditable(path) else {
            NSWorkspace.shared.open(URL(fileURLWithPath: path))
            return
        }
        let block = hosts.textBlock(for: path, on: on)
        show(block, lens: .editor, focusedShown?.lens == .terminal ? opener(focusedShown?.id) : .here)
    }

    /// Find in Files…: a search block on the focused block's host, under
    /// its project (the nearest folder up with `.git`, else where it is),
    /// starting from the editor's selection; placed beside what's focused.
    @objc func findInFiles(_ sender: Any?) {
        let on = focusedHost
        let root = projectRoot(from: focusedCwd, on: on)
        var text = ""
        if let tv = window?.firstResponder as? TextView {
            let selected = tv.selectedText
            if !selected.isEmpty, !selected.contains("\n") { text = selected }
        }
        guard let client = hosts.client(on) else { return }
        let block = client.newSearch(SearchQuery(text: text, root: root))
        show(block, lens: .search, .here)
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
        return agents.map { a in ClosureMenuItem(a.name, symbol: "sparkles") { [weak self] in self?.launchAgent(a.command) } }
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
        let block = client.gitBlock(for: path) { [weak self] error in
            // The host couldn't make it (no repository there): its tile,
            // waiting for a block that won't come, goes, and says why.
            guard let self, let error, let block = shown else { return }
            if let a = self.arrangement, let t = a.tile(of: block, lens: .git) { self.appendToSelected([.remove(t.id)]) }
            guard let window = self.window else { return }
            let alert = NSAlert()
            alert.messageText = "No source control here"
            alert.informativeText = error
            alert.beginSheetModal(for: window)
        }
        shown = block
        show(block, lens: .git, .here)
    }

    /// Compare with Last Commit: the focused file against HEAD, beside it.
    @objc func compareWithHead(_ sender: Any?) {
        guard let f = focusedShown, let path = f.path, f.lens == .editor || f.lens == .preview,
              let client = hosts.client(f.placement.block.host) else { return }
        let block = client.diffBlock(.sides(old: DiffSide(path: path, revision: "HEAD"), new: DiffSide(path: path)))
        hosts.link(from: block, to: f.placement.block, kind: .source, context: "HEAD → working tree")
        show(block, lens: .diff, .besideOpener(f.id), context: "Compare with Last Commit")
    }

    /// Opens a file at a place (line and column from 1) beside the
    /// placement that opened it, on the host the placement's block is on.
    func open(path: String, line: Int, column: Int?, on: HostID, from: PlacementID?, kind: LinkKind = .opened, context: String? = nil) {
        pendingJump = (path, line, column)
        let block = hosts.textBlock(for: path, on: on)
        show(block, lens: Lens.default(for: .text, path: path), opener(from), kind: kind, context: context ?? "\(path.lastPathComponent):\(line)")
        warpPointerToFocus()
    }

    func openDirectory(_ path: String, from: PlacementID?, context: String? = nil) {
        let on = from.flatMap { shown($0)?.placement.block.host } ?? focusedHost
        let block = hosts.directoryBlock(for: path, on: on)
        show(block, lens: .directory, opener(from), context: context)
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
    /// ⌘\: the workspace as a hierarchy, as Prism's Move to Heading is —
    /// its tiles by column, and the headings of the text in them, set in
    /// under their tile; those whose words have every word of the query.
    /// ↩ goes to a tile, or to a heading in its editor or preview.
    @objc func goToTile(_ sender: Any?) {
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
        let show = { [weak self] (line: Int?) in
            guard let self else { return }
            let (_, start) = self.workspaceOutline(a, currentLine: line)
            self.finder.showOutline({ [weak self] query in
                guard let self else { return [] }
                let (outline, _) = self.workspaceOutline(a, currentLine: line)
                let words = query.lowercased().split(whereSeparator: \.isWhitespace).map(String.init)
                return outline.filter { item in
                    words.isEmpty || words.allSatisfy { (item.title + " " + item.detail).lowercased().contains($0) }
                }
            }, startingAt: start, over: self.window)
        }
        if let f = a.focused, let m = views[f] as? MarkdownView {
            m.headingAtTop { index in show(index.map { -($0 + 1) }) }
        } else if let f = a.focused, let e = views[f] as? EditorView {
            show(e.caretLine)
        } else {
            show(nil)
        }
    }

    /// The outline, and the row to begin at: the focused tile's, or under
    /// it the heading at `currentLine` (a line from 1 in its editor; or,
    /// negative, minus one more than the index of the heading at the top
    /// of its preview).
    /// What runs in each terminal (the process trees under the shells,
    /// §7.5), so a terminal is found by its program — "claude" — too.
    private func runningPrograms() -> [BlockID: [String]] {
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

    private func workspaceOutline(_ a: ArrangementState, currentLine: Int?) -> ([FinderItem], Int?) {
        var items: [FinderItem] = []
        var start: Int?
        let running = runningPrograms()
        for (c, column) in a.columns.enumerated() {
            for p in column {
                guard let b = hosts.block(p.block) else { continue }
                let focused = p.id == a.focused
                if focused { start = items.count }
                var notes: [String] = []
                if a.columns.count > 1 { notes.append("column \(c + 1)") }
                if a.isStashed(p.id) { notes.append("stashed") }
                if p.id == a.focused { notes.append("focused") }
                let id = p.id
                // Where it is; and for a terminal, what runs in it and what
                // that reports — searched by too.
                var detail = [b.place?.abbreviatingHome ?? ""]
                detail += running[b.id] ?? []
                if let r = b.statusRecord {
                    if let app = r.app { detail.append(app) }
                    if let msg = r.msg, !msg.isEmpty { detail.append(msg) }
                }
                items.append(FinderItem(symbol: Theme.symbolName(for: b.kind, path: b.path), title: b.displayTitle,
                                        detail: detail.filter { !$0.isEmpty }.joined(separator: " · "), note: notes.joined(separator: " · "),
                                        run: { [weak self] in self?.focus(id); self?.warpPointerToFocus() }))
                // A text's headings, as Markdown has them, each gone to in
                // its editor by line, in its preview by index.
                guard b.kind == .text, let text = b.text?.text.string, Lens.viewRendering(for: b.path) == .markdown else { continue }
                var index = 0
                var line = 0
                var inFence = false
                for raw in text.split(separator: "\n", omittingEmptySubsequences: false) {
                    line += 1
                    if raw.hasPrefix("```") { inFence.toggle() }
                    guard !inFence, raw.hasPrefix("#") else { continue }
                    let level = raw.prefix { $0 == "#" }.count
                    guard level <= 6, raw.dropFirst(level).first == " " else { continue }
                    let heading = raw.dropFirst(level).trimmingCharacters(in: .whitespaces)
                    let at = line, nth = index
                    if focused, let current = currentLine, current >= 0 ? at <= current : nth <= -current - 1 { start = items.count }
                    items.append(FinderItem(symbol: "number", title: heading, detail: b.displayTitle, note: "", level: level,
                                            run: { [weak self] in
                        guard let self else { return }
                        self.focus(id)
                        if let e = self.views[id] as? EditorView { e.select(line: at) }
                        else if let m = self.views[id] as? MarkdownView { m.scroll(toHeading: nth) }
                        self.warpPointerToFocus()
                    }))
                    index += 1
                }
            }
        }
        return (items, start)
    }

    /// ⌘↩: the focused text between being edited and viewed — Markdown
    /// rendered (a note's too), anything else as it is on the grey of a
    /// page of code — in the same tile.
    @objc func toggleEditPreview(_ sender: Any?) {
        guard let f = focusedShown else { return }
        toggleMode(f.id)
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
            if a.full == id { self.appendToSelected([.full(fresh)]) }
        }
        if let e = views[id] as? EditorView { carry(e.topLine) }
        else if let m = views[id] as? MarkdownView { m.topLine(carry) }
        else { carry(nil) }
    }

    /// ⌥⇧⌘P: the other mode beside this one, both in view.
    @objc func editPreviewBeside(_ sender: Any?) {
        guard let f = focusedShown, f.lens.isText, f.block?.kind == .text else { return }
        let other: Lens = f.lens == .preview ? .editor : .preview
        show(f.placement.block, lens: other, .besideOpener(f.id), kind: .source, context: other == .editor ? "edited beside" : "viewed beside", exact: true)
    }

    /// Opens what a link in a placement points at: Markdown files in a
    /// preview beside it, folders in a listing, text to edit, anything else
    /// with the system.
    /// Whether a link just clicked is for Manifold's own web lens: ⌘-click
    /// goes to the system's handler, ⇧⌘-click (or a plain click, or an
    /// opening that isn't a click) stays here.
    static func opensHere(_ flags: NSEvent.ModifierFlags) -> Bool {
        !(flags.contains(.command) && !flags.contains(.shift))
    }

    private static var clickModifiers: NSEvent.ModifierFlags? {
        guard let e = NSApp.currentEvent, [.leftMouseUp, .leftMouseDown, .otherMouseUp, .rightMouseUp].contains(e.type) else { return nil }
        return e.modifierFlags
    }

    /// `over`: ⌥ was held (else read off the click): what opens goes over
    /// the tile, not beside it.
    func open(_ target: String, from placement: PlacementID?, here: Bool? = nil, over: Bool? = nil) {
        let place = opener(placement, over: over)
        // A link to a block (manifold:host/ulid, as a note's pill is): go to it.
        if target.hasPrefix("manifold:"), let b = BlockID(string: String(target.dropFirst(9)).trimmingCharacters(in: CharacterSet(charactersIn: "/"))) {
            arrive(b, from: placement, over: over)
            return
        }
        if let url = URL(string: target), let scheme = url.scheme, scheme.count > 1, scheme != "file" {
            if scheme == "http" || scheme == "https", here ?? Self.clickModifiers.map(Self.opensHere) ?? true {
                show(host.newWeb(url: url.absoluteString), lens: .web, place, context: target)
            } else {
                NSWorkspace.shared.open(url)
            }
            return
        }
        let base = placement.flatMap { shown($0)?.block }.flatMap { $0.terminal?.cwd ?? $0.place }
        let on = placement.flatMap { shown($0)?.placement.block.host } ?? host.host
        if on != host.host {
            // Another host's file: it says what it is.
            openRemote(target, on: on, base: base, from: placement, place: place)
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
            show(hosts.textBlock(for: base, on: on), lens: Lens.default(for: .text, path: base), place, context: target)
            return
        }
        path = URL(fileURLWithPath: path).standardizedFileURL.path
        if isDir.boolValue {
            show(hosts.directoryBlock(for: path, on: on), lens: .directory, place, context: target)
        } else if Lens.isMarkdown(path) {
            show(hosts.textBlock(for: path, on: on), lens: .preview, place, context: target)
        } else if Self.isHTML(path), on == host.host {
            show(host.webBlock(forFile: path), lens: .web, place, context: target)
        } else if Self.isEditable(path) {
            show(hosts.textBlock(for: path, on: on), lens: Lens.default(for: .text, path: path), place, context: target)
        } else if let kind = Self.mediaKind(path), let client = hosts.client(on) {
            show(client.mediaBlock(for: path, kind: kind), lens: kind == .pdf ? .pdf : .image, place, context: target)
        } else {
            NSWorkspace.shared.open(URL(fileURLWithPath: path))
        }
    }

    /// Opens a path on another host, where it can't be looked at from
    /// here: a folder if it ends in a slash, Markdown by its name, else
    /// text; `path:line:column` as from this host.
    private func openRemote(_ target: String, on: HostID, base: String?, from: PlacementID?, place: Where) {
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
            show(hosts.directoryBlock(for: String(path.dropLast()), on: on), lens: .directory, place, context: target)
        } else if let kind = Self.mediaKind(path), let client = hosts.client(on) {
            show(client.mediaBlock(for: path, kind: kind), lens: kind == .pdf ? .pdf : .image, place, context: target)
        } else {
            if let line { pendingJump = (path, line, column) }
            show(hosts.textBlock(for: path, on: on), lens: Lens.default(for: .text, path: path), place, context: target)
        }
    }

    /// Language Servers…: the table of what runs for which files.
    @objc func showLanguageServers(_ sender: Any?) {
        if languageServersWindow == nil {
            let wc = LanguageServersWindow()
            wc.source = { [weak self] in self?.desk.settings.languageServers ?? LanguageServerConfig.defaults }
            wc.states = { [weak self] in
                guard let self else { return [:] }
                var out: [String: String] = [:]
                for c in self.hosts.all {
                    for (key, state) in c.languageServerStates { out[hosts.label(of: c.host) + ": " + key] = state }
                }
                return out
            }
            wc.onChange = { [weak self] configs in
                guard let self else { return }
                var s = self.desk.settings
                s.languageServers = configs
                self.host.setSettings(s)
            }
            languageServersWindow = wc
        }
        languageServersWindow?.showWindow(nil)
        languageServersWindow?.refresh()
    }

    private var remotingWindow: RemotingWindow?

    /// Remoting…: the providers that reach hosts (§8), kept in the hosts file.
    func debugRemoting(_ arg: String) -> String {
        if arg == "add" { remotingWindow?.debugAdd() }
        return remotingWindow?.debugRows ?? "no remoting window"
    }

    @objc func showRemoting(_ sender: Any?) {
        if remotingWindow == nil {
            let wc = RemotingWindow()
            wc.source = { HostsFile.load().providers }
            wc.onChange = { providers in
                var file = HostsFile.load()
                file.providers = providers
                file.save()
            }
            wc.onAttach = { [weak self] in self?.attachToHost(nil) }
            remotingWindow = wc
        }
        remotingWindow?.showWindow(nil)
        remotingWindow?.refresh()
    }

    /// Attach to Host…: a destination, as ssh takes them, or
    /// `provider:name` for a `manifold-remote-<provider>` on the PATH.
    @objc func attachToHost(_ sender: Any?) {
        guard let window else { return }
        let alert = NSAlert()
        alert.messageText = "Attach to a Host"
        alert.informativeText = "A provider (Remoting… configures them) and a destination it understands. Manifold installs its server there, in ~/.manifold/bin, if it isn't already."
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

    /// A host's own preferences (its shell, for now), as every Mac
    /// attached to it shares them; the host says if it can't do as asked.
    func editPreferences(_ host: HostID) {
        guard let window, let c = hosts.client(host) else { return }
        let alert = NSAlert()
        alert.messageText = "Preferences for \(hosts.label(of: host))"
        alert.informativeText = "The shell new terminals there start: a name on the host's PATH, or a path; empty for your login shell. Shells already running keep theirs. Every Mac attached to the host shares these."
        let box = NSView(frame: NSRect(x: 0, y: 0, width: 300, height: 28))
        let label = NSTextField(labelWithString: "Shell")
        label.frame = NSRect(x: 0, y: 6, width: 44, height: 17)
        let field = NSTextField(frame: NSRect(x: 50, y: 2, width: 250, height: 24))
        field.placeholderString = "Login shell"
        field.stringValue = c.desk.preferences.shell ?? ""
        box.addSubview(label)
        box.addSubview(field)
        alert.accessoryView = box
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field
        alert.beginSheetModal(for: window) { [weak self] response in
            guard let self, response == .alertFirstButtonReturn else { return }
            var p = c.desk.preferences
            let shell = field.stringValue.trimmingCharacters(in: .whitespaces)
            p.shell = shell.isEmpty ? nil : shell
            self.hosts.setPreferences(p, on: host) { [weak self] error in
                guard let self, let error, let window = self.window else { return }
                let failed = NSAlert()
                failed.messageText = "\(self.hosts.label(of: host)) kept its preferences"
                failed.informativeText = error
                failed.beginSheetModal(for: window)
            }
        }
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

    /// Open requests being waited on: the placements that must go before
    /// the command returns.
    private var openWaits: [(host: HostID, id: Int, client: Int, placements: [PlacementID], made: [BlockID])] = []

    /// A `manifold` command on `on` asks for paths: each goes beside the
    /// block it was run in (or on the focused stack), and with `wait`, the
    /// command is answered once they've all been put away.
    private func openRequest(on: HostID, id: Int, client: Int, paths: [String], beside: BlockID?, wait: Bool) {
        var placed: [PlacementID] = []
        // The blocks this request makes ($EDITOR's): ephemeral, discarded
        // once the editing is done, so a commit message or an agent's
        // prompt leaves nothing in the graph.
        var made: [BlockID] = []
        // The arrangement with the block the command ran in, else the selected.
        let besidePlacement = beside.flatMap { b in
            allWorkspaces.lazy.compactMap { self.hosts.arrangement($0)?.placements.first { $0.block == b } }.first
        }
        if let besidePlacement, let aid = allWorkspaces.first(where: { hosts.arrangement($0)?.placement(besidePlacement.id) != nil }), aid != selected {
            hosts.select(aid)
        }
        for path in paths {
            let isDir = on == host.host && (try? FileManager.default.attributesOfItem(atPath: path))?[.type] as? FileAttributeType == .typeDirectory
            let media = Self.mediaKind(path)
            let html = Self.isHTML(path) && on == host.host
            let known = hosts.blocks.contains { $0.id.host == on && $0.path == path }
            let block = isDir || path.hasSuffix("/") ? hosts.directoryBlock(for: path, on: on)
                : html ? host.webBlock(forFile: path)
                : media.flatMap { kind in hosts.client(on)?.mediaBlock(for: path, kind: kind) } ?? hosts.textBlock(for: path, on: on)
            if wait, !known { made.append(block) }
            // With --wait ($EDITOR), a file is for editing, Markdown too.
            let lens: Lens = isDir || path.hasSuffix("/") ? .directory
                : html ? .web : media == .pdf ? .pdf : media == .image ? .image : (wait ? .editor : Lens.default(for: .text, path: path))
            let before = Set(arrangement?.placements.map(\.id) ?? [])
            if wait, placed.isEmpty, let opener = besidePlacement {
                // $EDITOR: over the terminal that ran it, which comes back
                // when the editing is done.
                showOver(block, lens: lens, over: opener.id, again: true, context: "\(path.lastPathComponent)")
            } else {
                show(block, lens: lens, besidePlacement.map { .besideOpener($0.id) } ?? .here)
            }
            if let a = arrangement, let p = a.placements.first(where: { $0.block == block && !before.contains($0.id) }) ?? a.placements.first(where: { $0.block == block }) {
                placed.append(p.id)
            }
        }
        if wait, !placed.isEmpty {
            openWaits.append((on, id, client, placed, made))
        } else {
            hosts.propose(.openDone(id: id, client: client), on: on)
        }
        NSApp.activate()
    }

    /// A block the host made for a command (`manifold diff`): shown beside
    /// the block the command ran in, else here, and the command answered.
    private func showRequest(on: HostID, id: Int, client: Int, block: BlockID, beside: BlockID?) {
        let besidePlacement = beside.flatMap { b in
            allWorkspaces.lazy.compactMap { self.hosts.arrangement($0)?.placements.first { $0.block == b } }.first
        }
        if let besidePlacement, let aid = allWorkspaces.first(where: { hosts.arrangement($0)?.placement(besidePlacement.id) != nil }), aid != selected {
            hosts.select(aid)
        }
        let lens = hosts.block(block).map { Lens.default(for: $0.kind, path: $0.path) } ?? .diff
        show(block, lens: lens, besidePlacement.map { .besideOpener($0.id) } ?? .here)
        hosts.propose(.openDone(id: id, client: client), on: on)
        NSApp.activate()
    }

    /// Answers `open --wait` commands whose placements have all gone, and
    /// discards the blocks they made that nothing else took up.
    private func checkOpenWaits() {
        guard !openWaits.isEmpty else { return }
        let present = Set(allWorkspaces.compactMap { hosts.arrangement($0) }.flatMap { $0.placements.map(\.id) })
        let placedBlocks = Set(allWorkspaces.compactMap { hosts.arrangement($0) }.flatMap { $0.placements.map(\.block) })
        openWaits.removeAll { wait in
            if wait.placements.allSatisfy({ !present.contains($0) }) {
                hosts.propose(.openDone(id: wait.id, client: wait.client), on: wait.host)
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

    /// Names an arrangement, which keeps it (§3.3).
    private func rename(_ id: BlockID) {
        guard let window, let a = hosts.arrangement(id) else { return }
        let alert = NSAlert()
        alert.messageText = "Name This Workspace"
        alert.informativeText = "A named workspace is kept on the desk until you take it off; an unnamed one leaves when it empties."
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

    // MARK: History

    private var history: HistoryView?

    /// The block whose history is up: the arrangement, or a text block.
    private var historyOf: BlockID?

    /// ⌘Y: the selected arrangement's history, to scrub through and restore.
    @objc func showHistory(_ sender: Any?) {
        guard let id = selected, history == nil else { return hideHistory() }
        let h = makeHistory()
        h.onRestore = { [weak self] state, moment in self?.restore(id, to: state, rewindingTo: moment) }
        h.onNeedBlock = { [weak self] block in self?.hosts.propose(.history(.block(block))) }
        historyOf = id
        hosts.propose(.history(.block(id)))
    }

    /// ⌥⌘Y: the focused file's history: its text at every change.
    @objc func showFileHistory(_ sender: Any?) {
        guard history == nil else { return hideHistory() }
        guard let f = focusedShown, f.kind == .text else { return }
        let block = f.placement.block
        let placement = f.id
        let h = makeHistory()
        h.font = hosts.state.appearance.theme.font(hosts.state.appearance.editorFont, size: hosts.state.appearance.theme.editorSize(hosts.state.appearance.editorFont))
        h.onRestoreText = { [weak self] text in self?.restore(block, toText: text) }
        h.onCompare = { [weak self] moment in
            guard let self, let client = self.hosts.client(block.host) else { return }
            self.hideHistory()
            let diff = client.diffBlock(.versions(block: block, from: moment, to: nil))
            self.hosts.link(from: diff, to: block, kind: .source, context: "then → now")
            self.show(diff, lens: .diff, .besideOpener(placement), context: "Compare with Now")
        }
        historyOf = block
        hosts.propose(.history(.block(block)))
    }

    private func makeHistory() -> HistoryView {
        let h = HistoryView(frame: root.bounds)
        h.onClose = { [weak self] in self?.hideHistory() }
        h.titleOf = { [weak self] block in self?.hosts.block(block)?.displayTitle ?? "?" }
        h.symbolOf = { lens in Theme.symbolName(for: lens) }
        root.addSubview(h, positioned: .above, relativeTo: nil)
        history = h
        return h
    }

    private func hideHistory() {
        history?.removeFromSuperview()
        history = nil
        historyOf = nil
    }

    private func historyArrived(_ shard: ShardID, _ base: Block?, _ entries: [Entry]) {
        guard let history, let block = shard.block else { return }
        if block == historyOf {
            if hosts.block(block)?.kind == .text {
                history.showText(entries: entries, block: block, base: base)
            } else {
                history.show(entries: entries, base: base?.arrangement)
            }
        } else {
            history.blockHistory(block, entries, base: base)
        }
    }

    /// Appends what makes the arrangement so again: a new version, never a
    /// revert; with a moment, each placed file's text is made what it was
    /// then, the same way.
    private func restore(_ id: BlockID, to state: ArrangementState, rewindingTo moment: Stamp?) {
        guard let current = hosts.arrangement(id) else { return }
        var events: [Event] = []
        for p in current.placements { events.append(.remove(p.id)) }
        var ids: [PlacementID: PlacementID] = [:]
        for (c, column) in state.columns.enumerated() {
            for (i, p) in column.enumerated() {
                let id = ULID.make()
                ids[p.id] = id
                events.append(.place(Placement(id: id, block: p.block, lens: p.lens), column: c, at: i))
            }
        }
        var heights: [PlacementID: Double] = [:]
        for (old, new) in ids { if let h = state.heights[old] { heights[new] = h } }
        if !heights.isEmpty { events.append(.heights(heights)) }
        if let f = state.focused, let id = ids[f] { events.append(.focus(id)) }
        if state.fractions.count == state.columns.count { events.append(.fractions(state.fractions)) }
        hosts.append(events, to: .block(id))
        if let moment, let history {
            for p in state.placements where p.lens == .editor || p.lens == .preview {
                if let then = history.text(of: p.block, at: moment) { restore(p.block, toText: then) }
            }
        }
        hideHistory()
    }

    /// A text block's text made what it was: one edit, in the log like
    /// any other (so it undoes, and is itself in the history).
    private func restore(_ block: BlockID, toText text: String) {
        guard let t = hosts.block(block)?.text, t.text.string != text else { return hideHistory() }
        hosts.append(.edit([TextEdit(TextRange(0, t.text.count), text)]), to: .block(block))
        hideHistory()
    }

    // MARK: Window

    func windowDidMove(_ notification: Notification) { saveFrame() }
    func windowDidResize(_ notification: Notification) { saveFrame() }

    private func saveFrame() {
        saveFrameWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, let f = self.window?.frame else { return }
            var state = self.hosts.state.window
            state.frame = [f.minX, f.minY, f.width, f.height]
            if state != self.hosts.state.window { self.hosts.setWindow(state) }
        }
        saveFrameWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: work)
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        // Closing the window quits; the sessions carry on in the server.
        NSApp.terminate(nil)
        return false
    }
}

extension MainWindowController: SidebarDelegate {

    func sidebarOrganizationChanged(_ organization: Organization) { setOrganization(organization, show: false) }
    func sidebarFilterChanged(_ text: String) { refreshOrganization(now: true) }
    func sidebarRemove(_ arrangement: BlockID) { removeFromDesk(arrangement) }
    func sidebarRename(_ arrangement: BlockID) { rename(arrangement) }
    func sidebarNewTab() { showPalette() }

    func sidebarMove(_ arrangement: BlockID, to index: Int) {
        guard let client = hosts.client(of: arrangement) else { return }
        var order = client.desk.order
        guard let from = order.firstIndex(of: arrangement) else { return }
        order.remove(at: from)
        order.insert(arrangement, at: min(max(index, 0), order.count))
        client.setWorkspaceOrder(order)
    }

    func sidebarTogglePinned() {
        var state = hosts.state.window
        state.sidebarPinned.toggle()
        hosts.setWindow(state)
        if state.sidebarPinned {
            showSidebar(animated: false)
            setTrafficLights(visible: true, animated: true)
        } else {
            hideWork?.cancel()
            hideSidebar(force: true)
        }
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.18
            ctx.allowsImplicitAnimation = true
            layoutViews()
            root.layoutSubtreeIfNeeded()
        }
    }

    func sidebarMoreMenu() -> NSMenu {
        let menu = NSMenu()
        // The organizations the bar doesn't hold.
        for org in [Organization.links, .time, .status] {
            let item = ClosureMenuItem("Organize by \(org.title)", symbol: org.symbol) { [weak self] in self?.setOrganization(org) }
            item.state = organization == org ? .on : .off
            menu.addItem(item)
        }
        menu.addItem(.separator())
        menu.addItem(ClosureMenuItem(pinned ? "Hide Sidebar" : "Show Sidebar", symbol: "sidebar.left") { [weak self] in self?.sidebarTogglePinned() })
        menu.addItem(.separator())
        menu.addItem(ClosureMenuItem("Show Logs in Finder", symbol: "folder") {
            NSWorkspace.shared.activateFileViewerSelecting([Paths.logs])
        })
        menu.addItem(ClosureMenuItem("End All Sessions and Quit…", symbol: "power") { [weak self] in self?.stopServer(nil) })
        return menu
    }

    func sidebarResize(to width: CGFloat) {
        resizingWidth = min(max(width.rounded(), Theme.sidebarWidthRange.lowerBound), Theme.sidebarWidthRange.upperBound)
        hideWork?.cancel()
        layoutViews()
    }

    func sidebarResizeEnded() {
        guard let width = resizingWidth else { return }
        var state = hosts.state.window
        state.sidebarWidth = Double(width)
        resizingWidth = nil
        if state != hosts.state.window { hosts.setWindow(state) }
        layoutViews()
        if let window {
            mouseMoved(to: root.convert(window.mouseLocationOutsideOfEventStream, from: nil))
        }
    }

    func sidebarDragChanged(_ dragging: Bool) {
        draggingTab = dragging
        // While anything is dragged, the grid catches it over every tile,
        // web views included.
        content.dragging = dragging
        if !dragging { scheduleHide() }
    }
}

extension MainWindowController: GridDelegate {
    func gridFocus(_ placement: PlacementID) { focus(placement) }
    func gridCanDrop(_ arrangement: BlockID) -> Bool { arrangement != selected }

    /// Another arrangement dropped on this one: its columns come over.
    func gridDropArrangement(_ arrangement: BlockID, column: Int) {
        guard let id = selected, let source = hosts.arrangement(arrangement) else { return hosts.select(arrangement) }
        hosts.append(source.placements.map { .remove($0.id) }, to: .block(arrangement))
        hosts.append(.adopt(columns: source.columns, at: column), to: .block(id))
        removeFromDesk(arrangement)
        hosts.select(id)
    }

    func gridMove(_ placement: PlacementID, column: Int, at: Int, newColumn: Bool, alone: Bool) {
        guard let a = arrangement else { return }
        if newColumn || column >= a.columns.count {
            movePlacement(placement, toNewColumn: column, in: a, alone: alone)
        } else {
            appendToSelected((alone ? a.leavingAlone(placement) : []) + [.move(placement, column: column, at: at)])
        }
    }

    /// A block from the sidebar dropped in the grid: brought there.
    func gridBring(_ block: BlockID, column: Int, at: Int, newColumn: Bool) {
        guard let b = hosts.block(block) else { return }
        if b.kind == .arrangement { return hosts.select(block) }
        let lens = Lens.default(for: b.kind, path: b.path)
        guard let a = arrangement else { return show(block, lens: lens, .here) }
        if newColumn || column >= a.columns.count { return show(block, lens: lens, .inNewColumn(column)) }
        let below = at > 0 && at - 1 < a.columns[column].count ? a.columns[column][at - 1].id : nil
        if let t = a.tile(of: block, lens: lens) { return focus(t.id) }
        if let below {
            appendToSelected(a.bringing(block, lens: lens, inColumn: column, below: below, newPlacement: { ULID.make() }))
        } else {
            appendToSelected([.place(Placement(block: block, lens: lens), column: column, at: 0)])
        }
    }

    func gridUnstash(_ placement: PlacementID) {
        guard let a = arrangement else { return }
        appendToSelected(a.unstashing(placement))
    }

    /// ⌥-click on a shown tile's pill: the first tile behind it takes its place.
    func gridSwapNext(_ placement: PlacementID) {
        guard let a = arrangement, let (c, _) = a.locate(placement),
              let next = a.columns[c].first(where: { a.isStashed($0.id) && a.tile(behind: $0.id)?.id == placement }) else { return NSSound.beep() }
        gridSwap(next.id)
    }

    /// ⌥-drag: the dragged tile takes a tile's place, that tile and its
    /// stack going behind it.
    func gridCover(_ placement: PlacementID, over target: PlacementID, alone: Bool) { cover(placement, over: target, alone: alone) }

    /// Close Stack: this tile and every one behind it are taken off the
    /// workspace (as ⌘W takes one; the blocks keep). Maximized, its stack
    /// is its whole column, which goes.
    func gridCloseStack(_ placement: PlacementID) {
        guard let a = arrangement, let (c, _) = a.locate(placement) else { return }
        let stack = a.full == placement
            ? a.columns[c]
            : a.columns[c].filter { $0.id == placement || (a.isStashed($0.id) && a.tile(behind: $0.id)?.id == placement) }
        var events: [Event] = a.full == placement ? [.full(nil)] : []
        events += stack.map { .remove($0.id) }
        appendToSelected(events)
    }

    /// Unstack: every tile behind this one shows, sharing its room.
    func gridUnstackAll(_ placement: PlacementID) {
        guard let a = arrangement, let (c, _) = a.locate(placement) else { return }
        let behind = a.columns[c].filter { a.isStashed($0.id) && a.tile(behind: $0.id)?.id == placement }
        guard !behind.isEmpty else { return }
        let share = a.height(of: placement) / Double(behind.count + 1)
        var heights: [PlacementID: Double] = [placement: share]
        for t in behind { heights[t.id] = share }
        appendToSelected([.heights(heights)])
    }

    /// ⌥-click on a stashed pill: that tile shows where the stack's top
    /// did, and the top goes behind it.
    func gridSwap(_ placement: PlacementID) {
        guard let a = arrangement, a.isStashed(placement), let top = a.tile(behind: placement) else { return gridUnstash(placement) }
        appendToSelected(a.unstashing(placement) + [.stash(top.id, behind: placement), .focus(placement)])
    }

    /// A pill clicked: its tile grows a step, as acme's does.
    func gridGrow(_ placement: PlacementID) {
        guard let a = arrangement else { return }
        appendToSelected(a.growing(placement))
    }

    /// A pill ⌘-clicked: its tile fills the column, the others stashed.
    func gridFill(_ placement: PlacementID) {
        guard let a = arrangement else { return }
        appendToSelected(a.growing(placement, whole: true))
    }

    func gridStash(_ placement: PlacementID, behind: PlacementID, alone: Bool) {
        guard let a = arrangement else { return }
        appendToSelected((alone ? a.leavingAlone(placement) : []) + a.stashing(placement, behind: behind))
    }

    func gridToggleFull(_ placement: PlacementID) {
        guard let a = arrangement else { return }
        appendToSelected([.full(a.full == placement ? nil : placement)])
    }

    /// ⌘M: the focused tile into the stack behind its nearest tile — the
    /// shown one above it in the column, else the column's first — as
    /// Stash in a pill's menu does; the focus goes to that tile.
    @objc func stashTile(_ sender: Any?) {
        guard let a = arrangement, let f = a.focused, let (c, i) = a.locate(f), !a.isStashed(f) else { return NSSound.beep() }
        let others = a.columns[c].enumerated().filter { $0.element.id != f && !a.isStashed($0.element.id) }
        guard let heir = others.last(where: { $0.offset < i })?.element ?? others.first?.element else { return NSSound.beep() }
        appendToSelected(a.stashing(f) + [.focus(heir.id)])
    }

    /// ⇧⌘↩: the focused tile over the whole arrangement, or back.
    @objc func toggleMaximize(_ sender: Any?) {
        guard let a = arrangement, let f = a.focused else { return }
        gridToggleFull(f)
    }

    func gridResized(fractions: [Double]) { appendToSelected([.fractions(fractions)]) }
    func gridResized(heights: [PlacementID: Double], stashed: [(PlacementID, PlacementID)]) {
        appendToSelected(stashed.map { Event.stash($0.0, behind: $0.1) } + [.heights(heights)])
    }
    func gridDragChanged(_ dragging: Bool) { sidebarDragChanged(dragging) }

    func gridDragAtLeftEdge() {
        if !sidebarShown { showSidebar(animated: true) }
    }

    /// A tile's pill clicked: its menu.
    /// ⌥-click on a pill: where the block is, as a path — the file or
    /// folder, then each folder up to the root (a terminal's working
    /// directory likewise); choosing one browses that folder here, as
    /// ⌘-clicking a document's title does in the Finder.
    func gridPathMenu(for placement: PlacementID) -> NSMenu? {
        guard let a = arrangement, let p = a.placement(placement), let b = hosts.block(p.block) else { return nil }
        let on = b.id.host
        guard let start = b.path ?? b.terminal?.cwd ?? b.home, start.hasPrefix("/") else { return nil }
        let menu = NSMenu()
        var path = start
        var first = true
        while true {
            let name = path == "/" ? "/" : path.lastPathComponent
            let isFolder = !first || b.path == nil || b.kind == .directory
            let here = path
            let item = ClosureMenuItem(name, symbol: isFolder ? "folder" : Theme.symbolName(for: b.kind, path: b.path)) { [weak self] in
                guard let self else { return }
                if isFolder, let client = self.hosts.client(on) {
                    self.show(client.directoryBlock(for: here), lens: .directory, .here)
                } else {
                    self.focus(placement)
                }
            }
            item.indentationLevel = 0
            menu.addItem(item)
            if path == "/" { break }
            path = path.deletingLastPathComponent
            if path.isEmpty { path = "/" }
            first = false
        }
        return menu
    }

    func gridPillMenu(for placement: PlacementID) -> NSMenu? {
        guard let a = arrangement, let p = a.placement(placement), let id = selected else { return nil }
        let block = p.block
        let menu = NSMenu()
        let maximized = a.full == placement
        menu.addItem(ClosureMenuItem(maximized ? "Restore" : "Maximize", symbol: maximized ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right") { [weak self] in self?.gridToggleFull(placement) })
        menu.addItem(ClosureMenuItem("Grow", symbol: "arrow.up.and.down") { [weak self] in self?.appendToSelected(a.growing(placement)) })
        if let c = a.columnIndex(of: placement), a.columns[c].contains(where: { a.isStashed($0.id) && a.tile(behind: $0.id)?.id == placement }) {
            menu.addItem(ClosureMenuItem("Unstack", symbol: "square.stack.3d.up.slash") { [weak self] in self?.gridUnstackAll(placement) })
            menu.addItem(ClosureMenuItem("Close Stack", symbol: "rectangle.stack.badge.minus") { [weak self] in self?.gridCloseStack(placement) })
        } else if maximized, let c = a.columnIndex(of: placement), a.columns[c].count > 1 {
            // Maximized, the column behind it is its stack: closed with it.
            menu.addItem(ClosureMenuItem("Close Column", symbol: "rectangle.stack.badge.minus") { [weak self] in self?.gridCloseStack(placement) })
        }
        menu.addItem(ClosureMenuItem("Fill the Column", symbol: "rectangle.expand.vertical") { [weak self] in self?.appendToSelected(a.growing(placement, whole: true)) })
        if [.terminal, .agent, .editor, .preview].contains(p.lens) {
            menu.addItem(ClosureMenuItem("Show Outline Beside", symbol: "list.bullet.rectangle") { [weak self] in
                self?.showOutline(of: block, beside: placement)
            })
        }
        if let c = a.columnIndex(of: placement), a.shownTiles(inColumn: c).count > 1 {
            menu.addItem(ClosureMenuItem("Stash", symbol: "tray.and.arrow.down", key: "m") { [weak self] in
                guard let self else { return }
                self.focus(placement)
                self.stashTile(nil)
            })
        }
        menu.addItem(.separator())
        if let own = views[placement]?.pillItems, !own.isEmpty {
            for item in own { menu.addItem(item) }
            menu.addItem(.separator())
        }
        if hosts.block(block)?.statusRecord != nil {
            menu.addItem(ClosureMenuItem("Clear Status", symbol: "eraser") { [weak self] in self?.hosts.propose(.clearStatus(block)) })
        }
        if let b = hosts.block(block) {
            menu.addItem(.separator())
            for item in keepingItems(for: b) { menu.addItem(item) }
        }
        let agents = NSMenu()
        for item in agentMenuItems() { agents.addItem(item) }
        let launch = NSMenuItem(title: "Launch Agent Here", action: nil, keyEquivalent: "")
        launch.setSymbol("sparkles", size: 12)
        launch.submenu = agents
        menu.addItem(launch)
        menu.addItem(ClosureMenuItem("Links Around This", symbol: "point.3.connected.trianglepath.dotted") { [weak self] in
            self?.linksCenter = block
            self?.setOrganization(.links)
        })
        if let b = hosts.block(block), b.isNote {
            menu.addItem(ClosureMenuItem("Name…", symbol: "pencil") { [weak self] in self?.nameNote(placement) })
        }
        if let b = hosts.block(block), b.kind == .text, p.lens.isText {
            let viewing = p.lens == .preview
            menu.addItem(ClosureMenuItem(viewing ? "Edit" : "View", symbol: viewing ? "pencil" : "eye", key: "\r") { [weak self] in self?.toggleMode(placement) })
        }
        menu.addItem(.separator())
        menu.addItem(ClosureMenuItem("Take Off This Workspace", symbol: "xmark") { [weak self] in
            self?.hosts.append(.remove(placement), to: .block(id))
        })
        return menu
    }

    /// A block's neighborhood (§3.5), each edge kind and direction that
    /// has anything as a bunch of cards: what Links shows.
    func footBunches(of block: BlockID) -> [FootBunch] {
        let n = hosts.neighborhood(of: block)
        var bunches: [FootBunch] = []
        func card(_ id: BlockID, detail: String, at: Stamp?) -> FootCard? {
            guard let b = hosts.block(id) else { return nil }
            return FootCard(block: id, title: b.displayTitle, symbol: Theme.symbolName(for: b.kind, path: b.path), detail: detail, at: at)
        }
        func bunch(_ role: FootBunch.Role, _ title: String, _ symbol: String, _ edges: [Edge], toward: KeyPath<Edge, BlockID>, fallback: String) {
            var seen: Set<BlockID> = []
            let cards = edges.compactMap { e -> FootCard? in
                let other = e[keyPath: toward]
                guard seen.insert(other).inserted else { return nil }
                return card(other, detail: e.context ?? fallback, at: e.at)
            }
            if !cards.isEmpty { bunches.append(FootBunch(role: role, title: title, symbol: symbol, cards: cards)) }
        }
        bunch(.openedFrom, "opened from", "arrow.turn.up.left", n.inbound[.link(.opened)] ?? [], toward: \.from, fallback: "opened here")
        bunch(.openedHere, "opened here", "arrow.turn.down.right", n.outbound[.link(.opened)] ?? [], toward: \.to, fallback: "opened from here")
        bunch(.found, "found by", "magnifyingglass", n.inbound[.link(.found)] ?? [], toward: \.from, fallback: "a hit")
        bunch(.found, "found", "magnifyingglass", n.outbound[.link(.found)] ?? [], toward: \.to, fallback: "a hit")
        bunch(.derived, "compared", "arrow.left.arrow.right", n.inbound[.link(.source)] ?? [], toward: \.from, fallback: "a diff of this")
        bunch(.sources, "sources", "doc.text", n.outbound[.link(.source)] ?? [], toward: \.to, fallback: "compared here")
        bunch(.linked, "links", "arrow.right", n.outbound[.link(.linked)] ?? [], toward: \.to, fallback: "linked by hand")
        bunch(.linked, "linked from", "arrow.left", n.inbound[.link(.linked)] ?? [], toward: \.from, fallback: "linked by hand")
        bunch(.mentions, "mentioned in", "link", n.inbound[.link(.mention)] ?? [], toward: \.from, fallback: "a link")
        bunch(.mentions, "mentions", "link", n.outbound[.link(.mention)] ?? [], toward: \.to, fallback: "a link")
        // Other arrangements holding the block: not the one it's shown in.
        let elsewhere = (n.inbound[.placed] ?? []).filter { $0.from != selected }
        bunch(.placedIn, "also in", "rectangle.3.group", elsewhere, toward: \.from, fallback: "placed there")
        if hosts.block(block)?.kind == .arrangement {
            bunch(.placedIn, "holds", "square.stack", n.outbound[.placed] ?? [], toward: \.to, fallback: "placed here")
        }
        func trail(_ role: FootBunch.Role, _ title: String, _ symbol: String, _ neighbors: [TrailNeighbor]) {
            let cards = neighbors.compactMap { t in card(t.block, detail: t.count == 1 ? "once" : "\(t.count) times", at: t.last) }
            if !cards.isEmpty { bunches.append(FootBunch(role: role, title: title, symbol: symbol, cards: Array(cards.prefix(8)))) }
        }
        trail(.before, "before", "arrow.left", n.before.filter { $0.block != block })
        trail(.after, "after", "arrow.right", n.after.filter { $0.block != block })
        return bunches
    }

    /// Moves a placement into a new column at `index`.
    private func movePlacement(_ placement: PlacementID, toNewColumn index: Int, in a: ArrangementState, alone: Bool = false) {
        guard let (sc, _) = a.locate(placement) else { return }
        let only = a.columns[sc].count == 1
        if only, index == sc || index == sc + 1 { return }
        // Past the end makes a new column; then it's moved into place.
        appendToSelected((alone ? a.leavingAlone(placement) : []) + [.move(placement, column: a.columns.count, at: 0)])
        guard let now = arrangement else { return }
        let from = now.columns.count - 1
        var to = index
        if only, sc < index { to -= 1 }
        reorderColumn(from: from, to: min(to, from))
    }

}

extension MainWindowController: EditorViewDelegate {
    func editor(_ view: EditorView, append events: [Event]) {
        hosts.append(events, to: .block(view.block))
    }

    func editor(_ view: EditorView, propose proposal: Proposal) {
        hosts.propose(proposal)
    }

    func editorText(_ view: EditorView) -> TextState? {
        hosts.block(view.block)?.text
    }

    /// An outline's entry clicked: the block's tile goes there — its
    /// terminal to the command's row, its editor or preview to the
    /// heading; with no tile of it shown, one is opened beside the outline.
    /// ⇧⌘O: the focused tile's outline beside it.
    @objc func showOutlineBeside(_ sender: Any?) {
        guard let f = focusedShown, [.terminal, .agent, .editor, .preview].contains(f.lens) else { return NSSound.beep() }
        showOutline(of: f.placement.block, beside: f.id)
    }

    /// An outline block of another (§3.8), beside its tile: a graph node
    /// of its own, linked to its subject as its source, gone when closed.
    func showOutline(of block: BlockID, beside placement: PlacementID) {
        guard let client = hosts.client(block.host) else { return }
        show(client.outlineBlock(of: block), lens: .outline, .besideOpener(placement), kind: .opened, context: "outline")
    }

    /// An outline block whose last tile closed is discarded: it was only
    /// ever a view of its subject.
    private func discardIfUnplaced(_ block: BlockID) {
        guard let b = hosts.block(block), b.kind == .outline,
              !allWorkspaces.contains(where: { hosts.arrangement($0)?.placements(of: block).isEmpty == false }) else { return }
        hosts.propose(.discard(block))
    }

    func outline(_ view: OutlineLensView, go entry: OutlineLensView.Entry) {
        let subject = view.subject ?? view.block
        let shown = views.values.filter { $0.block == subject && $0.superview != nil && !$0.isHidden && !($0 is OutlineLensView) }
        if shown.isEmpty, let b = hosts.block(subject) {
            if let path = b.path, let line = entry.line { pendingJump = (path, line + 1, nil) }
            show(subject, lens: Lens.default(for: b.kind, path: b.path), .besideOpener(view.placement))
            return
        }
        for v in shown {
            switch v {
            case let t as TerminalView: t.go(toCommand: entry.id)
            case let e as EditorView: if let line = entry.line { e.select(line: line + 1, column: nil) }
            case let m as MarkdownView: m.scroll(toHeading: entry.id)
            default: break
            }
            if let p = arrangement?.placement(v.placement), arrangement?.isStashed(p.id) == true { focus(p.id) }
        }
    }

    func editorEditedChanged(_ view: EditorView) {
        render()
    }

    func editorDiagnostics(_ view: EditorView) -> [Diagnostic] {
        hosts.diagnostics(view.block)
    }

    func editorGutter(_ view: EditorView) -> [GutterMark] {
        hosts.gutter(view.block)
    }

    func editor(_ view: EditorView, lsp request: LSPRequest, done: @escaping (LSPResult) -> Void) {
        hosts.lsp(request, done: done)
    }

    func editor(_ view: EditorView, open url: URL) {
        open(url.absoluteString, from: view.placement)
    }

    func terminal(_ view: TerminalView, setCopyOnSelect on: Bool) {
        var s = desk.settings
        s.copyOnSelect = on
        TerminalView.copyOnSelect = on
        host.setSettings(s)
    }

    /// A block ⇧-dragged into the editor: linked to the note (the host's
    /// mention scan sees the link in the text too, as a mention).
    func editor(_ view: EditorView, linkedFrom block: BlockID) { link(block, to: view.block) }

    /// A block ⇧-dragged onto a terminal: its path typed, and linked.
    func terminal(_ view: TerminalView, linkedFrom block: BlockID) { link(block, to: view.block) }

    /// The host's last process listing, those under this terminal's shell;
    /// and a fresh listing asked for, so the next menu is current.
    func terminalProcesses(_ view: TerminalView, refresh: Bool) -> [ProcessEntry] {
        guard let client = hosts.client(view.block.host) else { return [] }
        let pb = client.node.blocks.first { $0.kind == .process }
        if refresh { hosts.propose(.processes(block: pb?.id ?? BlockID(host: client.host))) }
        return pb?.processes?.entries.filter { $0.block == view.block } ?? []
    }

    func terminal(_ view: TerminalView, signal pid: Int32, _ signal: Int32) {
        hosts.client(view.block.host)?.propose(.signal(pid: pid, signal: signal)) { [weak self] error in
            if let error { self?.window?.title = error }
        }
    }

    /// A link in the text clicked: a block's gone to; an address opened.
    func editor(_ view: EditorView, follow target: String, over: Bool) { open(target, from: view.placement, over: over) }

    func editor(_ view: EditorView, open path: String, line: Int, column: Int) {
        let on = view.block.host
        pendingJump = (path, line, column)
        let block = hosts.textBlock(for: path, on: on)
        hosts.link(from: view.block, to: block, kind: .opened, context: view.lineAtCaret)
        show(block, lens: Lens.default(for: .text, path: path), opener(view.placement), context: view.lineAtCaret)
    }

    /// A server's edits to other files on the block's host: files that are
    /// blocks through their logs (the server saw the block's text), the
    /// rest written on the host.
    func editor(_ view: EditorView, apply edits: [LSPFileEdit]) {
        let on = view.block.host
        guard let client = hosts.client(on) else { return }
        for f in edits {
            let ordered = f.edits.sorted { $0.start > $1.start }
            if let b = client.node.blocks.first(where: { $0.kind == .text && $0.path == f.path }), b.text != nil {
                client.append(.edit(ordered), to: .block(b.id))
            } else {
                client.propose(.editFile(path: f.path, edits: ordered))
            }
        }
    }
}

extension MainWindowController: MarkdownViewDelegate {
    /// A link followed in a preview: another Markdown file opens as a
    /// preview on top of the same stack (the one it was followed from
    /// stays beneath, to go back to); a web address as a web block beside;
    /// any other file as what it is, beside; other schemes with the system.
    func markdownView(_ view: MarkdownView, follow url: URL, modifiers: NSEvent.ModifierFlags) {
        guard let a = arrangement, let p = a.placement(view.placement) else { return }
        if url.isFileURL {
            let path = url.standardizedFileURL.path
            let over = modifiers.contains(.option)
            if Lens.isMarkdown(path), !modifiers.contains(.command) {
                let block = hosts.textBlock(for: path, on: p.block.host)
                hosts.link(from: p.block, to: block, kind: .mention, context: path.lastPathComponent)
                // Page to page in the same tile, as a browser goes — or,
                // with ⌥, the page over this one.
                if over { showOver(block, lens: .preview, over: view.placement) } else { replace(view.placement, with: block, lens: .preview) }
            } else {
                open(path, from: view.placement, over: over)
            }
        } else {
            open(url.absoluteString, from: view.placement, here: Self.opensHere(modifiers), over: modifiers.contains(.option))
        }
    }
}

extension MainWindowController: WebViewDelegate {
    func webView(_ view: WebView, append events: [Event]) {
        hosts.append(events, to: .block(view.block))
    }

    func webView(_ view: WebView, open url: URL, over: Bool) {
        open(url.absoluteString, from: view.placement, here: true, over: over)
    }
}

extension MainWindowController: DirectoryViewDelegate {
    func directoryView(_ view: DirectoryView, open path: String, isDirectory: Bool) {
        let block = hosts.directoryBlock(for: path, on: view.block.host)
        let mods = Self.clickModifiers ?? []
        if isDirectory, mods.contains(.option) {
            // ⌥: the folder's listing over this one.
            showOver(block, lens: .directory, over: view.placement)
        } else if isDirectory, mods.contains(.command) {
            // ⌘: the folder's listing beside this one, which stays.
            show(block, lens: .directory, .besideOpener(view.placement))
        } else if isDirectory {
            // A folder takes the listing's place, in the same tile.
            replace(view.placement, with: block, lens: .directory)
        } else {
            open(path, from: view.placement)
        }
    }

    func directoryViewRefresh(_ view: DirectoryView) {
        hosts.propose(.listDirectory(view.block))
    }
}

extension MainWindowController: MediaViewDelegate {
    func mediaView(_ view: MediaView, needsBytes done: @escaping (Data?) -> Void) {
        guard let client = hosts.client(view.block.host) else { return done(nil) }
        client.readBytes(view.block, done: done)
    }
}

extension MainWindowController: ProcessViewDelegate {
    func processViewRefresh(_ view: ProcessView) {
        hosts.propose(.processes(block: view.block))
    }

    func processView(_ view: ProcessView, goTo block: BlockID) { arrive(block, from: view.placement) }

    func processView(_ view: ProcessView, signal pid: Int32, _ signal: Int32) {
        hosts.client(view.block.host)?.propose(.signal(pid: pid, signal: signal)) { [weak self] error in
            if let error { self?.window?.title = error }
        }
    }
}

extension MainWindowController: GitViewDelegate {
    func gitView(_ view: GitView, openDiff subject: DiffSubject) {
        guard let client = hosts.client(view.block.host) else { return }
        let block = client.diffBlock(subject)
        var context = ""
        switch subject {
        case let .sides(_, new):
            if let file = hosts.client(view.block.host)?.textBlock(path: new.path) {
                hosts.link(from: block, to: file.id, kind: .source, context: "HEAD → working tree")
            }
            context = new.path.lastPathComponent
        case let .commit(_, sha): context = String(sha.prefix(7))
        case .versions, .patch: break
        }
        show(block, lens: .diff, opener(view.placement), context: context)
    }

    func gitView(_ view: GitView, open path: String) {
        open(path: path, line: 1, column: nil, on: view.block.host, from: view.placement, context: path.lastPathComponent)
    }

    func gitViewRefresh(_ view: GitView) {
        hosts.propose(.refreshGit(block: view.block))
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
}

extension MainWindowController: SearchViewDelegate {
    func searchView(_ view: SearchView, run query: SearchQuery) {
        hosts.propose(.search(block: view.block, query: query))
    }

    func searchView(_ view: SearchView, open hit: SearchHit) {
        open(path: hit.path, line: hit.line, column: hit.column, on: view.block.host, from: view.placement,
             kind: .found, context: hit.text.trimmingCharacters(in: .whitespaces))
    }

    func searchViewCancel(_ view: SearchView) {
        hosts.propose(.cancelSearch(block: view.block))
    }
}

extension MainWindowController: TerminalViewDelegate {
    func terminal(_ view: TerminalView, open target: String, over: Bool) {
        open(target, from: view.placement, over: over)
    }

    /// A ⌘-clicked word that isn't a link to ghostty (`ls` prints a folder
    /// as a bare name): a folder by that name where the terminal is opens
    /// as a listing; anything else, nothing. On another host, what can't
    /// be looked at from here is taken for a folder when it ends in /.
    func terminal(_ view: TerminalView, openFolder name: String, over: Bool) {
        let word = name.trimmingCharacters(in: CharacterSet(charactersIn: "'\"`,;"))
        guard !word.isEmpty else { return }
        guard view.block.host == host.host else {
            if word.hasSuffix("/") { open(word, from: view.placement, over: over) }
            return
        }
        var path = (word as NSString).expandingTildeInPath
        if !path.hasPrefix("/"), let base = hosts.block(view.block)?.terminal?.cwd { path = (base as NSString).appendingPathComponent(path) }
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDir), isDir.boolValue else { return }
        open(word, from: view.placement, over: over)
    }

    /// A command from a terminal's scrubber (§3.8): a note of it and its
    /// output, as the screen showed it, opened from the terminal.
    func terminal(_ view: TerminalView, show command: ShellCommand, output: String) {
        let client = hosts.client(view.block.host) ?? host
        let note = client.newNote(home: hosts.block(view.block)?.terminal?.cwd)
        client.append(.title(command.text), to: .block(note))
        client.append(.content("$ " + command.text + "\n" + output + "\n", encoding: "utf-8", lineEnding: "\n", fingerprint: ""), to: .block(note))
        hosts.link(from: view.block, to: note, kind: .opened, context: "command output")
        show(note, lens: .editor, Self.clickModifiers?.contains(.option) == true ? .over(view.placement) : .here, kind: .opened)
    }

    func terminalDidFocus(_ view: TerminalView) {
        guard let a = arrangement, a.placement(view.placement) != nil, a.focused != view.placement else { return }
        focus(view.placement)
    }

    func terminalDidClose(_ view: TerminalView) {
        guard views[view.placement] === view else { return }
        views.removeValue(forKey: view.placement)
        view.removeFromSuperview()
        recentlyClosed.insert(view.block)
        render()
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
            self?.recentlyClosed.remove(view.block)
            self?.render()
        }
    }
}

final class MainWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }

    // ⌘Z and ⇧⌘Z that no view took (an editor takes its own): the
    // workspace's undo (§3.1). The window would otherwise answer them
    // with its own, empty, undo manager.
    @objc func undo(_ sender: Any?) { (windowController as? MainWindowController)?.undo(sender) }
    @objc func redo(_ sender: Any?) { (windowController as? MainWindowController)?.redo(sender) }

    // The title bar is hidden, but AppKit still treats the strip above the
    // content layout rect as one: a click there moves the window with any
    // twitch of the mouse, and a double click zooms it. Claiming the whole
    // window for content leaves no such strip; the sidebar's header moves
    // the window instead. (Ghostty does the same for its hidden title bar.)
    override var contentLayoutRect: CGRect {
        var rect = super.contentLayoutRect
        rect.origin.y = 0
        rect.size.height = frame.height
        return rect
    }
}

/// The window's content view; watches the mouse for the sidebar.
final class RootView: NSView {
    var onMouseMoved: ((NSPoint) -> Void)?
    var onMouseExitedWindow: (() -> Void)?
    var onLayout: (() -> Void)?

    override func updateTrackingAreas() {
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                       owner: self))
        super.updateTrackingAreas()
    }

    override func mouseMoved(with event: NSEvent) {
        onMouseMoved?(convert(event.locationInWindow, from: nil))
    }

    override func mouseExited(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        // Leaving through the left edge is how you reach the sidebar when the
        // window is against the side of the screen.
        if p.x <= 0 { onMouseMoved?(NSPoint(x: 0, y: p.y)) } else { onMouseExitedWindow?() }
    }

    override func layout() {
        super.layout()
        onLayout?()
    }
}

extension MainWindowController: OrganizationViewDelegate {
    /// A row clicked: an arrangement is gone to; a tile is focused (in its
    /// arrangement); any other block is gone to where it is, or, with ⌘,
    /// brought here (§3.1).
    func organizationOpen(_ node: OrgNode, newColumn bring: Bool) {
        HoverCard.shared.hide()
        if let arr = node.arrangement, !bring {
            hideStateView()
            if arr == selected, node.placement == nil, node.column == nil, node.style == .section {
                // The current workspace's label: folded, or opened again.
                deskFolded.toggle()
                refreshOrganization(now: true)
                return
            }
            if arr != selected {
                deskFolded = false
                hosts.select(arr)
            }
            if let p = node.placement, let a = hosts.arrangement(arr), a.placement(p) != nil {
                // Out of its stack, from behind a maximized tile, focused,
                // and the pointer on it.
                hosts.append(revealing(p, in: a), to: .block(arr))
                warpPointerToFocus()
            }
            return
        }
        guard let block = node.block, let b = hosts.block(block) else { return }
        if b.kind == .arrangement { return hosts.select(block) }
        if bring { show(block, lens: Lens.default(for: b.kind, path: b.path), .here) } else { arrive(block, from: arrangement?.focused) }
        if organization == .links, linksCenter != nil { linksCenter = block; refreshOrganization(now: true) }
    }

    /// Double-clicking an arrangement names it.
    func organizationActivate(_ node: OrgNode) -> Bool {
        guard let arr = node.arrangement, node.column == nil else { return false }
        rename(arr)
        return true
    }

    func organizationHover(_ node: OrgNode?, at rect: NSRect, in view: NSView) {
        guard let node, let id = node.block, let b = hosts.block(id), let window else { return HoverCard.shared.hide() }
        var detail = b.path?.deletingLastPathComponent.abbreviatingHome ?? b.kind.defaultTitle
        if let seen = hosts.client(of: id)?.node.graph.seen(id) { detail += " · " + Age.ago(seen) }
        if id.host != host.host { detail += " · on \(hosts.label(of: id.host))" }
        var body = ""
        var font: NSFont? = nil
        switch b.kind {
        case .text:
            body = String(b.text?.text.string.prefix(600) ?? "").split(separator: "\n", omittingEmptySubsequences: false).prefix(8).joined(separator: "\n")
            font = hosts.state.appearance.theme.font(hosts.state.appearance.editorFont, size: 12)
        case .terminal, .agent:
            body = b.terminal?.cwd?.abbreviatingHome ?? ""
        case .search:
            body = b.search.map { "\($0.hits.count) hits" } ?? ""
        case .arrangement:
            body = b.arrangement.map { a in a.visible.compactMap { self.hosts.block($0.block)?.displayTitle }.joined(separator: " · ") } ?? ""
        default: break
        }
        HoverCard.shared.show(title: b.displayTitle, detail: detail, body: body, font: font, beside: rect, in: window)
    }

    func organizationMenu(for node: OrgNode) -> NSMenu? {
        let menu = NSMenu()
        if node.id.hasPrefix("host:"), let c = hosts.all.first(where: { "host:\($0.host.raw)" == node.id }), c.isRemote {
            if c.link != .connected {
                menu.addItem(ClosureMenuItem("Try Again Now", symbol: "arrow.clockwise") { [weak self] in
                    c.retryNow()
                    self?.refreshOrganization(now: true)
                })
            }
            menu.addItem(ClosureMenuItem("Open Home Folder", symbol: "house") { [weak self] in
                guard let self, let home = c.home else { return }
                self.openDirectory(home, on: c.host)
            })
            let there = ClosureMenuItem("New Workspace on \(hosts.label(of: c.host))", symbol: "plus.rectangle.on.rectangle") { [weak self] in
                self?.newWorkspace(on: c.host, cwd: nil)
            }
            there.isEnabled = c.link == .connected
            menu.addItem(there)
            let preferences = ClosureMenuItem("Preferences for \(hosts.label(of: c.host))…", symbol: "gearshape") { [weak self] in
                self?.editPreferences(c.host)
            }
            preferences.isEnabled = c.link == .connected
            menu.addItem(preferences)
            menu.addItem(.separator())
            menu.addItem(ClosureMenuItem("Detach from \(hosts.label(of: c.host))…", symbol: "xmark") { [weak self] in
                self?.detach(c.host)
            })
            return menu
        }
        if let arr = node.arrangement, node.column == nil {
            menu.addItem(ClosureMenuItem("Name…", symbol: "pencil") { [weak self] in self?.rename(arr) })
            menu.addItem(.separator())
            menu.addItem(ClosureMenuItem("Take Off the Desk", symbol: "xmark") { [weak self] in self?.removeFromDesk(arr) })
            return menu
        }
        if node.id.hasPrefix("status:"), let group = StatusGroup.allCases.first(where: { "status:\($0)" == node.id }), group != .inactive {
            let blocks = (statusGroups("")[group] ?? []).map(\.0).filter { $0.statusRecord != nil }
            guard !blocks.isEmpty else { return nil }
            menu.addItem(ClosureMenuItem("Clear All \(group.title)", symbol: "eraser") { [weak self] in
                for b in blocks { self?.hosts.propose(.clearStatus(b.id)) }
            })
            return menu
        }
        guard let id = node.block else { return nil }
        if hosts.block(id)?.statusRecord != nil {
            menu.addItem(ClosureMenuItem("Clear Status", symbol: "eraser") { [weak self] in self?.hosts.propose(.clearStatus(id)) })
            menu.addItem(.separator())
        }
        if let arr = node.arrangement, let p = node.placement {
            menu.addItem(ClosureMenuItem("Take Off This Workspace", symbol: "xmark") { [weak self] in
                guard let self else { return }
                self.hosts.append(.remove(p), to: .block(arr))
                if self.hosts.arrangement(arr)?.isEmpty == true, self.hosts.arrangement(arr)?.isNamed == false { self.removeFromDesk(arr) }
            })
            menu.addItem(.separator())
        } else {
            menu.addItem(ClosureMenuItem("Go To", symbol: "arrow.right.circle") { [weak self] in self?.organizationOpen(node, newColumn: false) })
            menu.addItem(ClosureMenuItem("Bring Here", symbol: "arrow.down.to.line") { [weak self] in self?.organizationOpen(node, newColumn: true) })
            if let b = hosts.block(id), b.kind != .arrangement {
                menu.addItem(.separator())
                for item in keepingItems(for: b) { menu.addItem(item) }
            }
            menu.addItem(.separator())
        }
        menu.addItem(ClosureMenuItem("Links Around This", symbol: "point.3.connected.trianglepath.dotted") { [weak self] in
            self?.linksCenter = id
            self?.setOrganization(.links)
        })
        return menu
    }

    // MARK: Drops on the sidebar (§3.6)

    /// The block a dragged item stands for, and the placement to take
    /// away if it's a column's block being moved.
    private func dragged(_ item: OrgDragItem) -> (block: BlockID, from: (arrangement: BlockID, placement: Placement)?)? {
        switch item {
        case .block(let b): return (b, nil)
        case .arrangement(let a): return (a, nil)
        case .host: return nil
        case .placement(let p):
            for id in allWorkspaces {
                if let a = hosts.arrangement(id), let placed = a.placement(p) { return (placed.block, (id, placed)) }
            }
            return nil
        }
    }

    func organizationCanDrop(_ item: OrgDragItem, onto node: OrgNode?, at index: Int) -> Bool {
        // Hosts reordered among themselves, wherever they head the rows.
        if case .host = item { return (organization == .desk || organization == .files) && node == nil && index >= 0 }
        guard organization == .desk else { return false }
        switch item {
        case .host:
            return false
        case .arrangement(let a):
            // Reordered among the top-level rows, or among its host's.
            if let node { return node.id == "host:\(a.host.raw)" && index >= 0 }
            return index >= 0
        case .block, .placement:
            if let node { return node.arrangement != nil || node.id.hasPrefix("host:") }
            return index >= 0
        }
    }

    func organizationDrop(_ item: OrgDragItem, onto node: OrgNode?, at index: Int) -> Bool {
        if case .host(let h) = item {
            // Among the hosts as the sidebar shows them.
            var order = hosts.ordered.map(\.host)
            guard node == nil, let from = order.firstIndex(of: h) else { return false }
            order.remove(at: from)
            order.insert(h, at: min(from < index ? index - 1 : index, order.count))
            hosts.setHostOrder(order)
            return true
        }
        if case .arrangement(let a) = item {
            if let node {
                // Among its host's workspaces, which lead its rows.
                guard node.id == "host:\(a.host.raw)", let client = hosts.client(of: a),
                      let from = client.desk.order.firstIndex(of: a) else { return false }
                let to = min(from < index ? index - 1 : index, client.desk.order.count - 1)
                if to != from { sidebarMove(a, to: to) }
                return true
            }
            guard let from = allWorkspaces.firstIndex(of: a) else { return false }
            let to = from < index ? index - 1 : index
            if to != from { sidebarMove(a, to: to) }
            return true
        }
        guard let (block, from) = dragged(item), let b = hosts.block(block), b.kind != .arrangement else { return false }
        let lens = from?.placement.lens ?? Lens.default(for: b.kind, path: b.path)
        if let node, let arr = node.arrangement {
            // Onto a column: shown there; onto an arrangement: in its focused column.
            if let from, from.arrangement != arr { hosts.append(.remove(from.placement.id), to: .block(from.arrangement)) }
            let place: Where = node.column.map { .inColumn($0) } ?? .here
            show(block, lens: lens, place, in: arr)
            hosts.select(arr)
            return true
        }
        guard node == nil else { return false }
        // Between arrangements: one of its own there.
        if let from, hosts.arrangement(from.arrangement)?.placements.count == 1 {
            sidebarMove(from.arrangement, to: index)
            return true
        }
        if let from { hosts.append(.remove(from.placement.id), to: .block(from.arrangement)) }
        let n = host.newArrangement()
        show(block, lens: lens, .here, in: n)
        sidebarMove(n, to: index)
        hosts.select(n)
        return true
    }

    func organizationDragChanged(_ dragging: Bool) { sidebarDragChanged(dragging) }
}


/// The groups of the Status organization and the state views (§3.6).
enum StatusGroup: Int, CaseIterable {
    case needsYou, done, failed, working, inactive

    init(_ look: StatusGlyph.Look) {
        switch look {
        case .needsYou: self = .needsYou
        case .done: self = .done
        case .failed: self = .failed
        case .working: self = .working
        case .inactive, .connecting, .offline, .archived: self = .inactive
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

    var symbol: String {
        switch self {
        case .needsYou: "hand.raised"
        case .done: "checkmark.circle"
        case .failed: "exclamationmark.circle"
        case .working: "circle.dotted"
        case .inactive: "moon"
        }
    }
}

extension MainWindowController: OutlineLensViewDelegate {}
