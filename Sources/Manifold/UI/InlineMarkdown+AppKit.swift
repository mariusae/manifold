import AppKit
import ManifoldCore

extension InlineMarkdown {
    /// The line set in `font` and `color`: bold and italic as the family
    /// has them, code in the theme's code face a touch smaller, struck
    /// through as struck.
    static func attributed(_ s: String, font: NSFont, color: NSColor, extra: [NSAttributedString.Key: Any] = [:]) -> NSAttributedString {
        let out = NSMutableAttributedString()
        for span in spans(s) {
            var f = font
            if span.code {
                f = FontTheme.code(round(font.pointSize * 0.92 * 2) / 2)
            } else if span.bold || span.italic {
                f = font.emphasized(bold: span.bold, italic: span.italic)
            }
            var a = extra
            a[.font] = f
            a[.foregroundColor] = color
            if span.struck { a[.strikethroughStyle] = NSUnderlineStyle.single.rawValue }
            out.append(NSAttributedString(string: span.text, attributes: a))
        }
        return out
    }
}
