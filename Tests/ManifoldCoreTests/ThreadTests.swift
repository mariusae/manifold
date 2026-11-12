import Foundation
import Testing
@testable import ManifoldCore

/// A thread's state from its log (§3.12): entries in order, resolving,
/// who's written, what's not been seen, and the desk's marks.
private func at(_ ms: Int64) -> Stamp { Stamp(wall: ms, logical: 0, host: .local) }

private func thread(_ entries: [(Int64, ThreadAuthor, ThreadEntryKind)]) -> Block {
    var b = Block(id: BlockID(host: .local), kind: .thread, created: at(0))
    b.apply(.threadAbout(ThreadPlace(block: BlockID(host: .local), anchor: "abc123", context: "let x = 1", line: 12, title: "main.swift")), at: at(0))
    for (ms, author, kind) in entries { b.apply(.threadEntry(ThreadEntry(at: at(ms), author: author, kind: kind)), at: at(ms)) }
    return b
}

private let me = ThreadAuthor.you(machine: "mac")
private let claude = ThreadAuthor.agent(block: BlockID(host: .local), name: "Claude", turn: 3)

@Test func threadsResolveAndReopen() {
    var b = thread([(1, me, .comment("Why does this **allocate**?\nMore words.")), (2, claude, .comment("It copies the rope.")), (3, claude, .resolved)])
    #expect(b.thread?.resolved == true)
    #expect(b.displayTitle == "Why does this allocate?")
    #expect(b.thread?.comments.count == 2)
    #expect(b.thread?.lastComment?.author == claude)
    b.apply(.threadEntry(ThreadEntry(at: at(4), author: me, kind: .reopened)), at: at(4))
    #expect(b.thread?.resolved == false)
    // An entry already there (sent twice) is one entry.
    let e = b.thread!.entries[0]
    b.apply(.threadEntry(e), at: at(5))
    #expect(b.thread?.entries.count == 4)
    #expect(b.thread?.agents.map(\.name) == ["Claude"])
}

@Test func whatsNotSeen() {
    let b = thread([(1, me, .comment("Look at this")), (2, .manifold, .edited(added: 1, removed: 0)), (3, claude, .comment("Done")),
                    (4, claude, .comment("And this")), (5, me, .comment("Thanks"))])
    let t = b.thread!
    // An agent's comments, in a thread you're in: news. Yours aren't, nor a place edited.
    #expect(t.unseen(after: nil).map(\.at.wall) == [3, 4])
    #expect(t.unseen(after: at(3)).map(\.at.wall) == [4])
    #expect(t.unseen(after: at(5)).isEmpty)

    var desk = DeskState()
    desk.apply(.threadSeen([b.id: at(3)]))
    #expect(desk.unseen(b).count == 1)
    // Marks only go forward, from whichever Mac.
    desk.apply(.threadSeen([b.id: at(2)]))
    #expect(desk.threadsSeen[b.id] == at(3))
    desk.apply(.threadSeen([b.id: at(9)]))
    #expect(desk.unseen(b).isEmpty)
    // Kept across a save.
    let data = try! JSONEncoder().encode(desk)
    #expect(try! JSONDecoder().decode(DeskState.self, from: data).threadsSeen[b.id] == at(9))
}

// What's news (§3.12): an agent's comment in a thread you're in, or one
// naming you anywhere; nothing in a resolved thread; not a resolve, a
// reopen, or asking stopped.
@Test func onlyWhatsForYouIsNews() {
    // Resolved: quiet, whatever came before it.
    let done = thread([(1, me, .comment("Fix it")), (2, claude, .comment("Fixed")), (3, claude, .resolved)])
    #expect(done.thread!.unseen(after: nil).isEmpty)
    // Reopened by an agent: its comments news again, the reopen not.
    let back = thread([(1, me, .comment("Fix it")), (2, claude, .resolved), (3, claude, .reopened), (4, .manifold, .stopped("Asking stopped"))])
    #expect(back.thread!.unseen(after: nil).isEmpty)
    // Agents asking agents, without you: not news — unless one names you.
    let theirs = thread([(1, claude, .comment("@codex check this")), (2, claude, .comment("Looks fine to me"))])
    #expect(theirs.thread!.unseen(after: nil).isEmpty)
    let named = thread([(1, claude, .comment("@codex check this")), (2, claude, .comment("@user should we ship it?"))])
    #expect(named.thread!.unseen(after: nil).map(\.at.wall) == [2])
    // Started by an agent for you (asking no one): news.
    let forYou = thread([(1, claude, .comment("Is this lock needed?"))])
    #expect(forYou.thread!.unseen(after: nil).map(\.at.wall) == [1])
}

@Test func asksInARow() {
    let a = BlockID(host: .local)
    let b = thread([(1, me, .comment("@claude look")), (2, .manifold, .asked(agent: a, name: "Claude")), (3, claude, .comment("ok")),
                    (4, .manifold, .asked(agent: a, name: "Claude")), (5, .manifold, .asked(agent: a, name: "Claude"))])
    #expect(b.thread?.asksSinceYou == 3)
    let c = thread([(1, .manifold, .asked(agent: a, name: "Claude")), (2, me, .comment("again"))])
    #expect(c.thread?.asksSinceYou == 0)
}

@Test func tagsInAComment() {
    #expect(ThreadText.tags(in: "@claude why does this retry? cc @Codex.") == ["claude", "codex"])
    #expect(ThreadText.tags(in: "mail me at me@example.com") == [])
    #expect(ThreadText.tags(in: "not `@claude` in code, but @claude here, @claude again") == ["claude"])
    #expect(ThreadText.tags(in: "@") == [])
}

@Test func authorsAreTheSame() {
    #expect(ThreadAuthor.you(machine: "a").same(as: .you(machine: "b")))
    #expect(claude.same(as: .agent(block: claude.agentBlock!, name: "Claude", turn: 9)))
    #expect(!claude.same(as: me))
    #expect(me.name == "You" && claude.name == "Claude")
}

@Test func threadsEncodeAndDecode() throws {
    let b = thread([(1, me, .comment("hi")), (2, claude, .asked(agent: claude.agentBlock!, name: "Claude"))])
    let data = try JSONEncoder().encode(b)
    let back = try JSONDecoder().decode(Block.self, from: data)
    #expect(back == b)
    let ev = Event.threadAbout(ThreadPlace(block: b.id, diff: DiffPlace(block: b.id, file: "a.swift", new: true, start: 3, end: 5, commit: "abc")))
    #expect(try JSONDecoder().decode(Event.self, from: JSONEncoder().encode(ev)) == ev)
}
