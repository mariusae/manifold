import AppKit
import Testing
@testable import Manifold

// Every colour theme keeps to what DESIGN.md §11 promises of them all, by
// day and by night: text that reads, line numbers too; an accent that
// isn't what failed; a terminal whose inks read on its paper; and a diff
// whose added and taken-away lines a deuteranope tells apart.

private func over(_ top: NSColor, _ ground: NSColor) -> NSColor {
    let t = top.usingColorSpace(.sRGB)!, g = ground.usingColorSpace(.sRGB)!
    let a = t.alphaComponent
    return NSColor(srgbRed: t.redComponent * a + g.redComponent * (1 - a), green: t.greenComponent * a + g.greenComponent * (1 - a),
                   blue: t.blueComponent * a + g.blueComponent * (1 - a), alpha: 1)
}

private func each(_ check: (Palette, Bool, String) -> Void) {
    for p in Palette.all { for dark in [false, true] { check(p, dark, "\(p.id) \(dark ? "dark" : "light")") } }
}

@Test func everyThemesTextReadsOnItsPanels() {
    each { p, dark, name in
        let window = p.window.color(dark: dark)
        let panel = over(p.chrome.panel.color(dark: dark), window)
        let texts: [(String, Shade)] = [("primary", p.text.primary), ("secondary", p.text.secondary), ("tertiary", p.text.tertiary),
                                        ("done", p.status.done), ("attention", p.status.attention), ("failed", p.status.failed)]
        for (role, shade) in texts {
            let r = Tints.contrast(over(shade.color(dark: dark), panel), panel)
            #expect(r >= 4.5, "\(name): \(role) \(r)")
        }
        // Line numbers, on the page code's read on and the window it's edited on.
        for ground in [over(p.code.page.color(dark: dark), window), window] {
            let r = Tints.contrast(over(p.code.lineNumber.color(dark: dark), ground), ground)
            #expect(r >= 4.5, "\(name): line numbers \(r)")
        }
    }
}

@Test func noThemesAccentIsWhatFailed() {
    each { p, dark, name in
        let d = ColorVision.typical.difference(p.accent.accent.color(dark: dark), p.status.failed.color(dark: dark))
        #expect(d >= 0.1, "\(name): accent and failed \(d) apart")
    }
}

@Test func everyThemesTerminalInksReadOnItsPaper() {
    each { p, dark, name in
        let t = dark ? p.terminal.dark : p.terminal.light
        for i in 1..<16 {
            // By day the brights a step paler (3:1), as a light terminal's are;
            // by night bright black, the dim text of suggestions and comments, 3.7:1.
            let least: CGFloat = dark ? (i == 8 ? 3.7 : 4.5) : (i <= 8 ? 4.5 : 3)
            let r = Tints.contrast(t.colors[i], t.background)
            #expect(r >= least, "\(name): colour \(i) \(r)")
        }
    }
}

@Test func everyThemesDiffIsToldApartByADeuteranope() {
    each { p, dark, name in
        let window = p.window.color(dark: dark)
        let added = over(p.diff.added.color(dark: dark), window), removed = over(p.diff.removed.color(dark: dark), window)
        let d = ColorVision.deuteranopia.difference(added, removed)
        #expect(d >= (dark ? 0.06 : 0.044), "\(name): added and removed \(d) apart")
    }
}

@Test func themesThatWereAreThoseThatReplacedThem() {
    #expect(Palette.named("paper").id == "merino")
    #expect(Palette.named("claude-classic").id == "claude")
    #expect(Palette.named("claude-warm").id == "claude")
    #expect(Palette.named("newsprint").id == "classic")
    #expect(Palette.named("stone").id == "financial-times")
    #expect(Palette.named("dusk").id == "merino")
    #expect(Palette.named("slate").id == "graphite")
    #expect(Palette.named("nonesuch").id == "merino")
}

// The sidebar's words are on the backdrop, not a panel: its wash and its
// pools of light, as drawn — every theme's text reads there too (4.5:1),
// its faintest included.
@MainActor
@Test func everyThemesSidebarTextReadsOnItsBackdrop() {
    each { p, dark, name in
        let wash = p.backdrop.wash(dark: dark)
        let pools = wash.stops.map { NSColor(calibratedHue: $0.0, saturation: wash.pool.saturation, brightness: wash.pool.brightness, alpha: 1) }
        for ground in BackdropView.colors(of: wash) + pools {
            let g = ground.usingColorSpace(.sRGB)!
            for (role, shade) in [("primary", p.text.primary), ("secondary", p.text.secondary), ("tertiary", p.text.tertiary)] {
                let r = Tints.contrast(over(shade.color(dark: dark), g), g)
                #expect(r >= 4.5, "\(name): \(role) on the backdrop \(r)")
            }
        }
    }
}

// A listing's folders (blue, as ls has them) are told from its files (the
// terminal's ink) in every theme, by day and by night.
@Test func everyThemesTerminalTellsFoldersFromFiles() {
    each { p, dark, name in
        let t = dark ? p.terminal.dark : p.terminal.light
        let d = ColorVision.typical.difference(t.colors[4], t.foreground)
        #expect(d >= 0.15, "\(name): blue and the ink \(d) apart")
    }
}

// With contrast increased (the system's Increase Contrast), every theme's
// faint inks read at 7:1 on its panels and its backdrop, its accent and
// tints at 4.5:1 on its panels, and its rules are firmer than they were —
// its secondary ink still below its primary.
@MainActor
@Test func everyThemeIsFirmerWithContrastIncreased() {
    each { base, dark, name in
        let p = base.firmer()
        let panel = over(p.chrome.panel.color(dark: dark), p.window.color(dark: dark))
        let wash = p.backdrop.wash(dark: dark)
        for ground in BackdropView.colors(of: wash) + [panel] {
            let g = ground.usingColorSpace(.sRGB)!
            for (role, shade) in [("secondary", p.text.secondary), ("tertiary", p.text.tertiary)] {
                let r = Tints.contrast(over(shade.color(dark: dark), g), g)
                #expect(r >= 6.9, "\(name): \(role) \(r)")
            }
        }
        let primary = Tints.contrast(over(p.text.primary.color(dark: dark), panel), panel)
        let secondary = Tints.contrast(over(p.text.secondary.color(dark: dark), panel), panel)
        #expect(primary > secondary, "\(name): primary \(primary), secondary \(secondary)")
        for accent in [p.accent.accent] + p.tints.values.map(\.accent) {
            let r = Tints.contrast(over(accent.color(dark: dark), panel), panel)
            #expect(r >= 4.4, "\(name): an accent \(r)")
        }
        let before = Tints.contrast(over(base.chrome.divider.color(dark: dark), panel), panel)
        let after = Tints.contrast(over(p.chrome.divider.color(dark: dark), panel), panel)
        #expect(after > before, "\(name): rules \(before) → \(after)")
    }
}
