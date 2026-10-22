import AppKit
import WebKit
import ManifoldCore
import UniformTypeIdentifiers

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
    /// The content area, which the grids are clipped to: a workspace
    /// sliding out (⌃⇥) leaves through its edge, never under the sidebar
    /// (which is translucent, and would show it).
    private let stage: NSView = {
        let v = NSView()
        v.wantsLayer = true
        v.layer?.masksToBounds = true
        return v
    }()
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
        stage.addSubview(content)
        root.addSubview(stage)
        root.addSubview(sidebar)
        root.addSubview(toast)
        root.onMouseMoved = { [weak self] p in self?.mouseMoved(to: p) }
        root.onMouseExitedWindow = { [weak self] in self?.scheduleHide() }
        root.onLayout = { [weak self] in
            self?.layoutViews()
            self?.layoutTrafficLights()
        }
        sidebar.delegate = self
        sidebar.organizationView.delegate = self
        // The finder's window made ahead, so the first ⌘O shows at once.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in _ = self?.finder }
        sidebar.organizationView.collapsedByHand = Set(hosts.state.collapsedRows)
        sidebar.organizationView.onCollapsedChanged = { [weak self] rows in self?.hosts.setCollapsedRows(rows) }
        for c in [content, outgoing] {
            c.delegate = self
            c.onHiding = { [weak self] view in self?.rememberPicture(of: view) }
        }
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
        HostMenu.submenu = { [weak self] host in self?.hostSubmenu(host) }
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
        hosts.onNotebookLive = { [weak self] block, cell, output in
            guard let self else { return }
            for case let n as NotebookView in self.views.values where n.block == block { n.live(cell: cell, output: output) }
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

    /// Each block's tile as last pictured, for its card while it's out of
    /// sight: taken as a tile is stacked, collapsed or maximized over, as
    /// its workspace is left, and whenever its card is shown.
    private var tilePictures: [BlockID: NSImage] = [:]

    /// Rendering now, and a render asked for meanwhile.
    private var rendering = false
    private var renderAgain = false

    /// Everything brought in line with the state. Asked for while it's
    /// under way — a view being made that tells of itself (an editor of a
    /// dirty text, set to viewing, says it's edited) — it's done once more
    /// right after, not inside itself: within, the view isn't kept yet,
    /// so it would be made again, and again, until the stack ran out.
    func render() {
        guard !rendering else {
            renderAgain = true
            return
        }
        rendering = true
        defer {
            // The keyboard kept from other apps while a focused terminal reads a password.
            SecureInput.shared.focused = focusedShown.flatMap { [.terminal, .agent].contains($0.lens) ? $0.placement.block : nil }
            rendering = false
            if renderAgain {
                renderAgain = false
                DispatchQueue.main.async { [weak self] in self?.render() }
            }
        }
        renderNow()
    }

    private func renderNow() {
        guard let window else { return }
        if FontTheme.current != hosts.state.appearance.theme {
            FontTheme.current = hosts.state.appearance.theme
            for case let v as FollowsFontTheme in views.values { v.fontThemeChanged() }
        }
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
        if stateAgents {
            // Every agent on every host: those that need you first, then
            // those at work, those done, those idle or ended.
            stateBlocks = agentBlocks().map { ($0, $0.statusRecord, $0.statusRecord?.at ?? $0.created) }
            stateMembers = stateBlocks.map(\.0.id)
        } else if stateGroup != nil || stateWorkspace != nil {
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
            // A card's lent view goes home before the workspace changes
            // under it (it may be one of the workspace coming in).
            HoverCard.shared.hide()
            // The workspace left: each tile it showed pictured, for its card.
            for v in content.views where v.superview != nil && !v.isHiddenOrHasHiddenAncestor { rememberPicture(of: v) }
            if let dir = pendingSlide, shownArrangement != nil, selected != nil { slide(from: dir) }
            shownArrangement = selected
        }
        pendingSlide = nil

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
            let codeFont = hosts.state.appearance.theme.font(.monospaced, size: 12.5)
            for case let o as OutputView in views.values { o.font = codeFont; o.refresh() }
            for case let n as NotebookView in views.values { n.codeFont = codeFont; n.documentChanged() }
            for case let d as DirectoryView in views.values { d.documentChanged() }
            for case let w as WebView in views.values { w.documentChanged() }
            for case let s as SearchView in views.values { s.codeFont = codeFont; s.documentChanged() }
            for case let g as GitView in views.values { g.documentChanged() }
            for case let m as MediaView in views.values { m.documentChanged() }
            for case let pv as ProcessView in views.values { pv.documentChanged() }
            for case let d as DiffView in views.values { d.documentChanged() }
        } else {
            content.clear()
            window.title = "Manifold"
        }
        if let stateView, stateGroup != nil || stateWorkspace != nil || stateAgents {
            let items = stateBlocks.map { block, _, _ -> StateView.Item in
                let lens = stateLenses[block.id] ?? Lens.default(for: block.kind, path: block.path)
                let p = Placement(id: Self.statePlacement(block.id), block: block.id, lens: lens)
                var shown = Shown(placement: p, block: block)
                if stateAgents { shown.caption = agentCaption(block) }
                return StateView.Item(shown: shown, view: view(for: shown))
            }
            let title = stateAgents ? "Agents" : stateGroup?.title ?? "Overview"
            stateView.show(items, title: title, mode: stateMode)
            window.title = title
        }
        noteSeen(force: false)
        noteEditing()
        checkOpenWaits()
        noteTrailFocus()
        attend()
        scheduleHoldReconcile()
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
    /// A workspace's name: the one given; else, by what it holds — the
    /// folder most of its blocks are at (with its repository's branch,
    /// when a git block is there), else the focused block's name.
    private func title(of a: ArrangementState) -> String {
        if a.isNamed { return a.title! }
        let blocks = a.placements.compactMap { hosts.block($0.block) }
        var places: [String: Int] = [:]
        for b in blocks { if let p = b.place, p.count > 1 { places[p, default: 0] += 1 } }
        if let place = places.max(by: { $0.value != $1.value ? $0.value < $1.value : $0.key.count > $1.key.count })?.key {
            var t = place.abbreviatingHome
            if let branch = blocks.first(where: { $0.kind == .git })?.git?.branch, !branch.isEmpty { t += " · " + branch }
            return t
        }
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
        var s = Shown(placement: p, block: hosts.block(p.block), offline: hosts.client(p.block.host) != nil && !hosts.isReachable(p.block.host))
        if let w = selected, p.block.host != w.host { s.foreignHost = hosts.label(of: p.block.host) }
        return s
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
        // A file shown is a file read: one whose text never came is asked
        // for until it does.
        if shown.block?.needsRead == true { hosts.ensureRead(p.block) }
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
            t.readingPassword = SecureInput.shared.reading.contains(p.block)
            t.setSidebar(viewState(of: p)["outline"] == "1")
            t.onToggleSidebar = { [weak self] shown in self?.keepViewState(["outline": shown ? "1" : "0"], of: p) }
            SecureInput.shared.onChange = { [weak self] block in
                for case let v as TerminalView in self?.views.values.map({ $0 }) ?? [] where v.block == block {
                    v.readingPassword = SecureInput.shared.reading.contains(block)
                }
            }
            if p.block.host != host.host {
                t.uploadDrop = { [weak self] urls, done in self?.upload(urls, toShellOf: p.block, done: done) }
            }
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
            v = pv
        case .outline:
            // The block's commands or headings, as a list beside it (§3.8).
            let tv = OutlineLensView(placement: p.id, block: p.block)
            tv.delegate = self
            let subject = p.block
            tv.subject = subject
            tv.source = { [weak self] in self?.hosts.block(subject) }
            v = tv
        case .preview where Lens.viewRendering(for: shown.path) == .markdown:
            let m = MarkdownView(placement: p.id, block: p.block, path: shown.path ?? "", theme: hosts.state.appearance.theme)
            m.imageSource = { [weak self] id in self?.imageSource(id) }
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
        case .notebook:
            let n = NotebookView(placement: p.id, block: p.block)
            n.delegate = self
            n.source = { [weak self] in self?.hosts.block(p.block) }
            n.codeFont = hosts.state.appearance.theme.font(.monospaced, size: 12.5)
            n.documentChanged()
            v = n
        case .output where shown.block?.output?.markdown != nil:
            // An agent's turn: its Markdown, rendered (links to what it changed live).
            let m = MarkdownView(placement: p.id, block: p.block, path: "", theme: hosts.state.appearance.theme)
            m.delegate = self
            m.imageSource = { [weak self] id in self?.imageSource(id) }
            m.source = { [weak self] in
                guard let md = self?.hosts.block(p.block)?.output?.markdown else { return nil }
                return (md, md.hashValue)
            }
            v = m
        case .output:
            let o = OutputView(placement: p.id, block: p.block)
            o.delegate = self
            o.source = { [weak self] in self?.hosts.block(p.block) }
            o.font = hosts.state.appearance.theme.font(.monospaced, size: 12.5)
            o.refresh()
            v = o
        case .diff:
            let d = DiffView(placement: p.id, block: p.block, theme: hosts.state.appearance.theme)
            d.delegate = self
            d.source = { [weak self] in self?.hosts.block(p.block) }
            v = d
        case .search:
            let s = SearchView(placement: p.id, block: p.block)
            s.delegate = self
            s.codeFont = hosts.state.appearance.theme.font(.monospaced, size: 12.5)
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
                return PillLook(title: b.displayTitle, symbol: Theme.symbolName(for: b.kind, path: b.path), status: StatusGlyph.look(of: b))
            }
            e.richMarkdown = viewState(of: p)["markdown"] != "raw"
            e.onToggleMarkdown = { [weak self] rich in self?.keepViewState(["markdown": rich ? "rich" : "raw"], of: p) }
            e.setSidebar(viewState(of: p)["outline"] == "1")
            e.onToggleSidebar = { [weak self] shown in self?.keepViewState(["outline": shown ? "1" : "0"], of: p) }
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
        let left = pinned ? w + inset : 0
        stage.frame = NSRect(x: left, y: 0, width: b.width - left, height: b.height)
        content.frame = stage.bounds
        stateView?.frame = stage.frame
        if sliding { outgoing.frame = stage.bounds }
        palette?.frame = b
        history?.frame = b
        if !toast.isHidden {
            let s = toast.wantedSize
            toast.frame = NSRect(x: stage.frame.minX + (stage.frame.width - s.width) / 2, y: 14, width: s.width, height: s.height).integral
        }
    }

    // MARK: Closing and keeping (§4)

    private var holdWork: DispatchWorkItem?

    /// Holds on other hosts (§4) brought in step with what this client's
    /// hosts refer to, a moment after things settle.
    private func scheduleHoldReconcile() {
        holdWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.hosts.reconcileHolds() }
        holdWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5, execute: work)
    }

    /// What was closed, latest last: a tile with where it was, or a
    /// workspace taken off the desk — ⇧⌘T brings the last one back.
    private enum Closed {
        case tile(workspace: BlockID, column: Int, index: Int, placement: Placement, height: Double?)
        case workspace(BlockID, index: Int)
    }
    private var closedStack: [Closed] = []
    private let toast = ToastView()
    /// Each folder tile's own history: the folders it showed before, and
    /// those gone back from.
    private var folderHistory: [PlacementID: (back: [BlockID], forward: [BlockID])] = [:]
    /// Other hosts' images shown in notes, as data the page can load.
    private var remoteImages: [BlockID: String] = [:]
    private var fetchingImages: Set<BlockID> = []
    /// Images kept this second, so two get names of their own.
    private var imageCount = 0 { didSet { if imageCount == 1 { DispatchQueue.main.asyncAfter(deadline: .now() + 1.1) { [weak self] in self?.imageCount = 0 } } } }

    /// A tile about to be taken off: remembered, so ⇧⌘T can put it back.
    private func noteClosing(_ placement: PlacementID, in workspace: BlockID) {
        guard let a = hosts.arrangement(workspace), let p = a.placement(placement), let (c, i) = a.locate(placement) else { return }
        closedStack.append(.tile(workspace: workspace, column: c, index: i, placement: p, height: a.heights[placement]))
        if closedStack.count > 100 { closedStack.removeFirst(closedStack.count - 100) }
    }

    /// After tiles were taken off: whatever was reached before and isn't
    /// now — the blocks closed, and everything only they reached through
    /// what they placed and linked — is on its way to collection. When
    /// that would lose something — a text edited and unsaved, a terminal
    /// with a job running — a toast names each, with Restore.
    private func afterClosing(reachedBefore before: Set<BlockID>) {
        let after = hosts.reachable()
        var lost: [String] = []
        for id in before.subtracting(after) {
            guard let b = hosts.block(id) else { continue }
            if b.kind == .text, b.text?.isDirty == true {
                lost.append("“\(b.displayTitle)” (unsaved edits)")
            } else if (b.kind == .terminal || b.kind == .agent), b.terminal?.busy == true {
                lost.append("“\(b.displayTitle)” (\(b.kind == .agent ? "agent running" : "job running"))")
            }
        }
        guard !lost.isEmpty else { return }
        lost.sort()
        let minutes = hosts.local.desk.settings.collectAfterMinutes
        let when = minutes > 0 ? "; gone in \(minutes) min" : ""
        let text = lost.count == 1 ? "Closed \(lost[0])\(when)" : "Closed \(lost.count) blocks with something to lose: \(lost.joined(separator: ", "))\(when)"
        toast.show(text, action: "Restore ⇧⌘T", for: 12) { [weak self] in self?.reopenClosed(nil) }
        layoutViews()
    }

    /// ⇧⌘T: the last thing closed, back where it was — a tile into its
    /// workspace at its old place (here, if that workspace is gone), a
    /// workspace onto the desk. What has been collected meanwhile is
    /// skipped.
    @objc func reopenClosed(_ sender: Any?) {
        toast.hide()
        while let last = closedStack.popLast() {
            switch last {
            case let .workspace(id, index):
                guard let client = hosts.client(of: id), client.block(id)?.arrangement != nil else { continue }
                var order = client.desk.order
                guard !order.contains(id) else { continue }
                order.insert(id, at: min(index, order.count))
                client.setWorkspaceOrder(order)
                hosts.select(id)
                return
            case let .tile(workspace, column, index, placement, height):
                guard let b = hosts.block(placement.block) else { continue }
                let fresh = Placement(id: ULID.make(), block: placement.block, lens: placement.lens)
                if let a = hosts.arrangement(workspace), allWorkspaces.contains(workspace) {
                    let c = min(column, max(a.columns.count - 1, 0))
                    let i = a.columns.isEmpty ? 0 : min(index, a.columns[c].count)
                    var events: [Event] = [.place(fresh, column: c, at: i)]
                    if let height { events.append(.heights([fresh.id: height])) }
                    events.append(.focus(fresh.id))
                    hosts.select(workspace)
                    hosts.append(events, to: .block(workspace))
                } else {
                    show(placement.block, lens: Lens.default(for: b.kind, path: b.path), .here)
                }
                warpPointerToFocus()
                return
            }
        }
        NSSound.beep()
    }

    /// Debugging: what was closed, latest last; then every block that
    /// exists and nothing reaches.
    var debugClosed: String {
        let reachable = hosts.reachable()
        let stack = closedStack.map { c -> String in
            switch c {
            case let .tile(w, col, i, p, _): "tile \(hosts.block(p.block)?.displayTitle ?? "?") in \(hosts.arrangement(w).map(title(of:)) ?? "?") col \(col) at \(i)"
            case let .workspace(id, i): "workspace \(hosts.arrangement(id).map(title(of:)) ?? "?") at \(i)"
            }
        }
        let unreached = hosts.blocks.filter { !reachable.contains($0.id) }.map { "\($0.kind) \($0.displayTitle) \($0.id)" }
        return "closed:\n" + stack.joined(separator: "\n") + "\nroots \(hosts.roots().count) reachable \(reachable.count) blocks \(hosts.blocks.count)\nunreached:\n" + unreached.joined(separator: "\n")
    }

    var debugToast: String { toast.debugText ?? "none" }

    /// A word at the window's foot, with a button.
    func notice(_ text: String, action: String, _ act: @escaping () -> Void) {
        toast.show(text, action: action, for: 12, act)
    }

    /// Pin or Unpin: the focused block made a root of its own (§4), kept
    /// whatever refers to it.
    @objc func togglePin(_ sender: Any?) {
        guard let b = focusedShown?.block else { return NSSound.beep() }
        hosts.pin(b.id, !b.isPinned)
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

    /// The Inbox's blocks in its order: by host, by the workspace that
    /// holds each, newest first.
    func inboxOrder() -> [BlockID] {
        func leaves(_ nodes: [OrgNode]) -> [BlockID] {
            nodes.flatMap { n -> [BlockID] in n.isGroup ? leaves(n.children) : (n.block.map { [$0] } ?? []) }
        }
        return leaves(inboxTree("").0)
    }

    /// The Inbox as last gone through with ⌘J, to find what comes after a
    /// block that has left it (attended to on the way).
    private var inboxWalk: [BlockID] = []

    /// ⌘J: to the next block in the Inbox — after the focused one, else the
    /// first — warped to as a click in the sidebar goes, and attended to.
    @objc func nextInInbox(_ sender: Any?) {
        let order = inboxOrder()
        guard !order.isEmpty else {
            inboxWalk = []
            return NSSound.beep()
        }
        let here = focusedShown?.placement.block
        var next = order[0]
        if let here, let i = order.firstIndex(of: here) {
            if order.count == 1 { next = here } else { next = order[(i + 1) % order.count] }
        } else if let here, let was = inboxWalk.firstIndex(of: here),
                  let after = inboxWalk[(was + 1)...].first(where: { order.contains($0) }) {
            // The focused block has left the Inbox: what came after it then.
            next = after
        }
        inboxWalk = order
        goTo(next)
        hosts.propose(.attend(next))
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

    /// ⇧⌘W: the focused block kept and closed (§4) — a root of its own,
    /// off every workspace, under Kept in the sidebar until recalled.
    @objc func keepAndClose(_ sender: Any?) {
        guard let b = focusedShown?.block else { return NSSound.beep() }
        hosts.pin(b.id, true)
        withdraw(b.id)
    }

    /// The menu's verbs for a block's keeping: kept, or let go; kept and
    /// closed.
    private func keepingItems(for b: Block) -> [NSMenuItem] {
        var items = [ClosureMenuItem(b.isPinned ? "Let Go" : "Keep", symbol: b.isPinned ? "pin.slash" : "pin") { [weak self] in
            self?.hosts.pin(b.id, !b.isPinned)
        }]
        if !b.isPinned {
            items.append(ClosureMenuItem("Keep and Close", symbol: "pin", key: "W") { [weak self] in
                self?.hosts.pin(b.id, true)
                self?.withdraw(b.id)
            })
        }
        return items
    }

    private func terminalEnded(_ block: BlockID) { withdraw(block) }

    /// A block's tiles taken off every workspace (its shell ended, or it
    /// was kept and closed); an unnamed workspace left empty goes too.
    private func withdraw(_ block: BlockID) {
        for id in allWorkspaces {
            guard let a = hosts.arrangement(id) else { continue }
            for p in a.placements(of: block) { hosts.append(.remove(p.id), to: .block(id)) }
        }
        if let a = arrangement, a.isEmpty, let id = selected, !a.isNamed {
            hosts.client(of: id)?.removeWorkspace(id)
            hosts.select(allWorkspaces.first { $0 != id })
        }
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
        root.addSubview(sidebar, positioned: .above, relativeTo: stage)
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
    /// Debugging: the focused tile's pill menu, or the item so titled chosen.
    func debugPillMenu(_ title: String) -> String {
        guard let f = focusedShown, let menu = gridPillMenu(for: f.id) else { return "no menu" }
        if title.isEmpty {
            return menu.items.flatMap { i -> [String] in
                [i.isSeparatorItem ? "---" : i.title] + (i.submenu?.items.map { "  " + $0.title + ($0.isEnabled ? "" : " (off)") } ?? [])
            }.joined(separator: "\n")
        }
        guard let item = menu.items.first(where: { $0.title == title }) as? ClosureMenuItem else { return "no such item" }
        item.debugRun()
        return "chose \(title)"
    }

    /// Whether a block is in sight: Manifold in front, its window shown,
    /// and a tile of it showing in the workspace (not stashed, not behind
    /// a maximized one).
    func inSight(_ block: BlockID) -> Bool {
        guard NSApp.isActive, let window, window.isVisible, !window.isMiniaturized, stateView == nil, let a = arrangement else { return false }
        return a.placements(of: block).contains { !a.isStashed($0.id) && (a.full == nil || a.full == $0.id) }
    }

    /// A notification clicked: to the block, and the command if one.
    func openFromNotification(_ block: BlockID, command: Int?) {
        NSApp.activate()
        window?.makeKeyAndOrderFront(nil)
        goTo(block)
        if let command { goToCommand(command, in: block) }
    }

    /// Paths from outside (the Dock icon, Open With): each opened in the
    /// workspace shown, from the focused tile, as a path clicked there is.
    func openPaths(_ paths: [String]) {
        // They're this Mac's: from the focused tile only if it's here too.
        let from = arrangement?.focused.flatMap { f in shown(f)?.placement.block.host == host.host ? f : nil }
        for path in paths { open(path, from: from, here: false, over: false) }
    }

    /// Debugging: "host path d|f" as if a folder's entry were dropped
    /// at the end of the first column.
    func debugGridPath(_ arg: String) -> String {
        let f = arg.split(separator: " ").map(String.init)
        guard f.count == 3 else { return "usage: gridpath <host> <path> d|f" }
        gridOpenPaths([(HostID(f[0]), f[1], f[2] == "d")], column: 0, at: 99, newColumn: false)
        return "opened"
    }

    func debugOpenPaths(_ arg: String) -> String {
        openPaths(arg.split(separator: " ").map(String.init))
        return "opened"
    }

    /// The Dock icon's menu: every workspace on the desk, under its host's
    /// name when there's more than one, the one shown checked; chosen, it's
    /// gone to, Manifold coming to the front.
    func dockMenu() -> NSMenu {
        let menu = NSMenu()
        let byHost = hosts.ordered.map { c in (c, c.desk.order.filter { $0.host == c.host }.filter { hosts.arrangement($0) != nil }) }.filter { !$0.1.isEmpty }
        // Titles alike (a few workspaces in ~) told apart by what's focused in each.
        var seen: [String: Int] = [:]
        for id in byHost.flatMap(\.1) { if let a = hosts.arrangement(id) { seen[title(of: a), default: 0] += 1 } }
        func name(_ a: ArrangementState) -> String {
            let t = title(of: a)
            guard seen[t, default: 0] > 1, let f = a.focusedPlacement, let b = hosts.block(f.block), b.displayTitle != t else { return t }
            return "\(t) — \(b.displayTitle)"
        }
        for (c, ids) in byHost {
            if byHost.count > 1 {
                if menu.numberOfItems > 0 { menu.addItem(.separator()) }
                menu.addItem(NSMenuItem.sectionHeader(title: hosts.label(of: c.host)))
            }
            for id in ids {
                guard let a = hosts.arrangement(id) else { continue }
                let item = NSMenuItem(title: name(a), action: #selector(dockChoose(_:)), keyEquivalent: "")
                item.target = self
                item.representedObject = id
                item.state = id == selected ? .on : .off
                menu.addItem(item)
            }
        }
        return menu
    }

    @objc private func dockChoose(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? BlockID else { return }
        NSApp.activate()
        window?.makeKeyAndOrderFront(nil)
        goTo(id)
    }

    /// Debugging: the Dock menu's items, or the one titled so chosen.
    func debugDockMenu(_ title: String) -> String {
        let menu = dockMenu()
        if !title.isEmpty {
            guard let item = menu.items.first(where: { $0.title == title && $0.action != nil }) else { return "no \(title)" }
            dockChoose(item)
            return "chose \(title)"
        }
        return menu.items.map { $0.isSeparatorItem ? "—" : $0.isSectionHeader ? "[\($0.title)]" : ($0.state == .on ? "✓ " : "  ") + $0.title }.joined(separator: "\n")
    }

    /// Debugging: every workspace on the desk, its tiles' placements and titles.
    func debugWorkspaces() -> String {
        allWorkspaces.compactMap { id -> String? in
            guard let a = hosts.arrangement(id) else { return nil }
            let tiles = a.columns.map { col in col.map { "\($0.id)=\(hosts.block($0.block)?.displayTitle ?? "?")" }.joined(separator: ", ") }
            return "\(id == selected ? "*" : " ")\(id) \(title(of: a)): " + tiles.map { "[\($0)]" }.joined(separator: " ")
        }.joined(separator: "\n")
    }

    /// Debugging: a tile dropped on a workspace's row in the sidebar (or
    /// between the rows, "new"), moved or copied.
    func debugBlockDrop(_ placement: PlacementID, onto arrangement: BlockID?, copy: Bool) -> String {
        let node = arrangement.map { a -> OrgNode in
            let n = OrgNode(id: "ws:\(a)", block: a, title: "", symbol: "")
            n.arrangement = a
            return n
        }
        let item = OrgDragItem.placement(placement)
        guard organizationCanDrop(item, onto: node, at: node == nil ? 0 : -1) else { return "refused" }
        return organizationDrop(item, onto: node, at: node == nil ? 0 : -1, copy: copy) ? "ok" : "failed"
    }

    /// Debugging: a tile from another workspace dropped in this one's grid.
    func debugGridDrop(_ placement: PlacementID, column: Int, at: Int, copy: Bool) -> String {
        bringFromElsewhere(placement, column: column, at: at, newColumn: false, copy: copy)
        return "ok"
    }

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
            if view is ScrubberView || view is ScrubTip || view is LinkBadge || view is StackSwitcherView || view is OrganizationView { view.mouseMoved(with: event); break }
            if let badge = view.superview as? LinkBadge { badge.mouseMoved(with: event); break }
            v = view.superview
        }
    }

    var debugSidebarView: SidebarView { sidebar }
    /// Debugging: the output tiles, as shown; "raw", what each holds,
    /// escaped; "copy" and "back", the focused one's buttons pressed.
    /// Debugging: the focused search's preview; "searchpreview <n>", the nth hit chosen.
    func debugSearchPreview(_ arg: String) -> String {
        guard let s = arrangement?.focused.flatMap({ views[$0] as? SearchView }) else { return "no search focused" }
        return s.debugPreview(arg)
    }

    /// Debugging: the focused notebook, told `arg` (see NotebookView.debug).
    func debugNotebook(_ arg: String) -> String {
        guard let n = arrangement?.focused.flatMap({ views[$0] as? NotebookView }) else { return "no notebook focused" }
        return n.debug(arg)
    }

    /// Debugging: the focused folder view, told `arg` (see DirectoryView.debug).
    /// Debugging: the focused tile's own sidebar — "toggle", "pick N",
    /// or nothing: what it lists. "pdf …": the focused PDF's controls.
    func debugTileSidebar(_ arg: String) -> String {
        guard let f = arrangement?.focused, let v = views[f] else { return "nothing focused" }
        if arg.hasPrefix("pdf") { return (v as? MediaView)?.debugPDF(String(arg.dropFirst(3)).trimmingCharacters(in: .whitespaces)) ?? "no PDF focused" }
        if arg == "toggle" { toggleTileSidebar(nil) }
        let pick = arg.hasPrefix("pick ") ? Int(arg.dropFirst(5)) : nil
        switch v {
        case let e as EditorView:
            if let pick { _ = e.debugSidebarPick(pick) }
            return e.debugSidebar
        case let m as MarkdownView:
            if let pick { _ = m.debugSidebarPick(pick) }
            return m.debugSidebar
        case let p as MediaView:
            return p.debugPDF(pick.map { "pick \($0)" } ?? "")
        case let d as DiffView:
            return d.debugSidebar
        case let t as TerminalView:
            if let pick { _ = t.debugSidebarPick(pick) }
            return t.debugSidebar
        case let w as WebView:
            return w.debugSidebar
        default:
            return "no sidebar here"
        }
    }

    func debugDirectory(_ arg: String) -> String {
        guard let d = arrangement?.focused.flatMap({ views[$0] as? DirectoryView }) else { return "no folder focused" }
        return d.debug(arg)
    }

    func debugOutputs(_ verb: String) -> String {
        let focused = arrangement?.focused.flatMap { views[$0] as? OutputView }
        if verb == "copy" { return focused?.debugCopy() ?? "no output focused" }
        if verb == "back" { focused?.debugBack(); return focused == nil ? "no output focused" : "ok" }
        if verb.hasPrefix("find ") { return focused?.debugFind(String(verb.dropFirst(5))) ?? "no output focused" }
        return views.values.compactMap { v -> String? in
            guard let o = v as? OutputView else { return nil }
            guard verb == "raw" else { return o.debugDescription_ }
            return hosts.block(o.block)?.output.map { $0.line + ": " + $0.output.debugDescription } ?? "?"
        }.joined(separator: "\n---\n")
    }
    /// The outline lens made last (placement ids sort by time).
    var debugOutlineLens: OutlineLensView? { content.views.compactMap { $0 as? OutlineLensView }.max { $0.placement < $1.placement } }
    var debugFocusedTerminal: TerminalView? { arrangement?.focused.flatMap { views[$0] as? TerminalView } }
    var debugFocusedEditor: EditorView? { arrangement?.focused.flatMap { views[$0] as? EditorView } }

    func debugSidebar(show: Bool) {
        if show { showSidebar(animated: false) } else { hideWork?.cancel(); hideSidebar() }
    }

    var debugPills: String { content.debugPills }
    var debugDirty: String { content.debugDirty }
    func debugPushDown(column: Int, row: Int) -> String { content.debugPushDown(column: column, row: row) }
    func debugDirtyClick() -> String {
        guard let f = focusedShown, let t = hosts.block(f.placement.block)?.text, t.isDirty else { return "nothing dirty focused" }
        save(f.placement.block, from: f.id)
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

    func debugFocus(placementEndingIn suffix: String) -> Bool {
        guard let p = arrangement?.placements.first(where: { $0.id.hasSuffix(suffix) }) else { return false }
        gridFocus(p.id)
        return true
    }

    func debugStack(swap: Bool, index: Int = 0) -> String {
        guard let a = arrangement, let f = a.focused, let (c, _) = a.locate(f) else { return "nothing focused" }
        // The stack as the fan shows it: those stashed above the first
        // shown tile count as behind it, then those under the tile.
        let behind = a.columns[c].filter { a.isStashed($0.id) && a.tile(behind: $0.id)?.id == f }
        if swap, index >= 0, index < behind.count { gridSwap(behind[index].id) }
        if swap, index < 0 { gridSwapNext(f) }
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
        items.append(PaletteItem(symbol: "text.and.command.macwindow", title: "New Shell Notebook", subtitle: "⌃⇧⌘N") { [weak self] in
            self?.newShellNotebook(nil)
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
            if client.isRemote {
                items.append(PaletteItem(symbol: "arrow.triangle.2.circlepath", title: "Reset Server on \(hosts.label(of: h))…", subtitle: "reinstall, restart") { [weak self] in
                    self?.resetServer(h)
                })
            }
            items.append(PaletteItem(symbol: "server.rack", title: "Detach from \(hosts.label(of: h))…", subtitle: state) { [weak self] in
                self?.detach(h)
            })
        }
        for client in hosts.all where client.isConnected {
            let h = client.host
            items.append(PaletteItem(symbol: "point.3.connected.trianglepath.dotted", title: "Reset Graph on \(hosts.label(of: h))…", subtitle: "forget links and trail") { [weak self] in
                self?.resetGraph(h)
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

    /// ⌘T: the one box (§3.5) — the finder, where the verbs (new terminal,
    /// new note, attach…) are found by name beside the blocks. With
    /// nothing on the desk, the palette of verbs alone.
    @objc func newTab(_ sender: Any?) {
        if allWorkspaces.isEmpty { showPalette() } else { showGraphFinder() }
    }

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
    /// A shell notebook (§7.7) on the focused block's host, its shell
    /// started where that block is, placed here.
    @objc func newShellNotebook(_ sender: Any?) {
        let client = hosts.client(focusedHost) ?? host
        let id = BlockID(host: client.host)
        client.propose(.newNotebook(block: id, cwd: focusedCwd))
        showWhenMade(id, lens: .notebook, place: .here)
    }

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
                cards.append(LinkCard(link: e.id, block: e.to, title: Self.linkTitle(b), symbol: Theme.symbolName(for: b.kind, path: b.path), outbound: true))
            }
        }
        for c in hosts.all {
            for e in c.node.graph.edges(to: block, kind: .link(.linked)) where e.isLive {
                guard seen.insert(e.from).inserted, let b = hosts.block(e.from) else { continue }
                cards.append(LinkCard(link: e.id, block: e.from, title: Self.linkTitle(b), symbol: Theme.symbolName(for: b.kind, path: b.path), outbound: false))
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


    /// Saves a text block: through an editor on it (this tile's first),
    /// which keeps its own count of what's saved and names a note's file;
    /// else straight to its file.
    private func save(_ block: BlockID, from placement: PlacementID) {
        let editors = views.values.compactMap { $0 as? EditorView }.filter { $0.block == block }
        if let e = editors.first(where: { $0.placement == placement }) ?? editors.first { return e.saveDocument(nil) }
        guard let b = hosts.block(block), b.path != nil, !b.needsRead, let t = b.text else { return NSSound.beep() }
        hosts.propose(.writeFile(block, version: t.version, text: t.text.string))
    }

    /// The bar's ×: the tile taken off, as ⌘W takes the focused one.
    func gridClose(_ placement: PlacementID) {
        guard let a = arrangement, let id = selected, let block = a.placement(placement)?.block else { return }
        let before = hosts.reachable()
        noteClosing(placement, in: id)
        hosts.append([.remove(placement)], to: .block(id))
        if hosts.arrangement(id)?.isEmpty == true, !a.isNamed { removeFromDesk(id) }
        afterClosing(reachedBefore: before)
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
        let before = hosts.reachable()
        if let f = a.focused {
            // Taken off, a tile's room goes to the first of the stack
            // behind it, if there is one, which comes back where it was
            // and takes the focus (the model's doing); else to the next.
            let block = a.placement(f)?.block
            noteClosing(f, in: id)
            hosts.append([.remove(f)], to: .block(id))
        }
        if hosts.arrangement(id)?.isEmpty == true, !a.isNamed {
            removeFromDesk(id)
        }
        afterClosing(reachedBefore: before)
    }

    /// ⇧⌘W: the arrangement leaves the desk.
    @objc func closeTab(_ sender: Any?) {
        guard let id = selected else { return }
        let before = hosts.reachable()
        removeFromDesk(id)
        afterClosing(reachedBefore: before)
    }

    /// Every workspace on every host, in the sidebar's order.
    private var allWorkspaces: [BlockID] { hosts.all.flatMap { $0.desk.order } }

    private func removeFromDesk(_ id: BlockID) {
        let all = allWorkspaces
        guard let i = all.firstIndex(of: id) else { return }
        // Remembered for ⇧⌘T: the workspace, if it holds anything; else
        // its own blocks were noted as they went.
        if let client = hosts.client(of: id), let a = client.arrangement(id), !a.isEmpty,
           let j = client.desk.order.firstIndex(of: id) {
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
    func hostItems(_ host: HostID) -> [NSMenuItem] {
        let label = hosts.label(of: host)
        var items: [NSMenuItem] = []
        if let c = hosts.client(host), c.isRemote {
            // Its ports brought here: one asked for, those forwarded (each stopped).
            let fwd = ClosureMenuItem("Forward a Port from \(label)…", symbol: "arrow.left.arrow.right") { [weak self] in self?.askForwardPort(host) }
            fwd.isEnabled = c.isConnected
            items.append(fwd)
            for f in c.forwards.forwards.values.sorted(by: { $0.remote < $1.remote }) {
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
            items.append(ClosureMenuItem("Reset Server on \(label)…", symbol: "arrow.triangle.2.circlepath") { [weak self] in self?.resetServer(host) })
        }
        let graph = ClosureMenuItem("Reset Graph on \(label)…", symbol: "point.3.connected.trianglepath.dotted") { [weak self] in self?.resetGraph(host) }
        graph.isEnabled = hosts.client(host)?.isConnected == true
        items.append(graph)
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
        c.forwards.forward(port) { [weak self] local in
            guard let self else { return }
            if let local {
                let same = local == port ? "" : " (\(port) is taken here)"
                self.toast.show("\(self.hosts.label(of: h)):\(port) forwarded to localhost:\(local)\(same)", action: "Stop", for: 6) { c.forwards.stop(port) }
            } else {
                self.toast.show("Couldn't forward \(port) from \(self.hosts.label(of: h))", action: "OK", for: 8) {}
            }
            done(local)
        }
    }

    /// Resets a host's graph, once asked: every link and the trail gone.
    private func resetGraph(_ host: HostID) {
        let alert = NSAlert()
        alert.messageText = "Reset the graph on \(hosts.label(of: host))?"
        alert.informativeText = "Every link between the host's blocks is forgotten — opened from, found by, mentions, compared, made by hand — and the trail of where you went, before and after. What's on each workspace stays. This can't be undone."
        alert.addButton(withTitle: "Reset")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        hosts.resetGraph(on: host) { [weak self] error in
            if let error { NSLog("reset graph on %@: %@", host.raw, error) }
            self?.refreshOrganization(now: true)
        }
    }

    /// Resets a host's server, once asked: put there afresh and restarted.
    private func resetServer(_ host: HostID) {
        let alert = NSAlert()
        alert.messageText = "Reset the server on \(hosts.label(of: host))?"
        alert.informativeText = "Manifold installs its server there again, whatever is there now, and restarts it. Every shell on the host ends; its terminals start new ones, each in its folder. Blocks and workspaces stay."
        alert.addButton(withTitle: "Reset")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        hosts.resetServer(host)
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
        case #selector(nextInInbox(_:)):
            return !inboxOrder().isEmpty
        case #selector(printTile(_:)):
            return arrangement?.focused.flatMap { views[$0] } is Printable
        case #selector(toggleTileSidebar(_:)):
            guard let v = arrangement?.focused.flatMap({ views[$0] }), v.hasSidebar else { item.title = "Show Outline"; return false }
            item.title = v.sidebarShown ? "Hide Outline" : "Show Outline"
            return true
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
            for id in hosts.recentWorkspaces() + allWorkspaces where live.contains(id) && !order.contains(id) { order.append(id) }
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
        if !settling, let home = w.ids.first {
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
        stage.addSubview(content, positioned: .above, relativeTo: outgoing)
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

    /// Going to a tile of the workspace shown (⌘\'s outline): revealed —
    /// to the top of its stack, if it's in one — grown a little if it's
    /// down to its bar, and the pointer on it.
    func arrive(atTile placement: PlacementID) {
        guard let a = arrangement, a.placement(placement) != nil else { return }
        appendToSelected(arriving(placement, in: a))
        warpPointerToFocus()
    }

    /// Arriving at a tile (a link followed, a block gone to, a step back,
    /// a row of the sidebar): revealed, and grown if it's down to its bar.
    private func arriving(_ placement: PlacementID, in a: ArrangementState) -> [Event] {
        showingSome(a.revealing(placement), in: a)
    }

    /// How much of a tile to show, grown to it: a glimpse, for a tile
    /// gone to (as apex does for a window it goes to); more, for a stack
    /// about to fan out, so the cards have room to hang.
    enum Reveal {
        case glimpse, fan

        /// Its content's height, at most and as a part of the column.
        var points: CGFloat { self == .glimpse ? 160 : 320 }
        var share: CGFloat { self == .glimpse ? 1 / 4 : 1 / 2 }
    }

    /// Events that leave a tile focused (or `placement`), with that tile
    /// grown to `reveal` if it's short of it — for a glimpse, only one
    /// collapsed to its bar (a pill, less than a line of it showing) —
    /// taken from its neighbours as growing takes it.
    private func showingSome(_ events: [Event], in a: ArrangementState, placement: PlacementID? = nil, _ reveal: Reveal = .glimpse) -> [Event] {
        var after = a
        for e in events { after.apply(e) }
        guard let f = placement ?? after.focused, after.full == nil, !after.isStashed(f), let (c, _) = after.locate(f) else { return events }
        let shown = after.shownTiles(inColumn: c)
        guard shown.count > 1 else { return events }
        let sum = shown.reduce(0.0) { $0 + after.height(of: $1.id) }
        let usable = content.bounds.height - 2 * GridView.inset - CGFloat(shown.count - 1) * GridView.gap
        guard sum > 0, usable > 0 else { return events }
        let share = after.height(of: f) / sum
        let body = usable * CGFloat(share) - GridView.barHeight
        let target = min(reveal.points, usable * reveal.share)
        guard reveal == .glimpse ? body < 20 : body < target - 1 else { return events }
        let want = Double((target + GridView.barHeight) / usable)
        return events + after.growing(f, step: (want - share) * sum)
    }

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

    var organization: Organization {
        Organization(rawValue: hosts.state.window.organization ?? "") ?? .desk
    }

    @objc func organizeByDesk(_ sender: Any?) { setOrganization(.desk) }
    @objc func organizeByFiles(_ sender: Any?) { setOrganization(.files) }
    @objc func organizeByInbox(_ sender: Any?) { setOrganization(.inbox) }
    @objc func searchBlocks(_ sender: Any?) { setOrganization(organization == .search ? .desk : .search) }

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
            let reachable = self.hosts.reachable()
            self.sidebar.setFoot(kept: self.hosts.all.reduce(0) { $0 + self.keptItems(on: $1).count },
                                 closed: self.hosts.all.reduce(0) { $0 + self.closedItems(on: $1, reachable: reachable).count })
            // Flat, with sections, where rows are blocks by place or state;
            // a tree with chevrons where the nesting is the point (folders, links).
            self.sidebar.organizationView.flat = true
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
            for b in c.node.blocks {
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
            let blocks = c.node.blocks.filter { $0.needsAttention && matches(filter, [$0.displayTitle, $0.path, $0.statusRecord?.msg, $0.statusRecord?.app]) }
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

    // MARK: State views (§3.6)

    /// An ⌥-click walk through a stack (gridSwapNext): the stack's order
    /// when it began, and where it has come to.
    var stackWalk: (workspace: BlockID?, order: [PlacementID], index: Int, monitor: Any?)?
    /// Debugging: ⌥ taken as held for a stack walk, or let go.
    var debugOptionHeld = false {
        didSet { if !debugOptionHeld { endOptionWalk() } }
    }
    private var stateView: StateView?
    private var stateGroup: StatusGroup?
    private var stateMode: StateView.Mode = .list

    /// The surface shows a status group's blocks themselves, live.
    /// ⌘': every block in the workspace at once, as Mission Control shows
    /// windows; again, or ⎋, back to the workspace.
    @objc func showWorkspaceOverview(_ sender: Any?) {
        guard let id = selected, hosts.arrangement(id) != nil else { return NSSound.beep() }
        if stateWorkspace == id { return hideStateView() }
        stateAgents = false
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
        stateAgents = false
        presentStateView()
    }

    /// The agents' view, up.
    private var stateAgents = false

    /// Window ▸ Agents (⌃⌘A): every agent on every host at once, live, as
    /// a list or an overview — those that need you first — each bar saying
    /// what it's on, for how long, and what it has changed; clicked, gone
    /// to. Again, or ⎋, back.
    @objc func showAgents(_ sender: Any?) {
        if stateAgents { return hideStateView() }
        stateGroup = nil
        stateWorkspace = nil
        stateAgents = true
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
            root.addSubview(v, positioned: .above, relativeTo: stage)
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
        stateAgents = false
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
        case .inbox: return inboxTree(filter)
        case .kept: return keptTree(filter)
        case .closed: return closedTree(filter)
        case .search: return searchTree(filter)
        }
    }

    /// Search (§3.6): the words typed, in the contents of every block on
    /// every host — a text's lines, a terminal's commands, a page's title
    /// and address, a block's own name and place — each block a row with
    /// what matched under it, clicked to go there (a line in its editor,
    /// a command in its terminal).
    private func searchTree(_ query: String) -> ([OrgNode], Set<String>) {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else {
            sidebar.setPushedSubtitle("The contents of every block")
            return ([OrgNode(id: "search:hint", title: "Type to search every block", symbol: "text.magnifyingglass")], [])
        }
        let reachable = hosts.reachable()
        var open: Set<String> = []
        var rows: [(rank: Int, seen: Int64, node: OrgNode)] = []
        var lines = 0
        func snippet(_ s: Substring) -> String {
            // A Markdown link as its words, as the page shows it.
            let t = s.trimmingCharacters(in: .whitespaces)
                .replacingOccurrences(of: #"\[([^\]]*)\]\([^)]*\)"#, with: "$1", options: .regularExpression)
            guard let r = t.lowercased().range(of: q), t.count > 90 else { return t }
            let start = t.distance(from: t.startIndex, to: r.lowerBound)
            return (start > 30 ? "…" : "") + String(t.dropFirst(max(0, start - 30)).prefix(90))
        }
        for c in hosts.all {
            for b in c.node.blocks where b.kind != .arrangement && reachable.contains(b.id) {
                var hits: [OrgNode] = []
                let id = b.id
                let prefix = "search/\(id)"
                // A text's lines; an output's, its escapes taken out.
                let notebookText = b.notebook.map { nb in nb.cells.map { "$ " + $0.source + "\n" + ($0.output ?? "") }.joined(separator: "\n") }
                let searched = b.text?.text.string ?? notebookText.map { $0
                        .replacingOccurrences(of: "\u{1b}\\][^\u{07}\u{1b}]*(\u{07}|\u{1b}\\\\)", with: "", options: .regularExpression)
                        .replacingOccurrences(of: "\u{1b}\\[[0-9;?]*[ -/]*[@-~]", with: "", options: .regularExpression)
                } ?? b.output.map { o in
                    o.plain ? o.output : o.output
                        .replacingOccurrences(of: "\u{1b}\\][^\u{07}\u{1b}]*(\u{07}|\u{1b}\\\\)", with: "", options: .regularExpression)
                        .replacingOccurrences(of: "\u{1b}\\[[0-9;?]*[ -/]*[@-~]", with: "", options: .regularExpression)
                }
                if let text = searched {
                    var n = 0
                    for raw in text.split(separator: "\n", omittingEmptySubsequences: false) {
                        n += 1
                        guard hits.count < 40, raw.lowercased().contains(q) else { continue }
                        let line = n
                        let hit = OrgNode(id: "\(prefix)/\(line)", title: snippet(raw), symbol: "text.alignleft", detail: "line \(line)")
                        hit.action = b.kind == .output || b.kind == .notebook ? { [weak self] in self?.goTo(id) } : { [weak self] in self?.goToLine(line, in: id) }
                        hits.append(hit)
                    }
                }
                for cmd in b.terminal?.commands ?? [] where hits.count < 40 && cmd.text.lowercased().contains(q) {
                    let cid = cmd.id
                    let hit = OrgNode(id: "\(prefix)/cmd\(cid)", title: "$ " + snippet(Substring(cmd.text)), symbol: "text.alignleft",
                                      detail: cmd.status.map { $0 == 0 ? "ok" : "exit \($0)" } ?? "running")
                    hit.trailing = Age.short(cmd.at)
                    hit.action = { [weak self] in
                        self?.goTo(id)
                        self?.goToCommand(cid, in: id)
                    }
                    hits.append(hit)
                }
                let named = [b.displayTitle, b.path, b.place, b.web?.url].compactMap { $0 }.contains { $0.lowercased().contains(q) }
                guard named || !hits.isEmpty else { continue }
                lines += hits.count
                let n = node(for: b, id: prefix, detail: b.place?.abbreviatingHome ?? b.web?.url ?? "")
                n.isGroup = !hits.isEmpty
                n.style = .row
                n.loadChildren = nil
                let group = OrgNode(id: prefix, block: b.id, title: n.title, symbol: n.symbol, detail: n.detail, count: hits.isEmpty ? nil : hits.count,
                                    isGroup: !hits.isEmpty, children: hits)
                group.look = n.look
                group.tooltip = n.tooltip
                if !hits.isEmpty { open.insert(prefix) }
                // Named by it first, then by how many lines say it, then the latest seen.
                let rank = (named ? 1000 : 0) + min(hits.count, 999)
                rows.append((rank, c.node.graph.seen(b.id)?.wall ?? 0, group))
            }
        }
        rows.sort { $0.rank != $1.rank ? $0.rank > $1.rank : $0.seen > $1.seen }
        let blocks = rows.count
        sidebar.setPushedSubtitle(blocks == 0 ? "Nothing found" : "\(blocks) block\(blocks == 1 ? "" : "s")" + (lines > 0 ? ", \(lines) line\(lines == 1 ? "" : "s")" : ""))
        if rows.isEmpty { return ([OrgNode(id: "search:none", title: "Nothing found", symbol: "circle.dashed")], []) }
        return (rows.prefix(200).map(\.node), open)
    }

    /// A text block gone to, at a line: its editor here focused there, or
    /// one brought here.
    private func goToLine(_ line: Int, in block: BlockID) {
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

    /// What's kept off the desk on a host (§4): named workspaces, and
    /// kept blocks on no workspace of the desk — the last seen first.
    private func keptItems(on c: HostClient) -> [Block] {
        let onDesk = Set(c.desk.order)
        let onDeskBlocks = Set(allWorkspaces.compactMap { hosts.arrangement($0) }.flatMap { $0.placements.map(\.block) })
        let far = Stamp(wall: 0, logical: 0, host: c.host)
        return c.node.blocks.filter { b in
            b.id.host == c.host && (b.kind == .arrangement ? !onDesk.contains(b.id) && b.arrangement?.isNamed == true : b.isPinned && !onDeskBlocks.contains(b.id))
        }.sorted { (c.node.graph.seen($0.id) ?? far) > (c.node.graph.seen($1.id) ?? far) }
    }

    /// What's closed and not yet collected on a host (§4): what exists
    /// and nothing reaches — the last seen first.
    private func closedItems(on c: HostClient, reachable: Set<BlockID>) -> [Block] {
        let far = Stamp(wall: 0, logical: 0, host: c.host)
        return c.node.blocks.filter { !reachable.contains($0.id) && $0.id.host == c.host && !($0.kind == .arrangement && $0.arrangement!.isEmpty) }
            .sorted { (c.node.graph.seen($0.id) ?? far) > (c.node.graph.seen($1.id) ?? far) }
    }

    /// Rows of blocks and workspaces under their hosts (when there is
    /// more than one), each brought back by a click.
    private func hostedRows(_ make: (HostClient) -> [OrgNode], prefix: String) -> ([OrgNode], Set<String>) {
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

    /// Kept (§4), the list: named workspaces off the desk and kept blocks
    /// off it, each with a pin, each brought back by a click.
    private func keptTree(_ filter: String) -> ([OrgNode], Set<String>) {
        hostedRows({ c in
            keptItems(on: c).filter { matches(filter, [$0.kind == .arrangement ? title(of: $0.arrangement!) : $0.displayTitle, $0.path]) }.map { b -> OrgNode in
                let n = b.kind == .arrangement
                    ? OrgNode(id: "kept/\(b.id)", block: b.id, title: title(of: b.arrangement!), symbol: "rectangle.3.group", count: b.arrangement!.placements.count)
                    : node(for: b, id: "kept/\(b.id)", detail: b.place?.abbreviatingHome ?? "")
                n.detailSymbol = "pin"
                n.trailing = c.node.graph.seen(b.id).map(Age.short)
                return n
            }
        }, prefix: "kept")
    }

    /// Recently Closed (§4), the list: what exists and nothing reaches,
    /// dimmed, each brought back by a click, until collected.
    private func closedTree(_ filter: String) -> ([OrgNode], Set<String>) {
        let reachable = hosts.reachable()
        return hostedRows({ c in
            closedItems(on: c, reachable: reachable).filter { matches(filter, [$0.kind == .arrangement ? title(of: $0.arrangement!) : $0.displayTitle, $0.path]) }.prefix(100).map { b -> OrgNode in
                let n = b.kind == .arrangement
                    ? OrgNode(id: "closed/\(b.id)", block: b.id, title: title(of: b.arrangement!), symbol: "rectangle.3.group", count: b.arrangement!.placements.count)
                    : node(for: b, id: "closed/\(b.id)", detail: b.place?.abbreviatingHome ?? "")
                n.dimmed = true
                n.trailing = c.node.graph.seen(b.id).map(Age.short)
                return n
            }
        }, prefix: "closed")
    }

    /// Workspaces (§3.6): every attached host's, under its host when there
    /// is more than one, each expanding to its tiles in order (by column,
    /// top to bottom), the selected one open and the focused tile marked:
    /// the table of contents of the screen.
    private func deskTree(_ filter: String) -> ([OrgNode], Set<String>) {
        var open: Set<String> = []
        func workspace(_ id: BlockID) -> OrgNode? {
            guard let a = hosts.arrangement(id) else { return nil }
            let aid = "arr/\(id)"
            // Every workspace whole (§3.6): nothing folds by itself; one
            // closed by its chevron stays closed.
            var tiles: [OrgNode] = []
            for (c, column) in a.columns.enumerated() {
                for p in column {
                    let b = hosts.block(p.block)
                    let title = b?.displayTitle ?? "On \(hosts.label(of: p.block.host))"
                    guard matches(filter, [title, b?.path]) else { continue }
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
                            detail: "", count: a.placements.count > 1 ? a.placements.count : nil, children: tiles)
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
            let nodes = ids.compactMap(workspace)
            byHost.append((c, nodes))
        }
        guard byHost.count > 1 else { return (byHost.first?.1 ?? [], open) }
        let roots = byHost.map { c, nodes -> OrgNode in
            let id = "host:\(c.host.raw)"
            open.insert(id)
            let n = OrgNode(id: id, title: hosts.label(of: c.host), symbol: c.isRemote ? "server.rack" : "laptopcomputer", isGroup: true, children: nodes)
            n.style = .host
            hostStanding(n, c)
            return n
        }
        return (roots, open)
    }

    /// Files: each host's sparse tree, roots open.
    private func filesTree(_ filter: String) -> ([OrgNode], Set<String>) {
        var open: Set<String> = []
        // What is on a workspace now comes first in every folder; what is
        // kept otherwise (§4) after, dimmed — a folder with something active
        // among its blocks counts as active. What nothing keeps isn't here:
        // it's in Recently Closed, at the sidebar's foot.
        let placed = Set(allWorkspaces.compactMap { hosts.arrangement($0) }.flatMap { $0.placements.map(\.block) })
        let reachable = hosts.reachable()
        var active: [ObjectIdentifier: Bool] = [:]
        func convert(_ f: FileNode) -> OrgNode? {
            if let b = f.block, !f.isFolder, !reachable.contains(b) { return nil }
            let made = f.children.compactMap(convert)
            var children = made.filter { active[ObjectIdentifier($0)] == true }
            children += made.filter { active[ObjectIdentifier($0)] != true }
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

    // MARK: The neighborhood, in graph form

    private var neighborhoodView: NeighborhoodView?

    /// ⌥⌘N: the neighborhood map, around the focused block.
    @objc func showNeighborhood(_ sender: Any?) { showNeighborhood(around: nil) }

    /// The neighborhood map: a block's neighborhood to distance 2 as a
    /// picture, to look around and walk; ⌘-click or ⏎ goes to a block.
    /// The one big view of the links; the small one is the tile's badge.
    func showNeighborhood(around block: BlockID?) {
        guard neighborhoodView == nil else { return hideNeighborhood() }
        guard let center = block ?? focusedShown?.placement.block ?? selected else { return }
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
    /// Where focus is: the workspace and the tile, so a change is noticed.
    private var lastFocusPlace: (BlockID?, PlacementID?)?

    /// A move of focus takes the pen (§8.2): for the block, and the
    /// workspace it sits in. (The host writes the trail from the focus
    /// and the workspaces seen; nothing is kept here.)
    private func noteTrailFocus() {
        let place = (selected, arrangement?.focused)
        guard place.0 != lastFocusPlace?.0 || place.1 != lastFocusPlace?.1 else { return }
        lastFocusPlace = place
        noteNavFocus()
        if let b = focusedShown?.placement.block { hosts.own(b) }
        if let w = selected { hosts.own(w) }
    }

    /// Every host's trail, merged by time, oldest first.
    private func trailSteps() -> [Step] {
        var steps: [Step] = []
        for c in hosts.all {
            let g = c.node.graph
            for i in 0..<g.stepCount { if let s = g.step(at: i) { steps.append(s) } }
        }
        return steps.sorted { $0.at < $1.at }
    }

    // MARK: The block navigation stack (§3.5)

    /// A place in the stack: a tile in its workspace, its block, and where
    /// in the block it was.
    struct NavEntry {
        var workspace: BlockID?
        var placement: PlacementID?
        var block: BlockID
        var location: NavLocation?

        func same(as e: NavEntry) -> Bool {
            guard placement == e.placement, block == e.block else { return false }
            switch (location, e.location) {
            case let (a?, b?): return a.near(b)
            default: return true
            }
        }
    }

    /// Every place gone to, block by block and within blocks — a focus
    /// moved, a definition gone to, a found line, a heading, a command —
    /// oldest first, with where back and forward are now. ⌃- goes back,
    /// ⌃⇧- forward, as VS Code's do; anything new drops what's forward.
    private var navStack: [NavEntry] = []
    private var navCursor = -1
    /// Going back or forward: the moves it makes aren't new places.
    private var navigating = false

    /// The current entry, kept up with where its view is now.
    private func refreshNavCurrent() {
        guard navStack.indices.contains(navCursor), let p = navStack[navCursor].placement, let v = views[p] else { return }
        if let loc = v.navLocation { navStack[navCursor].location = loc }
    }

    /// `refresh`: the current entry first brought up to where its view is
    /// (not after a jump, where that's where it landed, not where it was).
    private func pushNav(_ e: NavEntry, refresh: Bool = true) {
        if refresh { refreshNavCurrent() }
        if navStack.indices.contains(navCursor), navStack[navCursor].same(as: e) {
            navStack[navCursor] = e
            return
        }
        if navCursor + 1 < navStack.count { navStack.removeSubrange((navCursor + 1)...) }
        navStack.append(e)
        if navStack.count > 300 { navStack.removeFirst(navStack.count - 300) }
        navCursor = navStack.count - 1
    }

    /// Focus moved to another tile: a new place.
    private func noteNavFocus() {
        guard !navigating, let f = focusedShown else { return }
        pushNav(NavEntry(workspace: selected, placement: f.id, block: f.placement.block, location: views[f.id]?.navLocation))
    }

    /// A view about to jump within its block: where it is noted first, and
    /// where it lands once it has.
    private func noteJump(_ view: PaneContent) {
        guard !navigating else { return }
        let here = NavEntry(workspace: selected, placement: view.placement, block: view.block, location: view.navLocation)
        if navStack.indices.contains(navCursor), navStack[navCursor].placement == view.placement {
            navStack[navCursor].location = here.location
        } else {
            pushNav(here)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self, weak view] in
            guard let self, let view, !self.navigating else { return }
            self.pushNav(NavEntry(workspace: self.selected, placement: view.placement, block: view.block, location: view.navLocation), refresh: false)
        }
    }

    /// ⌃- (or the mouse's back button): the place before, in another block
    /// or this one, the pointer following.
    @objc func navigateBack(_ sender: Any?) { walkNav(-1) }
    /// ⌃⇧- (or the mouse's forward button): forward again.
    @objc func navigateForward(_ sender: Any?) { walkNav(1) }

    private func walkNav(_ direction: Int) {
        refreshNavCurrent()
        var i = navCursor + direction
        while navStack.indices.contains(i) {
            if go(toNav: navStack[i]) {
                navCursor = i
                return
            }
            // Gone (its tile and block both): passed over, and forgotten.
            navStack.remove(at: i)
            if i < navCursor { navCursor -= 1 }
            if direction < 0 { i -= 1 }
        }
        NSSound.beep()
    }

    /// Goes to an entry: its tile if it's still anywhere (its workspace
    /// shown, out of its stack, focused), else its block wherever it is;
    /// then the place in it.
    private func go(toNav e: NavEntry) -> Bool {
        navigating = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in self?.navigating = false }
        var target: PlacementID?
        if let pid = e.placement, let w = e.workspace, allWorkspaces.contains(w), let a = hosts.arrangement(w), a.placement(pid) != nil {
            if selected != w { hosts.select(w) }
            if a.focused != pid || a.isStashed(pid) || (a.full != nil && a.full != pid) {
                hosts.append(arriving(pid, in: a), to: .block(w))
            }
            target = pid
        } else if hosts.block(e.block) != nil {
            goTo(e.block)
        } else {
            navigating = false
            return false
        }
        render()
        lastFocusPlace = (selected, arrangement?.focused)
        warpPointerToFocus()
        if let loc = e.location {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
                guard let self, let p = target ?? self.arrangement?.focused, let v = self.views[p] else { return }
                v.go(to: loc)
            }
        }
        return true
    }


    /// The mouse's back and forward buttons (3 and 4), wherever it is in
    /// the window: back and forward; and ⌃- and ⌃⇧-, the block navigation
    /// stack's keys, before any view takes them.
    private var historyButtonsMonitor: Any?
    private var navKeysMonitor: Any?
    private func watchHistoryButtons() {
        NavJumps.willJump = { [weak self] view in self?.noteJump(view) }
        navKeysMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, event.window === self.window, event.keyCode == 27 else { return event }
            let mods = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            guard mods == .control || mods == [.control, .shift] else { return event }
            if mods.contains(.shift) { self.navigateForward(nil) } else { self.navigateBack(nil) }
            return nil
        }
        historyButtonsMonitor = NSEvent.addLocalMonitorForEvents(matching: .otherMouseDown) { [weak self] event in
            guard let self, (event.window ?? NSApp.keyWindow) === self.window else { return event }
            switch event.buttonNumber {
            // A page's or a folder's own history where the tile has one;
            // else the block navigation stack.
            case 3: if !NSApp.sendAction(#selector(WebView.goBack(_:)), to: nil, from: self) { self.navigateBack(nil) }; return nil
            case 4: if !NSApp.sendAction(#selector(WebView.goForward(_:)), to: nil, from: self) { self.navigateForward(nil) }; return nil
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

    /// Debugging: the block navigation stack's last places, the one at marked.
    func debugHistory() -> String {
        let first = max(0, navStack.count - 30)
        return navStack[first...].enumerated().map { k, e in
            let i = first + k
            let loc = e.location.map { " @\($0)" } ?? ""
            return "\(i == navCursor ? ">" : " ")\(i) \(hosts.block(e.block)?.displayTitle ?? "?")\(loc)"
        }.joined(separator: "\n")
    }

    // MARK: Finding and opening

    func debugFinder(_ query: String) -> [String] { finder.debugQuery(query) }
    func debugFinderPicture(_ path: String) -> String { finder.debugPicture(path) }
    func debugFinderTime(_ query: String) -> String {
        if query == "open" {
            let start = Date()
            let (c, _) = finderCorpus(verbs: true)
            return String(format: "snapshot of %d in %.1f ms", c.count, Date().timeIntervalSince(start) * 1000)
        }
        return finder.debugTime(query)
    }
    func debugFinderChoose() { finder.debugChoose() }
    func debugFinderScope(_ n: Int) { finder.debugScope(n) }
    func debugFinderMove(_ by: Int) { finder.debugMove(by) }

    private lazy var finder: Finder = {
        let f = Finder()
        f.search = { [weak self] query, scope in
            guard let self else { return [] }
            switch scope {
            case .names: return []
            case .contents: return self.finderContentItems(query)
            case .blocks: return self.finderBlockItems(query)
            }
        }
        f.special = { [weak self] query in
            // A web address typed: opened as a page, first.
            guard query.hasPrefix("http://") || query.hasPrefix("https://") || (query.contains(".") && !query.contains(" ") && !query.contains("/") && query.split(separator: ".").last.map({ $0.count >= 2 && $0.allSatisfy(\.isLetter) }) == true) else { return nil }
            let url = query.contains("://") ? query : "https://" + query
            return FinderItem(symbol: "globe", title: url, detail: "Open as a web page", note: "web", run: { [weak self] in self?.open(url, from: self?.focusedShown?.id) })
        }
        f.openFile = { [weak self] path in self?.open(path, from: nil) }
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
        // A row a file, as a site's search lists pages: its name, its folder,
        // the lines that hold the query run together, each match marked.
        var order: [String] = []
        var byPath: [String: [SearchHit]] = [:]
        for hit in s.hits.prefix(400) {
            if byPath[hit.path] == nil { order.append(hit.path) }
            byPath[hit.path, default: []].append(hit)
        }
        var items: [FinderItem] = order.map { path in
            let hits = byPath[path]!
            let first = hits[0]
            return FinderItem(symbol: Finder.symbol(forFile: path.lastPathComponent), title: path.lastPathComponent,
                              detail: path.deletingLastPathComponent.abbreviatingHome,
                              note: hits.count == 1 ? "line \(first.line)" : "\(hits.count) lines",
                              run: { [weak self] in
                                  guard let self else { return }
                                  self.open(path: first.path, line: first.line, column: first.column, on: on, from: self.focusedShown?.placement.id, kind: .opened, context: query)
                              },
                              excerpt: Self.excerpt(hits.map(\.text)), marked: query)
        }
        if s.running || s.truncated || s.error != nil || !s.hits.isEmpty {
            items.append(FinderItem(symbol: "magnifyingglass", title: s.running ? "Looking…" : s.error ?? "\(s.hits.count)\(s.truncated ? "+" : "") lines", detail: "As a search block", note: "",
                                    run: { [weak self] in self?.show(id, lens: .search, .here) }))
        }
        return items
    }

    /// The lines that hold a query, as one excerpt: trimmed, run together.
    static func excerpt(_ lines: [String]) -> String {
        lines.prefix(6).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }.joined(separator: "  ·  ")
    }

    /// "In Blocks": the texts of the blocks — the selected workspace's
    /// first, then every other note and file kept as a block — a row each,
    /// its name, where it is, the lines that hold the query marked, going
    /// to the first of them.
    private func finderBlockItems(_ query: String) -> [FinderItem] {
        guard !query.isEmpty else { return [] }
        let q = query.lowercased()
        var items: [FinderItem] = []
        var seen = Set<BlockID>()
        let here = arrangement.map { a in a.placements.map { ($0.block, Optional($0.id)) } } ?? []
        let rest = hosts.blocks.filter { $0.kind == .text }.map { ($0.id, PlacementID?.none) }
        for (blockID, placement) in here + rest where seen.insert(blockID).inserted {
            guard let b = hosts.block(blockID), let text = b.text?.text.string, text.lowercased().contains(q) else { continue }
            var line = 0, firstLine = 0
            var matches: [String] = []
            for raw in text.split(separator: "\n", omittingEmptySubsequences: false) {
                line += 1
                guard raw.lowercased().contains(q) else { continue }
                if firstLine == 0 { firstLine = line }
                matches.append(String(raw))
            }
            let at = firstLine, block = b.id
            let place = b.path.map { $0.deletingLastPathComponent.abbreviatingHome } ?? (b.place.map { "Note · " + $0.abbreviatingHome } ?? "Note")
            items.append(FinderItem(symbol: Theme.symbolName(for: b.kind, path: b.path), title: b.displayTitle, detail: place,
                                    note: matches.count == 1 ? "line \(at)" : "\(matches.count) lines",
                                    run: { [weak self] in
                                        guard let self else { return }
                                        if let id = placement, self.arrangement?.placement(id) != nil, let e = self.views[id] as? EditorView {
                                            self.arrive(atTile: id)
                                            e.select(line: at)
                                            return
                                        }
                                        self.pendingJump = (b.path ?? "", at, nil)
                                        self.show(block, lens: Lens.default(for: .text, path: b.path), .here)
                                        self.warpPointerToFocus()
                                    },
                                    excerpt: Self.excerpt(matches), marked: query))
            if items.count >= 100 { break }
        }
        // Agents' turns: what was asked and what each said.
        for block in hosts.blocks {
            for turn in (block.terminal?.turns ?? []).reversed() {
                let said = [turn.prompt, turn.message ?? ""].joined(separator: "\n")
                guard said.lowercased().contains(q) else { continue }
                let lines = said.split(separator: "\n").map(String.init).filter { $0.lowercased().contains(q) }
                let first = turn.prompt.split(whereSeparator: \.isNewline).first.map(String.init) ?? "Turn"
                let agentID = block.id, turnID = turn.id
                items.append(FinderItem(symbol: "text.bubble", title: String(first.prefix(120)), detail: "Turn of \(block.displayTitle) · \(Age.short(turn.began))",
                                        note: (turn.files?.count).map { "\($0) file\($0 == 1 ? "" : "s")" } ?? "",
                                        run: { [weak self] in self?.showTurn(turnID, of: agentID, place: .here) },
                                        excerpt: Self.excerpt(lines), marked: query))
                if items.count >= 150 { return items }
            }
        }
        return items
    }

    /// ⌘O: the finder, over everything, and the files where the focused
    /// placement is.
    @objc func openDocument(_ sender: Any?) {
        // The files where the focused block is: its folder (a terminal's
        // working directory, a file's folder), on this Mac.
        let root = focusedShown.flatMap { $0.placement.block.host == host.host ? ($0.block?.terminal?.cwd ?? $0.block?.place) : nil } ?? NSHomeDirectory()
        let (corpus, actions) = finderCorpus(verbs: false)
        let known = Set(hosts.blocks.filter { $0.id.host == host.host }.compactMap(\.path))
        finder.show(corpus: corpus, actions: actions, filesUnder: root, knownPaths: known, scopes: true, placeholder: "Find a block, or a file in \(root.abbreviatingHome)…", over: window)
    }

    /// ⌘T: the graph alone — blocks and workspaces, what's kept — and
    /// what can be made, found by name (§3.5).
    private func showGraphFinder() {
        let (corpus, actions) = finderCorpus(verbs: true)
        finder.show(corpus: corpus, actions: actions, filesUnder: nil, scopes: false, placeholder: "Go to a block, or make one…", over: window)
    }

    /// What the finder finds by name (§3.5), taken once as it opens: every
    /// block and workspace, each with what it's called (and words as good:
    /// its kind, the agent at work in it), what's around it, how far it is
    /// from the focused block and how lately seen — and with `verbs`, what
    /// can be made. Ranked off the main thread as you type (FinderRanking).
    /// What nothing keeps (§4) comes last, marked recent.
    private func finderCorpus(verbs: Bool) -> ([FinderCandidate], [() -> Void]) {
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
                guard let a = block.arrangement, a.isNamed || !a.isEmpty else { continue }
                title = self.title(of: a)
                secondary = ""
                detail = a.isNamed ? "Workspace · \(a.placements.count) blocks" : "Workspace, unnamed · \(a.placements.count) blocks"
                note = allWorkspaces.contains(block.id) ? "on the desk" : ""
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
            } else if block.isPinned, note.isEmpty {
                note = "kept"
            } else if block.kind == .arrangement {
                if allWorkspaces.contains(block.id) { distance = min(distance, 2) }
            } else if here.contains(block.id) {
                distance = block.id == focusedBlock ? 1000 : 1
                if note.isEmpty { note = block.id == focusedBlock ? "here, focused" : "here" }
            } else if let d = near[block.id], d > 0 {
                if note.isEmpty { note = d == 1 ? "linked" : "near" }
            } else if onDesk.contains(block.id) {
                distance = min(distance, 3)
            }
            let seen = Age.short(entry.lastSeen)
            note = note.isEmpty ? seen : note + " · " + seen
            // Words as good as the title's own: the kind ("terminal", "note"),
            // and the agent at work in it ("claude", "Claude Code").
            let kindWord = block.kind == .text ? (block.path == nil ? "Note" : "File") : block.kind.defaultTitle
            let agentWords = agent.map { " " + $0.command + " " + $0.name } ?? ""
            secondary += " " + block.id.host.raw
            let id = block.id
            corpus.append(FinderCandidate(symbol: Theme.symbolName(for: block.kind, path: block.path), title: title, detail: detail + remote, note: note,
                                          name: title + " " + kindWord + agentWords, aliases: agent.map { [$0.command, $0.name] } ?? [], around: secondary,
                                          distance: distance, recency: max(entry.lastSeen.wall, joinedAt[block.id] ?? 0), action: actions.count))
            actions.append { [weak self] in self?.recall(id) }
        }
        // Agents' turns (§3.8), by what was asked: found as the turn, which
        // opens as its own block.
        for block in hosts.blocks {
            for turn in block.terminal?.turns ?? [] {
                let first = turn.prompt.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
                guard !first.isEmpty else { continue }
                let agentID = block.id, turnID = turn.id
                let files = (turn.files ?? []).prefix(3).joined(separator: ", ")
                corpus.append(FinderCandidate(symbol: "text.bubble", title: String(first.prefix(120)),
                                              detail: "Turn of \(block.displayTitle)" + (files.isEmpty ? "" : " · " + files),
                                              note: Age.short(turn.began), name: first + " turn " + turn.agent,
                                              around: (turn.repo ?? "") + " " + (turn.files ?? []).joined(separator: " "),
                                              distance: 60, recency: turn.began.wall, action: actions.count))
                actions.append { [weak self] in self?.showTurn(turnID, of: agentID, place: .here) }
            }
        }
        if verbs {
            for item in paletteItems() where item.title != "Find Anything…" {
                corpus.append(FinderCandidate(symbol: item.symbol, title: item.title, detail: item.subtitle, note: "do",
                                              name: item.title, around: item.subtitle, distance: 45, recency: 0, action: actions.count))
                actions.append(item.run)
            }
        }
        return (corpus, actions)
    }

    /// Recall, from the finder: an arrangement onto the desk and selected;
    /// any other block gone to.
    /// Chosen in the finder: gone to; with ⌘ held on ⏎, beside the focused
    /// tile; with ⌥, over it (the rule, §3.1).
    func recall(_ id: BlockID) {
        let mods = NSApp.currentEvent?.modifierFlags ?? []
        guard let b = hosts.block(id), b.kind != .arrangement, let f = arrangement?.focused else { return goTo(id) }
        let lens = Lens.default(for: b.kind, path: b.path)
        if mods.contains(.option) { show(id, lens: lens, .over(f)) }
        else if mods.contains(.command) { show(id, lens: lens, .besideOpener(f)) }
        else { goTo(id) }
    }

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
    func goTo(_ id: BlockID) {
        guard let block = hosts.block(id) else { return }
        hideStateView()
        warpPointerToFocus()
        if block.kind == .arrangement { return hosts.select(id) }
        if let a = arrangement, let t = a.placements(of: id).first, let here = selected {
            // Here already: out of its stack, from behind a maximized
            // tile, and focused.
            return hosts.append(arriving(t.id, in: a), to: .block(here))
        }
        let recent = hosts.recentWorkspaces()
        let order = recent + allWorkspaces.filter { !recent.contains($0) }
        for arr in order where arr != selected {
            if let a = hosts.arrangement(arr), let t = a.placements(of: id).first {
                hosts.select(arr)
                hosts.append(arriving(t.id, in: a), to: .block(arr))
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

    /// A terminal scrolled to one of its commands, once its tile is up and
    /// it has found the command's row (a moment, for a tile just made).
    func goToCommand(_ id: Int, in block: BlockID, tries: Int = 20) {
        if let t = content.views.compactMap({ $0 as? TerminalView }).first(where: { $0.block == block && !$0.isHiddenOrHasHiddenAncestor }), t.go(toCommand: id) { return }
        guard tries > 0 else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in self?.goToCommand(id, in: block, tries: tries - 1) }
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
        // A tile of the block already there, collapsed to its bar: grown.
        hosts.append(showingSome(events, in: a), to: .block(id))
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
            // Already here: gone to, as anything already here is.
            arrive(atTile: t.id)
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
        hosts.link(from: block, to: f.placement.block, kind: .opened, context: "HEAD → working tree")
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
                                        run: { [weak self] in self?.arrive(atTile: id) }))
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
                        self.arrive(atTile: id)
                        if let e = self.views[id] as? EditorView { e.select(line: at) }
                        else if let m = self.views[id] as? MarkdownView { m.scroll(toHeading: nth) }
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
        show(f.placement.block, lens: other, .besideOpener(f.id), kind: .opened, context: other == .editor ? "edited beside" : "viewed beside", exact: true)
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
        // A link to a block (manifold:host/ulid, as a note's pill is): go to
        // it — and to a place in it, if the link names one (#command=7).
        if target.hasPrefix("manifold:"), let (b, fragment) = BlockID.link(target) {
            arrive(b, from: placement, over: over)
            if let fragment, fragment.hasPrefix("command="), let id = Int(fragment.dropFirst(8)) { goToCommand(id, in: b) }
            return
        }
        if let url = URL(string: target), let scheme = url.scheme, scheme.count > 1, scheme != "file" {
            let inWeb = here ?? Self.clickModifiers.map(Self.opensHere) ?? true
            // A server on another host's own localhost (one a remote
            // terminal names): its port forwarded here, then the address
            // opened at the port here.
            let from = placement.flatMap { shown($0)?.placement.block.host } ?? host.host
            if from != host.host, scheme == "http" || scheme == "https", let h = url.host, Self.loopbackNames.contains(h) {
                let port = url.port ?? (scheme == "https" ? 443 : 80)
                forward(port, on: from) { [weak self] local in
                    guard let local, var parts = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return }
                    parts.host = "localhost"
                    parts.port = local
                    if let here = parts.url { self?.openWeb(here, place: place, here: inWeb, context: target) }
                }
                return
            }
            openWeb(url, place: place, here: inWeb, context: target)
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
        if let (block, lens) = pathBlock(path, isDirectory: isDir.boolValue, on: on) {
            show(block, lens: lens, place, context: target)
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

    static let loopbackNames: Set<String> = ["localhost", "127.0.0.1", "0.0.0.0", "::1", "[::1]"]

    /// An address: in the web lens (where `here` says), else the system's browser.
    func openWeb(_ url: URL, place: Where, here: Bool, context: String? = nil) {
        if (url.scheme == "http" || url.scheme == "https") && here {
            show(host.newWeb(url: url.absoluteString), lens: .web, place, context: context ?? url.absoluteString)
        } else {
            NSWorkspace.shared.open(url)
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

    /// The block whose history is up: a text block.
    private var historyOf: BlockID?

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
            self.hosts.link(from: diff, to: block, kind: .opened, context: "then → now")
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
        guard let history, let block = shard.block, block == historyOf else { return }
        history.showText(entries: entries, block: block, base: base)
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
    func sidebarNewTab() { newTab(nil) }

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

    func gridRoomForFan(_ top: PlacementID) -> Bool {
        guard let a = arrangement else { return false }
        let events = showingSome([], in: a, placement: top, .fan)
        guard !events.isEmpty else { return false }
        appendToSelected(events)
        render()
        return true
    }
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
        if a.placement(placement) == nil { return bringFromElsewhere(placement, column: column, at: at, newColumn: newColumn) }
        if newColumn || column >= a.columns.count {
            movePlacement(placement, toNewColumn: column, in: a, alone: alone)
        } else {
            appendToSelected((alone ? a.leavingAlone(placement) : []) + [.move(placement, column: column, at: at)])
        }
    }

    /// A tile dragged here from another workspace (one sprung open from
    /// the sidebar under the drag): its block placed where it was dropped,
    /// stacked behind `behind` if it was dropped on a tile, and taken from
    /// the workspace it came from — unless ⌥ copies it, shown in both.
    private func bringFromElsewhere(_ placement: PlacementID, column: Int, at: Int, newColumn: Bool, behind: PlacementID? = nil,
                                    copy: Bool = NSEvent.modifierFlags.contains(.option)) {
        guard let a = arrangement, let id = selected, let (block, from) = dragged(.placement(placement)), let from else { return }
        let lens = from.placement.lens
        if let t = a.tile(of: block, lens: lens) {
            // Here already: only gone from there.
            focus(t.id)
        } else {
            let new = ULID.make()
            if newColumn || column >= a.columns.count {
                show(block, lens: lens, .inNewColumn(column))
            } else {
                let below = at > 0 && at - 1 < a.columns[column].count ? a.columns[column][at - 1].id : nil
                appendToSelected(below.map { a.bringing(block, lens: lens, inColumn: column, below: $0, newPlacement: { new }) }
                                 ?? [.place(Placement(id: new, block: block, lens: lens), column: column, at: 0)])
                if let behind, let now = hosts.arrangement(id), now.placement(new) != nil {
                    appendToSelected(now.stashing(new, behind: behind))
                }
            }
        }
        if !copy { takeOut(from.placement.id, of: from.arrangement) }
    }

    /// A tile taken off a workspace it was moved from; the workspace, left
    /// empty and unnamed, off the desk.
    private func takeOut(_ placement: PlacementID, of arrangement: BlockID) {
        hosts.append(.remove(placement), to: .block(arrangement))
        if arrangement != selected, let a = hosts.arrangement(arrangement), a.isEmpty, !a.isNamed { removeFromDesk(arrangement) }
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

    /// ⌥-click on a shown tile's pill: the first tile behind it takes its
    /// place. With ⌥ held, clicked again (as ⌃⇥ walks workspaces) the next
    /// behind that, and so on round the stack, the ones passed staying as
    /// they were; letting go of ⌥ settles on the one come to.
    func gridSwapNext(_ placement: PlacementID) {
        guard let a = arrangement else { return }
        // Any of the stack's bars: clicked fast, the one that was on top
        // a moment ago may still be under the pointer.
        if let w = stackWalk, w.workspace == selected, w.order.contains(placement) {
            return walkStack(to: (w.index + 1) % w.order.count)
        }
        guard let order = stackOrder(of: placement, in: a), order.count > 1 else { return NSSound.beep() }
        beginStackWalk(order)
        walkStack(to: 1)
    }

    /// ⌥-click on a stashed pill, peeking out above its stack: it to the
    /// top — in a walk, as one of its steps.
    func gridSwap(_ placement: PlacementID) {
        guard let a = arrangement, a.isStashed(placement), let top = a.tile(behind: placement) else { return gridUnstash(placement) }
        if let w = stackWalk, w.workspace == selected, let k = w.order.firstIndex(of: placement) { return walkStack(to: k) }
        guard let order = stackOrder(of: top.id, in: a), let k = order.firstIndex(of: placement) else { return }
        beginStackWalk(order)
        walkStack(to: k)
    }

    /// A shown tile and the tiles behind it, in order (those stashed above
    /// a column's first shown tile are behind it too).
    private func stackOrder(of top: PlacementID, in a: ArrangementState) -> [PlacementID]? {
        guard let (c, _) = a.locate(top), !a.isStashed(top) else { return nil }
        return [top] + a.columns[c].filter { a.isStashed($0.id) && a.tile(behind: $0.id)?.id == top }.map(\.id)
    }

    private func beginStackWalk(_ order: [PlacementID]) {
        endOptionWalk()
        // Only with ⌥ held is there a walk to go on with.
        guard NSEvent.modifierFlags.contains(.option) || debugOptionHeld else {
            stackWalk = (selected, order, 0, nil)
            return
        }
        let monitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            if !event.modifierFlags.contains(.option) { self?.endOptionWalk() }
            return event
        }
        stackWalk = (selected, order, 0, monitor)
    }

    private func walkStack(to k: Int) {
        guard let a = arrangement, var w = stackWalk else { return }
        w.order = w.order.filter { a.placement($0) != nil }
        guard w.order.indices.contains(k) else { return endOptionWalk() }
        w.index = k
        stackWalk = w
        appendToSelected(a.walkingStack(w.order, to: k))
        // Not held: one step, settled.
        if w.monitor == nil { stackWalk = nil }
    }

    func endOptionWalk() {
        if let m = stackWalk?.monitor { NSEvent.removeMonitor(m) }
        stackWalk = nil
    }


    /// ⌥-drag: the dragged tile takes a tile's place, that tile and its
    /// stack going behind it.
    func gridCover(_ placement: PlacementID, over target: PlacementID, alone: Bool) {
        if let a = arrangement, a.placement(placement) == nil, let (c, i) = a.locate(target) {
            return bringFromElsewhere(placement, column: c, at: i + 1, newColumn: false, behind: target)
        }
        cover(placement, over: target, alone: alone)
    }

    /// Close Stack: this tile and every one behind it are taken off the
    /// workspace (as ⌘W takes one; the blocks keep). Maximized, its stack
    /// is its whole column, which goes.
    func gridCloseStack(_ placement: PlacementID) {
        guard let a = arrangement, let id = selected, let (c, _) = a.locate(placement) else { return }
        let stack = a.full == placement
            ? a.columns[c]
            : a.columns[c].filter { $0.id == placement || (a.isStashed($0.id) && a.tile(behind: $0.id)?.id == placement) }
        let before = hosts.reachable()
        for p in stack { noteClosing(p.id, in: id) }
        var events: [Event] = a.full == placement ? [.full(nil)] : []
        events += stack.map { .remove($0.id) }
        appendToSelected(events)
        if hosts.arrangement(id)?.isEmpty == true, !a.isNamed { removeFromDesk(id) }
        afterClosing(reachedBefore: before)
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
        if a.placement(placement) == nil, let (c, i) = a.locate(behind) {
            return bringFromElsewhere(placement, column: c, at: i + 1, newColumn: false, behind: behind)
        }
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

    /// Files dropped from the Finder: each opened where it landed, the
    /// first in a new column there if that's where the drop was.
    func gridOpenFiles(_ paths: [String], column: Int, at: Int, newColumn: Bool) {
        for (i, path) in paths.enumerated() {
            let isDir = (try? FileManager.default.attributesOfItem(atPath: path))?[.type] as? FileAttributeType == .typeDirectory
            let media = Self.mediaKind(path)
            let block = isDir ? hosts.directoryBlock(for: path, on: host.host)
                : media.flatMap { kind in host.mediaBlock(for: path, kind: kind) } ?? hosts.textBlock(for: path, on: host.host)
            let lens: Lens = isDir ? .directory : media == .pdf ? .pdf : media == .image ? .image : Lens.default(for: .text, path: path)
            let place: Where = i == 0 && newColumn ? .inNewColumn(column) : .inColumn(min(column, max((arrangement?.columns.count ?? 1) - 1, 0)))
            show(block, lens: lens, place)
        }
    }

    func gridOpenPaths(_ paths: [(host: HostID, path: String, isDirectory: Bool)], column: Int, at: Int, newColumn: Bool) {
        for (i, p) in paths.enumerated() {
            guard let (block, lens) = pathBlock(p.path, isDirectory: p.isDirectory, on: p.host) else {
                if p.host == host.host { NSWorkspace.shared.open(URL(fileURLWithPath: p.path)) }
                continue
            }
            let place: Where = i == 0 && newColumn ? .inNewColumn(column) : .inColumn(min(column, max((arrangement?.columns.count ?? 1) - 1, 0)))
            show(block, lens: lens, place)
        }
    }

    func gridShowMap(for placement: PlacementID) {
        guard let b = arrangement?.placement(placement)?.block else { return }
        showNeighborhood(around: b)
    }

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
        if let t = hosts.block(block)?.text, t.isDirty {
            menu.addItem(.separator())
            if t.stale {
                menu.addItem(ClosureMenuItem("Reload from Disk, Losing the Edits", symbol: "arrow.clockwise") { [weak self] in self?.hosts.propose(.readFile(block)) })
                menu.addItem(ClosureMenuItem("Overwrite with the Edits", symbol: "square.and.arrow.down") { [weak self] in self?.save(block, from: placement) })
            } else {
                menu.addItem(ClosureMenuItem("Save", symbol: "square.and.arrow.down", key: "S") { [weak self] in self?.save(block, from: placement) })
            }
        }
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
        if let last = hosts.block(block)?.terminal?.turns?.last {
            let sub = NSMenu()
            for item in turnItems(last, of: block, beside: placement) { sub.addItem(item) }
            let item = NSMenuItem(title: "Last Turn", action: nil, keyEquivalent: "")
            item.setSymbol("text.bubble", size: 12)
            item.submenu = sub
            menu.addItem(item)
        }
        if let o = hosts.block(block)?.output, o.markdown != nil, let agent = o.source, let id = o.command,
           let turn = hosts.block(agent)?.terminal?.turns?.first(where: { $0.id == id }) {
            for item in turnItems(turn, of: agent, beside: placement).dropFirst() { menu.addItem(item) }
        }
        if let snap = hosts.block(block)?.terminal?.snapshot {
            menu.addItem(ClosureMenuItem("Changes Since It Started", symbol: "plusminus") { [weak self] in
                self?.showAgentChanges(block, snap, beside: placement)
            })
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
        menu.addItem(ClosureMenuItem("Show the Neighborhood Map", symbol: "point.3.connected.trianglepath.dotted") { [weak self] in
            self?.showNeighborhood(around: block)
        })
        if let b = hosts.block(block), b.isNote {
            menu.addItem(ClosureMenuItem("Name…", symbol: "pencil") { [weak self] in self?.nameNote(placement) })
        }
        if let b = hosts.block(block), b.kind == .text, p.lens.isText {
            let viewing = p.lens == .preview
            menu.addItem(ClosureMenuItem(viewing ? "Edit" : "View", symbol: viewing ? "pencil" : "eye", key: "\r") { [weak self] in self?.toggleMode(placement) })
        }
        menu.addItem(.separator())
        for item in copyItems(for: block) { menu.addItem(item) }
        menu.addItem(.separator())
        menu.addItem(hostSubmenu(block.host))
        menu.addItem(ClosureMenuItem("Take Off This Workspace", symbol: "xmark") { [weak self] in
            self?.hosts.append(.remove(placement), to: .block(id))
        })
        return menu
    }

    /// Copy Link (a `manifold:` address that opens the block from any app
    /// on this Mac — Slack, Notes, a commit message); Copy Path and Reveal
    /// in Finder for what has a place.
    func copyItems(for block: BlockID) -> [NSMenuItem] {
        guard let b = hosts.block(block) else { return [] }
        var items: [NSMenuItem] = [ClosureMenuItem("Copy Link", symbol: "link") { [weak self] in self?.copyLink(to: block) }]
        if let path = b.path ?? b.terminal?.cwd ?? b.place {
            items.append(ClosureMenuItem("Copy Path", symbol: "doc.on.clipboard") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(path, forType: .string)
            })
            if block.host == host.host, FileManager.default.fileExists(atPath: path) {
                items.append(ClosureMenuItem("Reveal in Finder", symbol: "folder") {
                    NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
                })
            }
        }
        // A file: opened with an app here (another host's, a copy sent
        // back when saved), or fetched to Downloads.
        if let path = b.path, [.text, .image, .pdf, .directory].contains(b.kind) {
            if b.kind != .directory { items.append(openWithItem(path, on: block.host)) }
            if block.host != host.host {
                items.append(ClosureMenuItem("Download", symbol: "arrow.down.circle") { [weak self] in
                    self?.download(path, isDirectory: b.kind == .directory, on: block.host)
                })
            }
        }
        return items
    }

    /// The block's address on the clipboard: as a link where links are
    /// taken (its name over it), as text elsewhere, as a block's link in a note.
    func copyLink(to block: BlockID, fragment: String? = nil) {
        guard let b = hosts.block(block) else { return }
        let address = "manifold:\(block.description)" + (fragment.map { "#" + $0 } ?? "")
        let title = b.displayTitle.replacingOccurrences(of: "]", with: "\\]")
        let pb = NSPasteboard.general
        pb.clearContents()
        let item = NSPasteboardItem()
        item.setString(address, forType: .string)
        item.setString(address, forType: .URL)
        item.setString("<a href=\"\(address)\">\(b.displayTitle.replacingOccurrences(of: "<", with: "&lt;"))</a>", forType: .html)
        item.setString("[\(title)](\(address))", forType: .manifoldBlockLink)
        pb.writeObjects([item])
    }

    /// A `manifold:` address opened from another app (or the command
    /// line): the block gone to, as a link in a note goes.
    func openLink(_ address: String) {
        guard BlockID.link(address) != nil else { return NSSound.beep() }
        open(address, from: arrangement?.focused)
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
        bunch(.linked, "links", "arrow.right", n.outbound[.link(.linked)] ?? [], toward: \.to, fallback: "linked by hand")
        bunch(.linked, "linked from", "arrow.left", n.inbound[.link(.linked)] ?? [], toward: \.from, fallback: "linked by hand")
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
    /// ⌘P: the focused tile on paper (or a PDF), as it best prints: a
    /// text as text, a page as rendered, a PDF's pages, an image.
    @objc func printTile(_ sender: Any?) {
        guard let f = arrangement?.focused, let p = views[f] as? Printable, let op = p.printOperation(), let window else { return NSSound.beep() }
        op.showsPrintPanel = true
        op.showsProgressPanel = true
        op.runModal(for: window, delegate: nil, didRun: nil, contextInfo: nil)
    }

    var debugPrintOperation: NSPrintOperation? { (arrangement?.focused.flatMap { views[$0] } as? Printable)?.printOperation() }

    /// ⌥⌘S: the focused tile's own sidebar, shown or put away — a
    /// Markdown text's headings, a PDF's contents and pages (§7.5).
    @objc func toggleTileSidebar(_ sender: Any?) {
        guard let f = arrangement?.focused, let v = views[f], v.hasSidebar else { return NSSound.beep() }
        v.toggleSidebar()
        content.sidebarChanged(f)
    }

    /// ⇧⌘O: the focused tile's outline beside it.
    @objc func showOutlineBeside(_ sender: Any?) {
        guard let f = focusedShown, [.terminal, .agent, .editor, .preview].contains(f.lens) else { return NSSound.beep() }
        showOutline(of: f.placement.block, beside: f.id)
    }

    /// A block through its outline lens (§3.8), beside its tile: its
    /// commands or headings as a list, a view of the block itself.
    func showOutline(of block: BlockID, beside placement: PlacementID) {
        show(block, lens: .outline, .besideOpener(placement), exact: true)
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
            case let t as TerminalView:
                t.go(toCommand: entry.id)
                t.showOutput(ofCommand: entry.id, beside: view.placement)
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

    /// A block's image for a page: this Mac's file as it is; another
    /// host's fetched once (20 MB at most) and kept as data, the pages that
    /// show it drawn again when it's in.
    func imageSource(_ id: BlockID) -> String? {
        guard let b = hosts.block(id), b.kind == .image, let path = b.path else { return nil }
        if id.host == host.host { return URL(fileURLWithPath: path).absoluteString }
        if let data = remoteImages[id] { return data }
        guard !fetchingImages.contains(id), let c = hosts.client(id.host) else { return nil }
        fetchingImages.insert(id)
        c.readBytes(path: path, limit: 20 << 20) { [weak self] data in
            guard let self else { return }
            self.fetchingImages.remove(id)
            guard let data else { return }
            let type = UTType(filenameExtension: path.pathExtension)?.preferredMIMEType ?? "image/png"
            self.remoteImages[id] = "data:\(type);base64," + data.base64EncodedString()
            for case let m as MarkdownView in self.views.values { m.imagesArrived() }
        }
        return nil
    }

    /// An image put in a note or a Markdown file: written on the text's
    /// host — beside the file, named so other Markdown readers find it, or
    /// in Manifold's own folder for a note — as an image block, and shown
    /// in the text where the caret was: `![](name)` beside a file,
    /// `![](manifold:…)` in a note. The text then embeds it (§3.6), a
    /// strong edge: the image is kept while a text shows it.
    func editor(_ view: EditorView, image data: Data, kind: String) {
        guard let b = hosts.block(view.block), let c = hosts.client(view.block.host) else { return NSSound.beep() }
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd-HHmmss"
        imageCount += 1
        let name = "image-\(f.string(from: Date()))\(imageCount > 1 ? "-\(imageCount)" : "").\(kind == "jpeg" ? "jpg" : kind)"
        let folder = b.path.map { $0.deletingLastPathComponent }
        let id = BlockID(host: view.block.host)
        c.propose(.saveImage(block: id, data: data, name: name, folder: folder)) { [weak self, weak view] error in
            guard let self, let view else { return }
            if let error { return self.toast.show("Couldn't keep the image: \(error)", action: "OK", for: 8) {} }
            let target = folder != nil
                ? (self.hosts.block(id)?.path?.lastPathComponent ?? name).addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? name
                : "manifold:\(id.description)"
            view.textView.insert("![](\(target))", typing: false)
        }
    }

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
                hosts.link(from: p.block, to: block, kind: .opened, context: "[[" + path.lastPathComponent + "]]")
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
            // A folder takes the listing's place, in the same tile; the one
            // it was is the tile's to go back to (⌘[).
            let next = Placement(block: block, lens: .directory)
            var h = folderHistory.removeValue(forKey: view.placement) ?? (back: [], forward: [])
            h.back.append(view.block)
            h.forward = []
            folderHistory[next.id] = h
            replace(view.placement, with: block, lens: .directory, as: next.id)
        } else {
            open(path, from: view.placement)
        }
    }

    func directoryView(_ view: DirectoryView, history direction: Int) -> Bool {
        guard var h = folderHistory[view.placement] else { return false }
        let to: BlockID
        if direction < 0 {
            guard let b = h.back.popLast() else { return false }
            h.forward.append(view.block)
            to = b
        } else {
            guard let f = h.forward.popLast() else { return false }
            h.back.append(view.block)
            to = f
        }
        guard hosts.block(to) != nil else { return false }
        let next = Placement(block: to, lens: .directory)
        folderHistory.removeValue(forKey: view.placement)
        folderHistory[next.id] = h
        replace(view.placement, with: to, lens: .directory, as: next.id)
        return true
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

    func directoryView(_ view: DirectoryView, linkFor path: String, isDirectory: Bool) -> String? {
        guard let (id, _) = pathBlock(path, isDirectory: isDirectory, on: view.block.host) else { return nil }
        let title = (hosts.block(id)?.displayTitle ?? path.lastPathComponent).replacingOccurrences(of: "]", with: "\\]")
        return "[\(title)](manifold:\(id.description))"
    }

    func directoryView(_ view: DirectoryView, receive items: [DroppedItem], into folder: String) {
        copy(items, into: folder, on: view.block.host)
    }

    func directoryView(_ view: DirectoryView, download path: String, isDirectory: Bool, to url: URL, done: @escaping (String?) -> Void) {
        guard let c = hosts.client(view.block.host) else { return done("the host isn't attached") }
        Transfer.download(path, isDirectory: isDirectory, on: c, to: url, done: done)
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
                self?.show(block, lens: lens, .besideOpener(view.placement))
            })
        }
        menu.addItem(.separator())
        if !isDirectory { menu.addItem(openWithItem(path, on: on)) }
        if on == host.host {
            menu.addItem(ClosureMenuItem("Reveal in Finder", symbol: "folder") {
                NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
            })
        } else {
            menu.addItem(ClosureMenuItem("Download", symbol: "arrow.down.circle") { [weak self] in self?.download(path, isDirectory: isDirectory, on: on) })
        }
        menu.addItem(ClosureMenuItem("Copy Path", symbol: "doc.on.clipboard") {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(path, forType: .string)
        })
        return menu
    }

    // MARK: Files between hosts

    /// Files and folders put in a folder on a host: this Mac's, or entries
    /// of any host's (fetched here, then sent on). What's there already
    /// is asked about, once for all, before it's written over.
    func copy(_ items: [DroppedItem], into folder: String, on target: HostID, replacing: Bool = false) {
        guard let c = hosts.client(target) else { return NSSound.beep() }
        let label = hosts.label(of: target) + ":" + folder.abbreviatingHome
        let n = items.count
        toast.show("Copying \(n) item\(n == 1 ? "" : "s") to \(label)…", action: "OK", for: 60) {}
        var existing: [DroppedItem] = []
        var failure: String?
        func finish() {
            if let failure {
                toast.show("Couldn't copy to \(label): \(failure)", action: "OK", for: 10) {}
            } else if !existing.isEmpty {
                toast.show("Copied \(n - existing.count) of \(n)", action: "OK", for: 4) {}
                let alert = NSAlert()
                alert.messageText = existing.count == 1 ? "“\(Self.name(of: existing[0]))” is already in \(folder.lastPathComponent)" : "\(existing.count) items are already in \(folder.lastPathComponent)"
                alert.informativeText = "Replace what's there with what was dropped?"
                alert.addButton(withTitle: "Replace")
                alert.addButton(withTitle: "Leave Them")
                if let window { alert.beginSheetModal(for: window) { [weak self] r in
                    if r == .alertFirstButtonReturn { self?.copy(existing, into: folder, on: target, replacing: true) }
                } }
            } else {
                toast.show("Copied \(n) item\(n == 1 ? "" : "s") to \(label)", action: "OK", for: 4) {}
            }
            hosts.client(target).map { _ in hosts.propose(.listDirectory(hosts.directoryBlock(for: folder, on: target))) }
        }
        func next(_ i: Int) {
            guard i < items.count else { return finish() }
            let item = items[i]
            let dest = folder + "/" + Self.name(of: item)
            let after: (String?) -> Void = { error in
                if error == "exists" { existing.append(item) } else if let error { failure = error; return finish() }
                next(i + 1)
            }
            switch item {
            case let .local(url):
                Transfer.upload(url, to: dest, on: c, replace: replacing, done: after)
            case let .entry(host, path, isDirectory):
                // Another tile's entry: fetched to a scratch folder here, then sent.
                guard let source = hosts.client(host) else { return after("its host isn't attached") }
                let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("manifold-copy-\(UUID().uuidString)")
                try? FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
                let local = scratch.appendingPathComponent(path.lastPathComponent)
                Transfer.download(path, isDirectory: isDirectory, on: source, to: local) { error in
                    guard error == nil else { try? FileManager.default.removeItem(at: scratch); return after(error) }
                    Transfer.upload(local, to: dest, on: c, replace: replacing) { error in
                        try? FileManager.default.removeItem(at: scratch)
                        after(error)
                    }
                }
            }
        }
        next(0)
    }

    /// This Mac's files dropped on another host's terminal: sent to the
    /// shell's folder (each a name of its own there, nothing written over),
    /// their paths there given back to be typed.
    func upload(_ urls: [URL], toShellOf block: BlockID, done: @escaping ([String]) -> Void) {
        guard let c = hosts.client(block.host), let folder = hosts.block(block)?.terminal?.cwd else { return NSSound.beep() }
        let label = hosts.label(of: block.host)
        toast.show("Sending \(urls.count == 1 ? urls[0].lastPathComponent : "\(urls.count) items") to \(label)…", action: "OK", for: 60) {}
        c.listFolder(folder) { [weak self] entries in
            var taken = Set((entries ?? []).map(\.name))
            var sent: [String] = []
            func next(_ i: Int) {
                guard i < urls.count else {
                    self?.toast.show("Sent to \(label):\(folder.abbreviatingHome)", action: "OK", for: 4) {}
                    return done(sent)
                }
                let name = Self.freeName(urls[i].lastPathComponent, taken: taken)
                taken.insert(name)
                let dest = folder + "/" + name
                Transfer.upload(urls[i], to: dest, on: c, replace: false) { error in
                    if let error {
                        self?.toast.show("Couldn't send \(urls[i].lastPathComponent): \(error)", action: "OK", for: 10) {}
                        return done(sent)
                    }
                    sent.append(dest)
                    next(i + 1)
                }
            }
            next(0)
        }
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
        }
    }

    /// Another host's file or folder, fetched to Downloads (a name of its
    /// own if one's there), shown in the Finder when it's in.
    func download(_ path: String, isDirectory: Bool, on h: HostID) {
        guard let c = hosts.client(h), let downloads = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first else { return NSSound.beep() }
        var url = downloads.appendingPathComponent(path.lastPathComponent)
        var n = 2
        while FileManager.default.fileExists(atPath: url.path) {
            let ext = path.pathExtension
            url = downloads.appendingPathComponent((path.lastPathComponent as NSString).deletingPathExtension + " \(n)" + (ext.isEmpty ? "" : "." + ext))
            n += 1
        }
        toast.show("Downloading \(path.lastPathComponent)…", action: "OK", for: 60) {}
        Transfer.download(path, isDirectory: isDirectory, on: c, to: url) { [weak self] error in
            if let error {
                self?.toast.show("Couldn't download \(path.lastPathComponent): \(error)", action: "OK", for: 10) {}
            } else {
                self?.toast.show("Downloaded \(url.lastPathComponent)", action: "Show in Finder", for: 8) {
                    NSWorkspace.shared.activateFileViewerSelecting([url])
                }
            }
        }
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
        toast.show("Fetching \(path.lastPathComponent)…", action: "OK", for: 60) {}
        LocalCopies.shared.open(path, on: c, label: hosts.label(of: h)) { [weak self] url, error in
            guard let url else { self?.toast.show("Couldn't fetch \(path.lastPathComponent): \(error ?? "")", action: "OK", for: 10) {}; return }
            self?.toast.show("\(path.lastPathComponent) opened here; saved, it goes back to \(self?.hosts.label(of: h) ?? "its host")", action: "OK", for: 6) {}
            NSWorkspace.shared.open([url], withApplicationAt: app, configuration: config)
        }
        LocalCopies.shared.onSentBack = { [weak self] name, label, error in
            self?.toast.show(error.map { "Couldn't send \(name) back to \(label): \($0)" } ?? "Sent \(name) back to \(label)", action: "OK", for: 4) {}
        }
    }

    /// A file here, as it is; one on another host, fetched afresh (20 MB at
    /// most) into a folder by host and path.
    func directoryView(_ view: DirectoryView, localURLFor path: String, done: @escaping (URL?) -> Void) {
        guard let client = hosts.client(view.block.host) else { return done(nil) }
        if client.transport.isLocal { return done(URL(fileURLWithPath: path)) }
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("manifold-previews/\(view.block.host.raw)" + path.deletingLastPathComponent)
        let url = dir.appendingPathComponent(path.lastPathComponent)
        client.readBytes(path: path, limit: 20 << 20) { data in
            guard let data else { return done(nil) }
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            guard (try? data.write(to: url)) != nil else { return done(nil) }
            done(url)
        }
    }
}

extension MainWindowController: NotebookViewDelegate {
    func notebook(_ view: NotebookView, edit: NotebookEdit) {
        hosts.client(view.block.host)?.propose(.editNotebook(block: view.block, edit: edit))
    }

    func notebook(_ view: NotebookView, run cells: [String]) {
        hosts.client(view.block.host)?.propose(.runCells(block: view.block, cells: cells))
    }

    func notebookInterrupt(_ view: NotebookView) {
        hosts.client(view.block.host)?.propose(.interruptNotebook(block: view.block))
    }

    func notebookRestart(_ view: NotebookView) {
        hosts.client(view.block.host)?.propose(.restartNotebook(block: view.block))
    }

    func notebookStart(_ view: NotebookView) {
        guard hosts.block(view.block)?.notebook?.pid == nil else { return }
        hosts.client(view.block.host)?.propose(.startNotebook(block: view.block))
    }

    /// As a terminal's ⌘-click: a path from where the shell is, an address
    /// in the browser, `file:line:column` at that place.
    func notebook(_ view: NotebookView, open target: String) {
        open(target, from: view.placement)
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
    /// What an agent changed (§7.5): its repository's working tree now
    /// against the tree as it started, every file it touched, new ones
    /// too — a diff block of its own, linked from the agent.
    func showAgentChanges(_ agent: BlockID, _ snap: TreeSnapshot, beside placement: PlacementID) {
        guard let client = hosts.client(agent.host) else { return NSSound.beep() }
        let name = hosts.block(agent)?.displayTitle ?? "the agent"
        let subject = DiffSubject.since(repo: snap.repo, tree: snap.tree, title: "Changes by \(name) in \(snap.repo.lastPathComponent)")
        let diff = client.diffBlock(subject)
        hosts.link(from: agent, to: diff, kind: .opened, context: "changes since it started")
        show(diff, lens: .diff, .besideOpener(placement), context: "changes since it started")
    }

    func gitView(_ view: GitView, openDiff subject: DiffSubject) {
        guard let client = hosts.client(view.block.host) else { return }
        let block = client.diffBlock(subject)
        var context = ""
        switch subject {
        case let .sides(_, new):
            if let file = hosts.client(view.block.host)?.textBlock(path: new.path) {
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
             kind: .opened, context: hit.text.trimmingCharacters(in: .whitespaces))
    }

    func searchViewCancel(_ view: SearchView) {
        hosts.propose(.cancelSearch(block: view.block))
    }

    /// A file's text for the preview: 4 MB at most, and not a binary one.
    func searchView(_ view: SearchView, read path: String, done: @escaping (String?) -> Void) {
        guard let client = hosts.client(view.block.host) else { return done(nil) }
        client.readBytes(path: path, limit: 4 << 20) { data in
            guard let data, !data.prefix(8192).contains(0) else { return done(nil) }
            done(String(decoding: data, as: UTF8.self))
        }
    }

    func searchView(_ view: SearchView, open path: String, line: Int) {
        open(path: path, line: line, column: 1, on: view.block.host, from: view.placement, kind: .opened, context: nil)
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
    /// A command's output as a block of its own (§3.8): the host captures
    /// what the terminal received for it — colours and all — into an
    /// output block, linked from the terminal; shown read-only, with Copy
    /// and the way back. One per command: asked again, the one there is.
    func terminal(_ view: TerminalView, show command: ShellCommand, output: String, beside: PlacementID?) {
        let place: Where = beside != nil ? .here : (Self.clickModifiers?.contains(.option) == true ? .over(view.placement) : .besideOpener(view.placement))
        // An agent's turn: the turn, as a block of its own, not the TUI's bytes.
        if hosts.block(view.block)?.terminal?.turns?.contains(where: { $0.id == command.id }) == true {
            return showTurn(command.id, of: view.block, place: place)
        }
        let context = "command \(command.id)"
        if let made = hosts.neighborhood(of: view.block).outbound[.link(.opened)]?.first(where: { $0.context == context && hosts.block($0.to)?.kind == .output }) {
            return show(made.to, lens: .output, place, kind: .opened, context: context)
        }
        let id = BlockID(host: view.block.host)
        hosts.propose(.captureOutput(block: id, terminal: view.block, command: command.id, fallback: output))
        // Shown once the host has made it (a moment).
        showWhenMade(id, lens: .output, place: place, context: context)
    }

    /// An agent's turn as its own block (§3.8): the one made before, brought
    /// up to date, else one the host makes now.
    func showTurn(_ turn: Int, of agent: BlockID, place: Where) {
        let context = "turn \(turn)"
        let made = hosts.neighborhood(of: agent).outbound[.link(.opened)]?.first(where: { $0.context == context && hosts.block($0.to)?.kind == .output })?.to
        let id = made ?? BlockID(host: agent.host)
        hosts.propose(.captureTurn(block: id, agent: agent, turn: turn))
        if made != nil { return show(id, lens: .output, place, kind: .opened, context: context) }
        showTurnWhenMade(id, place: place, context: context)
    }

    /// `context`: the link the host made for it ("turn N"), said again —
    /// a link of another context would take its place, and the turn's
    /// block then not be found to show again.
    private func showTurnWhenMade(_ id: BlockID, place: Where, context: String, tries: Int = 60) {
        if hosts.block(id)?.output?.markdown != nil { return show(id, lens: .output, place, kind: .opened, context: context) }
        guard tries > 0 else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in self?.showTurnWhenMade(id, place: place, context: context, tries: tries - 1) }
    }

    /// Changes in This Turn: the working tree between the turn's two
    /// checkpoints (as it is now, while it runs), as a diff block.
    func showTurnChanges(_ turn: AgentTurn, of agent: BlockID, beside placement: PlacementID?) {
        guard let repo = turn.repo, let before = turn.before, let client = hosts.client(agent.host) else { return NSSound.beep() }
        let first = turn.prompt.split(whereSeparator: \.isNewline).first.map(String.init) ?? "Turn"
        let diff = client.diffBlock(.trees(repo: repo, from: before, to: turn.after, title: "Turn: " + String(first.prefix(60))))
        hosts.link(from: agent, to: diff, kind: .opened, context: "changes in turn \(turn.id)")
        show(diff, lens: .diff, placement.map { .besideOpener($0) } ?? .here, context: "changes in turn \(turn.id)")
    }

    /// Undo This Turn: asked first; then the turn's changes taken back.
    func undoTurn(_ turn: AgentTurn, of agent: BlockID) {
        guard turn.before != nil, turn.after != nil else { return NSSound.beep() }
        let alert = NSAlert()
        let first = turn.prompt.split(whereSeparator: \.isNewline).first.map(String.init) ?? "the turn"
        alert.messageText = "Undo “\(first.prefix(80))”?"
        let n = turn.files?.count ?? 0
        alert.informativeText = "What the turn changed in \(turn.repo?.lastPathComponent ?? "the repository") (\(n) file\(n == 1 ? "" : "s")) is taken back, as the working tree was before it — later changes kept. If later work changed the same lines, nothing is touched and Manifold says so."
        alert.addButton(withTitle: "Undo Turn")
        alert.addButton(withTitle: "Cancel")
        guard let window else { return }
        alert.beginSheetModal(for: window) { [weak self] r in
            guard r == .alertFirstButtonReturn else { return }
            self?.hosts.propose(.undoTurn(agent: agent, turn: turn.id)) { error in
                DispatchQueue.main.async {
                    self?.toast.show(error.map { "Couldn't undo the turn: \($0)" } ?? "Turn undone", action: "OK", for: error == nil ? 4 : 10) {}
                }
            }
        }
    }

    /// The menu of an agent's turn: shown, its changes, undone.
    func turnItems(_ turn: AgentTurn, of agent: BlockID, beside placement: PlacementID?) -> [NSMenuItem] {
        var items: [NSMenuItem] = [ClosureMenuItem("Show Turn", symbol: "text.bubble") { [weak self] in
            self?.showTurn(turn.id, of: agent, place: placement.map { .besideOpener($0) } ?? .here)
        }]
        if turn.before != nil {
            items.append(ClosureMenuItem("Changes in This Turn", symbol: "plusminus") { [weak self] in self?.showTurnChanges(turn, of: agent, beside: placement) })
        }
        let undo = ClosureMenuItem("Undo This Turn…", symbol: "arrow.uturn.backward") { [weak self] in self?.undoTurn(turn, of: agent) }
        undo.isEnabled = turn.before != nil && turn.after != nil
        items.append(undo)
        return items
    }

    /// A block the host is making, shown as soon as it exists here.
    /// `context`: the link the host made for it, said again (see showTurnWhenMade).
    private func showWhenMade(_ id: BlockID, lens: Lens, place: Where, context: String? = nil, tries: Int = 40) {
        if hosts.block(id) != nil { return show(id, lens: lens, place, kind: .opened, context: context) }
        guard tries > 0 else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in self?.showWhenMade(id, lens: lens, place: place, context: context, tries: tries - 1) }
    }

    func terminal(_ view: TerminalView, menuFor command: ShellCommand) -> NSMenu? {
        let menu = NSMenu()
        if let turn = hosts.block(view.block)?.terminal?.turns?.first(where: { $0.id == command.id }) {
            for item in turnItems(turn, of: view.block, beside: view.placement) { menu.addItem(item) }
        } else {
            menu.addItem(ClosureMenuItem("Show Output", symbol: "text.alignleft") { [weak view] in _ = view?.showOutput(ofCommand: command.id, beside: view?.placement) })
            menu.addItem(ClosureMenuItem("Copy Command", symbol: "doc.on.clipboard") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(command.text, forType: .string)
            })
        }
        return menu
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

    // Even so, a second click in a row up there (⌥-clicks walking a
    // stack whose bar is at the window's top, clicks growing a tile) is
    // taken for a double click on the title bar and never reaches the
    // bar: on a tile's bar, which takes every click as one, it goes as one.
    override func sendEvent(_ event: NSEvent) {
        if [.leftMouseDown, .leftMouseUp].contains(event.type), event.clickCount > 1,
           event.locationInWindow.y > frame.height - 40, onTileBar(event.locationInWindow),
           let single = NSEvent.mouseEvent(with: event.type, location: event.locationInWindow, modifierFlags: event.modifierFlags,
                                           timestamp: event.timestamp, windowNumber: event.windowNumber, context: nil,
                                           eventNumber: event.eventNumber, clickCount: 1, pressure: event.pressure) {
            return super.sendEvent(single)
        }
        super.sendEvent(event)
    }

    private func onTileBar(_ p: NSPoint) -> Bool {
        guard let content = contentView, var v = content.hitTest(content.superview?.convert(p, from: nil) ?? p) else { return false }
        while true {
            if v is TilePill { return true }
            guard let up = v.superview else { return false }
            v = up
        }
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
    func organizationOpen(_ node: OrgNode, modifiers: NSEvent.ModifierFlags) {
        HoverCard.shared.hide()
        let over = modifiers.contains(.option), beside = modifiers.contains(.command)
        if let arr = node.arrangement, !over, !beside {
            hideStateView()
            if arr != selected { hosts.select(arr) }
            if let p = node.placement, let a = hosts.arrangement(arr), a.placement(p) != nil {
                // Out of its stack, from behind a maximized tile, focused,
                // and the pointer on it.
                hosts.append(arriving(p, in: a), to: .block(arr))
                warpPointerToFocus()
            }
            return
        }
        guard let block = node.block, let b = hosts.block(block) else { return }
        if b.kind == .arrangement { return hosts.select(block) }
        // The rule (§3.1): plain goes to it where it is (here, if nowhere);
        // ⌥ puts it over the focused tile; ⌘ beside it.
        let lens = Lens.default(for: b.kind, path: b.path)
        if over, let f = arrangement?.focused { show(block, lens: lens, .over(f)) }
        else if beside, let f = arrangement?.focused { show(block, lens: lens, .besideOpener(f)) }
        else if beside { show(block, lens: lens, .here) }
        else { arrive(block, from: arrangement?.focused, over: false) }
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
        // Its tile, if one is on screen: a picture of it, as Safari shows a
        // tab — a terminal as the text on its screen, a page by its own
        // snapshot (which comes a moment later), the rest as they draw.
        // Out of sight (another workspace, stacked, collapsed, or nowhere):
        // the block itself, live, its view lent to the card — or, failing
        // that, a terminal as its screen still holds it, the rest as last
        // pictured.
        let key = id.description
        var picture: NSImage? = nil
        var lend: (() -> HoverCard.LiveLoan?)? = nil
        if let shown = content.views.first(where: { $0.block == id && $0.superview != nil && !$0.isHiddenOrHasHiddenAncestor && $0.window === window }) {
            switch shown {
            case let t as TerminalView:
                picture = HoverCard.picture(of: t)
                if picture == nil {
                    body = t.visibleText
                    font = hosts.state.appearance.theme.font(.monospaced, size: 11)
                }
            case let w as WebView:
                w.snapshot { [weak self] image in
                    if let image { self?.tilePictures[id] = image }
                    HoverCard.shared.updatePicture(image, for: key)
                }
            case let m as MarkdownView:
                m.snapshot { [weak self] image in
                    if let image { self?.tilePictures[id] = image }
                    HoverCard.shared.updatePicture(image, for: key)
                }
            default:
                picture = HoverCard.picture(of: shown)
            }
            if let picture { tilePictures[id] = picture }
        } else {
            lend = { [weak self] in self?.lendView(of: id) }
            if let t = views.values.first(where: { $0.block == id && $0 is TerminalView }) as? TerminalView,
               let image = HoverCard.surfacePicture(of: t) {
                picture = image
            } else if let kept = tilePictures[id] {
                picture = kept
            }
        }
        HoverCard.shared.show(key: key, title: b.displayTitle, detail: detail, body: body, font: font, picture: picture, lend: lend, beside: rect, in: window)
    }

    /// The block's own view, for a card to show live while the block is
    /// out of sight: a view it has that isn't showing (another workspace's,
    /// or stacked or collapsed in this one), lent and put back as it was;
    /// else one made for the card, let go after (its state not kept).
    private func lendView(of id: BlockID) -> HoverCard.LiveLoan? {
        guard let b = hosts.block(id), b.kind != .arrangement else { return nil }
        let size = NSSize(width: 760, height: 520)
        if let v = views.values.first(where: { $0.block == id && ($0.window == nil || $0.isHiddenOrHasHiddenAncestor) && !($0 is PlaceholderView) }) {
            let inGrid = v.superview === content
            let wasHidden = v.isHidden, frame = v.frame
            if inGrid { content.lend(v.placement) }
            let own = frame.width > 200 && frame.height > 120 ? frame.size : size
            return HoverCard.LiveLoan(view: v, size: own) { [weak self] view in
                guard let self else { return }
                view.frame = frame
                view.isHidden = wasHidden
                if inGrid { self.content.takeBack(v.placement, view: view) }
            }
        }
        // None made yet (a workspace not shown since launch, a block placed nowhere).
        let p = Placement(id: "hover:\(id)", block: id, lens: Lens.default(for: b.kind, path: b.path))
        let v = view(for: shown(p))
        views.removeValue(forKey: p.id)
        (v as? KeepsViewState)?.keeper.save = nil
        return HoverCard.LiveLoan(view: v, size: size) { view in
            view.removeFromSuperview()
            (view as? PaneContent)?.destroy()
        }
    }

    func rememberPicture(of view: PaneContent) {
        switch view {
        case let w as WebView:
            w.snapshot { [weak self] image in if let image { self?.tilePictures[view.block] = image } }
        case let m as MarkdownView:
            m.snapshot { [weak self] image in if let image { self?.tilePictures[view.block] = image } }
        default:
            if let image = HoverCard.picture(of: view) { tilePictures[view.block] = image }
        }
        // Kept for the blocks still about.
        if tilePictures.count > 200 { tilePictures = tilePictures.filter { hosts.block($0.key) != nil } }
    }

    func organizationMenu(for node: OrgNode) -> NSMenu? {
        let menu = NSMenu()
        if node.id.hasPrefix("host:"), let c = hosts.all.first(where: { "host:\($0.host.raw)" == node.id }), !c.isRemote {
            for item in hostItems(c.host) { menu.addItem(item) }
            return menu
        }
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
            for item in hostItems(c.host) { menu.addItem(item) }
            menu.addItem(ClosureMenuItem("Detach from \(hosts.label(of: c.host))…", symbol: "xmark") { [weak self] in
                self?.detach(c.host)
            })
            return menu
        }
        if let arr = node.arrangement, node.column == nil {
            menu.addItem(ClosureMenuItem("Name…", symbol: "pencil") { [weak self] in self?.rename(arr) })
            menu.addItem(.separator())
            menu.addItem(ClosureMenuItem("Take Off the Desk", symbol: "xmark") { [weak self] in self?.removeFromDesk(arr) })
            menu.addItem(.separator())
            menu.addItem(hostSubmenu(arr.host))
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
            menu.addItem(ClosureMenuItem("Go To", symbol: "arrow.right.circle") { [weak self] in self?.organizationOpen(node, modifiers: []) })
            menu.addItem(ClosureMenuItem("Show Beside", symbol: "rectangle.split.2x1") { [weak self] in self?.organizationOpen(node, modifiers: [.command]) })
            menu.addItem(ClosureMenuItem("Show Over", symbol: "square.stack") { [weak self] in self?.organizationOpen(node, modifiers: [.option]) })
            if let b = hosts.block(id), b.kind != .arrangement {
                menu.addItem(.separator())
                for item in keepingItems(for: b) { menu.addItem(item) }
            }
            menu.addItem(.separator())
        }
        menu.addItem(ClosureMenuItem("Show the Neighborhood Map", symbol: "point.3.connected.trianglepath.dotted") { [weak self] in
            self?.showNeighborhood(around: id)
        })
        menu.addItem(.separator())
        menu.addItem(hostSubmenu(id.host))
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
            if let node { return node.arrangement != nil || node.id.hasPrefix("host:") || node.id.hasPrefix("kept:") }
            return index >= 0
        }
    }

    func organizationSpring(_ node: OrgNode) {
        guard let arr = node.arrangement, arr != selected else { return }
        hosts.select(arr)
    }

    func organizationDrop(_ item: OrgDragItem, onto node: OrgNode?, at index: Int, copy: Bool) -> Bool {
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
        if let node, node.id.hasPrefix("kept:") {
            // Onto Kept: kept (§4), and left where it is.
            hosts.pin(block, true)
            return true
        }
        if let node, let arr = node.arrangement {
            // Onto a column: shown there; onto an arrangement: in its
            // focused column. Moved from where it was, or with ⌥ copied —
            // there as well as here.
            let place: Where = node.column.map { .inColumn($0) } ?? .here
            show(block, lens: lens, place, in: arr)
            if let from, from.arrangement != arr, !copy { takeOut(from.placement.id, of: from.arrangement) }
            hosts.select(arr)
            return true
        }
        guard node == nil else { return false }
        // Between arrangements: one of its own there.
        if !copy, let from, hosts.arrangement(from.arrangement)?.placements.count == 1 {
            sidebarMove(from.arrangement, to: index)
            return true
        }
        if let from, !copy { takeOut(from.placement.id, of: from.arrangement) }
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
        case .inactive, .connecting, .offline: self = .inactive
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

extension MainWindowController: OutputViewDelegate {
    func output(_ view: OutputView, showSource source: BlockID, command: Int) {
        arrive(source, from: view.placement, over: false)
        goToCommand(command, in: source)
    }
}

/// A menu of something on a host — a terminal's, an editor's — ends with
/// the host's own (Reset Server, Reset Graph): the window controller says
/// what that is.
@MainActor
enum HostMenu {
    static var submenu: ((HostID) -> NSMenuItem?)?

    static func append(for host: HostID, to menu: NSMenu) {
        guard let item = submenu?(host) else { return }
        menu.addItem(.separator())
        menu.addItem(item)
    }
}
