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
    /// Its own accent (the Theme tint); a terminal's caret and selection
    /// are its palette's then.
    var accent: TintColors
    /// Each tint's colours in it, but the system's (which is the system's).
    var tints: [Tint: TintColors]
    var code: Code
    var diff: Diff
    var found: Found
    var chart: Chart
    var kinds: Kinds
    /// All 256 of a terminal's colours, and its paper, text, caret and
    /// selection, in each appearance.
    var terminal: (light: TerminalPalette, dark: TerminalPalette)
    var page: Page
    /// What lies under the cards and the sidebar (`BackdropView`).
    var backdrop: Backdrop

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
        /// A column of summary cards (a card's fill).
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
        /// A tile's bar, where it isn't the panel's ground (Claude Warm's,
        /// a step off its pages, not white over them).
        var bar: Shade? = nil
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

    /// The backdrop in the light and in the dark: a wash from the upper
    /// left to the lower right through four colours (each turned a little
    /// in hue by the day), and two pools of light laid over it — the first
    /// the tint's, the other a hue of the wash's.
    struct Backdrop {
        struct Wash {
            /// Hue, saturation, brightness.
            var stops: [(CGFloat, CGFloat, CGFloat)]
            /// A pool of the wash's hue: its saturation and brightness.
            var pool: (saturation: CGFloat, brightness: CGFloat)
            /// The tint's pool: how much of the tint's saturation, and its brightness.
            var tintPool: (saturation: CGFloat, brightness: CGFloat)
        }
        var light: Wash
        var dark: Wash
        /// The shadow a tile casts on it in the light (none in the dark):
        /// its colour and how strong — black, as on Paper, reads as a grey
        /// band round each tile on a warm or tinted ground, so a theme's is
        /// a deeper shade of its own.
        var tileShadow: (color: NSColor, opacity: CGFloat) = (.black, 0.10)

        func wash(dark isDark: Bool) -> Wash { isDark ? dark : light }
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
    static let all: [Palette] = [.paper, .newsprint, .classic, .financialTimes, .claude, .claudeWarm, .claudeClassic]

    /// The theme by its id; Paper for one there isn't.
    static func named(_ id: String) -> Palette { all.first { $0.id == id } ?? .paper }

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
        // Its blue, the terminal's caret and selection as the blue's.
        accent: TintColors(accent: Shade(Theme.hex(0x3373F2)), caret: .hex(0x007AFF, 0x0A84FF), textSelection: .hex(0xCFE2FB, 0x264F78)),
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
        // Paper, and GitHub's palettes, light and dark; past the sixteen,
        // xterm's cube and greys in both.
        terminal: (
            light: TerminalPalette(background: "#fcfcfb", foreground: "#24292f", cursor: "#007aff",
                                   selectionBackground: "#cfe2fb", selectionForeground: "#1f2328", ansi: [
                                       "#24292f", "#cf222e", "#116329", "#4d2d00", "#0969da", "#8250df", "#1b7c83", "#6e7781",
                                       "#57606a", "#a40e26", "#1a7f37", "#633c01", "#218bff", "#a475f9", "#3192aa", "#8c959f"],
                                   extended: TerminalPalette.xtermExtended),
            dark: TerminalPalette(background: "#1c1c1b", foreground: "#e3e3df", cursor: "#0a84ff",
                                  selectionBackground: "#264f78", selectionForeground: "#f0f0ee", ansi: [
                                      "#484f58", "#ff7b72", "#3fb950", "#d29922", "#58a6ff", "#bc8cff", "#39c5cf", "#b1bac4",
                                      "#6e7681", "#ffa198", "#56d364", "#e3b341", "#79c0ff", "#d2a8ff", "#56d4dd", "#f0f6fc"],
                                  extended: TerminalPalette.xtermExtended)),
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
            attention: .hex(0xD68A1D, 0xD68A1D)),
        // Lavender to rose to peach to cream; in the dark, indigo to plum
        // to umber to near-black.
        backdrop: Backdrop(
            light: .init(stops: [(0.72, 0.28, 0.97), (0.95, 0.24, 0.99), (0.07, 0.28, 1.0), (0.12, 0.14, 1.0)],
                         pool: (0.18, 1), tintPool: (0.32, 1)),
            dark: .init(stops: [(0.70, 0.40, 0.26), (0.92, 0.35, 0.24), (0.06, 0.35, 0.22), (0.08, 0.15, 0.12)],
                        pool: (0.5, 0.4), tintPool: (0.6, 0.45))))
}

// MARK: Newsprint

