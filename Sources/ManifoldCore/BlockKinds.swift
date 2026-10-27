import Foundation

/// The kinds of block you can make, one table for every way of making one
/// (DESIGN §6.2): File ▸ New's items, the New Block picker (⌥⌘N), and
/// `mani new <kind> [what]` and its help are all made from it, so a kind
/// is added in one place and can't be left out of one of them.
public enum BlockKinds {
    public struct Kind: Sendable, Equatable {
        /// What it's called after `mani new`, and typed in the picker.
        public var name: String
        /// Other words for it, in the picker and after `mani new`.
        public var aliases: [String] = []
        /// As a menu names it ("New " before it).
        public var title: String
        /// Its symbol, as its tiles have it.
        public var symbol: String
        /// What it takes after its name (`mani new web <address>`, "web
        /// example.com" in the picker): what it's called; nil, nothing.
        public var what: String?
        /// A line on what it makes, for help and the picker. "Here" is
        /// the directory a shell's `mani` runs in, or the focused tile's
        /// folder.
        public var help: String
        /// Made from a menu or the picker, not only from a shell.
        public var interactive = true
    }

    public static let all: [Kind] = [
        Kind(name: "terminal", title: "Terminal", symbol: "apple.terminal", what: "command",
             help: "a terminal here, running the command if given"),
        Kind(name: "agent", title: "Agent", symbol: "sparkles", what: "command",
             help: "a coding agent here: the one Settings name, else the command"),
        Kind(name: "note", title: "Note", symbol: "note.text", what: "text",
             help: "a note, with the text if given"),
        Kind(name: "web", aliases: ["page"], title: "Web Page", symbol: "globe", what: "address",
             help: "a page at the address, or one to type it into"),
        Kind(name: "search", title: "Search", symbol: "magnifyingglass", what: "words",
             help: "a search of the files under here for the words"),
        Kind(name: "folder", aliases: ["directory"], title: "Folder", symbol: "folder", what: "path",
             help: "a folder's listing: the path's, else here"),
        Kind(name: "notebook", title: "Shell Notebook", symbol: "text.and.command.macwindow",
             help: "a shell notebook here: cells run in one shell that lives on"),
        Kind(name: "git", aliases: ["source"], title: "Source Control", symbol: "arrow.triangle.branch",
             help: "the repository's block (git or Sapling), for here"),
        Kind(name: "smartlog", title: "Smartlog", symbol: "arrow.triangle.pull",
             help: "Sapling's interactive smartlog, for here"),
        Kind(name: "process", aliases: ["processes", "ps"], title: "Processes", symbol: "cpu",
             help: "the host's processes, as ps lists them"),
    ]

    /// A kind by its name, an alias, or (unless `exact`) the start of one.
    public static func named(_ word: String, exact: Bool = true) -> Kind? {
        let w = word.lowercased()
        if let k = all.first(where: { $0.name == w || $0.aliases.contains(w) }) { return k }
        guard !exact, !w.isEmpty else { return nil }
        let starting = all.filter { k in ([k.name, k.title.lowercased()] + k.aliases).contains { $0.hasPrefix(w) } }
        return starting.count == 1 ? starting[0] : nil
    }

    /// The kinds a word could be the start of, in the table's order (all,
    /// for no word): what the picker lists as you type.
    public static func matching(_ word: String) -> [Kind] {
        let w = word.lowercased()
        guard !w.isEmpty else { return all.filter(\.interactive) }
        return all.filter { k in k.interactive && ([k.name, k.title.lowercased()] + k.aliases).contains { $0.hasPrefix(w) || $0.split(separator: " ").contains { $0.hasPrefix(w) } } }
    }

    /// What's typed in the picker, read as `mani new` reads its words: a
    /// kind's name (or the start of one), then what it takes.
    public static func parse(_ typed: String) -> (word: String, what: String?) {
        let t = typed.trimmingCharacters(in: .whitespaces)
        guard let space = t.firstIndex(of: " ") else { return (t, nil) }
        let rest = t[space...].trimmingCharacters(in: .whitespaces)
        return (String(t[..<space]), rest.isEmpty ? nil : rest)
    }

    /// `mani new`'s help: a line for each kind.
    static var help: String {
        let rows = all.map { k -> (String, String) in (k.name + (k.what.map { " [\($0)]" } ?? ""), k.help) }
        let width = (rows.map(\.0.count).max() ?? 0) + 2
        return rows.map { "  " + $0.0.padding(toLength: width, withPad: " ", startingAt: 0) + $0.1 }.joined(separator: "\n")
    }
}
