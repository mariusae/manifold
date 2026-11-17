import Foundation

/// What a file browser shows of a folder (§7.4): its entries, those its
/// repository ignores marked; and the tree under it, without them — git's
/// tracked and untracked-but-not-ignored files, Sapling's tracked and
/// unknown ones, or, outside a repository, what a walk finds (hidden and
/// dependency folders skipped). Each asked so its cost goes with what's
/// shown or asked for, never with the size of the repository: a folder's
/// marks by its names, a tree no further than its limit.
public enum FolderListing {
    /// A folder's entries, folders first, with `isIgnored` set.
    public static func children(of path: String) -> [DirectoryEntry]? {
        guard var entries = TextFile.list(path) else { return nil }
        let ignored = ignoredNames(in: path, names: entries.map(\.name))
        for i in entries.indices { entries[i].isIgnored = ignored.contains(entries[i].name) }
        return entries
    }

    /// The names among `names`, in the folder at `path`, its repository
    /// ignores — kept, and answered again without asking the repository
    /// while nothing it hangs on has changed: the folder (entries come or
    /// go), the repository's state (what's tracked), the ignore files at
    /// its root and in the folder; half a minute at most. Asked of each
    /// name, never of all under the folder (in a monorepo, millions).
    static func ignoredNames(in path: String, names: [String]) -> Set<String> {
        guard !names.isEmpty, let repo = VCS.repository(of: path) else { return [] }
        let token = ignoreToken(path, repo: repo)
        let asked = Set(names)
        ignoreLock.lock()
        if let c = ignoreCache[path], c.token == token, c.names == asked, Date().timeIntervalSince(c.at) < 30 {
            ignoreLock.unlock()
            return c.ignored
        }
        ignoreLock.unlock()
        let ignored = askIgnored(in: path, names: names, repo: repo)
        ignoreLock.lock()
        if ignoreCache.count > 500 { ignoreCache.removeAll() }
        ignoreCache[path] = (token, Date(), asked, ignored)
        ignoreLock.unlock()
        return ignored
    }

    private static let ignoreLock = NSLock()
    nonisolated(unsafe) private static var ignoreCache: [String: (token: String, at: Date, names: Set<String>, ignored: Set<String>)] = [:]

    /// What an answer for a folder hangs on, as modification times.
    private static func ignoreToken(_ path: String, repo: (root: String, vcs: VCS)) -> String {
        func mtime(_ p: String) -> String {
            ((try? FileManager.default.attributesOfItem(atPath: p))?[.modificationDate] as? Date).map { "\($0.timeIntervalSince1970)" } ?? "-"
        }
        let state = repo.vcs == .git ? ".git/index" : (FileManager.default.fileExists(atPath: repo.root + "/.sl") ? ".sl/dirstate" : ".hg/dirstate")
        return [path, repo.root + "/" + state, repo.root + "/.gitignore", path + "/.gitignore"].map(mtime).joined(separator: "|")
    }

    private static func askIgnored(in path: String, names: [String], repo: (root: String, vcs: VCS)) -> Set<String> {
        switch repo.vcs {
        case .git:
            // check-ignore leaves tracked files out: only what's ignored.
            let input = Data((names.joined(separator: "\0") + "\0").utf8)
            guard let r = try? Child.run(["git", "-C", path, "check-ignore", "-z", "--stdin"], input: input, timeout: 10, quiet: true) else { return [] }
            return Set(r.output.split(separator: 0).map { String(decoding: $0, as: UTF8.self) })
        case .sapling:
            return saplingIgnored(in: path, names: names, root: repo.root)
        }
    }

