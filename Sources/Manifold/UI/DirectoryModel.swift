import AppKit
import ManifoldCore
import UniformTypeIdentifiers

/// One file or folder in a browser, the same object each time it's asked
/// for (an outline and a browser key their rows by identity).
final class BrowserNode {
    let path: String
    var entry: DirectoryEntry
    var name: String { path.lastPathComponent }
    var isDirectory: Bool { entry.isDirectory }
    /// Hidden or ignored: shown dimmed, when shown.
    var isMuted: Bool { entry.isHidden || entry.isIgnored == true }

    init(path: String, entry: DirectoryEntry) {
        self.path = path
        self.entry = entry
    }

    var kind: String {
        if isDirectory { return "Folder" }
        return UTType(filenameExtension: name.pathExtension)?.localizedDescription?.capitalizingFirst ?? "Document"
    }

    var sizeText: String { isDirectory ? "--" : ByteCountFormatter.string(fromByteCount: entry.size, countStyle: .file) }

    var modifiedText: String { BrowserNode.dates.string(from: Date(timeIntervalSince1970: entry.modified)) }

    static let dates: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .short
        f.doesRelativeDateFormatting = true
        return f
    }()

    private static var icons: [String: NSImage] = [:]

    /// The Finder's icon for its type (not the file's own: the same for a
    /// file on another host as on this one).
    var icon: NSImage {
        let key = isDirectory ? "/" : name.pathExtension.lowercased()
        if let i = BrowserNode.icons[key] { return i }
        let type: UTType = isDirectory ? .folder : (UTType(filenameExtension: key) ?? .data)
        let i = NSWorkspace.shared.icon(for: type)
        BrowserNode.icons[key] = i
        return i
    }
}

extension String {
    var capitalizingFirst: String { prefix(1).uppercased() + dropFirst() }
}

/// The group a folder's entry is shown under, as the Finder's Use Groups
/// has them by kind — but code by its language: folders (first, and not
/// headed in columns), Documents, PDF
/// Documents, Rust, Swift, … (each language its own, by name), Build,
/// Configuration, Spreadsheets, Presentations, Images, Movies, Music,
/// Archives, Other. `rank` orders them.
struct FileGroup: Hashable {
    let rank: Int
    let title: String

    static let folders = FileGroup(rank: 0, title: "Folders")
    static let documents = FileGroup(rank: 10, title: "Documents")
    static let pdf = FileGroup(rank: 11, title: "PDF Documents")
    static func language(_ name: String) -> FileGroup { FileGroup(rank: 20, title: name) }
    static let build = FileGroup(rank: 30, title: "Build")
    static let configuration = FileGroup(rank: 31, title: "Configuration")
    static let spreadsheets = FileGroup(rank: 40, title: "Spreadsheets")
    static let presentations = FileGroup(rank: 41, title: "Presentations")
    static let images = FileGroup(rank: 50, title: "Images")
    static let movies = FileGroup(rank: 51, title: "Movies")
    static let music = FileGroup(rank: 52, title: "Music")
    static let archives = FileGroup(rank: 60, title: "Archives")
    static let other = FileGroup(rank: 99, title: "Other")

    /// Groups in the order shown: by rank, languages by name.
    static func < (a: FileGroup, b: FileGroup) -> Bool {
        a.rank != b.rank ? a.rank < b.rank : a.title.localizedStandardCompare(b.title) == .orderedAscending
    }

    static func of(_ name: String, isDirectory: Bool) -> FileGroup {
        if isDirectory { return .folders }
        let lower = name.lowercased(), ext = lower.pathExtension
        if let g = byName[lower] { return g }
        if !ext.isEmpty, let l = languages[ext] { return .language(l) }
        if let g = byExtension[ext] { return g }
        // Not in the tables: by what the system makes of its type.
        guard !ext.isEmpty, let t = UTType(filenameExtension: ext) else { return .other }
        if t.conforms(to: .pdf) { return .pdf }
        if t.conforms(to: .image) { return .images }
        if t.conforms(to: .movie) { return .movies }
        if t.conforms(to: .audio) { return .music }
        if t.conforms(to: .archive) || t.conforms(to: .diskImage) { return .archives }
        if t.conforms(to: .spreadsheet) { return .spreadsheets }
        if t.conforms(to: .presentation) { return .presentations }
        if t.conforms(to: .sourceCode) { return .language(t.localizedDescription?.capitalizingFirst ?? "Source Code") }
        if t.conforms(to: .text) || t.conforms(to: .compositeContent) { return .documents }
        return .other
    }

