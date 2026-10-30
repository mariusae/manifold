import Foundation
import Testing
@testable import ManifoldCore

struct NoteOutlineTests {
    /// Notes as they're written, each read and written back byte for byte.
    @Test func notesComeBackAsTheyWereWritten() {
        let notes = [
            "",
            "- one\n- two\n  - two a\n  - two b\n- three\n",
            "# Plans\n\nSome words first.\n\n- [ ] buy milk\n- [x] write tests\n  - [X] port the outline\n",
            "1. first\n2. second\n   1) inner\n10. tenth\n",
            "* star\n+ plus\n- dash",
            "---\ntitle: front\n---\n- a\n",
            "> quoted\n> on two lines\n\n- item\n\n  a paragraph in it\n\n  ```swift\n  let x = 1\n  ```\n- after\n",
            "- a\n\n- loose\n\n- list\n",
            "Text\r\n- windows\r\n",
            "***\n\n## Heading two\n### Three\nplain line\nlazy continuation\n",
            "-    wide spacing\n- [ ]\n- \n",
        ]
        for note in notes {
            #expect(NoteOutlineMarkdown.serialize(NoteOutlineMarkdown.parse(note)) == note, "“\(note)”")
        }
    }

    @Test func aNoteIsReadAsRows() {
        let o = NoteOutlineMarkdown.parse("# Plans\n- [ ] buy milk\n  - [x] at the shop\n1. first\n> said\n")
        #expect(o.rows.map(\.kind) == [.heading(1), .bullet, .bullet, .ordered, .quote])
        #expect(o.rows.map(\.depth) == [0, 0, 1, 0, 0])
        #expect(o.rows.map(\.text) == ["Plans", "buy milk", "at the shop", "first", "said"])
        #expect(o.rows[1].task == .open)
        #expect(o.rows[2].task == .done("x"))
    }

    @Test func rowsTakeTheirChildrenAlong() {
        var rows = NoteOutlineMarkdown.parse("- a\n- b\n  - b1\n- c\n").rows
        // b indented under a, its child with it.
        #expect(NoteOutlineEditing.indent(&rows, 1..<2) != nil)
        #expect(rows.map(\.depth) == [0, 1, 2, 0])
        // And out again.
        #expect(NoteOutlineEditing.outdent(&rows, 1..<2) != nil)
        #expect(rows.map(\.depth) == [0, 0, 1, 0])
        // c moved up past b and its child.
        #expect(NoteOutlineEditing.moveUp(&rows, 3..<4) == 1..<2)
        #expect(rows.map(\.text) == ["a", "c", "b", "b1"])
        // b, with b1, down past nothing: refused.
        #expect(NoteOutlineEditing.moveDown(&rows, 2..<3) == nil)
        var outline = NoteOutline(rows: rows)
        outline.endsWithNewline = true
        #expect(NoteOutlineMarkdown.serialize(outline) == "- a\n- c\n- b\n  - b1\n")
    }

    @Test func aFoldedRowStillWritesItsChildren() {
        var rows = NoteOutlineMarkdown.parse("- a\n  - a1\n  - a2\n- b\n").rows
        #expect(NoteOutlineEditing.fold(&rows, at: 0) == 2)
        #expect(rows.map(\.text) == ["a", "b"])
        #expect(NoteOutlineMarkdown.serialize(NoteOutline(rows: rows)) == "- a\n  - a1\n  - a2\n- b\n")
        #expect(NoteOutlineEditing.unfold(&rows, at: 0) == 2)
        #expect(rows.map(\.text) == ["a", "a1", "a2", "b"])
    }

    @Test func checklistsCycleAndCheck() {
        // (A blank line between: else "plain" goes on with "a", as Markdown reads it.)
        var rows = NoteOutlineMarkdown.parse("- a\n\nplain\n").rows
        #expect(rows.map(\.text) == ["a", "plain"])
        NoteOutlineEditing.cycle(.checklist, &rows, 0..<2)
        #expect(rows.map(\.task) == [.open, .open])
        #expect(rows.allSatisfy { $0.kind == .bullet })
        NoteOutlineEditing.cycle(.checklist, &rows, 0..<1)
        #expect(rows[0].task == .done("x"))
        NoteOutlineEditing.cycle(.checklist, &rows, 0..<1)
        #expect(rows[0].task == nil)
        NoteOutlineEditing.toggleDone(&rows, 1..<2)
        #expect(rows[1].task == .done("x"))
        #expect(NoteOutlineMarkdown.serialize(NoteOutline(rows: rows)) == "- a\n\n- [x] plain\n")
    }

    @Test func doneItemsSinkToTheBottom() {
        var rows = NoteOutlineMarkdown.parse("- [x] done one\n- [ ] open\n- [x] done two\n- [ ] also open\n").rows
        #expect(NoteOutlineEditing.moveDoneToBottom(&rows, at: 0) != nil)
        #expect(rows.map(\.text) == ["open", "also open", "done one", "done two"])
    }

    @Test func rowsDeeperThanMarkdownCanSayAreBroughtUp() {
        var rows = [NoteRow(kind: .bullet, depth: 0, text: "a"), NoteRow(kind: .bullet, depth: 3, text: "b"),
                    NoteRow(kind: .paragraph, depth: 0, text: "p"), NoteRow(kind: .bullet, depth: 1, text: "c")]
        NoteOutlineEditing.normalize(&rows)
        #expect(rows.map(\.depth) == [0, 1, 0, 0])
    }

    @Test func aNotesOutlineIsItsHeadingsAndTopLevelItems() {
        let note = "---\ntitle: x\n---\n# Groceries\n\n- milk\n- [x] eggs\n  - free range\n\n## Steps\n1. shop\n"
        let items = NoteOutlineMarkdown.items(in: note)
        #expect(items.map(\.title) == ["Groceries", "milk", "eggs", "Steps", "shop"])
        #expect(items.map(\.level) == [0, 1, 1, 1, 2])
        #expect(items.map(\.line) == [3, 5, 6, 9, 10])
        #expect(items[2].task == .done("x"))
        // A note of bullets alone: they're its outline, at the top.
        #expect(NoteOutlineMarkdown.items(in: "- a\n  - a1\n- b\n").map(\.level) == [0, 0])
    }

    /// A row's inline Markdown: its markup what's hidden, the caret kept
    /// out of it, Delete taking what's shown.
    @Test func inlineMarkupIsHiddenAndSteppedOver() {
        let text = "a **bold** [link](x)" as NSString
        let whole = NSRange(location: 0, length: text.length)
        let spans = InlineMarkup.spans(in: text, range: whole)
        let hidden = spans.flatMap(\.markup).map { text.substring(with: $0) }
        #expect(hidden.contains("**"))
        #expect(hidden.contains("](x)"))
        #expect(InlineMarkup.plainText(text as String) == "a bold link")
        // Within the opening ** the caret goes past it, or back before it.
        #expect(InlineEditing.snap(3, runs: spans.flatMap(\.markup), forward: true) == 4)
        #expect(InlineEditing.snap(3, runs: spans.flatMap(\.markup), forward: false) == 2)
        // Delete after "bold**" takes the d, not a *.
        let gone = InlineEditing.deletion(at: 10, forward: false, text: text, within: whole, spans: spans)
        #expect(gone.map { text.substring(with: $0) } == "d")
    }
}
