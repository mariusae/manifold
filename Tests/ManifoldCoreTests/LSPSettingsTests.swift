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
