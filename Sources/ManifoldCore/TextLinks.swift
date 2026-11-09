import Foundation

/// What in a line of text is an address — a web link, a file's, a
/// block's reference — read one way wherever text is: a terminal's, an
/// editor's, a note's, a paste.
public enum TextLinks {
    /// A scheme and "//" (`https://`, `file://`).
    static let scheme = #"[A-Za-z][A-Za-z0-9+.-]*://"#

    /// What an address doesn't end with: a sentence's punctuation, a
    /// bracket or a quote closing around it.
    static let trailing = Set(".,;:!?)]}>\"'`".unicodeScalars)

    /// An address with what it doesn't end with taken off its end.
    static func trimmed(_ s: Substring) -> Substring {
        var s = s
        while let last = s.unicodeScalars.last, trailing.contains(last) { s.removeLast() }
        return s
    }

    /// One address and nothing else (space around it aside): a web link,
    /// a file's, a mail's, or a block's.
    public static func isAddress(_ s: String) -> Bool {
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty, !t.contains(where: \.isWhitespace) else { return false }
        return startsAsAddress(t)
    }

    /// Whether text starts as an address does: a scheme and "//", or one
    /// that goes without (`mailto:`), or a block's (`manifold:`).
    static func startsAsAddress(_ s: String) -> Bool {
        s.range(of: "^" + scheme + #"\S"#, options: .regularExpression) != nil
            || s.lowercased().hasPrefix("mailto:") || s.hasPrefix("manifold:")
    }

    /// A block's reference (`manifold:host/id`, a place after `#`): the one
    /// pattern a reference has (a host's name may have dots and dashes).
    public static let reference = BlockID.referencePattern

    /// A reference written bare in prose — not a link's address, nor in
    /// quotes or brackets, nor part of a longer word or path.
    public static let bareReference = try! NSRegularExpression(pattern: #"(?<![(\[<"'=/\w])"# + reference)

    /// A web address written bare in prose (`https://…`), what it doesn't
    /// end with left out.
    public static let url = try! NSRegularExpression(pattern: #"\b"# + scheme + #"[^\s<>\x{2028}]*[^\s<>.,;:!?)\]}'"`\x{2028}]"#)

    /// The address at a place in a line (by UTF-16 offset) — a web
    /// address, or a block's reference — and where it is in the line.
    public static func address(at offset: Int, in line: String) -> (range: NSRange, address: String)? {
        let ns = line as NSString
        let all = NSRange(location: 0, length: ns.length)
        for re in [url, anyReference] {
            for m in re.matches(in: line, range: all) where m.range.location <= offset && offset <= NSMaxRange(m.range) {
                return (m.range, ns.substring(with: m.range))
            }
        }
        return nil
    }

    private static let anyReference = try! NSRegularExpression(pattern: reference)
}

/// What can be ⌘-clicked in a line of a terminal: addresses, and files —
/// a path, perhaps with a line and a column as grep, compilers and the
/// like print them (`path:line:column:` and then the text there).
public enum TerminalLinks {
    public struct Link: Equatable, Sendable {
        /// Where it is in the line, by Unicode scalar.
        public var range: Range<Int>
        /// What it opens: the address, or `path`, `path:line`, `path:line:column`.
        public var target: String
        /// How sure it is that it's one: a file's, until it's looked for,
        /// only as sure as the look of it.
        public var standing: Standing = .sure

        public init(range: Range<Int>, target: String, standing: Standing = .sure) {
            self.range = range
            self.target = target
            self.standing = standing
        }

        /// The file it names, the line and column left off; nil for an address.
        public var path: String? {
            guard !TextLinks.startsAsAddress(target) else { return nil }
            return target.split(separator: ":", maxSplits: 1).first.map(String.init) ?? target
        }

        /// Its file named from `base` (the directory it's relative to),
        /// if it's relative: what it opens wherever the terminal is now.
        public func from(_ base: String?) -> Link {
            guard let base, let path, !path.hasPrefix("/"), !path.hasPrefix("~") else { return self }
            var l = self
            l.target = TerminalLinks.absolute(path, from: base) + target.dropFirst(path.count)
            return l
        }
    }

    /// A link's standing. An address, or a file that's been looked for, is
    /// `sure`; a file not looked for yet (on another host) is `likely` if
    /// it looks like a path (`/x`, `./x`, `a/b.md`, `main.c:12`) — shown,
    /// as one not sure — and `possible` if it doesn't (a bare name, as `ls`
    /// prints one), which isn't shown until it's found.
    public enum Standing: Sendable {
        case sure, likely, possible
    }

    /// A path from a directory, `..` and `.` taken out, as the text it is
    /// (on another host as well as this one: nothing is looked at).
    public static func absolute(_ path: String, from base: String) -> String {
        if path.hasPrefix("/") || path.hasPrefix("~") { return path }
        var parts: [Substring] = []
        for p in (base + "/" + path).split(separator: "/") {
            if p == "." { continue }
            if p == ".." { if !parts.isEmpty { parts.removeLast() }; continue }
            parts.append(p)
        }
        return "/" + parts.joined(separator: "/") + (path.hasSuffix("/") && !parts.isEmpty ? "/" : "")
    }

    private static let opening = Set("([{<\"'`".unicodeScalars)
    private static let closing = Set(")]}>\"'`,;.".unicodeScalars)
    private static let pathCharacters: CharacterSet = {
        var c = CharacterSet.alphanumerics
        c.insert(charactersIn: "._-/~+@%=#")
        return c
    }()

    /// The links in a line. Each word is read from its start for as long
    /// as it goes on as a path, then a line and a column, if they follow —
    /// so `bootstrap.py:177:1:def` is `bootstrap.py:177:1`. A path with a
    /// line needs a dot or a slash in it (`main.c:12`, not `error:12`);
    /// without one, a slash and the look of a path (`./x`, `/usr`, `~/a`,
    /// or a name with an extension at its end); a bare name, to be there.
    /// `exists` says whether a path is there (relative ones from where the
    /// terminal is); nil where it can't be told yet (another host's, not
    /// looked for): then the look of it decides, and the link is `likely`.
    /// `possible`: those it can't be told of that don't look like paths
    /// too (bare names), to be looked for.
    public static func links(in line: String, exists: (String) -> Bool? = { _ in nil }, possible: Bool = false) -> [Link] {
        let s = Array(line.unicodeScalars)
        var out: [Link] = []
        var i = 0
        while i < s.count {
            while i < s.count, CharacterSet.whitespaces.contains(s[i]) { i += 1 }
            var end = i
            while end < s.count, !CharacterSet.whitespaces.contains(s[end]) { end += 1 }
            if let link = link(in: s, from: i, to: end, exists: exists), possible || link.standing != .possible { out.append(link) }
            i = end
        }
        return out
    }

    private static func link(in s: [Unicode.Scalar], from start: Int, to end: Int, exists: (String) -> Bool?) -> Link? {
        var a = start, b = end
        while a < b, opening.contains(s[a]) { a += 1 }
        while b > a, closing.contains(s[b - 1]) { b -= 1 }
        guard a < b else { return nil }
        let word = String(String.UnicodeScalarView(s[a..<b]))
        // An address.
        if word.range(of: "^" + TextLinks.scheme + #"\S"#, options: .regularExpression) != nil {
            let w = TextLinks.trimmed(word[...])
            return Link(range: a..<(a + w.unicodeScalars.count), target: String(w))
        }
        // A block's reference, alone or in a Markdown link (`[name](manifold:…)`).
        if let r = word.range(of: TextLinks.reference, options: .regularExpression),
           r.lowerBound == word.startIndex || word[..<r.lowerBound].hasSuffix("(") {
            let from = a + word[..<r.lowerBound].unicodeScalars.count
            return Link(range: from..<(from + word[r].unicodeScalars.count), target: String(word[r]))
        }
        // A path, as far as it goes as one.
        var p = a
        while p < b, pathCharacters.contains(s[p]) { p += 1 }
        guard p > a else { return nil }
        let path = String(String.UnicodeScalarView(s[a..<p]))
        guard path.unicodeScalars.contains(where: { CharacterSet.letters.contains($0) }) else { return nil }
        // Then a line and a column, each after a colon.
        func number(at k: Int) -> (Int, Int)? {
            guard k + 1 < b, s[k] == ":", CharacterSet.decimalDigits.contains(s[k + 1]) else { return nil }
            var e = k + 1
            while e < b, CharacterSet.decimalDigits.contains(s[e]) { e += 1 }
            return (Int(String(String.UnicodeScalarView(s[(k + 1)..<e]))) ?? 0, e)
        }
        if let (line, e) = number(at: p), line > 0 {
            let there = exists(path)
            guard there != false else { return nil }
            var target = path + ":\(line)", last = e
            if let (column, e2) = number(at: e), column > 0 {
                target += ":\(column)"
                last = e2
            }
            let looksLikeOne = path.contains(".") || path.contains("/")
            return Link(range: a..<last, target: target, standing: there == true ? .sure : looksLikeOne ? .likely : .possible)
        }
        // A path alone: the word ends with it (a colon after it, at most).
        guard p == b || (s[p] == ":" && p + 1 == b) else { return nil }
        let there = exists(path)
        guard there != false else { return nil }
        var looksLikeOne = false
        if path.contains("/") {
            let last = path.split(separator: "/").last.map(String.init) ?? ""
            looksLikeOne = path.hasPrefix("/") || path.hasPrefix("./") || path.hasPrefix("../") || path.hasPrefix("~/")
                || last.range(of: "\\.[A-Za-z][A-Za-z0-9]*$", options: .regularExpression) != nil
        }
        return Link(range: a..<p, target: path, standing: there == true ? .sure : looksLikeOne ? .likely : .possible)
    }

    /// The link at a place in the line (by Unicode scalar), if any.
    public static func link(at offset: Int, in line: String, exists: (String) -> Bool? = { _ in nil }, possible: Bool = false) -> Link? {
        links(in: line, exists: exists, possible: possible).first { $0.range.contains(offset) }
    }
}
