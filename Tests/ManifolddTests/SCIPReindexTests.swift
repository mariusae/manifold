import Foundation
import Testing
@testable import ManifoldCore
@testable import manifoldd

// I-8, M5 (STATE-MACHINES.md): a re-index asked for while the project is
// being indexed isn't dropped — it runs once that one's done.

extension ProcessLifecycle {
    @Test func aReindexAskedForWhileIndexingRunsAfter() throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("scip-\(UUID().uuidString)")
        let root = base.appendingPathComponent("project")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }
        // The index files kept here, not in the user's data folder.
        let dataBefore = ProcessInfo.processInfo.environment["MANIFOLD_DIR"]
        setenv("MANIFOLD_DIR", base.appendingPathComponent("data").path, 1)
        defer { if let dataBefore { setenv("MANIFOLD_DIR", dataBefore, 1) } else { unsetenv("MANIFOLD_DIR") } }
        try Data().write(to: root.appendingPathComponent("fake.marker"))
        let source = root.appendingPathComponent("a.swift").path
        try Data("let a = 1\n".utf8).write(to: URL(fileURLWithPath: source))
        let runs = base.appendingPathComponent("runs").path

        let queue = DispatchQueue(label: "test.scip")
        let scip = SCIPService(queue: queue)
        // An indexer that says each run and takes a second.
        scip.indexers = [SCIPIndexer(id: "fake", languages: ["swift"], rootMarkers: ["fake.marker"],
                                     command: "echo run >> \(runs.shellQuoted); sleep 1; echo x > {out}")]
        scip.preferredShell = { "/bin/sh" }
        let after = SCIPService.reindexAfter
        SCIPService.reindexAfter = 0.1
        defer { SCIPService.reindexAfter = after }
        func count() -> Int { ((try? String(contentsOfFile: runs, encoding: .utf8)) ?? "").split(separator: "\n").count }
        func waitFor(_ n: Int) {
            let end = Date().addingTimeInterval(10)
            while Date() < end, count() < n { Thread.sleep(forTimeInterval: 0.05) }
        }

        // Indexed once (so it has an index a save brings up to date).
        queue.sync { scip.request(.index(path: source)) { _ in } }
        waitFor(1)
        Thread.sleep(forTimeInterval: 1.5)
        // Indexed again, and saved while that runs.
        queue.sync { scip.request(.index(path: source)) { _ in } }
        waitFor(2)
        queue.sync { scip.saved(source) }
        // The saved one's run, once the second is done.
        waitFor(3)
        #expect(count() == 3, "the re-index asked for while indexing was dropped")
    }
}
