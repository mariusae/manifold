import Foundation
import Testing
@testable import ManifoldCore

private func ids(_ n: Int) -> [UUID] { (0..<n).map { _ in UUID() } }

private func workspace(tabs n: Int) -> (Workspace, tabs: [UUID], panes: [UUID]) {
    var ws = Workspace()
    let tabs = ids(n), panes = ids(n)
    for i in 0..<n {
        ws.apply(.newTab(tab: tabs[i], pane: panes[i], kind: .terminal, cwd: nil, after: nil))
    }
    return (ws, tabs, panes)
}

@Test func newTabIsSelectedAndPlacedAfter() {
    var (ws, tabs, _) = workspace(tabs: 3)
    #expect(ws.selectedTab == tabs[2])
    let t = UUID()
    ws.apply(.newTab(tab: t, pane: UUID(), kind: .terminal, cwd: "/tmp", after: tabs[0]))
    #expect(ws.tabs.map(\.id) == [tabs[0], t, tabs[1], tabs[2]])
    #expect(ws.selectedTab == t)
    #expect(ws.tab(t)?.panes.first?.cwd == "/tmp")
}

@Test func closingSelectedTabSelectsNeighbor() {
    var (ws, tabs, panes) = workspace(tabs: 3)
    ws.apply(.selectTab(tabs[1]))
    #expect(ws.apply(.closeTab(tabs[1])) == [panes[1]])
    #expect(ws.selectedTab == tabs[2])
    ws.apply(.closeTab(tabs[2]))
    #expect(ws.selectedTab == tabs[0])
    ws.apply(.closeTab(tabs[0]))
    #expect(ws.selectedTab == nil)
    #expect(ws.tabs.isEmpty)
}

@Test func mergeAndUnsplit() {
    var (ws, tabs, panes) = workspace(tabs: 3)
    // Drop tab 2 onto the right half of tab 1's only pane.
    ws.apply(.mergeTab(tabs[2], into: tabs[1], at: 1))
    #expect(ws.tabs.map(\.id) == [tabs[0], tabs[1]])
    #expect(ws.tab(tabs[1])?.panes.map(\.id) == [panes[1], panes[2]])
    #expect(ws.tab(tabs[1])?.focusedPane == panes[2])
    #expect(ws.tab(tabs[1])?.fractions == [0.5, 0.5])
    #expect(ws.selectedTab == tabs[1])

    ws.apply(.unsplit(tabs[1]))
    #expect(ws.tabs.count == 3)
    // The focused pane keeps the tab; the other gets a new tab after it.
    #expect(ws.tabs[1].id == tabs[1])
    #expect(ws.tabs[1].panes.map(\.id) == [panes[2]])
    #expect(ws.tabs[2].panes.map(\.id) == [panes[1]])
}

@Test func mergeIntoItselfDoesNothing() {
    var (ws, tabs, _) = workspace(tabs: 2)
    let before = ws
    ws.apply(.mergeTab(tabs[0], into: tabs[0], at: 0))
    #expect(ws == before)
}

@Test func closingLastPaneOfSplitLeavesTab() {
    var (ws, tabs, panes) = workspace(tabs: 2)
    ws.apply(.mergeTab(tabs[1], into: tabs[0], at: 0))
    #expect(ws.tab(tabs[0])?.panes.map(\.id) == [panes[1], panes[0]])
    ws.apply(.closePane(panes[1]))
    #expect(ws.tab(tabs[0])?.panes.map(\.id) == [panes[0]])
    #expect(ws.tab(tabs[0])?.focusedPane == panes[0])
    #expect(ws.tab(tabs[0])?.fractions == [1])
    ws.apply(.closePane(panes[0]))
    #expect(ws.tabs.isEmpty)
}

@Test func detachPane() {
    var (ws, tabs, panes) = workspace(tabs: 2)
    ws.apply(.mergeTab(tabs[1], into: tabs[0], at: 1))
    let t = UUID()
    ws.apply(.detachPane(panes[0], newTab: t))
    #expect(ws.tabs.map(\.id) == [tabs[0], t])
    #expect(ws.tab(t)?.panes.map(\.id) == [panes[0]])
    #expect(ws.tab(tabs[0])?.focusedPane == panes[1])
    #expect(ws.selectedTab == t)
}

@Test func titles() {
    var (ws, tabs, panes) = workspace(tabs: 1)
    #expect(ws.tabs[0].title == "Terminal")
    ws.apply(.setPaneTitle(panes[0], "vim"))
    #expect(ws.tabs[0].title == "vim")
    ws.apply(.renameTab(tabs[0], title: "  work "))
    #expect(ws.tabs[0].title == "work")
    ws.apply(.renameTab(tabs[0], title: ""))
    #expect(ws.tabs[0].customTitle == nil)
}

