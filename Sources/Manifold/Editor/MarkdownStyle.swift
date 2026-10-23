import AppKit
import ManifoldCore

/// A block as its pill in a note shows it: what the tile's pill shows.
struct PillLook: Equatable {
    var title: String
    var symbol: String
    var status: StatusGlyph.Look?
}

/// Markdown, shown richly in the editor while staying Markdown underneath
/// (§7): the text is what you type, every character where it is, but a
/// line's attributes say what it means — headings bold, emphasis in its
/// face, code in its font on a tint, list markers and quotes set off,
/// links as their words — and the markers themselves are drawn too small
/// to see, as Prism hides them, unless the caret is on the line, where
/// they show as written, dimmed. A link to a block is its pill, live: the
/// block's symbol, name and status, as its tile wears them — a link to a
/// place in it (`#page=6`, `#line=12`) named by its own words instead.
enum MarkdownStyle {
    /// A tint behind a run: a code span, a block's chip.
    static let chip = NSAttributedString.Key("manifold.chip")
    /// A run too small to see: a hidden marker (its characters stay, for
    /// the caret to pass through).
    static let hidden = NSAttributedString.Key("manifold.hidden")
    /// A line of a fenced code block: tinted edge to edge.
    static let codeBlock = NSAttributedString.Key("manifold.codeBlock")
    /// What a click on the run goes to: a web address, or manifold:id.
    static let target = NSAttributedString.Key("manifold.target")
    /// A block's pill drawn over the run (its first character's glyph is
    /// the pill's width; the rest are hidden): the look to draw.
    static let pill = NSAttributedString.Key("manifold.pill")

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

    /// Whether a line opens or closes a fenced code block.
    static func isFence(_ line: String) -> Bool { line.hasPrefix("```") || line.hasPrefix("~~~") }

    /// The pill's font and the width it takes for a look, at a row height.
    static let pillFont = NSFont.systemFont(ofSize: 11, weight: .medium)
    static func pillWidth(_ look: PillLook) -> CGFloat {
        let text = ceil((look.title as NSString).size(withAttributes: [.font: pillFont]).width)
        return 8 + 13 + 5 + text + (look.status == nil ? 0 : 4 + 11) + 8
    }

