import AppKit
import WebKit
import ManifoldCore
import UniformTypeIdentifiers

/// The window: the selected arrangement filling it, the sidebar (the desk)
/// floating over its left edge when the mouse goes there (or docked, when
/// pinned), and Open Quickly.
final class MainWindowController: NSWindowController, NSWindowDelegate {
    let hosts: Hosts
    /// This machine's host: the desk and settings are its.
    var host: HostClient { hosts.local }
    private let root = RootView()
    private let glass = NSVisualEffectView()
    private let backdrop = BackdropView()
    /// The grid of the workspace shown. Each workspace used lately keeps its
    /// own (`grids`), hidden while another shows: going back to it shows it
    /// again as it was, nothing laid out or drawn afresh.
    private(set) var content = GridView()
    /// Each tile shrunk to its summary, with its height before, to go back to.
    private var unshrunk: [PlacementID: Double] = [:]
    /// The grid for no workspace (none selected).
    private lazy var blankGrid: GridView = content
    /// The content area, which the grids are clipped to: a workspace
    /// sliding out (⌘`) leaves through its edge, never under the sidebar
    /// (which is translucent, and would show it).
    private let stage: NSView = {
        let v = NSView()
        v.wantsLayer = true
        v.layer?.masksToBounds = true
        return v
    }()
    /// The grids of the workspaces used lately, most recent first, kept in
    /// the window (hidden): `liveGrids` of them, so the tiles' drawings
    /// they hold don't grow with the desk; an older workspace's tiles go
    /// out of the window as they used to, and come back when it's shown.
    private var grids: [BlockID: GridView] = [:]
    private var gridOrder: [BlockID] = []
    static let liveGrids = 4
    /// The grid sliding away, while it does.
    private var slidingAway: GridView?
    /// Blocks awaited from their hosts (`whenMade`).
    private struct MadeWait {
        let id: BlockID, what: String, made: () -> Bool, then: () -> Void, started: Date
        var said = false
    }
    private var madeWaits: [MadeWait] = []
    private var madeWaitTimer: Timer?
    /// The arrangement `content` shows.
    private var shownArrangement: BlockID?
    private var sliding = false
    /// ⌘`'s walk, while ⌘ is held: the arrangements in the order it
    /// began with, and how far along it is.
    private var walk: (ids: [BlockID], index: Int)?
    private var walkMonitors: [Any] = []
    /// The app left mid-walk: ⌘'s letting go won't be heard.
    private var walkLeaving: NSObjectProtocol?
    /// A place settled on: a tile in its space (none, a space with
    /// nothing focused).
    private struct Place: Equatable {
        var space: BlockID
        var tile: PlacementID?
    }
    /// The places settled on in this window, the latest first: the trail
    /// as this window has it, which every switcher walks at its own scale —
    /// ⌘` its spaces, ⌥⇥ its tiles, ⌃⇥ a stack's (whose order is the
    /// trail's already, the tile settled on brought to its top). Those
    /// only passed on a walk aren't in it, and it doesn't wait on a host to
    /// hear of a switch (the hosts' trail, which comes after, fills in the
    /// rest).
    private var settled: [Place] = []
    /// ⌥⇥'s walk, while option is held: the places in the order it began
    /// with, how far along it is, and what shows its cards if it's held.
    private var tileWalk: (places: [Place], index: Int, show: DispatchWorkItem)?
    private var tileMonitors: [Any] = []
    private var tileLeaving: NSObjectProtocol?
    /// ⌥⇥'s cards, once they show, and their pictures on their way.
    private var tileSwitcher: (frame: NSView, column: StackColumnView)?
    private var tileFlights: [CALayer] = []
    /// ⌃⇥'s switcher, while control is held: what ends it.
    private var stackMonitors: [Any] = []
    private let sidebar = SidebarView()
    /// What the window shows with no space at all.
    private var emptyState: EmptyStateView?
    /// Each placement's view, for every arrangement on the desk.
    var views: [PlacementID: PaneContent] = [:]
    /// `mani`'s commands, done here.
    lazy var maniDesk = ManiDesk(self)
    private var seenTimer: Timer?
    private var lastSeenSent = Date.distantPast
    private var lastSeenSet: Set<BlockID> = []

