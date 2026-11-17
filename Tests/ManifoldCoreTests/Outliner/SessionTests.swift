import Testing
@testable import ManifoldCore

/// prism-markup's session.rs tests, on a session with prism's options
/// (the title kept apart; folds, names and cards written into the note).
struct SessionTests {
    typealias Session = Markup.Session
    typealias Change = Markup.Change
    typealias Command = Markup.Command

    static let note = "---\ntags: [Projects]\n---\n# Project Atlas\n\nA paragraph\nof two lines.\n\n## Next\n\n*   Book a room\n    *   ask [[Grace]]\n+ [ ] Send invites\n1. First\n\n```query\ntag: Person\n```\n"
    static let tree = "- one\n- two\n  - under two\n    - deep\n  - also under\n- three\n"

    static func session(_ source: String) -> Session { Session(source, options: .prism) }

    /// Applies a change to what a view shows, as the view would.
    static func shown(_ view: inout String, _ change: Change) {
        var b = view.u8
        b.replaceSubrange(change.range, with: change.replacement.u8)
        view = b.string
    }

    static func outline(_ source: String) -> (Session, String) {
        let session = Self.session(source)
        return (session, session.text)
    }

    /// Where these words first are, in bytes.
    static func find(_ text: String, _ needle: String) -> Int? { text.u8.find(needle.u8) }

    /// Types at the end of the view's line that starts with `line`.
    static func atEndOf(_ view: String, _ line: String) -> Int {
        let b = view.u8
        let start = b.find(line.u8)!
        return b.find(byte: .newline, from: start) ?? b.count
    }

    /// The index of the row shown that starts with these words.
    static func row(_ session: Session, _ words: String) -> Int {
        session.text.u8.split(byte: .newline).firstIndex { $0.hasPrefix(words.u8) }!
    }

    /// Does a command to the rows that start with these words, the caret where it is.
    @discardableResult
    static func on(_ session: Session, _ view: inout String, _ rows: [String], _ caret: Int, _ command: Command) -> Change? {
        let indexes = rows.map { row(session, $0) }
        guard let change = session.perform(onRows: indexes, caret..<caret, command) else { return nil }
        shown(&view, change)
        #expect(view == session.text)
        return change
    }

    /// The note's file, but for the marks of its folded rows.
    static func unmarked(_ session: Session) -> String { session.markdown().replacingOccurrences(of: " <!-- folded -->", with: "") }

    static func len(_ s: String) -> Int { s.utf8.count }

    @Test func theOutlineListsEveryRowAndARowIsBroughtIntoSight() {
        let session = Self.session("- one\n  - two\n    - three\n- four\n")
        #expect(session.outline().map { "\($0.depth) \($0.text)" } == ["0 one", "1 two", "2 three", "0 four"])
        session.setFoldedRows([FoldedRow(index: 0, text: "one")])
        #expect(session.text == "one\nfour")
        #expect(session.outline().count == 4)
        let at = session.revealRow(2)!
        #expect(session.text == "one\ntwo\nthree\nfour")
        #expect(session.text.u8.string(at..<(at + 5)) == "three")
        #expect(session.revealRow(9) == nil)
    }

    @Test func aFoldedRowIsMarkedInTheFileAndReadFoldedAgain() {
        let note = "# Plan\n\n- one\n  - under\n- [ ] two\n  more of two\n  - under two\n- three\n"
        var (session, view) = Self.outline(note)
        Self.on(session, &view, ["one"], 0, .toggleFold)
        Self.on(session, &view, ["two"], 0, .toggleFold)
        let written = session.markdown()
        #expect(written == "# Plan\n\n- one <!-- folded -->\n  - under\n- [ ] two <!-- folded -->\n  more of two\n  - under two\n- three\n")
        let again = Self.session(written)
        #expect(again.foldedRows() == [FoldedRow(index: 0, text: "one"), FoldedRow(index: 2, text: "two\nmore of two")])
        #expect(!again.text.contains("folded") && !again.text.contains("under"))
        #expect(again.markdown() == written)
        (session, view) = Self.outline(written)
        Self.on(session, &view, ["one"], 0, .toggleFold)
        Self.on(session, &view, ["two"], 0, .toggleFold)
        #expect(session.markdown() == note)
        #expect(Self.session("- alone <!-- folded -->\n").markdown() == "- alone\n")
        let code = "```\nx <!-- folded -->\n```\n"
        #expect(Self.session(code).markdown() == code)
    }

    @Test func aSessionFocusesWhereAPageIsSpokenOfOrWordsAreSaid() {
        let note = "# Day\n\n- standup\n- met with [[Ada Lovelace|Ada]] about\n  - the engine\n  - and [[Babbage]]\n- later #ada\n"
        var (session, view) = Self.outline(note)
        #expect(session.focusOnLinks(["Ada Lovelace"]))
        #expect(session.focusTitle == "met with [[Ada Lovelace|Ada]] about" && session.text == "the engine\nand \u{FFFC}")
        #expect(session.focus == nil, "nothing is named for it")
        #expect(session.markdown() == note, "and nothing in the note changes")
        #expect(session.focusOnLinks(["babbage"]) && session.focusTitle == "met with [[Ada Lovelace|Ada]] about")
        #expect(!session.focusOnLinks(["Ada"]) && session.text == view)
        #expect(!session.focusOnLinks(["Nobody"]) && session.text == view)
        #expect(session.focusOnWords(["ENGINE", "babbage"]))
        #expect(session.focusTitle == "met with [[Ada Lovelace|Ada]] about")
        #expect(session.focusOnWords(["engine"]) && session.focusTitle == "met with [[Ada Lovelace|Ada]] about")
        (session, view) = Self.outline("# Cos\n\n- [[2026-11-12]]\n- What are you up to\n- Kitchen\n  - don't make your own\n")
        #expect(!session.focusOnLinks(["2026-11-12"]) && session.text == view)
        #expect(!session.focusOnWords(["standup", "later"]) && session.text == view)
    }

