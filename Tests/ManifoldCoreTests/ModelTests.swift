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

@Test func movePaneToANewTab() {
    var (ws, tabs, panes) = workspace(tabs: 2)
    ws.apply(.mergeTab(tabs[1], into: tabs[0], at: 1))
    let t = UUID()
    ws.apply(.movePane(panes[0], to: .newTab(tab: t, index: 1)))
    #expect(ws.tabs.map(\.id) == [tabs[0], t])
    #expect(ws.tab(t)?.panes.map(\.id) == [panes[0]])
    #expect(ws.tab(tabs[0])?.focusedPane == panes[1])
    #expect(ws.selectedTab == t)
    // A pane that's a tab of its own already stays put.
    ws.apply(.movePane(panes[0], to: .newTab(tab: UUID(), index: 0)))
    #expect(ws.tabs.map(\.id) == [tabs[0], t])
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

@Test func themeDefaultsToMonaAndSurvivesUnknownThemes() throws {
    let old = #"{"contrastCorrection":"typical"}"#
    #expect(try JSONDecoder().decode(Appearance.self, from: Data(old.utf8)).theme == .mona)
    #expect(try JSONDecoder().decode(Appearance.self, from: Data(old.utf8)).colorScheme == .system)
    let future = #"{"theme":"comic","contrastCorrection":"off"}"#
    let a = try JSONDecoder().decode(Appearance.self, from: Data(future.utf8))
    #expect(a.theme == .mona)
    #expect(a.contrastCorrection == .off)
    let go = Appearance(theme: .go, colorScheme: .dark)
    #expect(try JSONDecoder().decode(Appearance.self, from: JSONEncoder().encode(go)) == go)
}

@Test func openFileBesideAPaneMakesAColumnThenStacksOnIt() {
    var (ws, tabs, panes) = workspace(tabs: 2)
    let a = UUID(), b = UUID()
    ws.apply(.openFile(path: "/tmp/a.md", kind: .markdown, pane: a, tab: UUID(), beside: panes[0]))
    #expect(ws.tabs.count == 2)
    #expect(ws.tab(tabs[0])?.columns.map { $0.panes.map(\.id) } == [[panes[0]], [a]])
    #expect(ws.tab(tabs[0])?.focusedPane == panes[0], "focus stays in the terminal")
    #expect(ws.selectedTab == tabs[0])
    // Another file goes on the right-hand stack, not into a third column.
    ws.apply(.openFile(path: "/tmp/b.md", kind: .markdown, pane: b, tab: UUID(), beside: panes[0]))
    #expect(ws.tab(tabs[0])?.columns.map { $0.panes.map(\.id) } == [[panes[0]], [a, b]])
    #expect(ws.tab(tabs[0])?.visiblePanes.map(\.id) == [panes[0], b])
    // A file already on the stack is raised, not pushed again.
    ws.apply(.openFile(path: "/tmp/a.md", kind: .markdown, pane: UUID(), tab: UUID(), beside: panes[0]))
    #expect(ws.tab(tabs[0])?.columns[1].panes.map(\.id) == [b, a])
}

@Test func openFileStacksOnAnExistingRightColumn() {
    // A terminal already on the right: the preview goes on its stack.
    var (ws, tabs, panes) = workspace(tabs: 2)
    ws.apply(.mergeTab(tabs[1], into: tabs[0], at: 1))
    let md = UUID()
    ws.apply(.openFile(path: "/tmp/a.md", kind: .markdown, pane: md, tab: UUID(), beside: panes[0]))
    #expect(ws.tab(tabs[0])?.columns.map { $0.panes.map(\.id) } == [[panes[0]], [panes[1], md]])
}

@Test func closingTheTopPopsTheStack() {
    var (ws, tabs, panes) = workspace(tabs: 1)
    let a = UUID(), b = UUID()
    ws.apply(.newPane(pane: a, tab: tabs[0], at: 1, kind: .terminal, cwd: nil))
    ws.apply(.openFile(path: "/tmp/b.md", kind: .markdown, pane: b, tab: UUID(), beside: panes[0]))
    // [p0] [a, b], focus on a's column top after focusing b
    ws.apply(.focusPane(b))
    #expect(ws.apply(.closePane(b)) == [b])
    #expect(ws.tab(tabs[0])?.columns.map { $0.panes.map(\.id) } == [[panes[0]], [a]])
    #expect(ws.tab(tabs[0])?.focusedPane == a, "the pane beneath takes focus")
    ws.apply(.closePane(a))
    #expect(ws.tab(tabs[0])?.columns.count == 1)
    #expect(ws.tab(tabs[0])?.focusedPane == panes[0])
}

@Test func focusingABuriedPaneRaisesIt() {
    var (ws, tabs, panes) = workspace(tabs: 1)
    let a = UUID(), b = UUID()
    ws.apply(.openFile(path: "/tmp/a.md", kind: .markdown, pane: a, tab: UUID(), beside: panes[0]))
    ws.apply(.openFile(path: "/tmp/b.md", kind: .markdown, pane: b, tab: UUID(), beside: panes[0]))
    ws.apply(.focusPane(a))
    #expect(ws.tab(tabs[0])?.columns[1].panes.map(\.id) == [b, a])
    #expect(ws.tab(tabs[0])?.focusedPane == a)
}

@Test func closingABuriedPaneLeavesFocusAlone() {
    var (ws, tabs, panes) = workspace(tabs: 1)
    let a = UUID(), b = UUID()
    ws.apply(.openFile(path: "/tmp/a.md", kind: .markdown, pane: a, tab: UUID(), beside: panes[0]))
    ws.apply(.openFile(path: "/tmp/b.md", kind: .markdown, pane: b, tab: UUID(), beside: panes[0]))
    ws.apply(.closePane(a))
    #expect(ws.tab(tabs[0])?.columns[1].panes.map(\.id) == [b])
    #expect(ws.tab(tabs[0])?.focusedPane == panes[0])
}

@Test func stackingATabPushesItsPanes() {
    var (ws, tabs, panes) = workspace(tabs: 2)
    let column = ws.tab(tabs[0])!.columns[0].id
    ws.apply(.stackTab(tabs[1], onto: column))
    #expect(ws.tabs.map(\.id) == [tabs[0]])
    #expect(ws.tab(tabs[0])?.columns.map { $0.panes.map(\.id) } == [[panes[0], panes[1]]])
    #expect(ws.tab(tabs[0])?.focusedPane == panes[1])
    #expect(!ws.tab(tabs[0])!.isSplit)
}

@Test func unsplitKeepsEachColumnsStack() {
    var (ws, tabs, panes) = workspace(tabs: 1)
    let a = UUID(), b = UUID()
    ws.apply(.openFile(path: "/tmp/a.md", kind: .markdown, pane: a, tab: UUID(), beside: panes[0]))
    ws.apply(.openFile(path: "/tmp/b.md", kind: .markdown, pane: b, tab: UUID(), beside: panes[0]))
    ws.apply(.unsplit(tabs[0]))
    #expect(ws.tabs.count == 2)
    #expect(ws.tabs[1].columns.map { $0.panes.map(\.id) } == [[a, b]])
}

@Test func stateSavedBeforeStacksLoads() throws {
    let p0 = UUID(), p1 = UUID(), t = UUID()
    let json = """
        {"tabs":[{"id":"\(t)","panes":[{"id":"\(p0)","kind":"terminal"},{"id":"\(p1)","kind":"terminal"}],
          "focusedPane":"\(p1)","fractions":[0.3,0.7]}],"selectedTab":"\(t)","window":{"sidebarPinned":false}}
        """
    let ws = try JSONDecoder().decode(Workspace.self, from: Data(json.utf8))
    #expect(ws.tabs[0].columns.map { $0.panes.map(\.id) } == [[p0], [p1]])
    #expect(ws.tabs[0].fractions == [0.3, 0.7])
    #expect(ws.tabs[0].focusedPane == p1)
    // And round-trips in the new form.
    let again = try JSONDecoder().decode(Workspace.self, from: JSONEncoder().encode(ws))
    #expect(again == ws)
}

@Test func openFileWithoutAPaneMakesOrReusesATab() {
    var (ws, tabs, _) = workspace(tabs: 1)
    let t = UUID()
    ws.apply(.openFile(path: "/tmp/a.md", kind: .markdown, pane: UUID(), tab: t, beside: nil))
    #expect(ws.tabs.map(\.id) == [tabs[0], t])
    #expect(ws.selectedTab == t)
    ws.apply(.selectTab(tabs[0]))
    ws.apply(.openFile(path: "/tmp/a.md", kind: .markdown, pane: UUID(), tab: UUID(), beside: nil))
    #expect(ws.tabs.count == 2)
    #expect(ws.selectedTab == t)
}

@Test func setPanePathFollowsLinks() {
    var ws = Workspace()
    let p = UUID()
    ws.apply(.openFile(path: "/tmp/a.md", kind: .markdown, pane: p, tab: UUID(), beside: nil))
    ws.apply(.setPanePath(p, "/tmp/b.md"))
    #expect(ws.pane(p)?.path == "/tmp/b.md")
    #expect(ws.tabs[0].title == "b.md")
}

@Test func newSheetPushesOntoAStack() {
    var (ws, tabs, panes) = workspace(tabs: 1)
    let column = ws.tabs[0].columns[0].id
    let p = UUID()
    ws.apply(.newSheet(pane: p, column: column, kind: .terminal, cwd: "/tmp"))
    #expect(ws.tab(tabs[0])?.columns.map { $0.panes.map(\.id) } == [[panes[0], p]])
    #expect(ws.tab(tabs[0])?.focusedPane == p)
    #expect(ws.pane(p)?.cwd == "/tmp")
}

@Test func movePaneBetweenStacksAndColumns() {
    var (ws, tabs, panes) = workspace(tabs: 1)
    let left = ws.tabs[0].columns[0].id
    let a = UUID(), b = UUID()
    ws.apply(.newPane(pane: a, tab: tabs[0], at: 1, kind: .terminal, cwd: nil))
    ws.apply(.newSheet(pane: b, column: left, kind: .terminal, cwd: nil))
    // [p0, b] [a]: move b onto the right-hand stack.
    let right = ws.tabs[0].columns[1].id
    ws.apply(.movePane(b, to: .stack(column: right)))
    #expect(ws.tabs[0].columns.map { $0.panes.map(\.id) } == [[panes[0]], [a, b]])
    #expect(ws.tabs[0].focusedPane == b)
    // Then into a new column at the far left.
    ws.apply(.movePane(b, to: .column(tab: tabs[0], index: 0)))
    #expect(ws.tabs[0].columns.map { $0.panes.map(\.id) } == [[b], [panes[0]], [a]])
    // Moving a column's only pane beside itself changes nothing.
    let before = ws
    ws.apply(.movePane(b, to: .column(tab: tabs[0], index: 1)))
    #expect(ws == before)
    // Moving it past its neighbour does move it; its old column goes.
    ws.apply(.movePane(b, to: .column(tab: tabs[0], index: 3)))
    #expect(ws.tabs[0].columns.map { $0.panes.map(\.id) } == [[panes[0]], [a], [b]])
}

@Test func movePaneOntoAnotherTabsStack() {
    var (ws, tabs, panes) = workspace(tabs: 2)
    let b = UUID()
    ws.apply(.newSheet(pane: b, column: ws.tabs[0].columns[0].id, kind: .terminal, cwd: nil))
    ws.apply(.movePane(b, to: .tabStack(tab: tabs[1])))
    #expect(ws.tab(tabs[0])?.panes.map(\.id) == [panes[0]])
    #expect(ws.tab(tabs[1])?.columns.map { $0.panes.map(\.id) } == [[panes[1], b]])
    #expect(ws.selectedTab == tabs[1])
    #expect(ws.tab(tabs[1])?.focusedPane == b)
    // A tab's last pane, moved away, takes the tab with it.
    ws.apply(.movePane(panes[0], to: .tabStack(tab: tabs[1])))
    #expect(ws.tabs.map(\.id) == [tabs[1]])
    #expect(ws.tabs[0].columns[0].panes.map(\.id) == [panes[1], b, panes[0]])
}

@Test func movePaneOntoItsOwnStackRaisesIt() {
    var (ws, tabs, panes) = workspace(tabs: 1)
    let column = ws.tabs[0].columns[0].id
    let b = UUID()
    ws.apply(.newSheet(pane: b, column: column, kind: .terminal, cwd: nil))
    ws.apply(.movePane(panes[0], to: .stack(column: column)))
    #expect(ws.tab(tabs[0])?.columns[0].panes.map(\.id) == [b, panes[0]])
    #expect(ws.tab(tabs[0])?.focusedPane == panes[0])
}

@Test func openingAnEditorFocusesIt() {
    var (ws, tabs, panes) = workspace(tabs: 1)
    let e = UUID()
    ws.apply(.openFile(path: "/tmp/a.swift", kind: .editor, pane: e, tab: UUID(), beside: panes[0]))
    #expect(ws.tab(tabs[0])?.columns.map { $0.panes.map(\.id) } == [[panes[0]], [e]])
    #expect(ws.tab(tabs[0])?.focusedPane == e)
    #expect(ws.pane(e)?.displayTitle == "a.swift")
}

@Test func openFileOnStackPushesOrRaises() {
    var (ws, tabs, panes) = workspace(tabs: 1)
    let column = ws.tabs[0].columns[0].id
    let a = UUID(), b = UUID()
    ws.apply(.openFileOnStack(path: "/tmp/a.txt", kind: .editor, pane: a, column: column))
    ws.apply(.openFileOnStack(path: "/tmp/b.txt", kind: .editor, pane: b, column: column))
    #expect(ws.tab(tabs[0])?.columns[0].panes.map(\.id) == [panes[0], a, b])
    ws.apply(.openFileOnStack(path: "/tmp/a.txt", kind: .editor, pane: UUID(), column: column))
    #expect(ws.tab(tabs[0])?.columns[0].panes.map(\.id) == [panes[0], b, a])
    #expect(ws.tab(tabs[0])?.focusedPane == a)
}

@Test func appearanceSavedBeforeEditorFontLoads() throws {
    let json = #"{"tabs":[],"appearance":{"contrastCorrection":"typical"}}"#
    let ws = try JSONDecoder().decode(Workspace.self, from: Data(json.utf8))
    #expect(ws.appearance.contrastCorrection == .typical)
    #expect(ws.appearance.editorFont == .proportional)
    #expect(ws.appearance.putAwayAfter == 60)
}
