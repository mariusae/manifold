import Foundation
import ManifoldCore
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#endif

/// A file's bytes down a stream (§8): read off the server's queue a
/// piece at a time, sent while the stream wants more (it's paced), then
/// `end`. Refused (`end` with why) when it can't be read, or is bigger
/// than `limit`.
final class FileSender {
    private let stream: MuxStream
    private let queue: DispatchQueue
    private let io = DispatchQueue(label: "manifoldd.file-read")
    private let handle: FileHandle
    /// What's left to send, if it's limited.
    private var left: Int64?
    private var reading = false
    private var done = false

    static func start(_ stream: MuxStream, path: String, offset: Int64, length: Int64?, limit: Int64?, queue: DispatchQueue) {
        func refuse(_ why: String) {
            stream.send(.message(ServerMessage.end(error: why, path: nil)))
            stream.close()
        }
        let size = (try? FileManager.default.attributesOfItem(atPath: path)[.size] as? Int64) ?? nil
        guard let size, let handle = FileHandle(forReadingAtPath: path) else { return refuse("couldn't read \(path)") }
        if let limit, size > limit { return refuse("bigger than \(limit) bytes") }
        do { try handle.seek(toOffset: UInt64(max(0, offset))) } catch { return refuse(error.localizedDescription) }
        let sender = FileSender(stream: stream, handle: handle, length: length, queue: queue)
        // The stream keeps it until it closes.
        stream.onDrain = { sender.more() }
        stream.onClose = { sender.finish() }
        sender.more()
    }

    private init(stream: MuxStream, handle: FileHandle, length: Int64?, queue: DispatchQueue) {
        self.stream = stream
        self.handle = handle
        self.left = length
        self.queue = queue
    }

    /// The next piece, read off the queue, if the stream wants it.
    private func more() {
        guard !reading, !done, stream.wantsMore else { return }
        let want = min(Int64(stream.piece), left ?? Int64.max)
        guard want > 0 else { return end(nil) }
        reading = true
        io.async { [self] in
            let result = Result { try handle.read(upToCount: Int(want)) ?? Data() }
            queue.async { [self] in
                reading = false
                guard !done else { return }
                switch result {
                case .success(let data) where data.isEmpty:
                    end(nil)
                case .success(let data):
                    left = left.map { $0 - Int64(data.count) }
                    stream.send(Frame(.data, data))
                    more()
                case .failure(let error):
                    end(error.localizedDescription)
                }
            }
        }
    }

    private func end(_ error: String?) {
        guard !done else { return }
        stream.send(.message(ServerMessage.end(error: error, path: nil)))
        stream.close()
    }

    private func finish() {
        done = true
        io.async { [handle] in try? handle.close() }
    }
}

/// A file's bytes up a stream (§8): written off the server's queue as
/// they come, each piece credited once it's on disk (so a slow disk slows
/// only the sender); an empty piece ends it, answered with `end` and the
/// path written. A file being replaced is written beside it and moved
/// over it at the end, and a new one that didn't finish is taken away, so
/// a transfer cut short leaves nothing half-written in its place.
final class FileReceiver {
    private let stream: MuxStream
    private let queue: DispatchQueue
    private let io = DispatchQueue(label: "manifoldd.file-write")
    /// Where it ends up; where it's written meanwhile; how it's opened.
    private var path: String
    private var writing: String
    private var handle: FileHandle?
    /// Why it can't be done, once something has failed.
    private var failure: String?
    private var ended = false
    /// Told the path written, on the server's queue, before `end` is sent.
    private var finished: ((String) -> Void)?

    static func start(_ stream: MuxStream, path: String, mode: WriteMode, queue: DispatchQueue, finished: ((String) -> Void)? = nil) {
        let r = FileReceiver(stream: stream, path: path, queue: queue, finished: finished)
        stream.manualCredit = true
        r.io.async {
            r.open(mode)
            // Refused at once, not after all of it has come.
            if r.failure != nil { queue.async { r.refuse() } }
        }
        stream.onFrame = { frame in r.received(frame) }
        stream.onClose = { r.cut() }
    }

    private init(stream: MuxStream, path: String, queue: DispatchQueue, finished: ((String) -> Void)?) {
        self.stream = stream
        self.path = path
        self.writing = path
        self.queue = queue
        self.finished = finished
    }

    /// On `io`: the file opened (the folders on the way made).
    private func open(_ mode: WriteMode) {
        let fm = FileManager.default
        let url = URL(fileURLWithPath: path)
        do {
            try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        } catch {
            failure = error.localizedDescription
            return
        }
        switch mode {
        case .create:
            guard Self.createNew(path) else { failure = fm.fileExists(atPath: path) ? "exists" : "couldn't create \(path)"; return }
        case .unique:
            // The name as given, else "name 2", "name 3"…: the first free.
            let dir = url.deletingLastPathComponent().path, name = url.lastPathComponent
            let ext = (name as NSString).pathExtension, base = (name as NSString).deletingPathExtension
            var n = 2
            while !Self.createNew(path) {
                guard fm.fileExists(atPath: path), n < 10_000 else { failure = "couldn't create \(path)"; return }
                path = dir + "/" + base + " \(n)" + (ext.isEmpty ? "" : "." + ext)
                n += 1
            }
            writing = path
        case .replace:
            writing = url.deletingLastPathComponent().appendingPathComponent(".\(url.lastPathComponent).manifold-\(getpid())-\(UInt32.random(in: 0...UInt32.max))").path
            guard fm.createFile(atPath: writing, contents: nil) else { failure = "couldn't write in \(url.deletingLastPathComponent().path)"; return }
        case .append:
            if !fm.fileExists(atPath: path), !fm.createFile(atPath: path, contents: nil) { failure = "couldn't create \(path)"; return }
        }
        handle = FileHandle(forWritingAtPath: writing)
        if handle == nil { failure = "couldn't write \(writing)" }
        if mode == .append { _ = try? handle?.seekToEnd() }
    }

    /// A file made only if there's none (O_EXCL), so two can't both take a name.
    private static func createNew(_ path: String) -> Bool {
        let fd = Foundation.open(path, O_WRONLY | O_CREAT | O_EXCL, 0o644)
        guard fd >= 0 else { return false }
        Foundation.close(fd)
        return true
    }

    private func received(_ frame: Frame) {
        guard frame.kind == .data, !ended else { return }
        if frame.payload.isEmpty { return finish() }
        let data = frame.payload, n = frame.payload.count + 5
        io.async { [self] in
            if failure == nil, let handle {
                do { try handle.write(contentsOf: data) } catch { failure = error.localizedDescription }
            }
            queue.async { [stream] in stream.consumed(n) }
        }
    }

    /// The last piece came: closed, put in place, answered.
    private func finish() {
        ended = true
        io.async { [self] in
            try? handle?.close()
            handle = nil
            if failure == nil, writing != path {
                if rename(writing, path) != 0 { failure = String(cString: strerror(errno)) }
            }
            if failure != nil { unlink(writing) }
            queue.async { [self] in
                if failure == nil { finished?(path) }
                stream.send(.message(ServerMessage.end(error: failure, path: failure == nil ? path : nil)))
                stream.close()
            }
        }
    }

    private func refuse() {
        guard !ended else { return }
        ended = true
        stream.send(.message(ServerMessage.end(error: failure, path: nil)))
        stream.close()
    }

    /// The stream closed before the end: what was written taken away.
    private func cut() {
        guard !ended else { return }
        ended = true
        io.async { [self] in
            try? handle?.close()
            handle = nil
            unlink(writing)
        }
    }
}
