import Foundation

/// Watches a file, calling back when it changes. Editors often save by
/// writing a new file and renaming it over the old one, so on a rename or
/// delete the path is watched afresh. Where there are no file system
/// event sources (Linux), the file is looked at once a second.
public final class FileWatcher {
    private let path: String
    private let queue: DispatchQueue
    private let onChange: () -> Void
    #if canImport(Darwin)
    private var source: DispatchSourceFileSystemObject?
    #else
    private var timer: DispatchSourceTimer?
    private var last: (Int64, Double)?
    #endif
    private var pending: DispatchWorkItem?

    public init(path: String, queue: DispatchQueue = .main, onChange: @escaping () -> Void) {
        self.path = path
        self.queue = queue
        self.onChange = onChange
        start(retries: 0)
    }

    deinit {
        #if canImport(Darwin)
        source?.cancel()
        #else
        timer?.cancel()
        #endif
    }

    #if canImport(Darwin)
    private func start(retries: Int) {
        source?.cancel()
        source = nil
        let fd = open(path, O_EVTONLY)
        guard fd >= 0 else {
            // Gone, perhaps mid-save: look again shortly, for a while.
            if retries < 20 {
                queue.asyncAfter(deadline: .now() + 0.1) { [weak self] in
                    self?.start(retries: retries + 1)
                }
            }
            return
        }
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd, eventMask: [.write, .extend, .delete, .rename, .attrib, .link], queue: queue)
        source.setEventHandler { [weak self, weak source] in
            guard let self, let source else { return }
            if !source.data.isDisjoint(with: [.delete, .rename]) {
                self.start(retries: 0)
            }
            self.changed()
        }
        source.setCancelHandler { close(fd) }
        source.resume()
        self.source = source
        if retries > 0 { changed() }
    }
    #else
    private func stamp() -> (Int64, Double)? {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: path) else { return nil }
        let size = (attrs[.size] as? Int64) ?? 0
        let modified = (attrs[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
        return (size, modified)
    }

    private func start(retries: Int) {
        last = stamp()
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 1, repeating: 1)
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            let now = self.stamp()
            if now?.0 != self.last?.0 || now?.1 != self.last?.1 {
                self.last = now
                self.changed()
            }
        }
        timer.resume()
        self.timer = timer
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
        var out = text
        if lineEnding != "\n" { out = out.replacingOccurrences(of: "\n", with: lineEnding) }
        let enc: String.Encoding = encoding == "iso-8859-1" ? .isoLatin1 : .utf8
        guard let data = out.data(using: enc) ?? out.data(using: .utf8) else {
            throw CocoaError(.fileWriteInapplicableStringEncoding)
        }
        let url = URL(fileURLWithPath: path)
        let permissions = (try? FileManager.default.attributesOfItem(atPath: path))?[.posixPermissions]
        try data.write(to: url, options: .atomic)
        if let permissions {
            try? FileManager.default.setAttributes([.posixPermissions: permissions], ofItemAtPath: path)
        }
        return Fingerprint.of(data)
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
