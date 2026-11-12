import AppKit
import Testing
@testable import Manifold

// Lists in a comment (an agent's, mostly): each item its one mark, however
// deep — not one for each list it's in — and a paragraph after a nested
// list on a line of its own, unmarked.

@MainActor
@Test func aNestedListsItemsHaveOneMarkEach() {
    let md = """
    - Outer one
      - inner a
      - inner b

      So after the inner list.
    - Outer two
      1. first
      2. second
    """
    let s = MarkdownText.attributed(md, font: .systemFont(ofSize: 13), code: .monospacedSystemFont(ofSize: 11, weight: .regular)).string
    let lines = s.split(separator: "\n").map(String.init)
    #expect(lines == ["• Outer one", "• inner a", "• inner b", "So after the inner list.", "• Outer two", "1. first", "2. second"], "\(lines)")
}
