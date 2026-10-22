import Foundation
import ManifoldCore

/// Files carried between this Mac and a host (§8): a file or folder
/// dropped on another host's folder or terminal goes up; one dragged out
/// of another host's folder (to the Finder, Mail) comes down; one opened
/// with an app here comes down and goes back up when it's saved. Each file
/// on a stream of its own, paced to the link, so none holds up anything
/// else said meanwhile — a keystroke, an edit.
enum Transfer {
    /// A file or a folder (all that's in it) of this Mac's to `remote` on
    /// the host. `replace`: over what's there; else a file already there
    /// fails it ("exists").
    static func upload(_ local: URL, to remote: String, on c: HostClient, replace: Bool, done: @escaping (String?) -> Void) {
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: local.path, isDirectory: &isDir) else { return done("not found") }
        guard isDir.boolValue else { return uploadFile(local, to: remote, on: c, replace: replace, done: done) }
        // A folder: it and the folders in it made, then each file, in turn.
        var folders = [remote]
        var files: [(URL, String)] = []
        let base = local.standardizedFileURL.path
        if let e = FileManager.default.enumerator(at: local, includingPropertiesForKeys: [.isDirectoryKey]) {
            for case let u as URL in e {
                let rel = String(u.standardizedFileURL.path.dropFirst(base.count + 1))
                let target = remote + "/" + rel
                if (try? u.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true { folders.append(target) } else { files.append((u, target)) }
            }
        }
        func makeFolders(_ i: Int) {
            guard i < folders.count else { return send(0) }
            c.propose(.makeFolder(path: folders[i])) { error in
                if let error { return done(error) }
                makeFolders(i + 1)
            }
        }
        func send(_ i: Int) {
            guard i < files.count else { return done(nil) }
            uploadFile(files[i].0, to: files[i].1, on: c, replace: replace) { error in
                if let error { return done(error) }
                send(i + 1)
            }
        }
        makeFolders(0)
    }

    private static func uploadFile(_ local: URL, to remote: String, on c: HostClient, replace: Bool, done: @escaping (String?) -> Void) {
        guard let h = try? FileHandle(forReadingFrom: local) else { return done("couldn't read \(local.lastPathComponent)") }
        c.writeFile(remote, mode: replace ? .replace : .create, next: { (try? h.read(upToCount: Mux.bulkPiece)) ?? Data() }) { error, _ in
            try? h.close()
            done(error)
        }
    }

    /// A file or folder of the host's to `local` on this Mac (made, or
    /// written over).
    static func download(_ remote: String, isDirectory: Bool, on c: HostClient, to local: URL, done: @escaping (String?) -> Void) {
        guard isDirectory else { return downloadFile(remote, on: c, to: local, done: done) }
        do { try FileManager.default.createDirectory(at: local, withIntermediateDirectories: true) } catch { return done(error.localizedDescription) }
        c.listFolder(remote) { entries in
            guard let entries else { return done("couldn't list \(remote)") }
            func next(_ i: Int) {
                guard i < entries.count else { return done(nil) }
                let e = entries[i]
                download(remote + "/" + e.name, isDirectory: e.isDirectory, on: c, to: local.appendingPathComponent(e.name)) { error in
                    if let error { return done(error) }
                    next(i + 1)
                }
            }
            next(0)
        }
    }

    private static func downloadFile(_ remote: String, on c: HostClient, to local: URL, done: @escaping (String?) -> Void) {
        FileManager.default.createFile(atPath: local.path, contents: nil)
        guard let h = try? FileHandle(forWritingTo: local) else { return done("couldn't write \(local.path)") }
        var failure: String?
        c.readFile(remote, onData: { data in
            guard failure == nil else { return }
            do { try h.write(contentsOf: data) } catch { failure = error.localizedDescription }
        }) { error in
            try? h.close()
            done(failure ?? error)
        }
    }
}

extension HostClient {
    /// A file's bytes from the host, down a stream of its own as they come
    /// (`onData`), from `offset`, `length` of them at most; then `done`,
    /// with why not if it wasn't all there (unreadable, bigger than
    /// `limit`, the link gone).
    func readFile(_ path: String, offset: Int64 = 0, length: Int64? = nil, limit: Int64? = nil,
                  onData: @escaping (Data) -> Void, done: @escaping (String?) -> Void) {
        guard let mux else { return done("not connected") }
        let stream = mux.open(bulk: true)
        var ended: String??
        stream.onFrame = { frame in
            if frame.kind == .data { return onData(frame.payload) }
            if case let .end(error, _)? = frame.decode(ServerMessage.self) { ended = .some(error) }
        }
        stream.onClose = { done(ended ?? "the link to the host went") }
        stream.send(.message(ClientMessage.readFile(path: path, offset: offset, length: length, limit: limit)))
    }

    /// A file's bytes up a stream of its own: `next` gives each piece (an
    /// empty one at the end), asked while the stream wants more; `done`
    /// with why not, or the path written.
    func writeFile(_ path: String, mode: WriteMode, next: @escaping () -> Data, done: @escaping (String?, String?) -> Void) {
        send(.writeFile(path: path, mode: mode), next: next, done: done)
    }

    /// An image kept on the host as `name` in `folder` (Manifold's own, if
    /// nil), "name 2" if that's taken, and an image block `block` made for
    /// it; `done` with why not, or where it went.
    func saveImage(_ data: Data, block: BlockID, name: String, folder: String?, done: @escaping (String?, String?) -> Void) {
        var offset = 0
        send(.saveImage(block: block, name: name, folder: folder), next: {
            let piece = data.subdata(in: offset..<min(data.count, offset + Mux.bulkPiece))
            offset += piece.count
            return piece
        }, done: done)
    }

    private func send(_ first: ClientMessage, next: @escaping () -> Data, done: @escaping (String?, String?) -> Void) {
        guard let mux else { return done("not connected", nil) }
        let stream = mux.open(bulk: true)
        var ended: (String?, String?)?
        var finished = false
        stream.onFrame = { frame in
            if case let .end(error, path)? = frame.decode(ServerMessage.self) {
                ended = (error, path)
                // Refused before the end: no more of it.
                finished = true
            }
        }
        stream.onClose = {
            let (error, path) = ended ?? ("the link to the host went", nil)
            done(error, path)
        }
        func produce() {
            while !finished, stream.wantsMore {
                let piece = next()
                stream.send(Frame(.data, piece))
                if piece.isEmpty { finished = true }
            }
        }
        stream.onDrain = { produce() }
        stream.send(.message(first))
        produce()
    }

    /// A file's bytes by its path (all of them, nil past `limit` or
    /// unreadable).
    func readBytes(path: String, limit: Int, done: @escaping (Data?) -> Void) {
        var whole = Data()
        readFile(path, limit: Int64(limit), onData: { whole.append($0) }) { error in done(error == nil ? whole : nil) }
    }

    /// A file block's bytes (an image, a PDF), as big as it is.
    func readBytes(_ block: BlockID, done: @escaping (Data?) -> Void) {
        guard let path = node.block(block)?.path else { return done(nil) }
        var whole = Data()
        readFile(path, onData: { whole.append($0) }) { error in done(error == nil ? whole : nil) }
    }
}