@Test func moveTabAndFractions() {
    var (ws, tabs, _) = workspace(tabs: 3)
    ws.apply(.moveTab(tabs[0], to: 2))
    #expect(ws.tabs.map(\.id) == [tabs[1], tabs[2], tabs[0]])
    ws.apply(.mergeTab(tabs[2], into: tabs[1], at: 1))
    ws.apply(.setFractions(tabs[1], [3, 1]))
    #expect(ws.tab(tabs[1])?.fractions == [0.75, 0.25])
    ws.apply(.setFractions(tabs[1], [1]))
    #expect(ws.tab(tabs[1])?.fractions == [0.75, 0.25])
}

@Test func workspaceRoundTrips() throws {
    var (ws, tabs, _) = workspace(tabs: 2)
    ws.apply(.mergeTab(tabs[1], into: tabs[0], at: 1))
    ws.apply(.setWindow(WindowState(frame: [1, 2, 3, 4], sidebarPinned: true)))
    let data = try JSONEncoder().encode(ws)
    #expect(try JSONDecoder().decode(Workspace.self, from: data) == ws)
    let cmd = Command.mergeTab(tabs[0], into: tabs[1], at: 3)
    #expect(try JSONDecoder().decode(Command.self, from: JSONEncoder().encode(cmd)) == cmd)
}

@Test func frames() throws {
    var d = FrameDecoder()
    let a = Frame.resize(cols: 300, rows: 40).encoded
    let b = Frame(.data, Data("hello".utf8)).encoded
    let all = a + b
    // Byte at a time.
    var got: [Frame] = []
    for byte in all {
        d.append(Data([byte]))
        while let f = try d.next() { got.append(f) }
    }
    #expect(got.count == 2)
    #expect(got[0].size?.cols == 300 && got[0].size?.rows == 40)
    #expect(got[1].payload == Data("hello".utf8))
}

@Test func titleScanner() {
    var s = TitleScanner()
    #expect(s.feed(Data("plain \u{1b}[1mtext".utf8)) == nil)
    #expect(s.feed(Data("\u{1b}]0;one\u{07}".utf8)) == "one")
    #expect(s.feed(Data("\u{1b}]2;tw".utf8)) == nil)
    #expect(s.feed(Data("o\u{1b}\\x".utf8)) == "two")
    #expect(s.feed(Data("\u{1b}]7;file://host/tmp\u{07}".utf8)) == nil)
    #expect(s.feed(Data("\u{1b}]0;a\u{07}\u{1b}]2;b\u{07}".utf8)) == "b")
}

@Test func replayTracksAltScreen() {
    var r = ReplayBuffer(limit: 100)
    r.append(Data("$ vim\r\n\u{1b}[?10".utf8))
    #expect(!r.altScreen)
    r.append(Data("49h".utf8))
    #expect(r.altScreen)
    // Trim away the switch; the replay must put it back.
    r.append(Data(String(repeating: "line\r\n", count: 30).utf8))
    let replay = String(decoding: r.replay, as: UTF8.self)
    #expect(replay.contains("\u{1b}[?1049h"))
    #expect(!replay.contains("vim"))
    r.append(Data("\u{1b}[?1049l$ ".utf8))
    #expect(!r.altScreen)
}

@Test func replayRestoresHistory() {
    var old = ReplayBuffer()
    old.append(Data("$ ls\r\nfile\r\n$ vim\u{1b}[?1049h~~~".utf8))
    let r = ReplayBuffer(restoring: old.contents)
    #expect(!r.altScreen)
    let text = String(decoding: r.replay, as: UTF8.self)
    #expect(text.contains("file"))
    #expect(text.hasSuffix("\u{1b}[0m\u{1b}[?1049l\r\n"))
    #expect(ReplayBuffer(restoring: Data()).contents.isEmpty)
}

@Test func oldStateDecodesWithDefaults() throws {
    let json = #"{"tabs":[],"window":{"sidebarPinned":true}}"#
    let ws = try JSONDecoder().decode(Workspace.self, from: Data(json.utf8))
    #expect(ws.window.sidebarPinned)
    #expect(ws.appearance == Appearance())
    var ws2 = ws
    ws2.apply(.setAppearance(Appearance(contrastCorrection: .off)))
    #expect(ws2.appearance.contrastCorrection == .off)
}