    /// A place to go in a file being opened: done once its editor is shown.
    private var pendingJump: (path: String, line: Int, column: Int?)?
    /// Tiles ⌘↩ made, each with the line the tile it replaced had at its top.
    private var pendingTopLines: [PlacementID: Double] = [:]
    private var clickMonitor: Any?
    /// Blocks whose terminal just closed; they get a new one after a moment
    /// if their shell is still there (the server was restarted, not the
    /// shell ended).
    private var recentlyClosed: Set<BlockID> = []
    private var sidebarShown = false {
        // The copies' badge only while the sidebar (which shows them) is away.
        didSet { if sidebarShown != oldValue { transfersChanged() } }
    }
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
    var selected: BlockID? { hosts.state.selected }
    var arrangement: ArrangementState? { hosts.arrangement(selected) }
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
        // Both grids stay in the window: the one slid away is hidden, not
        // taken out — putting a view back in a window tells every view in
        // it (a web view waits on its process to hear it), at each switch.
        stage.addSubview(content)
        root.addSubview(stage)
        root.addSubview(sidebar)
        root.addSubview(toast)
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
        watchHistoryButtons()
        HostMenu.submenu = { [weak self] host in self?.hostSubmenu(host) }
        // A site's icon arrived: its pages' rows and bars show it.
        NotificationCenter.default.addObserver(forName: .manifoldFaviconsChanged, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.render() }
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
        hosts.onFenced = { [weak self] client in
            self?.sayWatching(client)
            self?.refreshOrganization()
        }
        hosts.onRefused = { [weak self] client in self?.sayWatching(client, again: true) }
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
        maniDesk.modelChanged()
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
        pruneGrids()
        var onDesk = Set(allWorkspaces.compactMap { hosts.arrangement($0) }.flatMap { $0.placements.map(\.id) })
        onDesk.formUnion(stateBlocks.map { Self.statePlacement($0.0.id) })
        for (id, view) in views where !onDesk.contains(id) {
            // Seen going, where it was, as its neighbours take its room.
            if view.superview === content { content.fadeAway(view) }
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
                    slide(slideDirection(from: from, to: to), leaving: old)
                    // After the sidebar's had the change.
                    DispatchQueue.main.async { [weak self] in self?.sidebar.organizationView.travel(from: from, to: to) }
                } else {
                    old.isHidden = true
                }
            }
            // Pictured for their cards, one a turn — its grid kept, the
            // workspace left is still drawn (hidden), so nothing is lost by
            // waiting, and no one turn takes them all.
            picture(leaving)
            shownArrangement = selected
            if walk == nil, tileWalk == nil { settleHere() }
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
            if emptyState == nil, stateView == nil, history == nil, neighborhoodView == nil, !content.isEditingPill,
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
            for case let panel as PanelView in views.values { panel.documentChanged() }
        } else {
            content.clear()
            window.title = "Manifold"
        }
        if let stateView, stateGroup != nil || stateWorkspace != nil || stateAgents {
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
            if let d = v as? DiffView { d.theme = hosts.state.appearance.theme }
            if let t = v as? TerminalView {
                t.commands = hosts.block(p.block)?.terminal?.commands ?? []
                t.isAgent = isAgent(p)
            t.turns = Set(hosts.block(p.block)?.terminal?.turns?.map(\.id) ?? [])
                t.turns = Set(hosts.block(p.block)?.terminal?.turns?.map(\.id) ?? [])
                t.resumeIfLinkBack()
            }
            (v as? SmartlogView)?.refresh()
            if !v.isDead { return v }
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
                for case let v as TerminalView in self?.views.values.map({ $0 }) ?? [] where v.block == block {
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
            m.isLocal = p.block.host == host.host
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
            m.delegate = self
            m.acceptsImages = shown.block?.kind == .text
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
                return PillLook(title: b.displayTitle, symbol: Theme.symbolName(for: b), status: StatusGlyph.look(of: b))
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

    private let transfersBadge = TransfersBadge()

    private func transfersChanged() {
        let items = Transfers.shared.visible
        sidebar.transfers.items = items
        sidebar.needsLayout = true
        transfersBadge.show(items)
        transfersBadge.isHidden = items.isEmpty || sidebarShown
        root.needsLayout = true
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
        slidingAway?.frame = stage.bounds
        emptyState?.frame = stage.frame
        history?.frame = b
        if !transfersBadge.isHidden {
            let s = transfersBadge.wantedSize
            transfersBadge.frame = NSRect(x: 14, y: 14, width: s.width, height: s.height)
        }
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
    /// Each tile's own trail, as a browser window's: the blocks it showed
    /// before in its place (a listing's folders, a preview's pages), and
    /// those gone back from.
    private var trails: [PlacementID: (back: [BlockID], forward: [BlockID])] = [:]
    /// Other hosts' images shown in notes, as data the page can load.
    private var remoteImages: [BlockID: String] = [:]
    private var fetchingImages: Set<BlockID> = []
    /// Images kept this second, so two get names of their own.
    private var imageCount = 0 { didSet { if imageCount == 1 { DispatchQueue.main.asyncAfter(deadline: .now() + 1.1) { [weak self] in self?.imageCount = 0 } } } }

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
    func afterClosing(reachedBefore before: Set<BlockID>) {
        let after = hosts.reachable()
        var lost: [String] = []
        for id in before.subtracting(after) {
            guard let b = hosts.block(id) else { continue }
            if b.kind == .text, b.text?.isDirty == true {
                lost.append("“\(b.displayTitle)” (unsaved edits)")
            } else if b.isNote, !(b.text?.text.string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true) {
                // A note's words are kept nowhere else.
                lost.append("“\(b.displayTitle)” (a note)")
            } else if (b.kind == .terminal || b.kind == .agent), b.terminal?.busy == true {
                lost.append("“\(b.displayTitle)” (\(b.kind == .agent ? "agent running" : "job running"))")
            }
        }
        guard !lost.isEmpty else { return }
        lost.sort()
        let minutes = hosts.local.desk.settings.collectAfterMinutes
        let when = minutes > 0 ? "; gone in \(minutes) min" : ""
        let text = lost.count == 1 ? "Closed \(lost[0])\(when)" : "Closed \(lost.count) blocks with something to lose: \(lost.joined(separator: ", "))\(when)"
        // Undo while its time runs (⇧⌘T after, until it's collected).
        toast.show(text, action: "Undo", for: 12, countdown: true) { [weak self] in self?.reopenClosed(nil) }
        layoutViews()
    }

    /// ⇧⌘T: the last thing closed, back where it was — a tile into its
    /// workspace at its old place (here, if that workspace is gone), a
    /// workspace onto the desk. What has been collected meanwhile is
    /// skipped.
    @objc func reopenClosed(_ sender: Any?) {
        // Put away once it's back: a deletion waiting on the toast then
        // finds the block placed again, and isn't done.
        defer { toast.hide() }
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
    func debugToastAct() -> String { toast.debugAct() }
    func debugToastNudge() { toast.nudge() }
    func debugMarkArrival() -> String {
        guard let f = arrangement?.focused else { return "nothing focused" }
        content.markArrival(f)
        return "marked"
    }
    var debugFencing: String {
        hosts.all.map { c in
            "\(hosts.label(of: c.host)): " + (c.watching ? "watching, taken by \(c.fencedBy ?? "?"): \(c.fenced.map(\.description).sorted().joined(separator: " "))" : "leading")
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
        // A workspace seen is a step of the trail (⌘`'s order, back and
        // forward): not one only passed on ⌘`'s walk.
        guard walk == nil, window?.isVisible == true, window?.isMiniaturized == false, let a = arrangement, let id = selected else { return }
        var seen = Set(a.visible.map(\.block))
        seen.insert(id)
        if seen != lastSeenSet || force || Date().timeIntervalSince(lastSeenSent) > 14 {
            lastSeenSet = seen
            lastSeenSent = Date()
            hosts.propose(.seen(Array(seen)))
        }
    }


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

    private func mouseMoved(to p: NSPoint) {
        guard !pinned else { return }
        if p.x <= 6 && p.y >= 0 && p.y <= root.bounds.height {
            hideWork?.cancel()
            showSidebar(animated: true)
        } else if sidebarShown && p.x > sidebar.frame.maxX + Self.sidebarSlack {
            scheduleHide()
        } else if sidebarShown && sidebar.frame.insetBy(dx: -Self.sidebarSlack, dy: -Self.sidebarSlack).contains(p) {
            hideWork?.cancel()
        }
    }

    /// The sidebar wasn't made again while it was put away.
    private var organizationStale = false

    private func showSidebar(animated: Bool) {
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

    private func setTrafficLights(visible: Bool, animated: Bool) {
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
        // From outside: placed here, linked from nothing (the focused tile
        // has nothing to do with them).
        for path in paths { open(path, from: nil, here: false, over: false) }
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

    /// A pointer move, handed to the surface as its tracking area would.
    /// A synthesized move: to the grid (its stacks), and to whatever view
    /// is under the point that takes moves of its own (a scrubber, a
    /// command's dot).
    func debugHover(_ event: NSEvent) {
        content.mouseMoved(with: event)
        guard let root = window?.contentView, let hit = root.hitTest(root.convert(event.locationInWindow, from: nil)) else { return }
        var v: NSView? = hit
        while let view = v, view !== content {
            if view is ScrubberView || view is OutlineTicks || view is CommandDots || view is FloatingListRow || view is LinkBadge || view is StackColumnView || view is OrganizationView { view.mouseMoved(with: event); break }
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
    /// Debugging: the focused tile's address bar — "begin" (its pill a
    /// field), "type <text>", "key <down|up|tab|return|escape|delete|shiftdelete>",
    /// or nothing: the field and its completions.
    func debugOmni(_ arg: String) -> String {
        guard let f = arrangement?.focused, let pill = content.debugPill(f), let v = views[f] else { return "no tile focused" }
        let words = arg.split(separator: " ", maxSplits: 1).map(String.init)
        switch words.first {
        case "begin":
            guard let e = v.pillEdit else { return "no address to edit" }
            pill.beginEditing(e)
        case "type": pill.debugType(words.count > 1 ? words[1] : "")
        case "key": pill.debugKey(words.count > 1 ? words[1] : "")
        default: break
        }
        return pill.debugCompletions
    }

    func debugTicks(_ arg: String) -> String {
        let words = arg.split(separator: " ", maxSplits: 1).map(String.init)
        switch words.first {
        case "rows": return FloatingList.shared.debugRows
        case "click": return FloatingList.shared.debugClick(words.count > 1 ? words[1] : "")
        case "pointer": return FloatingList.shared.debugPointer(arg)
        case "leave": return FloatingList.shared.debugPointer("leave")
        default: break
        }
        guard let f = arrangement?.focused else { return "no tile focused" }
        guard let t = content.debugTicks(f) else { return "no outline" }
        if words.first == "open" {
            t.open()
            return FloatingList.shared.debugRows
        }
        return "frame \(NSStringFromRect(t.frame))\n" + t.debugState
    }

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
        // "dir show <host>:<path>": a folder tile of that host's, made here.
        if arg.hasPrefix("show ") {
            let parts = arg.dropFirst(5).split(separator: ":", maxSplits: 1).map(String.init)
            guard parts.count == 2 else { return "usage: dir show <host>:<path>" }
            show(hosts.directoryBlock(for: parts[1], on: HostID(parts[0])), lens: .directory, .here)
            return "ok"
        }
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
    var debugFocusedTerminal: TerminalView? { arrangement?.focused.flatMap { views[$0] as? TerminalView } }
    var debugFocusedEditor: EditorView? { arrangement?.focused.flatMap { views[$0] as? EditorView } }

    func debugSidebar(show: Bool) {
        if show { showSidebar(animated: false) } else { hideWork?.cancel(); hideSidebar() }
    }

    var debugPills: String { content.debugPills }
    var debugTiles: String { content.debugTiles }
    /// Debugging: a shown tile, by its title, given this much content
    /// height — taken from or given to the biggest other in its column.
    func debugTileHeight(_ title: String, _ points: CGFloat) -> String {
        guard let a = arrangement else { return "no workspace" }
        for (c, column) in a.columns.enumerated() {
            guard let p = column.first(where: { !a.isStashed($0.id) && hosts.block($0.block)?.displayTitle == title }) else { continue }
            guard let events = settingHeight(of: p.id, points: points, in: a) else { return "alone" }
            appendToSelected(events)
            return "ok"
        }
        return "no tile \(title)"
    }
    func debugPeek(_ on: Bool, button: Bool = false) -> String { content.debugPeek(on, button: button) }
    var debugPeekUp: String { content.debugPeekUp }
    var debugColumn: String { content.debugColumn }
    func debugPeekPick(_ i: Int) -> String { content.debugPeekPick(i) }
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
    var debugSheetTargets: String { content.debugSheetTargets }
    func debugFollowLink(toPlacementEndingIn suffix: String) -> String {
        guard let a = arrangement, let f = a.focused, let t = a.placements.first(where: { $0.id.hasSuffix(suffix) }) else { return "no \(suffix)" }
        gridOpenLink(t.block, from: f, modifiers: [])
        return debugStack(swap: false)
    }
    func debugClickSheets(drag: Bool) -> String { content.debugClickSheets(drag: drag) }
    func debugSwitcherPick(_ i: Int) -> String { content.debugSwitcherPick(i) }
    func debugSwitcherPointer() -> String { content.debugSwitcherPointer() }
    /// ⌃⇥ with control held, as far as the fan and its watching for its release.
    func debugWalkStack() {
        guard let a = arrangement, let f = a.focused, content.stepStackSwitcher(f, back: false) else { return }
        watchStackWalk()
    }
    /// Control let go, as the walk's monitor sees it (if it's still watching).
    func debugReleaseCommand() -> String {
        guard !stackMonitors.isEmpty else { return "not watching control" }
        endStackWalk(settling: true)
        return "settled"
    }

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
        if swap, index < 0, let next = behind.first { gridSwap(next.id) }
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

    /// A new web page beside the focused tile, its address to be typed.
    @objc func newWebPage(_ sender: Any?) {
        show(host.newWeb(url: "https://duckduckgo.com"), lens: .web, .beside)
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
    /// line (`#line=N`), going there from anywhere.
    @objc func copyLinkToLine(_ sender: Any?) {
        guard let f = focusedShown, let e = views[f.id] as? EditorView, case let .line(n)? = e.navLocation else { return NSSound.beep() }
        copyLink(to: f.placement.block, fragment: "line=\(n)")
    }

    /// New Note from Clipboard: its text as a note (a picture: an image block).
    @objc func newNoteFromClipboard(_ sender: Any?) {
        let pb = NSPasteboard.general
        if let s = pb.string(forType: .string), !s.isEmpty {
            show(host.newNote(home: focusedHost == host.host ? focusedCwd : nil, text: s), lens: .editor, .here)
        } else if case let images = TextView.images(on: pb), let (data, kind) = images.first {
            gridOpenDropped(.image(data, kind), column: max((arrangement?.columns.count ?? 1) - 1, 0), at: Int.max, newColumn: false)
        } else {
            NSSound.beep()
        }
    }

    @objc func newNote(_ sender: Any?) {
        let client = hosts.client(focusedHost) ?? host
        let note = client.newNote(home: focusedCwd)
        if let f = focusedShown, let b = f.block, b.kind != .arrangement {
            hosts.link(from: b.id, to: note, kind: .linked, context: "new note")
        }
        show(note, lens: .editor, .here)
    }

    /// The links a block has by hand (§3.5), for its bar: what it links to
    /// (→) and what links to it (←), and a note's images and the note an
    /// image is in — the most recent first, whichever way.
    private func links(of block: BlockID) -> [LinkCard] {
        // Straight from the graphs' edges: this runs for every tile on
        // every render.
        var seen = Set<BlockID>()
        var cards: [LinkCard] = []
        var stamps: [String: Stamp] = [:]
        // A note's images too (embeds), which aren't broken by hand.
        for kind in [LinkKind.linked, .embeds] {
            for c in hosts.all {
                for e in c.node.graph.edges(from: block, kind: .link(kind)) where e.isLive {
                    guard seen.insert(e.to).inserted, let b = hosts.block(e.to) else { continue }
                    cards.append(LinkCard(link: e.id, block: e.to, title: Self.linkTitle(b), symbol: Theme.symbolName(for: b), outbound: true, breakable: kind == .linked))
                    stamps[e.id] = e.at
                }
            }
            for c in hosts.all {
                for e in c.node.graph.edges(to: block, kind: .link(kind)) where e.isLive {
                    guard seen.insert(e.from).inserted, let b = hosts.block(e.from) else { continue }
                    cards.append(LinkCard(link: e.id, block: e.from, title: Self.linkTitle(b), symbol: Theme.symbolName(for: b), outbound: false, breakable: kind == .linked))
                    stamps[e.id] = e.at
                }
            }
        }
        // Stable: the edges' order among equal stamps, and unstamped last.
        return cards.enumerated().sorted { a, b in
            switch (stamps[a.element.link], stamps[b.element.link]) {
            case let (x?, y?) where x != y: return x > y
            case (_?, nil): return true
            case (nil, _?): return false
            default: return a.offset < b.offset
            }
        }.map(\.element)
    }

    /// A linked block's name on a badge: a note by its title or first words.
    private static func linkTitle(_ b: Block) -> String { b.kind == .text && b.path == nil ? noteTitle(b) : b.displayTitle }

    /// A block ⇧-dragged onto another: linked, from it to the target.
    func link(_ block: BlockID, to target: BlockID) {
        guard block != target else { return }
        hosts.link(from: block, to: target, kind: .linked, context: "⇧-dragged in")
    }

    /// Debugging: typed into the focused editor, as keys would be.
    func debugType(_ text: String) -> String {
        guard let e = debugFocusedEditor else { return "no editor focused" }
        e.debugType(text)
        return "typed \(text.count)"
    }

    /// Debugging: a block ⇧-dragged into the focused editor, dropped at its caret.
    /// Debugging: a block ⇧-dragged onto the focused tile — an editor, a
    /// terminal (or agent), a notebook (outside its cells).
    func debugDrop(_ block: BlockID) -> String {
        guard let b = hosts.block(block) else { return "no such block" }
        // As a ⇧-drag writes it (a block with no path, its link alone).
        let pb = NSPasteboard(name: NSPasteboard.Name("com.manifold.debug-drop"))
        pb.clearContents()
        guard let item = pathDragItem(for: block, linkOnly: false) else { return "no drag for \(b.displayTitle)" }
        for t in item.types { if let s = item.string(forType: t) { pb.setString(s, forType: t) } }
        if let e = debugFocusedEditor { return e.debugDrop(pb) ? "dropped" : "refused" }
        guard let f = focusedShown, let v = views[f.placement.id] else { return "nothing focused" }
        if let t = v as? TerminalView {
            let (taken, gives) = t.accepts(pb)
            guard taken else { return "refused as it's dragged over" }
            return (t.take(pb) ? "dropped" : "refused") + (gives ? ", its contents given" : ", typed")
        }
        if let n = v as? NotebookView { return n.take(pb) ? "dropped" : "refused" }
        return "the focused tile takes no drops"
    }

    /// Debugging: what Copy Contents would copy, from the focused tile (or
    /// the block named) — not put on the pasteboard; the previous ask's.
    private var debugContentsAnswer = "-"
    func debugContents(_ name: String) -> String {
        let last = debugContentsAnswer
        let b: Block? = BlockID(string: name).flatMap { hosts.block($0) } ?? focusedShown?.block
        guard let b else { return "nothing focused" }
        let view = views.first { $0.value.block == b.id }?.value
        Task { @MainActor [weak self] in
            do { self?.debugContentsAnswer = try await self?.maniDesk.contents(of: b, view: view, all: true) ?? "" } catch let e as ManiDesk.Failure { self?.debugContentsAnswer = "failure: " + e.message } catch {}
        }
        return last
    }

    /// Debugging: a terminal's outline item ⇧-dragged onto the focused
    /// terminal, as a drag would land: refused as it's over it, or taken.
    func debugDropCommand(from terminal: BlockID, _ i: Int) -> String {
        guard let source = views.values.first(where: { $0.block == terminal }) as? TerminalView,
              let item = source.debugOutlineDrag(i) else { return "no outline item \(i) there" }
        guard let f = focusedShown, let t = views[f.placement.id] as? TerminalView else { return "no terminal focused" }
        let pb = NSPasteboard(name: NSPasteboard.Name("com.manifold.debug-drop"))
        pb.clearContents()
        for type in item.types { if let s = item.string(forType: type) { pb.setString(s, forType: type) } }
        let carried = item.types.map(\.rawValue).joined(separator: ", ")
        let (taken, gives) = t.accepts(pb)
        guard taken else { return "refused as it's dragged over (\(carried))" }
        return (t.take(pb) ? "dropped" : "refused") + (gives ? ", its contents given" : ", typed") + " (\(carried))"
    }

    func debugDropRow(_ i: Int) -> String {
        guard let e = debugFocusedEditor else { return "no editor focused" }
        let rows = FloatingList.shared.rows
        guard rows.indices.contains(i), let item = rows[i].drag?([.shift]) as? NSPasteboardItem else { return "no row \(i)" }
        let pb = NSPasteboard(name: NSPasteboard.Name("com.manifold.debug-drop"))
        pb.clearContents()
        for t in item.types { if let s = item.string(forType: t) { pb.setString(s, forType: t) } }
        return e.debugDrop(pb) ? "dropped" : "refused"
    }

    /// What to call a note: its title, else its first line (`Block.noteTitle`), else "Note".
    static func noteTitle(_ b: Block) -> String {
        if let t = b.title, !t.isEmpty { return t }
        return b.text.flatMap { Block.noteTitle(from: $0.text) } ?? b.displayTitle
    }

    /// A linked block from a tile's badge: gone to where it is; placed
    /// nowhere, opened beside the tile.
    /// A tile's link clicked, as every link goes: to it (or, if it's
    /// nowhere, beside); ⌘ beside; ⌥ over; ⇧⌘ to the system's app.
    func gridOpenLink(_ block: BlockID, from placement: PlacementID, modifiers: NSEvent.ModifierFlags) {
        follow(block, from: placement, Disposition(modifiers), context: "from its links")
    }

    /// × on a badge's link: the edge ends, in both readings at once.
    func gridBreakLink(_ link: String) { hosts.propose(.unlink(link)) }


    /// Saves a text block: through an editor on it (this tile's first),
    /// which keeps its own count of what's saved and names a note's file;
    /// else straight to its file.
    func save(_ block: BlockID, from placement: PlacementID) {
        let editors = views.values.compactMap { $0 as? EditorView }.filter { $0.block == block }
        if let e = editors.first(where: { $0.placement == placement }) ?? editors.first { return e.saveDocument(nil) }
        guard let b = hosts.block(block), b.path != nil, !b.needsRead, let t = b.text else { return NSSound.beep() }
        hosts.propose(.writeFile(block, version: t.version))
    }

    /// The bar's ×: the tile taken off, as ⌘W takes the focused one.
    func gridClose(_ placement: PlacementID) {
        guard let id = selected else { return }
        closeTile(placement, in: id)
    }

    /// A tile closed, however it's asked for (⌘W, its ×, its menu, the
    /// sidebar's): kept to reopen (⇧⌘T), and what it leaves to be
    /// collected said, with Restore, if it had edits or a job running.
    /// ⌥⌘W: the focused editor (or a menu's) saved, then its tile closed —
    /// once the file is written, not before: an `$EDITOR`'s command, which
    /// reads it, ends as the tile goes. A file with nothing unsaved just
    /// closes; a note with no file is saved as one first (⌘S's panel);
    /// a save that fails leaves the tile, and says so.
    @objc func saveAndClose(_ sender: Any?) {
        guard let p = ((sender as? NSMenuItem)?.representedObject as? PlacementID) ?? arrangement?.focused else { return NSSound.beep() }
        saveAndClose(tile: p)
    }

    func saveAndClose(tile p: PlacementID) {
        guard let ws = selected, let shown = arrangement?.placement(p), let b = hosts.block(shown.block),
              b.kind == .text, b.text != nil else { return NSSound.beep() }
        if b.path != nil, b.text?.isDirty != true { return closeTile(p, in: ws) }
        if let e = views[p] as? EditorView { e.saveDocument(nil) } else { save(b.id, from: p) }
        savingToClose[p] = (b.id, ws, Date().addingTimeInterval(b.path == nil ? 600 : 15))
        closeOnceSaved()
    }

    /// Tiles waiting on their saves to close (⌥⌘W): the block, its space,
    /// and when to give up (a note's save panel may be open a while).
    private var savingToClose: [PlacementID: (block: BlockID, space: BlockID, until: Date)] = [:]

    private func closeOnceSaved() {
        for (p, w) in savingToClose {
            guard let b = hosts.block(w.block), hosts.arrangement(w.space)?.placement(p) != nil else {
                savingToClose.removeValue(forKey: p)
                continue
            }
            if b.statusRecord?.state == .error {
                savingToClose.removeValue(forKey: p)
                toast.show("Couldn't save “\(b.displayTitle)”: its tile stays", action: "OK", for: 6) {}
            } else if b.path != nil, b.text?.isDirty == false {
                savingToClose.removeValue(forKey: p)
                closeTile(p, in: w.space)
            } else if Date() > w.until {
                savingToClose.removeValue(forKey: p)
            }
        }
        guard !savingToClose.isEmpty else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in self?.closeOnceSaved() }
    }

    func closeTile(_ placement: PlacementID, in id: BlockID) {
        guard let a = hosts.arrangement(id), a.placement(placement) != nil else { return }
        let before = hosts.reachable()
        noteClosing(placement, in: id)
        hosts.append([.remove(placement)], to: .block(id))
        afterClosing(reachedBefore: before)
    }

    func gridLink(_ block: BlockID, to target: PlacementID) {
        guard let t = shown(target)?.block else { return }
        link(block, to: t.id)
    }

    /// Edit Address: the focused tile's pill edits what it offers (a page's address).
    @objc func editAddress(_ sender: Any?) {
        if !content.editFocusedPill() { NSSound.beep() }
    }

    /// ⌘L: in an editor, Go to Line; elsewhere, the tile's address edited
    /// (a page's, as a browser's ⌘L).
    @objc func goToLineOrAddress(_ sender: Any?) {
        if let e = arrangement?.focused.flatMap({ views[$0] }) as? EditorView { return e.goToLine(sender) }
        editAddress(sender)
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

    /// ⌘W: the focused tile taken off, its column showing what it showed
    /// before (its block kept while a space reaches it). With another
    /// window in front — Settings, a panel — that window closes instead:
    /// the action comes here by way of the main window.
    @objc func closePaneOrTab(_ sender: Any?) {
        if let key = NSApp.keyWindow, key !== window, key.styleMask.contains(.closable) { return key.performClose(sender) }
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
        afterClosing(reachedBefore: before)
    }

    /// ⇧⌘W: the focused tile's block deleted (or `sender`'s, a menu's).
    @objc func deleteFocusedBlock(_ sender: Any?) {
        let block = ((sender as? NSMenuItem)?.representedObject as? PlacementID).flatMap { arrangement?.placement($0)?.block }
            ?? focusedShown?.placement.block
        guard let block else { return NSSound.beep() }
        deleteBlock(block)
    }

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
            return (host.newWeb(url: address), .web, false)
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

    /// File ▸ New's items, by kind: each the action it always had, so a
    /// menu's New Note is ⇧⌘N's note (linked from the focused block), a
    /// search Find in Files', a repository's block as Source Control finds it.
    static let newActions: [String: Selector] = [
        "terminal": #selector(newTerminalBeside(_:)), "agent": #selector(newAgent(_:)), "note": #selector(newNote(_:)),
        "web": #selector(newWebPage(_:)), "search": #selector(findInFiles(_:)), "folder": #selector(browseFocusedFolder(_:)),
        "notebook": #selector(newShellNotebook(_:)), "git": #selector(showGit(_:)), "smartlog": #selector(showSmartlog(_:)),
        "process": #selector(showProcesses(_:)),
    ]

    /// ⌥⌘N: the New Block picker — the kinds, narrowed as a kind's name is
    /// typed, then what it takes after a space ("web example.com", "search
    /// TODO", "terminal make test"), as `mani new` reads its words; ↩ makes
    /// it in the active column, ⌘↩ beside the focused tile, ⌥↩ over it.
    @objc func newBlockPicker(_ sender: Any?) {
        let provider: (String) -> [FinderItem] = { [weak self] query in
            let (word, what) = BlockKinds.parse(query)
            return BlockKinds.matching(word).map { k in
                let with = k.what == nil ? nil : what
                return FinderItem(symbol: k.symbol, title: "New " + k.title + (with.map { " — " + $0 } ?? ""), detail: k.help,
                                  note: k.what.map { with == nil ? "then: \($0)" : "" } ?? "",
                                  run: { [weak self] in self?.makeFromPicker(k, with) })
            }
        }
        finder.showOutline(Finder.OutlineScope(provider: provider, start: nil,
                                               placeholder: "New block: a kind, then what it takes — web example.com",
                                               hint: "Make a block", keys: "↩ Here    ⌘↩ Beside    ⌥↩ Over    ⎋ Close"),
                           over: window)
    }

    private func makeFromPicker(_ kind: BlockKinds.Kind, _ what: String?) {
        let f = arrangement?.focused
        let place: Where = switch Self.disposition ?? .goTo {
        case .beside: f.map { .besideOpener($0) } ?? .here
        case .over: f.map { .over($0) } ?? .here
        default: .here
        }
        do {
            let from = focusedShown?.block
            let made = try makeBlock(kind, what: what, cwd: focusedCwd, on: focusedHost)
            // A note is about what was focused, as ⇧⌘N's is.
            if kind.name == "note", let b = from, b.kind != .arrangement { hosts.link(from: b.id, to: made.block, kind: .linked, context: "new note") }
            if made.later { showWhenMade(made.block, lens: made.lens, place: place, what: "the " + kind.title.lowercased()) }
            else { show(made.block, lens: made.lens, place, context: "new " + kind.name) }
        } catch let f as MakeFailure {
            toast.show(f.message, action: "OK", for: 5) {}
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
        toast.show(text, action: "Undo", for: loses.isEmpty ? 8 : 12, countdown: true, then: { [weak self] in
            self?.deleteNow(block)
        }) { [weak self] in
            guard let self else { return }
            for _ in 0..<tiles { self.reopenClosed(nil) }
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

    /// ⌥⇧⌘W: the workspace removed — the only way one goes (§4); what only
    /// it kept is collected after the grace, reopened meanwhile by ⇧⌘T.
    @objc func closeTab(_ sender: Any?) {
        guard let id = selected else { return }
        let before = hosts.reachable()
        removeFromDesk(id)
        afterClosing(reachedBefore: before)
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
            items.append(ClosureMenuItem("Reset Server on \(label)…", symbol: "arrow.triangle.2.circlepath") { [weak self] in self?.resetServer(host) })
        }
        if hosts.client(host)?.isRemote == false {
            // This Mac's own (another host's are in its own menu).
            items.append(ClosureMenuItem("Preferences for \(label)…", symbol: "gearshape") { [weak self] in self?.editPreferences(host) })
        }
        if ownRow {
            let graph = ClosureMenuItem("Reset Graph on \(label)…", symbol: "point.3.connected.trianglepath.dotted") { [weak self] in self?.resetGraph(host) }
            graph.isEnabled = hosts.client(host)?.isConnected == true
            items.append(.separator())
            items.append(graph)
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
            self.toast.show("Forwarding \(port) from \(self.hosts.label(of: h))…", action: "", for: 30) {}
        }
        c.forwards.forward(port) { [weak self] local in
            finished = true
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
        alert.informativeText = "Every link between the host's blocks is forgotten — opened from, found by, mentions, compared, made by hand — and the trail of where you went, before and after. What's on each space stays. This can't be undone."
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
        alert.informativeText = "Manifold installs its server there again, whatever is there now, and restarts it. Every shell on the host ends; its terminals start new ones, each in its folder. Blocks and spaces stay."
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
    /// takes over. Emptied, it's called by its first line again (as the
    /// host titles an unnamed note).
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
        case #selector(togglePinInWorkspace(_:)):
            // Named for what it will do to its tile's block.
            guard let id = selected, let block = pinTarget(item) else { item.title = "Pin in Space"; return false }
            let on = isPinned(block, in: id)
            item.title = on ? "Unpin" : "Pin in Space"
            item.image = Theme.symbol(on ? "pin.slash" : "pin", size: 13)
            return true
        case #selector(unstackFocused(_:)), #selector(closeFocusedStack(_:)):
            // Only for a tile with a stack behind it.
            guard let a = arrangement, let f = a.focused, let (c, _) = a.locate(f) else { return false }
            return a.columns[c].contains { a.isStashed($0.id) && a.tile(behind: $0.id)?.id == f }
        case #selector(setTerminalDormancy(_:)):
            item.state = item.tag == desk.settings.terminalDormantAfterHours ? .on : .off
        case #selector(nextInInbox(_:)):
            return !inboxOrder().isEmpty
        case #selector(printTile(_:)):
            return arrangement?.focused.flatMap { views[$0] } is Printable
        case #selector(goToLineOrAddress(_:)):
            // Named for what it will do in the focused tile.
            let v = arrangement?.focused.flatMap { views[$0] }
            if v is EditorView { item.title = "Go to Line…"; return true }
            item.title = v?.pillEdit != nil ? "Edit Address" : "Go to Line…"
            return v?.pillEdit != nil
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
        case #selector(growTile(_:)), #selector(fillColumn(_:)):
            return arrangement?.focused != nil
        case #selector(saveAndClose(_:)):
            return focusedShown.map { $0.block?.kind == .text } ?? false
        case #selector(deleteFocusedBlock(_:)):
            return focusedShown.map { $0.block?.kind != .arrangement } ?? false
        case #selector(stashTile(_:)):
            // As the tile's menu: not for a tile alone in its column.
            guard let a = arrangement, let f = a.focused, let c = a.columnIndex(of: f), !a.isStashed(f) else { return false }
            return a.shownTiles(inColumn: c).count > 1
        case #selector(walkStack(_:)), #selector(walkStackBack(_:)):
            guard let a = arrangement, let f = a.focused, let (c, _) = a.locate(f) else { return false }
            return content.isSwitching || a.columns[c].contains { a.isStashed($0.id) && a.tile(behind: $0.id)?.id == f }
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
        case #selector(toggleInspector(_:)):
            item.state = organization == .inspector && sidebarShown ? .on : .off
        case #selector(toggleSidebarFilter(_:)):
            item.state = sidebarFilter != nil ? .on : .off
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

    // MARK: ⌘`

    /// ⌘` (⇧⌘` back): with ⌘ held, a walk through the arrangements most
    /// recently settled on first, each shown at once sliding in from the
    /// right (from the left, going back); letting go of ⌘ settles on the
    /// one come to. The ones passed on the way aren't settled on; Escape
    /// goes back to where the walk began. With one workspace, ⌘` goes to
    /// the app's next window, as macOS has it.
    @objc func walkTabs(_ sender: Any?) { walkTabs(back: false) }
    @objc func walkTabsBack(_ sender: Any?) { walkTabs(back: true) }

    private func walkTabs(back: Bool) {
        let live = Set(allWorkspaces)
        // A walk whose ⌘ was let go unheard (the app left meanwhile) is over.
        if walk != nil, !walkMonitors.isEmpty, !NSEvent.modifierFlags.contains(.command), !debugHeld { endWalk(settling: true) }
        if walk == nil {
            guard let current = selected, allWorkspaces.count > 1 else { return cycleWindows(back: back) }
            var order = [current]
            for id in settled.map(\.space) + hosts.recentWorkspaces() + allWorkspaces where live.contains(id) && !order.contains(id) { order.append(id) }
            walk = (order, 0)
            if NSEvent.modifierFlags.contains(.command) || debugHeld { watchWalk() }
        }
        guard var w = walk else { return }
        w.ids = w.ids.filter { live.contains($0) }
        guard w.ids.count > 1 else { return endWalk(settling: true) }
        let n = w.ids.count
        w.index = ((back ? w.index - 1 : w.index + 1) % n + n) % n
        walk = w
        show(arrangement: w.ids[w.index])
        // From the menu, without ⌘ held, it's one step and settled.
        if walkMonitors.isEmpty { endWalk(settling: true) }
    }

    private func watchWalk() {
        walkLeaving = NotificationCenter.default.addObserver(forName: NSApplication.didResignActiveNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.endWalk(settling: true) }
        }
        walkMonitors.append(NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            if !event.modifierFlags.contains(.command) { self?.endWalk(settling: true) }
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
        if let o = walkLeaving { NotificationCenter.default.removeObserver(o) }
        walkLeaving = nil
        guard let w = walk else { return }
        walk = nil
        if !settling, let home = w.ids.first {
            show(arrangement: home)
        } else {
            settleHere()
        }
        // Seen now, settled on: what was passed on the way wasn't.
        noteSeen(force: true)
    }

    var debugFlights: String { [content.debugFlights, GridView.describe(tileFlights)].filter { !$0.isEmpty }.joined(separator: "\n") }

    /// Debugging: ⌘ taken as held, for "walk".
    private var debugHeld = false

    /// "walk step|back|end|escape|unheard|order": ⌘` pressed with ⌘ held,
    /// ⌘ let go, Escape, ⌘ let go unheard; or the walk and ⌘`'s order.
    func debugWalk(_ arg: String) -> String {
        switch arg {
        case "step", "back":
            debugHeld = true
            walkTabs(back: arg == "back")
        case "end": endWalk(settling: true)
        case "escape": endWalk(settling: false)
        case "unheard": debugHeld = false
        default: break
        }
        if walk == nil { debugHeld = false }
        func name(_ id: BlockID) -> String { hosts.block(id)?.title ?? id.ulid.description }
        return "cmd=\(NSEvent.modifierFlags.contains(.command)) selected=\(selected.map(name) ?? "-") walk=\(walk.map { "\($0.index):" + $0.ids.map(name).joined(separator: ",") } ?? "-") settled=\(settled.prefix(6).map(\.space).map(name).joined(separator: ",")) trail=\(hosts.recentWorkspaces().prefix(6).map(name).joined(separator: ","))"
    }

    /// Where the window is now, settled on: the latest place on its trail.
    private func settleHere() {
        guard let space = selected else { return }
        let here = Place(space: space, tile: hosts.arrangement(space)?.focused)
        settled.removeAll { $0 == here || ($0.space == space && $0.tile == nil) }
        settled.insert(here, at: 0)
        if settled.count > 200 { settled.removeLast() }
    }

    // MARK: ⌥⇥

    /// ⌥⇥ (⌥⇧⇥ back): the tiles most recently settled on first, in every
    /// space — the trail ⌘` walks by space, tile by tile. As ⌘⇥ is: let
    /// go quickly, and it's gone to the one before (back and forth between
    /// two); held a moment, the cards come, each ⌥⇥ a step further, and
    /// letting go of option goes to the one chosen — its card becoming its
    /// tile, in its space. Those passed on the way aren't settled on;
    /// Escape leaves things be. From the menu it's one step.
    @objc func walkTiles(_ sender: Any?) { walkTiles(back: false) }
    @objc func walkTilesBack(_ sender: Any?) { walkTiles(back: true) }

    /// The tiles of the trail, the latest first, from where the window is:
    /// those settled on here, then the hosts' trail, then the rest of this
    /// space. Each tile once, and only one still on the desk.
    private func tileTrail() -> [Place] {
        var home: [PlacementID: BlockID] = [:]
        for w in allWorkspaces {
            for p in hosts.arrangement(w)?.placements ?? [] where !recentlyClosed.contains(p.block) { home[p.id] = w }
        }
        var out: [Place] = []
        var seen: Set<PlacementID> = []
        func add(_ p: PlacementID?) {
            guard let p, let w = home[p], seen.insert(p).inserted else { return }
            out.append(Place(space: w, tile: p))
        }
        add(arrangement?.focused)
        for s in settled { add(s.tile) }
        for s in trailSteps().reversed() { add(s.placement) }
        for c in arrangement?.columns ?? [] { for p in c { add(p.id) } }
        return Array(out.prefix(Self.tileWalkLimit))
    }

    static let tileWalkLimit = 24

    private func walkTiles(back: Bool) {
        let step = back ? -1 : 1
        if var w = tileWalk {
            // Option let go unheard (the app left meanwhile): over.
            if tileMonitors.isEmpty || (!NSEvent.modifierFlags.contains(.option) && !debugHeld) { endTileWalk(settling: true) } else {
                let n = w.places.count
                w.index = ((w.index + step) % n + n) % n
                tileWalk = w
                tileSwitcher?.column.choose(w.index)
                return
            }
        }
        let places = tileTrail()
        // Where the walk begins: the focused tile, or (none) before the first.
        let start = places.first.map { $0.tile == arrangement?.focused } == true ? 0 : -1
        guard places.count > (start == 0 ? 1 : 0) else { return NSSound.beep() }
        let n = places.count
        let index = ((start + step) % n + n) % n
        guard NSEvent.modifierFlags.contains(.option) || debugHeld else { return go(to: places[index]) }
        let work = DispatchWorkItem { [weak self] in self?.showTileSwitcher() }
        tileWalk = (places, index, work)
        watchTileWalk()
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.switcherDelay, execute: work)
    }

    private func watchTileWalk() {
        tileMonitors.append(NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            if !event.modifierFlags.contains(.option) { self?.endTileWalk(settling: true) }
            return event
        } as Any)
        tileMonitors.append(NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard event.keyCode == 53 else { return event }
            self?.endTileWalk(settling: false)
            return nil
        } as Any)
        tileLeaving = NotificationCenter.default.addObserver(forName: NSApplication.didResignActiveNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.endTileWalk(settling: true) }
        }
    }

    /// Option let go (`settling`), or Escape: let go before the cards
    /// showed, gone to the tile stepped to with nothing shown; after, the
    /// card chosen becomes its tile, and the rest go back to theirs.
    private func endTileWalk(settling: Bool, to chosen: Int? = nil) {
        tileMonitors.forEach(NSEvent.removeMonitor)
        tileMonitors = []
        if let o = tileLeaving { NotificationCenter.default.removeObserver(o) }
        tileLeaving = nil
        debugHeld = false
        guard let w = tileWalk else { return }
        tileWalk = nil
        w.show.cancel()
        let index = chosen ?? w.index
        let target = settling && w.places.indices.contains(index) ? w.places[index] : nil
        guard let (frame, column) = tileSwitcher else {
            if let target { go(to: target) }
            return
        }
        tileSwitcher = nil
        landTiles()
        let cards = column.cardPictures(in: root)
        frame.removeFromSuperview()
        let home = arrangement?.focused
        if let target { go(to: target) }
        guard let host = root.layer else { return }
        // Where the space has its tiles now (the one gone to, if another).
        content.layoutSubtreeIfNeeded()
        let tiles = partsInRoot(content.placedParts(), from: content)
        let sheets = sheetsInRoot(for: w.places)
        let arriving = target?.tile ?? home
        var items: [GridView.Morph] = []
        for c in cards where c.frame != .zero {
            let card = GridView.Pictured(parts: [(c.frame, c.picture)], ground: c.ground)
            if c.id == arriving {
                // The one chosen (or, let be, the one it began from) becomes its tile.
                content.becomeTile(c.id, from: card, picture: c.picture, at: c.frame, in: root)
            } else if let tile = tiles[c.id] {
                // Back into its tile, here.
                items.append(GridView.Morph(from: c.frame, to: tile.whole, leaving: card, shrink: GridView.cardShrink))
            } else if let sheet = sheets[c.id] {
                // Back into its sheet, here.
                items.append(GridView.Morph(from: c.frame, to: sheet, leaving: card))
            } else if let place = w.places.first(where: { $0.tile == c.id }), let t = place.tile,
                      let row = sidebar.organizationView.row(of: t, in: place.space, in: root) {
                // In another space: back into its row in the sidebar.
                items.append(GridView.Morph(from: c.frame, to: row, leaving: card))
            } else {
                // Its tile's in another space: gone, sinking a little.
                let l = CALayer()
                l.contents = c.picture
                l.backgroundColor = c.ground
                l.frame = c.frame
                l.cornerRadius = Radius.surface
                l.cornerCurve = .continuous
                l.masksToBounds = true
                l.zPosition = 39
                l.opacity = 0
                host.addSublayer(l)
                let fade = CABasicAnimation(keyPath: "opacity")
                fade.fromValue = 1
                fade.toValue = 0
                let sink = CABasicAnimation(keyPath: "transform.scale")
                sink.fromValue = 1
                sink.toValue = Motion.reduced ? 1 : 0.94
                let g = CAAnimationGroup()
                g.animations = [fade, sink]
                g.duration = Motion.fast
                g.timingFunction = Motion.disappear
                CATransaction.begin()
                CATransaction.setCompletionBlock { l.removeFromSuperlayer() }
                l.add(g, forKey: "gone")
                CATransaction.commit()
                tileFlights.append(l)
            }
        }
        tileFlights += GridView.morph(items, in: host, over: Motion.spatial * 1.5)
    }

    /// The sheets of the space shown that `places`' tiles are in (the
    /// root's terms), by tile.
    private func sheetsInRoot(for places: [Place]) -> [PlacementID: NSRect] {
        let sheets = content.sheetPlaces()
        var out: [PlacementID: NSRect] = [:]
        for p in places where p.space == selected {
            guard let t = p.tile, let b = arrangement?.placement(t)?.block, let r = sheets[b] else { continue }
            out[t] = root.convert(r, from: content)
        }
        return out
    }

    private func landTiles() {
        tileFlights.forEach { $0.removeFromSuperlayer() }
        tileFlights = []
        tileSwitcher?.column.cardsShown = true
    }

    /// Goes to a place: its space shown, its tile out of its stack (from
    /// behind a maximized one) and focused, the pointer on it.
    private func go(to p: Place) {
        guard let t = p.tile, let a = hosts.arrangement(p.space), a.placement(t) != nil else { return NSSound.beep() }
        if stateView != nil { hideStateView() }
        if selected != p.space { hosts.select(p.space) }
        if a.focused != t || a.isStashed(t) || (a.full != nil && a.full != t) {
            hosts.append(arriving(t, in: a), to: .block(p.space))
        }
        render()
        warpPointerToFocus()
    }

    /// Held past the wait: the cards, over the space, the one stepped to
    /// chosen — the focused tile becoming the first, the rest coming from
    /// their tiles here, or out from under it.
    private func showTileSwitcher() {
        guard let w = tileWalk, tileSwitcher == nil, NSEvent.modifierFlags.contains(.option) || debugHeld else { return }
        let entries = w.places.compactMap { p -> SummaryCardContent? in
            guard let t = p.tile, let b = hosts.arrangement(p.space)?.placement(t)?.block, var c = cardContent(for: b, view: views[t], id: t) else { return nil }
            // Where it is, if not here.
            if p.space != selected, let a = hosts.arrangement(p.space) { c.age = title(of: a) }
            return c
        }
        guard entries.count == w.places.count else { return endTileWalk(settling: false) }
        let column = StackColumnView(entries: entries, selection: w.index)
        column.onPick = { [weak self] id, _ in
            guard let self, let i = self.tileWalk?.places.firstIndex(where: { $0.tile == id }) else { return }
            self.endTileWalk(settling: true, to: i)
        }
        column.onCancel = { [weak self] in self?.endTileWalk(settling: false) }
        let room = root.convert(content.bounds, from: content).insetBy(dx: 32, dy: 32)
        let width = min(520, room.width)
        let height = min(StackColumnView.height(for: entries.count), room.height, 640)
        // Floating over the space: a shadow under the column.
        let frame = NSView(frame: NSRect(x: room.midX - width / 2, y: room.midY - height / 2, width: width, height: height).integral)
        frame.wantsLayer = true
        Elevation.float.apply(to: frame.layer!)
        frame.layer?.shadowPath = CGPath(roundedRect: frame.bounds, cornerWidth: Radius.surface, cornerHeight: Radius.surface, transform: nil)
        frame.layer?.zPosition = 30
        column.frame = frame.bounds
        column.autoresizingMask = [.width, .height]
        frame.addSubview(column)
        root.addSubview(frame, positioned: .above, relativeTo: stateView ?? stage)
        tileSwitcher = (frame, column)
        column.present(dealt: false)
        guard !Motion.reduced, let host = root.layer else { return fadeIn(frame) }
        content.layoutSubtreeIfNeeded()
        let tiles = partsInRoot(content.placedParts(), from: content)
        let sheets = sheetsInRoot(for: w.places)
        let cards = column.cardPictures(in: root)
        guard let first = cards.first(where: { $0.frame != .zero }) else { return }
        var items: [GridView.Morph] = []
        for (i, c) in cards.enumerated() where c.frame != .zero {
            let card = GridView.Pictured(parts: [(c.frame, c.picture)], ground: c.ground)
            if let tile = tiles[c.id] {
                items.append(GridView.Morph(from: tile.whole, to: c.frame, leaving: tile, coming: card, shrink: GridView.cardShrink))
            } else if let sheet = sheets[c.id] {
                // Pulled out of its stack's sheet.
                items.append(GridView.Morph(from: sheet, to: c.frame, coming: card, delay: Double(i) * 0.03))
            } else if let place = w.places.first(where: { $0.tile == c.id }), let t = place.tile,
                      let row = sidebar.organizationView.row(of: t, in: place.space, in: root) {
                // In another space: out of its row in the sidebar.
                items.append(GridView.Morph(from: row, to: c.frame, coming: card, delay: Double(i) * 0.03))
            } else {
                // Elsewhere: out from under the first.
                items.append(GridView.Morph(from: first.frame, to: c.frame, coming: card, delay: Double(i) * 0.03))
            }
        }
        let d = Motion.spatial * 1.5
        column.cardsShown = false
        tileFlights += GridView.morph(items, in: host, over: d) { [weak column] in column?.cardsShown = true }
        // The column's ground comes in under them.
        if let l = column.layer, let ground = l.backgroundColor {
            let a = CABasicAnimation(keyPath: "backgroundColor")
            a.fromValue = ground.copy(alpha: 0)
            a.toValue = ground
            a.duration = d
            a.timingFunction = Motion.appear
            l.add(a, forKey: "ground")
            let s = CABasicAnimation(keyPath: "shadowOpacity")
            s.fromValue = 0
            s.toValue = frame.layer?.shadowOpacity ?? 0
            s.duration = d
            frame.layer?.add(s, forKey: "ground")
        }
    }

    /// "tilewalk step|back|end|escape|order|pick <n>": ⌥⇥ pressed with
    /// option held, option let go, Escape, a card clicked; or the walk and
    /// ⌥⇥'s order.
    func debugTileWalk(_ arg: String) -> String {
        let w = arg.split(separator: " ").map(String.init)
        switch w.first ?? "" {
        case "step", "back":
            debugHeld = true
            walkTiles(back: w.first == "back")
        case "show": tileWalk.map { _ in showTileSwitcher() }
        case "end": endTileWalk(settling: true)
        case "escape": endTileWalk(settling: false)
        case "pick": if let i = w.dropFirst().first.flatMap({ Int($0) }) { tileSwitcher.map { _ = $0.column.debugPick(i) } }
        default: break
        }
        func name(_ p: Place) -> String {
            let t = p.tile.flatMap { hosts.arrangement(p.space)?.placement($0)?.block }.flatMap { hosts.block($0)?.summary().title } ?? "-"
            return t + (p.space == selected ? "" : "@" + String(p.space.ulid.suffix(4)))
        }
        let here = selected.map { name(Place(space: $0, tile: arrangement?.focused)) } ?? "-"
        return "focused=\(here) walk=\(tileWalk.map { "\($0.index):" + $0.places.map(name).joined(separator: ",") } ?? "-") cards=\(tileSwitcher != nil) order=\(tileTrail().prefix(8).map(name).joined(separator: ","))"
    }

    // MARK: ⌃⇥

    /// ⌃⇥ (⌃⇧⇥ back): with control held, the focused tile's stack as a file
    /// of cards over its tile — the top drops flat to the bottom and the
    /// one beneath stands up in front, leaning back, the title bars of the
    /// rest behind it; each ⇥ flips the next one down, scrolling works
    /// too, and letting go of control brings the chosen one forward to the
    /// top (Escape leaves things be). From the menu it's one step.
    @objc func walkStack(_ sender: Any?) { walkStack(back: false) }
    @objc func walkStackBack(_ sender: Any?) { walkStack(back: true) }

    private func walkStack(back: Bool) {
        guard let a = arrangement, let f = a.focused else { return NSSound.beep() }
        if content.isSwitching {
            _ = content.stepStackSwitcher(f, back: back)
            return
        }
        // Pressed again before the cards show: a step more, still unseen.
        if var q = quickWalk {
            q.steps += back ? -1 : 1
            quickWalk = q
            return
        }
        if NSEvent.modifierFlags.contains(.control) {
            // As ⌘⇥ is: let go quickly, and it's gone to the tile behind
            // (⌃⇧⇥, the farthest) with nothing shown; held a moment, the
            // cards come, the steps taken meanwhile already taken.
            guard !a.isStashed(f), let (c, _) = a.locate(f),
                  a.columns[c].contains(where: { a.isStashed($0.id) && a.tile(behind: $0.id)?.id == f }) else { return NSSound.beep() }
            let work = DispatchWorkItem { [weak self] in self?.showQuickWalk() }
            quickWalk = (f, back ? -1 : 1, work)
            watchStackWalk()
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.switcherDelay, execute: work)
            return
        }
        guard !a.isStashed(f), content.stepStackSwitcher(f, back: back) else { return NSSound.beep() }
        // From the menu: one step, seen, then settled on.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in self?.content.settleStackSwitcher() }
    }

    private func watchStackWalk() {
        stackMonitors.append(NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            if !event.modifierFlags.contains(.control) { self?.endStackWalk(settling: true) }
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
        // Let go before the cards showed: the tile stepped to comes up.
        if let q = quickWalk {
            q.show.cancel()
            quickWalk = nil
            if settling { quickStep(q.top, steps: q.steps) }
            return
        }
        content.settleStackSwitcher(cancel: !settling)
    }

    /// ⌃⇥ pressed, the cards not shown yet: the tile, the steps taken, and
    /// what shows them if control is still held.
    private var quickWalk: (top: PlacementID, steps: Int, show: DispatchWorkItem)?
    /// How long ⌃⇥ is held before the cards show — as ⌘⇥'s switcher waits
    /// before it appears (some 200 ms; Apple doesn't say).
    static let switcherDelay: TimeInterval = 0.15

    /// Held past the wait: the cards, at the step reached.
    private func showQuickWalk() {
        guard let q = quickWalk else { return }
        quickWalk = nil
        guard NSEvent.modifierFlags.contains(.control), content.stepStackSwitcher(q.top, back: q.steps < 0) else { return endStackWalk(settling: false) }
        for _ in 0..<max(0, abs(q.steps) - 1) { _ = content.stepStackSwitcher(q.top, back: q.steps < 0) }
    }

    /// A quick ⌃⇥: the tile `steps` down the stack (round it; negative,
    /// up from the farthest) brought to the top, nothing shown.
    private func quickStep(_ top: PlacementID, steps: Int) {
        guard let a = arrangement, let (c, _) = a.locate(top) else { return }
        let order = [top] + a.columns[c].filter { a.isStashed($0.id) && a.tile(behind: $0.id)?.id == top }.map(\.id)
        let k = ((steps % order.count) + order.count) % order.count
        guard k != 0 else { return }
        gridSwap(order[k])
    }

    /// Debugging: ⌃⇥ pressed with control held, then let go after `hold` seconds.
    func debugQuickWalk(steps: Int, hold: TimeInterval) -> String {
        guard let a = arrangement, let f = a.focused, let (c, _) = a.locate(f),
              a.columns[c].contains(where: { a.isStashed($0.id) && a.tile(behind: $0.id)?.id == f }) else { return "no stack" }
        let work = DispatchWorkItem { [weak self] in
            guard let self, let q = self.quickWalk else { return }
            self.quickWalk = nil
            if self.content.stepStackSwitcher(q.top, back: q.steps < 0) {
                for _ in 0..<max(0, abs(q.steps) - 1) { _ = self.content.stepStackSwitcher(q.top, back: q.steps < 0) }
            }
        }
        quickWalk = (f, steps, work)
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.switcherDelay, execute: work)
        DispatchQueue.main.asyncAfter(deadline: .now() + hold) { [weak self] in self?.endStackWalk(settling: true) }
        return "pressed"
    }

    /// One workspace to walk: ⌘` as macOS has it, the app's next window
    /// (or, backward, its previous) — Settings, another window.
    private func cycleWindows(back: Bool) {
        let windows = NSApp.orderedWindows.filter { $0.isVisible && $0.canBecomeKey && !$0.isMiniaturized }
        guard windows.count > 1, let key = NSApp.keyWindow, let i = windows.firstIndex(of: key) else { return }
        // Ordered front to back: the next is the one behind; backward, the last.
        let next = back ? windows[(i + 1) % windows.count] : windows.last!
        next.makeKeyAndOrderFront(nil)
    }

    /// Which way a space comes in: as the sidebar has them, one below the
    /// space left comes up from below (1), one above down from above (-1);
    /// by the desk's order where either row doesn't show.
    private func slideDirection(from a: BlockID, to b: BlockID) -> CGFloat {
        let org = sidebar.organizationView
        if let ra = org.spaceRow(a), let rb = org.spaceRow(b), ra.midY != rb.midY { return rb.midY > ra.midY ? 1 : -1 }
        let order = allWorkspaces
        guard let i = order.firstIndex(of: a), let j = order.firstIndex(of: b) else { return 1 }
        return j >= i ? 1 : -1
    }

    /// The arrangement about to be shown (`content`, its grid shown) slides
    /// in over the one shown — from below for `dir` 1, from above for -1 —
    /// whose grid slides out the other way, both live. Only their layers
    /// move, so nothing is laid out again on the way. With less motion
    /// asked for, the one fades in over the other.
    private func slide(_ dir: CGFloat, leaving old: GridView) {
        finishSlide()
        let frame = content.frame
        content.layer?.zPosition = 1
        old.layer?.zPosition = 0
        guard let incoming = content.layer, let leaving = old.layer else { return old.isHidden = true }
        slidingAway = old
        sliding = true
        CATransaction.begin()
        CATransaction.setCompletionBlock { [weak self] in self?.finishSlide() }
        func animate(_ layer: CALayer, _ keyPath: String, _ from: Any, _ to: Any, _ duration: TimeInterval, _ ease: CAMediaTimingFunction) {
            let a = CABasicAnimation(keyPath: keyPath)
            a.fromValue = from
            a.toValue = to
            a.duration = duration
            a.timingFunction = ease
            a.fillMode = .forwards
            a.isRemovedOnCompletion = false
            layer.add(a, forKey: "manifold.slide")
        }
        if Motion.reduced {
            animate(incoming, "opacity", 0, 1, Motion.base, Motion.appear)
        } else {
            // The stage's layers have y up: below is negative.
            let h = frame.height
            animate(incoming, "transform", CATransform3DMakeTranslation(0, -dir * h, 0), CATransform3DIdentity, Motion.spatial, Motion.travel)
            animate(leaving, "transform", CATransform3DIdentity, CATransform3DMakeTranslation(0, dir * h, 0), Motion.spatial, Motion.travel)
        }
        CATransaction.commit()
    }

    /// The grid slid away is hidden (its tiles kept, for coming back to) —
    /// unless it's the one shown again since.
    private func finishSlide() {
        guard sliding else { return }
        sliding = false
        content.layer?.removeAnimation(forKey: "manifold.slide")
        if let g = slidingAway {
            g.layer?.removeAnimation(forKey: "manifold.slide")
            if g !== content { g.isHidden = true }
        }
        slidingAway = nil
    }

    private func setUp(_ g: GridView) {
        g.delegate = self
        g.onHiding = { [weak self] view in self?.rememberPicture(of: view) }
    }

    /// A workspace's grid: its own, kept, if it has one; else one made (or
    /// taken from the workspace used longest ago, whose tiles leave the
    /// window) — `liveGrids` at most.
    private func grid(for id: BlockID?) -> GridView {
        guard let id else { return blankGrid }
        gridOrder.removeAll { $0 == id }
        gridOrder.insert(id, at: 0)
        if let g = grids[id] { return g }
        let g: GridView
        if grids.count >= Self.liveGrids,
           let oldest = gridOrder.dropFirst().last(where: { grids[$0] != nil && grids[$0] !== content && grids[$0] !== slidingAway }),
           let taken = grids.removeValue(forKey: oldest) {
            gridOrder.removeAll { $0 == oldest }
            taken.clear()
            g = taken
        } else {
            g = GridView()
            setUp(g)
            stage.addSubview(g)
        }
        g.frame = stage.bounds
        grids[id] = g
        return g
    }

    /// Workspaces gone from the desk let go of their grids.
    private func pruneGrids() {
        let live = Set(allWorkspaces)
        for (id, g) in grids where !live.contains(id) && g !== content && g !== slidingAway {
            g.clear()
            g.removeFromSuperview()
            grids.removeValue(forKey: id)
            gridOrder.removeAll { $0 == id }
        }
    }

    /// Tiles pictured for their cards, one a turn.
    private func picture(_ leaving: [PaneContent]) {
        guard let v = leaving.first else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.rememberPicture(of: v, evenHidden: true)
            self.picture(Array(leaving.dropFirst()))
        }
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

    /// Going to a tile of the workspace shown (⌘P's outline): revealed —
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
    /// too short for its content (its summary in its place, or its bar alone) —
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
        guard reveal == .glimpse ? body < GridView.summarizeBelow : body < target - 1 else { return events }
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

    /// View ▸ Inspector (⇧⌘I): the sidebar shows the focused block's
    /// properties, and following the focus; again, back to what it showed.
    @objc func toggleInspector(_ sender: Any?) {
        if organization == .inspector, sidebarShown {
            setOrganization(beforeInspector)
        } else {
            if organization != .inspector { beforeInspector = organization }
            setOrganization(.inspector)
        }
    }

    /// What the sidebar showed before the Inspector, to go back to.
    private var beforeInspector: Organization = .desk
    @objc func organizeByFiles(_ sender: Any?) { setOrganization(.files) }

    /// What the sidebar is narrowed to (§3.6), whichever organization
    /// shows: only the rows the filter admits, and the way to each.
    private(set) var sidebarFilter: SidebarFilter?

    /// ⌘.: the sidebar narrowed to blocks with a status, or not.
    @objc func toggleSidebarFilter(_ sender: Any?) { setSidebarFilter(sidebarFilter == nil ? .status : nil) }

    func setSidebarFilter(_ f: SidebarFilter?) {
        sidebarFilter = f
        sidebar.setFilter(f)
        if f != nil, !sidebarShown { showSidebar(animated: true) }
        refreshOrganization(now: true)
    }

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
        // Put away, it isn't made: it's made when it shows again.
        guard sidebarShown || pinned else { return organizationStale = true }
        organizationStale = false
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            let filter = ""
            var (nodes, open) = self.organizationTree(org, filter: filter)
            let selected = org == .desk ? self.deskSelectedRow : nil
            // Narrowed: the rows the filter admits and the way to each, all open.
            if let f = self.sidebarFilter {
                nodes = OrgNode.filtered(nodes) { n in n.style == .row && n.block.flatMap { self.hosts.block($0) }.map(f.admits) == true }
                if nodes.isEmpty { nodes = [OrgNode(id: "filter:none", title: f.nothing, symbol: "circle.dashed")] }
                open = []
            }
            // The counts: what needs you, what's working, and what's done
            // or failed and not yet read — one attended to is counted no more.
            let g = self.statusGroups("")
            let unread = (g[.done] ?? []).filter { $0.1?.read != true }.count + (g[.failed] ?? []).filter { $0.1?.read != true }.count
            self.sidebar.setCounts(needsYou: g[.needsYou]?.count ?? 0, working: g[.working]?.count ?? 0, done: unread)
            let reachable = self.hosts.reachable()
            self.sidebar.setFoot(closed: self.hosts.all.reduce(0) { $0 + self.closedItems(on: $1, reachable: reachable).count })
            // Flat, with sections, where rows are blocks by place or state;
            // a tree with chevrons where the nesting is the point (folders, links).
            self.sidebar.organizationView.flat = true
            self.sidebar.organizationView.show(nodes, openByDefault: open, selected: selected, openAll: self.sidebarFilter != nil)
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
        let n = OrgNode(id: id ?? block.id.description, block: block.id, title: Self.linkTitle(block),
                        symbol: Theme.symbolName(for: block), detail: detail ?? "", age: Self.age(seen))
        n.dirty = block.text?.isDirty == true
        n.stale = block.text?.stale == true
        n.image = block.web.flatMap { Favicons.image(forPage: $0.url) }
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
                    if words.isEmpty, let s = StatusGlyph.remark(b) { words.append(s) }
                    let n = node(for: b, id: sid + "/" + b.id.description, detail: words.joined(separator: " · "))
                    n.trailing = Age.short(r?.at ?? b.created)
                    n.emphasis = r?.wantsAttention ?? false
                    n.age = nil
                    return n
                }
                let s = OrgNode(id: sid, block: w, title: title, symbol: Theme.spaceSymbol, count: rows.count, isGroup: true, children: rows)
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
        stateModeChosen = Self.overviewMode
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

    /// The agents' view, up: Overview, filtered to the agents.
    private var stateAgents = false
    /// The view's mode as chosen while it's up (else it goes by how many).
    private var stateModeChosen: StateView.Mode?
    /// Overview's mode as last chosen, kept for the next time (and the
    /// next launch): it opens as it was left.
    private static var overviewMode: StateView.Mode? {
        get { UserDefaults.standard.object(forKey: "OverviewMode").flatMap { ($0 as? Int).flatMap(StateView.Mode.init(rawValue:)) } }
        set { UserDefaults.standard.set(newValue?.rawValue, forKey: "OverviewMode") }
    }

    /// Window ▸ Agents (⌃⌘A): Overview, filtered to every agent on every
    /// host — those that need you first — each saying what it's on, for
    /// how long, and what it has changed; clicked, gone to. Again, or ⎋,
    /// back.
    @objc func showAgents(_ sender: Any?) {
        if stateAgents { return hideStateView() }
        stateGroup = nil
        stateWorkspace = nil
        stateAgents = true
        stateMode = .overview
        stateModeChosen = Self.overviewMode
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
        // Opening on the space shown: its tiles, as they are, to be seen
        // going to their places in it.
        let fromTiles = stateView == nil && !content.isHidden ? partsInRoot(content.tileParts(), from: content) : [:]
        let fromSheets = stateView == nil && !content.isHidden ? content.sheetPlaces().mapValues { root.convert($0, from: content) } : [:]
        if stateView == nil {
            let v = StateView()
            v.onOpen = { [weak self] b, mods in
                guard let self else { return }
                self.follow(b, from: self.arrangement?.focused, Disposition(mods), context: "from Overview")
            }
            v.onLeave = { [weak self] in self?.hideStateView() }
            v.onModeChanged = { [weak self] m in
                if self?.stateWorkspace != nil || self?.stateAgents == true { Self.overviewMode = m }
                self?.stateModeChosen = m
                if m != .summaries { self?.stateMode = m }
                self?.render()
            }
            // Overview's filter: this space's blocks, or every agent's.
            v.onFilterChanged = { [weak self] i in
                guard let self else { return }
                self.stateAgents = i == 1
                self.stateWorkspace = i == 1 ? nil : self.selected
                self.stateMembers = []
                self.render()
            }
            root.addSubview(v, positioned: .above, relativeTo: stage)
            stateView = v
        }
        stateMembers = []
        content.isHidden = true
        layoutViews()
        render()
        window?.makeFirstResponder(stateView)
        if let v = stateView, !fromTiles.isEmpty || !fromSheets.isEmpty { flyIn(v, from: fromTiles, sheets: fromSheets) }
    }

    func hideStateView() {
        guard let v = stateView else { return }
        // Its cards, as they are, to be seen going back to their tiles.
        let fromCards = partsInRoot(v.cellParts(), from: v)
        v.clear()
        v.removeFromSuperview()
        stateView = nil
        stateGroup = nil
        stateWorkspace = nil
        stateAgents = false
        stateModeChosen = nil
        content.isHidden = false
        render()
        if !fromCards.isEmpty { flyOut(from: fromCards) }
    }

    // MARK: Overview, as Mission Control does

    /// Only fading in (with Reduce motion).
    private func fadeIn(_ v: NSView) {
        guard let l = v.layer else { return }
        let a = CABasicAnimation(keyPath: "opacity")
        a.fromValue = 0
        a.toValue = 1
        a.duration = Motion.base
        l.add(a, forKey: "fadeIn")
    }

    private func partsInRoot<K>(_ parts: [K: GridView.Pictured], from view: NSView) -> [K: GridView.Pictured] {
        parts.mapValues { p in GridView.Pictured(parts: p.parts.map { (root.convert($0.0, from: view), $0.1) }, ground: p.ground) }
    }

    /// Overview opening, as Mission Control does: each tile in the space
    /// becomes its card where the card is — its outline going there, what
    /// it shows scaled to its width, the card coming in on the way — and
    /// each tile in a stack is pulled out of its sheet into its card; the
    /// rest of Overview fades in.
    private func flyIn(_ v: StateView, from tiles: [BlockID: GridView.Pictured], sheets: [BlockID: NSRect]) {
        guard !Motion.reduced, let host = root.layer else { return fadeIn(v) }
        var items: [GridView.Morph] = []
        var flown: [BlockID] = []
        for (block, card) in partsInRoot(v.cellParts(), from: v) {
            if let tile = tiles[block] {
                items.append(GridView.Morph(from: tile.whole, to: card.whole, leaving: tile, coming: card))
            } else if let sheet = sheets[block] {
                items.append(GridView.Morph(from: sheet, to: card.whole, coming: card))
            } else { continue }
            flown.append(block)
        }
        guard !items.isEmpty else { return fadeIn(v) }
        let d = Motion.spatial * 1.5
        GridView.morph(items, in: host, over: d)
        fade(v, over: d)
        for block in flown {
            for part in v.cellViews(of: block) { show(part, from: 1, over: d) }
        }
    }

    /// Overview closing: each card becomes its tile again, where the tile
    /// is (as the space has it now), or goes back into its sheet; the rest
    /// of the space fades in.
    private func flyOut(from cards: [BlockID: GridView.Pictured]) {
        guard !content.isHidden else { return }
        guard !Motion.reduced, let host = root.layer else { return fadeIn(content) }
        content.layoutSubtreeIfNeeded()
        let tiles = partsInRoot(content.tileParts(), from: content)
        let sheets = content.sheetPlaces().mapValues { root.convert($0, from: content) }
        var items: [GridView.Morph] = []
        var flown: [BlockID] = []
        for (block, card) in cards {
            if let tile = tiles[block] {
                items.append(GridView.Morph(from: card.whole, to: tile.whole, leaving: card, coming: tile))
                flown.append(block)
            } else if let sheet = sheets[block] {
                items.append(GridView.Morph(from: card.whole, to: sheet, leaving: card))
            }
        }
        guard !items.isEmpty else { return fadeIn(content) }
        let d = Motion.spatial * 1.5
        GridView.morph(items, in: host, over: d)
        fade(content, over: d)
        for block in flown {
            for part in content.tileViews(of: block) { show(part, from: 1, over: d) }
        }
    }

    /// A view faded in over a flight.
    private func fade(_ v: NSView, over d: Double) {
        guard let l = v.layer else { return }
        let a = CABasicAnimation(keyPath: "opacity")
        a.fromValue = 0
        a.toValue = 1
        a.duration = d
        a.timingFunction = Motion.appear
        l.add(a, forKey: "fadeIn")
    }

    /// A view out of sight till `from` of the way through a flight, then
    /// fading in by its end (at once, at its end).
    private func show(_ v: NSView, from: Double, over d: Double) {
        guard let l = v.layer else { return }
        let a = CAKeyframeAnimation(keyPath: "opacity")
        a.values = from >= 1 ? [0, 0] : [0, 0, 1]
        a.keyTimes = from >= 1 ? [0, 1] : [0, NSNumber(value: from), 1]
        a.duration = d
        l.add(a, forKey: "landing")
    }

    /// The blocks the state view shows, in order, while it's up.
    private var stateMembers: [BlockID] = []
    /// When each diff was last compared at a view's asking.
    private var diffReloaded: [BlockID: Date] = [:]

    func debugStateView(mode: StateView.Mode) {
        guard let stateView else { return }
        stateView.debugChoose(mode)
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
        case .closed: return closedTree(filter)
        case .inspector: return inspectorTree()
        }
    }

    /// What Search reads of each block, by block: kept while the block's
    /// content is as it was.
    private var searchTexts: [BlockID: SearchText] = [:]

    /// A block's text as Search reads it — a text's, a notebook's cells,
    /// an output's, escapes taken out — made again only when it changed.
    private func searchText(for b: Block) -> SearchText? {
        let key: String
        if let t = b.text { key = "t\(t.version)" }
        else if let nb = b.notebook { key = "n\(nb.runs)/\(nb.cells.count)/\(nb.cells.reduce(0) { $0 + $1.source.utf8.count + ($1.output?.utf8.count ?? 0) })" }
        else if let o = b.output { key = "o\(o.output.utf8.count)/\(o.ended != nil)" }
        else { return nil }
        if let st = searchTexts[b.id], st.key == key { return st }
        func plain(_ s: String) -> String {
            s.replacingOccurrences(of: "\u{1b}\\][^\u{07}\u{1b}]*(\u{07}|\u{1b}\\\\)", with: "", options: .regularExpression)
                .replacingOccurrences(of: "\u{1b}\\[[0-9;?]*[ -/]*[@-~]", with: "", options: .regularExpression)
        }
        let text: String
        if let t = b.text { text = t.text.string }
        else if let nb = b.notebook { text = plain(nb.cells.map { "$ " + $0.source + "\n" + ($0.output ?? "") }.joined(separator: "\n")) }
        else if let o = b.output { text = o.plain ? o.output : plain(o.output) }
        else { return nil }
        let st = SearchText(key: key, text: text)
        if searchTexts.count > 4 * max(hosts.blocks.count, 64) { searchTexts = searchTexts.filter { hosts.block($0.key) != nil } }
        searchTexts[b.id] = st
        return st
    }

    /// A text block gone to, at a line: its editor here focused there, or
    /// one brought here.
    func goToLine(_ line: Int, in block: BlockID) {
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

    /// What's closed and not yet collected on a host (§4): what exists
    /// and nothing reaches — the last seen first.
    private func closedItems(on c: HostClient, reachable: Set<BlockID>) -> [Block] {
        let far = Stamp(wall: 0, logical: 0, host: c.host)
        return c.node.blocks.filter { !reachable.contains($0.id) && $0.id.host == c.host }
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

    /// Recently Closed (§4), the list: what exists and nothing reaches,
    /// dimmed, each brought back by a click, until collected.
    // MARK: The Inspector (§3.5)

    /// The focused block's properties (⇧⌘I), Star's property sheet for any
    /// block: what it is, and what only its kind has; where it's placed and
    /// pinned (a click goes there); what keeps it (§4); its links, either
    /// way (a click opens one by the one rule); its history; and what can be
    /// done with it. Each a row, by sections; a value first, what it is in
    /// grey after it.
    private func inspectorTree() -> ([OrgNode], Set<String>) {
        guard let f = focusedShown, let b = f.block else {
            sidebar.setInspected(title: "Nothing to inspect", subtitle: "")
            return ([OrgNode(id: "insp:none", title: "Focus a tile to see what it is", symbol: "info.circle")], [])
        }
        let hostName = hosts.label(of: b.id.host)
        sidebar.setInspected(title: Self.linkTitle(b), subtitle: "\(b.kind.defaultTitle == "Untitled" ? "Note" : b.kind.defaultTitle) on \(hostName)" + (f.offline ? ", out of reach" : ""))
        var sections: [OrgNode] = []
        func row(_ value: String, _ label: String, _ symbol: String, _ action: (() -> Void)? = nil) -> OrgNode {
            let n = OrgNode(id: "insp/\(sections.count)/\(label)/\(value)", title: value, symbol: symbol, detail: label)
            n.tooltip = "\(label): \(value)"
            n.action = action
            return n
        }
        func section(_ title: String, _ symbol: String, _ rows: [OrgNode]) {
            guard !rows.isEmpty else { return }
            let s = OrgNode(id: "insp:\(title)", title: title, symbol: symbol, isGroup: true, children: rows)
            s.style = .section
            sections.append(s)
        }
        func copying(_ text: String) -> () -> Void {
            { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(text, forType: .string) }
        }
        let graph = hosts.client(of: b.id)?.node.graph

        // What it is.
        var about: [OrgNode] = [row(hostName, "host", "desktopcomputer")]
        if let p = b.path { about.append(row(p.abbreviatingHome, "path — click to copy", "doc", copying(p))) }
        if let u = b.web?.url { about.append(row(u, "address — click to copy", "globe", copying(u))) }
        if let d = b.terminal?.cwd { about.append(row(d.abbreviatingHome, "directory — click to copy", "folder", copying(d))) }
        about.append(row(Age.ago(b.created), "made", "calendar"))
        if let seen = graph?.seen(b.id) { about.append(row(Age.ago(seen), "last seen", "eye")) }
        if let t = StatusGlyph.tooltip(b), !t.isEmpty { about.append(row(t, "status", "circle.dotted")) }
        section("About", "info.circle", about)

        // What only its kind has.
        var own: [OrgNode] = []
        switch b.kind {
        case .text:
            if let t = b.text {
                let s = t.text.string
                own.append(row("\(s.split(separator: "\n", omittingEmptySubsequences: false).count)", "lines", "text.alignleft"))
                own.append(row("\(s.split { $0.isWhitespace || $0.isNewline }.count)", "words", "textformat"))
                own.append(row("\(s.count)", "characters", "character"))
                if t.isDirty { own.append(row("Unsaved", "edits", "pencil")) }
                if t.stale { own.append(row("Changed on disk", "file", "exclamationmark.triangle")) }
                own.append(row(t.encoding, "encoding", "doc.text"))
                own.append(row(t.lineEnding == "\r\n" ? "CRLF" : "LF", "line endings", "return"))
            }
        case .terminal, .agent:
            if let t = b.terminal {
                if let pid = t.pid { own.append(row("\(pid)", "shell's process", "number")) }
                if let c = t.commands?.last(where: { $0.isRunning }) { own.append(row(c.text, "running", "play")) }
                own.append(row("\(t.commands?.count ?? 0)", "commands run", "list.bullet"))
                if let turns = t.turns, !turns.isEmpty { own.append(row("\(turns.count)", "turns", "bubble.left.and.bubble.right")) }
                if let d = t.dormantSince { own.append(row(Age.ago(d), "dormant since", "moon")) }
            }
        case .search:
            if let s = b.search {
                if let q = s.query { own.append(row(q.text, "query", "magnifyingglass")); own.append(row(q.root.abbreviatingHome, "under", "folder")) }
                own.append(row("\(s.hits.count)" + (s.truncated ? "+" : ""), "hits", "text.magnifyingglass"))
                own.append(row("\(Set(s.hits.map(\.path)).count)", "files", "doc.on.doc"))
                if s.running { own.append(row("Searching", "now", "hourglass")) }
            }
        case .directory:
            own.append(row("\(b.directory?.entries.count ?? 0)", "entries", "list.bullet"))
        case .notebook:
            if let n = b.notebook {
                own.append(row("\(n.cells.count)", "cells", "square.stack"))
                if let sh = n.shell { own.append(row(sh, "shell", "terminal")) }
                own.append(row("\(n.runs)", "runs", "play"))
            }
        case .output:
            if let o = b.output {
                own.append(row(o.line, "command", "terminal"))
                if let st = o.status { own.append(row(st == 0 ? "OK" : "Exit \(st)", "ended", st == 0 ? "checkmark" : "xmark")) }
                if let src = o.source, let s = hosts.block(src) {
                    let n = row(Self.linkTitle(s), "ran in", Theme.symbolName(for: s))
                    n.block = src
                    own.append(n)
                }
            }
        case .git:
            if let g = b.git {
                if let br = g.branch { own.append(row(br, "branch", "arrow.triangle.branch")) }
                own.append(row("\(g.status.count)", "changes", "plusminus"))
                if g.ahead > 0 || g.behind > 0 { own.append(row("\(g.ahead) ahead, \(g.behind) behind", "upstream", "arrow.up.arrow.down")) }
            }
        case .diff:
            if let p = b.diff?.patch { own.append(row("\(p.components(separatedBy: "\ndiff --git").count)", "files", "doc.on.doc")) }
        case .process:
            own.append(row("\(b.processes?.entries.count ?? 0)", "processes", "cpu"))
        case .arrangement:
            own.append(row("\(b.arrangement?.placements.count ?? 0)", "tiles", "rectangle.split.3x1"))
        default:
            break
        }
        section(b.kind == .text ? "Text" : b.kind.defaultTitle, Theme.symbolName(for: b), own)

        // Where it is: each space it's placed in, and pinned in.
        var whereRows: [OrgNode] = []
        var placedIn = 0, pinnedIn = 0
        for w in allWorkspaces {
            guard let a = hosts.arrangement(w) else { continue }
            for p in a.placements where p.block == b.id {
                placedIn += 1
                let how = a.isStashed(p.id) ? "in a stack" : a.full == p.id ? "maximized" : w == selected && a.focused == p.id ? "this tile" : "a tile"
                let n = row(title(of: a), how, Theme.spaceSymbol)
                n.arrangement = w
                n.placement = p.id
                whereRows.append(n)
            }
            if isPinned(b.id, in: w) {
                pinnedIn += 1
                let n = row(title(of: a), "pinned", "pin")
                n.arrangement = w
                whereRows.append(n)
            }
        }
        section("Where", "map", whereRows)

        // What keeps it (§4): a space that places or pins it, a link by
        // hand to it; else it's let go of, and collected in a while.
        var strongIn = 0
        for c in hosts.all {
            for kind in [LinkKind.linked, .embeds] { strongIn += c.node.graph.edges(to: b.id, kind: .link(kind)).filter(\.isLive).count }
        }
        var kept: [String] = []
        if placedIn > 0 { kept.append("placed in \(placedIn) space\(placedIn == 1 ? "" : "s")") }
        if pinnedIn > 0 || b.isPinned { kept.append("pinned") }
        if strongIn > 0 { kept.append("linked to by \(strongIn)") }
        let reached = hosts.reachable().contains(b.id)
        section("Kept", "lock", [kept.isEmpty
            ? row(reached ? "By what reaches it" : "Not kept: collected in a while", "", reached ? "lock" : "clock.arrow.circlepath")
            : row(kept.joined(separator: ", ").capitalizingFirst, "", "lock")])

        // Its links, either way, the latest first.
        var edges: [(Edge, out: Bool)] = []
        for c in hosts.all {
            edges += c.node.graph.edges(from: b.id).filter { $0.isLive }.map { ($0, true) }
            edges += c.node.graph.edges(to: b.id).filter { $0.isLive }.map { ($0, false) }
        }
        var seenLinks = Set<String>()
        let linkRows: [OrgNode] = edges.filter { e, _ in
            if case .link(let k) = e.kind { return k != .pinned }
            return false
        }.sorted { $0.0.at > $1.0.at }.compactMap { e, out in
            let other = out ? e.to : e.from
            guard seenLinks.insert("\(other)\(out)\(e.kind)").inserted, let o = hosts.block(other) else { return nil }
            let how: String
            switch e.kind {
            case .link(.linked): how = out ? "links to" : "linked from"
            case .link(.embeds): how = out ? "shows" : "shown in"
            default: how = out ? "opened" : "opened from"
            }
            let n = node(for: o, id: "insp/link/\(e.id)/\(out)", detail: how)
            if let c = e.context, !c.isEmpty { n.tooltip = "\(how): \(c)" }
            return n
        }
        section("Links", "link", Array(linkRows.prefix(30)))

        // Its history: the trail's visits.
        let visits = hosts.all.flatMap { $0.node.graph.visits(b.id) }.sorted { $0.at > $1.at }
        var history: [OrgNode] = [row("\(visits.count)", "times gone to", "arrow.uturn.right")]
        if let last = visits.first { history.append(row(Age.ago(last.at), "last gone to", "clock")) }
        section("History", "clock", history)

        // What can be done with it: Copy Contents, and what its menu offers.
        var actions: [OrgNode] = []
        let copy = row("Copy Contents", "⇧⌘C", "doc.on.doc") { [weak self] in self?.copyContents(nil) }
        actions.append(copy)
        for item in copyItems(for: b.id) {
            guard let c = item as? ClosureMenuItem else { continue }
            let n = row(item.title, "", "circle")
            n.image = item.image
            n.action = { c.perform() }
            actions.append(n)
        }
        actions.append(row("Show the Neighborhood Map", "⌥⌘M", "point.3.connected.trianglepath.dotted") { [weak self] in self?.showNeighborhood(around: b.id) })
        if let w = selected, b.kind != .arrangement {
            let pinnedHere = isPinned(b.id, in: w)
            actions.append(row(pinnedHere ? "Unpin from This Space" : "Pin in This Space", "⌃⌘T", "pin") { [weak self] in self?.setPinned(b.id, in: w, !pinnedHere) })
        }
        section("Actions", "bolt", actions)
        return (sections, Set(sections.map(\.id)))
    }

    private func closedTree(_ filter: String) -> ([OrgNode], Set<String>) {
        let reachable = hosts.reachable()
        return hostedRows({ c in
            closedItems(on: c, reachable: reachable).filter { matches(filter, [$0.kind == .arrangement ? title(of: $0.arrangement!) : $0.displayTitle, $0.path]) }.prefix(100).map { b -> OrgNode in
                let n = b.kind == .arrangement
                    ? OrgNode(id: "closed/\(b.id)", block: b.id, title: title(of: b.arrangement!), symbol: Theme.spaceSymbol, count: b.arrangement!.placements.count)
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
    /// A workspace's rows as they're listed: each run of a tile and those
    /// behind it in its column (in a run, as listed) sharing a ground.
    private static func markStacks(_ rows: [OrgNode]) {
        var i = 0
        while i < rows.count {
            var j = i + 1
            while j < rows.count, rows[j].behind, rows[j].column == rows[i].column, rows[j].style == .row { j += 1 }
            if j - i > 1 || rows[i].behind {
                for k in i..<j { rows[k].stack = SelectionRowView.Grouped(first: k == i, last: k == j - 1) }
            }
            i = j
        }
    }

    private func deskTree(_ filter: String) -> ([OrgNode], Set<String>) {
        var open: Set<String> = []
        func workspace(_ id: BlockID) -> OrgNode? {
            guard let a = hosts.arrangement(id) else { return nil }
            let aid = "arr/\(id)"
            // Every workspace whole (§3.6): nothing folds by itself; one
            // closed by its chevron stays closed.
            var tiles: [OrgNode] = []
            let pinned = pins(of: id).map(\.to)
            for (c, column) in a.columns.enumerated() {
                // A stack's tiles under its top, nearest first, as it fans
                // (any stashed before the column's first shown tile are its).
                let lead = column.prefix { a.isStashed($0.id) }
                var ordered = Array(column.dropFirst(lead.count))
                if !ordered.isEmpty { ordered.insert(contentsOf: lead, at: 1) } else { ordered = Array(lead) }
                for p in ordered {
                    let b = hosts.block(p.block)
                    // An untitled note by its first words, as its links name it.
                    let title = b.map(Self.linkTitle) ?? "On \(hosts.label(of: p.block.host))"
                    guard matches(filter, [title, b?.path]) else { continue }
                    // What its status says beyond its glyph (not "Done"); else
                    // its state — stashed, maximized — as a small symbol. Edits
                    // unsaved: the bar's dot after its name.
                    var notes: [String] = []
                    if let status = StatusGlyph.remark(b) { notes.append(status) }
                    if b == nil { notes.append("not attached") }
                    let n = OrgNode(id: "\(aid)/tile/\(p.id)", block: p.block, title: title,
                                    symbol: b.map { Theme.symbolName(for: $0) } ?? "questionmark.square.dashed",
                                    detail: notes.joined(separator: " · "))
                    n.dirty = b?.text?.isDirty == true
                    n.stale = b?.text?.stale == true
                    n.image = b?.web.flatMap { Favicons.image(forPage: $0.url) }
                    if a.isStashed(p.id) { n.behind = true } else if a.full == p.id { n.detailSymbol = "arrow.up.left.and.arrow.down.right" }
                    n.look = StatusGlyph.look(of: b); n.tooltip = StatusGlyph.tooltip(b)
                    n.trailing = StatusGlyph.at(of: b).map(Age.short)
                    n.arrangement = id
                    n.column = c
                    n.placement = p.id
                    n.emphasis = id == selected && p.id == a.focused
                    tiles.append(n)
                }
            }
            // Its pinned blocks first, in the order pinned — each its tiles,
            // or, closed, a row to recall it here — then a hairline, then
            // the rest.
            if !pinned.isEmpty {
                // A pinned tile in a stack is in both places: at the top, and
                // in its stack — the two rows lighting together on hover.
                let stacked = Set(a.placements.filter { p in
                    a.isStashed(p.id) || a.columns.contains { col in col.contains { a.isStashed($0.id) && a.tile(behind: $0.id)?.id == p.id } }
                }.map(\.id))
                var top: [OrgNode] = []
                var twinned: Set<PlacementID> = []
                for block in pinned {
                    let open = tiles.filter { $0.block == block }
                    for t in open {
                        guard let p = t.placement, stacked.contains(p) else { top.append(t); continue }
                        let copy = OrgNode(id: "\(aid)/pinned/\(p)", title: t.title, symbol: t.symbol)
                        copy.take(t)
                        copy.behind = false
                        copy.twin = p
                        t.twin = p
                        twinned.insert(p)
                        top.append(copy)
                    }
                    if !open.isEmpty { continue }
                    guard let b = hosts.block(block) else { continue }
                    let title = Self.linkTitle(b)
                    guard matches(filter, [title, b.path]) else { continue }
                    let n = node(for: b, id: "\(aid)/pin/\(block)", detail: StatusGlyph.remark(b) ?? "")
                    n.arrangement = id
                    n.dimmed = true
                    n.age = nil
                    n.action = { [weak self] in self?.recallPinned(block, in: id) }
                    top.append(n)
                }
                let rest = tiles.filter { t in !pinned.contains { $0 == t.block } || t.placement.map(twinned.contains) == true }
                if !top.isEmpty {
                    let rule = OrgNode(id: "\(aid)/pins", title: "", symbol: "", detail: "")
                    rule.style = .divider
                    tiles = top + (rest.isEmpty ? [] : [rule]) + rest
                }
            }
            Self.markStacks(tiles)
            let titleMatches = matches(filter, [title(of: a)])
            guard filter.isEmpty || titleMatches || !tiles.isEmpty else { return nil }
            let focused = a.focusedPlacement.flatMap { hosts.block($0.block) }
            let n = OrgNode(id: aid, block: id, title: title(of: a),
                            symbol: a.placements.count > 1 ? Theme.spaceSymbol : focused.map { Theme.symbolName(for: $0) } ?? Theme.spaceSymbol,
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
            // Unnamed spaces called the same (their folder): told apart by
            // what each is on, after the name.
            let counts = Dictionary(grouping: nodes, by: \.title).filter { $0.value.count > 1 }
            for n in nodes where counts[n.title] != nil {
                guard let id = n.block, let a = hosts.arrangement(id), !a.isNamed,
                      let on = (a.focusedPlacement ?? a.placements.first).flatMap({ hosts.block($0.block) }) else { continue }
                n.title += " · " + Self.linkTitle(on)
            }
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
            if f.isPlace, let block {
                // At the folder, not a file in it: by its own title (a
                // terminal whose title is only its folder says "Terminal").
                let shown = block.displayTitle
                let title = block.terminal != nil && (shown.hasPrefix("~") || shown.hasPrefix("/")) ? block.kind.defaultTitle : shown
                if !filter.isEmpty, !matches(filter, [title, f.path]) { return nil }
                let node = OrgNode(id: "place:\(block.id)", block: f.block, title: title, symbol: Theme.symbolName(for: block),
                                   detail: "", age: Self.age(f.latest))
                node.dirty = block.text?.isDirty == true
                node.stale = block.text?.stale == true
                node.look = StatusGlyph.look(of: block)
                node.trailing = StatusGlyph.at(of: block).map(Age.short)
                node.dimmed = !isActive
                active[ObjectIdentifier(node)] = isActive
                return node
            }
            let node = OrgNode(id: id, block: f.block, title: f.name, symbol: block.map { Theme.symbolName(for: $0) } ?? "doc",
                               detail: "", age: Self.age(f.latest))
            node.dirty = block?.text?.isDirty == true
            node.stale = block?.text?.stale == true
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
        // Its ping times lately, by its name (a remote host's).
        if c.isRemote { n.pings = { [weak c] in c?.pings ?? [] } }
        switch c.link {
        case .connected:
            // Another Manifold leads it: an eye (the word would crowd out
            // its ping times), and who in its tooltip and card, Take Over in
            // its menu. (Quiet as well, the broken ring says that first.)
            if c.watching {
                n.look = .watching
                n.tooltip = "\(c.fencedBy ?? "Another Manifold") took over this host: what you do here doesn't take. Take Over is in its menu."
            }
            // Up, but quiet a while: a broken ring, and on hover, how long.
            guard c.silence != nil else { break }
            n.look = .quiet
            n.liveTooltip = { [weak c] in c?.silenceDescription ?? "Heard from again." }
        case .connecting:
            n.look = .connecting
            n.detail = "connecting…"
            // The step under way and how long so far, as of the hover; and
            // when it was last heard from, if it was connected before.
            n.liveTooltip = { [weak c] in
                [c?.stepDescription ?? "Connecting…", c?.silenceDescription].compactMap { $0 }.joined(separator: "\n")
            }
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
            self?.goTo(id)
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
            case .arrangement: "Space"
            case .terminal: b.terminal?.cwd?.abbreviatingHome ?? "Terminal"
            default: b.path?.deletingLastPathComponent.abbreviatingHome ?? b.kind.defaultTitle
            }
            return GraphNode(id: id, title: b.displayTitle, symbol: Theme.symbolName(for: b), detail: detail,
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
        if walk == nil, tileWalk == nil { settleHere() }
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
        Drags.copyLink = { [weak self] block, fragment in self?.copyLink(to: block, fragment: fragment) }
        Drags.path = { [weak self] path, isDir, host, mods in self?.entryDragItem(path, isDirectory: isDir, on: host, modifiers: mods) ?? NSPasteboardItem() }
        Drags.place = { [weak self] id, fragment, title, mods in
            guard let self else { return nil }
            if let item = self.pathDragItem(for: id, linkOnly: mods.contains(.option), place: fragment.map { ($0, title) }) { return item }
            // A block the host is making now (a turn's, asked for as the
            // drag began): its link, by the item's name, to land as it comes.
            let item = NSPasteboardItem()
            let t = title.replacingOccurrences(of: "]", with: "\\]")
            item.setString("[\(t)](manifold:\(id.description))", forType: .manifoldBlockLink)
            if mods.contains(.option) { item.setString("1", forType: .manifoldLinkOnly) }
            return item
        }
        Drags.block = { [weak self] id, mods in
            guard let self else { return nil }
            if mods.contains(.shift) { return self.pathDragItem(for: id, linkOnly: mods.contains(.option)) }
            // Plain: the block, to bring where it's dropped (nothing a text
            // view would take for text to put in).
            let item = NSPasteboardItem()
            item.setString(id.description, forType: .manifoldBlock)
            return item
        }
        // ⌃- and ⌃⇧- go back and forward, ⌃⇥ and ⌃⇧⇥ walk the focused
        // tile's stack, ⌘` and ⇧⌘` the workspaces, here, before anything
        // else sees them — whatever has the keyboard, or nothing (a
        // workspace's row clicked, its tile not taking it, where AppKit's
        // own going round the views took ⌃⇥ before the menu).
        navKeysMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, event.window === self.window, [27, 48, 50].contains(event.keyCode) else { return event }
            let mods = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            if event.keyCode == 50 {
                guard mods == .command || mods == [.command, .shift] else { return event }
                if mods.contains(.shift) { self.walkTabsBack(nil) } else { self.walkTabs(nil) }
                return nil
            }
            // ⌥⇥, the trail's tiles (taken from a terminal, as ⌃⇥ is).
            if event.keyCode == 48, mods == .option || mods == [.option, .shift] {
                if mods.contains(.shift) { self.walkTilesBack(nil) } else { self.walkTiles(nil) }
                return nil
            }
            guard mods == .control || mods == [.control, .shift] else { return event }
            // ⌃- in a terminal is the terminal's (undo, to a shell or Emacs).
            if event.keyCode == 27, self.window?.firstResponder is TerminalView { return event }
            if event.keyCode == 48 {
                if mods.contains(.shift) { self.walkStackBack(nil) } else { self.walkStack(nil) }
            } else if mods.contains(.shift) {
                self.navigateForward(nil)
            } else {
                self.navigateBack(nil)
            }
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
            let (c, _) = finderCorpus()
            return String(format: "snapshot of %d in %.1f ms", c.count, Date().timeIntervalSince(start) * 1000)
        }
        if query.hasPrefix("blocks ") {
            let q = String(query.dropFirst(7)), start = Date()
            let n = finderBlockItems(q).count
            return String(format: "%d rows in %.1f ms", n, Date().timeIntervalSince(start) * 1000)
        }
        return finder.debugTime(query)
    }
    func debugFinderChoose() { finder.debugChoose() }
    func debugSearchOutline(_ query: String) -> String {
        guard let f = arrangement?.focused, views[f]?.outline != nil else { return "no outline" }
        if !finder.isShowing { searchOutline(of: f) }
        return finder.debugQuery(query).joined(separator: "\n")
    }
    /// ⌘P's list: opened afresh with no query (shown once a preview
    /// focused says where it's at, a moment later); else, the list as it's
    /// filtered by one.
    /// "wsoutline [query]": ⌘P typed in; "wsoutline tab": its other scope;
    /// "wsoutline time <query>": how long the query took, and how many rows.
    func debugWorkspaceOutline(_ query: String) -> String {
        if query.isEmpty { goToTile(nil); return "opened" }
        if query == "tab" { finder.debugSwitchOutline(); return "switched" }
        if query == "selected" { return finder.debugSelected }
        if query.hasPrefix("find "), let a = arrangement, let index = syncOutlineIndex() {
            // The index's part alone: looked up, and the rows made.
            let q = String(query.dropFirst(5))
            let order = a.columns.joined().map(\.id)
            let t0 = DispatchTime.now().uptimeNanoseconds
            let hits = index.find(q, in: order).reduce(0) { $0 + $1.items.count }
            let t1 = DispatchTime.now().uptimeNanoseconds
            let rows = spaceOutlineRows(a, query: q).count
            let t2 = DispatchTime.now().uptimeNanoseconds
            return String(format: "index %.2f ms (%d), rows %.2f ms (%d), %d rows indexed", Double(t1 - t0) / 1e6, hits, Double(t2 - t1) / 1e6, rows, index.count)
        }
        if query.hasPrefix("time ") {
            let q = String(query.dropFirst(5))
            let t0 = DispatchTime.now().uptimeNanoseconds
            let rows = finder.debugQueryCount(q)
            let ms = Double(DispatchTime.now().uptimeNanoseconds - t0) / 1e6
            return String(format: "%.2f ms, %d rows", ms, rows)
        }
        return finder.debugQuery(query).joined(separator: "\n")
    }
    func debugFinderScope(_ n: Int) { finder.debugScope(n) }
    func debugFinderKinds(_ arg: String) -> String {
        switch arg {
        case "tab": finder.debugTab()
        case "back": finder.debugBackspace()
        case let a where a.hasPrefix("click "): finder.debugClickCount(String(a.dropFirst(6)))
        default: break
        }
        return finder.debugKinds()
    }
    func debugFinderMove(_ by: Int) { finder.debugMove(by) }

    private lazy var finder: Finder = {
        let f = Finder()
        // The chosen row's block: its card beside the list, at once.
        f.summarize = { [weak self] id in self?.cardContent(for: id) }
        f.search = { [weak self] query, scope in
            guard let self else { return [] }
            switch scope {
            case .names: return []
            case .blocks: return self.finderBlockItems(query)
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
        f.openFile = { [weak self] path in self?.open(path, from: nil) }
        return f
    }()

    /// The project the focused block is in: its repository's root (git
    /// or Sapling), else its own folder.
    func projectRoot(from cwd: String?, on: HostID) -> String {
        let root = cwd ?? NSHomeDirectory()
        guard on == host.host else { return root }
        return VCS.repository(of: root)?.root ?? root
    }

    /// The lines that hold a query, as one excerpt: trimmed, run together.
    static func excerpt(_ lines: [String]) -> String {
        lines.prefix(6).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }.joined(separator: "  ·  ")
    }

    /// A place in a block's outline (§7.5) as Find in Blocks finds it,
    /// read from the block itself, so every terminal and note is found,
    /// shown or not: a command a terminal ran, a Markdown heading.
    private struct OutlinePlace {
        var title: String
        var lower: String
        /// Where in the block: "command=7", "line=12".
        var fragment: String
        var detail: String
        var note: String
        var at: Stamp?
    }
    /// Each block's places, kept while it's as it was.
    private var outlinePlaces: [BlockID: (key: String, places: [OutlinePlace])] = [:]

    /// A block's outline, as its tile's would be, without its tile: a
    /// terminal's commands (an agent's outline is its turns, found as
    /// turns), a note's or Markdown file's headings. Nil for a block whose
    /// outline only its tile knows (a source file's symbols, a PDF's
    /// contents, a page's headings).
    private func outlinePlaces(of b: Block) -> [OutlinePlace]? {
        let key: String
        switch b.kind {
        case .terminal:
            guard let t = b.terminal, b.agent == nil || (t.turns ?? []).isEmpty else { return nil }
            key = "c\(t.commands?.count ?? 0)/\(t.commands?.last?.ended != nil)"
        case .text:
            guard let t = b.text, b.path.map(Lens.isMarkdown) ?? true else { return nil }
            key = "t\(t.version)"
        default:
            return nil
        }
        if let known = outlinePlaces[b.id], known.key == key { return known.places }
        var places: [OutlinePlace] = []
        if let t = b.terminal {
            // The latest first; a command run again, once (its latest).
            var seen = Set<String>()
            for c in (t.commands ?? []).reversed() {
                let text = c.text.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !text.isEmpty, seen.insert(text).inserted else { continue }
                let ran = (c.cwd ?? t.cwd)?.abbreviatingHome ?? "~"
                let how = c.ended == nil ? "" : c.status.map { $0 == 0 ? "" : "exit \($0)" } ?? ""
                places.append(OutlinePlace(title: text, lower: text.lowercased(), fragment: "command=\(c.id)",
                                           detail: "\(b.displayTitle) · \(ran)", note: how, at: c.at))
            }
        } else if let t = b.text {
            let place = b.path.map { $0.deletingLastPathComponent.abbreviatingHome } ?? "Note"
            for h in MarkdownOutline.headings(in: t.text.string) {
                places.append(OutlinePlace(title: h.text, lower: h.text.lowercased(), fragment: "line=\(h.line + 1)",
                                           detail: "\(b.displayTitle) · \(place)", note: "heading", at: nil))
            }
        }
        if outlinePlaces.count > 4 * max(hosts.blocks.count, 64) { outlinePlaces = outlinePlaces.filter { hosts.block($0.key) != nil } }
        outlinePlaces[b.id] = (key, places)
        return places
    }

    /// Find in Blocks' outline rows: every place in an outline whose title
    /// holds the query — this space's blocks first, then the rest; then
    /// the outlines only a tile knows, the desk's — each going to the
    /// place itself, as its tile's outline would.
    private func finderOutlineItems(_ q: String) -> [FinderItem] {
        var items: [FinderItem] = []
        var seen = Set<BlockID>()
        let here = arrangement?.placements.map(\.block) ?? []
        for id in here + hosts.blocks.map(\.id) where seen.insert(id).inserted {
            guard let b = hosts.block(id), let places = outlinePlaces(of: b) else { continue }
            let symbol = Theme.symbolName(for: b), kinds = FindKinds.of(b.kind, path: b.path, agent: b.agent != nil)
            for p in places where p.lower.contains(q) {
                let link = "manifold:\(id.description)#\(p.fragment)", fragment = p.fragment, title = p.title
                items.append(FinderItem(symbol: symbol, title: p.title, detail: p.detail, note: p.note,
                                        age: p.at.map { Age.short($0) }.flatMap { $0 == "now" ? nil : $0 },
                                        run: { [weak self] in self?.open(link, from: self?.arrangement?.focused) },
                                        drag: { Drags.place?(id, fragment, title, Drags.modifiers) }, kinds: kinds))
                if items.count >= 100 { return items }
            }
        }
        // A tile's own outline, for what only it knows: gone to through a
        // link where an item has a place (a symbol's line, a PDF's page),
        // else picked in its tile, this space's.
        let shown = (arrangement?.placements.map(\.id) ?? []) + views.keys.sorted { $0.description < $1.description }
        var tiles = Set<PlacementID>(), outlined = Set<BlockID>()
        for pid in shown where tiles.insert(pid).inserted {
            guard let view = views[pid], !(view is TerminalView), let o = view.outline, !o.items.isEmpty,
                  let b = hosts.block(view.block), outlinePlaces(of: b) == nil, outlined.insert(b.id).inserted else { continue }
            let symbol = Theme.symbolName(for: b), kinds = FindKinds.of(b.kind, path: b.path, agent: b.agent != nil)
            let inThisSpace = arrangement?.placement(pid) != nil
            for (i, item) in o.items.enumerated() where item.title.lowercased().contains(q) {
                let fragment = o.placeFor?(i)
                guard fragment != nil || inThisSpace else { continue }
                let id = b.id, title = item.title
                items.append(FinderItem(symbol: symbol, title: item.title, detail: b.displayTitle + (item.detail.isEmpty ? "" : " · " + item.detail),
                                        note: item.code ? "symbol" : "heading",
                                        run: { [weak self, weak o] in
                                            guard let self else { return }
                                            if let fragment { return self.open("manifold:\(id.description)#\(fragment)", from: self.arrangement?.focused) }
                                            self.arrive(atTile: pid)
                                            o?.pick(i)
                                        },
                                        drag: { Drags.place?(id, fragment, title, Drags.modifiers) }, kinds: kinds))
                if items.count >= 150 { return items }
            }
        }
        return items
    }

    /// "In Blocks" (⇧⌘O): the places in the blocks' outlines that hold the
    /// query (finderOutlineItems); then the texts of the blocks — the
    /// selected workspace's first, then every other note and file kept as
    /// a block — a row each, its name, where it is, the lines that hold
    /// the query marked, going to the first of them; then agents' turns.
    private func finderBlockItems(_ query: String) -> [FinderItem] {
        guard !query.isEmpty else { return [] }
        let q = query.lowercased()
        let needle = Array(q.utf8)
        let places = finderOutlineItems(q)
        var items: [FinderItem] = []
        var seen = Set<BlockID>()
        let here = arrangement.map { a in a.placements.map { ($0.block, Optional($0.id)) } } ?? []
        let rest = hosts.blocks.filter { $0.kind == .text }.map { ($0.id, PlacementID?.none) }
        for (blockID, placement) in here + rest where seen.insert(blockID).inserted {
            // Each text read through as made once per version (`SearchText`),
            // not lowercased afresh, line by line, at every key.
            guard let b = hosts.block(blockID), b.text != nil, let st = searchText(for: b) else { continue }
            let hits = st.lines(matching: needle, limit: 10_000)
            guard let at = hits.first else { continue }
            let matches = hits.prefix(6).map { String(st.lines[$0 - 1]) }
            let count = hits.count, block = b.id
            let place = b.path.map { $0.deletingLastPathComponent.abbreviatingHome } ?? (b.place.map { "Note · " + $0.abbreviatingHome } ?? "Note")
            items.append(FinderItem(symbol: Theme.symbolName(for: b), title: b.displayTitle, detail: place,
                                    note: count == 1 ? "line \(at)" : "\(count) lines",
                                    run: { [weak self] in
                                        guard let self else { return }
                                        let d = Self.disposition ?? .goTo
                                        if d == .goTo, let id = placement, self.arrangement?.placement(id) != nil, let e = self.views[id] as? EditorView {
                                            self.arrive(atTile: id)
                                            e.select(line: at)
                                            return
                                        }
                                        if d != .system { self.pendingJump = (b.path ?? "", at, nil) }
                                        self.follow(block, lens: Lens.default(for: .text, path: b.path), from: self.arrangement?.focused, d, context: "found in ⌘O")
                                        self.warpPointerToFocus()
                                    },
                                    excerpt: Self.excerpt(matches), marked: query,
                                    drag: { Drags.block?(block, Drags.modifiers) }, block: block,
                                    kinds: FindKinds.of(b.kind, path: b.path, agent: b.agent != nil)))
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
                                        run: { [weak self] in
                                            guard let self else { return }
                                            let f = self.arrangement?.focused
                                            let place: Where = switch Self.disposition ?? .goTo {
                                            case .over: f.map { .over($0) } ?? .here
                                            case .beside: f.map { .besideOpener($0) } ?? .here
                                            default: .here
                                            }
                                            self.showTurn(turnID, of: agentID, place: place)
                                        },
                                        excerpt: Self.excerpt(lines), marked: query, kinds: ["turn"]))
                if items.count >= 150 { return places + items }
            }
        }
        return places + items
    }

    /// ⌘O, Open Quickly: every block and space, by name. Files are found
    /// by Find in Files (⇧⌘F), a search block of their own.
    @objc func openDocument(_ sender: Any?) {
        let (corpus, actions) = finderCorpus()
        finder.show(corpus: corpus, actions: actions, filesUnder: nil, scope: .names, placeholder: "Open quickly…", over: window)
    }

    /// ⇧⌘O, Find in Blocks: the same finder, by the words in the blocks.
    @objc func findInBlocks(_ sender: Any?) {
        let (corpus, actions) = finderCorpus()
        finder.show(corpus: corpus, actions: actions, filesUnder: nil, scope: .blocks, placeholder: "Find in blocks…", over: window)
    }

    /// What the finder finds by name (§3.5), taken once as it opens: every
    /// block and workspace, each with what it's called (and words as good:
    /// its kind, the agent at work in it), what's around it, how far it is
    /// from the focused block and how lately seen. Ranked off the main
    /// thread as you type (FinderRanking).
    /// What nothing keeps (§4) comes last, marked recent.
    private func finderCorpus() -> ([FinderCandidate], [() -> Void]) {
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
                guard let a = block.arrangement else { continue }
                title = self.title(of: a)
                secondary = ""
                detail = a.isNamed ? "Space · \(a.placements.count) blocks" : "Space, unnamed · \(a.placements.count) blocks"
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
            case .smartlog:
                secondary = "smartlog isl sapling " + (block.path ?? "")
                detail = "Interactive Smartlog, \(block.path?.abbreviatingHome ?? "")"
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
            case .ui:
                secondary = "panel ui form " + (block.place ?? "")
                detail = "Panel" + (block.place.map { " · " + $0.abbreviatingHome } ?? "")
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
            // How long since it was seen, in a pill — none for just now.
            let seen = Age.short(entry.lastSeen)
            let age = seen == "now" ? nil : seen
            // Words as good as the title's own: the kind ("terminal", "note"),
            // and the agent at work in it ("claude", "Claude Code").
            let kindWord = block.kind == .text ? (block.path == nil ? "Note" : "File") : block.kind.defaultTitle
            let agentWords = agent.map { " " + $0.command + " " + $0.name } ?? ""
            secondary += " " + block.id.host.raw
            let id = block.id
            // What its summary says is found too: often the best of what
            // it holds (a terminal's last command, an agent's last words).
            let summary = block.kind == .arrangement ? "" : block.summary().lines.joined(separator: " ")
            corpus.append(FinderCandidate(symbol: Theme.symbolName(for: block), title: title, detail: detail + remote, note: note, age: age,
                                          name: title + " " + kindWord + agentWords, aliases: agent.map { [$0.command, $0.name] } ?? [], around: secondary,
                                          summary: summary,
                                          distance: distance, recency: max(entry.lastSeen.wall, joinedAt[block.id] ?? 0), action: actions.count, block: block.id,
                                          kinds: FindKinds.of(block.kind, path: block.path, agent: agent != nil)))
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
                                              note: "", age: Age.short(turn.began) == "now" ? nil : Age.short(turn.began), name: first + " turn " + turn.agent,
                                              around: (turn.repo ?? "") + " " + (turn.files ?? []).joined(separator: " "),
                                              distance: 60, recency: turn.began.wall, action: actions.count, kinds: ["turn"]))
                actions.append { [weak self] in self?.showTurn(turnID, of: agentID, place: .here) }
            }
        }
        return (corpus, actions)
    }

    /// Recall, from the finder: an arrangement onto the desk and selected;
    /// any other block gone to.
    /// Chosen in the finder: gone to; with ⌘ held on ⏎, beside the focused
    /// tile; with ⌥, over it (the rule, §3.1).
    func recall(_ id: BlockID) {
        let d = Self.disposition ?? .goTo
        // Nothing focused to open beside or over: gone to, or brought here.
        guard arrangement?.focused != nil || d == .system else { return goTo(id) }
        follow(id, from: arrangement?.focused, d, context: "chosen in ⌘O")
    }

    /// After a go-to (⌘O, ⌘P, a found line): the pointer moves to what was
    /// gone to — the text cursor if the tile has one, else the tile's
    /// middle — a moment later, once it is laid out.
    func warpPointerToFocus() {
        // Once laid out; and again once the layout's animation (a tile
        // coming out of a stack, a column resettling) has ended.
        for delay in [0.08, 0.32] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                guard let self, let a = self.arrangement, let f = a.focused, let view = self.views[f] else { return }
                self.warpPointer(to: view)
                // Arrived: the tile marked, once.
                if delay < 0.1 { self.content.markArrival(f) }
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
    /// `near`: of the block's tiles here, the one in that tile's stack
    /// first (brought to its top), then its column's — not whichever comes
    /// first (another of the block's tiles elsewhere, focused for nothing).
    func goTo(_ id: BlockID, near: PlacementID? = nil) {
        guard let block = hosts.block(id) else { return }
        hideStateView()
        warpPointerToFocus()
        if block.kind == .arrangement { return hosts.select(id) }
        if let a = arrangement, let t = nearest(a.placements(of: id), to: near, in: a), let here = selected {
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

    /// Of a block's tiles, the one nearest `near`: in its stack, then its
    /// column, then the first.
    private func nearest(_ tiles: [Placement], to near: PlacementID?, in a: ArrangementState) -> Placement? {
        guard let near, tiles.count > 1 else { return tiles.first }
        let top = a.isStashed(near) ? a.tile(behind: near)?.id : near
        if let t = tiles.first(where: { a.isStashed($0.id) && a.tile(behind: $0.id)?.id == top }) { return t }
        if let c = a.locate(near)?.column, let t = tiles.first(where: { a.locate($0.id)?.column == c }) { return t }
        return tiles.first
    }

    // MARK: Pins (§3.6)

    /// A workspace's pinned blocks, in the order pinned: each a strong link
    /// from the workspace, which keeps it while the workspace is kept.
    func pins(of workspace: BlockID) -> [Edge] {
        let edges = hosts.client(of: workspace)?.node.graph.edges(from: workspace, kind: .link(.pinned)).filter(\.isLive) ?? []
        var seen = Set<BlockID>()
        return edges.sorted { $0.at < $1.at }.filter { seen.insert($0.to).inserted }
    }

    func isPinned(_ block: BlockID, in workspace: BlockID) -> Bool { pins(of: workspace).contains { $0.to == block } }

    /// Pinned in a workspace, or let go of there.
    func setPinned(_ block: BlockID, in workspace: BlockID, _ on: Bool) {
        if on {
            guard !isPinned(block, in: workspace) else { return }
            hosts.link(from: workspace, to: block, kind: .pinned, context: "pinned")
        } else {
            for e in pins(of: workspace) where e.to == block { hosts.propose(.unlink(e.id)) }
        }
        refreshOrganization(now: true)
    }

    /// A pinned block with no tile, chosen in the sidebar: its workspace
    /// shown, the block in a tile there again.
    func recallPinned(_ block: BlockID, in workspace: BlockID) {
        guard let b = hosts.block(block) else { return }
        if selected != workspace { hosts.select(workspace) }
        if let a = hosts.arrangement(workspace), let t = a.placements(of: block).first {
            return hosts.append(arriving(t.id, in: a), to: .block(workspace))
        }
        show(block, lens: Lens.default(for: b.kind, path: b.path), .here, context: "pinned")
    }

    /// Pin in Workspace: a tile's block (the menu's, from a block's own
    /// menu; else the focused one's) pinned in the workspace shown, or let go of.
    @objc func togglePinInWorkspace(_ sender: Any?) {
        guard let id = selected, let block = pinTarget(sender) else { return NSSound.beep() }
        setPinned(block, in: id, !isPinned(block, in: id))
    }

    private func pinTarget(_ sender: Any?) -> BlockID? {
        if let p = (sender as? NSMenuItem)?.representedObject as? PlacementID, let t = arrangement?.placement(p) { return t.block }
        return focusedShown?.placement.block
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

    /// The one rule for opening anything (DESIGN §12) — a link, a capsule,
    /// a row, a hit: plain goes to it, ⌘ opens it beside, ⌥ (⌥⌘) over,
    /// ⇧⌘ in the system's app.
    enum Disposition {
        case goTo, beside, over, system

        init(_ flags: NSEvent.ModifierFlags) {
            if flags.isSuperset(of: [.command, .shift]) { self = .system }
            else if flags.contains(.option) { self = .over }
            else if flags.contains(.command) { self = .beside }
            else { self = .goTo }
        }
    }

    /// What the event in hand says: a click's modifiers, or ↩'s (⌘↩
    /// beside, ⌥↩ over); nil for anything else — a menu's key.
    static var disposition: Disposition? {
        if let flags = clickModifiers { return Disposition(flags) }
        guard let e = NSApp.currentEvent, e.type == .keyDown, e.keyCode == 36 || e.keyCode == 76 else { return nil }
        return Disposition(e.modifierFlags)
    }

    /// Whether a tile shows the block, in any space.
    func isPlaced(_ block: BlockID) -> Bool {
        allWorkspaces.contains { hosts.arrangement($0)?.placements(of: block).isEmpty == false }
    }

    /// A web block a tile shows at the address, in any space.
    func placedPage(_ url: URL) -> BlockID? {
        for arr in allWorkspaces {
            guard let a = hosts.arrangement(arr) else { continue }
            for t in a.placements where t.block.host == host.host {
                if hosts.block(t.block)?.web?.url == url.absoluteString { return t.block }
            }
        }
        return nil
    }

    /// A block opened from a tile (or from nowhere) as `d` says: gone to
    /// where a tile shows it, in any space — else beside the tile; beside;
    /// over; to the system's app. A space is gone to whatever's held.
    func follow(_ block: BlockID, lens: Lens? = nil, from placement: PlacementID?, _ d: Disposition,
                kind: LinkKind = .opened, context: String? = nil) {
        guard let b = hosts.block(block) else { return }
        if b.kind == .arrangement { return d == .system ? NSSound.beep() : goTo(block) }
        let lens = lens ?? Lens.default(for: b.kind, path: b.path)
        switch d {
        case .system:
            openInSystem(block)
        case .over:
            show(block, lens: lens, placement.map { .over($0) } ?? .here, kind: kind, context: context)
        case .goTo where isPlaced(block):
            if let placement { linkFollowed(from: placement, to: block, kind: kind, context: context) }
            goTo(block, near: placement)
        case .goTo, .beside:
            show(block, lens: lens, placement.map { .besideOpener($0) } ?? .here, kind: kind, context: context)
        }
    }

    /// A terminal scrolled to one of its commands, once its tile is up and
    /// it has found the command's row (a moment, for a tile just made).
    /// A place in a block, once its tile is up: a line (in a preview, the
    /// line's place on the page), a PDF's page.
    func goToPlace(_ place: NavLocation, in block: BlockID, tries: Int = 20) {
        if let v = content.views.first(where: { $0.block == block && !$0.isHiddenOrHasHiddenAncestor }) {
            if case let .line(n) = place, let m = v as? MarkdownView { return m.reveal(line: n) }
            // A PDF's document comes a moment after its tile.
            if case .page = place, let m = v as? MediaView, m.navLocation == nil, tries > 0 {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in self?.goToPlace(place, in: block, tries: tries - 1) }
                return
            }
            return v.go(to: place)
        }
        guard tries > 0 else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in self?.goToPlace(place, in: block, tries: tries - 1) }
    }

    func goToCommand(_ id: Int, in block: BlockID, tries: Int = 20) {
        if let t = content.views.compactMap({ $0 as? TerminalView }).first(where: { $0.block == block && !$0.isHiddenOrHasHiddenAncestor }), t.go(toCommand: id) { return }
        guard tries > 0 else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in self?.goToCommand(id, in: block, tries: tries - 1) }
    }

    /// Go to a block from a click: where it is — or, with ⌥ held, over
    /// the tile clicked in.
    func arrive(_ block: BlockID, from placement: PlacementID?, over: Bool? = nil) {
        if over ?? Self.clickModifiers?.contains(.option) ?? false, let placement, let b = hosts.block(block), b.kind != .arrangement {
            show(block, lens: Lens.default(for: b.kind, path: b.path), .over(placement), context: "followed")
        } else {
            goTo(block)
        }
    }

    /// A block's link followed from a tile (a terminal's, an output's, a
    /// page's): the tile's block linked to it, unless they're linked already
    /// (a note's mention of it).
    private func linkFollowed(from placement: PlacementID?, to block: BlockID, kind: LinkKind = .opened, context: String? = nil) {
        guard let from = placement.flatMap({ shown($0)?.placement.block }), from != block else { return }
        let linked = hosts.all.contains { $0.node.graph.edges(from: from).contains { $0.to == block && $0.isLive && $0.kind != .placed } }
        if !linked { hosts.link(from: from, to: block, kind: kind, context: context ?? "followed") }
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

    /// A tile gone on to another block in its place — a listing into a
    /// folder, a preview to another page — what it showed kept on its
    /// trail, to come back to (⌘[).
    private func goOn(_ placement: PlacementID, from block: BlockID, to next: BlockID, lens: Lens) {
        let p = Placement(block: next, lens: lens)
        var h = trails.removeValue(forKey: placement) ?? (back: [], forward: [])
        h.back.append(block)
        h.forward = []
        trails[p.id] = h
        replace(placement, with: next, lens: lens, as: p.id)
    }

    /// ⌘[ (-1) or ⌘] (1) in a tile that goes on in its place: along its
    /// trail; false at either end.
    func walkTrail(_ placement: PlacementID, of block: BlockID, lens: Lens, _ direction: Int) -> Bool {
        guard var h = trails[placement] else { return false }
        let to: BlockID
        if direction < 0 {
            guard let b = h.back.popLast() else { return false }
            h.forward.append(block)
            to = b
        } else {
            guard let f = h.forward.popLast() else { return false }
            h.back.append(block)
            to = f
        }
        guard hosts.block(to) != nil else { return false }
        let next = Placement(block: to, lens: lens)
        trails.removeValue(forKey: placement)
        trails[next.id] = h
        replace(placement, with: to, lens: lens, as: next.id)
        return true
    }

    /// Opens a file to edit: from a terminal, beside it; else here.
    func edit(_ path: String) {
        let on = focusedHost
        guard on != host.host || Self.isEditable(path) else {
            NSWorkspace.shared.open(URL(fileURLWithPath: path))
            return
        }
        let block = hosts.textBlock(for: path, on: on)
        show(block, lens: .editor, focusedShown?.lens == .terminal ? opener(focusedShown?.id) : .here, context: "edit \(path.lastPathComponent)")
    }

    /// Find in Files…: a search block on the focused block's host, under
    /// where it is (a terminal's directory, a file's folder) — its tile's
    /// path field to change, and Expand to Project to widen it to the
    /// repository — starting from the editor's selection; placed beside
    /// what's focused.
    @objc func findInFiles(_ sender: Any?) {
        let on = focusedHost
        let root = focusedCwd ?? NSHomeDirectory()
        var text = ""
        if let tv = window?.firstResponder as? TextView {
            let selected = tv.selectedText
            if !selected.isEmpty, !selected.contains("\n") { text = selected }
        }
        guard let client = hosts.client(on) else { return }
        let block = client.newSearch(SearchQuery(text: text, root: root))
        // Linked from where it was asked, by what was looked for.
        show(block, lens: .search, focusedShown.map { .besideOpener($0.id) } ?? .here, context: text.isEmpty ? "find in files" : "find “\(text)”")
    }

    /// Find in This Folder: a search under a folder (a folder tile's, an
    /// entry's), beside it, its words to type.
    func findInFolder(_ path: String, on h: HostID, from placement: PlacementID?) {
        guard let client = hosts.client(h) else { return NSSound.beep() }
        let block = client.newSearch(SearchQuery(text: "", root: path))
        show(block, lens: .search, placement.map { .besideOpener($0) } ?? .here, context: "find in \(path.lastPathComponent)")
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
        return agents.map { a in ClosureMenuItem(a.name, symbol: "sparkle") { [weak self] in self?.launchAgent(a.command) } }
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

    /// Interactive Smartlog (⌥⌘I): Sapling's, for the repository the focused
    /// block is in, as a block of its own (§7.6) — the one there is, else
    /// a new one; if there's no Sapling there, its tile says why.
    @objc func showSmartlog(_ sender: Any?) {
        let on = focusedHost
        guard let client = hosts.client(on) else { return NSSound.beep() }
        let path = focusedShown?.path ?? focusedCwd ?? NSHomeDirectory()
        let block = client.smartlogBlock(for: path)
        show(block, lens: .smartlog, focusedShown.map { .besideOpener($0.id) } ?? .here, context: "smartlog")
    }

    /// Compare with Last Commit: the focused file against HEAD, beside it.
    @objc func compareWithHead(_ sender: Any?) {
        guard let f = focusedShown, let path = f.path, f.lens == .editor || f.lens == .preview,
              let client = hosts.client(f.placement.block.host) else { return }
        let block = client.diffBlock(.sides(old: DiffSide(path: path, revision: "HEAD"), new: DiffSide(path: path)))
        show(block, lens: .diff, .besideOpener(f.id), context: "Compare with Last Commit")
    }

    /// Opens a file at a place (line and column from 1) beside the
    /// placement that opened it, on the host the placement's block is on.
    /// Opens a file at a place (line and column from 1), as the click or
    /// ↩ says (`as`, else read off the event; plain goes to it), from the
    /// placement that opened it, on the host the placement's block is on.
    func open(path: String, line: Int, column: Int?, on: HostID, from: PlacementID?, as d: Disposition? = nil,
              kind: LinkKind = .opened, context: String? = nil) {
        let d = d ?? Self.disposition ?? .goTo
        if d != .system { pendingJump = (path, line, column) }
        let block = hosts.textBlock(for: path, on: on)
        follow(block, lens: Lens.default(for: .text, path: path), from: from, d, kind: kind, context: context ?? "\(path.lastPathComponent):\(line)")
        warpPointerToFocus()
    }

    func openDirectory(_ path: String, from: PlacementID?, as d: Disposition? = nil, context: String? = nil) {
        let on = from.flatMap { shown($0)?.placement.block.host } ?? focusedHost
        let block = hosts.directoryBlock(for: path, on: on)
        follow(block, lens: .directory, from: from, d ?? Self.disposition ?? .goTo, context: context)
    }

    /// Whether a terminal tile is an agent's: its turns are its outline
    /// (ticks), not a shell's commands (dots).
    private func isAgent(_ p: Placement) -> Bool {
        guard let b = hosts.block(p.block) else { return p.lens == .agent }
        return p.lens == .agent || b.kind == .agent || b.agent != nil || b.terminal?.turns?.isEmpty == false
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
    /// ⌘P: the workspace as a hierarchy, as Prism's Move to Heading is —
    /// its tiles by column, and the headings of the text in them, set in
    /// under their tile; those whose words have every word of the query.
    /// ↩ goes to a tile, or to a heading in its editor or preview.
    /// ⇧⌘P: the focused tile's outline — a text's headings or symbols, a
    /// terminal's commands, a PDF's contents, a diff's files — filtered
    /// in its sidebar; again, the sidebar's filter left.
    @objc func searchOutline(_ sender: Any?) {
        guard let f = arrangement?.focused else { return NSSound.beep() }
        searchOutline(of: f)
    }

    /// ⇧⌘P: the tile's own outline, its sidebar (shown if it wasn't, put
    /// away again after), filtered by what's typed in the field at its
    /// top (kept from the last time), the pointer there — ↩ goes to the
    /// entry chosen, Escape clears then leaves, ⇧⌘P again leaves. A tile
    /// with an outline but no sidebar: ⌘P, on its outline.
    func searchOutline(of placement: PlacementID) {
        // Already there: ⇧⌘P again leaves it.
        if let view = views[placement], let s = view.sidebarView ?? Self.tileSidebar(in: view), s.isSearching {
            return s.endSearch()
        }
        if let view = views[placement], view.hasSidebar {
            let wasShown = view.sidebarShown
            if !wasShown {
                view.toggleSidebar()
                content.sidebarChanged(placement)
            }
            view.layoutSubtreeIfNeeded()
            if let sidebar = view.sidebarView ?? Self.tileSidebar(in: view) {
                // After the focus settles (a tile focused takes the keyboard).
                DispatchQueue.main.async { [weak self, weak view, weak sidebar] in
                    guard let self, let sidebar else { return }
                    sidebar.beginSearch { [weak self, weak view] in
                        guard let self, let view else { return }
                        if !wasShown, view.sidebarShown {
                            view.toggleSidebar()
                            self.content.sidebarChanged(placement)
                        }
                        self.focus(placement)
                    }
                    if let window = self.window {
                        let r = window.convertToScreen(sidebar.searchFrame)
                        Pointer.warp(to: NSPoint(x: r.minX + 24, y: r.midY))
                    }
                }
                return
            }
        }
        // No sidebar: ⌘P, on this tile's outline.
        focus(placement)
        goToTile(nil)
    }

    /// A tile's outline as rows for ⌘P: nested as it is while all of it
    /// shows; found (by the space's index), flat.
    private func tileOutlineItems(_ placement: PlacementID, _ view: PaneContent, _ outline: Outline, _ query: String) -> [FinderItem] {
        guard let index = syncOutlineIndex() else { return [] }
        let rows = index.rows(of: placement)
        // (Not by its title: the tile's own outline is found by its own words.)
        let found = query.isEmpty ? Array(rows.indices) : index.find(query, in: [placement], titles: false).first?.items ?? []
        let words = !query.trimmingCharacters(in: .whitespaces).isEmpty
        return found.compactMap { i -> FinderItem? in
            guard rows.indices.contains(i) else { return nil }
            let item = rows[i]
            return FinderItem(symbol: view is TerminalView ? "chevron.right" : item.code ? "curlybraces" : "number", title: item.title, detail: item.detail, note: "",
                              level: words ? 0 : item.level, run: { outline.pick(i) })
        }
    }

    /// A tile's own sidebar, wherever its view keeps it.
    static func tileSidebar(in view: NSView) -> TileSidebar? {
        (view as? TileSidebar) ?? view.subviews.lazy.compactMap { tileSidebar(in: $0) }.first
    }

    /// Debugging: the first process tile.
    /// Debugging: a process tile, the one in view if there is one.
    var debugProcessView: ProcessView? {
        let all = views.values.compactMap { $0 as? ProcessView }
        return all.first { $0.window != nil && !$0.isHiddenOrHasHiddenAncestor } ?? all.first
    }

    /// Debugging: ⇧⌘P's field in the focused tile's sidebar, typed into or keyed.
    func debugOutlineSearch(_ what: String) -> String {
        guard let f = arrangement?.focused, let v = views[f] else { return "nothing focused" }
        if what == "open" { searchOutline(of: f); return "opened" }
        return (v.sidebarView ?? Self.tileSidebar(in: v))?.debugSearch(what) ?? "no sidebar"
    }

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
        // The focused tile's own outline first, if it has one; ⇥ widens it
        // to the whole space's (and back).
        let tile: Finder.OutlineScope? = a.focused.flatMap { f in self.views[f].map { (f, $0) } }.flatMap { f, view in
            guard let outline = view.outline, !outline.items.isEmpty else { return nil }
            return Finder.OutlineScope(provider: { query in self.tileOutlineItems(f, view, outline, query) }, start: outline.current,
                                       placeholder: "Go to a place in this tile…", hint: "This tile's outline")
        }
        // Each query looked up in the space's index (kept as outlines
        // change), not the outlines gone through again.
        let space = Finder.OutlineScope(provider: { [weak self] query in
            guard let self, let a = self.arrangement else { return [] }
            return self.spaceOutlineRows(a, query: query)
        }, start: spaceOutlineStart(a), placeholder: "Go to a tile, or a place in its outline…", hint: "The space, by column and tile, headings within")
        if let tile { finder.showOutline(tile, wider: space, over: window) } else { finder.showOutline(space, over: window) }
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

    // MARK: The space's outline, indexed (⌘P)

    /// Each space's index of its tiles' outlines (`OutlineIndex`): kept as
    /// they change — an outline tells its index when its items do — and as
    /// tiles come and go, so a query in ⌘P only looks up. The selected
    /// space's, and a few others' as they were left.
    private var outlineIndexes: [BlockID: OutlineIndex<PlacementID, Outline.Item>] = [:]
    private var outlineSyncPending = false

    /// The selected space's index, brought up to date: a tile's rows taken
    /// again only if its outline changed since (its items, or which outline
    /// it is), and then only those that changed; each tile's title as it is.
    @discardableResult
    private func syncOutlineIndex() -> OutlineIndex<PlacementID, Outline.Item>? {
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
    private func spaceOutlineStart(_ a: ArrangementState) -> Int? {
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
    /// place, what runs in it or what that reports holds them.
    private func spaceOutlineRows(_ a: ArrangementState, query: String) -> [FinderItem] {
        guard let index = syncOutlineIndex() else { return [] }
        let order = a.columns.joined().map(\.id)
        var found: [PlacementID: [Int]] = [:]
        for hit in index.find(query, in: order) { found[hit.tile] = hit.items }
        let words = query.lowercased().split(whereSeparator: \.isWhitespace).map(String.init)
        let running = runningPrograms()
        var items: [FinderItem] = []
        for (c, column) in a.columns.enumerated() {
            for p in column {
                guard let b = hosts.block(p.block) else { continue }
                let id = p.id
                var notes: [String] = []
                if a.columns.count > 1 { notes.append("column \(c + 1)") }
                if a.isStashed(p.id) { notes.append("stashed") }
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
                }
                let rows = index.rows(of: id)
                let name = b.displayTitle
                guard let hits = found[id] else { continue }
                items.reserveCapacity(items.count + hits.count)
                for i in hits where rows.indices.contains(i) {
                    let item = rows[i]
                    items.append(FinderItem(symbol: item.code ? "chevron.forward" : "number", title: item.title,
                                            detail: item.detail.isEmpty ? name : name.isEmpty ? item.detail : name + " · " + item.detail,
                                            note: item.running ? "running" : item.failed ? "failed" : "", level: item.level + 1,
                                            run: { [weak self] in
                        guard let self else { return }
                        self.arrive(atTile: id)
                        self.views[id]?.outline?.pick(i)
                    }))
                }
            }
        }
        return items
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
    /// Whether a link just clicked stays in Manifold: every way of clicking
    /// it does (⌘ beside, ⌥ over) but ⇧⌘, which goes to the system's app —
    /// the browser, for an address.
    static func opensHere(_ flags: NSEvent.ModifierFlags) -> Bool {
        !flags.isSuperset(of: [.command, .shift])
    }

    /// A block given to the system's app: a page's address to the browser,
    /// a file of this Mac to what opens it; else a beep.
    func openInSystem(_ id: BlockID) {
        guard let b = hosts.block(id) else { return NSSound.beep() }
        if let address = b.web?.url, let url = URL(string: address) { NSWorkspace.shared.open(url); return }
        if let path = b.path, id.host == host.host { NSWorkspace.shared.open(URL(fileURLWithPath: path)); return }
        NSSound.beep()
    }

    private static var clickModifiers: NSEvent.ModifierFlags? {
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
            follow(b, from: placement, d, context: "followed")
            if d == .system { return }
            linkFollowed(from: placement, to: b)
            if let fragment, fragment.hasPrefix("command="), let id = Int(fragment.dropFirst(8)) { goToCommand(id, in: b) }
            // A place in it: a line (a heading's), a PDF's page.
            if let fragment, fragment.hasPrefix("line="), let n = Int(fragment.dropFirst(5)) { goToPlace(.line(n), in: b) }
            if let fragment, fragment.hasPrefix("page="), let n = Int(fragment.dropFirst(5)) { goToPlace(.page(n - 1), in: b) }
            return
        }
        // An address: a scheme and "//" (or one that goes without, as
        // mailto: does) — not `README.md:781`, whose "README.md" a URL
        // would take for a scheme.
        if let url = URL(string: target), let scheme = url.scheme, scheme.count > 1, scheme != "file",
           target.contains("://") || Self.schemesWithoutSlashes.contains(scheme.lowercased()) {
            let inWeb = here ?? (d != .system)
            // Plain: to a page already showing the address, in any space.
            if inWeb, d == .goTo, let page = placedPage(url) {
                linkFollowed(from: placement, to: page)
                return goTo(page, near: placement)
            }
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

    static let loopbackNames: Set<String> = ["localhost", "127.0.0.1", "0.0.0.0", "::1", "[::1]"]

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

    /// An address: in the web lens (where `here` says), else the system's browser.
    func openWeb(_ url: URL, place: Where, here: Bool, context: String? = nil) {
        if (url.scheme == "http" || url.scheme == "https") && here {
            show(host.newWeb(url: url.absoluteString), lens: .web, place, context: context ?? url.absoluteString)
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

    /// Settings (⌘,): every setting in one window.
    private var settingsWindow: SettingsWindow?

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

    /// Open requests being waited on: the placements that must go before
    /// the command returns.
    var openWaits: [(host: HostID, id: Int, client: Int, placements: [PlacementID], made: [BlockID])] = []

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
    private func showRequest(on: HostID, id: Int, client: Int, block: BlockID, beside: BlockID?) {
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
    private func rename(_ id: BlockID) {
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
            self.show(diff, lens: .diff, .besideOpener(placement), context: "Compare with Now")
        }
        h.onOpen = { [weak self] text, moment in
            guard let self, let client = self.hosts.client(block.host) else { return }
            self.hideHistory()
            let f = DateFormatter()
            f.dateStyle = .medium
            f.timeStyle = .short
            let title = "\(self.hosts.block(block)?.displayTitle ?? "Text") as of \(f.string(from: moment.date))"
            let id = BlockID(host: block.host)
            client.append([.create(kind: .output, title: title, path: nil),
                           .output(OutputState(line: title, ended: moment, output: text, plain: true))], to: .block(id))
            self.show(id, lens: .output, .besideOpener(placement), context: "as of \(f.string(from: moment.date))")
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
    func sidebarFilter(_ filter: SidebarFilter?) { setSidebarFilter(filter) }
    func sidebarRemove(_ arrangement: BlockID) { removeFromDesk(arrangement) }
    func sidebarRename(_ arrangement: BlockID) { rename(arrangement) }
    /// The sidebar's +: a new workspace with a terminal in it (⌥⌘T).
    func sidebarNewTab() { newTerminal(nil) }

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
            ctx.duration = Motion.reduced ? 0 : Motion.base
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
    /// A tile as a summary card: its block's summary, and what only the
    /// window has — a terminal's last lines on its screen, a picture of a
    /// page or a PDF as it was last seen.
    func gridLinkSummary(_ block: BlockID) -> SummaryCardContent? { cardContent(for: block) }

    func gridSummary(_ placement: PlacementID) -> SummaryCardContent? {
        guard let p = arrangement?.placement(placement) else { return nil }
        return cardContent(for: p.block, view: views[placement], id: placement)
    }

    /// A block's summary card: its summary, and what only the window has —
    /// a terminal's last lines on its screen, a picture of a page or a PDF
    /// as it was last seen. `view`: its tile's, if it has one shown.
    func cardContent(for block: BlockID, view: PaneContent? = nil, id: PlacementID = "") -> SummaryCardContent? {
        guard let b = hosts.block(block) else { return nil }
        let view = view ?? views.values.first { $0.block == block }
        var s = b.summary()
        // A shell's screen says more than its command: its last lines (not
        // the prompt waiting at the end).
        if let t = view as? TerminalView, b.terminal?.turns?.isEmpty ?? true {
            var screen = t.visibleText.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            // The prompt waiting at the end, and every line that begins with
            // it — the prompt again, or a command the card says already.
            if b.terminal?.commands?.last?.isRunning != true, let prompt = screen.last {
                screen.removeAll { $0.hasPrefix(prompt) }
            }
            let tail = screen.suffix(2).map { String($0) }
            if !tail.isEmpty { s.lines = Array(s.lines.prefix(1)) + tail }
        }
        s.place = s.place.map { $0.abbreviatingHome }
        var thumbnail: NSImage?
        if s.wantsThumbnail {
            thumbnail = tilePictures[b.id] ?? view.flatMap { HoverCard.picture(of: $0, evenHidden: true) }
        }
        return SummaryCardContent(id: id, symbol: Theme.symbolName(for: b), summary: s, thumbnail: thumbnail)
    }

    func gridFocus(_ placement: PlacementID) { focus(placement) }

    func gridKeptPicture(_ block: BlockID) -> NSImage? { tilePictures[block] }

    /// Edit ▸ Copy Contents (⇧⌘C): the focused block's content as text —
    /// what `mani read` gives: a file's text, a terminal's history, a
    /// page's, a listing, a search's hits — on the pasteboard, whatever
    /// the block is, and said so (or why not).
    @objc func copyContents(_ sender: Any?) {
        guard let f = focusedShown, let b = f.block else { return toast.show("Nothing focused to copy", action: "OK", for: 4) {} }
        let view = views[f.placement.id]
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let text = try await self.maniDesk.contents(of: b, view: view, all: true)
                let pb = NSPasteboard.general
                pb.clearContents()
                pb.setString(text, forType: .string)
                let n = text.split(separator: "\n", omittingEmptySubsequences: false).count
                self.toast.show("Copied “\(b.displayTitle)”: \(n) line\(n == 1 ? "" : "s")", action: "OK", for: 3) {}
            } catch let e as ManiDesk.Failure {
                self.toast.show("Couldn't copy: \(e.message)", action: "OK", for: 5) {}
            } catch {
                self.toast.show("Couldn't copy “\(b.displayTitle)”", action: "OK", for: 5) {}
            }
        }
    }

    func gridKeep(_ picture: NSImage, of block: BlockID) { tilePictures[block] = picture }

    func gridArrive(_ placement: PlacementID) { arrive(atTile: placement) }

    func gridShrinkToSummary(_ placement: PlacementID) { toggleSummary(placement) }

    /// ⇧⌘M: the focused tile down to its summary, or back.
    @objc func shrinkToSummary(_ sender: Any?) {
        guard let f = arrangement?.focused else { return NSSound.beep() }
        toggleSummary(f)
    }

    /// The content height a tile is given in summary: three of its lines.
    private static let summaryPoints: CGFloat = 60

    /// A tile down to its summary — its height given to the biggest other
    /// in its column — or, already there, back to the height it had (or,
    /// not shrunk here, grown a little, as going to it does).
    private func toggleSummary(_ placement: PlacementID) {
        guard let a = arrangement, a.full == nil, let body = contentHeight(of: placement, in: a) else { return NSSound.beep() }
        if body >= GridView.collapseBelow, body < GridView.summarizeBelow {
            if let back = unshrunk.removeValue(forKey: placement), let events = settingHeight(of: placement, share: back, in: a) {
                appendToSelected(events)
            } else {
                arrive(atTile: placement)
            }
            return
        }
        guard let events = settingHeight(of: placement, points: Self.summaryPoints, in: a) else { return NSSound.beep() }
        unshrunk[placement] = a.height(of: placement)
        appendToSelected(events)
    }

    /// Whether a tile is in summary: its content too short for itself.
    func isSummarized(_ placement: PlacementID) -> Bool {
        guard let a = arrangement, a.full == nil, let body = contentHeight(of: placement, in: a) else { return false }
        return body >= GridView.collapseBelow && body < GridView.summarizeBelow
    }

    /// A shown tile's content height, as the grid lays it out; nil for one
    /// stashed, or alone in its column.
    private func contentHeight(of placement: PlacementID, in a: ArrangementState) -> CGFloat? {
        guard !a.isStashed(placement), let (c, _) = a.locate(placement) else { return nil }
        let shown = a.shownTiles(inColumn: c)
        let sum = shown.reduce(0.0) { $0 + a.height(of: $1.id) }
        let usable = content.bounds.height - 2 * GridView.inset - CGFloat(shown.count - 1) * GridView.gap
        guard shown.count > 1, sum > 0, usable > 0 else { return nil }
        return usable * CGFloat(a.height(of: placement) / sum) - GridView.barHeight
    }

    /// A shown tile given `points` of content (or a `share`, as heights
    /// are kept): what it gives up to its nearest neighbour showing its
    /// content (below, then above), what it takes from the biggest other
    /// in its column.
    private func settingHeight(of placement: PlacementID, points: CGFloat? = nil, share: Double? = nil, in a: ArrangementState) -> [Event]? {
        guard !a.isStashed(placement), let (c, _) = a.locate(placement) else { return nil }
        let shown = a.shownTiles(inColumn: c)
        let sum = shown.reduce(0.0) { $0 + a.height(of: $1.id) }
        let usable = content.bounds.height - 2 * GridView.inset - CGFloat(shown.count - 1) * GridView.gap
        let want = share ?? points.map { Double(($0 + GridView.barHeight) / usable) * sum } ?? a.height(of: placement)
        let delta = want - a.height(of: placement)
        guard usable > 0, let i = shown.firstIndex(where: { $0.id == placement }) else { return nil }
        let others = shown.filter { $0.id != placement }
        let showing = { (p: Placement) in usable * CGFloat(a.height(of: p.id) / sum) - GridView.barHeight >= GridView.summarizeBelow }
        let nearest = (1..<max(shown.count, 2)).lazy.flatMap { d in [i + d, i - d] }.filter { shown.indices.contains($0) }.map { shown[$0] }.first(where: showing)
        guard let other = (delta < 0 ? nearest : nil) ?? others.max(by: { a.height(of: $0.id) < a.height(of: $1.id) }) else { return nil }
        guard a.height(of: other.id) - delta > 0 else { return nil }
        return [.heights([placement: want, other.id: a.height(of: other.id) - delta])]
    }

    func gridSwitcherFollowsPointer() {
        stackMonitors.forEach(NSEvent.removeMonitor)
        stackMonitors = []
    }

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
        removeFromDesk(arrangement, remember: false)
        hosts.select(id)
    }

    func gridMove(_ placement: PlacementID, column: Int, at: Int, newColumn: Bool, alone: Bool) {
        guard let a = arrangement else { return }
        if a.placement(placement) == nil { return bringFromElsewhere(placement, column: column, at: at, newColumn: newColumn) }
        if newColumn || column >= a.columns.count {
            movePlacement(placement, toNewColumn: column, in: a, alone: alone)
        } else {
            appendToSelected(a.moving(placement, column: column, at: at, alone: alone))
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

    /// A tile taken off a space it was moved from; the space stays, emptied
    /// or not, until it's removed (§4).
    private func takeOut(_ placement: PlacementID, of arrangement: BlockID) {
        hosts.append(.remove(placement), to: .block(arrangement))
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

    /// A tile behind another brought to the top of its stack (a peek's tab,
    /// a fanned card, a bar peeking out above it clicked), the rest in
    /// their order behind it.
    func gridSwap(_ placement: PlacementID) {
        guard let a = arrangement, a.isStashed(placement), let top = a.tile(behind: placement) else { return gridUnstash(placement) }
        guard let order = stackOrder(of: top.id, in: a), let k = order.firstIndex(of: placement) else { return }
        appendToSelected(a.walkingStack(order, to: k))
    }

    /// A shown tile and the tiles behind it, in order (those stashed above
    /// a column's first shown tile are behind it too).
    private func stackOrder(of top: PlacementID, in a: ArrangementState) -> [PlacementID]? {
        guard let (c, _) = a.locate(top), !a.isStashed(top) else { return nil }
        return [top] + a.columns[c].filter { a.isStashed($0.id) && a.tile(behind: $0.id)?.id == top }.map(\.id)
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
        afterClosing(reachedBefore: before)
    }

    /// Unstack: every tile behind this one shows, sharing its room.
    /// Tile ▸ Unstack, Close Stack: the focused tile's stack.
    @objc func unstackFocused(_ sender: Any?) {
        guard let f = arrangement?.focused else { return NSSound.beep() }
        gridUnstackAll(f)
    }

    @objc func closeFocusedStack(_ sender: Any?) {
        guard let f = arrangement?.focused else { return NSSound.beep() }
        gridCloseStack(f)
    }

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
    /// Debugging: the columns' widths set, as a divider dragged sets them.
    func debugSetFractions(_ f: [Double]) { gridResized(fractions: f) }
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

    var gridLocalHost: HostID { host.host }

    func gridOpenDropped(_ thing: GridView.Dropped, column: Int, at: Int, newColumn: Bool) {
        let place: Where = newColumn ? .inNewColumn(column) : .inColumn(min(column, max((arrangement?.columns.count ?? 1) - 1, 0)))
        switch thing {
        case let .promised(receivers):
            Promises.receive(receivers) { [weak self] urls in
                guard !urls.isEmpty else { return }
                self?.gridOpenFiles(urls.map(\.path), column: column, at: at, newColumn: newColumn)
            }
        case let .web(url):
            show(host.newWeb(url: url.absoluteString), lens: .web, place, context: "dropped")
        case let .text(text):
            // Words dropped: a note of them, at home where the focused block is.
            show(host.newNote(home: focusedHost == host.host ? focusedCwd : nil, text: text), lens: .editor, place)
        case let .image(data, kind):
            // A picture dropped: kept as an image block (in Manifold's folder).
            let id = BlockID(host: host.host)
            let f = DateFormatter()
            f.dateFormat = "yyyy-MM-dd-HHmmss"
            let name = "image-\(f.string(from: Date())).\(kind)"
            Transfers.shared.run(name, detail: "to \(hosts.label(of: host.host))", symbol: "photo") { [host] _, done in
                host.saveImage(data, block: id, name: name, folder: nil) { error, _ in done(error) }
                return nil
            } then: { [weak self] error in
                guard let self else { return }
                if let error { return self.toast.show("Couldn't keep the image: \(error)", action: "OK", for: 8) {} }
                self.showWhenMade(id, lens: .image, place: place, what: "the image")
            }
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
            let item = ClosureMenuItem(name, symbol: isFolder ? "folder" : Theme.symbolName(for: b)) { [weak self] in
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
        if !maximized, contentHeight(of: placement, in: a) != nil {
            let summarized = isSummarized(placement)
            menu.addItem(ClosureMenuItem(summarized ? "Show Content" : "Shrink to Summary", symbol: summarized ? "rectangle.expand.vertical" : "rectangle.compress.vertical",
                                         key: "M") { [weak self] in self?.toggleSummary(placement) })
        }
        if let t = hosts.block(block)?.text, t.isDirty {
            menu.addItem(.separator())
            if t.stale {
                menu.addItem(ClosureMenuItem("Reload from Disk, Losing the Edits", symbol: "arrow.clockwise") { [weak self] in self?.hosts.propose(.readFile(block)) })
                menu.addItem(ClosureMenuItem("Overwrite with the Edits", symbol: "square.and.arrow.down") { [weak self] in self?.save(block, from: placement) })
            } else {
                menu.addItem(ClosureMenuItem("Save", symbol: "square.and.arrow.down", key: "s") { [weak self] in self?.save(block, from: placement) })
            }
        }
        if let ws = selected {
            let on = isPinned(block, in: ws)
            let pin = ClosureMenuItem(on ? "Unpin" : "Pin in Space", symbol: on ? "pin.slash" : "pin", key: "t") { [weak self] in
                self?.setPinned(block, in: ws, !on)
            }
            pin.keyEquivalentModifierMask = [.command, .control]
            menu.addItem(pin)
        }
        if views[placement]?.outline != nil {
            menu.addItem(ClosureMenuItem("Filter Outline", symbol: "list.bullet.rectangle", key: "P") { [weak self] in
                guard let self else { return }
                self.focus(placement)
                self.searchOutline(of: placement)
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
        let agents = NSMenu()
        for item in agentMenuItems() { agents.addItem(item) }
        let launch = NSMenuItem(title: "Launch Agent Here", action: nil, keyEquivalent: "")
        launch.setSymbol("sparkle", size: 12)
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
        menu.addItem(ClosureMenuItem("Close Tile", symbol: "xmark", key: "w") { [weak self] in self?.closeTile(placement, in: id) })
        if hosts.block(block)?.kind == .text {
            let saveClose = ClosureMenuItem("Save and Close", symbol: "square.and.arrow.down", key: "w") { [weak self] in self?.saveAndClose(tile: placement) }
            saveClose.keyEquivalentModifierMask = [.command, .option]
            menu.addItem(saveClose)
        }
        let delete = ClosureMenuItem("Delete Block", symbol: "trash", key: "w") { [weak self] in self?.deleteBlock(block) }
        delete.keyEquivalentModifierMask = [.command, .shift]
        menu.addItem(delete)
        return menu
    }

    /// A path on a host dragged from a row (a hit, a change, a file in a
    /// diff), as a folder's entry is: its path, its place on its host, its
    /// file here; with ⇧ its block's link too; ⌥⇧ the link alone.
    func entryDragItem(_ path: String, isDirectory: Bool, on h: HostID, modifiers mods: NSEvent.ModifierFlags) -> NSPasteboardItem {
        let item = NSPasteboardItem()
        let link = mods.contains(.shift) ? pathBlock(path, isDirectory: isDirectory, on: h).map { id, _ -> String in
            let title = (hosts.block(id)?.displayTitle ?? path.lastPathComponent).replacingOccurrences(of: "]", with: "\\]")
            return "[\(title)](manifold:\(id.description))"
        } : nil
        if let link, mods.contains(.option) {
            item.setString(link, forType: .manifoldBlockLink)
            item.setString("1", forType: .manifoldLinkOnly)
            return item
        }
        item.setString(path, forType: .string)
        item.setString("\(h.raw)\t\(path)\t\(isDirectory ? "d" : "f")", forType: .manifoldPath)
        if h == host.host, !(isDirectory && link != nil) { item.setString(URL(fileURLWithPath: path).absoluteString, forType: .fileURL) }
        if let link { item.setString(link, forType: .manifoldBlockLink) }
        return item
    }

    /// What a block stands for when ⇧-dragged from anywhere (§3.4) — a
    /// tile's pill, a sidebar row, a finder row, a link's pill: its path
    /// (a terminal's folder, a page's address) for what types or inserts
    /// text, its file (here, not a folder) for the grid or another app, its
    /// place on its host for a folder tile, and its link for a note, a
    /// terminal or a tile to be linked. `linkOnly` (⌥⇧): the link alone.
    /// `place`: a place in it (an outline's item: "line=12", and its
    /// title), which the link names.
    func pathDragItem(for id: BlockID, linkOnly: Bool, place: (fragment: String, title: String)? = nil) -> NSPasteboardItem? {
        guard let b = hosts.block(id) else { return nil }
        let item = NSPasteboardItem()
        let title = (place?.title ?? b.displayTitle).replacingOccurrences(of: "]", with: "\\]")
        item.setString("[\(title)](manifold:\(id.description)\(place.map { "#" + $0.fragment } ?? ""))", forType: .manifoldBlockLink)
        if linkOnly {
            item.setString("1", forType: .manifoldLinkOnly)
            return item
        }
        guard let text = b.path ?? b.web?.url ?? b.terminal?.cwd ?? b.place else { return item }
        item.setString(text, forType: .string)
        if text.hasPrefix("/") {
            // Its place on its host, for a folder tile to copy — a file's or
            // a folder's own, not a terminal's working directory.
            if let path = b.path { item.setString("\(id.host.raw)\t\(path)\t\(b.kind == .directory ? "d" : "f")", forType: .manifoldPath) }
            var dir: ObjCBool = false
            if id.host == host.host, FileManager.default.fileExists(atPath: text, isDirectory: &dir), !dir.boolValue {
                item.setString(URL(fileURLWithPath: text).absoluteString, forType: .fileURL)
            }
        }
        return item
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
        // A folder (a terminal's): looked through.
        if let dir = b.kind == .directory ? b.path : b.terminal?.cwd {
            items.append(ClosureMenuItem("Find in This Folder…", symbol: "magnifyingglass") { [weak self] in
                self?.findInFolder(dir, on: block.host, from: self?.arrangement?.placements(of: block).first?.id)
            })
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

    func editor(_ view: EditorView, open url: URL, over: Bool) {
        open(url.absoluteString, from: view.placement, over: over)
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
        keepImage(data, kind: kind, for: view.block) { [weak view] markdown in view?.textView.insert(markdown, typing: false) }
    }

    /// An image dropped on a Markdown preview: kept as an editor keeps one,
    /// and shown at the end of the text.
    func markdownView(_ view: MarkdownView, image data: Data, kind: String) {
        let block = view.block
        keepImage(data, kind: kind, for: block) { [weak self] markdown in
            guard let self, let t = self.hosts.block(block)?.text else { return }
            let end = t.text.count
            let lead = t.text.string.hasSuffix("\n") || t.text.string.isEmpty ? "" : "\n"
            self.hosts.append(.edit([TextEdit(TextRange(end, end), lead + "\n" + markdown + "\n")]), to: .block(block))
        }
    }

    /// An image kept for a text, on its host: written as an image block,
    /// then `insert` given the Markdown that shows it.
    func keepImage(_ data: Data, kind: String, for text: BlockID, insert: @escaping (String) -> Void) {
        guard let b = hosts.block(text), let c = hosts.client(text.host) else { return NSSound.beep() }
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd-HHmmss"
        imageCount += 1
        let name = "image-\(f.string(from: Date()))\(imageCount > 1 ? "-\(imageCount)" : "").\(kind == "jpeg" ? "jpg" : kind)"
        let folder = b.path.map { $0.deletingLastPathComponent }
        let id = BlockID(host: text.host)
        var saved: String?
        Transfers.shared.run(name, detail: "into \(b.displayTitle)", symbol: "photo") { _, done in
            c.saveImage(data, block: id, name: name, folder: folder) { error, path in
                saved = path
                done(error)
            }
            return nil
        } then: { [weak self] error in
            let path = saved
            guard let self else { return }
            if let error { return self.toast.show("Couldn't keep the image: \(error)", action: "OK", for: 8) {} }
            let target = folder != nil
                ? (path?.lastPathComponent ?? name).addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? name
                : "manifold:\(id.description)"
            insert("![](\(target))")
        }
    }

    /// A block ⇧-dragged onto a terminal: its path typed, and linked.
    func terminal(_ view: TerminalView, linkedFrom block: BlockID) { link(block, to: view.block) }

    /// For an agent, what stands for a block it's given: its path where
    /// it's a file (or a folder, or a page's address) the agent can read;
    /// else what it holds, which only Manifold has to give.
    func terminal(_ view: TerminalView, contentsFor block: BlockID) -> ((@escaping (String?) -> Void) -> Void)? {
        guard let b = hosts.block(block) else {
            // Not here yet: a command ⇧-dragged from an outline, its block
            // asked for as the drag began. Given once it comes (a few
            // seconds at most), if it's one whose contents go.
            return { [weak self] done in
                Task { @MainActor in
                    for _ in 0..<40 where self?.hosts.block(block) == nil { try? await Task.sleep(for: .milliseconds(100)) }
                    guard let self, let b = self.hosts.block(block), Self.givesContents(b) else { return done(nil) }
                    self.give(b, done)
                }
            }
        }
        guard Self.givesContents(b) else { return nil }
        return { [weak self] done in self?.give(b, done) ?? done(nil) }
    }

    /// Whether an agent is given a block's contents rather than its path:
    /// one with no file (a terminal, a command's output, a search, a note).
    static func givesContents(_ b: Block) -> Bool {
        switch b.kind {
        case .terminal, .agent, .output, .search, .diff, .notebook, .git, .process: true
        case .text: b.path == nil
        default: false
        }
    }

    /// A block's contents as text, for an agent.
    private func give(_ b: Block, _ done: @escaping (String?) -> Void) {
        let shown = views.first { $0.value.block == b.id }?.value
        Task { @MainActor in
            do {
                done(try await maniDesk.contents(of: b, view: shown, all: true))
            } catch let e as ManiDesk.Failure {
                toast.show("Couldn't give “\(b.displayTitle)”: \(e.message)", action: "OK", for: 5) {}
                done(nil)
            } catch { done(nil) }
        }
    }

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

    /// A definition found (⌘-click): its file at its line, beside the
    /// editor — or, ⌘⌥-clicked, stacked over it.
    func editor(_ view: EditorView, open path: String, line: Int, column: Int, over: Bool) {
        let on = view.block.host
        pendingJump = (path, line, column)
        let block = hosts.textBlock(for: path, on: on)
        hosts.link(from: view.block, to: block, kind: .opened, context: view.lineAtCaret)
        show(block, lens: Lens.default(for: .text, path: path), opener(view.placement, over: over), context: view.lineAtCaret)
    }

    /// References as a search block: each place's line read from its file
    /// (this editor's own from its text, edits and all), the word marked.
    func editor(_ view: EditorView, references places: [LSPLocation], of word: String) {
        guard let client = hosts.client(view.block.host) else { return }
        let sorted = places.sorted { ($0.path == view.path ? 0 : 1, $0.path, $0.line) < ($1.path == view.path ? 0 : 1, $1.path, $1.line) }
        var paths: [String] = []
        for p in sorted where p.path != view.path && !paths.contains(p.path) { paths.append(p.path) }
        var lines: [String: [Substring]] = [:]
        let read = DispatchGroup()
        for path in paths.prefix(200) {
            read.enter()
            client.readBytes(path: path, limit: 4 << 20) { data in
                lines[path] = data.map { String(decoding: $0, as: UTF8.self).split(separator: "\n", omittingEmptySubsequences: false) }
                read.leave()
            }
        }
        read.notify(queue: .main) { [weak self, weak view] in
            guard let self, let view else { return }
            let text = view.textView.text
            let hits = sorted.map { p -> SearchHit in
                var line = ""
                if p.path == view.path, p.line < text.lineCount { line = text.lineText(p.line) }
                else if let file = lines[p.path], p.line < file.count { line = String(file[p.line]) }
                line = line.trimmingCharacters(in: CharacterSet(charactersIn: "\r"))
                return SearchHit(path: p.path, line: p.line + 1, column: p.character + 1, text: line.count > 400 ? String(line.prefix(400)) + "…" : line)
            }
            let root = self.projectRoot(from: view.path.deletingLastPathComponent, on: view.block.host)
            let id = BlockID(host: view.block.host)
            client.append([.create(kind: .search, title: "References to “\(word)”", path: nil),
                           .search(SearchQuery(text: word, caseSensitive: true, root: root), at: client.clock.now()),
                           .hits(hits, done: true, truncated: false, error: nil)], to: .block(id))
            self.show(id, lens: .search, .besideOpener(view.placement), context: "references to “\(word)”")
        }
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
            // ⇧⌘: a file of this Mac to the system's app, as any link.
            if modifiers.isSuperset(of: [.command, .shift]), p.block.host == host.host {
                NSWorkspace.shared.open(URL(fileURLWithPath: path))
                return
            }
            if Lens.isMarkdown(path), !modifiers.contains(.command) {
                let block = hosts.textBlock(for: path, on: p.block.host)
                // Not "[[…]]": that's the mention scan's, which would take it for its own.
                hosts.link(from: p.block, to: block, kind: .opened, context: "followed in the preview")
                // Page to page in the same tile, as a browser goes — or,
                // with ⌥, the page over this one.
                if over { showOver(block, lens: .preview, over: view.placement) } else { goOn(view.placement, from: p.block, to: block, lens: .preview) }
            } else {
                open(path, from: view.placement, as: Disposition(modifiers))
            }
        } else {
            open(url.absoluteString, from: view.placement, as: Disposition(modifiers))
        }
    }
}

extension MainWindowController {
    func markdownView(_ view: MarkdownView, history direction: Int) -> Bool {
        walkTrail(view.placement, of: view.block, lens: .preview, direction)
    }
}

extension MainWindowController: WebViewDelegate {
    func webView(_ view: WebView, append events: [Event]) {
        hosts.append(events, to: .block(view.block))
    }

    func webViewBarChanged(_ view: WebView) { content.barChanged(view.placement) }

    func webView(_ view: WebView, open url: URL, over: Bool) {
        open(url.absoluteString, from: view.placement, here: true, as: over ? .over : .beside)
    }

    /// An attached host as the address bar names it: its label, without
    /// case, spaces as hyphens.
    private static func addressName(_ label: String) -> String {
        label.lowercased().replacingOccurrences(of: " ", with: "-")
    }

    /// The other hosts attached, by the name the address bar knows them by —
    /// connected or not yet (one being reached again: a port forwarded from
    /// it waits for it, rather than the name being looked up as a site's).
    private var addressHosts: [(name: String, client: HostClient)] {
        hosts.all.filter { !$0.transport.isLocal }.map { (Self.addressName(hosts.label(of: $0.host)), $0) }
    }

    func webView(_ view: WebView, hostNamed name: String) -> HostID? {
        addressHosts.first { $0.name == name.lowercased() }?.client.host
    }

    func webView(_ view: WebView, forward port: Int, on host: HostID, done: @escaping (Int?) -> Void) {
        forward(port, on: host, done: done)
    }

    /// A page on this Mac's localhost at a port forwarded from a host: by
    /// that host and its port, as it's typed.
    func webView(_ view: WebView, addressOf url: URL) -> String {
        guard let h = url.host, Self.loopbackNames.contains(h), let port = url.port else { return url.absoluteString }
        for (name, c) in addressHosts {
            if let f = c.forwards.forwards.values.first(where: { $0.local == port }) {
                var rest = url.path.isEmpty ? "/" : url.path
                if let q = url.query { rest += "?" + q }
                if let fr = url.fragment { rest += "#" + fr }
                return "\(name):\(f.remote)\(rest == "/" ? "" : rest)"
            }
        }
        return url.absoluteString
    }

    func webView(_ view: WebView, visited url: URL, title: String?, again: Bool) {
        let address = webView(view, addressOf: url)
        if again { WebHistory.shared.titled(address, title) } else { WebHistory.shared.visited(address, title: title) }
    }

    /// The address bar's completions, as Chrome's: first a page begun by
    /// what's typed (completed in the field) if there is one, then what's
    /// typed itself (the address, or a search), other pages it matches, the
    /// attached hosts (`slowbox:`, and their ports here before), and a
    /// search for it.
    func webView(_ view: WebView, suggestionsFor typed: String) -> [PillSuggestion] {
        let q = typed.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return [] }
        let plainQ = WebAddress.plain(q).lowercased()
        // The history, and pages open in tiles from before it was kept.
        var history = WebHistory.shared.matches(q, limit: 12)
        let known = Set(history.map { WebAddress.plain($0.address) })
        for b in hosts.blocks where b.kind == .web {
            guard let u = b.web?.url, let url = URL(string: u), !u.hasPrefix("file:") else { continue }
            let address = webView(view, addressOf: url), plain = WebAddress.plain(address)
            guard !known.contains(plain), !WebHistory.shared.forgotten.contains(plain), plain.lowercased().contains(plainQ) || (b.web?.title ?? "").lowercased().contains(plainQ) else { continue }
            history.append(WebHistory.Entry(address: address, title: b.web?.title ?? "", visits: 0, last: .distantPast))
        }
        func page(_ e: WebHistory.Entry, inline: Bool) -> PillSuggestion {
            let plain = WebAddress.plain(e.address)
            return PillSuggestion(fill: plain, title: plain, detail: e.title, symbol: "globe", inline: inline, commitText: e.address,
                                  remove: { WebHistory.shared.forget(e.address) })
        }
        var out: [PillSuggestion] = []
        var shown = Set<String>()
        let parsed = WebAddress.parse(q)
        if !q.contains(" "), !q.contains("://"), let i = history.firstIndex(where: { WebAddress.plain($0.address).lowercased().hasPrefix(plainQ) }) {
            let e = history.remove(at: i)
            out.append(page(e, inline: true))
            shown.insert(WebAddress.plain(e.address).lowercased())
        }
        // What's typed, as it would go — unless the page begun by it is it.
        let search = PillSuggestion(fill: q, title: q, detail: "Search DuckDuckGo", symbol: "magnifyingglass",
                                    run: { [weak view] in view?.search(q) })
        switch parsed {
        case _ where shown.contains(plainQ):
            break
        case .search:
            out.append(search)
        case let .page(address):
            out.append(PillSuggestion(fill: q, title: WebAddress.plain(address), symbol: "globe"))
        case let .hostPort(name, port, rest):
            let on = addressHosts.first { $0.name == name.lowercased() }
            out.append(PillSuggestion(fill: q, title: q, detail: on.map { "localhost:\(port)\(rest == "/" ? "" : rest) on \(hosts.label(of: $0.client.host))" } ?? "",
                                      symbol: on == nil ? "globe" : "network"))
        }
        shown.insert(WebAddress.plain(q).lowercased())
        for e in history where out.count < 6 {
            let plain = WebAddress.plain(e.address).lowercased()
            guard shown.insert(plain).inserted else { continue }
            out.append(page(e, inline: false))
        }
        // The hosts: a name begun (to type its port after), or its ports
        // forwarded before.
        for (name, c) in addressHosts {
            let label = hosts.label(of: c.host)
            if !q.contains(":"), name.hasPrefix(plainQ), shown.insert(name + ":").inserted {
                out.append(PillSuggestion(fill: name + ":", title: name + ":", detail: "a port on \(label)'s localhost", symbol: "network", fillsOnly: true))
            } else if plainQ.hasPrefix(name + ":") {
                var ports = Set(c.forwards.forwards.filter { !$0.value.hidden }.keys)
                for e in WebHistory.shared.entries.values where e.address.hasPrefix(name + ":") {
                    if let p = Int(e.address.dropFirst(name.count + 1).prefix { $0.isNumber }) { ports.insert(p) }
                }
                for p in ports.sorted() where "\(name):\(p)".hasPrefix(plainQ) && shown.insert("\(name):\(p)").inserted {
                    out.append(PillSuggestion(fill: "\(name):\(p)", title: "\(name):\(p)", detail: "localhost:\(p) on \(label)", symbol: "network"))
                }
            }
        }
        // A search for it, always on offer (last, if not first).
        if !out.contains(where: { $0.run != nil }) { out.append(search) }
        return Array(out.prefix(9))
    }
}

extension MainWindowController: SmartlogViewDelegate {
    func smartlogStart(_ view: SmartlogView) {
        guard let c = hosts.client(view.block.host), let b = hosts.block(view.block), let path = b.path else { return }
        c.propose(.smartlog(block: view.block, path: path))
    }

    /// This Mac's as the host gives it; another host's through its port,
    /// forwarded here (not listed with the forwards asked for).
    func smartlog(_ view: SmartlogView, localURL url: String, done: @escaping (URL?) -> Void) {
        guard var parts = URLComponents(string: url), let c = hosts.client(view.block.host) else { return done(nil) }
        if c.transport.isLocal { return done(parts.url) }
        guard let port = parts.port else { return done(nil) }
        c.forwards.forward(port, hidden: true) { local in
            guard let local else { return done(nil) }
            parts.host = "localhost"
            parts.port = local
            done(parts.url)
        }
    }

    func smartlog(_ view: SmartlogView, open url: URL) { NSWorkspace.shared.open(url) }

    func smartlog(_ view: SmartlogView, openFile path: String, line: Int?) {
        if let line, line > 0 {
            open(path: path, line: line, column: nil, on: view.block.host, from: view.placement, context: "\(path.lastPathComponent):\(line)")
        } else {
            open(path, from: view.placement)
        }
    }

    func smartlog(_ view: SmartlogView, revealFile path: String) {
        openDirectory((path as NSString).deletingLastPathComponent, from: view.placement, context: path.lastPathComponent)
    }
}

extension MainWindowController: DirectoryViewDelegate {
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

    func directoryView(_ view: DirectoryView, linkFor path: String, isDirectory: Bool) -> String? {
        guard let (id, _) = pathBlock(path, isDirectory: isDirectory, on: view.block.host) else { return nil }
        let title = (hosts.block(id)?.displayTitle ?? path.lastPathComponent).replacingOccurrences(of: "]", with: "\\]")
        return "[\(title)](manifold:\(id.description))"
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
            menu.addItem(ClosureMenuItem("Download", symbol: "arrow.down.circle") { [weak self] in self?.download(path, isDirectory: isDirectory, on: on) })
        }
        menu.addItem(ClosureMenuItem("Copy Path", symbol: "doc.on.clipboard") {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(path, forType: .string)
        })
        return menu
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
    func download(_ path: String, isDirectory: Bool, on h: HostID) {
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
        open(target, from: view.placement, as: Self.commandClick(over: false))
    }

    func notebook(_ view: NotebookView, linkedFrom block: BlockID) { link(block, to: view.block) }

    /// A cell's output as an output block, as a terminal's command's is:
    /// the one made for this run of it again, if there is one.
    func notebook(_ view: NotebookView, openOutput cell: NotebookCell) {
        guard let client = hosts.client(view.block.host) else { return }
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
        if let s = sides {
            for (rev, label) in [(s.new, "Open This Version"), (s.old, "Open the Version Before")] {
                guard let rev else { continue }
                menu.addItem(ClosureMenuItem(label, symbol: "clock.arrow.circlepath") { [weak self] in
                    self?.showRevision(path, repo: s.repo, revision: rev, from: view)
                })
            }
            if let old = s.old, !(subject.isSides) {
                menu.addItem(ClosureMenuItem("This File's Changes Alone", symbol: "plusminus") { [weak self] in
                    guard let self, let client = self.hosts.client(view.block.host) else { return }
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
        guard let client = hosts.client(view.block.host) else { return NSSound.beep() }
        client.propose(.showRevision(block: id, repo: repo, path: path, revision: revision, title: title)) { [weak self] error in
            guard let self else { return }
            if let error { return self.toast.show(error, action: "OK", for: 6) {} }
            self.showWhenMade(id, lens: .output, place: .besideOpener(view.placement), context: "version \(short)", what: "that version")
        }
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
        open(target, from: view.placement, as: Self.commandClick(over: over))
    }

    /// A terminal's link click, ⌘ being what makes it one: beside, ⌥⌘
    /// over, ⇧⌘ the system's app — read off the click if it's in hand.
    static func commandClick(over: Bool) -> Disposition {
        if let d = disposition, d != .goTo { return d }
        return over ? .over : .beside
    }

    /// A ⌘-clicked word that isn't a link to ghostty or to the terminal's
    /// reading of its screen (which takes the names it shows, looked for on
    /// their host): a folder by that name where the terminal is opens as a
    /// listing; anything else, nothing. On another host, nothing.
    func terminal(_ view: TerminalView, openFolder name: String, over: Bool) {
        let word = name.trimmingCharacters(in: CharacterSet(charactersIn: "'\"`,;"))
        guard !word.isEmpty, view.block.host == host.host else { return }
        var path = (word as NSString).expandingTildeInPath
        if !path.hasPrefix("/"), let base = hosts.block(view.block)?.terminal?.cwd { path = (base as NSString).appendingPathComponent(path) }
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDir), isDir.boolValue else { return }
        open(word, from: view.placement, as: Self.commandClick(over: over))
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
        let (id, made) = outputBlock(of: command, in: view.block, output: output)
        let context = "command \(command.id)"
        if made { return show(id, lens: .output, place, kind: .opened, context: context) }
        // Shown once the host has made it (a moment).
        showWhenMade(id, lens: .output, place: place, context: context, what: "the command's output")
    }

    func terminal(_ view: TerminalView, blockFor command: ShellCommand, output: String) -> BlockID {
        if hosts.block(view.block)?.terminal?.turns?.contains(where: { $0.id == command.id }) == true {
            return turnBlock(command.id, of: view.block).id
        }
        return outputBlock(of: command, in: view.block, output: output).id
    }

    /// The block of a command's output, made by the host if there's none.
    func outputBlockID(of command: ShellCommand, in terminal: BlockID) -> BlockID {
        outputBlock(of: command, in: terminal, output: "").id
    }

    /// A command's output as a block (§3.8): the one made before, else one
    /// the host is asked to make now (`made` false: not here yet).
    private func outputBlock(of command: ShellCommand, in terminal: BlockID, output: String) -> (id: BlockID, made: Bool) {
        let context = "command \(command.id)"
        if let made = hosts.neighborhood(of: terminal).outbound[.link(.opened)]?.first(where: { $0.context == context && hosts.block($0.to)?.kind == .output }) {
            return (made.to, true)
        }
        let id = BlockID(host: terminal.host)
        hosts.propose(.captureOutput(block: id, terminal: terminal, command: command.id, fallback: output))
        return (id, false)
    }

    /// An agent's turn as its own block: the one made before, else one the
    /// host makes now; either brought up to date.
    private func turnBlock(_ turn: Int, of agent: BlockID) -> (id: BlockID, made: Bool) {
        let context = "turn \(turn)"
        let made = hosts.neighborhood(of: agent).outbound[.link(.opened)]?.first(where: { $0.context == context && hosts.block($0.to)?.kind == .output })?.to
        let id = made ?? BlockID(host: agent.host)
        hosts.propose(.captureTurn(block: id, agent: agent, turn: turn))
        return (id, made != nil)
    }

    /// An agent's turn as its own block (§3.8): the one made before, brought
    /// up to date, else one the host makes now.
    func showTurn(_ turn: Int, of agent: BlockID, place: Where) {
        let context = "turn \(turn)"
        let (id, made) = turnBlock(turn, of: agent)
        if made { return show(id, lens: .output, place, kind: .opened, context: context) }
        showTurnWhenMade(id, place: place, context: context)
    }

    /// `context`: the link the host made for it ("turn N"), said again —
    /// a link of another context would take its place, and the turn's
    /// block then not be found to show again.
    private func showTurnWhenMade(_ id: BlockID, place: Where, context: String) {
        whenMade(id, what: "the turn", made: { [weak self] in self?.hosts.block(id)?.output?.markdown != nil }) { [weak self] in
            self?.show(id, lens: .output, place, kind: .opened, context: context)
        }
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
    func showWhenMade(_ id: BlockID, lens: Lens, place: Where, context: String? = nil, what: String = "it") {
        whenMade(id, what: what, made: { [weak self] in self?.hosts.block(id) != nil }) { [weak self] in
            self?.show(id, lens: lens, place, kind: .opened, context: context)
        }
    }

    /// Something a host is making for a click (a command's output, a turn,
    /// a notebook): done once it's made. A moment in, a word at the foot
    /// of the window says what's awaited, and from where, so the click
    /// isn't taken for nothing; after half a minute it's given up, saying so.
    /// `then` once `made` holds — looked at with each change that comes
    /// (the host's reply is one), not every 50 ms; past half a second it's
    /// said what's awaited, past 30 that it didn't come.
    func whenMade(_ id: BlockID, what: String, made: @escaping () -> Bool, then: @escaping () -> Void) {
        if made() { return then() }
        madeWaits.append(MadeWait(id: id, what: what, made: made, then: then, started: Date()))
        checkMadeWaits()
    }


    /// The waits whose blocks have come, done; the rest said, or given up.
    private func checkMadeWaits() {
        guard !madeWaits.isEmpty else { madeWaitTimer?.invalidate(); madeWaitTimer = nil; return }
        var still: [MadeWait] = []
        for var w in madeWaits {
            if w.made() {
                if w.said { toast.hide() }
                w.then()
                continue
            }
            let waited = Date().timeIntervalSince(w.started)
            let host = hosts.label(of: w.id.host)
            if waited > 30 {
                toast.show("\(host) didn't make \(w.what) in time", action: "OK", for: 8) {}
                continue
            }
            if !w.said, waited > 0.5 {
                w.said = true
                toast.show("Getting \(w.what) from \(host)…", action: "", for: 31) {}
            }
            still.append(w)
        }
        madeWaits = still
        if madeWaits.isEmpty {
            madeWaitTimer?.invalidate()
            madeWaitTimer = nil
        } else if madeWaitTimer == nil {
            // For what's said, and giving up: the blocks come with changes.
            madeWaitTimer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in self?.checkMadeWaits() }
        }
    }

    func terminal(_ view: TerminalView, menuFor command: ShellCommand) -> NSMenu? {
        let menu = NSMenu()
        let linkItem = ClosureMenuItem("Copy Link to This \(hosts.block(view.block)?.terminal?.turns?.contains(where: { $0.id == command.id }) == true ? "Turn" : "Command")", symbol: "link") { [weak self] in
            self?.copyLink(to: view.block, fragment: "command=\(command.id)")
        }
        defer { menu.addItem(.separator()); menu.addItem(linkItem) }
        if let turn = hosts.block(view.block)?.terminal?.turns?.first(where: { $0.id == command.id }) {
            for item in turnItems(turn, of: view.block, beside: view.placement) { menu.addItem(item) }
        } else {
            menu.addItem(ClosureMenuItem("Open as Block", symbol: "text.alignleft") { [weak view] in _ = view?.showOutput(ofCommand: command.id, beside: view?.placement) })
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

    /// A cursor update no view under the pointer took (one with a cursor
    /// rect, where the pointer's at its edge) stops here, the arrow: passed
    /// on, it went to the title bar over the window's top, which hands it
    /// to the view under the pointer again, and round — under the title
    /// bar (the sidebar's edge, a tile's bar), until the stack ran out.
    override func cursorUpdate(with event: NSEvent) { NSCursor.arrow.set() }

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
        let d = Disposition(modifiers)
        if let arr = node.arrangement, d == .goTo {
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
        // The one rule: plain goes to it where it is (here, if nowhere);
        // ⌘ beside the focused tile; ⌥ over it; ⇧⌘ the system's app.
        follow(block, from: arrangement?.focused, d, context: "from the sidebar")
    }

    /// Double-clicking an arrangement names it.
    func organizationActivate(_ node: OrgNode) -> Bool {
        guard let arr = node.arrangement, node.column == nil else { return false }
        rename(arr)
        return true
    }

    func organizationHover(_ node: OrgNode?, at rect: NSRect, in view: NSView) {
        // A host's row: its machine, and a remote's link, live.
        if let node, node.id.hasPrefix("host:"), let c = hosts.all.first(where: { "host:\($0.host.raw)" == node.id }), let window {
            var detail = c.isRemote ? HostDashboard.standing(c) : c.machineLatest.map { "\($0.hostname) · \($0.system)" } ?? "This Mac"
            if c.watching, !c.isRemote { detail = "Watching: \(c.fencedBy ?? "another Manifold") took over · " + detail }
            // How long its server has been running.
            if c.isConnected, let started = c.serverStarted { detail += " · server up " + HostDashboard.duration(Date().timeIntervalSince(started)) }
            HoverCard.shared.show(key: node.id, title: hosts.label(of: c.host), detail: detail, body: "", font: nil,
                                  lend: {
                                      let d = HostDashboard(client: c)
                                      return HoverCard.LiveLoan(view: d, size: d.size, width: HostDashboard.width) { $0.removeFromSuperview() }
                                  },
                                  beside: rect, in: window)
            return
        }
        guard let node, let id = node.block, let window else { return HoverCard.shared.hide() }
        showBlockCard(id, beside: rect, in: window)
    }

    /// A block's card beside a rect (a sidebar row, ⌘O's list): a picture
    /// of its tile, or the block itself live, over its summary card.
    func showBlockCard(_ id: BlockID, beside rect: NSRect, in window: NSWindow, delay: TimeInterval = 0.45) {
        guard let b = hosts.block(id) else { return HoverCard.shared.hide() }
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
        // Out of sight (another space, stacked, down to its bar, or
        // nowhere): a terminal as its screen still holds it, the rest as
        // last pictured — no live view, the summary card saying the rest.
        let key = id.description
        var picture: NSImage? = nil
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
            // Out of sight: its last picture (a terminal's screen as it
            // holds it), and the summary card says the rest.
            if let t = views.values.first(where: { $0.block == id && $0 is TerminalView }) as? TerminalView,
               let image = HoverCard.surfacePicture(of: t) {
                picture = image
            } else if let kept = tilePictures[id] {
                picture = kept
            }
        }
        // Under it, the block in a few lines, as a stack's column has it
        // (an arrangement, which has none, as it was).
        let summary = b.kind == .arrangement ? nil : cardContent(for: id)
        HoverCard.shared.show(key: key, title: b.displayTitle, detail: detail, body: body, font: font, picture: picture,
                              summary: summary, beside: rect, in: window, delay: delay)
    }

    /// `evenHidden`: in a grid kept hidden (a workspace just left), which
    /// still draws as it did.
    func rememberPicture(of view: PaneContent, evenHidden: Bool = false) {
        switch view {
        case let w as WebView:
            w.snapshot { [weak self] image in if let image { self?.tilePictures[view.block] = image } }
        case let m as MarkdownView:
            m.snapshot { [weak self] image in if let image { self?.tilePictures[view.block] = image } }
        default:
            if let image = HoverCard.picture(of: view, evenHidden: evenHidden) { tilePictures[view.block] = image }
        }
        // Kept for the blocks still about.
        if tilePictures.count > 200 { tilePictures = tilePictures.filter { hosts.block($0.key) != nil } }
    }

    func organizationMenu(for node: OrgNode) -> NSMenu? {
        let menu = NSMenu()
        if node.id.hasPrefix("host:"), let c = hosts.all.first(where: { "host:\($0.host.raw)" == node.id }), c.watching {
            menu.addItem(ClosureMenuItem("Take Over", symbol: "hand.raised") { [weak self] in self?.takeOver(c) })
            menu.addItem(.separator())
        }
        if node.id.hasPrefix("host:"), let c = hosts.all.first(where: { "host:\($0.host.raw)" == node.id }), !c.isRemote {
            for item in hostItems(c.host, ownRow: true) { menu.addItem(item) }
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
            let there = ClosureMenuItem("New Space on \(hosts.label(of: c.host))", symbol: "plus.rectangle.on.rectangle") { [weak self] in
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
            for item in hostItems(c.host, ownRow: true) { menu.addItem(item) }
            menu.addItem(ClosureMenuItem("Detach from \(hosts.label(of: c.host))…", symbol: "xmark") { [weak self] in
                self?.detach(c.host)
            })
            return menu
        }
        if let arr = node.arrangement, node.column == nil {
            menu.addItem(ClosureMenuItem("Name…", symbol: "pencil") { [weak self] in self?.rename(arr) })
            menu.addItem(.separator())
            menu.addItem(ClosureMenuItem("Remove Space", symbol: "xmark") { [weak self] in self?.removeFromDesk(arr) })
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
        if let arr = node.arrangement, node.style == .row {
            let on = isPinned(id, in: arr)
            menu.addItem(ClosureMenuItem(on ? "Unpin" : "Pin in Space", symbol: on ? "pin.slash" : "pin") { [weak self] in
                self?.setPinned(id, in: arr, !on)
            })
            menu.addItem(.separator())
        }
        if hosts.block(id)?.statusRecord != nil {
            menu.addItem(ClosureMenuItem("Clear Status", symbol: "eraser") { [weak self] in self?.hosts.propose(.clearStatus(id)) })
            menu.addItem(.separator())
        }
        if let arr = node.arrangement, let p = node.placement {
            menu.addItem(ClosureMenuItem("Close Tile", symbol: "xmark") { [weak self] in self?.closeTile(p, in: arr) })
            menu.addItem(.separator())
        } else {
            menu.addItem(ClosureMenuItem("Go To", symbol: "arrow.right.circle") { [weak self] in self?.organizationOpen(node, modifiers: []) })
            menu.addItem(ClosureMenuItem("Show Beside", symbol: "rectangle.split.2x1") { [weak self] in self?.organizationOpen(node, modifiers: [.command]) })
            menu.addItem(ClosureMenuItem("Show Over", symbol: "square.stack") { [weak self] in self?.organizationOpen(node, modifiers: [.option]) })
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

    func organizationOpen(files: [String], in workspace: BlockID) {
        if selected != workspace { hosts.select(workspace) }
        render()
        let column = max((arrangement?.columns.count ?? 1) - 1, 0)
        gridOpenFiles(files, column: column, at: Int.max, newColumn: false)
    }

    func organizationPathItem(for block: BlockID, modifiers: NSEvent.ModifierFlags) -> NSPasteboardItem? {
        pathDragItem(for: block, linkOnly: modifiers.contains(.option))
    }
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
        case .inactive, .connecting, .offline, .quiet, .watching: self = .inactive
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

/// A block's text as Search reads it: its lines as written, and lowercased
/// bytes with where each line begins — looked through with memmem, not a
/// line at a time.
final class SearchText {
    let key: String
    let lines: [Substring]
    private let bytes: [UInt8]
    private let lineStarts: [Int]

    init(key: String, text: String) {
        self.key = key
        lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        bytes = Array(text.lowercased().utf8)
        var starts = [0]
        for (i, c) in bytes.enumerated() where c == 0x0A { starts.append(i + 1) }
        lineStarts = starts
    }

    /// The lines (from 1) `q` (lowercased) is in, the first `limit`.
    func lines(matching q: [UInt8], limit: Int) -> [Int] {
        guard !q.isEmpty, bytes.count >= q.count else { return [] }
        var out: [Int] = []
        bytes.withUnsafeBytes { hay in
            q.withUnsafeBytes { needle in
                guard let base = hay.baseAddress, let n = needle.baseAddress else { return }
                var at = 0
                while out.count < limit, at <= bytes.count - q.count,
                      let p = memmem(base + at, bytes.count - at, n, q.count) {
                    let offset = base.distance(to: UnsafeRawPointer(p))
                    // Its line: the last start at or before it.
                    var lo = 0, hi = lineStarts.count - 1
                    while lo < hi {
                        let mid = (lo + hi + 1) / 2
                        if lineStarts[mid] <= offset { lo = mid } else { hi = mid - 1 }
                    }
                    if lo < lines.count { out.append(lo + 1) }
                    // On from the next line: a line is a hit once.
                    at = lo + 1 < lineStarts.count ? lineStarts[lo + 1] : bytes.count
                }
            }
        }
        return out
    }
}

/// A block's own menu's Pin in Workspace (a terminal's, an editor's): for
/// its tile, named Unpin when it's pinned (`validateMenuItem`).
enum PinMenu {
    static func item(for placement: PlacementID) -> NSMenuItem {
        let item = NSMenuItem(title: "Pin in Space", action: #selector(MainWindowController.togglePinInWorkspace(_:)), keyEquivalent: "t")
        item.keyEquivalentModifierMask = [.command, .control]
        item.representedObject = placement
        return item
    }
}

extension MainWindowController: PanelViewDelegate {
    func panel(_ view: PanelView, event: [String: Any], changed: [String: String], run: String?) {
        maniDesk.panelEvent(view.block, event: event, changed: changed, run: run)
    }
}
