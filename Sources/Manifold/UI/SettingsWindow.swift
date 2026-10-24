import AppKit
import ManifoldCore

/// Settings (⌘,): every setting in one window, a pane each — how things
/// look, terminals, history, how hosts are reached, language servers.
final class SettingsWindow: NSWindowController {
    enum Pane: Int, CaseIterable { case appearance, terminals, history, remoting, languageServers }

    let source = SettingsSource()
    let appearance: AppearancePane
    let terminals: TerminalsPane
    let history: HistoryPane
    let remoting = RemotingPane()
    let languageServers = LanguageServersPane()
    private let tabs = NSTabViewController()

    init() {
        appearance = AppearancePane(source)
        terminals = TerminalsPane(source)
        history = HistoryPane(source)
        tabs.tabStyle = .toolbar
        tabs.transitionOptions = [.crossfade, .allowUserInteraction]
        let panes: [(NSViewController, String)] = [
            (appearance, "paintpalette"), (terminals, "terminal"), (history, "clock.arrow.circlepath"),
            (remoting, "network"), (languageServers, "curlybraces"),
        ]
        for (vc, symbol) in panes {
            let item = NSTabViewItem(viewController: vc)
            item.label = vc.title ?? ""
            item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: vc.title)
            tabs.addTabViewItem(item)
        }
        let window = NSWindow(contentViewController: tabs)
        window.styleMask = [.titled, .closable]
        window.toolbarStyle = .preference
        window.backgroundColor = Theme.windowBackground
        super.init(window: window)
        window.center()
    }

    required init?(coder: NSCoder) { fatalError() }

    /// Shown, at `pane` if one is asked for.
    func show(_ pane: Pane? = nil) {
        if let pane { tabs.selectedTabViewItemIndex = pane.rawValue }
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        refresh()
    }

    /// The panes as the settings are now (another Mac changed them);
    /// `tables`: the remoting and language servers' too (not at every render).
    func refresh(tables: Bool = true) {
        guard window?.isVisible == true else { return }
        for vc in [appearance, terminals, history] as [SettingsPane] where vc.isViewLoaded { vc.refresh() }
        guard tables else { return }
        if remoting.isViewLoaded { remoting.refresh() }
        if languageServers.isViewLoaded { languageServers.refresh() }
    }

    var debugState: String {
        let pane = Pane(rawValue: tabs.selectedTabViewItemIndex).map { "\($0)" } ?? "?"
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
        l.font = .systemFont(ofSize: 13)
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
            n.font = .systemFont(ofSize: 11)
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
        let s = FlatSegments(titles: titles, font: .systemFont(ofSize: 12))
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
    private let themes = FontThemeList()

    init(_ source: SettingsSource) { super.init(source, title: "Appearance") }
    required init?(coder: NSCoder) { fatalError() }

    override func build() {
        let (scheme, s) = segments(["Match System", "Light", "Dark"], [ColorScheme.system, .light, .dark]) { [weak self] v in
            self?.source.change { (a: inout Appearance) in a.colorScheme = v }
        }
        showScheme = s
        row("Appearance", scheme)
        tints.onPick = { [weak self] t in self?.source.change { (a: inout Appearance) in a.tint = t } }
        row("Accent", tints, note: "The focus ring, what's chosen, the caret and selections, and a pool of light in the backdrop.")
        gap()
        themes.onPick = { [weak self] t in self?.source.change { (a: inout Appearance) in a.theme = t } }
        row("Fonts", themes, top: true)
        let (editor, e) = segments(["Proportional", "Fixed Width"], [EditorFont.proportional, .monospaced]) { [weak self] v in
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
        tints.tint = a.tint
        themes.theme = a.theme
        showEditor?(a.editorFont)
        showContrast?(a.contrastCorrection)
    }

    /// For DebugControl: a tint picked, as a click on its swatch.
    func debugPickTint(_ t: Tint) { tints.debugPick(t) }
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
        name.font = .systemFont(ofSize: 12)
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
            t.accent.setFill()
            NSBezierPath(ovalIn: r).fill()
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

/// The font themes, each named in its own two fonts: the chosen one on
/// a band, as a chosen row is.
final class FontThemeList: NSView {
    var theme: FontTheme = .notes { didSet { needsDisplay = true } }
    var onPick: ((FontTheme) -> Void)?
    private var hovered: Int? { didSet { if hovered != oldValue { needsDisplay = true } } }
    private static let rowHeight: CGFloat = 26
    private static let width: CGFloat = 400

    override var isFlipped: Bool { true }
    override var intrinsicContentSize: NSSize { NSSize(width: Self.width, height: CGFloat(FontTheme.allCases.count) * Self.rowHeight) }

    private func rect(_ i: Int) -> NSRect { NSRect(x: 0, y: CGFloat(i) * Self.rowHeight, width: bounds.width, height: Self.rowHeight) }

    override func draw(_ dirtyRect: NSRect) {
        for (i, t) in FontTheme.allCases.enumerated() {
            let r = rect(i)
            if t == theme || hovered == i {
                (t == theme ? Theme.selection : Theme.hover).setFill()
                NSBezierPath(roundedRect: r.insetBy(dx: 0, dy: 1), xRadius: 6, yRadius: 6).fill()
            }
            let name = NSAttributedString(string: t.title, attributes: [.font: t.font(.proportional, size: 13), .foregroundColor: Theme.text])
            let fonts = NSAttributedString(string: "\(t.proportionalName) · \(t.monospacedName)", attributes: [
                .font: t.font(.monospaced, size: 11), .foregroundColor: Theme.secondaryText,
            ])
            let ns = name.size(), fs = fonts.size()
            name.draw(at: NSPoint(x: r.minX + 10, y: r.midY - ns.height / 2))
            fonts.draw(at: NSPoint(x: r.maxX - 10 - fs.width, y: r.midY - fs.height / 2))
        }
    }

    private func index(at p: NSPoint) -> Int? { FontTheme.allCases.indices.first { rect($0).contains(p) } }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self))
    }

    override func mouseMoved(with event: NSEvent) { hovered = index(at: convert(event.locationInWindow, from: nil)) }
    override func mouseExited(with event: NSEvent) { hovered = nil }

    override func mouseDown(with event: NSEvent) {
        guard let i = index(at: convert(event.locationInWindow, from: nil)) else { return }
        theme = FontTheme.allCases[i]
        onPick?(theme)
    }
}

