import Foundation

/// How a language writes its comments — and its strings, inside which a
/// comment's leader doesn't start one: what the editor sets comments in
/// the technical font by (DESIGN §7.1). Lexical only, a line at a time,
/// from the state the line before left (inside a block comment, or a
/// string that runs on): no parse, no language server, nothing guessed
/// about what a comment says.
public struct CommentSyntax: Equatable, Sendable {
    /// A block comment's delimiters.
    public struct Block: Equatable, Sendable {
        public var open: String
        public var close: String
        public init(_ open: String, _ close: String) {
            self.open = open
            self.close = close
        }
    }

    /// A string's form.
    public struct Quote: Equatable, Sendable {
        public var open: String
        public var close: String
        /// A backslash takes the character after it.
        public var escapes: Bool
        /// It may run on past the line's end.
        public var multiline: Bool
        /// Letters before it that are part of it (Rust's r, br).
        public var prefix: String
        /// Hashes between the prefix and the quote, matched after the
        /// close (Swift's #"…"#, Rust's r#"…"#); at least one with no prefix.
        public var hashes: Bool
        /// A character, not a string: one only if it closes a character
        /// later ('a', '\n') — else the quote is nothing (Rust's 'a, a
        /// lifetime; Haskell's x').
        public var character: Bool

        public init(_ open: String, _ close: String? = nil, escapes: Bool = true, multiline: Bool = false,
                    prefix: String = "", hashes: Bool = false, character: Bool = false) {
            self.open = open
            self.close = close ?? open
            self.escapes = escapes
            self.multiline = multiline
            self.prefix = prefix
            self.hashes = hashes
            self.character = character
        }
    }

    /// Line comments' leaders.
    public var line: [String]
    public var blocks: [Block]
    /// Block comments within block comments close separately (Swift's, Rust's).
    public var nests: Bool
    /// The strings, longest opening first.
    public var quotes: [Quote]
    /// A leader starts a comment only at the start of a word (a shell's
    /// #, not $# or a#b).
    public var leaderStartsWord: Bool
    /// Only as the line's first character but blanks (an ini file's ;).
    public var leaderStartsLine: Bool
    /// After a backslash, a leader is the character itself (TeX's \%).
    public var backslashEscapes: Bool

    public init(line: [String] = [], blocks: [Block] = [], nests: Bool = false, quotes: [Quote] = [],
                leaderStartsWord: Bool = false, leaderStartsLine: Bool = false, backslashEscapes: Bool = false) {
        self.line = line
        self.blocks = blocks
        self.nests = nests
        self.quotes = quotes
        self.leaderStartsWord = leaderStartsWord
        self.leaderStartsLine = leaderStartsLine
        self.backslashEscapes = backslashEscapes
    }
}

/// Where a line starts: in code, in a block comment (which, how deep),
/// or in a string run on from the line before (which, with how many hashes).
public enum CommentState: Hashable, Sendable {
    case code
    case block(Int, depth: Int)
    case quote(Int, hashes: Int)
}

