import AppKit
import ManifoldCore

/// Settings (⌘,): every setting in one window, a pane each — how things
/// look, terminals, history, how hosts are reached, language servers.
final class SettingsWindow: NSWindowController {
    enum Pane: Int, CaseIterable { case appearance, typography, terminals, history, remoting, languageServers }

    let source = SettingsSource()
    let appearance: AppearancePane
    let typography: TypographyPane
    let terminals: TerminalsPane
    let history: HistoryPane
    let remoting = RemotingPane()
    let languageServers = LanguageServersPane()
    private let tabs = NSTabViewController()
    /// Typography's tab: there only with advanced typography on.
    private var typographyItem: NSTabViewItem?

    init() {
        appearance = AppearancePane(source)
        typography = TypographyPane(source)
        terminals = TerminalsPane(source)
        history = HistoryPane(source)
        tabs.tabStyle = .toolbar
        tabs.transitionOptions = [.crossfade, .allowUserInteraction]
        let panes: [(NSViewController, String)] = [
            (appearance, "paintpalette"), (typography, "textformat"), (terminals, "terminal"), (history, "clock.arrow.circlepath"),
            (remoting, "network"), (languageServers, "curlybraces"),
        ]
        for (vc, symbol) in panes {
            let item = NSTabViewItem(viewController: vc)
            item.label = vc.title ?? ""
            item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: vc.title)
            if vc === typography { typographyItem = item } else { tabs.addTabViewItem(item) }
        }
        let window = NSWindow(contentViewController: tabs)
        window.styleMask = [.titled, .closable]
        window.toolbarStyle = .preference
        window.backgroundColor = Theme.windowBackground
        super.init(window: window)
        window.center()
    }

    required init?(coder: NSCoder) { fatalError() }

    /// Typography's tab put in or taken out, as advanced typography is on.
    private func showTypographyTab() {
        guard let item = typographyItem else { return }
        let on = source.appearance().advancedTypography
        let shown = tabs.tabViewItems.contains(item)
        if on, !shown { tabs.insertTabViewItem(item, at: 1) }
        if !on, shown { tabs.removeTabViewItem(item) }
    }

    /// The tab of a pane, if it's there.
    private func index(of pane: Pane) -> Int? {
        let vc: NSViewController = switch pane {
        case .appearance: appearance
        case .typography: typography
        case .terminals: terminals
        case .history: history
        case .remoting: remoting
        case .languageServers: languageServers
        }
        return tabs.tabViewItems.firstIndex { $0.viewController === vc }
    }

    /// Shown, at `pane` if one is asked for.
    func show(_ pane: Pane? = nil) {
        showTypographyTab()
        if let pane, let i = index(of: pane) { tabs.selectedTabViewItemIndex = i }
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        refresh()
    }

    /// The panes as the settings are now (another Mac changed them);
    /// `tables`: the remoting and language servers' too (not at every render).
    func refresh(tables: Bool = true) {
        guard window?.isVisible == true else { return }
        showTypographyTab()
        for vc in [appearance, typography, terminals, history] as [SettingsPane] where vc.isViewLoaded { vc.refresh() }
        guard tables else { return }
        if remoting.isViewLoaded { remoting.refresh() }
        if languageServers.isViewLoaded { languageServers.refresh() }
    }

    var debugState: String {
        let pane = Pane.allCases.first { index(of: $0) == tabs.selectedTabViewItemIndex }.map { "\($0)" } ?? "?"
        return "\(window?.isVisible == true ? "shown" : "hidden") at \(pane), \(Int(window?.frame.width ?? 0))×\(Int(window?.frame.height ?? 0))"
    }
}

/// Where the panes read and write: this Mac's appearance, and the
/// settings every Mac attached shares.
final class SettingsSource {
    var appearance: () -> Appearance = { Appearance() }
    var setAppearance: (Appearance) -> Void = { _ in }
    var settings: () -> Settings = { Settings() }
    var setSettings: (Settings) -> Void = { _ in }

    func change(_ edit: (inout Appearance) -> Void) {
        var a = appearance()
        edit(&a)
        setAppearance(a)
    }

