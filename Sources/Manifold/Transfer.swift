import Foundation
import ManifoldCore

/// Files carried between this Mac and its hosts (§8), or between two
/// hosts, or within one: a file or folder dropped on another host's folder
/// or terminal goes up; one dragged out to the Finder, or downloaded, comes
/// down; one copied from one host's folder to another's goes straight from
/// the one to the other; one opened with an app here comes down and goes
/// back up when it's saved. Each is a tree on a stream of its own (paced
/// to the link, so it holds up nothing else), its walking and its disk
/// work on a queue of its own — never the main thread; it ends at its
/// destination all at once, or not at all.
///
/// Each says how far it has got (`progress`, from any thread: bytes, of
/// how many once that's known), says it's done on the main thread (why
/// not, or nil), and gives back how to stop it.
enum Transfer {
    typealias Progress = (Int64, Int64?) -> Void
    typealias Stop = () -> Void

    /// A file or folder of this Mac's to `remote` on the host; over what's
    /// there if `replace`, else failing ("exists").
    @discardableResult
    static func upload(_ local: URL, to remote: String, on c: HostClient, replace: Bool,
                       progress: Progress? = nil, done: @escaping (String?) -> Void) -> Stop {
        guard let mux = c.mux else { return failed(done, "\(c.host.raw) isn't connected") }
        let q = DispatchQueue(label: "manifold.upload")
        let finish = once(done)
        let stream = mux.open(bulk: true, compress: true, callbackQueue: q)
        let source = TreeSource(stream, root: local.path)
        var result: String??
        var stopped = false
        source.onProgress = { sent, total in progress?(sent, total) }
        // The source failed (the file changed, or went): the host's side is
        // told, and answers `end`.
        stream.onFrame = { frame in
            if case let .end(error, _)? = frame.decode(TreeMessage.self) { result = .some(error) }
        }
        stream.onClose = {
            source.cancel()
            finish(stopped ? "cancelled" : result ?? "the link to the host went")
        }
        stream.send(.message(ClientMessage.writeTree(path: remote, replace: replace)))
        source.start()
        return { q.async { stopped = true; stream.abort() } }
    }

    /// A file or folder of the host's to `local` here; over what's there if
    /// `replace` (it's put there only once all of it has come).
    @discardableResult
    static func download(_ remote: String, on c: HostClient, to local: URL, replace: Bool = true,
                         progress: Progress? = nil, done: @escaping (String?) -> Void) -> Stop {
        guard let mux = c.mux else { return failed(done, "\(c.host.raw) isn't connected") }
        let q = DispatchQueue(label: "manifold.download")
        let finish = once(done)
        let stream = mux.open(bulk: true, compress: true, callbackQueue: q)
        let sink = TreeSink(stream, destination: local.path, replace: replace)
        var stopped = false
        sink.onProgress = { written, total in progress?(written, total) }
        sink.onFinished = { error, _ in
            stream.close()
            finish(error)
        }
        stream.onFrame = { frame in sink.received(frame) }
        stream.onClose = { sink.cut(stopped ? "cancelled" : "the link to the host went") }
        stream.send(.message(ClientMessage.readTree(path: remote)))
        return { q.async { stopped = true; stream.abort() } }
    }