    /// Styles one line. `reveal`: the caret is on it, so markers show,
    /// dimmed, instead of hidden. `inCodeBlock`: between fences. `look`:
    /// a block's look, for a link to it; nil for a chip of the words.
    static func apply(to a: NSMutableAttributedString, base: NSFont, code codeFont: NSFont, palette: Palette,
                      reveal: Bool, inCodeBlock: Bool = false, look: (BlockID) -> PillLook? = { _ in nil }) {
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
        /// A marker: as written on the caret's line, else out of sight.
        func mark(_ r: NSRange) { if reveal { dim(r) } else { hide(r) } }

        // A fenced code block: its lines in the code font on a tint, the
        // fences dimmed.
        if inCodeBlock || isFence(a.string) {
            a.addAttributes([.font: codeFont, codeBlock: true], range: all)
            if isFence(a.string) { dim(all) }
            return
        }

        // The line's kind.
        if let m = heading.firstMatch(in: a.string, range: all) {
            a.addAttribute(.font, value: boldFont, range: NSRange(location: m.range.length, length: all.length - m.range.length))
            mark(m.range)
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
            mark(NSRange(location: m.range.location, length: 1))
            mark(NSRange(location: m.range.location + m.range.length - 1, length: 1))
        }
        func inCode(_ r: NSRange) -> Bool { codeRanges.contains { NSIntersectionRange($0, r).length > 0 } }

        // Links: the words as a link, the rest hidden — or, to a block,
        // its pill (on the caret's line, a chip of the words as written).
        for m in link.matches(in: a.string, range: all) where !inCode(m.range) {
            let words = m.range(at: 2), address = s.substring(with: m.range(at: 4))
            a.addAttribute(target, value: address, range: m.range)
            let rest = NSRange(location: m.range(at: 3).location, length: m.range(at: 3).length + m.range(at: 4).length + m.range(at: 5).length)
            if address.hasPrefix("manifold:"), let (id, place) = BlockID.link(address) {
                if !reveal, var look = look(id) {
                    // A link to a place in the block (a heading, a PDF's page):
                    // its own words, which name the place, not the block's name.
                    let named = s.substring(with: words).trimmingCharacters(in: .whitespaces)
                    if place != nil, !named.isEmpty { look.title = named }
                    let width = pillWidth(look)
                    let first = NSRange(location: m.range.location, length: 1)
                    a.addAttributes([pill: look as Any, .foregroundColor: NSColor.clear, kCTRunDelegateAttributeName as NSAttributedString.Key: RunWidth.delegate(width: width, font: base)], range: first)
                    hide(NSRange(location: m.range.location + 1, length: m.range.length - 1))
                    // An image shown (`![](manifold:…)`): its pill, the mark gone too.
                    if m.range.location > 0, s.character(at: m.range.location - 1) == 0x21 { hide(NSRange(location: m.range.location - 1, length: 1)) }
                } else {
                    a.addAttributes([.foregroundColor: palette.text, chip: palette.chipTint], range: words)
                    dim(m.range(at: 1)); dim(rest)
                }
            } else {
                a.addAttributes([.foregroundColor: palette.accent, .underlineStyle: NSUnderlineStyle.single.rawValue], range: words)
                mark(m.range(at: 1)); mark(rest)
            }
        }

        // Emphasis: the face changes, the markers go.
        for m in bold.matches(in: a.string, range: all) where !inCode(m.range) {
            a.addAttribute(.font, value: boldFont, range: m.range(at: 2))
            mark(m.range(at: 1))
            mark(NSRange(location: m.range.location + m.range.length - m.range(at: 1).length, length: m.range(at: 1).length))
        }
        for m in italic.matches(in: a.string, range: all) where !inCode(m.range) {
            let inner = m.range(at: 2)
            let current = a.attribute(.font, at: inner.location, effectiveRange: nil) as? NSFont ?? base
            a.addAttribute(.font, value: manager.convert(current, toHaveTrait: .italicFontMask), range: inner)
            mark(m.range(at: 1))
            mark(NSRange(location: m.range.location + m.range.length - 1, length: 1))
        }
        for m in strike.matches(in: a.string, range: all) where !inCode(m.range) {
            a.addAttribute(.strikethroughStyle, value: NSUnderlineStyle.single.rawValue, range: m.range(at: 1))
            mark(NSRange(location: m.range.location, length: 2))
            mark(NSRange(location: m.range.location + m.range.length - 2, length: 2))
        }
    }

    /// A glyph of a given width in a Core Text line: what a pill stands
    /// in for.
    private final class RunWidth {
        let width: CGFloat
        let ascent: CGFloat
        let descent: CGFloat
        init(width: CGFloat, font: NSFont) {
            self.width = width
            ascent = font.ascender
            descent = -font.descender
        }

        static func delegate(width: CGFloat, font: NSFont) -> CTRunDelegate {
            var callbacks = CTRunDelegateCallbacks(
                version: kCTRunDelegateCurrentVersion,
                dealloc: { Unmanaged<RunWidth>.fromOpaque($0).release() },
                getAscent: { Unmanaged<RunWidth>.fromOpaque($0).takeUnretainedValue().ascent },
                getDescent: { Unmanaged<RunWidth>.fromOpaque($0).takeUnretainedValue().descent },
                getWidth: { Unmanaged<RunWidth>.fromOpaque($0).takeUnretainedValue().width })
            let box = Unmanaged.passRetained(RunWidth(width: width, font: font))
            return CTRunDelegateCreate(&callbacks, box.toOpaque())!
        }
    }
}