    /// Sapling's ignored among a folder's names, asked of each name — never
    /// of what's under the folder (in a monorepo that's millions of files):
    /// `debugignore` says which its rules ignore, and of those, the files
    /// it tracks in the folder and the folders holding any it tracks (a
    /// first one found is enough) aren't. Nothing said when it can't say.
    static func saplingIgnored(in path: String, names: [String], root: String) -> Set<String> {
        guard let rel = path.relative(to: root) else { return [] }
        let prefix = rel.isEmpty || rel == "." ? "" : rel + "/"
        let asked = names.filter { $0 != ".sl" && $0 != ".hg" }
        var ruled = Set<String>()
        // In batches, so the arguments stay well within what a command takes.
        var i = 0
        while i < asked.count {
            let batch = Array(asked[i..<min(i + 300, asked.count)])
            i += batch.count
            guard let out = Scans.run(["sl", "--cwd", root, "debugignore"] + batch.map { prefix + $0 }, records: .max, root: root, timeout: 10) else { return [] }
            let said = String(decoding: out, as: UTF8.self)
            for line in said.split(separator: "\n") {
                for name in batch where line.hasPrefix(prefix + name + ": ignored") { ruled.insert(name) }
            }
        }
        guard !ruled.isEmpty else { return [] }
        let folders = Set(TextFile.list(path)?.filter(\.isDirectory).map(\.name) ?? [])
        // Tracked though its rules say otherwise: kept.
        if ruled.contains(where: { !folders.contains($0) }),
           let out = Scans.run(["sl", "--cwd", root, "files", "-0", "rootfilesin:" + (prefix.isEmpty ? "." : rel)], records: .max, root: root, timeout: 10) {
            for raw in out.split(separator: 0) { ruled.remove(String(decoding: raw, as: UTF8.self).lastPathComponent) }
        }
        for name in ruled where folders.contains(name) {
            if let out = Scans.run(["sl", "--cwd", root, "files", "-0", "path:" + prefix + name], records: 1, root: root, timeout: 10), !out.isEmpty {
                ruled.remove(name)
            }
        }
        return ruled
    }

    /// Sapling's tracked and unknown files under `path`, relative to it, at
    /// most `limit`: what's new first (`status`, which Sapling's virtual
    /// file system answers from its journal), then what's tracked (from
    /// the commit's tree, only the part under `path` read) — each command
    /// ended once it's given enough. Where `status` would walk every file
    /// (a large repository without such a file system), only what's
    /// tracked. Nil when Sapling couldn't say.
    static func saplingFiles(in path: String, limit: Int, root: String? = nil) -> (paths: [String], complete: Bool)? {
        var paths: [String] = []
        var seen = Set<String>()
        let walksForStatus = root.map { Repositories.isLarge($0) && !Repositories.isVirtual($0) } ?? false
        // `status` names files relative to where it's run from, not to
        // `--cwd` (a folder through a link, /tmp, came out as ../../private/…):
        // asked from the root, its part taken off.
        let under = root.flatMap { path.relative(to: $0) }.map { $0.isEmpty || $0 == "." ? "" : $0 + "/" }
        let commands = (walksForStatus || under == nil ? [] : [["status", "-u", "-n", "-0", "--root-relative", "."]]) + [["files", "-0", "."]]
        for args in commands {
            let wanted = limit - paths.count + 1
            guard let r = Scans.run(["sl", "--cwd", path] + args, records: wanted, root: root ?? path) else { return nil }
            for raw in r.split(separator: 0) {
                var p = String(decoding: raw, as: UTF8.self)
                if args[0] == "status", let under {
                    guard p.hasPrefix(under) else { continue }
                    p.removeFirst(under.count)
                }
                guard seen.insert(p).inserted else { continue }
                paths.append(p)
                if paths.count >= limit { return (paths, false) }
            }
        }
        return (paths, true)
    }

