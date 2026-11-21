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
    /// The least chroma what tells a space or an agent apart keeps, of its
    /// own (`identityChroma`).
    var identityLeast: CGFloat = 0.6

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
        /// A tile's bar, where it isn't the panel's ground (Field's by day, a
        /// breath off its white pages).
        var bar: Shade? = nil
        /// A bar's details (the place after the name) and its buttons till
        /// the pointer's on it, where they aren't the secondary ink (Field's:
        /// muted, as Rex's).
        var barInk: Shade? = nil
        /// Popovers' and menus' ground, where it isn't the system's frosted
        /// grey (Field's: white, a step up by night).
        var menu: Shade? = nil
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
        /// A chosen row's band, where it isn't the tint thin over the row
        /// (a neutral step, the tint kept for what's acted on).
        var band: Shade?

        init(accent: Shade, caret: Shade? = nil, textSelection: Shade, band: Shade? = nil) {
            self.accent = accent
            self.caret = caret ?? accent
            self.textSelection = textSelection
            self.band = band
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
        /// A diff's ground, where it isn't the window's: read, not edited,
        /// as code in view mode is.
        var page: Shade? = nil
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
        /// The hairline round each tile, by day and night, where it isn't
        /// the cards' border (Field's, as Rex draws its panes): every theme
        /// draws one.
        var tileEdge: Shade? = nil
        /// A grain over it, by day and by night: how strong (0, none) — a
        /// material's, not a colour's (Terra's).
        var grain: (light: CGFloat, dark: CGFloat) = (0, 0)
        /// Whether it's taken by the day's light (warmer at dusk, cooler at
        /// noon), as the atmospheric themes' are; an instrument's isn't.
        var daylight = true

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
        /// Links underlined always, as anthropic.com sets them: else only
        /// under the pointer.
        var linksUnderlined = false

        /// Each as a CSS variable, `--page-<role>`, in the light, and again
        /// in the dark; and the links' underline, if it's always there.
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
            let underline = linksUnderlined
                ? "\na:not([href^=\"manifold:\"]) { text-decoration: underline; text-decoration-skip-ink: auto; text-underline-offset: .18em; }"
                : ""
            return ":root { \(vars(dark: false)) }\n@media (prefers-color-scheme: dark) { :root { \(vars(dark: true)) } }" + underline
        }
    }
}

extension Palette {
    /// The page's colours as CSS (`Page.css`), and a chart's series —
    /// `--page-series-1`…8 — from the theme's terminal colours: red,
    /// yellow, green, cyan, blue, magenta, then the bright red and yellow.
    var pageCSS: String {
        func series(_ t: TerminalPalette) -> String {
            [1, 3, 2, 6, 4, 5, 9, 11].enumerated().compactMap { i, c in
                t.colorsHex.indices.contains(c) ? "--page-series-\(i + 1): \(t.colorsHex[c]);" : nil
            }.joined(separator: " ")
        }
        return page.css + "\n:root { \(series(terminal.light)) }\n@media (prefers-color-scheme: dark) { :root { \(series(terminal.dark)) } }"
    }

    /// The theme in use (made firmer where contrast is to be increased).
    private(set) static var current: Palette = .field
    /// The theme set, as it's defined, and whether it was made firmer.
    private static var applied: (id: String, contrast: Bool)?
    private static var chosen: Palette = .field

    /// Every theme there is.
    static let all: [Palette] = [.field, .folio, .terra, .spectrum, .graphite, .signal]

    /// Whether contrast is increased: as the system's accessibility setting
    /// has it (Increase Contrast), unless a debug command says otherwise.
    static var increasedContrast: Bool { forcedContrast ?? NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast }
    static var forcedContrast: Bool? = nil

    /// Themes there were, and the names they had, by what took their
    /// place: Merino is Field, Classic Terra, Financial Times Folio, Claude
    /// Spectrum; Paper's is Field; Claude Classic's and Claude Warm's,
    /// Spectrum; Newsprint's (ink on
    /// paper), Terra; the quiet ones — Stone's (a warm paper), Folio;
    /// Slate's (grey-blue), Graphite; Sage's (grey-green), Terra; Dusk's, Field.
    static let replaced = ["merino": "field", "classic": "terra", "financial-times": "folio", "claude": "spectrum",
                           "paper": "field", "claude-classic": "spectrum", "claude-warm": "spectrum", "newsprint": "terra",
                           "stone": "folio", "slate": "graphite", "sage": "terra", "dusk": "field"]

    /// The theme by its id (or by the one that replaced it); Field for one there isn't.
    static func named(_ id: String) -> Palette {
        let id = replaced[id] ?? id
        return all.first { $0.id == id } ?? .field
    }

    /// A theme set: every colour redrawn, what's held in layers by the
    /// hooks that set them, the terminals reconfigured.
    static func apply(_ palette: Palette) {
        let contrast = increasedContrast
        guard applied?.id != palette.id || applied?.contrast != contrast else { return }
        applied = (palette.id, contrast)
        chosen = palette
        current = contrast ? palette.firmer() : palette
        NotificationCenter.default.post(name: .manifoldPaletteChanged, object: nil)
        NotificationCenter.default.post(name: .manifoldAppearanceChanged, object: nil)
        for window in NSApp.windows { window.contentView.map(redraw) }
        GhosttyRuntime.shared.reapply()
    }

    /// The theme set again, as the contrast asked of it now has it (the
    /// system's setting changed).
    static func reapply() { apply(chosen) }

    private static func redraw(_ view: NSView) {
        view.needsDisplay = true
        view.subviews.forEach(redraw)
    }
}

extension Palette {
    /// How saturated its inks are: its terminal's six (red to cyan), their
    /// mean chroma in Oklab, against Field's (GitHub's) — at most 1, at
    /// least 0.6. What tells a space or an agent apart is eased to it, so a
    /// muted theme's (Terra's, Folio's) isn't loud in it.
    func identityChroma(dark: Bool) -> CGFloat {
        func chroma(_ p: Palette) -> CGFloat {
            let t = dark ? p.terminal.dark : p.terminal.light
            let six = t.colors[1...6].map { ColorVision.oklab(ColorVision.typical.seen($0)) }
            return six.map { sqrt($0.a * $0.a + $0.b * $0.b) }.reduce(0, +) / 6
        }
        return min(1, max(identityLeast, chroma(self) / chroma(.field)))
    }
}

