import Foundation
import ManifoldCore

/// The pages web tiles have shown, for the address bar's completions:
/// each address once (as it's typed again: a forwarded page by its host
/// and port, `slowbox:3000/x`), its title, how often and when last. Kept in
/// the app's folder, saved a moment after it changes.
final class WebHistory {
    static let shared = WebHistory()

    struct Entry: Codable, Equatable {
        var address: String
        var title: String
        var visits: Int
        var last: Date
    }

    private(set) var entries: [String: Entry] = [:]
    /// Pages forgotten (⇧⌫): not offered again, from tiles either, until
    /// they're visited again.
    private(set) var forgotten: Set<String> = []

    private struct Saved: Codable {
        var entries: [Entry]
        var forgotten: [String]
    }
    private let file = Paths.directory.appendingPathComponent("web-history.json")
    private var saveWork: DispatchWorkItem?
    static let limit = 3000

    private init() {
        if let data = try? Data(contentsOf: file), let saved = try? JSONDecoder().decode(Saved.self, from: data) {
            for e in saved.entries { entries[WebAddress.plain(e.address)] = e }
            forgotten = Set(saved.forgotten)
        }
    }

    func visited(_ address: String, title: String?) {
        let key = WebAddress.plain(address)
        // Pages, not files shown as pages, nor blank ones.
        guard !key.isEmpty, !key.hasPrefix("about:"), !key.hasPrefix("file:") else { return }
        var e = entries[key] ?? Entry(address: address, title: "", visits: 0, last: Date())
        e.address = address
        if let title, !title.isEmpty { e.title = title }
        e.visits += 1
        e.last = Date()
        entries[key] = e
        forgotten.remove(key)
        if entries.count > Self.limit {
            for (k, _) in entries.sorted(by: { $0.value.last < $1.value.last }).prefix(entries.count - Self.limit) { entries.removeValue(forKey: k) }
        }
        scheduleSave()
    }

    /// A page's title come after it was shown.
    func titled(_ address: String, _ title: String?) {
        let key = WebAddress.plain(address)
        guard let title, !title.isEmpty, var e = entries[key], e.title != title else { return }
        e.title = title
        entries[key] = e
        scheduleSave()
    }

    /// A page taken out (⇧⌫ on its completion).
    func forget(_ address: String) {
        let key = WebAddress.plain(address)
        entries.removeValue(forKey: key)
        forgotten.insert(key)
        scheduleSave()
    }

    /// Those whose address begins with what's typed first, then those with
    /// it in their address or title (the likeliest first: visited most,
    /// then lately).
    func matches(_ typed: String, limit: Int) -> [Entry] {
        let q = WebAddress.plain(typed).lowercased()
        guard !q.isEmpty else { return [] }
        func rank(_ a: Entry, _ b: Entry) -> Bool { a.visits != b.visits ? a.visits > b.visits : a.last > b.last }
        let all = Array(entries.values)
        // Begun by it: the site before pages within it (as Chrome completes
        // `loc` to `localhost:8765`, not a page deep in it), then the likeliest.
        func depth(_ e: Entry) -> Int { WebAddress.plain(e.address).filter { $0 == "/" }.count }
        let starts = all.filter { WebAddress.plain($0.address).lowercased().hasPrefix(q) }
            .sorted { depth($0) != depth($1) ? depth($0) < depth($1) : rank($0, $1) }
        let begun = Set(starts.map(\.address))
        let within = all.filter { !begun.contains($0.address) && (WebAddress.plain($0.address).lowercased().contains(q) || $0.title.lowercased().contains(q)) }
            .sorted(by: rank)
        return Array((starts + within).prefix(limit))
    }

    private func scheduleSave() {
        saveWork?.cancel()
        let saved = Saved(entries: Array(entries.values), forgotten: Array(forgotten))
        let work = DispatchWorkItem { [file] in
            guard let data = try? JSONEncoder().encode(saved) else { return }
            try? data.write(to: file, options: .atomic)
        }
        saveWork = work
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 1, execute: work)
    }
}
