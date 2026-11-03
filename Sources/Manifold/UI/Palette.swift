import AppKit
import ManifoldCore

/// One colour in the light and one in the dark.
struct Shade {
    let light: NSColor
    let dark: NSColor

    init(_ light: NSColor, _ dark: NSColor) {
        self.light = light
        self.dark = dark
    }

    /// The same in both.
    init(_ both: NSColor) {
        light = both
        dark = both
    }

    /// The same white in each, at its own alpha: a wash of black over the
    /// light, of white over the dark (a hover, a hairline).
    static func wash(_ light: CGFloat, _ dark: CGFloat) -> Shade {
        Shade(NSColor(white: 0, alpha: light), NSColor(white: 1, alpha: dark))
    }

    /// Greys: `light` and `dark`, opaque.
    static func grey(_ light: CGFloat, _ dark: CGFloat) -> Shade {
        Shade(NSColor(white: light, alpha: 1), NSColor(white: dark, alpha: 1))
    }

    static func hex(_ light: Int, _ dark: Int) -> Shade { Shade(Theme.hex(light), Theme.hex(dark)) }

    func color(dark isDark: Bool) -> NSColor { isDark ? dark : light }

    /// As one colour: itself where it's one, else the one for the
    /// appearance it's drawn in.
    var color: NSColor { light === dark ? light : .dynamic(light, dark) }
}

/// A theme's colours (DESIGN.md §11): every colour Manifold draws its own
/// things in, each in the light and in the dark — its chrome, its texts,
/// its tints, what says something (status, diffs, matches), the
/// terminal's palette and the preview's page. One is in use
/// (`Palette.current`); what draws reads it as it draws (`NSColor.themed`),
/// so a theme set recolours everything, as light and dark switching does.
struct Palette {
    /// What it's called, to keep and to show.
    var id: String
    var title: String

    var chrome: Chrome
    var text: Text
    var status: StatusColors
    /// The tint's colours, for each tint but the system's (which is the system's).
    var tints: [Tint: TintColors]
    var code: Code
    var diff: Diff
    var found: Found
    var chart: Chart
    var kinds: Kinds
    var terminal: (light: TerminalPalette, dark: TerminalPalette)
    var page: Page

    /// The window's own ground, the bars', the gaps between tiles: the
    /// terminal's paper.
    var window: Shade { Shade(terminal.light.background, terminal.dark.background) }

    struct Chrome {
        var hover: Shade
        /// A chosen thing's ground where it isn't a band (a segment).
        var selected: Shade
        var pressed: Shade
        var divider: Shade
        var panel: Shade
        var panelBorder: Shade
        /// Over the window, behind the palette.
        var scrim: Shade
        var cardBorder: Shade
        /// The sidebar's resize handle.
        var handle: Shade
        var scrubberKnob: Shade
        var sheetEdge: Shade
        var sheetEdgeHovered: Shade
        /// A sheet beneath a stack's top, `level` deep.
        var sheet: (Int) -> Shade
        /// A run of rows drawn round together (a stack's tiles in the sidebar).
        var groupOutline: Shade
        /// A stack's column of cards.
        var stack: Shade
        /// What's dragged, as a pill.
        var dragPill: Shade
        /// A link capsule's faces behind the front one, `depth` back.
        var linkBehind: (Int) -> Shade
        /// The ground of a path inserter's field.
        var well: Shade
        /// A pill's capsule: a count, an age.
        var pill: Shade
        /// A history's picture of a space: a wash from one to the other.
        var historyWash: (from: Shade, to: Shade)
    }

    struct Text {
        var primary: Shade
        /// What's read and edited at length.
        var body: Shade
        /// Headings and bold in it.
        var strong: Shade
        var secondary: Shade
        var tertiary: Shade
        /// The preview's reading colours, for Markdown set natively.
        var readingBody: Shade
        var readingStrong: Shade
    }

    struct StatusColors {
        var done: Shade
        var attention: Shade
        var failed: Shade
    }

    struct TintColors {
        /// The tint itself: lines, fills, symbols.
        var accent: Shade
        /// An editor's and a terminal's caret.
        var caret: Shade
        /// Selected text, behind it.
        var textSelection: Shade

        init(accent: Shade, caret: Shade? = nil, textSelection: Shade) {
            self.accent = accent
            self.caret = caret ?? accent
            self.textSelection = textSelection
        }
    }

