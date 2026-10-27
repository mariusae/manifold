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
        Kind(name: "terminal", title: "Terminal", symbol: "manifold.terminal", what: "command",
             help: "a terminal here, running the command if given"),
        Kind(name: "agent", title: "Agent", symbol: "sparkle", what: "command",
             help: "a coding agent here: the one Settings name, else the command"),
        Kind(name: "note", title: "Note", symbol: "manifold.note", what: "text",
             help: "a note, with the text if given"),
        Kind(name: "web", aliases: ["page"], title: "Web Page", symbol: "globe", what: "address",
             help: "a page at the address, or one to type it into"),
        Kind(name: "search", title: "Search", symbol: "magnifyingglass", what: "words",
             help: "a search of the files under here for the words"),
        Kind(name: "folder", aliases: ["directory"], title: "Folder", symbol: "folder", what: "path",
             help: "a folder's listing: the path's, else here"),
        Kind(name: "notebook", title: "Shell Notebook", symbol: "text.line.first.and.arrowtriangle.forward",
             help: "a shell notebook here: cells run in one shell that lives on"),
        Kind(name: "git", aliases: ["source"], title: "Source Control", symbol: "arrow.triangle.branch",
             help: "the repository's block (git or Sapling), for here"),
        Kind(name: "smartlog", title: "Smartlog", symbol: "arrow.triangle.pull",
             help: "Sapling's interactive smartlog, for here"),
        Kind(name: "process", aliases: ["processes", "ps"], title: "Processes", symbol: "gauge.medium",
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

/// The kinds of thing Open Quickly (⌘O) and Find in Blocks (⇧⌘O) can be
/// narrowed to (DESIGN §6): a kind's name, or its start, then ⇥, makes a
/// chip of it; the line at the panel's foot counts what each kind found.
/// More than BlockKinds' — what's made is fewer than what's kept: files,
/// spaces, agents' turns.
public enum FindKinds {
    public struct Kind: Sendable, Equatable {
        /// What it's typed as (lowercased), and other words for it.
        public var name: String
        public var aliases: [String] = []
        /// As a chip says it.
        public var title: String
        public var symbol: String
    }

    /// In the order ⇥ offers them for a start more than one begins
    /// ("t": terminal, then turn) and the counts list them.
    public static let all: [Kind] = [
        Kind(name: "terminal", aliases: ["shell"], title: "Terminal", symbol: "manifold.terminal"),
        Kind(name: "agent", title: "Agent", symbol: "sparkle"),
        Kind(name: "note", title: "Note", symbol: "manifold.note"),
        Kind(name: "file", title: "File", symbol: "doc"),
        Kind(name: "folder", aliases: ["directory"], title: "Folder", symbol: "folder"),
        Kind(name: "web", aliases: ["page"], title: "Web", symbol: "globe"),
        Kind(name: "space", aliases: ["workspace", "arrangement"], title: "Space", symbol: "square.split.2x1"),
        Kind(name: "turn", title: "Turn", symbol: "text.bubble"),
        Kind(name: "search", title: "Search", symbol: "magnifyingglass"),
        Kind(name: "notebook", title: "Notebook", symbol: "text.line.first.and.arrowtriangle.forward"),
        Kind(name: "git", aliases: ["source"], title: "Git", symbol: "arrow.triangle.branch"),
        Kind(name: "smartlog", title: "Smartlog", symbol: "arrow.triangle.pull"),
        Kind(name: "diff", title: "Diff", symbol: "plus.forwardslash.minus"),
        Kind(name: "output", title: "Output", symbol: "text.alignleft"),
        Kind(name: "image", title: "Image", symbol: "photo"),
        Kind(name: "pdf", title: "PDF", symbol: "doc.richtext"),
        Kind(name: "panel", aliases: ["ui", "form"], title: "Panel", symbol: "slider.horizontal.3"),
    ]

    public static func named(_ name: String) -> Kind? { all.first { $0.name == name } }

    /// The kinds a word is the start of, in the table's order — those by
    /// name, then by another word for it ("s": space, search, smartlog,
    /// then shell's terminal): ⇥ takes the first, and again the next.
    public static func starting(_ word: String) -> [Kind] {
        let w = word.lowercased()
        guard !w.isEmpty else { return [] }
        let byName = all.filter { $0.name.hasPrefix(w) }
        return byName + all.filter { k in !byName.contains(k) && k.aliases.contains { $0.hasPrefix(w) } }
    }

    /// What a block is found as: its kind's name — a note or a file for a
    /// text, as it has a path; a terminal an agent works in is an agent's
    /// too.
    public static func of(_ kind: BlockKind, path: String?, agent: Bool) -> [String] {
        let name: String? = switch kind {
        case .text: path == nil ? "note" : "file"
        case .terminal: "terminal"
        case .directory: "folder"
        case .web: "web"
        case .image: "image"
        case .pdf: "pdf"
        case .search: "search"
        case .diff: "diff"
        case .git: "git"
        case .smartlog: "smartlog"
        case .process: nil
        case .agent: "agent"
        case .output: "output"
        case .notebook: "notebook"
        case .arrangement: "space"
        case .ui: "panel"
        }
        guard let name else { return [] }
        return kind == .terminal && agent ? [name, "agent"] : [name]
    }
}