extension NSColor {
    /// A colour that tells a thing apart (a space's, an agent's) as the
    /// theme in use has it: its hue and lightness, its chroma eased to the
    /// theme's (`Palette.identityChroma`).
    static func identity(_ base: NSColor) -> NSColor {
        NSColor(name: nil) { appearance in
            var resolved = base
            appearance.performAsCurrentDrawingAppearance { resolved = base.usingColorSpace(.sRGB) ?? base }
            let k = Palette.current.identityChroma(dark: appearance.isDark)
            guard k < 1 else { return resolved }
            let c = ColorVision.oklab(ColorVision.typical.seen(resolved))
            return ColorVision.srgb(fromOklab: (c.l, c.a * k, c.b * k)).withAlphaComponent(resolved.alphaComponent)
        }
    }

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

// MARK: What themes share

extension Palette {
    /// Each tint's colours, for a theme that doesn't give its own:
    /// Manifold's, from before there were themes.
    static let standardTints: [Tint: TintColors] = [
        .blue: TintColors(accent: Shade(Theme.hex(0x3373F2)), caret: .hex(0x007AFF, 0x0A84FF), textSelection: .hex(0xCFE2FB, 0x264F78)),
        // Overcast's orange (#FC7E0F) in the dark; deeper in the light.
        .orange: TintColors(accent: .hex(0xE36A00, 0xFC7E0F), caret: .hex(0xEB7300, 0xFF8A26), textSelection: .hex(0xFDE1C4, 0x6E3D12)),
        .purple: TintColors(accent: .hex(0x9550D6, 0xBF7AF0), textSelection: .hex(0xEADCF8, 0x4B2F68)),
        .pink: TintColors(accent: .hex(0xDC3F78, 0xFF6B9C), textSelection: .hex(0xFADAE6, 0x6B2B43)),
        .green: TintColors(accent: .hex(0x2A9A4A, 0x3FCB68), textSelection: .hex(0xD5EFDC, 0x25512F)),
        .graphite: TintColors(accent: .hex(0x6E6E73, 0x98989D), caret: .hex(0x48484D, 0xC7C7CC), textSelection: .hex(0xE1E1E4, 0x4A4A4E)),
    ]

    /// A colour with its chroma (in Oklab) eased by `k`: its hue and
    /// lightness kept.
    static func eased(_ c: NSColor, chroma k: CGFloat) -> NSColor {
        let o = ColorVision.oklab(ColorVision.typical.seen(c))
        let alpha = (c.usingColorSpace(.sRGB) ?? c).alphaComponent
        return ColorVision.srgb(fromOklab: (o.l, o.a * k, o.b * k)).withAlphaComponent(alpha)
    }

    static func eased(_ v: Int, chroma k: CGFloat) -> Int {
        let c = eased(Theme.hex(v), chroma: k).usingColorSpace(.sRGB)!
        func byte(_ x: CGFloat) -> Int { Int((min(max(x, 0), 1) * 255).rounded()) }
        return (byte(c.redComponent) << 16) | (byte(c.greenComponent) << 8) | byte(c.blueComponent)
    }

    /// Each tint as a theme has it: the standard tint's hue, its chroma
    /// eased to the theme's (`k`, by day and by night: a quiet theme's
    /// green isn't the system's), its lightness made to stand at 3.5:1 on
    /// the theme's panels (a ring round a tile, a line), the caret it;
    /// what's selected, a wash of it on the window.
    static func calibratedTints(chroma k: (light: CGFloat, dark: CGFloat), panel: Shade, window: Shade) -> [Tint: TintColors] {
        var out: [Tint: TintColors] = [:]
        for (tint, base) in standardTints {
            func make(_ dark: Bool) -> (accent: NSColor, selection: NSColor) {
                let muted = eased(base.accent.color(dark: dark), chroma: tint == .graphite ? 1 : (dark ? k.dark : k.light))
                let ground = panel.color(dark: dark).usingColorSpace(.sRGB) ?? .gray
                let accent = Tints.reaching(3.5, from: muted.usingColorSpace(.sRGB) ?? muted, on: ground, toward: dark ? .white : .black)
                let w = window.color(dark: dark).usingColorSpace(.sRGB) ?? .gray
                return (accent, w.blended(withFraction: dark ? 0.32 : 0.2, of: accent) ?? w)
            }
            let l = make(false), d = make(true)
            out[tint] = TintColors(accent: Shade(l.accent, d.accent), textSelection: Shade(l.selection, d.selection))
        }
        return out
    }

    /// Its secondary and tertiary inks made to read — 4.5:1 — wherever
    /// they're set: on its panels, and on its backdrop, where the sidebar's
    /// words are (its wash and its pools, as drawn); lifted by night and
    /// deepened by day only as far as they must be, so they stay below
    /// the primary ink.
    func legible(_ least: CGFloat = 4.6) -> Palette {
        var p = self
        func grounds(_ dark: Bool) -> [NSColor] {
            let wash = backdrop.wash(dark: dark)
            let pools = wash.stops.map { NSColor(calibratedHue: $0.0, saturation: wash.pool.saturation, brightness: wash.pool.brightness, alpha: 1) }
            return (BackdropView.colors(of: wash) + pools + [chrome.panel.color(dark: dark)]).compactMap { $0.usingColorSpace(.sRGB) }
        }
        func fixed(_ shade: Shade) -> Shade {
            func one(_ dark: Bool) -> NSColor {
                var c = shade.color(dark: dark).usingColorSpace(.sRGB) ?? shade.color(dark: dark)
                for g in grounds(dark) { c = Tints.reaching(least, from: c, on: g, toward: dark ? .white : .black) }
                return c
            }
            return Shade(one(false), one(true))
        }
        p.text.secondary = fixed(text.secondary)
        p.text.tertiary = fixed(text.tertiary)
        return p
    }

    /// The theme with its contrast increased (DESIGN.md §11), its character
    /// kept: its secondary and tertiary inks at 7:1 wherever they're set,
    /// its primary at 12:1; its rules, borders and the hairline round each
    /// tile firmer; its accent and tints — a focus ring, a chosen row — at
    /// 4.5:1 on its panels; a bar's details in its secondary ink. Its
    /// backdrop by night a third darker, so its faint inks needn't climb to
    /// its primary to read on it.
    func firmer() -> Palette {
        var dimmed = self
        dimmed.backdrop.dark.stops = backdrop.dark.stops.map { ($0.0, $0.1, $0.2 * 0.67) }
        dimmed.backdrop.dark.pool.brightness *= 0.67
        dimmed.backdrop.dark.tintPool.brightness *= 0.67
        var p = dimmed.legible(7)
        func each(_ s: Shade, _ f: (NSColor, Bool) -> NSColor) -> Shade {
            Shade(f(s.light.usingColorSpace(.sRGB) ?? s.light, false), f(s.dark.usingColorSpace(.sRGB) ?? s.dark, true))
        }
        let ink = text.primary
        // A rule: twice as strong where it's a wash, a third of the way to
        // the ink where it's opaque.
        func firm(_ s: Shade) -> Shade {
            each(s) { c, dark in
                c.alphaComponent < 1 ? c.withAlphaComponent(min(1, c.alphaComponent * 2))
                    : (c.blended(withFraction: 0.33, of: ink.color(dark: dark).usingColorSpace(.sRGB)!) ?? c)
            }
        }
        func reads(_ s: Shade, _ least: CGFloat) -> Shade {
            each(s) { c, dark in
                let ground = chrome.panel.color(dark: dark).usingColorSpace(.sRGB) ?? .gray
                return Tints.reaching(least, from: c, on: ground, toward: dark ? .white : .black)
            }
        }
        p.text.primary = reads(text.primary, 12)
        p.text.body = reads(text.body, 12)
        p.chrome.divider = firm(chrome.divider)
        p.chrome.panelBorder = firm(chrome.panelBorder)
        p.chrome.cardBorder = firm(chrome.cardBorder)
        p.chrome.sheetEdge = firm(chrome.sheetEdge)
        p.chrome.barInk = p.text.secondary
        p.backdrop.tileEdge = firm(backdrop.tileEdge ?? chrome.cardBorder)
        p.accent.accent = reads(accent.accent, 4.5)
        p.tints = tints.mapValues { var t = $0; t.accent = reads(t.accent, 4.5); return t }
        return p
    }

