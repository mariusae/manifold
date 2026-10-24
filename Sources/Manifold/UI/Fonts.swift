import AppKit
import ManifoldCore

/// What each theme sets things in, besides the interface's system font:
/// a **monospaced** font for terminals and code; an **editing** font for
/// what's edited (notes, text in an editor, unless it's set fixed width);
/// and a **reading** font for previews, set for reading (a Markdown
/// preview). Most themes edit and read in one face; Lato reads in Tiempos
/// Text.
extension FontTheme {
    var title: String {
        switch self {
        case .notes: "Notes"
        case .tiempos: "Tiempos"
        case .tiemposFira: "Tiempos/Fira"
        case .tiemposJetBrains: "Tiempos/JetBrains"
        case .tiemposAnthrosevka: "Tiempos/Anthrosevka"
        case .mona: "Mona"
        case .recursive: "Recursive"
        case .go: "Go"
        case .lato: "Lato"
        case .system: "System"
        }
    }

    /// The editing font's name.
    var proportionalName: String {
        switch self {
        case .notes: "SF Pro"
        case .tiempos, .tiemposFira, .tiemposJetBrains, .tiemposAnthrosevka: "Tiempos Text"
        case .mona: "Mona Sans"
        case .recursive: "Recursive Sans"
        case .go: "Go"
        case .lato: "Lato"
        case .system: "SF"
        }
    }

    /// The reading font's name: the editing font's, but for Lato's.
    var readingName: String { self == .lato ? "Tiempos Text" : proportionalName }

    var monospacedName: String {
        switch self {
        case .notes: "Menlo"
        case .tiempos: "Menlo"
        case .tiemposFira: "Fira Code"
        case .tiemposJetBrains: "JetBrains Mono"
        case .tiemposAnthrosevka: "Anthrosevka Mono"
        case .mona: "Monaspace Xenon"
        case .recursive: "Recursive Mono"
        case .go: "Go Mono"
        case .lato: "Source Code Pro"
        case .system: "SF Mono"
        }
    }

    /// The Ghostty config's font lines.
    var terminalConfig: String {
        switch self {
        case .mona:
            """
            font-family = Monaspace Xenon
            font-family-italic = Monaspace Radon
            font-feature = calt
            font-feature = ss02
            font-feature = ss03
            font-feature = ss07
            font-feature = ss08
            """
        case .notes: "font-family = Menlo"
        case .tiempos: "font-family = Menlo"
        case .tiemposFira: "font-family = Fira Code"
        case .tiemposJetBrains: "font-family = JetBrains Mono"
        case .tiemposAnthrosevka: "font-family = Anthrosevka Mono"
        case .recursive: "font-family = Recursive Mono Linear Static"
        case .go: "font-family = Go Mono"
        case .lato: "font-family = Source Code Pro"
        // Terminal.app's copy, registered for this process at launch.
        case .system: "font-family = SF Mono"
        }
    }

    /// Monaspace's stylistic sets, as your terminal has them: ss02, ss03,
    /// ss07, ss08. The others take their fonts' defaults.
    private var monospacedFeatures: [String] {
        self == .mona ? ["ss02", "ss03", "ss07", "ss08"] : []
    }

    /// SF Pro's single-story a (ss07), as Notes sets its text: a little
    /// more like handwriting, as legible as ever.
    private var proportionalFeatures: [String] {
        self == .notes ? ["ss07"] : []
    }

    /// The editor's size for each kind: the fonts differ in how big they
    /// look at a size (Tiempos Text is a text face, set a point larger).
    func editorSize(_ kind: EditorFont) -> CGFloat {
        switch (self, kind) {
        case (.mona, .proportional), (.tiempos, .proportional), (.tiemposFira, .proportional), (.tiemposJetBrains, .proportional),
             (.tiemposAnthrosevka, .proportional): 15
        case (.recursive, .proportional), (.lato, .proportional): 14.5
        case (.go, .proportional), (.system, .proportional), (.notes, .proportional): 14
        case (.go, .monospaced), (.notes, .monospaced), (.tiempos, .monospaced), (.tiemposFira, .monospaced), (.tiemposJetBrains, .monospaced),
             (.lato, .monospaced): 13
        // Iosevka's letters are narrow, and look small at a size.
        case (.tiemposAnthrosevka, .monospaced): 14
        case (_, .monospaced): 13.5
        }
    }

    /// The reading font: previews'.
    func readingFont(size: CGFloat) -> NSFont {
        guard self == .lato else { return font(.proportional, size: size) }
        return NSFont(name: "Tiempos Text", size: size) ?? .systemFont(ofSize: size)
    }

