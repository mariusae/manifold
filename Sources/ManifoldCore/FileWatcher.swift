import Foundation

/// Files' modification times, sizes and inodes, as last looked at: what
/// tells a change from a touch — a read, or `git status` writing the index
/// back as it was, which a watch hears as a change all the same.
public final class FileStamps {
    private let paths: [String]
    private var last: [Stamp?]
    private struct Stamp: Equatable { var modified: Double, size: Double, inode: Double }

    public init(_ paths: [String]) {
        self.paths = paths
        last = []
        last = now()
    }

    private func now() -> [Stamp?] {
        paths.map { p in
            guard let a = try? FileManager.default.attributesOfItem(atPath: p) else { return nil }
            return Stamp(modified: (a[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0, size: (a[.size] as? NSNumber)?.doubleValue ?? 0,
                         inode: (a[.systemFileNumber] as? NSNumber)?.doubleValue ?? 0)
        }
    }

    /// Whether any moved since the last look (or since they were first
    /// looked at).
    public func moved() -> Bool {
        let now = now()
        guard now != last else { return false }
        last = now
        return true
    }
}

/// Watches a file, calling back when it changes. Editors often save by
/// writing a new file and renaming it over the old one, so on a rename or
/// delete the path is watched afresh; one that isn't there is waited for
/// by watching the nearest folder up that is, until it comes (§ M4). The
/// file system says so — a Mac's vnode events, Linux's inotify (a folder
/// watched itself, a file through its folder) — nothing looked at again
/// and again.
public final class FileWatcher {
    private let path: String
    private let queue: DispatchQueue
    private let onChange: () -> Void
    #if canImport(Darwin)
    private var source: DispatchSourceFileSystemObject?
    /// While it isn't there: the folder up it would come in.
    private var waiting: DispatchSourceFileSystemObject?
    #else
    private var token: Inotify.Token?
    #endif
    private var pending: DispatchWorkItem?

    /// `ignoringTouches`: called back only when one of those files has
    /// moved (`FileStamps`), not for every event the watch hears.
    public init(path: String, queue: DispatchQueue = .main, ignoringTouches stamps: FileStamps? = nil, onChange: @escaping () -> Void) {
        self.path = path
        self.queue = queue
        self.onChange = stamps.map { stamps in { if stamps.moved() { onChange() } } } ?? onChange
        start(missing: false)
    }

    deinit {
        #if canImport(Darwin)
        source?.cancel()
        waiting?.cancel()
        #else
        if let token { Inotify.shared.unwatch(token) }
        #endif
    }

    /// The nearest folder up from the path that's there.
    private var nearestThere: String {
        var dir = path.deletingLastPathComponent
        while dir.count > 1, !FileManager.default.fileExists(atPath: dir) { dir = dir.deletingLastPathComponent }
        return dir.isEmpty ? "/" : dir
    }

    #if canImport(Darwin)
    private func start(missing: Bool) {
        source?.cancel()
        source = nil
        waiting?.cancel()
        waiting = nil
        let fd = open(path, O_EVTONLY)
        guard fd >= 0 else { return wait() }
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd, eventMask: [.write, .extend, .delete, .rename, .attrib, .link], queue: queue)
        source.setEventHandler { [weak self, weak source] in
            guard let self, let source else { return }
            if !source.data.isDisjoint(with: [.delete, .rename]) {
                self.start(missing: true)
            }
            self.changed()
        }
        source.setCancelHandler { close(fd) }
        source.resume()
        self.source = source
        if missing { changed() }
    }

    /// Not there (perhaps mid-save): the folder it would come in watched
    /// — or the nearest one up that's there — and looked for again when
    /// that changes.
    private func wait() {
        let dir = nearestThere
        let fd = open(dir, O_EVTONLY)
        guard fd >= 0 else { return }
        let w = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: [.write, .link, .rename, .delete], queue: queue)
        w.setEventHandler { [weak self] in self?.start(missing: true) }
        w.setCancelHandler { close(fd) }
        w.resume()
        waiting = w
        // Come while the watch was being set.
        if FileManager.default.fileExists(atPath: path) || nearestThere != dir { start(missing: true) }
    }
    #else
    private func start(missing: Bool) {
        if let token { Inotify.shared.unwatch(token) }
        token = nil
        let fm = FileManager.default
        let name = path.lastPathComponent
        if fm.isDirectory(atPath: path) == true {
            // A folder: what's in it, watched in it.
            token = Inotify.shared.watch(path) { [weak self] _, mask in
                self?.queue.async {
                    guard let self else { return }
                    if mask & (Inotify.ignored | Inotify.deleteSelf | Inotify.moveSelf) != 0 { self.start(missing: true) }
                    self.changed()
                }
            }
        } else if fm.fileExists(atPath: path.deletingLastPathComponent) {
            // A file (or none yet): its folder's events for its name.
            let dir = path.deletingLastPathComponent
            token = Inotify.shared.watch(dir) { [weak self] entry, mask in
                self?.queue.async {
                    guard let self else { return }
                    if mask & (Inotify.ignored | Inotify.deleteSelf | Inotify.moveSelf) != 0 { return self.start(missing: true) }
                    guard entry == name else { return }
                    // Made a folder where the file was: watched as one.
                    if mask & (Inotify.create | Inotify.movedTo) != 0, fm.isDirectory(atPath: self.path) == true { self.start(missing: true) }
                    self.changed()
                }
            }
        } else {
            // Its folder isn't there: the nearest up that is, until it comes.
            let dir = nearestThere
            token = Inotify.shared.watch(dir) { [weak self] _, _ in
                self?.queue.async { self?.start(missing: true) }
            }
            if nearestThere != dir { return start(missing: true) }
        }
        if missing, fm.fileExists(atPath: path) { changed() }
    }
    #endif

