import AppKit
import ManifoldCore

/// What each theme sets things in, besides the interface's system font:
/// a **monospaced** font for terminals and code; an **editing** font for
/// what's edited (notes, text in an editor, unless it's set monospaced);
/// and a **reading** font for previews, set for reading (a Markdown
/// preview). Humanist edits in Lato and reads in Tiempos Text; System is
/// SF, both ways; Custom is what Settings ▸ Typography sets (`Typography`):
/// each role's face, size, line height, letter spacing and features.
extension FontTheme {
    var title: String {
        switch self {
        case .humanist: "Humanist"
        case .system: "System"
        case .custom: "Custom"
        }
    }

    /// The editing font's name.
    var proportionalName: String {
        switch self {
        case .humanist: "Lato"
        case .system: "SF"
        case .custom: Self.typography.editing.displayName(.editing)
        }
    }

    /// The reading font's name.
    var readingName: String {
        switch self {
        case .humanist: "Tiempos Text"
        case .system: "SF"
        case .custom: Self.typography.reading.displayName(.reading)
        }
    }

    var monospacedName: String {
        switch self {
        case .humanist: "Source Code Pro"
        case .system: "SF Mono"
        case .custom: Self.typography.monospaced.displayName(.monospaced)
        }
    }

    /// The Ghostty config's font lines.
    var terminalConfig: String {
        switch self {
        case .humanist: "font-family = Source Code Pro"
        // Terminal.app's copy, registered for this process at launch.
        case .system: "font-family = SF Mono"
        case .custom: Self.typography.monospaced.terminalConfig
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
        // Humanist's: what custom sizes are scaled from (`font`).
        case (.custom, .proportional): 14.5
        case (.custom, .monospaced): 13
        }
    }

    /// The reading font: previews'.
    func readingFont(size: CGFloat) -> NSFont {
        switch self {
        case .humanist: NSFont(name: "Tiempos Text", size: size) ?? .systemFont(ofSize: size)
        case .system: .systemFont(ofSize: size)
        case .custom: Self.typography.reading.font(size: size * Self.typography.reading.size / 16, role: .reading)
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
        // Each role at its size where the theme's would be at 14.5 (or 13), the rest in proportion.
        case (.custom, .proportional): Self.typography.editing.font(size: size * Self.typography.editing.size / 14.5, role: .editing)
        case (.custom, .monospaced): Self.typography.monospaced.font(size: size * Self.typography.monospaced.size / 13, role: .monospaced)
        }
    }

    /// The editor's lines, as a multiple of the font's own height: the
    /// theme's (`fallback`), or custom typography's, as a multiple of the
    /// size, made one of the font's.
    func editorLineHeight(_ kind: EditorFont, font: NSFont, fallback: CGFloat) -> CGFloat {
        guard self == .custom else { return fallback }
        let style = kind == .monospaced ? Self.typography.monospaced : Self.typography.editing
        let natural = font.ascender - font.descender + font.leading
        return natural > 0 ? max(0.5, style.lineHeight * font.pointSize / natural) : fallback
    }

    /// Letter spacing in points for a font set in a role (custom only).
    func tracking(_ kind: EditorFont, font: NSFont) -> CGFloat {
        guard self == .custom else { return 0 }
        let style = kind == .monospaced ? Self.typography.monospaced : Self.typography.editing
        return style.tracking / 1000 * font.pointSize
    }

    /// The custom theme's typography, as Settings has it; kept by the window
    /// as it renders, with `current`.
    nonisolated(unsafe) static var typography: Typography = .humanist

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
        case .humanist: return (#""Tiempos Text""#, #""Source Code Pro""#, #""calt""#, "normal")
        case .system: return ("-apple-system", "ui-monospace", #""calt""#, "normal")
        case .custom:
            let t = Self.typography
            return (t.reading.cssFamily(.reading), t.monospaced.cssFamily(.monospaced), t.monospaced.cssFeatures, t.reading.cssFeatures)
        }
    }

