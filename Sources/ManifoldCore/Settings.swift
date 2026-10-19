import Foundation

/// The window: where it is, and the sidebar.
public struct WindowState: Codable, Equatable, Sendable {
    /// x, y, width, height in screen coordinates.
    public var frame: [Double]?
    public var sidebarPinned = false
    /// The sidebar's width, once it's been resized.
    public var sidebarWidth: Double?
    /// Which organization the sidebar shows (§3.6): desk, files, links, time.
    public var organization: String?

    public init(frame: [Double]? = nil, sidebarPinned: Bool = false, sidebarWidth: Double? = nil) {
        self.frame = frame
        self.sidebarPinned = sidebarPinned
        self.sidebarWidth = sidebarWidth
    }
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
    /// Minutes after which a placement unseen (and not held) leaves an
    /// unnamed arrangement; 0 never.
    public var collectAfterMinutes: Int = 60
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

    public init() {}

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        collectAfterMinutes = (try? c.decodeIfPresent(Int.self, forKey: .collectAfterMinutes)) ?? 60
        terminalDormantAfterHours = (try? c.decodeIfPresent(Int.self, forKey: .terminalDormantAfterHours)) ?? 8
        textHistoryDays = (try? c.decodeIfPresent(Int.self, forKey: .textHistoryDays)) ?? 0
        terminalHistoryDays = (try? c.decodeIfPresent(Int.self, forKey: .terminalHistoryDays)) ?? 30
        undoDepth = (try? c.decodeIfPresent(Int.self, forKey: .undoDepth)) ?? 0
        languageServers = (try? c.decodeIfPresent([LanguageServerConfig].self, forKey: .languageServers)) ?? LanguageServerConfig.defaults
        agentCommand = (try? c.decodeIfPresent(String.self, forKey: .agentCommand)) ?? "claude"
    }
}

/// The fonts everything is set in, a proportional one and a fixed-width
/// one, chosen together: SF Pro (with its single-story a, as Notes sets
/// it) and Menlo; Mona Sans and Monaspace; Recursive Sans and Mono; Go
/// and Go Mono; or SF and SF Mono. Fixed, not configurable.
public enum FontTheme: String, Codable, CaseIterable, Sendable {
    case notes, mona, recursive, go, system
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
