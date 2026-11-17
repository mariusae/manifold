import Testing
@testable import ManifoldCore

/// prism-markup's block.rs tests.
struct BlockTests {
    typealias Document = Markup.Document
    typealias Block = Markup.Block
    typealias Kind = Markup.BlockKind

    @discardableResult
    func roundTrip(_ source: String) -> Document {
        let document = Document.parse(source)
        #expect(document.toMarkdown().same(source), "round trip of \(source.debugDescription): \(document.toMarkdown().debugDescription)")
        return document
    }

    func kinds(_ document: Document) -> [(Int, Kind, String)] {
        document.rows().map { ($0.depth, $0.block.kind, $0.block.text) }
    }

    @Test func listsNestByIndentation() {
        let document = roundTrip("- one\n  - two\n    - three\n  - four\n- five\n")
        #expect(document.rows().map(\.depth) == [0, 1, 2, 1, 0])
        #expect(document.rows().map(\.block.text) == ["one", "two", "three", "four", "five"])
        #expect(document.blocks.count == 2)
        #expect(document.blocks[0].children.count == 2)
        #expect(document.get([0, 0, 0])?.text == "three")
        #expect(document.get([0, 5]) == nil)
        #expect(!document.rows().contains { $0.block.kind == .raw })
    }

    @Test func everyBlockKindIsReadForWhatItIs() {
        let source = "# Title\n\nA paragraph\nover two lines.\n\n> quoted\n> again\n\n```rust\nfn main() {}\n```\n\n| a | b |\n|---|---|\n| 1 | 2 |\n\n---\n\n1. first\n2) second\n+ [ ] task\n- [x] done\n* star\n"
        let document = roundTrip(source)
        let got = kinds(document)
        #expect(got[0] == (0, .heading(1), "Title"))
        #expect(got[1] == (0, .paragraph, "A paragraph\nover two lines."))
        #expect(got[2] == (0, .quote, "quoted\nagain"))
        #expect(got[3] == (0, .code, "```rust\nfn main() {}\n```"))
        #expect(got[4] == (0, .table, "| a | b |\n|---|---|\n| 1 | 2 |"))
        #expect(got[5] == (0, .rule, "---"))
        #expect(got[6].1 == .item(.init(marker: .ordered(number: 1, delimiter: "."), task: nil)))
        #expect(got[7].1 == .item(.init(marker: .ordered(number: 2, delimiter: ")"), task: nil)))
        #expect(got[8].1 == .item(.init(marker: .bullet("+"), task: .open)))
        #expect(got[9].1 == .item(.init(marker: .bullet("-"), task: .done("x"))))
        #expect(got[10] == (0, .item(.init(marker: .bullet("*"), task: nil)), "star"))
        #expect(document.blocks[3].codeParts! == ("rust", "fn main() {}"))
    }

    @Test func whatIsInsideAListItemIsItsChildren() {
        let document = roundTrip("- item\n\n  A paragraph inside.\n\n  ```\n  code\n  ```\n  - nested\n- next\n")
        let item = document.blocks[0]
        #expect(item.children.count == 3)
        #expect(item.children[0].kind == .paragraph)
        #expect(item.children[1].kind == .code)
        #expect(item.children[1].codeParts?.body == "code")
        #expect(item.children[2].isItem)
    }

    @Test func oddButLegalShapesRoundTrip() {
        for source in [
            "", "\n", "\n\n", "no newline at the end", "- a\n\n\n- b\n\n", "-   wide spacing\n   - odd indent\n", "-\n- \n-  \n",
            "* [X] Capital\n+ [ ]\n+ [ ] \n", "> quote\nlazy line\n>bare\n> \n> end\n", "paragraph\n  indented more\n continuation\n",
            "- item\ncontinues lazily\n  and properly\n", "10. ten\n    - under ten\n", "## \n#\n####### seven is no heading\n",
            "```\nunclosed fence\n\n- not a list\n", "~~~~ info\n```\n~~~~\nafter\n", "- ```\n  in item\n  ```\n", "text\n***\n___\n- - -\n",
            "line one\r\nline two\r\n\r\n- a\r\n  - b\r\n", "   \n\t\ntext\n  \n", "- a\n      deep continuation\n",
            "+ [ ] task\n  more of it\n\n  para child\n", "| a |\n|---|\n| b |\ntrailing text\n\nnext\n", "1. a\n2. b\n3. c\n   continuation\n",
            "# Heading #\n\nSetext\n======\n", "<div>\n  html\n</div>\n",
        ] {
            roundTrip(source)
        }
    }

    @Test func whatCannotBeWrittenBackIsKeptRawBlockByBlock() {
        let document = roundTrip("- fine\n\n- parent\n\t- tabbed child\n\n- also fine\n")
        #expect(document.blocks.count == 3)
        #expect(document.blocks[0].isItem)
        #expect(document.blocks[1].kind == .raw)
        #expect(document.blocks[1].text == "\n- parent\n\t- tabbed child")
        #expect(document.blocks[2].isItem)
        roundTrip("unix\nwindows\r\nunix\n")
        roundTrip("\tindented with a tab\n")
    }

    @Test func codeAndCalloutsHaveParts() {
        let document = Document.parse("> [!TIP]\n> Follow a link.\n\n> plain\n\n````md\n```\ninner\n```\n````\n\n```\n")
        #expect(document.blocks[0].callout! == ("TIP", "Follow a link."))
        #expect(document.blocks[1].callout == nil)
        #expect(document.blocks[2].codeParts! == ("md", "```\ninner\n```"))
        #expect(document.blocks[3].codeParts! == ("", ""))
        #expect(Block.paragraph("x").codeParts == nil)
    }

    @Test func newBlocksAreWrittenCanonically() {
        var document = Document()
        document.blocks.append(.heading(2, "Plan"))
        document.blocks.append(Block.bullet("first").with(children: [.task("sub"), .paragraph("a note")]))
        document.blocks.append(Block.ordered(1, "numbered").with(children: [.bullet("under")]))
        document.blocks.append(.code("md", "```\ninner\n```"))
        document.blocks.append(.quote("said\ntwice"))
        document.blocks.append(.rule())
        let written = document.toMarkdown()
        #expect(written == "## Plan\n- first\n  + [ ] sub\n\n  a note\n1. numbered\n   - under\n````md\n```\ninner\n```\n````\n> said\n> twice\n---\n")
        let again = Document.parse(written)
        #expect(kinds(again).map { "\($0.0) \($0.2)" } == kinds(document).map { "\($0.0) \($0.2)" })
    }

    @Test func aParagraphAfterTextIsKeptApart() {
        var document = Document()
        document.blocks = [.paragraph("one"), .paragraph("two"), .bullet("three"), .paragraph("four")]
        #expect(document.toMarkdown() == "one\n\ntwo\n- three\n\nfour\n")
        #expect(Document.parse(document.toMarkdown()).blocks.count == 4)
    }

    @Test func blankDocumentsAreBlank() {
        #expect(Document.parse("").isBlank)
        #expect(Document.parse("- \n").isBlank)
        #expect(!Document.parse("- [ ] \n").isBlank)
        #expect(!Document.parse("- a\n").isBlank)
        #expect(Document().toMarkdown() == "")
    }

    @Test func editingABlockChangesOnlyItsLines() {
        var document = Document.parse("*   odd bullet\n\n\n1) keep\n   - [X] me\n")
        document.modify([1, 0]) { $0.text = "changed" }
        #expect(document.toMarkdown() == "*   odd bullet\n\n\n1) keep\n   - [X] changed\n")
    }
}
