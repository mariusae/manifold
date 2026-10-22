import Foundation
import Testing
@testable import ManifoldCore

/// A folder with what a copy has to carry: nested folders, an empty file,
/// an executable one, a link, a file bigger than a piece.
private func sampleTree() throws -> String {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("tree-\(UUID().uuidString)").path
    let fm = FileManager.default
    try fm.createDirectory(atPath: root + "/src/deep", withIntermediateDirectories: true)
    try "hello".write(toFile: root + "/a.txt", atomically: true, encoding: .utf8)
    try "".write(toFile: root + "/src/empty", atomically: true, encoding: .utf8)
    try "#!/bin/sh\necho hi\n".write(toFile: root + "/src/run.sh", atomically: true, encoding: .utf8)
    try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: root + "/src/run.sh")
    let big = Data((0..<(300 << 10)).map { UInt8(truncatingIfNeeded: $0 &* 7) })
    try big.write(to: URL(fileURLWithPath: root + "/src/deep/big.bin"))
    try fm.createSymbolicLink(atPath: root + "/link", withDestinationPath: "a.txt")
    return root
}

/// The same tree: names, kinds, sizes, permissions, links, bytes.
private func same(_ a: String, _ b: String) -> Bool {
    guard let x = TreeEntry.walk(a), let y = TreeEntry.walk(b), x.count == y.count else { return false }
    for (e, f) in zip(x, y) {
        guard e.path == f.path, e.kind == f.kind, e.size == f.size, e.target == f.target else { return false }
        if e.kind == .file {
            guard e.mode == f.mode else { return false }
            let p = e.path.isEmpty ? "" : "/" + e.path
            guard FileManager.default.contents(atPath: a + p) == FileManager.default.contents(atPath: b + p) else { return false }
        }
    }
    return true
}

private func muxPair(_ queue: DispatchQueue) -> (Mux, Mux) {
    var fds: [Int32] = [0, 0]
    #if canImport(Darwin)
    socketpair(AF_UNIX, SOCK_STREAM, 0, &fds)
    #else
    socketpair(AF_UNIX, Int32(SOCK_STREAM.rawValue), 0, &fds)
    #endif
    return (Mux(Connection(fd: fds[0], queue: queue)), Mux(Connection(fd: fds[1], queue: queue)))
}

private final class Box<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: T?
    func set(_ v: T) { lock.withLock { value = v } }
    var get: T? { lock.withLock { value } }
}

private func wait(until done: () -> Bool) {
    let end = Date().addingTimeInterval(10)
    while !done(), Date() < end { usleep(5_000) }
}

@Test func aFolderGoesDownAStreamWhole() throws {
    let root = try sampleTree()
    let dest = FileManager.default.temporaryDirectory.appendingPathComponent("tree-out-\(UUID().uuidString)").path
    defer { try? FileManager.default.removeItem(atPath: root); try? FileManager.default.removeItem(atPath: dest) }
    let queue = DispatchQueue(label: "tree-test")
    let (a, b) = muxPair(queue)
    let result = Box<(String?, String?)>()
    var source: TreeSource?
    b.onStream = { stream in
        let sink = TreeSink(stream, destination: dest, replace: false)
        sink.onFinished = { e, p in result.set((e, p)) }
        stream.onFrame = { sink.received($0) }
    }
    queue.sync {
        a.start()
        b.start()
        let s = a.open(bulk: true)
        source = TreeSource(s, root: root)
        source?.start()
    }
    wait { result.get != nil }
    #expect(result.get?.0 == nil)
    #expect(result.get?.1 == dest)
    #expect(same(root, dest))
    // Nothing of the work left beside it.
    let parent = (dest as NSString).deletingLastPathComponent
    #expect(!((try? FileManager.default.contentsOfDirectory(atPath: parent)) ?? []).contains { $0.hasPrefix("." + dest.lastPathComponent + ".manifold-") })
    queue.sync { a.connection.close(); b.connection.close() }
}

@Test func aCopyWithinADiskCopiesAll() throws {
    let root = try sampleTree()
    let dest = FileManager.default.temporaryDirectory.appendingPathComponent("tree-copy-\(UUID().uuidString)").path
    defer { try? FileManager.default.removeItem(atPath: root); try? FileManager.default.removeItem(atPath: dest) }
    let result = Box<(String?, String?)>()
    let copier = TreeCopier(from: root, to: dest, replace: false)
    copier.onFinished = { e, p in result.set((e, p)) }
    copier.start()
    wait { result.get != nil }
    #expect(result.get?.0 == nil)
    #expect(same(root, dest))
    // Again, not replacing: refused.
    let again = Box<(String?, String?)>()
    let second = TreeCopier(from: root, to: dest, replace: false)
    second.onFinished = { e, p in again.set((e, p)) }
    second.start()
    wait { again.get != nil }
    #expect(again.get?.0 == "exists")
}

@Test func aSinkCutShortLeavesNothing() throws {
    let dest = FileManager.default.temporaryDirectory.appendingPathComponent("tree-cut-\(UUID().uuidString)").path
    let queue = DispatchQueue(label: "tree-test")
    let (a, b) = muxPair(queue)
    let result = Box<(String?, String?)>()
    b.onStream = { stream in
        let sink = TreeSink(stream, destination: dest, replace: false)
        sink.onFinished = { e, p in result.set((e, p)) }
        stream.onFrame = { sink.received($0) }
        stream.onClose = { sink.cut("cancelled") }
    }
    queue.sync {
        a.start()
        b.start()
        let s = a.open(bulk: true)
        s.send(.message(TreeMessage.total(10)))
        s.send(.message(TreeMessage.entry(TreeEntry(path: "", kind: .file, size: 10))))
        s.send(Frame(.data, Data("half".utf8)))
        s.abort()
    }
    wait { result.get != nil }
    #expect(result.get?.0 == "cancelled")
    #expect(!FileManager.default.fileExists(atPath: dest))
    let parent = (dest as NSString).deletingLastPathComponent
    #expect(!((try? FileManager.default.contentsOfDirectory(atPath: parent)) ?? []).contains { $0.hasPrefix("." + dest.lastPathComponent + ".manifold-") })
    queue.sync { a.connection.close(); b.connection.close() }
}
