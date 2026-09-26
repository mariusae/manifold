import AppKit
import ManifoldCore

final class AppDelegate: NSObject, NSApplicationDelegate {
    private let server = ServerClient()
    private var windowController: MainWindowController?
    private var createdFirstTab = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        signal(SIGPIPE, SIG_IGN)
        _ = GhosttyRuntime.shared
        NSApp.mainMenu = makeMainMenu()

        server.onState = { [weak self] ws in self?.stateChanged(ws) }
        server.onVersionMismatch = { [weak self] version in self?.serverIsStale(version) }
        server.connect()
        DebugControl.start { [weak self] in self?.windowController }
    }

    private func stateChanged(_ ws: Workspace) {
        GhosttyRuntime.shared.apply(ws.appearance)
        if windowController == nil {
            let wc = MainWindowController(server: server)
            windowController = wc
            // The very first time, start with a terminal rather than an empty
            // window.
            if ws.tabs.isEmpty && !createdFirstTab && !FileManager.default.fileExists(atPath: Paths.state.path) {
                createdFirstTab = true
                server.send(.newTab(tab: UUID(), pane: UUID(), kind: .terminal, cwd: nil, after: nil))
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
            alert.informativeText = "Manifold was updated, but its server is still the old one (protocol \(version), not \(protocolVersion)), so some things won't work until it's restarted. Your tabs are kept; each shell starts again in the same directory, under its recent output."
            alert.addButton(withTitle: "Restart Server")
            alert.addButton(withTitle: "Not Now")
            if alert.runModal() == .alertFirstButtonReturn {
                ServerClient.stopServer()
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
        app.addItem(.separator())
        item(app, "Restart Server…", #selector(MainWindowController.restartServer(_:)), "")
        item(app, "End All Sessions and Quit…", #selector(MainWindowController.stopServer(_:)), "")
        app.addItem(withTitle: "Quit Manifold", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")

        let file = submenu(main, "File")
        item(file, "New Tab…", #selector(MainWindowController.newTab(_:)), "t")
        item(file, "New Terminal", #selector(MainWindowController.newTerminal(_:)), "t", [.command, .option])
        item(file, "Open Terminal to the Right", #selector(MainWindowController.splitRight(_:)), "d")
        item(file, "Open…", #selector(MainWindowController.openDocument(_:)), "o")
        file.addItem(.separator())
        item(file, "Rename Tab…", #selector(MainWindowController.renameTab(_:)), "r", [.command, .shift])
        file.addItem(.separator())
        item(file, "Close", #selector(MainWindowController.closePaneOrTab(_:)), "w")
        item(file, "Close Tab", #selector(MainWindowController.closeTab(_:)), "w", [.command, .shift])

        let edit = submenu(main, "Edit")
        item(edit, "Copy", #selector(TerminalView.copy(_:)), "c")
        item(edit, "Paste", #selector(TerminalView.paste(_:)), "v")
        item(edit, "Select All", #selector(NSResponder.selectAll(_:)), "a")
        edit.addItem(.separator())
        item(edit, "Clear", #selector(TerminalView.clearScreen(_:)), "k")

        let view = submenu(main, "View")
        item(view, "Show Sidebar", #selector(MainWindowController.togglePinnedSidebar(_:)), "s", [.command, .control])
        view.addItem(.separator())
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
        item(window, "Show Next Tab", #selector(MainWindowController.nextTab(_:)), "]", [.command, .shift])
        item(window, "Show Previous Tab", #selector(MainWindowController.previousTab(_:)), "[", [.command, .shift])
        item(window, "Show Next Tab", #selector(MainWindowController.nextTab(_:)), "\t", [.control]).isAlternate = false
        item(window, "Show Previous Tab", #selector(MainWindowController.previousTab(_:)), "\t", [.control, .shift])
        for n in 1...9 {
            item(window, n == 9 ? "Select Last Tab" : "Select Tab \(n)", #selector(MainWindowController.selectTabByNumber(_:)), "\(n)").tag = n
        }
        window.addItem(.separator())
        item(window, "Cycle Stack", #selector(MainWindowController.cycleStack(_:)), "e")
        item(window, "Focus Next Pane", #selector(MainWindowController.nextPane(_:)), "]")
        item(window, "Focus Previous Pane", #selector(MainWindowController.previousPane(_:)), "[")
        item(window, "Move Pane to New Tab", #selector(MainWindowController.movePaneToNewTab(_:)), "")
        item(window, "Separate Columns", #selector(MainWindowController.unsplitTab(_:)), "")
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
