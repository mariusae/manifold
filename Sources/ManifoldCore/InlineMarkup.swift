import Foundation

/// A stretch of inline Markdown in a row: what it is, the text it shows, and
/// the markup around that text, which the outline hides (Prism's, as the
/// outliner lens shows a note, §7.9).
public struct InlineSpan: Equatable, Sendable {
    public enum Kind: Equatable, Sendable {
        case strong, emphasis, strikethrough, code
        /// `==text==`: marked as with a highlighter.
        case highlight
        /// `[text](url)`, and `<url>`.
        case link(String)
        /// `[[title]]` or `[[title|text]]`.
        case wikiLink(String)
        /// A bare `https://…`; nothing to hide.
        case url(String)
        /// `![text](source)`, and the size Prism's editor may note in a
        /// comment straight after it: `<!-- {"width":425,"height":270} -->`.
        /// Drawn as the picture; the Markdown is hidden, whole.
        case image(ImageReference)
        /// An image the app cannot show — a page, not a picture — left as
        /// the Markdown it is.
        case imageText
        /// `<!-- … -->`, hidden whole.
        case comment
        case tag
    }

    public var kind: Kind
    /// The span, markup included.
    public var range: NSRange
    /// The text it shows. Empty, at the span's start, for a comment.
    public var content: NSRange
    /// A web link written `[text](address "no card")`: shown without the
    /// card — a post, a video, a page — that would otherwise follow it.
    public var hidesCard = false

    public var isImage: Bool { if case .image = kind { true } else { false } }

    /// The markup before and after the content, which is not shown.
    public var markup: [NSRange] {
        switch kind {
        case .url, .imageText, .tag: return []
        case .comment, .image: return [range]
        default:
            return [NSRange(location: range.location, length: content.location - range.location),
                    NSRange(location: NSMaxRange(content), length: NSMaxRange(range) - NSMaxRange(content))]
                .filter { $0.length > 0 }
        }
    }
}

/// Where an image comes from, and the size it is to be shown at, when the
/// note says.
public struct ImageReference: Equatable, Hashable, Sendable {
    public var source: String
    public var alt: String
    public var width: Double?
    public var height: Double?

    public init(source: String, alt: String = "", width: Double? = nil, height: Double? = nil) {
        self.source = source
        self.alt = alt
        self.width = width
        self.height = height
    }

    /// Reads `{"width":425,"height":270}`, either key alone, or neither.
    static func size(from json: String) -> (width: Double?, height: Double?) {
        guard let data = json.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return (nil, nil) }
        func number(_ key: String) -> Double? { (object[key] as? NSNumber)?.doubleValue }
        return (number("width"), number("height"))
    }
}