extension Palette {
    /// Ink on newsprint: a grey, faintly warm paper and a near-black ink,
    /// muted inks for colour (a brick red, a sage, an ochre, a slate blue,
    /// a plum, a teal) — and by night the same paper unlit, the inks
    /// lifted to read on it. Its accent is the red, a terminal's caret too,
    /// selections a grey; its 256 colours are made from its own.
    static let newsprint: Palette = {
        let light = (bg: "#f2f2f0", fg: "#333331", ansi: [
            "#333331", "#b3402e", "#5d7f52", "#987921", "#4f6d94", "#85607f", "#4d7f7c", "#d5d5d0",
            "#78786f", "#cc4f3b", "#6f9562", "#af8e2c", "#6182ab", "#9b7494", "#5e9692", "#fdfdfb"])
        let dark = (bg: "#1f1f1d", fg: "#d6d6d0", ansi: [
            "#4a4a46", "#db6650", "#84a672", "#c2a24a", "#7894bf", "#a986a1", "#6fa39c", "#c9c9c2",
            "#6e6e68", "#e8806a", "#9dbe8a", "#d6b862", "#93acd3", "#c09fb8", "#89bab3", "#f2f2f0"])
        // Warm greys: a step less blue than red and green.
        func warm(_ v: CGFloat) -> NSColor { NSColor(srgbRed: v, green: v, blue: max(0, v - 0.008), alpha: 1) }
        func ink(_ light: Int, _ dark: Int) -> Shade { .hex(light, dark) }
        let red = ink(0xB3402E, 0xE07258), green = ink(0x56763F, 0x84A672), ochre = ink(0x7D6316, 0xC2A24A)
        let blue = ink(0x4F6D94, 0x7894BF), plum = ink(0x85607F, 0xA986A1), teal = ink(0x4D7F7C, 0x6FA39C)
        return Palette(
            id: "newsprint",
            title: "Newsprint",
            chrome: Chrome(
                hover: .wash(0.055, 0.07),
                selected: Shade(warm(0.985), NSColor(white: 1, alpha: 0.12)),
                pressed: .wash(0.11, 0.14),
                divider: .wash(0.1, 0.1),
                panel: .hex(0xF7F7F5, 0x2A2A27),
                panelBorder: .wash(0.12, 0.14),
                scrim: Shade(NSColor(srgbRed: 0.9, green: 0.9, blue: 0.89, alpha: 0.35), NSColor(white: 0, alpha: 0.3)),
                cardBorder: .wash(0.08, 0.1),
                handle: .wash(0.22, 0.25),
                scrubberKnob: .wash(0.14, 0.18),
                sheetEdge: .wash(0.2, 0.16),
                sheetEdgeHovered: .wash(0.34, 0.34),
                sheet: { level in Shade(warm(0.92 - CGFloat(level) * 0.045), warm(0.33 - CGFloat(level) * 0.045)) },
                stack: .hex(0xF7F7F5, 0x2E2E2B),
                dragPill: .hex(0xFBFBF9, 0x4A4A46),
                linkBehind: { depth in Shade(warm(0.94 - CGFloat(depth) * 0.03), warm(0.15 - CGFloat(depth) * 0.015)) },
                well: .wash(0.06, 0.09),
                pill: .wash(0.07, 0.1),
                historyWash: (from: .hex(0xEDEDE8, 0x2A2A27), to: .hex(0xE8E2D6, 0x302B25))),
            text: Text(
                primary: .hex(0x333331, 0xD6D6D0),
                body: .hex(0x333331, 0xD0D0CA),
                strong: .hex(0x1F1F1D, 0xEFEFE9),
                // At least 4.5:1 on a panel, in either appearance.
                secondary: .hex(0x66665F, 0xA3A39C),
                tertiary: .hex(0x707069, 0x96968F),
                readingBody: .hex(0x333331, 0xD6D6D0),
                readingStrong: .hex(0x1F1F1D, 0xEFEFE9)),
            status: StatusColors(done: green, attention: ochre, failed: red),
            // The brick red, as the terminal's caret is; selections its grey.
            accent: TintColors(accent: red, caret: ink(0xB3402E, 0xDB6650), textSelection: .hex(0xDDDDD6, 0x3A3A36)),
            tints: [
                .blue: TintColors(accent: blue, textSelection: .hex(0xD5DCE6, 0x343F4E)),
                .orange: TintColors(accent: .hex(0xB8662A, 0xD98A4E), textSelection: .hex(0xEBDDCD, 0x4A3A2C)),
                .purple: TintColors(accent: plum, textSelection: .hex(0xE3D9E1, 0x42363F)),
                .pink: TintColors(accent: .hex(0xA84A6A, 0xC77894), textSelection: .hex(0xEBD7DE, 0x4A3139)),
                .green: TintColors(accent: green, textSelection: .hex(0xD7E0D1, 0x34402F)),
                .graphite: TintColors(accent: .hex(0x66665F, 0xA3A39C), caret: .hex(0x333331, 0xD6D6D0), textSelection: .hex(0xDDDDD6, 0x3A3A36)),
            ],
            code: Code(
                page: .hex(0xEEEEEA, 0x2A2A27),
                text: .hex(0x333331, 0xDEDED8),
                lineNumber: .hex(0x9A9A93, 0x7A7A73),
                lineHighlight: .hex(0xECE9DA, 0x33322A),
                gutterText: .hex(0x9A9A93, 0x6E6E68),
                use: .wash(0.075, 0.1),
                match: Shade(NSColor(srgbRed: 0.88, green: 0.8, blue: 0.48, alpha: 0.6), NSColor(srgbRed: 0.55, green: 0.47, blue: 0.2, alpha: 0.7)),
                link: blue,
                linkHover: .wash(0.08, 0.13),
                added: ink(0x5D7F52, 0x84A672),
                modified: blue,
                deleted: ink(0xB3402E, 0xE07258),
                pins: [
                    Shade(NSColor(srgbRed: 0.30, green: 0.50, blue: 0.49, alpha: 0.26), NSColor(srgbRed: 0.44, green: 0.64, blue: 0.61, alpha: 0.33)),
                    Shade(NSColor(srgbRed: 0.60, green: 0.47, blue: 0.13, alpha: 0.28), NSColor(srgbRed: 0.76, green: 0.64, blue: 0.29, alpha: 0.33)),
                    Shade(NSColor(srgbRed: 0.52, green: 0.38, blue: 0.50, alpha: 0.26), NSColor(srgbRed: 0.66, green: 0.53, blue: 0.63, alpha: 0.33)),
                    Shade(NSColor(srgbRed: 0.70, green: 0.25, blue: 0.18, alpha: 0.22), NSColor(srgbRed: 0.88, green: 0.45, blue: 0.35, alpha: 0.3)),
                ],
                error: red,
                warning: ochre,
                hint: Shade(Theme.hex(0x4F6D94).withAlphaComponent(0.6), Theme.hex(0x7894BF).withAlphaComponent(0.6)),
                changedOnDisk: .hex(0xEEE8D5, 0x37332A),
                highlighter: Shade(NSColor(srgbRed: 0.91, green: 0.82, blue: 0.45, alpha: 0.5), NSColor(srgbRed: 0.6, green: 0.5, blue: 0.2, alpha: 0.45))),
            diff: Diff(
                added: .hex(0xDCE4D6, 0x2C3A28),
                removed: .hex(0xEFDAD5, 0x45292A),
                hunk: .hex(0xDDE2E9, 0x2B3340),
                found: .hex(0xEDE3BA, 0x4A4227),
                current: .hex(0xE2CE86, 0x6E5D25)),
            found: Found(
                current: Shade(NSColor(srgbRed: 0.84, green: 0.58, blue: 0.3, alpha: 0.5), NSColor(srgbRed: 0.72, green: 0.45, blue: 0.2, alpha: 0.55)),
                currentRing: red,
                pdf: Shade(NSColor(srgbRed: 1, green: 0.84, blue: 0, alpha: 0.8)),
                pdfCurrent: Shade(NSColor(srgbRed: 0.2, green: 0.56, blue: 1, alpha: 0.7))),
            chart: Chart(
                one: blue,
                two: ink(0xB3402E, 0xDB6650),
                three: teal,
                track: .wash(0.07, 0.09),
                surface: .wash(0.025, 0.035),
                grid: .wash(0.07, 0.08)),
            kinds: Kinds(
                git: ink(0xB8662A, 0xD98A4E), swift: ink(0xB8662A, 0xD98A4E), shell: green, pdf: red, image: plum,
                data: ochre, patch: green, archive: ink(0x7A6A55, 0xA8977E), media: ink(0xA84A6A, 0xC77894), code: blue,
                linked: plum, embeds: teal),
            terminal: (
                light: TerminalPalette(background: light.bg, foreground: light.fg, cursor: "#b3402e", cursorText: light.bg,
                                       selectionBackground: "#ddddd6", selectionForeground: light.fg, ansi: light.ansi,
                                       extended: TerminalPalette.generated(background: light.bg, foreground: light.fg, ansi: light.ansi)),
                dark: TerminalPalette(background: dark.bg, foreground: dark.fg, cursor: "#db6650", cursorText: dark.bg,
                                      selectionBackground: "#3a3a36", selectionForeground: "#ecece6", ansi: dark.ansi,
                                      extended: TerminalPalette.generated(background: dark.bg, foreground: dark.fg, ansi: dark.ansi))),
            page: Page(
                background: .hex(0xF7F7F4, 0x1F1F1D),
                text: .hex(0x333331, 0xD6D6D0),
                strong: .hex(0x1F1F1D, 0xEFEFE9),
                link: blue,
                code: .hex(0xEAEAE6, 0x2A2A27),
                codeText: .hex(0x333331, 0xDEDED8),
                copy: .hex(0xF7F7F4, 0x333330),
                copyEdge: .hex(0xD6D6CF, 0x48483F),
                copyText: .hex(0x707069, 0xA3A39C),
                copyHoverEdge: .hex(0xBDBDB5, 0x5A5A54),
                copyHoverText: .hex(0x333331, 0xEFEFE9),
                copyDone: green,
                quote: .hex(0x66665F, 0xA3A39C),
                quoteRule: .hex(0xD6D6CF, 0x46463F),
                rule: .hex(0xDDDDD6, 0x3A3A36),
                tableHead: .hex(0xECECE7, 0x282826),
                tableStripe: .hex(0xF0F0EC, 0x232321),
                struck: .hex(0x85857F, 0x8B8B85),
                missing: red,
                diagramError: red,
                selection: .hex(0xDDDDD6, 0x3A3A36),
                failed: red,
                running: blue,
                attention: ochre),
            // Newsprint under the cards: off-whites a shade warmer or
            // cooler than the paper, by night its paper unlit; the pools
            // faint, the tint's (its red) a blush.
            backdrop: Backdrop(
                // Deeper than the paper the tiles are, from corner to
                // corner more than before, as a desk under the pages: a
                // warm grey, little colour in it.
                light: .init(stops: [(0.11, 0.11, 0.89), (0.07, 0.13, 0.85), (0.12, 0.10, 0.80), (0.14, 0.05, 0.92)],
                             pool: (0.10, 0.96), tintPool: (0.12, 0.96)),
                dark: .init(stops: [(0.10, 0.10, 0.19), (0.06, 0.13, 0.18), (0.11, 0.10, 0.15), (0.13, 0.05, 0.11)],
                            pool: (0.16, 0.25), tintPool: (0.22, 0.31)),
                // A warm umber, softer: the paper deepened, not greyed.
                tileShadow: (Theme.hex(0x5A4630), 0.08)))
    }()
}

// MARK: Classic