    @Test func aSessionFocusedOnARowShowsAndEditsOnlyWhatIsUnderIt() {
        let note = "# Plan\n\n- one\n- two **bold**\n  - under two\n    - deep\n      - deeper\n  - also under\n- three\n"
        var (session, view) = Self.outline(note)
        let deep = session.anchorRow(Self.row(session, "deep"))!
        #expect(session.anchorRow(Self.row(session, "deep")) == deep)
        #expect(session.text == view, "a name is no part of a row's words")
        let named = note.replacingOccurrences(of: "- deep\n", with: "- deep <!-- ^\(deep) -->\n")
        #expect(session.markdown() == named)
        #expect(!session.setFocus("nosuch") && session.focus == nil && session.text == view)

        #expect(session.setFocus(deep))
        #expect(session.focus == deep && session.focusTitle == "deep")
        #expect(session.focusTrail == ["two bold", "under two"])
        #expect(session.text == "deeper")
        #expect(session.layout().lines[0].depth == 1, "what is under it starts at the margin")
        #expect(session.markdown() == named, "and the file is the whole note's")
        view = session.text
        var end = Self.len(view)
        Self.shown(&view, session.replace(end..<end, "!"))
        Self.shown(&view, session.perform((end + 1)..<(end + 1), .newline)!)
        end = Self.len(view)
        Self.shown(&view, session.replace(end..<end, "new"))
        #expect(view == "deeper!\nnew")
        session.setFocusTitle("deep,  renamed\n")
        let written = named.replacingOccurrences(of: "- deep <", with: "- deep, renamed <").replacingOccurrences(of: "      - deeper\n", with: "      - deeper!\n      - new\n")
        #expect(session.markdown() == written)
        let again = Self.session(written.replacingOccurrences(of: "- one\n", with: "- zero\n- one\n  - under one\n"))
        #expect(again.setFocus(deep))
        #expect(again.text == "deeper!\nnew")

        let over = session.focusOut(1)!
        #expect(session.focusOut(3) == nil && session.focusOut(0) == nil)
        #expect(session.setFocus(over))
        #expect(session.focusTitle == "under two" && session.text == "deep, renamed\ndeeper!\nnew")
        let top = session.focusOut(1)!
        #expect(session.setFocus(top) && session.focusTrail.isEmpty && session.focusOut(1) == nil)
        #expect(session.setFocus(nil as String?) && session.focus == nil)
        #expect(session.text == "one\ntwo bold\nunder two\ndeep, renamed\ndeeper!\nnew\nalso under\nthree")
        #expect(session.markdown().components(separatedBy: "<!-- ^").count - 1 == 3)

        (session, _) = Self.outline("- alone\n- [ ] other\n")
        let alone = session.anchorRow(0)!
        let marked = "- alone <!-- ^\(alone) -->\n- [ ] other\n"
        #expect(session.setFocus(alone))
        #expect(session.text == "" && session.markdown() == marked)
        _ = session.replace(0..<0, "child")
        #expect(session.markdown() == marked.replacingOccurrences(of: "-->\n", with: "-->\n  - child\n"))
        (session, view) = Self.outline("- a <!-- ^x1 --> \(Markup.foldedMark)\n  - b\n\nprose <!-- ^p1 -->\n")
        #expect(session.text == "a\nprose" && session.foldedRows().count == 1)
        #expect(session.anchorRow(1) == "p1")
        Self.on(session, &view, ["a"], 0, .duplicateRows)
        #expect(session.markdown().components(separatedBy: "^x1").count - 1 == 1)
    }

    @Test func aFirstLineIsTakenToBeTheTitle() {
        let session = Self.session("- Plans for *spring*\n  - seeds\n  - beds\n- later\n")
        #expect(session.firstLine() == "Plans for spring")
        #expect(session.takeFirstLine() == "Plans for spring")
        #expect(session.text == "seeds\nbeds\nlater")
        session.setTitle("Plans for spring")
        #expect(session.markdown() == "# Plans for spring\n\n- seeds\n- beds\n- later\n")
        let text = Self.session("# A title typed\n\nAnd the rest.\n")
        #expect(text.title() == "A title typed")
        let plain = Self.session("First words\nsecond line\n\nmore\n")
        #expect(plain.takeFirstLine() == "First words")
        #expect(plain.markdown() == "second line\n\nmore\n")
        #expect(Self.session("```\ncode\n```\n").takeFirstLine() == nil)
        #expect(Self.session("![](a.png)\n").takeFirstLine() == nil)
        #expect(text.takeFirstLine() == "And the rest.")
    }

    @Test func arrowsAreMadeAsTheyAreTyped() {
        var session = Self.session("")
        var caret = 0
        for typed in "a -> b <- c, `x -> y`, <!-- no -->" {
            caret = session.replace(caret..<caret, String(typed)).selection.upperBound
        }
        #expect(session.text == "a → b ← c, `x -> y`, <!-- no -->")
        session = Self.session("")
        _ = session.replace(0..<0, "a -> b")
        #expect(session.text == "a -> b")
    }

    @Test func aHeadingAfterBlankLinesIsStillTheTitle() {
        let source = "---\nicon: link\n---\n\n# Cerebras on X\n\n- URL: <https://example.com>\n"
        let session = Self.session(source)
        #expect(session.title() == "Cerebras on X")
        #expect(session.text == "URL: https://example.com")
        #expect(session.markdown() == source)
        session.setTitle("Cerebras")
        #expect(session.markdown() == "---\nicon: link\n---\n\n# Cerebras\n\n- URL: <https://example.com>\n")
    }

    @Test func aNoteOpensAndClosesAsItWasInEitherMode() {
        let session = Self.session(Self.note)
        #expect(session.markdown() == Self.note)
        #expect(session.title() == "Project Atlas")
        #expect(Self.session("").text == "")
        #expect(Self.session("").markdown() == "")
        #expect(Self.session("- a day\n").title() == nil)
    }

    @Test func anOutlineShowsARowABlockAndOnlyItsWords() {
        let session = Self.session(Self.note)
        #expect(session.text == "A paragraph\u{2028}of two lines.\nNext\nBook a room\nask \u{FFFC}\nSend invites\nFirst\ntag: Person")
        let layout = session.layout()
        let t = session.text.u8
        let lines = layout.lines.map { (t.string($0.range), $0.kind, $0.depth) }
        #expect(lines[1] == ("Next", .heading(2), 1))
        #expect(lines[2] == ("Book a room", .item(ordered: nil, task: nil, bullet: "*"), 1))
        #expect(lines[3] == ("ask \u{FFFC}", .item(ordered: nil, task: nil, bullet: "*"), 2))
        #expect(lines[4] == ("Send invites", .item(ordered: nil, task: false, bullet: "+"), 1))
        #expect(lines[5] == ("First", .item(ordered: 1, task: nil, bullet: "."), 1))
        #expect(lines[6].1 == .code)
        #expect(layout.runs.contains { if case .pageLink(let target, _) = $0.kind { return target == "Grace" }; return false })
    }

    @Test func typingInARowChangesThatBlockAndNoOtherByte() {
        var (session, view) = Self.outline(Self.note)
        let at = Self.atEndOf(view, "Book a room")
        var change = session.replace(at..<at, " today")
        Self.shown(&view, change)
        #expect(view == session.text)
        #expect(change.selection == (at + 6)..<(at + 6))
        #expect(session.markdown() == Self.note.replacingOccurrences(of: "*   Book a room", with: "*   Book a room today"))
        change = session.replace(at..<(at + 6), "")
        Self.shown(&view, change)
        #expect(view == session.text && session.markdown() == Self.note)
    }