    /// The files under `root` changed and not committed — modified, added,
    /// new and not ignored — relative to it, at most `limit`: what version
    /// control keeps track of, not every file looked at. Nil where it
    /// can't say without looking at every file (a large repository not
    /// on a virtual file system) or isn't a repository.
    public static func changed(under root: String, limit: Int = 10_000) -> [String]? {
        guard let repo = VCS.repository(of: root) else { return nil }
        let argv: [String]
        switch repo.vcs {
        case .git: argv = ["git", "-C", root, "--no-optional-locks", "ls-files", "-z", "--modified", "--others", "--exclude-standard"]
        case .sapling:
            guard !Repositories.isLarge(repo.root) || Repositories.isVirtual(repo.root) else { return nil }
            argv = ["sl", "--cwd", root, "status", "-m", "-a", "-u", "-n", "-0", "--root-relative", "."]
        }
        guard let out = Scans.run(argv, records: limit, root: repo.root) else { return nil }
        let under = repo.vcs == .git ? "" : (root.relative(to: repo.root).map { $0.isEmpty || $0 == "." ? "" : $0 + "/" } ?? "")
        return Array(Set(out.split(separator: 0).compactMap { raw -> String? in
            let p = String(decoding: raw, as: UTF8.self)
            guard p.hasPrefix(under) else { return nil }
            return String(p.dropFirst(under.count))
        })).sorted()
    }

    /// The files under `root` not ignored, and the folders holding them, as
    /// entries named by their paths relative to it; `complete` is false
    /// when there were more than `limit` files.
    public static func tree(of root: String, limit: Int = 20_000) -> (entries: [DirectoryEntry], complete: Bool) {
        let f = files(under: root, limit: limit)
        let large = VCS.repository(of: root).map { Repositories.isLarge($0.root) } ?? false
        return (entries(root: root, files: f.paths, look: !large), f.complete)
    }

    /// The files under `root` not ignored, relative to it — its version
    /// control's (git's or Sapling's), else found by walking — at most
    /// `limit`; `complete` is false when there were more.
    /// In a large repository, never a walk (what it would read is what
    /// its version control is there not to).
    public static func files(under root: String, limit: Int = 20_000) -> (paths: [String], complete: Bool) {
        var files: [String]
        let repo = VCS.repository(of: root)
        let walk = { repo.map { Repositories.isLarge($0.root) } == true ? [] : FileFinder.walk(root: root, limit: limit + 1) }
        switch repo?.vcs {
        case .git?: files = FileFinder.gitFiles(root: root, limit: limit + 1) ?? walk()
        case .sapling?: files = saplingFiles(in: root, limit: limit + 1, root: repo?.root)?.paths ?? walk()
        case nil: files = walk()
        }
        let complete = files.count <= limit
        if !complete { files.removeLast(files.count - limit) }
        return (files, complete)
    }

    /// Files and the folders they imply, each looked at once — or, `look`
    /// false, not at all (in a virtual file system, looking at a file not
    /// yet fetched asks a server for it): named, sizes and dates unknown.
    static func entries(root: String, files: [String], look: Bool = true) -> [DirectoryEntry] {
        var folders = Set<String>()
        for f in files {
            var dir = f.deletingLastPathComponent
            while !dir.isEmpty, dir != ".", folders.insert(dir).inserted { dir = dir.deletingLastPathComponent }
        }
        let fm = FileManager.default
        func entry(_ rel: String, folder: Bool) -> DirectoryEntry? {
            guard look else {
                return DirectoryEntry(name: rel, isDirectory: folder, size: 0, modified: 0, isHidden: rel.lastPathComponent.hasPrefix("."))
            }
            guard let a = try? fm.attributesOfItem(atPath: root.appendingPathComponent(rel)) else { return nil }
            let name = rel.lastPathComponent
            return DirectoryEntry(name: rel, isDirectory: folder || (a[.type] as? FileAttributeType) == .typeDirectory,
                                  size: (a[.size] as? Int64) ?? 0, modified: (a[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0,
                                  isHidden: name.hasPrefix("."))
        }
        return folders.sorted().compactMap { entry($0, folder: true) } + files.compactMap { entry($0, folder: false) }
    }
}
