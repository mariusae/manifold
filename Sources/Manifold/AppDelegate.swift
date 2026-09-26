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
        item(app, "End All Sessions and Quit…", #selector(MainWindowController.stopServer(_:)), "")
        app.addItem(withTitle: "Quit Manifold", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")

        let file = submenu(main, "File")
        item(file, "New Tab…", #selector(MainWindowController.newTab(_:)), "t")
        item(file, "New Terminal", #selector(MainWindowController.newTerminal(_:)), "t", [.command, .option])
        item(file, "Open Terminal to the Right", #selector(MainWindowController.splitRight(_:)), "d")
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
        item(window, "Focus Next Pane", #selector(MainWindowController.nextPane(_:)), "]")
        item(window, "Focus Previous Pane", #selector(MainWindowController.previousPane(_:)), "[")
        item(window, "Move Pane to New Tab", #selector(MainWindowController.movePaneToNewTab(_:)), "")
        item(window, "Separate Panes", #selector(MainWindowController.unsplitTab(_:)), "")
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