    /// The editing font (`.proportional`) or the monospaced one.
    func font(_ kind: EditorFont, size: CGFloat) -> NSFont {
        switch kind {
        case .proportional:
            let name: String? = switch self {
            case .tiempos, .tiemposFira, .tiemposJetBrains, .tiemposAnthrosevka: "Tiempos Text"
            case .mona: "Mona Sans"
            case .recursive: "Recursive Sans Linear Static"
            case .go: "Go"
            case .lato: "Lato"
            case .system, .notes: nil
            }
            let base = name.flatMap { NSFont(name: $0, size: size) } ?? .systemFont(ofSize: size)
            guard !proportionalFeatures.isEmpty else { return base }
            let features = proportionalFeatures.map {
                [kCTFontOpenTypeFeatureTag: $0, kCTFontOpenTypeFeatureValue: 1] as [CFString: Any]
            }
            return NSFont(descriptor: base.fontDescriptor.addingAttributes([.featureSettings: features]), size: size) ?? base
        case .monospaced:
            let name: String? = switch self {
            case .notes: "Menlo"
            case .tiempos: "Menlo"
            case .tiemposFira: "Fira Code"
            case .tiemposJetBrains: "JetBrains Mono"
            case .tiemposAnthrosevka: "Anthrosevka Mono"
            case .mona: "Monaspace Xenon"
            case .recursive: "Recursive Mono Linear Static"
            case .go: "Go Mono"
            case .lato: "Source Code Pro"
            case .system: nil
            }
            guard let name else { return .monospacedSystemFont(ofSize: size, weight: .regular) }
            let features = monospacedFeatures.map {
                [kCTFontOpenTypeFeatureTag: $0, kCTFontOpenTypeFeatureValue: 1] as [CFString: Any]
            }
            let descriptor = NSFontDescriptor(fontAttributes: [.family: name])
                .addingAttributes([.featureSettings: features])
            return NSFont(descriptor: descriptor, size: size) ?? .monospacedSystemFont(ofSize: size, weight: .regular)
        }
    }

    /// The theme the window is set in, for what isn't handed one: a list
    /// of commands, a commit's hash. Kept by the window as it renders.
    nonisolated(unsafe) static var current: FontTheme = .notes

    /// The current theme's code face: wherever code or a command is set.
    static func code(_ size: CGFloat) -> NSFont { current.font(.monospaced, size: size) }
}

/// A view set in `FontTheme.current`, told when it changes.
protocol FollowsFontTheme: AnyObject {
    func fontThemeChanged()
}

extension FontTheme {

    /// CSS for the Markdown preview, set on its root element.
    var css: (sans: String, mono: String, features: String, sansFeatures: String) {
        let features = (["calt"] + monospacedFeatures).map { "\"\($0)\"" }.joined(separator: ", ")
        let sansFeatures = proportionalFeatures.isEmpty ? "normal" : proportionalFeatures.map { "\"\($0)\"" }.joined(separator: ", ")
        return switch self {
        case .notes: ("-apple-system", "Menlo", features, sansFeatures)
        case .tiempos: (#""Tiempos Text""#, "Menlo", features, sansFeatures)
        case .tiemposFira: (#""Tiempos Text""#, #""Fira Code""#, features, sansFeatures)
        case .tiemposJetBrains: (#""Tiempos Text""#, #""JetBrains Mono""#, features, sansFeatures)
        case .tiemposAnthrosevka: (#""Tiempos Text""#, #""Anthrosevka Mono""#, features, sansFeatures)
        case .mona: (#""Mona Sans""#, #""Monaspace Xenon""#, features, sansFeatures)
        case .recursive: (#""Recursive Sans""#, #""Recursive Mono""#, features, sansFeatures)
        case .go: (#""Go""#, #""Go Mono""#, features, sansFeatures)
        // Previews read in the reading font.
        case .lato: (#""Tiempos Text""#, #""Source Code Pro""#, features, sansFeatures)
        case .system: ("-apple-system", "ui-monospace", features, sansFeatures)
        }
    }

    /// Makes Terminal.app's SF Mono available to this process (it isn't a
    /// public font, and can't be bundled); nothing is installed.
    static func registerSystemMono() {
        let dir = URL(fileURLWithPath: "/System/Applications/Utilities/Terminal.app/Contents/Resources/Fonts")
        guard let files = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
        else { return }
        for url in files where url.lastPathComponent.hasPrefix("SF-Mono-") {
            CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil)
        }
    }
}
