import CTreeSitter
import Foundation
import ManifoldCore
import struct ManifoldCore.TextRange

/// A query asked of a language's trees (tree-sitter's S-expressions),
/// compiled once, with the predicates its patterns are filtered by —
/// tree-sitter leaves those to whoever asks: `#match?` / `#not-match?`
/// (a capture's text and a regular expression), `#eq?` / `#not-eq?` (a
/// capture's text and a string or another capture's), `#any-of?` (and
/// strings), and `#adjacent? @a @b`, of Manifold's own: of @a's nodes,
/// only the run on the lines just above @b's, none blank between (a
/// declaration's doc comments). Others are taken as holding.
public final class SyntaxQuery {
    let query: OpaquePointer
    /// Its captures' names, by index.
    public let captureNames: [String]

    enum Argument {
        case capture(UInt32)
        case string(String)
    }

    final class Predicate {
        let name: String
        let arguments: [Argument]
        init(_ name: String, _ arguments: [Argument]) {
            self.name = name
            self.arguments = arguments
        }
        /// `#match?`'s expression, compiled once.
        lazy var regex: NSRegularExpression? = {
            guard arguments.count == 2, case .string(let p) = arguments[1] else { return nil }
            return try? NSRegularExpression(pattern: p)
        }()
    }

    /// Each pattern's predicates, by its index.
    let predicates: [[Predicate]]

    /// Nil if it doesn't compile for the language (a node type it hasn't).
    public init?(_ language: SyntaxLanguage, _ source: String) {
        var offset: UInt32 = 0
        var error = TSQueryErrorNone
        guard let q = source.withCString({ ts_query_new(language.grammar, $0, UInt32(strlen($0)), &offset, &error) }) else { return nil }
        query = q
        func name(_ s: UnsafePointer<CChar>?, _ n: UInt32) -> String {
            String(decoding: UnsafeRawBufferPointer(start: s, count: Int(n)), as: UTF8.self)
        }
        captureNames = (0..<ts_query_capture_count(q)).map { i in
            var n: UInt32 = 0
            let s = ts_query_capture_name_for_id(q, i, &n)
            return name(s, n)
        }
        predicates = (0..<ts_query_pattern_count(q)).map { pattern in
            var count: UInt32 = 0
            guard let steps = ts_query_predicates_for_pattern(q, pattern, &count) else { return [] }
            var out: [Predicate] = [], words: [Argument] = []
            for i in 0..<Int(count) {
                let step = steps[i]
                switch step.type {
                case TSQueryPredicateStepTypeCapture: words.append(.capture(step.value_id))
                case TSQueryPredicateStepTypeString:
                    var n: UInt32 = 0
                    words.append(.string(name(ts_query_string_value_for_id(q, step.value_id, &n), n)))
                default:
                    if case .string(let first)? = words.first { out.append(Predicate(first, Array(words.dropFirst()))) }
                    words = []
                }
            }
            return out
        }
    }

    deinit { ts_query_delete(query) }
}

/// A text's syntax tree, kept as the text changes: given the text as it
/// is now, it finds what changed since the text it had (the same at the
/// start and the end compared), edits its tree so — at once: what the
/// tree says stays where it was in the text around the change — and
/// parses again from it, only what the change touched. In the background
/// (the first parse of a big file takes a while), the tree put in place
/// on the main queue when it's in, with the edits made since, and
/// `onChange` told where it differs. A parse that takes too long (a text
/// of many megabytes) is given up: no tree, nothing said about the text.
public final class SyntaxTree {
    public let language: SyntaxLanguage
    /// The text the tree is of (edited to, if not yet parsed again).
    public private(set) var text: Rope
    private var tree: OpaquePointer? { didSet { texts = [:] } }
    /// Nodes' texts, for predicates, while the tree's the same.
    private var texts: [TextRange: String] = [:]
    private let cursor: OpaquePointer
    private let parser: Parser
    private let background: Bool
    /// A parse under way, of the text as it was; the edits made since, to
    /// be made to its tree when it's in, before the next.
    private var parsing = false
    private var editsSince: [TSInputEdit] = []
    /// How long a parse may take; a text it can't be parsed in isn't.
    public static var budget: TimeInterval = 5
    /// A parse ran out of time: the text isn't parsed again.
    public private(set) var gaveUp = false
    /// Where the syntax changed, once a parse in the background is in
    /// (on the main queue): ranges of the text as it is.
    public var onChange: (([TextRange]) -> Void)?

