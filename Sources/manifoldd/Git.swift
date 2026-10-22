import Foundation
import ManifoldCore

/// Version control on this host, git or Sapling, for git and diff blocks
/// and the editor's gutter (DESIGN.md §7.5): commands run off the
/// server's queue, answered on it.
final class Git {
    private let queue: DispatchQueue
    private let work = DispatchQueue(label: "manifold.git", qos: .userInitiated)
    private var repos: [String: (root: String, vcs: VCS)?] = [:]

    init(queue: DispatchQueue) {
        self.queue = queue
    }

    /// The repository a path is in, if any (cached by directory).
    func repository(of path: String) -> (root: String, vcs: VCS)? {
        var isDir: ObjCBool = false
        FileManager.default.fileExists(atPath: path, isDirectory: &isDir)
        let dir = isDir.boolValue ? path : path.deletingLastPathComponent
        if let known = repos[dir] { return known }
        let found = VCS.repository(of: dir)
        repos[dir] = found
        return found
    }

    func root(of path: String) -> String? { repository(of: path)?.root }

    /// Runs the repository's command in a directory; the output, or the
    /// error, on the server's queue.
    func run(_ vcs: VCS, _ args: [String], in dir: String, done: @escaping (Result<String, GitError>) -> Void) {
        work.async {
            let result: Result<String, GitError>
            do {
                let argv = vcs == .git ? ["git", "-C", dir] + args : ["sl", "--cwd", dir] + args
                let (out, status) = try Child.run(argv, timeout: 60, quiet: true)
                if status == 0 {
                    result = .success(String(decoding: out, as: UTF8.self))
                } else {
                    result = .failure(GitError("\(vcs.command) \(args.first { !$0.hasPrefix("-") } ?? "") failed (\(status))"))
                }
            } catch {
                result = .failure(GitError("couldn't run \(vcs.command): \(error)"))
            }
            self.queue.async { done(result) }
        }
    }

    /// Several commands, together.
    func run(_ vcs: VCS, _ commands: [[String]], in dir: String, done: @escaping ([Result<String, GitError>]) -> Void) {
        var results = [Result<String, GitError>?](repeating: nil, count: commands.count)
        var left = commands.count
        guard left > 0 else { return done([]) }
        for (i, args) in commands.enumerated() {
            run(vcs, args, in: dir) { r in
                results[i] = r
                left -= 1
                if left == 0 { done(results.map { $0! }) }
            }
        }
    }

    /// The whole working tree of a git repository as a tree object —
    /// tracked files as they are, untracked ones that aren't ignored —
    /// written through an index of its own (a copy of the real one, so
    /// only what changed is read), the real index and the files untouched.
    func snapshotTree(_ root: String, done: @escaping (String?) -> Void) {
        work.async {
            let tmp = NSTemporaryDirectory() + "manifold-index-\(UUID().uuidString)"
            defer { try? FileManager.default.removeItem(atPath: tmp) }
            if let (out, status) = try? Child.run(["git", "-C", root, "rev-parse", "--git-path", "index"], timeout: 20, quiet: true), status == 0 {
                var index = String(decoding: out, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
                if !index.hasPrefix("/") { index = root + "/" + index }
                try? FileManager.default.copyItem(atPath: index, toPath: tmp)
            }
            let git = ["env", "GIT_INDEX_FILE=\(tmp)", "git", "-C", root]
            var tree: String?
            if let (_, added) = try? Child.run(git + ["add", "-A"], timeout: 300, quiet: true), added == 0,
               let (out, status) = try? Child.run(git + ["write-tree"], timeout: 60, quiet: true), status == 0 {
                tree = String(decoding: out, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            }
            self.queue.async { done(tree) }
        }
    }

    /// A file as a revision has it (`HEAD`: the committed version, in
    /// either system); nil if the revision doesn't have it.
    func show(_ path: String, at revision: String, done: @escaping (String?) -> Void) {
        guard let (root, vcs) = repository(of: path) else { return done(nil) }
        let rel = path.hasPrefix(root + "/") ? String(path.dropFirst(root.count + 1)) : path
        run(vcs, vcs.catArguments(path: rel, revision: revision), in: root) { result in
            if case .success(let text) = result { done(text) } else { done(nil) }
        }
    }
}

struct GitError: Error {
    let message: String
    init(_ message: String) { self.message = message }
}
