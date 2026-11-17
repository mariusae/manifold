import Foundation
import Testing
@testable import ManifoldCore

/// prism-ffi's editing.rs tests, and Manifold's own: NoteEditor in UTF-16,
/// and where Manifold's notes differ from Weft's.
struct NoteEditorTests {
    func units(_ s: String) -> [UInt16] { Array(s.utf16) }
    func slice(_ s: String, _ start: Int, _ end: Int) -> String { String(decoding: Array(s.utf16)[start..<end], as: UTF16.self) }

    // --- editing.rs ---------------------------------------------------------

    @Test func offsetsCrossInUTF16() {
        let editor = NoteEditor(source: "- 🚀 **go** [[Café]]\n")
        let (body, layout) = (editor.text, editor.layout)
        #expect(layout.runs.contains { $0.kind == .strong && slice(body, $0.start, $0.end) == "go" })
        // The page link is one character of the view, after "🚀 go ": 6 units in.
        #expect(layout.runs.contains { if case .pageLink(let target, _) = $0.kind { return target == "Café" && $0.start == 6 }; return false })
        #expect(layout.lines[0].content == 0 && layout.lines[0].end == units(body).count)
        let typed = NoteEditor.completion(in: "🚀 see [[Caf", caret: 12)!
        #expect(typed.kind == .link && typed.typed == "Caf" && typed.start == 7 && typed.end == 12)
    }

    @Test func aLinkToAPageIsShownWithItsLabelAndChangedWhole() {
        var editor = NoteEditor(source: "- notes from [[meeting-x]] then\n")
        #expect(editor.text == "notes from \u{FFFC} then")
        #expect(editor.linkTargets == ["meeting-x"])
        editor.setLinkLabels(["meeting-x": "Meeting: Object model"])
        #expect(editor.text == "notes from \u{FFFC}Meeting: Object model then")
        let link = editor.layout.runs.first { if case .pageLink = $0.kind { return true }; return false }!
        #expect(link.start == 11 && link.end == 11 + 1 + 21)
        // Typed inside the words: after the link, and the link kept as it was.
        var edit = editor.replace(start: 15, end: 15, with: "!")
        #expect(editor.markdown == "- notes from [[meeting-x]]! then\n")
        #expect(edit.start == 33 && edit.end == 33 && edit.replacement == "!" && edit.selectionStart == 34)
        // A character of its words deleted: the whole link goes.
        edit = editor.replace(start: 32, end: 33, with: "")
        #expect(editor.markdown == "- notes from ! then\n")
        #expect(edit.start == 11 && edit.end == 33 && edit.replacement == "" && edit.selectionStart == 11)
        editor = NoteEditor(source: "- see [[a]] and [[b]]\n")
        editor.setLinkLabels(["a": "Alpha"])
        #expect(editor.text == "see \u{FFFC}Alpha and \u{FFFC}b")
        #expect(editor.markdownBetween(start: 6, end: 14) == "[[a]] and")
    }

    @Test func anEditorIsTheNoteAndTheViewFollowsIt() {
        // As Weft's, the title kept apart (its fields and title setters are Weft's own, not here).
        let source = "---\ntags: [a]\n---\n# Atlas 🚀\n\n- one 🚀\n- two\n"
        let editor = NoteEditor(source: source, options: .prism)
        #expect(editor.text == "one 🚀\ntwo")
        var edit = editor.replace(start: 6, end: 6, with: "!")
        #expect(edit.start == 6 && edit.end == 6 && edit.replacement == "!" && edit.selectionStart == 7)
        edit = editor.perform(.newline, selectionStart: 7, selectionEnd: 7)!
        #expect(edit.start == 8 && edit.replacement == "\n" && edit.selectionStart == 8)
        #expect(editor.markdown == "---\ntags: [a]\n---\n# Atlas 🚀\n\n- one 🚀!\n- \n- two\n")
        edit = editor.perform(.indent, selectionStart: 8, selectionEnd: 8)!
        #expect(edit.start == edit.end && edit.replacement.isEmpty && edit.selectionStart == 8)
        #expect(editor.undo() != nil && editor.canRedo)
    }

