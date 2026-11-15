import AppKit

/// What was asked before in a kind of field — find in files, its folder,
/// a project's search — the latest first, kept across launches: ↑ in the
/// field the one before, ↓ the one after (and past the latest, what was
/// being typed), as a shell's history is.
final class SearchHistory {
    private let key: String
    private let most: Int
    /// The latest first.
    private(set) var items: [String]
    /// Where ↑ has walked to (nil: not walking), and what was typed before.
    private var index: Int?
    private var draft = ""

    init(_ name: String, most: Int = 50) {
        key = "searchHistory." + name
        self.most = most
        items = UserDefaults.standard.stringArray(forKey: key) ?? []
    }

    /// Asked: at the front, once.
    func add(_ query: String) {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        index = nil
        guard !q.isEmpty else { return }
        items.removeAll { $0 == q }
        items.insert(q, at: 0)
        if items.count > most { items.removeLast(items.count - most) }
        UserDefaults.standard.set(items, forKey: key)
    }

    /// Whether ↑ has walked back from what was being typed.
    var walking: Bool { index != nil }

    /// ↑ (`older`) or ↓: the query to show, if there's one that way.
    func step(older: Bool, from current: String) -> String? {
        if older {
            var next = (index ?? -1) + 1
            if index == nil {
                draft = current
                // The latest is what's showing (just asked): the one before it.
                if next < items.count, items[next] == current { next += 1 }
            }
            guard next < items.count else { return nil }
            index = next
            return items[next]
        }
        guard let i = index else { return nil }
        if i == 0 { index = nil; return draft }
        index = i - 1
        return items[i - 1]
    }

    /// Typed in: no longer walking.
    func typed() { index = nil }
}

extension NSTextField {
    /// A recalled query shown, its caret at its end.
    func showRecalled(_ text: String) {
        stringValue = text
        if let editor = currentEditor() { editor.selectedRange = NSRange(location: (text as NSString).length, length: 0) }
    }
}
