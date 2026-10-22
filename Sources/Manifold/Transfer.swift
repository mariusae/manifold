import Foundation
import ManifoldCore

/// Files carried between this Mac and a host (§8): a file or folder
/// dropped on another host's folder or terminal goes up; one dragged out
/// of another host's folder (to the Finder, Mail) comes down; one opened
/// with an app here comes down and goes back up when it's saved. In
/// pieces, one after another, so a big file isn't one message.
enum Transfer {
    static let piece = 4 << 20

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
        func next(_ first: Bool) {
            let data = (try? h.read(upToCount: piece)) ?? Data()
            // The first piece makes the file (even an empty one); the rest add to it.
            guard first || !data.isEmpty else { try? h.close(); return done(nil) }
            let mode: WriteMode = first ? (replace ? .replace : .create) : .append
            c.propose(.writePath(path: remote, data: data, mode: mode)) { error in
                if let error { try? h.close(); return done(error) }
                if data.count < piece { try? h.close(); return done(nil) }
                next(false)
            }
        }
        next(true)
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
        func next(_ offset: Int64) {
            c.readRange(path: remote, offset: offset, length: piece) { data in
                guard let data else { try? h.close(); return done("couldn't read \(remote)") }
                do { try h.write(contentsOf: data) } catch { try? h.close(); return done(error.localizedDescription) }
                if data.count < piece { try? h.close(); return done(nil) }
                next(offset + Int64(data.count))
            }
        }
        next(0)
    }
}
