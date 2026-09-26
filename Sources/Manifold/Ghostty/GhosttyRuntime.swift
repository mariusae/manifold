import AppKit
import Carbon
import GhosttyKit
import ManifoldCore

/// The one ghostty app, which every terminal surface belongs to.
final class GhosttyRuntime {
    static let shared = GhosttyRuntime()

    private(set) var app: ghostty_app_t?
    private var config: ghostty_config_t?

    static let background = NSColor.dynamic(
        NSColor(srgbRed: 0xfc / 255, green: 0xfc / 255, blue: 0xfb / 255, alpha: 1),
        NSColor(srgbRed: 0x1c / 255, green: 0x1c / 255, blue: 0x1b / 255, alpha: 1))

    /// Paper, and GitHub's light palette.
    private static let lightColors = """
        background = #fcfcfb
        foreground = #24292f
        cursor-color = #007aff
        selection-background = #cfe2fb
        selection-foreground = #1f2328
        palette = 0=#24292f
        palette = 1=#cf222e
        palette = 2=#116329
        palette = 3=#4d2d00
        palette = 4=#0969da
        palette = 5=#8250df
        palette = 6=#1b7c83
        palette = 7=#6e7781
        palette = 8=#57606a
        palette = 9=#a40e26
        palette = 10=#1a7f37
        palette = 11=#633c01
        palette = 12=#218bff
        palette = 13=#a475f9
        palette = 14=#3192aa
        palette = 15=#8c959f
        """

    /// The same paper, unlit, and GitHub's dark palette.
    private static let darkColors = """
        background = #1c1c1b
        foreground = #e3e3df
        cursor-color = #0a84ff
        selection-background = #264f78
        selection-foreground = #f0f0ee
        palette = 0=#484f58
        palette = 1=#ff7b72
        palette = 2=#3fb950
        palette = 3=#d29922
        palette = 4=#58a6ff
        palette = 5=#bc8cff
        palette = 6=#39c5cf
        palette = 7=#b1bac4
        palette = 8=#6e7681
        palette = 9=#ffa198
        palette = 10=#56d364
        palette = 11=#e3b341
        palette = 12=#79c0ff
        palette = 13=#d2a8ff
        palette = 14=#56d4dd
        palette = 15=#f0f6fc
        """

    private static let baseConfig = """
        font-size = 13
        font-thicken = false
        cursor-style = bar
        cursor-style-blink = true
        adjust-cursor-thickness = 3
        minimum-contrast = 1.1
        window-padding-x = 10
        window-padding-y = 6
        window-padding-balance = true
        window-padding-color = extend
        keybind = clear
        confirm-close-surface = false
        wait-after-command = false
        shell-integration = none
        mouse-hide-while-typing = true
        copy-on-select = false
        clipboard-read = allow
        clipboard-write = allow
        app-notifications = false
        """

    private static func configText(_ appearance: Appearance, dark: Bool) -> String {
        let mode = switch appearance.contrastCorrection {
        case .off: "none"
        case .typical: "typical"
        case .deuteranopia: "deuteranopia"
        }
        return baseConfig + "\n" + (dark ? darkColors : lightColors) + "\n" + appearance.theme.terminalConfig + "\ncontrast-correction = \(mode)\n"
    }

    private static func makeConfig(_ appearance: Appearance, dark: Bool) -> ghostty_config_t? {
        let config = ghostty_config_new()
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("manifold-ghostty-\(getpid()).conf")
        try? configText(appearance, dark: dark).write(to: url, atomically: true, encoding: .utf8)
        ghostty_config_load_file(config, url.path)
        try? FileManager.default.removeItem(at: url)
        ghostty_config_finalize(config)
        for i in 0..<ghostty_config_diagnostics_count(config) {
            let d = ghostty_config_get_diagnostic(config, i)
            NSLog("ghostty config: %@", String(cString: d.message))
        }
        return config
    }

    private var appearance = Appearance()
    private var dark = NSApp.effectiveAppearance.isDark

    /// Recolors (and resets in the theme's fonts) every terminal.
    func apply(_ appearance: Appearance, dark: Bool) {
        guard appearance != self.appearance || dark != self.dark, let app else { return }
        self.appearance = appearance
        self.dark = dark
        guard let config = Self.makeConfig(appearance, dark: dark) else { return }
        ghostty_app_update_config(app, config)
        // Programs that ask (mode 2031) are told, too.
        ghostty_app_set_color_scheme(app, dark ? GHOSTTY_COLOR_SCHEME_DARK : GHOSTTY_COLOR_SCHEME_LIGHT)
        if let old = self.config { ghostty_config_free(old) }
        self.config = config
    }

