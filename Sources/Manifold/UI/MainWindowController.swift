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
    /// The arrangement shown; and the one it replaced, while it slides away.
    private var content = ColumnsView()
    private var outgoing = ColumnsView()
    /// The arrangement `content` shows, and which way the next one to be
    /// shown slides in (1 from the right, -1 from the left), if it does.
    private var shownArrangement: BlockID?
    private var pendingSlide: CGFloat?
    private var sliding = false
    /// ⌃⇥'s walk, while control is held: the arrangements in the order it
    /// began with, and how far along it is.
    private var walk: (ids: [BlockID], index: Int)?
    private var walkMonitors: [Any] = []
    private let sidebar = SidebarView()
    private var palette: CommandPaletteView?
    /// Each placement's view, for every arrangement on the desk.
    private var views: [PlacementID: PaneContent] = [:]
    private var seenTimer: Timer?
    private var lastSeenSent = Date.distantPast
    private var lastSeenSet: Set<BlockID> = []

    /// A place to go in a file being opened: done once its editor is shown.
    private var pendingJump: (path: String, line: Int, column: Int?)?
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
        let w = resizingWidth ?? desk.window.sidebarWidth.map { CGFloat($0) } ?? Theme.sidebarWidth
        return min(max(w, Theme.sidebarWidthRange.lowerBound), Theme.sidebarWidthRange.upperBound)
    }
    private var selected: BlockID? { desk.selected }
    private var arrangement: ArrangementState? { hosts.arrangement(selected) }
    private var pinned: Bool { desk.window.sidebarPinned }

    init(hosts: Hosts) {
        self.hosts = hosts
        let window = MainWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1100, height: 720),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered, defer: false)
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.titlebarSeparatorStyle = .none
        window.backgroundColor = Theme.windowBackground
        window.isMovableByWindowBackground = false
        window.minSize = NSSize(width: 480, height: 300)
        window.tabbingMode = .disallowed
        window.isRestorable = false
        super.init(window: window)
        window.delegate = self

        root.frame = window.contentLayoutRect
        window.contentView = root
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
        for c in [content, outgoing] {
            c.delegate = self
            c.paneInfo = { [weak self] id in self?.shown(id) }
        }
        sidebar.isHidden = true

        if let f = desk.window.frame, f.count == 4 {
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
        seenTimer = Timer.scheduledTimer(withTimeInterval: 15, repeats: true) { [weak self] _ in
            self?.noteSeen(force: true)
            self?.collect()
        }
        hosts.onTerminalEnded = { [weak self] block in self?.terminalEnded(block) }
        hosts.onHistory = { [weak self] shard, base, entries in self?.historyArrived(shard, base?.state.block, entries) }
        hosts.onOpen = { [weak self] host, id, client, paths, beside, wait in
            self?.openRequest(on: host, id: id, client: client, paths: paths, beside: beside, wait: wait)
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
        for a in desk.order.compactMap({ hosts.arrangement($0) }) {
            if let p = a.placement(id) { return Shown(placement: p, block: hosts.block(p.block)) }
        }
        return nil
    }

    func render() {
        guard let window else { return }
        sidebar.pinned = pinned
        if pinned && !sidebarShown { showSidebar(animated: false) }

        // Views for placements no longer on the desk go.
        let onDesk = Set(desk.order.compactMap { hosts.arrangement($0) }.flatMap { $0.placements.map(\.id) })
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
        if walk == nil, let id = selected, desk.settled.first != id {
            hosts.append(.settled(id), to: .desk(host.host))
        }

        if let a = arrangement {
            // One block per column (§3.1): what each shows.
            let cols = a.visible.filter { !recentlyClosed.contains($0.block) }.map { p -> ColumnsView.Column in
                ColumnsView.Column(id: p.id, view: view(for: Shown(placement: p, block: hosts.block(p.block))))
            }
            content.show(cols, fractions: a.fractions, focused: a.focused)
            window.title = title(of: a)
            if palette == nil, let focused = a.focused, let view = views[focused],
               !((window.firstResponder as? NSView)?.isDescendant(of: view) ?? false), view.superview != nil {
                // Not while something is over the window with the keyboard.
                if history == nil, neighborhoodView == nil { window.makeFirstResponder(view.focusView) }
            }
            for case let t as TerminalView in views.values { t.syncFocus() }
            for case let m as MarkdownView in views.values { m.textChanged() }
            for case let e as EditorView in views.values { e.documentChanged() }
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
        noteSeen(force: false)
        noteEditing()
        checkOpenWaits()
        noteTrailFocus()
        refreshOrganization()

        if let jump = pendingJump,
           let editor = content.views.compactMap({ $0 as? EditorView }).first(where: { $0.path == jump.path }), editor.isLoaded {
            pendingJump = nil
            editor.select(line: jump.line, column: jump.column)
        }

        sidebar.update(rows: desk.order.compactMap { id -> SidebarRow? in
            guard let b = hosts.block(id), let a = b.arrangement else { return nil }
            let focused = a.focusedPlacement.flatMap { hosts.block($0.block) }
            let edited = a.placements.contains { hosts.block($0.block)?.text?.isDirty == true }
            return SidebarRow(id: id, title: title(of: a), named: a.isNamed, columnCount: a.columns.count,
                              symbol: focused.map { Theme.symbolName(for: $0.kind, path: $0.path) } ?? "rectangle.3.group",
                              edited: edited)
        }, selected: selected)
        layoutViews()

        if desk.order.isEmpty && host.hasState {
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

    private func view(for shown: Shown) -> PaneContent {
        let p = shown.placement
        if let v = views[p.id] {
            if let m = v as? MarkdownView {
                m.theme = desk.appearance.theme
                m.show(block: p.block, path: shown.path ?? "")
            }
            if let e = v as? EditorView {
                e.font = desk.appearance.editorFont
                e.theme = desk.appearance.theme
                e.undoLimit = desk.settings.undoDepth
            }
            if let d = v as? DiffView { d.theme = desk.appearance.theme }
            if !v.isDead { return v }
            v.removeFromSuperview()
            v.destroy()
        }
        let v: PaneContent
        switch p.lens {
        case .terminal, .agent:
            let t = TerminalView(placement: p.id, block: p.block, command: HostClient.attachCommand(block: p.block))
            t.delegate = self
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
            v = pv
        case .preview:
            let m = MarkdownView(placement: p.id, block: p.block, path: shown.path ?? "", theme: desk.appearance.theme)
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
            let d = DiffView(placement: p.id, block: p.block, theme: desk.appearance.theme)
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
            let e = EditorView(placement: p.id, block: p.block, path: shown.path ?? "", font: desk.appearance.editorFont,
                               theme: desk.appearance.theme)
            e.delegate = self
            v = e
        }
        if let k = v as? KeepsViewState {
            let id = p.id
            k.keeper.load = { [weak self] in
                guard let self, let b = self.shown(id)?.placement.block else { return [:] }
                return self.hosts.block(b)?.views?[id] ?? [:]
            }
            k.keeper.save = { [weak self] values in
                guard let self, let b = self.shown(id)?.placement.block else { return }
                self.hosts.append(.view(placement: id, values), to: .block(b))
            }
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
            if let v = self.content.views.first(where: { $0.frame.contains(p) }), !(v is TerminalView),
               self.arrangement?.focused != v.placement {
                self.focus(v.placement)
            }
            return event
        }
    }

    private func layoutViews() {
        let b = root.bounds
        let w = sidebarWidth, inset = Theme.sidebarInset
        let sidebarFrame = NSRect(x: sidebarShown ? inset : -w - 20, y: inset, width: w, height: b.height - 2 * inset)
        if sidebar.layer?.animationKeys()?.isEmpty ?? true { sidebar.frame = sidebarFrame }
        let left = pinned ? w + 2 * inset : 0
        content.frame = NSRect(x: left, y: 0, width: b.width - left, height: b.height)
        if sliding { outgoing.frame = content.frame }
        palette?.frame = b
        history?.frame = b
    }

    // MARK: Seen, and collection

    /// Tells the host what's on screen, so it knows what's unseen.
    /// Every file placed in an arrangement on the desk is open with its
    /// host's language server.
    private func noteEditing() {
        var ids: Set<BlockID> = []
        for id in desk.order {
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

    /// A column's past is trimmed (§4): placements unseen for a while leave
    /// unnamed arrangements, unless their blocks are held (unsaved changes,
    /// a running job); terminals stay (the host sees to their dormancy).
    /// What a column shows is never collected. An unnamed arrangement left
    /// empty leaves the desk.
    private func collect() {
        let minutes = desk.settings.collectAfterMinutes
        var order = desk.order
        for id in desk.order {
            guard let a = hosts.arrangement(id), !a.isNamed else { continue }
            if minutes > 0 {
                let cutoff = Int64(Date().addingTimeInterval(-Double(minutes) * 60).timeIntervalSince1970 * 1000)
                for p in a.placements where !a.visible.contains(where: { $0.id == p.id }) {
                    guard let block = hosts.block(p.block), block.kind != .terminal, !block.isHeld,
                          let seen = hosts.registryEntry(p.block)?.lastSeen, seen.wall < cutoff else { continue }
                    hosts.append(.remove(p.id), to: .block(id))
                }
            }
            if hosts.arrangement(id)?.isEmpty == true, id != selected {
                order.removeAll { $0 == id }
            }
        }
        if order != desk.order { hosts.append(.order(order), to: .desk(host.host)) }
    }

    /// Pretends every placement was last seen `minutes` ago, then collects.
    func debugCollect(agingBy minutes: Double) {
        collect()
    }

    @objc func setCollectAfter(_ sender: NSMenuItem) {
        var s = desk.settings
        s.collectAfterMinutes = sender.tag
        host.setSettings(s)
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
    private func terminalEnded(_ block: BlockID) {
        for id in desk.order {
            guard let a = hosts.arrangement(id) else { continue }
            for p in a.placements(of: block) { hosts.append(.remove(p.id), to: .block(id)) }
        }
        if let a = arrangement, a.isEmpty, let id = selected, !a.isNamed {
            hosts.append(.order(desk.order.filter { $0 != id }), to: .desk(host.host))
            hosts.append(.select(desk.order.first { $0 != id }), to: .desk(host.host))
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

    var debugFocusedTerminal: TerminalView? { arrangement?.focused.flatMap { views[$0] as? TerminalView } }

    func debugSidebar(show: Bool) {
        if show { showSidebar(animated: false) } else { hideWork?.cancel(); hideSidebar() }
    }

    func debugDescribe() -> String {
        var out = "selected \(selected.map(\.description) ?? "none")\n"
        if let a = arrangement {
            for (c, column) in a.columns.enumerated() {
                out += "column \(c): " + column.map { p in
                    let b = hosts.block(p.block)
                    let mark = p.id == a.focused ? "*" : (a.shown(in: c)?.id == p.id ? "!" : "")
                    return "\(p.lens.rawValue)=\(b?.displayTitle ?? "?")\(mark)"
                }.joined(separator: " | ") + "\n"
            }
        }
        out += "desk: " + desk.order.map { hosts.arrangement($0).map { title(of: $0) } ?? "?" }.joined(separator: ", ")
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
        items.append(PaletteItem(symbol: "apple.terminal", title: "New Terminal in a New Arrangement", subtitle: "⌥⌘T") { [weak self] in
            self?.newTerminal(nil)
        })
        items.append(PaletteItem(symbol: "note.text", title: "New Note", subtitle: "⇧⌘N") { [weak self] in
            self?.newNote(nil)
        })
        if arrangement != nil {
            items.append(PaletteItem(symbol: "pencil", title: "Name This Arrangement…", subtitle: "⇧⌘R") { [weak self] in
                self?.renameTab(nil)
            })
            items.append(PaletteItem(symbol: "clock.arrow.circlepath", title: "History of This Arrangement", subtitle: "⌘Y") { [weak self] in
                self?.showHistory(nil)
            })
        }
        items.append(PaletteItem(symbol: "magnifyingglass", title: "Find Anything…", subtitle: "⌘O") { [weak self] in
            self?.openDocument(nil)
        })
        for client in hosts.all where client.isRemote {
            let h = client.host
            let state = client.isConnected ? "connected" : "offline"
            items.append(PaletteItem(symbol: "server.rack", title: "New Terminal on \(h) in a New Arrangement", subtitle: state) { [weak self] in
                guard let self else { return }
                let a = self.host.newArrangement(after: self.selected)
                let t = self.hosts.newTerminal(on: h, cwd: nil)
                self.hosts.append(.place(Placement(block: t, lens: .terminal), column: 0, at: 0), to: .block(a))
            })
            items.append(PaletteItem(symbol: "server.rack", title: "Detach from \(h)", subtitle: state) { [weak self] in
                self?.hosts.detach(h)
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
        items.append(PaletteItem(symbol: "cpu", title: "Processes on \(focusedHost == host.host ? "This Mac" : focusedHost.raw)", subtitle: "Action") { [weak self] in
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
        // The file shown, the other way: edit a preview's, preview an editor's.
        if let f = focusedShown, let path = f.path, let a = arrangement, let column = a.columnIndex(of: f.id) {
            if f.lens == .preview {
                items.append(PaletteItem(symbol: "pencil.line", title: "Edit This File", subtitle: "⌥⌘P") { [weak self] in
                    self?.toggleEditPreview(nil)
                })
                items.append(PaletteItem(symbol: "pencil.line", title: "Edit This File Beside", subtitle: "⌥⇧⌘P") { [weak self] in
                    self?.editPreviewBeside(nil)
                })
            } else if f.lens == .editor, Lens.isMarkdown(path) {
                items.append(PaletteItem(symbol: "doc.richtext", title: "Preview This File", subtitle: "⌥⌘P") { [weak self] in
                    self?.toggleEditPreview(nil)
                })
                items.append(PaletteItem(symbol: "doc.richtext", title: "Preview This File Beside", subtitle: "⌥⇧⌘P") { [weak self] in
                    self?.editPreviewBeside(nil)
                })
            }
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
        for id in desk.order {
            guard let a = hosts.arrangement(id) else { continue }
            let focused = a.focusedPlacement.flatMap { hosts.block($0.block) }
            let place = focused?.place.map { $0.abbreviatingHome } ?? ""
            items.append(PaletteItem(symbol: a.columns.count > 1 ? "rectangle.split.2x1" : (focused.map { Theme.symbolName(for: $0.kind, path: $0.path) } ?? "rectangle.3.group"),
                                     title: title(of: a), subtitle: a.isNamed ? "Named · \(place)" : place) { [weak self] in
                self?.host.select(id)
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

    /// An arrangement to put things in: the selected one, or a new one.
    private func arrangementForPlacing() -> BlockID {
        if let id = selected, hosts.arrangement(id) != nil { return id }
        return host.newArrangement()
    }

    @objc func newTab(_ sender: Any?) { showPalette() }

    /// A new terminal in a new arrangement.
    @objc func newTerminal(_ sender: Any?) {
        let cwd = focusedCwd
        let a = host.newArrangement(after: selected)
        let t = hosts.newTerminal(on: focusedHost, cwd: cwd)
        hosts.append(.place(Placement(block: t, lens: .terminal), column: 0, at: 0), to: .block(a))
    }

    /// ⌘N: a new terminal beside the focused block, in a new column
    /// (§3.1), where the focused block is.
    @objc func newTerminalBeside(_ sender: Any?) {
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
    @objc func newNote(_ sender: Any?) {
        show(host.newNote(), lens: .editor, .beside)
    }

    /// ⌘W: the focused block leaves its column, which shows what it showed
    /// before (its block stays, to be found again); an unnamed arrangement
    /// left empty leaves the desk.
    @objc func closePaneOrTab(_ sender: Any?) {
        if palette != nil, palette?.dismissable == true { return hidePalette() }
        guard let a = arrangement, let id = selected else { return }
        if let f = a.focused {
            hosts.append(.remove(f), to: .block(id))
        }
        if hosts.arrangement(id)?.isEmpty == true, !a.isNamed {
            removeFromDesk(id)
        }
    }

    /// ⇧⌘W: the arrangement leaves the desk.
    @objc func closeTab(_ sender: Any?) {
        if let id = selected { removeFromDesk(id) }
    }

    private func removeFromDesk(_ id: BlockID) {
        var order = desk.order
        guard let i = order.firstIndex(of: id) else { return }
        order.remove(at: i)
        hosts.append(.order(order), to: .desk(host.host))
        if selected == id {
            hosts.append(.select(order.isEmpty ? nil : order[min(i, order.count - 1)]), to: .desk(host.host))
        }
    }

    @objc func renameTab(_ sender: Any?) {
        if let id = selected { rename(id) }
    }

    @objc func togglePinnedSidebar(_ sender: Any?) { sidebarTogglePinned() }

    @objc func setColorScheme(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let scheme = ColorScheme(rawValue: raw) else { return }
        var a = desk.appearance
        a.colorScheme = scheme
        host.setAppearance(a)
    }

    @objc func setTheme(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let theme = FontTheme(rawValue: raw) else { return }
        var a = desk.appearance
        a.theme = theme
        host.setAppearance(a)
    }

    @objc func setEditorFont(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let font = EditorFont(rawValue: raw) else { return }
        var a = desk.appearance
        a.editorFont = font
        host.setAppearance(a)
    }

    @objc func setContrastCorrection(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let mode = ContrastCorrection(rawValue: raw) else { return }
        var a = desk.appearance
        a.contrastCorrection = mode
        host.setAppearance(a)
    }

    @objc func validateMenuItem(_ item: NSMenuItem) -> Bool {
        switch item.action {
        case #selector(setCollectAfter(_:)):
            item.state = item.tag == desk.settings.collectAfterMinutes ? .on : .off
        case #selector(setTerminalDormancy(_:)):
            item.state = item.tag == desk.settings.terminalDormantAfterHours ? .on : .off
        case #selector(toggleEditPreview(_:)), #selector(editPreviewBeside(_:)):
            guard let f = focusedShown, let path = f.path else { return false }
            return f.lens == .preview || (f.lens == .editor && Lens.isMarkdown(path))
        case #selector(setTextHistory(_:)):
            item.state = item.tag == desk.settings.textHistoryDays ? .on : .off
        case #selector(setTranscriptHistory(_:)):
            item.state = item.tag == desk.settings.terminalHistoryDays ? .on : .off
        case #selector(setUndoDepth(_:)):
            item.state = item.tag == desk.settings.undoDepth ? .on : .off
        case #selector(setColorScheme(_:)):
            item.state = (item.representedObject as? String) == desk.appearance.colorScheme.rawValue ? .on : .off
        case #selector(setTheme(_:)):
            item.state = (item.representedObject as? String) == desk.appearance.theme.rawValue ? .on : .off
        case #selector(setEditorFont(_:)):
            item.state = (item.representedObject as? String) == desk.appearance.editorFont.rawValue ? .on : .off
        case #selector(setContrastCorrection(_:)):
            item.state = (item.representedObject as? String) == desk.appearance.contrastCorrection.rawValue ? .on : .off
        case #selector(togglePinnedSidebar(_:)):
            item.title = pinned ? "Hide Sidebar" : "Show Sidebar"
        case #selector(columnBack(_:)):
            return arrangement.flatMap { a in a.focusedColumn.flatMap { a.step(inColumn: $0, offset: -1) } } != nil
        case #selector(columnForward(_:)):
            return arrangement.flatMap { a in a.focusedColumn.flatMap { a.step(inColumn: $0, offset: 1) } } != nil
        default:
            break
        }
        return true
    }

    @objc func nextTab(_ sender: Any?) { stepTab(1) }
    @objc func previousTab(_ sender: Any?) { stepTab(-1) }

    private func stepTab(_ d: Int) {
        let order = desk.order
        guard !order.isEmpty else { return }
        let i = selected.flatMap { order.firstIndex(of: $0) } ?? 0
        show(arrangement: order[(i + d + order.count) % order.count], slidingFrom: CGFloat(d))
    }

    /// Selects an arrangement, which slides in from `dir`'s side over the
    /// one shown.
    private func show(arrangement id: BlockID, slidingFrom dir: CGFloat) {
        guard id != selected else { return }
        pendingSlide = dir
        host.select(id)
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
        let live = Set(desk.order)
        if walk == nil {
            guard let current = selected, desk.order.count > 1 else { return }
            var order = [current]
            for id in desk.settled + desk.order where live.contains(id) && !order.contains(id) { order.append(id) }
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
        let order = desk.order
        guard !order.isEmpty else { return }
        let n = sender.tag
        let i = n == 9 ? order.count - 1 : n - 1
        if i < order.count { host.select(order[i]) }
    }

    // MARK: A column's past (§3.1)

    /// ⌘[: what the focused column showed before this.
    @objc func columnBack(_ sender: Any?) { stepColumn(-1) }
    /// ⌘]: forward again.
    @objc func columnForward(_ sender: Any?) { stepColumn(1) }

    private func stepColumn(_ offset: Int) {
        guard let a = arrangement, let c = a.focusedColumn, let p = a.step(inColumn: c, offset: offset) else { return }
        appendToSelected([.focus(p.id)])
    }

    @objc func nextColumn(_ sender: Any?) { stepPane(1) }
    @objc func previousColumn(_ sender: Any?) { stepPane(-1) }

    private func stepPane(_ d: Int) {
        guard let a = arrangement, a.visible.count > 1 else { return }
        let visible = a.visible
        let i = visible.firstIndex { $0.id == a.focused } ?? 0
        focus(visible[(i + d + visible.count) % visible.count].id)
    }

    /// Focuses a placement of the selected arrangement (showing it, if it
    /// is in its column's past).
    func focus(_ placement: PlacementID) {
        guard let a = arrangement, a.placement(placement) != nil else { return }
        if a.focused == placement, a.visible.contains(where: { $0.id == placement }) { return }
        appendToSelected([.focus(placement)])
    }

    // MARK: Organizations (§3.6)

    private var organizationWork: DispatchWorkItem?
    /// The block the Links organization is centered on, when not the focused.
    private var linksCenter: BlockID?

    var organization: Organization {
        Organization(rawValue: desk.window.organization ?? "") ?? .desk
    }

    @objc func organizeByDesk(_ sender: Any?) { setOrganization(.desk) }
    @objc func organizeByFiles(_ sender: Any?) { setOrganization(.files) }
    @objc func organizeByLinks(_ sender: Any?) { setOrganization(.links) }
    @objc func organizeByTime(_ sender: Any?) { setOrganization(.time) }

    func setOrganization(_ org: Organization, show: Bool = true) {
        var state = desk.window
        state.organization = org.rawValue
        if state != desk.window { host.setWindow(state) }
        sidebar.setOrganization(org)
        if show, !sidebarShown { showSidebar(animated: true) }
        refreshOrganization(now: true)
    }

    /// The sidebar's tree again, a moment after the last change.
    func refreshOrganization(now: Bool = false) {
        let org = organization
        if sidebar.organization != org { sidebar.setOrganization(org) }
        guard org != .desk else { return }
        organizationWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            let filter = self.sidebar.filterText.lowercased()
            let (nodes, open) = self.organizationTree(org, filter: filter)
            self.sidebar.organizationView.show(nodes, openByDefault: open)
        }
        organizationWork = work
        if now { work.perform() } else { DispatchQueue.main.asyncAfter(deadline: .now() + 0.2, execute: work) }
    }

    private static func age(_ stamp: Stamp?) -> Double? {
        guard let stamp else { return nil }
        let hours = Date().timeIntervalSince(stamp.date) / 3600
        return min(1, max(0, (hours - 1) / 167))
    }

    private func node(for block: Block, id: String? = nil, detail: String? = nil) -> OrgNode {
        let seen = hosts.client(of: block.id)?.node.graph.seen(block.id)
        return OrgNode(id: id ?? block.id.description, block: block.id, title: block.displayTitle,
                       symbol: Theme.symbolName(for: block.kind, path: block.path), detail: detail ?? "", age: Self.age(seen))
    }

    private func matches(_ filter: String, _ texts: [String?]) -> Bool {
        filter.isEmpty || texts.contains { $0?.lowercased().contains(filter) ?? false }
    }

    /// The tree for an organization, and which rows open by themselves.
    func organizationTree(_ org: Organization, filter: String) -> ([OrgNode], Set<String>) {
        switch org {
        case .desk: return ([], [])
        case .files: return filesTree(filter)
        case .links: return linksTree(filter)
        case .time: return timeTree(filter)
        }
    }

    /// Files: each host's sparse tree, roots open.
    private func filesTree(_ filter: String) -> ([OrgNode], Set<String>) {
        var open: Set<String> = []
        func convert(_ f: FileNode) -> OrgNode? {
            let children = f.children.compactMap(convert)
            let block = f.block.flatMap { hosts.block($0) }
            if !filter.isEmpty, children.isEmpty, !matches(filter, [f.name, f.path]) { return nil }
            let id = "file:\(f.host.raw):\(f.path)"
            if f.isFolder {
                if !filter.isEmpty { open.insert(id) }
                return OrgNode(id: id, block: f.block, title: f.name, symbol: f.kind == .git ? "arrow.triangle.branch" : "folder",
                               detail: "", count: children.isEmpty ? nil : f.count, age: Self.age(f.latest), isGroup: true, children: children)
            }
            let edited = block?.text?.isDirty == true ? "edited" : ""
            return OrgNode(id: id, block: f.block, title: f.name, symbol: block.map { Theme.symbolName(for: $0.kind, path: $0.path) } ?? "doc",
                           detail: edited, age: Self.age(f.latest))
        }
        var roots: [OrgNode] = []
        let clients = hosts.all
        for c in clients {
            let home = c.transport.isLocal ? NSHomeDirectory() : nil
            let tree = c.node.graph.fileTree(host: c.host, home: home).compactMap(convert)
            if clients.count > 1 {
                let id = "host:\(c.host.raw)"
                open.insert(id)
                roots.append(OrgNode(id: id, title: c.host == host.host ? "This Mac" : c.host.raw, symbol: "desktopcomputer",
                                     count: tree.reduce(0) { $0 + ($1.count ?? 0) }, isGroup: true, children: tree))
            } else {
                roots += tree
                for r in tree { open.insert(r.id) }
            }
        }
        return (roots, open)
    }

    /// Links: around the focused block (or the one looked at), by edge kind.
    private func linksTree(_ filter: String) -> ([OrgNode], Set<String>) {
        guard let center = linksCenter ?? focusedShown?.placement.block, let b = hosts.block(center) else {
            return ([OrgNode(id: "none", title: "Nothing focused", symbol: "circle.dashed")], [])
        }
        var open: Set<String> = ["center"]
        func bunches(of block: BlockID, prefix: String) -> [OrgNode] {
            footBunches(of: block).compactMap { bunch -> OrgNode? in
                let cards = bunch.cards.filter { matches(filter, [$0.title, $0.detail]) }
                guard !cards.isEmpty else { return nil }
                let id = "\(prefix)/\(bunch.title)"
                open.insert(id)
                let children = cards.map { card -> OrgNode in
                    let cid = "\(id)/\(card.block)"
                    let node = OrgNode(id: cid, block: card.block, title: card.title, symbol: card.symbol,
                                       detail: card.detail + (card.at.map { " · " + Age.ago($0) } ?? ""), age: Self.age(card.at))
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
            for b in c.node.blocks where b.kind != .arrangement || b.arrangement?.isNamed == true {
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
            case .arrangement: "Arrangement"
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

    // MARK: Back and forward along the trail

    /// Where along the trail ⌃⌘[ has gone back to, and where it started.
    private var trailPosition: Int?
    private var trailAnchor: Int?
    private var navigatingTrail = false
    private var lastTrailFocus: PlacementID?

    /// Any other move resets the walk: the next ⌃⌘[ starts from now.
    private func noteTrailFocus() {
        let f = arrangement?.focused
        if f != lastTrailFocus {
            lastTrailFocus = f
            if !navigatingTrail { trailPosition = nil; trailAnchor = nil }
        }
    }

    /// ⌃⌘[: the block gone to before this one, by the trail (§3.5).
    @objc func goBack(_ sender: Any?) { walkTrail(-1) }
    /// ⌃⌘]: forward again, as far as where going back began.
    @objc func goForward(_ sender: Any?) { walkTrail(1) }

    private func walkTrail(_ direction: Int) {
        let g = host.node.graph
        guard g.stepCount > 0 else { return }
        let current = focusedShown?.placement.block
        if trailPosition == nil {
            trailPosition = g.stepCount - 1
            trailAnchor = trailPosition
        }
        var i = trailPosition! + direction
        let limit = direction < 0 ? 0 : (trailAnchor ?? g.stepCount - 1)
        while direction < 0 ? i >= limit : i <= limit {
            guard let step = g.step(at: i) else { return }
            if step.block != current, step.block != g.step(at: trailPosition!)?.block, hosts.block(step.block) != nil {
                trailPosition = i
                go(to: step)
                return
            }
            i += direction
        }
    }

    /// Goes to a step: its arrangement; the block's placement here, if it
    /// has one; else the block recalled beside what's focused.
    private func go(to step: Step) {
        guard let b = hosts.block(step.block) else { return }
        navigatingTrail = true
        defer { navigatingTrail = false }
        if b.kind == .arrangement {
            host.select(step.block)
        } else if let a = arrangement, let p = (step.placement.flatMap { a.placement($0) } ?? a.placements(of: step.block).first) {
            focus(p.id)
        } else {
            show(step.block, lens: Lens.default(for: b.kind, path: b.path), .here, context: "back along the trail")
        }
        render()
        lastTrailFocus = arrangement?.focused
    }

    // MARK: Finding and opening

    func debugFinder(_ query: String) -> [String] { finder.debugQuery(query) }

    private lazy var finder: Finder = {
        let f = Finder()
        f.search = { [weak self] query, files in self?.finderItems(query, files: files) ?? [] }
        return f
    }()

    /// ⌘O: the finder, over everything, and the files where the focused
    /// placement is.
    @objc func openDocument(_ sender: Any?) {
        let root = focusedCwd ?? NSHomeDirectory()
        finder.show(root: root, over: window)
    }

    private func finderItems(_ query: String, files: [String]) -> [FinderItem] {
        var scored: [(score: Int, recency: Int64, item: FinderItem)] = []
        let known = Set(hosts.blocks.filter { $0.id.host == host.host }.compactMap(\.path))
        // Context is the ranking (§3.5): what's near the focused block in
        // the graph comes first, nearest first; a match near it outranks
        // one far from it.
        let near = focusedShown.map { hosts.distances(from: $0.placement.block, limit: 3) } ?? [:]
        // When each neighbor was last joined to the focused block: the newest
        // connection ranks first among equals.
        var joinedAt: [BlockID: Int64] = [:]
        if let f = focusedShown?.placement.block {
            let n = hosts.neighborhood(of: f)
            for es in n.outbound.values { for e in es { joinedAt[e.to] = max(joinedAt[e.to] ?? 0, e.at.wall) } }
            for es in n.inbound.values { for e in es { joinedAt[e.from] = max(joinedAt[e.from] ?? 0, e.at.wall) } }
            for t in n.before + n.after { joinedAt[t.block] = max(joinedAt[t.block] ?? 0, t.last.wall) }
        }
        for block in hosts.blocks {
            guard let entry = hosts.registryEntry(block.id) else { continue }
            let remote = block.id.host != host.host ? " on \(block.id.host)" : ""
            let title = block.displayTitle
            let hay: String
            let detail: String
            var note = ""
            switch block.kind {
            case .arrangement:
                guard let a = block.arrangement, a.isNamed || !a.isEmpty else { continue }
                hay = title + " " + a.placements.compactMap { hosts.block($0.block)?.displayTitle }.joined(separator: " ")
                detail = a.isNamed ? "Arrangement · \(a.placements.count) blocks" : "Arrangement, unnamed · \(a.placements.count) blocks"
                note = desk.order.contains(block.id) ? "on the desk" : ""
            case .text:
                hay = (block.path ?? title) + " " + title
                detail = block.path.map { ($0 as NSString).deletingLastPathComponent.abbreviatingHome } ?? "Note"
                note = block.text?.isDirty == true ? "edited" : ""
            case .terminal:
                hay = title + " " + (block.terminal?.cwd ?? "")
                detail = "Terminal in \(block.terminal?.cwd?.abbreviatingHome ?? "~")"
                note = block.terminal?.dormantSince != nil && block.terminal?.pid == nil ? "dormant" : (block.terminal?.busy == true ? "running" : "")
            case .directory:
                hay = block.path ?? title
                detail = "Folder"
            case .search:
                hay = title + " " + (block.search?.query?.root ?? "")
                detail = "Search in \(block.search?.query?.root.abbreviatingHome ?? "")"
            case .image, .pdf:
                hay = block.path ?? title
                detail = block.kind == .pdf ? "PDF" : "Image"
            case .process:
                hay = "processes " + title
                detail = "Processes"
            case .agent:
                hay = "agent " + title + " " + (block.terminal?.cwd ?? "")
                detail = "Agent in \(block.terminal?.cwd?.abbreviatingHome ?? "~")"
                note = block.terminal?.pid == nil ? "ended" : ""
            case .git:
                hay = "git " + (block.path ?? title)
                detail = "Git, \(block.path?.abbreviatingHome ?? "")"
            case .diff:
                hay = "diff " + title + " " + (block.path ?? "")
                detail = "Diff, \(block.path?.deletingLastPathComponent.abbreviatingHome ?? "")"
            default:
                hay = title
                detail = block.kind.defaultTitle
            }
            var score = query.isEmpty ? 1 : (Finder.score(query, hay + " " + block.id.host.raw))
            guard score > 0 else { continue }
            if let d = near[block.id], d > 0 {
                score = query.isEmpty ? 1 + (4 - d) : score * (5 - d) / 2
                if note.isEmpty { note = d == 1 ? "linked" : "near" }
            }
            let id = block.id
            let kind = block.kind
            let path = block.path
            scored.append((score, max(entry.lastSeen.wall, joinedAt[block.id] ?? 0), FinderItem(
                symbol: Theme.symbolName(for: kind, path: path), title: title, detail: detail + remote, note: note,
                run: { [weak self] in self?.recall(id) })))
        }
        for file in files where !known.contains(file) {
            let name = (file as NSString).lastPathComponent
            let score = query.isEmpty ? 1 : Finder.score(query, file)
            guard score > 0 else { continue }
            scored.append((score, 0, FinderItem(symbol: Finder.symbol(forFile: name), title: name,
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

    /// Brings a block back: an arrangement onto the desk and selected; any
    /// other shown here, in the focused column.
    func recall(_ id: BlockID) {
        guard let block = hosts.block(id) else { return }
        if block.kind == .arrangement {
            host.select(id)
            return
        }
        show(id, lens: Lens.default(for: block.kind, path: block.path), .here)
    }

    /// Where a block goes (§3.1): the only three places anything is put.
    enum Where {
        /// In the focused column; what it showed joins its past.
        case here
        /// In a column, as `here` there.
        case inColumn(Int)
        /// A new column to the right of the focused one.
        case beside
        /// Beside the placement that opened it: in the column to its right
        /// if that column's block was opened from this one, else a new
        /// column there. Links the two.
        case besideOpener(PlacementID)
    }

    /// `besideOpener` when there is an opener, else `here`.
    private func opener(_ placement: PlacementID?) -> Where {
        placement.map { .besideOpener($0) } ?? .here
    }

    /// Shows a block in the selected arrangement, by the rules.
    func show(_ block: BlockID, lens: Lens, _ place: Where, kind: LinkKind = .opened, context: String? = nil) {
        let id = arrangementForPlacing()
        guard let a = hosts.arrangement(id) else { return }
        let fresh = { ULID.make() }
        let events: [Event]
        switch place {
        case .here:
            events = a.showing(block, lens: lens, inColumn: a.focusedColumn ?? a.columns.count, newPlacement: fresh)
        case .inColumn(let c):
            events = a.showing(block, lens: lens, inColumn: c, newPlacement: fresh)
        case .beside:
            events = a.showing(block, lens: lens, inNewColumnAt: (a.focusedColumn ?? a.columns.count - 1) + 1, newPlacement: fresh)
        case .besideOpener(let p):
            guard let c = a.columnIndex(of: p), let from = a.placement(p)?.block else {
                return show(block, lens: lens, .beside, kind: kind, context: context)
            }
            let right = c + 1
            // The column to the right is the opener's if what it shows was
            // opened from the opener (any link between them says so).
            let reuse = a.shown(in: right).map { shownRight in
                shownRight.block == from || hosts.client(of: from)?.node.graph.edges(from: from).contains { $0.to == shownRight.block } == true
            } ?? false
            events = reuse ? a.showing(block, lens: lens, inColumn: right, newPlacement: fresh)
                : a.showing(block, lens: lens, inNewColumnAt: right, newPlacement: fresh)
            hosts.link(from: from, to: block, kind: kind, context: context)
        }
        hosts.append(events, to: .block(id))
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
        var root = focusedCwd ?? NSHomeDirectory()
        if on == host.host {
            var dir = root
            while dir.count > 1 {
                if FileManager.default.fileExists(atPath: dir.appendingPathComponent(".git")) { root = dir; break }
                dir = dir.deletingLastPathComponent
            }
        }
        var text = ""
        if let tv = window?.firstResponder as? TextView {
            let selected = tv.selectedText
            if !selected.isEmpty, !selected.contains("\n") { text = selected }
        }
        guard let client = hosts.client(on) else { return }
        let block = client.newSearch(SearchQuery(text: text, root: root))
        show(block, lens: .search, .beside)
    }

    /// New Agent: a terminal running the agent command (the settings'),
    /// where the focused block is, beside it.
    @objc func newAgent(_ sender: Any?) {
        let on = focusedHost
        guard let client = hosts.client(on) else { return }
        let block = client.newAgent(cwd: focusedCwd, command: desk.settings.agentCommand)
        show(block, lens: .agent, .beside)
    }

    /// Processes: the focused block's host's process list, beside it.
    @objc func showProcesses(_ sender: Any?) {
        guard let client = hosts.client(focusedHost) else { return }
        show(client.processBlock(), lens: .process, .beside)
    }

    /// Git for This Project: the git block for the repository the focused
    /// block is in, placed beside it.
    @objc func showGit(_ sender: Any?) {
        let on = focusedHost
        guard let client = hosts.client(on) else { return }
        let path = focusedCwd ?? NSHomeDirectory()
        let block = client.gitBlock(for: path)
        show(block, lens: .git, .beside)
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
        show(block, lens: .editor, opener(from), kind: kind, context: context ?? "\(path.lastPathComponent):\(line)")
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
    @objc func toggleEditPreview(_ sender: Any?) {
        guard let f = focusedShown, let path = f.path, let a = arrangement, let (c, i) = a.locate(f.id) else { return }
        let other: Lens
        switch f.lens {
        case .preview: other = .editor
        case .editor where Lens.isMarkdown(path): other = .preview
        default: return
        }
        appendToSelected([.remove(f.id), .place(Placement(block: f.placement.block, lens: other), column: c, at: i)])
    }

    /// ⌥⇧⌘P: the other lens beside this one, both in view.
    @objc func editPreviewBeside(_ sender: Any?) {
        guard let f = focusedShown, let path = f.path else { return }
        let other: Lens
        switch f.lens {
        case .preview: other = .editor
        case .editor where Lens.isMarkdown(path): other = .preview
        default: return
        }
        show(f.placement.block, lens: other, .besideOpener(f.id), kind: .source, context: other == .editor ? "edited beside" : "previewed beside")
    }

    /// Opens what a link in a placement points at: Markdown files in a
    /// preview beside it, folders in a listing, text to edit, anything else
    /// with the system.
    func open(_ target: String, from placement: PlacementID?) {
        if let url = URL(string: target), let scheme = url.scheme, scheme.count > 1, scheme != "file" {
            if scheme == "http" || scheme == "https" {
                show(host.newWeb(url: url.absoluteString), lens: .web, opener(placement), context: target)
            } else {
                NSWorkspace.shared.open(url)
            }
            return
        }
        let base = placement.flatMap { shown($0)?.block }.flatMap { $0.terminal?.cwd ?? $0.place }
        let on = placement.flatMap { shown($0)?.placement.block.host } ?? host.host
        if on != host.host {
            // Another host's file: it says what it is.
            openRemote(target, on: on, base: base, from: placement)
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
            show(hosts.textBlock(for: base, on: on), lens: .editor, opener(placement), context: target)
            return
        }
        path = URL(fileURLWithPath: path).standardizedFileURL.path
        if isDir.boolValue {
            openDirectory(path, from: placement, context: target)
        } else if Lens.isMarkdown(path) {
            show(hosts.textBlock(for: path, on: on), lens: .preview, opener(placement), context: target)
        } else if Self.isHTML(path), on == host.host {
            show(host.webBlock(forFile: path), lens: .web, opener(placement), context: target)
        } else if Self.isEditable(path) {
            show(hosts.textBlock(for: path, on: on), lens: .editor, opener(placement), context: target)
        } else if let kind = Self.mediaKind(path), let client = hosts.client(on) {
            show(client.mediaBlock(for: path, kind: kind), lens: kind == .pdf ? .pdf : .image, opener(placement), context: target)
        } else {
            NSWorkspace.shared.open(URL(fileURLWithPath: path))
        }
    }

    /// Opens a path on another host, where it can't be looked at from
    /// here: a folder if it ends in a slash, Markdown by its name, else
    /// text; `path:line:column` as from this host.
    private func openRemote(_ target: String, on: HostID, base: String?, from: PlacementID?) {
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
            show(hosts.directoryBlock(for: String(path.dropLast()), on: on), lens: .directory, opener(from), context: target)
        } else if let kind = Self.mediaKind(path), let client = hosts.client(on) {
            show(client.mediaBlock(for: path, kind: kind), lens: kind == .pdf ? .pdf : .image, opener(from), context: target)
        } else {
            if let line { pendingJump = (path, line, column) }
            show(hosts.textBlock(for: path, on: on), lens: Lens.isMarkdown(path) ? .preview : .editor, opener(from), context: target)
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
                    for (key, state) in c.languageServerStates { out[c.host.raw + ": " + key] = state }
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

    /// Attach to Host…: a destination, as ssh takes them, or
    /// `provider:name` for a `manifold-remote-<provider>` on the PATH.
    @objc func attachToHost(_ sender: Any?) {
        guard let window else { return }
        let alert = NSAlert()
        alert.messageText = "Attach to a Host"
        alert.informativeText = "A destination ssh understands (user@host), or provider:name for a manifold-remote-<provider> on your PATH. Manifold installs its server there, in ~/.manifold/bin, if it isn't already."
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 280, height: 24))
        field.placeholderString = "user@host"
        alert.accessoryView = field
        alert.addButton(withTitle: "Attach")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field
        alert.beginSheetModal(for: window) { [weak self] response in
            guard let self, response == .alertFirstButtonReturn, let dest = Destination(field.stringValue) else { return }
            self.attach(dest)
        }
    }

    func attach(_ dest: Destination) {
        hosts.attach(dest) { [weak self] result in
            guard let self else { return }
            switch result {
            case .success(let h):
                let a = self.host.newArrangement(after: self.selected)
                let t = self.hosts.newTerminal(on: h, cwd: nil)
                self.hosts.append(.place(Placement(block: t, lens: .terminal), column: 0, at: 0), to: .block(a))
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
    private var openWaits: [(host: HostID, id: Int, client: Int, placements: [PlacementID])] = []

    /// A `manifold` command on `on` asks for paths: each goes beside the
    /// block it was run in (or on the focused stack), and with `wait`, the
    /// command is answered once they've all been put away.
    private func openRequest(on: HostID, id: Int, client: Int, paths: [String], beside: BlockID?, wait: Bool) {
        var placed: [PlacementID] = []
        // The arrangement with the block the command ran in, else the selected.
        let besidePlacement = beside.flatMap { b in
            desk.order.lazy.compactMap { self.hosts.arrangement($0)?.placements.first { $0.block == b } }.first
        }
        if let besidePlacement, let aid = desk.order.first(where: { hosts.arrangement($0)?.placement(besidePlacement.id) != nil }), aid != selected {
            host.select(aid)
        }
        for path in paths {
            let isDir = on == host.host && (try? FileManager.default.attributesOfItem(atPath: path))?[.type] as? FileAttributeType == .typeDirectory
            let media = Self.mediaKind(path)
            let html = Self.isHTML(path) && on == host.host
            let block = isDir || path.hasSuffix("/") ? hosts.directoryBlock(for: path, on: on)
                : html ? host.webBlock(forFile: path)
                : media.flatMap { kind in hosts.client(on)?.mediaBlock(for: path, kind: kind) } ?? hosts.textBlock(for: path, on: on)
            let lens: Lens = isDir || path.hasSuffix("/") ? .directory
                : html ? .web : media == .pdf ? .pdf : media == .image ? .image : (Lens.isMarkdown(path) ? .preview : .editor)
            let before = Set(arrangement?.placements.map(\.id) ?? [])
            show(block, lens: lens, besidePlacement.map { .besideOpener($0.id) } ?? .beside)
            if let a = arrangement, let p = a.placements.first(where: { $0.block == block && !before.contains($0.id) }) ?? a.placements.first(where: { $0.block == block }) {
                placed.append(p.id)
            }
        }
        if wait, !placed.isEmpty {
            openWaits.append((on, id, client, placed))
        } else {
            hosts.propose(.openDone(id: id, client: client), on: on)
        }
        NSApp.activate()
    }

    /// Answers `open --wait` commands whose placements have all gone.
    private func checkOpenWaits() {
        guard !openWaits.isEmpty else { return }
        let present = Set(desk.order.compactMap { hosts.arrangement($0) }.flatMap { $0.placements.map(\.id) })
        openWaits.removeAll { wait in
            if wait.placements.allSatisfy({ !present.contains($0) }) {
                hosts.propose(.openDone(id: wait.id, client: wait.client), on: wait.host)
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
        alert.messageText = "Name This Arrangement"
        alert.informativeText = "A named arrangement is kept as it is until you change it; an unnamed one is tidied away as its blocks go unused."
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
        h.font = desk.appearance.theme.font(desk.appearance.editorFont, size: desk.appearance.theme.editorSize(desk.appearance.editorFont))
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
        // Each column shows what it showed then, and the focus is as it was.
        for c in state.columns.indices {
            if let shown = state.shown(in: c), let id = ids[shown.id] { events.append(.focus(id)) }
        }
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
            var state = self.desk.window
            state.frame = [f.minX, f.minY, f.width, f.height]
            if state != self.desk.window { self.host.setWindow(state) }
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
    func sidebarSelect(_ arrangement: BlockID) { host.select(arrangement) }

    func sidebarOrganizationChanged(_ organization: Organization) { setOrganization(organization, show: false) }
    func sidebarFilterChanged(_ text: String) { refreshOrganization(now: true) }
    func sidebarRemove(_ arrangement: BlockID) { removeFromDesk(arrangement) }
    func sidebarRename(_ arrangement: BlockID) { rename(arrangement) }
    func sidebarNewTab() { showPalette() }

    func sidebarMove(_ arrangement: BlockID, to index: Int) {
        var order = desk.order
        guard let from = order.firstIndex(of: arrangement) else { return }
        order.remove(at: from)
        order.insert(arrangement, at: min(max(index, 0), order.count))
        hosts.append(.order(order), to: .desk(host.host))
    }

    func sidebarTogglePinned() {
        var state = desk.window
        state.sidebarPinned.toggle()
        host.setWindow(state)
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
        menu.addItem(ClosureMenuItem(pinned ? "Hide Sidebar" : "Show Sidebar") { [weak self] in self?.sidebarTogglePinned() })
        menu.addItem(.separator())
        menu.addItem(ClosureMenuItem("Show Logs in Finder") {
            NSWorkspace.shared.activateFileViewerSelecting([Paths.logs])
        })
        menu.addItem(ClosureMenuItem("End All Sessions and Quit…") { [weak self] in self?.stopServer(nil) })
        return menu
    }

    func sidebarResize(to width: CGFloat) {
        resizingWidth = min(max(width.rounded(), Theme.sidebarWidthRange.lowerBound), Theme.sidebarWidthRange.upperBound)
        hideWork?.cancel()
        layoutViews()
    }

    func sidebarResizeEnded() {
        guard let width = resizingWidth else { return }
        var state = desk.window
        state.sidebarWidth = Double(width)
        resizingWidth = nil
        if state != desk.window { host.setWindow(state) }
        layoutViews()
        if let window {
            mouseMoved(to: root.convert(window.mouseLocationOutsideOfEventStream, from: nil))
        }
    }

    func sidebarMovePlacement(_ placement: PlacementID, to destination: SidebarDrop) {
        guard let from = desk.order.first(where: { hosts.arrangement($0)?.placement(placement) != nil }),
              let p = hosts.arrangement(from)?.placement(placement) else { return }
        switch destination {
        case .arrangement(let target):
            guard target != from, let a = hosts.arrangement(target) else { return }
            hosts.append(.remove(placement), to: .block(from))
            let c = a.focused.flatMap { a.columnIndex(of: $0) } ?? max(a.columns.count - 1, 0)
            hosts.append(.place(Placement(block: p.block, lens: p.lens), column: c, at: c < a.columns.count ? a.columns[c].count : 0), to: .block(target))
            host.select(target)
        case .newArrangement(let index):
            if hosts.arrangement(from)?.placements.count == 1 { return sidebarMove(from, to: index) }
            hosts.append(.remove(placement), to: .block(from))
            let n = host.newArrangement(select: false)
            hosts.append(.place(Placement(block: p.block, lens: p.lens), column: 0, at: 0), to: .block(n))
            sidebarMove(n, to: index)
            host.select(n)
        }
    }

    func sidebarDragChanged(_ dragging: Bool) {
        draggingTab = dragging
        if !dragging { scheduleHide() }
    }
}

extension MainWindowController: ColumnsDelegate {
    func contentCanDrop(_ arrangement: BlockID) -> Bool { arrangement != selected }

    /// Another arrangement dropped on this one: its columns come over.
    func contentDrop(_ arrangement: BlockID, on target: ColumnsView.DropTarget) {
        guard let id = selected, let source = hosts.arrangement(arrangement), let a = hosts.arrangement(id) else {
            return host.select(arrangement)
        }
        hosts.append(source.placements.map { .remove($0.id) }, to: .block(arrangement))
        switch target {
        case .column(let index):
            hosts.append(.adopt(columns: source.columns, at: index), to: .block(id))
        case .into(let c):
            let placements = source.placements
            hosts.append(placements.enumerated().map { i, p in
                .place(Placement(id: p.id, block: p.block, lens: p.lens), column: c, at: a.columns[c].count + i)
            }, to: .block(id))
        }
        removeFromDesk(arrangement)
        host.select(id)
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

    func contentMovePane(_ placement: PlacementID, to target: ColumnsView.DropTarget) {
        guard let a = arrangement else { return }
        switch target {
        case .column(let index):
            movePlacement(placement, toNewColumn: index, in: a)
        case .into(let c):
            if a.columnIndex(of: placement) == c { return }
            appendToSelected([.move(placement, column: c, at: a.columns[c].count)])
        }
    }

    /// Moves a placement into a new column at `index`.
    private func movePlacement(_ placement: PlacementID, toNewColumn index: Int, in a: ArrangementState) {
        guard let (sc, _) = a.locate(placement) else { return }
        let alone = a.columns[sc].count == 1
        if alone, index == sc || index == sc + 1 { return }
        // Past the end makes a new column; then it's moved into place.
        appendToSelected([.move(placement, column: a.columns.count, at: 0)])
        guard let now = arrangement else { return }
        let from = now.columns.count - 1
        var to = index
        if alone, sc < index { to -= 1 }
        reorderColumn(from: from, to: min(to, from))
    }

    func contentPaneDragChanged(_ dragging: Bool) { sidebarDragChanged(dragging) }

    func contentDragAtLeftEdge() {
        if !sidebarShown { showSidebar(animated: true) }
    }

    func contentResized(_ fractions: [Double]) {
        appendToSelected([.fractions(fractions)])
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

    func editor(_ view: EditorView, open path: String, line: Int, column: Int) {
        let on = view.block.host
        pendingJump = (path, line, column)
        let block = hosts.textBlock(for: path, on: on)
        hosts.link(from: view.block, to: block, kind: .opened, context: view.lineAtCaret)
        // A definition is gone to here, in the editor's column: a thread
        // followed, that ⌘[ comes back along.
        if let a = arrangement, let c = a.columnIndex(of: view.placement) {
            show(block, lens: .editor, .inColumn(c))
        } else {
            show(block, lens: .editor, .here)
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
    func markdownView(_ view: MarkdownView, follow url: URL) {
        guard let a = arrangement, let p = a.placement(view.placement), let (c, _) = a.locate(view.placement) else { return }
        if url.isFileURL {
            let path = url.standardizedFileURL.path
            if Lens.isMarkdown(path) {
                let block = hosts.textBlock(for: path, on: p.block.host)
                hosts.link(from: p.block, to: block, kind: .mention, context: path.lastPathComponent)
                // Page to page, here, as a browser goes; ⌘[ comes back.
                show(block, lens: .preview, .inColumn(c))
            } else {
                open(path, from: view.placement)
            }
        } else {
            open(url.absoluteString, from: view.placement)
        }
    }
}

extension MainWindowController: WebViewDelegate {
    func webView(_ view: WebView, append events: [Event]) {
        hosts.append(events, to: .block(view.block))
    }
}

extension MainWindowController: DirectoryViewDelegate {
    func directoryView(_ view: DirectoryView, open path: String) {
        var isDir: ObjCBool = false
        FileManager.default.fileExists(atPath: path, isDirectory: &isDir)
        if isDir.boolValue {
            // A folder takes the listing's place, here; ⌘[ comes back up.
            guard let a = arrangement, let c = a.columnIndex(of: view.placement) else { return }
            show(host.directoryBlock(for: path), lens: .directory, .inColumn(c))
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
        case .versions: break
        }
        show(block, lens: .diff, .besideOpener(view.placement), context: context)
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

    func diffViewReload(_ view: DiffView) {
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
    func terminal(_ view: TerminalView, open target: String) {
        open(target, from: view.placement)
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
    func organizationOpen(_ block: BlockID, newColumn: Bool) {
        HoverCard.shared.hide()
        guard let b = hosts.block(block) else { return }
        if b.kind == .arrangement { return host.select(block) }
        show(block, lens: Lens.default(for: b.kind, path: b.path), newColumn ? .beside : .here)
        if organization == .links, linksCenter != nil { linksCenter = block; refreshOrganization(now: true) }
    }

    func organizationHover(_ node: OrgNode?, at rect: NSRect, in view: NSView) {
        guard let node, let id = node.block, let b = hosts.block(id), let window else { return HoverCard.shared.hide() }
        var detail = b.path?.deletingLastPathComponent.abbreviatingHome ?? b.kind.defaultTitle
        if let seen = hosts.client(of: id)?.node.graph.seen(id) { detail += " · " + Age.ago(seen) }
        if id.host != host.host { detail += " · on \(id.host.raw)" }
        var body = ""
        var font: NSFont? = nil
        switch b.kind {
        case .text:
            body = String(b.text?.text.string.prefix(600) ?? "").split(separator: "\n", omittingEmptySubsequences: false).prefix(8).joined(separator: "\n")
            font = desk.appearance.theme.font(desk.appearance.editorFont, size: 12)
        case .terminal, .agent:
            body = b.terminal?.cwd?.abbreviatingHome ?? ""
        case .search:
            body = b.search.map { "\($0.hits.count) hits" } ?? ""
        case .arrangement:
            body = b.arrangement.map { a in a.placements.compactMap { self.hosts.block($0.block)?.displayTitle }.joined(separator: " · ") } ?? ""
        default: break
        }
        HoverCard.shared.show(title: b.displayTitle, detail: detail, body: body, font: font, beside: rect, in: window)
    }

    func organizationMenu(for node: OrgNode) -> NSMenu? {
        guard let id = node.block else { return nil }
        let menu = NSMenu()
        menu.addItem(ClosureMenuItem("Show Here") { [weak self] in self?.organizationOpen(id, newColumn: false) })
        menu.addItem(ClosureMenuItem("Show Beside") { [weak self] in self?.organizationOpen(id, newColumn: true) })
        menu.addItem(.separator())
        menu.addItem(ClosureMenuItem("Links Around This") { [weak self] in
            self?.linksCenter = id
            self?.setOrganization(.links)
        })
        return menu
    }
}
