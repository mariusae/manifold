import Testing
@testable import ManifoldCore

struct TableTests {
    @Test func readsCellsAlignmentsAndEscapedPipes() throws {
        let table = try #require(Markup.Table.parse("| Name | Born | Note |\n|:-----|-----:|:----:|\n| Ada | 1815 | a \\| b |\n| Grace | 1906 |\n"))
        #expect(table.header == ["Name", "Born", "Note"])
        #expect(table.alignments == [.left, .right, .center])
        #expect(table.rows == [["Ada", "1815", "a | b"], ["Grace", "1906"]])
        #expect(Markup.Table.parse("| not a table |\njust text") == nil)
        #expect(Markup.Table.isSeparator("|---|---|"))
        #expect(!Markup.Table.isSeparator("| a | b |"))
        #expect(!Markup.Table.isSeparator("---"))
    }

    @Test func writesBackWhatReadsTheSame() throws {
        let table = try #require(Markup.Table.parse("|a|b|\n|-|:-:|\n|1|x \\| y|"))
        let written = table.toMarkdown()
        #expect(written == "| a | b |\n| --- | :-: |\n| 1 | x \\| y |")
        #expect(Markup.Table.parse(written) == table)
    }
}
