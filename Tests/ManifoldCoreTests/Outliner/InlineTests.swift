import Testing
@testable import ManifoldCore

/// prism-markup's inline.rs tests.
struct InlineTests {
    typealias Inline = Markup.Inline
    typealias K = Markup.SpanKind

    /// Each top-level span as (kind, whole, content).
    func spans(_ text: String) -> [(K, String, String)] {
        let t = text.u8
        return Inline.parse(text).map { ($0.kind, t.string($0.range), t.string($0.content)) }
    }

    func same(_ a: [(K, String, String)], _ b: [(K, String, String)]) -> Bool {
        a.count == b.count && zip(a, b).allSatisfy { $0.0 == $1.0 && $0.1 == $1.1 && $0.2 == $1.2 }
    }

    @Test func emphasisOfEveryKind() {
        #expect(same(spans("**strong** *em* _em_ __strong__ ~~struck~~ ==marked== `code`"), [
            (.strong, "**strong**", "strong"), (.emphasis, "*em*", "em"), (.emphasis, "_em_", "em"), (.strong, "__strong__", "strong"),
            (.strikethrough, "~~struck~~", "struck"), (.highlight, "==marked==", "marked"), (.code, "`code`", "code"),
        ]))
    }

    @Test func whatIsNotEmphasisIsLeftAlone() {
        for text in ["a * b * c", "snake_case_name", "2 * 3 * 4", "** not strong **", "a == b == c", "=======", "<<<<<<< this device",
                     "~~ no ~~", "*unclosed", "`unclosed", "5*3 and 4*2", "a*b*c"] {
            #expect(spans(text).isEmpty, "\(text)")
        }
    }

    @Test func spansNest() {
        let text = "***both*** and **a `code` and [link](u) in** it"
        let parsed = Inline.parse(text)
        #expect(parsed[0].kind == .strong)
        #expect(parsed[0].children[0].kind == .emphasis)
        #expect(text.u8.string(parsed[0].children[0].content) == "both")
        #expect(parsed[1].children.map(\.kind) == [.code, .link(target: "u", title: nil)])
        #expect(Inline.walk(parsed).count == 5)
    }

    @Test func codeHidesEverythingInIt() {
        #expect(same(spans("`**not** [[here]] #tag`"), [(.code, "`**not** [[here]] #tag`", "**not** [[here]] #tag")]))
        #expect(same(spans("``a ` b``"), [(.code, "``a ` b``", "a ` b")]))
        #expect(spans("*a `*` b*")[0].1 == "*a `*` b*")
    }

    @Test func linksOfEveryKind() {
        #expect(same(spans("[text](https://a.example/x) <https://b.example> https://c.example/y. [t](u \"no card\")"), [
            (.link(target: "https://a.example/x", title: nil), "[text](https://a.example/x)", "text"),
            (.autolink(url: "https://b.example"), "<https://b.example>", "https://b.example"),
            (.url, "https://c.example/y", "https://c.example/y"),
            (.link(target: "u", title: "no card"), "[t](u \"no card\")", "t"),
        ]))
        #expect(same(spans("(see https://x.example/a_(b))"), [(.url, "https://x.example/a_(b", "https://x.example/a_(b")]))
        #expect(spans("xhttps://no.example [broken](a b) [](empty)").isEmpty)
    }

    @Test func wikiLinksAndEmbeds() {
        func wiki(_ target: String, _ label: String?, _ embed: Bool) -> K { .wikiLink(target: target, label: label, embed: embed) }
        #expect(same(spans("[[Ada Lovelace]] [[Project Atlas|the project]] ![[Embedded]] [[2026-10-31]] [[A\\|b]]"), [
            (wiki("Ada Lovelace", nil, false), "[[Ada Lovelace]]", "Ada Lovelace"),
            (wiki("Project Atlas", "the project", false), "[[Project Atlas|the project]]", "the project"),
            (wiki("Embedded", nil, true), "![[Embedded]]", "Embedded"),
            (wiki("2026-10-31", nil, false), "[[2026-10-31]]", "2026-10-31"),
            (wiki("A", "b", false), "[[A\\|b]]", "b"),
        ]))
        #expect(spans("[[]] [[ ]] [[a\nb]] [[unclosed").isEmpty)
    }

    @Test func aWikiLinksTargetIsFoundWhereItIsWritten() {
        let text = "[[ Ada ]] ![[Project Atlas|the project]] [[A\\|b]] **bold**"
        let targets = Inline.parse(text).compactMap { Inline.wikiTargetRange(text, $0) }.map { text.u8.string($0) }
        #expect(targets == ["Ada", "Project Atlas", "A"])
    }

    @Test func imagesTakeTheirSizeComment() {
        let text = "![a cat](assets/cat.png)<!-- {\"width\":425,\"height\":270.5} --> ![](https://x.example/p.jpg) <!-- note -->"
        let parsed = Inline.parse(text)
        #expect(parsed[0].kind == .image(source: "assets/cat.png", alt: "a cat", width: 425, height: 270.5))
        #expect(text.u8.string(parsed[0].range) == "![a cat](assets/cat.png)<!-- {\"width\":425,\"height\":270.5} -->")
        #expect(parsed[0].content.isEmpty)
        #expect(parsed[1].kind == .image(source: "https://x.example/p.jpg", alt: "", width: nil, height: nil))
        #expect(parsed[2].kind == .comment)
    }

    @Test func tagsStartAWord() {
        #expect(same(spans("#planning and #work/deep-focus, not a#b or #1 or # x; #ünï"), [
            (.tag("planning"), "#planning", "planning"), (.tag("work/deep-focus"), "#work/deep-focus", "work/deep-focus"), (.tag("ünï"), "#ünï", "ünï"),
        ]))
    }

    @Test func escapesAreLiteral() {
        #expect(same(spans("\\*not em\\* \\[\\[no]]"), [(.escape, "\\*", "*"), (.escape, "\\*", "*"), (.escape, "\\[", "["), (.escape, "\\[", "[")]))
    }

    @Test func plainTextIsWhatIsShown() {
        #expect(Inline.plainText("Kick-off with [[Ada Lovelace|Ada]] on **[[2026-10-31]]** #planning ![x](a.png)<!-- {\"width\":1} --> see [the *docs*](https://d.example) \\* `code`<!-- hidden -->")
                == "Kick-off with Ada on 2026-10-31 #planning  see the docs * code")
        #expect(Inline.plainText("  plain  ") == "plain")
    }

    @Test func togglingPutsAStyleOnAndTakesItOff() {
        let (bold, range) = Inline.toggle("make this bold", 5..<9, .strong)
        #expect(bold == "make **this** bold" && bold.u8.string(range) == "this")
        let (plain, range2) = Inline.toggle(bold, range, .strong)
        #expect(plain == "make this bold" && plain.u8.string(range2) == "this")
        #expect(Inline.toggle("a `b` c", 2..<5, .code).0 == "a b c")
        #expect(Inline.toggle("a **b** c", 4..<5, .emphasis).0 == "a ***b*** c")
        #expect(Inline.toggle("abc", 1..<1, .strong).0 == "abc")
    }

    @Test func multibyteTextIsNeverSplit() {
        for text in ["é*è*ü", "日本語 **太字** #タグ [[ノート]]", "🙂 ==🙃== `🙂`", "\\é *", "“[x](y)”"] {
            let t = text.u8
            for span in Inline.walk(Inline.parse(text)) {
                #expect(t.isBoundary(span.range.lowerBound) && t.isBoundary(span.range.upperBound))
                #expect(t.isBoundary(span.content.lowerBound) && t.isBoundary(span.content.upperBound))
            }
            _ = Inline.plainText(text)
        }
    }
}
