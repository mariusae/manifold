import Foundation

// Inline Markdown: the spans in a block's text.
//
// A block keeps its text as the Markdown it was written in. `Inline.parse`
// finds what that text means — emphasis, links, tags, pictures — as a tree
// of `Span`s, each a byte range of the text with the range of what it shows
// inside it. Nothing is rewritten.
//
// The dialect: `**strong**`, `*emphasis*`, `` `code` ``, `~~struck~~`,
// `==highlighted==`, `[text](url)`, `<https://…>`, bare `https://…`,
// `[[Title]]`, `[[Title|shown]]`, `![[Title]]`, `![alt](src)<!-- {"width":425} -->`,
// `#tag`, `<!-- comments -->` and backslash escapes. Code comes first, since
// nothing inside it is Markdown; then links and pictures, whose addresses are
// not either; then emphasis, which may hold a link or sit inside a link's
// text, but never straddles its markup.

extension Markup {
    /// What a span is.
    public enum SpanKind: Equatable, Sendable {
        case strong, emphasis, strikethrough
        /// `==text==`.
        case highlight
        /// `` `code` ``: its content is shown as written.
        case code
        /// `[text](target)`, maybe with a title.
        case link(target: String, title: String?)
        /// `<https://…>`.
        case autolink(url: String)
        /// A bare `https://…`; there is no markup to hide.
        case url
        /// `[[target]]` or `[[target|label]]`; with `embed`, `![[target]]`.
        case wikiLink(target: String, label: String?, embed: Bool)
        /// `![alt](source)`, and the size noted in a comment straight after.
        case image(source: String, alt: String, width: Double?, height: Double?)
        /// `#tag`: the name, without its `#`.
        case tag(String)
        /// `<!-- … -->`: hidden whole.
        case comment
        /// `\*`: the character, taken literally.
        case escape
    }

    /// A stretch of inline Markdown.
    public struct Span: Equatable, Sendable {
        public var kind: SpanKind
        /// The whole span, markup included, as bytes of the text.
        public var range: Range<Int>
        /// What it shows. Empty, at the span's start, for a picture or a
        /// comment, which show none of their text.
        public var content: Range<Int>
        /// The spans within the content.
        public var children: [Span] = []

        /// This span and every span in it, outermost first.
        public var walk: [Span] { [self] + children.flatMap(\.walk) }
    }

    /// A style a toggle puts on, or takes off.
    public enum Style: Equatable, Sendable {
        case strong, emphasis, strikethrough, highlight, code

        var delimiter: String {
            switch self {
            case .strong: return "**"
            case .emphasis: return "*"
            case .strikethrough: return "~~"
            case .highlight: return "=="
            case .code: return "`"
            }
        }

        func matches(_ kind: SpanKind) -> Bool {
            switch (self, kind) {
            case (.strong, .strong), (.emphasis, .emphasis), (.strikethrough, .strikethrough), (.highlight, .highlight), (.code, .code): return true
            default: return false
            }
        }
    }

    public enum Inline {
        /// The spans in a text, in order; nested ones are their parents' children.
        public static func parse(_ text: String) -> [Span] {
            let t = text.u8
            return parseRange(t, 0, t.count)
        }

        static func parse(bytes t: Bytes) -> [Span] { parseRange(t, 0, t.count) }

        /// Every span in a text, nested ones included, outermost first.
        public static func walk(_ spans: [Span]) -> [Span] { spans.flatMap(\.walk) }

        /// Where a wiki link's target is written in the text: what a rename
        /// rewrites. nil for a span that is no wiki link.
        public static func wikiTargetRange(_ text: String, _ span: Span) -> Range<Int>? {
            guard case .wikiLink(_, _, let embed) = span.kind else { return nil }
            let t = text.u8
            let start = span.range.lowerBound + (embed ? 3 : 2)
            guard span.range.upperBound >= 2, start <= span.range.upperBound - 2 else { return nil }
            let body = t.sub(start..<(span.range.upperBound - 2))
            // `target`, `target|shown`, or `target\|shown` in a table.
            let cut = body.find("\\|".u8) ?? body.find(byte: UInt8(ascii: "|")) ?? body.count
            let written = body.sub(0..<cut)
            let leading = written.count - written.trimmedStart.count
            return (start + leading)..<(start + leading + written.trimmed.count)
        }