extension Palette {
    /// apex's Classic (~/src/apex, crates/apex-client/src/theme.rs): acme's
    /// make — cream paper, its tags (here the panels, the sidebar's ground)
    /// a pale blue, a yellow selection — in the hues of go.dev's
    /// playground: its ink (#202224) and secondary (#6e7072), Go blue
    /// (#007d9c) the accent and caret. By night go.dev's own: #202224
    /// paper, #e6e6e6 ink, its link blue (#50b7e0), acme's dark yellow
    /// selection. As apex has it for a colour-blind reader: orange for red
    /// and blue for green — diffs, gutters, the terminal's sixteen
    /// (GitHub's colour-blind ones) — B2's burnt orange (#c85a00) and B3's
    /// deeper blue (#2a5db0) for what's added and taken away.
    static let classic: Palette = {
        let light = (bg: "#fcfcf2", fg: "#202224", ansi: [
            "#24292f", "#b35900", "#0550ae", "#4d2d00", "#0969da", "#8250df", "#1b7c83", "#6e7781",
            "#57606a", "#8a4600", "#0969da", "#633c01", "#218bff", "#a475f9", "#3192aa", "#8c959f"])
        let dark = (bg: "#202224", fg: "#e6e6e6", ansi: [
            "#545d68", "#f69d50", "#539bf5", "#c69026", "#539bf5", "#b083f0", "#39c5cf", "#909dab",
            "#636e7b", "#ffbc6f", "#6cb6ff", "#daaa3f", "#6cb6ff", "#dcbdfb", "#56d4dd", "#cdd9e5"])
        let go = Shade.hex(0x007D9C, 0x50B7E0)
        // B2 and B3's sweeps: what's taken away and what's added.
        let orange = Shade.hex(0xC85A00, 0xE07A2A), blue = Shade.hex(0x2A5DB0, 0x5E8EDB)
        // Stale's ochre (darkened in the light to read as text), and the
        // fuchsia of a fenced handle for what failed.
        let ochre = Shade.hex(0x8F6B00, 0xFDDD00), fuchsia = Shade.hex(0xCE3262, 0xE0547A)
        let selection = Shade.hex(0xF1E9A6, 0x4A4526)
        return Palette(
            id: "classic",
            title: "Classic",
            chrome: Chrome(
                hover: .hex(0xF0F4F5, 0x333537),
                selected: Shade(.white, NSColor(white: 1, alpha: 0.12)),
                pressed: .wash(0.11, 0.14),
                divider: .hex(0xD6DCDD, 0x3A3C3E),
                panel: .hex(0xFFFFFF, 0x2B2D2F),
                panelBorder: .hex(0xD6DCDD, 0x3A3C3E),
                scrim: Shade(NSColor(srgbRed: 0.91, green: 0.94, blue: 0.95, alpha: 0.35), NSColor(white: 0, alpha: 0.3)),
                cardBorder: .wash(0.08, 0.1),
                handle: .hex(0xD4D4C4, 0x4A4C4E),
                scrubberKnob: .hex(0xD4D4C4, 0x4A4C4E),
                sheetEdge: .wash(0.2, 0.16),
                sheetEdgeHovered: .wash(0.34, 0.34),
                // The tags' pale blue, deeper further down; by night lighter nearer the top.
                sheet: { level in Shade(NSColor(srgbRed: 0.90 - CGFloat(level) * 0.045, green: 0.94 - CGFloat(level) * 0.045, blue: 0.95 - CGFloat(level) * 0.04, alpha: 1),
                                        NSColor(srgbRed: 0.31 - CGFloat(level) * 0.045, green: 0.32 - CGFloat(level) * 0.045, blue: 0.33 - CGFloat(level) * 0.045, alpha: 1)) },
                stack: .hex(0xF5F5EA, 0x26282A),
                dragPill: .hex(0xFFFFFF, 0x4A4C4E),
                linkBehind: { depth in Shade(NSColor(srgbRed: 0.92 - CGFloat(depth) * 0.03, green: 0.96 - CGFloat(depth) * 0.03, blue: 0.97 - CGFloat(depth) * 0.03, alpha: 1),
                                            NSColor(srgbRed: 0.17 - CGFloat(depth) * 0.015, green: 0.18 - CGFloat(depth) * 0.015, blue: 0.19 - CGFloat(depth) * 0.015, alpha: 1)) },
                well: .wash(0.06, 0.09),
                pill: .wash(0.07, 0.1),
                historyWash: (from: .hex(0xEAF4F7, 0x1F3A44), to: .hex(0xF1E9C6, 0x3A3524))),
            text: Text(
                primary: .hex(0x202224, 0xE6E6E6),
                body: .hex(0x202224, 0xDEDEDE),
                strong: .hex(0x000000, 0xF7F7F7),
                // At least 4.5:1 on a panel, in either appearance (apex's
                // faint #8a8c8e isn't, so a step darker).
                secondary: .hex(0x6E7072, 0x9A9C9E),
                tertiary: .hex(0x737577, 0x969899),
                readingBody: .hex(0x202224, 0xDBDBDB),
                readingStrong: .hex(0x202224, 0xF7F7F7)),
            status: StatusColors(done: blue, attention: ochre, failed: fuchsia),
            // Go blue, a terminal's caret too; acme's yellow selection.
            accent: TintColors(accent: go, textSelection: selection),
            tints: Palette.paper.tints,
            code: Code(
                page: .hex(0xFCFCF2, 0x202224),
                text: .hex(0x202224, 0xE6E6E6),
                lineNumber: .hex(0x8A8C8E, 0x6E7072),
                lineHighlight: .hex(0xF7F2CC, 0x2F2D22),
                gutterText: .hex(0x8A8C8E, 0x6E7072),
                use: .wash(0.075, 0.1),
                match: Shade(NSColor(srgbRed: 0.95, green: 0.87, blue: 0.45, alpha: 0.65), NSColor(srgbRed: 0.5, green: 0.44, blue: 0.12, alpha: 0.75)),
                link: go,
                linkHover: .wash(0.08, 0.13),
                added: blue,
                modified: go,
                deleted: orange,
                pins: Palette.paper.code.pins,
                error: fuchsia,
                warning: orange,
                hint: Shade(Theme.hex(0x007D9C).withAlphaComponent(0.6), Theme.hex(0x50B7E0).withAlphaComponent(0.6)),
                changedOnDisk: .hex(0xF5EFCF, 0x332F20),
                highlighter: Shade(NSColor(srgbRed: 0.95, green: 0.88, blue: 0.4, alpha: 0.55), NSColor(srgbRed: 0.6, green: 0.52, blue: 0.15, alpha: 0.45))),
            diff: Diff(
                added: .hex(0xE1F3F8, 0x16323D),
                removed: .hex(0xFFF0DA, 0x3A2C1C),
                hunk: .hex(0xEAF4F7, 0x2B2D2F),
                found: selection,
                current: .hex(0xE8D66A, 0x6E6326)),
            found: Found(
                current: Shade(NSColor(srgbRed: 0.78, green: 0.35, blue: 0, alpha: 0.45), NSColor(srgbRed: 0.88, green: 0.48, blue: 0.16, alpha: 0.55)),
                currentRing: orange,
                pdf: Shade(NSColor(srgbRed: 1, green: 0.84, blue: 0, alpha: 0.8)),
                pdfCurrent: Shade(NSColor(srgbRed: 0.2, green: 0.56, blue: 1, alpha: 0.7))),
            chart: Chart(
                one: blue,
                two: orange,
                three: go,
                track: .wash(0.07, 0.09),
                surface: .wash(0.025, 0.035),
                grid: .wash(0.07, 0.08)),
            kinds: Palette.paper.kinds,
            terminal: (
                light: TerminalPalette(background: light.bg, foreground: light.fg, cursor: "#007d9c", cursorText: light.bg,
                                       selectionBackground: "#f1e9a6", selectionForeground: light.fg, ansi: light.ansi,
                                       extended: TerminalPalette.xtermExtended),
                dark: TerminalPalette(background: dark.bg, foreground: dark.fg, cursor: "#50b7e0", cursorText: dark.bg,
                                      selectionBackground: "#4a4526", selectionForeground: "#f7f7f7", ansi: dark.ansi,
                                      extended: TerminalPalette.xtermExtended)),
            // As go.dev sets its docs, on the cream paper.
            page: Page(
                background: .hex(0xFCFCF2, 0x202224),
                text: .hex(0x202224, 0xDBDBDB),
                strong: .hex(0x202224, 0xF7F7F7),
                link: go,
                code: .hex(0xF2F2E6, 0x2B2D2F),
                codeText: .hex(0x202224, 0xF0F1F2),
                copy: .hex(0xFFFFFF, 0x383A3C),
                copyEdge: .hex(0xD6DCDD, 0x4A4C4E),
                copyText: .hex(0x6E7072, 0xA8AAAC),
                copyHoverEdge: .hex(0xBCC4C6, 0x5A5C5E),
                copyHoverText: .hex(0x202224, 0xF0F1F2),
                copyDone: blue,
                quote: .hex(0x6E7072, 0x9A9C9E),
                quoteRule: .hex(0xD6DCDD, 0x444648),
                rule: .hex(0xD6DCDD, 0x3A3C3E),
                tableHead: .hex(0xEAF4F7, 0x2B2D2F),
                tableStripe: .hex(0xF5F5EA, 0x242628),
                struck: .hex(0x6E7072, 0x8A8C8E),
                missing: fuchsia,
                diagramError: fuchsia,
                selection: selection,
                failed: fuchsia,
                running: go,
                attention: ochre),
            // acme's colours under the cards: its tags' pale blue into its
            // cream paper and its yellow; by night go.dev's slate into
            // acme's dark yellow. The tint's pool, Go blue.
            backdrop: Backdrop(
                light: .init(stops: [(0.54, 0.17, 0.96), (0.52, 0.09, 0.98), (0.16, 0.13, 0.99), (0.15, 0.25, 0.98)],
                             pool: (0.2, 1), tintPool: (0.4, 1)),
                dark: .init(stops: [(0.55, 0.45, 0.27), (0.57, 0.32, 0.22), (0.14, 0.42, 0.23), (0.58, 0.15, 0.13)],
                            pool: (0.45, 0.33), tintPool: (0.65, 0.42)),
                // go.dev's slate.
                tileShadow: (Theme.hex(0x2B4650), 0.09)))
    }()
}

// MARK: Financial Times

