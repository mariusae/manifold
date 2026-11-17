import Foundation

// A row's words as rich text: what they show, and how they are marked.
//
// A block keeps its words as the Markdown they were written in, and is
// written back as it was read unless it was edited. An editor shows them as
// `Rich`: the words as they read — no `**`, no brackets — with runs saying
// which are strong, emphasised, struck, highlighted, code, or a link's
// words. What is not words — a link to a page, a picture, a comment — is
// one `atom` character, with its Markdown kept to be written back as it
// was. Edits are made to the rich text; the Markdown is made again from it
// (`toMarkdown`), escaping only what would otherwise be read as Markdown.

extension Markup {
    /// What stands in the words for something that is not words: a link to
    /// a page, a picture, a comment. One character, drawn as what it is.
    public static let atom: Unicode.Scalar = "\u{FFFC}"
    static let atomBytes = "\u{FFFC}".u8

    /// How a stretch of the words is marked.
    public enum Mark: Equatable, Sendable {
        case strong
        /// With the character it was written with: `*` or `_`.
        case emphasis(Character)
        case strikethrough
        case highlight
        /// Its words shown as written; with how many backticks were around them.
        case code(Int)
        /// `[words](target "title")`.
        case link(target: String, title: String?)
        /// `<https://…>`: the address is the words.
        case autolink
        /// A bare address in the words: no Markdown of its own.
        case url
        /// `#tag`: words, read as a tag.
        case tag(String)
        /// What an atom stands for: its Markdown, as written.
        case atom(Atom)

        /// Whether it is a style that what is typed beside it takes on.
        var carries: Bool {
            switch self {
            case .strong, .emphasis, .strikethrough, .highlight: return true
            default: return false
            }
        }

        /// Whether it is written as Markdown around its words — as against
        /// words read as something (an address, a tag), or an atom.
        var wraps: Bool {
            switch self {
            case .url, .tag, .atom: return false
            default: return true
            }
        }

        var isAtom: Bool { if case .atom = self { return true } else { return false } }
        var isLink: Bool { if case .link = self { return true } else { return false } }
        var isCode: Bool { if case .code = self { return true } else { return false } }

        /// Which kind of mark it is, whatever it says.
        var discriminant: Int {
            switch self {
            case .strong: return 0
            case .emphasis: return 1
            case .strikethrough: return 2
            case .highlight: return 3
            case .code: return 4
            case .link: return 5
            case .autolink: return 6
            case .url: return 7
            case .tag: return 8
            case .atom: return 9
            }
        }

        /// The same kind of mark, whatever it says — for toggling.
        func sameKind(_ other: Mark) -> Bool { discriminant == other.discriminant }
    }

    /// What an atom stands for.
    public struct Atom: Equatable, Sendable {
        /// Its Markdown, written back as it was.
        public var source: String
        public var kind: AtomKind
    }

    public enum AtomKind: Equatable, Sendable {
        /// `[[target]]`, `[[target|label]]`, or — embedded — `![[target]]`.
        case page(target: String, label: String?, embed: Bool)
        /// `![alt](source)`, with any size noted after it.
        case picture(source: String, alt: String, width: Double?, height: Double?)
        /// `<!-- … -->`: nothing shown.
        case comment
    }

    /// A stretch of the words, marked: byte offsets of `Rich.bytes`.
    public struct RichRun: Equatable, Sendable {
        public var range: Range<Int>
        public var mark: Mark
    }

    /// A row's words, as rich text.
    public struct Rich: Equatable, Sendable {
        /// The words as they read, as UTF-8; an atom for each thing that is not words.
        public var bytes: [UInt8] = []
        /// The marks on them, in order of where they start.
        public var runs: [RichRun] = []

        public init() {}
        init(bytes: Bytes, runs: [RichRun] = []) { self.bytes = bytes; self.runs = runs }

        /// The words as they read.
        public var text: String { bytes.string }
    }
}

/// Where a part of the Markdown went in the words: `markdown` bytes are
/// shown as `shown` bytes (the same, for plain words; none, for markup; one
/// atom, for an atom's).
private struct Piece {
    var markdown: Range<Int>
    var shown: Range<Int>
    /// Plain words, shown byte for byte as written.
    var plain: Bool
}

