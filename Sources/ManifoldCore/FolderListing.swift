import Foundation

/// What a file browser shows of a folder (§7.4): its entries, those its
/// repository ignores marked; and the tree under it, without them — git's
/// tracked and untracked-but-not-ignored files, Sapling's tracked and
/// unknown ones, or, outside a repository, what a walk finds (hidden and
/// dependency folders skipped).
public enum FolderListing {
    /// A folder's entries, folders first, with `isIgnored` set.
    public static func children(of path: String) -> [DirectoryEntry]? {
        guard var entries = TextFile.list(path) else { return nil }
        let ignored = ignoredNames(in: path, names: entries.map(\.name))
        for i in entries.indices { entries[i].isIgnored = ignored.contains(entries[i].name) }
        return entries
    }

    /// The names among `names`, in the folder at `path`, its repository ignores.
    static func ignoredNames(in path: String, names: [String]) -> Set<String> {
        guard !names.isEmpty, let repo = VCS.repository(of: path) else { return [] }
        switch repo.vcs {
        case .git:
            let input = Data((names.joined(separator: "\0") + "\0").utf8)
            guard let r = try? Child.run(["git", "-C", path, "check-ignore", "-z", "--stdin"], input: input, timeout: 10, quiet: true) else { return [] }
            return Set(r.output.split(separator: 0).map { String(decoding: $0, as: UTF8.self) })
        case .sapling:
            // Sapling has no check-ignore: what's tracked or unknown under
            // the folder is shown, and the rest of its names are ignored —
            // unless the listing didn't finish, when nothing is said.
            guard let shown = saplingFiles(in: path, limit: 200_000) , shown.complete else { return [] }
            let visible = Set(shown.paths.map { $0.split(separator: "/", maxSplits: 1).first.map(String.init) ?? $0 })
            return Set(names.filter { !visible.contains($0) && $0 != ".sl" && $0 != ".hg" })
        }
    }

    /// Sapling's tracked and unknown files under `path`, relative to it.
    static func saplingFiles(in path: String, limit: Int) -> (paths: [String], complete: Bool)? {
        var paths: [String] = []
        for args in [["files", "-0", "."], ["status", "-u", "-n", "-0", "."]] {
            guard let r = try? Child.run(["sl", "--cwd", path] + args, timeout: 20, quiet: true), r.status == 0 else { return nil }
            for raw in r.output.split(separator: 0) {
                paths.append(String(decoding: raw, as: UTF8.self))
                if paths.count >= limit { return (paths, false) }
            }
        }
        return (paths, true)
    }

    /// The files under `root` not ignored, and the folders holding them, as
    /// entries named by their paths relative to it; `complete` is false
    /// when there were more than `limit` files.
    public static func tree(of root: String, limit: Int = 20_000) -> (entries: [DirectoryEntry], complete: Bool) {
        var files: [String]
        var complete: Bool
        switch VCS.repository(of: root)?.vcs {
        case .git?:
            if let f = FileFinder.gitFiles(root: root, limit: limit + 1) {
                files = f
            } else {
                files = FileFinder.walk(root: root, limit: limit + 1)
            }
        case .sapling?:
            if let s = saplingFiles(in: root, limit: limit + 1) {
                files = s.paths
            } else {
                files = FileFinder.walk(root: root, limit: limit + 1)
            }
        case nil:
            files = FileFinder.walk(root: root, limit: limit + 1)
        }
        complete = files.count <= limit
        if !complete { files.removeLast(files.count - limit) }
        return (entries(root: root, files: files), complete)
    }

    /// Files and the folders they imply, each looked at once.
    static func entries(root: String, files: [String]) -> [DirectoryEntry] {
        var folders = Set<String>()
        for f in files {
            var dir = f.deletingLastPathComponent
            while !dir.isEmpty, dir != ".", folders.insert(dir).inserted { dir = dir.deletingLastPathComponent }
        }
        let fm = FileManager.default
        func entry(_ rel: String, folder: Bool) -> DirectoryEntry? {
            guard let a = try? fm.attributesOfItem(atPath: root.appendingPathComponent(rel)) else { return nil }
            let name = rel.lastPathComponent
            return DirectoryEntry(name: rel, isDirectory: folder || (a[.type] as? FileAttributeType) == .typeDirectory,
                                  size: (a[.size] as? Int64) ?? 0, modified: (a[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0,
                                  isHidden: name.hasPrefix("."))
        }
        return folders.sorted().compactMap { entry($0, folder: true) } + files.compactMap { entry($0, folder: false) }
    }
}
