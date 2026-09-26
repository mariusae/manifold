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

    public init(frame: [Double]? = nil, sidebarPinned: Bool = false) {
        self.frame = frame
        self.sidebarPinned = sidebarPinned
    }
}

/// How terminals are colored.
public struct Appearance: Codable, Equatable, Sendable {
    public var contrastCorrection: ContrastCorrection = .deuteranopia

    public init(contrastCorrection: ContrastCorrection = .deuteranopia) {
        self.contrastCorrection = contrastCorrection
    }
}

/// Automatic contrast correction: text in a program's own colors that
/// doesn't reach WCAG AA against its background is moved in lightness,
/// keeping its hue, until it does -- as a typical viewer sees it, or as both
/// a typical viewer and a deuteranope do.
public enum ContrastCorrection: String, Codable, CaseIterable, Sendable {
    case off, typical, deuteranopia
}

/// A tab is a row of one or more panes, side by side.
public struct Tab: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var customTitle: String?
    public var panes: [Pane]
    public var focusedPane: UUID?
    /// Each pane's share of the width; sums to 1.
    public var fractions: [Double]

    public init(id: UUID = UUID(), panes: [Pane], customTitle: String? = nil) {
        self.id = id
        self.panes = panes
        self.customTitle = customTitle
        self.focusedPane = panes.first?.id
        self.fractions = Tab.equalFractions(panes.count)
    }

    public var title: String {
        if let customTitle, !customTitle.isEmpty { return customTitle }
        let pane = panes.first { $0.id == focusedPane } ?? panes.first
        if let title = pane?.title, !title.isEmpty { return title }
        return pane?.kind.defaultTitle ?? "Tab"
    }

    public var isSplit: Bool { panes.count > 1 }

    static func equalFractions(_ n: Int) -> [Double] {
        n == 0 ? [] : Array(repeating: 1 / Double(n), count: n)
    }
}

public enum PaneKind: String, Codable, Sendable {
    case terminal

    public var defaultTitle: String {
        switch self {
        case .terminal: "Terminal"
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

    public init(id: UUID = UUID(), kind: PaneKind = .terminal, title: String? = nil, cwd: String? = nil) {
        self.id = id
        self.kind = kind
        self.title = title
        self.cwd = cwd
    }
}

/// A change to the workspace, sent by the app to the server. Ids of new tabs
/// and panes are chosen by the sender, so it can refer to them right away.
public enum Command: Codable, Equatable, Sendable {
    case newTab(tab: UUID, pane: UUID, kind: PaneKind, cwd: String?, after: UUID?)
    case newPane(pane: UUID, tab: UUID, at: Int, kind: PaneKind, cwd: String?)
    case selectTab(UUID)
    case focusPane(UUID)
    case closeTab(UUID)
    case closePane(UUID)
    case renameTab(UUID, title: String?)
    case moveTab(UUID, to: Int)
    /// Moves all of one tab's panes into another, at a pane index.
    case mergeTab(UUID, into: UUID, at: Int)
    /// Moves a pane out of its tab into a new tab of its own, right after it.
    case detachPane(UUID, newTab: UUID)
    /// Splits a tab back into one tab per pane.
    case unsplit(UUID)
    case setFractions(UUID, [Double])
    case setPaneTitle(UUID, String?)
    case setPaneCwd(UUID, String?)
    case setWindow(WindowState)
    case setAppearance(Appearance)
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
            let index = min(max(at, 0), tabs[t].panes.count)
            tabs[t].panes.insert(Pane(id: paneID, kind: kind, cwd: cwd), at: index)
            tabs[t].fractions = Tab.equalFractions(tabs[t].panes.count)
            tabs[t].focusedPane = paneID
            selectedTab = tabID

        case let .selectTab(id):
            if tab(id) != nil { selectedTab = id }

        case let .focusPane(id):
            guard let t = tabs.firstIndex(where: { $0.panes.contains { $0.id == id } }) else { return [] }
            tabs[t].focusedPane = id
            selectedTab = tabs[t].id

        case let .closeTab(id):
            guard let t = tabIndex(id) else { return [] }
            let removed = tabs[t].panes.map(\.id)
            removeTab(at: t)
            return removed

        case let .closePane(id):
            guard let t = tabs.firstIndex(where: { $0.panes.contains { $0.id == id } }) else { return [] }
            if tabs[t].panes.count == 1 {
                removeTab(at: t)
            } else {
                let p = tabs[t].panes.firstIndex { $0.id == id }!
                tabs[t].panes.remove(at: p)
                tabs[t].fractions = Tab.equalFractions(tabs[t].panes.count)
                if tabs[t].focusedPane == id {
                    tabs[t].focusedPane = tabs[t].panes[min(p, tabs[t].panes.count - 1)].id
                }
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
            let index = min(max(at, 0), tabs[t].panes.count)
            tabs[t].panes.insert(contentsOf: source.panes, at: index)
            tabs[t].fractions = Tab.equalFractions(tabs[t].panes.count)
            tabs[t].focusedPane = source.panes.first?.id ?? tabs[t].focusedPane
            selectedTab = targetID

        case let .detachPane(paneID, newTabID):
            guard tab(newTabID) == nil,
                  let t = tabs.firstIndex(where: { $0.panes.contains { $0.id == paneID } }),
                  tabs[t].panes.count > 1 else { return [] }
            let p = tabs[t].panes.firstIndex { $0.id == paneID }!
            let pane = tabs[t].panes.remove(at: p)
            tabs[t].fractions = Tab.equalFractions(tabs[t].panes.count)
            if tabs[t].focusedPane == paneID {
                tabs[t].focusedPane = tabs[t].panes[min(p, tabs[t].panes.count - 1)].id
            }
            tabs.insert(Tab(id: newTabID, panes: [pane]), at: t + 1)
            selectedTab = newTabID

        case let .unsplit(id):
            guard let t = tabIndex(id), tabs[t].panes.count > 1 else { return [] }
            let focused = tabs[t].focusedPane
            let keep = tabs[t].panes.first { $0.id == focused } ?? tabs[t].panes[0]
            let others = tabs[t].panes.filter { $0.id != keep.id }
            tabs[t].panes = [keep]
            tabs[t].fractions = [1]
            tabs[t].focusedPane = keep.id
            tabs.insert(contentsOf: others.map { Tab(panes: [$0]) }, at: t + 1)

        case let .setFractions(id, fractions):
            guard let t = tabIndex(id), fractions.count == tabs[t].panes.count,
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
        }
        return []
    }

    private mutating func updatePane(_ id: UUID, _ f: (inout Pane) -> Void) {
        for t in tabs.indices {
            if let p = tabs[t].panes.firstIndex(where: { $0.id == id }) {
                f(&tabs[t].panes[p])
                return
            }
        }
    }

    private mutating func removeTab(at t: Int) {
        let id = tabs[t].id
        tabs.remove(at: t)
        if selectedTab == id {
            selectedTab = tabs.isEmpty ? nil : tabs[min(t, tabs.count - 1)].id
        }
    }
}
