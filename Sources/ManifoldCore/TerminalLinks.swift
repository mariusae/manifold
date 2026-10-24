import Foundation

/// What can be ⌘-clicked in a line of a terminal: addresses, and files —
/// a path, perhaps with a line and a column as grep, compilers and the
/// like print them (`path:line:column:` and then the text there).
public enum TerminalLinks {
    public struct Link: Equatable, Sendable {
        /// Where it is in the line, by Unicode scalar.
        public var range: Range<Int>
        /// What it opens: the address, or `path`, `path:line`, `path:line:column`.
        public var target: String

        public init(range: Range<Int>, target: String) {
            self.range = range
            self.target = target
        }
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
    /// terminal is); nil where it can't be told (another host): then the
    /// look of it decides.
    public static func links(in line: String, exists: (String) -> Bool? = { _ in nil }) -> [Link] {
        let s = Array(line.unicodeScalars)
        var out: [Link] = []
        var i = 0
        while i < s.count {
            while i < s.count, CharacterSet.whitespaces.contains(s[i]) { i += 1 }
            var end = i
            while end < s.count, !CharacterSet.whitespaces.contains(s[end]) { end += 1 }
            if let link = link(in: s, from: i, to: end, exists: exists) { out.append(link) }
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
        if let r = word.range(of: "^[A-Za-z][A-Za-z0-9+.-]*://\\S+", options: .regularExpression) {
            var w = word[r]
            while w.hasSuffix(":") { w.removeLast() }
            return Link(range: a..<(a + w.unicodeScalars.count), target: String(w))
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
            guard path.contains(".") || path.contains("/") || exists(path) == true, exists(path) != false else { return nil }
            var target = path + ":\(line)", last = e
            if let (column, e2) = number(at: e), column > 0 {
                target += ":\(column)"
                last = e2
            }
            return Link(range: a..<last, target: target)
        }
        // A path alone: the word ends with it (a colon after it, at most).
        guard p == b || (s[p] == ":" && p + 1 == b) else { return nil }
        if path.contains("/") {
            let last = path.split(separator: "/").last.map(String.init) ?? ""
            let looksLikeOne = path.hasPrefix("/") || path.hasPrefix("./") || path.hasPrefix("../") || path.hasPrefix("~/")
                || last.range(of: "\\.[A-Za-z][A-Za-z0-9]*$", options: .regularExpression) != nil
            guard exists(path) ?? looksLikeOne else { return nil }
        } else {
            guard exists(path) == true else { return nil }
        }
        return Link(range: a..<p, target: path)
    }

    /// The link at a place in the line (by Unicode scalar), if any.
    public static func link(at offset: Int, in line: String, exists: (String) -> Bool? = { _ in nil }) -> Link? {
        links(in: line, exists: exists).first { $0.range.contains(offset) }
    }
}
