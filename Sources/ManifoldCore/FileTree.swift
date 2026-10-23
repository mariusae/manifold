import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#endif

/// What's said on a tree stream (§8), either way: the sender's total,
/// each item and (for a file) its bytes in `data` frames after it, then
/// `done`; the receiver's (or the copying host's) `progress` and last
/// word, `end`.
public enum TreeMessage: Codable, Sendable {
    case total(Int64)
    case entry(TreeEntry)
    case done
    case progress(done: Int64, total: Int64)
    case end(error: String?, path: String?)
}

/// A file or folder sent from disk down a stream (§8): walked, each item
/// said and each file read a piece at a time while the stream wants more,
/// all on a queue of its own — no caller's thread waits on the disk.
public final class TreeSource {
    private let stream: MuxStream
    private let root: String
    private let io = DispatchQueue(label: "manifold.tree-source", qos: .utility)
    /// On `io`: what's left to say, the file being read, and where.
    private var entries: [TreeEntry] = []
    private var index = 0
    private var handle: FileHandle?
    private var left: Int64 = 0
    private var started = false
    private var finished = false
    private var sent: Int64 = 0
    private var total: Int64 = 0
    /// Told the bytes sent so far, and of how many (on `io`).
    public var onProgress: ((Int64, Int64) -> Void)?
    /// Told it couldn't be read, or nil once all of it has gone (on `io`).
    public var onFinished: ((String?) -> Void)?

    public init(_ stream: MuxStream, root: String) {
        self.stream = stream
        self.root = root
    }

    /// Begins; goes on as the stream wants more (its `onDrain`, which this
    /// takes).
    public func start() {
        stream.onDrain = { [weak self] in self?.io.async { self?.pump() } }
        io.async { self.pump() }
    }

    /// Stops reading (the stream is the caller's to close).
    public func cancel() {
        io.async { [self] in
            finished = true
            try? handle?.close()
            handle = nil
        }
    }

    private func pump() {
        guard !finished else { return }
        if !started {
            started = true
            guard let walked = TreeEntry.walk(root) else { return fail("couldn't read \(root)") }
            entries = walked
            total = TreeEntry.total(walked)
            stream.send(.message(TreeMessage.total(total)))
            onProgress?(0, total)
        }
        while !finished, stream.wantsMore {
            if let h = handle {
                let piece: Data
                do { piece = try h.read(upToCount: Int(min(Int64(stream.piece), left))) ?? Data() } catch { return fail(error.localizedDescription) }
                // Shorter than it was: the file changed under us.
                guard !piece.isEmpty || left == 0 else { return fail("\((root + "/" + entries[index - 1].path).lastPathComponent) changed while it was copied") }
                stream.send(Frame(.data, piece))
                left -= Int64(piece.count)
                sent += Int64(piece.count)
                onProgress?(sent, total)
                if left == 0 {
                    try? h.close()
                    handle = nil
                }
                continue
            }
            guard index < entries.count else {
                finished = true
                stream.send(.message(TreeMessage.done))
                onFinished?(nil)
                return
            }
            let e = entries[index]
            index += 1
            if e.kind == .file, e.size > 0 {
                let full = e.path.isEmpty ? root : root + "/" + e.path
                guard let h = FileHandle(forReadingAtPath: full) else { return fail("couldn't read \(full)") }
                handle = h
                left = e.size
            }
            stream.send(.message(TreeMessage.entry(e)))
        }
    }

    private func fail(_ why: String) {
        finished = true
        try? handle?.close()
        handle = nil
        stream.send(.message(TreeMessage.end(error: why, path: nil)))
        onFinished?(why)
    }
}

/// A file or folder received from a stream onto disk (§8): written
/// beside where it goes (a hidden name of its own) as it comes, each piece
/// credited once it's written — a slow disk slows only the sender — and
/// moved into place when `done` comes, over what's there if `replace`;
/// cut short, what was written is taken away. All on a queue of its own.
public final class TreeSink {
    private let stream: MuxStream
    private let destination: String
    private let replace: Bool
    private let io = DispatchQueue(label: "manifold.tree-sink", qos: .utility)
    /// On `io`.
    private let temporary: String
    private var handle: FileHandle?
    private var current: TreeEntry?
    private var left: Int64 = 0
    private var directories: [TreeEntry] = []
    private var written: Int64 = 0
    private var total: Int64 = 0
    private var ended = false
    /// Told the bytes written so far, and of how many (on `io`).
    public var onProgress: ((Int64, Int64) -> Void)?
    /// Told why it failed, or nil and the path it's at (on `io`).
    public var onFinished: ((String?, String?) -> Void)?

