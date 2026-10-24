import AppKit
import ManifoldCore

/// Settings ▸ Typography: custom typography (the Custom font theme), a
/// role at a time — editing, reading, monospaced — each with its family
/// and face, size, line height, letter spacing and OpenType features (and
/// for reading, its measure and the space between paragraphs), set in a
/// sample as it changes. Changing anything here sets Manifold in it.
final class TypographyPane: SettingsPane {
    private var role: FontRole = .editing
    private let use = NSButton(checkboxWithTitle: "Set Manifold in custom typography", target: nil, action: nil)
    private let start = NSPopUpButton(frame: .zero, pullsDown: true)
    private var showRole: ((FontRole) -> Void)?
    private let family = NSPopUpButton()
    private let face = NSPopUpButton()
    private let size = NSTextField()
    private let sizeStepper = NSStepper()
    private let leading = NSSlider(value: 1.4, minValue: 0.9, maxValue: 2.4, target: nil, action: nil)
    private let leadingValue = NSTextField(labelWithString: "")
    private let tracking = NSSlider(value: 0, minValue: -80, maxValue: 200, target: nil, action: nil)
    private let trackingValue = NSTextField(labelWithString: "")
    private let features = NSTextField()
    private let featureMenu = NSPopUpButton(frame: .zero, pullsDown: true)
    private let measure = NSSlider(value: 0, minValue: 0, maxValue: 120, target: nil, action: nil)
    private let measureValue = NSTextField(labelWithString: "")
    private let gapSlider = NSSlider(value: 1, minValue: 0, maxValue: 2.5, target: nil, action: nil)
    private let gapValue = NSTextField(labelWithString: "")
    private let sample = NSTextField(wrappingLabelWithString: "")
    /// The role the fields were last filled for: they're filled again for
    /// another, even while one has the keyboard.
    private var shownRole: FontRole?
    /// What's shown, as edited: set to the settings when idle.
    private var style = Typography.humanist.editing
    private var commit: DispatchWorkItem?

    init(_ source: SettingsSource) { super.init(source, title: "Typography") }
    required init?(coder: NSCoder) { fatalError() }