    /// A file or folder of one host's to `dest` on another (or the same):
    /// within a host, the host copies it itself; between two, it comes from
    /// the one and goes to the other as it comes, through here but never
    /// onto this Mac's disk.
    @discardableResult
    static func copy(_ path: String, on a: HostClient, to dest: String, on b: HostClient, replace: Bool,
                     progress: Progress? = nil, done: @escaping (String?) -> Void) -> Stop {
        if a === b { return copyWithin(path, to: dest, on: a, replace: replace, progress: progress, done: done) }
        guard let from = a.mux else { return failed(done, "\(a.host.raw) isn't connected") }
        guard let to = b.mux else { return failed(done, "\(b.host.raw) isn't connected") }
        let q = DispatchQueue(label: "manifold.relay")
        let finish = once(done)
        let source = from.open(bulk: true, compress: true, callbackQueue: q)
        let sink = to.open(bulk: true, compress: true, callbackQueue: q)
        // Credit back to the source only as the sink takes what it sent:
        // the slower link sets the pace, and nothing piles up here.
        source.manualCredit = true
        var owed = 0, moved: Int64 = 0, total: Int64?
        var forwarded = false, ended = false, stopped = false
        func payBack() {
            guard owed > 0 else { return }
            source.consumed(owed)
            owed = 0
        }
        source.onFrame = { frame in
            if frame.kind == .data {
                moved += Int64(frame.payload.count)
                progress?(moved, total)
            } else if let m = frame.decode(TreeMessage.self) {
                switch m {
                case let .total(t): total = t; progress?(0, t)
                case .done: forwarded = true
                default: break
                }
            }
            sink.send(frame)
            owed += frame.payload.count + 5
            if sink.wantsMore { payBack() }
        }
        sink.onDrain = { payBack() }
        sink.onFrame = { frame in
            guard case let .end(error, _)? = frame.decode(TreeMessage.self) else { return }
            ended = true
            source.abort()
            finish(error)
        }
        source.onClose = {
            // Closed before all of it had come: the copy can't finish.
            guard !forwarded, !ended else { return }
            ended = true
            sink.abort()
            finish(stopped ? "cancelled" : "the link to \(a.host.raw) went")
        }
        sink.onClose = {
            guard !ended else { return }
            ended = true
            source.abort()
            finish(stopped ? "cancelled" : "the link to \(b.host.raw) went")
        }
        source.send(.message(ClientMessage.readTree(path: path)))
        sink.send(.message(ClientMessage.writeTree(path: dest, replace: replace)))
        return { q.async { stopped = true; source.abort(); sink.abort() } }
    }

    /// Copied by the host itself, saying how far it has got.
    private static func copyWithin(_ path: String, to dest: String, on c: HostClient, replace: Bool,
                                   progress: Progress?, done: @escaping (String?) -> Void) -> Stop {
        guard let mux = c.mux else { return failed(done, "\(c.host.raw) isn't connected") }
        let q = DispatchQueue(label: "manifold.copy")
        let finish = once(done)
        let stream = mux.open(bulk: true, compress: true, callbackQueue: q)
        var result: String??
        var stopped = false
        stream.onFrame = { frame in
            switch frame.decode(TreeMessage.self) {
            case let .progress(d, t)?: progress?(d, t)
            case let .end(error, _)?: result = .some(error)
            default: break
            }
        }
        stream.onClose = { finish(stopped ? "cancelled" : result ?? "the link to the host went") }
        stream.send(.message(ClientMessage.copyTree(from: path, to: dest, replace: replace)))
        return { q.async { stopped = true; stream.abort() } }
    }

    /// A copy of each of several things, as one: `limit` at a time (so a
    /// drop of hundreds doesn't open hundreds of streams at once), their
    /// progress added up (the total once each has said its own), each's
    /// outcome given back in order, on the main thread.
    typealias Job = (_ progress: @escaping Progress, _ done: @escaping (String?) -> Void) -> Stop?

    @discardableResult
    static func batch(_ jobs: [Job], limit: Int = 4, progress: Progress? = nil, done: @escaping ([String?]) -> Void) -> Stop {
        let q = DispatchQueue(label: "manifold.batch")
        var results = [String??](repeating: nil, count: jobs.count)
        var dones = [Int64](repeating: 0, count: jobs.count)
        var totals = [Int64?](repeating: nil, count: jobs.count)
        var stops: [Int: Stop] = [:]
        var next = 0, running = 0, stopped = false, reported = false
        func finishIfAll() {
            guard !reported, running == 0, results.allSatisfy({ $0 != nil }) else { return }
            reported = true
            let out = results.map { $0 ?? "cancelled" }
            DispatchQueue.main.async { done(out) }
        }
        func report() {
            let known = totals.compactMap { $0 }
            progress?(dones.reduce(0, +), known.count == jobs.count ? known.reduce(0, +) : nil)
        }
        func launch() {
            while running < limit, next < jobs.count, !stopped {
                let i = next
                next += 1
                running += 1
                let job = jobs[i]
                DispatchQueue.main.async {
                    let stop = job({ d, t in q.async { dones[i] = d; if let t { totals[i] = t }; report() } }) { error in
                        q.async {
                            results[i] = .some(error)
                            stops[i] = nil
                            running -= 1
                            if error == nil, let t = totals[i] { dones[i] = t }
                            report()
                            launch()
                            finishIfAll()
                        }
                    }
                    if let stop { q.async { stops[i] = stop } }
                }
            }
        }
        if jobs.isEmpty { DispatchQueue.main.async { done([]) } }
        q.async { launch() }
        return {
            q.async {
                stopped = true
                for stop in stops.values { stop() }
                // Those not begun: stopped too.
                for i in next..<jobs.count { results[i] = .some("cancelled") }
                next = jobs.count
                finishIfAll()
            }
        }
    }

