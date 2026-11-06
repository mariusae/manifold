import Foundation
import ManifoldCore

extension Server {
    /// A file's history (`FileHistoryRequest`), from its repository's
    /// version control; `.untracked` for a file in none. Answered on the
    /// server's queue.
    func fileHistory(_ request: FileHistoryRequest, done: @escaping (FileHistoryResult) -> Void) {
        let file: String
        switch request {
        case let .log(path, _, _): file = path
        case let .text(f, _, _), let .blame(f, _, _): file = f
        }
        guard let (root, vcs) = git.repository(of: file) else { return done(.untracked) }
        func relative(_ p: String) -> String { p.hasPrefix(root + "/") ? String(p.dropFirst(root.count + 1)) : p }
        switch request {
        case let .log(path, skip, limit):
            let rel = relative(path)
            git.run(vcs, FileHistory.logArguments(vcs, path: rel, skip: skip, limit: limit), in: root) { result in
                switch result {
                case .success(let out):
                    let revisions = FileHistory.parseLog(vcs, out, path: rel, skip: skip)
                    done(.log(root: root, vcs: vcs, revisions: revisions, more: revisions.count >= limit))
                case .failure(let e):
                    done(.error(e.message))
                }
            }
        case let .text(_, path, revision):
            git.run(vcs, vcs.catArguments(path: path, revision: revision), in: root) { result in
                switch result {
                case .success(let text): done(.text(text))
                case .failure(let e): done(.error(e.message))
                }
            }
        case let .blame(_, path, revision):
            git.run(vcs, FileHistory.blameArguments(vcs, path: path, revision: revision), in: root) { result in
                switch result {
                case .success(let out): done(.blame(FileHistory.parseBlame(vcs, out)))
                case .failure(let e): done(.error(e.message))
                }
            }
        }
    }
}