/// The references a space or a tab is written as where Markdown would drop
/// it — at a line's start or end — and what each stands for.
private let keptSpaces: [(Bytes, UInt8)] = [("&#32;".u8, .space), ("&#9;".u8, .tab)]

private enum Escaping { case none, least, underscores, all }

extension Markup.Rich {
    public typealias Mark = Markup.Mark
    public typealias Run = Markup.RichRun

    /// A row's words, read from their Markdown.
    public static func parse(_ markdown: String) -> Markup.Rich { read(markdown.u8).0 }

    /// Plain words, marked with nothing.
    public static func plain(_ text: String) -> Markup.Rich { Markup.Rich(bytes: text.u8) }
    static func plain(bytes: Bytes) -> Markup.Rich { Markup.Rich(bytes: bytes) }

    /// A row's words read from their Markdown, with where each part went.
    fileprivate static func read(_ md: Bytes) -> (Markup.Rich, [Piece]) {
        var rich = Markup.Rich()
        var pieces: [Piece] = []
        let spans = Markup.Inline.parse(bytes: md)
        emit(md, 0..<md.count, spans, &rich, &pieces)
        // One mark read in pieces — italics around bold — is one run.
        rich.tidy()
        return (rich, pieces)
    }

    fileprivate static func pushPlain(_ md: Bytes, _ range: Range<Int>, _ rich: inout Markup.Rich, _ pieces: inout [Piece]) {
        if range.isEmpty { return }
        // Spaces at a line's start or end are no words — Markdown drops them — but markup.
        func blank(_ b: UInt8) -> Bool { b == .space || b == .tab }
        var edge: Range<Int>? = nil
        var at = range.lowerBound
        while at < range.upperBound {
            if blank(md[at]) {
                var end = at
                while end < range.upperBound && blank(md[end]) { end += 1 }
                var runEnd = at
                while runEnd < md.count && blank(md[runEnd]) { runEnd += 1 }
                if at == 0 || md[at - 1] == .newline || runEnd == md.count || md[runEnd] == .newline {
                    edge = at..<end
                    break
                }
                at = end
            } else {
                at += 1
            }
        }
        if let edge {
            pushPlain(md, range.lowerBound..<edge.lowerBound, &rich, &pieces)
            pushMarkup(edge, rich, &pieces)
            return pushPlain(md, edge.upperBound..<range.upperBound, &rich, &pieces)
        }
        // A space kept by its reference is shown as the space; the reference is markup.
        var next: (Int, Bytes, UInt8)? = nil
        for (written, c) in keptSpaces {
            if let found = md.find(written, from: range.lowerBound, to: range.upperBound), next == nil || found < next!.0 { next = (found, written, c) }
        }
        if let (found, written, c) = next {
            pushPlain(md, range.lowerBound..<found, &rich, &pieces)
            let at = rich.bytes.count
            rich.bytes.append(c)
            pieces.append(Piece(markdown: found..<(found + written.count), shown: at..<rich.bytes.count, plain: false))
            return pushPlain(md, (found + written.count)..<range.upperBound, &rich, &pieces)
        }
        let start = rich.bytes.count
        rich.bytes.append(contentsOf: md[range])
        pieces.append(Piece(markdown: range, shown: start..<rich.bytes.count, plain: true))
    }

    fileprivate static func pushMarkup(_ range: Range<Int>, _ rich: Markup.Rich, _ pieces: inout [Piece]) {
        if !range.isEmpty {
            let at = rich.bytes.count
            pieces.append(Piece(markdown: range, shown: at..<at, plain: false))
        }
    }

