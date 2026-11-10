import AppKit
import Carbon
import GhosttyKit
import ManifoldCore

/// The one ghostty app, which every terminal surface belongs to.
final class GhosttyRuntime {
    static let shared = GhosttyRuntime()

    private(set) var app: ghostty_app_t?
    private var config: ghostty_config_t?

    private static let baseConfig = """
        font-size = 13
        font-thicken = false
        cursor-style = bar
        cursor-style-blink = true
        adjust-cursor-thickness = 3
        minimum-contrast = 1.1
        window-padding-x = 11,10
        window-padding-y = 6
        window-padding-balance = false
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
        link-url = false
        """

    static func debugConfigText(dark: Bool) -> String { configText(shared.appearance, dark: dark) }

    /// Debugging: the 256 colours Ghostty makes of the config, as it reads it.
    static func debugResolvedPalette(dark: Bool) -> String {
        guard let config = makeConfig(shared.appearance, dark: dark) else { return "no config" }
        defer { ghostty_config_free(config) }
        var palette = ghostty_config_palette_s()
        let key = "palette"
        guard ghostty_config_get(config, &palette, key, UInt(key.utf8.count)) else { return "no palette" }
        return withUnsafeBytes(of: palette.colors) { raw in
            raw.bindMemory(to: ghostty_config_color_s.self).enumerated().map { i, c in
                String(format: "%d=#%02x%02x%02x", i, c.r, c.g, c.b)
            }.joined(separator: " ")
        }
    }

    private static func configText(_ appearance: Appearance, dark: Bool) -> String {
        let mode = switch appearance.contrastCorrection {
        case .off: "none"
        case .typical: "typical"
        case .deuteranopia: "deuteranopia"
        }
        // The caret and selection in an accent chosen, over the palette's;
        // the theme's own accent, the palette's own.
        let tint = appearance.tint == .theme ? ""
            : "cursor-color = \(Tints.hex(appearance.tint.caret, dark: dark))\nselection-background = \(Tints.hex(appearance.tint.textSelection, dark: dark))\n"
        return baseConfig + "\n" + TerminalPalette.current(dark: dark).config + "\n" + tint + (appearance.theme == .custom ? appearance.typography.monospaced.terminalConfig : appearance.theme.terminalConfig) + "\ncontrast-correction = \(mode)\n"
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
    /// `force`: though nothing in it changed (the system's accent color,
    /// which the System tint follows, did).
    func apply(_ appearance: Appearance, dark: Bool, force: Bool = false) {
        guard force || appearance != self.appearance || dark != self.dark, let app else { return }
        self.appearance = appearance
        self.dark = dark
        guard let config = Self.makeConfig(appearance, dark: dark) else { return }
        ghostty_app_update_config(app, config)
        // Programs that ask (mode 2031) are told, too.
        ghostty_app_set_color_scheme(app, dark ? GHOSTTY_COLOR_SCHEME_DARK : GHOSTTY_COLOR_SCHEME_LIGHT)
        if let old = self.config { ghostty_config_free(old) }
        self.config = config
    }

    /// Every terminal recolored as it is (the system's accent changed).
    func reapply() { apply(appearance, dark: dark, force: true) }

    private init() {
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
            // Not `shared`: this can come while `shared` is still being
            // made (setting the color scheme below asks for a redraw).
            guard let app, let userdata = ghostty_app_userdata(app) else { return false }
            return Unmanaged<GhosttyRuntime>.fromOpaque(userdata).takeUnretainedValue()
                .handle(action: action, target: target)
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
            view?.linkOpened = true
            if let view, let delegate = view.delegate {
                delegate.terminal(view, open: str, over: view.openOver)
            } else if let url = URL(string: str), url.scheme != nil {
                NSWorkspace.shared.open(url)
            } else {
                NSWorkspace.shared.open(URL(fileURLWithPath: str))
            }
            return true
        case GHOSTTY_ACTION_MOUSE_OVER_LINK:
            // A program's own link (OSC 8) under the pointer, or none: one
            // that leads nowhere says so.
            let l = action.action.mouse_over_link
            let str = l.url.map { String(decoding: UnsafeRawBufferPointer(start: $0, count: Int(l.len)), as: UTF8.self) }
            DispatchQueue.main.async { view?.overLink(str.flatMap { $0.isEmpty ? nil : $0 }) }
            return true
        case GHOSTTY_ACTION_RING_BELL:
            // Only on the Mac its host is attached to (§8.2): every Mac with
            // the terminal open hears its output.
            DispatchQueue.main.async {
                if view.map({ TerminalView.ringsHere($0.block) }) ?? true { NSSound.beep() }
            }
            return true
        // Search (§3.1 Find): the core finds and highlights; it tells us how
        // many and which is selected, and asks for the pill when a binding
        // of its own starts or ends a search.
        case GHOSTTY_ACTION_START_SEARCH:
            let s = action.action.start_search
            let needle = s.needle.map { String(cString: $0) } ?? ""
            DispatchQueue.main.async { view?.searchStarted(needle: needle) }
            return true
        case GHOSTTY_ACTION_END_SEARCH:
            DispatchQueue.main.async { view?.searchEnded() }
            return true
        case GHOSTTY_ACTION_SEARCH_TOTAL:
            let total = action.action.search_total.total
            DispatchQueue.main.async { view?.searchTotal(total >= 0 ? Int(total) : nil) }
            return true
        case GHOSTTY_ACTION_SEARCH_SELECTED:
            let selected = action.action.search_selected.selected
            DispatchQueue.main.async { view?.searchSelected(selected >= 0 ? Int(selected) : nil) }
            return true
        case GHOSTTY_ACTION_SCROLLBAR:
            let s = action.action.scrollbar
            view?.noteScrollbar(total: Int(s.total), offset: Int(s.offset), len: Int(s.len))
            return true
        case GHOSTTY_ACTION_RENDER, GHOSTTY_ACTION_SET_TITLE, GHOSTTY_ACTION_PWD,
             GHOSTTY_ACTION_COLOR_CHANGE, GHOSTTY_ACTION_RENDERER_HEALTH,
             GHOSTTY_ACTION_CONFIG_CHANGE, GHOSTTY_ACTION_SIZE_LIMIT,
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
