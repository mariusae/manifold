import Foundation

/// Markdown said on one line — an agent's answer in a summary, a card's
/// line — as spans to set: bold, italic, code, a link's words; or, where
/// nothing's set, its words alone, the marks gone.
public enum InlineMarkdown {
    public struct Span: Equatable, Sendable {
        public var text: String
        public var bold = false
        public var italic = false
        public var code = false
        public var struck = false

        public init(_ text: String, bold: Bool = false, italic: Bool = false, code: Bool = false, struck: Bool = false) {
            self.text = text
            self.bold = bold
            self.italic = italic
            self.code = code
            self.struck = struck
        }
    }

    /// A block of Markdown made one line: each line's own marks — a
    /// heading's #s, a list's bullet or number, a quote's >, a fence —
    /// gone; a table's rows their cells, apart; what's inline kept.
    public static func flattened(_ s: String) -> String {
        var out: [String] = []
        for raw in s.split(separator: "\n", omittingEmptySubsequences: true) {
            var line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("```") || line.hasPrefix("~~~") { continue }
            // A table: its rule gone, its cells apart.
            if line.hasPrefix("|") {
                if line.allSatisfy({ "|-: ".contains($0) }) { continue }
                line = line.split(separator: "|").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }.joined(separator: " · ")
            }
            if line.allSatisfy({ "-*_ ".contains($0) }), line.filter({ $0 != " " }).count >= 3 { continue }
            while line.hasPrefix(">") { line = String(line.dropFirst()).trimmingCharacters(in: .whitespaces) }
            if let r = line.range(of: #"^#{1,6}\s+"#, options: .regularExpression) { line.removeSubrange(r) }
            if let r = line.range(of: #"^([-*+]|\d{1,3}[.)])\s+(\[[ xX]\]\s+)?"#, options: .regularExpression) { line.removeSubrange(r) }
            if !line.isEmpty { out.append(line) }
        }
        return out.joined(separator: " ")
    }

    /// The line as spans, in order, as the outline's own reading of
    /// inline Markdown (`InlineMarkup`) has it: each mark's characters
    /// gone, a picture by its words, a comment gone.
    public static func spans(_ s: String) -> [Span] {
        // An escaped mark is no mark: each set aside as a character of
        // Unicode's private use while the rest is read, and put back.
        var escaped: [Character: Character] = [:]
        var source = ""
        var chars = Array(s)[...]
        while let ch = chars.popFirst() {
            if ch == "\\", let next = chars.first, next.isPunctuation || next.isSymbol {
                chars.removeFirst()
                let stand = Character(UnicodeScalar(0xE000 + escaped.count % 6000)!)
                escaped[stand] = next
                source.append(stand)
            } else {
                source.append(ch)
            }
        }
        let back: (String) -> String = { escaped.isEmpty ? $0 : String($0.map { escaped[$0] ?? $0 }) }
        return spansOf(source).map { var x = $0; x.text = back(x.text); return x }
    }

    private static func spansOf(_ s: String) -> [Span] {
        let ns = s as NSString
        let found = InlineMarkup.spans(in: ns, range: NSRange(location: 0, length: ns.length))
        var hidden = IndexSet()
        for span in found {
            for r in span.markup { hidden.insert(integersIn: r.location..<NSMaxRange(r)) }
        }
        var out: [Span] = []
        var i = 0
        while i < ns.length {
            guard !hidden.contains(i) else { i += 1; continue }
            let around = found.filter { NSLocationInRange(i, $0.content) }
            var span = Span("")
            for f in around {
                switch f.kind {
                case .strong: span.bold = true
                case .emphasis: span.italic = true
                case .code: span.code = true
                case .strikethrough: span.struck = true
                default: break
                }
            }
            // A picture: its words, where it has them.
            if let image = found.first(where: { $0.isImage && $0.range.location == i }), case let .image(ref) = image.kind {
                if !ref.alt.isEmpty { out.append(Span(ref.alt)) }
                i = NSMaxRange(image.range)
                continue
            }
            let r = ns.rangeOfComposedCharacterSequence(at: i)
            span.text = ns.substring(with: r)
            out.append(span)
            i = NSMaxRange(r)
        }
        return merged(out)
    }

    /// Neighbours alike, one span.
    private static func merged(_ spans: [Span]) -> [Span] {
        var out: [Span] = []
        for s in spans where !s.text.isEmpty {
            if var last = out.last, last.bold == s.bold, last.italic == s.italic, last.code == s.code, last.struck == s.struck {
                last.text += s.text
                out[out.count - 1] = last
            } else {
                out.append(s)
            }
        }
        return out
    }

    /// Typed quotes as set ones: an apostrophe and a closing quote ’ ”,
    /// an opening one ‘ “ — at the start, or after a space or an opening
    /// bracket or dash.
    public static func curled(_ s: String) -> String {
        guard s.contains("'") || s.contains("\"") else { return s }
        var out = ""
        var before: Character? = nil
        for ch in s {
            let opens = before == nil || before!.isWhitespace || "([{—–-/".contains(before!)
            switch ch {
            case "'": out.append(opens ? "‘" : "’")
            case "\"": out.append(opens ? "“" : "”")
            default: out.append(ch)
            }
            before = ch
        }
        return out
    }

    /// Its words alone.
    public static func plain(_ s: String) -> String { spans(s).map(\.text).joined() }
}
