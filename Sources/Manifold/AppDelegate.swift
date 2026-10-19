import AppKit
import ManifoldCore

final class AppDelegate: NSObject, NSApplicationDelegate {
    private let hosts = Hosts()
    private var host: HostClient { hosts.local }
    private var windowController: MainWindowController?
    private var createdFirst = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        signal(SIGPIPE, SIG_IGN)
        _ = GhosttyRuntime.shared
        NSApp.mainMenu = makeMainMenu()
        AppearanceWatcher.shared.start()
        NotificationCenter.default.addObserver(forName: .manifoldAppearanceChanged, object: nil, queue: .main) {
            [weak self] _ in
            guard let self else { return }
            GhosttyRuntime.shared.apply(self.host.desk.appearance, dark: NSApp.effectiveAppearance.isDark)
        }

        hosts.onChange = { [weak self] in self?.stateChanged() }
        host.onVersionMismatch = { [weak self] version in self?.serverIsStale(version) }
        host.connect()
        hosts.reattachRemembered()
        DebugControl.start { [weak self] in self?.windowController }
    }

    private func stateChanged() {
        guard host.hasState else { return }
        hosts.pushLanguageServers()
        let scheme = host.desk.appearance.colorScheme.appearance
        if NSApp.appearance?.name != scheme?.name { NSApp.appearance = scheme }
        GhosttyRuntime.shared.apply(host.desk.appearance, dark: NSApp.effectiveAppearance.isDark)
        if windowController == nil {
            let wc = MainWindowController(hosts: hosts)
            windowController = wc
            // The very first time, start with a terminal rather than an empty
            // window.
            if host.desk.order.isEmpty && !createdFirst && host.node.blocks.isEmpty {
                createdFirst = true
                wc.newTerminal(nil)
            }
            wc.showWindow(nil)
            NSApp.activate()
        }
        windowController?.render()
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

    private static let cliLink = "/usr/local/bin/manifold"

    private var cliPath: String {
        Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/manifold").path
    }

    /// Links `manifold` into /usr/local/bin, which takes an administrator's
    /// password, as for other apps' command line tools.
    @objc func installCommandLineTool(_ sender: Any?) {
        let link = Self.cliLink
        let target = cliPath
        let alert = NSAlert()
        if (try? FileManager.default.destinationOfSymbolicLink(atPath: link)) == target {
            alert.messageText = "The manifold command is installed"
            alert.informativeText = "\(link) runs this copy of Manifold's. Try manifold README.md in a terminal."
            alert.runModal()
            return
        }
        alert.messageText = "Install the manifold command?"
        alert.informativeText = "This links \(link) to Manifold, so you can run, say, manifold README.md to preview it. You'll be asked for an administrator's password."
        alert.addButton(withTitle: "Install")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        func quote(_ s: String) -> String { "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'" }
        let shell = "mkdir -p /usr/local/bin && ln -sf \(quote(target)) \(quote(link))"
        let script = "do shell script \"\(shell.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\""))\" with administrator privileges"
        var error: NSDictionary?
        NSAppleScript(source: script)?.executeAndReturnError(&error)
        if let error, (error[NSAppleScript.errorNumber] as? Int) != -128 {
            let failed = NSAlert()
            failed.messageText = "The manifold command wasn't installed"
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
        app.addItem(withTitle: "Hide Manifold", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        item(app, "Hide Others", #selector(NSApplication.hideOtherApplications(_:)), "h", [.command, .option])
        app.addItem(withTitle: "Show All", action: #selector(NSApplication.unhideAllApplications(_:)), keyEquivalent: "")
        app.addItem(.separator())
        item(app, "Install Command Line Tool…", #selector(installCommandLineTool(_:)), "")
        item(app, "Attach to Host…", #selector(MainWindowController.attachToHost(_:)), "k", [.command, .shift])
        item(app, "Language Servers…", #selector(MainWindowController.showLanguageServers(_:)), "")
        app.addItem(.separator())
        item(app, "Restart Server…", #selector(MainWindowController.restartServer(_:)), "")
        item(app, "End All Sessions and Quit…", #selector(MainWindowController.stopServer(_:)), "")
        app.addItem(withTitle: "Quit Manifold", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")

        let file = submenu(main, "File")
        item(file, "New…", #selector(MainWindowController.newTab(_:)), "t")
        file.addItem(.separator())
        item(file, "New Terminal Beside", #selector(MainWindowController.newTerminalBeside(_:)), "n")
        item(file, "New Terminal in a New Arrangement", #selector(MainWindowController.newTerminal(_:)), "t", [.command, .option])
        item(file, "New Note", #selector(MainWindowController.newNote(_:)), "n", [.command, .shift])
        item(file, "New Agent", #selector(MainWindowController.newAgent(_:)), "a", [.command, .option])
        item(file, "Processes", #selector(MainWindowController.showProcesses(_:)), "")
        item(file, "Find Anything…", #selector(MainWindowController.openDocument(_:)), "o")
        file.addItem(.separator())
        item(file, "Source Control for This Project", #selector(MainWindowController.showGit(_:)), "g", [.command, .option])
        item(file, "Compare with Last Commit", #selector(MainWindowController.compareWithHead(_:)), "d", [.command, .option])
        file.addItem(.separator())
        item(file, "Save", #selector(EditorView.saveDocument(_:)), "s")
        item(file, "Revert to Saved", #selector(EditorView.revertDocumentToSaved(_:)), "")
        file.addItem(.separator())
        item(file, "Take Off This Column", #selector(MainWindowController.closePaneOrTab(_:)), "w")
        item(file, "Take Arrangement Off the Desk", #selector(MainWindowController.closeTab(_:)), "w", [.command, .shift])

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
        ] {
            item(find, title, #selector(NSTextView.performTextFinderAction(_:)), key, mods).tag = action.rawValue
        }
        find.addItem(.separator())
        item(find, "Find in Files…", #selector(MainWindowController.findInFiles(_:)), "f", [.command, .shift])
        let findItem = NSMenuItem(title: "Find", action: nil, keyEquivalent: "")
        findItem.submenu = find
        edit.addItem(findItem)
        item(edit, "Go to Line…", #selector(EditorView.goToLine(_:)), "l")
        edit.addItem(.separator())
        item(edit, "Edit or Preview", #selector(MainWindowController.toggleEditPreview(_:)), "p", [.command, .option])
        item(edit, "Edit or Preview Beside", #selector(MainWindowController.editPreviewBeside(_:)), "p", [.command, .option, .shift])
        edit.addItem(.separator())
        let code = NSMenu(title: "Code")
        item(code, "Complete", #selector(EditorView.completeSymbol(_:)), " ", [.control])
        item(code, "Go to Definition", #selector(EditorView.goToDefinition(_:)), "j", [.command, .control])
        item(code, "Find References", #selector(EditorView.findReferences(_:)), "r", [.command, .control])
        item(code, "Show Documentation", #selector(EditorView.showDocumentation(_:)), "h", [.command, .control])
        code.addItem(.separator())
        item(code, "Rename Symbol…", #selector(EditorView.renameSymbol(_:)), "n", [.command, .control])
        item(code, "Format Document", #selector(EditorView.formatDocument(_:)), "f", [.command, .control])
        let codeItem = NSMenuItem(title: "Code", action: nil, keyEquivalent: "")
        codeItem.submenu = code
        edit.addItem(codeItem)
        edit.addItem(.separator())
        item(edit, "Clear", #selector(TerminalView.clearScreen(_:)), "k")

        let arrangement = submenu(main, "Arrangement")
        item(arrangement, "Name…", #selector(MainWindowController.renameTab(_:)), "r", [.command, .shift])
        arrangement.addItem(.separator())
        item(arrangement, "Grow Tile", #selector(MainWindowController.growTile(_:)), "=", [.command, .control])
        item(arrangement, "Fill the Column", #selector(MainWindowController.fillColumn(_:)), "=", [.command, .control, .shift])
        item(arrangement, "Maximize Tile", #selector(MainWindowController.toggleMaximize(_:)), "\r", [.command, .shift])
        arrangement.addItem(.separator())
        item(arrangement, "History…", #selector(MainWindowController.showHistory(_:)), "y")
        item(arrangement, "History of This File…", #selector(MainWindowController.showFileHistory(_:)), "y", [.command, .option])

        let view = submenu(main, "View")
        item(view, "Show Sidebar", #selector(MainWindowController.togglePinnedSidebar(_:)), "s", [.command, .control])
        view.addItem(.separator())
        let schemes = NSMenu(title: "Appearance")
        for scheme in ColorScheme.allCases {
            item(schemes, scheme.title, #selector(MainWindowController.setColorScheme(_:)), "", [])
                .representedObject = scheme.rawValue
            if scheme == .system { schemes.addItem(.separator()) }
        }
        let schemesItem = NSMenuItem(title: "Appearance", action: nil, keyEquivalent: "")
        schemesItem.submenu = schemes
        view.addItem(schemesItem)
        let themes = NSMenu(title: "Theme")
        for theme in FontTheme.allCases {
            item(themes, "\(theme.title) (\(theme.proportionalName), \(theme.monospacedName))",
                 #selector(MainWindowController.setTheme(_:)), "", []).representedObject = theme.rawValue
        }
        let themesItem = NSMenuItem(title: "Theme", action: nil, keyEquivalent: "")
        themesItem.submenu = themes
        view.addItem(themesItem)
        let contrast = NSMenu(title: "Contrast Correction")
        for (mode, title) in [(ContrastCorrection.off, "Off"),
                              (.typical, "For Typical Vision"),
                              (.deuteranopia, "For Typical Vision and Deuteranopia")] {
            item(contrast, title, #selector(MainWindowController.setContrastCorrection(_:)), "", [])
                .representedObject = mode.rawValue
        }
        let contrastItem = NSMenuItem(title: "Contrast Correction", action: nil, keyEquivalent: "")
        contrastItem.submenu = contrast
        view.addItem(contrastItem)
        let fonts = NSMenu(title: "Editor Font")
        for (font, title) in [(EditorFont.proportional, "Proportional"), (.monospaced, "Fixed Width")] {
            item(fonts, title, #selector(MainWindowController.setEditorFont(_:)), "", []).representedObject = font.rawValue
        }
        let fontsItem = NSMenuItem(title: "Editor Font", action: nil, keyEquivalent: "")
        fontsItem.submenu = fonts
        view.addItem(fontsItem)
        let organize = NSMenu(title: "Organize By")
        for (title, sel, key) in [("Desk", #selector(MainWindowController.organizeByDesk(_:)), "1"), ("Files", #selector(MainWindowController.organizeByFiles(_:)), "2"),
                                  ("Links", #selector(MainWindowController.organizeByLinks(_:)), "3"), ("Time", #selector(MainWindowController.organizeByTime(_:)), "4"),
                                  ("Status", #selector(MainWindowController.organizeByStatus(_:)), "5")] {
            item(organize, title, sel, key, [.command, .option])
        }
        let organizeItem = NSMenuItem(title: "Organize By", action: nil, keyEquivalent: "")
        organizeItem.submenu = organize
        view.addItem(organizeItem)
        view.addItem(.separator())
        let dormancy = NSMenu(title: "End Idle Shells")
        for (hours, title) in [(2, "After 2 Hours Off Screen"), (8, "After 8 Hours Off Screen"), (24, "After a Day Off Screen"),
                               (168, "After a Week Off Screen"), (0, "Never")] {
            item(dormancy, title, #selector(MainWindowController.setTerminalDormancy(_:)), "", []).tag = hours
        }
        let dormancyItem = NSMenuItem(title: "End Idle Shells", action: nil, keyEquivalent: "")
        dormancyItem.submenu = dormancy
        view.addItem(dormancyItem)
        let keep = NSMenu(title: "Keep History")
        for (days, title) in [(0, "Text Changes: Forever"), (30, "Text Changes: 30 Days"), (90, "Text Changes: 90 Days"), (365, "Text Changes: a Year")] {
            item(keep, title, #selector(MainWindowController.setTextHistory(_:)), "", []).tag = days
        }
        keep.addItem(.separator())
        for (days, title) in [(30, "Transcripts: 30 Days"), (90, "Transcripts: 90 Days"), (365, "Transcripts: a Year"), (0, "Transcripts: Forever")] {
            item(keep, title, #selector(MainWindowController.setTranscriptHistory(_:)), "", []).tag = days
        }
        keep.addItem(.separator())
        for (depth, title) in [(0, "Undo: Everything"), (100, "Undo: 100 Steps"), (1000, "Undo: 1,000 Steps")] {
            item(keep, title, #selector(MainWindowController.setUndoDepth(_:)), "", []).tag = depth
        }
        let keepItem = NSMenuItem(title: "Keep History", action: nil, keyEquivalent: "")
        keepItem.submenu = keep
        view.addItem(keepItem)
        view.addItem(.separator())
        item(view, "Bigger", #selector(TerminalView.increaseFontSize(_:)), "+")
        item(view, "Smaller", #selector(TerminalView.decreaseFontSize(_:)), "-")
        item(view, "Actual Size", #selector(TerminalView.resetFontSize(_:)), "0")
        view.addItem(.separator())
        item(view, "Scroll to Top", #selector(TerminalView.scrollToTop(_:)), String(UnicodeScalar(NSHomeFunctionKey)!), [.command])
        item(view, "Scroll to Bottom", #selector(TerminalView.scrollToBottom(_:)), String(UnicodeScalar(NSEndFunctionKey)!), [.command])
        view.addItem(.separator())
        item(view, "Enter Full Screen", #selector(NSWindow.toggleFullScreen(_:)), "f", [.command, .control])

        let window = submenu(main, "Window")
        item(window, "Minimize", #selector(NSWindow.performMiniaturize(_:)), "m")
        item(window, "Zoom", #selector(NSWindow.performZoom(_:)), "")
        window.addItem(.separator())
        item(window, "Show Next Arrangement", #selector(MainWindowController.nextTab(_:)), "]", [.command, .shift])
        item(window, "Show Previous Arrangement", #selector(MainWindowController.previousTab(_:)), "[", [.command, .shift])
        item(window, "Switch to Recent Arrangement", #selector(MainWindowController.walkTabs(_:)), "\t", [.control])
        item(window, "Switch to Recent Arrangement, Backward", #selector(MainWindowController.walkTabsBack(_:)), "\t", [.control, .shift])
        for n in 1...9 {
            item(window, n == 9 ? "Select Last Arrangement" : "Select Arrangement \(n)", #selector(MainWindowController.selectTabByNumber(_:)), "\(n)").tag = n
        }
        window.addItem(.separator())
        item(window, "Go Back", #selector(MainWindowController.goBack(_:)), "[")
        item(window, "Go Forward", #selector(MainWindowController.goForward(_:)), "]")
        item(window, "Focus Next Tile", #selector(MainWindowController.nextTile(_:)), "]", [.command, .option])
        item(window, "Focus Previous Tile", #selector(MainWindowController.previousTile(_:)), "[", [.command, .option])
        window.addItem(.separator())
        item(window, "Show Links", #selector(MainWindowController.showLinks(_:)), "n", [.command, .option])
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