    /// Files known by their whole name.
    private static let byName: [String: FileGroup] = {
        var m: [String: FileGroup] = [:]
        for n in ["readme", "license", "licence", "copying", "authors", "notice", "changelog", "contributing", "todo", "news"] { m[n] = .documents }
        for n in ["makefile", "gnumakefile", "dockerfile", "containerfile", "justfile", "cmakelists.txt", "build", "build.bazel",
                  "workspace", "rakefile", "gemfile", "procfile", "vagrantfile", "meson.build"] { m[n] = .build }
        for n in [".gitignore", ".gitattributes", ".gitmodules", ".editorconfig", ".env", ".envrc", ".dockerignore", ".clang-format",
                  ".swiftlint.yml", ".prettierrc", ".eslintrc"] { m[n] = .configuration }
        return m
    }()

    /// Code, by extension, named by its language.
    private static let languages: [String: String] = {
        var m: [String: String] = [:]
        let table: [(String, [String])] = [
            ("Swift", ["swift", "swiftinterface"]), ("Rust", ["rs"]), ("Go", ["go"]), ("C", ["c", "h"]),
            ("C++", ["cc", "cpp", "cxx", "c++", "hpp", "hh", "hxx", "ipp", "inl"]), ("Objective-C", ["m", "mm"]),
            ("Python", ["py", "pyi", "pyx", "ipynb"]), ("Ruby", ["rb", "erb"]), ("JavaScript", ["js", "mjs", "cjs", "jsx"]),
            ("TypeScript", ["ts", "mts", "cts", "tsx"]), ("Java", ["java"]), ("Kotlin", ["kt", "kts"]), ("Scala", ["scala", "sc"]),
            ("Zig", ["zig"]), ("Lua", ["lua"]), ("Haskell", ["hs", "lhs"]), ("OCaml", ["ml", "mli"]), ("Elixir", ["ex", "exs"]),
            ("Erlang", ["erl", "hrl"]), ("PHP", ["php"]), ("C#", ["cs"]), ("F#", ["fs", "fsi", "fsx"]), ("Dart", ["dart"]),
            ("Julia", ["jl"]), ("R", ["r"]), ("Perl", ["pl", "pm"]), ("Clojure", ["clj", "cljs", "cljc", "edn"]),
            ("Elm", ["elm"]), ("Nim", ["nim"]), ("Odin", ["odin"]), ("V", ["v"]), ("D", ["d"]), ("Fortran", ["f", "f90", "f95"]),
            ("Assembly", ["s", "asm"]), ("Shell", ["sh", "bash", "zsh", "fish", "ksh", "command", "rc"]),
            ("PowerShell", ["ps1", "psm1"]), ("SQL", ["sql"]), ("HTML", ["html", "htm", "xhtml"]),
            ("CSS", ["css", "scss", "sass", "less"]), ("Vue", ["vue"]), ("Svelte", ["svelte"]), ("Nix", ["nix"]),
            ("Protocol Buffers", ["proto"]), ("GraphQL", ["graphql", "gql"]), ("Metal", ["metal"]), ("GLSL", ["glsl", "vert", "frag"]),
            ("Lisp", ["lisp", "el", "scm", "rkt"]), ("Tcl", ["tcl"]), ("Verilog", ["v", "sv"]), ("Solidity", ["sol"]),
            ("Gleam", ["gleam"]), ("Starlark", ["bzl", "star"]),
        ]
        for (lang, exts) in table { for e in exts where m[e] == nil { m[e] = lang } }
        return m
    }()