    @Test func returnSplitsARowIntoTwoOfItsSort() {
        var (session, view) = Self.outline("- one\n- two\n  - under two\n+ [x] done\n")
        var at = Self.atEndOf(view, "one")
        var change = session.perform(at..<at, .newline)!
        Self.shown(&view, change)
        #expect(view == "one\n\ntwo\nunder two\ndone")
        #expect(change.selection == 4..<4)
        #expect(session.markdown() == "- one\n- \n- two\n  - under two\n+ [x] done\n")
        change = session.replace(4..<4, "new")
        Self.shown(&view, change)
        change = session.perform(5..<5, .newline)!
        Self.shown(&view, change)
        #expect(session.markdown() == "- one\n- n\n- ew\n- two\n  - under two\n+ [x] done\n")
        at = Self.atEndOf(view, "two")
        change = session.perform(at..<at, .newline)!
        Self.shown(&view, change)
        #expect(session.markdown() == "- one\n- n\n- ew\n- two\n\n  - \n  - under two\n+ [x] done\n")
        at = Self.len(view)
        _ = session.perform(at..<at, .newline)!
        #expect(session.layout().lines.last!.kind == .item(ordered: nil, task: false, bullet: "+"), "\(session.markdown())")
        let (pasted, _) = Self.outline("- one\n")
        _ = pasted.replace(3..<3, "\ntwo\nthree")
        #expect(pasted.markdown() == "- one\n- two\n- three\n")
    }

    @Test func returnOnAnEmptyRowMakesANewRowOrATypedOnePlain() {
        let (session, _) = Self.outline("- one\n\n  - \n")
        #expect(session.text == "one\n")
        var at = Self.len(session.text)
        _ = session.perform(at..<at, .newline)!
        #expect(session.text == "one\n\n")
        #expect(session.layout().lines[2].depth == 2)
        let (task, _) = Self.outline("- one\n  - [ ] t\n")
        at = Self.len(task.text)
        _ = task.replace((at - 1)..<at, "")
        at = Self.len(task.text)
        _ = task.perform(at..<at, .newline)!
        #expect(task.text == "one\n")
        #expect(task.layout().lines[1].kind == .item(ordered: nil, task: nil, bullet: "-"))
        let (deep, _) = Self.outline("- one\n  - two\n")
        _ = deep.perform(7..<7, .newline)!
        #expect(deep.markdown() == "- one\n  - two\n  - \n")
    }

    @Test func deleteAtARowsStartUnmakesItThenJoinsItToTheRowBefore() {
        var (session, view) = Self.outline("- one\n+ [ ] two\n  - under two\n")
        let at = Self.find(view, "two")!
        var change = session.perform(at..<at, .deleteBackward)!
        Self.shown(&view, change)
        #expect(session.markdown() == "- one\n- two\n  - under two\n")
        change = session.perform(at..<at, .deleteBackward)!
        Self.shown(&view, change)
        #expect(view == "onetwo\nunder two" && change.selection == 3..<3)
        #expect(session.markdown() == "- onetwo\n  - under two\n")
        #expect(session.perform(2..<2, .deleteBackward) == nil)
        #expect(session.perform(0..<0, .deleteBackward) == nil)
        let (across, _) = Self.outline("- alpha\n- beta\n- gamma\n")
        _ = across.replace(3..<13, "")
        #expect(across.markdown() == "- alpmma\n")
    }

    @Test func rowsAreIndentedMovedAndRemovedAsBlocksOfTheTree() {
        var (session, view) = Self.outline("- one\n- two\n  - under two\n- three\n")
        let at = Self.find(view, "two")! + 1
        var change = session.perform(at..<at, .indent)!
        Self.shown(&view, change)
        #expect(session.markdown() == "- one\n  - two\n    - under two\n- three\n")
        #expect(view == session.text && change.selection == at..<at)
        _ = session.perform(at..<at, .outdent)!
        #expect(session.markdown() == "- one\n- two\n  - under two\n- three\n")
        change = session.perform(at..<at, .moveUp)!
        #expect(session.markdown() == "- two\n  - under two\n- one\n- three\n")
        #expect(session.text.u8.string((change.selection.lowerBound - 1)..<(change.selection.lowerBound + 2)) == "two")
        let caret = change.selection.lowerBound
        _ = session.perform(caret..<caret, .moveDown)!
        let two = Self.find(session.text, "two")!
        _ = session.perform(two..<two, .moveDown)!
        #expect(session.markdown() == "- one\n- three\n- two\n  - under two\n")
        #expect(session.perform(0..<0, .indent) == nil)
        #expect(session.perform(0..<0, .moveUp) == nil)
        let both = 0..<(Self.find(session.text, "three")! + 2)
        _ = session.perform(both, .duplicateRows)!
        #expect(session.markdown() == "- one\n- one\n- three\n- three\n- two\n  - under two\n")
        _ = session.perform(0..<0, .deleteRows)!
        #expect(session.markdown() == "- one\n- three\n- three\n- two\n  - under two\n")
    }

    @Test func deleteOrUndoStraightAfterATypedKindGivesTheTypingBack() {
        func typed(_ session: Session) {
            _ = session.replace(0..<0, "#")
            _ = session.replace(1..<1, " ")
        }
        var (session, _) = Self.outline("- words\n")
        typed(session)
        #expect(session.markdown() == "# words\n")
        var change = session.perform(0..<0, .deleteBackward)!
        #expect(session.text == "# words" && change.selection == 2..<2)
        #expect(session.markdown() == "- \\# words\n")
        (session, _) = Self.outline("- words\n")
        typed(session)
        change = session.undo()!
        #expect(session.text == "# words" && change.selection == 2..<2)
        (session, _) = Self.outline("- words\n")
        typed(session)
        _ = session.replace(0..<0, "x")
        _ = session.replace(0..<1, "")
        _ = session.perform(0..<0, .deleteBackward)!
        #expect(session.text == "words")
        #expect(session.layout().lines[0].kind == .paragraph)
    }

