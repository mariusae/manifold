import AppKit

/// Markdown as attributed text, for a few lines of it in a native view (a
/// commit's message): paragraphs, headings, lists, quotes and code blocks,
/// and strong, emphasis, code, struck and linked words inline — not the
/// preview's page, which is for a document. A paragraph's lines are joined
/// as Markdown joins them (a commit's are wrapped at 72).
enum MarkdownText {
    /// The preview's reading colours (`MarkdownPage`): the body a step
    /// down from white in the dark, headings and bold brighter.
    static let readingBody = NSColor.themed { $0.text.readingBody }
    static let readingStrong = NSColor.themed { $0.text.readingStrong }
    /// Code's ground in a comment: the card's ground a step toward the
    /// text, opaque — drawn twice (as a text view may draw a run's ground),
    /// the same, where a faint see-through tint came out twice as strong.
    static let codeGround = NSColor(name: nil) { a in
        var c = NSColor.gray
        a.performAsCurrentDrawingAppearance {
            let ground = Theme.panel.usingColorSpace(.sRGB) ?? .white, ink = Theme.text.usingColorSpace(.sRGB) ?? .black
            c = ground.blended(withFraction: a.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? 0.09 : 0.06, of: ink) ?? ground
        }
        return c
    }

    /// `strong`: headings' and bold's colour (else `color`); `lineHeight`:
    /// lines as a multiple of the font's own (0, its own); `tracking`:
    /// letter spacing in points.
    static func attributed(_ markdown: String, font: NSFont, code: NSFont, color: NSColor = Theme.text,
                           secondary: NSColor = Theme.secondaryText, strong: NSColor? = nil,
                           lineHeight: CGFloat = 0, tracking: CGFloat = 0, boxes: Bool = false, breaks: Bool = false) -> NSAttributedString {
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .full, failurePolicy: .returnPartiallyParsedIfPossible)
        guard let parsed = try? AttributedString(markdown: markdown, options: options) else {
            return NSAttributedString(string: markdown, attributes: [.font: font, .foregroundColor: color])
        }
        let out = NSMutableAttributedString()
        var lastBlock: Int?
        // Items already marked: each its mark once, before its first words
        // (not again before a later paragraph of it, or an item in it).
        var marked = Set<Int>()
        // `boxes`: a code block on a tint of its own, padded, as an issue's
        // comment shows one (laid out by a text view: TextKit's blocks).
        var lastWasCode = false
        var codeBlockID: Int?
        let codeBox: NSTextBlock? = boxes ? {
            let b = NSTextBlock()
            b.backgroundColor = Self.codeGround
            b.setWidth(10, type: .absoluteValueType, for: .padding)
            // As wide as the text (without a width, a block is as narrow as a letter).
            b.setValue(100, type: .percentageValueType, for: .width)
            // Room above and below, so its ground stays off the lines round
            // it (an inline code's tint just under it most).
            b.setWidth(6, type: .absoluteValueType, for: .margin, edge: .minY)
            b.setWidth(10, type: .absoluteValueType, for: .margin, edge: .maxY)
            return b
        }() : nil
        for run in parsed.runs {
            var text = String(parsed[run.range].characters)
            // An item's mark: a run of its own, in the item's face — not the
            // look of the words it's before (code's, bold's).
            var mark: String?
            let components = run.presentationIntent?.components ?? []
            let block = components.first?.identity
            let isCode = components.contains { if case .codeBlock = $0.kind { true } else { false } }
            // A new block: on a line of its own, a blank line's room above.
            if block != lastBlock, out.length > 0 { out.append(NSAttributedString(string: "\n")) }
            lastBlock = block
            let paragraph = NSMutableParagraphStyle()
            paragraph.paragraphSpacing = font.pointSize * 0.5
            if lineHeight > 0 { paragraph.lineHeightMultiple = lineHeight }
            var runFont = font
            var runColor = color
            var depth = 0
            // The innermost item this run is in: the only one it may mark.
            let item = components.first { if case .listItem = $0.kind { true } else { false } }
            for c in components {
                switch c.kind {
                case let .header(level):
                    runFont = NSFontManager.shared.convert(font, toHaveTrait: .boldFontMask)
                    if let strong { runColor = strong }
                    if level <= 2 { runFont = NSFont(descriptor: runFont.fontDescriptor, size: font.pointSize * (level == 1 ? 1.25 : 1.12)) ?? runFont }
                case let .listItem(ordinal):
                    depth += 1
                    // The item's mark, before its first words: its own list's
                    // kind (the list just outside it), ordered or not.
                    if c.identity == item?.identity, marked.insert(c.identity).inserted {
                        let list = components.drop { $0.identity != c.identity }.dropFirst().first
                        let ordered = if case .orderedList = list?.kind { true } else { false }
                        mark = ordered ? "\(ordinal). " : "• "
                    }
                case .blockQuote:
                    depth += 1
                    runColor = secondary
                case .codeBlock:
                    runFont = code
                default: break
                }
            }
            if depth > 0 {
                let indent = CGFloat(depth) * font.pointSize * 1.3
                paragraph.firstLineHeadIndent = indent - font.pointSize * 1.1
                paragraph.headIndent = indent
            }
            if isCode {
                while text.hasSuffix("\n") { text.removeLast() }
                if let codeBox { paragraph.textBlocks = [codeBox] }
            } else if codeBox != nil, lastWasCode, block != codeBlockID {
                // Just after a code block's box: room above, clear of its ground.
                paragraph.paragraphSpacingBefore = font.pointSize * 0.7
            }
            if isCode { codeBlockID = block }
            lastWasCode = isCode
            if !isCode {
                text = text.replacingOccurrences(of: "\n", with: " ")
                // A line's end within a paragraph (a soft break): a space, as
                // Markdown joins them (a commit's, wrapped at 72); `breaks`,
                // kept — a comment's, as a chat's and an issue's keep them. A
                // hard break (two spaces, a backslash), always kept.
                if let inline = run.inlinePresentationIntent,
                   inline.contains(.lineBreak) || (breaks && inline.contains(.softBreak)) {
                    text = "\u{2028}"
                }
            }
            var attrs: [NSAttributedString.Key: Any] = [.font: runFont, .foregroundColor: runColor, .paragraphStyle: paragraph]
            if let inline = run.inlinePresentationIntent {
                if inline.contains(.code) {
                    attrs[.font] = code
                    if boxes { attrs[.backgroundColor] = Self.codeGround }
                }
                if inline.contains(.stronglyEmphasized) {
                    attrs[.font] = NSFontManager.shared.convert(attrs[.font] as! NSFont, toHaveTrait: .boldFontMask)
                    if let strong { attrs[.foregroundColor] = strong }
                }
                if inline.contains(.emphasized) { attrs[.font] = NSFontManager.shared.convert(attrs[.font] as! NSFont, toHaveTrait: .italicFontMask) }
                if inline.contains(.strikethrough) { attrs[.strikethroughStyle] = NSUnderlineStyle.single.rawValue }
            }
            if let link = run.link { attrs[.link] = link }
            if tracking != 0, !isCode, run.inlinePresentationIntent?.contains(.code) != true { attrs[.kern] = tracking }
            if let mark {
                out.append(NSAttributedString(string: mark, attributes: [.font: runFont, .foregroundColor: runColor, .paragraphStyle: paragraph]))
            }
            out.append(NSAttributedString(string: text, attributes: attrs))
        }
        return out
    }
}