    private static let byExtension: [String: FileGroup] = {
        var m: [String: FileGroup] = [:]
        let table: [(FileGroup, [String])] = [
            (.documents, ["md", "markdown", "mdx", "txt", "text", "rst", "org", "adoc", "tex", "bib", "rtf", "doc", "docx", "pages",
                          "odt", "epub", "man"]),
            (.pdf, ["pdf"]),
            (.build, ["mk", "cmake", "gradle", "bazel", "ninja", "podspec", "xcodeproj", "pbxproj", "xcworkspace"]),
            (.configuration, ["json", "jsonc", "json5", "yaml", "yml", "toml", "plist", "ini", "conf", "cfg", "config", "xcconfig",
                              "lock", "env", "properties", "xml", "entitlements", "xcscheme", "modulemap"]),
            (.spreadsheets, ["csv", "tsv", "xlsx", "xls", "numbers", "ods"]),
            (.presentations, ["key", "pptx", "ppt", "odp"]),
            (.images, ["png", "jpg", "jpeg", "gif", "heic", "heif", "webp", "svg", "ico", "icns", "tiff", "tif", "bmp", "psd", "avif"]),
            (.movies, ["mp4", "mov", "m4v", "webm", "mkv", "avi"]),
            (.music, ["mp3", "wav", "m4a", "aac", "flac", "ogg", "aiff", "aif", "opus"]),
            (.archives, ["zip", "tar", "gz", "tgz", "xz", "bz2", "zst", "7z", "rar", "dmg", "pkg", "jar", "whl"]),
        ]
        for (g, exts) in table { for e in exts { m[e] = g } }
        return m
    }()

    /// Entries in their groups, the groups in order and each keeping the
    /// order it was given.
    static func grouped(_ nodes: [BrowserNode]) -> [(FileGroup, [BrowserNode])] {
        var by: [FileGroup: [BrowserNode]] = [:]
        for n in nodes { by[n.group, default: []].append(n) }
        return by.keys.sorted(by: <).map { ($0, by[$0]!) }
    }
}

extension BrowserNode {
    var group: FileGroup { FileGroup.of(name, isDirectory: isDirectory) }
}

/// What a file browser knows of the folders under its root (§7.4): each
/// folder's entries as the host lists them, asked for as they're opened;
/// hidden and ignored ones shown only when asked; and, when a filter is
/// typed, the whole tree, its files matching it ranked as the picker ranks
/// them (its letters in order, in the name for more).
final class DirectoryModel {
    private(set) var root: String
    var showHidden = false
    enum SortKey: String { case name, modified, size, kind }
    var sortKey = SortKey.name
    var ascending = true
    /// Columns' entries under headers by kind, code by language (View ▸
    /// Use Groups), each group in the sort's order.
    var useGroups = true

    /// Lists a folder on the block's host.
    var list: (String, @escaping ([DirectoryEntry]?) -> Void) -> Void = { _, done in done(nil) }
    /// Lists the tree under a folder on the block's host.
    var listTree: (String, @escaping ([DirectoryEntry]?, Bool) -> Void) -> Void = { _, done in done(nil, false) }
    /// A folder's entries changed (its absolute path).
    var changed: (String) -> Void = { _ in }
    /// What the filter shows changed.
    var filterChanged: () -> Void = {}
    /// Folders began or finished being listed for the first time.
    var readingChanged: () -> Void = {}

    private var listed: [String: [DirectoryEntry]] = [:]
    private var asking: Set<String> = []
    private var nodes: [String: BrowserNode] = [:]

    init(root: String) { self.root = root }

    func node(_ path: String, _ entry: DirectoryEntry) -> BrowserNode {
        if let n = nodes[path] {
            n.entry = entry
            return n
        }
        let n = BrowserNode(path: path, entry: entry)
        nodes[path] = n
        return n
    }

    func existingNode(_ path: String) -> BrowserNode? { nodes[path] }

    func relative(_ path: String) -> String {
        if path == root { return "" }
        return path.hasPrefix(root + "/") ? String(path.dropFirst(root.count + 1)) : path
    }

    func absolute(_ rel: String) -> String { rel.isEmpty ? root : root.appendingPathComponent(rel) }

    // MARK: Listing

    /// The root's entries, as its block has them.
    func setRootEntries(_ entries: [DirectoryEntry]) {
        guard listed[root] != entries else { return }
        listed[root] = entries
        changed(root)
    }

