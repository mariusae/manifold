import Testing
@testable import ManifoldCore

/// prism-markup's editor.rs tests.
struct EditorTests {
    typealias Editor = Markup.Editor

    @Test func aPageIsLookedForAfterAnAt() {
        func at(_ text: String) -> (String, Range<Int>)? {
            guard let found = Editor.completion(text, caret: text.utf8.count), found.kind == .mention else { return nil }
            return (found.typed, found.range)
        }
        #expect(at("see @")! == ("", 4..<5))
        #expect(at("see @acy watson")! == ("acy watson", 4..<15))
        #expect(at("- (@Ada")! == ("Ada", 3..<7))
        #expect(at("mail ada@example") == nil)
        #expect(at("`@decorator") == nil)
        #expect(at("@ada  and") == nil)
        #expect(at("@ada, and") == nil)
        #expect(Editor.completion("@x [[Ad", caret: 7)?.kind == .link)
    }

    @Test func linesKnowWhatTheyAre() {
        let body = "# Title\n\n- one\n  - [x] two\n    more of two\n1. three\n> [!TIP]\n> quoted\n\n```query\ntag: X\n```\n| a |\n---\nplain"
        let layout = Editor.layout(body)
        let b = body.u8
        let kinds = layout.lines.map { (b.string($0.range), $0.kind, $0.depth) }
        let expected: [(String, Markup.LineKind, Int)] = [
            ("# Title", .heading(1), 0), ("", .blank, 0), ("- one", .item(ordered: nil, task: nil, bullet: "-"), 1),
            ("  - [x] two", .item(ordered: nil, task: true, bullet: "-"), 2), ("    more of two", .paragraph, 2),
            ("1. three", .item(ordered: 1, task: nil, bullet: "."), 1), ("> [!TIP]", .quote, 0), ("> quoted", .quote, 0), ("", .blank, 0),
            ("```query", .fence, 0), ("tag: X", .code, 0), ("```", .fence, 0), ("| a |", .table, 0), ("---", .rule, 0), ("plain", .paragraph, 0),
        ]
        #expect(kinds.count == expected.count)
        for (got, want) in zip(kinds, expected) { #expect(got.0 == want.0 && got.1 == want.1 && got.2 == want.2, "\(got)") }
        #expect(b.string(layout.lines[0].content..<layout.lines[0].range.upperBound) == "Title")
        #expect(b.string(layout.lines[3].content..<layout.lines[3].range.upperBound) == "two")
        #expect(b.string(layout.lines[7].content..<layout.lines[7].range.upperBound) == "quoted")
        #expect(layout.line(at: 0) == 0)
        #expect(layout.line(at: b.count) == 14)
    }

    @Test func runsSayWhatToDrawAndWhatToHide() {
        let body = "- [ ] See **[[Ada Lovelace|Ada]]** and #person at <https://x.example> ![cat](assets/cat.png)<!-- {\"width\":40} -->\n## A `code` heading \\*"
        let b = body.u8
        let shown = Editor.layout(body).runs.map { (b.string($0.range), $0.kind) }
        func has(_ text: String, _ kind: Markup.RunKind) { #expect(shown.contains { $0.0 == text && $0.1 == kind }, "\(text) as \(kind)") }
        has("- ", .bullet)
        has("[ ]", .checkbox(done: false))
        has("[[Ada Lovelace|Ada]]", .strong)
        has("Ada", .pageLink(target: "Ada Lovelace", embed: false))
        has("[[Ada Lovelace|", .markup)
        has("]]", .markup)
        has("#person", .tag(name: "person"))
        has("https://x.example", .webLink(url: "https://x.example"))
        has("![cat](assets/cat.png)<!-- {\"width\":40} -->", .image(source: "assets/cat.png", alt: "cat", width: 40, height: nil))
        has("## ", .markup)
        has("code", .code)
        has("\\", .markup)
        #expect(Editor.layout("```\n**not bold** [[not a link]]\n```").runs.isEmpty)
    }

    @Test func whatIsHalfTypedCanBeFinished() {
        func at(_ text: String) -> (Markup.CompletionKind, String, String)? {
            let caret = text.u8.find(byte: UInt8(ascii: "|"))!
            var body = text.u8
            body.remove(at: caret)
            guard let c = Editor.completion(body.string, caret: caret) else { return nil }
            return (c.kind, c.typed, body.string(c.range))
        }
        #expect(at("see [[Ada Lo|")! == (.link, "Ada Lo", "[[Ada Lo"))
        #expect(at("see [[Ada Lo|]] and")! == (.link, "Ada Lo", "[[Ada Lo]]"))
        #expect(at("![[Eng|")! == (.embed, "Eng", "![[Eng"))
        #expect(at("[[|")! == (.link, "", "[["))
        #expect(at("[[Done]] and |") == nil)
        #expect(at("a #per|")! == (.tag, "per", "#per"))
        #expect(at("(#work/de|")! == (.tag, "work/de", "#work/de"))
        #expect(at("a#b|") == nil)
        #expect(at("#|") == nil)
        #expect(at("## Head|") == nil)
        #expect(at("#1|") == nil)
        #expect(at("[[open\nnext|") == nil)
    }
}