// MARK: Terminals

final class TerminalsPane: SettingsPane {
    private let copyOnSelect = NSButton()
    private var showDormancy: ((Int) -> Void)?

    init(_ source: SettingsSource) { super.init(source, title: "Terminals") }
    required init?(coder: NSCoder) { fatalError() }

    override func build() {
        copyOnSelect.setButtonType(.switch)
        copyOnSelect.title = "Copy text as it's selected"
        copyOnSelect.target = self
        copyOnSelect.action = #selector(copyOnSelectClicked)
        row("Selection", copyOnSelect, note: "Not in full screen.")
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
        let (text, t) = segments(["Forever", "30 Days", "90 Days", "A Year"], [0, 30, 90, 365]) { [weak self] v in
            self?.source.change { (s: inout Settings) in s.textHistoryDays = v }
        }
        showText = t
        row("Text Changes", text, note: "Every change to a text, kept to go back through.")
        let (transcripts, r) = segments(["30 Days", "90 Days", "A Year", "Forever"], [30, 90, 365, 0]) { [weak self] v in
            self?.source.change { (s: inout Settings) in s.terminalHistoryDays = v }
        }
        showTranscripts = r
        row("Transcripts", transcripts, note: "What terminals showed.")
        let (undo, u) = segments(["Everything", "100 Steps", "1,000 Steps"], [0, 100, 1000]) { [weak self] v in
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