    fileprivate static func emit(_ md: Bytes, _ range: Range<Int>, _ spans: [Markup.Span], _ rich: inout Markup.Rich, _ pieces: inout [Piece]) {
        var at = range.lowerBound
        var skip = false
        for (index, original) in spans.enumerated() {
            if skip { skip = false; continue }
            // A picture's size, noted in a comment a space after it, is the picture's: one atom.
            var span = original
            if case .image = original.kind, index + 1 < spans.count {
                let next = spans[index + 1]
                if next.kind == .comment && md.sub(next.range).contains(UInt8(ascii: "{")) && md.trimmed(original.range.upperBound..<next.range.lowerBound).isEmpty {
                    skip = true
                    span.range = original.range.lowerBound..<next.range.upperBound
                }
            }
            pushPlain(md, at..<span.range.lowerBound, &rich, &pieces)
            let start = rich.bytes.count
            func atom(_ kind: Markup.AtomKind) {
                let at = rich.bytes.count
                rich.bytes.append(contentsOf: Markup.atomBytes)
                pieces.append(Piece(markdown: span.range, shown: at..<rich.bytes.count, plain: false))
                rich.runs.append(Run(range: at..<rich.bytes.count, mark: .atom(Markup.Atom(source: md.string(span.range), kind: kind))))
            }
            let mark: Mark
            switch span.kind {
            case .wikiLink(let target, let label, let embed):
                atom(.page(target: target, label: label, embed: embed))
                at = span.range.upperBound
                continue
            case .image(let source, let alt, let width, let height):
                atom(.picture(source: source, alt: alt, width: width, height: height))
                at = span.range.upperBound
                continue
            case .comment:
                atom(.comment)
                at = span.range.upperBound
                continue
            case .escape:
                // The character, shown; the backslash, markup.
                pushMarkup(span.range.lowerBound..<span.content.lowerBound, rich, &pieces)
                pushPlain(md, span.content, &rich, &pieces)
                at = span.range.upperBound
                continue
            case .strong: mark = .strong
            case .emphasis: mark = .emphasis(md[span.range.lowerBound] == UInt8(ascii: "_") ? "_" : "*")
            case .strikethrough: mark = .strikethrough
            case .highlight: mark = .highlight
            case .code: mark = .code(span.content.lowerBound - span.range.lowerBound)
            case .link(let target, let title): mark = .link(target: target, title: title)
            case .autolink: mark = .autolink
            case .url: mark = .url
            case .tag(let name): mark = .tag(name)
            }
            if case .tag = mark { } else if case .url = mark { } else {
                pushMarkup(span.range.lowerBound..<span.content.lowerBound, rich, &pieces)
                if mark.isCode {
                    // Nothing in code is Markdown: its words, as written.
                    pushPlain(md, span.content, &rich, &pieces)
                } else {
                    emit(md, span.content, span.children, &rich, &pieces)
                }
                pushMarkup(span.content.upperBound..<span.range.upperBound, rich, &pieces)
                let end = rich.bytes.count
                if end > start { rich.runs.append(Run(range: start..<end, mark: mark)) }
                at = span.range.upperBound
                continue
            }
            // Words read as a tag or an address: all of them shown.
            pushPlain(md, span.range, &rich, &pieces)
            rich.runs.append(Run(range: start..<rich.bytes.count, mark: mark))
            at = span.range.upperBound
        }
        pushPlain(md, at..<range.upperBound, &rich, &pieces)
    }

    /// Where a place in the Markdown is shown: inside markup, where the
    /// markup is shown (nowhere — its edge); inside an atom, before it.
    public static func shownOffset(_ markdown: String, _ offset: Int) -> Int {
        let (rich, pieces) = read(markdown.u8)
        for piece in pieces {
            if offset < piece.markdown.lowerBound { return piece.shown.lowerBound }
            if offset < piece.markdown.upperBound || (offset == piece.markdown.upperBound && piece.plain) {
                return piece.plain ? piece.shown.lowerBound + (offset - piece.markdown.lowerBound) : piece.shown.lowerBound
            }
        }
        return rich.bytes.count
    }

