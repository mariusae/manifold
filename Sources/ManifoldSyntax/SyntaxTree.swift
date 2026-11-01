import CTreeSitter
import Foundation
import ManifoldCore
import struct ManifoldCore.TextRange

/// A query asked of a language's trees (tree-sitter's S-expressions),
/// compiled once.
public final class SyntaxQuery {
    let query: OpaquePointer
    /// Its captures' names, by index.
    public let captureNames: [String]

    /// Nil if it doesn't compile for the language (a node type it hasn't).
    public init?(_ language: SyntaxLanguage, _ source: String) {
        var offset: UInt32 = 0
        var error = TSQueryErrorNone
        guard let q = source.withCString({ ts_query_new(language.grammar, $0, UInt32(strlen($0)), &offset, &error) }) else { return nil }
        query = q
        captureNames = (0..<ts_query_capture_count(q)).map { i in
            var n: UInt32 = 0
            let s = ts_query_capture_name_for_id(q, i, &n)!
            return String(decoding: UnsafeRawBufferPointer(start: s, count: Int(n)), as: UTF8.self)
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
    private var tree: OpaquePointer?
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

    /// The captures of `query` among the nodes overlapping `range`, in
    /// order: each's name and the node's bytes.
    public func captures(_ query: SyntaxQuery, in range: TextRange) -> [(name: String, range: TextRange)] {
        guard let tree else { return [] }
        ts_query_cursor_set_byte_range(cursor, UInt32(range.start), UInt32(max(range.end, range.start + 1)))
        ts_query_cursor_exec(cursor, query.query, ts_tree_root_node(tree))
        var out: [(String, TextRange)] = []
        var match = TSQueryMatch()
        var index: UInt32 = 0
        while ts_query_cursor_next_capture(cursor, &match, &index) {
            let capture = match.captures[Int(index)]
            let node = capture.node
            out.append((query.captureNames[Int(capture.index)], TextRange(Int(ts_node_start_byte(node)), Int(ts_node_end_byte(node)))))
        }
        return out
    }

    /// The words of the comments in `range` (a line's), as bytes of the
    /// text: their leaders and delimiters left out (`CommentMarks`).
    public func commentWords(in range: TextRange) -> [TextRange] {
        guard let query = language.commentQuery, !range.isEmpty else { return [] }
        let marks = language.marks
        var out: [TextRange] = []
        // The line's own bytes at hand, the comment's ends read as wanted.
        let lineBytes = text.bytes(in: range)
        let byte: (Int) -> UInt8 = { [text] k in
            k >= range.start && k < range.end ? lineBytes[k - range.start] : text.byte(at: k) ?? 0
        }
        for c in captures(query, in: range) {
            let segment = max(c.range.start, range.start)..<min(c.range.end, range.end)
            guard !segment.isEmpty else { continue }
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