    private init() {
        Self.registerBundledFonts()
        FontTheme.registerSystemMono()
        // Ghostty finds terminfo and shell integration next to its resources.
        if let res = Bundle.main.resourceURL?.appendingPathComponent("ghostty"),
           FileManager.default.fileExists(atPath: res.path) {
            setenv("GHOSTTY_RESOURCES_DIR", res.path, 1)
        }
        guard ghostty_init(UInt(CommandLine.argc), CommandLine.unsafeArgv) == GHOSTTY_SUCCESS else {
            fatalError("ghostty_init failed")
        }

        let config = Self.makeConfig(appearance, dark: dark)
        self.config = config

        var runtime = ghostty_runtime_config_s()
        runtime.userdata = Unmanaged.passUnretained(self).toOpaque()
        runtime.supports_selection_clipboard = false
        runtime.wakeup_cb = { _ in
            DispatchQueue.main.async { GhosttyRuntime.shared.tick() }
        }
        runtime.action_cb = { app, target, action in
            GhosttyRuntime.shared.handle(action: action, target: target)
        }
        runtime.read_clipboard_cb = { userdata, _, state in
            guard let view = TerminalView.from(userdata), let surface = view.surface else { return false }
            let str = NSPasteboard.general.string(forType: .string) ?? ""
            str.withCString { ghostty_surface_complete_clipboard_request(surface, $0, state, false) }
            return true
        }
        runtime.confirm_read_clipboard_cb = { userdata, str, state, _ in
            // clipboard-read is "allow", so this is only for unsafe pastes;
            // paste them anyway, as Terminal.app would.
            guard let view = TerminalView.from(userdata), let surface = view.surface else { return }
            ghostty_surface_complete_clipboard_request(surface, str, state, true)
        }
        runtime.write_clipboard_cb = { _, location, content, len, _ in
            guard location == GHOSTTY_CLIPBOARD_STANDARD, let content, len > 0 else { return }
            let pb = NSPasteboard.general
            pb.clearContents()
            for i in 0..<len {
                let item = content[i]
                guard let data = item.data else { continue }
                let mime = item.mime.map { String(cString: $0) } ?? "text/plain"
                if mime.hasPrefix("text/plain") {
                    pb.setString(String(cString: data), forType: .string)
                }
            }
        }
        runtime.close_surface_cb = { userdata, _ in
            guard let view = TerminalView.from(userdata) else { return }
            DispatchQueue.main.async { view.surfaceClosed() }
        }
        app = ghostty_app_new(&runtime, config)
        guard app != nil else { fatalError("ghostty_app_new failed") }

        ghostty_app_set_color_scheme(app, dark ? GHOSTTY_COLOR_SCHEME_DARK : GHOSTTY_COLOR_SCHEME_LIGHT)
        let nc = NotificationCenter.default
        nc.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            if let app = self?.app { ghostty_app_set_focus(app, true) }
        }
        nc.addObserver(forName: NSApplication.didResignActiveNotification, object: nil, queue: .main) { [weak self] _ in
            if let app = self?.app { ghostty_app_set_focus(app, false) }
        }
        DistributedNotificationCenter.default().addObserver(
            forName: NSNotification.Name(kTISNotifySelectedKeyboardInputSourceChanged as String),
            object: nil, queue: .main
        ) { [weak self] _ in
            if let app = self?.app { ghostty_app_keyboard_changed(app) }
        }
    }

    /// Makes the fonts in Resources/Fonts (Monaspace, Mona Sans, Recursive,
    /// Go) available to this
    /// process only; nothing is installed.
    private static func registerBundledFonts() {
        guard let dir = Bundle.main.resourceURL?.appendingPathComponent("Fonts"),
              let files = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
        else { return }
        for url in files where ["otf", "ttf"].contains(url.pathExtension) {
            var error: Unmanaged<CFError>?
            if !CTFontManagerRegisterFontsForURL(url as CFURL, .process, &error) {
                NSLog("manifold: could not register %@: %@", url.lastPathComponent,
                      String(describing: error?.takeRetainedValue()))
            }
        }
    }

    func tick() {
        if let app { ghostty_app_tick(app) }
    }

    private func handle(action: ghostty_action_s, target: ghostty_target_s) -> Bool {
        let view: TerminalView? = target.tag == GHOSTTY_TARGET_SURFACE
            ? TerminalView.from(ghostty_surface_userdata(target.target.surface)) : nil
        switch action.tag {
        case GHOSTTY_ACTION_MOUSE_SHAPE:
            view?.setCursor(action.action.mouse_shape)
            return true
        case GHOSTTY_ACTION_MOUSE_VISIBILITY:
            NSCursor.setHiddenUntilMouseMoves(action.action.mouse_visibility == GHOSTTY_MOUSE_HIDDEN)
            return true
        case GHOSTTY_ACTION_CELL_SIZE:
            let s = action.action.cell_size
            view?.cellSize = NSSize(width: Double(s.width), height: Double(s.height))
            return true
        case GHOSTTY_ACTION_OPEN_URL:
            let u = action.action.open_url
            guard let ptr = u.url else { return false }
            let str = String(decoding: UnsafeRawBufferPointer(start: ptr, count: Int(u.len)), as: UTF8.self)
            if let view, let delegate = view.delegate {
                delegate.terminal(view, open: str)
            } else if let url = URL(string: str), url.scheme != nil {
                NSWorkspace.shared.open(url)
            } else {
                NSWorkspace.shared.open(URL(fileURLWithPath: str))
            }
            return true
        case GHOSTTY_ACTION_RING_BELL:
            NSSound.beep()
            return true
        case GHOSTTY_ACTION_RENDER, GHOSTTY_ACTION_SET_TITLE, GHOSTTY_ACTION_PWD,
             GHOSTTY_ACTION_COLOR_CHANGE, GHOSTTY_ACTION_RENDERER_HEALTH, GHOSTTY_ACTION_SCROLLBAR,
             GHOSTTY_ACTION_MOUSE_OVER_LINK, GHOSTTY_ACTION_CONFIG_CHANGE, GHOSTTY_ACTION_SIZE_LIMIT,
             GHOSTTY_ACTION_INITIAL_SIZE, GHOSTTY_ACTION_SHOW_CHILD_EXITED, GHOSTTY_ACTION_COMMAND_FINISHED,
             GHOSTTY_ACTION_PROGRESS_REPORT, GHOSTTY_ACTION_KEY_SEQUENCE, GHOSTTY_ACTION_KEY_TABLE:
            // Titles and directories come from the server, which sees the
            // same output; the rest we don't show.
            return true
        default:
            return false
        }
    }
}