        /// A text with its Markdown taken out: what it says, as it is shown —
        /// links by their text, emphasis without its marks, pictures and
        /// comments left out.
        public static func plainText(_ text: String) -> String {
            let t = text.u8
            var out = Bytes()
            out.reserveCapacity(t.count)
            func emit(_ range: Range<Int>, _ spans: [Span]) {
                var at = range.lowerBound
                for span in spans {
                    out.append(contentsOf: t[at..<span.range.lowerBound])
                    switch span.kind {
                    case .image, .comment: break
                    case .wikiLink(let target, let label, _): out.append(contentsOf: (label ?? target).utf8)
                    case .tag, .url: out.append(contentsOf: t[span.range])
                    default: emit(span.content, span.children)
                    }
                    at = span.range.upperBound
                }
                out.append(contentsOf: t[at..<range.upperBound])
            }
            emit(0..<t.count, parseRange(t, 0, t.count))
            return out.trimmed.string
        }

        /// Puts a style on a range of a text, or takes it off when the range
        /// is exactly a span of that style (its content, or all of it). Gives
        /// the new text, and the range the same words now have in it.
        public static func toggle(_ text: String, _ range: Range<Int>, _ style: Style) -> (String, Range<Int>) {
            let t = text.u8
            if let span = walk(parse(bytes: t)).first(where: { style.matches($0.kind) && ($0.content == range || $0.range == range) }) {
                var out = t.sub(0..<span.range.lowerBound)
                out += t[span.content]
                out += t[span.range.upperBound...]
                return (out.string, span.range.lowerBound..<(span.range.lowerBound + span.content.count))
            }
            if range.isEmpty || range.upperBound > t.count || !t.isBoundary(range.lowerBound) || !t.isBoundary(range.upperBound) { return (text, range) }
            let d = style.delimiter
            let out = t.string(0..<range.lowerBound) + d + t.string(range) + d + t.string(range.upperBound..<t.count)
            return (out, (range.lowerBound + d.utf8.count)..<(range.upperBound + d.utf8.count))
        }

        /// The picture that ends just before a place in a text, if one does:
        /// all of its markup, with the size written after it.
        public static func pictureBefore(_ text: String, _ at: Int) -> Range<Int>? {
            let t = text.u8
            let spans = parse(bytes: t)
            guard let before = spans.firstIndex(where: { $0.range.upperBound == at }) else { return nil }
            switch spans[before].kind {
            case .image: return spans[before].range
            case .comment where t.sub(spans[before].range).contains(UInt8(ascii: "{")):
                // A size parted from its picture by spaces is still the picture's.
                guard before > 0, case .image = spans[before - 1].kind else { return nil }
                let picture = spans[before - 1]
                return t.trimmed(picture.range.upperBound..<spans[before].range.lowerBound).isEmpty ? picture.range.lowerBound..<at : nil
            default: return nil
            }
        }

        /// A text that is a web or mail address and nothing else, trimmed.
        public static func address(_ text: String) -> String? {
            let text = text.trimmedWS
            if text.isEmpty || text.unicodeScalars.contains(where: \.isWS) { return nil }
            let t = text.u8
            guard let colon = t.find(byte: UInt8(ascii: ":")) else { return nil }
            let scheme = t.string(0..<colon).lowercased()
            let rest = t.sub(from: colon + 1)
            func host() -> Bool {
                guard rest.hasPrefix("//".u8) else { return false }
                let after = rest.sub(from: 2)
                let end = after.firstIndex(where: { $0 == UInt8(ascii: "/") || $0 == UInt8(ascii: "?") || $0 == UInt8(ascii: "#") }) ?? after.count
                return end > 0
            }
            if (scheme == "http" || scheme == "https") && host() { return text }
            if scheme == "mailto" && !rest.isEmpty { return text }
            return nil
        }

        /// Links a range of a text to an address: `[words](address)` — or,
        /// when the words are a link's already, points that link there. Gives
        /// the new text, and where the link ends in it. nil when the range is
        /// empty, spans lines, or is itself an address.
        public static func link(_ text: String, _ range: Range<Int>, to target: String) -> (String, Int)? {
            let t = text.u8
            if range.isEmpty || range.upperBound > t.count || !t.isBoundary(range.lowerBound) || !t.isBoundary(range.upperBound) { return nil }
            let words = t.sub(range)
            if words.contains(.newline) || words.contains("\u{2028}".u8) || address(words.string) != nil { return nil }
            // Brackets and spaces in an address would end its Markdown early.
            let target = escapedAddress(target)
            let inside = { (span: Span) -> Bool in
                if case .link = span.kind { return span.content.lowerBound <= range.lowerBound && range.upperBound <= span.content.upperBound }
                return false
            }
            if let span = walk(parse(bytes: t)).first(where: inside) {
                // Already a link's words: only where it goes changes.
                let old = (span.content.upperBound + 2)..<(span.range.upperBound - 1)
                let end = span.range.upperBound - old.count + target.utf8.count
                return (t.string(0..<old.lowerBound) + target + t.string(old.upperBound..<t.count), end)
            }
            let linked = "[" + words.string.replacingOccurrences(of: "[", with: "\\[").replacingOccurrences(of: "]", with: "\\]") + "](" + target + ")"
            let end = range.lowerBound + linked.utf8.count
            return (t.string(0..<range.lowerBound) + linked + t.string(range.upperBound..<t.count), end)
        }

