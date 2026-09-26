import Foundation

/// Everything Manifold shows lives here. The server owns the one true copy,
/// persists it, and sends it to the app whenever it changes; the app only
/// renders it and sends back `Command`s.
public struct Workspace: Codable, Equatable, Sendable {
    public var tabs: [Tab] = []
    public var selectedTab: UUID?
    public var window = WindowState()
    public var appearance = Appearance()

    public init() {}

    // State saved by an older version may lack newer fields.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        tabs = try c.decodeIfPresent([Tab].self, forKey: .tabs) ?? []
        selectedTab = try c.decodeIfPresent(UUID.self, forKey: .selectedTab)
        window = try c.decodeIfPresent(WindowState.self, forKey: .window) ?? WindowState()
        appearance = try c.decodeIfPresent(Appearance.self, forKey: .appearance) ?? Appearance()
    }

    public func tab(_ id: UUID?) -> Tab? { tabs.first { $0.id == id } }
    public func tabIndex(_ id: UUID) -> Int? { tabs.firstIndex { $0.id == id } }
    public func tabContaining(pane: UUID) -> Tab? { tabs.first { $0.panes.contains { $0.id == pane } } }
    public var allPanes: [Pane] { tabs.flatMap(\.panes) }
    public func pane(_ id: UUID) -> Pane? { allPanes.first { $0.id == id } }
}

public struct WindowState: Codable, Equatable, Sendable {
    /// x, y, width, height in screen coordinates.
    public var frame: [Double]?
    public var sidebarPinned = false
    /// The sidebar's width, once it's been resized.
    public var sidebarWidth: Double?

    public init(frame: [Double]? = nil, sidebarPinned: Bool = false, sidebarWidth: Double? = nil) {
        self.frame = frame
        self.sidebarPinned = sidebarPinned
        self.sidebarWidth = sidebarWidth
    }
}

/// How terminals are colored.
public struct Appearance: Codable, Equatable, Sendable {
    public var contrastCorrection: ContrastCorrection = .deuteranopia
    public var editorFont: EditorFont = .proportional

    public init(contrastCorrection: ContrastCorrection = .deuteranopia, editorFont: EditorFont = .proportional) {
        self.contrastCorrection = contrastCorrection
        self.editorFont = editorFont
    }

    // Settings saved before a setting existed get its default.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        contrastCorrection = try c.decodeIfPresent(ContrastCorrection.self, forKey: .contrastCorrection) ?? .deuteranopia
        editorFont = try c.decodeIfPresent(EditorFont.self, forKey: .editorFont) ?? .proportional
    }
}

/// The editor's text: Mona Sans, or Monaspace Xenon.
public enum EditorFont: String, Codable, CaseIterable, Sendable {
    case proportional, monospaced
}

/// Automatic contrast correction: text in a program's own colors that
/// doesn't reach WCAG AA against its background is moved in lightness,
/// keeping its hue, until it does -- as a typical viewer sees it, or as both
/// a typical viewer and a deuteranope do.
public enum ContrastCorrection: String, Codable, CaseIterable, Sendable {
    case off, typical, deuteranopia
}

/// A tab is a row of columns, side by side. Each column is a stack of panes,
/// of which only the top one shows.
public struct Tab: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var customTitle: String?
    public var columns: [Column]
    /// The focused pane, always the top of its column.
    public var focusedPane: UUID?
    /// Each column's share of the width; sums to 1.
    public var fractions: [Double]

    public init(id: UUID = UUID(), columns: [Column], customTitle: String? = nil) {
        self.id = id
        self.columns = columns
        self.customTitle = customTitle
        self.focusedPane = columns.first?.top?.id
        self.fractions = Tab.equalFractions(columns.count)
    }

    /// A tab with each pane in a column of its own.
    public init(id: UUID = UUID(), panes: [Pane], customTitle: String? = nil) {
        self.init(id: id, columns: panes.map { Column(panes: [$0]) }, customTitle: customTitle)
    }

    enum CodingKeys: String, CodingKey { case id, customTitle, columns, focusedPane, fractions }
    enum LegacyKeys: String, CodingKey { case panes }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        customTitle = try c.decodeIfPresent(String.self, forKey: .customTitle)
        focusedPane = try c.decodeIfPresent(UUID.self, forKey: .focusedPane)
        if let columns = try c.decodeIfPresent([Column].self, forKey: .columns) {
            self.columns = columns
        } else {
            // Saved before columns were stacks: each pane had a column.
            let legacy = try decoder.container(keyedBy: LegacyKeys.self)
            columns = try legacy.decode([Pane].self, forKey: .panes).map { Column(panes: [$0]) }
        }
        let fractions = try c.decodeIfPresent([Double].self, forKey: .fractions) ?? []
        self.fractions = fractions.count == columns.count ? fractions : Tab.equalFractions(columns.count)
    }

    public var title: String {
        if let customTitle, !customTitle.isEmpty { return customTitle }
        return focused?.displayTitle ?? "Tab"
    }

    /// Every pane, column by column, bottom to top.
    public var panes: [Pane] { columns.flatMap(\.panes) }

    /// The panes that show: the top of each column.
    public var visiblePanes: [Pane] { columns.compactMap(\.top) }

    /// The focused pane, or the first showing when none is.
    public var focused: Pane? { visiblePanes.first { $0.id == focusedPane } ?? visiblePanes.first }

    public var isSplit: Bool { columns.count > 1 }

    /// The column holding a pane.
    public func columnIndex(of pane: UUID) -> Int? {
        columns.firstIndex { $0.panes.contains { $0.id == pane } }
    }

    static func equalFractions(_ n: Int) -> [Double] {
        n == 0 ? [] : Array(repeating: 1 / Double(n), count: n)
    }
}