    func change(_ edit: (inout Settings) -> Void) {
        var s = settings()
        edit(&s)
        setSettings(s)
    }
}

/// A pane of settings, as a form: a label on the left of each row, right
/// aligned, what it sets on the right, a note under it if it needs one.
class SettingsPane: NSViewController {
    let source: SettingsSource
    private let form = NSGridView()
    static let width: CGFloat = 600

    init(_ source: SettingsSource, title: String) {
        self.source = source
        super.init(nibName: nil, bundle: nil)
        self.title = title
    }

    required init?(coder: NSCoder) { fatalError() }

    override func loadView() {
        view = NSView(frame: NSRect(x: 0, y: 0, width: Self.width, height: 200))
        form.translatesAutoresizingMaskIntoConstraints = false
        form.rowSpacing = 14
        form.columnSpacing = 12
        view.addSubview(form)
        NSLayoutConstraint.activate([
            form.topAnchor.constraint(equalTo: view.topAnchor, constant: 24),
            form.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 24),
            form.trailingAnchor.constraint(lessThanOrEqualTo: view.trailingAnchor, constant: -24),
            form.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -24),
            view.widthAnchor.constraint(equalToConstant: Self.width),
        ])
        build()
        form.column(at: 0).xPlacement = .trailing
        refresh()
        preferredContentSize = view.fittingSize
    }

    func build() {}
    func refresh() {}

    /// A row: its label, and what it sets — sized as it wants to be.
    func row(_ label: String, _ control: NSView, note: String? = nil, top: Bool = false) {
        let l = NSTextField(labelWithString: label.isEmpty ? "" : label + ":")
        l.font = UIType.row
        l.textColor = Theme.text
        control.setContentHuggingPriority(.required, for: .horizontal)
        let r = form.addRow(with: [l, control])
        r.yPlacement = .center
        // A tall one's label beside its first line.
        if top {
            r.yPlacement = .top
            r.cell(at: 0).customPlacementConstraints = [l.topAnchor.constraint(equalTo: control.topAnchor, constant: 4)]
        }
        if let note {
            let n = NSTextField(wrappingLabelWithString: note)
            n.font = UIType.footnote
            n.textColor = Theme.secondaryText
            n.preferredMaxLayoutWidth = Self.width - 200
            let nr = form.addRow(with: [NSGridCell.emptyContentView, n])
            nr.topPadding = -8
        }
    }

    /// A gap before the next group of rows.
    func gap() {
        let r = form.addRow(with: [NSGridCell.emptyContentView, NSGridCell.emptyContentView])
        r.height = 4
    }

    /// Choices in a row of segments, `values` in their order.
    func segments<T: Equatable>(_ titles: [String], _ values: [T], set: @escaping (T) -> Void) -> (FlatSegments, (T) -> Void) {
        let s = FlatSegments(titles: titles, font: UIType.body)
        s.onChange = { i in if i < values.count { set(values[i]) } }
        return (s, { v in s.selectedSegment = values.firstIndex(of: v) ?? 0 })
    }
}

// MARK: Appearance

final class AppearancePane: SettingsPane {
    private var showScheme: ((ColorScheme) -> Void)?
    private var showEditor: ((EditorFont) -> Void)?
    private var showContrast: ((ContrastCorrection) -> Void)?
    private let tints = TintPicker()
    private let colorThemes = ColorThemePicker()
    private let themes = FontThemeList()
    private let advanced = Flat.checkbox("Enable advanced typography")

    init(_ source: SettingsSource) { super.init(source, title: "Appearance") }
    required init?(coder: NSCoder) { fatalError() }