    /// Whether folders asked for are still being listed the first time (not
    /// those listed again to keep current, which show as they are).
    var readingFolders: Bool { asking.contains { listed[$0] == nil } }

    /// The entries shown in a folder, sorted; nil while they're being
    /// listed (asked for, and `changed` told when they come).
    func children(of folder: String) -> [BrowserNode]? {
        guard let l = listed[folder] else {
            // (The root comes with its block's listing, `setRootEntries`:
            // not asked for again, twice over a slow link.)
            load(folder)
            // Under a filter, the tree has it meanwhile: columns down to a
            // match at once, not a folder at a time.
            if filtering, let t = treeChildren(folder) { return sorted(t.filter(shown)).map { node(folder.appendingPathComponent($0.name), $0) } }
            return nil
        }
        return sorted(l.filter(shown)).map { node(folder.appendingPathComponent($0.name), $0) }
    }

    /// A folder's entries as the tree has them (named by their own names),
    /// the tree gone through once per listing of it.
    private func treeChildren(_ folder: String) -> [DirectoryEntry]? {
        guard let tree else { return nil }
        if treeByFolder?.at != treeAt {
            var byFolder: [String: [DirectoryEntry]] = [:]
            for e in tree {
                var own = e
                own.name = e.name.lastPathComponent
                byFolder[e.name.deletingLastPathComponent, default: []].append(own)
            }
            treeByFolder = (treeAt, byFolder)
        }
        return treeByFolder?.entries[relative(folder)]
    }
    private var treeByFolder: (at: Date?, entries: [String: [DirectoryEntry]])?

    func shown(_ e: DirectoryEntry) -> Bool { showHidden || (!e.isHidden && e.isIgnored != true) }

    private func load(_ folder: String) {
        // The root is its block's, listed by the host and kept current there.
        guard folder != root, !asking.contains(folder) else { return }
        let first = listed[folder] == nil
        asking.insert(folder)
        if first { readingChanged() }
        list(folder) { [weak self] entries in
            guard let self else { return }
            self.asking.remove(folder)
            let fresh = entries ?? []
            if self.listed[folder] != fresh {
                self.listed[folder] = fresh
                self.changed(folder)
            }
            if first { self.readingChanged() }
        }
    }

    /// Debugging: the folders being listed, those the first time marked.
    var debugAsking: String { asking.map { relative($0) + (listed[$0] == nil ? "*" : "") }.sorted().joined(separator: " ") }

    /// Folders asked for ahead of being opened (all at once, not each after the one above).
    func prefetch(_ folders: [String]) {
        for f in folders where listed[f] == nil { load(f) }
    }

    /// Folders listed again (those shown, say), each told if it changed.
    func refresh(_ folders: [String]) {
        for f in folders where f != root && listed[f] != nil { load(f) }
    }

    private func sorted(_ entries: [DirectoryEntry]) -> [DirectoryEntry] {
        entries.sorted { a, b in
            if a.isDirectory != b.isDirectory { return a.isDirectory }
            let less: Bool
            switch sortKey {
            case .name: less = a.name.lastPathComponent.standardCompare(b.name.lastPathComponent)
            case .modified: less = a.modified == b.modified ? a.name.standardCompare(b.name) : a.modified < b.modified
            case .size: less = a.size == b.size ? a.name.standardCompare(b.name) : a.size < b.size
            case .kind:
                let ka = a.name.pathExtension.lowercased(), kb = b.name.pathExtension.lowercased()
                less = ka == kb ? a.name.standardCompare(b.name) : ka < kb
            }
            return ascending ? less : !less
        }
    }

    // MARK: Filtering

    private(set) var filter = ""
    var filtering: Bool { !filter.isEmpty }
    /// The tree (entries named by their path, relative), when it's in hand.
    private var tree: [DirectoryEntry]?
    private var treeAt: Date?
    private(set) var treeComplete = true
    private var treeAsked = false
    /// Under the filter: the files matching it (relative), best first, and
    /// where its letters fell in each.
    private(set) var matches: [String] = []
    private(set) var matchedAt: [String: [Int]] = [:]
    /// Every file matching it (relative), not only those listed, and the
    /// folders they're in, every one on the way: what columns keep.
    private(set) var matchedFiles: Set<String> = []
    private var onTheWay: Set<String> = []
    var isLoadingTree: Bool { filtering && tree == nil }
    /// The most matches shown.
    static let matchLimit = 1000