    public init(_ stream: MuxStream, destination: String, replace: Bool) {
        self.stream = stream
        self.destination = destination
        self.replace = replace
        let url = URL(fileURLWithPath: destination)
        temporary = url.deletingLastPathComponent().appendingPathComponent(".\(url.lastPathComponent).manifold-\(UInt32.random(in: 0...UInt32.max))").path
        stream.manualCredit = true
    }

    /// Whether it's there already and mustn't be written over: refused at
    /// once (`end`), not after all of it has come.
    public func refusedAtOnce() -> Bool {
        guard !replace, FileManager.default.fileExists(atPath: destination) else { return false }
        ended = true
        return true
    }

    /// A frame of the stream's (from whatever thread it comes on).
    public func received(_ frame: Frame) {
        io.async { [self] in take(frame) }
    }

    /// The stream closed before `done`: what was written taken away, and
    /// why it stopped said.
    public func cut(_ why: String = "the link went") {
        io.async { [self] in
            guard !ended else { return }
            ended = true
            try? handle?.close()
            handle = nil
            Self.remove(temporary)
            report(why, nil)
        }
    }

    private func take(_ frame: Frame) {
        guard !ended else { return }
        defer { stream.consumed(frame.payload.count + 5) }
        if frame.kind == .data {
            guard left > 0, let handle else { return fail("bytes came for no file") }
            do { try handle.write(contentsOf: frame.payload) } catch { return fail(error.localizedDescription) }
            left -= Int64(frame.payload.count)
            written += Int64(frame.payload.count)
            onProgress?(written, total)
            if left <= 0 { closeFile() }
            return
        }
        guard let m = frame.decode(TreeMessage.self) else { return }
        switch m {
        case let .total(t):
            total = t
            onProgress?(0, t)
        case let .entry(e):
            guard left == 0, e.isSafe else { return fail(left > 0 ? "a file ended early" : "a path out of the folder: \(e.path)") }
            let full = e.path.isEmpty ? temporary : temporary + "/" + e.path
            let fm = FileManager.default
            switch e.kind {
            case .directory:
                do { try fm.createDirectory(atPath: full, withIntermediateDirectories: true) } catch { return fail(error.localizedDescription) }
                directories.append(e)
            case .symlink:
                do { try fm.createSymbolicLink(atPath: full, withDestinationPath: e.target ?? "") } catch { return fail(error.localizedDescription) }
            case .file:
                if e.path.isEmpty { try? fm.createDirectory(atPath: (temporary as NSString).deletingLastPathComponent, withIntermediateDirectories: true) }
                guard fm.createFile(atPath: full, contents: nil), let h = FileHandle(forWritingAtPath: full) else { return fail("couldn't write \(full)") }
                handle = h
                current = e
                left = e.size
                if left == 0 { closeFile() }
            }
        case .done:
            guard left == 0 else { return fail("a file ended early") }
            finish()
        case let .end(error, _):
            // The sender couldn't go on.
            fail(error ?? "the sender stopped")
        case .progress:
            break
        }
    }

    /// The file just written: its permissions and time as they were.
    private func closeFile() {
        try? handle?.close()
        handle = nil
        guard let e = current else { return }
        current = nil
        Self.stamp(e.path.isEmpty ? temporary : temporary + "/" + e.path, e)
    }

    private func finish() {
        ended = true
        // Folders' times last (writing in them changed them), deepest first.
        for d in directories.reversed() { Self.stamp(d.path.isEmpty ? temporary : temporary + "/" + d.path, d) }
        if FileManager.default.fileExists(atPath: destination) {
            guard replace else {
                Self.remove(temporary)
                return report("exists", nil)
            }
            Self.clearFor(temporary, destination)
        }
        guard rename(temporary, destination) == 0 else {
            let why = String(cString: strerror(errno))
            Self.remove(temporary)
            return report(why, nil)
        }
        report(nil, destination)
    }

    private func fail(_ why: String) {
        ended = true
        try? handle?.close()
        handle = nil
        Self.remove(temporary)
        report(why, nil)
    }

    private func report(_ error: String?, _ path: String?) {
        onFinished?(error, path)
    }

    static func stamp(_ path: String, _ e: TreeEntry) {
        try? FileManager.default.setAttributes([.posixPermissions: NSNumber(value: e.mode), .modificationDate: Date(timeIntervalSince1970: e.modified)], ofItemAtPath: path)
    }

