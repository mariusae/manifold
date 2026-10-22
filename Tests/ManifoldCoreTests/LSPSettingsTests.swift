import Foundation
import Testing
@testable import ManifoldCore

@Test func languageServerSettingsReadAsApexWritesThem() throws {
    let text = """
        lsp.root .hg
        lsp.rust “$HOME/.apex/fblsp-server rust”
        python "$HOME/.apex/fblsp-server python"
        # a comment, and a blank line

        lsp.c.root compile_commands.json, .hg
        """
    let ids = LanguageServerConfig.defaults.map(\.id)
    let lsp = try HostPreferences.parseLSP(text, languages: ids).get()
    #expect(lsp == ["root": ".hg", "rust": "$HOME/.apex/fblsp-server rust", "python": "$HOME/.apex/fblsp-server python",
                    "c.root": "compile_commands.json, .hg"])
    // Back to lines, and read again: the same.
    #expect(try HostPreferences.parseLSP(HostPreferences(lsp: lsp).lspLines, languages: ids).get() == lsp)
    // A language there's none of: refused, saying which there are.
    if case .success = HostPreferences.parseLSP("lsp.cobol cobold", languages: ids) { Issue.record("cobol taken") }
}

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