extension Palette {
    /// The Financial Times' (github.com/mariusae/financial-times-theme, from
    /// FT Origami's palette): its paper (#fff1e5) and body ink (#33302e),
    /// wheat (#f2dfce) for what's selected, teal (#0d7680) for links and the
    /// accent, an ink caret; its jade, mandarin and crimson for what passed,
    /// wants attention and failed; and by night its inverse, slate
    /// (#262a33) with white ink, black-70 (#4d4845) selected, the inks lifted
    /// to read on it. The terminal's sixteen are the theme's own Ghostty
    /// palette (Origami's colours eased to 5.5:1 on the paper), the rest
    /// made from them. FT's muted grey (#807973) reads at 3.9:1, so the
    /// secondary text is the step darker, black-60; jade and mandarin are
    /// deepened where they're read as text.
    static let financialTimes: Palette = {
        let light = (bg: "#fff1e5", fg: "#33302e", ansi: [
            "#262a33", "#990f3d", "#146f41", "#855330", "#0f5499", "#593380", "#136c74", "#66605c",
            "#4d4845", "#c40202", "#56672c", "#665f29", "#1a6886", "#855060", "#27686d", "#5c5958"])
        let dark = (bg: "#262a33", fg: "#ffffff", ansi: [
            "#a8aaad", "#d193a8", "#caeada", "#ff8833", "#87aacc", "#ac99c0", "#6eadb3", "#fff1e5",
            "#a6a4a2", "#e88c8c", "#d5eba9", "#ffec1a", "#26aee2", "#ff7faa", "#14bdcc", "#ffffff"])
        let teal = Shade.hex(0x0D7680, 0x14BDCC), oxford = Shade.hex(0x0F5499, 0x87AACC)
        let jade = Shade.hex(0x007A3D, 0x66CC99), mandarin = Shade.hex(0xA35214, 0xFF8833), crimson = Shade.hex(0xCC0000, 0xFF6666)
        let claret = Shade.hex(0x990F3D, 0xD193A8), velvet = Shade.hex(0x593380, 0xAC99C0)
        let wheat = Shade.hex(0xF2DFCE, 0x4D4845)
        // FT's warm greys (black-5 to black-30) by day; slate lightened by night.
        return Palette(
            id: "financial-times",
            title: "Financial Times",
            chrome: Chrome(
                hover: .wash(0.05, 0.07),
                selected: Shade(Theme.hex(0xFFFCFA), NSColor(white: 1, alpha: 0.12)),
                pressed: .wash(0.1, 0.14),
                divider: .hex(0xE6D9CE, 0x3D414A),
                panel: .hex(0xFFF7EF, 0x2D313A),
                panelBorder: .hex(0xE6D9CE, 0x3D414A),
                scrim: Shade(NSColor(srgbRed: 0.95, green: 0.88, blue: 0.81, alpha: 0.35), NSColor(white: 0, alpha: 0.3)),
                cardBorder: .wash(0.08, 0.1),
                handle: .hex(0xCCC1B7, 0x4D515A),
                scrubberKnob: .hex(0xCCC1B7, 0x4D515A),
                sheetEdge: .wash(0.2, 0.16),
                sheetEdgeHovered: .wash(0.34, 0.34),
                // Wheat, deeper further down; by night slate, lighter nearer the top.
                sheet: { level in Shade(NSColor(srgbRed: 0.95 - CGFloat(level) * 0.045, green: 0.875 - CGFloat(level) * 0.045, blue: 0.81 - CGFloat(level) * 0.04, alpha: 1),
                                        NSColor(srgbRed: 0.27 - CGFloat(level) * 0.04, green: 0.29 - CGFloat(level) * 0.04, blue: 0.33 - CGFloat(level) * 0.045, alpha: 1)) },
                stack: .hex(0xFFF7EF, 0x2A2E37),
                dragPill: .hex(0xFFFCFA, 0x4D515A),
                linkBehind: { depth in Shade(NSColor(srgbRed: 0.97 - CGFloat(depth) * 0.03, green: 0.91 - CGFloat(depth) * 0.03, blue: 0.86 - CGFloat(depth) * 0.03, alpha: 1),
                                            NSColor(srgbRed: 0.18 - CGFloat(depth) * 0.015, green: 0.19 - CGFloat(depth) * 0.015, blue: 0.23 - CGFloat(depth) * 0.015, alpha: 1)) },
                well: .wash(0.06, 0.09),
                pill: .wash(0.07, 0.1),
                // Sky into FT pink; by night Oxford's deep blue into claret's.
                historyWash: (from: .hex(0xE6EEF5, 0x1E2E44), to: .hex(0xFCE0CC, 0x3A2230))),
            text: Text(
                primary: .hex(0x33302E, 0xE9EAEB),
                body: .hex(0x33302E, 0xE9EAEB),
                strong: .hex(0x1A1817, 0xFFFFFF),
                // At least 4.5:1 on a panel, in either appearance.
                secondary: .hex(0x66605C, 0xA8AAAD),
                tertiary: .hex(0x6F6964, 0x9A9CA0),
                readingBody: .hex(0x33302E, 0xE9EAEB),
                readingStrong: .hex(0x1A1817, 0xFFFFFF)),
            status: StatusColors(done: jade, attention: mandarin, failed: crimson),
            // Teal, as FT's links and buttons; an ink caret on wheat, as its terminal's.
            accent: TintColors(accent: teal, caret: .hex(0x33302E, 0xFFFFFF), textSelection: wheat),
            tints: Palette.paper.tints,
            code: Code(
                page: .hex(0xFFF1E5, 0x262A33),
                text: .hex(0x33302E, 0xF2F2F2),
                lineNumber: .hex(0x999189, 0x7D8088),
                lineHighlight: .hex(0xF7E7DA, 0x2D313A),
                gutterText: .hex(0x999189, 0x6E717A),
                use: .wash(0.075, 0.1),
                match: Shade(NSColor(srgbRed: 1, green: 0.88, blue: 0.4, alpha: 0.6), NSColor(srgbRed: 0.6, green: 0.5, blue: 0.1, alpha: 0.7)),
                link: teal,
                linkHover: .wash(0.08, 0.13),
                added: Shade.hex(0x00994D, 0x66CC99),
                modified: Shade.hex(0xFF8833, 0xFF8833),
                deleted: crimson,
                pins: [
                    Shade(NSColor(srgbRed: 0.05, green: 0.46, blue: 0.50, alpha: 0.24), NSColor(srgbRed: 0.08, green: 0.74, blue: 0.80, alpha: 0.3)),
                    Shade(NSColor(srgbRed: 1, green: 0.53, blue: 0.2, alpha: 0.3), NSColor(srgbRed: 1, green: 0.53, blue: 0.2, alpha: 0.33)),
                    Shade(NSColor(srgbRed: 0.35, green: 0.2, blue: 0.5, alpha: 0.24), NSColor(srgbRed: 0.67, green: 0.6, blue: 0.75, alpha: 0.33)),
                    Shade(NSColor(srgbRed: 1, green: 0.5, blue: 0.67, alpha: 0.3), NSColor(srgbRed: 1, green: 0.5, blue: 0.67, alpha: 0.33)),
                ],
                error: crimson,
                warning: Shade.hex(0xFF8833, 0xFF8833),
                hint: Shade(Theme.hex(0x0D7680).withAlphaComponent(0.6), Theme.hex(0x14BDCC).withAlphaComponent(0.6)),
                changedOnDisk: .hex(0xF2DFCE, 0x3A3633),
                highlighter: Shade(NSColor(srgbRed: 1, green: 0.93, blue: 0.1, alpha: 0.45), NSColor(srgbRed: 0.7, green: 0.62, blue: 0.1, alpha: 0.45))),
            diff: Diff(
                // FT's success background; crimson at a wash, on its paper.
                added: .hex(0xD7F0D1, 0x1E3D33),
                removed: .hex(0xFADBD0, 0x46262C),
                hunk: .hex(0xE6EEF5, 0x2D3646),
                found: .hex(0xFFF0A8, 0x4A4527),
                current: .hex(0xFFE066, 0x6E6326)),
            found: Found(
                current: Shade(NSColor(srgbRed: 1, green: 0.53, blue: 0.2, alpha: 0.45), NSColor(srgbRed: 1, green: 0.53, blue: 0.2, alpha: 0.5)),
                currentRing: .hex(0xFF8833, 0xFF8833),
                pdf: Shade(NSColor(srgbRed: 1, green: 0.84, blue: 0, alpha: 0.8)),
                pdfCurrent: Shade(NSColor(srgbRed: 0.2, green: 0.56, blue: 1, alpha: 0.7))),
            chart: Chart(
                one: oxford,
                two: Shade.hex(0xFF8833, 0xFF8833),
                three: teal,
                track: .wash(0.07, 0.09),
                surface: .wash(0.025, 0.035),
                grid: .wash(0.07, 0.08)),
            kinds: Kinds(
                git: mandarin, swift: mandarin, shell: jade, pdf: crimson, image: velvet,
                data: Shade.hex(0x665F29, 0xFFEC1A), patch: jade, archive: .hex(0x66605C, 0xA8AAAD), media: claret, code: oxford,
                linked: velvet, embeds: teal),
            terminal: (
                light: TerminalPalette(background: light.bg, foreground: light.fg, cursor: light.fg, cursorText: light.bg,
                                       selectionBackground: "#f2dfce", selectionForeground: light.fg, ansi: light.ansi,
                                       extended: TerminalPalette.generated(background: light.bg, foreground: light.fg, ansi: light.ansi)),
                dark: TerminalPalette(background: dark.bg, foreground: dark.fg, cursor: dark.fg, cursorText: dark.bg,
                                      selectionBackground: "#4d4845", selectionForeground: dark.fg, ansi: dark.ansi,
                                      extended: TerminalPalette.generated(background: dark.bg, foreground: dark.fg, ansi: dark.ansi))),
            // As ft.com sets an article: on its paper, teal links.
            page: Page(
                background: .hex(0xFFF1E5, 0x262A33),
                text: .hex(0x33302E, 0xE9EAEB),
                strong: .hex(0x1A1817, 0xFFFFFF),
                link: teal,
                code: .hex(0xF2E5DA, 0x2D313A),
                codeText: .hex(0x33302E, 0xF2F2F2),
                copy: .hex(0xFFF7EF, 0x333740),
                copyEdge: .hex(0xE6D9CE, 0x4A4E57),
                copyText: .hex(0x66605C, 0xA8AAAD),
                copyHoverEdge: .hex(0xCCC1B7, 0x5A5E67),
                copyHoverText: .hex(0x33302E, 0xF2F2F2),
                copyDone: jade,
                quote: .hex(0x4D4845, 0xA8AAAD),
                quoteRule: .hex(0xCCC1B7, 0x4A4E57),
                rule: .hex(0xE6D9CE, 0x3D414A),
                tableHead: .hex(0xF2E5DA, 0x2D313A),
                tableStripe: .hex(0xFAECE0, 0x21252D),
                struck: .hex(0x807973, 0x8B8D91),
                missing: crimson,
                diagramError: crimson,
                selection: wheat,
                failed: crimson,
                running: teal,
                attention: mandarin),
            // FT pink into its paper and wheat; by night slate, a claret
            // dusk in it. The tint's pool, teal.
            backdrop: Backdrop(
                // The salmon paper deepened under the tiles, more from
                // corner to corner: the pages set apart from it.
                light: .init(stops: [(0.07, 0.30, 0.93), (0.08, 0.18, 0.96), (0.075, 0.26, 0.84), (0.075, 0.12, 0.93)],
                             pool: (0.22, 0.98), tintPool: (0.35, 0.98)),
                dark: .init(stops: [(0.61, 0.32, 0.24), (0.60, 0.42, 0.22), (0.93, 0.35, 0.20), (0.61, 0.22, 0.14)],
                            pool: (0.4, 0.3), tintPool: (0.6, 0.4)),
                // A warm ink, as FT's black-80: the paper deepened, not greyed.
                tileShadow: (Theme.hex(0x4D3A2A), 0.09)))
    }()
}

