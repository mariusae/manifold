import AppKit

// MARK: Quiet themes

/// Themes of medium contrast: a paper a step off white by day (and a step
/// off black by night), tinted — Stone warm, Slate cool, Sage green, Dusk
/// violet — its ink at some 8:1 rather than 12 to 20, its inks muted. What
/// every theme keeps to (DESIGN.md §11) bounds them: what's secondary, its
/// tertiary, a status, a line number all at 4.5:1 at least, so the ink's
/// above that, and the paper can't go far from white or black.
///
/// Each is made from a few colours — its paper, its panels', its inks and
/// its terminal's sixteen, by day and by night — and the rest mixed from
/// them, as a Newsprint's are by hand.
extension Palette {
    /// One appearance of a quiet theme: what it's made from.
    struct QuietSide {
        /// The window's ground (the terminal's paper), the panels', the ink.
        var paper: Int
        var panel: Int
        var ink: Int
        var strong: Int
        var secondary: Int
        var tertiary: Int
        var accent: Int
        var done: Int
        var attention: Int
        var failed: Int
        /// Its inks for kinds, charts and tints: red, green, ochre, blue, plum, teal, orange.
        var red: Int, green: Int, ochre: Int, blue: Int, plum: Int, teal: Int, orange: Int
        /// A diff's added and taken-away lines' grounds: blue-green and
        /// orange-red, as a deuteranope tells them apart.
        var added: Int
        var removed: Int
        /// The terminal's sixteen.
        var ansi: [Int]
        /// The backdrop's hue, saturation and brightness.
        var wash: (h: CGFloat, s: CGFloat, b: CGFloat)
    }