    override func build() {
        let (scheme, s) = segments(["Match System", "Light", "Dark"], [ColorScheme.system, .light, .dark]) { [weak self] v in
            self?.source.change { (a: inout Appearance) in a.colorScheme = v }
        }
        showScheme = s
        row("Appearance", scheme)
        colorThemes.onPick = { [weak self] p in self?.source.change { (a: inout Appearance) in a.colorTheme = p.id } }
        row("Theme", colorThemes, note: "Every color: the window and its backdrop, text, terminals' palettes, diffs, the preview's page. Each in light and dark.")
        tints.onPick = { [weak self] t in self?.source.change { (a: inout Appearance) in a.tint = t } }
        row("Accent", tints, note: "The focus ring, what's chosen, the caret and selections, and a pool of light in the backdrop. Theme: the theme's own; any other, over it.")
        gap()
        themes.onPick = { [weak self] t in self?.source.change { (a: inout Appearance) in a.theme = t } }
        row("Fonts", themes, top: true)
        advanced.target = self
        advanced.action = #selector(toggleAdvanced)
        row("", advanced, note: "A Typography pane, and a Custom theme: each role's face, size, spacing and OpenType features.")
        let (editor, e) = segments(["Editing Font", "Monospaced"], [EditorFont.proportional, .monospaced]) { [weak self] v in
            self?.source.change { (a: inout Appearance) in a.editorFont = v }
        }
        showEditor = e
        row("Editor Text", editor)
        gap()
        let (contrast, c) = segments(["Off", "Typical Vision", "Typical and Deuteranopia"], [ContrastCorrection.off, .typical, .deuteranopia]) { [weak self] v in
            self?.source.change { (a: inout Appearance) in a.contrastCorrection = v }
        }
        showContrast = c
        row("Contrast", contrast, note: "Text in a program's own colors that doesn't reach WCAG AA on its background is moved in lightness, keeping its hue, until it does.")
    }

    override func refresh() {
        let a = source.appearance()
        showScheme?(a.colorScheme)
        colorThemes.chosen = a.colorTheme
        tints.tint = a.tint
        themes.advanced = a.advancedTypography
        themes.theme = a.theme
        advanced.state = a.advancedTypography ? .on : .off
        showEditor?(a.editorFont)
        showContrast?(a.contrastCorrection)
    }

    /// Advanced typography on (Typography's pane, Custom offered) or off —
    /// leaving Custom, if it was set in it, for Apple.
    @objc private func toggleAdvanced() {
        let on = advanced.state == .on
        source.change { (a: inout Appearance) in
            a.advancedTypography = on
            if !on, a.theme == .custom { a.theme = .apple }
        }
    }

    /// For DebugControl: advanced typography turned on or off, as a click would.
    func debugSetAdvanced(_ on: Bool) {
        advanced.state = on ? .on : .off
        toggleAdvanced()
    }

    /// For DebugControl: a tint picked, as a click on its swatch.
    func debugPickTint(_ t: Tint) { tints.debugPick(t) }

    /// For DebugControl: a colour theme picked, as a click on its card.
    func debugPickColorTheme(_ id: String) { colorThemes.debugPick(id) }
}

/// The tints, as swatches: the one chosen ringed, its name beside them.
final class TintPicker: NSView {
    var tint: Tint = .blue { didSet { needsDisplay = true; name.stringValue = tint.title; needsLayout = true } }
    var onPick: ((Tint) -> Void)?
    private let name = NSTextField(labelWithString: "")
    private var hovered: Int? { didSet { if hovered != oldValue { needsDisplay = true } } }
    private static let side: CGFloat = 20, spacing: CGFloat = 10

    override init(frame: NSRect) {
        super.init(frame: frame)
        name.font = UIType.body
        name.textColor = Theme.secondaryText
        addSubview(name)
        for (i, t) in Tint.allCases.enumerated() { addToolTip(rect(i), owner: t.title as NSString, userData: nil) }
    }

    required init?(coder: NSCoder) { fatalError() }

    private var swatchesWidth: CGFloat { CGFloat(Tint.allCases.count) * (Self.side + Self.spacing) - Self.spacing }
    override var intrinsicContentSize: NSSize { NSSize(width: swatchesWidth + 12 + 80, height: Self.side + 6) }

    private func rect(_ i: Int) -> NSRect {
        NSRect(x: 3 + CGFloat(i) * (Self.side + Self.spacing), y: 3, width: Self.side, height: Self.side)
    }

    override func layout() {
        super.layout()
        name.sizeToFit()
        name.frame.origin = NSPoint(x: swatchesWidth + 14, y: (bounds.height - name.frame.height) / 2)
    }

