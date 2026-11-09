import AppKit
import ManifoldCore

/// Another host's files opened with an app on this Mac (§8): each fetched
/// to a copy of its own here, the copy watched, and sent back to the host
/// whenever it's saved — a moment after the writing stops.
final class LocalCopies {
    static let shared = LocalCopies()

    private struct Copy {
        let url: URL
        let path: String
        weak var client: HostClient?
        let label: String
        /// When it was last sent back (or fetched).
        var modified: Date?
        var sending = false
        var watcher: FileWatcher?
    }

    private var copies: [URL: Copy] = [:]
    /// A copy's send put off while it's still being written, and tried
    /// again a while after one didn't go.
    private let settle = KeyedDebouncer<URL>()
    /// Sent back (or not): the file's name, the host's, and why not.
    var onSentBack: ((String, String, String?) -> Void)?

    private var folder: URL {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
        return caches.appendingPathComponent("Manifold/Opened", isDirectory: true)
    }

    /// The file fetched afresh (over an earlier copy of it), then watched.
    func open(_ path: String, on c: HostClient, label: String, done: @escaping (URL?, String?) -> Void) {
        // A folder of its own per host and place, so two files of one name don't meet.
        let place = (c.host.raw + path.deletingLastPathComponent).data(using: .utf8)!.base64EncodedString()
            .replacingOccurrences(of: "/", with: "_").suffix(60)
        let dir = folder.appendingPathComponent(String(place), isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent(path.lastPathComponent)
        // An earlier copy let go first: what's fetched over it isn't sent back.
        copies.removeValue(forKey: url)
        settle.cancel(url)
        Transfers.shared.run(path.lastPathComponent, detail: "from \(label), to open here", symbol: "arrow.down") { progress, finished in
            Transfer.download(path, on: c, to: url, progress: progress, done: finished)
        } then: { [weak self] error in
            guard let self, error == nil else { return done(nil, error) }
            self.copies[url] = Copy(url: url, path: path, client: c, label: label, modified: Self.modified(url))
            self.copies[url]?.watcher = FileWatcher(path: url.path) { [weak self] in self?.changed(url) }
            done(url, nil)
        }
    }

    private static func modified(_ url: URL) -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date
    }

    /// A copy written to: sent back once the writing stops a moment.
    private func changed(_ url: URL) {
        settle.schedule(url, after: 1) { [weak self] in self?.sendBack(url) }
    }

    /// The copy, saved since it was last sent, goes back to its host; one
    /// that didn't go is tried again in a while; one deleted, or whose
    /// host has gone, is let go.
    private func sendBack(_ url: URL) {
        guard let copy = copies[url], !copy.sending else { return }
        guard FileManager.default.fileExists(atPath: url.path) else {
            copies.removeValue(forKey: url)
            return
        }
        guard let m = Self.modified(url), m != copy.modified else { return }
        guard let c = copy.client else {
            copies.removeValue(forKey: url)
            onSentBack?(url.lastPathComponent, copy.label, "\(copy.label) isn't connected any more")
            return
        }
        copies[url]?.sending = true
        Transfers.shared.run(url.lastPathComponent, detail: "saved, back to \(copy.label)", symbol: "arrow.up") { progress, finished in
            Transfer.upload(url, to: copy.path, on: c, replace: true, progress: progress, done: finished)
        } then: { [weak self] error in
            guard let self else { return }
            self.copies[url]?.sending = false
            if error == nil { self.copies[url]?.modified = m }
            self.onSentBack?(url.lastPathComponent, copy.label, error)
            // Written again while it went, or it didn't go: again.
            self.settle.schedule(url, after: error == nil ? 0 : 10) { [weak self] in self?.sendBack(url) }
        }
    }
}