    /// `background`: parsed off the main queue; else at once, as the
    /// text's given (a small one's).
    public init(_ language: SyntaxLanguage, text: Rope, background: Bool = true) {
        self.language = language
        self.text = text
        self.background = background
        parser = Parser(language)
        cursor = ts_query_cursor_new()
        if background { reparse() } else { _ = adopt(parser.parse(text, old: nil)) }
    }

    deinit {
        if let tree { ts_tree_delete(tree) }
        ts_query_cursor_delete(cursor)
    }

    /// The tree as an S-expression (for a look at it).
    public var outline: String {
        guard let tree, let s = ts_node_string(ts_tree_root_node(tree)) else { return "" }
        defer { free(s) }
        return String(cString: s)
    }

    /// Whether there's a tree (the text was parsed, in time).
    public var isParsed: Bool { tree != nil }

    /// Brings the tree to `new`: the ranges (in it) whose syntax may have
    /// changed — what was edited, and parsed here, where the tree's
    /// structure differs (a block comment opened above everything after
    /// it); in the background, that's told `onChange`.
    @discardableResult
    public func update(to new: Rope) -> [TextRange] {
        guard let (start, oldEnd, newEnd) = new.changed(from: text) else { return [] }
        var edit = TSInputEdit(start_byte: UInt32(start), old_end_byte: UInt32(oldEnd), new_end_byte: UInt32(newEnd),
                               start_point: Self.point(start, in: new), old_end_point: Self.point(oldEnd, in: text),
                               new_end_point: Self.point(newEnd, in: new))
        if let tree { ts_tree_edit(tree, &edit) }
        text = new
        texts = [:]
        guard !gaveUp else { return [] }
        let edited = [TextRange(start, newEnd)]
        if !background { return edited + adopt(parser.parse(text, old: tree)) }
        if parsing { editsSince.append(edit) } else { reparse() }
        return edited
    }

    /// A tree parsed, put in place of the one there: the ranges where they
    /// differ (everything, if there was none, or it's given up).
    private func adopt(_ new: OpaquePointer?) -> [TextRange] {
        let old = tree
        tree = new
        guard let new else {
            gaveUp = true
            guard let old else { return [] }
            ts_tree_delete(old)
            return [TextRange(0, text.count)]
        }
        guard let old else { return [TextRange(0, text.count)] }
        defer { ts_tree_delete(old) }
        var changed: [TextRange] = []
        var n: UInt32 = 0
        if let ranges = ts_tree_get_changed_ranges(old, new, &n) {
            for i in 0..<Int(n) { changed.append(TextRange(Int(ranges[i].start_byte), Int(ranges[i].end_byte))) }
            free(ranges)
        }
        return changed
    }

    /// The text as it is parsed off the main queue, from (a copy of) the
    /// tree as it is; again when it's in if the text changed meanwhile.
    private func reparse() {
        parsing = true
        editsSince = []
        let snapshot = text, parser = parser
        let old = tree.map { ts_tree_copy($0)! }
        DispatchQueue.global(qos: .userInitiated).async {
            let new = parser.parse(snapshot, old: old)
            if let old { ts_tree_delete(old) }
            DispatchQueue.main.async { [weak self] in
                guard let self else {
                    if let new { ts_tree_delete(new) }
                    return
                }
                self.parsing = false
                if let new { for var e in self.editsSince { ts_tree_edit(new, &e) } }
                let changed = self.adopt(new)
                if !self.editsSince.isEmpty, !self.gaveUp { self.reparse() }
                if !changed.isEmpty { self.onChange?(changed) }
            }
        }
    }

    /// The captures of `query` among the nodes overlapping `range`, its
    /// predicates held, in the text's order, each once: each's name and
    /// its node's bytes. Captures named with a `_` first are left out.
    public func captures(_ query: SyntaxQuery, in range: TextRange) -> [(name: String, range: TextRange)] {
        var out: [(name: String, range: TextRange)] = []
        var seen = Set<TextRange>()
        for match in matches(query, in: range) {
            for c in match where !c.name.hasPrefix("_") && seen.insert(c.range).inserted { out.append(c) }
        }
        return out.sorted { $0.range < $1.range }
    }

