import AppKit
import ManifoldCore

final class AppDelegate: NSObject, NSApplicationDelegate {
    private let hosts = Hosts()
    private var host: HostClient { hosts.local }
    private var windowController: MainWindowController?
    /// Manifold ▸ Restart Server's hosts, made as it opens.
    private let serverMenu = MenuFiller()
    private let agentMenu = LiveMenu()
    private var createdFirst = false
    private let notifier = Notifier()

    func applicationDidFinishLaunching(_ notification: Notification) {
        ScrollerFlash.install()
        signal(SIGPIPE, SIG_IGN)
        CrashGuard.start()
        safeMode = CrashGuard.unfinished >= 2 && askSafeMode()
        MemoryWatch.start()
        OptionKeysPage.start()
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
            MainActor.unchecked { self?.windowController?.fontsChanged() }
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
        Palette.apply(Palette.named(hosts.state.appearance.colorTheme))
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
            notifier.speaksHere = { [weak hosts] b in hosts?.speaksHere(b) ?? true }
            TerminalView.ringsHere = { [weak hosts] b in hosts?.speaksHere(b) ?? true }
            notifier.onOpen = { [weak wc] b, command in wc?.openFromNotification(b, command: command) }
            notifier.threadNews = { [weak hosts] t in hosts?.unseen(t) ?? [] }
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
    @objc func showLogs(_ sender: Any?) { NSWorkspace.shared.activateFileViewerSelecting([Paths.logs]) }

    @objc func validateMenuItem(_ item: NSMenuItem) -> Bool {
        if item.action == #selector(toggleSecureInput(_:)) { item.state = SecureInput.shared.always ? .on : .off }
        return true
    }

    func applicationWillTerminate(_ notification: Notification) {
        // A deletion waiting out its undo: done.
        windowController?.finishPending()
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
        var shell = "mkdir -p /usr/local/bin && ln -sf \(target.shellQuoted) \(link.shellQuoted)"
        if let old = try? FileManager.default.destinationOfSymbolicLink(atPath: Self.oldCLILink), old.contains(".app/Contents/Helpers/") {
            shell += " && rm -f \(Self.oldCLILink.shellQuoted)"
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
        // Restart Server ▸ This Mac, and each other host (its server put
        // there afresh): made as it opens, the hosts as they are then.
        let servers = NSMenu(title: "Restart Server")
        servers.delegate = serverMenu
        serverMenu.items = { [weak self] in self?.windowController?.serverItems() ?? [] }
        let serversItem = NSMenuItem(title: "Restart Server", action: nil, keyEquivalent: "")
        serversItem.submenu = servers
        app.addItem(serversItem)
        item(app, "End All Sessions and Quit…", #selector(MainWindowController.stopServer(_:)), "")
        app.addItem(withTitle: "Quit Manifold", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")

        let file = submenu(main, "File")
        // ⌘N: any kind, by typing — its letter, or its name, then what it takes.
        item(file, "New Block…", #selector(MainWindowController.newBlockPicker(_:)), "n")
        // New ▸: every kind of block (BlockKinds, the one table `mani new`
        // and the picker are made from too), each on ⌥⌘ and its letter,
        // below the focused tile; ⇧ too (the item shown with ⇧ held), in a
        // new column.
        let new = NSMenu(title: "New")
        for kind in BlockKinds.all where kind.interactive {
            guard let action = MainWindowController.newActions[kind.name] else { continue }
            let it = item(new, kind.title, action, kind.key ?? "", [.command, .option])
            it.image = Theme.symbol(kind.symbol, size: 13)
            let column = item(new, kind.title + " in a New Column", #selector(MainWindowController.newInNewColumn(_:)), kind.key ?? "",
                              [.command, .option, .shift])
            column.representedObject = kind.name
            column.image = it.image
            column.isAlternate = true
        }
        let newItem = NSMenuItem(title: "New", action: nil, keyEquivalent: "")
        newItem.submenu = new
        file.addItem(newItem)
        file.addItem(.separator())
        item(file, "New Note from Selection", #selector(MainWindowController.newNoteFromSelection(_:)), "")
        item(file, "New Note from Clipboard", #selector(MainWindowController.newNoteFromClipboard(_:)), "")
        let agents = NSMenu(title: "Launch Agent Here")
        agents.delegate = agentMenu
        agentMenu.items = { [weak self] in self?.windowController?.agentMenuItems() ?? [] }
        let agentsItem = NSMenuItem(title: "Launch Agent Here", action: nil, keyEquivalent: "")
        agentsItem.submenu = agents
        file.addItem(agentsItem)
        file.addItem(.separator())
        // ⌥⌘O is New ▸ Folder (this one); Open Quickly (⌘O) finds any.
        item(file, "Open Folder…", #selector(MainWindowController.openFolder(_:)), "")
        // New ▸ Folder's (⌥⌘F), where Open Folder… is.
        item(file, "Browse This Folder", #selector(MainWindowController.browseFocusedFolder(_:)), "")
        // Source control in one place: the project's, its smartlog, the
        // file against its last commit, the file's history.
        let source = NSMenu(title: "Source Control")
        // (The project's and its smartlog are New ▸'s, ⌥⌘G and ⌥⌘L.)
        item(source, "Compare with Last Commit", #selector(MainWindowController.compareWithHead(_:)), "d", [.command, .option, .shift])
        item(source, "History of This File…", #selector(MainWindowController.showFileHistory(_:)), "y", [.command, .option])
        // Each line's commit, in a column beside the line numbers.
        item(source, "Blame", #selector(EditorView.toggleBlame(_:)), "b", [.command, .control])
        let sourceItem = NSMenuItem(title: "Source Control", action: nil, keyEquivalent: "")
        sourceItem.submenu = source
        file.addItem(sourceItem)
        file.addItem(.separator())
        item(file, "Save", #selector(EditorView.saveDocument(_:)), "s")
        // Saved, then closed once it's written: vim's :wq, an $EDITOR's done.
        // ⇧⌘S: save, and the bigger thing (Manifold has no Save As).
        item(file, "Save and Close", #selector(MainWindowController.saveAndClose(_:)), "s", [.command, .shift])
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
        // The focused block's content as text, whatever it is (§3.5).
        item(edit, "Copy Contents", #selector(MainWindowController.copyContents(_:)), "c", [.command, .shift])
        item(edit, "Paste", #selector(TerminalView.paste(_:)), "v")
        // As every Mac app has it: the clipboard's text as text — in a note,
        // a picture on it not kept, an address over words not made a link.
        item(edit, "Paste and Match Style", #selector(NSTextView.pasteAsPlainText(_:)), "v", [.command, .option, .shift])
        item(edit, "Select All", #selector(NSResponder.selectAll(_:)), "a")
        // A terminal's (an agent's): a path from where its shell is, typed at the cursor.
        item(edit, "Insert Path…", #selector(TerminalView.insertPath(_:)), "i", [.command, .control])
        edit.addItem(.separator())
        // A thread about where you are (§3.12): the selection, the rows
        // chosen, the caret's place — a comment, to yourself or an agent.
        item(edit, "Comment", #selector(MainWindowController.commentHere(_:)), "m", [.command, .option])
        // Every thread of the space (or its project) as one timeline, a tile beside.
        item(edit, "Show Threads", #selector(MainWindowController.showThreads(_:)), "")
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
        edit.addItem(.separator())
        let code = NSMenu(title: "Code")
        item(code, "Complete", #selector(EditorView.completeSymbol(_:)), " ", [.control])
        item(code, "Go to Definition", #selector(EditorView.goToDefinition(_:)), "j", [.command, .control])
        item(code, "Find References", #selector(EditorView.findReferences(_:)), "r", [.command, .control, .shift])
        item(code, "Show Callers", #selector(MainWindowController.showCallers(_:)), "")
        // A symbol's uses, kept tinted in its own colour (several at once).
        item(code, "Highlight Uses", #selector(TextView.highlightUses(_:)), "e", [.command, .control])
        item(code, "Clear Highlights", #selector(TextView.clearHighlights(_:)), "")
        code.addItem(.separator())
        // An agent asked about the selection: one item, its three ways under it.
        let ask = NSMenu(title: "Ask an Agent")
        item(ask, "Describe", #selector(MainWindowController.describeWithAgent(_:)), "")
        item(ask, "Explain", #selector(MainWindowController.explainWithAgent(_:)), "")
        item(ask, "Walk Through", #selector(MainWindowController.walkWithAgent(_:)), "")
        let askItem = NSMenuItem(title: "Ask an Agent", action: nil, keyEquivalent: "")
        askItem.submenu = ask
        code.addItem(askItem)
        // The project's SCIP index (§2.5): references across its files.
        item(code, "Index Project", #selector(EditorView.indexProject(_:)), "")
        item(code, "Show Documentation", #selector(EditorView.showDocumentation(_:)), "h", [.command, .control])
        code.addItem(.separator())
        item(code, "Rename Symbol…", #selector(EditorView.renameSymbol(_:)), "r", [.command, .control])
        // ⌃⌥⌘F: ⌥⇧⌘F is a folder in a new column.
        item(code, "Format Document", #selector(EditorView.formatDocument(_:)), "f", [.command, .option, .control])
        let codeItem = NSMenuItem(title: "Code", action: nil, keyEquivalent: "")
        codeItem.submenu = code
        edit.addItem(codeItem)
        edit.addItem(.separator())
        // An editor's own: lines, carets, and a note's marks.
        let up = String(UnicodeScalar(NSUpArrowFunctionKey)!), down = String(UnicodeScalar(NSDownArrowFunctionKey)!)
        let left = String(UnicodeScalar(NSLeftArrowFunctionKey)!), right = String(UnicodeScalar(NSRightArrowFunctionKey)!)
        let lines = NSMenu(title: "Lines")
        item(lines, "Delete Line", #selector(TextView.deleteLine(_:)), "k", [.command, .shift])
        item(lines, "Duplicate Line", #selector(TextView.duplicateLine(_:)), "d", [.command, .shift])
        item(lines, "Move Line Up", #selector(TextView.moveLineUp(_:)), up, [.command, .control])
        item(lines, "Move Line Down", #selector(TextView.moveLineDown(_:)), down, [.command, .control])
        item(lines, "Join Lines", #selector(TextView.joinLine(_:)), "j", [.control])
        // ⌥⌘/: ⌘/ is the tile's outline, everywhere.
        item(lines, "Comment or Uncomment", #selector(TextView.toggleLineComment(_:)), "/", [.command, .option])
        let linesItem = NSMenuItem(title: "Lines", action: nil, keyEquivalent: "")
        linesItem.submenu = lines
        edit.addItem(linesItem)
        let carets = NSMenu(title: "Selection")
        // ⌥⌘E, Xcode's Select Next Occurrence (⌘D is Delete Block).
        item(carets, "Add Next Occurrence", #selector(TextView.addNextOccurrence(_:)), "e", [.command, .option])
        item(carets, "Add Caret Above", #selector(TextView.addCaretAbove(_:)), up, [.control, .shift])
        item(carets, "Add Caret Below", #selector(TextView.addCaretBelow(_:)), down, [.control, .shift])
        let caretsItem = NSMenuItem(title: "Selection", action: nil, keyEquivalent: "")
        caretsItem.submenu = carets
        edit.addItem(caretsItem)
        let format = NSMenu(title: "Format")
        item(format, "Bold", #selector(TextView.formatBold(_:)), "b")
        item(format, "Italic", #selector(TextView.formatItalic(_:)), "i")
        item(format, "Strikethrough", #selector(TextView.formatStrikethrough(_:)), "x", [.command, .shift])
        item(format, "Code", #selector(TextView.formatCode(_:)), "c", [.command, .option])
        item(format, "Highlight", #selector(TextView.formatHighlight(_:)), "h", [.command, .shift])
        item(format, "Link…", #selector(NoteOutlineTextView.editLink(_:)), "k", [.command, .option])
        let formatItem = NSMenuItem(title: "Format", action: nil, keyEquivalent: "")
        formatItem.submenu = format
        edit.addItem(formatItem)
        // An outline's own (§7.9), as Prism's: its rows, their kinds, the
        // selection a step at a time, a row focused on. (⌘↩ checks a row,
        // ⌃⌘↑ ⌃⌘↓ move rows, ⇧⌘D ⇧⌘K duplicate and delete them: the
        // editor's keys for lines.)
        let outline = NSMenu(title: "Outline")
        item(outline, "New Row", #selector(NoteOutlineTextView.newRow(_:)), "")
        outline.addItem(.separator())
        item(outline, "Indent", #selector(NoteOutlineTextView.indentRows(_:)), right, [.command, .control])
        item(outline, "Outdent", #selector(NoteOutlineTextView.outdentRows(_:)), left, [.command, .control])
        outline.addItem(.separator())
        item(outline, "Checklist Item", #selector(NoteOutlineTextView.cycleChecklist(_:)), "")
        item(outline, "Task", #selector(NoteOutlineTextView.cycleTask(_:)), "")
        // ⇧⌘U: Notes' Mark as Checked.
        item(outline, "Toggle Done", #selector(NoteOutlineTextView.toggleDone(_:)), "u", [.command, .shift])
        item(outline, "Move Done to Bottom", #selector(NoteOutlineTextView.moveDoneToBottom(_:)), "d", [.command, .control, .shift])
        outline.addItem(.separator())
        item(outline, "Bullet", #selector(NoteOutlineTextView.toggleBullet(_:)), "8", [.command, .shift])
        item(outline, "Horizontal Line", #selector(NoteOutlineTextView.insertHorizontalLine(_:)), "-", [.command, .option])
        item(outline, "Code Block", #selector(NoteOutlineTextView.toggleCodeBlock(_:)), "c", [.command, .option, .shift])
        let turn = NSMenu(title: "Turn Into")
        for (i, type) in NoteOutlineTextView.RowType.allCases.enumerated() {
            item(turn, type.title, #selector(NoteOutlineTextView.turnInto(_:)), "").tag = i
        }
        let turnItem = NSMenuItem(title: "Turn Into", action: nil, keyEquivalent: "")
        turnItem.submenu = turn
        outline.addItem(turnItem)
        outline.addItem(.separator())
        item(outline, "Select Row Text", #selector(NoteOutlineTextView.selectRowText(_:)), "l", [.command, .shift])
        item(outline, "Select Branch", #selector(NoteOutlineTextView.selectBranch(_:)), "b", [.command, .shift])
        // ⌃⌥⌘ and an arrow, Prism's ⌥⌘ (here the tile that way).
        item(outline, "Expand Selection", #selector(NoteOutlineTextView.expandSelection(_:)), up, [.command, .option, .control])
        item(outline, "Contract Selection", #selector(NoteOutlineTextView.contractSelection(_:)), down, [.command, .option, .control])
        outline.addItem(.separator())
        item(outline, "Focus In", #selector(NoteOutlineTextView.focusIn(_:)), right, [.command, .option, .control])
        item(outline, "Focus Out", #selector(NoteOutlineTextView.focusOut(_:)), left, [.command, .option, .control])
        item(outline, "Unfocus", #selector(NoteOutlineTextView.unfocus(_:)), "")
        // Its folds too (they were View's): an outline's all in one place.
        outline.addItem(.separator())
        item(outline, "Collapse", #selector(NoteOutlineTextView.collapse(_:)), "9", [.command, .control])
        item(outline, "Expand", #selector(NoteOutlineTextView.expand(_:)), "0", [.command, .control])
        item(outline, "Collapse All", #selector(NoteOutlineTextView.collapseAll(_:)), "9", [.command, .option])
        item(outline, "Expand All", #selector(NoteOutlineTextView.expandAll(_:)), "0", [.command, .option])
        item(outline, "Collapse Completely", #selector(NoteOutlineTextView.collapseCompletely(_:)), "")
        item(outline, "Expand Completely", #selector(NoteOutlineTextView.expandCompletely(_:)), "")
        let outlineItem = NSMenuItem(title: "Outline", action: nil, keyEquivalent: "")
        outlineItem.submenu = outline
        edit.addItem(outlineItem)
        // ⌘K: a terminal's Clear Screen, a note's Link… (as Notes, Pages and
        // Mail have it) — one item, named by what's focused: a key on two
        // items is the first's, even where it can't be chosen.
        item(edit, "Clear Screen", #selector(TerminalView.clearOrLink(_:)), "k")
        edit.addItem(.separator())
        // Spelling and Grammar, as every Mac app has it (a note's text is checked as it's typed).
        let spelling = NSMenu(title: "Spelling and Grammar")
        item(spelling, "Show Spelling and Grammar", #selector(NSText.showGuessPanel(_:)), ":")
        item(spelling, "Check Document Now", #selector(NSText.checkSpelling(_:)), ";")
        spelling.addItem(.separator())
        item(spelling, "Check Spelling While Typing", #selector(NSTextView.toggleContinuousSpellChecking(_:)), "")
        item(spelling, "Check Grammar With Spelling", #selector(NSTextView.toggleGrammarChecking(_:)), "")
        item(spelling, "Correct Spelling Automatically", #selector(NSTextView.toggleAutomaticSpellingCorrection(_:)), "")
        let spellingItem = NSMenuItem(title: "Spelling and Grammar", action: nil, keyEquivalent: "")
        spellingItem.submenu = spelling
        edit.addItem(spellingItem)

        let view = submenu(main, "View")
        // ⌘/ the tile's sidebar (its outline), ⇧⌘/ the window's: ⇧ the
        // bigger one, as it is for closing and finding.
        item(view, "Show Outline", #selector(MainWindowController.toggleTileSidebar(_:)), "/")
        // Titled by what it does now: the sidebar kept beside the tiles, or
        // let slide out over them at the window's edge.
        item(view, "Keep Sidebar Shown", #selector(MainWindowController.togglePinnedSidebar(_:)), "/", [.command, .shift])
        // ⌃⌘S too, the Finder's and Mail's.
        let sidebar = item(view, "Keep Sidebar Shown", #selector(MainWindowController.togglePinnedSidebar(_:)), "s", [.command, .control])
        sidebar.isHidden = true
        sidebar.allowsKeyEquivalentWhenHidden = true
        view.addItem(.separator())
        let organize = NSMenu(title: "Organize By")
        for (title, sel, key) in [("Spaces", #selector(MainWindowController.organizeByDesk(_:)), "1"), ("Files", #selector(MainWindowController.organizeByFiles(_:)), "2"),
                                 ("Threads", #selector(MainWindowController.organizeByThreads(_:)), "3")] {
            item(organize, title, sel, key, [.command, .option])
        }
        let organizeItem = NSMenuItem(title: "Organize By", action: nil, keyEquivalent: "")
        organizeItem.submenu = organize
        view.addItem(organizeItem)
        // The focused block's properties, in the sidebar (Star's SHOW PROPERTIES).
        item(view, "Inspector", #selector(MainWindowController.toggleInspector(_:)), "i", [.command, .option])
        // The space's tiles, the last seen first, and what was closed (Dia's ⇧⌘A).
        item(view, "Tiles and Recently Closed…", #selector(MainWindowController.showTilesMenu(_:)), "a", [.command, .shift])
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
        // ⌃⌘G, not the Finder's ⌃⌘0: that's an outline's Expand, and a
        // menu keeps a key for one item only.
        item(view, "Use Groups", #selector(DirectoryView.toggleGroups(_:)), "g", [.command, .control])
        view.addItem(.separator())
        item(view, "Enter Full Screen", #selector(NSWindow.toggleFullScreen(_:)), "f", [.command, .control])

        // Go: finding a place and getting there.
        let go = submenu(main, "Go")
        item(go, "Open Quickly…", #selector(MainWindowController.openDocument(_:)), "o")
        item(go, "Find in Blocks…", #selector(MainWindowController.findInBlocks(_:)), "o", [.command, .shift])
        item(go, "Go To…", #selector(MainWindowController.goToTile(_:)), "p")
        item(go, "Find in Outline…", #selector(MainWindowController.searchOutline(_:)), "p", [.command, .shift])
        // The project the focused tile is in, its homepage (⌃⌘P).
        item(go, "Go to Project", #selector(MainWindowController.goToNearestProject(_:)), "p", [.command, .control])
        // ⌘L is one key for two things, by the tile: a line, in an editor
        // (as Xcode's); its address, in a page (as a browser's).
        item(go, "Go to Line…", #selector(MainWindowController.goToLineOrAddress(_:)), "l")
        go.addItem(.separator())
        // The places you've been (§3.5): ⌃- and ⌃⇧-, as VS Code's.
        item(go, "Back", #selector(MainWindowController.navigateBack(_:)), "-", [.control])
        item(go, "Forward", #selector(MainWindowController.navigateForward(_:)), "-", [.control, .shift])
        item(go, "Next in Inbox", #selector(MainWindowController.nextInInbox(_:)), "j")
        go.addItem(.separator())
        item(go, "Show Next Space", #selector(MainWindowController.nextTab(_:)), "]", [.command, .shift])
        item(go, "Show Previous Space", #selector(MainWindowController.previousTab(_:)), "[", [.command, .shift])
        // ⌘`, as macOS cycles an app's windows: here, its spaces, as cards
        // of their grids while ⌘ is held (and, with one, the windows).
        item(go, "Switch to Recent Space", #selector(MainWindowController.switchSpace(_:)), "`", [.command])
        item(go, "Switch to Recent Space, Backward", #selector(MainWindowController.switchSpaceBack(_:)), "`", [.command, .shift])
        // ⌃⇥, as ⌃⇥ goes round a browser's tabs: this space's tiles, those
        // docked too (§3.1).
        item(go, "Switch to Recent Tile in Space", #selector(MainWindowController.walkSpaceTiles(_:)), "\t", [.control])
        item(go, "Switch to Recent Tile in Space, Backward", #selector(MainWindowController.walkSpaceTilesBack(_:)), "\t", [.control, .shift])
        for n in 1...9 {
            item(go, n == 9 ? "Select Last Space" : "Select Space \(n)", #selector(MainWindowController.selectTabByNumber(_:)), "\(n)").tag = n
        }
        go.addItem(.separator())
        // ⌥⌘ and an arrow: the tile that way (⌥⇧⌘ moves it there).
        let focusMenu = NSMenu(title: "Focus")
        for (title, sel, key) in [("Left", #selector(MainWindowController.focusLeft(_:)), left), ("Right", #selector(MainWindowController.focusRight(_:)), right),
                                  ("Up", #selector(MainWindowController.focusUp(_:)), up), ("Down", #selector(MainWindowController.focusDown(_:)), down)] {
            item(focusMenu, "Focus " + title, sel, key, [.command, .option])
        }
        let focusItem = NSMenuItem(title: "Focus", action: nil, keyEquivalent: "")
        focusItem.submenu = focusMenu
        go.addItem(focusItem)
        item(go, "Focus Next Tile", #selector(MainWindowController.nextTile(_:)), "]", [.command, .option])
        item(go, "Focus Previous Tile", #selector(MainWindowController.previousTile(_:)), "[", [.command, .option])
        go.addItem(.separator())
        // A walk through code (§2.5): the focused note's references, a step
        // at a time, each shown beside it.
        item(go, "Next Step", #selector(MainWindowController.nextStep(_:)), "]", [.command, .control])
        item(go, "Previous Step", #selector(MainWindowController.previousStep(_:)), "[", [.command, .control])

        // Tile: the focused tile — its size, docking it, its keeping.
        let tile = submenu(main, "Tile")
        item(tile, "Close Tile", #selector(MainWindowController.closePaneOrTab(_:)), "w")
        item(tile, "Reopen Closed", #selector(MainWindowController.reopenClosed(_:)), "t", [.command, .shift])
        // Deleted, not closed: its links broken, the block gone; what only
        // it reached into Recently Closed.
        // ⌘D: common, and safe enough at a key — its toast undoes it.
        item(tile, "Delete Block", #selector(MainWindowController.deleteFocusedBlock(_:)), "d")
        tile.addItem(.separator())
        // ↩, how the tile shows: ⌘↩ its own thing (Edit or View, Run Cell,
        // Toggle Checkbox — titled by the tile), ⌥ as an outline, ⌃ the
        // other mode beside, ⇧ over everything.
        item(tile, "Edit or View", #selector(MainWindowController.toggleEditPreview(_:)), "\r")
        item(tile, "Edit or View Beside", #selector(MainWindowController.editPreviewBeside(_:)), "\r", [.command, .control])
        item(tile, "Edit as Outline", #selector(MainWindowController.toggleOutliner(_:)), "\r", [.command, .option])
        item(tile, "Maximize", #selector(MainWindowController.toggleMaximize(_:)), "\r", [.command, .shift])
        tile.addItem(.separator())
        item(tile, "Grow", #selector(MainWindowController.growTile(_:)), "=", [.command, .control])
        item(tile, "Fill the Column", #selector(MainWindowController.fillColumn(_:)), "=", [.command, .control, .shift])
        item(tile, "Fill the Column, Keeping Bars", #selector(MainWindowController.fillColumnKeepingBars(_:)), "=", [.command, .control, .option])
        item(tile, "Shrink to Summary", #selector(MainWindowController.shrinkToSummary(_:)), "m", [.command, .shift])
        item(tile, "Dock", #selector(MainWindowController.dockTile(_:)), "m")
        // ⌥⇧⌘ and an arrow: the tile a step that way.
        let moveMenu = NSMenu(title: "Move")
        for (title, sel, key) in [("Left", #selector(MainWindowController.moveTileLeft(_:)), left), ("Right", #selector(MainWindowController.moveTileRight(_:)), right),
                                  ("Up", #selector(MainWindowController.moveTileUp(_:)), up), ("Down", #selector(MainWindowController.moveTileDown(_:)), down)] {
            item(moveMenu, "Move " + title, sel, key, [.command, .option, .shift])
        }
        let moveItem = NSMenuItem(title: "Move", action: nil, keyEquivalent: "")
        moveItem.submenu = moveMenu
        tile.addItem(moveItem)
        tile.addItem(.separator())
        // ⌘., the system's cancel: a notebook's running cell.
        item(tile, "Interrupt", #selector(MainWindowController.interruptTile(_:)), ".")
        tile.addItem(.separator())
        // ⌃⌘T, the Finder's Add to Sidebar: a pin keeps the block in the
        // space's part of the sidebar, tile or not.
        item(tile, "Pin in Space", #selector(MainWindowController.togglePinInWorkspace(_:)), "t", [.command, .control])
        item(tile, "Name Note…", #selector(MainWindowController.nameFocusedNote(_:)), "")
        item(tile, "Show the Neighborhood Map", #selector(MainWindowController.showNeighborhood(_:)), "m", [.command, .option, .shift])

        // Space: the space itself.
        let space = submenu(main, "Space")
        // ⌘T, as a browser's new tab (⇧⌘T reopens what was closed, ⇧⌘[ ⇧⌘]
        // go between them): a space with a terminal.
        item(space, "New Space", #selector(MainWindowController.newTerminal(_:)), "t")
        item(space, "Rename Space…", #selector(MainWindowController.renameTab(_:)), "r", [.command, .shift])
        item(space, "Overview", #selector(MainWindowController.showWorkspaceOverview(_:)), "'")
        space.addItem(.separator())
        // ⇧⌘W, as the Mac closes a window: ⌘W's bigger thing.
        item(space, "Remove Space", #selector(MainWindowController.closeTab(_:)), "w", [.command, .shift])

        let window = submenu(main, "Window")
        // ⌘M is Dock (§3.1): Minimize from the menu alone.
        item(window, "Minimize", #selector(NSWindow.performMiniaturize(_:)), "")
        item(window, "Zoom", #selector(NSWindow.performZoom(_:)), "")
        window.addItem(.separator())
        item(window, "Agents", #selector(MainWindowController.showAgents(_:)), "a", [.command, .control])
        NSApp.windowsMenu = window

        // Help: the system's search over every menu command (it puts the
        // field in itself), for an app with some ninety of them.
        let help = submenu(main, "Help")
        NSApp.helpMenu = help
        item(help, "Show Logs in Finder", #selector(showLogs(_:)), "")

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

/// A menu whose items are made each time it opens.
final class MenuFiller: NSObject, NSMenuDelegate {
    var items: () -> [NSMenuItem] = { [] }
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        for i in items() { menu.addItem(i) }
    }
}
