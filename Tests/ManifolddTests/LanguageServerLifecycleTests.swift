import Foundation
import Testing
import ManifoldCore
@testable import manifoldd

// I-5, M3 (STATE-MACHINES.md): a language server that fails isn't given up
// on for good — it's started afresh when next wanted, a while on.

extension ProcessLifecycle {
    @Test func aLanguageServerThatFailsIsStartedAgainWhenNextWanted() throws {
        let queue = DispatchQueue(label: "test.lsp")
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("lsp-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let path = dir.appendingPathComponent("a.fake").path
        let block = BlockID(host: HostID("testhost"))

        let servers = LanguageServers(queue: queue)
        let lock = NSLock()
        var states: [String] = []
        servers.onState = { _, _, state in lock.withLock { states.append(state) } }
        servers.textOf = { $0 == block ? (Rope("text"), path) : nil }
        let before = LanguageServers.retryAfter
        LanguageServers.retryAfter = 0.2
        defer { LanguageServers.retryAfter = before }
        queue.sync {
            // A server that ends at once: started, then failed.
            servers.configure([LanguageServerConfig(id: "fake", extensions: ["fake"], command: "false", rootMarkers: [])])
            servers.textChanged(block)
        }
        Thread.sleep(forTimeInterval: 1)
        let first = lock.withLock { states }
        #expect(first.filter { $0 == "starting" }.count == 1)
        #expect(first.contains("exited"))

        // Wanted again (an edit) after the while: started afresh.
        queue.sync { servers.textChanged(block) }
        Thread.sleep(forTimeInterval: 1)
        let after = lock.withLock { states }
        #expect(after.filter { $0 == "starting" }.count == 2, "states: \(after)")
    }
}
