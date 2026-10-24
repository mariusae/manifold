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
    public var window = WindowState()
    public var appearance = Appearance()
    /// The hosts in the order the sidebar shows them, by session id;
    /// ones not in it after, as they come.
    public var hostOrder: [String] = []
    /// Sidebar rows closed by hand (a workspace's), by row id: they stay
    /// closed until opened again.
    public var collapsedRows: [String] = []

    public init() {}

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        selected = try? c.decodeIfPresent(BlockID.self, forKey: .selected)
        window = (try? c.decodeIfPresent(WindowState.self, forKey: .window)) ?? WindowState()
        appearance = (try? c.decodeIfPresent(Appearance.self, forKey: .appearance)) ?? Appearance()
        hostOrder = (try? c.decodeIfPresent([String].self, forKey: .hostOrder)) ?? []
        collapsedRows = (try? c.decodeIfPresent([String].self, forKey: .collapsedRows)) ?? []
    }

    enum CodingKeys: String, CodingKey { case selected, window, appearance, hostOrder, collapsedRows }
}

/// How things look: the theme's fonts, and how terminals are colored.
public struct Appearance: Codable, Equatable, Sendable {
    public var theme: FontTheme = .apple
    public var colorScheme: ColorScheme = .system
    public var contrastCorrection: ContrastCorrection = .deuteranopia
    public var editorFont: EditorFont = .proportional
    /// The color the app's own marks take: the focus ring, selections,
    /// the caret, a pool of light in the backdrop.
    public var tint: Tint = .blue
    /// The custom font theme's typography (used when `theme` is `.custom`).
    public var typography: Typography = .apple
    /// Settings ▸ Typography shown, and the Custom theme offered.
    public var advancedTypography = false

    public init(theme: FontTheme = .apple, colorScheme: ColorScheme = .system,
                contrastCorrection: ContrastCorrection = .deuteranopia,
                editorFont: EditorFont = .proportional, tint: Tint = .blue) {
        self.theme = theme
        self.colorScheme = colorScheme
        self.contrastCorrection = contrastCorrection
        self.editorFont = editorFont
        self.tint = tint
    }

    // Settings saved before a setting existed get its default.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        theme = (try? c.decodeIfPresent(FontTheme.self, forKey: .theme)) ?? .apple
        colorScheme = (try? c.decodeIfPresent(ColorScheme.self, forKey: .colorScheme)) ?? .system
        contrastCorrection = (try? c.decodeIfPresent(ContrastCorrection.self, forKey: .contrastCorrection)) ?? .deuteranopia
        editorFont = (try? c.decodeIfPresent(EditorFont.self, forKey: .editorFont)) ?? .proportional
        tint = (try? c.decodeIfPresent(Tint.self, forKey: .tint)) ?? .blue
        typography = (try? c.decodeIfPresent(Typography.self, forKey: .typography)) ?? .apple
        // On for those who set a custom theme before there was the switch.
        advancedTypography = (try? c.decodeIfPresent(Bool.self, forKey: .advancedTypography)) ?? (theme == .custom)
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
    /// Days after which an unnamed workspace unseen leaves the desk (§4),
    /// for collection; 0 never.
    public var workspaceDriftDays: Int = 3
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
        workspaceDriftDays = (try? c.decodeIfPresent(Int.self, forKey: .workspaceDriftDays)) ?? 3
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

    /// The agent a command line starts, by its program's name ("claude",
    /// "/usr/local/bin/codex --foo", "npx @openai/codex"), if one is known.
    public static func agent(inCommand line: String) -> Agent? {
        let words = line.split(separator: " ").map { String($0).lastPathComponent.lowercased() }
        for w in words.prefix(3) {
            if let a = known.first(where: { w == $0.command || w.hasPrefix($0.command + "-") || w.hasPrefix($0.command + "@") }) { return a }
        }
        return nil
    }

    /// The agent a status names as its app ("claude-code", "codex"), if known.
    public static func agent(namedByApp app: String) -> Agent? {
        let a = app.lowercased()
        return known.first { a == $0.command || a.hasPrefix($0.command + "-") || a == $0.name.lowercased() }
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
    /// Its language servers, as apex's are set (§7.2), over the desk's
    /// table — set in Settings' table for this host: "rust" the command for
    /// a language, "root" a marker whose folder is every language's
    /// workspace root, "rust.root" one language's.
    public var lsp: [String: String] = [:]

    public init(shell: String? = nil, lsp: [String: String] = [:]) {
        self.shell = shell
        self.lsp = lsp
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        shell = try? c.decodeIfPresent(String.self, forKey: .shell)
        lsp = (try? c.decodeIfPresent([String: String].self, forKey: .lsp)) ?? [:]
    }

    enum CodingKeys: String, CodingKey { case shell, lsp }
}

/// The fonts everything is set in, besides the interface's system font,
/// each theme a `Typography`. None are shipped: each is of fonts macOS
/// has, or that are installed.
public enum FontTheme: String, Codable, CaseIterable, Sendable {
    /// System: SF. Apple: Avenir Next, New York, Menlo (the default).
    /// Humanist: Ideal Sans, Chronicle, Menlo, where they're installed.
    /// Custom: the typography set in Settings (`Appearance.typography`).
    case system, apple, humanist, custom

    public init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        // The themes there once were: SF's (Notes) as System, the rest as Humanist.
        switch raw {
        case "custom": self = .custom
        case "apple": self = .apple
        case "system", "notes": self = .system
        default: self = .humanist
        }
    }
}

