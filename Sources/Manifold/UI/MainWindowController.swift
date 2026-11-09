import AppKit
import WebKit
import ManifoldCore
import ManifoldSyntax
import UniformTypeIdentifiers
import PDFKit

/// The window: the selected arrangement filling it, the sidebar (the desk)
/// floating over its left edge when the mouse goes there (or docked, when
/// pinned), and Open Quickly.
final class MainWindowController: NSWindowController, NSWindowDelegate {
    let hosts: Hosts
    /// This machine's host: the desk and settings are its.
    var host: HostClient { hosts.local }
    let root = RootView()
    private let glass = NSVisualEffectView()
    let backdrop = BackdropView()
    /// The grid of the workspace shown. Each workspace used lately keeps its
    /// own (`grids`), hidden while another shows: going back to it shows it
    /// again as it was, nothing laid out or drawn afresh.
    private(set) var content = GridView()
    /// Each tile shrunk to its summary, with its height before, to go back to.
    var unshrunk: [PlacementID: Double] = [:]
    /// The grid for no workspace (none selected).
    lazy var blankGrid: GridView = content
    /// The content area, which the grids are clipped to as a workspace
    /// slides (⌘`): one sliding out leaves through its edge, never under
    /// the sidebar (which is translucent, and would show it). Not at rest:
    /// the tiles' shadows fall past it, under the sidebar, as on one
    /// surface — clipped there, a column's shadow stopped in a line at
    /// the sidebar's edge, a band of another colour beside it.
    let stage: NSView = {
        let v = NSView()
        v.wantsLayer = true
        v.layer?.masksToBounds = false
        return v
    }()
    /// The grids of the workspaces used lately, most recent first, kept in
    /// the window (hidden): `liveGrids` of them, so the tiles' drawings
    /// they hold don't grow with the desk; an older workspace's tiles go
    /// out of the window as they used to, and come back when it's shown.
    var grids: [BlockID: GridView] = [:]
    var gridOrder: [BlockID] = []
    static let liveGrids = 4
    /// The grid sliding away, while it does.
    var slidingAway: GridView?
    /// Blocks awaited from their hosts (`whenMade`).
    struct MadeWait {
        let id: BlockID, what: String, made: () -> Bool, then: () -> Void, started: Date
        var said = false
    }
    var madeWaits: [MadeWait] = []
    var madeWaitTimer: Timer?
    /// The arrangement `content` shows.
    private var shownArrangement: BlockID?
    var sliding = false
    /// A place settled on: a tile in its space (none, a space with
    /// nothing focused).
    struct Settled: Equatable {
        var space: BlockID
        var tile: PlacementID?
    }
    /// The places settled on in this window, the latest first: the trail
    /// as this window has it, which every switcher walks at its own scale —
    /// ⌘` its spaces, ⌃⇥ the space's tiles (its docked ones too). Those
    /// only passed on a walk aren't in it, and it doesn't wait on a host to
    /// hear of a switch (the hosts' trail, which comes after, fills in the
    /// rest).
    var settled: [Settled] = []
    /// ⌃⇥'s walk, while control is held: the places in the order it began
    /// with, how far along it is, and what shows its cards if it's held.
    var tileWalk: (places: [Settled], index: Int, show: DispatchWorkItem)?
    var tileMonitors: [Any] = []
    var tileLeaving: NSObjectProtocol?
    /// ⌃⇥'s cards, once they show, and their pictures on their way.
    var tileSwitcher: (frame: NSView, column: CardColumnView)?
    var tileFlights: [CALayer] = []
    let sidebar = SidebarView()
    /// What the window shows with no space at all.
    private var emptyState: EmptyStateView?
    /// Each placement's view, for every arrangement on the desk.
    var views: [PlacementID: PaneContent] = [:]
    /// `mani`'s commands, done here.
    lazy var maniDesk = ManiDesk(self)
    /// Threads' cards and chats on screen (§3.12).
    let threadUI = ThreadUI()
    private var seenTimer: Timer?
    private var lastSeenSent = Date.distantPast
    private var lastSeenSet: Set<BlockID> = []

    /// A place to go in a file being opened: done once its editor is shown.
    var pendingJump: (path: String, line: Int, column: Int?)?
    /// Tiles ⌘↩ made, each with the line the tile it replaced had at its top.
    var pendingTopLines: [PlacementID: Double] = [:]
    private var clickMonitor: Any?
    /// Blocks whose terminal just closed; they get a new one after a moment
    /// if their shell is still there (the server was restarted, not the
    /// shell ended).
    var recentlyClosed: Set<BlockID> = []
    private(set) var sidebarShown = false {
        // The copies' badge only while the sidebar (which shows them) is away.
        didSet { if sidebarShown != oldValue { transfersChanged() } }
    }
    var draggingTab = false
    let hideWork = Debouncer()
    private let saveFrameWork = Debouncer()

    /// The sidebar's width while its handle is being dragged.
    var resizingWidth: CGFloat?