    private func changed() {
        pending?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.onChange() }
        pending = work
        queue.asyncAfter(deadline: .now() + 0.05, execute: work)
    }
}

/// Reading and writing text files as the host does it: the encoding and
/// line endings kept, and a fingerprint to tell our own writes from others'.
public enum TextFile {
    public struct Contents {
        public var text: String
        public var encoding: String
        public var lineEnding: String
        public var fingerprint: String
    }

    /// Whether a file looks like text: no NULs near its start.
    public static func isText(_ path: String) -> Bool {
        guard let handle = FileHandle(forReadingAtPath: path) else { return false }
        defer { try? handle.close() }
        let head = (try? handle.read(upToCount: 8192)) ?? Data()
        return !head.contains(0)
    }

    public static func read(_ path: String) -> Contents? {
        guard let data = FileManager.default.contents(atPath: path) else { return nil }
        let encoding: String
        let raw: String
        if let s = String(data: data, encoding: .utf8) {
            (raw, encoding) = (s, "utf-8")
        } else if let s = String(data: data, encoding: .isoLatin1) {
            (raw, encoding) = (s, "iso-8859-1")
        } else {
            return nil
        }
        let crlf = raw.contains("\r\n")
        return Contents(text: crlf ? raw.replacingOccurrences(of: "\r\n", with: "\n") : raw,
                        encoding: encoding, lineEnding: crlf ? "\r\n" : "\n", fingerprint: Fingerprint.of(data))
    }

    public static func fingerprint(_ path: String) -> String? {
        FileManager.default.contents(atPath: path).map { Fingerprint.of($0) }
    }

    /// Writes, keeping the file's permissions; returns the fingerprint.
    public static func write(_ text: String, to path: String, encoding: String, lineEnding: String) throws -> String {
        let data = try encoded(text, encoding: encoding, lineEnding: lineEnding)
        try write(data, to: path)
        return Fingerprint.of(data)
    }

    /// The bytes a text is written as.
    public static func encoded(_ text: String, encoding: String, lineEnding: String) throws -> Data {
        var out = text
        if lineEnding != "\n" { out = out.replacingOccurrences(of: "\n", with: lineEnding) }
        let enc: String.Encoding = encoding == "iso-8859-1" ? .isoLatin1 : .utf8
        guard let data = out.data(using: enc) ?? out.data(using: .utf8) else {
            throw CocoaError(.fileWriteInapplicableStringEncoding)
        }
        return data
    }

    /// Bytes written over a file, atomically, keeping its permissions.
    public static func write(_ data: Data, to path: String) throws {
        let permissions = (try? FileManager.default.attributesOfItem(atPath: path))?[.posixPermissions]
        try data.write(to: URL(fileURLWithPath: path), options: .atomic)
        if let permissions {
            try? FileManager.default.setAttributes([.posixPermissions: permissions], ofItemAtPath: path)
        }
    }

    /// A folder's entries, as a directory block lists them.
    public static func list(_ path: String) -> [DirectoryEntry]? {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: path) else { return nil }
        var out: [DirectoryEntry] = []
        for name in names {
            let full = path.appendingPathComponent(name)
            guard let attrs = try? FileManager.default.attributesOfItem(atPath: full) else { continue }
            let isDir = (attrs[.type] as? FileAttributeType) == .typeDirectory
            let size = (attrs[.size] as? Int64) ?? 0
            let modified = (attrs[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
            out.append(DirectoryEntry(name: name, isDirectory: isDir, size: size, modified: modified, isHidden: name.hasPrefix(".")))
        }
        return out.sorted { a, b in
            if a.isDirectory != b.isDirectory { return a.isDirectory }
            return a.name.standardCompare(b.name)
        }
    }
}