/// A stack of panes: the last is on top, and the only one that shows.
public struct Column: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var panes: [Pane]

    public init(id: UUID = UUID(), panes: [Pane]) {
        self.id = id
        self.panes = panes
    }

    public var top: Pane? { panes.last }
}

public enum PaneKind: String, Codable, Sendable {
    case terminal
    /// A live preview of a Markdown file.
    case markdown
    /// A text file, being edited.
    case editor

    public var defaultTitle: String {
        switch self {
        case .terminal: "Terminal"
        case .markdown: "Markdown"
        case .editor: "Untitled"
        }
    }
}

/// A pane is one view. For a terminal, its id is also the id of the shell
/// session the server keeps for it.
public struct Pane: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var kind: PaneKind
    /// The title the program in it last set (e.g. by an OSC sequence).
    public var title: String?
    /// The working directory, so a new session can start where the old one was.
    public var cwd: String?
    /// The file shown, for a view of one.
    public var path: String?

    public init(id: UUID = UUID(), kind: PaneKind = .terminal, title: String? = nil, cwd: String? = nil,
                path: String? = nil) {
        self.id = id
        self.kind = kind
        self.title = title
        self.cwd = cwd
        self.path = path
    }

    public var displayTitle: String {
        if let title, !title.isEmpty { return title }
        if let path { return (path as NSString).lastPathComponent }
        return kind.defaultTitle
    }
}

/// A change to the workspace, sent by the app to the server. Ids of new tabs
/// and panes are chosen by the sender, so it can refer to them right away.
public enum Command: Codable, Equatable, Sendable {
    case newTab(tab: UUID, pane: UUID, kind: PaneKind, cwd: String?, after: UUID?)
    /// A new pane, in a new column at a column index.
    case newPane(pane: UUID, tab: UUID, at: Int, kind: PaneKind, cwd: String?)
    /// A new pane, pushed onto a column's stack (the column's id).
    case newSheet(pane: UUID, column: UUID, kind: PaneKind, cwd: String?)
    case selectTab(UUID)
    /// Focuses a pane, raising it to the top of its stack.
    case focusPane(UUID)
    case closeTab(UUID)
    /// Closes a pane; closing the top of a stack pops it.
    case closePane(UUID)
    case renameTab(UUID, title: String?)
    case moveTab(UUID, to: Int)
    /// Moves one tab's columns into another, at a column index.
    case mergeTab(UUID, into: UUID, at: Int)
    /// Pushes one tab's panes onto a column's stack (the column's id).
    case stackTab(UUID, onto: UUID)
    /// Moves a pane (a sheet) somewhere else, focusing it there.
    case movePane(UUID, to: PaneDestination)
    /// Splits a tab into one tab per column.
    case unsplit(UUID)
    case setFractions(UUID, [Double])
    case setPaneTitle(UUID, String?)
    case setPaneCwd(UUID, String?)
    case setWindow(WindowState)
    case setAppearance(Appearance)
    /// Shows a file in a new pane `pane`. Beside the pane `beside` if given:
    /// pushed onto the stack of the column to its right (raising it if the
    /// file is there already), or a new column there. Else in a new tab
    /// `tab` (or a tab showing just that file).
    case openFile(path: String, kind: PaneKind, pane: UUID, tab: UUID, beside: UUID?)
    /// Points a file view at another file (following a link).
    case setPanePath(UUID, String)
    /// Shows a file in a new pane `pane` on top of a column's stack (the
    /// column's id), or raises the pane there showing it already.
    case openFileOnStack(path: String, kind: PaneKind, pane: UUID, column: UUID)
}