    struct Code {
        /// A text in view mode: its page, its text, its line numbers.
        var page: Shade
        var text: Shade
        var lineNumber: Shade
        /// The caret's line, lit.
        var lineHighlight: Shade
        var gutterText: Shade
        /// The caret's symbol's other uses.
        var use: Shade
        var match: Shade
        var link: Shade
        var linkHover: Shade
        /// A line's mark in the gutter: added, changed, deleted.
        var added: Shade
        var modified: Shade
        var deleted: Shade
        /// Highlight Uses' colours, in turn.
        var pins: [Shade]
        /// A diagnostic's underline: an error, a warning, the rest.
        var error: Shade
        var warning: Shade
        var hint: Shade
        /// The bar over a file changed on disk while edited.
        var changedOnDisk: Shade
        /// `==text==`'s ground.
        var highlighter: Shade
    }

    struct Diff {
        var added: Shade
        var removed: Shade
        var hunk: Shade
        var found: Shade
        var current: Shade
    }

    /// What a search found, where it's shown.
    struct Found {
        /// The chosen hit's match in a search's preview, and its ring.
        var current: Shade
        var currentRing: Shade
        /// A PDF's matches, and the one gone to: a page is paper whatever the appearance.
        var pdf: Shade
        var pdfCurrent: Shade
    }

    /// A machine's charts: three series, and what they're drawn on.
    struct Chart {
        var one: Shade
        var two: Shade
        var three: Shade
        var track: Shade
        var surface: Shade
        var grid: Shade
    }

    /// Colours that tell kinds apart: a file's type, a link's.
    struct Kinds {
        var git: Shade
        var swift: Shade
        var shell: Shade
        var pdf: Shade
        var image: Shade
        var data: Shade
        var patch: Shade
        var archive: Shade
        var media: Shade
        var code: Shade
        var linked: Shade
        var embeds: Shade
    }

    /// The preview's page (`MarkdownPage`), as CSS colours by role.
    struct Page {
        var background: Shade
        var text: Shade
        /// Headings (and in the dark, bold).
        var strong: Shade
        var link: Shade
        var code: Shade
        var codeText: Shade
        var copy: Shade
        var copyEdge: Shade
        var copyText: Shade
        var copyHoverEdge: Shade
        var copyHoverText: Shade
        var copyDone: Shade
        var quote: Shade
        var quoteRule: Shade
        var rule: Shade
        var tableHead: Shade
        var tableStripe: Shade
        var struck: Shade
        var missing: Shade
        var diagramError: Shade
        var selection: Shade
        /// A card's note: failed, running, wanting attention.
        var failed: Shade
        var running: Shade
        var attention: Shade

        /// Each as a CSS variable, `--page-<role>`, in the light, and again
        /// in the dark.
        var css: String {
            let roles: [(String, Shade)] = [
                ("background", background), ("text", text), ("strong", strong), ("link", link), ("code", code),
                ("code-text", codeText), ("copy", copy), ("copy-edge", copyEdge), ("copy-text", copyText),
                ("copy-hover-edge", copyHoverEdge), ("copy-hover-text", copyHoverText), ("copy-done", copyDone),
                ("quote", quote), ("quote-rule", quoteRule), ("rule", rule), ("table-head", tableHead),
                ("table-stripe", tableStripe), ("struck", struck), ("missing", missing), ("diagram-error", diagramError),
                ("selection", selection), ("failed", failed), ("running", running), ("attention", attention),
            ]
            func vars(dark: Bool) -> String {
                roles.map { "--page-\($0.0): \(Tints.hex($0.1.color(dark: dark), dark: dark));" }.joined(separator: " ")
            }
            return ":root { \(vars(dark: false)) }\n@media (prefers-color-scheme: dark) { :root { \(vars(dark: true)) } }"
        }
    }
}

extension Palette {
    /// The theme in use.
    private(set) static var current: Palette = .paper

    /// Every theme there is.
    static let all: [Palette] = [.paper]

    /// A theme set: every colour redrawn, what's held in layers by the
    /// hooks that set them, the terminals reconfigured.
    static func apply(_ palette: Palette) {
        guard palette.id != current.id else { return }
        current = palette
        NotificationCenter.default.post(name: .manifoldPaletteChanged, object: nil)
        NotificationCenter.default.post(name: .manifoldAppearanceChanged, object: nil)
        for window in NSApp.windows { window.contentView.map(redraw) }
        GhosttyRuntime.shared.reapply()
    }

    private static func redraw(_ view: NSView) {
        view.needsDisplay = true
        view.subviews.forEach(redraw)
    }
}

extension NSColor {
    /// A colour of the theme in use, as it has it in the appearance it's
    /// drawn in: one object, recoloured when the theme changes.
    static func themed(_ pick: @escaping (Palette) -> Shade) -> NSColor {
        NSColor(name: nil) { pick(Palette.current).color(dark: $0.isDark) }
    }
}

