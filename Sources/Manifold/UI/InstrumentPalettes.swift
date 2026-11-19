import AppKit

// MARK: Instruments

extension Palette {
    /// What a theme of structure rather than atmosphere is made from
    /// (Graphite's, Signal's): its grounds, its rules, its inks, the few
    /// colours that say something, its terminal — the rest mixed from them.
    /// Its tiles stand on a near-flat ground, each with a firm hairline
    /// round it and hardly a shadow; colour is what informs.
    struct Instrument {
        var id: String
        var title: String
        /// The tiles' ground (and the terminal's paper), what's read on
        /// (code in view mode, a page), a tile's bar, the panels, popovers.
        var window: Shade
        var subtle: Shade
        var bar: Shade
        var panel: Shade
        var menu: Shade
        /// Rules and borders, and the hairline round each tile.
        var border: Shade
        var edge: Shade
        /// The grey its hovers and wells are washes of.
        var neutral: Shade
        var ink: Shade
        var strong: Shade
        var secondary: Shade
        var tertiary: Shade
        var accent: Shade
        var selection: Shade
        var link: Shade
        var done: Shade
        var attention: Shade
        var failed: Shade
        var purple: Shade
        var cyan: Shade
        var severe: Shade
        /// A diff's added and taken-away grounds (a blue, an orange: apart
        /// to every eye).
        var added: Shade
        var removed: Shade
        var chartTwo: Shade
        var terminal: (light: (bg: String, fg: String, cursor: String, selection: String, ansi: [String]),
                       dark: (bg: String, fg: String, cursor: String, selection: String, ansi: [String]))
        var backdrop: Backdrop
    }