    /// Where a place in the words is in the Markdown: at the edge of markup,
    /// after it when `inside` (in the run that markup opens), before it
    /// otherwise.
    public static func markdownOffset(_ markdown: String, _ offset: Int, inside: Bool) -> Int {
        let md = markdown.u8
        let (_, pieces) = read(md)
        var found: Int? = nil
        for piece in pieces {
            if piece.plain && piece.shown.lowerBound <= offset && offset <= piece.shown.upperBound {
                let at = piece.markdown.lowerBound + (offset - piece.shown.lowerBound)
                // At a plain piece's start, markup may come before it: after it when inside.
                if offset == piece.shown.lowerBound && !inside && found != nil { return found ?? at }
                if offset < piece.shown.upperBound || !inside { return at }
                found = at
            } else if !piece.plain && piece.shown.lowerBound == offset {
                if found == nil || inside { found = inside ? piece.markdown.upperBound : piece.markdown.lowerBound }
                if !inside { return found ?? piece.markdown.lowerBound }
            } else if piece.shown.lowerBound > offset {
                break
            }
        }
        return found ?? md.count
    }

    /// The marks what is typed at a place takes on: the styles of the words
    /// before it (at a row's start, after it) — not a link's or code's at
    /// their ends, which typing beside them does not lengthen.
    public func marks(at: Int) -> [Mark] {
        var marks: [Mark] = []
        for run in runs {
            let inside = run.range.lowerBound < at && at < run.range.upperBound
            let touches = at == 0 ? run.range.lowerBound == 0 && !run.range.isEmpty : run.range.lowerBound < at && at <= run.range.upperBound
            let takes: Bool
            switch run.mark {
            case .link, .code: takes = inside
            default: takes = run.mark.carries && touches
            }
            if takes && !marks.contains(run.mark) { marks.append(run.mark) }
        }
        return marks
    }

    /// The marks words put in place of a range take: those that cover the
    /// whole of it — a link's, renamed — or, for a place, those of the words
    /// they join.
    public func marks(over range: Range<Int>) -> [Mark] {
        if range.isEmpty { return marks(at: range.lowerBound) }
        var marks: [Mark] = []
        for run in runs where run.range.lowerBound <= range.lowerBound && range.upperBound <= run.range.upperBound && run.mark.wraps && !marks.contains(run.mark) {
            marks.append(run.mark)
        }
        return marks
    }

    /// The words of a range replaced with others — marked as `marks` says,
    /// or, with none, as the words they join.
    public mutating func replace(_ range: Range<Int>, with other: Markup.Rich, marks given: [Mark]?) {
        let (a, b) = (min(range.lowerBound, bytes.count), min(range.upperBound, bytes.count))
        let marks = given ?? self.marks(at: a)
        let gone = b - a
        // First what is taken out: runs closed up over it; an atom in it, gone.
        var closed: [Run] = []
        closed.reserveCapacity(runs.count + other.runs.count + marks.count)
        for run in runs {
            let atom = run.mark.isAtom
            if atom && gone > 0 && run.range.lowerBound < b && run.range.upperBound > a { continue }
            func close(_ o: Int) -> Int { o <= a ? o : o >= b ? o - gone : a }
            let (start, end) = (close(run.range.lowerBound), close(run.range.upperBound))
            if end > start || (atom && end == start + Markup.atomBytes.count) { closed.append(Run(range: start..<end, mark: run.mark)) }
        }
        bytes.removeSubrange(a..<b)
        // Then what comes in, at `a`: runs that carry on take it; those it parts are parted.
        let added = other.bytes.count
        var given: [Mark] = []
        var placed: [Run] = []
        placed.reserveCapacity(closed.count + 2)
        for run in closed {
            let (s, e) = (run.range.lowerBound, run.range.upperBound)
            let carried = marks.contains(run.mark) && !given.contains(run.mark)
            if added == 0 || e < a || (e == a && !carried) {
                placed.append(run)
            } else if s > a || (s == a && !carried) {
                placed.append(Run(range: (s + added)..<(e + added), mark: run.mark))
            } else if carried {
                // It takes what came in.
                given.append(run.mark)
                placed.append(Run(range: s..<(e + added), mark: run.mark))
            } else {
                // What came in parts it.
                placed.append(Run(range: s..<a, mark: run.mark))
                placed.append(Run(range: (a + added)..<(e + added), mark: run.mark))
            }
        }
        if added > 0 {
            for mark in marks where !given.contains(mark) { placed.append(Run(range: a..<(a + added), mark: mark)) }
            placed.append(contentsOf: other.runs.map { Run(range: ($0.range.lowerBound + a)..<($0.range.upperBound + a), mark: $0.mark) })
        }
        bytes.insert(contentsOf: other.bytes, at: a)
        runs = placed
        tidy()
    }