    /// The theme with what tells a space or an agent apart kept at least
    /// `least` of its chroma (Terra's, whose pigments would mute them to
    /// pastels on its stone).
    func identities(least: CGFloat) -> Palette {
        var p = self
        p.identityLeast = least
        return p
    }

    /// Highlight Uses' colours, in turn, for a theme without its own.
    static let standardPins: [Shade] = [
        Shade(NSColor(srgbRed: 0.2, green: 0.7, blue: 0.7, alpha: 0.28), NSColor(srgbRed: 0.25, green: 0.75, blue: 0.75, alpha: 0.35)),
        Shade(NSColor(srgbRed: 0.95, green: 0.7, blue: 0.2, alpha: 0.32), NSColor(srgbRed: 0.95, green: 0.72, blue: 0.25, alpha: 0.35)),
        Shade(NSColor(srgbRed: 0.6, green: 0.45, blue: 0.95, alpha: 0.28), NSColor(srgbRed: 0.65, green: 0.5, blue: 1, alpha: 0.35)),
        Shade(NSColor(srgbRed: 0.95, green: 0.4, blue: 0.55, alpha: 0.26), NSColor(srgbRed: 1, green: 0.45, blue: 0.6, alpha: 0.33)),
    ]

    /// The colours that tell kinds apart, for a theme without its own: the system's.
    static let standardKinds = Kinds(git: Shade(.systemOrange), swift: Shade(.systemOrange), shell: Shade(.systemGreen), pdf: Shade(.systemRed),
        image: Shade(.systemPurple), data: Shade(.systemYellow), patch: Shade(.systemGreen), archive: Shade(.systemBrown),
        media: Shade(.systemPink), code: Shade(.systemBlue), linked: Shade(.systemPurple), embeds: Shade(.systemTeal))
}

// MARK: Terra

extension Palette {
    /// Terra: earthy, grounded, of natural materials — linen and oat
    /// paper on a stone table, walnut ink, a sage accent, and pigments for
    /// what says something: indigo, burnt sienna, rose madder, ochre. By
    /// night the one warm theme: warm charcoal on dark stone and smoked
    /// oak, bone-coloured ink. Its faint inks at 5.5:1, not 4.5, so they're
    /// dusty, not dim; what tells a space or an agent apart less muted than
    /// its terminal's chroma alone would have it.
    /// Its ground has a grain, as paper and stone do, and its shadows are
    /// soft. Grown from apex's Classic (~/src/apex,
    /// crates/apex-client/src/theme.rs): acme's paper, panels and yellow
    /// selection, go.dev's ink and blue, each turned to its material — and,
    /// as apex has it for a colour-blind reader, blue for what's added or
    /// passed and orange for what's taken away, here indigo and sienna
    /// (the terminal's green a blue-green verdigris moss, apart from its
    /// rust).
    static let terra: Palette = {
        let light = (bg: "#faf7f0", fg: "#2a2520", ansi: [
            "#2a2520", "#a8431e", "#2c6a5c", "#86621a", "#3b5b7a", "#7d3f6e", "#2a6f80", "#6b625a",
            "#5a524a", "#c0582c", "#3b8571", "#9a7016", "#5876a0", "#97568a", "#2f7f8f", "#8a8075"])
        let dark = (bg: "#221e1b", fg: "#ebe4da", ansi: [
            "#4a423a", "#e0805a", "#6fafb4", "#d9b25a", "#8fa8cc", "#c993b8", "#9fcfc8", "#b5aca1",
            "#877d72", "#f09b74", "#8dc4cb", "#e8c679", "#a8bfe0", "#dbabcc", "#bfe2da", "#f2ece3"])
        // Indigo: links, the caret, what's added and done.
        let indigo = Shade.hex(0x3B5B7A, 0x8FAACB), done = Shade.hex(0x35557F, 0x87A4D2)
        // Burnt sienna for what's taken away and warnings; rose madder
        // (a crimson lake, bluer and deeper than the sienna) for what failed.
        let sienna = Shade.hex(0xA4501F, 0xE08A55), madder = Shade.hex(0x9B2C4A, 0xEE8EA2)
        // Ochre for what's stale and wants attention.
        let ochre = Shade.hex(0x86621A, 0xD9B25A)
        // Straw, for what's selected; stone, a step off the paper.
        let straw = Shade.hex(0xEFE3B8, 0x4A4128), stone = Shade.hex(0xEFEAE0, 0x37322D)
        let paper = Shade.hex(0xFAF7F0, 0x221E1B), panel = Shade.hex(0xFDFBF6, 0x2D2924)
        // What's read (code in view mode, a page): the paper by day, by
        // night a step lifted from the window, so it reads as a page.
        let page = Shade.hex(0xFAF7F0, 0x27231F)
        let rule = Shade.hex(0xDDD5C8, 0x433D37)
        // Umber, at an alpha: hairlines and washes the paper's own.
        func umber(_ light: CGFloat, _ dark: CGFloat) -> Shade {
            Shade(Theme.hex(0x4A3B28).withAlphaComponent(light), Theme.hex(0xF2E6D4).withAlphaComponent(dark))
        }
        return Palette(
            id: "terra",
            title: "Terra",
            chrome: Chrome(
                hover: stone,
                selected: Shade(Theme.hex(0xFFFDF8), NSColor(white: 1, alpha: 0.12)),
                pressed: umber(0.12, 0.14),
                divider: rule,
                panel: panel,
                panelBorder: rule,
                scrim: Shade(Theme.hex(0xEFEAE0).withAlphaComponent(0.4), NSColor(white: 0, alpha: 0.3)),
                cardBorder: umber(0.11, 0.1),
                handle: .hex(0xD6CDBE, 0x524B44),
                scrubberKnob: .hex(0xD6CDBE, 0x524B44),
                sheetEdge: umber(0.22, 0.16),
                sheetEdgeHovered: umber(0.36, 0.34),
                // Stone, deeper further down; by night lighter nearer the top.
                sheet: { level in Shade(NSColor(srgbRed: 0.93 - CGFloat(level) * 0.045, green: 0.91 - CGFloat(level) * 0.045, blue: 0.87 - CGFloat(level) * 0.045, alpha: 1),
                                        NSColor(srgbRed: 0.34 - CGFloat(level) * 0.045, green: 0.31 - CGFloat(level) * 0.045, blue: 0.27 - CGFloat(level) * 0.045, alpha: 1)) },
                stack: .hex(0xF3EFE6, 0x282420),
                dragPill: .hex(0xFFFDF8, 0x524B44),
                linkBehind: { depth in Shade(NSColor(srgbRed: 0.94 - CGFloat(depth) * 0.03, green: 0.92 - CGFloat(depth) * 0.03, blue: 0.88 - CGFloat(depth) * 0.03, alpha: 1),
                                            NSColor(srgbRed: 0.20 - CGFloat(depth) * 0.015, green: 0.17 - CGFloat(depth) * 0.015, blue: 0.14 - CGFloat(depth) * 0.015, alpha: 1)) },
                well: umber(0.06, 0.09),
                pill: umber(0.08, 0.1),
                // Indigo into straw.
                historyWash: (from: .hex(0xE6EBF0, 0x24303D), to: .hex(0xF2EACB, 0x3A3324)),
                bar: .hex(0xF0EBE1, 0x2D2924)),
            text: Text(
                primary: .hex(0x2A2520, 0xEBE4DA),
                body: .hex(0x2A2520, 0xE3DCD2),
                strong: .hex(0x14110D, 0xFAF5EE),
                secondary: .hex(0x6B625A, 0xA39A8F),
                tertiary: .hex(0x71685F, 0x9E958A),
                readingBody: .hex(0x2A2520, 0xE0D9CF),
                readingStrong: .hex(0x14110D, 0xFAF5EE)),
            status: StatusColors(done: done, attention: ochre, failed: madder),
            // Sage, a little mossy: olive by day, a muted sage by night; an
            // indigo caret, a straw selection.
            accent: TintColors(accent: .hex(0x55703A, 0x94A982), caret: indigo, textSelection: straw),
            tints: Palette.calibratedTints(chroma: (0.6, 0.55), panel: panel, window: paper),
            code: Code(
                page: page,
                text: .hex(0x2A2520, 0xEBE4DA),
                lineNumber: .hex(0x6E655C, 0x9A9085),
                lineHighlight: .hex(0xF4EEDC, 0x2C2824),
                gutterText: .hex(0x8A8178, 0x776D62),
                use: umber(0.08, 0.1),
                match: Shade(Theme.hex(0xE3C76A).withAlphaComponent(0.55), Theme.hex(0x8A7430).withAlphaComponent(0.65)),
                link: indigo,
                linkHover: umber(0.08, 0.13),
                added: done,
                modified: ochre,
                deleted: sienna,
                pins: [
                    Shade(Theme.hex(0xC99A2E).withAlphaComponent(0.26), Theme.hex(0xD9B25A).withAlphaComponent(0.3)),
                    Shade(Theme.hex(0x3B5B7A).withAlphaComponent(0.2), Theme.hex(0x8FAACB).withAlphaComponent(0.3)),
                    Shade(Theme.hex(0x55703A).withAlphaComponent(0.22), Theme.hex(0x94A982).withAlphaComponent(0.3)),
                    Shade(Theme.hex(0x9B2C4A).withAlphaComponent(0.18), Theme.hex(0xEE8EA2).withAlphaComponent(0.28)),
                ],
                error: madder,
                warning: sienna,
                hint: Shade(Theme.hex(0x3B5B7A).withAlphaComponent(0.6), Theme.hex(0x8FAACB).withAlphaComponent(0.6)),
                changedOnDisk: .hex(0xF4ECD2, 0x332E26),
                highlighter: Shade(Theme.hex(0xE3C76A).withAlphaComponent(0.5), Theme.hex(0x9A8032).withAlphaComponent(0.45))),
            diff: Diff(
                // An indigo wash for what's added, a sienna for what's taken away.
                added: .hex(0xE0E9F4, 0x1E2B3A),
                removed: .hex(0xFBE6D8, 0x3F2A1C),
                hunk: stone,
                found: straw,
                current: .hex(0xE6D28A, 0x6A5A28)),
            found: Found(
                current: Shade(Theme.hex(0xA4501F).withAlphaComponent(0.4), Theme.hex(0xE08A55).withAlphaComponent(0.5)),
                currentRing: sienna,
                pdf: Shade(NSColor(srgbRed: 1, green: 0.84, blue: 0, alpha: 0.8)),
                pdfCurrent: Shade(NSColor(srgbRed: 0.23, green: 0.36, blue: 0.48, alpha: 0.7))),
            chart: Chart(
                one: indigo,
                two: sienna,
                three: .hex(0x55703A, 0x94A982),
                track: umber(0.07, 0.09),
                surface: umber(0.025, 0.035),
                grid: umber(0.07, 0.08)),
            kinds: Kinds(
                git: sienna, swift: sienna, shell: .hex(0x55703A, 0x94A982), pdf: madder,
                image: .hex(0x7D3F6E, 0xC993B8), data: ochre, patch: done, archive: .hex(0x6B625A, 0xA39A8F),
                media: .hex(0x7D3F6E, 0xC993B8), code: indigo, linked: .hex(0x7D3F6E, 0xC993B8), embeds: .hex(0x2A6F80, 0x82B9C4)),
            terminal: (
                light: TerminalPalette(background: light.bg, foreground: light.fg, cursor: "#3b5b7a", cursorText: light.bg,
                                       selectionBackground: "#efe3b8", selectionForeground: light.fg, ansi: light.ansi,
                                       extended: TerminalPalette.generated(background: light.bg, foreground: light.fg, ansi: light.ansi)),
                dark: TerminalPalette(background: dark.bg, foreground: dark.fg, cursor: "#8faacb", cursorText: dark.bg,
                                      selectionBackground: "#4a4128", selectionForeground: "#faf5ee", ansi: dark.ansi,
                                      extended: TerminalPalette.generated(background: dark.bg, foreground: dark.fg, ansi: dark.ansi))),
            // On the linen paper.
            page: Page(
                background: page,
                text: .hex(0x2A2520, 0xE0D9CF),
                strong: .hex(0x14110D, 0xFAF5EE),
                link: indigo,
                code: .hex(0xF2EDE2, 0x2D2924),
                codeText: .hex(0x2A2520, 0xF2ECE3),
                copy: .hex(0xFFFDF8, 0x393530),
                copyEdge: rule,
                copyText: .hex(0x6B625A, 0xADA59B),
                copyHoverEdge: .hex(0xC2B8A8, 0x5E574F),
                copyHoverText: .hex(0x2A2520, 0xF2ECE3),
                copyDone: done,
                quote: .hex(0x6B625A, 0xA39A8F),
                quoteRule: .hex(0xD6CDBE, 0x4A433C),
                rule: rule,
                tableHead: stone,
                tableStripe: .hex(0xF6F2EA, 0x27231F),
                struck: .hex(0x6B625A, 0x8F857A),
                missing: madder,
                diagramError: madder,
                selection: straw,
                failed: madder,
                running: indigo,
                attention: ochre),
            // A stone table under the paper: by day lichen, linen, sandstone
            // and a slate stone, hardly coloured — a step under the tiles, so
            // they stand on it; by night dark stone and smoked oak, a hint of
            // sage, a muted clay, a slate at one corner — not olive, not sepia. The tint's pool, sage. A grain over it,
            // as paper and stone have, and the tiles' shadows soft and wide.
            backdrop: Backdrop(
                light: .init(stops: [(0.22, 0.07, 0.895), (0.11, 0.06, 0.915), (0.07, 0.09, 0.89), (0.58, 0.04, 0.9)],
                             pool: (0.08, 0.95), tintPool: (0.2, 0.95)),
                // Kept low enough under the sidebar's words that its greys
                // stay below its ink.
                dark: .init(stops: [(0.09, 0.21, 0.18), (0.17, 0.15, 0.17), (0.07, 0.27, 0.175), (0.58, 0.10, 0.14)],
                            pool: (0.22, 0.21), tintPool: (0.35, 0.23)),
                tileShadow: (Theme.hex(0x4A3B28), 0.08),
                grain: (0.05, 0.06)))
    }().legible(5.5).identities(least: 0.75)
}

// MARK: Folio

extension Palette {
    /// Folio: editorial, of paper and print. The Financial Times'
    /// (github.com/mariusae/financial-times-theme, from
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
    static let folio: Palette = {
        // Its salmon a tenth less coloured than FT's own (#fff1e5): the
        // paper still, warm, less pink over an afternoon.
        func p(_ v: Int) -> Int { Palette.eased(v, chroma: 0.9) }
        func pc(_ c: NSColor) -> NSColor { Palette.eased(c, chroma: 0.9) }
        let light = (bg: String(format: "#%06x", p(0xFFF1E5)), fg: "#33302e", ansi: [
            "#262a33", "#990f3d", "#146f41", "#855330", "#0f5499", "#593380", "#136c74", "#66605c",
            "#4d4845", "#c40202", "#56672c", "#665f29", "#1a6886", "#855060", "#27686d", "#5c5958"])
        // By night its brights' colour eased by a quarter (their lightness
        // kept): FT's cyan, blue and yellow glowed on the slate.
        let dark = (bg: "#262a33", fg: "#ffffff", ansi: [
            "#a8aaad", "#d193a8", "#caeada", "#ff8833", "#87aacc", "#ac99c0", "#6eadb3", "#fff1e5",
            "#a6a4a2", "#da9494", "#d8e9b8", "#f9ec71", "#57abd2", "#ed8dab", "#58b8c3", "#ffffff"])
        let teal = Shade.hex(0x0D7680, 0x14BDCC), oxford = Shade.hex(0x0F5499, 0x87AACC)
        let jade = Shade.hex(0x007A3D, 0x66CC99), mandarin = Shade.hex(0xA35214, 0xFF8833), crimson = Shade.hex(0xCC0000, 0xFF6666)
        let claret = Shade.hex(0x990F3D, 0xD193A8), velvet = Shade.hex(0x593380, 0xAC99C0)
        let wheat = Shade.hex(p(0xF2DFCE), 0x4D4845)
        // FT's warm greys (black-5 to black-30) by day; slate lightened by night.
        return Palette(
            id: "folio",
            title: "Folio",
            chrome: Chrome(
                hover: .wash(0.05, 0.07),
                selected: Shade(Theme.hex(p(0xFFFCFA)), NSColor(white: 1, alpha: 0.12)),
                pressed: .wash(0.1, 0.14),
                divider: .hex(p(0xE6D9CE), 0x3D414A),
                panel: .hex(p(0xFFF7EF), 0x2D313A),
                panelBorder: .hex(p(0xE6D9CE), 0x3D414A),
                scrim: Shade(pc(NSColor(srgbRed: 0.95, green: 0.88, blue: 0.81, alpha: 0.35)), NSColor(white: 0, alpha: 0.3)),
                cardBorder: .wash(0.08, 0.1),
                handle: .hex(p(0xCCC1B7), 0x4D515A),
                scrubberKnob: .hex(p(0xCCC1B7), 0x4D515A),
                sheetEdge: .wash(0.2, 0.16),
                sheetEdgeHovered: .wash(0.34, 0.34),
                // Wheat, deeper further down; by night slate, lighter nearer the top.
                sheet: { level in Shade(pc(NSColor(srgbRed: 0.95 - CGFloat(level) * 0.045, green: 0.875 - CGFloat(level) * 0.045, blue: 0.81 - CGFloat(level) * 0.04, alpha: 1)),
                                        NSColor(srgbRed: 0.27 - CGFloat(level) * 0.04, green: 0.29 - CGFloat(level) * 0.04, blue: 0.33 - CGFloat(level) * 0.045, alpha: 1)) },
                stack: .hex(p(0xFFF7EF), 0x2A2E37),
                dragPill: .hex(p(0xFFFCFA), 0x4D515A),
                linkBehind: { depth in Shade(pc(NSColor(srgbRed: 0.97 - CGFloat(depth) * 0.03, green: 0.91 - CGFloat(depth) * 0.03, blue: 0.86 - CGFloat(depth) * 0.03, alpha: 1)),
                                            NSColor(srgbRed: 0.18 - CGFloat(depth) * 0.015, green: 0.19 - CGFloat(depth) * 0.015, blue: 0.23 - CGFloat(depth) * 0.015, alpha: 1)) },
                well: .wash(0.06, 0.09),
                pill: .wash(0.07, 0.1),
                // Sky into FT pink; by night Oxford's deep blue into claret's.
                historyWash: (from: .hex(0xE6EEF5, 0x1E2E44), to: .hex(p(0xFCE0CC), 0x3A2230))),
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
            // Its teal; by night a calmer one than its links' (FT's own
            // #14bdcc glows on the slate as a ring round a tile).
            accent: TintColors(accent: .hex(0x0D7680, 0x5FA7B0), caret: .hex(0x33302E, 0xFFFFFF), textSelection: wheat),
            tints: Palette.calibratedTints(chroma: (0.7, 0.65), panel: .hex(p(0xFFF7EF), 0x2D313A), window: .hex(p(0xFFF1E5), 0x262A33)),
            code: Code(
                page: .hex(p(0xFFF1E5), 0x262A33),
                text: .hex(0x33302E, 0xF2F2F2),
                lineNumber: .hex(0x766E66, 0x8D9099),
                lineHighlight: .hex(p(0xF7E7DA), 0x2D313A),
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
                changedOnDisk: .hex(p(0xF2DFCE), 0x3A3633),
                highlighter: Shade(NSColor(srgbRed: 1, green: 0.93, blue: 0.1, alpha: 0.45), NSColor(srgbRed: 0.7, green: 0.62, blue: 0.1, alpha: 0.45))),
            diff: Diff(
                // Its oxford blue for what's added, mandarin for what's
                // taken away, each at a wash on its paper; hunks its grey.
                added: .hex(0xCCEEFA, 0x1D3B44),
                removed: .hex(0xF9DCCC, 0x412B1F),
                hunk: .hex(0xEAEDF1, 0x343639),
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
                                       selectionBackground: String(format: "#%06x", p(0xF2DFCE)), selectionForeground: light.fg, ansi: light.ansi,
                                       extended: TerminalPalette.generated(background: light.bg, foreground: light.fg, ansi: light.ansi)),
                dark: TerminalPalette(background: dark.bg, foreground: dark.fg, cursor: dark.fg, cursorText: dark.bg,
                                      selectionBackground: "#4d4845", selectionForeground: dark.fg, ansi: dark.ansi,
                                      extended: TerminalPalette.generated(background: dark.bg, foreground: dark.fg, ansi: dark.ansi))),
            // As ft.com sets an article: on its paper, teal links.
            page: Page(
                background: .hex(p(0xFFF1E5), 0x262A33),
                text: .hex(0x33302E, 0xE9EAEB),
                strong: .hex(0x1A1817, 0xFFFFFF),
                link: teal,
                code: .hex(p(0xF2E5DA), 0x2D313A),
                codeText: .hex(0x33302E, 0xF2F2F2),
                copy: .hex(p(0xFFF7EF), 0x333740),
                copyEdge: .hex(p(0xE6D9CE), 0x4A4E57),
                copyText: .hex(0x66605C, 0xA8AAAD),
                copyHoverEdge: .hex(p(0xCCC1B7), 0x5A5E67),
                copyHoverText: .hex(0x33302E, 0xF2F2F2),
                copyDone: jade,
                quote: .hex(0x4D4845, 0xA8AAAD),
                quoteRule: .hex(p(0xCCC1B7), 0x4A4E57),
                rule: .hex(p(0xE6D9CE), 0x3D414A),
                tableHead: .hex(p(0xF2E5DA), 0x2D313A),
                tableStripe: .hex(p(0xFAECE0), 0x21252D),
                struck: .hex(0x807973, 0x8B8D91),
                missing: crimson,
                diagramError: crimson,
                selection: wheat,
                failed: crimson,
                running: teal,
                attention: mandarin),
            // FT pink into its paper and wheat; by night ink-blue and
            // Oxford's, the paper's salmon an ember at one corner — no plum,
            // so it isn't Spectrum's night, and no teal, so it isn't Field's.
            // The tint's pool, teal.
            backdrop: Backdrop(
                // The salmon paper deepened under the tiles, more from
                // corner to corner: the pages set apart from it.
                light: .init(stops: [(0.07, 0.27, 0.93), (0.08, 0.162, 0.96), (0.075, 0.234, 0.84), (0.075, 0.108, 0.93)],
                             pool: (0.198, 0.98), tintPool: (0.35, 0.98)),
                dark: .init(stops: [(0.61, 0.32, 0.24), (0.595, 0.40, 0.21), (0.06, 0.32, 0.21), (0.61, 0.22, 0.14)],
                            pool: (0.4, 0.3), tintPool: (0.6, 0.4)),
                // A warm ink, as FT's black-80: the paper deepened, not greyed.
                tileShadow: (Theme.hex(0x4D3A2A), 0.07)))
    }().legible()
}