    override func draw(_ dirtyRect: NSRect) {
        for (i, t) in Tint.allCases.enumerated() {
            let r = rect(i)
            if t == .system {
                // System: the system's own colours round it, as macOS draws
                // its Multicolor — not a second blue beside Blue.
                let colors: [NSColor] = [.systemRed, .systemOrange, .systemYellow, .systemGreen, .systemBlue, .systemPurple, .systemPink]
                let c = NSPoint(x: r.midX, y: r.midY)
                for (k, color) in colors.enumerated() {
                    let wedge = NSBezierPath()
                    wedge.move(to: c)
                    wedge.appendArc(withCenter: c, radius: r.width / 2, startAngle: CGFloat(k) * 360 / CGFloat(colors.count) + 90,
                                    endAngle: CGFloat(k + 1) * 360 / CGFloat(colors.count) + 90)
                    wedge.close()
                    color.setFill()
                    wedge.fill()
                }
            } else if t == .theme {
                // Theme: its accent on its paper, halved across.
                Theme.windowBackground.setFill()
                NSBezierPath(ovalIn: r).fill()
                NSGraphicsContext.saveGraphicsState()
                NSBezierPath(ovalIn: r).addClip()
                let half = NSBezierPath()
                half.move(to: NSPoint(x: r.minX, y: r.minY))
                half.line(to: NSPoint(x: r.maxX, y: r.minY))
                half.line(to: NSPoint(x: r.maxX, y: r.maxY))
                half.close()
                t.accent.setFill()
                half.fill()
                NSGraphicsContext.restoreGraphicsState()
                EdgeColor.hairline.setStroke()
                NSBezierPath(ovalIn: r.insetBy(dx: 0.25, dy: 0.25)).stroke()
            } else {
                t.accent.setFill()
                NSBezierPath(ovalIn: r).fill()
            }
            if t == tint || hovered == i {
                let ring = NSBezierPath(ovalIn: r.insetBy(dx: -2.5, dy: -2.5))
                ring.lineWidth = 1.5
                (t == tint ? Theme.text : Theme.secondaryText.withAlphaComponent(0.5)).setStroke()
                ring.stroke()
            }
            // System: half the swatch its blend of the others, as macOS draws it.
            if t == .system {
                NSColor.white.withAlphaComponent(0.85).setFill()
                NSBezierPath(ovalIn: r.insetBy(dx: 6.5, dy: 6.5)).fill()
            }
        }
    }

    private func index(at p: NSPoint) -> Int? {
        Tint.allCases.indices.first { rect($0).insetBy(dx: -4, dy: -4).contains(p) }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self))
    }

    override func mouseMoved(with event: NSEvent) { hovered = index(at: convert(event.locationInWindow, from: nil)) }
    override func mouseExited(with event: NSEvent) { hovered = nil }
    override func resetCursorRects() { for i in Tint.allCases.indices { addCursorRect(rect(i), cursor: .pointingHand) } }

    override func mouseDown(with event: NSEvent) {
        guard let i = index(at: convert(event.locationInWindow, from: nil)) else { return }
        let t = Tint.allCases[i]
        tint = t
        onPick?(t)
    }

    /// For DebugControl: a tint picked, as a click would.
    func debugPick(_ t: Tint) { tint = t; onPick?(t) }
}

/// The colour themes, each a small Manifold window in its own colours as
/// the appearance has them — a sidebar with a row chosen and blocks'
/// states, an editor's tile (its gutter, a lit line, the caret, changes
/// marked) and a terminal's, focused, a test run in its palette — its
/// name under it, the chosen one ringed.
final class ColorThemePicker: NSView {
    var chosen = Palette.paper.id { didSet { if chosen != oldValue { needsDisplay = true } } }
    var onPick: ((Palette) -> Void)?
    private var hovered: Int? { didSet { if hovered != oldValue { needsDisplay = true } } }
    private static let card = NSSize(width: 214, height: 136), label: CGFloat = 22, spacing: CGFloat = 14

