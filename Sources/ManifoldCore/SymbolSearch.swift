import Foundation

/// A symbol found by its name across a project (§2.6): where it's
/// defined, its definition's line, and who said so — the project's
/// index (SCIP), or a language server running there.
public struct SymbolHit: Codable, Equatable, Sendable {
    public enum Source: String, Codable, Sendable { case index, server }
    /// Its own name, and what it's in (a type, a module), if anything.
    public var name: String
    public var container: String
    /// What it is, in a word: type, func, module, value… ("" unknown).
    public var kind: String
    public var path: String
    /// Where its name is, from 0.
    public var line: Int
    public var character: Int
    public var text: String
    public var source: Source
    /// How well it matched (higher better).
    public var score: Int

    public init(name: String, container: String, kind: String, path: String, line: Int, character: Int, text: String, source: Source, score: Int) {
        self.name = name
        self.container = container
        self.kind = kind
        self.path = path
        self.line = line
        self.character = character
        self.text = text
        self.source = source
        self.score = score
    }

    /// Its name with what it's in: `Card.save`.
    public var qualified: String { container.isEmpty ? name : container + "." + name }

    /// How well a query names a symbol (0: not at all): by its own name
    /// first, then with what it's in; a type or a function a little over
    /// a value of the same match.
    public static func score(_ query: String, name: String, container: String, kind: String) -> Int {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return 0 }
        let qualified = container.isEmpty ? name : container + "." + name
        // "Card.save": the qualified name as the title.
        let m = q.contains(".") ? FileFinder.nameMatch(q, title: qualified, secondary: "")
            : FileFinder.nameMatch(q, title: name, secondary: qualified)
        return m == 0 ? 0 : m + (weight[kind] ?? 0)
    }

    static let weight: [String: Int] = ["type": 12, "class": 12, "struct": 12, "interface": 12, "enum": 12, "func": 8, "method": 8, "module": 4]

    /// What a SCIP symbol is, by its last descriptor: `#` a type, `().`
    /// a function or method, `/` a namespace, `.` a term, `!` a macro.
    /// Nil for what isn't looked for by name: parameters, type
    /// parameters, meta.
    public static func kind(scip symbol: String) -> String? {
        if symbol.hasSuffix(").") { return "func" }
        if symbol.hasSuffix("#") { return "type" }
        if symbol.hasSuffix("/") { return "module" }
        if symbol.hasSuffix("!") { return "macro" }
        if symbol.hasSuffix(".") { return "value" }
        return nil
    }

    /// Hits from several places as one list: one for each place (the
    /// first list's kept over a later one's for the same line), best
    /// first, at most `limit`.
    public static func merge(_ lists: [[SymbolHit]], limit: Int) -> [SymbolHit] {
        var seen: Set<String> = []
        var out: [SymbolHit] = []
        for list in lists {
            for h in list where seen.insert("\(h.path):\(h.line)").inserted { out.append(h) }
        }
        return Array(out.sorted { $0.score != $1.score ? $0.score > $1.score : ($0.name.count, $0.path) < ($1.name.count, $1.path) }.prefix(limit))
    }
}

/// What a project search looks for (§2.6), as typed: `sym:` symbols
/// alone, `file:` (or `path:`) files alone, `text:` the files' text
/// alone; without one, all three.
public struct ProjectQuery: Equatable, Sendable {
    public var text: String
    public var kinds: [String]

    public static let all = ["symbols", "files", "text"]

    public init(text: String, kinds: [String]) {
        self.text = text
        self.kinds = kinds
    }

    public init(_ typed: String) {
        let t = typed.trimmingCharacters(in: .whitespaces)
        for (prefix, kind) in [("sym:", "symbols"), ("symbol:", "symbols"), ("file:", "files"), ("path:", "files"), ("text:", "text")]
            where t.lowercased().hasPrefix(prefix) {
            text = t.dropFirst(prefix.count).trimmingCharacters(in: .whitespaces)
            kinds = [kind]
            return
        }
        text = t
        kinds = Self.all
    }
}