extension CommentSyntax {
    /// A line's comments: the ranges (in its UTF-8) of what they say —
    /// not their leaders and delimiters, the blanks after those, the
    /// stars down a block's left, or blanks at the end — and the state
    /// the next line starts in.
    public func scan(_ line: [UInt8], from start: CommentState) -> (comments: [Range<Int>], end: CommentState) {
        let n = line.count
        var out: [Range<Int>] = []
        var state = start
        var i = 0

        func at(_ s: [UInt8], _ k: Int) -> Bool { Self.match(line, k, s) }
        func blank(_ c: UInt8) -> Bool { c == 0x20 || c == 0x09 }
        func skipBlanks(_ k: Int) -> Int {
            var k = k
            while k < n, blank(line[k]) { k += 1 }
            return k
        }
        /// What a comment says from `a` to `b`, its trailing blanks off.
        func said(_ a: Int, _ b: Int) {
            var b = b
            while b > a, blank(line[b - 1]) { b -= 1 }
            if b > a { out.append(a..<b) }
        }
        let leaders = self.line.map { Array($0.utf8) }
        let blocks = self.blocks.map { (open: Array($0.open.utf8), close: Array($0.close.utf8)) }
        let quotes = self.quotes.map { (q: $0, open: Array($0.open.utf8), close: Array($0.close.utf8), prefix: Array($0.prefix.utf8)) }

        /// A block comment's words, from `text` on: to its close (state
        /// back to code, `i` after it) or the line's end.
        func inBlock(_ k: Int, depth: Int, text: Int) {
            let (open, close) = blocks[k]
            var depth = depth
            while i < n {
                if at(close, i) {
                    depth -= 1
                    if depth == 0 {
                        // Stars run up to its close (**/) are its own.
                        var end = i
                        while end > text, line[end - 1] == close[0], close.count > 1 { end -= 1 }
                        said(text, end)
                        i += close.count
                        state = .code
                        return
                    }
                    i += close.count
                } else if nests, at(open, i) {
                    depth += 1
                    i += open.count
                } else {
                    i += 1
                }
            }
            said(text, n)
            state = .block(k, depth: depth)
        }

        /// A string's rest: to its close (state back to code) or the
        /// line's end (still in it, if it runs on).
        func inQuote(_ k: Int, hashes: Int) {
            let q = quotes[k]
            let close = q.close + Array(repeating: UInt8(ascii: "#"), count: hashes)
            while i < n {
                if q.q.escapes, line[i] == UInt8(ascii: "\\") {
                    i += 2
                    continue
                }
                if at(close, i) {
                    i += close.count
                    state = .code
                    return
                }
                i += 1
            }
            i = n
            state = q.q.multiline ? .quote(k, hashes: hashes) : .code
        }

        // Carried on from the line before.
        switch state {
        case .code: break
        case let .block(k, depth):
            guard k < blocks.count else { state = .code; break }
            // The blanks and stars down a block's left are its margin.
            var t = skipBlanks(0)
            while t < n, line[t] == UInt8(ascii: "*"), !at(blocks[k].close, t) { t += 1 }
            inBlock(k, depth: depth, text: skipBlanks(t))
        case let .quote(k, hashes):
            guard k < quotes.count else { state = .code; break }
            inQuote(k, hashes: hashes)
        }

        scanning: while i < n {
            // A block comment opening (before the line leaders: Lua's --[[).
            for (k, b) in blocks.enumerated() where at(b.open, i) && leaderAllowed(line, i) {
                var j = i + b.open.count
                // Its doc forms are its own (/**, /*!), up to a close.
                while j < n, line[j] == b.open.last! || line[j] == UInt8(ascii: "!"), !at(b.close, j) { j += 1 }
                i = j
                inBlock(k, depth: 1, text: skipBlanks(j))
                continue scanning
            }
            for leader in leaders where at(leader, i) && leaderAllowed(line, i) {
                var j = i + leader.count
                // ///, //!, ##, ;;; are the leader's.
                while j < n, line[j] == leader.last! || line[j] == UInt8(ascii: "!") { j += 1 }
                said(skipBlanks(j), n)
                return (out, .code)
            }
            for (k, q) in quotes.enumerated() {
                guard let (after, hashes) = opening(q.q, open: q.open, prefix: q.prefix, line, i) else { continue }
                if q.q.character {
                    // A character only if it closes a character on.
                    var j = after
                    if j < n, line[j] == UInt8(ascii: "\\") {
                        j += 2
                        while j < n, line[j] != UInt8(ascii: "'"), j - after < 12 { j += 1 }
                    } else if j < n {
                        j += 1
                        while j < n, line[j] & 0xC0 == 0x80 { j += 1 }
                    }
                    if j < n, at(q.close, j) { i = j + q.close.count } else { i += 1 }
                    continue scanning
                }
                i = after
                inQuote(k, hashes: hashes)
                continue scanning
            }
            i += 1
        }
        return (out, state)
    }

    /// Whether a leader at `i` starts a comment, as the language has it.
    private func leaderAllowed(_ line: [UInt8], _ i: Int) -> Bool {
        if backslashEscapes, i > 0, line[i - 1] == UInt8(ascii: "\\") { return false }
        if leaderStartsLine, line[..<i].contains(where: { $0 != 0x20 && $0 != 0x09 }) { return false }
        if leaderStartsWord, i > 0 {
            let c = line[i - 1]
            return c == 0x20 || c == 0x09 || c == UInt8(ascii: ";") || c == UInt8(ascii: "|") || c == UInt8(ascii: "&")
                || c == UInt8(ascii: "(") || c == UInt8(ascii: ")")
        }
        return true
    }

