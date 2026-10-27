import Foundation

/// The paths under a folder, found as they're wanted (Insert Path, §3.8):
/// the folder's own entries first; then, once asked to go on, the folders
/// under it a level at a time, nearest first, several listed at once (a
/// remote host's answers take a while each), each folder's entries there
/// as soon as it comes. A folder looked for (gone into) is listed before
/// the rest. Hidden folders, those a repository ignores, dependencies and
/// packages are listed as entries but not gone into. It never waits: the
/// listing is given (one folder's entries, answered whenever), and what's
/// found is there to read at any time. Confined to the thread it's used
/// on; `list` answers there too.
public final class PathCrawl {
    public struct Found: Sendable {
        /// Relative to the root.
        public var path: String
        public var isFolder: Bool
        public var depth: Int
        public var modified: Double
    }

    public let root: String
    /// What's been found, in the order it came: nearest first.
    public private(set) var found: [Found] = []
    /// Each folder's entries (indices into `found`), by its relative path
    /// ("" for the root), once listed.
    public private(set) var children: [String: [Int]] = [:]
    /// Whether to go on past the root's own entries.
    public var going = false { didSet { if going != oldValue { pump() } } }
    /// A folder (relative) to list before the rest, and what's under it.
    public var toward: String? { didSet { if toward != oldValue { pump() } } }
    /// Told as anything is found, and as it stops.
    public var onChange: (() -> Void)?

    public var listing: Int { inFlight }
    public var foldersListed: Int { children.count }
    /// Everything there is to find is found (or as much as it will find).
    public var finished: Bool { (head >= pending.count || stopped) && inFlight == 0 && children[""] != nil }

    private let list: (String, @escaping ([DirectoryEntry]?) -> Void) -> Void
    private let skipLibrary: Bool
    private var pending: [(path: String, depth: Int)] = []
    private var head = 0
    private var inFlight = 0
    private var asked: Set<String> = []
    private var pumping = false
    private var stopped: Bool { found.count >= maxFound || children.count >= maxFolders }

    public let maxFound: Int
    public let maxFolders: Int
    public let maxDepth: Int
    public let concurrency: Int

    /// `list` lists one folder (absolute), answering nil if it can't be;
    /// `home`, the host's: its Library isn't gone into.
    public init(root: String, home: String?, maxFound: Int = 60_000, maxFolders: Int = 6_000, maxDepth: Int = 14, concurrency: Int = 8,
                list: @escaping (String, @escaping ([DirectoryEntry]?) -> Void) -> Void) {
        self.root = root
        self.list = list
        self.maxFound = maxFound
        self.maxFolders = maxFolders
        self.maxDepth = maxDepth
        self.concurrency = concurrency
        skipLibrary = home.map { (root.hasSuffix("/") ? String(root.dropLast()) : root) == $0 } ?? false
        pending = [("", 0)]
        pump()
    }

    /// The absolute path of a relative one.
    public func absolute(_ rel: String) -> String {
        rel.isEmpty ? root : (root.hasSuffix("/") ? root + rel : root + "/" + rel)
    }

    /// Folders listed next, as many at once as it takes: the root first,
    /// alone; then, going on, one toward the folder looked for, else the
    /// nearest.
    private func pump() {
        guard !pumping else { return }
        pumping = true
        defer { pumping = false }
        while inFlight < concurrency, !stopped {
            let rootListed = children[""] != nil
            guard rootListed ? going : inFlight == 0 && asked.isEmpty, let next = takeNext() else { break }
            asked.insert(next.path)
            inFlight += 1
            list(absolute(next.path)) { [weak self] entries in self?.listed(next.path, depth: next.depth, entries) }
        }
    }

    private func takeNext() -> (path: String, depth: Int)? {
        if let toward, !toward.isEmpty,
           let i = pending[head...].firstIndex(where: { toward == $0.path || toward.hasPrefix($0.path + "/") || $0.path.hasPrefix(toward + "/") }) {
            let next = pending[i]
            pending.remove(at: i)
            return next
        }
        while head < pending.count {
            let next = pending[head]
            head += 1
            if !asked.contains(next.path) { return next }
        }
        // (Compacted now and then: what's been taken from the front.)
        if head > 4096 { pending.removeFirst(head); head = 0 }
        return nil
    }

    private func listed(_ path: String, depth: Int, _ entries: [DirectoryEntry]?) {
        inFlight -= 1
        var mine: [Int] = []
        for e in (entries ?? []).sorted(by: { $0.name.localizedStandardCompare($1.name) == .orderedAscending }) {
            guard found.count < maxFound else { break }
            let rel = path.isEmpty ? e.name : path + "/" + e.name
            mine.append(found.count)
            found.append(Found(path: rel, isFolder: e.isDirectory, depth: depth + 1, modified: e.modified))
            if e.isDirectory, depth + 1 < maxDepth, Self.goesInto(e, under: path, skipLibrary: skipLibrary) {
                pending.append((rel, depth + 1))
            }
        }
        children[path] = mine
        onChange?()
        pump()
        if finished { onChange?() }
    }

    /// Folders not gone into: hidden ones, what the repository ignores,
    /// dependencies and build products, packages — and a home's Library.
    static func goesInto(_ e: DirectoryEntry, under parent: String, skipLibrary: Bool) -> Bool {
        if e.isHidden || e.name.hasPrefix(".") || e.isIgnored == true { return false }
        if FileFinder.skipped.contains(e.name) { return false }
        if packages.contains(e.name.pathExtension.lowercased()) { return false }
        if skipLibrary, parent.isEmpty, e.name == "Library" { return false }
        return true
    }

    static let packages: Set<String> = ["app", "bundle", "framework", "xcodeproj", "xcworkspace", "photoslibrary", "musiclibrary",
                                        "tvlibrary", "xcarchive", "kext", "plugin", "appex", "lproj", "xcassets", "playground"]
}