    /// Puts a style on a range, or — if every word of it has that style —
    /// takes it off. Code is alone: making words code takes the other styles
    /// off them.
    public mutating func toggle(_ range: Range<Int>, _ mark: Mark) {
        if range.isEmpty { return }
        let covered = self.covered(range, mark)
        unmark(range, mark)
        if !covered {
            if mark.isCode {
                for other in [Mark.strong, .emphasis("*"), .strikethrough, .highlight] { unmark(range, other) }
            }
            runs.append(Run(range: range, mark: mark))
        }
        tidy()
    }

    /// Links a range to a target, or points the link already there at it.
    public mutating func link(_ range: Range<Int>, _ target: String) {
        if range.isEmpty { return }
        // Within a link's words already: only where it goes changes.
        if let index = runs.firstIndex(where: { $0.mark.isLink && $0.range.lowerBound <= range.lowerBound && range.upperBound <= $0.range.upperBound }) {
            if case .link(_, let title) = runs[index].mark { runs[index].mark = .link(target: target, title: title) }
            return
        }
        unmark(range, .link(target: "", title: nil))
        runs.append(Run(range: range, mark: .link(target: target, title: nil)))
        tidy()
    }

    /// Whether every word of a range has a mark of this kind.
    func covered(_ range: Range<Int>, _ mark: Mark) -> Bool {
        var at = range.lowerBound
        for run in Markup.stableSorted(runs.filter { $0.mark.sameKind(mark) }, by: { $0.range.lowerBound < $1.range.lowerBound }) {
            if run.range.lowerBound <= at && run.range.upperBound > at { at = run.range.upperBound }
        }
        return at >= range.upperBound
    }

    /// A mark of this kind taken off a range: runs cut, or split around it.
    mutating func unmark(_ range: Range<Int>, _ mark: Mark) {
        var kept: [Run] = []
        for run in runs {
            if !run.mark.sameKind(mark) || run.range.upperBound <= range.lowerBound || run.range.lowerBound >= range.upperBound {
                kept.append(run)
                continue
            }
            if run.range.lowerBound < range.lowerBound { kept.append(Run(range: run.range.lowerBound..<range.lowerBound, mark: run.mark)) }
            if run.range.upperBound > range.upperBound { kept.append(Run(range: range.upperBound..<run.range.upperBound, mark: run.mark)) }
        }
        runs = kept
    }

    /// Runs merged where they meet or overlap with the same mark, empty ones
    /// taken out, all in order.
    mutating func tidy() {
        let order: (Run, Run) -> Bool = { $0.range.lowerBound != $1.range.lowerBound ? $0.range.lowerBound < $1.range.lowerBound : $0.range.upperBound > $1.range.upperBound }
        let count = bytes.count
        let sorted = Markup.stableSorted(runs.filter { !$0.range.isEmpty && $0.range.upperBound <= count }, by: order)
        var merged: [Run] = []
        merged.reserveCapacity(sorted.count)
        for run in sorted {
            if let last = merged.lastIndex(where: { $0.mark == run.mark }) {
                if !run.mark.isAtom && merged[last].range.upperBound >= run.range.lowerBound {
                    merged[last].range = merged[last].range.lowerBound..<max(merged[last].range.upperBound, run.range.upperBound)
                    continue
                }
            }
            merged.append(run)
        }
        runs = Markup.stableSorted(merged, by: order)
    }

    /// The words from a place on, split off: what Return leaves on the next row.
    public mutating func splitOff(_ at: Int) -> Markup.Rich {
        let at = min(at, bytes.count)
        var tail = Markup.Rich(bytes: bytes.sub(from: at))
        bytes.removeSubrange(at...)
        var head: [Run] = []
        for run in runs {
            if run.range.upperBound <= at {
                head.append(run)
            } else if run.range.lowerBound >= at {
                tail.runs.append(Run(range: (run.range.lowerBound - at)..<(run.range.upperBound - at), mark: run.mark))
            } else {
                head.append(Run(range: run.range.lowerBound..<at, mark: run.mark))
                tail.runs.append(Run(range: 0..<(run.range.upperBound - at), mark: run.mark))
            }
        }
        runs = head
        tidy()
        tail.tidy()
        return tail
    }