    @Test func aMarkerTypedAtARowsStartMakesTheRowThatKind() {
        func typed(_ source: String, _ marker: String) -> String {
            var (session, view) = Self.outline(source)
            var at = 0
            for c in marker + " " {
                let change = session.replace(at..<at, String(c))
                Self.shown(&view, change)
                at = change.selection.upperBound
            }
            #expect(view == session.text)
            return session.markdown()
        }
        #expect(typed("plain\n", "-") == "* plain\n")
        #expect(typed("- item\n", "-") == "* item\n")
        #expect(typed("- item\n", "*") == "* item\n")
        #expect(typed("plain\n", "##") == "## plain\n")
        #expect(typed("plain\n", ">") == "> plain\n")
        #expect(typed("plain\n", "1.") == "1. plain\n")
        #expect(typed("- item\n", "[]") == "- [ ] item\n")
        #expect(typed("- item\n", "+") == "+ [ ] item\n")
        #expect(typed("- item\n", "[x]") == "- [x] item\n")
        #expect(typed("## Title\n", "-") == "## - Title\n")
        let (session, _) = Self.outline("- ab\n")
        _ = session.replace(1..<1, " -")
        _ = session.replace(3..<3, " ")
        #expect(session.markdown() == "- a - b\n")
    }

    @Test func commandsTurnRowsIntoOtherKindsOfRow() {
        let (session, _) = Self.outline("plain\n- item\n")
        _ = session.perform(0..<0, .cycleChecklist)!
        #expect(session.markdown() == "- [ ] plain\n- item\n")
        _ = session.perform(0..<0, .cycleChecklist)!
        _ = session.perform(0..<0, .cycleChecklist)!
        #expect(session.markdown() == "- plain\n- item\n")
        _ = session.perform(0..<0, .toggleTask)!
        #expect(session.markdown() == "+ [ ] plain\n- item\n")
        _ = session.perform(0..<0, .toggleCheckbox)!
        #expect(session.markdown() == "+ [x] plain\n- item\n")
        _ = session.perform(0..<Self.len(session.text), .heading(2))!
        #expect(session.markdown() == "## plain\n## item\n")
        _ = session.perform(0..<0, .heading(2))!
        #expect(session.markdown() == "plain\n## item\n")
        let change = session.perform(0..<5, .toggle(.strong))!
        #expect(session.markdown() == "**plain**\n## item\n" && change.selection == 0..<5)
    }

    @Test func returnAfterAFenceMakesTheRowACodeBlock() {
        var (session, view) = Self.outline("- one\n- two\n")
        var end = Self.len(view)
        Self.shown(&view, session.replace(end..<end, "\n"))
        end = Self.len(view)
        Self.shown(&view, session.replace(end..<end, "```rust"))
        end = Self.len(view)
        let change = session.perform(end..<end, .newline)!
        Self.shown(&view, change)
        #expect(view == "one\ntwo\n")
        let caret = change.selection.lowerBound
        #expect(caret == Self.len(view))
        Self.shown(&view, session.replace(caret..<caret, "let x = 1;"))
        #expect(session.markdown() == "- one\n- two\n```rust\nlet x = 1;\n```\n")
        #expect(session.layout().lines.last?.kind == .code)
        (session, view) = Self.outline("- ``` and `more`\n")
        let done = session.perform(Self.len(view)..<Self.len(view), .newline)
        #expect(!(done != nil && session.markdown().contains("```\n")))
    }

    @Test func aLinkShownAsItsCardIsMarkedSoInTheNote() {
        let note = "- [A page](https://a.example) <!-- card -->\n- plain\n"
        let (session, view) = Self.outline(note)
        #expect(view == "A page\nplain")
        #expect(session.rowCards() == [true, false])
        #expect(session.markdown() == note)
        _ = session.perform(onRows: [0], 0..<0, .toggleCard)!
        #expect(session.markdown() == "- [A page](https://a.example)\n- plain\n" && session.rowCards() == [false, false])
        _ = session.perform(onRows: [0, 1], 0..<0, .toggleCard)!
        #expect(session.markdown() == "- [A page](https://a.example) <!-- card -->\n- plain <!-- card -->\n")
        _ = session.undo()!
        #expect(session.markdown() == "- [A page](https://a.example)\n- plain\n")
        let both = "- [A](https://a.example) <!-- ^k3f9 --> <!-- card --> <!-- folded -->\n  - under\n"
        let (again, _) = Self.outline(both)
        #expect(again.rowCards() == [true] && again.markdown() == both)
    }

    @Test func returnOnACodeBlocksLastLineLeavesIt() {
        var (session, view) = Self.outline("- one\n")
        var end = Self.len(view)
        Self.shown(&view, session.replace(end..<end, "\n```"))
        end = Self.len(view)
        var change = session.perform(end..<end, .newline)!
        Self.shown(&view, change)
        let caret = change.selection.lowerBound
        Self.shown(&view, session.replace(caret..<caret, "foobar"))
        let at = caret + 6
        change = session.perform(at..<at, .newline)!
        Self.shown(&view, change)
        change = session.perform(change.selection, .newline)!
        Self.shown(&view, change)
        Self.shown(&view, session.replace(change.selection, "after"))
        #expect(session.markdown() == "- one\n```\nfoobar\n```\n- after\n")
        let line = Self.find(view, "after")! - 1
        change = session.perform(line..<line, .newline)!
        Self.shown(&view, change)
        #expect(session.markdown() == "- one\n```\nfoobar\n\n```\n- after\n")
        #expect(view == session.text)
        _ = end
    }

    @Test func deleteAtAnEmptyCodeBlocksStartMakesItItsFenceAgain() {
        var (session, view) = Self.outline("- one\n")
        var end = Self.len(view)
        Self.shown(&view, session.replace(end..<end, "\n```rust"))
        end = Self.len(view)
        Self.shown(&view, session.perform(end..<end, .newline)!)
        let start = Self.len(view)
        let change = session.perform(start..<start, .deleteBackward)!
        Self.shown(&view, change)
        #expect(session.markdown() == "- one\n- ```rust\n")
        #expect(change.selection == Self.len(view)..<Self.len(view))
    }

    @Test func codeIsOneRowAndALineBreakInItStaysInIt() {
        var (session, view) = Self.outline("- before\n\n```\nlet x = 1;\n```\n")
        let at = Self.find(view, "let x = 1;")! + 10
        var change = session.perform(at..<at, .newline)!
        Self.shown(&view, change)
        change = session.replace(change.selection, "let y = 2;")
        Self.shown(&view, change)
        #expect(view == session.text)
        #expect(session.markdown() == "- before\n\n```\nlet x = 1;\nlet y = 2;\n```\n")
    }

    @Test func theFirstWordsInAnEmptyNoteMakeItsFirstRow() {
        var (session, view) = Self.outline("---\ntags: [a]\n---\n# Title\n\n")
        let change = session.replace(0..<0, "hello")
        Self.shown(&view, change)
        #expect(view == "hello" && change.selection == 5..<5)
        #expect(session.markdown() == "---\ntags: [a]\n---\n# Title\n\n- hello\n")
    }