    /// `done`, once, on the main thread.
    private static func once(_ done: @escaping (String?) -> Void) -> (String?) -> Void {
        let lock = NSLock()
        var called = false
        return { error in
            let first = lock.withLock { () -> Bool in
                defer { called = true }
                return !called
            }
            if first { DispatchQueue.main.async { done(error) } }
        }
    }

    private static func failed(_ done: @escaping (String?) -> Void, _ why: String) -> Stop {
        DispatchQueue.main.async { done(why) }
        return {}
    }
}

extension HostClient {
    /// A file's bytes from the host, down a stream of its own as they come
    /// (`onData`), from `offset`, `length` of them at most; then `done`,
    /// with why not if it wasn't all there (unreadable, bigger than
    /// `limit`, the link gone). What it returns stops it (and then `done`
    /// says the link went).
    @discardableResult
    func readFile(_ path: String, offset: Int64 = 0, length: Int64? = nil, limit: Int64? = nil,
                  onData: @escaping (Data) -> Void, done: @escaping (String?) -> Void) -> () -> Void {
        guard let mux else { done("not connected"); return {} }
        let stream = mux.open(bulk: true, compress: true, callbackQueue: .main)
        var ended: String??
        stream.onFrame = { frame in
            if frame.kind == .data { return onData(frame.payload) }
            if case let .end(error, _)? = frame.decode(ServerMessage.self) { ended = .some(error) }
        }
        stream.onClose = { done(ended ?? "the link to the host went") }
        stream.send(.message(ClientMessage.readFile(path: path, offset: offset, length: length, limit: limit)))
        return { [weak stream] in stream?.abort() }
    }

    /// An image kept on the host as `name` in `folder` (Manifold's own, if
    /// nil), "name 2" if that's taken, and an image block `block` made for
    /// it; `done` (on the main thread) with why not, or where it went.
    func saveImage(_ data: Data, block: BlockID, name: String, folder: String?, done: @escaping (String?, String?) -> Void) {
        guard let mux else { return done("not connected", nil) }
        let stream = mux.open(bulk: true, callbackQueue: .main)
        var ended: (String?, String?)?
        var offset = 0, finished = false
        stream.onFrame = { frame in
            if case let .end(error, path)? = frame.decode(ServerMessage.self) {
                ended = (error, path)
                finished = true
            }
        }
        stream.onClose = {
            let (error, path) = ended ?? ("the link to the host went", nil)
            done(error, path)
        }
        func produce() {
            while !finished, stream.wantsMore {
                let piece = data.subdata(in: offset..<min(data.count, offset + stream.piece))
                offset += piece.count
                stream.send(Frame(.data, piece))
                if piece.isEmpty { finished = true }
            }
        }
        stream.onDrain = { produce() }
        stream.send(.message(ClientMessage.saveImage(block: block, name: name, folder: folder)))
        produce()
    }

    /// A file's bytes by its path (all of them, nil past `limit` or
    /// unreadable); what it returns stops it.
    @discardableResult
    func readBytes(path: String, limit: Int, done: @escaping (Data?) -> Void) -> () -> Void {
        var whole = Data()
        return readFile(path, limit: Int64(limit), onData: { whole.append($0) }) { error in done(error == nil ? whole : nil) }
    }

    /// A file block's bytes (an image, a PDF), as big as it is.
    func readBytes(_ block: BlockID, done: @escaping (Data?) -> Void) {
        guard let path = node.block(block)?.path else { return done(nil) }
        var whole = Data()
        readFile(path, onData: { whole.append($0) }) { error in done(error == nil ? whole : nil) }
    }
}
