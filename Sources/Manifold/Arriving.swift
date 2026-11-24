import Foundation
import ManifoldCore

/// Blocks on their way to another host (§3.11): a file of this Mac
/// dropped on an agent there is named at once — its reference typed — and
/// sent on, its block made there once it's in. Asked for meanwhile (`mani
/// read`, `mani info`), it's waited for a while; still coming, it's said
/// so, and how far it's got.
@MainActor final class Arriving {
    static let shared = Arriving()

    enum Outcome: Equatable {
        /// In, and its block made.
        case arrived
        /// It didn't come: why.
        case failed(String)
        /// Still on its way: how far, in words.
        case coming(String)
    }

    private struct Item {
        var name: String
        var to: String
        var sent: Int64 = 0
        var total: Int64?
        var waiters: [UUID: CheckedContinuation<Outcome, Never>] = [:]
    }
    private var items: [BlockID: Item] = [:]
    /// Those that didn't come, a while: asked for, said why.
    private var failures: [BlockID: String] = [:]

    func begin(_ id: BlockID, name: String, to host: String) {
        items[id] = Item(name: name, to: host)
        failures[id] = nil
    }

    func progress(_ id: BlockID, sent: Int64, of total: Int64?) {
        items[id]?.sent = sent
        if let total { items[id]?.total = total }
    }

    func end(_ id: BlockID, error: String?) {
        guard let item = items.removeValue(forKey: id) else { return }
        if let error { failures[id] = error }
        for w in item.waiters.values { w.resume(returning: error.map { .failed(Self.failure(item.name, $0)) } ?? .arrived) }
    }

    func isComing(_ id: BlockID) -> Bool { items[id] != nil }

    /// Its outcome once it's in, or failed; still coming after `limit`, how
    /// far it's got. Nil for one that isn't coming (nor failed).
    func wait(_ id: BlockID, limit: TimeInterval) async -> Outcome? {
        if let why = failures[id] { return .failed(Self.failure("It", why)) }
        guard items[id] != nil else { return nil }
        let key = UUID()
        return await withCheckedContinuation { c in
            items[id]?.waiters[key] = c
            Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(limit * 1_000_000_000))
                guard let self, let w = self.items[id]?.waiters.removeValue(forKey: key) else { return }
                w.resume(returning: .coming(self.words(id)))
            }
        }
    }

    /// "report.pdf is still on its way to devvm — 3.1 MB of 7.7 MB; ask again in a moment".
    private func words(_ id: BlockID) -> String {
        guard let i = items[id] else { return "" }
        let far = i.total.map { "\(MediaView.megabytes(i.sent)) of \(MediaView.megabytes($0))" } ?? MediaView.megabytes(i.sent)
        return "\(i.name) is still on its way to \(i.to) — \(far) so far; ask again in a moment"
    }

    private static func failure(_ name: String, _ why: String) -> String { "\(name) didn't arrive: \(why)" }
}