    static func instrument(_ s: Instrument) -> Palette {
        func mix(_ a: Shade, _ b: Shade, _ f: CGFloat) -> Shade {
            func one(_ dark: Bool) -> NSColor {
                let x = a.color(dark: dark).usingColorSpace(.sRGB)!, y = b.color(dark: dark).usingColorSpace(.sRGB)!
                return x.blended(withFraction: f, of: y) ?? x
            }
            return Shade(one(false), one(true))
        }
        func alpha(_ c: Shade, _ light: CGFloat, _ dark: CGFloat) -> Shade {
            Shade(c.light.withAlphaComponent(light), c.dark.withAlphaComponent(dark))
        }
        func wash(_ light: CGFloat, _ dark: CGFloat) -> Shade { alpha(s.neutral, light, dark) }
        let lt = s.terminal.light, dk = s.terminal.dark
        return Palette(
            id: s.id,
            title: s.title,
            chrome: Chrome(
                hover: wash(0.12, 0.2),
                selected: wash(0.18, 0.3),
                pressed: wash(0.26, 0.4),
                divider: s.border,
                panel: s.panel,
                panelBorder: s.border,
                scrim: Shade(s.subtle.light.withAlphaComponent(0.4), s.window.dark.withAlphaComponent(0.55)),
                cardBorder: s.edge,
                handle: wash(0.4, 0.5),
                scrubberKnob: wash(0.3, 0.4),
                sheetEdge: s.border,
                sheetEdgeHovered: mix(s.border, s.ink, 0.3),
                sheet: { level in mix(s.subtle, s.ink, 0.03 + CGFloat(level) * 0.04) },
                stack: s.subtle,
                dragPill: s.menu,
                linkBehind: { depth in mix(s.subtle, s.ink, 0.02 + CGFloat(depth) * 0.03) },
                well: mix(s.subtle, s.ink, 0.03),
                pill: wash(0.15, 0.25),
                historyWash: (from: mix(s.window, s.accent, 0.12), to: mix(s.window, s.done, 0.12)),
                bar: s.bar,
                barInk: s.tertiary,
                menu: s.menu),
            text: Text(
                primary: s.ink,
                body: s.ink,
                strong: s.strong,
                secondary: s.secondary,
                tertiary: s.tertiary,
                readingBody: s.ink,
                readingStrong: s.strong),
            status: StatusColors(done: s.done, attention: s.attention, failed: s.failed),
            accent: TintColors(accent: s.accent, caret: s.accent, textSelection: s.selection),
            tints: Palette.calibratedTints(chroma: (0.6, 0.55), panel: s.panel, window: s.window),
            code: Code(
                page: s.subtle,
                text: s.ink,
                lineNumber: s.secondary,
                lineHighlight: mix(s.window, s.ink, 0.035),
                gutterText: s.tertiary,
                use: alpha(s.accent, 0.12, 0.2),
                match: alpha(s.attention, 0.25, 0.3),
                link: s.link,
                linkHover: wash(0.12, 0.2),
                added: s.done,
                modified: s.attention,
                deleted: s.failed,
                pins: [alpha(s.attention, 0.22, 0.3), alpha(s.purple, 0.2, 0.3), alpha(s.accent, 0.2, 0.3), alpha(s.done, 0.2, 0.3)],
                error: s.failed,
                warning: s.attention,
                hint: alpha(s.accent, 0.6, 0.6),
                changedOnDisk: mix(s.window, s.attention, 0.14),
                highlighter: alpha(s.attention, 0.35, 0.4)),
            diff: Diff(
                added: s.added,
                removed: s.removed,
                hunk: mix(s.subtle, s.ink, 0.04),
                found: mix(s.window, s.attention, 0.16),
                current: mix(s.window, s.attention, 0.4)),
            found: Found(
                current: alpha(s.attention, 0.5, 0.55),
                currentRing: s.attention,
                pdf: Shade(NSColor(srgbRed: 1, green: 0.84, blue: 0, alpha: 0.8)),
                pdfCurrent: Shade(NSColor(srgbRed: 0.2, green: 0.5, blue: 0.97, alpha: 0.7))),
            chart: Chart(
                one: s.accent,
                two: s.chartTwo,
                three: s.done,
                track: wash(0.15, 0.25),
                surface: wash(0.05, 0.08),
                grid: wash(0.15, 0.2)),
            kinds: Kinds(
                git: s.severe, swift: s.severe, shell: s.done, pdf: s.failed,
                image: s.purple, data: s.attention, patch: s.done, archive: s.secondary, media: s.purple, code: s.link,
                linked: s.purple, embeds: s.cyan),
            terminal: (
                light: TerminalPalette(background: lt.bg, foreground: lt.fg, cursor: lt.cursor, cursorText: lt.bg,
                                       selectionBackground: lt.selection, selectionForeground: lt.fg, ansi: lt.ansi,
                                       extended: TerminalPalette.generated(background: lt.bg, foreground: lt.fg, ansi: lt.ansi)),
                dark: TerminalPalette(background: dk.bg, foreground: dk.fg, cursor: dk.cursor, cursorText: dk.bg,
                                      selectionBackground: dk.selection, selectionForeground: dk.fg, ansi: dk.ansi,
                                      extended: TerminalPalette.generated(background: dk.bg, foreground: dk.fg, ansi: dk.ansi))),
            page: Page(
                background: s.subtle,
                text: s.ink,
                strong: s.strong,
                link: s.link,
                code: mix(s.subtle, s.ink, 0.05),
                codeText: s.ink,
                copy: s.menu,
                copyEdge: s.border,
                copyText: s.secondary,
                copyHoverEdge: mix(s.border, s.ink, 0.3),
                copyHoverText: s.ink,
                copyDone: s.done,
                quote: s.secondary,
                quoteRule: s.border,
                rule: s.border,
                tableHead: mix(s.subtle, s.ink, 0.05),
                tableStripe: mix(s.subtle, s.ink, 0.025),
                struck: s.tertiary,
                missing: s.failed,
                diagramError: s.failed,
                selection: s.selection,
                failed: s.failed,
                running: s.accent,
                attention: s.attention),
            backdrop: s.backdrop)
    }

    // MARK: Graphite