// MARK: Claude

extension Palette {
    /// Claude's desktop app (Claude.app, read from its stylesheets and
    /// scripts as shipped): the Code tab's design system (`cds`) with its
    /// neutral greys, as the app on this Mac draws them — by day white
    /// pages (#fff) on a #fafafa sidebar, by night #191919 on #1f1f1f,
    /// popovers #303030 — its ink (#0b0b0b, #efefef) and its secondary
    /// text (black at 60%, white at 57%); clay (#d97757, emphasized
    /// #c6613f where it sits on white) for the accent, as its brand fill
    /// and its spinner; and Claude Code's own terminal and code palettes
    /// (`claudeCodeThemes`): its ANSI sixteen, its cool ink
    /// (hsl(220 20% 10%), hsl(220 15% 93%)), a blue caret and a blue
    /// selection. Its diffs' grounds as the app renders them. One
    /// departure: its muted grey (#878787) reads at 3.6:1 on white, so the
    /// tertiary text by day is #737373 (4.7:1).
    static let claude: Palette = {
        let light = (bg: "#ffffff", fg: "#14181f", ansi: [
            "#1a1a1a", "#ff3a30", "#1e9e3c", "#98801f", "#0073e6", "#cd2054", "#8e6bd9", "#999999",
            "#666666", "#ff5047", "#1e9e3c", "#98801f", "#0078f0", "#cd2054", "#8e6bd9", "#d6d6d6"])
        let dark = (bg: "#191919", fg: "#eaecf0", ansi: [
            "#262626", "#ff3a30", "#32d74b", "#ffd014", "#0099ff", "#ff2c56", "#b796ff", "#a6a6a6",
            "#525252", "#ff5047", "#32d74b", "#ffd014", "#0087ee", "#ff2c56", "#b796ff", "#ededed"])
        let clay = Shade.hex(0xC6613F, 0xD97757)
        // Claude Code's blue: its terminal's caret, its selection's hue.
        let blue = Shade.hex(0x0073E6, 0x0099FF), selection = Shade.hex(0xBFDCF9, 0x123F5E)
        // Its git colours (cds-text-git-*): added, modified, removed.
        let added = Shade.hex(0x1E9E3C, 0x32D74B), modified = Shade.hex(0x98801F, 0xFFD014), removed = Shade.hex(0xCD2054, 0xFF2C56)
        let violet = Shade.hex(0x8E6BD9, 0xB796FF), aqua = Shade.hex(0x0F7E5C, 0x3BBD8C)
        // Its success, warning and danger, as text: each 4.9:1 or more.
        let done = Shade.hex(0x008300, 0x0CA30C), attention = Shade.hex(0x945D00, 0xDB9300), failed = Shade.hex(0xB93535, 0xEC7E7E)
        func alpha(_ hex: Int, _ light: CGFloat, _ darkHex: Int, _ dark: CGFloat) -> Shade {
            Shade(Theme.hex(hex).withAlphaComponent(light), Theme.hex(darkHex).withAlphaComponent(dark))
        }
        return Palette(
            id: "claude",
            title: "Claude",
            chrome: Chrome(
                // Its ghost hover and selected fills: black at 5% and 10%,
                // white at 7.5% and 15%.
                hover: .wash(0.05, 0.075),
                selected: Shade(.white, NSColor(white: 1, alpha: 0.13)),
                pressed: .wash(0.1, 0.15),
                // Its seams (black at 10%) and its composer's ring (12%).
                divider: .wash(0.1, 0.1),
                panel: .hex(0xFFFFFF, 0x303030),
                panelBorder: .wash(0.12, 0.14),
                scrim: Shade(NSColor(white: 0.9, alpha: 0.35), NSColor(white: 0, alpha: 0.4)),
                cardBorder: .wash(0.08, 0.1),
                handle: .wash(0.22, 0.25),
                scrubberKnob: .wash(0.14, 0.18),
                sheetEdge: .wash(0.2, 0.16),
                sheetEdgeHovered: .wash(0.34, 0.34),
                sheet: { level in .grey(0.94 - CGFloat(level) * 0.045, 0.25 - CGFloat(level) * 0.04) },
                stack: .hex(0xFFFFFF, 0x1F1F1F),
                dragPill: .hex(0xFFFFFF, 0x303030),
                linkBehind: { depth in .grey(0.95 - CGFloat(depth) * 0.03, 0.14 - CGFloat(depth) * 0.015) },
                well: .wash(0.05, 0.075),
                pill: .wash(0.07, 0.1),
                // Claude Code's blue into clay.
                historyWash: (from: .hex(0xEBF4FD, 0x162B39), to: .hex(0xFAEBE6, 0x3F2C25))),
            text: Text(
                primary: .hex(0x0B0B0B, 0xEFEFEF),
                body: .hex(0x0B0B0B, 0xEFEFEF),
                strong: .hex(0x000000, 0xFFFFFF),
                secondary: .hex(0x666666, 0x9C9C9C),
                tertiary: .hex(0x737373, 0x878787),
                readingBody: .hex(0x0B0B0B, 0xEFEFEF),
                readingStrong: .hex(0x000000, 0xFFFFFF)),
            status: StatusColors(done: done, attention: attention, failed: failed),
            accent: TintColors(accent: clay, caret: blue, textSelection: selection),
            tints: Palette.paper.tints,
            code: Code(
                // Read, not edited (view mode, a search's preview): a grey
                // step off the white pages edited; by night its sidebar's.
                page: .hex(0xF7F7F7, 0x1F1F1F),
                text: .hex(0x14181F, 0xEAECF0),
                lineNumber: .hex(0x878787, 0x878787),
                // Its editor's line highlight: #1a1a1a at 4%, white at 5%.
                lineHighlight: .hex(0xF6F6F6, 0x242424),
                gutterText: .hex(0x878787, 0x6B6B6B),
                // Its selection match: the blue at 10% and 14%.
                use: alpha(0x0073E6, 0.1, 0x0099FF, 0.14),
                // Its other find matches: #ffd500 at 25% and 18%.
                match: alpha(0xFFD500, 0.25, 0xFFD500, 0.18),
                link: blue,
                linkHover: .wash(0.08, 0.13),
                added: added,
                modified: modified,
                deleted: removed,
                // Its bracket pairs' colours, faint.
                pins: [
                    alpha(0x945D00, 0.24, 0xFFD014, 0.3),
                    alpha(0xAD3D66, 0.22, 0xF3C0D3, 0.3),
                    alpha(0x256ABF, 0.22, 0x3BBD8C, 0.3),
                    alpha(0x8E6BD9, 0.22, 0xB796FF, 0.3),
                ],
                error: .hex(0xE34948, 0xFF5047),
                warning: .hex(0xB77700, 0xFFD014),
                hint: alpha(0x0073E6, 0.6, 0x0099FF, 0.6),
                changedOnDisk: .hex(0xFFF7D5, 0x352F18),
                // Its highlight: the warning's yellow, a third through.
                highlighter: alpha(0xFFD014, 0.4, 0xFFD014, 0.3)),
            diff: Diff(
                // As the app's diffs are drawn (read from its window).
                added: .hex(0xE9F5E8, 0x263C25),
                removed: .hex(0xFAE9EE, 0x461C24),
                hunk: .hex(0xEBF4FD, 0x162B39),
                found: .hex(0xFFF4BF, 0x423B14),
                current: .hex(0xFFE873, 0x75640F)),
            found: Found(
                // Its find match: #ffd500 at 55%.
                current: alpha(0xFFD500, 0.55, 0xFFD500, 0.55),
                currentRing: .hex(0xB77700, 0xFFD014),
                pdf: Shade(NSColor(srgbRed: 1, green: 0.84, blue: 0, alpha: 0.8)),
                pdfCurrent: Shade(NSColor(srgbRed: 0.2, green: 0.56, blue: 1, alpha: 0.7))),
            chart: Chart(
                // Its accent fill's blue, clay, and its added green.
                one: .hex(0x2A78D6, 0x3987E5),
                two: .hex(0xD97757, 0xD97757),
                three: added,
                track: .wash(0.07, 0.09),
                surface: .wash(0.025, 0.035),
                grid: .wash(0.07, 0.08)),
            kinds: Kinds(
                git: .hex(0xC5621B, 0xFA832E), swift: .hex(0xD95926, 0xEC835A), shell: added, pdf: .hex(0xE34948, 0xEC7E7E),
                image: violet, data: modified, patch: added, archive: .hex(0x6B6B6B, 0xA6A6A6), media: removed, code: blue,
                linked: violet, embeds: aqua),
            terminal: (
                light: TerminalPalette(background: light.bg, foreground: light.fg, cursor: "#0073e6", cursorText: light.bg,
                                       selectionBackground: "#bfdcf9", selectionForeground: light.fg, ansi: light.ansi,
                                       extended: TerminalPalette.generated(background: light.bg, foreground: light.fg, ansi: light.ansi)),
                dark: TerminalPalette(background: dark.bg, foreground: dark.fg, cursor: "#0099ff", cursorText: dark.bg,
                                      selectionBackground: "#123f5e", selectionForeground: dark.fg, ansi: dark.ansi,
                                      extended: TerminalPalette.generated(background: dark.bg, foreground: dark.fg, ansi: dark.ansi))),
            // As it sets a reply: its page, its ink, its links (blue 500,
            // 300), its code on black or white at 5%.
            page: Page(
                // A rendered page, read: as its code read.
                background: .hex(0xF7F7F7, 0x1F1F1F),
                text: .hex(0x0B0B0B, 0xEFEFEF),
                strong: .hex(0x000000, 0xFFFFFF),
                link: .hex(0x256ABF, 0x6DA7EC),
                code: .hex(0xF2F2F2, 0x242424),
                codeText: .hex(0x14181F, 0xEAECF0),
                copy: .hex(0xFFFFFF, 0x303030),
                copyEdge: .hex(0xE6E6E6, 0x3A3A3A),
                copyText: .hex(0x666666, 0x9C9C9C),
                copyHoverEdge: .hex(0xCCCCCC, 0x4A4A4A),
                copyHoverText: .hex(0x0B0B0B, 0xEFEFEF),
                copyDone: done,
                quote: .hex(0x666666, 0x9C9C9C),
                quoteRule: .hex(0xE0E0E0, 0x303030),
                rule: .hex(0xE6E6E6, 0x2A2A2A),
                tableHead: .hex(0xF9F9F9, 0x1F1F1F),
                tableStripe: .hex(0xFCFCFC, 0x1C1C1C),
                struck: .hex(0x878787, 0x878787),
                missing: failed,
                diagramError: failed,
                selection: selection,
                failed: failed,
                // Running, as its spinner: clay.
                running: .hex(0xD97757, 0xD97757),
                attention: attention),
            // Under its grey pages, Claude's illustrations' colours: sky
            // into lavender into clay into peach; by night ink-blue into
            // plum into a clay ember. Clay's pool of light in it.
            // (Brightness as the calibrated space has it.)
            backdrop: Backdrop(
                light: .init(stops: [(0.58, 0.22, 0.97), (0.74, 0.18, 0.97), (0.035, 0.30, 0.99), (0.09, 0.22, 1.0)],
                             pool: (0.2, 1), tintPool: (0.38, 1)),
                dark: .init(stops: [(0.61, 0.42, 0.2), (0.77, 0.34, 0.18), (0.03, 0.48, 0.2), (0.07, 0.3, 0.11)],
                            pool: (0.45, 0.3), tintPool: (0.6, 0.34))))
    }()
}

