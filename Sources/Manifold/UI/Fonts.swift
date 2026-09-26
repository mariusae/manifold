import AppKit
import ManifoldCore

/// What each theme sets things in: terminals in its fixed-width font, the
/// editor in either, and Markdown in its proportional font with code in
/// the fixed-width one.
extension FontTheme {
    var title: String {
        switch self {
        case .mona: "Mona"
        case .recursive: "Recursive"
        case .go: "Go"
        case .system: "System"
        }
    }

    var proportionalName: String {
        switch self {
        case .mona: "Mona Sans"
        case .recursive: "Recursive Sans"
        case .go: "Go"
        case .system: "SF"
        }
    }

    var monospacedName: String {
        switch self {
        case .mona: "Monaspace Xenon"
        case .recursive: "Recursive Mono"
        case .go: "Go Mono"
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
        case .recursive: "font-family = Recursive Mono Linear Static"
        case .go: "font-family = Go Mono"
        // Terminal.app's copy, registered for this process at launch.
        case .system: "font-family = SF Mono"
        }
    }

    /// Monaspace's stylistic sets, as your terminal has them: ss02, ss03,
    /// ss07, ss08. The others take their fonts' defaults.
    private var monospacedFeatures: [String] {
        self == .mona ? ["ss02", "ss03", "ss07", "ss08"] : []
    }

    /// The editor's size for each kind: the fonts differ in how big they
    /// look at a size.
    func editorSize(_ kind: EditorFont) -> CGFloat {
        switch (self, kind) {
        case (.mona, .proportional): 15
        case (.recursive, .proportional): 14.5
        case (.go, .proportional), (.system, .proportional): 14
        case (.go, .monospaced): 13
        case (_, .monospaced): 13.5
        }
    }

    func font(_ kind: EditorFont, size: CGFloat) -> NSFont {
        switch kind {
        case .proportional:
            let name: String? = switch self {
            case .mona: "Mona Sans"
            case .recursive: "Recursive Sans Linear Static"
            case .go: "Go"
            case .system: nil
            }
            return name.flatMap { NSFont(name: $0, size: size) } ?? .systemFont(ofSize: size)
        case .monospaced:
            let name: String? = switch self {
            case .mona: "Monaspace Xenon"
            case .recursive: "Recursive Mono Linear Static"
            case .go: "Go Mono"
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

    /// CSS for the Markdown preview, set on its root element.
    var css: (sans: String, mono: String, features: String) {
        let features = (["calt"] + monospacedFeatures).map { "\"\($0)\"" }.joined(separator: ", ")
        return switch self {
        case .mona: (#""Mona Sans""#, #""Monaspace Xenon""#, features)
        case .recursive: (#""Recursive Sans""#, #""Recursive Mono""#, features)
        case .go: (#""Go""#, #""Go Mono""#, features)
        case .system: ("-apple-system", "ui-monospace", features)
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
