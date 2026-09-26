import AppKit
import ManifoldCore

/// The window: a tab's panes filling it, the sidebar floating over its left
/// edge when the mouse goes there (or docked, when pinned), and the palette.
final class MainWindowController: NSWindowController, NSWindowDelegate {
    private let server: ServerClient
    private let root = RootView()
    private let content = TabContentView()
    private let sidebar = SidebarView()
    private var palette: CommandPaletteView?
    private var terminals: [UUID: TerminalView] = [:]
    /// Panes whose terminal just closed; they get a new one after a moment
    /// if they're still around (i.e. the server was restarted, not the shell
    /// ended).
    private var recentlyClosed: Set<UUID> = []
    private var sidebarShown = false
    private var draggingTab = false
    private var hideWork: DispatchWorkItem?
    private var saveFrameWork: DispatchWorkItem?

    /// The sidebar's width while its handle is being dragged.
    private var resizingWidth: CGFloat?

    private var ws: Workspace { server.workspace }
    private var sidebarWidth: CGFloat {
        let w = resizingWidth ?? ws.window.sidebarWidth.map { CGFloat($0) } ?? Theme.sidebarWidth
        return min(max(w, Theme.sidebarWidthRange.lowerBound), Theme.sidebarWidthRange.upperBound)
    }
    private var selectedTab: Tab? { ws.tab(ws.selectedTab) }
    private var pinned: Bool { ws.window.sidebarPinned }