// MARK: Claude Warm

extension Palette {
    /// Claude as claude.ai has long set it — the token set Claude.app ships
    /// for its own small windows, "taken from claude.ai" (2025-10-17): its
    /// ivory (#faf9f5) on #f5f4ed, white cards; by night #262624 on
    /// #1f1e1d, cards #30302e; its warm inks (#141413, #3d3d3a, #73726c;
    /// #faf9f5, #c2c0b6, #9c9a92) and borders (#1f1e1d and #dedcd1, faint);
    /// clay for the accent, its blue (#1b67b2, #74abe2) for links and its
    /// pale blue (#d3e5f8, #1c3f62) for what's selected; its success and
    /// danger, and their pale grounds for diffs. The terminal is Claude
    /// Code's sixteen with their greys made the ink's warm ones, on the
    /// ivory. By night the danger is its lighter one (#fe8181), #dd5353
    /// reading at 3.9:1.
    static let claudeWarm: Palette = {
        let light = (bg: "#faf9f5", fg: "#141413", ansi: [
            "#141413", "#ff3a30", "#1e9e3c", "#98801f", "#0073e6", "#cd2054", "#8e6bd9", "#9c9a92",
            "#73726c", "#ff5047", "#1e9e3c", "#98801f", "#0078f0", "#cd2054", "#8e6bd9", "#dedcd1"])
        let dark = (bg: "#262624", fg: "#faf9f5", ansi: [
            "#141413", "#ff3a30", "#32d74b", "#ffd014", "#0099ff", "#ff2c56", "#b796ff", "#c2c0b6",
            "#73726c", "#ff5047", "#32d74b", "#ffd014", "#0087ee", "#ff2c56", "#b796ff", "#faf9f5"])
        let clay = Shade.hex(0xC6613F, 0xD97757)
        let blue = Shade.hex(0x2C84DB, 0x2C84DB), link = Shade.hex(0x1B67B2, 0x74ABE2)
        let selection = Shade.hex(0xD3E5F8, 0x1C3F62)
        let done = Shade.hex(0x2F7613, 0x65BB30), attention = Shade.hex(0x945D00, 0xDB9300), failed = Shade.hex(0xB53333, 0xFE8181)
        let added = Shade.hex(0x1E9E3C, 0x32D74B), modified = Shade.hex(0x98801F, 0xFFD014), removed = Shade.hex(0xCD2054, 0xFF2C56)
        let violet = Shade.hex(0x8E6BD9, 0xB796FF), aqua = Shade.hex(0x0F7E5C, 0x3BBD8C)
        // Its borders' ink (#1f1e1d, #dedcd1) at an alpha: a warm wash.
        func wash(_ light: CGFloat, _ dark: CGFloat) -> Shade {
            Shade(Theme.hex(0x1F1E1D).withAlphaComponent(light), Theme.hex(0xDEDCD1).withAlphaComponent(dark))
        }
        func alpha(_ hex: Int, _ light: CGFloat, _ darkHex: Int, _ dark: CGFloat) -> Shade {
            Shade(Theme.hex(hex).withAlphaComponent(light), Theme.hex(darkHex).withAlphaComponent(dark))
        }
        return Palette(
            id: "claude-warm",
            title: "Claude Warm",
            chrome: Chrome(
                hover: wash(0.05, 0.07),
                selected: Shade(.white, Theme.hex(0x30302E)),
                pressed: wash(0.1, 0.14),
                divider: wash(0.12, 0.12),
                panel: .hex(0xFFFFFF, 0x30302E),
                panelBorder: wash(0.15, 0.15),
                scrim: Shade(Theme.hex(0xF0EEE6).withAlphaComponent(0.4), NSColor(white: 0, alpha: 0.4)),
                cardBorder: wash(0.1, 0.12),
                handle: wash(0.22, 0.25),
                scrubberKnob: wash(0.14, 0.18),
                sheetEdge: wash(0.2, 0.16),
                sheetEdgeHovered: wash(0.34, 0.34),
                // Its bg-200 and on, deeper further down; by night its
                // card, lighter nearer the top.
                sheet: { level in Shade(NSColor(srgbRed: 0.96 - CGFloat(level) * 0.045, green: 0.955 - CGFloat(level) * 0.045, blue: 0.93 - CGFloat(level) * 0.045, alpha: 1),
                                        NSColor(srgbRed: 0.24 - CGFloat(level) * 0.04, green: 0.24 - CGFloat(level) * 0.04, blue: 0.23 - CGFloat(level) * 0.04, alpha: 1)) },
                stack: .hex(0xFFFFFF, 0x30302E),
                dragPill: .hex(0xFFFFFF, 0x3A3A37),
                linkBehind: { depth in Shade(NSColor(srgbRed: 0.95 - CGFloat(depth) * 0.03, green: 0.945 - CGFloat(depth) * 0.03, blue: 0.92 - CGFloat(depth) * 0.03, alpha: 1),
                                            NSColor(srgbRed: 0.17 - CGFloat(depth) * 0.015, green: 0.17 - CGFloat(depth) * 0.015, blue: 0.16 - CGFloat(depth) * 0.015, alpha: 1)) },
                well: wash(0.05, 0.07),
                pill: wash(0.07, 0.1),
                // Its pale blue into clay's.
                historyWash: (from: .hex(0xE6EEF5, 0x1C2B3A), to: .hex(0xF7E6DD, 0x3F2C25)),
                // A tile's bar a step off its pages, as claude.ai's sidebar
                // is (bg-200): #f5f4ed on #faf9f5, #1f1e1d on #262624 — not
                // its cards' white over the ivory.
                bar: .hex(0xF5F4ED, 0x1F1E1D)),
            text: Text(
                primary: .hex(0x141413, 0xFAF9F5),
                body: .hex(0x141413, 0xFAF9F5),
                strong: .hex(0x000000, 0xFFFFFF),
                secondary: .hex(0x3D3D3A, 0xC2C0B6),
                tertiary: .hex(0x73726C, 0x9C9A92),
                readingBody: .hex(0x141413, 0xFAF9F5),
                readingStrong: .hex(0x000000, 0xFFFFFF)),
            status: StatusColors(done: done, attention: attention, failed: failed),
            accent: TintColors(accent: clay, caret: blue, textSelection: selection),
            tints: Palette.paper.tints,
            code: Code(
                // Read, not edited: as claude.ai sets code, a step deeper
                // than its page — its oat (bg-300, #f0eee6) under the
                // ivory; by night its cards' #30302e over #262624.
                page: .hex(0xF0EEE6, 0x30302E),
                text: .hex(0x141413, 0xFAF9F5),
                lineNumber: .hex(0x9C9A92, 0x73726C),
                // The caret's line, seen on the ivory and the oat both.
                lineHighlight: .hex(0xEBE9E1, 0x363634),
                gutterText: .hex(0x9C9A92, 0x73726C),
                use: alpha(0x2C84DB, 0.1, 0x2C84DB, 0.18),
                match: alpha(0xFFD500, 0.25, 0xFFD500, 0.18),
                link: link,
                linkHover: wash(0.08, 0.13),
                added: added,
                modified: modified,
                deleted: removed,
                pins: [
                    alpha(0x945D00, 0.24, 0xFFD014, 0.3),
                    alpha(0xAD3D66, 0.22, 0xF3C0D3, 0.3),
                    alpha(0x256ABF, 0.22, 0x3BBD8C, 0.3),
                    alpha(0x8E6BD9, 0.22, 0xB796FF, 0.3),
                ],
                error: .hex(0xB53333, 0xDD5353),
                warning: .hex(0xB77700, 0xFFD014),
                hint: alpha(0x2C84DB, 0.6, 0x74ABE2, 0.6),
                changedOnDisk: .hex(0xFBF2CC, 0x403A22),
                highlighter: alpha(0xFFD014, 0.4, 0xFFD014, 0.3)),
            diff: Diff(
                // Its success and danger, faint on the ivory; its pale blue.
                added: .hex(0xE2E9DA, 0x303E26),
                removed: .hex(0xF3E5E2, 0x472E2C),
                hunk: .hex(0xEAF0F3, 0x27333E),
                found: .hex(0xFBF0B8, 0x4D461E),
                current: .hex(0xFDE56E, 0x7D6C16)),
            found: Found(
                current: alpha(0xFFD500, 0.55, 0xFFD500, 0.55),
                currentRing: .hex(0xB77700, 0xFFD014),
                pdf: Shade(NSColor(srgbRed: 1, green: 0.84, blue: 0, alpha: 0.8)),
                pdfCurrent: Shade(NSColor(srgbRed: 0.2, green: 0.56, blue: 1, alpha: 0.7))),
            chart: Chart(
                one: blue,
                two: .hex(0xD97757, 0xD97757),
                three: done,
                track: wash(0.07, 0.09),
                surface: wash(0.025, 0.035),
                grid: wash(0.07, 0.08)),
            kinds: Kinds(
                git: .hex(0xC5621B, 0xFA832E), swift: .hex(0xD95926, 0xEC835A), shell: added, pdf: failed,
                image: violet, data: modified, patch: added, archive: .hex(0x73726C, 0x9C9A92), media: removed, code: link,
                linked: violet, embeds: aqua),
            terminal: (
                light: TerminalPalette(background: light.bg, foreground: light.fg, cursor: "#2c84db", cursorText: light.bg,
                                       selectionBackground: "#d3e5f8", selectionForeground: light.fg, ansi: light.ansi,
                                       extended: TerminalPalette.generated(background: light.bg, foreground: light.fg, ansi: light.ansi)),
                dark: TerminalPalette(background: dark.bg, foreground: dark.fg, cursor: "#2c84db", cursorText: dark.bg,
                                      selectionBackground: "#1c3f62", selectionForeground: dark.fg, ansi: dark.ansi,
                                      extended: TerminalPalette.generated(background: dark.bg, foreground: dark.fg, ansi: dark.ansi))),
            // As claude.ai sets a reply: on its ivory, its inks, its links.
            page: Page(
                // A rendered page, read: as its code read.
                background: .hex(0xF0EEE6, 0x30302E),
                text: .hex(0x141413, 0xFAF9F5),
                strong: .hex(0x000000, 0xFFFFFF),
                link: link,
                // Inline code a step deeper again (bg-400).
                code: .hex(0xE8E6DC, 0x1F1E1D),
                codeText: .hex(0x141413, 0xFAF9F5),
                copy: .hex(0xFFFFFF, 0x30302E),
                copyEdge: .hex(0xE4E3DF, 0x42413E),
                copyText: .hex(0x73726C, 0x9C9A92),
                copyHoverEdge: .hex(0xD9D8D5, 0x52514D),
                copyHoverText: .hex(0x141413, 0xFAF9F5),
                copyDone: done,
                quote: .hex(0x3D3D3A, 0xC2C0B6),
                quoteRule: .hex(0xD9D8D5, 0x42413E),
                rule: .hex(0xE4E3DF, 0x383835),
                tableHead: .hex(0xE8E6DC, 0x3A3A37),
                tableStripe: .hex(0xF5F4ED, 0x2B2B29),
                struck: .hex(0x73726C, 0x9C9A92),
                missing: failed,
                diagramError: failed,
                selection: selection,
                failed: failed,
                running: .hex(0xD97757, 0xD97757),
                attention: attention),
            // Under its ivory, Claude's warm illustration colours: clay
            // into kraft into manilla into oat; by night embers of the
            // same. Clay's pool of light in it. (Brightness as the
            // calibrated space has it.)
            backdrop: Backdrop(
                light: .init(stops: [(0.035, 0.34, 0.97), (0.075, 0.30, 0.97), (0.12, 0.28, 0.98), (0.14, 0.16, 0.97)],
                             pool: (0.24, 1), tintPool: (0.42, 1)),
                dark: .init(stops: [(0.03, 0.5, 0.2), (0.065, 0.45, 0.18), (0.11, 0.38, 0.16), (0.08, 0.25, 0.1)],
                            pool: (0.5, 0.28), tintPool: (0.6, 0.32)),
                tileShadow: (Theme.hex(0x3D3D3A), 0.1)))
    }()
}