    override init(frame: NSRect) {
        super.init(frame: frame)
        for (i, p) in Palette.all.enumerated() { addToolTip(rect(i), owner: p.title as NSString, userData: nil) }
    }

    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }
    override var intrinsicContentSize: NSSize {
        NSSize(width: CGFloat(Palette.all.count) * (Self.card.width + Self.spacing) - Self.spacing + 6, height: Self.card.height + Self.label + 6)
    }

    private func rect(_ i: Int) -> NSRect {
        NSRect(origin: NSPoint(x: 3 + CGFloat(i) * (Self.card.width + Self.spacing), y: 3), size: Self.card)
    }

    override func draw(_ dirtyRect: NSRect) {
        let dark = effectiveAppearance.isDark
        for (i, p) in Palette.all.enumerated() {
            let r = rect(i)
            let shape = NSBezierPath(roundedRect: r, xRadius: Radius.control, yRadius: Radius.control)
            NSGraphicsContext.saveGraphicsState()
            shape.addClip()
            Self.drawWindow(p, dark: dark, in: r)
            NSGraphicsContext.restoreGraphicsState()
            let isChosen = p.id == chosen
            (isChosen ? Theme.text : hovered == i ? EdgeColor.controlHovered : EdgeColor.hairline).setStroke()
            let edge = isChosen ? NSBezierPath(roundedRect: r.insetBy(dx: -2.5, dy: -2.5), xRadius: Radius.control + 2.5, yRadius: Radius.control + 2.5) : shape
            edge.lineWidth = isChosen ? 1.5 : 0.5
            edge.stroke()
            let name = NSAttributedString(string: p.title, attributes: [.font: isChosen ? UIType.title : UIType.body,
                                                                        .foregroundColor: isChosen ? Theme.text : Theme.secondaryText])
            name.draw(at: NSPoint(x: r.midX - name.size().width / 2, y: r.maxY + 5))
        }
    }

    /// A window as the theme draws one, in `r`.
    private static func drawWindow(_ p: Palette, dark: Bool, in r: NSRect) {
        func c(_ s: Shade) -> NSColor { s.color(dark: dark) }
        let terminal = dark ? p.terminal.dark : p.terminal.light
        let accent = c(p.accent.accent)
        // Its backdrop's wash, under the sidebar and between the tiles.
        let wash = BackdropView.colors(of: p.backdrop.wash(dark: dark)).map(\.cgColor)
        if let ctx = NSGraphicsContext.current?.cgContext,
           let g = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: wash as CFArray, locations: [0, 0.4, 0.75, 1]) {
            ctx.drawLinearGradient(g, start: CGPoint(x: r.minX, y: r.minY), end: CGPoint(x: r.maxX, y: r.maxY), options: [])
        } else {
            c(p.window).setFill()
            r.fill()
        }

        // The sidebar: blocks, one chosen, their states at the ends.
        let side = NSRect(x: r.minX, y: r.minY, width: 58, height: r.height)
        c(p.chrome.hover).setFill()
        side.fill()
        for k in 0..<3 { NSColor(white: 0.5, alpha: 0.5).setFill(); NSBezierPath(ovalIn: NSRect(x: side.minX + 6 + CGFloat(k) * 7, y: side.minY + 6, width: 4.5, height: 4.5)).fill() }
        let states: [Shade?] = [nil, p.status.done, nil, p.status.attention, nil, p.status.failed, nil]
        for (k, state) in states.enumerated() {
            let y = side.minY + 18 + CGFloat(k) * 14
            if k == 2 {
                accent.withAlphaComponent(dark ? 0.30 : 0.16).setFill()
                NSBezierPath(roundedRect: NSRect(x: side.minX + 3, y: y - 3.5, width: side.width - 6, height: 12), xRadius: 3, yRadius: 3).fill()
            }
            c(p.text.secondary).setFill()
            NSBezierPath(roundedRect: NSRect(x: side.minX + 7, y: y, width: 5, height: 5), xRadius: 1, yRadius: 1).fill()
            c(k == 2 ? p.text.primary : p.text.secondary).withAlphaComponent(0.85).setFill()
            NSBezierPath(roundedRect: NSRect(x: side.minX + 15, y: y + 1, width: [26, 20, 30, 22, 18, 27, 24][k], height: 3), xRadius: 1.5, yRadius: 1.5).fill()
            if let state {
                c(state).setFill()
                NSBezierPath(ovalIn: NSRect(x: side.maxX - 10, y: y + 0.5, width: 4, height: 4)).fill()
            }
        }

        let mono = NSFont.systemMono(ofSize: 6.5, weight: .regular)
        let bold = NSFont.systemMono(ofSize: 6.5, weight: .bold)
        let barFont = NSFont.systemFont(ofSize: 6.5, weight: .semibold)
        func words(_ parts: [(String, NSColor, NSFont)], at pt: NSPoint) {
            var x = pt.x
            for (text, color, font) in parts {
                let a = NSAttributedString(string: text, attributes: [.font: font, .foregroundColor: color])
                a.draw(at: NSPoint(x: x, y: pt.y))
                x += a.size().width
            }
        }
        /// A tile: its bar, its body; its frame in the accent if focused.
        func tile(_ t: NSRect, title: String, body: NSColor, focused: Bool) -> NSRect {
            let shape = NSBezierPath(roundedRect: t, xRadius: 4, yRadius: 4)
            NSGraphicsContext.saveGraphicsState()
            shape.addClip()
            body.setFill()
            t.fill()
            c(p.chrome.panel).setFill()
            NSRect(x: t.minX, y: t.minY, width: t.width, height: 12).fill()
            c(p.chrome.divider).setFill()
            NSRect(x: t.minX, y: t.minY + 12, width: t.width, height: 0.5).fill()
            words([(title, c(p.text.primary), barFont)], at: NSPoint(x: t.minX + 6, y: t.minY + 2))
            NSGraphicsContext.restoreGraphicsState()
            (focused ? accent : c(p.chrome.panelBorder)).setStroke()
            shape.lineWidth = focused ? 1.2 : 0.5
            shape.stroke()
            return NSRect(x: t.minX, y: t.minY + 12.5, width: t.width, height: t.height - 12.5)
        }

        // An editor: a gutter, the caret's line lit, changes marked.
        let main = NSRect(x: side.maxX + 4, y: r.minY + 4, width: r.maxX - side.maxX - 8, height: r.height - 8)
        let editor = tile(NSRect(x: main.minX, y: main.minY, width: main.width, height: 58), title: "store.rs", body: c(p.chrome.panel), focused: false)
        let code: [[(String, NSColor, NSFont)]] = [
            [("/// Writes the card.", c(p.text.secondary), mono)],
            [("pub fn ", c(p.text.primary), bold), ("save", c(p.text.primary), mono), ("(card: &Card) {", c(p.text.primary), mono)],
            [("    store.", c(p.text.primary), mono), ("write", c(p.code.link), mono), ("(card)?;", c(p.text.primary), mono)],
            [("}", c(p.text.primary), mono)],
        ]
        for (k, line) in code.enumerated() {
            let y = editor.minY + 3 + CGFloat(k) * 9.5
            if k == 2 {
                c(p.code.lineHighlight).setFill()
                NSRect(x: editor.minX, y: y - 0.5, width: editor.width, height: 9.5).fill()
            }
            words([("\(k + 1)", c(p.code.gutterText), mono)], at: NSPoint(x: editor.minX + 5, y: y))
            if k == 1 || k == 2 {
                c(k == 1 ? p.code.modified : p.code.added).setFill()
                NSRect(x: editor.minX + 13, y: y, width: 1.5, height: 8.5).fill()
            }
            words(line, at: NSPoint(x: editor.minX + 18, y: y))
            if k == 2 {
                c(p.accent.caret).setFill()
                NSRect(x: editor.minX + 18 + 68, y: y, width: 1, height: 8.5).fill()
            }
        }

        // A terminal, focused: a test run in its palette, a word selected, the cursor.
        let term = tile(NSRect(x: main.minX, y: main.minY + 62, width: main.width, height: main.height - 62),
                        title: "Terminal", body: terminal.background, focused: true)
        let ansi = terminal.colors
        let lines: [[(String, NSColor, NSFont)]] = [
            [("~/app", ansi[4], mono), (" main", ansi[5], mono), (" $ cargo test", terminal.foreground, mono)],
            [("   Compiling", ansi[2], bold), (" app v0.1.0", terminal.foreground, mono)],
            [("warning", ansi[3], bold), (": unused `card`", terminal.foreground, mono)],
            [("test result: ", terminal.foreground, mono), ("12 passed", ansi[2], mono), (", ", terminal.foreground, mono), ("1 failed", ansi[1], mono)],
            [("$ ", terminal.foreground, mono)],
        ]
        for (k, line) in lines.enumerated() {
            let y = term.minY + 3 + CGFloat(k) * 9
            if k == 2 {
                TerminalPalette.hex(terminal.selectionBackgroundHex).setFill()
                NSRect(x: term.minX + 30, y: y, width: 26, height: 8.5).fill()
            }
            words(line, at: NSPoint(x: term.minX + 5, y: y))
            if k == lines.count - 1 {
                TerminalPalette.hex(terminal.cursorHex).setFill()
                NSRect(x: term.minX + 13, y: y + 0.5, width: 1.5, height: 7.5).fill()
            }
        }
    }

    private func index(at p: NSPoint) -> Int? { Palette.all.indices.first { rect($0).insetBy(dx: 0, dy: -Self.label / 2).offsetBy(dx: 0, dy: Self.label / 2).contains(p) } }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self))
    }

    override func mouseMoved(with event: NSEvent) { hovered = index(at: convert(event.locationInWindow, from: nil)) }
    override func mouseExited(with event: NSEvent) { hovered = nil }
    override func resetCursorRects() { for i in Palette.all.indices { addCursorRect(rect(i), cursor: .pointingHand) } }

    override func mouseDown(with event: NSEvent) {
        guard let i = index(at: convert(event.locationInWindow, from: nil)) else { return }
        chosen = Palette.all[i].id
        onPick?(Palette.all[i])
    }

    /// For DebugControl: a theme picked, as a click would.
    func debugPick(_ id: String) {
        guard let p = Palette.all.first(where: { $0.id == id }) else { return }
        chosen = p.id
        onPick?(p)
    }
}