    static func remove(_ path: String) {
        try? FileManager.default.removeItem(atPath: path)
    }

    /// Before `from` is moved to `to` over what's there: a file is replaced
    /// by the move itself, at once (an editor watching it sees no gap); a
    /// folder, or a file where a folder was, has to go first.
    static func clearFor(_ from: String, _ to: String) {
        var isDir: ObjCBool = false, wasDir: ObjCBool = false
        FileManager.default.fileExists(atPath: from, isDirectory: &isDir)
        FileManager.default.fileExists(atPath: to, isDirectory: &wasDir)
        if isDir.boolValue || wasDir.boolValue { remove(to) }
    }
}

/// A file or folder copied within one disk's host (§8), from `from` to
/// `to`: written beside `to` and moved into place at the end, as a sink
/// does, its progress said as it goes; on a queue of its own.
public final class TreeCopier {
    private let from: String, to: String, replace: Bool
    private let io = DispatchQueue(label: "manifold.tree-copy", qos: .utility)
    private let lock = NSLock()
    private var cancelled = false
    public var onProgress: ((Int64, Int64) -> Void)?
    public var onFinished: ((String?, String?) -> Void)?

    public init(from: String, to: String, replace: Bool) {
        self.from = from
        self.to = to
        self.replace = replace
    }

    public func cancel() { lock.withLock { cancelled = true } }

    public func start() {
        io.async { [self] in
            let (error, path) = copy()
            onFinished?(error, path)
        }
    }

    private func copy() -> (String?, String?) {
        let fm = FileManager.default
        if !replace, fm.fileExists(atPath: to) { return ("exists", nil) }
        guard let entries = TreeEntry.walk(from) else { return ("couldn't read \(from)", nil) }
        let total = TreeEntry.total(entries)
        let url = URL(fileURLWithPath: to)
        let temporary = url.deletingLastPathComponent().appendingPathComponent(".\(url.lastPathComponent).manifold-\(UInt32.random(in: 0...UInt32.max))").path
        var done: Int64 = 0
        var said = Date.distantPast
        onProgress?(0, total)
        func fail(_ why: String) -> (String?, String?) {
            TreeSink.remove(temporary)
            return (why, nil)
        }
        var buffer = [UInt8](repeating: 0, count: 1 << 20)
        for e in entries {
            if lock.withLock({ cancelled }) { return fail("cancelled") }
            let src = e.path.isEmpty ? from : from + "/" + e.path
            let dst = e.path.isEmpty ? temporary : temporary + "/" + e.path
            switch e.kind {
            case .directory:
                do { try fm.createDirectory(atPath: dst, withIntermediateDirectories: true) } catch { return fail(error.localizedDescription) }
            case .symlink:
                do { try fm.createSymbolicLink(atPath: dst, withDestinationPath: e.target ?? "") } catch { return fail(error.localizedDescription) }
            case .file:
                let input = open(src, O_RDONLY), output = open(dst, O_WRONLY | O_CREAT | O_TRUNC, 0o600)
                defer {
                    if input >= 0 { close(input) }
                    if output >= 0 { close(output) }
                }
                guard input >= 0, output >= 0 else { return fail("couldn't copy \(src)") }
                while true {
                    if lock.withLock({ cancelled }) { return fail("cancelled") }
                    let n = buffer.withUnsafeMutableBytes { read(input, $0.baseAddress, $0.count) }
                    if n == 0 { break }
                    guard n > 0 else { return fail(String(cString: strerror(errno))) }
                    var off = 0
                    while off < n {
                        let w = buffer.withUnsafeBytes { write(output, $0.baseAddress! + off, n - off) }
                        guard w > 0 else { return fail(String(cString: strerror(errno))) }
                        off += w
                    }
                    done += Int64(n)
                    if Date().timeIntervalSince(said) > 0.1 {
                        said = Date()
                        onProgress?(done, total)
                    }
                }
                TreeSink.stamp(dst, e)
            }
        }
        for d in entries.reversed() where d.kind == .directory {
            TreeSink.stamp(d.path.isEmpty ? temporary : temporary + "/" + d.path, d)
        }
        onProgress?(done, total)
        if fm.fileExists(atPath: to) {
            guard replace else { return fail("exists") }
            TreeSink.clearFor(temporary, to)
        }
        guard rename(temporary, to) == 0 else { return fail(String(cString: strerror(errno))) }
        return (nil, to)
    }
}
