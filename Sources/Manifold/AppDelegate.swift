import AppKit
import ManifoldCore

final class AppDelegate: NSObject, NSApplicationDelegate {
    private let hosts = Hosts()
    private var host: HostClient { hosts.local }
    private var windowController: MainWindowController?
    private let agentMenu = LiveMenu()
    private var createdFirst = false
    private let notifier = Notifier()

    func applicationDidFinishLaunching(_ notification: Notification) {
        signal(SIGPIPE, SIG_IGN)
        CrashGuard.start()
        safeMode = CrashGuard.unfinished >= 2 && askSafeMode()
        MemoryWatch.start()
        _ = GhosttyRuntime.shared
        // After Ghostty's, so ours writes the report and then hands on to it.
        CrashGuard.armHandler()
        NSApp.mainMenu = makeMainMenu()
        AppearanceWatcher.shared.start()
        Tints.watchSystemAccent()
        // Fonts installed or taken away (Humanist's faces, a family a custom
        // role names): what's set in them set again.
        NotificationCenter.default.addObserver(forName: NSFont.fontSetChangedNotification, object: nil, queue: .main) { [weak self] _ in
            FontTheme.fontsChanged()
            MainActor.assumeIsolated { self?.windowController?.fontsChanged() }
        }
        // Agents' hooks put in when the command was `manifold`, moved over.
        DispatchQueue.global(qos: .utility).async { AgentSkill.refresh() }
        NotificationCenter.default.addObserver(forName: .manifoldAppearanceChanged, object: nil, queue: .main) {
            [weak self] _ in
            guard let self else { return }
            GhosttyRuntime.shared.apply(self.hosts.state.appearance, dark: NSApp.effectiveAppearance.isDark)
        }

        hosts.onChange = { [weak self] in self?.stateChanged() }
        host.onVersionMismatch = { [weak self] version in self?.serverIsStale(version) }
        host.connect()
        // Safe: other hosts left until asked for (one may be what crashed).
        if !safeMode { hosts.reattachRemembered() }
        hosts.watchNetwork()
        DebugControl.start { [weak self] in self?.windowController }
    }