    static func quiet(id: String, title: String, light l: QuietSide, dark d: QuietSide, shadow: Int) -> Palette {
        func hex(_ v: Int) -> String { String(format: "#%06x", v) }
        func rgb(_ v: Int) -> (CGFloat, CGFloat, CGFloat) {
            (CGFloat((v >> 16) & 0xFF) / 255, CGFloat((v >> 8) & 0xFF) / 255, CGFloat(v & 0xFF) / 255)
        }
        func mix(_ a: Int, _ b: Int, _ t: CGFloat) -> Int {
            let (ar, ag, ab) = rgb(a), (br, bg, bb) = rgb(b)
            func c(_ x: CGFloat, _ y: CGFloat) -> Int { Int(((x + (y - x) * t) * 255).rounded()) }
            return (c(ar, br) << 16) | (c(ag, bg) << 8) | c(ab, bb)
        }
        func alpha(_ v: Int, _ a: CGFloat) -> NSColor { Theme.hex(v).withAlphaComponent(a) }
        /// The same in each: a colour picked from a side.
        func both(_ pick: (QuietSide) -> Int) -> Shade { .hex(pick(l), pick(d)) }
        func mixed(_ t: CGFloat, _ a: (QuietSide) -> Int, _ b: (QuietSide) -> Int) -> Shade {
            .hex(mix(a(l), b(l), t), mix(a(d), b(d), t))
        }
        let red = both(\.red), green = both(\.green), ochre = both(\.ochre), blue = both(\.blue)
        let plum = both(\.plum), teal = both(\.teal), orange = both(\.orange), accent = both(\.accent)
        let selection = Shade.hex(mix(l.paper, l.accent, 0.2), mix(d.paper, d.accent, 0.3))
        let codePage = mixed(0.5, \.paper, \.panel)
        func terminal(_ s: QuietSide, selection: Int) -> TerminalPalette {
            let ansi = s.ansi.map(hex)
            return TerminalPalette(background: hex(s.paper), foreground: hex(s.ink), cursor: hex(s.accent), cursorText: hex(s.paper),
                                   selectionBackground: hex(selection), selectionForeground: hex(s.ink), ansi: ansi,
                                   extended: TerminalPalette.generated(background: hex(s.paper), foreground: hex(s.ink), ansi: ansi))
        }
        func wash(_ w: (h: CGFloat, s: CGFloat, b: CGFloat), dark: Bool) -> Backdrop.Wash {
            let step: CGFloat = dark ? 0.02 : 0.04
            return .init(stops: [(w.h, w.s, w.b), (w.h - 0.02, w.s * 1.2, w.b - step), (w.h + 0.01, w.s, w.b - 2 * step), (w.h + 0.02, w.s * 0.5, w.b + step / 2)],
                         pool: (w.s, min(1, w.b + step)), tintPool: (0.14, min(1, w.b + step)))
        }
        return Palette(
            id: id,
            title: title,
            chrome: Chrome(
                hover: .wash(0.05, 0.07),
                selected: Shade(Theme.hex(mix(l.panel, 0xFFFFFF, 0.5)), NSColor(white: 1, alpha: 0.1)),
                pressed: .wash(0.1, 0.13),
                divider: .wash(0.09, 0.1),
                panel: both(\.panel),
                panelBorder: .wash(0.11, 0.13),
                scrim: Shade(alpha(l.paper, 0.35), NSColor(white: 0, alpha: 0.3)),
                cardBorder: .wash(0.08, 0.1),
                handle: .wash(0.2, 0.24),
                scrubberKnob: .wash(0.14, 0.18),
                sheetEdge: .wash(0.18, 0.16),
                sheetEdgeHovered: .wash(0.32, 0.34),
                sheet: { level in .hex(mix(l.paper, l.ink, 0.04 + CGFloat(level) * 0.05), mix(d.paper, d.ink, 0.07 - CGFloat(level) * 0.025)) },
                stack: both(\.panel),
                dragPill: .hex(mix(l.panel, 0xFFFFFF, 0.5), mix(d.panel, d.ink, 0.15)),
                linkBehind: { depth in .hex(mix(l.paper, l.ink, 0.03 + CGFloat(depth) * 0.04), mix(d.paper, 0x000000, 0.25 + CGFloat(depth) * 0.08)) },
                well: .wash(0.06, 0.09),
                pill: .wash(0.07, 0.1),
                historyWash: (from: codePage, to: .hex(mix(l.paper, l.attention, 0.12), mix(d.paper, d.attention, 0.12)))),
            text: Text(
                primary: both(\.ink),
                body: both(\.ink),
                strong: both(\.strong),
                secondary: both(\.secondary),
                tertiary: both(\.tertiary),
                readingBody: both(\.ink),
                readingStrong: both(\.strong)),
            status: StatusColors(done: both(\.done), attention: both(\.attention), failed: both(\.failed)),
            accent: TintColors(accent: accent, textSelection: selection),
            tints: [
                .blue: TintColors(accent: blue, textSelection: .hex(mix(l.paper, l.blue, 0.2), mix(d.paper, d.blue, 0.3))),
                .orange: TintColors(accent: orange, textSelection: .hex(mix(l.paper, l.orange, 0.2), mix(d.paper, d.orange, 0.3))),
                .purple: TintColors(accent: plum, textSelection: .hex(mix(l.paper, l.plum, 0.2), mix(d.paper, d.plum, 0.3))),
                .pink: TintColors(accent: red, textSelection: .hex(mix(l.paper, l.red, 0.18), mix(d.paper, d.red, 0.28))),
                .green: TintColors(accent: green, textSelection: .hex(mix(l.paper, l.green, 0.2), mix(d.paper, d.green, 0.3))),
                .graphite: TintColors(accent: both(\.secondary), caret: both(\.ink), textSelection: .hex(mix(l.paper, l.ink, 0.12), mix(d.paper, d.ink, 0.15))),
            ],
            code: Code(
                page: codePage,
                text: both(\.ink),
                // On the page and the window alike, at 4.5:1.
                lineNumber: both(\.secondary),
                lineHighlight: .hex(mix(mix(l.paper, l.panel, 0.5), l.attention, 0.08), mix(mix(d.paper, d.panel, 0.5), d.attention, 0.08)),
                gutterText: .hex(mix(l.paper, l.ink, 0.45), mix(d.paper, d.ink, 0.4)),
                use: .wash(0.075, 0.1),
                match: Shade(alpha(l.attention, 0.35), alpha(d.attention, 0.4)),
                link: accent,
                linkHover: .wash(0.08, 0.12),
                added: green,
                modified: blue,
                deleted: red,
                pins: [
                    Shade(alpha(l.teal, 0.26), alpha(d.teal, 0.33)),
                    Shade(alpha(l.ochre, 0.28), alpha(d.ochre, 0.33)),
                    Shade(alpha(l.plum, 0.26), alpha(d.plum, 0.33)),
                    Shade(alpha(l.red, 0.22), alpha(d.red, 0.3)),
                ],
                error: both(\.failed),
                warning: both(\.attention),
                hint: Shade(alpha(l.accent, 0.6), alpha(d.accent, 0.6)),
                changedOnDisk: .hex(mix(l.panel, l.attention, 0.14), mix(d.panel, d.attention, 0.14)),
                highlighter: Shade(alpha(l.ochre, 0.35), alpha(d.ochre, 0.4))),
            diff: Diff(
                added: both(\.added),
                removed: both(\.removed),
                hunk: .hex(mix(l.paper, l.ink, 0.08), mix(d.paper, d.ink, 0.08)),
                found: .hex(mix(l.paper, l.ochre, 0.25), mix(d.paper, d.ochre, 0.25)),
                current: .hex(mix(l.paper, l.ochre, 0.5), mix(d.paper, d.ochre, 0.45))),
            found: Found(
                current: Shade(alpha(l.orange, 0.45), alpha(d.orange, 0.5)),
                currentRing: orange,
                pdf: Shade(NSColor(srgbRed: 1, green: 0.84, blue: 0, alpha: 0.8)),
                pdfCurrent: Shade(NSColor(srgbRed: 0.2, green: 0.56, blue: 1, alpha: 0.7))),
            chart: Chart(one: accent, two: red, three: teal, track: .wash(0.07, 0.09), surface: .wash(0.025, 0.035), grid: .wash(0.07, 0.08)),
            kinds: Kinds(git: orange, swift: orange, shell: green, pdf: red, image: plum, data: ochre, patch: green,
                         archive: .hex(mix(l.ochre, l.ink, 0.4), mix(d.ochre, d.ink, 0.4)), media: red, code: blue, linked: plum, embeds: teal),
            terminal: (light: terminal(l, selection: mix(l.paper, l.accent, 0.2)), dark: terminal(d, selection: mix(d.paper, d.accent, 0.3))),
            page: Page(
                background: .hex(l.panel, d.paper),
                text: both(\.ink),
                strong: both(\.strong),
                link: accent,
                code: .hex(mix(l.panel, l.ink, 0.05), d.panel),
                codeText: both(\.ink),
                copy: both(\.panel),
                copyEdge: .hex(mix(l.panel, l.ink, 0.15), mix(d.panel, d.ink, 0.15)),
                copyText: both(\.tertiary),
                copyHoverEdge: .hex(mix(l.panel, l.ink, 0.28), mix(d.panel, d.ink, 0.25)),
                copyHoverText: both(\.strong),
                copyDone: both(\.done),
                quote: both(\.secondary),
                quoteRule: .hex(mix(l.panel, l.ink, 0.16), mix(d.panel, d.ink, 0.15)),
                rule: .hex(mix(l.panel, l.ink, 0.12), mix(d.panel, d.ink, 0.1)),
                tableHead: .hex(mix(l.panel, l.ink, 0.05), mix(d.paper, d.ink, 0.04)),
                tableStripe: .hex(mix(l.panel, l.ink, 0.03), mix(d.paper, d.ink, 0.02)),
                struck: .hex(mix(l.ink, l.paper, 0.35), mix(d.ink, d.paper, 0.35)),
                missing: both(\.failed),
                diagramError: both(\.failed),
                selection: selection,
                failed: both(\.failed),
                running: accent,
                attention: both(\.attention)),
            backdrop: Backdrop(light: wash(l.wash, dark: false), dark: wash(d.wash, dark: true),
                               tileShadow: (Theme.hex(shadow), 0.08)))
    }

