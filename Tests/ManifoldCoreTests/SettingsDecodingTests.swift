import Foundation
import Testing
@testable import ManifoldCore

/// Settings saved before a setting existed get its default; one saved in
/// a form since gone, too; the rest come back as they were.

private func decoded<T: Decodable>(_ type: T.Type, _ json: String) throws -> T {
    try JSONDecoder().decode(type, from: Data(json.utf8))
}

private func again<T: Codable>(_ value: T) throws -> T {
    try Codec.decode(T.self, from: Codec.encode(value))
}

@Test func nothingSavedIsEveryDefault() throws {
    #expect(try decoded(Settings.self, "{}") == Settings())
    #expect(try decoded(Appearance.self, "{}") == Appearance())
    #expect(try decoded(HostPreferences.self, "{}") == HostPreferences())
    #expect(try decoded(ClientState.self, "{}") == ClientState())
    #expect(try decoded(TypeStyle.self, "{}") == TypeStyle(family: "", size: 14, lineHeight: 1.3))
}

@Test func whatWasSavedComesBackAsItWas() throws {
    var s = Settings()
    s.collectAfterMinutes = 5
    s.terminalDormantAfterHours = 0
    s.textHistoryDays = 3
    s.terminalHistoryDays = 7
    s.undoDepth = 100
    s.agentCommand = "codex"
    s.copyOnSelect = false
    s.rootsSettled = true
    s.languageServers = Array(LanguageServerConfig.defaults.prefix(1))
    #expect(try again(s) == s)

    var a = Appearance(theme: .custom, colorScheme: .dark, contrastCorrection: .deuteranopia, editorFont: .proportional, tint: .theme, colorTheme: "ink")
    a.typography = .humanist
    a.advancedTypography = false
    #expect(try again(a) == a)

    let p = HostPreferences(shell: "fish", lsp: ["rust": "rust-analyzer"], environment: [])
    #expect(try again(p) == p)

    var c = ClientState()
    c.selected = BlockID(host: .local)
    c.hostOrder = ["h1", "h2"]
    c.collapsedRows = ["r"]
    c.window = WindowState(frame: [1, 2, 3, 4], sidebarPinned: false, sidebarWidth: 240)
    c.appearance = a
    #expect(try again(c) == c)

    let t = TypeStyle(family: "Menlo", size: 13, weight: 500, lineHeight: 1.4, tracking: 5, features: "calt", measure: 70,
                      paragraphSpacing: 0.5, headingWeight: 600, boldFace: "Bold")
    #expect(try again(t) == t)
}

@Test func oldOrOddValuesTakeTheDefault() throws {
    let s = try decoded(Settings.self, #"{"collectAfterMinutes": "soon", "undoDepth": 9}"#)
    #expect(s.collectAfterMinutes == 30)
    #expect(s.undoDepth == 9)
    // A custom theme set before Advanced Typography: shown.
    #expect(try decoded(Appearance.self, #"{"theme": "custom"}"#).advancedTypography)
    #expect(try decoded(Appearance.self, #"{"theme": "custom", "advancedTypography": false}"#).advancedTypography == false)
    #expect(try decoded(Appearance.self, #"{"theme": "notes"}"#).theme == .system)
    #expect(try decoded(HostPreferences.self, #"{"shell": "zsh"}"#).environment == nil)
}