    /// The matches of `query` among the nodes overlapping `range` (all of
    /// the text, if nil), its predicates held: each its captures' names
    /// and nodes' bytes.
    public func matches(_ query: SyntaxQuery, in range: TextRange? = nil) -> [[(name: String, range: TextRange)]] {
        guard let tree else { return [] }
        let r = range ?? TextRange(0, text.count)
        ts_query_cursor_set_byte_range(cursor, UInt32(r.start), UInt32(max(r.end, r.start + 1)))
        ts_query_cursor_exec(cursor, query.query, ts_tree_root_node(tree))
        var out: [[(name: String, range: TextRange)]] = []
        var match = TSQueryMatch()
        while ts_query_cursor_next_match(cursor, &match) {
            var captures = (0..<Int(match.capture_count)).map { match.captures[$0] }
            guard holds(query.predicates[Int(match.pattern_index)], &captures) else { continue }
            out.append(captures.map { (query.captureNames[Int($0.index)], TextRange(Int(ts_node_start_byte($0.node)), Int(ts_node_end_byte($0.node)))) })
        }
        return out
    }

    /// Its declarations (§2.5), in order: each with its path — the names of
    /// the declarations it's in and its own, `Type.method` (its `@context`
    /// first, where it doesn't sit inside what qualifies it) — its bytes,
    /// and its name's.
    public func declarations() -> [Declaration] {
        guard let query = language.declarationQuery else { return [] }
        var found: [(decl: TextRange, name: TextRange, context: String?)] = []
        var seen = Set<TextRange>()
        for m in matches(query) {
            guard let decl = m.first(where: { $0.name == "decl" })?.range, let name = m.first(where: { $0.name == "name" })?.range,
                  seen.insert(decl).inserted else { continue }
            found.append((decl, name, m.first(where: { $0.name == "context" }).map { text[$0.range] }))
        }
        found.sort { $0.decl.start != $1.decl.start ? $0.decl.start < $1.decl.start : $0.decl.end > $1.decl.end }
        var out: [Declaration] = []
        var open: [Declaration] = []
        for f in found {
            while let last = open.last, last.range.end <= f.decl.start { open.removeLast() }
            let own = text[f.name].split(separator: "\n").first.map(String.init) ?? ""
            let parts = open.map(\.name) + [f.context, own].compactMap { $0 }
            let d = Declaration(name: own, path: parts.joined(separator: "."), range: f.decl, nameRange: f.name)
            out.append(d)
            open.append(d)
        }
        return out
    }

    /// Whether a match's predicates hold (`#adjacent?` leaving out the
    /// nodes it doesn't take).
    private func holds(_ predicates: [SyntaxQuery.Predicate], _ captures: inout [TSQueryCapture]) -> Bool {
        func nodes(_ i: UInt32) -> [TSNode] { captures.filter { $0.index == i }.map(\.node) }
        func texts(_ a: SyntaxQuery.Argument) -> [String] {
            switch a {
            case .capture(let i): return nodes(i).map(nodeText)
            case .string(let s): return [s]
            }
        }
        for p in predicates {
            let args = p.arguments
            switch p.name {
            case "match?", "not-match?":
                guard let regex = p.regex, let first = args.first else { continue }
                let matched = texts(first).allSatisfy { regex.firstMatch(in: $0, range: NSRange($0.startIndex..., in: $0)) != nil }
                if matched != (p.name == "match?") { return false }
            case "eq?", "not-eq?":
                guard args.count == 2 else { continue }
                let equal = texts(args[0]) == texts(args[1])
                if equal != (p.name == "eq?") { return false }
            case "any-of?":
                guard let first = args.first else { continue }
                let options = Set(args.dropFirst().flatMap(texts))
                if !texts(first).allSatisfy(options.contains) { return false }
            case "adjacent?":
                guard args.count == 2, case .capture(let a) = args[0], case .capture(let b) = args[1],
                      let below = nodes(b).first else { continue }
                // Up from the node below, while each is on the line above the last.
                var line = Int(ts_node_start_point(below).row)
                var kept = Set<UInt32>()
                for node in nodes(a).sorted(by: { ts_node_start_byte($0) > ts_node_start_byte($1) }) {
                    let end = ts_node_end_point(node), start = ts_node_start_point(node)
                    // A comment that takes its line break ends at the next line's start.
                    let last = end.column == 0 && end.row > start.row ? Int(end.row) - 1 : Int(end.row)
                    guard last == line - 1 || last == line else { break }
                    kept.insert(ts_node_start_byte(node))
                    line = Int(start.row)
                }
                if kept.isEmpty { return false }
                captures.removeAll { $0.index == a && !kept.contains(ts_node_start_byte($0.node)) }
            default:
                continue
            }
        }
        return true
    }

    /// A node's text, kept while the tree is (predicates ask again as
    /// lines are laid out).
    private func nodeText(_ node: TSNode) -> String {
        let r = TextRange(Int(ts_node_start_byte(node)), Int(ts_node_end_byte(node)))
        if let t = texts[r] { return t }
        if texts.count > 2000 { texts = [:] }
        let t = text[r]
        texts[r] = t
        return t
    }

