import Testing
@testable import ManifoldCore

private let page = "---\nid: 01jbxk3t6y8q2zp4m9v7c5r0wd\naliases: [Atlas, \"A, B\"]\ntags: [Projects]\n# a comment\nwiki: true\nstatus:   active  # for now\nrelated:\n  - Ada Lovelace\n  - \"[[2026-10-31]]\"\nsummary: |\n  Two lines\n  of text\n---\n# Project Atlas\n"

struct FrontmatterTests {
    @Test func readsScalarsListsAndBlocks() throws {
        let (parsed, body) = Markup.Frontmatter.split(page)
        let front = try #require(parsed)
        #expect(body == "# Project Atlas\n")
        #expect(front.text("id") == "01jbxk3t6y8q2zp4m9v7c5r0wd")
        #expect(front.list("aliases") == ["Atlas", "A, B"])
        #expect(front.list("tags") == ["Projects"])
        #expect(front.flag("wiki"))
        #expect(front.text("status") == "active")
        #expect(front.list("related") == ["Ada Lovelace", "[[2026-10-31]]"])
        #expect(front.text("summary") == "Two lines\nof text\n")
        #expect(front.keys == ["id", "aliases", "tags", "wiki", "status", "related", "summary"])
        #expect(front.get("missing") == nil)
    }

    @Test func writesBackWhatItReadByteForByte() throws {
        for source in [
            page,
            "---\n---\nbody",
            "---  \ntitle: 'It''s'\n...\n",
            "---\r\ntitle: Windows\r\ntags:\r\n- a\r\n- b\r\n---\r\nbody\r\n",
            "---\nweird line without colon\n\nkey: value\n---\n",
        ] {
            let (parsed, body) = Markup.Frontmatter.split(source)
            let front = try #require(parsed, "\(source)")
            #expect(Array((front.description + body).utf8) == Array(source.utf8))
        }
    }

    @Test func aFileWithoutAClosedBlockIsAllBody() {
        for source in ["# Title\n", "---\nnever closed\n", "", "--- not a fence\n---\n", "text\n---\na: b\n---\n", "---\na: b\n---"] {
            let (front, body) = Markup.Frontmatter.split(source)
            #expect(front == nil, "\(source)")
            #expect(Array(body.utf8) == Array(source.utf8))
        }
    }

    @Test func settingRewritesOnlyTheEntrySet() throws {
        var front = try self.front(page)
        front.set("status", "done")
        front.set("wiki", "true") // unchanged: its line is left alone
        front.set("rating", "5")
        let written = front.description
        let header = String(page.dropLast("# Project Atlas\n".count))
        let expected = header
            .replacing("status:   active  # for now", with: "status: done")
            .replacing("  of text\n---\n", with: "  of text\nrating: 5\n---\n")
        #expect(written == expected)
        #expect(written.contains("# a comment\nwiki: true\n"))
    }

    @Test func listsKeepTheirShapeAndValuesAreQuotedWhenTheyMustBe() throws {
        var front = try self.front(page)
        front.set("related", ["Ada Lovelace", "Grace: Hopper"])
        front.set("tags", ["Projects", "a, b", "#x"])
        front.set("note", "line one\nline two")
        front.set("empty", [String]())
        front.set("odd key: here", " padded ")
        let written = front.description
        #expect(written.contains("related:\n  - Ada Lovelace\n  - \"Grace: Hopper\"\n"), "\(written)")
        #expect(written.contains("tags: [Projects, \"a, b\", \"#x\"]\n"), "\(written)")
        #expect(written.contains("note: |-\n  line one\n  line two\n"), "\(written)")
        #expect(written.contains("empty: []\n"))
        #expect(written.contains("\"odd key: here\": \" padded \"\n"))
        // And all of it reads back as it was set.
        let again = try self.front(written)
        #expect(again.list("related") == ["Ada Lovelace", "Grace: Hopper"])
        #expect(again.list("tags") == ["Projects", "a, b", "#x"])
        #expect(again.text("note") == "line one\nline two")
        #expect(again.list("empty") == [])
        #expect(again.text("odd key: here") == " padded ")
    }

    private func front(_ source: String) throws -> Markup.Frontmatter {
        try #require(Markup.Frontmatter.split(source).0)
    }

    @Test func longListsGoAnItemALine() {
        var front = Markup.Frontmatter()
        front.set("tags", (1...5).map { "tag\($0)" })
        #expect(front.description == "---\ntags:\n  - tag1\n  - tag2\n  - tag3\n  - tag4\n  - tag5\n---\n")
    }

    @Test func removingTakesTheEntrysLines() throws {
        var front = try self.front(page)
        let removed = front.remove("related")
        let again = front.remove("related")
        #expect(removed)
        #expect(!again)
        #expect(!front.description.contains("Ada"))
        #expect(front.description.contains("status:   active  # for now\nsummary: |\n"))
    }

    @Test func escapesReadAsYAMLReadsThem() throws {
        let front = try self.front("---\na: \"tab\\there \\u00e9 \\\"q\\\"\"\nb: 'single ''quoted'''\nc: \"runs\n  on\"\nd: >-\n  folded\n  text\n---\n")
        #expect(front.text("a") == "tab\there é \"q\"")
        #expect(front.text("b") == "single 'quoted'")
        #expect(front.text("c") == "runs on")
        #expect(front.text("d") == "folded text")
    }
}