    override func build() {
        use.target = self
        use.action = #selector(toggleUse)
        row("Fonts", use, note: "The Custom font theme. Each role scales the sizes set in it everywhere it's used.")
        start.addItem(withTitle: "Start From")
        start.menu?.delegate = self
        row("", start)
        gap()
        let (roles, show) = segments(FontRole.allCases.map(\.title), FontRole.allCases) { [weak self] r in
            guard let self else { return }
            self.flush()
            self.role = r
            self.refresh()
        }
        showRole = show
        row("Role", roles)

        family.target = self
        family.action = #selector(pickFamily)
        family.widthAnchor.constraint(equalToConstant: 260).isActive = true
        row("Font", family)
        face.target = self
        face.action = #selector(pickFace)
        face.widthAnchor.constraint(equalToConstant: 160).isActive = true
        row("Face", face)

        size.widthAnchor.constraint(equalToConstant: 56).isActive = true
        size.alignment = .right
        size.target = self
        size.action = #selector(typedSize)
        size.cell?.sendsActionOnEndEditing = true
        sizeStepper.minValue = 6
        sizeStepper.maxValue = 72
        sizeStepper.increment = 0.5
        sizeStepper.valueWraps = false
        sizeStepper.target = self
        sizeStepper.action = #selector(steppedSize)
        row("Size", line([size, sizeStepper, label("pt")]))

        for (s, v) in [(leading, leadingValue), (tracking, trackingValue), (measure, measureValue), (gapSlider, gapValue)] {
            s.isContinuous = true
            s.target = self
            s.action = #selector(slid(_:))
            s.widthAnchor.constraint(equalToConstant: 240).isActive = true
            v.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
            v.textColor = Theme.secondaryText
            v.widthAnchor.constraint(equalToConstant: 90).isActive = true
        }
        row("Line Height", line([leading, leadingValue]))
        row("Letter Spacing", line([tracking, trackingValue]))

        features.placeholderString = "ss01, zero, -liga"
        features.widthAnchor.constraint(equalToConstant: 200).isActive = true
        features.target = self
        features.action = #selector(typedFeatures)
        features.cell?.sendsActionOnEndEditing = true
        featureMenu.addItem(withTitle: "Font's Features")
        featureMenu.widthAnchor.constraint(equalToConstant: 140).isActive = true
        row("Features", line([features, featureMenu]), note: "OpenType features by tag: on (ss01), off (-liga), or a value (cv05=2).")

        row("Measure", line([measure, measureValue]), note: "Reading only: the longest line in a preview, in characters.")
        row("Paragraphs", line([gapSlider, gapValue]), note: "Reading only: the space between paragraphs.")
        gap()
        sample.isSelectable = false
        sample.preferredMaxLayoutWidth = 356
        sample.translatesAutoresizingMaskIntoConstraints = false
        // On a card of its own, a little in from its edges.
        let card = NSView()
        card.wantsLayer = true
        card.layer?.cornerRadius = 8
        card.themed { $0.layer?.backgroundColor = NSColor.controlBackgroundColor.cgColor }
        card.addSubview(sample)
        NSLayoutConstraint.activate([
            card.widthAnchor.constraint(equalToConstant: 380),
            card.heightAnchor.constraint(equalToConstant: 150),
            sample.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 12),
            sample.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -12),
            sample.topAnchor.constraint(equalTo: card.topAnchor, constant: 10),
        ])
        row("Sample", card, top: true)
    }

    private func label(_ s: String) -> NSTextField {
        let l = NSTextField(labelWithString: s)
        l.textColor = Theme.secondaryText
        return l
    }

    private func line(_ views: [NSView]) -> NSStackView {
        let s = NSStackView(views: views)
        s.spacing = 8
        s.alignment = .centerY
        return s
    }

    // MARK: Showing

    override func refresh() {
        let a = source.appearance()
        use.state = a.theme == .custom ? .on : .off
        showRole?(role)
        // Not over what's being edited.
        if commit == nil { style = a.typography[role] }
        show()
    }

    private func show() {
        fillFamilies()
        fillFaces()
        let newRole = shownRole != role
        shownRole = role
        if newRole || size.currentEditor() == nil { size.stringValue = Self.number(style.size) }
        sizeStepper.doubleValue = style.size
        leading.doubleValue = style.lineHeight
        leadingValue.stringValue = String(format: "%.2f ×", style.lineHeight)
        tracking.doubleValue = style.tracking
        trackingValue.stringValue = style.tracking == 0 ? "normal" : String(format: "%+.3f em", style.tracking / 1000)
        if newRole || features.currentEditor() == nil { features.stringValue = style.features }
        fillFeatureMenu()
        let reading = role == .reading
        measure.isEnabled = reading
        gapSlider.isEnabled = reading
        measure.doubleValue = style.measure
        measureValue.stringValue = style.measure < 20 ? "the page's" : "\(Int(style.measure)) ch"
        gapSlider.doubleValue = style.paragraphSpacing
        gapValue.stringValue = String(format: "%.2f em", style.paragraphSpacing)
        showSample()
    }

    private static func number(_ d: Double) -> String { d == d.rounded() ? String(Int(d)) : String(format: "%.1f", d) }

    private var families: [String]?
    private var fixedPitch: Set<String>?

    /// The families there are: the system's first; for monospaced, those of
    /// fixed pitch, then the rest.
    private func fillFamilies() {
        if families == nil {
            families = NSFontManager.shared.availableFontFamilies.filter { !$0.hasPrefix(".") }.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
            fixedPitch = Set((NSFontManager.shared.availableFontNames(with: .fixedPitchFontMask) ?? []).compactMap { NSFont(name: $0, size: 12)?.familyName })
        }
        family.removeAllItems()
        let menu = family.menu!
        let system = NSMenuItem(title: role == .monospaced ? "System (SF Mono)" : "System (SF)", action: nil, keyEquivalent: "")
        system.representedObject = ""
        menu.addItem(system)
        // The system's serif, which has no family of its own.
        if role != .monospaced {
            let serif = NSMenuItem(title: "New York", action: nil, keyEquivalent: "")
            serif.representedObject = "New York"
            menu.addItem(serif)
        }
        menu.addItem(.separator())
        let all = families ?? []
        let groups = role == .monospaced ? [all.filter { fixedPitch?.contains($0) == true }, all.filter { fixedPitch?.contains($0) != true }] : [all]
        for (i, group) in groups.enumerated() {
            if i > 0 { menu.addItem(.separator()) }
            for f in group {
                let item = NSMenuItem(title: f, action: nil, keyEquivalent: "")
                item.representedObject = f
                menu.addItem(item)
            }
        }
        if let item = menu.items.first(where: { $0.representedObject as? String == style.family }) {
            family.select(item)
        } else {
            // A family that's gone (uninstalled): said as such.
            let item = NSMenuItem(title: "\(style.family) (missing)", action: nil, keyEquivalent: "")
            item.representedObject = style.family
            menu.insertItem(item, at: 0)
            family.select(item)
        }
    }

    private func fillFaces() {
        face.removeAllItems()
        let faces = FontFace.faces(of: style.family, role: role)
        for f in faces {
            let item = NSMenuItem(title: "\(f.name)  \(f.weight)", action: nil, keyEquivalent: "")
            item.representedObject = f.weight
            face.menu?.addItem(item)
        }
        let nearest = style.face(role)
        if let i = faces.firstIndex(where: { $0 == nearest }) { face.selectItem(at: i) }
        face.isEnabled = faces.count > 1
    }

    /// The font's own features, each checked if it's on.
    private func fillFeatureMenu() {
        while featureMenu.numberOfItems > 1 { featureMenu.removeItem(at: 1) }
        let font = style.font(size: CGFloat(style.size), role: role)
        let on = Dictionary(style.featureTags.map { ($0.tag, $0.value) }, uniquingKeysWith: { $1 })
        let available = TypeStyle.availableFeatures(of: font)
        if available.isEmpty {
            let none = NSMenuItem(title: "None Listed", action: nil, keyEquivalent: "")
            none.isEnabled = false
            featureMenu.menu?.addItem(none)
        }
        for (tag, name) in available {
            let item = ClosureMenuItem("\(tag) — \(name)") { [weak self] in self?.toggleFeature(tag) }
            item.state = (on[tag] ?? 0) != 0 ? .on : .off
            featureMenu.menu?.addItem(item)
        }
    }

    /// The role's sample, in its font, as it's set.
    private func showSample() {
        let text: String
        switch role {
        case .editing: text = "# Notes\nThe quick brown fox jumps over the lazy dog. Sphinx of black quartz, judge my vow — 1234567890."
        case .reading: text = "Typography is the craft of endowing human language with a durable visual form. The reader should be able to read without effort: 0123456789, “quotes”, fi fl ffi."
        case .monospaced: text = "func fib(_ n: Int) -> Int {\n    n < 2 ? n : fib(n - 1) + fib(n - 2) // 0O 1lI\n}\n$ make test && echo ok  != == => -> <= >="
        }
        let font = style.font(size: CGFloat(style.size), role: role)
        let p = NSMutableParagraphStyle()
        let natural = font.ascender - font.descender + font.leading
        if natural > 0 { p.lineHeightMultiple = CGFloat(style.lineHeight) * font.pointSize / natural }
        if role == .reading { p.paragraphSpacing = CGFloat(style.paragraphSpacing) * font.pointSize }
        sample.attributedStringValue = NSAttributedString(string: text, attributes: [
            .font: font, .kern: CGFloat(style.tracking) / 1000 * font.pointSize,
            .paragraphStyle: p, .foregroundColor: Theme.text,
        ])
    }

    // MARK: Changing

    /// The edited role kept, and Manifold set in it, once edits pause.
    private func changed(now: Bool = false) {
        show()
        commit?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.flush() }
        commit = work
        DispatchQueue.main.asyncAfter(deadline: .now() + (now ? 0 : 0.2), execute: work)
    }

    private func flush() {
        guard let work = commit else { return }
        work.cancel()
        commit = nil
        let role = self.role, style = self.style
        source.change { (a: inout Appearance) in
            a.typography[role] = style
            a.theme = .custom
        }
    }

    fileprivate func startFrom(_ preset: Typography, all: Bool) {
        commit?.cancel()
        commit = nil
        let role = self.role
        source.change { (a: inout Appearance) in
            if all { a.typography = preset } else { a.typography[role] = preset[role] }
            a.theme = .custom
        }
        refresh()
    }

    @objc private func toggleUse() {
        flush()
        let on = use.state == .on
        source.change { (a: inout Appearance) in a.theme = on ? .custom : .apple }
    }

    @objc private func pickFamily() {
        guard let f = family.selectedItem?.representedObject as? String else { return }
        style.family = f
        // The weight kept as near as the new family has it.
        if let nearest = style.face(role) { style.weight = nearest.weight }
        changed(now: true)
    }

    @objc private func pickFace() {
        guard let w = face.selectedItem?.representedObject as? Int else { return }
        style.weight = w
        changed(now: true)
    }

    @objc private func typedSize() {
        guard let v = Double(size.stringValue.replacingOccurrences(of: ",", with: ".")), v >= 6, v <= 72 else { return show() }
        style.size = v
        changed(now: true)
    }

    @objc private func steppedSize() {
        style.size = sizeStepper.doubleValue
        changed()
    }

    @objc private func slid(_ s: NSSlider) {
        switch s {
        case leading: style.lineHeight = (s.doubleValue * 20).rounded() / 20
        case tracking: style.tracking = (s.doubleValue / 5).rounded() * 5
        case measure: style.measure = s.doubleValue < 20 ? 0 : s.doubleValue.rounded()
        case gapSlider: style.paragraphSpacing = (s.doubleValue * 20).rounded() / 20
        default: return
        }
        changed()
    }

    @objc private func typedFeatures() {
        style.features = features.stringValue
        changed(now: true)
    }

    /// A feature from the font's list turned on, or off if it was on.
    private func toggleFeature(_ tag: String) {
        var tags = style.featureTags
        if let i = tags.firstIndex(where: { $0.tag == tag }) {
            if tags[i].value != 0 { tags.remove(at: i) } else { tags[i].value = 1 }
        } else {
            tags.append((tag, 1))
        }
        style.features = tags.map { $0.value == 1 ? $0.tag : $0.value == 0 ? "-" + $0.tag : "\($0.tag)=\($0.value)" }.joined(separator: ", ")
        changed(now: true)
    }

    /// For DebugControl: the pane's state, a line.
    var debugState: String {
        "role \(role.rawValue): \(style.displayName(role)) \(style.size)pt ×\(style.lineHeight) \(style.tracking)‰ [\(style.features)] faces \(face.numberOfItems) features \(featureMenu.numberOfItems - 1)"
    }

    /// For DebugControl: a role chosen, and a change made to it.
    func debugSet(role r: FontRole, _ edit: (inout TypeStyle) -> Void) {
        flush()
        role = r
        refresh()
        edit(&style)
        changed(now: true)
    }
}

extension TypographyPane: NSMenuDelegate {
    /// Start From's presets, as they are when it opens: Humanist only
    /// where its faces are installed.
    func menuNeedsUpdate(_ menu: NSMenu) {
        while menu.numberOfItems > 1 { menu.removeItem(at: 1) }
        for theme in [FontTheme.system, .apple, .humanist] where theme.isAvailable {
            let preset = theme.styles
            menu.addItem(ClosureMenuItem("All Roles from \(theme.title)") { [weak self] in self?.startFrom(preset, all: true) })
            menu.addItem(ClosureMenuItem("This Role from \(theme.title)") { [weak self] in self?.startFrom(preset, all: false) })
        }
    }
}