    /// Stone: a warm grey paper, a soft umber ink; an ochre accent, amber
    /// for what wants you — by night the stone in shade.
    static let stone = quiet(id: "stone", title: "Stone",
        light: QuietSide(paper: 0xE3DFD7, panel: 0xECE9E2, ink: 0x45423C, strong: 0x2C2A26, secondary: 0x5F5B53, tertiary: 0x67635B,
                         accent: 0x7C6224, done: 0x46663A, attention: 0x94541A, failed: 0x9C3B2A,
                         red: 0x9C3B2A, green: 0x46663A, ochre: 0x7A5C12, blue: 0x3F5F86, plum: 0x7A5070, teal: 0x386663, orange: 0x94541A,
                         added: 0xC3D6DC, removed: 0xE8C9B8,
                         ansi: [0x3A3833, 0x9C3B2A, 0x46663A, 0x7A5C12, 0x3F5F86, 0x7A5070, 0x386663, 0x5E5A52,
                                0x615D55, 0xB34E3A, 0x5E8250, 0x94742A, 0x52749E, 0x926685, 0x4F8480, 0x77736A],
                         wash: (0.10, 0.10, 0.84)),
        dark: QuietSide(paper: 0x2D2B28, panel: 0x353330, ink: 0xD3CEC4, strong: 0xECE8DF, secondary: 0xA6A197, tertiary: 0xA09B91,
                        accent: 0xC8AF63, done: 0x93B07D, attention: 0xD9954A, failed: 0xE5866F,
                        red: 0xE07A63, green: 0x93B07D, ochre: 0xCBA65A, blue: 0x8AA3C8, plum: 0xBC94B2, teal: 0x7FB0AA, orange: 0xD9954A,
                        added: 0x2B4550, removed: 0x523528,
                        ansi: [0x4A4843, 0xE07A63, 0x93B07D, 0xCBA65A, 0x8AA3C8, 0xBC94B2, 0x7FB0AA, 0xCFCAC0,
                               0x88837B, 0xEB9079, 0xA8C392, 0xDDB96F, 0xA1B8DA, 0xCFA9C6, 0x95C3BD, 0xEDE9E0],
                        wash: (0.09, 0.12, 0.17)),
        shadow: 0x4A3E30)