    /// Other words put after these: what joining a row onto another does.
    public mutating func append(_ other: Markup.Rich) {
        let at = bytes.count
        bytes.append(contentsOf: other.bytes)
        runs.append(contentsOf: other.runs.map { Run(range: ($0.range.lowerBound + at)..<($0.range.upperBound + at), mark: $0.mark) })
        tidy()
    }

    // --- Written as Markdown ---------------------------------------------

    /// The words as Markdown: marks around the words they mark, atoms as
    /// they were written, and only what would be read as Markdown escaped.
    public func toMarkdown() -> String { markdown(guarded: true) }

    /// As `toMarkdown`; `guarded` false for words that cannot be read as
    /// another kind of row whatever they begin with — a heading's.
    public func markdown(guarded: Bool) -> String {
        func finish(_ written: String) -> String { keepSpaces(guarded ? guardStart(written) : written) }
        // Emphasis as it was written; else by `_`, which does not run into `**`.
        var underscored = self
        underscored.runs = runs.map { run in
            if case .emphasis = run.mark { return Run(range: run.range, mark: .emphasis("_")) }
            return run
        }
        for rich in [self, underscored] {
            for escaping in [Escaping.none, .least, .underscores, .all] {
                let written = finish(rich.write(escaping))
                if Markup.Rich.parse(written).sameAs(self) { return written }
            }
        }
        return finish(write(.least))
    }

    /// Whether two rich texts read the same: their words, and which of them
    /// — spaces aside — carry each mark Markdown writes.
    func sameAs(_ other: Markup.Rich) -> Bool {
        func marked(_ rich: Markup.Rich) -> [String] {
            var out: [String] = []
            for run in rich.runs where run.mark.wraps || run.mark.isAtom {
                let mark = String(describing: normal(run.mark))
                var at = run.range.lowerBound
                while at < run.range.upperBound {
                    if let c = rich.bytes.scalar(at: at), !c.isWS { out.append("\(at)\u{1}\(mark)") }
                    at += rich.bytes.charLen(at: at)
                }
            }
            return Array(Set(out)).sorted()
        }
        return bytes == other.bytes && marked(self) == marked(other)
    }

