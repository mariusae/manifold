import Testing
@testable import ManifoldMarkdown

@Test func basics() {
    let html = MarkdownRenderer.html("# Title\n\nSome *text* and `code`.\n")
    #expect(html.contains("<h1>Title</h1>"))
    #expect(html.contains("<em>text</em>"))
    #expect(html.contains("<code>code</code>"))
}

@Test func githubExtensions() {
    let md = """
        | a | b |
        |---|---|
        | 1 | 2 |

        - [x] done
        - [ ] todo

        ~~gone~~ and https://example.com
        """
    let html = MarkdownRenderer.html(md)
    #expect(html.contains("<table>"))
    #expect(html.contains("<td>1</td>"))
    #expect(html.contains("type=\"checkbox\""))
    #expect(html.contains("<del>gone</del>"))
    #expect(html.contains("<a href=\"https://example.com\">"))
}

@Test func codeBlocksKeepTheirLanguage() {
    let html = MarkdownRenderer.html("```swift\nlet x = 1\n```\n")
    #expect(html.contains("<pre lang=\"swift\"><code>let x = 1"))
}

@Test func rawHTMLPassesButScriptsAreFiltered() {
    let html = MarkdownRenderer.html("<details><summary>More</summary>hi</details>\n\n<script>alert(1)</script>\n")
    #expect(html.contains("<details>"))
    #expect(!html.contains("<script>"))
}

@Test func frontMatterIsDropped() {
    let md = "---\ntitle: Notes\ntags: [a]\n---\n# Body\n"
    #expect(MarkdownRenderer.stripFrontMatter(md) == "# Body\n")
    #expect(!MarkdownRenderer.html(md).contains("title:"))
    // A thematic break later on is left alone.
    #expect(MarkdownRenderer.stripFrontMatter("text\n---\nmore") == "text\n---\nmore")
    // An unclosed block is left as it is.
    #expect(MarkdownRenderer.stripFrontMatter("---\nno end") == "---\nno end")
}