/// Where a moved pane goes.
public enum PaneDestination: Codable, Equatable, Sendable {
    /// A new column of its own, at a column index of a tab.
    case column(tab: UUID, index: Int)
    /// The top of a column's stack.
    case stack(column: UUID)
    /// A new tab of its own (with this id), at a tab index.
    case newTab(tab: UUID, index: Int)
    /// The top of a tab's focused stack.
    case tabStack(tab: UUID)
}

extension Workspace {
    /// Applies a command. Returns the panes it removed, whose sessions should
    /// end. Commands that refer to things that no longer exist do nothing.
    @discardableResult
    public mutating func apply(_ command: Command) -> [UUID] {
        switch command {
        case let .newTab(tabID, paneID, kind, cwd, after):
            guard tab(tabID) == nil, pane(paneID) == nil else { return [] }
            let tab = Tab(id: tabID, panes: [Pane(id: paneID, kind: kind, cwd: cwd)])
            let index = after.flatMap(tabIndex).map { $0 + 1 } ?? tabs.count
            tabs.insert(tab, at: index)
            selectedTab = tabID

        case let .newPane(paneID, tabID, at, kind, cwd):
            guard let t = tabIndex(tabID), pane(paneID) == nil else { return [] }
            let index = min(max(at, 0), tabs[t].columns.count)
            tabs[t].columns.insert(Column(panes: [Pane(id: paneID, kind: kind, cwd: cwd)]), at: index)
            tabs[t].fractions = Tab.equalFractions(tabs[t].columns.count)
            tabs[t].focusedPane = paneID
            selectedTab = tabID

        case let .newSheet(paneID, columnID, kind, cwd):
            guard pane(paneID) == nil, let (t, c) = locateColumn(columnID) else { return [] }
            tabs[t].columns[c].panes.append(Pane(id: paneID, kind: kind, cwd: cwd))
            tabs[t].focusedPane = paneID
            selectedTab = tabs[t].id

        case let .selectTab(id):
            if tab(id) != nil { selectedTab = id }

        case let .focusPane(id):
            guard let (t, c) = locate(id) else { return [] }
            raise(id, in: t, c)
            tabs[t].focusedPane = id
            selectedTab = tabs[t].id

        case let .closeTab(id):
            guard let t = tabIndex(id) else { return [] }
            let removed = tabs[t].panes.map(\.id)
            removeTab(at: t)
            return removed

        case let .closePane(id):
            guard let (t, _) = locate(id) else { return [] }
            if tabs[t].panes.count == 1 {
                removeTab(at: t)
            } else {
                _ = take(id, from: t)
            }
            return [id]

        case let .renameTab(id, title):
            guard let t = tabIndex(id) else { return [] }
            let trimmed = title?.trimmingCharacters(in: .whitespacesAndNewlines)
            tabs[t].customTitle = trimmed?.isEmpty == false ? trimmed : nil

        case let .moveTab(id, to):
            guard let t = tabIndex(id) else { return [] }
            let tab = tabs.remove(at: t)
            tabs.insert(tab, at: min(max(to, 0), tabs.count))

        case let .mergeTab(sourceID, targetID, at):
            guard sourceID != targetID, let s = tabIndex(sourceID), tabIndex(targetID) != nil else { return [] }
            let source = tabs.remove(at: s)
            let t = tabIndex(targetID)!
            let index = min(max(at, 0), tabs[t].columns.count)
            tabs[t].columns.insert(contentsOf: source.columns, at: index)
            tabs[t].fractions = Tab.equalFractions(tabs[t].columns.count)
            tabs[t].focusedPane = source.focused?.id ?? tabs[t].focusedPane
            selectedTab = targetID

        case let .stackTab(sourceID, columnID):
            guard let s = tabIndex(sourceID),
                  let t = tabs.firstIndex(where: { $0.columns.contains { $0.id == columnID } }),
                  s != t else { return [] }
            let source = tabs.remove(at: s)
            let t2 = tabs.firstIndex { $0.columns.contains { $0.id == columnID } }!
            let c = tabs[t2].columns.firstIndex { $0.id == columnID }!
            // The source's focused pane goes on top.
            let focused = source.focused
            var pushed = source.panes.filter { $0.id != focused?.id }
            if let focused { pushed.append(focused) }
            tabs[t2].columns[c].panes.append(contentsOf: pushed)
            tabs[t2].focusedPane = focused?.id ?? tabs[t2].focusedPane
            selectedTab = tabs[t2].id

        case let .movePane(paneID, destination):
            move(paneID, to: destination)

        case let .unsplit(id):
            guard let t = tabIndex(id), tabs[t].columns.count > 1 else { return [] }
            let keep = tabs[t].focusedPane.flatMap { tabs[t].columnIndex(of: $0) } ?? 0
            let others = tabs[t].columns.enumerated().filter { $0.offset != keep }.map(\.element)
            tabs[t].columns = [tabs[t].columns[keep]]
            tabs[t].fractions = [1]
            tabs[t].focusedPane = tabs[t].columns[0].top?.id
            tabs.insert(contentsOf: others.map { Tab(columns: [$0]) }, at: t + 1)

        case let .setFractions(id, fractions):
            guard let t = tabIndex(id), fractions.count == tabs[t].columns.count,
                  fractions.allSatisfy({ $0 > 0 }) else { return [] }
            let sum = fractions.reduce(0, +)
            tabs[t].fractions = fractions.map { $0 / sum }

        case let .setPaneTitle(id, title):
            updatePane(id) { $0.title = title }

        case let .setPaneCwd(id, cwd):
            updatePane(id) { $0.cwd = cwd }

        case let .setWindow(window):
            self.window = window

        case let .setAppearance(appearance):
            self.appearance = appearance

        case let .openFile(path, kind, paneID, tabID, beside):
            if let beside, let (t, c) = locate(beside) {
                selectedTab = tabs[t].id
                let right = c + 1
                var opened = paneID
                if right < tabs[t].columns.count {
                    if let existing = tabs[t].columns[right].panes.first(where: { $0.kind == kind && $0.path == path }) {
                        raise(existing.id, in: t, right)
                        opened = existing.id
                    } else if pane(paneID) == nil {
                        tabs[t].columns[right].panes.append(Pane(id: paneID, kind: kind, path: path))
                    }
                } else if pane(paneID) == nil {
                    tabs[t].columns.append(Column(panes: [Pane(id: paneID, kind: kind, path: path)]))
                    tabs[t].fractions = Tab.equalFractions(tabs[t].columns.count)
                }
                // A file to edit takes the keyboard; a preview leaves it be.
                if kind == .editor { tabs[t].focusedPane = opened }
                return []
            }
            if let existing = tabs.first(where: { $0.panes.count == 1 && $0.panes[0].kind == kind && $0.panes[0].path == path }) {
                selectedTab = existing.id
                return []
            }
            guard tab(tabID) == nil, pane(paneID) == nil else { return [] }
            let index = selectedTab.flatMap(tabIndex).map { $0 + 1 } ?? tabs.count
            tabs.insert(Tab(id: tabID, panes: [Pane(id: paneID, kind: kind, path: path)]), at: index)
            selectedTab = tabID

        case let .setPanePath(id, path):
            updatePane(id) {
                $0.path = path
                $0.title = nil
            }

        case let .openFileOnStack(path, kind, paneID, columnID):
            guard let (t, c) = locateColumn(columnID) else { return [] }
            if let existing = tabs[t].columns[c].panes.first(where: { $0.kind == kind && $0.path == path }) {
                raise(existing.id, in: t, c)
                tabs[t].focusedPane = existing.id
            } else {
                guard pane(paneID) == nil else { return [] }
                tabs[t].columns[c].panes.append(Pane(id: paneID, kind: kind, path: path))
                tabs[t].focusedPane = paneID
            }
            selectedTab = tabs[t].id
        }
        return []
    }

