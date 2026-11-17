import Foundation
import Testing
@testable import ManifoldCore

// I-8, M4 (STATE-MACHINES.md): a watched file deleted, and made again later
// than the moment a save by rename takes, is still followed.

private final class Seen: @unchecked Sendable {
    private let lock = NSLock()
    private var n = 0
    func add() { lock.withLock { n += 1 } }
    var count: Int { lock.withLock { n } }
}

@Test func aFileDeletedAndMadeAgainLaterIsStillWatched() throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("watch-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    let path = dir.appendingPathComponent("a.txt").path
    try Data("one".utf8).write(to: URL(fileURLWithPath: path))
    let queue = DispatchQueue(label: "test.watch")
    let seen = Seen()
    let watcher = FileWatcher(path: path, queue: queue) { seen.add() }
    _ = watcher
    try FileManager.default.removeItem(atPath: path)
    // Gone longer than the watcher's quick looks for it (2 s).
    Thread.sleep(forTimeInterval: 3)
    let before = seen.count
    try Data("two".utf8).write(to: URL(fileURLWithPath: path))
    let end = Date().addingTimeInterval(4)
    while Date() < end, seen.count == before { Thread.sleep(forTimeInterval: 0.05) }
    #expect(seen.count > before, "made again, it wasn't heard")
    // And changes after that are heard too.
    Thread.sleep(forTimeInterval: 0.3)
    let after = seen.count
    try Data("three!".utf8).write(to: URL(fileURLWithPath: path))
    let end2 = Date().addingTimeInterval(3)
    while Date() < end2, seen.count == after { Thread.sleep(forTimeInterval: 0.05) }
    #expect(seen.count > after, "changed after it was made again, it wasn't heard")
}

@Test func aFileWhoseFolderIsntThereYetIsHeardWhenBothCome() throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("watch-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    let path = dir.appendingPathComponent("not/yet/a.txt").path
    let queue = DispatchQueue(label: "test.watch.missing")
    let seen = Seen()
    let watcher = queue.sync { FileWatcher(path: path, queue: queue) { seen.add() } }
    _ = watcher
    Thread.sleep(forTimeInterval: 0.3)
    try FileManager.default.createDirectory(atPath: path.deletingLastPathComponent, withIntermediateDirectories: true)
    Thread.sleep(forTimeInterval: 0.3)
    try Data("here".utf8).write(to: URL(fileURLWithPath: path))
    let end = Date().addingTimeInterval(4)
    while Date() < end, seen.count == 0 { Thread.sleep(forTimeInterval: 0.05) }
    #expect(seen.count > 0, "made with its folders, it wasn't heard")
}

private final class Told: @unchecked Sendable {
    private let lock = NSLock()
    private var all: [Set<String>] = []
    func add(_ s: Set<String>) { lock.withLock { all.append(s) } }
    var union: Set<String> { lock.withLock { all.reduce(into: Set<String>()) { $0.formUnion($1) } } }
    func clear() { lock.withLock { all = [] } }
}

@Test func aWatchedFolderIsToldOfItsOwnEntriesOnly() throws {
    // Through /tmp, a link: told as it was asked.
    let dir = "/tmp/folder-watch-\(UUID().uuidString)"
    try FileManager.default.createDirectory(atPath: dir + "/sub", withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(atPath: dir) }
    let queue = DispatchQueue(label: "test.folderwatch")
    let told = Told()
    let watch = FolderWatch(queue: queue) { told.add($0) }
    queue.sync { watch.set([dir]) }
    Thread.sleep(forTimeInterval: 0.3)
    try Data("x".utf8).write(to: URL(fileURLWithPath: dir + "/new.txt"))
    var end = Date().addingTimeInterval(4)
    while Date() < end, told.union.isEmpty { Thread.sleep(forTimeInterval: 0.05) }
    #expect(told.union == [dir])
    // Under a folder within it: not its change.
    Thread.sleep(forTimeInterval: 0.3)
    told.clear()
    try Data("y".utf8).write(to: URL(fileURLWithPath: dir + "/sub/deeper.txt"))
    Thread.sleep(forTimeInterval: 0.6)
    #expect(told.union.isEmpty)
    // Watched too: told.
    queue.sync { watch.set([dir, dir + "/sub"]) }
    Thread.sleep(forTimeInterval: 0.3)
    try FileManager.default.removeItem(atPath: dir + "/sub/deeper.txt")
    end = Date().addingTimeInterval(4)
    while Date() < end, told.union.isEmpty { Thread.sleep(forTimeInterval: 0.05) }
    #expect(told.union == [dir + "/sub"])
    queue.sync { watch.set([]) }
}
