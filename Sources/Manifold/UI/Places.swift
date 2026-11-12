import AppKit
import ManifoldCore

/// Places (§2.5, §3.11), made one way: every view says what's here as a
/// `Place` (`PaneContent.here`) — its selection, else where it's at — and
/// every outline's item, hit, and row is one too. A reference to a place,
/// a drag of it, a link copied to it, a thread about it are all made of
/// it here: anchored in its block (a file's opened as one), so it keeps
/// leading there as the text changes.
extension MainWindowController {
    /// The anchor a place in a block is at, found among the block's or
    /// minted in its log; a place that's one already, or can't be one yet
    /// (a text not read in, a command not there), as it is.
    func anchor(_ at: Locator, in id: BlockID, unsure: Bool = false) -> Locator {
        guard let b = hosts.block(id), var wanted = wantedAnchor(at, in: b) else { return at }
        if unsure { wanted.unsure = true }
        guard let address = reference(to: wanted, in: id), let f = BlockID.link(address)?.fragment else { return at }
        return .anchor(f)
    }

    func anchor(_ at: Locator?, in id: BlockID) -> Locator? { at.map { anchor($0, in: id) } }

    /// What an anchor for a place would be at, as the block's kind knows
    /// it: a line, the declaration or heading there (else the line); lines,
    /// just those; a stretch, the declaration or heading it names (else
    /// itself); a command; a page. Nil where there's none to make.
    private func wantedAnchor(_ at: Locator, in b: Block) -> Anchor? {
        let readable = b.kind == .text && b.text.map { !$0.isUnread } == true
        switch at {
        case .anchor:
            return nil
        case let .line(n):
            return readable ? Anchoring.anchor(atLine: n - 1, of: b) : nil
        case let .lines(s, e):
            guard readable, let rope = b.text?.text, rope.lineCount > 0 else { return nil }
            let first = max(0, min(s - 1, rope.lineCount - 1)), last = max(first, min(e - 1, rope.lineCount - 1))
            let words = rope.lineText(first).trimmingCharacters(in: .whitespacesAndNewlines)
            return Anchor(id: "", at: .range, range: TextRange(rope.offset(ofLine: first), rope.lineRange(last).end), excerpt: words, name: String(words.prefix(60)))
        case let .range(r):
            return readable ? Anchoring.anchor(range: r, of: b) : nil
        case let .command(n):
            guard let c = b.terminal?.commands?.first(where: { $0.id == n }) else { return nil }
            return Anchor(id: "", at: .command(n), name: String(c.text.prefix(80)))
        case let .page(n):
            return b.kind == .pdf ? Anchor(id: "", at: .page(n), name: "Page \(n)") : nil
        case .cell, .comment:
            return nil
        }
    }

    /// The block a place is in: its own; a file's, the block it opens as
    /// (made if there's none, not placed).
    func block(of p: Place) -> BlockID? {
        switch p.subject {
        case let .block(id): id
        case let .file(host, path): pathBlock(path, isDirectory: false, on: host)?.0
        }
    }

    /// A place as a reference names it, now: its block, and its anchor
    /// (a place that can't be anchored yet, legibly).
    func resolved(_ p: Place) -> (block: BlockID, at: Locator?)? {
        guard let id = block(of: p) else { return nil }
        return (id, p.at.map { anchor($0, in: id, unsure: p.unsure) })
    }

    /// The same, once its text is in: a file's read first (a hit's, a
    /// diff's lines), so it's anchored, not a line number that drifts.
    func resolve(_ p: Place, done: @escaping ((block: BlockID, at: Locator?)?) -> Void) {
        guard let id = block(of: p) else { return done(nil) }
        guard let at = p.at, at.anchorID == nil, hosts.block(id)?.kind == .text || hosts.block(id) == nil else { return done(resolved(p)) }
        hosts.ensureRead(id)
        func when(tries: Int) {
            guard let b = hosts.block(id), let t = b.text, !t.isUnread else {
                guard tries > 0 else { return done((id, at)) }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { when(tries: tries - 1) }
                return
            }
            done((id, anchor(at, in: id, unsure: p.unsure)))
        }
        when(tries: 40)
    }

    /// The same, awaited.
    func resolve(_ p: Place) async -> (block: BlockID, at: Locator?)? {
        await withCheckedContinuation { c in resolve(p) { c.resume(returning: $0) } }
    }

    /// A place's address: `manifold:host/ulid#anchor`.
    func reference(to p: Place) -> String? {
        resolved(p).map { Self.address($0.block, anchor: $0.at?.fragment) }
    }

