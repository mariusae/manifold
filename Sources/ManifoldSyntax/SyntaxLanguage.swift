import CTreeSitter
import CTreeSitterGrammars
import Foundation
import ManifoldCore

/// A language there's a grammar for (scripts/fetch-tree-sitter.sh): how
/// files in it are known, and what's asked of their trees — where their
/// comments are, which of them are its doc comments (DESIGN §7.1), and how
/// a comment's leader and delimiters are told from its words.
public final class SyntaxLanguage {
    public let name: String
    /// The grammar's `const TSLanguage *`.
    let grammar: OpaquePointer
    /// The node types that are whole comments.
    let commentNodes: [String]
    /// The query that captures its doc comments' nodes as `@doc`; nil if
    /// it has none.
    let docSource: String?
    public let marks: CommentMarks

    init(_ name: String, _ grammar: OpaquePointer?, comments: [String] = ["comment"], docs: String? = nil, marks: CommentMarks) {
        self.name = name
        self.grammar = grammar!
        commentNodes = comments
        docSource = docs
        self.marks = marks
    }

    /// Captures every comment, as `@comment`.
    public private(set) lazy var commentQuery: SyntaxQuery? =
        SyntaxQuery(self, "[" + commentNodes.map { "(\($0))" }.joined(separator: " ") + "] @comment")

    /// Captures its doc comments (or the words of its docstrings), as `@doc`.
    public private(set) lazy var docQuery: SyntaxQuery? = docSource.flatMap { SyntaxQuery(self, $0) }

    // MARK: The languages

    private static let cStyle = CommentMarks(line: ["//"], blocks: [("/*", "*/")])
    private static let hash = CommentMarks(line: ["#"])

    // What a doc comment is, by language: a comment written so (///, /**
    // but not ////, /**/), one the grammar says is (Rust's), the run of
    // comments just above a declaration (Go's, Ruby's — a body's first
    // comment is its parent's child, beside the body), or a docstring.
    /// `/**` … `*/`: Javadoc, KDoc, JSDoc.
    private static func starStar(_ node: String) -> String {
        #"((\#(node)) @doc (#match? @doc "^/\\*\\*([^*/]|$)"))"#
    }
    /// `///`, `//!`, and `/**`, `/*!`: Doxygen's.
    private static let doxygen = #"((comment) @doc (#match? @doc "^(//[/!]([^/]|$)|/\\*(\\*([^*/]|$)|!))"))"#