// MARK: Claude Classic

extension Palette {
    /// Claude's desktop app before its neutral greys (its stylesheet of
    /// 2026-10-14, the last before them, as this Mac's cache kept it): the
    /// Code tab's warm greys — by day white cards and terminal on the
    /// sidebar's #f3f3f0, its chat on #f9f9f7; by night #1a1a19 on #111111,
    /// its chat on #151515, cards #20201f — its warm inks (#131313,
    /// #383835; #f9f9f7, #c3c2b7, #97958d), its text roles (blue 600 and
    /// 300, green 600 and 400, yellow 600 and 300, red 600 and 300), clay,
    /// and Claude Code's terminal as it was then (the same sixteen, on
    /// white and on #1a1a19). One departure: its muted grey by day (#7b7974,
    /// 4.35:1 on white) is the next on its scale, #6d6b67.
    static let claudeClassic: Palette = {
        let light = (bg: "#ffffff", fg: "#14181f", ansi: [
            "#1a1a1a", "#ff3a30", "#1e9e3c", "#98801f", "#0073e6", "#cd2054", "#8e6bd9", "#999999",
            "#666666", "#ff5047", "#1e9e3c", "#98801f", "#0078f0", "#cd2054", "#8e6bd9", "#d6d6d6"])
        let dark = (bg: "#1a1a19", fg: "#eaecf0", ansi: [
            "#262626", "#ff3a30", "#32d74b", "#ffd014", "#0099ff", "#ff2c56", "#b796ff", "#a6a6a6",
            "#525252", "#ff5047", "#32d74b", "#ffd014", "#0087ee", "#ff2c56", "#b796ff", "#ededed"])
        let clay = Shade.hex(0xC6613F, 0xD97757)
        let blue = Shade.hex(0x0073E6, 0x0099FF), link = Shade.hex(0x184F95, 0x6DA7EC)
        let selection = Shade.hex(0xBFDCF9, 0x12405E)
        let done = Shade.hex(0x006300, 0x0CA30C), attention = Shade.hex(0x734500, 0xDB9300), failed = Shade.hex(0x8E2626, 0xEC7E7E)
        let added = Shade.hex(0x1E9E3C, 0x32D74B), modified = Shade.hex(0x98801F, 0xFFD014), removed = Shade.hex(0xCD2054, 0xFF2C56)
        let violet = Shade.hex(0x8E6BD9, 0xB796FF), aqua = Shade.hex(0x0F7E5C, 0x3BBD8C)
        // Its neutral-900 and gray-50 at an alpha (its alpha scale): a warm wash.
        func wash(_ light: CGFloat, _ dark: CGFloat) -> Shade {
            Shade(Theme.hex(0x0B0B0B).withAlphaComponent(light), Theme.hex(0xF0EFEC).withAlphaComponent(dark))
        }
        func alpha(_ hex: Int, _ light: CGFloat, _ darkHex: Int, _ dark: CGFloat) -> Shade {
            Shade(Theme.hex(hex).withAlphaComponent(light), Theme.hex(darkHex).withAlphaComponent(dark))
        }
        return Palette(
            id: "claude-classic",
            title: "Claude Classic",
            chrome: Chrome(
                // Its ghost hover and selected: 5% and 10%; 7.5% and 15%.
                hover: wash(0.05, 0.075),
                selected: Shade(.white, Theme.hex(0x20201F)),
                pressed: wash(0.1, 0.15),
                divider: wash(0.1, 0.1),
                panel: .hex(0xFFFFFF, 0x20201F),
                panelBorder: wash(0.12, 0.14),
                scrim: Shade(Theme.hex(0xF0EFEC).withAlphaComponent(0.4), NSColor(white: 0, alpha: 0.45)),
                cardBorder: wash(0.08, 0.1),
                handle: wash(0.22, 0.25),
                scrubberKnob: wash(0.14, 0.18),
                sheetEdge: wash(0.2, 0.16),
                sheetEdgeHovered: wash(0.34, 0.34),
                // Its greys from gray-40 down by day; by night from gray-800 up.
                sheet: { level in Shade(NSColor(srgbRed: 0.953 - CGFloat(level) * 0.045, green: 0.953 - CGFloat(level) * 0.045, blue: 0.94 - CGFloat(level) * 0.045, alpha: 1),
                                        NSColor(srgbRed: 0.2 - CGFloat(level) * 0.035, green: 0.2 - CGFloat(level) * 0.035, blue: 0.195 - CGFloat(level) * 0.035, alpha: 1)) },
                stack: .hex(0xFFFFFF, 0x20201F),
                dragPill: .hex(0xFFFFFF, 0x2C2C2A),
                linkBehind: { depth in Shade(NSColor(srgbRed: 0.95 - CGFloat(depth) * 0.03, green: 0.95 - CGFloat(depth) * 0.03, blue: 0.94 - CGFloat(depth) * 0.03, alpha: 1),
                                            NSColor(srgbRed: 0.13 - CGFloat(depth) * 0.015, green: 0.13 - CGFloat(depth) * 0.015, blue: 0.125 - CGFloat(depth) * 0.015, alpha: 1)) },
                well: wash(0.05, 0.075),
                pill: wash(0.07, 0.1),
                historyWash: (from: .hex(0xEBF4FD, 0x162B39), to: .hex(0xFAEBE6, 0x3F2C25))),
            text: Text(
                primary: .hex(0x131313, 0xF9F9F7),
                body: .hex(0x131313, 0xF9F9F7),
                strong: .hex(0x0B0B0B, 0xFFFFFF),
                secondary: .hex(0x383835, 0xC3C2B7),
                tertiary: .hex(0x6D6B67, 0x97958D),
                readingBody: .hex(0x131313, 0xF9F9F7),
                readingStrong: .hex(0x0B0B0B, 0xFFFFFF)),
            status: StatusColors(done: done, attention: attention, failed: failed),
            accent: TintColors(accent: clay, caret: blue, textSelection: selection),
            tints: Palette.paper.tints,
            code: Code(
                // Read, not edited: its gray-30 (#f6f6f4) off its white;
                // by night its chat's ground (#151515).
                page: .hex(0xF6F6F4, 0x151515),
                text: .hex(0x14181F, 0xEAECF0),
                lineNumber: .hex(0x97958D, 0x7B7974),
                lineHighlight: .hex(0xF6F6F6, 0x252524),
                gutterText: .hex(0x97958D, 0x6D6B67),
                use: alpha(0x0073E6, 0.1, 0x0099FF, 0.14),
                match: alpha(0xFFD500, 0.25, 0xFFD500, 0.18),
                link: link,
                linkHover: wash(0.08, 0.13),
                added: added,
                modified: modified,
                deleted: removed,
                pins: [
                    alpha(0x945D00, 0.24, 0xFFD014, 0.3),
                    alpha(0xAD3D66, 0.22, 0xF3C0D3, 0.3),
                    alpha(0x256ABF, 0.22, 0x3BBD8C, 0.3),
                    alpha(0x8E6BD9, 0.22, 0xB796FF, 0.3),
                ],
                error: .hex(0xE34948, 0xFF5047),
                warning: .hex(0xB77700, 0xFFD014),
                hint: alpha(0x0073E6, 0.6, 0x0099FF, 0.6),
                changedOnDisk: .hex(0xFFF7D5, 0x353018),
                // Its highlight: the warning's fill a third through.
                highlighter: alpha(0xFFD014, 0.4, 0xDB9300, 0.35)),
            diff: Diff(
                // Its git colours at a fifth, as its diffs' grounds were.
                added: .hex(0xD2ECD8, 0x1F4023),
                removed: .hex(0xF5D2DD, 0x481E25),
                hunk: .hex(0xCDE2FB, 0x032042),
                found: .hex(0xFFF4BF, 0x433C14),
                current: .hex(0xFFE873, 0x76650F)),
            found: Found(
                current: alpha(0xFFD500, 0.55, 0xFFD500, 0.55),
                currentRing: .hex(0xB77700, 0xFFD014),
                pdf: Shade(NSColor(srgbRed: 1, green: 0.84, blue: 0, alpha: 0.8)),
                pdfCurrent: Shade(NSColor(srgbRed: 0.2, green: 0.56, blue: 1, alpha: 0.7))),
            chart: Chart(
                one: .hex(0x2A78D6, 0x3987E5),
                two: .hex(0xD97757, 0xD97757),
                three: added,
                track: wash(0.07, 0.09),
                surface: wash(0.025, 0.035),
                grid: wash(0.07, 0.08)),
            kinds: Kinds(
                git: .hex(0xC5621B, 0xFA832E), swift: .hex(0xD95926, 0xEC835A), shell: added, pdf: .hex(0xE34948, 0xEC7E7E),
                image: violet, data: modified, patch: added, archive: .hex(0x6D6B67, 0xA5A49A), media: removed, code: blue,
                linked: violet, embeds: aqua),
            terminal: (
                light: TerminalPalette(background: light.bg, foreground: light.fg, cursor: "#0073e6", cursorText: light.bg,
                                       selectionBackground: "#bfdcf9", selectionForeground: light.fg, ansi: light.ansi,
                                       extended: TerminalPalette.generated(background: light.bg, foreground: light.fg, ansi: light.ansi)),
                dark: TerminalPalette(background: dark.bg, foreground: dark.fg, cursor: "#0099ff", cursorText: dark.bg,
                                      selectionBackground: "#12405e", selectionForeground: dark.fg, ansi: dark.ansi,
                                      extended: TerminalPalette.generated(background: dark.bg, foreground: dark.fg, ansi: dark.ansi))),
            // A rendered page, read: as its code read.
            page: Page(
                background: .hex(0xF6F6F4, 0x151515),
                text: .hex(0x131313, 0xF9F9F7),
                strong: .hex(0x0B0B0B, 0xFFFFFF),
                link: link,
                code: .hex(0xEDEDEB, 0x212121),
                codeText: .hex(0x14181F, 0xEAECF0),
                copy: .hex(0xFFFFFF, 0x20201F),
                copyEdge: .hex(0xE1E0D9, 0x383835),
                copyText: .hex(0x6D6B67, 0x97958D),
                copyHoverEdge: .hex(0xC3C2B7, 0x454442),
                copyHoverText: .hex(0x131313, 0xF9F9F7),
                copyDone: done,
                quote: .hex(0x383835, 0xC3C2B7),
                quoteRule: .hex(0xE1E0D9, 0x383835),
                rule: .hex(0xE1E1DF, 0x2C2C2C),
                tableHead: .hex(0xF0EFEC, 0x20201F),
                tableStripe: .hex(0xF3F3F0, 0x1A1A19),
                struck: .hex(0x6D6B67, 0x97958D),
                missing: failed,
                diagramError: failed,
                selection: selection,
                failed: failed,
                running: .hex(0xD97757, 0xD97757),
                attention: attention),
            // Under its white cards, Claude's quieter illustration colours:
            // sage into heather into clay into oat; by night deep teal into
            // aubergine into a clay ember. Clay's pool of light in it.
            // (Brightness as the calibrated space has it.)
            backdrop: Backdrop(
                light: .init(stops: [(0.42, 0.18, 0.93), (0.70, 0.16, 0.95), (0.035, 0.28, 0.98), (0.11, 0.20, 0.97)],
                             pool: (0.2, 0.99), tintPool: (0.36, 0.99)),
                dark: .init(stops: [(0.47, 0.45, 0.15), (0.76, 0.38, 0.14), (0.03, 0.5, 0.16), (0.09, 0.3, 0.08)],
                            pool: (0.45, 0.24), tintPool: (0.6, 0.28))))
    }()
}