    /// The rest of the preview's CSS variables for custom typography: the
    /// reading role's size, weight, spacing and measure, the code's weight
    /// and spacing; none for the other themes (the page's own).
    var cssExtras: String {
        guard self == .custom else { return "" }
        let r = Self.typography.reading, m = Self.typography.monospaced
        var out = "--read-size: \(r.size)px; --read-weight: \(r.weight); --read-leading: \(r.lineHeight); --read-tracking: \(r.tracking / 1000)em;"
        out += " --read-gap: \(r.paragraphSpacing)em; --mono-weight: \(m.weight); --mono-tracking: \(m.tracking / 1000)em;"
        out += " --mono-scale: \(m.size / 13);"
        // Bold as the editor takes it: a face heavier by a step, not CSS's
        // "bolder" (from Light, only Regular).
        out += " --read-bold: \(min(900, r.weight + FontFace.boldStep)); --read-heading: \(min(900, max(700, r.weight + FontFace.boldStep)));"
        if r.measure > 0 { out += " --read-measure: \(r.measure)ch;" }
        return out
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


/// The three roles custom typography sets.
enum FontRole: String, CaseIterable {
    case editing, reading, monospaced

    var title: String {
        switch self {
        case .editing: "Editing"
        case .reading: "Reading"
        case .monospaced: "Monospaced"
        }
    }
}

extension Typography {
    subscript(role: FontRole) -> TypeStyle {
        get {
            switch role {
            case .editing: editing
            case .reading: reading
            case .monospaced: monospaced
            }
        }
        set {
            switch role {
            case .editing: editing = newValue
            case .reading: reading = newValue
            case .monospaced: monospaced = newValue
            }
        }
    }
}

/// A family's faces, as the system has them: the face's name (as it's
/// called within its family: Light, Regular, Semibold Italic), its
/// PostScript name, its weight as CSS counts (the font's own, from its
/// OS/2 table, where it says), and whether it's italic.
struct FontFace: Equatable {
    var name: String
    var postScript: String
    var weight: Int
    var italic = false

    /// A family's upright faces ("" is the system's, named by weight),
    /// lightest first, one to a weight.
    static func faces(of family: String, role: FontRole) -> [FontFace] {
        let real = family.isEmpty && role == .monospaced ? "SF Mono" : family
        if real.isEmpty {
            return [("Ultralight", 100), ("Thin", 200), ("Light", 300), ("Regular", 400), ("Medium", 500),
                    ("Semibold", 600), ("Bold", 700), ("Heavy", 800), ("Black", 900)].map { FontFace(name: $0.0, postScript: "", weight: $0.1) }
        }
        var out: [FontFace] = []
        for f in all(of: real) where !f.italic && !out.contains(where: { $0.weight == f.weight }) { out.append(f) }
        return out
    }

    nonisolated(unsafe) private static var families: [String: [FontFace]] = [:]

    /// Every face of a family, italics too, lightest first.
    static func all(of family: String) -> [FontFace] {
        if let known = families[family] { return known }
        var out: [FontFace] = []
        for m in NSFontManager.shared.availableMembers(ofFontFamily: family) ?? [] where m.count >= 4 {
            guard let ps = m[0] as? String, let name = m[1] as? String, let w = m[2] as? Int, let traits = m[3] as? UInt else { continue }
            out.append(FontFace(name: name, postScript: ps, weight: weightClass(ps) ?? cssWeight(w),
                                italic: NSFontTraitMask(rawValue: traits).contains(.italicFontMask)))
        }
        out.sort { $0.weight < $1.weight }
        families[family] = out
        return out
    }

    /// A face's weight as its font says (OS/2's usWeightClass), from 100 to 900.
    static func weightClass(_ postScript: String) -> Int? {
        let font = CTFontCreateWithName(postScript as CFString, 12, nil)
        guard let data = CTFontCopyTable(font, CTFontTableTag(kCTFontTableOS2), []) as Data?, data.count >= 6 else { return nil }
        let w = Int(data[data.startIndex + 4]) << 8 | Int(data[data.startIndex + 5])
        return (1...1000).contains(w) ? w : nil
    }

    /// NSFontManager's weights (0–15, 5 regular, 9 bold) as CSS's, for a
    /// font that doesn't say its own.
    static func cssWeight(_ w: Int) -> Int {
        let table = [0: 100, 1: 100, 2: 100, 3: 200, 4: 300, 5: 400, 6: 500, 7: 600, 8: 600, 9: 700, 10: 800, 11: 900, 12: 900]
        return table[w] ?? (w > 12 ? 900 : 400)
    }

    /// How much heavier bold is than what it's in: Light's is Semibold,
    /// Regular's Bold, as a type designer pairs them.
    static let boldStep = 300

    /// The face for emphasis in a family, from a face of `weight`: bold, a
    /// face heavier by about `boldStep` (the nearest heavier one); italic,
    /// the slanted face of the weight (or the bold one's). Nil if the
    /// family has none.
    static func emphasis(in family: String, from weight: Int, bold: Bool, italic: Bool) -> FontFace? {
        let target = bold ? min(900, weight + boldStep) : weight
        let pool = all(of: family).filter { $0.italic == italic && (!bold || $0.weight > weight) }
        return pool.min { a, b in
            let da = abs(a.weight - target), db = abs(b.weight - target)
            return da != db ? da < db : a.weight < b.weight
        }
    }
}

extension NSFont {
    /// The font made bold or italic as its family has it, its features
    /// kept: from a light face, bold is a heavier face, not the light one
    /// unchanged — as asking the font manager for the bold trait gives, in
    /// a family with more weights than regular and bold.
    func emphasized(bold: Bool = false, italic: Bool = false) -> NSFont {
        guard bold || italic else { return self }
        var out: NSFont?
        if let family = familyName, !family.hasPrefix(".") {
            let weight = FontFace.weightClass(fontName) ?? FontFace.all(of: family).first { $0.postScript == fontName }?.weight ?? 400
            if let face = FontFace.emphasis(in: family, from: weight, bold: bold, italic: italic) {
                out = NSFont(name: face.postScript, size: pointSize)
            }
        } else {
            // The system's: a heavier weight of it, slanted by its descriptor.
            var f = self
            if bold {
                let traits = fontDescriptor.object(forKey: .traits) as? [NSFontDescriptor.TraitKey: Any]
                let w = (traits?[.weight] as? CGFloat) ?? 0
                let weights: [NSFont.Weight] = [.ultraLight, .thin, .light, .regular, .medium, .semibold, .bold, .heavy, .black]
                let i = weights.indices.min { abs(weights[$0].rawValue - w) < abs(weights[$1].rawValue - w) } ?? 3
                let heavier = weights[min(weights.count - 1, i + 3)]
                f = isFixedPitch ? .monospacedSystemFont(ofSize: pointSize, weight: heavier) : .systemFont(ofSize: pointSize, weight: heavier)
            }
            if italic, let d = Optional(f.fontDescriptor.withSymbolicTraits(.italic)) { f = NSFont(descriptor: d, size: pointSize) ?? f }
            out = f
        }
        var f = out ?? {
            var f = self
            if bold { f = NSFontManager.shared.convert(f, toHaveTrait: .boldFontMask) }
            if italic { f = NSFontManager.shared.convert(f, toHaveTrait: .italicFontMask) }
            return f
        }()
        if let features = fontDescriptor.object(forKey: .featureSettings) {
            f = NSFont(descriptor: f.fontDescriptor.addingAttributes([.featureSettings: features]), size: pointSize) ?? f
        }
        return f
    }
}

extension TypeStyle {
    /// What to call it: its family and, if not regular, its face.
    func displayName(_ role: FontRole) -> String {
        let family = self.family.isEmpty ? (role == .monospaced ? "SF Mono" : "SF") : self.family
        guard weight != 400, let face = face(role) else { return family }
        return family + " " + face.name
    }

    /// The upright face nearest the weight.
    func face(_ role: FontRole) -> FontFace? {
        FontFace.faces(of: family, role: role).min { abs($0.weight - weight) < abs($1.weight - weight) }
    }

    /// Set at a size: its face, with its features.
    func font(size: CGFloat, role: FontRole) -> NSFont {
        var base: NSFont?
        if family.isEmpty {
            let w = Self.systemWeight(weight)
            base = role == .monospaced ? .monospacedSystemFont(ofSize: size, weight: w) : .systemFont(ofSize: size, weight: w)
        } else if let face = face(role) {
            base = NSFont(name: face.postScript, size: size)
        }
        let font = base ?? (role == .monospaced ? .monospacedSystemFont(ofSize: size, weight: .regular) : .systemFont(ofSize: size))
        let tags = featureTags
        guard !tags.isEmpty else { return font }
        let settings = tags.map { ["CTFeatureOpenTypeTag": $0.tag, "CTFeatureOpenTypeValue": $0.value] as [String: Any] }
        let d = font.fontDescriptor.addingAttributes([.featureSettings: settings])
        return NSFont(descriptor: d, size: size) ?? font
    }

    static func systemWeight(_ w: Int) -> NSFont.Weight {
        switch w {
        case ..<150: .ultraLight
        case ..<250: .thin
        case ..<350: .light
        case ..<450: .regular
        case ..<550: .medium
        case ..<650: .semibold
        case ..<750: .bold
        case ..<850: .heavy
        default: .black
        }
    }

    /// Ghostty's lines for it, as the terminals' font: its family and face,
    /// size, features, and its cells' height and width made to give its
    /// line height and letter spacing.
    var terminalConfig: String {
        let family = self.family.isEmpty ? "SF Mono" : self.family
        var lines = ["font-family = \(family)", "font-size = \(size)"]
        if let face = face(.monospaced) {
            lines.append("font-style = \(face.name)")
            // Bold and italic from the family's faces, as the editor takes them.
            let real = self.family.isEmpty ? "SF Mono" : self.family
            if let bold = FontFace.emphasis(in: real, from: face.weight, bold: true, italic: false) { lines.append("font-style-bold = \(bold.name)") }
            if let italic = FontFace.emphasis(in: real, from: face.weight, bold: false, italic: true) { lines.append("font-style-italic = \(italic.name)") }
            if let both = FontFace.emphasis(in: real, from: face.weight, bold: true, italic: true) { lines.append("font-style-bold-italic = \(both.name)") }
        }
        for (tag, value) in featureTags { lines.append("font-feature = " + (value == 0 ? "-\(tag)" : value == 1 ? tag : "\(tag)=\(value)")) }
        let f = font(size: CGFloat(size), role: .monospaced)
        let natural = f.ascender - f.descender + f.leading
        if natural > 0 {
            let percent = Int(((CGFloat(lineHeight) * f.pointSize / natural) - 1) * 100)
            if percent != 0 { lines.append("adjust-cell-height = \(percent)%") }
        }
        let advance = f.maximumAdvancement.width
        if advance > 0, tracking != 0 {
            let percent = Int((CGFloat(tracking) / 1000 * f.pointSize) / advance * 100)
            if percent != 0 { lines.append("adjust-cell-width = \(percent)%") }
        }
        return lines.joined(separator: "\n")
    }

    /// As CSS names it, the theme's fallbacks after it.
    func cssFamily(_ role: FontRole) -> String {
        if family.isEmpty { return role == .monospaced ? "ui-monospace" : "-apple-system" }
        return "\"" + family.replacingOccurrences(of: "\"", with: "") + "\""
    }

    /// Its features as CSS's font-feature-settings.
    var cssFeatures: String {
        let tags = featureTags
        return tags.isEmpty ? "normal" : tags.map { "\"\($0.tag)\" \($0.value)" }.joined(separator: ", ")
    }

    /// The OpenType features a font has, by tag, with what the font calls
    /// them: what the features menu offers.
    static func availableFeatures(of font: NSFont) -> [(tag: String, name: String)] {
        guard let types = CTFontCopyFeatures(font as CTFont) as? [[String: Any]] else { return [] }
        var out: [(String, String)] = []
        for type in types {
            let typeName = type[kCTFontFeatureTypeNameKey as String] as? String ?? ""
            for sel in type[kCTFontFeatureTypeSelectorsKey as String] as? [[String: Any]] ?? [] {
                guard let tag = sel["CTFeatureOpenTypeTag"] as? String, tag.count == 4 else { continue }
                if out.contains(where: { $0.0 == tag }) { continue }
                let name = sel[kCTFontFeatureSelectorNameKey as String] as? String ?? typeName
                out.append((tag, name == typeName || typeName.isEmpty ? name : "\(typeName): \(name)"))
            }
        }
        return out.sorted { $0.0 < $1.0 }
    }
}