    /// Slate: a grey-blue paper, a blue-grey ink, a steel-blue accent —
    /// cool where Stone is warm.
    static let slate = quiet(id: "slate", title: "Slate",
        light: QuietSide(paper: 0xDFE3E7, panel: 0xE9ECEF, ink: 0x3B424A, strong: 0x262C33, secondary: 0x57606A, tertiary: 0x5F6872,
                         accent: 0x3E6491, done: 0x3F6B4A, attention: 0x8A5A14, failed: 0xA3423A,
                         red: 0xA03F37, green: 0x3D6847, ochre: 0x7A5B13, blue: 0x3C5F8C, plum: 0x77507A, teal: 0x36686F, orange: 0x9A5A22,
                         added: 0xBFD8E6, removed: 0xECCBBE,
                         ansi: [0x3B424A, 0xA03F37, 0x3D6847, 0x7A5B13, 0x3C5F8C, 0x77507A, 0x36686F, 0x59626C,
                                0x5A636E, 0xB85246, 0x508059, 0x957528, 0x5078A8, 0x8F6893, 0x4A828A, 0x737C86],
                         wash: (0.58, 0.08, 0.85)),
        dark: QuietSide(paper: 0x292E35, panel: 0x31373F, ink: 0xCBD2DA, strong: 0xE6EBF0, secondary: 0x9FA9B4, tertiary: 0x98A2AD,
                        accent: 0x8EAFD6, done: 0x8DB894, attention: 0xD6A458, failed: 0xE8877D,
                        red: 0xE07F74, green: 0x8DB894, ochre: 0xCDA45E, blue: 0x85A6D2, plum: 0xB897C4, teal: 0x7DB5BD, orange: 0xDB9257,
                        added: 0x24414E, removed: 0x4E3229,
                        ansi: [0x3F4650, 0xE07F74, 0x8DB894, 0xCDA45E, 0x85A6D2, 0xB897C4, 0x7DB5BD, 0xC3CAD2,
                               0x808A96, 0xEC968C, 0xA3C9A9, 0xDDB872, 0x9DB9DE, 0xCBAED5, 0x95C8CF, 0xE6EBF0],
                        wash: (0.59, 0.16, 0.17)),
        shadow: 0x2E3C4E)

