import Foundation
import Testing
@testable import ManifoldCore

/// prism-markup's rich.rs tests.
struct RichTests {
    typealias Rich = Markup.Rich
    typealias Mark = Markup.Mark

    func round(_ markdown: String) -> String { Rich.parse(markdown).toMarkdown() }

    @Test func wordsAreShownWithoutTheirMarkdown() {
        let rich = Rich.parse("plain **bold** and *it* and `co*de` and [a link](https://x.org) and \\*star")
        #expect(rich.text == "plain bold and it and co*de and a link and *star")
        let marks = rich.runs.map { (rich.bytes.string($0.range), $0.mark) }
        #expect(marks.contains { $0 == ("bold", .strong) })
        #expect(marks.contains { $0 == ("it", .emphasis("*")) })
        #expect(marks.contains { $0 == ("co*de", .code(1)) })
        #expect(marks.contains { $0 == ("a link", .link(target: "https://x.org", title: nil)) })
    }

    @Test func whatIsNotWordsIsOneAtom() {
        let rich = Rich.parse("see [[Ada]] and ![pic](a.png) here")
        #expect(rich.text == "see \u{FFFC} and \u{FFFC} here")
        #expect(rich.toMarkdown() == "see [[Ada]] and ![pic](a.png) here")
    }

    @Test func markdownWrittenBackReadsTheSame() {
        for markdown in ["plain words", "**bold** and *it* and ***both***", "a [link **bold** inside](u) end", "`code` and ``co`de``",
                         "==hi== and ~~gone~~", "snake_case and 2*3 and a * b", "<https://x.org> and https://bare.example/path_x",
                         "#tag and #another", "line one\nline two", "_under_ score"] {
            let rich = Rich.parse(markdown)
            #expect(Rich.parse(rich.toMarkdown()) == rich, "\(markdown) → \(rich.toMarkdown())")
        }
        #expect(Rich.plain("2*3 and [x] and a_b").toMarkdown() == "2*3 and [x] and a_b")
        #expect(Rich.plain("a *b* c").toMarkdown() == "a \\*b\\* c")
        #expect(Rich.plain("1. one").toMarkdown() == "1\\. one")
        #expect(Rich.plain("# not a heading").toMarkdown() == "\\# not a heading")
        #expect(Rich.plain("- not a bullet").toMarkdown() == "\\- not a bullet")
        #expect(Rich.plain("#tag").toMarkdown() == "#tag")
        #expect(round("**bold**") == "**bold**")
        #expect(round("_under_") == "_under_")
    }

    @Test func typingTakesTheMarksOfTheWordsItJoins() {
        var rich = Rich.parse("a **bold** b")
        rich.replace(6..<6, with: .plain("er"), marks: nil)
        #expect(rich.toMarkdown() == "a **bolder** b")
        rich = Rich.parse("**bold** b")
        rich.replace(0..<0, with: .plain("very "), marks: nil)
        #expect(rich.toMarkdown() == "**very bold** b")
        rich = Rich.parse("[link](u)")
        rich.replace(4..<4, with: .plain(" more"), marks: nil)
        #expect(rich.toMarkdown() == "[link](u) more")
        rich = Rich.parse("a **bold** b")
        rich.replace(6..<6, with: .plain("x"), marks: [])
        #expect(rich.toMarkdown() == "a **bold**x b")
    }

    @Test func deletingKeepsTheMarksAround() {
        var rich = Rich.parse("a **bold** b")
        rich.replace(3..<5, with: Rich(), marks: nil)
        #expect(rich.toMarkdown() == "a **bd** b")
        rich = Rich.parse("a **bold** b")
        rich.replace(2..<6, with: Rich(), marks: nil)
        #expect(rich.toMarkdown() == "a  b")
        rich = Rich.parse("x [[Ada]] y")
        rich.replace(2..<5, with: Rich(), marks: nil)
        #expect(rich.toMarkdown() == "x  y")
    }

    @Test func stylesToggleOnAndOff() {
        var rich = Rich.plain("one two three")
        rich.toggle(4..<7, .strong)
        #expect(rich.toMarkdown() == "one **two** three")
        rich.toggle(4..<7, .strong)
        #expect(rich.toMarkdown() == "one two three")
        rich.toggle(0..<7, .emphasis("*"))
        rich.toggle(4..<13, .strong)
        #expect(Rich.parse(rich.toMarkdown()).sameAs(rich), "\(rich.toMarkdown())")
        rich = Rich.plain("one two three")
        rich.toggle(3..<8, .strong)
        #expect(rich.toMarkdown() == "one **two** three")
    }

    @Test func splitAndJoin() {
        var rich = Rich.parse("a **bold** b")
        let tail = rich.splitOff(4)
        #expect(rich.toMarkdown() == "a **bo**")
        #expect(tail.toMarkdown() == "**ld** b")
        rich.append(tail)
        #expect(rich.toMarkdown() == "a **bold** b")
    }

    @Test func placesMapBothWays() {
        let md = "a **bold** b"
        #expect(Rich.shownOffset(md, 4) == 2)
        #expect(Rich.markdownOffset(md, 2, inside: true) == 4)
        #expect(Rich.markdownOffset(md, 2, inside: false) == 2)
        #expect(Rich.shownOffset(md, 3) == 2)
        #expect(Rich.markdownOffset(md, 6, inside: false) == 8)
        #expect(Rich.markdownOffset(md, 8, inside: false) == md.utf8.count)
    }

    @Test func spacesAtALinesEndsAreKept() {
        for words in [" lead", "  two lead", "trail ", "end  ", " ", "\tindent", "a\n  b ", "say &#32; literally"] {
            let written = Rich.plain(words).toMarkdown()
            #expect(Rich.parse(written).text == words, "\(words.debugDescription) written \(written.debugDescription)")
        }
        #expect(Rich.plain(" a  b ").toMarkdown() == "&#32;a  b&#32;")
        #expect(Rich.plain("a b").toMarkdown() == "a b")
    }

    /// Every row of a graph's notes, read and written back: `RICH_GRAPH=<folder> swift test --filter RichTests`.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["RICH_GRAPH"] != nil))
    func everyRowOfAGraphReadsBackTheSame() throws {
        let root = URL(fileURLWithPath: ProcessInfo.processInfo.environment["RICH_GRAPH"]!)
        var (rows, same, misread) = (0, 0, [(String, String)]())
        let files = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil)
        while let url = files?.nextObject() as? URL {
            if url.lastPathComponent == ".git" { files?.skipDescendants(); continue }
            guard url.pathExtension == "md", let source = try? String(contentsOf: url, encoding: .utf8) else { continue }
            for row in Markup.Document.parse(source).rows() where row.block.hasInlineContent {
                rows += 1
                let rich = Rich.parse(row.block.text)
                let written = rich.toMarkdown()
                if written == row.block.text { same += 1 }
                if !Rich.parse(written).sameAs(rich) { misread.append((row.block.text, written)) }
            }
        }
        print("rows \(rows), written the same \(same), read back differently \(misread.count)")
        for (from, to) in misread.prefix(15) { print("  \(from.debugDescription)\n→ \(to.debugDescription)") }
        #expect(misread.isEmpty)
    }
}
