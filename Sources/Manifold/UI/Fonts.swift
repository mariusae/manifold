import AppKit
import ManifoldCore

/// What each theme sets things in, besides the interface's system font:
/// a **monospaced** font for terminals and code; an **editing** font for
/// what's edited (notes, text in an editor, unless it's set monospaced);
/// and a **reading** font for previews, set for reading (a Markdown
/// preview). Humanist edits in Lato and reads in Tiempos Text; System is
/// SF, both ways.
extension FontTheme {
    var title: String {
        switch self {
        case .humanist: "Humanist"
        case .system: "System"
        }
    }

    /// The editing font's name.
    var proportionalName: String {
        switch self {
        case .humanist: "Lato"
        case .system: "SF"
        }
    }

    /// The reading font's name.
    var readingName: String {
        switch self {
        case .humanist: "Tiempos Text"
        case .system: "SF"
        }
    }

    var monospacedName: String {
        switch self {
        case .humanist: "Source Code Pro"
        case .system: "SF Mono"
        }
    }

    /// The Ghostty config's font lines.
    var terminalConfig: String {
        switch self {
        case .humanist: "font-family = Source Code Pro"
        // Terminal.app's copy, registered for this process at launch.
        case .system: "font-family = SF Mono"
        }
    }

    /// The editor's size for each kind: the fonts differ in how big they
    /// look at a size.
    func editorSize(_ kind: EditorFont) -> CGFloat {
        switch (self, kind) {
        case (.humanist, .proportional): 14.5
        case (.system, .proportional): 14
        case (.humanist, .monospaced): 13
        case (.system, .monospaced): 13.5
        }
    }

    /// The reading font: previews'.
    func readingFont(size: CGFloat) -> NSFont {
        switch self {
        case .humanist: NSFont(name: "Tiempos Text", size: size) ?? .systemFont(ofSize: size)
        case .system: .systemFont(ofSize: size)
        }
    }

    /// The editing font (`.proportional`) or the monospaced one.
    func font(_ kind: EditorFont, size: CGFloat) -> NSFont {
        switch (self, kind) {
        case (.humanist, .proportional): NSFont(name: "Lato", size: size) ?? .systemFont(ofSize: size)
        case (.system, .proportional): .systemFont(ofSize: size)
        case (.humanist, .monospaced):
            NSFont(descriptor: NSFontDescriptor(fontAttributes: [.family: "Source Code Pro"]), size: size)
                ?? .monospacedSystemFont(ofSize: size, weight: .regular)
        case (.system, .monospaced): .monospacedSystemFont(ofSize: size, weight: .regular)
        }
    }

    /// The theme the window is set in, for what isn't handed one: a list
    /// of commands, a commit's hash. Kept by the window as it renders.
    nonisolated(unsafe) static var current: FontTheme = .humanist

    /// The current theme's code face: wherever code or a command is set.
    static func code(_ size: CGFloat) -> NSFont { current.font(.monospaced, size: size) }
}

/// A view set in `FontTheme.current`, told when it changes.
protocol FollowsFontTheme: AnyObject {
    func fontThemeChanged()
}

extension FontTheme {

    /// CSS for the Markdown preview, set on its root element: it reads in
    /// the reading font, code in the monospaced one.
    var css: (sans: String, mono: String, features: String, sansFeatures: String) {
        switch self {
        case .humanist: (#""Tiempos Text""#, #""Source Code Pro""#, #""calt""#, "normal")
        case .system: ("-apple-system", "ui-monospace", #""calt""#, "normal")
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
