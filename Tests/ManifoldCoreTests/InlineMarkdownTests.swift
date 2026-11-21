import Foundation
import Testing
@testable import ManifoldCore

// Markdown on one line (an agent's answer in its summary): its marks set
// as they say, or gone — never shown as asterisks.
@Test func markdownOnOneLineIsSetAsItSays() {
    let s = InlineMarkdown.spans("**f9e55aa (11:07)** reworked the `TilePill`, *quietly*.")
    #expect(s == [.init("f9e55aa (11:07)", bold: true), .init(" reworked the "), .init("TilePill", code: true),
                  .init(", "), .init("quietly", italic: true), .init(".")])
    #expect(InlineMarkdown.plain("See [the doc](https://x.y/z) and ~~old~~ **new**") == "See the doc and old new")
    // A name's underscores, a lone star, a multiplication: words.
    #expect(InlineMarkdown.plain("snake_case_name and 2 * 3 * 4") == "snake_case_name and 2 * 3 * 4")
    #expect(InlineMarkdown.plain("**unclosed bold") == "**unclosed bold")
    #expect(InlineMarkdown.plain("`a ** b` stays") == "a ** b stays")
    #expect(InlineMarkdown.plain(#"\*not italic\*"#) == "*not italic*")
}

@Test func aBlockOfMarkdownFlattensToItsWords() {
    let md = """
    Six commits landed.

    ### Tile bars and agent pills

    - **f9e55aa** reworked the bar:
      1. One centre line.
    > quoted

    | a | b |
    |---|---|
    | 1 | 2 |

    ```swift
    let x = 1
    ```
    ---
    """
    #expect(InlineMarkdown.flattened(md) == "Six commits landed. Tile bars and agent pills **f9e55aa** reworked the bar: One centre line. quoted a · b 1 · 2 let x = 1")
}

@Test func anAgentsAnswerInItsSummaryIsMarkedFormatted() {
    var s = BlockSummary(title: "t", lines: ["asked", "**said**"])
    s.formatted = [1]
    #expect(s.plainLines == ["asked", "said"])
}

@Test func typedQuotesAreSet() {
    #expect(InlineMarkdown.curled(#"it's "quoted" and 'single' (or 'not')"#) == "it’s “quoted” and ‘single’ (or ‘not’)")
}

// A note's outline names a list item by its bold lead-in, as it's written to be.
@Test func aListItemsLeadInIsItsName() {
    #expect(NoteOutlineMarkdown.leadIn("**Tables.** The header is centered") == "Tables")
    #expect(NoteOutlineMarkdown.leadIn("**What they are, in order:** a, b, c") == "What they are, in order")
    #expect(NoteOutlineMarkdown.leadIn("**Only bold**") == nil)
    #expect(NoteOutlineMarkdown.leadIn("Plain **then bold** after") == nil)
    let items = NoteOutlineMarkdown.items(in: "# Typography\n\n- **Tables.** The header is centered.\n- Plain item\n")
    #expect(items.map(\.title) == ["Typography", "Tables", "Plain item"])
}
