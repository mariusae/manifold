import AppKit
import Testing
import ManifoldCore
@testable import Manifold

// Editing a comment of yours in a thread's chat.

@MainActor
private final class Chat: ThreadChatDelegate {
    var sent: [String] = []
    var edits: [(entry: String, text: String)] = []
    func threadChat(_ view: ThreadChatView, send text: String) { sent.append(text) }
    func threadChat(_ view: ThreadChatView, resolve: Bool) {}
    func threadChat(_ view: ThreadChatView, follow address: String) {}
    func threadChatOpenTile(_ view: ThreadChatView) {}
    func threadChat(_ view: ThreadChatView, edit entry: String, text: String) { edits.append((entry, text)) }
}

private func at(_ ms: Int64) -> Stamp { Stamp(wall: ms, logical: 0, host: .local) }

@MainActor
private func chat(_ entries: [ThreadEntry]) -> (ThreadChatView, Chat) {
    var b = Block(id: BlockID(host: .local), kind: .thread, created: at(0))
    for e in entries { b.apply(.threadEntry(e), at: e.at) }
    let view = ThreadChatView(frame: NSRect(x: 0, y: 0, width: 360, height: 400))
    let delegate = Chat()
    view.delegate = delegate
    view.threadID = b.id
    var m = ThreadChatModel()
    m.thread = b
    view.show(m)
    return (view, delegate)
}

private func key(_ code: UInt16, _ chars: String) -> NSEvent {
    NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil,
                     characters: chars, charactersIgnoringModifiers: chars, isARepeat: false, keyCode: code)!
}

@MainActor
@Test func aCommentsWordsComeBackAsWrittenReferencesAndAll() {
    let composer = ComposerTextView()
    let markdown = "See [Plan \\] B](manifold:h1/01ABC#a) and [the docs](https://example.org), line 2\nmore"
    composer.fill(markdown: markdown)
    // A reference is a pill again — one piece, drawn as a block's capsule
    // (its name in the picture), its link sent.
    #expect(!composer.string.contains("manifold:"))
    let storage = composer.textStorage!
    var pills: [String] = []
    storage.enumerateAttribute(.mentionLink, in: NSRange(location: 0, length: storage.length)) { v, r, _ in
        if let link = v as? String {
            pills.append(link)
            #expect(r.length == 1 && storage.attribute(.attachment, at: r.location, effectiveRange: nil) != nil)
        }
    }
    #expect(pills == ["[Plan \\] B](manifold:h1/01ABC#a)"])
    #expect(composer.message == markdown)
}

@MainActor
@Test func upInAnEmptyComposerEditsYourLastCommentAndReturnSavesIt() {
    let mine = ThreadEntry(at: at(1), author: .you(machine: "mac"), kind: .comment("Frist thoughts"))
    let theirs = ThreadEntry(at: at(2), author: .agent(block: BlockID(host: .local), name: "Claude", turn: 1), kind: .comment("Noted."))
    let (view, delegate) = chat([mine, theirs])
    view.composer.keyDown(with: key(126, String(UnicodeScalar(NSUpArrowFunctionKey)!)))
    #expect(view.editing == mine.id)
    #expect(view.composer.message == "Frist thoughts")
    view.composer.string = "First thoughts"
    view.composer.keyDown(with: key(36, "\r"))
    #expect(delegate.edits.count == 1)
    #expect(delegate.edits.first?.entry == mine.id && delegate.edits.first?.text == "First thoughts")
    // Saved: not a new comment, and done editing.
    #expect(delegate.sent.isEmpty)
    #expect(view.editing == nil)
}

@MainActor
@Test func escapeLeavesItAsItWasAndWhatYouWereWritingComesBack() {
    let mine = ThreadEntry(at: at(1), author: .you(machine: "mac"), kind: .comment("As it was"))
    let (view, delegate) = chat([mine])
    view.composer.string = "half a reply"
    view.edit(mine.id)
    #expect(view.composer.message == "As it was")
    view.composer.cancelOperation(nil)
    #expect(view.editing == nil)
    #expect(view.composer.string == "half a reply")
    #expect(delegate.edits.isEmpty)
}

@MainActor
@Test func someoneElsesCommentIsntOffered() {
    let theirs = ThreadEntry(at: at(1), author: .agent(block: BlockID(host: .local), name: "Claude", turn: 1), kind: .comment("Mine to change"))
    let (view, _) = chat([theirs])
    view.edit(theirs.id)
    #expect(view.editing == nil)
    // Nor ↑: nothing of yours there.
    view.composer.keyDown(with: key(126, String(UnicodeScalar(NSUpArrowFunctionKey)!)))
    #expect(view.editing == nil)
}
