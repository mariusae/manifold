import AppKit
import ManifoldCore

/// Debugging: every named colour, resolved in the light and the dark, and
/// the terminal's config — to compare two builds' looks.
@MainActor enum ColorDump {
    static func run() -> String {
        var named: [(String, NSColor)] = [
            ("windowBackground", Theme.windowBackground), ("text", Theme.text), ("bodyText", Theme.bodyText),
            ("strongText", Theme.strongText), ("secondaryText", Theme.secondaryText), ("tertiaryText", Theme.tertiaryText),
            ("hover", Theme.hover), ("selected", Theme.selected), ("selection", Theme.selection),
            ("selectionInactive", Theme.selectionInactive), ("divider", Theme.divider), ("accent", Theme.accent),
            ("statusError", Theme.statusError), ("dropHighlight", Theme.dropHighlight), ("codePage", Theme.codePage),
            ("codeText", Theme.codeText), ("codeLineNumber", Theme.codeLineNumber), ("panel", Theme.panel),
            ("panelBorder", Theme.panelBorder), ("scrim", Theme.scrim), ("cardBorder", Theme.cardBorder),
            ("handle", Theme.handle), ("scrubberKnob", Theme.scrubberKnob),
            ("sheetEdge", Theme.sheetEdge(hovered: false)), ("sheetEdgeHovered", Theme.sheetEdge(hovered: true)),
            ("pressed", Flat.pressed), ("done", Status.done), ("attention", Status.attention), ("failed", Status.failed),
            ("pill", Pill.ground), ("stack", SummaryCard.fill), ("dragPill", DragPill.fill),
            ("highlighter", NoteOutlineStyler.highlighter), ("searchCurrent", SearchPreviewView.currentMatch),
            ("pdfMatch", MediaView.pdfMatch), ("pdfCurrent", MediaView.pdfCurrentMatch),
            ("diffFound", DiffRowsView.foundBackground), ("diffCurrent", DiffRowsView.currentBackground),
            ("diffAdded", DiffRowsView.addedBackground), ("diffRemoved", DiffRowsView.removedBackground),
            ("diffHunk", DiffRowsView.hunkBackground), ("linkHover", TextView.linkHover), ("link", TextView.linkColor),
            ("lineHighlight", TextView.lineHighlight), ("gutterText", TextView.gutterText), ("use", TextView.useColor),
            ("match", TextView.matchColor), ("added", TextView.addedColor), ("modified", TextView.modifiedColor),
            ("deleted", TextView.deletedColor), ("diag1", TextView.diagnosticColor(.error)), ("diag2", TextView.diagnosticColor(.warning)),
            ("diag3", TextView.diagnosticColor(.information)), ("readingBody", MarkdownText.readingBody),
            ("readingStrong", MarkdownText.readingStrong), ("chart1", MachineInk.one), ("chart2", MachineInk.two),
            ("chart3", MachineInk.three), ("chartTrack", MachineInk.track), ("chartSurface", MachineInk.surface),
            ("chartGrid", MachineInk.grid), ("linked", GraphCanvas.color(.link(.linked))),
            ("embeds", GraphCanvas.color(.link(.embeds))), ("accentText", Tints.accentText), ("accentFill", Tints.accentFill),
            ("caret", Tints.caret), ("textSelection", Tints.textSelection),
        ]
        for level in 0..<4 { named.append(("sheet\(level)", Theme.sheet(level: level))) }
        for (i, c) in TextView.pinColors.enumerated() { named.append(("pin\(i)", c)) }
        for name in [".gitignore", "a.swift", "a.sh", "a.pdf", "a.png", "a.json", "a.diff", "a.zip", "a.mp3", "a.rs", "a.md"] {
            named.append(("glyph " + name, BrowserNode.glyph(name).color))
        }
        for t in Tint.allCases {
            named += [("tint \(t) accent", t.accent), ("tint \(t) caret", t.caret), ("tint \(t) selection", t.textSelection),
                      ("tint \(t) band", t.band(active: true)), ("tint \(t) bandInactive", t.band(active: false))]
        }
        var lines: [String] = []
        for (name, color) in named {
            for dark in [false, true] {
                var s = ""
                NSAppearance(named: dark ? .darkAqua : .aqua)?.performAsCurrentDrawingAppearance {
                    let c = color.usingColorSpace(.sRGB) ?? color
                    s = String(format: "%.5f %.5f %.5f %.5f", c.redComponent, c.greenComponent, c.blueComponent, c.alphaComponent)
                }
                lines.append("\(name) \(dark ? "dark" : "light"): \(s)")
            }
        }
        for dark in [false, true] { lines.append("terminal \(dark ? "dark" : "light"):\n" + GhosttyRuntime.debugConfigText(dark: dark)) }
        // What Ghostty makes of it: its 256 colours, and what a command's output is drawn in.
        for dark in [false, true] {
            lines.append("ghostty palette \(dark ? "dark" : "light"): " + GhosttyRuntime.debugResolvedPalette(dark: dark))
            let p = TerminalPalette.current(dark: dark)
            lines.append("output palette \(dark ? "dark" : "light"): " + (0..<256).map { i in "\(i)=" + Tints.hex(p.color(i), dark: dark) }.joined(separator: " "))
        }
        return lines.joined(separator: "\n")
    }
}
