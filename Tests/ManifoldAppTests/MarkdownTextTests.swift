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

// A comment's code block (boxes): one box, its lines in it, on a tint;
// the words round it in none.
@MainActor
@Test func aCommentsCodeBlockIsBoxed() {
    let md = "Before:\n\n```\nline one\nline two\n```\n\nAfter."
    let s = MarkdownText.attributed(md, font: .systemFont(ofSize: 13), code: .monospacedSystemFont(ofSize: 12, weight: .regular), boxes: true)
    let ns = s.string as NSString
    func blocks(at word: String) -> [NSTextBlock] {
        let r = ns.range(of: word)
        return (s.attribute(.paragraphStyle, at: r.location, effectiveRange: nil) as? NSParagraphStyle)?.textBlocks ?? []
    }
    #expect(blocks(at: "line one").count == 1)
    #expect(blocks(at: "line one").first === blocks(at: "line two").first)
    #expect(blocks(at: "Before").isEmpty && blocks(at: "After").isEmpty)
}

// A comment cut into words and code: each fenced block its own piece (laid
// out unwrapped, scrolled sideways), the words round it pieces of their own.
@Test func aCommentIsCutAtItsCodeBlocks() {
    let md = "B3 crashed:\n\n```rust\npanicked at node.rs:1702\n  range end\n```\n\nNow capped at `text.len()`.\n~~~\nopen fence"
    #expect(CommentPieces.split(md) == [
        .words("B3 crashed:"),
        .code("panicked at node.rs:1702\n  range end"),
        .words("Now capped at `text.len()`."),
        .code("open fence"),
    ])
    #expect(CommentPieces.split("No code at all.") == [.words("No code at all.")])
}
