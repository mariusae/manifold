import Testing
@testable import ManifoldCore

@Suite struct DiffContextTests {
    // a.txt: lines 1…12, line 5 and line 10 changed.
    let patch = """
    diff --git a/a.txt b/a.txt
    --- a/a.txt
    +++ b/a.txt
    @@ -4,3 +4,3 @@
     4
    -5
    +five
     6
    @@ -9,3 +9,3 @@
     9
    -10
    +ten
     11
    """
    var lines: [String] { (1...12).map { $0 == 5 ? "five" : $0 == 10 ? "ten" : "\\($0)" } }

    @Test func nothingAskedEndsInARowForMore() {
        let (rows, hunks) = DiffRows.withContext(DiffRows.patch(patch), texts: [:], above: [:], below: [:])
        #expect(rows.last == DiffRow(kind: .fold(0), text: "below"))
        #expect(Set(hunks.values) == [4, 9])
    }

    @Test func moreAboveAndBelow() {
        let (rows, _) = DiffRows.withContext(DiffRows.patch(patch), texts: ["a.txt": lines], above: ["a.txt": [4: 20]], below: ["a.txt": 1])
        let numbered = rows.compactMap { $0.kind == .context || $0.kind == .added ? $0.newLine : nil }
        // 1…3 above the first hunk; 12 below the last (11 was its own), then no more to ask for.
        #expect(Array(numbered.prefix(3)) == [1, 2, 3])
        #expect(numbered.last == 12)
        #expect(rows.last?.kind != .fold(0))
        // The first hunk's header now says where its rows begin.
        #expect(rows.first { $0.kind == .hunk }?.newLine == 1)
    }

    @Test func aHunkComingToMeetTheOneBeforeJoinsIt() {
        let (rows, _) = DiffRows.withContext(DiffRows.patch(patch), texts: ["a.txt": lines], above: ["a.txt": [9: 20]], below: [:])
        #expect(rows.filter { $0.kind == .hunk }.count == 1)
        let numbered = rows.compactMap { $0.kind == .removed || $0.kind == .hunk ? nil : $0.newLine }
        #expect(numbered == Array(4...11))
        // Old lines follow along.
        #expect(rows.first { $0.newLine == 7 }?.oldLine == 7)
    }
}
