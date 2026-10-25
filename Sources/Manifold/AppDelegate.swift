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
                wc.notice("Started safely: other hosts aren't attached, and a new space is shown", action: "OK") {}
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
        alert.informativeText = "It happened \(CrashGuard.unfinished) times in a row. Started safely, Manifold shows a new, empty space instead of the last one, and doesn't attach other hosts until you ask; everything is kept. Reports are in ~/Library/Logs/Manifold."
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
        // From the menu alone: ⇧⌘K is the editor's Delete Line.
        item(app, "Attach to Host…", #selector(MainWindowController.attachToHost(_:)), "")
        app.addItem(.separator())
        item(app, "Restart Server…", #selector(MainWindowController.restartServer(_:)), "")
        item(app, "End All Sessions and Quit…", #selector(MainWindowController.stopServer(_:)), "")
        app.addItem(withTitle: "Quit Manifold", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")

        let file = submenu(main, "File")
        item(file, "New Terminal", #selector(MainWindowController.newTerminalBeside(_:)), "n")
        item(file, "New Terminal in a New Column", #selector(MainWindowController.newTerminalInNewColumn(_:)), "n", [.command, .option, .shift])
        item(file, "New Terminal in a New Space", #selector(MainWindowController.newTerminal(_:)), "t", [.command, .option])
        item(file, "New Note", #selector(MainWindowController.newNote(_:)), "n", [.command, .shift])
        item(file, "New Note from Selection", #selector(MainWindowController.newNoteFromSelection(_:)), "")
        item(file, "New Note from Clipboard", #selector(MainWindowController.newNoteFromClipboard(_:)), "")
        item(file, "New Web Page", #selector(MainWindowController.newWebPage(_:)), "")
        item(file, "New Shell Notebook", #selector(MainWindowController.newShellNotebook(_:)), "n", [.command, .control, .shift])
        item(file, "New Agent", #selector(MainWindowController.newAgent(_:)), "a", [.command, .option])
        let agents = NSMenu(title: "Launch Agent Here")
        agents.delegate = agentMenu
        agentMenu.items = { [weak self] in self?.windowController?.agentMenuItems() ?? [] }
        let agentsItem = NSMenuItem(title: "Launch Agent Here", action: nil, keyEquivalent: "")
        agentsItem.submenu = agents
        file.addItem(agentsItem)
        file.addItem(.separator())
        item(file, "Open Folder…", #selector(MainWindowController.openFolder(_:)), "o", [.command, .option])
        item(file, "Browse This Folder", #selector(MainWindowController.browseFocusedFolder(_:)), "o", [.command, .control])
        // Source control in one place: the project's, its smartlog, the
        // file against its last commit, the file's history.
        let source = NSMenu(title: "Source Control")
        item(source, "Source Control for This Project", #selector(MainWindowController.showGit(_:)), "g", [.command, .option])
        item(source, "Interactive Smartlog", #selector(MainWindowController.showSmartlog(_:)), "i", [.command, .option])
        item(source, "Compare with Last Commit", #selector(MainWindowController.compareWithHead(_:)), "d", [.command, .option, .shift])
        item(source, "History of This File…", #selector(MainWindowController.showFileHistory(_:)), "y", [.command, .option])
        let sourceItem = NSMenuItem(title: "Source Control", action: nil, keyEquivalent: "")
        sourceItem.submenu = source
        file.addItem(sourceItem)
        file.addItem(.separator())
        item(file, "Save", #selector(EditorView.saveDocument(_:)), "s")
        item(file, "Revert to Saved", #selector(EditorView.revertDocumentToSaved(_:)), "")
        file.addItem(.separator())
        // From the menu alone: ⌘P is the outline.
        item(file, "Print…", #selector(MainWindowController.printTile(_:)), "")

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
        item(code, "Find References", #selector(EditorView.findReferences(_:)), "r", [.command, .control, .shift])
        item(code, "Show Documentation", #selector(EditorView.showDocumentation(_:)), "h", [.command, .control])
        code.addItem(.separator())
        item(code, "Rename Symbol…", #selector(EditorView.renameSymbol(_:)), "r", [.command, .control])
        item(code, "Format Document", #selector(EditorView.formatDocument(_:)), "f", [.command, .option, .shift])
        let codeItem = NSMenuItem(title: "Code", action: nil, keyEquivalent: "")
        codeItem.submenu = code
        edit.addItem(codeItem)
        edit.addItem(.separator())
        // An editor's own: lines, carets, and a note's marks.
        let up = String(UnicodeScalar(NSUpArrowFunctionKey)!), down = String(UnicodeScalar(NSDownArrowFunctionKey)!)
        let lines = NSMenu(title: "Lines")
        item(lines, "Delete Line", #selector(TextView.deleteLine(_:)), "k", [.command, .shift])
        item(lines, "Duplicate Line", #selector(TextView.duplicateLine(_:)), "d", [.command, .shift])
        item(lines, "Move Line Up", #selector(TextView.moveLineUp(_:)), up, [.command, .control])
        item(lines, "Move Line Down", #selector(TextView.moveLineDown(_:)), down, [.command, .control])
        item(lines, "Join Lines", #selector(TextView.joinLine(_:)), "j", [.control])
        item(lines, "Comment or Uncomment", #selector(TextView.toggleLineComment(_:)), "/")
        let linesItem = NSMenuItem(title: "Lines", action: nil, keyEquivalent: "")
        linesItem.submenu = lines
        edit.addItem(linesItem)
        let carets = NSMenu(title: "Selection")
        item(carets, "Add Next Occurrence", #selector(TextView.addNextOccurrence(_:)), "d")
        item(carets, "Add Caret Above", #selector(TextView.addCaretAbove(_:)), up, [.control, .shift])
        item(carets, "Add Caret Below", #selector(TextView.addCaretBelow(_:)), down, [.control, .shift])
        let caretsItem = NSMenuItem(title: "Selection", action: nil, keyEquivalent: "")
        caretsItem.submenu = carets
        edit.addItem(caretsItem)
        let format = NSMenu(title: "Format")
        item(format, "Bold", #selector(TextView.formatBold(_:)), "b")
        item(format, "Italic", #selector(TextView.formatItalic(_:)), "i")
        item(format, "Strikethrough", #selector(TextView.formatStrikethrough(_:)), "x", [.command, .shift])
        item(format, "Code", #selector(TextView.formatCode(_:)), "c", [.command, .shift])
        let formatItem = NSMenuItem(title: "Format", action: nil, keyEquivalent: "")
        formatItem.submenu = format
        edit.addItem(formatItem)
        item(edit, "Clear Screen", #selector(TerminalView.clearScreen(_:)), "k")

        let view = submenu(main, "View")
        // Titled by what it does now: the sidebar kept beside the tiles, or
        // let slide out over them at the window's edge.
        item(view, "Keep Sidebar Shown", #selector(MainWindowController.togglePinnedSidebar(_:)), "s", [.command, .control])
        item(view, "Show Outline", #selector(MainWindowController.toggleTileSidebar(_:)), "s", [.command, .option])
        view.addItem(.separator())
        let organize = NSMenu(title: "Organize By")
        for (title, sel, key) in [("Spaces", #selector(MainWindowController.organizeByDesk(_:)), "1"), ("Files", #selector(MainWindowController.organizeByFiles(_:)), "2"),
                                  ("Inbox", #selector(MainWindowController.organizeByInbox(_:)), "3")] {
            item(organize, title, sel, key, [.command, .option])
        }
        let organizeItem = NSMenuItem(title: "Organize By", action: nil, keyEquivalent: "")
        organizeItem.submenu = organize
        view.addItem(organizeItem)
        view.addItem(.separator())
        item(view, "Bigger", #selector(TerminalView.increaseFontSize(_:)), "+")
        // ⌘= too, the key + is on, unshifted.
        let bigger = item(view, "Bigger", #selector(TerminalView.increaseFontSize(_:)), "=")
        bigger.isHidden = true
        bigger.allowsKeyEquivalentWhenHidden = true
        item(view, "Smaller", #selector(TerminalView.decreaseFontSize(_:)), "-")
        item(view, "Actual Size", #selector(TerminalView.resetFontSize(_:)), "0")
        view.addItem(.separator())
        item(view, "Scroll to Top", #selector(TerminalView.scrollToTop(_:)), String(UnicodeScalar(NSHomeFunctionKey)!), [.command])
        item(view, "Scroll to Bottom", #selector(TerminalView.scrollToBottom(_:)), String(UnicodeScalar(NSEndFunctionKey)!), [.command])
        view.addItem(.separator())
        // A page's or a folder's own history, as a browser's Back — not the
        // places you've been (Go ▸ Back, ⌃-).
        item(view, "Back in This Tile", #selector(WebView.goBack(_:)), "[", [.command])
        item(view, "Forward in This Tile", #selector(WebView.goForward(_:)), "]", [.command])
        item(view, "Reload Page", #selector(WebView.reloadPage(_:)), "r", [.command])
        item(view, "Show Hidden Files", #selector(DirectoryView.toggleHiddenFiles(_:)), ".", [.command, .shift])
        view.addItem(.separator())
        item(view, "Processes", #selector(MainWindowController.showProcesses(_:)), "")
        item(view, "Enter Full Screen", #selector(NSWindow.toggleFullScreen(_:)), "f", [.command, .control])

        // Go: finding a place and getting there.
        let go = submenu(main, "Go")
        item(go, "Open Quickly…", #selector(MainWindowController.openDocument(_:)), "o")
        item(go, "Outline…", #selector(MainWindowController.goToTile(_:)), "p")
        item(go, "Filter Outline", #selector(MainWindowController.searchOutline(_:)), "p", [.command, .shift])
        go.addItem(.separator())
        // The places you've been (§3.5): ⌃- and ⌃⇧-, as VS Code's.
        item(go, "Back", #selector(MainWindowController.navigateBack(_:)), "-", [.control])
        item(go, "Forward", #selector(MainWindowController.navigateForward(_:)), "-", [.control, .shift])
        item(go, "Next in Inbox", #selector(MainWindowController.nextInInbox(_:)), "j")
        go.addItem(.separator())
        item(go, "Show Next Space", #selector(MainWindowController.nextTab(_:)), "]", [.command, .shift])
        item(go, "Show Previous Space", #selector(MainWindowController.previousTab(_:)), "[", [.command, .shift])
        // ⌘`, as macOS cycles an app's windows: here, its spaces (and,
        // with one, the windows).
        item(go, "Switch to Recent Space", #selector(MainWindowController.walkTabs(_:)), "`", [.command])
        item(go, "Switch to Recent Space, Backward", #selector(MainWindowController.walkTabsBack(_:)), "`", [.command, .shift])
        for n in 1...9 {
            item(go, n == 9 ? "Select Last Space" : "Select Space \(n)", #selector(MainWindowController.selectTabByNumber(_:)), "\(n)").tag = n
        }
        go.addItem(.separator())
        item(go, "Focus Next Tile", #selector(MainWindowController.nextTile(_:)), "]", [.command, .option])
        item(go, "Focus Previous Tile", #selector(MainWindowController.previousTile(_:)), "[", [.command, .option])

        // Tile: the focused tile — its size, its stack, its keeping.
        let tile = submenu(main, "Tile")
        item(tile, "Close Tile", #selector(MainWindowController.closePaneOrTab(_:)), "w")
        item(tile, "Reopen Closed", #selector(MainWindowController.reopenClosed(_:)), "t", [.command, .shift])
        tile.addItem(.separator())
        item(tile, "Grow", #selector(MainWindowController.growTile(_:)), "=", [.command, .control])
        item(tile, "Fill the Column", #selector(MainWindowController.fillColumn(_:)), "=", [.command, .control, .shift])
        item(tile, "Maximize", #selector(MainWindowController.toggleMaximize(_:)), "\r", [.command, .shift])
        item(tile, "Shrink to Summary", #selector(MainWindowController.shrinkToSummary(_:)), "m", [.command, .shift])
        item(tile, "Stash", #selector(MainWindowController.stashTile(_:)), "m")
        tile.addItem(.separator())
        // ⌃⇥, as ⌃⇥ goes round a browser's tabs: a stack's tiles.
        item(tile, "Next in Stack", #selector(MainWindowController.walkStack(_:)), "\t", [.control])
        item(tile, "Previous in Stack", #selector(MainWindowController.walkStackBack(_:)), "\t", [.control, .shift])
        item(tile, "Unstack", #selector(MainWindowController.unstackFocused(_:)), "")
        item(tile, "Close Stack", #selector(MainWindowController.closeFocusedStack(_:)), "")
        tile.addItem(.separator())
        item(tile, "Pin in Space", #selector(MainWindowController.togglePinInWorkspace(_:)), "")
        item(tile, "Name Note…", #selector(MainWindowController.nameFocusedNote(_:)), "")
        item(tile, "Show the Neighborhood Map", #selector(MainWindowController.showNeighborhood(_:)), "m", [.command, .option])

        // Space: the space itself.
        let space = submenu(main, "Space")
        item(space, "Name Space…", #selector(MainWindowController.renameTab(_:)), "r", [.command, .shift])
        item(space, "Overview", #selector(MainWindowController.showWorkspaceOverview(_:)), "'")
        space.addItem(.separator())
        item(space, "Remove Space", #selector(MainWindowController.closeTab(_:)), "w", [.command, .shift, .option])

        let window = submenu(main, "Window")
        // ⌘M is Stash: Minimize from the menu alone.
        item(window, "Minimize", #selector(NSWindow.performMiniaturize(_:)), "")
        item(window, "Zoom", #selector(NSWindow.performZoom(_:)), "")
        window.addItem(.separator())
        item(window, "Agents", #selector(MainWindowController.showAgents(_:)), "a", [.command, .control])
        NSApp.windowsMenu = window

        // Help: the system's search over every menu command (it puts the
        // field in itself), for an app with some ninety of them.
        NSApp.helpMenu = submenu(main, "Help")

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