    /// Graphite: a neutral instrument — as a Braun radio, a Swiss poster,
    /// a photographer's editor or a Unix workstation are. Grey throughout,
    /// a step lighter round the tiles than in them by night and a step
    /// darker by day, the ground all but flat; firm hairlines, hardly a
    /// shadow; its inks the strongest of the themes (secondary text 6:1 and
    /// more). Its accent a slate blue, quiet; colour is kept for what says
    /// something — a status, a diff, an agent, a space, the terminal's
    /// sixteen — and so is read as information, not as atmosphere.
    static let graphite: Palette = instrument(Instrument(
        id: "graphite",
        title: "Graphite",
        window: .hex(0xFAFAFA, 0x1E1F21),
        subtle: .hex(0xF4F4F5, 0x232426),
        bar: .hex(0xEFEFF0, 0x2A2B2D),
        panel: .hex(0xFFFFFF, 0x252628),
        menu: .hex(0xFFFFFF, 0x2C2D30),
        border: .hex(0xD4D4D8, 0x3A3B3F),
        edge: .hex(0xCDCDD1, 0x3A3B3F),
        neutral: .hex(0x808086, 0x6E6E74),
        ink: .hex(0x1A1A1C, 0xE8E8EA),
        strong: .hex(0x000000, 0xF7F7F8),
        secondary: .hex(0x4E4E53, 0xB0B0B5),
        tertiary: .hex(0x5C5C61, 0x9E9EA3),
        accent: .hex(0x4F6380, 0x9AA8BE),
        selection: .hex(0xD3DBE7, 0x3A4556),
        link: .hex(0x2F5A92, 0x9DB6DC),
        done: .hex(0x2E7A3A, 0x6DC07A),
        attention: .hex(0x8A5F00, 0xD9A548),
        failed: .hex(0xC2302B, 0xF07A70),
        purple: .hex(0x7A4FB8, 0xB89AE6),
        cyan: .hex(0x1F7480, 0x6CC0C8),
        severe: .hex(0xB24A10, 0xE0823F),
        added: .hex(0xDCEAFA, 0x1C2C3C),
        removed: .hex(0xFDE4D4, 0x3A261C),
        chartTwo: .hex(0x7A4FB8, 0xB89AE6),
        terminal: (
            light: (bg: "#fafafa", fg: "#1a1a1c", cursor: "#4f6380", selection: "#d3dbe7", ansi: [
                "#1a1a1c", "#c2302b", "#2e7a3a", "#8a5f00", "#2f5a92", "#7a4fb8", "#1f7480", "#5f5f64",
                "#4e4e53", "#d64a3d", "#3a9149", "#a87700", "#4a76b3", "#9468cf", "#2a8f9c", "#86868b"]),
            dark: (bg: "#1e1f21", fg: "#e8e8ea", cursor: "#9aa8be", selection: "#3a4556", ansi: [
                "#3a3b3f", "#f07a70", "#6dc07a", "#d9a548", "#86a8db", "#b89ae6", "#6cc0c8", "#c4c4c8",
                "#7d7e83", "#ff958b", "#8ad596", "#e9bd68", "#a3bfe8", "#cdb3f0", "#8ad3da", "#f2f2f4"])),
        // All but flat: the faintest cool grey, a step lighter than the
        // tiles by night (so the gaps between them show) and darker by
        // day; the tint's pool barely there.
        backdrop: Backdrop(
            light: .init(stops: [(0.62, 0.02, 0.86), (0.62, 0.015, 0.85), (0.62, 0.02, 0.84), (0.62, 0.015, 0.855)],
                         pool: (0.01, 0.89), tintPool: (0.06, 0.89)),
            dark: .init(stops: [(0.62, 0.04, 0.105), (0.62, 0.03, 0.1), (0.62, 0.04, 0.095), (0.62, 0.03, 0.085)],
                        pool: (0.03, 0.12), tintPool: (0.1, 0.125)),
            tileShadow: (.black, 0.04),
            tileEdge: .hex(0xCDCDD1, 0x3A3B3F),
            daylight: false)))
        .legible()

    // MARK: Signal