    init(server: ServerClient) {
        self.server = server
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
        content.delegate = self
        sidebar.isHidden = true

        if let f = server.workspace.window.frame, f.count == 4 {
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
        for name in [NSWindow.didBecomeKeyNotification, NSWindow.didResignKeyNotification,
                     NSWindow.didResizeNotification, NSWindow.didExitFullScreenNotification] {
            NotificationCenter.default.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in
                self?.layoutTrafficLights()
                DispatchQueue.main.async { self?.layoutTrafficLights() }
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

    func render() {
        guard let window else { return }
        sidebar.pinned = pinned
        sidebar.update(tabs: ws.tabs, selected: ws.selectedTab)
        if pinned && !sidebarShown { showSidebar(animated: false) }

        let live = Set(ws.allPanes.map(\.id))
        for (id, view) in terminals where !live.contains(id) {
            view.removeFromSuperview()
            view.destroy()
            terminals.removeValue(forKey: id)
        }

        if let tab = selectedTab {
            let views = tab.panes.filter { !recentlyClosed.contains($0.id) }.map { terminal(for: $0.id) }
            content.show(views, fractions: tab.fractions, focused: tab.focusedPane)
            window.title = tab.title
            if palette == nil, let focused = tab.focusedPane, let view = terminals[focused],
               window.firstResponder !== view {
                window.makeFirstResponder(view)
            }
        } else {
            content.show([], fractions: [], focused: nil)
            window.title = "Manifold"
        }
        layoutViews()

        if ws.tabs.isEmpty && server.hasState {
            showPalette(dismissable: false)
        } else if let palette, !palette.dismissable {
            palette.dismissable = true
            hidePalette()
        }
    }

    private func terminal(for pane: UUID) -> TerminalView {
        if let t = terminals[pane] {
            // A surface can't be made while no display is awake; try again.
            if t.surface != nil || Date().timeIntervalSince(t.created) < 2 { return t }
            t.removeFromSuperview()
        }
        let t = TerminalView(pane: pane, command: ServerClient.attachCommand(pane: pane))
        t.delegate = self
        terminals[pane] = t
        return t
    }

    private func layoutViews() {
        let b = root.bounds
        let w = sidebarWidth, inset = Theme.sidebarInset
        let sidebarFrame = NSRect(x: sidebarShown ? inset : -w - 20, y: inset, width: w, height: b.height - 2 * inset)
        if sidebar.layer?.animationKeys()?.isEmpty ?? true { sidebar.frame = sidebarFrame }
        let left = pinned ? w + 2 * inset : 0
        content.frame = NSRect(x: left, y: 0, width: b.width - left, height: b.height)
        palette?.frame = b
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

    var debugFocusedTerminal: TerminalView? { focusedPane.flatMap { terminals[$0.id] } }

    func debugSidebar(show: Bool) {
        if show { showSidebar(animated: false) } else { hideWork?.cancel(); hideSidebar() }
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
        var items = [PaletteItem(symbol: "apple.terminal", title: "Open Terminal", subtitle: "Action") { [weak self] in
            self?.openTerminal()
        }]
        if selectedTab != nil {
            items.append(PaletteItem(symbol: "rectangle.split.2x1", title: "Open Terminal to the Right", subtitle: "Action") { [weak self] in
                self?.splitRight(nil)
            })
            items.append(PaletteItem(symbol: "pencil", title: "Rename Tab", subtitle: "Action") { [weak self] in
                self?.renameTab(nil)
            })
        }
        for tab in ws.tabs {
            let pane = tab.panes.first { $0.id == tab.focusedPane } ?? tab.panes.first
            let place = pane?.cwd.map { "Terminal in \(Self.abbreviate($0))" } ?? "Terminal"
            let id = tab.id
            items.append(PaletteItem(symbol: tab.isSplit ? "rectangle.split.2x1" : "apple.terminal",
                                     title: tab.title, subtitle: place) { [weak self] in
                self?.server.send(.selectTab(id))
            })
        }
        return items
    }

    static func abbreviate(_ path: String) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        if path == home { return "~" }
        if path.hasPrefix(home + "/") { return "~" + path.dropFirst(home.count) }
        return path
    }

    // MARK: Commands

    private var focusedPane: Pane? {
        guard let tab = selectedTab else { return nil }
        return tab.panes.first { $0.id == tab.focusedPane } ?? tab.panes.first
    }

    private func openTerminal() {
        server.send(.newTab(tab: UUID(), pane: UUID(), kind: .terminal, cwd: focusedPane?.cwd, after: ws.selectedTab))
    }

    @objc func newTab(_ sender: Any?) { showPalette() }

    @objc func newTerminal(_ sender: Any?) { openTerminal() }

    @objc func splitRight(_ sender: Any?) {
        guard let tab = selectedTab else { return openTerminal() }
        let i = tab.panes.firstIndex { $0.id == tab.focusedPane } ?? tab.panes.count - 1
        server.send(.newPane(pane: UUID(), tab: tab.id, at: i + 1, kind: .terminal, cwd: focusedPane?.cwd))
    }

    @objc func closePaneOrTab(_ sender: Any?) {
        if palette != nil, palette?.dismissable == true { return hidePalette() }
        guard let tab = selectedTab else { return }
        if tab.isSplit, let pane = tab.focusedPane {
            server.send(.closePane(pane))
        } else {
            server.send(.closeTab(tab.id))
        }
    }

    @objc func closeTab(_ sender: Any?) {
        if let tab = selectedTab { server.send(.closeTab(tab.id)) }
    }

    @objc func renameTab(_ sender: Any?) {
        if let tab = selectedTab { rename(tab.id) }
    }

    @objc func unsplitTab(_ sender: Any?) {
        if let tab = selectedTab, tab.isSplit { server.send(.unsplit(tab.id)) }
    }

    @objc func movePaneToNewTab(_ sender: Any?) {
        if let tab = selectedTab, tab.isSplit, let pane = tab.focusedPane {
            server.send(.detachPane(pane, newTab: UUID()))
        }
    }

    @objc func togglePinnedSidebar(_ sender: Any?) { sidebarTogglePinned() }

    @objc func setContrastCorrection(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let mode = ContrastCorrection(rawValue: raw) else { return }
        server.send(.setAppearance(Appearance(contrastCorrection: mode)))
    }

    @objc func validateMenuItem(_ item: NSMenuItem) -> Bool {
        switch item.action {
        case #selector(setContrastCorrection(_:)):
            item.state = (item.representedObject as? String) == ws.appearance.contrastCorrection.rawValue ? .on : .off
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
        guard !ws.tabs.isEmpty else { return }
        let i = ws.selectedTab.flatMap(ws.tabIndex) ?? 0
        server.send(.selectTab(ws.tabs[(i + d + ws.tabs.count) % ws.tabs.count].id))
    }

    @objc func selectTabByNumber(_ sender: NSMenuItem) {
        guard !ws.tabs.isEmpty else { return }
        let n = sender.tag
        let i = n == 9 ? ws.tabs.count - 1 : n - 1
        if i < ws.tabs.count { server.send(.selectTab(ws.tabs[i].id)) }
    }

    @objc func nextPane(_ sender: Any?) { stepPane(1) }
    @objc func previousPane(_ sender: Any?) { stepPane(-1) }

    private func stepPane(_ d: Int) {
        guard let tab = selectedTab, tab.isSplit else { return }
        let i = tab.panes.firstIndex { $0.id == tab.focusedPane } ?? 0
        server.send(.focusPane(tab.panes[(i + d + tab.panes.count) % tab.panes.count].id))
    }

    @objc func stopServer(_ sender: Any?) {
        let alert = NSAlert()
        alert.messageText = "Quit and end all sessions?"
        alert.informativeText = "Every shell in Manifold will be closed. Your tabs are kept, and start fresh shells next time."
        alert.addButton(withTitle: "End Sessions and Quit")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        ServerClient.stopServer()
        NSApp.terminate(nil)
    }

    private func rename(_ id: UUID) {
        guard let window, let tab = ws.tab(id) else { return }
        let alert = NSAlert()
        alert.messageText = "Rename Tab"
        alert.informativeText = "Enter a custom title for this tab."
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 240, height: 24))
        field.stringValue = tab.customTitle ?? tab.title
        alert.accessoryView = field
        alert.addButton(withTitle: "Rename")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field
        alert.beginSheetModal(for: window) { [weak self] response in
            guard let self else { return }
            if response == .alertFirstButtonReturn {
                self.server.send(.renameTab(id, title: field.stringValue))
            }
            self.render()
        }
    }

    // MARK: Window

    func windowDidMove(_ notification: Notification) { saveFrame() }
    func windowDidResize(_ notification: Notification) { saveFrame() }

    private func saveFrame() {
        saveFrameWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, let f = self.window?.frame else { return }
            var state = self.ws.window
            state.frame = [f.minX, f.minY, f.width, f.height]
            if state != self.ws.window { self.server.send(.setWindow(state)) }
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
    func sidebarSelect(_ tab: UUID) { server.send(.selectTab(tab)) }
    func sidebarClose(_ tab: UUID) { server.send(.closeTab(tab)) }
    func sidebarUnsplit(_ tab: UUID) { server.send(.unsplit(tab)) }
    func sidebarRename(_ tab: UUID) { rename(tab) }
    func sidebarMove(_ tab: UUID, to index: Int) { server.send(.moveTab(tab, to: index)) }
    func sidebarNewTab() { showPalette() }

    func sidebarTogglePinned() {
        var state = ws.window
        state.sidebarPinned.toggle()
        server.send(.setWindow(state))
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
        menu.addItem(ClosureMenuItem("Show State File in Finder") {
            NSWorkspace.shared.activateFileViewerSelecting([Paths.state])
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
        var state = ws.window
        state.sidebarWidth = Double(width)
        resizingWidth = nil
        if state != ws.window { server.send(.setWindow(state)) }
        layoutViews()
        if let window {
            mouseMoved(to: root.convert(window.mouseLocationOutsideOfEventStream, from: nil))
        }
    }

    func sidebarDragChanged(_ dragging: Bool) {
        draggingTab = dragging
        if !dragging { scheduleHide() }
    }
}

extension MainWindowController: TabContentDelegate {
    func contentCanDrop(_ tab: UUID) -> Bool { tab != ws.selectedTab }

    func contentDrop(_ tab: UUID, at index: Int) {
        if let target = ws.selectedTab {
            server.send(.mergeTab(tab, into: target, at: index))
        } else {
            server.send(.selectTab(tab))
        }
    }

    func contentResized(_ fractions: [Double]) {
        if let tab = ws.selectedTab { server.send(.setFractions(tab, fractions)) }
    }
}

extension MainWindowController: TerminalViewDelegate {
    func terminalDidFocus(_ view: TerminalView) {
        guard let tab = ws.tabContaining(pane: view.pane), tab.focusedPane != view.pane else { return }
        server.send(.focusPane(view.pane))
    }

    func terminalDidClose(_ view: TerminalView) {
        guard terminals[view.pane] === view else { return }
        terminals.removeValue(forKey: view.pane)
        view.removeFromSuperview()
        recentlyClosed.insert(view.pane)
        render()
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
            self?.recentlyClosed.remove(view.pane)
            self?.render()
        }
    }
}

final class MainWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
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