    /// A string opening at `i`: where its contents start, and its hashes.
    private func opening(_ q: Quote, open: [UInt8], prefix: [UInt8], _ line: [UInt8], _ i: Int) -> (Int, Int)? {
        var j = i
        if !prefix.isEmpty {
            // A prefix only at a word's start (not the r ending "for").
            if i > 0, Self.isWordByte(line[i - 1]) { return nil }
            guard Self.match(line, j, prefix) else { return nil }
            j += prefix.count
        }
        var hashes = 0
        if q.hashes {
            while j < line.count, line[j] == UInt8(ascii: "#") { hashes += 1; j += 1 }
            if prefix.isEmpty, hashes == 0 { return nil }
        }
        guard Self.match(line, j, open) else { return nil }
        return (j + open.count, hashes)
    }

    private static func match(_ line: [UInt8], _ k: Int, _ s: [UInt8]) -> Bool {
        guard k + s.count <= line.count else { return false }
        for (j, c) in s.enumerated() where line[k + j] != c { return false }
        return true
    }

    private static func isWordByte(_ c: UInt8) -> Bool {
        (c >= 0x30 && c <= 0x39) || (c >= 0x41 && c <= 0x5A) || (c >= 0x61 && c <= 0x7A) || c == UInt8(ascii: "_") || c >= 0x80
    }
}

extension CommentSyntax {
    private static let dq = Quote("\"")
    private static let sq = Quote("'")
    private static let character = Quote("'", character: true)
    private static let tripleDQ = Quote("\"\"\"", multiline: true)
    private static let tripleSQ = Quote("'''", multiline: true)
    private static let cBlock = Block("/*", "*/")

    /// C's, and its family's: // and /* */, double-quoted strings, characters.
    private static let c = CommentSyntax(line: ["//"], blocks: [cBlock], quotes: [dq, character])
    /// With text blocks (""") before the rest, and nesting (Kotlin's, Scala's).
    private static let jvm = CommentSyntax(line: ["//"], blocks: [cBlock], nests: true, quotes: [tripleDQ, dq, character])
    /// Strings in either quote, three of them too (Dart's, Groovy's).
    private static let dart = CommentSyntax(line: ["//"], blocks: [cBlock], nests: true, quotes: [tripleDQ, tripleSQ, dq, sq])
    private static let javascript = CommentSyntax(line: ["//"], blocks: [cBlock], quotes: [dq, sq, Quote("`", multiline: true)])
    private static let swift = CommentSyntax(line: ["//"], blocks: [cBlock], nests: true, quotes: [
        Quote("\"\"\"", escapes: false, multiline: true, hashes: true), Quote("\"", escapes: false, hashes: true), tripleDQ, dq,
    ])
    private static let rust = CommentSyntax(line: ["//"], blocks: [cBlock], nests: true, quotes: [
        Quote("\"", escapes: false, multiline: true, prefix: "br", hashes: true), Quote("\"", escapes: false, multiline: true, prefix: "r", hashes: true),
        Quote("\"", multiline: true), character,
    ])
    private static let go = CommentSyntax(line: ["//"], blocks: [cBlock], quotes: [dq, character, Quote("`", escapes: false, multiline: true)])
    private static let css = CommentSyntax(blocks: [cBlock], quotes: [dq, sq])
    private static let scss = CommentSyntax(line: ["//"], blocks: [cBlock], quotes: [dq, sq])
    private static let python = CommentSyntax(line: ["#"], quotes: [tripleDQ, tripleSQ, dq, sq])
    private static let shell = CommentSyntax(line: ["#"], quotes: [Quote("\"", multiline: true), Quote("'", escapes: false, multiline: true)], leaderStartsWord: true)
    private static let ruby = CommentSyntax(line: ["#"], quotes: [Quote("\"", multiline: true), Quote("'", multiline: true)])
    private static let hash = CommentSyntax(line: ["#"], quotes: [dq, sq])
    private static let yaml = CommentSyntax(line: ["#"], quotes: [dq, Quote("'", escapes: false)], leaderStartsWord: true)
    private static let toml = CommentSyntax(line: ["#"], quotes: [tripleDQ, Quote("'''", escapes: false, multiline: true), dq, Quote("'", escapes: false)])
    private static let ini = CommentSyntax(line: ["#", ";"], leaderStartsLine: true)
    private static let make = CommentSyntax(line: ["#"], leaderStartsWord: true)
    private static let nix = CommentSyntax(line: ["#"], blocks: [cBlock], quotes: [Quote("''", escapes: false, multiline: true), Quote("\"", multiline: true)])
    private static let hcl = CommentSyntax(line: ["#", "//"], blocks: [cBlock], quotes: [dq])
    private static let php = CommentSyntax(line: ["//", "#"], blocks: [cBlock], quotes: [Quote("\"", multiline: true), Quote("'", multiline: true)])
    private static let julia = CommentSyntax(line: ["#"], blocks: [Block("#=", "=#")], nests: true, quotes: [tripleDQ, dq, character])
    private static let elixir = CommentSyntax(line: ["#"], quotes: [tripleDQ, dq, sq])
    private static let lua = CommentSyntax(line: ["--"], blocks: [Block("--[[", "]]")], quotes: [Quote("[[", "]]", escapes: false, multiline: true), dq, sq])
    private static let sql = CommentSyntax(line: ["--"], blocks: [cBlock], quotes: [Quote("'", escapes: false), dq])
    private static let haskell = CommentSyntax(line: ["--"], blocks: [Block("{-", "-}")], nests: true, quotes: [dq, character])
    private static let lisp = CommentSyntax(line: [";"], blocks: [Block("#|", "|#")], nests: true, quotes: [Quote("\"", multiline: true)], backslashEscapes: true)
    private static let tex = CommentSyntax(line: ["%"], backslashEscapes: true)
    private static let erlang = CommentSyntax(line: ["%"], quotes: [dq])
    private static let markup = CommentSyntax(blocks: [Block("<!--", "-->")])
    private static let ocaml = CommentSyntax(blocks: [Block("(*", "*)")], nests: true, quotes: [dq])
    private static let vim = CommentSyntax(line: ["\""], leaderStartsLine: true)
    private static let powershell = CommentSyntax(line: ["#"], blocks: [Block("<#", "#>")], quotes: [dq, Quote("'", escapes: false)])

