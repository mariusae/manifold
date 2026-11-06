import Foundation
import Testing
@testable import ManifoldCore

@Test func aGitLogIsReadWithEachCommitsNameForTheFile() {
    let r = "\u{1e}", f = "\u{1f}"
    let out = "\(r)aaa\(f)Ann\(f)200\(f)renamed it\n\nb.txt\n\(r)bbb\(f)Bo\(f)100\(f)first\n\na.txt\n"
    let revs = FileHistory.parseLog(.git, out, path: "b.txt", skip: 0)
    #expect(revs.map(\.sha) == ["aaa", "bbb"])
    #expect(revs.map(\.path) == ["b.txt", "a.txt"])
    #expect(revs[0].author == "Ann" && revs[0].at == 200 && revs[0].summary == "renamed it")
}

@Test func aSaplingLogIsReadAndWhatWasSkippedPassedOver() {
    let r = "\u{1e}", f = "\u{1f}"
    let out = "\(r)n3\(f)Ann\(f)300 18000\(f)third\(f)b.txt\n\(r)n2\(f)Ann\(f)200 18000\(f)rename\(f)a.txt\nb.txt\n\(r)n1\(f)Bo\(f)100 0\(f)first\(f)a.txt\n"
    let revs = FileHistory.parseLog(.sapling, out, path: "b.txt", skip: 1)
    #expect(revs.map(\.sha) == ["n2", "n1"])
    #expect(revs[0].at == 200)
    #expect(revs[1].path == "a.txt")
}

@Test func gitBlameIsReadEachLineToItsCommit() {
    let a = String(repeating: "a", count: 40), b = String(repeating: "b", count: 40), z = String(repeating: "0", count: 40)
    let out = """
    \(a) 1 1 1
    author Ann
    author-time 200
    summary second
    filename x
    \tone
    \(b) 2 2 1
    author Bo
    author-time 100
    summary first
    filename x
    \ttwo
    \(a) 3 3
    \tthree
    \(z) 4 4 1
    author Not Committed Yet
    author-time 300
    summary Version of x from x
    \tfour
    """
    let blame = FileHistory.parseBlame(.git, out)
    #expect(blame.commits.map(\.author) == ["Ann", "Bo", "Not Committed Yet"])
    #expect(blame.lines == [0, 1, 0, -1])
    #expect(blame.commits[0].summary == "second" && blame.commits[1].at == 100)
}

@Test func saplingBlameIsReadFromItsJSON() {
    let out = """
    [{"abspath": "b.txt", "lines": [{"date": [200.0, 0], "line": "zero\\n", "node": "n2", "user": "Ann <a@x>"}, {"date": [100.0, 0], "line": "one\\n", "node": "n1", "user": "Bo <b@x>"}, {"date": [200.0, 0], "line": "two\\n", "node": "n2", "user": "Ann <a@x>"}], "path": "b.txt"}]
    """
    let blame = FileHistory.parseBlame(.sapling, out)
    #expect(blame.commits.map(\.author) == ["Ann", "Bo"])
    #expect(blame.lines == [0, 1, 0])
    #expect(blame.commits[1].at == 100)
}

@Test func blameIsCarriedOntoTheTextAsEditedWhatChangedNotCommitted() {
    let blame = BlameLines(commits: [.init(sha: "a", author: "A", at: 1, summary: ""), .init(sha: "b", author: "B", at: 2, summary: "")],
                           lines: [0, 1, 0])
    let carried = FileHistory.carry(blame, from: "one\ntwo\nthree\n", to: "zero\none\nTWO\nthree\nfour\n")
    #expect(carried.lines == [-1, 0, -1, 0, -1])
}