    @Test func rowsFoldAndMoveInTheViewsOwnOffsets() {
        let editor = NoteEditor(source: "- 🚀 one\n  - 9:00–9:30 two\n  - 10:00 three\n- last\n")
        let caret = units(editor.text).count - 2
        let edit = editor.perform(.fold, onRows: [0], selectionStart: caret, selectionEnd: caret)!
        #expect(editor.text == "🚀 one\nlast" && edit.selectionStart == caret - 26)
        let lines = editor.layout.lines
        #expect(lines[0].isFolded && lines[0].hasChildren && !lines[1].isFolded)
        #expect(editor.foldedRows == [FoldedRow(index: 0, text: "🚀 one")])
        let info = editor.rowInfo(0)!
        #expect(info.isFolded && info.hidden == 2 && info.canMoveDown)
        #expect(!editor.setFoldedRows(editor.foldedRows) && editor.setFoldedRows([]))
        #expect(editor.text.split(separator: "\n").count == 4)
        #expect(editor.dropDepth(rows: [3], before: 0, depth: 4) == 0)
        #expect(editor.moveRows([3], before: 0, depth: 0, selectionStart: 0, selectionEnd: 0) != nil)
        #expect(editor.markdownOf(rows: [0, 1]) == "- last\n- 🚀 one\n  - 9:00–9:30 two\n  - 10:00 three\n")
        #expect(NoteEditor.webAddress(" https://example.com ") == "https://example.com")
        let linked = editor.link(selectionStart: 0, selectionEnd: 4, address: "https://example.com")!
        #expect(editor.text.hasPrefix("last\n") && linked.selectionStart == 4)
        #expect(editor.markdown.hasPrefix("- [last](https://example.com)\n"))
    }

    // --- Manifold's notes ---------------------------------------------------

    @Test func untouchedNotesAreByteForByteTheSame() {
        for source in [
            "", "\n", "# Title\n\nSome words.\n\n- one\n  - two\n", "---\ntags: [a]\n---\n# T\n\n- x <!-- folded -->\n  - y\n",
            "* [X] Capital\n+ [ ]\n1) one\n2) two\n", "> [!TIP]\n> quoted\n\n```swift\nlet x = 1\n```\n", "line one\r\nline two\r\n",
            "- a\n\n\n- b\n\n", "| a | b |\n|---|---|\n| 1 | 2 |\n", "- tabbed\n\t- child\n", "e\u{301}cole café\n", "- [x](manifold:h/01M7H26D73H3TTEXV8X914R50J) and [[wiki]]\n",
            "no newline at the end",
        ] {
            let editor = NoteEditor(source: source)
            #expect(editor.markdown.same(source), "\(source.debugDescription) → \(editor.markdown.debugDescription)")
            // A command with nothing to do changes nothing.
            _ = editor.perform(.unfoldAll, selectionStart: 0, selectionEnd: 0)
            #expect(editor.markdown.same(source))
        }
    }

    @Test func theTitleIsARowLikeAnyOther() {
        let editor = NoteEditor(source: "# Plan\n\n- one\n- two\n")
        #expect(editor.text == "Plan\none\ntwo")
        #expect(editor.layout.lines[0].kind == .heading(level: 1))
        #expect(editor.layout.lines[1].depth == 1, "a top-level row is in one list item: its own")
        // Written in like any other row.
        let edit = editor.replace(start: 4, end: 4, with: "s")
        #expect(edit.selectionStart == 5)
        #expect(editor.markdown == "# Plans\n\n- one\n- two\n")
        // Return at its end: a plain row after it.
        _ = editor.perform(.newline, selectionStart: 5, selectionEnd: 5)!
        #expect(editor.text == "Plans\n\none\ntwo")
        #expect(editor.outline.map(\.words) == ["Plans", "", "one", "two"])
        #expect(editor.outline[0].heading == 1)
    }

