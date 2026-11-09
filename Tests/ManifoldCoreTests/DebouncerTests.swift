import Foundation
import Testing
@testable import ManifoldCore

// I-8, M31 (STATE-MACHINES.md): what's waiting, run now (a project
// search's ⏎), runs once, and nothing runs once it's been cancelled —
// a search typed over isn't run later with what was typed before.

private final class Runs: @unchecked Sendable {
    private let lock = NSLock()
    private var all: [String] = []
    func add(_ s: String) { lock.withLock { all.append(s) } }
    var list: [String] { lock.withLock { all } }
}

@Test func whatsWaitingFlushedRunsOnceNotAgainAtItsTime() {
    let queue = DispatchQueue(label: "test.debouncer")
    let soon = Debouncer(queue: queue)
    let runs = Runs()
    queue.sync { soon.schedule(after: 0.1) { runs.add("abc") } }
    queue.sync {
        #expect(soon.isPending)
        soon.flush()
        #expect(!soon.isPending)
    }
    Thread.sleep(forTimeInterval: 0.3)
    #expect(runs.list == ["abc"])
}

@Test func whatsCancelledIsntRunByAFlush() {
    let queue = DispatchQueue(label: "test.debouncer")
    let soon = Debouncer(queue: queue)
    let runs = Runs()
    queue.sync {
        soon.schedule(after: 0.1) { runs.add("old") }
        // Typed over where it can't be searched (Home off): nothing waits.
        soon.cancel()
        #expect(!soon.isPending)
        // ⏎: nothing stale run.
        soon.flush()
    }
    Thread.sleep(forTimeInterval: 0.3)
    #expect(runs.list.isEmpty)
}