    /// The words of the comments in `range` (a line's), as bytes of the
    /// text: their leaders and delimiters left out (`CommentMarks`).
    public func commentWords(in range: TextRange) -> [TextRange] {
        language.commentQuery.map { words(of: $0, in: range) } ?? []
    }

    /// The words of the doc comments (and docstrings) in `range`.
    public func docWords(in range: TextRange) -> [TextRange] {
        language.docQuery.map { words(of: $0, in: range) } ?? []
    }

    private func words(of query: SyntaxQuery, in range: TextRange) -> [TextRange] {
        guard !range.isEmpty else { return [] }
        let marks = language.marks
        var out: [TextRange] = []
        // The line's own bytes at hand, the comment's ends read as wanted.
        let lineBytes = text.bytes(in: range)
        let byte: (Int) -> UInt8 = { [text] k in
            k >= range.start && k < range.end ? lineBytes[k - range.start] : text.byte(at: k) ?? 0
        }
        for c in captures(query, in: range) {
            // A match's captures may lie off the line (a doc comment's others).
            let lo = max(c.range.start, range.start), hi = min(c.range.end, range.end)
            guard lo < hi else { continue }
            let segment = lo..<hi
            if let w = marks.words(of: c.range.range, segment: segment, byte: byte) {
                // Comments within comments (Rust's doc comments' parts) once.
                if let last = out.last, last.end > w.lowerBound { continue }
                out.append(TextRange(w.lowerBound, w.upperBound))
            }
        }
        return out
    }

    // MARK: Parsing

    /// A parser for the language, used by one parse at a time.
    private final class Parser {
        let parser: OpaquePointer
        init(_ language: SyntaxLanguage) {
            parser = ts_parser_new()
            ts_parser_set_language(parser, language.grammar)
        }
        deinit { ts_parser_delete(parser) }

        /// `text`'s tree, from `old` edited to it; nil if out of time.
        func parse(_ text: Rope, old: OpaquePointer?) -> OpaquePointer? {
            let reader = Reader(text)
            let input = TSInput(
                payload: Unmanaged.passUnretained(reader).toOpaque(),
                read: { payload, offset, _, count in
                    Unmanaged<Reader>.fromOpaque(payload!).takeUnretainedValue().read(Int(offset), count!)
                },
                encoding: TSInputEncodingUTF8,
                decode: nil)
            var deadline = Date.timeIntervalSinceReferenceDate + SyntaxTree.budget
            let tree = withExtendedLifetime(reader) {
                withUnsafeMutablePointer(to: &deadline) { d in
                    ts_parser_parse_with_options(parser, old, input, TSParseOptions(payload: d, progress_callback: { state in
                        Date.timeIntervalSinceReferenceDate > state!.pointee.payload.assumingMemoryBound(to: TimeInterval.self).pointee
                    }))
                }
            }
            if tree == nil { ts_parser_reset(parser) }
            return tree
        }
    }

    /// Feeds the parser the rope a chunk at a time, each copied where it
    /// stays until the next is asked for.
    private final class Reader {
        let text: Rope
        var buffer = UnsafeMutableBufferPointer<UInt8>.allocate(capacity: 8192)
        init(_ text: Rope) { self.text = text }
        deinit { buffer.deallocate() }

        func read(_ offset: Int, _ count: UnsafeMutablePointer<UInt32>) -> UnsafePointer<CChar>? {
            let (start, bytes) = text.chunk(at: offset)
            let piece = bytes.count > 0 ? bytes[(offset - start)...] : []
            if piece.count > buffer.count {
                buffer.deallocate()
                buffer = .allocate(capacity: piece.count)
            }
            _ = UnsafeMutableBufferPointer(rebasing: buffer[..<piece.count]).initialize(from: piece)
            count.pointee = UInt32(piece.count)
            return UnsafeRawPointer(buffer.baseAddress!).assumingMemoryBound(to: CChar.self)
        }
    }

    private static func point(_ offset: Int, in text: Rope) -> TSPoint {
        let row = text.line(at: offset)
        return TSPoint(row: UInt32(row), column: UInt32(offset - text.offset(ofLine: row)))
    }
}

/// A declaration in code (§2.5): what a symbol anchor is at.
public struct Declaration: Equatable, Sendable {
    public var name: String
    /// The names of the declarations it's in and its own: `Type.method`.
    public var path: String
    public var range: TextRange
    public var nameRange: TextRange
}
