import Foundation

extension KeyedDecodingContainer {
    /// What's under `key` decoded onto `value`, if it's there and reads;
    /// else `value` left as it was — its default, for what was saved
    /// before it existed, or in a form since gone.
    func opt<T: Decodable>(_ value: inout T, _ key: Key) {
        if let v = try? decodeIfPresent(T.self, forKey: key) { value = v }
    }
}

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
        self.init()
        c.opt(&selected, .selected)
        c.opt(&window, .window)
        c.opt(&appearance, .appearance)
        c.opt(&hostOrder, .hostOrder)
        c.opt(&collapsedRows, .collapsedRows)
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
    public var tint: Tint = .theme
    /// The colour theme, by its id: every colour the app draws in.
    public var colorTheme: String = "paper"
    /// The custom font theme's typography (used when `theme` is `.custom`).
    public var typography: Typography = .apple
    /// Settings ▸ Typography shown, and the Custom theme offered.
    public var advancedTypography = false

    public init(theme: FontTheme = .apple, colorScheme: ColorScheme = .system,
                contrastCorrection: ContrastCorrection = .deuteranopia,
                editorFont: EditorFont = .proportional, tint: Tint = .theme, colorTheme: String = "paper") {
        self.theme = theme
        self.colorScheme = colorScheme
        self.contrastCorrection = contrastCorrection
        self.editorFont = editorFont
        self.tint = tint
        self.colorTheme = colorTheme
    }

    // Settings saved before a setting existed get its default.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init()
        c.opt(&theme, .theme)
        c.opt(&colorScheme, .colorScheme)
        c.opt(&contrastCorrection, .contrastCorrection)
        c.opt(&editorFont, .editorFont)
        c.opt(&tint, .tint)
        c.opt(&colorTheme, .colorTheme)
        c.opt(&typography, .typography)
        // On for those who set a custom theme before there was the switch.
        advancedTypography = theme == .custom
        c.opt(&advancedTypography, .advancedTypography)
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
    /// What kept things before the spaces were the only roots has been
    /// brought into them (§4): done once, not at every collection — a
    /// named space removed by hand was put back on the desk each time.
    public var rootsSettled: Bool = false

    public init() {}

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init()
        c.opt(&collectAfterMinutes, .collectAfterMinutes)
        c.opt(&terminalDormantAfterHours, .terminalDormantAfterHours)
        c.opt(&textHistoryDays, .textHistoryDays)
        c.opt(&terminalHistoryDays, .terminalHistoryDays)
        c.opt(&undoDepth, .undoDepth)
        c.opt(&rootsSettled, .rootsSettled)
        c.opt(&languageServers, .languageServers)
        c.opt(&agentCommand, .agentCommand)
        c.opt(&copyOnSelect, .copyOnSelect)
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
    /// Variables its server sets in what it starts (§8.6). Nil: not said
    /// — a client from before them, whose preferences leave them as they are.
    public var environment: [EnvironmentVariable]?

    public init(shell: String? = nil, lsp: [String: String] = [:], environment: [EnvironmentVariable]? = nil) {
        self.shell = shell
        self.lsp = lsp
        self.environment = environment
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init()
        c.opt(&shell, .shell)
        c.opt(&lsp, .lsp)
        c.opt(&environment, .environment)
    }

    enum CodingKeys: String, CodingKey { case shell, lsp, environment }
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
    /// The face bold is set in, by its name in the family ("Semibold"),
    /// where the usual — the face some 300 heavier — is too heavy, or the
    /// family's weights don't say (Ideal's run 275 to 400); "" for that.
    public var boldFace: String

    public init(family: String, size: Double, weight: Int = 400, lineHeight: Double, tracking: Double = 0,
                features: String = "", measure: Double = 0, paragraphSpacing: Double = 1, headingWeight: Int = 700, boldFace: String = "") {
        self.family = family
        self.size = size
        self.weight = weight
        self.lineHeight = lineHeight
        self.tracking = tracking
        self.features = features
        self.measure = measure
        self.paragraphSpacing = paragraphSpacing
        self.headingWeight = headingWeight
        self.boldFace = boldFace
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(family: "", size: 14, lineHeight: 1.3)
        c.opt(&family, .family)
        c.opt(&size, .size)
        c.opt(&weight, .weight)
        c.opt(&lineHeight, .lineHeight)
        c.opt(&tracking, .tracking)
        c.opt(&features, .features)
        c.opt(&measure, .measure)
        c.opt(&paragraphSpacing, .paragraphSpacing)
        c.opt(&headingWeight, .headingWeight)
        c.opt(&boldFace, .boldFace)
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

/// Custom typography (§3.1): how each of the four font roles is set.
public struct Typography: Codable, Equatable, Sendable {
    public var editing: TypeStyle
    public var reading: TypeStyle
    public var monospaced: TypeStyle
    /// Beside the monospaced: a proportional face for what's said about
    /// code — its comments. Its size is where the monospaced is set at 13;
    /// its lines are the monospaced's.
    public var technical: TypeStyle

    public init(editing: TypeStyle, reading: TypeStyle, monospaced: TypeStyle, technical: TypeStyle) {
        self.editing = editing
        self.reading = reading
        self.monospaced = monospaced
        self.technical = technical
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        editing = try c.decode(TypeStyle.self, forKey: .editing)
        reading = try c.decode(TypeStyle.self, forKey: .reading)
        monospaced = try c.decode(TypeStyle.self, forKey: .monospaced)
        // Kept before there was one: the system's, beside whatever's monospaced.
        technical = (try? c.decodeIfPresent(TypeStyle.self, forKey: .technical)) ?? Self.system.technical
    }

    /// Humanist: Hoefler&Co.'s ScreenSmart faces, set for the screen —
    /// Ideal Sans Book to edit, with lining, tabular figures (its own are
    /// old-style, proportional) and ligatures; Chronicle to read, with
    /// ligatures, its headings a step below Bold (Semibold, or Medium where
    /// the family has none); Menlo for code, and Whitney beside it, made for
    /// information, at 13.5 to meet Menlo's x-height, in its Medium (its
    /// weights run 300 to 450: Book 325, Medium 350, Bold 400 — so asked
    /// for at 400 it was Bold; SF where it isn't installed). Lines: 1.45 to edit, 1.55 to read (a
    /// serif's longer lines and smaller eye want more), 1.3 for code.
    public static let humanist = Typography(
        editing: TypeStyle(family: "Ideal Sans SSm", size: 14.5, weight: 325, lineHeight: 1.45, features: "lnum, tnum, liga", boldFace: "Semibold"),
        reading: TypeStyle(family: "Chronicle SSm", size: 15.5, lineHeight: 1.55, features: "liga", headingWeight: 600),
        monospaced: TypeStyle(family: "Menlo", size: 13, lineHeight: 1.3, features: "calt"),
        technical: TypeStyle(family: "Whitney SSm", size: 13.5, weight: 350, lineHeight: 1.3, features: "lnum"))

    /// Apple: Avenir Next to edit (its tall x-height and long extenders
    /// set at 1.45), New York to read (at 1.5), Menlo for code, and Lucida
    /// Grande beside it, at 13.5 to meet Menlo's x-height.
    public static let apple = Typography(
        editing: TypeStyle(family: "Avenir Next", size: 15, lineHeight: 1.45),
        reading: TypeStyle(family: "New York", size: 16, lineHeight: 1.5),
        monospaced: TypeStyle(family: "Menlo", size: 13, lineHeight: 1.3, features: "calt"),
        technical: TypeStyle(family: "Lucida Grande", size: 13.5, lineHeight: 1.3))

    /// System: SF, and SF Mono with SF beside it (as Xcode has them).
    public static let system = Typography(
        editing: TypeStyle(family: "", size: 14, lineHeight: 1.45),
        reading: TypeStyle(family: "", size: 16, lineHeight: 1.45),
        monospaced: TypeStyle(family: "", size: 13, lineHeight: 1.3, features: "calt"),
        technical: TypeStyle(family: "", size: 13, lineHeight: 1.3))
}

/// Light or dark: as the system is, or always one.
public enum ColorScheme: String, Codable, CaseIterable, Sendable {
    case system, light, dark
}

/// The app's tint (§3.1): as the system's accent color, or one of its own —
/// orange as Overcast's.
public enum Tint: String, Codable, CaseIterable, Sendable {
    /// The colour theme's own accent (a terminal's caret and selection
    /// its palette's); any other is set over the theme's, everywhere.
    case theme
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
