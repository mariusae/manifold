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
        var modified: Date?
        var sending = false
    }

    private var copies: [URL: Copy] = [:]
    private var timer: Timer?
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
        Transfers.shared.run(path.lastPathComponent, detail: "from \(label), to open here", symbol: "arrow.down") { progress, finished in
            Transfer.download(path, on: c, to: url, progress: progress, done: finished)
        } then: { [weak self] error in
            guard let self, error == nil else { return done(nil, error) }
            self.copies[url] = Copy(url: url, path: path, client: c, label: label, modified: Self.modified(url))
            self.watch()
            done(url, nil)
        }
    }

    private static func modified(_ url: URL) -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date
    }

    private func watch() {
        guard timer == nil else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] _ in self?.check() }
    }

    /// Each copy saved since it was last sent (and not still being
    /// written: its date unchanged since the last look) goes back.
    private var seen: [URL: Date] = [:]
    private func check() {
        for (url, copy) in copies where !copy.sending {
            guard FileManager.default.fileExists(atPath: url.path) else { copies.removeValue(forKey: url); continue }
            guard let m = Self.modified(url), m != copy.modified else { continue }
            // Settled: the same date as a moment ago.
            if seen[url] != m { seen[url] = m; continue }
            guard let c = copy.client else { continue }
            copies[url]?.sending = true
            Transfers.shared.run(url.lastPathComponent, detail: "saved, back to \(copy.label)", symbol: "arrow.up") { progress, finished in
                Transfer.upload(url, to: copy.path, on: c, replace: true, progress: progress, done: finished)
            } then: { [weak self] error in
                guard let self else { return }
                self.copies[url]?.sending = false
                if error == nil { self.copies[url]?.modified = m }
                self.onSentBack?(url.lastPathComponent, copy.label, error)
            }
        }
        if copies.isEmpty { timer?.invalidate(); timer = nil }
    }
}
