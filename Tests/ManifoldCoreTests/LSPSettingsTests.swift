import Foundation
import Testing
@testable import ManifoldCore

@Test func languageServerSettingsChangeTheTable() {
    let applied = LanguageServerConfig.applying(LanguageServerConfig.defaults,
                                                ["root": ".hg", "rust": "fblsp rust", "c.root": "compile_commands.json, .hg"])
    let rust = applied.first { $0.id == "rust" }!, go = applied.first { $0.id == "go" }!, c = applied.first { $0.id == "c" }!
    #expect(rust.command == "fblsp rust")
    #expect(rust.rootMarkers == [".hg"])
    #expect(go.command == "gopls")
    #expect(go.rootMarkers == [".hg"])
    #expect(c.rootMarkers == ["compile_commands.json", ".hg"])
    // A root marker that's a folder (.hg) finds the folder holding it.
    let top = FileManager.default.temporaryDirectory.appendingPathComponent("lsp-root-\(UUID().uuidString)").path
    defer { try? FileManager.default.removeItem(atPath: top) }
    try? FileManager.default.createDirectory(atPath: top + "/.hg", withIntermediateDirectories: true)
    try? FileManager.default.createDirectory(atPath: top + "/a/b", withIntermediateDirectories: true)
    try? "fn main() {}".write(toFile: top + "/a/b/main.rs", atomically: true, encoding: .utf8)
    try? "[package]".write(toFile: top + "/a/Cargo.toml", atomically: true, encoding: .utf8)
    #expect(rust.root(of: top + "/a/b/main.rs") == top)
    // Without the setting, Cargo.toml's folder.
    #expect(LanguageServerConfig.defaults.first { $0.id == "rust" }!.root(of: top + "/a/b/main.rs") == top + "/a")
}

@Test func aTextsSymbolsMakeItsOutline() {
    func r(_ line: Int) -> [String: Any] { ["start": ["line": line, "character": 0], "end": ["line": line, "character": 1]] }
    // Nested (DocumentSymbol): a struct, its method and property; a function and its local.
    let nested: [[String: Any]] = [
        ["name": "Widget", "kind": 23, "range": r(0), "selectionRange": r(1), "children": [
            ["name": "size", "kind": 7, "range": r(2), "selectionRange": r(2)],
            ["name": "grow()", "kind": 6, "range": r(3), "selectionRange": r(3), "children": [
                ["name": "step", "kind": 13, "range": r(4), "selectionRange": r(4)],
            ]],
        ]],
        ["name": "main()", "kind": 12, "range": r(8), "selectionRange": r(8)],
    ]
    #expect(LSPSymbol.outline(nested) == [
        LSPSymbol(name: "Widget", kind: 23, line: 1, level: 0),
        LSPSymbol(name: "grow()", kind: 6, line: 3, level: 1),
        LSPSymbol(name: "main()", kind: 12, line: 8, level: 0),
    ])
    // Flat (SymbolInformation), out of order: sorted, a level in when contained.
    let flat: [[String: Any]] = [
        ["name": "run", "kind": 6, "containerName": "Server", "location": ["uri": "file:///a.go", "range": r(9)]],
        ["name": "Server", "kind": 23, "location": ["uri": "file:///a.go", "range": r(4)]],
        ["name": "port", "kind": 8, "containerName": "Server", "location": ["uri": "file:///a.go", "range": r(5)]],
    ]
    #expect(LSPSymbol.outline(flat) == [
        LSPSymbol(name: "Server", kind: 23, line: 4, level: 0),
        LSPSymbol(name: "run", kind: 6, line: 9, level: 1),
    ])
    #expect(LSPSymbol.outline(NSNull()) == [])
}