/// The font themes, each named in its own two fonts: the chosen one on
/// a band, as a chosen row is.
final class FontThemeList: NSView {
    var theme: FontTheme = .apple { didSet { needsDisplay = true } }
    /// Custom offered (advanced typography on).
    var advanced = false { didSet { if advanced != oldValue { invalidateIntrinsicContentSize(); needsDisplay = true } } }
    /// The themes to choose from: Humanist where its faces are installed,
    /// Custom with advanced typography.
    private var themes: [FontTheme] { FontTheme.allCases.filter { $0.isAvailable && ($0 != .custom || advanced) } }
    var onPick: ((FontTheme) -> Void)?
    private var hovered: Int? { didSet { if hovered != oldValue { needsDisplay = true } } }
    private static let rowHeight: CGFloat = 26
    private static let width: CGFloat = 400

    override var isFlipped: Bool { true }
    override var intrinsicContentSize: NSSize { NSSize(width: Self.width, height: CGFloat(themes.count) * Self.rowHeight) }

    private func rect(_ i: Int) -> NSRect { NSRect(x: 0, y: CGFloat(i) * Self.rowHeight, width: bounds.width, height: Self.rowHeight) }

    override func draw(_ dirtyRect: NSRect) {
        // Humanist without its faces is Apple, chosen as such.
        let chosen = theme.effective
        for (i, t) in themes.enumerated() {
            let r = rect(i)
            if t == chosen || hovered == i {
                (t == chosen ? Theme.selection : Theme.hover).setFill()
                Flat.rowBand(r.insetBy(dx: -6, dy: 0)).fill()
            }
            let name = NSAttributedString(string: t.title, attributes: [.font: t.font(.proportional, size: 13), .foregroundColor: Theme.text])
            // Editing, then reading if it's another face, then monospaced
            // and the technical beside it.
            let names = [t.proportionalName] + (t.readingName != t.proportionalName ? [t.readingName] : []) + [t.monospacedName]
                + (t.technicalName != t.proportionalName ? [t.technicalName] : [])
            // At the right, in what room the name leaves: cut short, not
            // over it (Custom's faces can be long).
            let style = NSMutableParagraphStyle()
            style.alignment = .right
            style.lineBreakMode = .byTruncatingTail
            let fonts = NSAttributedString(string: names.joined(separator: " · "), attributes: [
                .font: UIType.detail, .foregroundColor: Theme.secondaryText, .paragraphStyle: style,
            ])
            let ns = name.size(), fs = fonts.size()
            name.draw(at: NSPoint(x: r.minX + 10, y: r.midY - ns.height / 2))
            let left = r.minX + 10 + ns.width + 16
            fonts.draw(with: NSRect(x: left, y: r.midY - fs.height / 2, width: max(0, r.maxX - 10 - left), height: fs.height),
                       options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
        }
    }

    private func index(at p: NSPoint) -> Int? { themes.indices.first { rect($0).contains(p) } }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self))
    }

    override func mouseMoved(with event: NSEvent) { hovered = index(at: convert(event.locationInWindow, from: nil)) }
    override func mouseExited(with event: NSEvent) { hovered = nil }

    override func mouseDown(with event: NSEvent) {
        guard let i = index(at: convert(event.locationInWindow, from: nil)) else { return }
        theme = themes[i]
        onPick?(theme)
    }
}