        /// An address as a link's Markdown can hold it.
        static func escapedAddress(_ target: String) -> String {
            target.trimmedWS.replacingOccurrences(of: " ", with: "%20").replacingOccurrences(of: "(", with: "%28").replacingOccurrences(of: ")", with: "%29")
        }

        // --- The scanner ---------------------------------------------------

        static func parseRange(_ t: Bytes, _ start: Int, _ end: Int) -> [Span] {
            var spans: [Span] = []
            var at = start
            while at < end {
                if let span = atomicAt(t, at, start, end) ?? delimitedAt(t, at, start, end) {
                    at = span.range.upperBound
                    spans.append(span)
                } else {
                    at += t.charLen(at: at)
                }
            }
            return spans
        }

        /// Whether these bytes are at an offset, before `end`.
        static func starts(_ t: Bytes, _ at: Int, _ end: Int, _ needle: String) -> Bool {
            let n = needle.utf8
            guard at + n.count <= end else { return false }
            var i = at
            for b in n { if t[i] != b { return false }; i += 1 }
            return true
        }

        /// The first place, from `from` and before `end`, whose character is so.
        static func firstChar(_ t: Bytes, _ from: Int, _ end: Int, _ test: (Unicode.Scalar) -> Bool) -> Int? {
            var at = from
            while at < end {
                if let c = t.scalar(at: at), test(c) { return at }
                at += t.charLen(at: at)
            }
            return nil
        }

        static func leaf(_ kind: SpanKind, _ range: Range<Int>, _ content: Range<Int>) -> Span? { Span(kind: kind, range: range, content: content) }

        /// A span that starts at `at` and whose inside is not searched for
        /// emphasis delimiters: code, a comment, a picture, a link, a tag.
        static func atomicAt(_ t: Bytes, _ at: Int, _ start: Int, _ end: Int) -> Span? {
            switch t[at] {
            case UInt8(ascii: "\\"):
                guard at + 1 < end, let next = t.scalar(at: at + 1), next.isAsciiPunct else { return nil }
                return leaf(.escape, at..<(at + 2), (at + 1)..<(at + 2))
            case UInt8(ascii: "`"):
                var run = 0
                while at + run < end && t[at + run] == UInt8(ascii: "`") { run += 1 }
                // The closing run: as many backticks, no more, on either side.
                var search = at + run
                while let close = t.find(byte: UInt8(ascii: "`"), from: search, to: end) {
                    var closeRun = 0
                    while close + closeRun < end && t[close + closeRun] == UInt8(ascii: "`") { closeRun += 1 }
                    if closeRun == run && close > at + run { return leaf(.code, at..<(close + run), (at + run)..<close) }
                    search = close + closeRun
                }
                return nil
            case UInt8(ascii: "<"):
                if starts(t, at, end, "<!--") {
                    guard let close = t.find("-->".u8, from: at + 4, to: end) else { return nil }
                    return leaf(.comment, at..<(close + 3), at..<at)
                }
                let inner = at + 1
                guard starts(t, inner, end, "http://") || starts(t, inner, end, "https://") else { return nil }
                guard let close = firstChar(t, inner, end, { $0.isWS || $0 == "<" || $0 == ">" }), t[close] == UInt8(ascii: ">") else { return nil }
                return leaf(.autolink(url: t.string(inner..<close)), at..<(close + 1), inner..<close)
            case UInt8(ascii: "!") where starts(t, at, end, "![["):
                guard var span = wikiLink(t, at + 1, end) else { return nil }
                span.range = at..<span.range.upperBound
                if case .wikiLink(let target, let label, _) = span.kind { span.kind = .wikiLink(target: target, label: label, embed: true) }
                return span
            case UInt8(ascii: "!") where starts(t, at, end, "!["):
                return image(t, at, end)
            case UInt8(ascii: "[") where starts(t, at, end, "[["):
                return wikiLink(t, at, end) ?? link(t, at, end)
            case UInt8(ascii: "["):
                return link(t, at, end)
            case UInt8(ascii: "h") where starts(t, at, end, "http://") || starts(t, at, end, "https://"):
                if at > start, let before = t.scalar(before: at), before.isAlnum || before == "_" { return nil }
                let scheme = starts(t, at, end, "https://") ? 8 : 7
                var len = (firstChar(t, at, end, { $0.isWS || $0 == "<" || $0 == ">" || $0 == "\u{2028}" }) ?? end) - at
                let trailing = ".,;:!?)]'\"".u8
                while len > scheme && trailing.contains(t[at + len - 1]) { len -= 1 }
                return len > scheme ? leaf(.url, at..<(at + len), at..<(at + len)) : nil
            case UInt8(ascii: "#"):
                if at > start, let before = t.scalar(before: at), !before.isWS { return nil }
                guard at + 1 < end, let first = t.scalar(at: at + 1), first.isAlpha else { return nil }
                let nameEnd = firstChar(t, at + 1, end, { !($0.isAlnum || $0 == "/" || $0 == "_" || $0 == "-") }) ?? end
                return leaf(.tag(t.string((at + 1)..<nameEnd)), at..<nameEnd, (at + 1)..<nameEnd)
            default:
                return nil
            }
        }