    private mutating func move(_ paneID: UUID, to destination: PaneDestination) {
        guard let (st, sc) = locate(paneID) else { return }
        let sourceTab = tabs[st].id
        let sourceColumn = tabs[st].columns[sc].id
        let alone = tabs[st].panes.count == 1
        let lastInColumn = tabs[st].columns[sc].panes.count == 1

        // Work out where it goes before taking it out, as that can remove
        // its column or tab.
        enum Place { case column(UUID, before: UUID?), stack(UUID), tab(UUID, before: UUID?) }
        let place: Place
        switch destination {
        case let .column(tabID, index):
            guard let t = tabIndex(tabID) else { return }
            // Already a column of its own, going beside itself: no change.
            if tabID == sourceTab, lastInColumn, index == sc || index == sc + 1 { return }
            let before = index < tabs[t].columns.count ? tabs[t].columns[index].id : nil
            place = .column(tabID, before: before)
        case let .stack(columnID):
            guard locateColumn(columnID) != nil else { return }
            if columnID == sourceColumn {
                // Onto its own stack: to the top.
                apply(.focusPane(paneID))
                return
            }
            place = .stack(columnID)
        case let .newTab(tabID, index):
            guard tab(tabID) == nil else { return }
            if alone { return } // It's a tab of its own already.
            place = .tab(tabID, before: index < tabs.count ? tabs[index].id : nil)
        case let .tabStack(tabID):
            guard let t = tabIndex(tabID), tabID != sourceTab,
                  let column = tabs[t].focusedPane.flatMap({ tabs[t].columnIndex(of: $0) }) ?? (tabs[t].columns.isEmpty ? nil : 0)
            else { return }
            place = .stack(tabs[t].columns[column].id)
        }

        let pane: Pane
        if alone {
            pane = tabs[st].panes[0]
            removeTab(at: st)
        } else {
            pane = take(paneID, from: st)!
        }

        switch place {
        case let .column(tabID, before):
            let t = tabIndex(tabID)!
            let index = before.flatMap { b in tabs[t].columns.firstIndex { $0.id == b } } ?? tabs[t].columns.count
            tabs[t].columns.insert(Column(panes: [pane]), at: index)
            tabs[t].fractions = Tab.equalFractions(tabs[t].columns.count)
            tabs[t].focusedPane = pane.id
            selectedTab = tabID
        case let .stack(columnID):
            let (t, c) = locateColumn(columnID)!
            tabs[t].columns[c].panes.append(pane)
            tabs[t].focusedPane = pane.id
            selectedTab = tabs[t].id
        case let .tab(tabID, before):
            let index = before.flatMap(tabIndex) ?? tabs.count
            tabs.insert(Tab(id: tabID, panes: [pane]), at: index)
            selectedTab = tabID
        }
    }

