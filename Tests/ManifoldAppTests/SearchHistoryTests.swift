import Foundation
import Testing
@testable import Manifold

// ↑ walks back through what was asked, ↓ forward to what was being typed.
@Test func searchHistoryWalksBackAndForth() {
    let name = "test-\(UUID().uuidString)"
    defer { UserDefaults.standard.removeObject(forKey: "searchHistory." + name) }
    let h = SearchHistory(name)
    h.add("one")
    h.add("two")
    h.add("one")   // asked again: to the front, once
    #expect(h.items == ["one", "two"])
    #expect(h.step(older: true, from: "draft") == "one")
    #expect(h.step(older: true, from: "one") == "two")
    #expect(h.step(older: true, from: "two") == nil)
    #expect(h.step(older: false, from: "two") == "one")
    #expect(h.step(older: false, from: "one") == "draft")
    #expect(!h.walking)
    // What's showing is the latest (just asked): ↑ the one before it.
    #expect(h.step(older: true, from: "one") == "two")
    // Kept across.
    #expect(SearchHistory(name).items == ["one", "two"])
}
