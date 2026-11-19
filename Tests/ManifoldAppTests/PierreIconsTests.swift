import AppKit
import Testing
@testable import Manifold

// Every icon Manifold names of Pierre's is there, in Resources/PierreIcons
// (scripts/update-pierre-icons.sh), at each size — or it'd be drawn as the
// system's without a word.
@Test func everyPierreIconNamedIsBundled() {
    let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Resources/PierreIcons")
    for icon in PierreIcons.named {
        for px in [12, 16, 24] {
            let path = root.appendingPathComponent("Icon\(icon)/outline-\(px)px.svg").path
            #expect(FileManager.default.fileExists(atPath: path), "Icon\(icon) at \(px)px")
        }
    }
    for use in PierreIcons.replacing.values where use.fill {
        let path = root.appendingPathComponent("Icon\(use.icon)/fill-16px.svg").path
        #expect(FileManager.default.fileExists(atPath: path), "Icon\(use.icon) filled")
    }
}

// A name of our own for what Pierre tells apart (a diff's "more above")
// is still drawn, as the system's, when its set is the system's.
@Test func ourNamesFallBackToTheSystemsSymbols() {
    for name in ["diff.more.above", "thread.new"] {
        #expect(PierreIcons.replacing[name] != nil, "\(name) is Pierre's")
        let drawn = Theme.symbolFallbacks[name]?.contains { NSImage(systemSymbolName: $0, accessibilityDescription: nil) != nil } == true
        #expect(drawn, "\(name)")
    }
}