    func setFilter(_ text: String) {
        let t = text.trimmingCharacters(in: .whitespaces)
        guard t != filter else { return }
        filter = t
        if filtering, tree == nil || Date().timeIntervalSince(treeAt ?? .distantPast) > 30 { loadTree() }
        recompute()
        filterChanged()
    }

    private func loadTree() {
        guard !treeAsked else { return }
        treeAsked = true
        listTree(root) { [weak self] entries, complete in
            guard let self else { return }
            self.treeAsked = false
            self.tree = entries ?? []
            self.treeAt = Date()
            self.treeComplete = complete
            self.recompute()
            self.filterChanged()
        }
    }

    /// The tree's files ranked against the filter — on another thread, as
    /// a tree of tens of thousands takes a while to go through (about
    /// 80 ms at 20,000 files, at every key): the matches shown are the
    /// last ones until the new are in, those of a filter typed since not
    /// taken. Narrowed from the last ones when the filter only grew and
    /// they were all there were.
    private func recompute() {
        rankGeneration &+= 1
        guard filtering, let tree else {
            matches = []
            matchedAt = [:]
            matchedFiles = []
            onTheWay = []
            ranked = nil
            return
        }
        let generation = rankGeneration, filter = self.filter, showHidden = self.showHidden
        let from: [String]
        if let r = ranked, r.complete, r.showHidden == showHidden, filter.lowercased().hasPrefix(r.filter.lowercased()), r.tree == treeAt {
            from = r.all
        } else {
            from = tree.filter { !$0.isDirectory }.map(\.name)
        }
        let treeAt = self.treeAt
        DispatchQueue.global(qos: .userInteractive).async {
            var scored: [(String, Int)] = []
            for name in from where showHidden || !name.split(separator: "/").contains(where: { $0.hasPrefix(".") }) {
                if let s = FileFinder.score(filter, name) { scored.append((name, s)) }
            }
            scored.sort { $0.1 != $1.1 ? $0.1 > $1.1 : $0.0.count < $1.0.count }
            let all = scored.map(\.0)
            let shown = Array(all.prefix(Self.matchLimit))
            var at: [String: [Int]] = [:]
            for m in shown { at[m] = FileFinder.positions(filter, m) }
            let files = Set(all)
            var folders = Set<String>()
            for m in all {
                var d = m.deletingLastPathComponent
                while !d.isEmpty, folders.insert(d).inserted { d = d.deletingLastPathComponent }
            }
            DispatchQueue.main.async { [weak self] in
                guard let self, self.rankGeneration == generation else { return }
                self.matches = shown
                self.matchedAt = at
                self.matchedFiles = files
                self.onTheWay = folders
                self.ranked = (filter, showHidden, all, true, treeAt)
                self.filterChanged()
            }
        }
    }
    private var rankGeneration = 0
    /// The last ranking: its filter, every file it matched (for a longer
    /// filter to narrow from), and the tree it went through.
    private var ranked: (filter: String, showHidden: Bool, all: [String], complete: Bool, tree: Date?)?

    /// Whether an entry stays under the filter, in columns: a file matching
    /// it, or a folder with one somewhere under it.
    func keeps(_ path: String) -> Bool {
        guard filtering else { return true }
        let rel = relative(path)
        return matchedFiles.contains(rel) || onTheWay.contains(rel)
    }

    /// The files that matched, as nodes, best first.
    func matchedNodes() -> [BrowserNode] {
        guard let tree else { return [] }
        if treeByName?.at != treeAt {
            treeByName = (treeAt, Dictionary(tree.map { ($0.name, $0) }, uniquingKeysWith: { a, _ in a }))
        }
        let byName = treeByName?.entries ?? [:]
        return matches.compactMap { rel in byName[rel].map { node(absolute(rel), $0) } }
    }
    /// The tree's entries by name, made once per listing of it.
    private var treeByName: (at: Date?, entries: [String: DirectoryEntry])?
}
