import AppKit
import ManifoldCore

/// A block as its pill in a note shows it: what the tile's pill shows.
extension MarkdownStyle {
    /// A place's name (an anchor's), for its reference's pill: given by
    /// the window, which knows the blocks.
    nonisolated(unsafe) static var placeName: ((BlockID, String) -> String?)?
}

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
        /// Headings and bold: brighter than the text.
        var strong: NSColor
        var dim: NSColor
        var accent: NSColor
        /// Behind a fenced code block's lines (not a code span's: its face
        /// says it's code, and a row of tinted spans reads as chips).
        var codeTint: NSColor
        var chipTint: NSColor
        /// `==text==`'s ground: the outline's highlighter.
        var highlight: NSColor = NoteOutlineStyler.highlighter
    }

    /// A block's reference written bare (`manifold:host/id#place`, as an
    /// agent writes one): its pill too.
    private static let reference = TextLinks.bareReference
    private static let heading = try! NSRegularExpression(pattern: #"^(#{1,6}) "#)
    private static let listItem = try! NSRegularExpression(pattern: #"^(\s*)([-*+]|\d+[.)])(\s)"#)
    private static let quote = try! NSRegularExpression(pattern: #"^(>\s?)+"#)
    private static let rule = try! NSRegularExpression(pattern: #"^\s*([-*_])(\s*\1){2,}\s*$"#)

    /// Whether a line opens or closes a fenced code block.
    static func isFence(_ line: String) -> Bool { line.hasPrefix("```") || line.hasPrefix("~~~") }

    /// The pill's font and the width it takes for a look, at a row height.
    static let pillFont = LinkCapsule.font
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
        // From the base's family, a face heavier or slanted (not the trait
        // asked of the font manager, which a light face of a family of many
        // weights doesn't change for).
        let boldFont = base.emphasized(bold: true)
        let italicFont = base.emphasized(italic: true)
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
            a.addAttributes([.font: boldFont, .foregroundColor: palette.strong], range: NSRange(location: m.range.length, length: all.length - m.range.length))
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

        // The inline Markdown, as the outline reads it (InlineMarkup).
        let spans = InlineMarkup.spans(in: s, range: all)

        // Code spans: in their font, and left alone otherwise.
        for span in spans where span.kind == .code {
            a.addAttribute(.font, value: codeFont, range: span.content)
            span.markup.forEach(mark)
        }

        /// A block's pill over a run: its first character as wide as the
        /// pill, the rest out of sight.
        func showPill(_ r: NSRange, _ look: PillLook) {
            let first = NSRange(location: r.location, length: 1)
            a.addAttributes([pill: look as Any, .foregroundColor: NSColor.clear, kCTRunDelegateAttributeName as NSAttributedString.Key: RunWidth.delegate(width: pillWidth(look), font: base)], range: first)
            hide(NSRange(location: r.location + 1, length: r.length - 1))
        }

        /// A link: the words as a link, the rest hidden — or, to a block,
        /// its pill (on the caret's line, a chip of the words as written).
        /// `whole` runs from what opens it (`[`, `<`) to what closes it;
        /// `bang`, an image's `!` before it.
        func link(_ whole: NSRange, words: NSRange, to address: String, bang: Bool = false) {
            a.addAttribute(target, value: address, range: whole)
            let open = NSRange(location: whole.location, length: words.location - whole.location)
            let rest = NSRange(location: NSMaxRange(words), length: NSMaxRange(whole) - NSMaxRange(words))
            if address.hasPrefix("manifold:"), let (id, place) = BlockID.link(address) {
                if !reveal, var look = look(id) {
                    // A link to a place in the block (a heading, a PDF's page):
                    // its own words, which name the place, not the block's name.
                    let named = s.substring(with: words).trimmingCharacters(in: .whitespaces)
                    if place != nil, !named.isEmpty { look.title = named }
                    showPill(whole, look)
                    // An image shown (`![](manifold:…)`): its pill, the mark gone too.
                    if bang { hide(NSRange(location: whole.location - 1, length: 1)) }
                } else {
                    a.addAttributes([.foregroundColor: palette.text, chip: palette.chipTint], range: words)
                    dim(open); dim(rest)
                }
            } else {
                a.addAttributes([.foregroundColor: palette.accent, .underlineStyle: NSUnderlineStyle.single.rawValue], range: words)
                mark(open); mark(rest)
            }
        }

        // Links, and addresses written bare or in `<…>`.
        for span in spans {
            switch span.kind {
            case let .link(address) where !address.isEmpty:
                link(span.range, words: span.content, to: address)
            case let .url(address):
                link(span.range, words: span.content, to: address)
            case let .image(picture):
                // `![words](source)`, then perhaps its size noted
                // (`<!-- {"width":320} -->`, as the outline's grip writes
                // one): the size, markup; the rest, a link to the source —
                // with no words, only a block's (its pill), else as written.
                let words = NSRange(location: span.range.location + 2, length: (picture.alt as NSString).length)
                let whole = NSRange(location: span.range.location + 1, length: NSMaxRange(words) + 3 + (picture.source as NSString).length - span.range.location - 1)
                if NSMaxRange(whole) < NSMaxRange(span.range) { mark(NSRange(location: NSMaxRange(whole), length: NSMaxRange(span.range) - NSMaxRange(whole))) }
                if picture.source.isEmpty || words.length == 0 && !picture.source.hasPrefix("manifold:") { continue }
                link(whole, words: words, to: picture.source, bang: true)
            default:
                break
            }
        }

        // A bare reference: its block's pill, as a link's; on the caret's
        // line, as written. Not in code, nor in a link or an address.
        let opaque = spans.filter {
            switch $0.kind {
            case .code, .link, .url, .image, .imageText, .wikiLink, .comment: true
            default: false
            }
        }.map(\.range)
        for m in reference.matches(in: a.string, range: all) where !opaque.contains(where: { NSIntersectionRange($0, m.range).length > 0 }) {
            let address = s.substring(with: m.range)
            guard let (id, place) = BlockID.link(address) else { continue }
            a.addAttribute(target, value: address, range: m.range)
            guard !reveal, var look = look(id) else {
                a.addAttributes([.foregroundColor: palette.text, chip: palette.chipTint], range: m.range)
                continue
            }
            // A place by its name (an anchor's, §2.5), else as written.
            if let place {
                let at = Locator(fragment: place)
                if let anchor = at?.anchorID, let name = Self.placeName?(id, anchor) { look.title = name } else { look.title += " · " + (at?.words ?? place) }
            }
            showPill(m.range, look)
        }

        /// Each run of a span's own words restyled — not a marker hidden,
        /// a pill, or code, which keep their look.
        func restyle(_ r: NSRange, _ change: (NSFont, NSRange) -> Void) {
            a.enumerateAttributes(in: r) { attrs, run, _ in
                guard attrs[hidden] == nil, attrs[pill] == nil else { return }
                let font = attrs[.font] as? NSFont ?? base
                if font != codeFont { change(font, run) }
            }
        }

        // Emphasis: the face changes, the markers go. Bold first, so
        // italic inside bold (or around it, `***both***`) is bold-italic.
        for span in spans where span.kind == .strong {
            restyle(span.content) { _, run in a.addAttributes([.font: boldFont, .foregroundColor: palette.strong], range: run) }
            span.markup.forEach(mark)
        }
        for span in spans where span.kind == .emphasis {
            restyle(span.content) { font, run in
                // Bold and italic both: the bold-italic face, from the base.
                a.addAttribute(.font, value: base.emphasized(bold: font != base && font != italicFont, italic: true), range: run)
            }
            span.markup.forEach(mark)
        }
        for span in spans {
            switch span.kind {
            case .strikethrough:
                a.addAttribute(.strikethroughStyle, value: NSUnderlineStyle.single.rawValue, range: span.content)
            case .highlight:
                // `==text==`: on the highlighter's ground.
                a.addAttribute(chip, value: palette.highlight, range: span.content)
            default:
                continue
            }
            span.markup.forEach(mark)
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