extension Notification.Name {
    /// Another theme was set.
    static let manifoldPaletteChanged = Notification.Name("ManifoldPaletteChanged")
}

// MARK: Paper

extension Palette {
    /// Manifold's own: paper, greys, go.dev's code and GitHub's terminal palettes.
    static let paper = Palette(
        id: "paper",
        title: "Paper",
        chrome: Chrome(
            hover: .wash(0.055, 0.07),
            selected: Shade(.white, NSColor(white: 1, alpha: 0.13)),
            pressed: .wash(0.11, 0.14),
            divider: .wash(0.1, 0.1),
            panel: .grey(0.995, 0.17),
            panelBorder: .wash(0.12, 0.14),
            scrim: Shade(NSColor(white: 0.9, alpha: 0.35), NSColor(white: 0, alpha: 0.3)),
            cardBorder: .wash(0.08, 0.1),
            handle: .wash(0.22, 0.25),
            scrubberKnob: .wash(0.14, 0.18),
            sheetEdge: .wash(0.2, 0.16),
            sheetEdgeHovered: .wash(0.34, 0.34),
            // Darker further down in light, lighter nearer the top in dark.
            sheet: { level in .grey(0.93 - CGFloat(level) * 0.045, 0.36 - CGFloat(level) * 0.05) },
            groupOutline: Shade(NSColor(white: 0, alpha: 0.28), NSColor(white: 1, alpha: 0.28)),
            stack: .grey(0.995, 0.2),
            dragPill: Shade(NSColor(white: 1, alpha: 1), NSColor(white: 0.3, alpha: 1)),
            linkBehind: { depth in .grey(0.95 - CGFloat(depth) * 0.03, 0.16 - CGFloat(depth) * 0.015) },
            well: .wash(0.06, 0.09),
            pill: .wash(0.07, 0.1),
            historyWash: (
                from: Shade(NSColor(calibratedHue: 0.72, saturation: 0.18, brightness: 0.98, alpha: 1),
                            NSColor(calibratedHue: 0.70, saturation: 0.35, brightness: 0.22, alpha: 1)),
                to: Shade(NSColor(calibratedHue: 0.07, saturation: 0.18, brightness: 1, alpha: 1),
                          NSColor(calibratedHue: 0.06, saturation: 0.3, brightness: 0.2, alpha: 1)))),
        text: Text(
            primary: .grey(0.13, 0.89),
            body: .grey(0.13, 0.86),
            strong: .grey(0.08, 0.97),
            // Each at least 4.5:1 on a panel or a card, in either appearance.
            secondary: .grey(0.40, 0.68),
            tertiary: .grey(0.45, 0.62),
            readingBody: Shade(NSColor(srgbRed: 0x20 / 255, green: 0x22 / 255, blue: 0x24 / 255, alpha: 1), NSColor(white: 0xdb / 255, alpha: 1)),
            readingStrong: Shade(NSColor(srgbRed: 0x20 / 255, green: 0x22 / 255, blue: 0x24 / 255, alpha: 1), NSColor(white: 0xf7 / 255, alpha: 1))),
        status: StatusColors(
            done: Shade(NSColor(srgbRed: 0.10, green: 0.50, blue: 0.22, alpha: 1), NSColor(srgbRed: 0.35, green: 0.80, blue: 0.45, alpha: 1)),
            attention: Shade(NSColor(srgbRed: 0.66, green: 0.38, blue: 0.0, alpha: 1), NSColor(srgbRed: 0.95, green: 0.70, blue: 0.32, alpha: 1)),
            failed: Shade(NSColor(srgbRed: 0.76, green: 0.15, blue: 0.12, alpha: 1), NSColor(srgbRed: 1.0, green: 0.42, blue: 0.38, alpha: 1))),
        tints: [
            .blue: TintColors(accent: Shade(Theme.hex(0x3373F2)), caret: .hex(0x007AFF, 0x0A84FF), textSelection: .hex(0xCFE2FB, 0x264F78)),
            // Overcast's orange (#FC7E0F) in the dark; deeper in the light.
            .orange: TintColors(accent: .hex(0xE36A00, 0xFC7E0F), caret: .hex(0xEB7300, 0xFF8A26), textSelection: .hex(0xFDE1C4, 0x6E3D12)),
            .purple: TintColors(accent: .hex(0x9550D6, 0xBF7AF0), textSelection: .hex(0xEADCF8, 0x4B2F68)),
            .pink: TintColors(accent: .hex(0xDC3F78, 0xFF6B9C), textSelection: .hex(0xFADAE6, 0x6B2B43)),
            .green: TintColors(accent: .hex(0x2A9A4A, 0x3FCB68), textSelection: .hex(0xD5EFDC, 0x25512F)),
            .graphite: TintColors(accent: .hex(0x6E6E73, 0x98989D), caret: .hex(0x48484D, 0xC7C7CC), textSelection: .hex(0xE1E1E4, 0x4A4A4E)),
        ],
        code: Code(
            // As go.dev's docs (the Go spec) set code: on their grey, in
            // their text colour, its line numbers in theirs.
            page: .hex(0xF8F8F8, 0x2D2D2D),
            text: .hex(0x202224, 0xF0F1F2),
            lineNumber: .hex(0x999999, 0x848688),
            lineHighlight: Shade(NSColor(srgbRed: 1, green: 0.95, blue: 0.72, alpha: 1), NSColor(srgbRed: 0.32, green: 0.28, blue: 0.12, alpha: 1)),
            gutterText: .grey(0.62, 0.42),
            use: .wash(0.075, 0.1),
            match: Shade(NSColor(srgbRed: 1, green: 0.9, blue: 0.5, alpha: 0.7), NSColor(srgbRed: 0.5, green: 0.42, blue: 0.1, alpha: 0.8)),
            link: Shade(NSColor(srgbRed: 0, green: 0x7d / 255.0, blue: 0x9c / 255.0, alpha: 1),
                        NSColor(srgbRed: 0x50 / 255.0, green: 0xb7 / 255.0, blue: 0xe0 / 255.0, alpha: 1)),
            linkHover: .wash(0.08, 0.13),
            added: Shade(NSColor(srgbRed: 0.3, green: 0.72, blue: 0.4, alpha: 1), NSColor(srgbRed: 0.4, green: 0.8, blue: 0.5, alpha: 1)),
            modified: Shade(NSColor(srgbRed: 0.35, green: 0.6, blue: 0.95, alpha: 1), NSColor(srgbRed: 0.45, green: 0.65, blue: 1, alpha: 1)),
            deleted: Shade(NSColor(srgbRed: 0.9, green: 0.35, blue: 0.35, alpha: 1), NSColor(srgbRed: 1, green: 0.45, blue: 0.45, alpha: 1)),
            pins: [
                Shade(NSColor(srgbRed: 0.2, green: 0.7, blue: 0.7, alpha: 0.28), NSColor(srgbRed: 0.25, green: 0.75, blue: 0.75, alpha: 0.35)),
                Shade(NSColor(srgbRed: 0.95, green: 0.7, blue: 0.2, alpha: 0.32), NSColor(srgbRed: 0.95, green: 0.72, blue: 0.25, alpha: 0.35)),
                Shade(NSColor(srgbRed: 0.6, green: 0.45, blue: 0.95, alpha: 0.28), NSColor(srgbRed: 0.65, green: 0.5, blue: 1, alpha: 0.35)),
                Shade(NSColor(srgbRed: 0.95, green: 0.4, blue: 0.55, alpha: 0.26), NSColor(srgbRed: 1, green: 0.45, blue: 0.6, alpha: 0.33)),
            ],
            error: Shade(.systemRed),
            warning: Shade(.systemOrange),
            hint: Shade(NSColor.systemBlue.withAlphaComponent(0.6)),
            changedOnDisk: Shade(NSColor(srgbRed: 1, green: 0.97, blue: 0.86, alpha: 1), NSColor(srgbRed: 0.27, green: 0.24, blue: 0.13, alpha: 1)),
            highlighter: Shade(NSColor(srgbRed: 1, green: 0.86, blue: 0.3, alpha: 0.55), NSColor.systemYellow.withAlphaComponent(0.32))),
        diff: Diff(
            added: Shade(NSColor(srgbRed: 0.86, green: 0.96, blue: 0.87, alpha: 1), NSColor(srgbRed: 0.13, green: 0.26, blue: 0.16, alpha: 1)),
            removed: Shade(NSColor(srgbRed: 0.99, green: 0.88, blue: 0.88, alpha: 1), NSColor(srgbRed: 0.3, green: 0.14, blue: 0.14, alpha: 1)),
            hunk: Shade(NSColor(srgbRed: 0.91, green: 0.94, blue: 0.99, alpha: 1), NSColor(srgbRed: 0.15, green: 0.19, blue: 0.27, alpha: 1)),
            found: Shade(NSColor(srgbRed: 1, green: 0.95, blue: 0.6, alpha: 1), NSColor(srgbRed: 0.45, green: 0.4, blue: 0.1, alpha: 1)),
            current: Shade(NSColor(srgbRed: 1, green: 0.85, blue: 0.3, alpha: 1), NSColor(srgbRed: 0.7, green: 0.55, blue: 0.1, alpha: 1))),
        found: Found(
            current: Shade(NSColor(srgbRed: 1, green: 0.62, blue: 0.15, alpha: 0.55), NSColor(srgbRed: 0.85, green: 0.5, blue: 0.1, alpha: 0.6)),
            currentRing: Shade(.systemOrange),
            // Apart by hue and lightness both, for eyes that don't tell red from green.
            pdf: Shade(NSColor(srgbRed: 1, green: 0.84, blue: 0, alpha: 0.8)),
            pdfCurrent: Shade(NSColor(srgbRed: 0.2, green: 0.56, blue: 1, alpha: 0.7))),
        chart: Chart(
            // Checked for telling apart (colorblind too), each stepped for
            // light and dark: blue, orange, aqua.
            one: .hex(0x2A78D6, 0x3987E5),
            two: .hex(0xEB6834, 0xD95926),
            three: .hex(0x1BAF7A, 0x199E70),
            track: .wash(0.07, 0.09),
            surface: .wash(0.025, 0.035),
            grid: .wash(0.07, 0.08)),
        kinds: Kinds(
            git: Shade(.systemOrange), swift: Shade(.systemOrange), shell: Shade(.systemGreen), pdf: Shade(.systemRed),
            image: Shade(.systemPurple), data: Shade(.systemYellow), patch: Shade(.systemGreen), archive: Shade(.systemBrown),
            media: Shade(.systemPink), code: Shade(.systemBlue), linked: Shade(.systemPurple), embeds: Shade(.systemTeal)),
        // Paper, and GitHub's palettes, light and dark.
        terminal: (
            light: TerminalPalette(background: "#fcfcfb", foreground: "#24292f", cursor: "#007aff",
                                   selectionBackground: "#cfe2fb", selectionForeground: "#1f2328", ansi: [
                                       "#24292f", "#cf222e", "#116329", "#4d2d00", "#0969da", "#8250df", "#1b7c83", "#6e7781",
                                       "#57606a", "#a40e26", "#1a7f37", "#633c01", "#218bff", "#a475f9", "#3192aa", "#8c959f"]),
            dark: TerminalPalette(background: "#1c1c1b", foreground: "#e3e3df", cursor: "#0a84ff",
                                  selectionBackground: "#264f78", selectionForeground: "#f0f0ee", ansi: [
                                      "#484f58", "#ff7b72", "#3fb950", "#d29922", "#58a6ff", "#bc8cff", "#39c5cf", "#b1bac4",
                                      "#6e7681", "#ffa198", "#56d364", "#e3b341", "#79c0ff", "#d2a8ff", "#56d4dd", "#f0f6fc"])),
        // As go.dev sets its docs: its colours.
        page: Page(
            background: .hex(0xFFFFFF, 0x202224),
            text: .hex(0x202224, 0xDBDBDB),
            strong: .hex(0x202224, 0xF7F7F7),
            link: .hex(0x007D9C, 0x50B7E0),
            code: .hex(0xF8F8F8, 0x2D2D2D),
            codeText: .hex(0x202224, 0xF0F1F2),
            copy: .hex(0xFFFFFF, 0x383838),
            copyEdge: .hex(0xE1E4E8, 0x4A4A4A),
            copyText: .hex(0x6E7781, 0xA8A8A8),
            copyHoverEdge: .hex(0xC8CCD1, 0x5A5A5A),
            copyHoverText: .hex(0x202224, 0xF0F1F2),
            copyDone: .hex(0x1A7F37, 0x56D364),
            quote: .hex(0x57606A, 0x9D9D98),
            quoteRule: .hex(0xD8DBE0, 0x444441),
            rule: .hex(0xE1E4E8, 0x3A3A38),
            tableHead: .hex(0xF6F6F4, 0x262625),
            tableStripe: .hex(0xF9F9F7, 0x212120),
            struck: .hex(0x6E7781, 0x8B8B86),
            missing: .hex(0xA40E26, 0xFF7B72),
            diagramError: .hex(0xA40E26, 0xA40E26),
            selection: .hex(0xCFE2FB, 0x264F78),
            failed: .hex(0xD6453D, 0xD6453D),
            running: .hex(0x2F8FDD, 0x2F8FDD),
            attention: .hex(0xD68A1D, 0xD68A1D)))
}
