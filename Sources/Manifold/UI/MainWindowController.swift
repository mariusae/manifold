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
    private var views: [UUID: PaneContent] = [:]
    /// A place to go in a file being opened: done once its editor is shown.
    private var pendingJump: (path: String, line: Int, column: Int?)?
    private var clickMonitor: Any?
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
        content.paneInfo = { [weak self] id in self?.ws.pane(id) }
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
        watchClicks()
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
        if pinned && !sidebarShown { showSidebar(animated: false) }

        let live = Set(ws.allPanes.map(\.id))
        for (id, view) in views where !live.contains(id) {
            view.removeFromSuperview()
            view.destroy()
            views.removeValue(forKey: id)
        }

        if let tab = selectedTab {
            let shown: [TabContentView.ColumnContent] = tab.columns.compactMap { column in
                guard let top = column.top, !recentlyClosed.contains(top.id) else { return nil }
                return .init(id: column.id, view: view(for: top), beneath: column.panes.dropLast().reversed())
            }
            content.show(shown, fractions: tab.fractions, focused: tab.focusedPane)
            window.title = tab.title
            if palette == nil, let focused = tab.focusedPane, let view = views[focused],
               !((window.firstResponder as? NSView)?.isDescendant(of: view) ?? false) {
                window.makeFirstResponder(view.focusView)
            }
        } else {
            content.show([], fractions: [], focused: nil)
            window.title = "Manifold"
        }
        if let jump = pendingJump,
           let editor = content.panes.compactMap({ $0 as? EditorView }).first(where: { $0.path == jump.path }) {
            pendingJump = nil
            editor.select(line: jump.line, column: jump.column)
        }

        // After the panes' views, which know whether they've unsaved changes.
        sidebar.update(tabs: ws.tabs, selected: ws.selectedTab, edited: editedTabs)
        layoutViews()

        if ws.tabs.isEmpty && server.hasState {
            showPalette(dismissable: false)
        } else if let palette, !palette.dismissable {
            palette.dismissable = true
            hidePalette()
        }
    }

    private func view(for pane: Pane) -> PaneContent {
        if let v = views[pane.id] {
            if let m = v as? MarkdownView, let path = pane.path { m.show(path: path) }
            if let e = v as? EditorView { e.font = ws.appearance.editorFont }
            if !v.isDead { return v }
            v.removeFromSuperview()
            v.destroy()
        }
        let v: PaneContent
        switch pane.kind {
        case .terminal:
            let t = TerminalView(pane: pane.id, command: ServerClient.attachCommand(pane: pane.id))
            t.delegate = self
            v = t
        case .markdown:
            let m = MarkdownView(pane: pane.id, path: pane.path ?? "")
            m.delegate = self
            v = m
        case .editor:
            let e = EditorView(pane: pane.id, path: pane.path ?? "", font: ws.appearance.editorFont)
            e.delegate = self
            v = e
        }
        views[pane.id] = v
        return v
    }

    /// A click in a pane focuses it. Terminals say so themselves; the
    /// others' views (a web view, say) don't, so clicks are watched here.
    private func watchClicks() {
        clickMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
            guard let self, event.window === self.window, self.palette == nil else { return event }
            // Not clicks on the sidebar, floating over the panes.
            if self.sidebarShown && self.sidebar.frame.contains(self.root.convert(event.locationInWindow, from: nil)) {
                return event
            }
            let p = self.content.convert(event.locationInWindow, from: nil)
            if let v = self.content.panes.first(where: { $0.frame.contains(p) }), !(v is TerminalView),
               self.ws.tabContaining(pane: v.pane)?.focusedPane != v.pane {
                self.server.send(.focusPane(v.pane))
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

    func debugPeek(_ column: Int) { content.debugPeek(column) }

    var debugFocusedPane: Pane? { focusedPane }

    var debugFocusedTerminal: TerminalView? { focusedPane.flatMap { views[$0.id] as? TerminalView } }

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
        // A new terminal on this stack, in a new column, or in a new tab: the
        // same three as ⌘N, ⌘D and ⌥⌘T.
        var items: [PaletteItem] = []
        if selectedTab != nil {
            items.append(PaletteItem(symbol: "square.stack", title: "New Terminal on This Stack", subtitle: "⌘N") { [weak self] in
                self?.newSheet(nil)
            })
            items.append(PaletteItem(symbol: "rectangle.split.2x1", title: "New Terminal in a New Column", subtitle: "⌘D") { [weak self] in
                self?.splitRight(nil)
            })
        }
        items.append(PaletteItem(symbol: "apple.terminal", title: "New Terminal in a New Tab", subtitle: "⌥⌘T") { [weak self] in
            self?.openTerminal()
        })
        if selectedTab != nil {
            items.append(PaletteItem(symbol: "pencil", title: "Rename Tab", subtitle: "Action") { [weak self] in
                self?.renameTab(nil)
            })
        }
        items.append(PaletteItem(symbol: "doc.text.magnifyingglass", title: "Open File…", subtitle: "⌘O") { [weak self] in
            self?.openDocument(nil)
        })
        // The file shown, the other way: edit a preview's, preview an editor's.
        if let pane = focusedPane, let path = pane.path, let column = selectedTab?.columnIndex(of: pane.id).map({ selectedTab!.columns[$0].id }) {
            if pane.kind == .markdown {
                items.append(PaletteItem(symbol: "pencil.line", title: "Edit This File", subtitle: "Action") { [weak self] in
                    self?.server.send(.openFileOnStack(path: path, kind: .editor, pane: UUID(), column: column))
                })
            } else if pane.kind == .editor, Self.isMarkdown(path) {
                items.append(PaletteItem(symbol: "doc.richtext", title: "Preview This File", subtitle: "Action") { [weak self] in
                    self?.server.send(.openFileOnStack(path: path, kind: .markdown, pane: UUID(), column: column))
                })
            }
        }
        for tab in ws.tabs {
            let pane = tab.focused
            let place: String
            switch pane?.kind {
            case .markdown?:
                place = pane?.path.map { "Markdown in \(Self.abbreviate(($0 as NSString).deletingLastPathComponent))" } ?? "Markdown"
            case .editor?:
                place = pane?.path.map { "Editing in \(Self.abbreviate(($0 as NSString).deletingLastPathComponent))" } ?? "Editing"
            default:
                place = pane?.cwd.map { "Terminal in \(Self.abbreviate($0))" } ?? "Terminal"
            }
            let id = tab.id
            items.append(PaletteItem(symbol: tab.isSplit ? "rectangle.split.2x1" : Theme.symbolName(for: pane?.kind ?? .terminal),
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
        return tab.focused
    }

    private func openTerminal() {
        server.send(.newTab(tab: UUID(), pane: UUID(), kind: .terminal, cwd: focusedPane?.cwd, after: ws.selectedTab))
    }

    @objc func newTab(_ sender: Any?) { showPalette() }

    @objc func newTerminal(_ sender: Any?) { openTerminal() }

    /// A new terminal on top of the focused column's stack.
    @objc func newSheet(_ sender: Any?) {
        guard let tab = selectedTab, let focused = tab.focusedPane, let c = tab.columnIndex(of: focused) else {
            return openTerminal()
        }
        server.send(.newSheet(pane: UUID(), column: tab.columns[c].id, kind: .terminal, cwd: focusedPane?.cwd))
    }

    @objc func splitRight(_ sender: Any?) {
        guard let tab = selectedTab else { return openTerminal() }
        let i = tab.focusedPane.flatMap { tab.columnIndex(of: $0) } ?? tab.columns.count - 1
        server.send(.newPane(pane: UUID(), tab: tab.id, at: i + 1, kind: .terminal, cwd: focusedPane?.cwd))
    }

    @objc func closePaneOrTab(_ sender: Any?) {
        if palette != nil, palette?.dismissable == true { return hidePalette() }
        guard let tab = selectedTab else { return }
        // Pops the focused stack, or closes the tab when it's all there is.
        if tab.panes.count > 1, let pane = tab.focusedPane {
            confirmClosing([pane]) { [weak self] in self?.server.send(.closePane(pane)) }
        } else {
            closeTab(id: tab.id)
        }
    }

    @objc func closeTab(_ sender: Any?) {
        if let tab = selectedTab { closeTab(id: tab.id) }
    }

    private func closeTab(id: UUID) {
        guard let tab = ws.tab(id) else { return }
        confirmClosing(tab.panes.map(\.id)) { [weak self] in self?.server.send(.closeTab(id)) }
    }

    /// Asks before closing editors with unsaved changes, as a Mac app does:
    /// save them, don't, or don't close.
    private func confirmClosing(_ panes: [UUID], then close: @escaping () -> Void) {
        let edited = panes.compactMap { views[$0] as? EditorView }.filter(\.isEdited)
        guard !edited.isEmpty, let window else { return close() }
        let alert = NSAlert()
        if edited.count == 1 {
            alert.messageText = "Do you want to save the changes you made to \((edited[0].path as NSString).lastPathComponent)?"
        } else {
            alert.messageText = "Do you want to save the changes you made to \(edited.count) files?"
        }
        alert.informativeText = "Your changes will be lost if you don't save them."
        alert.addButton(withTitle: edited.count == 1 ? "Save" : "Save All")
        alert.addButton(withTitle: "Cancel")
        alert.addButton(withTitle: "Don't Save").hasDestructiveAction = true
        alert.beginSheetModal(for: window) { response in
            switch response {
            case .alertFirstButtonReturn:
                edited.forEach { $0.saveDocument(nil) }
                if edited.allSatisfy({ !$0.isEdited }) { close() }
            case .alertThirdButtonReturn:
                close()
            default:
                break
            }
        }
    }

    @objc func renameTab(_ sender: Any?) {
        if let tab = selectedTab { rename(tab.id) }
    }

    @objc func unsplitTab(_ sender: Any?) {
        if let tab = selectedTab, tab.isSplit { server.send(.unsplit(tab.id)) }
    }

    @objc func movePaneToNewTab(_ sender: Any?) {
        if let tab = selectedTab, tab.panes.count > 1, let pane = tab.focusedPane {
            let index = ws.tabIndex(tab.id).map { $0 + 1 } ?? ws.tabs.count
            server.send(.movePane(pane, to: .newTab(tab: UUID(), index: index)))
        }
    }

    @objc func togglePinnedSidebar(_ sender: Any?) { sidebarTogglePinned() }

    @objc func setEditorFont(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let font = EditorFont(rawValue: raw) else { return }
        var appearance = ws.appearance
        appearance.editorFont = font
        server.send(.setAppearance(appearance))
    }

    @objc func setContrastCorrection(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let mode = ContrastCorrection(rawValue: raw) else { return }
        server.send(.setAppearance(Appearance(contrastCorrection: mode)))
    }

    @objc func validateMenuItem(_ item: NSMenuItem) -> Bool {
        switch item.action {
        case #selector(setEditorFont(_:)):
            item.state = (item.representedObject as? String) == ws.appearance.editorFont.rawValue ? .on : .off
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

    /// Brings the bottom of the focused column's stack to the top, so that
    /// pressing it again and again goes through the whole stack.
    @objc func cycleStack(_ sender: Any?) {
        guard let tab = selectedTab, let focused = tab.focusedPane, let c = tab.columnIndex(of: focused),
              tab.columns[c].panes.count > 1, let bottom = tab.columns[c].panes.first else { return }
        server.send(.focusPane(bottom.id))
    }

    @objc func nextPane(_ sender: Any?) { stepPane(1) }
    @objc func previousPane(_ sender: Any?) { stepPane(-1) }

    private func stepPane(_ d: Int) {
        guard let tab = selectedTab, tab.isSplit else { return }
        let visible = tab.visiblePanes
        let i = visible.firstIndex { $0.id == tab.focusedPane } ?? 0
        server.send(.focusPane(visible[(i + d + visible.count) % visible.count].id))
    }

    func debugPicker(_ query: String) -> [String] { filePicker.debugQuery(query) }

    private lazy var filePicker: FilePicker = {
        let picker = FilePicker()
        picker.onOpen = { [weak self] path in self?.edit(path) }
        return picker
    }()

    /// ⌘O: the picker, over the files where the focused pane is.
    @objc func openDocument(_ sender: Any?) {
        let root: String
        switch focusedPane?.kind {
        case .terminal?: root = focusedPane?.cwd ?? NSHomeDirectory()
        case .some: root = focusedPane?.path.map { ($0 as NSString).deletingLastPathComponent } ?? NSHomeDirectory()
        case nil: root = NSHomeDirectory()
        }
        filePicker.show(root: root, over: window)
    }

    /// Opens a file to edit: from a terminal, on the stack beside it; from
    /// a file, on its own stack; with no tab, in a tab of its own.
    func edit(_ path: String) {
        guard Self.isEditable(path) else {
            NSWorkspace.shared.open(URL(fileURLWithPath: path))
            return
        }
        guard let tab = selectedTab, let pane = focusedPane else {
            server.send(.openFile(path: path, kind: .editor, pane: UUID(), tab: UUID(), beside: nil))
            return
        }
        if pane.kind == .terminal {
            server.send(.openFile(path: path, kind: .editor, pane: UUID(), tab: UUID(), beside: pane.id))
        } else if let c = tab.columnIndex(of: pane.id) {
            server.send(.openFileOnStack(path: path, kind: .editor, pane: UUID(), column: tab.columns[c].id))
        }
    }

    static func isMarkdown(_ path: String) -> Bool {
        ["md", "markdown", "mdown", "mkd", "mdx"].contains((path as NSString).pathExtension.lowercased())
    }

    /// Text, and not too big to edit.
    static func isEditable(_ path: String) -> Bool {
        let size = (try? FileManager.default.attributesOfItem(atPath: path))?[.size] as? Int ?? 0
        return size < 32 << 20 && EditorView.isText(path)
    }

    /// Opens what a link in a pane points at: Markdown files in a preview
    /// beside the pane, anything else with the system.
    func open(_ target: String, from pane: UUID) {
        if let url = URL(string: target), let scheme = url.scheme, scheme.count > 1, scheme != "file" {
            NSWorkspace.shared.open(url)
            return
        }
        func resolve(_ text: String) -> String {
            var path = text.hasPrefix("file://") ? (URL(string: text)?.path ?? text) : text
            path = (path as NSString).expandingTildeInPath
            if !path.hasPrefix("/"), let cwd = ws.pane(pane)?.cwd {
                path = (cwd as NSString).appendingPathComponent(path)
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
            server.send(.openFile(path: base, kind: .editor, pane: UUID(), tab: UUID(), beside: pane))
            return
        }
        path = URL(fileURLWithPath: path).standardizedFileURL.path
        if isDir.boolValue {
            NSWorkspace.shared.open(URL(fileURLWithPath: path))
        } else if Self.isMarkdown(path) {
            server.send(.openFile(path: path, kind: .markdown, pane: UUID(), tab: UUID(), beside: pane))
        } else if Self.isEditable(path) {
            server.send(.openFile(path: path, kind: .editor, pane: UUID(), tab: UUID(), beside: pane))
        } else {
            NSWorkspace.shared.open(URL(fileURLWithPath: path))
        }
    }

    @objc func restartServer(_ sender: Any?) {
        let alert = NSAlert()
        alert.messageText = "Restart Manifold's server?"
        alert.informativeText = "Your tabs are kept. Each shell starts again in the same directory, under its recent output; programs running in them are ended."
        alert.addButton(withTitle: "Restart Server")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        ServerClient.stopServer()
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
    func sidebarClose(_ tab: UUID) { closeTab(id: tab) }
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

    func sidebarMovePane(_ pane: UUID, to destination: PaneDestination) {
        server.send(.movePane(pane, to: destination))
    }

    func sidebarDragChanged(_ dragging: Bool) {
        draggingTab = dragging
        if !dragging { scheduleHide() }
    }
}

extension MainWindowController: TabContentDelegate {
    func contentCanDrop(_ tab: UUID) -> Bool { tab != ws.selectedTab }

    func contentDrop(_ tab: UUID, on target: TabContentView.DropTarget) {
        guard let selected = ws.selectedTab else { return server.send(.selectTab(tab)) }
        switch target {
        case .column(let index): server.send(.mergeTab(tab, into: selected, at: index))
        case .stack(let column): server.send(.stackTab(tab, onto: column))
        }
    }

    func contentRaise(_ pane: UUID) {
        server.send(.focusPane(pane))
    }

    func contentMovePane(_ pane: UUID, to target: TabContentView.DropTarget) {
        guard let tab = ws.selectedTab else { return }
        switch target {
        case .column(let index): server.send(.movePane(pane, to: .column(tab: tab, index: index)))
        case .stack(let column): server.send(.movePane(pane, to: .stack(column: column)))
        }
    }

    func contentPaneDragChanged(_ dragging: Bool) { sidebarDragChanged(dragging) }

    func contentDragAtLeftEdge() {
        if !sidebarShown { showSidebar(animated: true) }
    }

    func contentResized(_ fractions: [Double]) {
        if let tab = ws.selectedTab { server.send(.setFractions(tab, fractions)) }
    }
}

extension MainWindowController: EditorViewDelegate {
    func editorEditedChanged(_ view: EditorView) {
        render()
    }

    /// Tabs with an editor whose changes aren't saved.
    var editedTabs: Set<UUID> {
        Set(ws.tabs.filter { tab in tab.panes.contains { (views[$0.id] as? EditorView)?.isEdited == true } }.map(\.id))
    }
}

extension MainWindowController: MarkdownViewDelegate {
    func markdownView(_ view: MarkdownView, open path: String) {
        server.send(.setPanePath(view.pane, path))
    }
}

extension MainWindowController: TerminalViewDelegate {
    func terminal(_ view: TerminalView, open target: String) {
        open(target, from: view.pane)
    }

    func terminalDidFocus(_ view: TerminalView) {
        guard let tab = ws.tabContaining(pane: view.pane), tab.focusedPane != view.pane else { return }
        server.send(.focusPane(view.pane))
    }

    func terminalDidClose(_ view: TerminalView) {
        guard views[view.pane] === view else { return }
        views.removeValue(forKey: view.pane)
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
