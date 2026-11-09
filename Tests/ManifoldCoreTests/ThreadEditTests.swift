import Foundation
import Testing
@testable import ManifoldCore

// A comment's words changed by whoever wrote it (`threadEdit`, protocol 71).

private func at(_ ms: Int64) -> Stamp { Stamp(wall: ms, logical: 0, host: .local) }
private let me = ThreadAuthor.you(machine: "mac")
private let otherMac = ThreadAuthor.you(machine: "laptop")
private let claude = ThreadAuthor.agent(block: BlockID(host: .local), name: "Claude", turn: 3)

private func thread(_ entries: [ThreadEntry]) -> Block {
    var b = Block(id: BlockID(host: .local), kind: .thread, created: at(0))
    for e in entries { b.apply(.threadEntry(e), at: e.at) }
    return b
}

@Test func aCommentIsEditedByItsAuthor() {
    let first = ThreadEntry(at: at(1), author: me, kind: .comment("Why does this alocate?"))
    var b = thread([first, ThreadEntry(at: at(2), author: claude, kind: .comment("It copies the rope."))])
    // Yours from another Mac is still yours.
    b.apply(.threadEdit(entry: first.id, text: "Why does this allocate?", by: otherMac, at: at(5)), at: at(5))
    let e = b.thread?.entries.first
    #expect(e?.comment == "Why does this allocate?")
    #expect(e?.edited == at(5))
    #expect(e?.at == at(1))
    // The thread's title follows its first comment's words.
    #expect(b.displayTitle == "Why does this allocate?")
    // No new entry, and nothing unread for it.
    #expect(b.thread?.entries.count == 2)
}

@Test func noOneElsesCommentIsEdited() {
    let theirs = ThreadEntry(at: at(1), author: claude, kind: .comment("It copies the rope."))
    let resolved = ThreadEntry(at: at(2), author: me, kind: .resolved)
    var b = thread([theirs, resolved])
    b.apply(.threadEdit(entry: theirs.id, text: "It doesn't.", by: me, at: at(3)), at: at(3))
    #expect(b.thread?.entries.first?.comment == "It copies the rope.")
    #expect(b.thread?.entries.first?.edited == nil)
    // Nor anything but a comment.
    b.apply(.threadEdit(entry: resolved.id, text: "words", by: me, at: at(4)), at: at(4))
    #expect(b.thread?.entries.last?.kind == .resolved)
}

@Test func anEntryFromBeforeEditsReadsAsOne() throws {
    // As logs written before protocol 71 have it: no `edited`.
    let e = ThreadEntry(at: at(1), author: me, kind: .comment("hi"))
    let data = try JSONEncoder().encode(e)
    #expect(!String(decoding: data, as: UTF8.self).contains("edited"))
    #expect(try JSONDecoder().decode(ThreadEntry.self, from: data) == e)
}
