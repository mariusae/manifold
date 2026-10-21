import Foundation

/// The window: where it is, and the sidebar.
public struct WindowState: Codable, Equatable, Sendable {
    /// x, y, width, height in screen coordinates.
    public var frame: [Double]?
    /// The sidebar is the spine of the window (§3.6): beside the surface
    /// unless set to slide out over it.
    public var sidebarPinned = true
    /// The sidebar's width, once it's been resized.
    public var sidebarWidth: Double?
    /// Which organization the sidebar shows (§3.6): desk, files, links, time.
    public var organization: String?

    public init(frame: [Double]? = nil, sidebarPinned: Bool = true, sidebarWidth: Double? = nil) {
        self.frame = frame
        self.sidebarPinned = sidebarPinned
        self.sidebarWidth = sidebarWidth
    }
}

/// What is this client's alone (§8.2): which workspace it shows, the
/// order it settled on them, its window, and how things look. Kept in a
/// file beside the hosts file, not in any host's log.
public struct ClientState: Codable, Equatable, Sendable {
    public var selected: BlockID?
    /// Workspaces most recently settled on first (⌃⇥'s order).
    public var settled: [BlockID] = []
    public var window = WindowState()
    public var appearance = Appearance()
    /// The hosts in the order the sidebar shows them, by session id;
    /// ones not in it after, as they come.
    public var hostOrder: [String] = []

    public init() {}

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        selected = try? c.decodeIfPresent(BlockID.self, forKey: .selected)
        settled = (try? c.decodeIfPresent([BlockID].self, forKey: .settled)) ?? []
        window = (try? c.decodeIfPresent(WindowState.self, forKey: .window)) ?? WindowState()
        appearance = (try? c.decodeIfPresent(Appearance.self, forKey: .appearance)) ?? Appearance()
        hostOrder = (try? c.decodeIfPresent([String].self, forKey: .hostOrder)) ?? []
    }

    enum CodingKeys: String, CodingKey { case selected, settled, window, appearance, hostOrder }
}

/// How things look: the theme's fonts, and how terminals are colored.
public struct Appearance: Codable, Equatable, Sendable {
    public var theme: FontTheme = .notes
    public var colorScheme: ColorScheme = .system
    public var contrastCorrection: ContrastCorrection = .deuteranopia
    public var editorFont: EditorFont = .proportional

    public init(theme: FontTheme = .notes, colorScheme: ColorScheme = .system,
                contrastCorrection: ContrastCorrection = .deuteranopia,
                editorFont: EditorFont = .proportional) {
        self.theme = theme
        self.colorScheme = colorScheme
        self.contrastCorrection = contrastCorrection
        self.editorFont = editorFont
    }

    // Settings saved before a setting existed get its default.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        theme = (try? c.decodeIfPresent(FontTheme.self, forKey: .theme)) ?? .notes
        colorScheme = (try? c.decodeIfPresent(ColorScheme.self, forKey: .colorScheme)) ?? .system
        contrastCorrection = (try? c.decodeIfPresent(ContrastCorrection.self, forKey: .contrastCorrection)) ?? .deuteranopia
        editorFont = (try? c.decodeIfPresent(EditorFont.self, forKey: .editorFont)) ?? .proportional
    }
}

/// Policy: every number the core reads about when things are collected and
/// how much history is kept. None of these is a constant in the model.
public struct Settings: Codable, Equatable, Sendable {
    /// Minutes a block stays once nothing reaches it (§4) before it is
    /// collected; 0 never.
    public var collectAfterMinutes: Int = 30
    /// Hours after which a terminal off screen with an idle shell goes
    /// dormant (its shell ended, its transcript kept); 0 never.
    public var terminalDormantAfterHours: Int = 8
    /// Days of full-resolution history kept for text; 0 forever.
    public var textHistoryDays: Int = 0
    /// Days of transcript kept for terminals.
    public var terminalHistoryDays: Int = 30
    /// Undo depth kept per text block; 0 unlimited.
    public var undoDepth: Int = 0
    /// Language servers, by language (§7.1): the defaults, as changed.
    public var languageServers: [LanguageServerConfig] = LanguageServerConfig.defaults
    /// The command an agent block runs.
    public var agentCommand: String = "claude"
    /// A terminal's selection goes to the clipboard as it's made (not
    /// in full screen).
    public var copyOnSelect: Bool = true

    public init() {}

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        collectAfterMinutes = (try? c.decodeIfPresent(Int.self, forKey: .collectAfterMinutes)) ?? 30
        terminalDormantAfterHours = (try? c.decodeIfPresent(Int.self, forKey: .terminalDormantAfterHours)) ?? 8
        textHistoryDays = (try? c.decodeIfPresent(Int.self, forKey: .textHistoryDays)) ?? 0
        terminalHistoryDays = (try? c.decodeIfPresent(Int.self, forKey: .terminalHistoryDays)) ?? 30
        undoDepth = (try? c.decodeIfPresent(Int.self, forKey: .undoDepth)) ?? 0
        languageServers = (try? c.decodeIfPresent([LanguageServerConfig].self, forKey: .languageServers)) ?? LanguageServerConfig.defaults
        agentCommand = (try? c.decodeIfPresent(String.self, forKey: .agentCommand)) ?? "claude"
        copyOnSelect = (try? c.decodeIfPresent(Bool.self, forKey: .copyOnSelect)) ?? true
    }
}

/// The coding agents Manifold knows to look for on a host, by the
/// command that starts each, in the order they're offered.
public enum AgentCatalog {
    public struct Agent: Equatable, Sendable {
        public let command: String
        public let name: String
    }

    public static let known: [Agent] = [
        Agent(command: "claude", name: "Claude Code"),
        Agent(command: "codex", name: "Codex"),
        Agent(command: "pi", name: "Pi"),
        Agent(command: "muse", name: "Muse"),
        Agent(command: "gemini", name: "Gemini CLI"),
        Agent(command: "opencode", name: "opencode"),
        Agent(command: "amp", name: "Amp"),
        Agent(command: "cursor-agent", name: "Cursor Agent"),
        Agent(command: "goose", name: "Goose"),
        Agent(command: "aider", name: "Aider"),
    ]

    /// The known agents among commands a host has, in the catalog's order.
    public static func agents(among commands: [String]) -> [Agent] {
        known.filter { commands.contains($0.command) }
    }
}

/// A host's own preferences, kept in its desk: every Mac attached to it
/// sees and sets the same ones, and its server acts on them.
public struct HostPreferences: Codable, Equatable, Sendable {
    /// The shell new terminals start (a name on the host's PATH, or a
    /// path); nil for the user's login shell.
    public var shell: String?

    public init(shell: String? = nil) {
        self.shell = shell
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        shell = try? c.decodeIfPresent(String.self, forKey: .shell)
    }

    enum CodingKeys: String, CodingKey { case shell }
}

/// The fonts everything is set in, a proportional one and a fixed-width
/// one, chosen together: SF Pro (with its single-story a, as Notes sets
/// it) and Menlo; Tiempos Text and Menlo, Fira Code or JetBrains Mono;
/// Mona Sans and Monaspace; Recursive Sans and Mono; Go and Go Mono; or
/// SF and SF Mono. Fixed, not configurable.
public enum FontTheme: String, Codable, CaseIterable, Sendable {
    case notes, tiempos, tiemposFira, tiemposJetBrains, mona, recursive, go, system
}

/// Light or dark: as the system is, or always one.
public enum ColorScheme: String, Codable, CaseIterable, Sendable {
    case system, light, dark
}

/// The editor's text: the theme's proportional font, or its fixed-width one.
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
