import AppKit

/// Markdown as attributed text, for a few lines of it in a native view (a
/// commit's message): paragraphs, headings, lists, quotes and code blocks,
/// and strong, emphasis, code, struck and linked words inline — not the
/// preview's page, which is for a document. A paragraph's lines are joined
/// as Markdown joins them (a commit's are wrapped at 72).
enum MarkdownText {
    /// The preview's reading colours (`MarkdownPage`): the body a step
    /// down from white in the dark, headings and bold brighter.
    static let readingBody = NSColor.dynamic(NSColor(srgbRed: 0x20 / 255, green: 0x22 / 255, blue: 0x24 / 255, alpha: 1), NSColor(white: 0xdb / 255, alpha: 1))
    static let readingStrong = NSColor.dynamic(NSColor(srgbRed: 0x20 / 255, green: 0x22 / 255, blue: 0x24 / 255, alpha: 1), NSColor(white: 0xf7 / 255, alpha: 1))

    /// `strong`: headings' and bold's colour (else `color`); `lineHeight`:
    /// lines as a multiple of the font's own (0, its own); `tracking`:
    /// letter spacing in points.
    static func attributed(_ markdown: String, font: NSFont, code: NSFont, color: NSColor = Theme.text,
                           secondary: NSColor = Theme.secondaryText, strong: NSColor? = nil,
                           lineHeight: CGFloat = 0, tracking: CGFloat = 0) -> NSAttributedString {
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .full, failurePolicy: .returnPartiallyParsedIfPossible)
        guard let parsed = try? AttributedString(markdown: markdown, options: options) else {
            return NSAttributedString(string: markdown, attributes: [.font: font, .foregroundColor: color])
        }
        let out = NSMutableAttributedString()
        var lastBlock: Int?
        var lastItem: Int?
        for run in parsed.runs {
            var text = String(parsed[run.range].characters)
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
            for c in components {
                switch c.kind {
                case let .header(level):
                    runFont = NSFontManager.shared.convert(font, toHaveTrait: .boldFontMask)
                    if let strong { runColor = strong }
                    if level <= 2 { runFont = NSFont(descriptor: runFont.fontDescriptor, size: font.pointSize * (level == 1 ? 1.25 : 1.12)) ?? runFont }
                case let .listItem(ordinal):
                    depth += 1
                    // The item's mark, before its first words.
                    if c.identity != lastItem {
                        lastItem = c.identity
                        let ordered = components.contains { if case .orderedList = $0.kind { true } else { false } }
                        text = (ordered ? "\(ordinal). " : "• ") + text
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
            } else {
                text = text.replacingOccurrences(of: "\n", with: " ")
            }
            var attrs: [NSAttributedString.Key: Any] = [.font: runFont, .foregroundColor: runColor, .paragraphStyle: paragraph]
            if let inline = run.inlinePresentationIntent {
                if inline.contains(.code) { attrs[.font] = code }
                if inline.contains(.stronglyEmphasized) {
                    attrs[.font] = NSFontManager.shared.convert(attrs[.font] as! NSFont, toHaveTrait: .boldFontMask)
                    if let strong { attrs[.foregroundColor] = strong }
                }
                if inline.contains(.emphasized) { attrs[.font] = NSFontManager.shared.convert(attrs[.font] as! NSFont, toHaveTrait: .italicFontMask) }
                if inline.contains(.strikethrough) { attrs[.strikethroughStyle] = NSUnderlineStyle.single.rawValue }
            }
            if let link = run.link { attrs[.link] = link }
            if tracking != 0, !isCode, run.inlinePresentationIntent?.contains(.code) != true { attrs[.kern] = tracking }
            out.append(NSAttributedString(string: text, attributes: attrs))
        }
        return out
    }
}
