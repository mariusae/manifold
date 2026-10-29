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