    @Test func aTitleAndFieldsAreTheNotesOwn() {
        let session = Self.session("- no title yet\n")
        session.setTitle("  Atlas ")
        session.changeFrontmatter { $0.set("pinned", "true") }
        #expect(session.markdown() == "---\npinned: true\n---\n# Atlas\n\n- no title yet\n")
        session.setTitle("Atlas Reborn")
        session.changeFrontmatter { $0.remove("pinned") }
        session.dropEmptyFrontmatter()
        #expect(session.markdown() == "# Atlas Reborn\n\n- no title yet\n")
        #expect(session.title() == "Atlas Reborn")
    }

    @Test func theLeastChangeIsWhatAViewIsAskedToMake() {
        func diff(_ a: String, _ b: String) -> (Range<Int>, String) { Markup.difference(a.u8, b.u8) }
        #expect(diff("one\ntwo", "one\nnew\ntwo") == (4..<4, "new\n"))
        #expect(diff("café au lait", "café noir") == (6..<13, "noir"))
        #expect(diff("same", "same") == (4..<4, ""))
        #expect(diff("", "all new") == (0..<0, "all new"))
        #expect(diff("é", "è") == (0..<2, "è"))
    }

    @Test func undoPutsTheTreeBackStructureAndAll() {
        var (session, view) = Self.outline("- one\n- two\n")
        var change = session.perform(5..<5, .indent)!
        Self.shown(&view, change)
        #expect(session.markdown() == "- one\n  - two\n")
        change = session.undo()!
        Self.shown(&view, change)
        #expect(session.markdown() == "- one\n- two\n" && change.selection == 5..<5)
        change = session.redo()!
        Self.shown(&view, change)
        #expect(session.markdown() == "- one\n  - two\n")
        for (at, c) in "new".enumerated() {
            Self.shown(&view, session.replace((3 + at)..<(3 + at), String(c)))
        }
        _ = session.replace(6..<6, " ")
        _ = session.replace(7..<7, "x")
        #expect(session.text == "onenew x\ntwo")
        _ = session.undo()
        _ = session.undo()
        #expect(session.text == "onenew\ntwo")
        _ = session.undo()
        #expect(session.text == "one\ntwo")
        #expect(session.canRedo)
        #expect(session.perform(0..<0, .indent) == nil)
        _ = session.replace(0..<0, "z")
        #expect(!session.canRedo)
        while session.undo() != nil {}
        #expect(session.markdown() == "- one\n- two\n")
    }

    @Test func aFoldedRowShowsNoneOfWhatIsUnderIt() {
        var (session, view) = Self.outline(Self.tree)
        let caret = Self.find(view, "deep")! + 2
        let change = Self.on(session, &view, ["two"], caret, .fold)!
        #expect(view == "one\ntwo\nthree")
        #expect(change.selection == 4..<4)
        #expect(session.markdown() == Self.tree.replacingOccurrences(of: "- two\n", with: "- two <!-- folded -->\n"), "a fold is the note's to remember")
        #expect(session.rowFolds().map { "\($0.0)\($0.1)" } == ["falsefalse", "truetrue", "falsefalse"])
        #expect(session.foldedRows() == [FoldedRow(index: 1, text: "two")])
        let info = session.rowInfo(1)!
        #expect(info.folded && info.hidden == 3 && info.shown == 0 && info.hasChildren && info.canMoveUp && info.canMoveDown)
        #expect(session.perform(0..<0, .fold) == nil)
        Self.shown(&view, session.undo()!)
        #expect(view == "one\ntwo\nunder two\ndeep\nalso under\nthree" && session.foldedRows().isEmpty)
        Self.shown(&view, session.redo()!)
        #expect(view == "one\ntwo\nthree")
        Self.on(session, &view, ["two"], 0, .toggleFold)
        #expect(view == "one\ntwo\nunder two\ndeep\nalso under\nthree")
        #expect(session.perform(4..<4, .unfold) == nil)
    }

    @Test func rowsFoldCompletelyAndAllAtOnce() {
        var (session, view) = Self.outline(Self.tree)
        let info = session.rowInfo(1)!
        #expect(info.openInside && !info.foldsInside && info.shown == 3)
        Self.on(session, &view, ["two"], 0, .foldCompletely)
        #expect(view == "one\ntwo\nthree")
        Self.on(session, &view, ["two"], 0, .unfold)
        #expect(view == "one\ntwo\nunder two\nalso under\nthree")
        #expect(session.rowInfo(1)!.foldsInside)
        Self.on(session, &view, ["two"], 0, .unfoldCompletely)
        #expect(view == "one\ntwo\nunder two\ndeep\nalso under\nthree")
        Self.shown(&view, session.perform(0..<0, .foldAll)!)
        #expect(view == "one\ntwo\nthree" && session.foldedRows().count == 2)
        Self.shown(&view, session.perform(0..<0, .unfoldAll)!)
        #expect(view == "one\ntwo\nunder two\ndeep\nalso under\nthree")
        #expect(session.perform(0..<0, .unfoldAll) == nil)
    }

    @Test func foldsAreKeptByPlaceAndWordsAndFoundAgain() {
        let (session, _) = Self.outline(Self.tree)
        #expect(session.setFoldedRows([FoldedRow(index: 1, text: "two")]))
        #expect(session.text == "one\ntwo\nthree")
        #expect(!session.setFoldedRows([FoldedRow(index: 1, text: "two")]))
        let moved = Self.session("- new\n" + Self.tree)
        #expect(moved.setFoldedRows([FoldedRow(index: 1, text: "two"), FoldedRow(index: 9, text: "gone")]))
        #expect(moved.text == "new\none\ntwo\nthree")
        #expect(moved.foldedRows() == [FoldedRow(index: 2, text: "two")])
        let twins = Self.session("- a\n  - x\n- b\n- a\n  - y\n")
        twins.setFoldedRows([FoldedRow(index: 2, text: "a"), FoldedRow(index: 2, text: "b")])
        #expect(twins.text == "a\nx\nb\na")
        #expect(twins.setFoldedRows([]))
        #expect(twins.text == "a\nx\nb\na\ny")
    }

