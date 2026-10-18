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
