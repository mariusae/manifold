import AppKit
import ManifoldCore

// MARK: Status, one rule (§3.7)
//
// Every surface — a tile's bar, a card, a sidebar row, a space's square,
// the switcher, a pill, a menu, the Dock — asks `StatusGlyph.look(of:)`.
// A terminal's, an agent's, a file's is its own; a thread's and a space's
// are made here, of others' — and many made one by `StatusGlyph.strongest`,
// the one ranking.

extension Hosts {
    /// The agents at work on a thread now: each asked there whose turn
    /// since is still going — until it ends, not until it first says
    /// something back (a reply along the way doesn't end it).
    func agentsAtWork(on t: Block) -> [BlockID] {
        guard let th = t.thread else { return [] }
        var asked: [BlockID: Stamp] = [:]
        for e in th.entries { if case let .asked(a, _) = e.kind { asked[a] = e.at } }
        return asked.compactMap { a, at -> BlockID? in
            guard let b = block(a), b.statusState == .working || b.statusState == .blocked else { return nil }
            // Its turn since it was asked: the first begun after (a few
            // seconds' slack: the ask's noted as it's typed in).
            guard let turns = b.terminal?.turns, !turns.isEmpty else {
                // No turns to go by: at work on it while asked here last.
                if case .asked? = th.entries.last?.kind { return a }
                return nil
            }
            guard let since = turns.first(where: { $0.began.wall >= at.wall - 5000 }) else {
                // Not begun yet by its record (a transcript a moment behind): its
                // last turn running, begun before the ask, is something else.
                return nil
            }
            return since.isRunning ? a : nil
        }
        .sorted { $0.description < $1.description }
    }
}

extension MainWindowController {
    /// Threads' and spaces' looks, made here for every surface.
    func installStatusRule() {
        StatusGlyph.composite = { [weak self] b in self?.compositeLook(b) }
    }

    private func compositeLook(_ b: Block) -> StatusGlyph.Look? {
        switch b.kind {
        case .thread: threadLook(b)
        case .arrangement: hosts.arrangement(b.id).flatMap { spaceStatus($0, space: b.id) }
        default: nil
        }
    }

    /// The agents a thread's asks wait on: asked there, at something else first.
    func queuedAgents(on thread: BlockID) -> [BlockID] {
        var out: [BlockID] = []
        for a in threadUI.asks where a.threads.contains(thread) && !out.contains(a.agent) { out.append(a.agent) }
        return out
    }

    /// A thread's status: its agents' at work on it (working, or needing
    /// you for it), something in it not seen, an ask waiting its turn —
    /// the most pressing.
    func threadLook(_ t: Block) -> StatusGlyph.Look? {
        let agents = hosts.agentsAtWork(on: t).map { StatusGlyph.look(of: hosts.block($0)) }
        let unseen: StatusGlyph.Look? = hosts.unseen(t).isEmpty ? nil : .unseen
        let queued: StatusGlyph.Look? = queuedAgents(on: t.id).isEmpty ? nil : .queued
        return StatusGlyph.strongest(agents + [unseen, queued])
    }

    /// A space's status: the most pressing of its tiles' (docked too) and
    /// its threads'.
    func spaceStatus(_ a: ArrangementState, space: BlockID? = nil) -> StatusGlyph.Look? {
        var ids = Set<BlockID>()
        var looks: [StatusGlyph.Look?] = []
        for p in a.placements where ids.insert(p.block).inserted {
            looks.append(StatusGlyph.look(of: hosts.block(p.block)))
        }
        if let space {
            for t in hosts.threads(inSpace: space) where ids.insert(t.id).inserted && t.thread?.resolved != true {
                looks.append(StatusGlyph.look(of: t))
            }
        }
        return StatusGlyph.strongest(looks)
    }

    /// What the Dock's badge counts: what can't go on without you — a
    /// tile needing you or failed and not read, a thread with something
    /// not seen; not every turn that finished (its dot says it).
    func waitingCount() -> Int {
        var n = 0
        for b in hosts.blocks {
            switch b.kind {
            case .thread: if !hosts.unseen(b).isEmpty { n += 1 }
            case .arrangement: continue
            default:
                switch StatusGlyph.look(of: b) {
                case .needsYou?, .failed(read: false)?: n += 1
                default: break
                }
            }
        }
        return n
    }

    /// An agent shown as its conversation that comes to need you — what
    /// it asks is answered in its terminal — turned to its terminal, at
    /// once, not told to go there; and back to its conversation once it's
    /// on again (unless turned by hand meanwhile). Not while something's
    /// being written in its composer.
    func turnToTerminalsWhenNeeded() {
        guard let a = arrangement else { return }
        for p in a.placements {
            guard let b = hosts.block(p.block), b.agent != nil else { continue }
            let blocked = b.statusState == .blocked
            if blocked, p.lens == .thread, let c = views[p.id] as? AgentConversationView, let at = b.statusRecord?.at, turnedFor[b.id] != at {
                guard c.composer.string.isEmpty else { continue }
                turnedFor[b.id] = at
                turnedToTerminal.insert(b.id)
                DispatchQueue.main.async { [weak self] in self?.toggleConversation(p.id) }
            } else if !blocked, turnedToTerminal.remove(b.id) != nil, p.lens != .thread, views[p.id] is TerminalView {
                DispatchQueue.main.async { [weak self] in self?.toggleConversation(p.id) }
            }
        }
    }
}