    var desk: DeskState { host.desk }
    private var sidebarWidth: CGFloat {
        let w = resizingWidth ?? hosts.state.window.sidebarWidth.map { CGFloat($0) } ?? Theme.sidebarWidth
        return min(max(w, Theme.sidebarWidthRange.lowerBound), Theme.sidebarWidthRange.upperBound)
    }
    var selected: BlockID? { hosts.state.selected }
    var arrangement: ArrangementState? { hosts.arrangement(selected) }
    var pinned: Bool { hosts.state.window.sidebarPinned }

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
        // Both grids stay in the window: the one slid away is hidden, not
        // taken out — putting a view back in a window tells every view in
        // it (a web view waits on its process to hear it), at each switch.
        stage.addSubview(content)
        root.addSubview(stage)
        root.addSubview(sidebar)
        root.addSubview(toast.window)
        toast.stack = sidebar.toasts
        toast.inSidebar = { [weak self] in self.map { $0.sidebarShown || $0.pinned } ?? false }
        toast.reveal = { [weak self] in self?.showSidebar(animated: true) }
        ChatBox.chipFor = { [weak self] id in self?.mentionChip(id) }
        watchCommandKey()
        // Copies on their way (§8): in the sidebar, and, while it's away,
        // a badge at the lower left that brings it out.
        transfersBadge.isHidden = true
        transfersBadge.onClick = { [weak self] in self?.showSidebar(animated: true) }
        root.addSubview(transfersBadge)
        NotificationCenter.default.addObserver(forName: Transfers.changed, object: nil, queue: .main) { [weak self] _ in
            self?.transfersChanged()
        }
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
        setUp(content)
        _ = blankGrid
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
        installGlobalHooks()
        watchNavKeys()
        HostMenu.submenu = { [weak self] host in self?.hostSubmenu(host) }
        // A site's icon arrived: its pages' rows and bars show it.
        NotificationCenter.default.addObserver(forName: .manifoldFaviconsChanged, object: nil, queue: .main) { [weak self] _ in
            MainActor.unchecked { self?.render() }
        }
        seenTimer = Timer.scheduledTimer(withTimeInterval: 15, repeats: true) { [weak self] _ in
            self?.noteSeen(force: true)
        }
        hosts.onTerminalEnded = { [weak self] block in self?.terminalEnded(block) }
        hosts.onHistory = { [weak self] shard, base, entries in self?.historyArrived(shard, base?.state.block, entries) }
        hosts.onCommand = { [weak self] host, id, client, request in
            self?.maniCommand(on: host, id: id, client: client, request)
        }
        hosts.onCommandEnded = { [weak self] host, id, client in
            self?.maniCommandEnded(on: host, id: id, client: client)
        }
        hosts.onShow = { [weak self] host, id, client, block, beside in
            self?.showRequest(on: host, id: id, client: client, block: block, beside: beside)
        }
        hosts.onLanguageServer = { [weak self] _, _, _, _ in self?.settingsWindow?.refresh() }
        hosts.onErased = { [weak self] client, by in self?.sessionErased(client, by: by) }
        hosts.onReplaced = { [weak self] client, _ in
            guard let self, client.isRemote else { return }
            self.toast.say("The session on \(self.hosts.label(of: client.host)) was gone — deleted there; a new one started", .long)
        }
        hosts.onFenced = { [weak self] client in
            self?.sayWatching(client)
            self?.refreshOrganization()
        }
        hosts.onRefused = { [weak self] client in self?.sayWatching(client, again: true) }
        hosts.onGutter = { [weak self] block in
            guard let self else { return }
            for e in self.views(of: block, as: EditorView.self) { e.gutterChanged() }
        }
        hosts.onNotebookLive = { [weak self] block, cell, output in
            guard let self else { return }
            for n in self.views(of: block, as: NotebookView.self) { n.live(cell: cell, output: output) }
        }
        hosts.onDiagnostics = { [weak self] block in
            guard let self else { return }
            for e in self.views(of: block, as: EditorView.self) { e.diagnosticsChanged() }
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
            // Terminals that couldn't be made while it slept, tried again now.
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { self?.deadRetries = [:]; self?.render() }
        }
        // Reduce motion turned on or off: working's names shimmer, or hold
        // still with a dot (`StatusMark`), everywhere at once.
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            self?.render()
            self?.refreshOrganization(now: true)
        }
    }

    required init?(coder: NSCoder) { fatalError() }

    // MARK: Rendering

    /// What's known of a placement on the desk.
    /// The tiles showing a block (in any space), as a kind of view.
    func views<T>(of block: BlockID, as: T.Type = PaneContent.self) -> [T] {
        views.values.compactMap { $0.block == block ? $0 as? T : nil }
    }

    /// A tile showing a block, as a kind of view: the shown space's, if it
    /// has one, else any.
    func view<T>(of block: BlockID, as type: T.Type = PaneContent.self) -> T? {
        arrangement?.placements(of: block).lazy.compactMap { self.views[$0.id] as? T }.first ?? views(of: block, as: type).first
    }

    /// The focused tile's view.
    var focusedView: PaneContent? { focusedView }

    /// The focused tile, and its view as a kind of view (nil when it's another).
    func focused<T>(_ type: T.Type) -> (shown: Shown, view: T)? {
        guard let f = focusedShown, let v = views[f.id] as? T else { return nil }
        return (f, v)
    }

    func shown(_ id: PlacementID) -> Shown? {
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
    /// sight: taken as a tile is docked, collapsed or maximized over, as
    /// its workspace is left, and whenever its card is shown.
    var tilePictures: [BlockID: NSImage] = [:]

    /// Rendering now, and a render asked for meanwhile.
    private var rendering = false
    private var renderAgain = false

    /// Everything brought in line with the state. Asked for while it's
    /// under way — a view being made that tells of itself (an editor of a
    /// dirty text, set to viewing, says it's edited) — it's done once more
    /// right after, not inside itself: within, the view isn't kept yet,
    /// so it would be made again, and again, until the stack ran out.
    func render() {
        maniDesk.modelChanged()
        threadsChanged()
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
        // When the focus last moved to another tile (or space): an arrival
        // marks the tile only then, not a move within the one it's on.
        let now = (selected, arrangement?.focused)
        if now.0 != focusWas.0 || now.1 != focusWas.1 {
            focusWas = now
            focusMovedAt = Date()
        }
    }

    private var focusWas: (BlockID?, PlacementID?) = (nil, nil)
    var focusMovedAt = Date.distantPast

    private func renderNow() {
        guard let window else { return }
        let appearance = hosts.state.appearance
        if FontTheme.current != appearance.theme || FontTheme.typography != appearance.typography {
            // Custom typography changed under the same theme too: what's
            // set in it is told, as for a new theme.
            FontTheme.current = appearance.theme
            FontTheme.typography = appearance.typography
            for case let v as FollowsFontTheme in views.values { v.fontThemeChanged() }
        }
        settingsWindow?.refresh(tables: false)
        sidebar.pinned = pinned
        if pinned && !sidebarShown { showSidebar(animated: false) }

        // Views for placements no longer on the desk go (a state view's stay
        // while it's up: its blocks are settled before any view is made,
        // since making one can render again).
        func item(_ b: Block) -> (Block, StatusRecord?, Stamp) { (b, b.statusRecord, b.statusRecord?.at ?? b.created) }
        var stateBlocks = stateGroup.map { statusGroups()[$0] ?? [] } ?? []
        var stateLenses: [BlockID: Lens] = [:]
        if let w = stateWorkspace, let a = hosts.arrangement(w) {
            // ⌘': the workspace's blocks, each as its tile shows it.
            for p in a.placements where stateLenses[p.block] == nil {
                guard let b = hosts.block(p.block) else { continue }
                stateLenses[p.block] = p.lens
                stateBlocks.append(item(b))
            }
        }
        if stateAgents {
            // Every agent on every host: those that need you first, then
            // those at work, those done, those idle or ended.
            stateBlocks = agentBlocks().map(item)
            stateMembers = stateBlocks.map(\.0.id)
        } else if stateShown != nil {
            // Membership sticks while the view is up: a block that leaves
            // the state for a moment (a diff reloading, a repository
            // refreshing) keeps its place rather than its view being torn
            // down and made again; new arrivals come first.
            let current = Set(stateBlocks.map(\.0.id))
            let staying = stateMembers.filter { !current.contains($0) }.compactMap { hosts.block($0).map(item) }
            let arrivals = stateBlocks.filter { !stateMembers.contains($0.0.id) }
            let kept = stateMembers.compactMap { id in stateBlocks.first { $0.0.id == id } ?? staying.first { $0.0.id == id } }
            stateBlocks = arrivals + kept
            stateMembers = stateBlocks.map(\.0.id)
        }
        pruneGrids()
        var onDesk = Set(allWorkspaces.compactMap { hosts.arrangement($0) }.flatMap { $0.placements.map(\.id) })
        onDesk.formUnion(stateBlocks.map { Self.statePlacement($0.0.id) })
        for (id, view) in views where !onDesk.contains(id) {
            // Seen going, where it was, as its neighbours take its room.
            if view.superview === content { content.poof(view) }
            view.removeFromSuperview()
            view.destroy()
            views.removeValue(forKey: id)
        }

        if selected != shownArrangement {
            // A card's lent view goes home before the workspace changes
            // under it (it may be one of the workspace coming in).
            HoverCard.shared.hide()
            // The workspace left: each tile it showed pictured, for its card —
            // once it's sliding away (the slide is Core Animation's, so the
            // pictures don't hold it up), as it still shows then; with no
            // slide, before its views go.
            let old = content
            let leaving = old.views.filter { $0.superview != nil && !$0.isHiddenOrHasHiddenAncestor }
            content = grid(for: selected)
            content.frame = stage.bounds
            content.isHidden = stateView != nil
            if old !== content {
                if let from = shownArrangement, let to = selected {
                    let dir = slideDirection(from: from, to: to)
                    slide(dir, leaving: old)
                    // The sidebar's space slides with it, the next turn (its
                    // tree made then, at once).
                    DispatchQueue.main.async { [weak self] in
                        guard let self else { return }
                        if self.sidebar.organization == .desk {
                            self.sidebar.slideSpace(dir) { self.refreshOrganization(now: true) }
                        } else {
                            self.refreshSpaceStrip()
                        }
                    }
                } else {
                    old.isHidden = true
                }
            }
            // Pictured for their cards once switching has been quiet a
            // second, one a turn — its grid kept, the workspace left is
            // still drawn (hidden), so nothing is lost by waiting; a card
            // wanted sooner pictures its tile itself.
            picture(leaving)
            shownArrangement = selected
            if tileWalk == nil { settleHere() }
        }

        if let a = arrangement {
            // The grid (§3.1): every tile, in its column, top to bottom.
            let tiles = a.columns.map { column in
                column.filter { !recentlyClosed.contains($0.block) }.map { p -> GridView.Tile in
                    let shown = self.shown(p)
                    return GridView.Tile(shown: shown, view: view(for: shown), links: links(of: p.block))
                }
            }.filter { !$0.isEmpty }
            // $EDITOR's stacks, as the space keeps them (a terminal docked
            // under an editor's tile): known again after a restart.
            for d in a.docked {
                guard let top = d.under, stackTops[top] == nil, a.placement(top)?.lens == .editor,
                      hosts.block(d.placement.block)?.kind == .terminal else { continue }
                stackTops[top] = d.placement.id
                stacked.insert(d.placement.id)
            }
            let flights = dockFlights(before: a)
            content.departure = { [weak self] v in self?.departure(of: v, flown: flights) ?? .moved }
            content.show(tiles, fractions: a.fractions, heights: a.heights, focused: a.focused, full: a.full)
            flyDock(flights)
            window.title = title(of: a)
            // The keyboard may be in no view at all (the window's, after
            // the view it was in went, as a closed editor's does).
            let responder = window.firstResponder as? NSView
            // Nor while a pill is a field (a note being named, an address typed).
            if emptyState == nil, stateView == nil, history == nil, neighborhoodView == nil, !content.isEditingPill,
               let focused = a.focused, let view = views[focused], view.superview != nil,
               !(responder?.isDescendant(of: view) ?? false) {
                // Not while something is over the window with the keyboard.
                if focused == lastFocused, let responder,
                   ([threadUI.overlay, sidebar, footerMenu.view] as [NSView?]).contains(where: { $0.map(responder.isDescendant(of:)) ?? false }) {
                    // Typing in the threads' overlay or the sidebar (its
                    // composer, its filter): a refresh, the focus where it
                    // was, leaves the keyboard there.
                } else if focused == lastFocused, let responder,
                   let typing = views.first(where: { $0.value.superview != nil && !$0.value.isHidden && responder.isDescendant(of: $0.value) })?.key,
                   a.locate(typing) != nil {
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
            for case let m as MarkdownView in views.values { m.textChanged(); m.refreshCards(); m.refreshPlaces() }
            for case let e as EditorView in views.values { e.documentChanged(); e.refreshPills() }
            for case let o as OutlineNoteView in views.values { o.theme = hosts.state.appearance.theme; o.documentChanged(); o.threadPlaces = places(of: o.block) }
            let codeFont = hosts.state.appearance.theme.font(.monospaced, size: 12.5)
            for case let o as OutputView in views.values { o.font = codeFont; o.refresh() }
            for case let n as NotebookView in views.values { n.codeFont = codeFont; n.documentChanged() }
            for case let d as DirectoryView in views.values { d.documentChanged() }
            for case let w as WebView in views.values { w.documentChanged() }
            for case let s as SearchView in views.values { s.codeFont = codeFont; s.documentChanged() }
            for case let g as GitView in views.values { g.documentChanged() }
            for case let pv as ProcessView in views.values { pv.documentChanged() }
            for case let d as DiffView in views.values { d.documentChanged() }
            for case let panel as PanelView in views.values { panel.documentChanged() }
        } else {
            content.clear()
            window.title = "Manifold"
        }
        if let stateView, stateShown != nil {
            // As chosen; else, past ten blocks, their summaries (live views
            // of so many would be small, and dear).
            let mode = stateModeChosen ?? (stateBlocks.count > 10 ? .summaries : stateMode)
            let items = stateBlocks.map { block, _, _ -> StateView.Item in
                let lens = stateLenses[block.id] ?? Lens.default(for: block.kind, path: block.path)
                let p = Placement(id: Self.statePlacement(block.id), block: block.id, lens: lens)
                var shown = Shown(placement: p, block: block)
                if stateAgents { shown.caption = agentCaption(block) }
                if mode == .summaries { return StateView.Item(shown: shown, view: nil, summary: cardContent(for: block.id)) }
                return StateView.Item(shown: shown, view: view(for: shown), summary: nil)
            }
            let title = stateGroup?.title ?? "Overview"
            stateView.show(items, title: title, mode: mode, filter: stateGroup == nil ? (stateAgents ? 1 : 0) : nil)
            window.title = stateAgents ? "Agents" : title
        }
        noteSeen(force: false)
        noteEditing()
        checkOpenWaits()
        if !madeWaits.isEmpty { DispatchQueue.main.async { [weak self] in self?.checkMadeWaits() } }
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
            if emptyState == nil {
                let v = EmptyStateView(target: self)
                v.frame = stage.frame
                root.addSubview(v, positioned: .above, relativeTo: stage)
                emptyState = v
            }
        } else if let v = emptyState {
            v.removeFromSuperview()
            emptyState = nil
        }
    }

    /// An arrangement's title: its name, else what's focused in it.
    /// A workspace's name: the one given; else, by what it holds — the
    /// folder most of its blocks are at (with its repository's branch,
    /// when a git block is there), else the focused block's name.
    func title(of a: ArrangementState) -> String {
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
        if let t = stackedTerminal(p.id) {
            s.stackedOver = t.displayTitle
            s.caption = t.displayTitle
        }
        s.version = hosts.client(of: p.block)?.node.seq(.block(p.block)) ?? 0
        // A space's timeline (§3.12): said so, not the space's name.
        if p.lens == .threads {
            let n = hosts.threads(inSpace: p.block).reduce(0) { $0 + hosts.unseen($1).count }
            s.caption = "Threads" + (n > 0 ? " · \(n) new" : "")
        }
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

    /// When a dead view may be made again, and how long it waited last.
    private var deadRetries: [PlacementID: (next: Date, wait: TimeInterval)] = [:]

    private func view(for shown: Shown) -> PaneContent {
        // A tile kept from when there was an outline lens (a tile's sidebar
        // is its outline now): the block through its own lens.
        if shown.placement.lens == .outline, let b = shown.block {
            var own = shown
            own.placement.lens = Lens.default(for: b.kind, path: b.path)
            return view(for: own)
        }
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
            // Its host there, the block on its way (one just made, a round
            // trip off): the tile as it will be, quiet for a moment, rather
            // than words that go as they're read.
            if hosts.client(p.block.host)?.link == .connected {
                v.waitQuietly(paper: p.lens == .terminal || p.lens == .agent ? TerminalPalette.current(for: v).background : Theme.windowBackground)
            }
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
            if let d = v as? DiffView {
                d.theme = hosts.state.appearance.theme
                // Its rows may have come again (reloaded): the marks put on them again.
                markThreads(in: d)
            }
            if let t = v as? TerminalView {
                t.commands = hosts.block(p.block)?.terminal?.commands ?? []
                t.isAgent = isAgent(p)
            t.turns = Set(hosts.block(p.block)?.terminal?.turns?.map(\.id) ?? [])
                t.turns = Set(hosts.block(p.block)?.terminal?.turns?.map(\.id) ?? [])
                t.resumeIfLinkBack()
            }
            (v as? SmartlogView)?.refresh()
            if !v.isDead { return v }
            // Dead (a terminal whose surface couldn't be made — the display
            // asleep, no GPU): made again, but not at every render — each
            // try sets Metal up, and while the display slept every terminal
            // was torn down and made afresh every couple of seconds. Tried
            // again in 2 s, then 4, 8… a minute at most; at once when the
            // screens wake.
            if let retry = deadRetries[p.id], Date() < retry.next { return v }
            let wait = min((deadRetries[p.id]?.wait ?? 1) * 2, 60)
            deadRetries[p.id] = (Date().addingTimeInterval(wait), wait)
            v.removeFromSuperview()
            v.destroy()
            }
        }
        let v: PaneContent
        switch p.lens {
        case .terminal, .agent:
            let t = TerminalView(placement: p.id, block: p.block, client: hosts.client(p.block.host))
            t.delegate = self
            t.commands = hosts.block(p.block)?.terminal?.commands ?? []
            t.isAgent = isAgent(p)
            t.readingPassword = SecureInput.shared.reading.contains(p.block)
            t.setSidebar(viewState(of: p)["outline"] == "1")
            t.onToggleSidebar = { [weak self] shown in self?.keepViewState(["outline": shown ? "1" : "0"], of: p) }
            SecureInput.shared.onChange = { [weak self] block in
                for v in self?.views(of: block, as: TerminalView.self) ?? [] {
                    v.readingPassword = SecureInput.shared.reading.contains(block)
                }
            }
            t.directory = { [weak self] in self?.hosts.block(p.block)?.terminal?.cwd }
            t.pathSource = { [weak self] in
                guard let self, let cwd = self.hosts.block(p.block)?.terminal?.cwd, let client = self.hosts.client(p.block.host) else { return nil }
                let here = p.block.host == self.host.host
                return PathInserter.Source(host: p.block.host, directory: cwd, home: here ? NSHomeDirectory() : client.home,
                                           listFolder: { path, done in client.listFolder(path, done: done) }, type: { _ in })
            }
            if p.block.host != host.host {
                t.uploadDrop = { [weak self] urls, done in self?.upload(urls, toShellOf: p.block, done: done) }
                t.lookUp = { [weak self] paths, done in
                    guard let client = self?.hosts.client(p.block.host) else { return done(nil) }
                    client.lookUp(paths, done: done)
                }
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
            pv.blockCard = { [weak self] in self?.cardContent(for: $0) }
            pv.client = { [weak self] in self?.hosts.client(p.block.host) }
            v = pv
        case .outline:
            // (Shown as the block's own view, above.)
            v = PlaceholderView(placement: p.id, block: p.block, label: hosts.label(of: p.block.host))
        case .preview where Lens.viewRendering(for: shown.path) == .markdown:
            let m = MarkdownView(placement: p.id, block: p.block, path: shown.path ?? "", theme: hosts.state.appearance.theme)
            m.imageSource = { [weak self] id in self?.imageSource(id) }
            m.cardFor = { [weak self] id, place in self?.hosts.block(id)?.kind == .image ? nil : self?.cardContent(for: id, at: place) }
            m.delegate = self
            m.takesDrops = shown.block?.kind == .text
            m.placesFor = { [weak self] in self?.places(of: p.block) ?? [] }
            m.source = { [weak self] in
                guard let t = self?.hosts.block(p.block)?.text else { return nil }
                return (t.text.string, t.version)
            }
            m.isUnread = { [weak self] in
                guard let b = self?.hosts.block(p.block), b.path != nil else { return false }
                return b.text?.isUnread ?? true
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
        case .smartlog:
            let s = SmartlogView(placement: p.id, block: p.block)
            s.delegate = self
            s.source = { [weak self] in self?.hosts.block(p.block) }
            s.refresh()
            // The host's smartlog may have stopped since (a restart): asked for.
            smartlogStart(s)
            v = s
        case .threads:
            let t = ThreadsTimelineTileView(placement: p.id, block: p.block)
            watch(t.timeline)
            v = t
        case .thread:
            let t = ThreadTileView(placement: p.id, block: p.block)
            t.chat.threadID = p.block
            t.chat.show(chatModel(thread: hosts.block(p.block), place: nil, inTile: true))
            watch(t.chat)
            v = t
        case .ui:
            let panel = PanelView(placement: p.id, block: p.block)
            panel.delegate = self
            panel.source = { [weak self] in self?.hosts.block(p.block) }
            panel.documentChanged()
            v = panel
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
            m.cardFor = { [weak self] id, place in self?.hosts.block(id)?.kind == .image ? nil : self?.cardContent(for: id, at: place) }
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
            d.onThreads = { [weak self, weak d] row, rect in
                guard let self, let d else { return }
                self.diffThreadsClicked(d, row: row, rect: rect)
            }
            markThreads(in: d)
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
        case .outliner:
            // A note as an outline: its Markdown read into rows, written
            // back as they change.
            let o = OutlineNoteView(placement: p.id, block: p.block, theme: hosts.state.appearance.theme)
            o.source = { [weak self] in self?.hosts.block(p.block) }
            o.apply = { [weak self] edits in self?.hosts.append(.edit(edits), to: .block(p.block)) }
            o.onOpen = { [weak self] target in self?.open(target, from: p.id) }
            o.onLinked = { [weak self] b in self?.link(b, to: p.block) }
            o.keepImage = { [weak self] data, kind, insert in self?.keepImage(data, kind: kind, for: p.block, insert: insert) }
            o.cardFor = { [weak self] id, place in self?.cardContent(for: id, at: place) }
            o.onThreads = { [weak self, weak o] line, rect in
                guard let self, let o else { return }
                let ids = self.threads(inText: o.block, line: line)
                if !ids.isEmpty { self.showThreadCard(threads: ids, at: rect, in: o) }
            }
            o.pictureFor = { [weak self] source in self?.picture(source, in: p.block) }
            o.documentChanged()
            v = o
        default:
            let e = EditorView(placement: p.id, block: p.block, path: shown.path ?? "",
                               font: editorFont(for: p, path: shown.path),
                               theme: hosts.state.appearance.theme)
            e.delegate = self
            e.textView.onThreads = { [weak self, weak e] line, rect in
                guard let self, let e else { return }
                self.editorThreadsClicked(e, line: line, rect: rect)
            }
            e.onToggleFont = { [weak self] kind in self?.keepViewState(["font": kind.rawValue], of: p) }
            e.showsNotes = viewState(of: p)["notes"] != "hidden"
            e.opensFolded = viewState(of: p)["folded"] == "1"
            e.onToggleOpensFolded = { [weak self] on in self?.keepViewState(["folded": on ? "1" : ""], of: p) }
            e.onToggleNotes = { [weak self] shown in self?.keepViewState(["notes": shown ? "shown" : "hidden"], of: p) }
            e.blockLook = { [weak self] id in
                guard let b = self?.hosts.block(id) else { return nil }
                return PillLook(title: b.displayTitle, symbol: Theme.symbolName(for: b), status: StatusGlyph.look(of: b))
            }
            e.blockCard = { [weak self] id, place in self?.cardContent(for: id, at: place) }
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
            guard let self, event.window === self.window, self.emptyState == nil else { return event }
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

    /// The dock as a shelf at the grid's foot (View ▸ Show Dock Shelf).
    /// The column the last tile to fill one left, and as it was before.
    var columnFill: ColumnFill?
    /// The space whose dock was last seen, and what was docked: what
    /// changed since flies between the grid and the sidebar.
    var dockSeen: (space: BlockID?, docked: Set<PlacementID>)?
    /// Tiles leaving the grid flown by hand (to a space's square in the
    /// strip), not seen to go by the grid.
    var flownAway: Set<PlacementID> = []
    /// The +'s host list, to be put away.
    let pickerHide = Debouncer()
    /// The sidebar's tree not made again before this (media time): a
    /// tile's row squeezing shut as it pours out of it.
    var sidebarHeldUntil: CFTimeInterval = 0
    /// The footer's menu, open, and which; its click-outside watcher; the
    /// tiles' menu showing them all.
    var footerMenu: (view: PopMenu?, which: FooterMenu) = (nil, .threads)
    var footerMonitor: Any?
    var tilesShowAll = false
    /// ⌘`'s walk through the spaces: their order, the one chosen; its
    /// cards, shown; what shows them, and what watches ⌘ and ⎋.
    var spaceSwitch: (order: [BlockID], index: Int)?
    var spaceSwitcher: SpaceSwitcherView?
    let spaceSwitchShow = Debouncer()
    var spaceSwitchMonitors: [Any] = []
    /// A space's card under the pointer on its square in the strip.
    var spacePeek: SpaceSwitcherView?
    let spacePeekWork = Debouncer()
    /// ⌘ held a moment: the strip's numbers shown, till it's let go.
    let commandHeld = Debouncer()
    var commandMonitor: Any?

    /// Watches ⌘: held alone a quarter of a second, the spaces' numbers
    /// shown on their squares; let go, or another key pressed, gone.
    func watchCommandKey() {
        guard commandMonitor == nil else { return }
        commandMonitor = NSEvent.addLocalMonitorForEvents(matching: [.flagsChanged, .keyDown]) { [weak self] e in
            guard let self else { return e }
            let alone = e.type == .flagsChanged && e.modifierFlags.intersection(.deviceIndependentFlagsMask).subtracting(.capsLock) == .command
            self.commandHeld.cancel()
            if alone {
                self.commandHeld.schedule(after: 0.25) { [weak self] in self?.sidebar.spaces.showsNumbers = true }
            } else if e.type == .flagsChanged || !e.modifierFlags.contains(.command) {
                self.sidebar.spaces.showsNumbers = false
            }
            return e
        }
    }
    /// A docked tile's picture as it went (its body's): what it pours back
    /// out as, a view just shown again having nothing drawn yet (a PDF's).
    var dockedPictures: [PlacementID: Any] = [:]
    /// Tiles under an $EDITOR's (§3.1): a pure stack — the one under is
    /// seen nowhere (not docked in the sidebar, not in ⌃⇥ or ⇧⌘A) and
    /// comes back only when the one over it goes; neither flies.
    var stacked: Set<PlacementID> = []
    /// The tile over each (the $EDITOR's, by its placement), and the one under it.
    var stackTops: [PlacementID: PlacementID] = [:]

    /// The terminal an $EDITOR's tile is over: the tile shows as it —
    /// its name, its symbol (badged with a document), and Editing.
    func stackedTerminal(_ p: PlacementID) -> Block? {
        guard let under = stackTops[p], let space = selected, let a = hosts.arrangement(space),
              let t = a.docked.first(where: { $0.placement.id == under })?.placement ?? a.placement(under) else { return nil }
        return hosts.block(t.block)
    }

    private let transfersBadge = TransfersBadge()

    private func transfersChanged() {
        let items = Transfers.shared.visible
        sidebar.transfers.items = items
        sidebar.needsLayout = true
        transfersBadge.show(items)
        transfersBadge.isHidden = items.isEmpty || sidebarShown
        root.needsLayout = true
    }

    func layoutViews() {
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
        slidingAway?.frame = stage.bounds
        emptyState?.frame = stage.frame
        history?.frame = b
        if !transfersBadge.isHidden {
            let s = transfersBadge.wantedSize
            transfersBadge.frame = NSRect(x: 14, y: 14, width: s.width, height: s.height)
        }
        if !toast.window.isHidden {
            let s = toast.window.wantedSize
            toast.window.frame = NSRect(x: stage.frame.minX + (stage.frame.width - s.width) / 2, y: 14, width: s.width, height: s.height).integral
        }
    }

    // MARK: Closing and keeping (§4)

    private let holdWork = Debouncer()

    /// Holds on other hosts (§4) brought in step with what this client's
    /// hosts refer to, a moment after things settle.
    private func scheduleHoldReconcile() {
        holdWork.schedule(after: 1.5) { [weak self] in self?.hosts.reconcileHolds() }
    }

    /// What was closed, latest last: a tile with where it was, or a
    /// workspace taken off the desk — ⇧⌘T brings the last one back.
    enum Closed {
        case tile(workspace: BlockID, column: Int, index: Int, placement: Placement, height: Double?)
        case workspace(BlockID, index: Int)
    }
    var closedStack: [Closed] = []
    let toast = Toasts()
    /// A walk through code under way (§2.5): ⌃⌘] and ⌃⌘[ step along it.
    var codeWalk: CodeWalk?
    /// Each tile's own trail, as a browser window's: the blocks it showed
    /// before in its place (a listing's folders, a preview's pages), and
    /// those gone back from.
    var trails: [PlacementID: (back: [BlockID], forward: [BlockID])] = [:]
    /// Other hosts' images shown in notes, as data the page can load.
    var remoteImages: [BlockID: String] = [:]
    /// Pictures notes' outlines show, by host and path or address; those
    /// that aren't pictures (or can't be read), so they're asked once.
    let pictures = NSCache<NSString, NSImage>()
    var notPictures: Set<String> = []
    var fetchingPictures: Set<String> = []
    var fetchingImages: Set<BlockID> = []
    /// Images kept this second, so two get names of their own.
    var imageCount = 0 { didSet { if imageCount == 1 { DispatchQueue.main.asyncAfter(deadline: .now() + 1.1) { [weak self] in self?.imageCount = 0 } } } }

    /// A tile about to be taken off: remembered, so ⇧⌘T can put it back.
    func noteClosing(_ placement: PlacementID, in workspace: BlockID) {
        guard let a = hosts.arrangement(workspace), let p = a.placement(placement), let (c, i) = a.locate(placement) else { return }
        closedStack.append(.tile(workspace: workspace, column: c, index: i, placement: p, height: a.heights[placement]))
        if closedStack.count > 100 { closedStack.removeFirst(closedStack.count - 100) }
    }

    /// After tiles were taken off: whatever was reached before and isn't
    /// now — the blocks closed, and everything only they reached through
    /// what they placed and linked — is on its way to collection. When
    /// that would lose something — a text edited and unsaved, a note's
    /// words (kept nowhere else), a terminal with a job running — a toast
    /// names each, with Undo while its time runs down.
    /// `space`: a space was removed (⇧⌘W), named so — said whether or not
    /// anything is lost with it, as it's a step easily taken unawares.
    func afterClosing(reachedBefore before: Set<BlockID>, space: String? = nil) {
        let after = hosts.reachable()
        var lost: [String] = []
        for id in before.subtracting(after) {
            guard let b = hosts.block(id) else { continue }
            if b.kind == .text, b.text?.isDirty == true {
                lost.append("“\(b.displayTitle)” (unsaved edits)")
            } else if b.isNote, !(b.text?.text.string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true), hasEdges(id) {
                // A note's words are kept nowhere else — said, unless it's
                // tied to nothing (no link, no edge either way): that one
                // just goes, ⇧⌘T bringing it back until it's collected.
                lost.append("“\(b.displayTitle)” (a note)")
            } else if (b.kind == .terminal || b.kind == .agent), b.terminal?.busy == true {
                lost.append("“\(b.displayTitle)” (\(b.kind == .agent ? "agent running" : "job running"))")
            }
        }
        guard !lost.isEmpty || space != nil else { return }
        lost.sort()
        let minutes = hosts.local.desk.settings.collectAfterMinutes
        let when = minutes > 0 ? "; gone in \(minutes) min" : ""
        var text: String
        if let space {
            text = "Removed “\(space)” to Recently Closed"
            if !lost.isEmpty { text += ", with " + lost.joined(separator: ", ") + when }
        } else {
            text = lost.count == 1 ? "Closed \(lost[0])\(when)" : "Closed \(lost.count) blocks with something to lose: \(lost.joined(separator: ", "))\(when)"
        }
        // Undo while its time runs (⇧⌘T after, until it's collected).
        toast.show(text, action: "Undo", for: lost.isEmpty ? 6 : 12, countdown: true) { [weak self] in self?.reopenClosed(nil) }
        layoutViews()
    }

    /// Whether a block is tied to anything: an edge from it (a link, a
    /// mention, a file opened from it), or one to it by hand (a link, an
    /// embedding, a pin) — not where it was opened from, which every
    /// block made from another has, nor its being placed.
    private func hasEdges(_ id: BlockID) -> Bool {
        hosts.all.contains { c in
            c.node.graph.edges(from: id).contains { e in
                guard e.isLive, case .link = e.kind else { return false }
                return true
            } || c.node.graph.edges(to: id).contains { e in
                guard e.isLive, case .link(let k) = e.kind else { return false }
                return k != .opened
            }
        }
    }

    /// ⇧⌘T: the last thing closed, back where it was — a tile into its
    /// workspace at its old place (here, if that workspace is gone), a
    /// workspace onto the desk. What has been collected meanwhile is
    /// skipped.
    @objc func reopenClosed(_ sender: Any?) {
        // Put away once it's back: a deletion waiting on the toast then
        // finds the block placed again, and isn't done.
        defer { toast.hide() }
        reopenLast()
    }

    /// A deletion undone: its block's tiles back, the latest closed first,
    /// as many as it had — not whatever was closed last (another
    /// deletion's, under way at the same time), and no other toast touched.
    func reopenClosed(block: BlockID, tiles n: Int) {
        for _ in 0..<n {
            guard let k = closedStack.lastIndex(where: { if case let .tile(_, _, _, p, _) = $0 { return p.block == block } else { return false } }) else { return }
            closedStack.append(closedStack.remove(at: k))
            reopenLast()
        }
    }

    private func reopenLast() {
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

    /// Debugging: what reaches a block (its id ending in `suffix`): the
    /// strong edges from a root to it, each with its kind.
    func debugWhyReached(_ suffix: String) -> String {
        guard let target = hosts.blocks.first(where: { $0.id.description.hasSuffix(suffix) })?.id else { return "no block" }
        let roots = hosts.roots()
        var parent: [BlockID: (BlockID, String)] = [:]
        var seen = roots, frontier = Array(roots)
        while let b = frontier.popLast() {
            for e in hosts.client(of: b)?.node.graph.strongEdges(from: b) ?? [] where seen.insert(e.to).inserted {
                parent[e.to] = (b, "\(e.kind)")
                frontier.append(e.to)
            }
        }
        guard seen.contains(target) else { return "unreached" }
        var lines: [String] = [], b = target
        while let (from, kind) = parent[b] {
            lines.append("\(hosts.block(from)?.displayTitle ?? "?") \(from) —\(kind)→ \(hosts.block(b)?.displayTitle ?? "?")")
            b = from
        }
        return (roots.contains(b) ? "root \(hosts.block(b)?.displayTitle ?? "?") \(b)\n" : "") + lines.reversed().joined(separator: "\n")
    }

    var debugToast: String { toast.debugText ?? "none" }
    func debugToastAct() -> String { toast.debugAct() }
    func debugToastNudge() { toast.nudge() }
    func debugMarkArrival() -> String {
        guard let f = arrangement?.focused else { return "nothing focused" }
        content.markArrival(f)
        return "marked"
    }
    var debugFencing: String {
        hosts.all.map { c in
            "\(hosts.label(of: c.host)): " + (c.watching ? "watching, taken by \(c.fencedBy ?? "?")\(c.superseded ? " (superseded)" : ""): \(c.fenced.map(\.description).sorted().joined(separator: " "))" : "leading")
                + " · attached \(c.attachedHere ? "here" : c.attachedPresent ? "elsewhere" : "to no one here") · acts \(c.actsHere ? "here" : c.actor.map { "on \($0)" } ?? "nowhere") · speaks \(c.speaksHere ? "here" : "not here")"
        }.joined(separator: "\n")
    }

    // MARK: Watching (§8.2)

    /// Another Manifold took the pen for this host's blocks: said, with
    /// Take Over — never done for the user (two clients each taking it
    /// back would trade it between them). Said again when something done
    /// here didn't take (`again`), at most every few seconds.
    private var saidWatching: [HostID: Date] = [:]

    private var nudgedWatching = Date.distantPast
    func sayWatching(_ client: HostClient, again: Bool = false) {
        guard client.watching else { return }
        // Said lately and still up: shaken, not said again (a quarter of a
        // second apart at most, as keys repeat).
        if again, let said = saidWatching[client.host], Date().timeIntervalSince(said) < 4 {
            if toast.debugText?.contains(hosts.label(of: client.host)) == true, Date().timeIntervalSince(nudgedWatching) > 0.25 {
                nudgedWatching = Date()
                toast.nudge()
            }
            return
        }
        saidWatching[client.host] = Date()
        let who = client.fencedBy ?? "Another Manifold"
        toast.show("\(who) took over \(hosts.label(of: client.host)): what you do here doesn't take", action: "Take Over", for: 20) { [weak self, weak client] in
            guard let self, let client else { return }
            self.takeOver(client)
        }
        layoutViews()
    }

    /// The pens back: what was taken, and what's focused here.
    func takeOver(_ client: HostClient) {
        var also: [ShardID] = []
        if let b = focusedShown?.placement.block, b.host == client.host { also.append(.block(b)) }
        if let w = selected, w.host == client.host { also.append(.block(w)) }
        client.takeOver(also: also)
        saidWatching[client.host] = nil
        toast.hide()
        refreshOrganization()
    }

    /// Asked first, as a sheet on the window: `then` once the first button
    /// is chosen (the second, Cancel, leaves things be).
    func confirm(_ title: String, _ info: String, button: String, cancel: String = "Cancel", destructive: Bool = false,
                 then: @escaping () -> Void) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = info
        alert.addButton(withTitle: button)
        alert.addButton(withTitle: cancel)
        alert.buttons[0].hasDestructiveAction = destructive
        guard let window else { if alert.runModal() == .alertFirstButtonReturn { then() }; return }
        alert.beginSheetModal(for: window) { if $0 == .alertFirstButtonReturn { then() } }
    }

    /// Said, as a sheet on the window: nothing to choose.
    func notify(_ title: String, _ info: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = info
        if let window { alert.beginSheetModal(for: window) } else { alert.runModal() }
    }

    /// A word at the window's foot, with a button.
    func notice(_ text: String, action: String, _ act: @escaping () -> Void) {
        toast.show(text, action: action, for: 12, act)
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
        // Threads with something not seen (§3.12) wait on you too.
        let waiting = hosts.blocks.filter { $0.statusRecord?.wantsAttention ?? false }.count + hosts.unseenThreads.count
        let badge = waiting == 0 ? "" : "\(waiting)"
        if NSApp.dockTile.badgeLabel != badge { NSApp.dockTile.badgeLabel = badge }
    }

    /// What waits on you (§3.7), in ⌘J's order: the blocks whose status
    /// came to need attention and haven't been taken out by hand, and
    /// threads with something not seen (§3.12) — by host, then grouped by
    /// the space that first holds each (the group with the newest first),
    /// newest first within it.
    func inboxOrder() -> [BlockID] {
        var order: [BlockID] = []
        for c in hosts.all {
            let blocks = c.node.blocks.filter { b in b.needsAttention || (b.kind == .thread && !hosts.unseen(b).isEmpty) }
            var bySpace: [(BlockID?, [BlockID])] = []
            for b in blocks.sorted(by: { ($0.statusRecord?.at ?? $0.created) > ($1.statusRecord?.at ?? $1.created) }) {
                let w = allWorkspaces.first { hosts.arrangement($0)?.placements(of: b.id).isEmpty == false }
                if let i = bySpace.firstIndex(where: { $0.0 == w }) { bySpace[i].1.append(b.id) } else { bySpace.append((w, [b.id])) }
            }
            order += bySpace.flatMap(\.1)
        }
        return order
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
        // A thread: in the overlay, where it's read and answered (§3.12).
        if hosts.block(next)?.kind == .thread { return showThreadOverlay(nil, thread: next) }
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
        // A workspace seen is a step of the trail (⌘`'s order, back and
        // forward).
        guard window?.isVisible == true, window?.isMiniaturized == false, let a = arrangement, let id = selected else { return }
        var seen = Set(a.visible.map(\.block))
        seen.insert(id)
        if seen != lastSeenSet || force || Date().timeIntervalSince(lastSeenSent) > 14 {
            lastSeenSet = seen
            lastSeenSent = Date()
            hosts.propose(.seen(Array(seen)))
        }
    }

    /// A terminal's shell ended (not for dormancy): its placements go, as a
    /// closed window's would; the block stays, with its transcript.

    private func terminalEnded(_ block: BlockID) { withdraw(block) }

    /// A block's tiles taken off every workspace (its shell ended); the
    /// workspaces stay, emptied or not, until they're removed (§4).
    private func withdraw(_ block: BlockID) {
        for id in allWorkspaces {
            guard let a = hosts.arrangement(id) else { continue }
            for p in a.placements(of: block) { hosts.append(.remove(p.id), to: .block(id)) }
        }
    }

    // MARK: Sidebar

    /// How far past its edge the mouse may stray before the floating sidebar
    /// goes, and how long after that it goes.
    private static let sidebarSlack: CGFloat = 8
    private static let sidebarHideDelay: TimeInterval = 0.1

    func mouseMoved(to p: NSPoint) {
        guard !pinned else { return }
        if p.x <= 6 && p.y >= 0 && p.y <= root.bounds.height {
            hideWork.cancel()
            showSidebar(animated: true)
        } else if sidebarShown && p.x > sidebar.frame.maxX + Self.sidebarSlack {
            scheduleHide()
        } else if sidebarShown && sidebar.frame.insetBy(dx: -Self.sidebarSlack, dy: -Self.sidebarSlack).contains(p) {
            hideWork.cancel()
        }
    }

    /// The sidebar wasn't made again while it was put away.
    var organizationStale = false

    func showSidebar(animated: Bool) {
        guard !sidebarShown else { return }
        sidebarShown = true
        if organizationStale { refreshOrganization(now: true) }
        sidebar.isHidden = false
        root.addSubview(sidebar, positioned: .above, relativeTo: stage)
        let target = NSRect(x: Theme.sidebarInset, y: Theme.sidebarInset, width: sidebarWidth,
                            height: root.bounds.height - 2 * Theme.sidebarInset)
        if animated {
            sidebar.frame = target.offsetBy(dx: Motion.distance(-24), dy: 0)
            sidebar.alphaValue = 0
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = Motion.base
                ctx.timingFunction = Motion.appear
                sidebar.animator().frame = target
                sidebar.animator().alphaValue = 1
            }
        } else {
            sidebar.frame = target
            sidebar.alphaValue = 1
        }
        setTrafficLights(visible: true, animated: animated)
    }

    func scheduleHide() {
        guard sidebarShown, !pinned, !draggingTab, resizingWidth == nil, footerMenu.view == nil else { return }
        hideWork.schedule(after: Self.sidebarHideDelay) { [weak self] in self?.hideSidebar() }
    }

    /// Hides the floating sidebar, unless something's still using it; `force`
    /// hides it even with the mouse over it (when asked to by ⇧⌘/ or ⌃⌘S).
    func hideSidebar(force: Bool = false) {
        guard sidebarShown, !pinned, !draggingTab, resizingWidth == nil,
              NSApp.modalWindow == nil, window?.attachedSheet == nil else { return }
        // Not while a menu from it is open, or the mouse is back over it.
        if let window, !force {
            let p = root.convert(window.mouseLocationOutsideOfEventStream, from: nil)
            if sidebar.frame.insetBy(dx: -Self.sidebarSlack, dy: -Self.sidebarSlack).contains(p) && window.isKeyWindow
                && NSEvent.pressedMouseButtons == 0 && root.bounds.contains(p) { return }
        }
        sidebarShown = false
        let target = sidebar.frame.offsetBy(dx: Motion.distance(-24), dy: 0)
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = Motion.fast
            ctx.timingFunction = Motion.disappear
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

    func setTrafficLights(visible: Bool, animated: Bool) {
        for type in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
            guard let b = window?.standardWindowButton(type) else { continue }
            if animated {
                NSAnimationContext.runAnimationGroup { ctx in
                    ctx.duration = Motion.fast
                    b.animator().alphaValue = visible ? 1 : 0
                }
            } else {
                b.alphaValue = visible ? 1 : 0
            }
            b.isEnabled = visible
        }
    }

    // MARK: Commands

    var focusedShown: Shown? {
        guard let a = arrangement, let p = a.focusedPlacement else { return nil }
        return Shown(placement: p, block: hosts.block(p.block))
    }

    var focusedCwd: String? {
        guard let f = focusedShown else { return nil }
        return f.block?.terminal?.cwd ?? f.block?.place
    }

    /// The host the focused block is on: where new terminals and files go.
    var focusedHost: HostID { focusedShown?.placement.block.host ?? host.host }

    /// Changes the selected arrangement.
    func appendToSelected(_ events: [Event]) {
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
    func arrangementForPlacing() -> BlockID {
        if let id = selected, hosts.arrangement(id) != nil { return id }
        let id = host.newArrangement()
        hosts.select(id)
        return id
    }

    /// A new web page below the focused tile, its address to be typed;
    /// where the focused block is — on another host, loaded through it
    /// (§7.6), as a new terminal is made there.
    @objc func newWebPage(_ sender: Any?) {
        let c = hosts.client(focusedHost) ?? host
        show(c.newWeb(url: "https://duckduckgo.com", viaHost: c.isRemote), lens: .web, .here)
    }

    /// ⌘T (and the first thing at launch): a new terminal in a new
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

    /// ⌥⌘T: a new terminal in the active column, as acme and apex place a
    /// window — below the column's biggest tile, taking its lower half.
    @objc func newTerminalBeside(_ sender: Any?) {
        guard let a = arrangement, !a.isEmpty else { return newTerminal(nil) }
        let t = hosts.newTerminal(on: focusedHost, cwd: focusedCwd)
        show(t, lens: .terminal, .here)
    }

    /// ⌥⇧⌘ and a kind's letter (File ▸ New's items with ⇧ held): the kind
    /// made as ⌥⌘ makes it, in a new column to the right of the focused
    /// one instead of below it.
    @objc func newInNewColumn(_ sender: Any?) {
        guard let name = (sender as? NSMenuItem)?.representedObject as? String, let action = Self.newActions[name] else { return }
        inNewColumn = true
        defer { inNewColumn = false }
        _ = perform(action, with: sender)
    }

    /// Set while one of ⌥⇧⌘'s makes its kind: where it's shown is a new
    /// column (`show`, `showWhenMade` read it as they're called).
    var inNewColumn = false

    /// Moves a whole column to another index.
    func reorderColumn(from: Int, to: Int) {
        guard let a = arrangement, from < a.columns.count, from != to else { return }
        appendToSelected([.moveColumn(from: from, to: to)])
    }

    /// ⌥⌘N: a new note beside the focused block.
    /// ⌥⌘N: a note on the focused block's host, at home in its folder.
    /// ⌥⌘N: a note — about the focused block (§3.5): the block linked to
    /// the note, as if ⇧-dragged into it, so the block wears it and the
    /// note knows its subject.
    /// A shell notebook (§7.7) on the focused block's host, its shell
    /// started where that block is, placed here.
    @objc func newShellNotebook(_ sender: Any?) {
        let client = hosts.client(focusedHost) ?? host
        let id = BlockID(host: client.host)
        client.propose(.newNotebook(block: id, cwd: focusedCwd))
        showWhenMade(id, lens: .notebook, place: .here, what: "the notebook")
    }

    /// New Note from Selection: what's selected in the focused editor or
    /// terminal, as a note of its own beside it — code fenced, as it was —
    /// linked from where it came from, by the lines it was.
    @objc func newNoteFromSelection(_ sender: Any?) {
        guard let f = focusedShown, let view = views[f.id], let b = f.block else { return NSSound.beep() }
        var text: String?
        var context = "from the selection"
        var fence = ""
        if let e = view as? EditorView, case let s = e.textView.selectedText, !s.isEmpty {
            text = s
            if let sel = e.textView.selections.first(where: { !$0.isCaret }) {
                let first = e.textView.text.line(at: sel.min) + 1, last = e.textView.text.line(at: max(sel.max - 1, sel.min)) + 1
                context = first == last ? "line \(first)" : "lines \(first)–\(last)"
            }
            if !(b.path.map(Lens.isMarkdown) ?? true) { fence = b.path?.pathExtension ?? "" }
        } else if let t = view as? TerminalView, let s = t.selectedText, !s.isEmpty {
            text = s
            context = "from the terminal"
            fence = "text"
        }
        guard let text else { return NSSound.beep() }
        let body = fence.isEmpty ? text : "```" + (fence == "text" ? "" : fence) + "\n" + text + (text.hasSuffix("\n") ? "" : "\n") + "```\n"
        let client = hosts.client(b.id.host) ?? host
        let note = client.newNote(home: b.place, text: body)
        hosts.link(from: b.id, to: note, kind: .linked, context: context)
        show(note, lens: .editor, .besideOpener(f.id), context: context)
    }

    /// Save Scrollback as Note: the focused terminal's whole transcript, as
    /// a note beside it (in a code fence), linked from it.
    @objc func saveScrollbackAsNote(_ sender: Any?) {
        guard let f = focusedShown, let t = views[f.id] as? TerminalView, let text = t.transcriptLines, let b = f.block else { return NSSound.beep() }
        let trimmed = text.replacingOccurrences(of: "\\s+$", with: "", options: .regularExpression)
        let note = (hosts.client(b.id.host) ?? host).newNote(home: b.place, text: "# Scrollback · \(b.displayTitle)\n\n```\n" + trimmed + "\n```\n")
        hosts.link(from: b.id, to: note, kind: .linked, context: "scrollback")
        show(note, lens: .editor, .besideOpener(f.id), context: "scrollback")
    }

    /// Copy Link to This Line: the focused text's address with the caret's
    /// line's anchor (the declaration or heading there, else the line).
    @objc func copyLinkToLine(_ sender: Any?) {
        guard let f = focusedShown, let e = views[f.id] as? EditorView, let n = e.navLocation?.line else { return NSSound.beep() }
        copyLink(to: Place(block: f.placement.block, at: .line(n)))
    }

    // MARK: Kept for Asking an agent about a place (§2.5) — its code in MainWindowController+Agents.swift

    /// Debugging: what Copy Contents would copy, from the focused tile (or
    /// the block named) — not put on the pasteboard; the previous ask's.
    var debugContentsAnswer = "-"
    /// Tiles waiting on their saves to close (⇧⌘S): the block, its space,
    /// and when to give up (a note's save panel may be open a while).
    var savingToClose: [PlacementID: (block: BlockID, space: BlockID, until: Date)] = [:]

    // MARK: Kept for Making blocks (BlockKinds) — its code in MainWindowController+Making.swift

    /// Debugging: the walk's key taken as held (⌘`'s, ⌃⇥'s).
    var debugHeld = false

    // MARK: Kept for ⌃⇥ — its code in TileSwitcher.swift

    /// The key a tile walk is held on.
    let tileWalkKey: NSEvent.ModifierFlags = .control
    /// ⌃⇥'s cards made out of sight: what shows them, unfolding to be in
    /// place by the time it's given.
    var tileUnseen: ((Date) -> Void)?
    /// When they last began unfolding (media time).
    var tileUnfoldBegan: CFTimeInterval?
    /// Debugging: when ⌃⇥'s cards were last asked for, shown, and in place.
    var debugTilesPressed: Date?
    var debugTilesShown: Date?
    var debugTilesSettled: Date?
    var picturing = 0
    // MARK: Tiles

    @objc func nextTile(_ sender: Any?) { stepPane(1) }
    @objc func previousTile(_ sender: Any?) { stepPane(-1) }

    /// Go ▸ Focus ▸ (⌥⌘ and an arrow): the tile that way, as `mani`'s
    /// @left and @below name it.
    @objc func focusLeft(_ sender: Any?) { focusToward(.left) }
    @objc func focusRight(_ sender: Any?) { focusToward(.right) }
    @objc func focusUp(_ sender: Any?) { focusToward(.above) }
    @objc func focusDown(_ sender: Any?) { focusToward(.below) }

    private func focusToward(_ way: ManiLayout.Direction) {
        guard let a = arrangement, case let .tile(id) = ManiLayout(a).resolve(way.rawValue, from: a.focused) else { return NSSound.beep() }
        focus(id)
    }

    /// Tile ▸ Move ▸ (⌥⇧⌘ and an arrow): the focused tile a step that
    /// way (`ArrangementState.nudging`).
    @objc func moveTileLeft(_ sender: Any?) { moveTile(.left) }
    @objc func moveTileRight(_ sender: Any?) { moveTile(.right) }
    @objc func moveTileUp(_ sender: Any?) { moveTile(.above) }
    @objc func moveTileDown(_ sender: Any?) { moveTile(.below) }

    private func moveTile(_ way: ManiLayout.Direction) {
        guard let a = arrangement, let id = a.focused, a.full == nil, let events = a.nudging(id, way) else { return NSSound.beep() }
        appendToSelected(events)
    }

    private func stepPane(_ d: Int) {
        guard let a = arrangement, a.visible.count > 1 else { return }
        let visible = a.visible
        let i = visible.firstIndex { $0.id == a.focused } ?? 0
        focus(visible[(i + d + visible.count) % visible.count].id)
    }

    /// Focuses a tile of the selected arrangement.
    func focus(_ placement: PlacementID) {
        guard let a = arrangement, a.placement(placement) != nil, a.focused != placement || a.isDocked(placement) else { return }
        appendToSelected(revealing(placement, in: a))
    }

    /// What brings a tile into view and focus: a maximized other tile
    /// gives way, a docked one goes back where it was, and it is focused.
    private func revealing(_ placement: PlacementID, in a: ArrangementState) -> [Event] { a.revealing(placement) }

    /// Going to a tile of the workspace shown (⌘P's outline): revealed —
    /// back from the dock, if it's there — grown a little if it's down to
    /// its bar, and the pointer on it.
    func arrive(atTile placement: PlacementID) {
        guard let a = arrangement, a.placement(placement) != nil else { return }
        appendToSelected(arriving(placement, in: a))
        warpPointerToFocus()
    }

    /// Arriving at a tile (a link followed, a block gone to, a step back,
    /// a row of the sidebar): revealed, and grown if it's down to its bar.
    func arriving(_ placement: PlacementID, in a: ArrangementState) -> [Event] {
        showingSome(a.revealing(placement), in: a)
    }

    /// A space shown, and a tile in it arrived at (`arriving`) — nothing
    /// appended when it's focused, in the grid and not behind another
    /// maximized already.
    func land(on tile: PlacementID, in space: BlockID, _ a: ArrangementState) {
        if selected != space { hosts.select(space) }
        guard a.focused != tile || a.isDocked(tile) || (a.full != nil && a.full != tile) else { return }
        hosts.append(arriving(tile, in: a), to: .block(space))
    }

    /// How much of a tile gone to is shown, grown to it (as apex does for a
    /// window it goes to): its content's height, at most, and as a part
    /// of the column.
    private static let glimpse: (points: CGFloat, share: CGFloat) = (160, 1 / 4)

    /// Events that leave a tile focused (or `placement`), with that tile
    /// grown to a glimpse if it's too short for its content (its summary
    /// in its place, or its bar alone) — taken from its neighbours as
    /// growing takes it.
    func showingSome(_ events: [Event], in a: ArrangementState, placement: PlacementID? = nil) -> [Event] {
        var after = a
        for e in events { after.apply(e) }
        guard let f = placement ?? after.focused, after.full == nil, let m = metrics(of: f, in: after),
              m.shown.count > 1, m.sum > 0, m.usable > 0 else { return events }
        let target = min(Self.glimpse.points, m.usable * Self.glimpse.share)
        guard m.body(after.height(of: f)) < GridView.summarizeBelow else { return events }
        return events + after.growing(f, step: m.share(forBody: target) - after.height(of: f))
    }

    /// Grow (acme's colgrow): the focused tile takes a step from its
    /// neighbors; with ⇧, as much of its column as can be.
    @objc func growTile(_ sender: Any?) {
        guard let a = arrangement, let f = a.focused else { return }
        appendToSelected(a.growing(f, whole: NSApp.currentEvent?.modifierFlags.contains(.shift) == true))
    }

    @objc func fillColumn(_ sender: Any?) {
        guard let f = arrangement?.focused else { return }
        fill(f, keepingBars: false)
    }

    /// The focused tile all its column but the others' bars (as its bar
    /// ⌥-clicked): they stay in the grid, not docked.
    @objc func fillColumnKeepingBars(_ sender: Any?) {
        guard let f = arrangement?.focused else { return }
        gridSqueeze(f)
    }

    // MARK: Kept for Organizations (§3.6) — its code in MainWindowController+Organizations.swift

    var organizationWork: DispatchWorkItem?
    /// The row the sidebar's tree was last made with chosen.
    var organizationShownFor: String?

    // MARK: Kept for State views (§3.6) — its code in MainWindowController+Overview.swift

    var stateView: StateView?
    /// What it shows while it's up: a status group's blocks, a space's
    /// (Overview, ⌘'), or every agent's (⌃⌘A).
    enum StateShown: Equatable { case group(StatusGroup), space(BlockID), agents }
    var stateShown: StateShown?
    var stateGroup: StatusGroup? { if case let .group(g) = stateShown { g } else { nil } }
    /// The workspace shown as an overview (⌘'), if one is.
    var stateWorkspace: BlockID? { if case let .space(w) = stateShown { w } else { nil } }
    /// The agents' view, up: Overview, filtered to the agents.
    var stateAgents: Bool { stateShown == .agents }
    var stateMode: StateView.Mode = .list
    /// The view's mode as chosen while it's up (else it goes by how many).
    var stateModeChosen: StateView.Mode?

    // MARK: Kept for Overview, as Mission Control does — its code in MainWindowController+Overview.swift

    /// The blocks the state view shows, in order, while it's up.
    var stateMembers: [BlockID] = []
    /// When each diff was last compared at a view's asking.
    var diffReloaded: [BlockID: Date] = [:]
    /// What Search reads of each block, by block: kept while the block's
    /// content is as it was.
    var searchTexts: [BlockID: SearchText] = [:]

    // MARK: Kept for The Inspector (§3.5) — its code in MainWindowController+Inspector.swift

    /// Its window, once it's been shown.
    var inspector: InspectorPanel?
    /// Blocks' logs as their hosts gave them, the latest of each (a
    /// replica only has what came since it connected), and those asked for.
    var inspectorLogs: [BlockID: [Entry]] = [:]
    var inspectorAsked: Set<BlockID> = []
    /// It, and the tile focused then: until another is.
    var inspected: (what: Inspected, focus: PlacementID?)?
    /// The inspector shows what changes by the second (a host's link): it's
    /// shown again each second while it does.
    var inspectorIsLive = false
    let inspectorTick = Debouncer()
    /// The inspected block's name, what and where it is, its symbol.
    var inspectorHeader: (title: String, subtitle: String, symbol: String?, tags: [String]) = ("", "", nil, [])
    let inspectorWork = Debouncer()

    // MARK: Kept for The neighborhood, in graph form — its code in MainWindowController+Neighborhood.swift

    var neighborhoodView: NeighborhoodView?

    // MARK: Kept for Back and forward, by focus — its code in MainWindowController+Navigation.swift

    /// A place focus was, in this client's history: a tile in a workspace.
    /// Where focus is: the workspace and the tile, so a change is noticed.
    var lastFocusPlace: (BlockID?, PlacementID?)?

    // MARK: Kept for The block navigation stack (§3.5) — its code in MainWindowController+Navigation.swift

    /// Every place gone to, block by block and within blocks — a focus
    /// moved, a definition gone to, a found line, a heading, a command —
    /// oldest first, with where back and forward are now. ⌃- goes back,
    /// ⌃⇧- forward, as VS Code's do; anything new drops what's forward.
    var navStack: [NavEntry] = []
    var navCursor = -1
    /// Going back or forward: the moves it makes aren't new places.
    var navigating = false
    /// The mouse's back and forward buttons (3 and 4), wherever it is in
    /// the window: back and forward; and ⌃- and ⌃⇧-, the block navigation
    /// stack's keys, before any view takes them.
    var historyButtonsMonitor: Any?
    var navKeysMonitor: Any?

    // MARK: Kept for Finding and opening — its code in MainWindowController+Finder.swift

    lazy var finder: Finder = {
        let f = Finder()
        // The chosen row's block: its card beside the list, at once.
        f.summarize = { [weak self] id in self?.cardContent(for: id) }
        f.search = { [weak self] query, scope, reach in
            guard let self else { return [] }
            switch scope {
            case .names: return []
            case .blocks: return self.finderBlockItems(query, everywhere: reach == .all)
            }
        }
        f.special = { [weak self] query in
            // A web address typed: opened as a page, first — as a page's bar
            // takes it: `host:port` an attached host's own localhost (or a
            // site's port), localhost and numbers, http(s) addresses, a domain.
            // (A name with a dot and no more, `README.md`, is a file's here.)
            guard let self else { return nil }
            let q = query.trimmingCharacters(in: .whitespaces)
            let parsed = WebAddress.parse(q)
            let domain = q.contains(".") && !q.contains(" ") && !q.contains("/") && q.split(separator: ".").last.map({ $0.count >= 2 && $0.allSatisfy(\.isLetter) }) == true
            let local = q.range(of: #"^(localhost|\d{1,3}(\.\d{1,3}){3})([:/].*)?$"#, options: .regularExpression) != nil
            var detail = "Open as a web page"
            switch parsed {
            case let .hostPort(name, port, _):
                if let h = self.hostNamedInAddress(name) { detail = "localhost:\(port) on \(self.hosts.label(of: h))" }
            case .page:
                guard q.hasPrefix("http://") || q.hasPrefix("https://") || domain || local else { return nil }
                if let u = URL(string: q.contains("://") ? q : "http://" + q), let name = u.host, let h = self.hostNamedInAddress(name) {
                    detail = "localhost:\(u.port ?? 80) on \(self.hosts.label(of: h))"
                }
            case .search:
                return nil
            }
            let title: String = { if case let .page(a) = parsed { return a } else { return q } }()
            return FinderItem(symbol: "globe", title: title, detail: detail, note: "web", run: { [weak self] in self?.openAddress(q, place: .here) })
        }
        f.openFile = { [weak self] path, on in
            guard let self else { return }
            // A project's file: on its host (§2.6).
            if let on {
                return self.open(path: path, line: 1, column: nil, on: on, from: self.arrangement?.focused, context: "found in ⌘O")
            }
            self.open(path, from: nil)
        }
        return f
    }()
    /// Each block's places, kept while it's as it was.
    var outlinePlaceCache: [BlockID: (key: String, places: [OutlinePlace])] = [:]

    // MARK: Kept for The space's outline, indexed (⌘P) — its code in MainWindowController+SpaceOutline.swift

    /// Each space's index of its tiles' outlines (`OutlineIndex`): kept as
    /// they change — an outline tells its index when its items do — and as
    /// tiles come and go, so a query in ⌘P only looks up. The selected
    /// space's, and a few others' as they were left.
    var outlineIndexes: [BlockID: OutlineIndex<PlacementID, Outline.Item>] = [:]
    var outlineSyncPending = false
    var opensKnown: [String: (Bool, Date)] = [:]
    /// Settings (⌘,): every setting in one window.
    var settingsWindow: SettingsWindow?
    /// Open requests being waited on: the placements that must go before
    /// the command returns.
    var openWaits: [(host: HostID, id: Int, client: Int, placements: [PlacementID], made: [BlockID])] = []

    // MARK: Kept for History — its code in MainWindowController+History.swift

    var history: HistoryView?
    /// The block whose history is up: a text block.
    var historyOf: BlockID?
    // MARK: Window

    func windowDidMove(_ notification: Notification) { saveFrame() }
    func windowDidResize(_ notification: Notification) { saveFrame() }

    private func saveFrame() {
        saveFrameWork.schedule(after: 0.5) { [weak self] in
            guard let self, let f = self.window?.frame else { return }
            var state = self.hosts.state.window
            state.frame = [f.minX, f.minY, f.width, f.height]
            if state != self.hosts.state.window { self.hosts.setWindow(state) }
        }
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        // Closing the window quits; the sessions carry on in the server.
        NSApp.terminate(nil)
        return false
    }
}