// MARK: Spectrum

extension Palette {
    /// Spectrum: chromatic, expressive, softly prismatic. From Claude's
    /// desktop app (Claude.app, read from its stylesheets and
    /// scripts as shipped): the Code tab's design system (`cds`) with its
    /// neutral greys, as the app on this Mac draws them — by day white
    /// pages (#fff) on a #fafafa sidebar, by night #191919 on #1f1f1f,
    /// popovers #303030 — its ink (#0b0b0b, #efefef) and its secondary
    /// text (black at 60%, white at 57%); clay (#d97757, emphasized
    /// #c6613f where it sits on white) for the accent, as its brand fill
    /// and its spinner; and Claude Code's own terminal and code palettes
    /// (`claudeCodeThemes`): its ANSI sixteen, its cool ink
    /// (hsl(220 20% 10%), hsl(220 15% 93%)), a blue caret and a blue
    /// selection. Departures, to read: its muted grey (#878787) is 3.6:1
    /// on white and on its popovers, so the tertiary text is #737373 by
    /// day and #979797 by night; its night green lifted likewise; its
    /// danger a crimson, apart from the clay (its own red was a step from
    /// it, so a focus ring read as a failure); the terminal's inks
    /// deepened by day to 4.5:1 on white (its white a grey, as a light
    /// terminal's is), its bright black lifted by night; its diffs' grounds
    /// a blue and an orange, apart to every eye.
    static let spectrum: Palette = {
        let light = (bg: "#ffffff", fg: "#14181f", ansi: [
            "#1a1a1a", "#e91b19", "#03892d", "#8c7409", "#0073e6", "#cd2054", "#8562cf", "#767676",
            "#666666", "#ff5047", "#1e9e3c", "#98801f", "#0078f0", "#cd2054", "#8e6bd9", "#949494"])
        let dark = (bg: "#1b1a1d", fg: "#eaecf0", ansi: [
            "#262626", "#ff3a30", "#32d74b", "#ffd014", "#0099ff", "#ff2c56", "#b796ff", "#a6a6a6",
            "#787878", "#ff5047", "#32d74b", "#ffd014", "#0087ee", "#ff2c56", "#b796ff", "#ededed"])
        let clay = Shade.hex(0xC6613F, 0xD97757)
        // Claude Code's blue: its terminal's caret, its selection's hue.
        let blue = Shade.hex(0x0073E6, 0x0099FF), selection = Shade.hex(0xBFDCF9, 0x123F5E)
        // Its git colours (cds-text-git-*): added, modified, removed.
        let added = Shade.hex(0x1E9E3C, 0x32D74B), modified = Shade.hex(0x98801F, 0xFFD014), removed = Shade.hex(0xCD2054, 0xFF2C56)
        let violet = Shade.hex(0x8E6BD9, 0xB796FF), aqua = Shade.hex(0x0F7E5C, 0x3BBD8C)
        // Its success, warning and danger, as text: each 4.5:1 or more on
        // a page or a popover; danger a crimson, apart from the clay.
        let done = Shade.hex(0x008300, 0x25AF22), attention = Shade.hex(0x945D00, 0xDB9300), failed = Shade.hex(0xA4273E, 0xFF93A1)
        func alpha(_ hex: Int, _ light: CGFloat, _ darkHex: Int, _ dark: CGFloat) -> Shade {
            Shade(Theme.hex(hex).withAlphaComponent(light), Theme.hex(darkHex).withAlphaComponent(dark))
        }
        return Palette(
            id: "spectrum",
            title: "Spectrum",
            chrome: Chrome(
                // Its ghost hover and selected fills: black at 5% and 10%,
                // white at 7.5% and 15%.
                hover: .wash(0.05, 0.075),
                selected: Shade(.white, NSColor(white: 1, alpha: 0.13)),
                pressed: .wash(0.1, 0.15),
                // Its seams (black at 10%) and its composer's ring (12%).
                divider: .wash(0.1, 0.1),
                panel: .hex(0xFFFFFF, 0x312F34),
                panelBorder: .wash(0.12, 0.14),
                scrim: Shade(NSColor(white: 0.9, alpha: 0.35), NSColor(white: 0, alpha: 0.4)),
                cardBorder: .wash(0.08, 0.1),
                handle: .wash(0.22, 0.25),
                scrubberKnob: .wash(0.14, 0.18),
                sheetEdge: .wash(0.2, 0.16),
                sheetEdgeHovered: .wash(0.34, 0.34),
                sheet: { level in .grey(0.94 - CGFloat(level) * 0.045, 0.25 - CGFloat(level) * 0.04) },
                stack: .hex(0xFFFFFF, 0x1F1F1F),
                dragPill: .hex(0xFFFFFF, 0x312F34),
                linkBehind: { depth in .grey(0.95 - CGFloat(depth) * 0.03, 0.14 - CGFloat(depth) * 0.015) },
                well: .wash(0.05, 0.075),
                pill: .wash(0.07, 0.1),
                // Claude Code's blue into clay.
                historyWash: (from: .hex(0xEBF4FD, 0x162B39), to: .hex(0xFAEBE6, 0x3F2C25)),
                // (Its focused bar was a wash of clay: the ring says focus,
                // and the name in full ink, without the bar saying it again.)
                bar: .hex(0xF6F5F8, 0x312F34)),
            text: Text(
                primary: .hex(0x0B0B0B, 0xEFEFEF),
                body: .hex(0x0B0B0B, 0xEFEFEF),
                strong: .hex(0x000000, 0xFFFFFF),
                secondary: .hex(0x666666, 0x9C9C9C),
                tertiary: .hex(0x737373, 0x979797),
                readingBody: .hex(0x0B0B0B, 0xEFEFEF),
                readingStrong: .hex(0x000000, 0xFFFFFF)),
            status: StatusColors(done: done, attention: attention, failed: failed),
            accent: TintColors(accent: clay, caret: blue, textSelection: selection),
            tints: Palette.calibratedTints(chroma: (0.75, 0.7), panel: .hex(0xFFFFFF, 0x312F34), window: .hex(0xFFFFFF, 0x1B1A1D)),
            code: Code(
                // Read, not edited (view mode, a search's preview): a grey
                // step off the white pages edited; by night its sidebar's.
                page: .hex(0xF7F7F7, 0x1F1F1F),
                text: .hex(0x14181F, 0xEAECF0),
                lineNumber: .hex(0x707070, 0x878787),
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
                // A blue for what's added, an orange for what's taken away
                // (the app's green and pink were one to a deuteranope);
                // hunks a grey.
                added: .hex(0xDAF5FD, 0x0E3C48),
                removed: .hex(0xFFE8DC, 0x402312),
                hunk: .hex(0xF0F3F7, 0x26292B),
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
                copy: .hex(0xFFFFFF, 0x312F34),
                copyEdge: .hex(0xE6E6E6, 0x3A3A3A),
                copyText: .hex(0x666666, 0x9C9C9C),
                copyHoverEdge: .hex(0xCCCCCC, 0x4A4A4A),
                copyHoverText: .hex(0x0B0B0B, 0xEFEFEF),
                copyDone: done,
                quote: .hex(0x666666, 0x9C9C9C),
                quoteRule: .hex(0xE0E0E0, 0x312F34),
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
            // plum into a clay ember — lighter than the bars and more
            // coloured, so the gaps between tiles show, as by day. Clay's
            // pool of light in it.
            // (Brightness as the calibrated space has it.)
            backdrop: Backdrop(
                light: .init(stops: [(0.58, 0.22, 0.97), (0.74, 0.16, 0.97), (0.035, 0.27, 0.99), (0.09, 0.22, 1.0)],
                             pool: (0.2, 1), tintPool: (0.38, 1)),
                dark: .init(stops: [(0.61, 0.55, 0.36), (0.77, 0.45, 0.33), (0.03, 0.58, 0.37), (0.07, 0.45, 0.26)],
                            pool: (0.5, 0.34), tintPool: (0.62, 0.36)),
                // A plum shade under the tiles, not black.
                tileShadow: (Theme.hex(0x2E2A36), 0.07)))
    }().legible()
}

// MARK: Field

extension Palette {
    /// Field: cool and spatial, a continuous field things stand in. GitHub's
    /// Primer, as the terminal theme Merino sets it —
    /// GitHub Light's sixteen with its yellows deepened (#9d5c00, #c47a00),
    /// on white in #1f2328, a blue caret, selection inverted; by night
    /// GitHub Dark's in #e6edf3, on #161b22 (its subtle canvas: its
    /// #0d1117 a step too dark). The rest from Primer's tokens:
    /// canvas white and #f6f8fa (#0d1117, #161b22), its borders (#d0d7de,
    /// #30363d), its muted inks (#59636e, #9198a1: each over 5:1), its
    /// blue, and its success, attention, danger and done for what's done,
    /// waiting, failed, and a chart's third hue. Its chrome as Rex's Merino theme:
    /// a tile's bar the page's own, a hairline round it, the blue ring
    /// round the focused one — and nothing dimmed. What's read on the
    /// subtle canvas, as GitHub sets code.
    static let field: Palette = {
        let light = (bg: "#ffffff", fg: "#1f2328", ansi: [
            "#24292f", "#cf222e", "#116329", "#9d5c00", "#0969da", "#8250df", "#1b7c83", "#6e7781",
            "#57606a", "#a40e26", "#1a7f37", "#c47a00", "#218bff", "#a475f9", "#3192aa", "#8c959f"])
        let dark = (bg: "#161b22", fg: "#e6edf3", ansi: [
            "#484f58", "#ff7b72", "#3fb950", "#d29922", "#58a6ff", "#bc8cff", "#39c5cf", "#b1bac4",
            "#6e7681", "#ffa198", "#56d364", "#e3b341", "#79c0ff", "#d2a8ff", "#56d4dd", "#ffffff"])
        // Primer's fg.accent, its text selection's blue, its subtle canvas.
        let blue = Shade.hex(0x0969DA, 0x2F81F7), selection = Shade.hex(0xB6D8FF, 0x234879)
        let subtle = Shade.hex(0xF6F8FA, 0x1C2128), border = Shade.hex(0xD0D7DE, 0x30363D), muted = Shade.hex(0xDFDFE1, 0x2A3038)
        let done = Shade.hex(0x1A7F37, 0x3FB950), attention = Shade.hex(0x9A6700, 0xD29922), failed = Shade.hex(0xD1242F, 0xF85149)
        let purple = Shade.hex(0x8250DF, 0xA371F7), severe = Shade.hex(0xBC4C00, 0xDB6D28), pink = Shade.hex(0xBF3989, 0xDB61A2)
        let cyan = Shade.hex(0x1B7C83, 0x39C5CF)
        // Its emphases, as marks (a gutter's), not text.
        let added = Shade.hex(0x1F883D, 0x2EA043), modified = Shade.hex(0xBF8700, 0xBB8009), removed = Shade.hex(0xCF222E, 0xDA3633)
        // Primer's neutral (#818b98, #656c76) at an alpha: its hovers and wells.
        func wash(_ light: CGFloat, _ dark: CGFloat) -> Shade {
            Shade(Theme.hex(0x818B98).withAlphaComponent(light), Theme.hex(0x656C76).withAlphaComponent(dark))
        }
        func alpha(_ hex: Int, _ light: CGFloat, _ darkHex: Int, _ dark: CGFloat) -> Shade {
            Shade(Theme.hex(hex).withAlphaComponent(light), Theme.hex(darkHex).withAlphaComponent(dark))
        }
        return Palette(
            id: "field",
            title: "Field",
            chrome: Chrome(
                hover: wash(0.12, 0.2),
                selected: wash(0.18, 0.3),
                pressed: wash(0.24, 0.4),
                divider: border,
                panel: .hex(0xFFFFFF, 0x161B22),
                panelBorder: border,
                scrim: Shade(NSColor(white: 0.95, alpha: 0.4), Theme.hex(0x0D1117).withAlphaComponent(0.55)),
                cardBorder: muted,
                handle: wash(0.4, 0.5),
                scrubberKnob: wash(0.3, 0.4),
                sheetEdge: border,
                sheetEdgeHovered: .hex(0xAFB8C1, 0x6E7681),
                sheet: { level in .grey(0.95 - CGFloat(level) * 0.04, 0.15 + CGFloat(level) * 0.04) },
                stack: subtle,
                dragPill: .hex(0xFFFFFF, 0x1C2128),
                linkBehind: { depth in .grey(0.96 - CGFloat(depth) * 0.03, 0.15 - CGFloat(depth) * 0.015) },
                well: .hex(0xF6F8FA, 0x0D1117),
                pill: wash(0.15, 0.25),
                // Its accent's subtle into done's.
                historyWash: (from: .hex(0xDDF4FF, 0x192638), to: .hex(0xFBEFFF, 0x2B2842)),
                // Its bar a breath off the white page by day (GitHub's
                // subtle), the page's by night; its place and buttons
                // muted, as Rex's (#848689, #90959c) but over 4.5:1.
                bar: .hex(0xF6F8FA, 0x161B22),
                barInk: .hex(0x6E7781, 0x8B949E),
                // Its overlays: white, a step up by night, bordered.
                menu: .hex(0xFFFFFF, 0x1C2128)),
            text: Text(
                primary: .hex(0x1F2328, 0xE6EDF3),
                body: .hex(0x1F2328, 0xE6EDF3),
                strong: .hex(0x1F2328, 0xF0F6FC),
                secondary: .hex(0x59636E, 0x9198A1),
                tertiary: .hex(0x656D76, 0x7D8590),
                readingBody: .hex(0x1F2328, 0xE6EDF3),
                readingStrong: .hex(0x1F2328, 0xF0F6FC)),
            status: StatusColors(done: done, attention: attention, failed: failed),
            accent: TintColors(accent: blue, caret: blue, textSelection: selection),
            tints: Palette.calibratedTints(chroma: (0.8, 0.75), panel: .hex(0xFFFFFF, 0x161B22), window: .hex(0xFFFFFF, 0x161B22)),
            code: Code(
                // Read, not edited: the subtle canvas, as GitHub sets code.
                page: subtle,
                text: .hex(0x1F2328, 0xE6EDF3),
                lineNumber: .hex(0x6A737D, 0x808893),
                lineHighlight: .hex(0xF6F8FA, 0x1C2128),
                gutterText: .hex(0x6E7781, 0x7D8590),
                use: alpha(0x0969DA, 0.1, 0x2F81F7, 0.15),
                match: alpha(0xD4A72C, 0.3, 0xBB8009, 0.3),
                link: blue,
                linkHover: wash(0.12, 0.2),
                added: added,
                modified: modified,
                deleted: removed,
                pins: [
                    alpha(0x9A6700, 0.22, 0xD29922, 0.3),
                    alpha(0x8250DF, 0.2, 0xA371F7, 0.3),
                    alpha(0x0969DA, 0.2, 0x2F81F7, 0.3),
                    alpha(0x1A7F37, 0.2, 0x3FB950, 0.3),
                ],
                error: failed,
                warning: attention,
                hint: alpha(0x0969DA, 0.6, 0x2F81F7, 0.6),
                // Its attention's subtle ground.
                changedOnDisk: .hex(0xFFF8C5, 0x2F2A1E),
                highlighter: alpha(0xD4A72C, 0.4, 0xBB8009, 0.4)),
            diff: Diff(
                // As GitHub's colour-blind themes draw a diff: what's added
                // in a pale blue, what's taken away in a pale orange, hunks
                // a grey.
                added: .hex(0xE0F7FF, 0x112E37),
                removed: .hex(0xFFE8DC, 0x341F13),
                hunk: .hex(0xECF0F3, 0x242628),
                found: .hex(0xFFF8C5, 0x2F2A1E),
                current: .hex(0xEEDCAB, 0x584318)),
            found: Found(
                current: alpha(0xD4A72C, 0.5, 0xBB8009, 0.55),
                currentRing: modified,
                pdf: Shade(NSColor(srgbRed: 1, green: 0.84, blue: 0, alpha: 0.8)),
                pdfCurrent: Shade(NSColor(srgbRed: 0.2, green: 0.5, blue: 0.97, alpha: 0.7))),
            chart: Chart(
                one: blue,
                two: purple,
                three: done,
                track: wash(0.15, 0.25),
                surface: wash(0.05, 0.08),
                grid: wash(0.15, 0.2)),
            kinds: Kinds(
                git: severe, swift: severe, shell: done, pdf: failed,
                image: purple, data: attention, patch: done, archive: .hex(0x59636E, 0x9198A1), media: pink, code: blue,
                linked: purple, embeds: cyan),
            terminal: (
                light: TerminalPalette(background: light.bg, foreground: light.fg, cursor: "#0969da", cursorText: "#b6d8ff",
                                       selectionBackground: light.fg, selectionForeground: light.bg, ansi: light.ansi,
                                       extended: TerminalPalette.generated(background: light.bg, foreground: light.fg, ansi: light.ansi)),
                dark: TerminalPalette(background: dark.bg, foreground: dark.fg, cursor: "#2f81f7", cursorText: "#eff8ff",
                                      selectionBackground: dark.fg, selectionForeground: dark.bg, ansi: dark.ansi,
                                      extended: TerminalPalette.generated(background: dark.bg, foreground: dark.fg, ansi: dark.ansi))),
            // As GitHub sets a README, on the subtle canvas (it's read).
            page: Page(
                background: subtle,
                text: .hex(0x1F2328, 0xE6EDF3),
                strong: .hex(0x1F2328, 0xF0F6FC),
                link: blue,
                code: .hex(0xEAEEF2, 0x262C36),
                codeText: .hex(0x1F2328, 0xE6EDF3),
                copy: .hex(0xFFFFFF, 0x262C36),
                copyEdge: border,
                copyText: .hex(0x59636E, 0x9198A1),
                copyHoverEdge: .hex(0xAFB8C1, 0x6E7681),
                copyHoverText: .hex(0x1F2328, 0xE6EDF3),
                copyDone: done,
                quote: .hex(0x59636E, 0x9198A1),
                quoteRule: border,
                rule: border,
                tableHead: .hex(0xEAEEF2, 0x262C36),
                tableStripe: .hex(0xEFF2F5, 0x21262E),
                struck: .hex(0x6E7781, 0x7D8590),
                missing: failed,
                diagramError: failed,
                selection: selection,
                failed: failed,
                running: blue,
                attention: attention),
            // Heathered, as merino is, and cool, as Rex is: a slate grey a
            // step under the white panes (they stand on it, as Rex's on its
            // #f9f9f9), into teal and GitHub's green — no pink, nothing of
            // Spectrum's pastels; by night slate, deep teal, forest. (Brightness
            // as the calibrated space has it.)
            backdrop: Backdrop(
                light: .init(stops: [(0.59, 0.12, 0.92), (0.52, 0.162, 0.91), (0.40, 0.17, 0.92), (0.60, 0.06, 0.94)],
                             pool: (0.08, 0.98), tintPool: (0.2, 0.98)),
                dark: .init(stops: [(0.59, 0.38, 0.22), (0.51, 0.50, 0.20), (0.40, 0.46, 0.18), (0.60, 0.22, 0.12)],
                            pool: (0.3, 0.24), tintPool: (0.5, 0.28)),
                tileShadow: (Theme.hex(0x1F2328), 0.06),
                // Rex's panes' hairline: #dfdfe1, #2a3038.
                tileEdge: muted))
    }().legible()
}