/// Finding the inline Markdown in a line of text.
///
/// Code comes first, since nothing inside it is Markdown; then links, whose
/// addresses are not either; then emphasis, which may sit inside a link's
/// text, or hold one, but never straddle its markup.
public enum InlineMarkup {
    private static let code = try! NSRegularExpression(pattern: #"(`+)(?!`)(.+?)(?<!`)\1(?!`)"#)
    private static let comment = try! NSRegularExpression(pattern: #"<!--.*?-->"#)
    private static let image = try! NSRegularExpression(pattern: #"!\[([^\[\]\n]*)\]\(([^)\s]*)\)(?:<!--\s*(\{[^{}\n]*\})\s*-->)?"#)
    private static let wiki = try! NSRegularExpression(pattern: #"\[\[([^\[\]|\n]+)(?:\|([^\[\]\n]*))?\]\]"#)
    /// `[text](address)`, or with a title after the address: `[text](address "title")`.
    private static let link = try! NSRegularExpression(pattern: #"\[([^\[\]\n]+)\]\(([^)\s]*)(?:\s+"([^"\n]*)")?\)"#)
    private static let autolink = try! NSRegularExpression(pattern: #"<(https?://[^\s<>]+)>"#)
    private static let url = try! NSRegularExpression(pattern: #"\bhttps?://[^\s<>\x{2028}]+[^\s<>.,;:!?)\]'"\x{2028}]"#)
    private static let tag = try! NSRegularExpression(pattern: #"(?<=^|\s)#\p{L}[\p{L}\p{N}/_-]*"#)
    private static let strong = try! NSRegularExpression(pattern: #"(\*\*|__)(?=\S)(.+?)(?<=\S)\1"#)
    private static let strike = try! NSRegularExpression(pattern: #"~~(?=\S)(.+?)(?<=\S)~~"#)
    /// Not a run of `=`, as a conflict's divider is.
    private static let highlight = try! NSRegularExpression(pattern: #"(?<!=)==(?=[^\s=])(.+?)(?<=[^\s=])==(?!=)"#)
    private static let emphasis = try! NSRegularExpression(pattern: #"(?<![*_\w])([*_])(?=[^\s*_])(.+?)(?<=[^\s*_])\1(?![*_\w])"#)

    /// Text with its Markdown taken out: what it says, as it is shown —
    /// links by their text, emphasis without its marks, pictures left out.
    public static func plainText(_ text: String) -> String {
        let ns = text as NSString
        let spans = spans(in: ns, range: NSRange(location: 0, length: ns.length))
        var edits: [(NSRange, String)] = []
        for span in spans where !spans.contains(where: { $0 != span && NSLocationInRange(span.range.location, $0.range) && $0.range.length > span.range.length && ($0.isImage || $0.kind == .comment) }) {
            switch span.kind {
            case .image, .comment: edits.append((span.range, ""))
            default: edits.append(contentsOf: span.markup.map { ($0, "") })
            }
        }
        let result = NSMutableString(string: text)
        for (range, replacement) in edits.sorted(by: { $0.0.location > $1.0.location }) where NSMaxRange(range) <= result.length {
            result.replaceCharacters(in: range, with: replacement)
        }
        return (result as String).replacingOccurrences(of: "\\", with: "").trimmingCharacters(in: .whitespaces)
    }

    /// The spans in a range of text, outermost first where they nest.
    public static func spans(in text: NSString, range: NSRange) -> [InlineSpan] {
        var spans: [InlineSpan] = []
        let string = text as String

        func add(_ pattern: NSRegularExpression, _ make: (NSTextCheckingResult) -> InlineSpan?) {
            // (Not enumerateMatches: its closure escapes on Linux.)
            for match in pattern.matches(in: string, range: range) {
                guard let span = make(match), fits(span, among: spans) else { continue }
                spans.append(span)
            }
        }
        func group(_ match: NSTextCheckingResult, _ index: Int) -> String {
            text.substring(with: match.range(at: index))
        }

        add(code) { InlineSpan(kind: .code, range: $0.range, content: $0.range(at: 2)) }
        add(image) { match in
            let size = match.range(at: 3).location == NSNotFound ? (nil, nil) : ImageReference.size(from: group(match, 3))
            let reference = ImageReference(source: group(match, 2), alt: group(match, 1), width: size.0, height: size.1)
            return InlineSpan(kind: .image(reference), range: match.range, content: NSRange(location: match.range.location, length: 0))
        }
        add(comment) { InlineSpan(kind: .comment, range: $0.range, content: NSRange(location: $0.range.location, length: 0)) }
        add(wiki) { match in
            let label = match.range(at: 2)
            let content = label.location != NSNotFound && label.length > 0 ? label : match.range(at: 1)
            return InlineSpan(kind: .wikiLink(group(match, 1)), range: match.range, content: content)
        }
        add(link) { match in
            var span = InlineSpan(kind: .link(group(match, 2)), range: match.range, content: match.range(at: 1))
            // (Prism's `"no card"` title: a link written so shows no card.)
            span.hidesCard = match.range(at: 3).location != NSNotFound && group(match, 3) == "no card"
            return span
        }
        add(autolink) { InlineSpan(kind: .link(group($0, 1)), range: $0.range, content: $0.range(at: 1)) }
        add(url) { InlineSpan(kind: .url(text.substring(with: $0.range)), range: $0.range, content: $0.range) }
        add(tag) { InlineSpan(kind: .tag, range: $0.range, content: $0.range) }
        add(strong) { InlineSpan(kind: .strong, range: $0.range, content: $0.range(at: 2)) }
        add(strike) { InlineSpan(kind: .strikethrough, range: $0.range, content: $0.range(at: 1)) }
        add(highlight) { InlineSpan(kind: .highlight, range: $0.range, content: $0.range(at: 1)) }
        add(emphasis) { InlineSpan(kind: .emphasis, range: $0.range, content: $0.range(at: 2)) }
        return spans.sorted { ($0.range.location, -$0.range.length) < ($1.range.location, -$1.range.length) }
    }

    /// Whether a span can stand beside those found before it: apart from
    /// each, or wholly inside the text of one, or holding one wholly in its
    /// own text. Nothing goes inside code, a URL, or an image.
    private static func fits(_ span: InlineSpan, among spans: [InlineSpan]) -> Bool {
        spans.allSatisfy { other in
            if NSIntersectionRange(span.range, other.range).length == 0 { return true }
            // A bare address in a link's text is the link, not another.
            if case .url = span.kind, case .link = other.kind { return false }
            let opaque: Bool
            switch other.kind {
            case .code, .url, .image, .imageText, .comment, .tag: opaque = true
            default: opaque = false
            }
            if !opaque, contains(other.content, span.range) { return true }
            if contains(span.content, other.range) {
                if case .code = span.kind { return false }
                return true
            }
            return false
        }
    }

    private static func contains(_ outer: NSRange, _ inner: NSRange) -> Bool {
        inner.location >= outer.location && NSMaxRange(inner) <= NSMaxRange(outer)
    }

    /// The runs of hidden markup in a range, each run the markup of one
    /// span, in order.
    public static func hiddenRuns(in text: NSString, range: NSRange) -> [NSRange] {
        spans(in: text, range: range).flatMap(\.markup).sorted { $0.location < $1.location }
    }
}

/// Arrows typed as two characters — `->`, `<-`, `<->` — shown as one; the
/// text itself left as typed.
public enum TypedArrows {
    /// Each arrow in a range: where its characters are, and the arrow it shows.
    /// Not in code, nor in what `skipping` covers.
    public static func find(in text: NSString, range: NSRange, skipping: [NSRange] = []) -> [(range: NSRange, arrow: String)] {
        var found: [(NSRange, String)] = []
        var at = range.location
        let end = NSMaxRange(range)
        while at + 1 < end {
            let a = text.character(at: at), b = text.character(at: at + 1)
            var match: (Int, String)?
            if a == 0x3C, b == 0x2D { // <-
                match = at + 2 < end && text.character(at: at + 2) == 0x3E ? (3, "↔") : (2, "←")
            } else if a == 0x2D, b == 0x3E { // ->
                // Not the end of a longer run, `-->`, nor an HTML comment's.
                if !(at > range.location && text.character(at: at - 1) == 0x2D) { match = (2, "→") }
            }
            if let (length, arrow) = match {
                let candidate = NSRange(location: at, length: length)
                if !skipping.contains(where: { NSIntersectionRange($0, candidate).length > 0 }) {
                    found.append((candidate, arrow))
                }
                at += length
            } else {
                at += 1
            }
        }
        return found
    }
}
