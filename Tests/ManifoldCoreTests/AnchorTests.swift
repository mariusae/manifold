import Foundation
import Testing
@testable import ManifoldCore
import struct ManifoldCore.TextRange

private let host = HostID("h")
private func at(_ n: Int64) -> Stamp { Stamp(wall: n, logical: 0, host: host) }

/// A text block with `text`, and an anchor over `range` of it.
private func block(_ text: String, anchor range: TextRange) -> Block {
    var b = Block(id: BlockID(host: host), kind: .text, created: at(1))
    b.apply(.content(text, encoding: "utf-8", lineEnding: "\n", fingerprint: nil), at: at(2))
    b.apply(.anchor(Anchor(id: "a1", at: .symbol(path: "f"), range: range, excerpt: "func f()")), at: at(3))
    return b
}

@Test func anAnchorFollowsEditsAroundAndInIt() {
    // "one\nfunc f() {}\n": the anchor on "func f() {}", 4..<15.
    var b = block("one\nfunc f() {}\n", anchor: TextRange(4, 15))
    b.apply(.edit([TextEdit.insert("zero\n", at: 0)]), at: at(4))
    #expect(b.anchors?["a1"]?.range == TextRange(9, 20))
    // Inside it: it grows; after it: nothing moves.
    b.apply(.edit([TextEdit.insert(" ", at: 13)]), at: at(5))
    #expect(b.anchors?["a1"]?.range == TextRange(9, 21))
    b.apply(.edit([TextEdit.insert("tail", at: 22)]), at: at(6))
    #expect(b.anchors?["a1"]?.range == TextRange(9, 21))
    // Typed at its very start: it moves on; at its very end: it doesn't grow.
    b.apply(.edit([TextEdit.insert("x", at: 9)]), at: at(7))
    #expect(b.anchors?["a1"]?.range == TextRange(10, 22))
    b.apply(.edit([TextEdit.insert("y", at: 22)]), at: at(8))
    #expect(b.anchors?["a1"]?.range == TextRange(10, 22))
    // Several edits in one group, in order.
    b.apply(.edit([TextEdit.delete(TextRange(0, 5)), TextEdit.insert("!", at: 0)]), at: at(9))
    #expect(b.anchors?["a1"]?.range == TextRange(6, 18))
}

@Test func anAnchorFollowsTheTextReadAgainAndIsUnsureWhereItChanged() {
    var b = block("one\nfunc f() {}\nthree\n", anchor: TextRange(4, 15))
    // Read again with a line put in above: moved, sure.
    b.apply(.content("zero\none\nfunc f() {}\nthree\n", encoding: "utf-8", lineEnding: "\n", fingerprint: "x"), at: at(4))
    #expect(b.anchors?["a1"]?.range == TextRange(9, 20))
    #expect(b.anchors?["a1"]?.unsure == nil)
    // Read again changed inside it: a guess, to be found again.
    b.apply(.content("zero\none\nfunc g() {}\nthree\n", encoding: "utf-8", lineEnding: "\n", fingerprint: "y"), at: at(5))
    #expect(b.anchors?["a1"]?.unsure == true)
    // Minted again (found again), sure.
    var a = b.anchors!["a1"]!
    a.unsure = nil
    b.apply(.anchor(a), at: at(6))
    #expect(b.anchors?["a1"]?.unsure == nil)
}

@Test func linksBetweenDifferentPlacesOfTwoBlocksAreDifferentLinks() {
    let a = BlockID(host: host), c = BlockID(host: host)
    var links = Links()
    links.apply(.link(Link(from: a, to: c, kind: .linked, at: at(1), toAnchor: "x")))
    links.apply(.link(Link(from: a, to: c, kind: .linked, at: at(2), toAnchor: "y", relation: "describes")))
    links.apply(.link(Link(from: a, to: c, kind: .linked, at: at(3), toAnchor: "x")))
    #expect(links.links.map(\.toAnchor) == ["y", "x"])
    #expect(links.links.first?.relation == "describes")
    // Written before anchors: decoded with none.
    let old = #"{"id":"l","from":"h/A","to":"h/B","kind":"linked","at":{"wall":1,"logical":0,"host":"h"}}"#
    let l = try? JSONDecoder().decode(Link.self, from: Data(old.utf8))
    #expect(l != nil && l?.toAnchor == nil && l?.relation == nil)
}

@Test func aReferenceWithAnAnchorIsAMentionOfThePlace() {
    let m = Mention.find(in: "See [layout](manifold:h/01ABC#k7q2mx) and [line](manifold:h/01ABC#line=3), [again](manifold:h/01ABC#k7q2mx).")
    #expect(m.map(\.anchor) == ["k7q2mx", nil])
    #expect(Anchor.isAnchor("k7q2mx") && !Anchor.isAnchor("line=3"))
}

@Test func anAnchorAtACommandOrAPageIsThatPlace() {
    var t = Block(id: BlockID(host: host), kind: .terminal, created: at(1))
    t.apply(.ran(id: 7, "make test", at: at(2)), at: at(2))
    t.apply(.exited(id: 7, status: 1, at: at(3)), at: at(3))
    t.apply(.anchor(Anchor(id: "c7", at: .command(7), name: "make test")), at: at(4))
    #expect(t.anchors?["c7"]?.legibleFragment == "command=7")
    #expect(t.summary(at: "c7") == t.summary(at: "command=7"))
    #expect(t.summary(at: "c7")?.title == "make test")
    #expect(Anchor(id: "p", at: .page(3)).legibleFragment == "page=3")
    #expect(Anchor(id: "s", at: .symbol(path: "f")).legibleFragment == nil)
}