        /// `[[target]]` or `[[target|label]]`, starting at `at`.
        static func wikiLink(_ t: Bytes, _ at: Int, _ end: Int) -> Span? {
            let bodyStart = at + 2
            guard let close = t.find("]]".u8, from: bodyStart, to: end) else { return nil }
            let body = t.sub(bodyStart..<close)
            if body.contains(UInt8(ascii: "[")) || body.contains(UInt8(ascii: "]")) || body.contains(.newline) { return nil }
            var target = body
            var label: Bytes? = nil
            if let bar = body.find(byte: UInt8(ascii: "|")) {
                target = body.sub(0..<bar)
                // In a table a pipe is written `\|`.
                if target.last == UInt8(ascii: "\\") { target.removeLast() }
                label = body.sub(from: bar + 1)
            }
            if target.isBlankWS { return nil }
            let shown = label.flatMap { $0.isEmpty ? nil : $0 }
            let content = shown.map { (bodyStart + body.count - $0.count)..<(bodyStart + body.count) } ?? bodyStart..<(bodyStart + target.count)
            return Span(kind: .wikiLink(target: target.trimmed.string, label: shown?.string, embed: false), range: at..<(close + 2), content: content)
        }

        /// The first of `[`, `]` or a line break in a range: where a link's
        /// words end, if a `](` is there.
        static func wordsEnd(_ t: Bytes, _ from: Int, _ end: Int) -> Int? {
            var i = from
            while i < end {
                let b = t[i]
                if b == UInt8(ascii: "[") || b == UInt8(ascii: "]") || b == .newline { return starts(t, i, end, "](") ? i : nil }
                i += 1
            }
            return nil
        }

        /// `[text](target)` or `[text](target "title")`, starting at `at`.
        static func link(_ t: Bytes, _ at: Int, _ end: Int) -> Span? {
            guard let close = wordsEnd(t, at + 1, end), close > at + 1 else { return nil }
            guard let (target, title, len) = destination(t, close + 2, end, allowTitle: true).map({ ($0.0, $0.1, $0.2) }) else { return nil }
            let content = (at + 1)..<close
            return Span(kind: .link(target: target, title: title), range: at..<(close + 2 + len), content: content,
                        children: parseRange(t, content.lowerBound, content.upperBound))
        }

        /// What follows `](`: the address, a title when allowed, and how many
        /// bytes they take, the closing `)` included.
        static func destination(_ t: Bytes, _ from: Int, _ end: Int, allowTitle: Bool) -> (String, String?, Int)? {
            guard let targetEnd = firstChar(t, from, end, { $0 == ")" || $0.isWS }) else { return nil }
            let target = t.string(from..<targetEnd)
            if t[targetEnd] == UInt8(ascii: ")") { return (target, nil, targetEnd - from + 1) }
            if !allowTitle { return nil }
            var spaces = 0
            while targetEnd + spaces < end && (t[targetEnd + spaces] == .space || t[targetEnd + spaces] == .tab) { spaces += 1 }
            let quoteAt = targetEnd + spaces
            guard quoteAt < end, t[quoteAt] == UInt8(ascii: "\"") else { return nil }
            var i = quoteAt + 1
            while i < end && t[i] != UInt8(ascii: "\"") && t[i] != .newline { i += 1 }
            guard i < end, starts(t, i, end, "\")") else { return nil }
            return (target, t.string((quoteAt + 1)..<i), i + 2 - from)
        }