    @Test func writingGoesOnAroundWhatIsFolded() {
        var (session, view) = Self.outline(Self.tree)
        Self.on(session, &view, ["two"], 0, .fold)
        let at = Self.atEndOf(view, "two")
        Self.shown(&view, session.replace(at..<at, "!"))
        #expect(Self.unmarked(session) == Self.tree.replacingOccurrences(of: "- two", with: "- two!"))
        let change = session.perform((at + 1)..<(at + 1), .newline)!
        Self.shown(&view, change)
        #expect(view == "one\ntwo!\n\nthree" && change.selection == 9..<9)
        #expect(Self.unmarked(session) == "- one\n- two!\n  - under two\n    - deep\n  - also under\n- \n- three\n")
        Self.shown(&view, session.undo()!)
        Self.shown(&view, session.perform((at - 1)..<(at - 1), .newline)!)
        #expect(view == "one\ntw\no!\nthree")
        #expect(Self.unmarked(session) == "- one\n- tw\n  - under two\n    - deep\n  - also under\n- o!\n- three\n")
        Self.shown(&view, session.undo()!)
        #expect(view == "one\ntwo!\nthree")
        Self.shown(&view, session.replace((at + 1)..<(at + 1), "\npasted"))
        #expect(view == "one\ntwo!\npasted\nthree")
        #expect(session.markdown().contains("  - also under\n- pasted\n- three\n"))
        Self.shown(&view, session.undo()!)
        let three = Self.find(view, "three")!
        let joined = session.perform(three..<three, .deleteBackward)!
        Self.shown(&view, joined)
        #expect(view == "one\ntwo!three" && joined.selection == 8..<8)
        #expect(Self.unmarked(session) == "- one\n- two!three\n  - under two\n    - deep\n  - also under\n")
    }

    @Test func returnAtARowsStartOpensARowAboveIt() {
        var (session, view) = Self.outline("- one\n1. first\n   - under\n+ [x] done\n")
        var at = Self.find(view, "first")!
        let change = session.perform(at..<at, .newline)!
        Self.shown(&view, change)
        #expect(view == "one\n\nfirst\nunder\ndone" && view.u8.string(change.selection.lowerBound..<(change.selection.lowerBound + 5)) == "first")
        #expect(session.markdown() == "- one\n1. \n2. first\n   - under\n+ [x] done\n")
        at = Self.find(view, "done")!
        _ = session.perform(at..<at, .newline)!
        #expect(session.markdown().hasSuffix("+ [ ]\n+ [x] done\n"), "\(session.markdown())")
    }

    @Test func aFoldedRowTakesWhatItHidesWhereverItGoes() {
        var (session, view) = Self.outline(Self.tree)
        Self.on(session, &view, ["two"], 0, .fold)
        var caret = Self.find(view, "two")! + 1
        let change = session.perform(caret..<caret, .moveDown)!
        Self.shown(&view, change)
        #expect(view == "one\nthree\ntwo")
        #expect(session.markdown() == "- one\n- three\n- two <!-- folded -->\n  - under two\n    - deep\n  - also under\n")
        caret = change.selection.lowerBound
        Self.shown(&view, session.perform(caret..<caret, .indent)!)
        #expect(Self.unmarked(session) == "- one\n- three\n  - two\n    - under two\n      - deep\n    - also under\n")
        #expect(view == "one\nthree\ntwo")
        Self.shown(&view, session.perform(caret..<caret, .outdent)!)
        Self.shown(&view, session.perform(caret..<caret, .moveToTop)!)
        #expect(view == "two\none\nthree")
        #expect(session.foldedRows() == [FoldedRow(index: 0, text: "two")])
        Self.on(session, &view, ["one"], 0, .indent)
        #expect(view == "two\nunder two\ndeep\nalso under\none\nthree")
        Self.shown(&view, session.undo()!)
        #expect(view == "two\none\nthree")
        Self.shown(&view, session.perform(0..<0, .duplicateRows)!)
        #expect(view == "two\ntwo\none\nthree" && session.body.rows().count == 10)
        Self.shown(&view, session.perform(0..<0, .deleteRows)!)
        Self.shown(&view, session.perform(0..<0, .deleteRows)!)
        #expect(session.markdown() == "- one\n- three\n")
    }

    @Test func aSelectionDeletedAcrossAFoldedRowTakesWhatItHid() {
        var (session, view) = Self.outline(Self.tree)
        Self.on(session, &view, ["two"], 0, .fold)
        let end = Self.len(view) - 3
        Self.shown(&view, session.replace(2..<end, ""))
        #expect(view == "onree" && session.markdown() == "- onree\n")
        (session, view) = Self.outline(Self.tree)
        Self.on(session, &view, ["two"], 0, .fold)
        Self.shown(&view, session.replace(2..<5, ""))
        #expect(view == "onwo\nunder two\ndeep\nalso under\nthree")
        #expect(session.markdown() == "- onwo\n  - under two\n    - deep\n  - also under\n- three\n")
    }

    @Test func rowsPutInJoinedGroupedAndMovedAsBikeDoes() {
        var (session, _) = Self.outline("- alpha\n  - beta\n- delta\n")
        var change = session.perform(2..<2, .insertBelow)!
        #expect(session.markdown() == "- alpha\n  - beta\n- \n- delta\n")
        #expect(change.selection == 11..<11)
        (session, _) = Self.outline("- alpha\n  - beta\n")
        _ = session.perform(2..<2, .insertChild)!
        #expect(session.text == "alpha\n\nbeta")
        (session, _) = Self.outline("- alpha\n  - beta\n")
        _ = session.perform(8..<8, .insertAbove)!
        #expect(session.text == "alpha\n\nbeta")
        (session, _) = Self.outline("- one\n- two\n  - kid\n")
        change = session.perform(1..<1, .joinRows)!
        #expect(session.markdown() == "- one two\n  - kid\n")
        #expect(change.selection == 1..<1)
        (session, _) = Self.outline("- one\n- two\n- three\n")
        change = session.perform(4..<9, .group)!
        #expect(session.text == "one\n\ntwo\nthree")
        #expect(session.layout().lines[2].depth == 2)
        #expect(change.selection == 4..<4)
        (session, _) = Self.outline("- one\n  - two\n  - three\n- four\n")
        change = session.perform(5..<5, .moveUp)!
        #expect(session.markdown() == "- two\n- one\n  - three\n- four\n")
        #expect(change.selection == 1..<1)
        (session, _) = Self.outline("- a\n  - b\n  - c\n  - d\n")
        _ = session.perform(4..<4, .outdent)!
        #expect(session.markdown() == "- a\n  - b\n  - d\n- c\n")
    }

    @Test func foldingByLevelGoesALevelAtATime() {
        let (session, _) = Self.outline("- a1\n  - b1\n    - c1\n  - b2\n- a2\n  - b3\n")
        _ = session.perform(0..<0, .foldByLevel)!
        #expect(session.text == "a1\nb1\nb2\na2\nb3")
        _ = session.perform(0..<0, .foldByLevel)!
        #expect(session.text == "a1\na2\nb3")
        _ = session.perform(0..<0, .unfoldByLevel)!
        #expect(session.text == "a1\nb1\nb2\na2\nb3")
        let (all, _) = Self.outline("- a1\n  - b1\n    - c1\n- a2\n  - b3\n")
        _ = all.perform(0..<0, .foldAllByLevel)!
        #expect(all.text == "a1\nb1\na2\nb3")
        _ = all.perform(0..<0, .foldAllByLevel)!
        #expect(all.text == "a1\na2")
        _ = all.perform(0..<0, .unfoldAllByLevel)!
        #expect(all.text == "a1\nb1\na2\nb3")
    }