    /// Signal: an instrument for watching many things run — a scope's
    /// face, a flight deck's, an engineering workstation's, without their
    /// glow. By night its tiles a midnight navy raised from a deeper one,
    /// edged in steel, cyan for what's chosen and amber for what wants
    /// you; by day a blueprint's cold white on its pale blue, the cyan
    /// deepened to a petrol, blueprint-blue links and a bronze amber. Its contrast high, its states told apart
    /// at a glance; a chart's series cyan, amber and green.
    static let signal: Palette = instrument(Instrument(
        id: "signal",
        title: "Signal",
        window: .hex(0xF6F8FB, 0x141B29),
        subtle: .hex(0xEFF2F8, 0x18202F),
        bar: .hex(0xE8EDF5, 0x1B2335),
        panel: .hex(0xFFFFFF, 0x1B2335),
        menu: .hex(0xFFFFFF, 0x202A3E),
        border: .hex(0xCFD7E4, 0x2A3A50),
        edge: .hex(0xC3CCDC, 0x2A3A50),
        neutral: .hex(0x7A879C, 0x5F6F88),
        ink: .hex(0x1C2636, 0xE2E8F0),
        strong: .hex(0x0B1220, 0xF4F7FB),
        secondary: .hex(0x45536A, 0xA2B0C4),
        tertiary: .hex(0x526078, 0x8E9DB3),
        accent: .hex(0x1F6F8B, 0x7FB8CF),
        selection: .hex(0xCCE2EC, 0x24435A),
        link: .hex(0x2B5F96, 0x8CC6DC),
        done: .hex(0x23794F, 0x6CC79A),
        attention: .hex(0x86602A, 0xD4AE6B),
        failed: .hex(0xB83A30, 0xF2837A),
        purple: .hex(0x6B55B0, 0xAFA0E6),
        cyan: .hex(0x1C7488, 0x7FB8CF),
        severe: .hex(0xA65616, 0xE39256),
        added: .hex(0xDDEDFA, 0x16314A),
        removed: .hex(0xFBE7D8, 0x3C2A1A),
        chartTwo: .hex(0x86602A, 0xD4AE6B),
        terminal: (
            light: (bg: "#f6f8fb", fg: "#1c2636", cursor: "#1f6f8b", selection: "#cce2ec", ansi: [
                "#1c2636", "#b83a30", "#23794f", "#86602a", "#2b5f96", "#6b55b0", "#1c7488", "#556379",
                "#45536a", "#cf4c40", "#2f9262", "#a57a37", "#4479b3", "#8670c9", "#2a8da3", "#7a879c"]),
            dark: (bg: "#141b29", fg: "#e2e8f0", cursor: "#7fb8cf", selection: "#24435a", ansi: [
                "#2a3a50", "#f2837a", "#6cc79a", "#d4ae6b", "#7aa7dc", "#afa0e6", "#7fb8cf", "#b4c0d0",
                "#6e819c", "#ff9d94", "#8ddbb2", "#e6c58a", "#9cc0ea", "#c8bcf2", "#a0d0e2", "#f0f4f9"])),
        // By night a deeper navy round the tiles, all but flat, steel at
        // one corner — the one theme whose tiles are raised from their
        // ground by night, as a panel's faces from its bezel; by day the
        // blueprint's pale blue. The tint's pool faint.
        backdrop: Backdrop(
            light: .init(stops: [(0.61, 0.17, 0.85), (0.60, 0.13, 0.87), (0.58, 0.15, 0.84), (0.62, 0.11, 0.875)],
                         pool: (0.08, 0.92), tintPool: (0.2, 0.92)),
            dark: .init(stops: [(0.615, 0.66, 0.068), (0.61, 0.62, 0.062), (0.58, 0.52, 0.078), (0.62, 0.62, 0.056)],
                        pool: (0.5, 0.09), tintPool: (0.5, 0.1)),
            tileShadow: (Theme.hex(0x1C2636), 0.05),
            tileEdge: .hex(0xC3CCDC, 0x2A3A50),
            daylight: false)))
        .legible()
}
