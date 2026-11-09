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