    /// The file's language's, by its name or extension; nil for a
    /// language unknown here, or prose (Markdown).
    public static func forPath(_ path: String) -> CommentSyntax? {
        let name = (path as NSString).lastPathComponent.lowercased()
        switch name {
        case "makefile", "gnumakefile", "justfile": return make
        case "dockerfile", "containerfile", "procfile", ".gitignore", ".gitattributes", ".dockerignore", ".editorconfig", ".npmrc": return hash
        case ".bashrc", ".bash_profile", ".zshrc", ".zprofile", ".zshenv", ".profile", ".envrc": return shell
        case "gemfile", "rakefile", "podfile", "brewfile", "vagrantfile", "fastfile": return ruby
        case "cmakelists.txt": return hash
        default: break
        }
        if name.hasPrefix(".env") { return shell }
        switch (name as NSString).pathExtension {
        case "c", "h", "cpp", "cc", "cxx", "hpp", "hh", "hxx", "m", "mm", "cs", "glsl", "vert", "frag", "metal", "hlsl", "proto", "sol", "zig", "d": return c
        case "java", "kt", "kts", "scala", "sc": return jvm
        case "dart", "groovy", "gradle": return dart
        case "js", "jsx", "mjs", "cjs", "ts", "tsx", "mts", "cts", "jsonc", "json5": return javascript
        case "swift": return swift
        case "rs": return rust
        case "go": return go
        case "css": return css
        case "scss", "less", "sass": return scss
        case "py", "pyi", "pyw": return python
        case "sh", "bash", "zsh", "ksh", "fish", "command": return shell
        case "rb", "rake", "gemspec": return ruby
        case "pl", "pm", "r", "cmake", "nim", "tcl", "awk", "cr", "conf", "cfg", "gitignore", "dockerfile", "graphql", "gql": return hash
        case "yaml", "yml": return yaml
        case "toml": return toml
        case "ini", "properties", "desktop": return ini
        case "mk", "make", "just": return make
        case "nix": return nix
        case "tf", "tfvars", "hcl": return hcl
        case "php": return php
        case "jl": return julia
        case "ex", "exs": return elixir
        case "lua": return lua
        case "sql": return sql
        case "hs", "elm", "purs": return haskell
        case "lisp", "el", "clj", "cljs", "cljc", "edn", "scm", "ss", "rkt", "fnl": return lisp
        case "tex", "sty", "cls", "bib": return tex
        case "erl", "hrl": return erlang
        case "html", "htm", "xml", "svg", "plist", "xib", "storyboard", "vue", "svelte": return markup
        case "ml", "mli": return ocaml
        case "vim": return vim
        case "ps1", "psm1": return powershell
        default: return nil
        }
    }
}
