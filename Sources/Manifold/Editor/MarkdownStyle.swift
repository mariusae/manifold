import AppKit

/// Markdown, shown richly in the editor while staying Markdown underneath
/// (§7): the text is what you type, every character where it is, but a
/// line's attributes say what it means — headings bold, emphasis in its
/// face, code in its font on a tint, list markers and quotes set off,
/// link addresses dimmed; a link to a block collapses to a chip of its
/// title, its brackets and address drawn too small to see, unless the
/// caret is on the line, where it shows as written.
enum MarkdownStyle {
    /// A tint behind a run: a code span, a block's chip.
    static let chip = NSAttributedString.Key("manifold.chip")
    /// A run too small to see: a hidden marker (its characters stay, for
    /// the caret to pass through).
    static let hidden = NSAttributedString.Key("manifold.hidden")

    struct Palette {
        var text: NSColor
        var dim: NSColor
        var accent: NSColor
        var codeTint: NSColor
        var chipTint: NSColor
    }

    private static let bold = try! NSRegularExpression(pattern: #"(\*\*|__)(?=\S)(.+?)(?<=\S)\1"#)
    private static let italic = try! NSRegularExpression(pattern: #"(?<![\*\w])(\*|_)(?=\S)([^\*_]+?)(?<=\S)\1(?![\*\w])"#)
    private static let strike = try! NSRegularExpression(pattern: #"~~(?=\S)(.+?)(?<=\S)~~"#)
    private static let code = try! NSRegularExpression(pattern: #"`([^`]+)`"#)
    private static let link = try! NSRegularExpression(pattern: #"(\[)([^\]\n]+)(\]\()([^)\s]+)(\))"#)
    private static let heading = try! NSRegularExpression(pattern: #"^(#{1,6}) "#)
    private static let listItem = try! NSRegularExpression(pattern: #"^(\s*)([-*+]|\d+[.)])(\s)"#)
    private static let quote = try! NSRegularExpression(pattern: #"^(>\s?)+"#)
    private static let rule = try! NSRegularExpression(pattern: #"^\s*([-*_])(\s*\1){2,}\s*$"#)

    static func apply(to a: NSMutableAttributedString, base: NSFont, code codeFont: NSFont, palette: Palette, collapseLinks: Bool) {
        let s = a.string as NSString
        let all = NSRange(location: 0, length: s.length)
        guard all.length > 0 else { return }
        let manager = NSFontManager.shared
        let boldFont = manager.convert(base, toHaveTrait: .boldFontMask)
        let italicFont = manager.convert(base, toHaveTrait: .italicFontMask)
        let tiny = NSFont(descriptor: base.fontDescriptor, size: 0.01) ?? base
        func dim(_ r: NSRange) { a.addAttribute(.foregroundColor, value: palette.dim, range: r) }
        func hide(_ r: NSRange) {
            a.addAttributes([.font: tiny, .foregroundColor: NSColor.clear, hidden: true], range: r)
        }

        // The line's kind.
        if let m = heading.firstMatch(in: a.string, range: all) {
            a.addAttribute(.font, value: boldFont, range: NSRange(location: m.range.length, length: all.length - m.range.length))
            dim(m.range(at: 1))
        } else if let m = rule.firstMatch(in: a.string, range: all) {
            dim(m.range)
            return
        } else if let m = listItem.firstMatch(in: a.string, range: all) {
            a.addAttribute(.foregroundColor, value: palette.accent, range: m.range(at: 2))
        }
        if let m = quote.firstMatch(in: a.string, range: all) {
            dim(m.range)
            a.addAttribute(.font, value: italicFont, range: NSRange(location: m.range.length, length: all.length - m.range.length))
        }

        // Code spans: in their font, on a tint, and left alone otherwise.
        var codeRanges: [NSRange] = []
        for m in code.matches(in: a.string, range: all) {
            codeRanges.append(m.range)
            a.addAttributes([.font: codeFont, chip: palette.codeTint], range: m.range(at: 1))
            dim(NSRange(location: m.range.location, length: 1))
            dim(NSRange(location: m.range.location + m.range.length - 1, length: 1))
        }
        func inCode(_ r: NSRange) -> Bool { codeRanges.contains { NSIntersectionRange($0, r).length > 0 } }

        // Links: the words as a link; the address dimmed — or, to a block,
        // a chip of the words alone.
        for m in link.matches(in: a.string, range: all) where !inCode(m.range) {
            let words = m.range(at: 2), target = s.substring(with: m.range(at: 4))
            if target.hasPrefix("manifold:") {
                a.addAttributes([.foregroundColor: palette.text, chip: palette.chipTint], range: words)
                if collapseLinks {
                    hide(m.range(at: 1))
                    hide(NSRange(location: m.range(at: 3).location, length: m.range(at: 3).length + m.range(at: 4).length + m.range(at: 5).length))
                } else {
                    dim(m.range(at: 1)); dim(m.range(at: 3)); dim(m.range(at: 4)); dim(m.range(at: 5))
                }
            } else {
                a.addAttributes([.foregroundColor: palette.accent, .underlineStyle: NSUnderlineStyle.single.rawValue], range: words)
                dim(m.range(at: 1)); dim(m.range(at: 3)); dim(m.range(at: 4)); dim(m.range(at: 5))
            }
        }

        // Emphasis: the face changes, the markers go dim.
        for m in bold.matches(in: a.string, range: all) where !inCode(m.range) {
            a.addAttribute(.font, value: boldFont, range: m.range(at: 2))
            dim(m.range(at: 1))
            dim(NSRange(location: m.range.location + m.range.length - m.range(at: 1).length, length: m.range(at: 1).length))
        }
        for m in italic.matches(in: a.string, range: all) where !inCode(m.range) {
            let inner = m.range(at: 2)
            let current = a.attribute(.font, at: inner.location, effectiveRange: nil) as? NSFont ?? base
            a.addAttribute(.font, value: manager.convert(current, toHaveTrait: .italicFontMask), range: inner)
            dim(m.range(at: 1))
            dim(NSRange(location: m.range.location + m.range.length - 1, length: 1))
        }
        for m in strike.matches(in: a.string, range: all) where !inCode(m.range) {
            a.addAttribute(.strikethroughStyle, value: NSUnderlineStyle.single.rawValue, range: m.range(at: 1))
            dim(NSRange(location: m.range.location, length: 2))
            dim(NSRange(location: m.range.location + m.range.length - 2, length: 2))
        }
    }
}