    @Test func commandsAreDoneToRowsWhereverTheCaretIs() {
        var (session, view) = Self.outline("- one\n- two\n- three\n- four\n")
        func caret(_ view: String) -> Int { Self.find(view, "four")! + 2 }
        func stays(_ view: String, _ change: Change) {
            #expect(view.u8.string((change.selection.lowerBound - 2)..<(change.selection.lowerBound + 2)) == "four")
        }
        var change = Self.on(session, &view, ["two", "three"], caret(view), .indent)!
        #expect(session.markdown() == "- one\n  - two\n  - three\n- four\n")
        stays(view, change)
        change = Self.on(session, &view, ["one"], caret(view), .moveDown)!
        #expect(session.markdown() == "- four\n- one\n  - two\n  - three\n")
        stays(view, change)
        change = Self.on(session, &view, ["two", "three"], caret(view), .outdent)!
        #expect(session.markdown() == "- four\n- one\n- two\n- three\n")
        stays(view, change)
        Self.on(session, &view, ["one", "three"], 0, .moveToTop)
        #expect(view == "one\nthree\nfour\ntwo")
        Self.on(session, &view, ["one", "three"], 0, .moveToBottom)
        #expect(view == "four\ntwo\none\nthree")
        #expect(Self.on(session, &view, ["one", "three"], 0, .moveToBottom) == nil)
        let at = Self.find(view, "two")! + 1
        change = Self.on(session, &view, ["two", "three"], at, .deleteRows)!
        #expect(view == "four\none" && change.selection == 5..<5)
        #expect(session.perform(onRows: [0], 0..<0, .newline) == nil)
        _ = session
    }

    @Test func rowsAreTurnedAndCheckedTogether() {
        var (session, view) = Self.outline("- plain\n+ [ ] task\n- [x] ticked\n## Head\n- list\n  - [x] a\n  - [ ] b\n\n  - [x] c\n  - d\n")
        Self.on(session, &view, ["plain", "task", "ticked"], 0, .markDone)
        #expect(session.markdown().hasPrefix("- plain\n+ [x] task\n- [x] ticked\n"))
        #expect(Self.on(session, &view, ["plain", "ticked"], 0, .markDone) == nil)
        let info = session.rowInfo(Self.row(session, "list"))!
        #expect(info.hasChecklist && info.doneToMove && info.task == nil)
        Self.on(session, &view, ["list"], 0, .moveDoneToBottom)
        #expect(session.markdown().hasSuffix("- list\n  - [ ] b\n  - d\n\n  - [x] a\n  - [x] c\n"), "\(session.markdown())")
        #expect(!session.rowInfo(Self.row(session, "list"))!.doneToMove)
        #expect(Self.on(session, &view, ["list"], 0, .moveDoneToBottom) == nil)
        Self.on(session, &view, ["task"], 0, .turn(.checkbox))
        Self.on(session, &view, ["ticked"], 0, .turn(.task))
        Self.on(session, &view, ["Head"], 0, .turn(.quote))
        #expect(session.markdown().hasPrefix("- plain\n- [x] task\n+ [x] ticked\n> Head\n"), "\(session.markdown())")
        Self.on(session, &view, ["plain", "task"], 0, .turn(.numbered))
        Self.on(session, &view, ["ticked"], 0, .turn(.heading(2)))
        Self.on(session, &view, ["Head"], 0, .turn(.paragraph))
        #expect(session.markdown().hasPrefix("1. plain\n2. task\n## ticked\nHead\n"), "\(session.markdown())")
        #expect(Self.on(session, &view, ["plain"], 0, .turn(.numbered)) == nil)
        #expect(!session.canRedo)
    }

    @Test func rowsAreCarriedAndPutDownAtADepth() {
        var (session, view) = Self.outline(Self.tree)
        func carry(_ words: String, _ before: String, _ depth: Int) -> String? {
            let rows = [Self.row(session, words)]
            let at = before.isEmpty ? session.layout().lines.count : Self.row(session, before)
            guard let change = session.moveRows(rows, at, depth, 0..<0) else { return nil }
            Self.shown(&view, change)
            #expect(view == session.text)
            return Self.unmarked(session)
        }
        let (three, also) = (Self.row(session, "three"), Self.row(session, "also under"))
        #expect(session.dropDepth([three], also, 0) == 1 && session.dropDepth([three], also, 9) == 3)
        #expect(carry("three", "also under", 0) == "- one\n- two\n  - under two\n    - deep\n  - three\n  - also under\n")
        let (three2, end) = (Self.row(session, "three"), session.layout().lines.count)
        #expect(session.dropDepth([three2], end, 9) == 2 && session.dropDepth([three2], end, 0) == 0)
        #expect(carry("three", "", 2) == "- one\n- two\n  - under two\n    - deep\n  - also under\n    - three\n")
        #expect(carry("three", "", 0) == Self.tree)
        #expect(session.dropDepth([Self.row(session, "two")], Self.row(session, "deep"), 1) == nil)
        #expect(carry("two", "deep", 1) == nil)
        #expect(carry("two", "three", 0) == nil)
        #expect(carry("two", "one", 0) == "- two\n  - under two\n    - deep\n  - also under\n- one\n- three\n")
        #expect(carry("three", "under two", 5) == "- two\n  - three\n  - under two\n    - deep\n  - also under\n- one\n")
        _ = session.perform(onRows: [0], 0..<0, .fold)!
        view = session.text
        #expect(session.dropDepth([1], 2, 5) == 0)
        #expect(session.dropDepth([0], 9, 0) == 0)
        #expect(carry("one", "", 5) == nil)
        #expect(carry("one", "two", 3) == "- one\n- two\n  - three\n  - under two\n    - deep\n  - also under\n")
        var (gaps, gapView) = Self.outline("- a\n\n- b\n- c\n")
        let change = gaps.moveRows([1], 3, 0, 2..<2)!
        Self.shown(&gapView, change)
        #expect(gaps.markdown() == "- a\n\n- c\n- b\n" && gapView.u8.string(change.selection.lowerBound..<Self.len(gapView)) == "b")
        _ = gaps.undo()!
        #expect(gaps.markdown() == "- a\n\n- b\n- c\n")
        _ = gaps
    }