    @Test func foldsAreTheViewsNeverTheNotes() {
        let source = "- one\n  - under\n- two\n"
        let editor = NoteEditor(source: source)
        _ = editor.perform(.fold, onRows: [0], selectionStart: 0, selectionEnd: 0)!
        #expect(editor.text == "one\ntwo")
        #expect(editor.markdown == source, "nothing is written for a fold")
        #expect(editor.foldedRows == [FoldedRow(index: 0, text: "one")])
        // Kept by the view, and given back to another editor of the same note.
        let again = NoteEditor(source: source)
        #expect(again.setFoldedRows(editor.foldedRows))
        #expect(again.text == "one\ntwo" && again.markdown == source)
        // A note that has the comment already keeps it, as words of no kind.
        let marked = "- one <!-- folded -->\n  - under\n"
        let old = NoteEditor(source: marked)
        #expect(old.text == "one \u{FFFC}\nunder" && old.foldedRows.isEmpty && old.markdown == marked)
        _ = old.replace(start: 0, end: 0, with: "the ")
        #expect(old.markdown == "- the one <!-- folded -->\n  - under\n")
    }

    @Test func focusIsByRowAndKeptInMemory() {
        let source = "# Plan\n\n- one\n- two **bold**\n  - under two\n    - deep\n      - deeper\n  - also under\n- three\n"
        let editor = NoteEditor(source: source)
        #expect(!editor.isFocused && editor.focusLabel == nil)
        let deep = editor.text.components(separatedBy: "\n").firstIndex(of: "deep")!
        #expect(editor.setFocus(row: deep))
        #expect(editor.isFocused && editor.text == "deeper")
        #expect(editor.focusLabel == "deep" && editor.focusTrail == ["two bold", "under two"])
        #expect(editor.layout.lines[0].depth == 1)
        #expect(editor.markdown == source, "no name is written for a focus")
        // Written in, it is the note that is written in.
        let end = units(editor.text).count
        _ = editor.replace(start: end, end: end, with: "!")
        #expect(editor.markdown == source.replacingOccurrences(of: "deeper\n", with: "deeper!\n"))
        // Focused further in, by a row of what is shown.
        #expect(editor.setFocus(row: 0))
        #expect(editor.text == "" && editor.focusTrail == ["two bold", "under two", "deep"])
        _ = editor.replace(start: 0, end: 0, with: "new")
        #expect(editor.markdown.contains("      - deeper!\n        - new\n"))
        // Out a level, and out past the top: the whole note.
        #expect(editor.focusOut(levels: 1) && editor.focusLabel == "deep" && editor.text == "deeper!\nnew")
        #expect(editor.focusOut(levels: 9) && !editor.isFocused)
        #expect(!editor.focusOut(levels: 1))
        #expect(editor.text == "Plan\none\ntwo bold\nunder two\ndeep\ndeeper!\nnew\nalso under\nthree")
        #expect(!editor.markdown.contains("<!--"))
        // A row with nothing under it is given a row to write in, no part of the note till written.
        #expect(editor.setFocus(row: 8) && editor.text == "" && editor.markdown.hasSuffix("- three\n"))
        #expect(editor.setFocus(row: nil) && !editor.isFocused)
        // No such row, or one that can hold none: no focus.
        #expect(!editor.setFocus(row: 99) && !editor.setFocus(row: 0))
    }

    @Test func thereAreNoCards() {
        let source = "- [A page](https://a.example) <!-- card -->\n- plain\n"
        let editor = NoteEditor(source: source)
        #expect(editor.text == "A page \u{FFFC}\nplain")
        #expect(editor.perform(.toggleCard, onRows: [0], selectionStart: 0, selectionEnd: 0) == nil)
        #expect(editor.perform(.toggleCard, selectionStart: 0, selectionEnd: 0) == nil)
        #expect(!editor.layout.lines.contains { $0.isCard })
        #expect(editor.markdown == source)
    }