// MARK: Terminals

final class TerminalsPane: SettingsPane {
    private let copyOnSelect = Flat.checkbox("")
    private var showDormancy: ((Int) -> Void)?

    init(_ source: SettingsSource) { super.init(source, title: "Terminals") }
    required init?(coder: NSCoder) { fatalError() }

    override func build() {
        copyOnSelect.title = "Copy text as it's selected"
        copyOnSelect.target = self
        copyOnSelect.action = #selector(copyOnSelectClicked)
        row("Selection", copyOnSelect, note: "A terminal's selection on the clipboard as it's made — except in full screen.")
        let (dormancy, d) = segments(["2 Hours", "8 Hours", "A Day", "A Week", "Never"], [2, 8, 24, 168, 0]) { [weak self] v in
            self?.source.change { (s: inout Settings) in s.terminalDormantAfterHours = v }
        }
        showDormancy = d
        row("End Idle Shells", dormancy, note: "A terminal off screen this long with its shell idle has the shell ended; its transcript stays, and it starts again when shown.")
    }

    @objc private func copyOnSelectClicked() {
        let on = copyOnSelect.state == .on
        source.change { (s: inout Settings) in s.copyOnSelect = on }
    }

    override func refresh() {
        let s = source.settings()
        copyOnSelect.state = s.copyOnSelect ? .on : .off
        showDormancy?(s.terminalDormantAfterHours)
    }
}