    /// Sage: a grey-green paper, a moss accent; what's done a teal, so it
    /// isn't the accent — by night the leaves in shade.
    static let sage = quiet(id: "sage", title: "Sage",
        light: QuietSide(paper: 0xDFE4DC, panel: 0xE9EDE6, ink: 0x3A4238, strong: 0x262D25, secondary: 0x565F54, tertiary: 0x5E675B,
                         accent: 0x4F6B2E, done: 0x2E6A60, attention: 0x8A5A14, failed: 0xA3423A,
                         red: 0xA03F37, green: 0x4A6A2E, ochre: 0x7A5B13, blue: 0x3E5F86, plum: 0x77507A, teal: 0x33685E, orange: 0x9A5A22,
                         added: 0xBED8E4, removed: 0xEBCBBE,
                         ansi: [0x3A4238, 0xA03F37, 0x4A6A2E, 0x7A5B13, 0x3E5F86, 0x77507A, 0x33685E, 0x586255,
                                0x5A6457, 0xB85246, 0x5E8243, 0x957528, 0x52749E, 0x8F6893, 0x458278, 0x737C70],
                         wash: (0.27, 0.09, 0.84)),
        dark: QuietSide(paper: 0x2A2F29, panel: 0x323831, ink: 0xCDD3C8, strong: 0xE7ECE3, secondary: 0xA0AA9C, tertiary: 0x9AA496,
                        accent: 0xA7C27F, done: 0x84BFB2, attention: 0xD6A458, failed: 0xE8877D,
                        red: 0xE07F74, green: 0xA7C27F, ochre: 0xCDA45E, blue: 0x85A6D2, plum: 0xB897C4, teal: 0x7DB8AA, orange: 0xDB9257,
                        added: 0x1F4150, removed: 0x53332A,
                        ansi: [0x40473E, 0xE07F74, 0xA7C27F, 0xCDA45E, 0x85A6D2, 0xB897C4, 0x7DB8AA, 0xC5CCC0,
                               0x828C7E, 0xEC968C, 0xBBD497, 0xDDB872, 0x9DB9DE, 0xCBAED5, 0x93CBBE, 0xE7ECE3],
                        wash: (0.28, 0.14, 0.17)),
        shadow: 0x34402F)

    /// Dusk: a lavender-grey paper, a soft violet accent — and by night
    /// dark lifted, as twilight is, not black.
    static let dusk = quiet(id: "dusk", title: "Dusk",
        light: QuietSide(paper: 0xE2E0E7, panel: 0xEBEAF0, ink: 0x403D4A, strong: 0x2B2833, secondary: 0x5E5A6A, tertiary: 0x666272,
                         accent: 0x5E58A0, done: 0x3F6B4A, attention: 0x8A5A14, failed: 0xA3423A,
                         red: 0xA03F3E, green: 0x3F6849, ochre: 0x7A5B13, blue: 0x3F5D8E, plum: 0x7A4F84, teal: 0x37676F, orange: 0x9A5A22,
                         added: 0xC8D6E6, removed: 0xEACDC8,
                         ansi: [0x403D4A, 0xA03F3E, 0x3F6849, 0x7A5B13, 0x3F5D8E, 0x7A4F84, 0x37676F, 0x5D5A68,
                                0x605D6B, 0xB8524F, 0x508059, 0x957528, 0x5577AA, 0x926399, 0x4A828A, 0x78758A],
                         wash: (0.71, 0.07, 0.86)),
        dark: QuietSide(paper: 0x33323C, panel: 0x3B3A45, ink: 0xD4D2DE, strong: 0xECEBF3, secondary: 0xAEABBA, tertiary: 0xA8A5B4,
                        accent: 0xABA6E6, done: 0x94C49C, attention: 0xDDAD62, failed: 0xEE958C,
                        red: 0xEB8E86, green: 0x94C49C, ochre: 0xD6AB64, blue: 0x92AEDD, plum: 0xC4A2D6, teal: 0x85C0C6, orange: 0xE19A5E,
                        added: 0x2B4556, removed: 0x573A35,
                        ansi: [0x4A4955, 0xEB8E86, 0x94C49C, 0xD6AB64, 0x92AEDD, 0xC4A2D6, 0x85C0C6, 0xCBC9D6,
                               0x8E8C9C, 0xF3A39B, 0xABD3B1, 0xE3BE7C, 0xA9C1E8, 0xD4B7E2, 0x9DD0D5, 0xECEBF3],
                        wash: (0.71, 0.14, 0.21)),
        shadow: 0x3A3550)
}