    /// The tab and column index of a column.
    private func locateColumn(_ id: UUID) -> (Int, Int)? {
        for t in tabs.indices {
            if let c = tabs[t].columns.firstIndex(where: { $0.id == id }) { return (t, c) }
        }
        return nil
    }

    /// The tab and column holding a pane.
    private func locate(_ pane: UUID) -> (Int, Int)? {
        for t in tabs.indices {
            if let c = tabs[t].columnIndex(of: pane) { return (t, c) }
        }
        return nil
    }

    /// Moves a pane to the top of its stack.
    private mutating func raise(_ pane: UUID, in t: Int, _ c: Int) {
        guard let p = tabs[t].columns[c].panes.firstIndex(where: { $0.id == pane }) else { return }
        let moved = tabs[t].columns[c].panes.remove(at: p)
        tabs[t].columns[c].panes.append(moved)
    }

    /// Takes a pane out of a tab that has others, dropping its column if it
    /// was the column's last, and moving focus off it.
    private mutating func take(_ pane: UUID, from t: Int) -> Pane? {
        guard let c = tabs[t].columnIndex(of: pane) else { return nil }
        let p = tabs[t].columns[c].panes.firstIndex { $0.id == pane }!
        let removed = tabs[t].columns[c].panes.remove(at: p)
        var nextFocus = tabs[t].columns[c].top?.id
        if tabs[t].columns[c].panes.isEmpty {
            tabs[t].columns.remove(at: c)
            tabs[t].fractions = Tab.equalFractions(tabs[t].columns.count)
            nextFocus = tabs[t].columns[min(c, tabs[t].columns.count - 1)].top?.id
        }
        if tabs[t].focusedPane == pane { tabs[t].focusedPane = nextFocus }
        return removed
    }

    private mutating func updatePane(_ id: UUID, _ f: (inout Pane) -> Void) {
        guard let (t, c) = locate(id), let p = tabs[t].columns[c].panes.firstIndex(where: { $0.id == id }) else { return }
        f(&tabs[t].columns[c].panes[p])
    }

    private mutating func removeTab(at t: Int) {
        let id = tabs[t].id
        tabs.remove(at: t)
        if selectedTab == id {
            selectedTab = tabs.isEmpty ? nil : tabs[min(t, tabs.count - 1)].id
        }
    }
}