    @Test func manifoldsLinksComeThroughEditsUntouched() {
        let link = "[x](manifold:h/01M7H26D73H3TTEXV8X914R50J)"
        let editor = NoteEditor(source: "- see \(link) here\n- next\n")
        #expect(editor.text == "see x here\nnext")
        #expect(editor.layout.runs.contains { $0.kind == .webLink(url: "manifold:h/01M7H26D73H3TTEXV8X914R50J") && $0.start == 4 && $0.end == 5 })
        _ = editor.replace(start: 0, end: 0, with: "Do ")
        _ = editor.replace(start: 13, end: 13, with: " now")
        _ = editor.perform(.bold, selectionStart: 0, selectionEnd: 2)!
        _ = editor.perform(.indent, onRows: [1], selectionStart: 0, selectionEnd: 0)!
        _ = editor.perform(.moveUp, onRows: [0], selectionStart: 0, selectionEnd: 0)
        #expect(editor.markdown == "- **Do** see \(link) here now\n  - next\n")
        // Return in the middle splits around it, and Delete joins it back.
        let at = units(editor.text).firstIndex(of: UInt16(UInt8(ascii: "h")))!
        _ = editor.perform(.newline, selectionStart: at, selectionEnd: at)!
        #expect(editor.markdown == "- **Do** see \(link) \n- here now\n  - next\n" || editor.markdown.contains(link))
        _ = editor.perform(.deleteBackward, selectionStart: at + 1, selectionEnd: at + 1)
        #expect(editor.markdown.contains(link))
        // Its words written over: still the same address. Typed after them: not the link's.
        let x = units(editor.text).firstIndex(of: UInt16(UInt8(ascii: "x")))!
        _ = editor.replace(start: x, end: x + 1, with: "xy")
        #expect(editor.markdown.contains("[xy](manifold:h/01M7H26D73H3TTEXV8X914R50J)"))
        _ = editor.replace(start: x + 2, end: x + 2, with: "z")
        #expect(editor.markdown.contains("[xy](manifold:h/01M7H26D73H3TTEXV8X914R50J)z"))
        while editor.undo() != nil {}
        #expect(editor.markdown == "- see \(link) here\n- next\n")
        // Pasted whole, it is a link.
        let pasted = NoteEditor(source: "- a b\n")
        _ = pasted.replace(start: 2, end: 2, with: link)
        #expect(pasted.markdown == "- a \(link)b\n" && pasted.text == "a xb")
    }

    @Test func offsetsAreUTF16WithEmojiAndCJK() {
        let editor = NoteEditor(source: "- 日本語 🚀 **太字**\n- 👩‍👩‍👧 family\n")
        #expect(editor.text == "日本語 🚀 太字\n👩‍👩‍👧 family")
        let strong = editor.layout.runs.first { $0.kind == .strong }!
        #expect(slice(editor.text, strong.start, strong.end) == "太字" && strong.start == 7)
        // After the rocket (two units) and before the bold words.
        var edit = editor.replace(start: 6, end: 6, with: "!")
        #expect(edit.start == 6 && edit.selectionStart == 7)
        #expect(editor.markdown == "- 日本語 🚀! **太字**\n- 👩‍👩‍👧 family\n")
        // A place inside a surrogate pair is the character's end.
        let second = units(editor.text).firstIndex(of: 10)! + 1
        #expect(editor.layout.lines[1].start == second)
        edit = editor.perform(.newline, selectionStart: second + 8, selectionEnd: second + 8)!
        // (The space a row's words now start with is kept, as its reference.)
        #expect(editor.markdown == "- 日本語 🚀! **太字**\n- 👩‍👩‍👧\n- &#32;family\n")
        #expect(editor.undo() != nil)
        #expect(editor.markdown == "- 日本語 🚀! **太字**\n- 👩‍👩‍👧 family\n")
        // Deleted across rows by UTF-16 range.
        edit = editor.replace(start: 4, end: second + 9, with: "")
        #expect(editor.markdown == "- 日本語 family\n" && edit.selectionStart == 4)
    }

