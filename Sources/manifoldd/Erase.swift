import Foundation
import ManifoldCore

/// A host's session deleted for good (issue #1): every file Manifold keeps
/// on the host for it — its data folder (logs, snapshots, transcripts,
/// indexes, the images kept for notes, its id) and the server a client
/// installed there. Files of the user's own (opened, saved, in their
/// folders) aren't the session's, and stay.
enum SessionFiles {
    /// What's in the data folder that isn't the session's: on a Mac, the
    /// app keeps its list of other hosts there too.
    static let notTheSession: Set<String> = [Paths.hosts.lastPathComponent]

    /// Removes them; what couldn't be, said.
    @discardableResult
    static func erase() -> [String] {
        let fm = FileManager.default
        var failed: [String] = []
        func remove(_ url: URL) {
            guard fm.fileExists(atPath: url.path) else { return }
            do { try fm.removeItem(at: url) } catch { failed.append("\(url.path): \(error.localizedDescription)") }
        }
        let dir = Paths.directory
        for name in (try? fm.contentsOfDirectory(atPath: dir.path)) ?? [] where !notTheSession.contains(name) {
            remove(dir.appendingPathComponent(name))
        }
        // The server installed here, and its folders, if that leaves them
        // empty — the default session's (one kept elsewhere, MANIFOLD_DIR's,
        // a test's, isn't what it was installed for).
        let elsewhere = ProcessInfo.processInfo.environment["MANIFOLD_DIR"].map { !$0.isEmpty } ?? false
        var folders = [dir]
        if !elsewhere {
            remove(Paths.installedServer)
            let bin = Paths.installedServer.deletingLastPathComponent()
            folders = [bin, bin.deletingLastPathComponent(), dir]
        }
        for folder in folders where ((try? fm.contentsOfDirectory(atPath: folder.path)) ?? ["?"]).isEmpty {
            remove(folder)
        }
        return failed
    }

    /// What the session is called, and where its files are, for asking.
    static var describe: String {
        let id = (try? String(contentsOf: Paths.session, encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "none"
        let label = (try? String(contentsOf: Paths.label, encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines)
        return "session \(id)\(label.map { " (\($0))" } ?? "") in \(Paths.directory.path)"
    }
}
