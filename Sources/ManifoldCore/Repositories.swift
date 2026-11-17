import Foundation

/// Repositories too large to list: a monorepo's millions of files, on a
/// virtual file system that fetches only what's looked at (EdenFS), where
/// anything that reads the whole of it — every file listed, every file
/// looked at — takes minutes and many gigabytes, and runs on long after
/// whatever asked has gone. In those, nothing is asked of the whole: what's
/// shown is asked about, and what can't be had otherwise isn't offered.
public enum Repositories {
    /// The size of a repository's own record of its files past which it's
    /// taken to be large: git's index and Sapling's tree state run to about
    /// a hundred bytes a file, so some quarter of a million files.
    static let largeState: Int64 = 25 << 20

    /// Whether the repository at `root` is large: on a virtual file system,
    /// its record of its files that big, or found so (a listing of it that
    /// ran out of time) in the last half hour. Kept a minute.
    public static func isLarge(_ root: String) -> Bool {
        lock.lock()
        if let m = marked[root], Date().timeIntervalSince(m) < 1800 { lock.unlock(); return true }
        if let k = known[root], Date().timeIntervalSince(k.at) < 60 { lock.unlock(); return k.large }
        lock.unlock()
        let large = isVirtual(root) || stateSize(root) > largeState
        lock.lock()
        known[root] = (Date(), large)
        lock.unlock()
        return large
    }

    /// Whether the repository's working copy is a virtual file system's
    /// (EdenFS, which puts a `.eden` in each folder it serves): one whose
    /// status comes from its journal, not from looking at every file.
    public static func isVirtual(_ root: String) -> Bool {
        FileManager.default.fileExists(atPath: root.appendingPathComponent(".eden"))
    }

    /// A listing of it ran out of time: large, for a while.
    public static func markLarge(_ root: String) {
        lock.lock()
        marked[root] = Date()
        lock.unlock()
    }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var known: [String: (at: Date, large: Bool)] = [:]
    nonisolated(unsafe) private static var marked: [String: Date] = [:]

    /// The biggest of git's index or Sapling's tree state files.
    private static func stateSize(_ root: String) -> Int64 {
        let fm = FileManager.default
        func size(_ p: String) -> Int64 { ((try? fm.attributesOfItem(atPath: p))?[.size] as? NSNumber)?.int64Value ?? 0 }
        var biggest = size(root + "/.git/index")
        for dir in [root + "/.sl/treestate", root + "/.hg/treestate"] {
            for name in (try? fm.contentsOfDirectory(atPath: dir)) ?? [] { biggest = max(biggest, size(dir + "/" + name)) }
        }
        for f in [root + "/.sl/dirstate", root + "/.hg/dirstate"] { biggest = max(biggest, size(f)) }
        return biggest
    }
}

/// Listings of a repository asked of its version control, each by itself:
/// the same one asked for again while it runs waits for it rather than
/// running again (a folder shown, the finder and a search, each asking at
/// once, ran three); no more than two at a time, the rest waiting; one
/// that runs out of time marks its repository large.
enum Scans {
    private final class Flight: @unchecked Sendable {
        let done = DispatchSemaphore(value: 0)
        var result: Data?
        var waiters = 0
    }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var flying: [String: Flight] = [:]
    private static let slots = DispatchSemaphore(value: 2)

    /// The output of `argv`, ended once it has said `records` NUL-ended
    /// records (`.max`: all it says); nil if it failed or ran out of
    /// `timeout`.
    static func run(_ argv: [String], records: Int, root: String, timeout: TimeInterval = 30) -> Data? {
        let key = argv.joined(separator: "\u{0}") + "\u{0}\(records)"
        lock.lock()
        if let f = flying[key] {
            f.waiters += 1
            lock.unlock()
            f.done.wait()
            f.done.signal()
            return f.result
        }
        let f = Flight()
        flying[key] = f
        lock.unlock()
        slots.wait()
        let started = Date()
        let r = try? Child.run(argv, timeout: timeout, quiet: true, records: records == .max ? nil : records)
        slots.signal()
        // Ended for having said enough, or done: its output. Else nothing —
        // and, out of time, the repository's large.
        if let r {
            let said = r.output.reduce(0) { $1 == 0 ? $0 + 1 : $0 }
            if r.status == 0 || said >= records {
                f.result = r.output
            } else if Date().timeIntervalSince(started) >= timeout - 0.5 {
                Repositories.markLarge(root)
            }
        }
        lock.lock()
        flying[key] = nil
        lock.unlock()
        f.done.signal()
        return f.result
    }
}