    @Test func replacePerformAndUndoRoundTrip() {
        let source = "- one\n- two\n  - under\n- three\n"
        let editor = NoteEditor(source: source)
        var view = editor.text
        func apply(_ edit: BodyEdit) {
            var u = Array(view.utf16)
            u.replaceSubrange(edit.start..<edit.end, with: Array(edit.replacement.utf16))
            view = String(decoding: u, as: UTF16.self)
            #expect(view == editor.text)
        }
        apply(editor.replace(start: 3, end: 3, with: "!"))
        apply(editor.perform(.newline, selectionStart: 4, selectionEnd: 4)!)
        apply(editor.replace(start: 5, end: 5, with: "new"))
        apply(editor.perform(.indent, selectionStart: 5, selectionEnd: 5)!)
        apply(editor.perform(.moveDown, onRows: [0], selectionStart: 0, selectionEnd: 0)!)
        apply(editor.perform(.toggleFold, onRows: [1], selectionStart: 0, selectionEnd: 0)!)
        apply(editor.perform(.deleteRows, onRows: [0], selectionStart: 0, selectionEnd: 0)!)
        let changed = editor.markdown
        var undone = 0
        while let edit = editor.undo() { apply(edit); undone += 1 }
        #expect(editor.markdown == source && undone > 0 && !editor.canUndo)
        while let edit = editor.redo() { apply(edit) }
        #expect(editor.markdown == changed)
    }

    @Test func aRowsLinesInTheFile() {
        let editor = NoteEditor(source: "---\na: b\n---\n# T\n\nA paragraph\nof two lines.\n\n- one\n  - two\n    more of two\n- three\n")
        #expect(editor.text == "T\nA paragraph\u{2028}of two lines.\none\ntwo\u{2028}more of two\nthree")
        #expect(editor.markdownLines(ofRow: 0) == 3...3)
        #expect(editor.markdownLines(ofRow: 1) == 5...6)
        #expect(editor.markdownLines(ofRow: 2) == 8...8)
        #expect(editor.markdownLines(ofRow: 3) == 9...10)
        #expect(editor.markdownLines(ofRow: 4) == 11...11)
        #expect(editor.markdownLines(ofRow: 5) == nil)
        #expect(editor.setFocus(row: 2))
        #expect(editor.markdownLines(ofRow: 0) == 9...10)
    }

    @Test func blankAndProse() {
        #expect(NoteEditor(source: "").isBlank && NoteEditor(source: "- \n").isBlank && !NoteEditor(source: "- a\n").isBlank)
        let editor = NoteEditor(source: "First.\n\nSecond.\n")
        #expect(editor.readsAsProse)
        editor.setProse(true)
        _ = editor.perform(.newline, selectionStart: 6, selectionEnd: 6)!
        _ = editor.replace(start: 7, end: 7, with: "Between.")
        #expect(editor.markdown == "First.\n\nBetween.\n\nSecond.\n")
    }

    @Test func aLongNoteStaysResponsive() {
        var source = "# Long\n\n"
        for i in 0..<5000 { source += i % 7 == 0 ? "- row **\(i)** with [a link](https://x.example/\(i))\n" : "  - row \(i) [[page \(i % 50)]] #tag\n" }
        let clock = ContinuousClock()
        var editor: NoteEditor!
        let open = clock.measure { editor = NoteEditor(source: source) }
        #expect(editor.markdown == source)
        let end = Array(editor.text.utf16).count
        var typed = Duration.zero
        for i in 0..<10 {
            typed += clock.measure { _ = editor.replace(start: end + i, end: end + i, with: "x") }
        }
        let newline = clock.measure { _ = editor.perform(.newline, selectionStart: end + 10, selectionEnd: end + 10) }
        let layout = clock.measure { _ = editor.layout }
        let fold = clock.measure { _ = editor.perform(.foldAll, selectionStart: 0, selectionEnd: 0) }
        print("5,000 rows: open \(open), a keystroke \(typed / 10), return \(newline), layout \(layout), fold all \(fold)")
        #expect(open < .seconds(2) && typed / 10 < .milliseconds(250) && newline < .milliseconds(500) && layout < .milliseconds(500) && fold < .seconds(1))
    }
}