    fileprivate func write(_ escaping: Escaping) -> String {
        let text = bytes
        func isLink(_ run: Run) -> Bool {
            switch run.mark {
            case .link, .autolink: return true
            default: return false
            }
        }
        // The marks written around words, cut where words cannot be marked
        // across: a line break, and the leading and trailing spaces of a run.
        var cutRuns: [Run] = []
        for run in runs where run.mark.wraps {
            var start = run.range.lowerBound
            for i in run.range where text[i] == .newline {
                cutRuns.append(Run(range: start..<i, mark: run.mark))
                start = i + 1
            }
            cutRuns.append(Run(range: start..<run.range.upperBound, mark: run.mark))
        }
        // Marks that cross cannot be written so: the later is cut where the
        // earlier ends, so that every mark nests. A link is not cut: what
        // crosses it is.
        cutRuns = Markup.stableSorted(cutRuns, by: { $0.range.lowerBound != $1.range.lowerBound ? $0.range.lowerBound < $1.range.lowerBound : $0.range.upperBound > $1.range.upperBound })
        var cut = true
        while cut {
            cut = false
            pairs: for i in 0..<cutRuns.count {
                for j in 0..<cutRuns.count {
                    let (outer, inner) = (cutRuns[i], cutRuns[j])
                    let crosses = inner.range.lowerBound > outer.range.lowerBound && inner.range.lowerBound < outer.range.upperBound && inner.range.upperBound > outer.range.upperBound
                    if !crosses { continue }
                    if isLink(inner) && !isLink(outer) {
                        let at = inner.range.lowerBound
                        let rest = Run(range: at..<cutRuns[i].range.upperBound, mark: cutRuns[i].mark)
                        cutRuns[i].range = cutRuns[i].range.lowerBound..<at
                        cutRuns.append(rest)
                    } else {
                        let at = outer.range.upperBound
                        let rest = Run(range: at..<cutRuns[j].range.upperBound, mark: cutRuns[j].mark)
                        cutRuns[j].range = cutRuns[j].range.lowerBound..<at
                        cutRuns.append(rest)
                    }
                    cut = true
                    break pairs
                }
            }
            cutRuns.removeAll { $0.range.isEmpty }
        }
        for index in cutRuns.indices {
            switch cutRuns[index].mark {
            case .code, .link, .autolink: continue
            default: break
            }
            let range = cutRuns[index].range
            let trimmed = text.trimmed(range)
            let leading = trimmed.isEmpty ? range.count : trimmed.lowerBound - range.lowerBound
            let trailing = trimmed.isEmpty ? range.count : range.upperBound - trimmed.upperBound
            cutRuns[index].range = (range.lowerBound + leading)..<max(range.upperBound - trailing, range.lowerBound + leading)
        }
        cutRuns.removeAll { $0.range.isEmpty }
        let atoms = runs.filter { $0.mark.isAtom }
        let raw = runs.filter { if case .url = $0.mark { return true }; if case .tag = $0.mark { return true }; return false }

        // Every place a mark opens or closes, in order.
        var cuts = Set<Int>([0, text.count])
        for run in cutRuns { cuts.insert(run.range.lowerBound); cuts.insert(run.range.upperBound) }
        for run in atoms { cuts.insert(run.range.lowerBound); cuts.insert(run.range.upperBound) }
        let places = cuts.sorted()

        var out = Bytes()
        out.reserveCapacity(text.count + 16)
        var open: [Run] = []
        for w in 0..<max(places.count - 1, 0) {
            let (start, end) = (places[w], places[w + 1])
            // Close what ends here, innermost first.
            while let last = open.last, last.range.upperBound <= start {
                open.removeLast()
                out.append(contentsOf: closer(last.mark).utf8)
            }
            // Open what starts here: links outermost, then the longest.
            let opening = Markup.stableSorted(cutRuns.filter { $0.range.lowerBound == start }, by: { a, b in
                isLink(a) != isLink(b) ? isLink(a) : a.range.upperBound > b.range.upperBound
            })
            for run in opening {
                out.append(contentsOf: opener(run.mark).utf8)
                open.append(run)
            }
            if let atom = atoms.first(where: { $0.range.lowerBound == start }) {
                if case .atom(let a) = atom.mark { out.append(contentsOf: a.source.utf8) }
                continue
            }
            let words = text[start..<end]
            let inCode = open.contains { $0.mark.isCode }
            let inRaw = raw.contains { $0.range.lowerBound <= start && end <= $0.range.upperBound }
            if inCode || inRaw || open.contains(where: { if case .autolink = $0.mark { return true }; return false }) {
                out.append(contentsOf: words)
            } else {
                escape(Array(words), text.scalar(before: start), &out, escaping)
            }
        }
        for run in open.reversed() { out.append(contentsOf: closer(run.mark).utf8) }
        return out.string
    }
}

/// A mark as Markdown reads it back: an emphasis by either character is one
/// emphasis; code with any number of backticks one code.
private func normal(_ mark: Markup.Mark) -> Markup.Mark {
    switch mark {
    case .emphasis: return .emphasis("*")
    case .code: return .code(1)
    default: return mark
    }
}