    private func stateChanged() {
        guard host.hasState else { return }
        hosts.pushLanguageServers()
        let scheme = hosts.state.appearance.colorScheme.appearance
        if NSApp.appearance?.name != scheme?.name { NSApp.appearance = scheme }
        Tints.apply(hosts.state.appearance.tint)
        GhosttyRuntime.shared.apply(hosts.state.appearance, dark: NSApp.effectiveAppearance.isDark)
        if windowController == nil {
            let wc = MainWindowController(hosts: hosts)
            windowController = wc
            hosts.onWorkspaceChange = { [weak wc] id, before, events in wc?.noteWorkspaceChange(id, before: before, events: events) }
            // Safe: a workspace of its own shown, not the one that crashed.
            if safeMode {
                let a = host.newArrangement(title: "Safe Mode")
                hosts.select(a)
            }
            // The very first time, start with a terminal rather than an empty
            // window.
            if hosts.all.allSatisfy({ $0.desk.order.isEmpty }) && !createdFirst && host.node.blocks.isEmpty {
                createdFirst = true
                wc.newTerminal(nil)
            }
            wc.showWindow(nil)
            NSApp.activate()
            if let report = CrashGuard.lastReport {
                wc.notice("Manifold quit unexpectedly last time; a report was kept", action: "Show") {
                    NSWorkspace.shared.activateFileViewerSelecting([report])
                }
            } else if safeMode {
                wc.notice("Started safely: other hosts aren't attached, and a new workspace is shown", action: "OK") {}
            }
            if !openWhenReady.isEmpty || !linksWhenReady.isEmpty {
                let paths = openWhenReady, links = linksWhenReady
                openWhenReady = []
                linksWhenReady = []
                // Once the hosts have said what blocks there are.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                    wc.openPaths(paths)
                    links.forEach(wc.openLink)
                }
            }
        }
        windowController?.render()
        if let wc = windowController {
            notifier.inSight = { [weak wc] b in wc?.inSight(b) ?? false }
            notifier.onOpen = { [weak wc] b, command in wc?.openFromNotification(b, command: command) }
            notifier.update(hosts.blocks)
        }
    }

    var debugNotifications: String { notifier.posted.joined(separator: "\n") }

    /// Files and folders dropped on the Dock icon (or opened with
    /// Manifold): each opened in the workspace shown, as a path is — a
    /// tile of its own, or gone to where it already is. Before the window
    /// is up, once it is.
    private var openWhenReady: [String] = []

    func application(_ sender: NSApplication, open urls: [URL]) {
        // manifold: addresses, from another app: the blocks gone to.
        let links = urls.filter { $0.scheme == "manifold" }.map(\.absoluteString)
        let paths = urls.filter(\.isFileURL).map(\.path)
        guard let wc = windowController else { openWhenReady += paths; linksWhenReady += links; return }
        NSApp.activate()
        wc.window?.makeKeyAndOrderFront(nil)
        wc.openPaths(paths)
        links.forEach(wc.openLink)
    }
    private var linksWhenReady: [String] = []

    func applicationDockMenu(_ sender: NSApplication) -> NSMenu? {
        windowController?.dockMenu()
    }

    private var safeMode = false

    /// Two launches in a row ended within half a minute: start as usual,
    /// or safely — a new, empty workspace shown, other hosts not attached.
    private func askSafeMode() -> Bool {
        let alert = NSAlert()
        alert.messageText = "Manifold quit unexpectedly as it started"
        alert.informativeText = "It happened \(CrashGuard.unfinished) times in a row. Started safely, Manifold shows a new, empty workspace instead of the last one, and doesn't attach other hosts until you ask; everything is kept. Reports are in ~/Library/Logs/Manifold."
        alert.addButton(withTitle: "Start Safely")
        alert.addButton(withTitle: "Start as Usual")
        return alert.runModal() == .alertFirstButtonReturn
    }

    /// Secure Keyboard Entry, by hand: on while Manifold is in front.
    @objc func toggleSecureInput(_ sender: Any?) { SecureInput.shared.always.toggle() }

    @objc func validateMenuItem(_ item: NSMenuItem) -> Bool {
        if item.action == #selector(toggleSecureInput(_:)) { item.state = SecureInput.shared.always ? .on : .off }
        return true
    }

    func applicationWillTerminate(_ notification: Notification) {
        hosts.flushState()
        CrashGuard.launchedFine()
    }

    private var askedAboutStaleServer = false

    /// The server running is from another build of Manifold. It keeps the
    /// shells, so it isn't replaced without asking.
    private func serverIsStale(_ version: Int) {
        guard !askedAboutStaleServer else { return }
        askedAboutStaleServer = true
        DispatchQueue.main.async {
            let alert = NSAlert()
            alert.messageText = "Manifold's server is from another version"
            alert.informativeText = "Manifold was updated, but its server is still the old one (protocol \(version), not \(protocolVersion)), so some things won't work until it's restarted. Everything is kept; each shell starts again in the same directory, under its recent output."
            alert.addButton(withTitle: "Restart Server")
            alert.addButton(withTitle: "Not Now")
            if alert.runModal() == .alertFirstButtonReturn {
                HostClient.stopServer()
            }
        }
    }

    // MARK: Command line tool

    private static let cliLink = "/usr/local/bin/mani"
    /// Where the command was linked when it was `manifold`: taken away
    /// with the new link put in, if it's a link into a Manifold.
    private static let oldCLILink = "/usr/local/bin/manifold"

    private var cliPath: String {
        Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/mani").path
    }

    /// Links `mani` into /usr/local/bin, which takes an administrator's
    /// password, as for other apps' command line tools.
    @objc func installCommandLineTool(_ sender: Any?) {
        let link = Self.cliLink
        let target = cliPath
        let alert = NSAlert()
        if (try? FileManager.default.destinationOfSymbolicLink(atPath: link)) == target {
            alert.messageText = "The mani command is installed"
            alert.informativeText = "\(link) runs this copy of Manifold's. Try mani open README.md in a terminal."
            alert.runModal()
            return
        }
        alert.messageText = "Install the mani command?"
        alert.informativeText = "This links \(link) to Manifold, so you can run, say, mani open README.md to preview it. You'll be asked for an administrator's password."
        alert.addButton(withTitle: "Install")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        func quote(_ s: String) -> String { "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'" }
        var shell = "mkdir -p /usr/local/bin && ln -sf \(quote(target)) \(quote(link))"
        if let old = try? FileManager.default.destinationOfSymbolicLink(atPath: Self.oldCLILink), old.contains(".app/Contents/Helpers/") {
            shell += " && rm -f \(quote(Self.oldCLILink))"
        }
        let script = "do shell script \"\(shell.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\""))\" with administrator privileges"
        var error: NSDictionary?
        NSAppleScript(source: script)?.executeAndReturnError(&error)
        if let error, (error[NSAppleScript.errorNumber] as? Int) != -128 {
            let failed = NSAlert()
            failed.messageText = "The mani command wasn't installed"
            failed.informativeText = (error[NSAppleScript.errorMessage] as? String) ?? "Something went wrong."
            failed.runModal()
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply { .terminateNow }

    // MARK: Menus

    private func makeMainMenu() -> NSMenu {
        let main = NSMenu()

        let app = submenu(main, "Manifold")
        app.addItem(withTitle: "About Manifold", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        app.addItem(.separator())
        item(app, "Settings…", #selector(MainWindowController.showSettings(_:)), ",")
        app.addItem(.separator())
        app.addItem(withTitle: "Hide Manifold", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        item(app, "Hide Others", #selector(NSApplication.hideOtherApplications(_:)), "h", [.command, .option])
        app.addItem(withTitle: "Show All", action: #selector(NSApplication.unhideAllApplications(_:)), keyEquivalent: "")
        app.addItem(.separator())
        item(app, "Secure Keyboard Entry", #selector(toggleSecureInput(_:)), "")
        item(app, "Install Command Line Tool…", #selector(installCommandLineTool(_:)), "")
        item(app, "Attach to Host…", #selector(MainWindowController.attachToHost(_:)), "k", [.command, .shift])
        app.addItem(.separator())
        item(app, "Restart Server…", #selector(MainWindowController.restartServer(_:)), "")
        item(app, "End All Sessions and Quit…", #selector(MainWindowController.stopServer(_:)), "")
        app.addItem(withTitle: "Quit Manifold", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")

        let file = submenu(main, "File")
        item(file, "New…", #selector(MainWindowController.newTab(_:)), "t")
        file.addItem(.separator())
        item(file, "New Terminal", #selector(MainWindowController.newTerminalBeside(_:)), "n")
        item(file, "New Terminal in a New Column", #selector(MainWindowController.newTerminalInNewColumn(_:)), "n", [.command, .option, .shift])
        item(file, "New Terminal in a New Workspace", #selector(MainWindowController.newTerminal(_:)), "t", [.command, .option])
        item(file, "New Note", #selector(MainWindowController.newNote(_:)), "n", [.command, .shift])
        item(file, "New Note from Selection", #selector(MainWindowController.newNoteFromSelection(_:)), "")
        item(file, "New Note from Clipboard", #selector(MainWindowController.newNoteFromClipboard(_:)), "")
        item(file, "New Shell Notebook", #selector(MainWindowController.newShellNotebook(_:)), "n", [.command, .control, .shift])
        item(file, "New Agent", #selector(MainWindowController.newAgent(_:)), "a", [.command, .option])
        let agents = NSMenu(title: "Launch Agent Here")
        agents.delegate = agentMenu
        agentMenu.items = { [weak self] in self?.windowController?.agentMenuItems() ?? [] }
        let agentsItem = NSMenuItem(title: "Launch Agent Here", action: nil, keyEquivalent: "")
        agentsItem.submenu = agents
        file.addItem(agentsItem)
        item(file, "Processes", #selector(MainWindowController.showProcesses(_:)), "")
        item(file, "Find Anything…", #selector(MainWindowController.openDocument(_:)), "o")
        item(file, "Search Outline…", #selector(MainWindowController.searchOutline(_:)), "o", [.command, .shift])
        item(file, "Open Folder…", #selector(MainWindowController.openFolder(_:)), "o", [.command, .option])
        item(file, "Browse This Folder", #selector(MainWindowController.browseFocusedFolder(_:)), "o", [.command, .control])
        item(file, "Go to Tile or Outline…", #selector(MainWindowController.goToTile(_:)), "\\")
        file.addItem(.separator())
        item(file, "Source Control for This Project", #selector(MainWindowController.showGit(_:)), "g", [.command, .option])
        item(file, "Interactive Smartlog", #selector(MainWindowController.showSmartlog(_:)), "i", [.command, .option])
        item(file, "Compare with Last Commit", #selector(MainWindowController.compareWithHead(_:)), "d", [.command, .option])
        file.addItem(.separator())
        item(file, "Save", #selector(EditorView.saveDocument(_:)), "s")
        item(file, "Revert to Saved", #selector(EditorView.revertDocumentToSaved(_:)), "")
        item(file, "Name Note…", #selector(MainWindowController.nameFocusedNote(_:)), "")
        file.addItem(.separator())
        item(file, "Print…", #selector(MainWindowController.printTile(_:)), "p")
        file.addItem(.separator())
        item(file, "Close Tile", #selector(MainWindowController.closePaneOrTab(_:)), "w")
        item(file, "Reopen Closed", #selector(MainWindowController.reopenClosed(_:)), "t", [.command, .shift])
        item(file, "Keep and Close", #selector(MainWindowController.keepAndClose(_:)), "w", [.command, .shift])
        item(file, "Keep or Let Go", #selector(MainWindowController.togglePin(_:)), "")
        item(file, "Take Workspace Off the Desk", #selector(MainWindowController.closeTab(_:)), "w", [.command, .shift, .option])

        let edit = submenu(main, "Edit")
        item(edit, "Undo", Selector(("undo:")), "z")
        item(edit, "Redo", Selector(("redo:")), "z", [.command, .shift])
        edit.addItem(.separator())
        item(edit, "Cut", #selector(NSText.cut(_:)), "x")
        item(edit, "Copy", #selector(TerminalView.copy(_:)), "c")
        item(edit, "Paste", #selector(TerminalView.paste(_:)), "v")
        item(edit, "Select All", #selector(NSResponder.selectAll(_:)), "a")
        edit.addItem(.separator())
        let find = NSMenu(title: "Find")
        for (title, action, key, mods) in [
            ("Find…", NSTextFinder.Action.showFindInterface, "f", NSEvent.ModifierFlags.command),
            ("Find and Replace…", .showReplaceInterface, "f", [.command, .option]),
            ("Find Next", .nextMatch, "g", .command),
            ("Find Previous", .previousMatch, "g", [.command, .shift]),
            // As macOS has them: the selection (or the word at hand) found,
            // or put in Replace.
            ("Use Selection for Find", .setSearchString, "e", .command),
        ] {
            item(find, title, #selector(NSTextView.performTextFinderAction(_:)), key, mods).tag = action.rawValue
        }
        // NSTextFinder has no action of its own for it: a tag of the find pill's.
        item(find, "Use Selection for Replace", #selector(NSTextView.performTextFinderAction(_:)), "e", [.command, .shift]).tag = FindHost.useForReplace
        find.addItem(.separator())
        item(find, "Find in Files…", #selector(MainWindowController.findInFiles(_:)), "f", [.command, .shift])
        let findItem = NSMenuItem(title: "Find", action: nil, keyEquivalent: "")
        findItem.submenu = find
        edit.addItem(findItem)
        // ⌘L is one key for two things, by the tile: a line, in an editor
        // (as Xcode's); its address, in a page (as a browser's).
        item(edit, "Go to Line…", #selector(MainWindowController.goToLineOrAddress(_:)), "l")
        edit.addItem(.separator())
        item(edit, "Edit or View", #selector(MainWindowController.toggleEditPreview(_:)), "\r")
        item(edit, "Edit or View Beside", #selector(MainWindowController.editPreviewBeside(_:)), "p", [.command, .option, .shift])
        edit.addItem(.separator())
        let code = NSMenu(title: "Code")
        item(code, "Complete", #selector(EditorView.completeSymbol(_:)), " ", [.control])
        item(code, "Go to Definition", #selector(EditorView.goToDefinition(_:)), "j", [.command, .control])
        item(code, "Find References", #selector(EditorView.findReferences(_:)), "r", [.command, .control])
        item(code, "Show Documentation", #selector(EditorView.showDocumentation(_:)), "h", [.command, .control])
        code.addItem(.separator())
        item(code, "Rename Symbol…", #selector(EditorView.renameSymbol(_:)), "n", [.command, .control])
        item(code, "Format Document", #selector(EditorView.formatDocument(_:)), "f", [.command, .option, .shift])
        let codeItem = NSMenuItem(title: "Code", action: nil, keyEquivalent: "")
        codeItem.submenu = code
        edit.addItem(codeItem)
        edit.addItem(.separator())
        item(edit, "Clear", #selector(TerminalView.clearScreen(_:)), "k")

        let arrangement = submenu(main, "Workspace")
        item(arrangement, "Name…", #selector(MainWindowController.renameTab(_:)), "r", [.command, .shift])
        arrangement.addItem(.separator())
        item(arrangement, "Grow Tile", #selector(MainWindowController.growTile(_:)), "=", [.command, .control])
        item(arrangement, "Fill the Column", #selector(MainWindowController.fillColumn(_:)), "=", [.command, .control, .shift])
        item(arrangement, "Maximize Tile", #selector(MainWindowController.toggleMaximize(_:)), "\r", [.command, .shift])
        item(arrangement, "Stash Tile", #selector(MainWindowController.stashTile(_:)), "m")
        item(arrangement, "Overview", #selector(MainWindowController.showWorkspaceOverview(_:)), "'")
        arrangement.addItem(.separator())
        item(arrangement, "History of This File…", #selector(MainWindowController.showFileHistory(_:)), "y", [.command, .option])

        let view = submenu(main, "View")
        item(view, "Show Sidebar", #selector(MainWindowController.togglePinnedSidebar(_:)), "s", [.command, .control])
        item(view, "Show Outline", #selector(MainWindowController.toggleTileSidebar(_:)), "s", [.command, .option])
        view.addItem(.separator())
        let organize = NSMenu(title: "Organize By")
        for (title, sel, key) in [("Workspaces", #selector(MainWindowController.organizeByDesk(_:)), "1"), ("Files", #selector(MainWindowController.organizeByFiles(_:)), "2"),
                                  ("Inbox", #selector(MainWindowController.organizeByInbox(_:)), "3"),
                                  ("Search", #selector(MainWindowController.searchBlocks(_:)), "4")] {
            item(organize, title, sel, key, [.command, .option])
        }
        let organizeItem = NSMenuItem(title: "Organize By", action: nil, keyEquivalent: "")
        organizeItem.submenu = organize
        view.addItem(organizeItem)
        view.addItem(.separator())
        item(view, "Bigger", #selector(TerminalView.increaseFontSize(_:)), "+")
        item(view, "Smaller", #selector(TerminalView.decreaseFontSize(_:)), "-")
        item(view, "Actual Size", #selector(TerminalView.resetFontSize(_:)), "0")
        view.addItem(.separator())
        item(view, "Scroll to Top", #selector(TerminalView.scrollToTop(_:)), String(UnicodeScalar(NSHomeFunctionKey)!), [.command])
        item(view, "Scroll to Bottom", #selector(TerminalView.scrollToBottom(_:)), String(UnicodeScalar(NSEndFunctionKey)!), [.command])
        view.addItem(.separator())
        item(view, "Edit Address", #selector(MainWindowController.editAddress(_:)), "")
        item(view, "Back", #selector(WebView.goBack(_:)), "[", [.command])
        item(view, "Forward", #selector(WebView.goForward(_:)), "]", [.command])
        item(view, "Reload Page", #selector(WebView.reloadPage(_:)), "r", [.command])
        item(view, "Enter Full Screen", #selector(NSWindow.toggleFullScreen(_:)), "f", [.command, .control])

        let window = submenu(main, "Window")
        item(window, "Minimize", #selector(NSWindow.performMiniaturize(_:)), "m", [.command, .option])
        item(window, "Zoom", #selector(NSWindow.performZoom(_:)), "")
        window.addItem(.separator())
        item(window, "Show Next Workspace", #selector(MainWindowController.nextTab(_:)), "]", [.command, .shift])
        item(window, "Show Previous Workspace", #selector(MainWindowController.previousTab(_:)), "[", [.command, .shift])
        // ⌘`, as macOS cycles an app's windows: here, its workspaces (and,
        // with one, the windows).
        item(window, "Switch to Recent Workspace", #selector(MainWindowController.walkTabs(_:)), "`", [.command])
        item(window, "Switch to Recent Workspace, Backward", #selector(MainWindowController.walkTabsBack(_:)), "`", [.command, .shift])
        // ⌃⇥, as ⌃⇥ goes round a browser's tabs: a stack's sheets.
        item(window, "Switch Stack", #selector(MainWindowController.walkStack(_:)), "\t", [.control])
        item(window, "Switch Stack, Backward", #selector(MainWindowController.walkStackBack(_:)), "\t", [.control, .shift])
        for n in 1...9 {
            item(window, n == 9 ? "Select Last Workspace" : "Select Workspace \(n)", #selector(MainWindowController.selectTabByNumber(_:)), "\(n)").tag = n
        }
        window.addItem(.separator())
        // The block navigation stack (§3.5): ⌃- and ⌃⇧-, as VS Code's.
        item(window, "Navigate Back", #selector(MainWindowController.navigateBack(_:)), "-", [.control])
        item(window, "Navigate Forward", #selector(MainWindowController.navigateForward(_:)), "-", [.control, .shift])
        item(window, "Next in Inbox", #selector(MainWindowController.nextInInbox(_:)), "j")
        item(window, "Agents", #selector(MainWindowController.showAgents(_:)), "a", [.command, .control])
        item(window, "Focus Next Tile", #selector(MainWindowController.nextTile(_:)), "]", [.command, .option])
        item(window, "Focus Previous Tile", #selector(MainWindowController.previousTile(_:)), "[", [.command, .option])
        window.addItem(.separator())
        item(window, "Show the Neighborhood Map", #selector(MainWindowController.showNeighborhood(_:)), "n", [.command, .option])
        NSApp.windowsMenu = window

        return main
    }

    private func submenu(_ main: NSMenu, _ title: String) -> NSMenu {
        let menu = NSMenu(title: title)
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.submenu = menu
        main.addItem(item)
        return menu
    }

    @discardableResult
    private func item(_ menu: NSMenu, _ title: String, _ action: Selector, _ key: String,
                      _ mods: NSEvent.ModifierFlags = [.command]) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.keyEquivalentModifierMask = mods
        menu.addItem(item)
        return item
    }
}


/// A menu made as it opens, from what's true then (the agents on the
/// focused block's host).
final class LiveMenu: NSObject, NSMenuDelegate {
    var items: () -> [NSMenuItem] = { [] }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        for item in items() { menu.addItem(item) }
    }
}