/// How a font role is set (custom typography): its face, size and how
/// its lines and letters are spaced, and the OpenType features it's set
/// with.
public struct TypeStyle: Codable, Equatable, Sendable {
    /// The family, as the system names it; "" for the system's own (SF,
    /// SF Mono for the monospaced role).
    public var family: String
    /// Points, where the role is set at its usual size (an editor's text,
    /// a preview's paragraphs, a terminal): the rest scale with it.
    public var size: Double
    /// From 100 (thin) to 900 (black), as CSS counts; 400 is regular. The
    /// family's upright face nearest it is used.
    public var weight: Int
    /// Lines apart, as a multiple of the size.
    public var lineHeight: Double
    /// Letter spacing, in thousandths of an em.
    public var tracking: Double
    /// OpenType features, as CSS and Ghostty write them: "ss01, zero,
    /// -liga, cv05=2".
    public var features: String
    /// For reading: the longest line, in characters (0: the page's own).
    public var measure: Double
    /// For reading: the space between paragraphs, in ems.
    public var paragraphSpacing: Double
    /// For reading: headings' weight (the family's face nearest it).
    public var headingWeight: Int

    public init(family: String, size: Double, weight: Int = 400, lineHeight: Double, tracking: Double = 0,
                features: String = "", measure: Double = 0, paragraphSpacing: Double = 1, headingWeight: Int = 700) {
        self.family = family
        self.size = size
        self.weight = weight
        self.lineHeight = lineHeight
        self.tracking = tracking
        self.features = features
        self.measure = measure
        self.paragraphSpacing = paragraphSpacing
        self.headingWeight = headingWeight
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        family = (try? c.decodeIfPresent(String.self, forKey: .family)) ?? ""
        size = (try? c.decodeIfPresent(Double.self, forKey: .size)) ?? 14
        weight = (try? c.decodeIfPresent(Int.self, forKey: .weight)) ?? 400
        lineHeight = (try? c.decodeIfPresent(Double.self, forKey: .lineHeight)) ?? 1.3
        tracking = (try? c.decodeIfPresent(Double.self, forKey: .tracking)) ?? 0
        features = (try? c.decodeIfPresent(String.self, forKey: .features)) ?? ""
        measure = (try? c.decodeIfPresent(Double.self, forKey: .measure)) ?? 0
        paragraphSpacing = (try? c.decodeIfPresent(Double.self, forKey: .paragraphSpacing)) ?? 1
        headingWeight = (try? c.decodeIfPresent(Int.self, forKey: .headingWeight)) ?? 700
    }

    /// The features as tags and values: "-liga" is liga 0, "cv05=2" cv05 2,
    /// "ss01" ss01 1; what isn't a tag of four letters or digits is left out.
    public var featureTags: [(tag: String, value: Int)] {
        features.split(whereSeparator: { $0 == "," || $0 == " " || $0 == "\n" }).compactMap { word in
            var w = word.trimmingCharacters(in: .whitespaces)
            var value = 1
            if w.hasPrefix("-") { value = 0; w.removeFirst() } else if w.hasPrefix("+") { w.removeFirst() }
            if let eq = w.firstIndex(of: "=") {
                guard let v = Int(w[w.index(after: eq)...]) else { return nil }
                value = v
                w = String(w[..<eq])
            }
            guard w.count == 4, w.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber) }) else { return nil }
            return (w, value)
        }
    }
}

/// Custom typography (§3.1): how each of the three font roles is set.
public struct Typography: Codable, Equatable, Sendable {
    public var editing: TypeStyle
    public var reading: TypeStyle
    public var monospaced: TypeStyle

    public init(editing: TypeStyle, reading: TypeStyle, monospaced: TypeStyle) {
        self.editing = editing
        self.reading = reading
        self.monospaced = monospaced
    }

    /// Humanist: Hoefler&Co.'s ScreenSmart faces, set for the screen —
    /// Ideal Sans Book to edit, with lining, tabular figures (its own are
    /// old-style, proportional) and ligatures; Chronicle to read, with
    /// ligatures, its headings a step below Bold (Semibold, or Medium where
    /// the family has none); Menlo for code. Lines: 1.45 to edit, 1.55 to read (a
    /// serif's longer lines and smaller eye want more), 1.3 for code.
    public static let humanist = Typography(
        editing: TypeStyle(family: "Ideal Sans SSm", size: 14.5, weight: 325, lineHeight: 1.45, features: "lnum, tnum, liga"),
        reading: TypeStyle(family: "Chronicle SSm", size: 15.5, lineHeight: 1.55, features: "liga", headingWeight: 600),
        monospaced: TypeStyle(family: "Menlo", size: 13, lineHeight: 1.3, features: "calt"))

    /// Apple: Avenir Next to edit (its tall x-height and long extenders
    /// set at 1.45), New York to read (at 1.5), Menlo for code.
    public static let apple = Typography(
        editing: TypeStyle(family: "Avenir Next", size: 15, lineHeight: 1.45),
        reading: TypeStyle(family: "New York", size: 16, lineHeight: 1.5),
        monospaced: TypeStyle(family: "Menlo", size: 13, lineHeight: 1.3, features: "calt"))

    /// System: SF, and SF Mono.
    public static let system = Typography(
        editing: TypeStyle(family: "", size: 14, lineHeight: 1.45),
        reading: TypeStyle(family: "", size: 16, lineHeight: 1.45),
        monospaced: TypeStyle(family: "", size: 13, lineHeight: 1.3, features: "calt"))
}

/// Light or dark: as the system is, or always one.
public enum ColorScheme: String, Codable, CaseIterable, Sendable {
    case system, light, dark
}

/// The app's tint (§3.1): as the system's accent color, or one of its own —
/// orange as Overcast's.
public enum Tint: String, Codable, CaseIterable, Sendable {
    case system, blue, orange, purple, pink, green, graphite
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