    @Test func rowsFromElsewhereArePutDownAtAPlace() {
        var (session, view) = Self.outline("- one\n  - under one\n- two\n")
        let two = Self.row(session, "two")
        #expect(session.dropDepth([], two, 5) == 2 && session.dropDepth([], two, 1) == 1)
        let change = session.insertRows("- [ ] carried <!-- ^c1 -->\n  - with it\n- and another\n", two, 1, 0..<0)!
        Self.shown(&view, change)
        #expect(view == "one\nunder one\ncarried\nwith it\nand another\ntwo")
        let carried = Self.find(view, "carried")!
        #expect(change.selection == carried..<carried)
        #expect(session.markdown() == "- one\n  - under one\n  - [ ] carried <!-- ^c1 -->\n    - with it\n  - and another\n- two\n")
        let end = session.layout().lines.count
        Self.shown(&view, session.insertRows("- last <!-- ^c1 -->\n", end, 0, 0..<0)!)
        #expect(session.markdown().hasSuffix("- two\n- last\n"))
        let (empty, _) = Self.outline("")
        _ = empty.insertRows("- a\n- b\n", 0, 0, 0..<0)!
        #expect(empty.markdown() == "- a\n- b\n")
        _ = empty.undo()!
        #expect(empty.markdown() == "")
        _ = session
    }

    @Test func rowsAreCopiedAsMarkdownOfTheirOwn() {
        let (session, _) = Self.outline(Self.tree)
        #expect(session.markdownOf([2, 3, 5]) == "- under two\n  - deep\n- three\n")
        _ = session.perform(onRows: [1], 0..<0, .fold)!
        #expect(session.markdownOf([1]) == "- two\n  - under two\n    - deep\n  - also under\n")
        #expect(session.markdownOf([]) == "")
    }

    @Test func aPictureIsOneCharacterAndAnAddressLinksWords() {
        let (session, view) = Self.outline("- see ![cat](assets/cat.png) <!-- {\"width\":40} --> there\n- ![](a.png) ![](b.png)\n")
        let firstLine = view.u8.split(byte: .newline)[0].string
        #expect(firstLine.unicodeScalars.filter { $0 == "\u{FFFC}" }.count == 1)
        let at = Self.find(view, "\u{FFFC}")!
        _ = session.replace(at..<(at + 3), "")
        #expect(!session.markdown().contains("cat.png") && !session.markdown().contains("width"), "\(session.markdown())")
        #expect(session.perform(2..<2, .deleteBackward) == nil, "inside a row, Delete is the view's own")
        let change = session.link(0..<3, " https://example.com/a(b)\n")!
        #expect(session.markdown().hasPrefix("- [see](https://example.com/a%28b%29)"), "\(session.markdown())")
        #expect(session.text.hasPrefix("see "), "the view shows the words, not the link")
        #expect(change.selection == 3..<3)
        _ = session.link(1..<2, "mailto:ada@example.com")!
        #expect(session.markdown().hasPrefix("- [see](mailto:ada@example.com)"))
        #expect(session.link(0..<Self.len(session.text), "https://example.com") == nil, "not across rows")
        #expect(session.link(0..<2, "not an address") == nil)
        #expect(session.link(3..<3, "https://example.com") == nil)
        _ = session.undo()!
        #expect(session.markdown().hasPrefix("- [see](https://example.com/a%28b%29)"))
    }

    /// A row as the outline has it, the body row's two forms one.
    static func shape(_ session: Session) -> [String] {
        session.body.rows().map { row in
            let block = row.block
            let cls: String
            if block.isBodyRow {
                cls = "body"
            } else if case .item(let item) = block.kind {
                var ordered = false
                if case .ordered = item.marker { ordered = true }
                cls = "item \(ordered) \(item.task != nil)"
            } else {
                cls = "\(block.kind)"
            }
            return "\(row.depth) \(cls) \(Markup.wordsOf(block).text)"
        }
    }

    @Test func aParagraphAndADashAreOneRowWrittenTwoWays() {
        let sources = ["", "Para one\n\nPara two\n", "# H\n\nPara\n\n- a\n  - b\n- c\n\nEnd.\n", "- one\n\n  more of one\n- two\n", "Para\n\n1. x\n2. y\n",
                       "- [ ] task\n  + [x] done\n\nPara\n\n## Sub\n\nLast words.\n", "> quoted\n\nPara\n\n```rust\nlet x = 1;\n```\n\n- after\n"]
        let commands: [Command] = [.newline, .indent, .outdent, .insertBelow, .insertAbove, .insertChild, .deleteBackward, .moveUp, .moveDown, .joinRows, .promoteChildren]
        var seed: UInt64 = 7
        func next(_ below: Int) -> Int {
            seed = seed &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return Int((seed >> 33) % UInt64(max(below, 1)))
        }
        for source in sources {
            for prose in [false, true] {
                for _ in 0..<150 {
                    let session = Self.session(source)
                    session.setProse(prose)
                    for _ in 0..<20 {
                        var at = next(Self.len(session.text) + 1)
                        while !session.text.u8.isBoundary(at) { at -= 1 }
                        if next(3) == 0 {
                            _ = session.replace(at..<at, ["w", " ", "w "][next(3)])
                        } else {
                            _ = session.perform(at..<at, commands[next(commands.count)])
                        }
                    }
                    let written = session.markdown()
                    let again = Self.session(written)
                    #expect(Self.shape(again) == Self.shape(session), "\(source.debugDescription) prose \(prose), written:\n\(written)")
                    #expect(again.markdown() == written)
                }
            }
        }
    }

    @Test func proseIsHowANoteIsShownAndWhatRowsAreWrittenAs() {
        #expect(Self.session("# Essay\n\nOne thought.\n\nAnother.\n\n- a point\n").readsAsProse)
        #expect(!Self.session("- one\n- two\n\nA line.\n").readsAsProse)
        #expect(!Self.session("").readsAsProse)
        var session = Self.session("First.\n\n- listed\n")
        session.setProse(true)
        _ = session.perform(6..<6, .newline)!
        _ = session.replace(7..<7, "Second.")
        var end = Self.len(session.text)
        _ = session.perform(end..<end, .newline)!
        _ = session.replace((end + 1)..<(end + 1), "Third.")
        #expect(session.markdown() == "First.\n\nSecond.\n\n- listed\n\nThird.\n")
        session.setProse(false)
        end = Self.len(session.text)
        _ = session.perform(end..<end, .newline)!
        _ = session.replace((end + 1)..<(end + 1), "Fourth.")
        #expect(session.markdown().hasSuffix("Third.\n\nFourth.\n"))
        session = Self.session("Para\n\nNext\n")
        session.setProse(true)
        _ = session.perform(5..<5, .indent)!
        #expect(session.markdown() == "- Para\n  - Next\n")
        #expect(Self.session(session.markdown()).text == session.text)
        _ = session.perform(5..<5, .outdent)!
        #expect(session.markdown() == "Para\n\nNext\n")
    }
}