private func escape(_ words: Bytes, _ before: Unicode.Scalar?, _ out: inout Bytes, _ escaping: Escaping) {
    let chars = words.scalars
    for (index, (at, c)) in chars.enumerated() {
        let next: Unicode.Scalar? = index + 1 < chars.count ? chars[index + 1].1 : nil
        let needs: Bool
        switch escaping {
        case .none: needs = false
        case .all: needs = c.isAsciiPunct
        default:
            let after = at + c.utf8Len
            needs = c == "\\" || c == "*" || c == "`"
                || (c == "_" && escaping == .underscores)
                || c == "[" || c == "]"
                || (c == "<" && next.map { $0 == "!" || $0.isAsciiAlpha } == true)
                || (c == "~" && next == "~")
                || (c == "=" && next == "=")
                || (c == "&" && keptSpaces.contains { words.has(Array($0.0.dropFirst()), at: after) })
                || (c == "!" && next == "[")
        }
        if needs { out.append(UInt8(ascii: "\\")) }
        out.append(contentsOf: words[at..<(at + c.utf8Len)])
    }
    _ = before
}

/// Words written with the spaces at each line's ends kept: Markdown drops
/// them there — and two at an end would break the line — so the outermost
/// is written as its reference.
private func keepSpaces(_ written: String) -> String {
    func reference(_ c: UInt8) -> Bytes { c == .tab ? "&#9;".u8 : "&#32;".u8 }
    let lines = written.u8.split(byte: .newline).map { original -> Bytes in
        var line = original
        if let last = line.last, last == .space || last == .tab {
            if line.count > 1 || line.first != last {
                line.removeLast()
                line.append(contentsOf: reference(last))
            }
        }
        if let first = line.first, first == .space || first == .tab {
            line.replaceSubrange(0..<1, with: reference(first))
        }
        return line
    }
    var out = Bytes()
    for (i, line) in lines.enumerated() {
        if i > 0 { out.append(.newline) }
        out.append(contentsOf: line)
    }
    return out.string
}

/// A row's words written so that they cannot be read as the start of
/// another kind of row — a heading, a quote, a list, a task, a fence, a
/// rule: what begins them is escaped.
private func guardStart(_ written: String) -> String {
    let w = written.u8
    func starts(_ prefix: String) -> Bool { w.hasPrefix(prefix.u8) }
    func spaced(_ mark: String) -> Bool {
        let m = mark.u8
        guard w.hasPrefix(m) else { return false }
        return w.count == m.count || w[m.count] == .space || w[m.count] == .tab
    }
    let digits = w.leadingDigits
    if digits > 0 && digits <= 9 && digits < w.count && (w[digits] == UInt8(ascii: ".") || w[digits] == UInt8(ascii: ")"))
        && (w.count == digits + 1 || w[digits + 1] == .space || w[digits + 1] == .tab) {
        return w.string(0..<digits) + "\\" + w.string(digits..<w.count)
    }
    let hashes = w.leading(UInt8(ascii: "#"))
    let block = (hashes > 0 && hashes < w.count && (w[hashes] == .space || w[hashes] == .tab))
        || (!w.isEmpty && hashes == w.count)
        || starts(">") || spaced("-") || spaced("+") || spaced("*")
        || starts("```") || starts("~~~") || starts("---") || starts("[ ]") || starts("[x]") || starts("[X]")
    return block ? "\\" + written : written
}

private func opener(_ mark: Markup.Mark) -> String {
    switch mark {
    case .strong: return "**"
    case .emphasis(let c): return String(c)
    case .strikethrough: return "~~"
    case .highlight: return "=="
    case .code(let ticks): return String(repeating: "`", count: max(ticks, 1))
    case .link: return "["
    case .autolink: return "<"
    case .url, .tag, .atom: return ""
    }
}

private func closer(_ mark: Markup.Mark) -> String {
    switch mark {
    case .link(let target, let title): return title.map { "](\(target) \"\($0)\")" } ?? "](\(target))"
    case .autolink: return ">"
    default: return opener(mark)
    }
}

extension Array where Element == UInt8 {
    var leadingDigits: Int {
        var n = 0
        while n < count && self[n].isAsciiDigit { n += 1 }
        return n
    }
}

extension Markup {
    /// A sort that keeps the order of what it holds equal: Rust's `sort_by`.
    static func stableSorted<T>(_ items: [T], by less: (T, T) -> Bool) -> [T] {
        items.enumerated().sorted { a, b in
            if less(a.element, b.element) { return true }
            if less(b.element, a.element) { return false }
            return a.offset < b.offset
        }.map(\.element)
    }
}