    static let bash = SyntaxLanguage("bash", tree_sitter_bash(), marks: hash)
    static let c = SyntaxLanguage("c", tree_sitter_c(), docs: doxygen, marks: cStyle)
    static let cpp = SyntaxLanguage("cpp", tree_sitter_cpp(), docs: doxygen, marks: cStyle)
    static let css = SyntaxLanguage("css", tree_sitter_css(), comments: ["comment", "js_comment"], marks: cStyle)
    static let elixir = SyntaxLanguage("elixir", tree_sitter_elixir(), docs: #"""
        (unary_operator operand: (call target: (identifier) @_name
          (arguments [(string (quoted_content) @doc) (sigil (quoted_content) @doc)]))
          (#any-of? @_name "doc" "moduledoc" "typedoc"))
        """#, marks: hash)
    static let go = SyntaxLanguage("go", tree_sitter_go(), docs: """
        (source_file (comment)+ @doc . [(package_clause) (function_declaration) (method_declaration)
          (type_declaration) (const_declaration) (var_declaration)] @_decl (#adjacent? @doc @_decl))
        """, marks: cStyle)
    static let html = SyntaxLanguage("html", tree_sitter_html(), marks: CommentMarks(blocks: [("<!--", "-->")]))
    static let java = SyntaxLanguage("java", tree_sitter_java(), comments: ["line_comment", "block_comment"], docs: starStar("block_comment"), marks: cStyle)
    static let javascript = SyntaxLanguage("javascript", tree_sitter_javascript(), comments: ["comment", "html_comment"], docs: starStar("comment"), marks: CommentMarks(line: ["//", "<!--", "-->"], blocks: [("/*", "*/")]))
    static let json = SyntaxLanguage("json", tree_sitter_json(), marks: cStyle)
    static let kotlin = SyntaxLanguage("kotlin", tree_sitter_kotlin(), comments: ["line_comment", "block_comment"], docs: starStar("block_comment"), marks: cStyle)
    static let lua = SyntaxLanguage("lua", tree_sitter_lua(), docs: #"((comment) @doc (#match? @doc "^---([^-]|$)"))"#, marks: CommentMarks(line: ["--"], blocks: [("--[[", "]]")]))
    static let make = SyntaxLanguage("make", tree_sitter_make(), marks: hash)
    static let python = SyntaxLanguage("python", tree_sitter_python(), docs: """
        (module . (expression_statement (string (string_content) @doc)))
        (class_definition body: (block . (expression_statement (string (string_content) @doc))))
        (function_definition body: (block . (expression_statement (string (string_content) @doc))))
        """, marks: hash)
    static let ruby = SyntaxLanguage("ruby", tree_sitter_ruby(), docs: """
        ((comment)+ @doc . [(method) (singleton_method) (class) (module)] @_decl (#adjacent? @doc @_decl))
        ((comment)+ @doc . (body_statement . [(method) (singleton_method) (class) (module)] @_decl) (#adjacent? @doc @_decl))
        """, marks: CommentMarks(line: ["#"], blocks: [("=begin", "=end")]))
    static let rust = SyntaxLanguage("rust", tree_sitter_rust(), comments: ["line_comment", "block_comment"], docs: """
        (line_comment doc: (doc_comment)) @doc
        (block_comment doc: (doc_comment)) @doc
        """, marks: cStyle)
    static let sql = SyntaxLanguage("sql", tree_sitter_sql(), comments: ["comment", "marginalia"], marks: CommentMarks(line: ["--"], blocks: [("/*", "*/")]))
    static let swift = SyntaxLanguage("swift", tree_sitter_swift(), comments: ["comment", "multiline_comment"], docs: #"""
        ((comment) @doc (#match? @doc "^///([^/]|$)"))
        """# + starStar("multiline_comment"), marks: cStyle)
    static let toml = SyntaxLanguage("toml", tree_sitter_toml(), marks: hash)
    static let tsx = SyntaxLanguage("tsx", tree_sitter_tsx(), comments: ["comment", "html_comment"], docs: starStar("comment"), marks: cStyle)
    static let typescript = SyntaxLanguage("typescript", tree_sitter_typescript(), comments: ["comment", "html_comment"], docs: starStar("comment"), marks: cStyle)
    static let yaml = SyntaxLanguage("yaml", tree_sitter_yaml(), marks: hash)
    static let zig = SyntaxLanguage("zig", tree_sitter_zig(), docs: #"((comment) @doc (#match? @doc "^//[/!]([^/]|$)"))"#, marks: cStyle)

    public static let all = [bash, c, cpp, css, elixir, go, html, java, javascript, json, kotlin, lua, make,
                             python, ruby, rust, sql, swift, toml, tsx, typescript, yaml, zig]

    /// The grammars, by the language (`CodeLanguage.id`) each parses.
    private static let byLanguage: [String: SyntaxLanguage] = [
        "shell": bash, "c": c, "cpp": cpp, "metal": cpp, "css": css, "elixir": elixir, "go": go, "html": html,
        "java": java, "javascript": javascript, "json": json, "kotlin": kotlin, "lua": lua, "make": make,
        "python": python, "ruby": ruby, "rust": rust, "sql": sql, "swift": swift, "toml": toml, "tsx": tsx,
        "typescript": typescript, "yaml": yaml, "zig": zig,
    ]

    /// The file's: its language's (`CodeLanguage`, the one table of what's
    /// code), if there's a grammar for it; nil for prose and languages
    /// without one.
    public static func forPath(_ path: String) -> SyntaxLanguage? {
        CodeLanguage.forPath(path).flatMap { byLanguage[$0.id] }
    }
}

/// How a language marks its comments: what's taken off a comment's ends
/// (and a block's left margin) to leave its words.
public struct CommentMarks {
    /// Line comments' leaders.
    public var line: [String]
    /// Block comments' delimiters.
    public var blocks: [(open: String, close: String)]

    public init(line: [String] = [], blocks: [(open: String, close: String)] = []) {
        self.line = line
        self.blocks = blocks
    }

    /// A comment's words within `segment`, a part of it on one line (it's
    /// at `comment`, the whole of it): its leader, or a block's opening
    /// and closing, left off where they're in the segment — with the
    /// characters the leader's last repeats (///, ##, /**) and a `!` after
    /// it (//!, /*!) — a block's lines' margin of blanks (and stars, where
    /// it opens with one), and blanks at either end. Nil if no words.
    public func words(of comment: Range<Int>, segment: Range<Int>, byte: (Int) -> UInt8) -> Range<Int>? {
        func has(_ s: String, at k: Int) -> Bool {
            let u = Array(s.utf8)
            guard k >= comment.lowerBound, k + u.count <= comment.upperBound else { return false }
            return u.indices.allSatisfy { byte(k + $0) == u[$0] }
        }
        // The longest mark it opens with.
        let opens = line.map { ($0, nil as String?) } + blocks.map { ($0.open, $0.close as String?) }
        let mark = opens.filter { has($0.0, at: comment.lowerBound) }.max { $0.0.utf8.count < $1.0.utf8.count }
        var a = segment.lowerBound, b = segment.upperBound
        func isBlank(_ k: Int) -> Bool { let c = byte(k); return c == 0x20 || c == 0x09 || c == 0x0D || c == 0x0A }
        if let close = mark?.1, b == comment.upperBound, has(close, at: b - close.utf8.count) {
            b -= close.utf8.count
            let first = close.utf8.first!
            if first == UInt8(ascii: "*") { while b > a, byte(b - 1) == first { b -= 1 } }
        }
        if let (open, _) = mark, a == comment.lowerBound {
            a = min(a + open.utf8.count, b)
            let last = open.utf8.last!
            while a < b, byte(a) == last { a += 1 }
            if a < b, byte(a) == UInt8(ascii: "!") { a += 1 }
        } else if let (open, close) = mark, close != nil {
            while a < b, isBlank(a) { a += 1 }
            if open.utf8.last == UInt8(ascii: "*") { while a < b, byte(a) == UInt8(ascii: "*") { a += 1 } }
        }
        while a < b, isBlank(a) { a += 1 }
        while b > a, isBlank(b - 1) { b -= 1 }
        return a < b ? a..<b : nil
    }
}
