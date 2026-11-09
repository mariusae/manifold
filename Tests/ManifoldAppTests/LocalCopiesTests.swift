import Foundation
import Testing
import ManifoldCore
@testable import Manifold

// I-5, M18 (STATE-MACHINES.md): a remote file opened here, saved while its
// host is away, waits for the host — it isn't sent (and failed, and said
// so) again and again.

@MainActor
@Test func aCopySavedWhileItsHostIsAwayWaitsQuietly() async throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("localcopies-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    let url = dir.appendingPathComponent("notes.txt")
    try Data("first".utf8).write(to: url)
    // A host never reached: its link isn't up.
    let away = HostClient(transport: .remote(Destination(provider: "ssh", target: "nowhere.invalid"), name: "nowhere"))
    #expect(away.link != .connected)

    let copies = LocalCopies()
    LocalCopies.awayRetry = 0.3
    defer { LocalCopies.awayRetry = 10 }
    var said: [String?] = []
    copies.onSentBack = { _, _, error in said.append(error) }
    let rowsBefore = Transfers.shared.items.count
    copies.adopt(url, of: "/remote/notes.txt", on: away, label: "nowhere")

    // Saved (later, so its date moves), then the time a send would take,
    // and a few looks again.
    try await Task.sleep(for: .seconds(1.1))
    try Data("second".utf8).write(to: url)
    // Waited on suspended, so the main queue (the watcher's, the
    // debouncer's) runs meanwhile.
    try await Task.sleep(for: .seconds(2.5))

    #expect(said.isEmpty, "said \(said)")
    #expect(Transfers.shared.items.count == rowsBefore, "a transfer was tried while its host was away")
}
