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
    #expect(Palette.named("nonesuch").id == "merino")
}