    /// A place gone to in a block: an anchor where it is now, a command, a
    /// page, a line.
    func goTo(_ at: Locator, in b: BlockID) {
        switch at {
        case let .anchor(id): goToAnchor(id, in: b)
        case let .command(n): goToCommand(n, in: b)
        case let .page(n): goToPlace(.page(n - 1), in: b)
        case let .line(n), let .lines(n, _): goToPlace(.line(n), in: b)
        case let .range(r):
            guard let rope = hosts.block(b)?.text?.text else { return }
            goToPlace(.line(rope.line(at: min(r.start, rope.count)) + 1), in: b)
        case let .cell(id):
            goToCell(id, in: b)
        case let .comment(id):
            goToComment(id, in: b)
        }
    }

    /// A thread's comment gone to: scrolled to and ringed in the chat that
    /// shows the thread (its tile, the overlay), once one does.
    func goToComment(_ id: String, in thread: BlockID, tries: Int = 20) {
        let chats = threadUI.chats.compactMap(\.value).filter { $0.threadID == thread && $0.window != nil && !$0.isHiddenOrHasHiddenAncestor }
        if let chat = chats.first { return chat.reveal(entry: id) }
        guard tries > 0 else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in self?.goToComment(id, in: thread, tries: tries - 1) }
    }

    /// A notebook's cell gone to: its tile's, once it's shown.
    func goToCell(_ id: String, in block: BlockID, tries: Int = 20) {
        if let n = content.views.compactMap({ $0 as? NotebookView }).first(where: { $0.block == block && !$0.isHiddenOrHasHiddenAncestor }) {
            return n.focus(id, atEnd: false)
        }
        guard tries > 0 else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in self?.goToCell(id, in: block, tries: tries - 1) }
    }

    /// A place in a block, as a link names it (an anchor, `line=12`, `page=3`, `command=7`).
    func goTo(_ fragment: String, in b: BlockID) {
        if let at = Locator(fragment: fragment) { goTo(at, in: b) }
    }

    /// What's here in a tile: its view's place (its selection, else where
    /// it's at), else the tile's block itself; nil for what isn't a place
    /// (a space, a thread).
    func here(in placement: PlacementID) -> Place? {
        guard let p = arrangement?.placement(placement), let b = hosts.block(p.block), b.kind != .arrangement, b.kind != .thread else { return nil }
        if let place = views[placement]?.here { return place }
        return Place(block: b.id, title: b.path?.lastPathComponent ?? b.displayTitle)
    }

    /// A place as a thread is about it (§3.12): anchored, with what it was
    /// written against — the lines there (a command's line), unless the
    /// place brought its own (a diff's rows, a past version's lines).
    func threadPlace(_ p: Place, done: @escaping (ThreadPlace?) -> Void) {
        resolve(p) { [weak self] r in
            guard let self, let r else { return done(nil) }
            let b = self.hosts.block(r.block)
            // Its anchor; a notebook's cell, by its id (which keeps as an anchor's would).
            var anchor = r.at?.anchorID
            if case .cell? = r.at { anchor = r.at?.fragment }
            var t = ThreadPlace(block: r.block, anchor: anchor, context: p.context,
                                title: p.title ?? b?.path?.lastPathComponent ?? b?.displayTitle, name: p.name)
            t.diff = p.diff
            t.revision = p.revision
            if let b, let id = r.at?.anchorID, let a = b.anchors?[id] {
                if t.name == nil { t.name = Anchoring.name(of: a) }
                if case let .command(n) = a.at, t.context == nil, let c = b.terminal?.commands?.first(where: { $0.id == n }) {
                    t.context = "$ " + c.text
                } else if let rope = b.text?.text, let (range, _) = Anchoring.locate(a, in: b) {
                    let first = rope.line(at: range.start), last = rope.line(at: max(range.start, range.end))
                    t.line = first + 1
                    if t.context == nil {
                        t.context = (first...min(last, first + 11)).map { rope.lineText($0).trimmingCharacters(in: .newlines) }.joined(separator: "\n")
                    }
                }
            }
            done(t)
        }
    }

    /// A place dragged (§3.11): its block as a thing, at its place in it
    /// (anchored, where it can be now; a file's, once it's dropped), its
    /// name its words — or what's `selected`, put in as words where words
    /// are wanted.
    func dragItem(_ p: Place, selected: String? = nil) -> NSPasteboardItem {
        var t: DragThing
        switch p.subject {
        case let .block(id):
            t = dragThing(id, at: p.at.map { anchor($0, in: id, unsure: p.unsure) }, title: p.name)
        case let .file(host, path):
            t = DragThing(title: p.name ?? path.lastPathComponent, file: .init(host: host, path: path, isDirectory: false), text: path)
            t.at = p.at
            if p.unsure { t.unsure = true }
        }
        if let selected {
            t.text = selected
            t.selection = true
        }
        return Drags.item(t)
    }
}