        /// `![alt](source)`, with the size comment that may follow it.
        static func image(_ t: Bytes, _ at: Int, _ end: Int) -> Span? {
            guard let close = wordsEnd(t, at + 2, end) else { return nil }
            guard let (source, _, len) = destination(t, close + 2, end, allowTitle: false) else { return nil }
            var rangeEnd = close + 2 + len
            var (width, height): (Double?, Double?) = (nil, nil)
            // `<!-- {"width":425,"height":270} -->`, straight after.
            if starts(t, rangeEnd, end, "<!--"), let commentEnd = t.find("-->".u8, from: rangeEnd + 4, to: end) {
                let json = t.sub(t.trimmed((rangeEnd + 4)..<commentEnd))
                if json.first == UInt8(ascii: "{") && json.last == UInt8(ascii: "}") && json.count >= 2 {
                    let inner = json[1..<(json.count - 1)]
                    if !inner.contains(UInt8(ascii: "{")) && !inner.contains(UInt8(ascii: "}")) && !inner.contains(.newline) {
                        width = jsonNumber(json, "width")
                        height = jsonNumber(json, "height")
                        rangeEnd = commentEnd + 3
                    }
                }
            }
            return leaf(.image(source: source, alt: t.string((at + 2)..<close), width: width, height: height), at..<rangeEnd, at..<at)
        }

        /// A number under a key in a flat JSON object: all the size comment is.
        static func jsonNumber(_ json: Bytes, _ key: String) -> Double? {
            guard let found = json.find("\"\(key)\"".u8) else { return nil }
            var after = json.sub(from: found + key.utf8.count + 2).trimmedStart
            guard after.first == UInt8(ascii: ":") else { return nil }
            after = after.sub(from: 1).trimmedStart
            let len = after.firstIndex(where: { !($0.isAsciiDigit || ".-+eE".u8.contains($0)) }) ?? after.count
            return Double(after.string(0..<len))
        }

        /// Emphasis of some kind, opening at `at`.
        static func delimitedAt(_ t: Bytes, _ at: Int, _ start: Int, _ end: Int) -> Span? {
            let before: Unicode.Scalar? = at > start ? t.scalar(before: at) : nil
            func attempt(_ delimiter: String, _ kind: SpanKind) -> Span? {
                guard starts(t, at, end, delimiter) else { return nil }
                let d = delimiter.utf8.count
                let contentStart = at + d
                guard contentStart < end, let opensOn = t.scalar(at: contentStart) else { return nil }
                let mark = Unicode.Scalar(delimiter.utf8.first!)
                let wordBound = kind == .emphasis
                if opensOn.isWS || (d == 1 && opensOn == mark) || (kind == .highlight && opensOn == "=") { return nil }
                if wordBound, let before, before == "*" || before == "_" || before.isAlnum { return nil }
                if kind == .highlight && before == "=" { return nil }
                // The closer: the first that can close, on the same line,
                // outside any code or link between.
                var search = contentStart + opensOn.utf8Len
                while search < end {
                    if t[search] == .newline { return nil }
                    if let skip = atomicAt(t, search, start, end) {
                        search = skip.range.upperBound
                        continue
                    }
                    if starts(t, search, end, delimiter) {
                        var close = search
                        // In a longer run of the mark, the closer is its end:
                        // `***both***` is strong around emphasis.
                        while starts(t, close + 1, end, delimiter) { close += 1 }
                        let last = t.scalar(before: close)
                        let after: Unicode.Scalar? = close + d < end ? t.scalar(at: close + d) : nil
                        var closes = last.map { !$0.isWS && !(d == 1 && $0 == mark) } ?? false
                        if wordBound, let after, after == "*" || after == "_" || after.isAlnum { closes = false }
                        if kind == .highlight && (after == "=" || last == "=") { closes = false }
                        if closes {
                            return Span(kind: kind, range: at..<(close + d), content: contentStart..<close, children: parseRange(t, contentStart, close))
                        }
                        search = close + d
                        continue
                    }
                    search += t.charLen(at: search)
                }
                return nil
            }
            switch t[at] {
            case UInt8(ascii: "*"): return attempt("**", .strong) ?? attempt("*", .emphasis)
            case UInt8(ascii: "_"): return attempt("__", .strong) ?? attempt("_", .emphasis)
            case UInt8(ascii: "~"): return attempt("~~", .strikethrough)
            case UInt8(ascii: "="): return attempt("==", .highlight)
            default: return nil
            }
        }
    }
}