// MARK: History

final class HistoryPane: SettingsPane {
    private var showText: ((Int) -> Void)?
    private var showTranscripts: ((Int) -> Void)?
    private var showUndo: ((Int) -> Void)?

    init(_ source: SettingsSource) { super.init(source, title: "History") }
    required init?(coder: NSCoder) { fatalError() }

    override func build() {
        let (text, t) = segments(["30 Days", "90 Days", "A Year", "Forever"], [30, 90, 365, 0]) { [weak self] v in
            self?.source.change { (s: inout Settings) in s.textHistoryDays = v }
        }
        showText = t
        row("Text Changes", text, note: "Every change to a text, kept to go back through.")
        let (transcripts, r) = segments(["30 Days", "90 Days", "A Year", "Forever"], [30, 90, 365, 0]) { [weak self] v in
            self?.source.change { (s: inout Settings) in s.terminalHistoryDays = v }
        }
        showTranscripts = r
        row("Transcripts", transcripts, note: "What terminals showed.")
        let (undo, u) = segments(["100 Steps", "1,000 Steps", "Everything"], [100, 1000, 0]) { [weak self] v in
            self?.source.change { (s: inout Settings) in s.undoDepth = v }
        }
        showUndo = u
        row("Undo", undo)
    }

    override func refresh() {
        let s = source.settings()
        showText?(s.textHistoryDays)
        showTranscripts?(s.terminalHistoryDays)
        showUndo?(s.undoDepth)
    }
}
