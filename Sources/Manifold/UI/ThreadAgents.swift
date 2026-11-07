import AppKit
import ManifoldCore

/// Agents in threads (§3.12): asked by a tag (`@claude`, or an agent's
/// pill dropped in), and — once they've written in one — by your comments
/// there; told with a line typed into their terminal when they're idle,
/// else when their turn ends; a thread asks at most three times in a row
/// without you; and handed a set of threads at once (Address These).
extension MainWindowController {
    /// Asks agents don't take while they're at work: waited on.
    struct PendingAsk {
        var agent: BlockID
        var threads: [BlockID]
        var prompt: String
    }

    static let asksInARow = 3

    /// A comment written in a thread (by you, or an agent through mani):
    /// the agents it asks, asked.
    func askAgents(in id: BlockID, comment: String, author: ThreadAuthor, tries: Int = 30) {
        // A thread just made: once it's come.
        guard let t = hosts.block(id), let th = t.thread else {
            guard tries > 0 else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
                self?.askAgents(in: id, comment: comment, author: author, tries: tries - 1)
            }
            return
        }
        var asked: [BlockID] = []
        var starting: [AgentCatalog.Agent] = []
        // Tagged: a pill of an agent's terminal, or a word naming one.
        for m in Mention.find(in: comment) {
            if case .block(let b) = m.target, hosts.block(b)?.agent != nil, b != author.agentBlock { asked.append(b) }
        }
        for word in ThreadText.tags(in: comment) {
            guard let kind = Self.agentKind(word) else { continue }
            if let a = agentFor(kind, near: th), a != author.agentBlock {
                if !asked.contains(a) { asked.append(a) }
            } else if author.isYou {
                starting.append(kind)
            }
        }
        // Following: your comment asks the agents that have written here.
        if author.isYou {
            for a in th.agents where !asked.contains(a.block) && hosts.block(a.block)?.terminal?.pid != nil { asked.append(a.block) }
        }
        guard !asked.isEmpty || !starting.isEmpty else { return }
        // A loop: agents asking agents, with no word from you.
        if !author.isYou, th.asksSinceYou >= Self.asksInARow {
            if case .stopped? = th.entries.last?.kind { return }
            hosts.addToThread(id, .stopped("Asking stopped: \(Self.asksInARow) asks in a row without you — reply to ask again"), author: .manifold)
            return
        }
        let line = prompt(for: t, comment: comment, author: author)
        for a in asked { ask(a, threads: [id], prompt: line) }
        for kind in starting { startAgent(kind, for: t, prompt: line) }
    }

    /// The kind of agent a tag names: `@claude`, `@codex`; `@agent`, the
    /// one Settings name.
    static func agentKind(_ word: String) -> AgentCatalog.Agent? {
        let w = word.lowercased()
        if w == "agent" { return AgentCatalog.agent(inCommand: "claude") }
        return AgentCatalog.known.first { w == $0.command || w == $0.name.lowercased() || $0.name.lowercased().hasPrefix(w) }
    }

    /// An agent of a kind to ask about a thread: one running in the
    /// thread's space, else in the project of what it's about, else any.
    private func agentFor(_ kind: AgentCatalog.Agent, near th: ThreadState) -> BlockID? {
        let running = hosts.blocks.filter { b in
            guard let a = b.agent, a.command == kind.command, b.terminal?.pid != nil, b.terminal?.dormantSince == nil else { return false }
            return true
        }
        guard !running.isEmpty else { return nil }
        if let space = th.space, let a = hosts.arrangement(space) {
            if let b = running.first(where: { r in a.placements.contains { $0.block == r.id } }) { return b.id }
        }
        if let about = th.about?.block, let g = hosts.client(about.host)?.node.graph, let root = g.project(of: about) {
            if let b = running.first(where: { g.project(of: $0.id) == root }) { return b.id }
        }
        return running.first?.id
    }

    /// The line typed into an agent's terminal: which thread, about what,
    /// what was said, and how to answer — on one line.
    private func prompt(for t: Block, comment: String, author: ThreadAuthor) -> String {
        let ref = Self.address(t.id)
        let about = t.thread?.about.map { describe($0).title } ?? "the space"
        let said = comment.replacingOccurrences(of: "\n", with: " ").prefix(400)
        return "[Manifold thread \(ref), about \(about)] \(author.isYou ? "The user" : author.name) wrote: \"\(said)\" — "
            + "read it with `mani thread read \(ref)`, and answer in the thread with `mani thread reply \(ref) \"…\"` (--resolve only if you did what it asks)."
    }

    /// Words typed into an agent's prompt and sent: the words, then
    /// Return a moment after — in one write, an agent's prompt (Claude
    /// Code's) takes it all as a paste, the Return a new line in it.
    func say(_ text: String, to agent: BlockID) {
        hosts.propose(.input(block: agent, text: text))
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            self?.hosts.propose(.input(block: agent, text: "\r"))
        }
    }

    /// An agent asked: now if it's idle, else when its turn ends.
    func ask(_ agent: BlockID, threads: [BlockID], prompt: String) {
        threadUI.asks.append(PendingAsk(agent: agent, threads: threads, prompt: prompt))
        deliverAsks()
    }

    /// Asks waiting on agents now idle: typed in (several to one agent as
    /// one line), and each thread told it asked.
    func deliverAsks() {
        guard !threadUI.asks.isEmpty else { return }
        var waiting: [PendingAsk] = []
        var byAgent: [BlockID: [PendingAsk]] = [:]
        for a in threadUI.asks {
            guard let b = hosts.block(a.agent), b.terminal?.pid != nil else { continue }
            let state = b.statusState
            if state == .working || state == .blocked { waiting.append(a); continue }
            byAgent[a.agent, default: []].append(a)
        }
        threadUI.asks = waiting
        for (agent, asks) in byAgent {
            let text = asks.count == 1 ? asks[0].prompt : asks.map(\.prompt).joined(separator: " — and: ")
            say(text, to: agent)
            let name = hosts.block(agent)?.agent?.name ?? "The agent"
            for id in Set(asks.flatMap(\.threads)) { hosts.addToThread(id, .asked(agent: agent, name: name), author: .manifold) }
        }
    }

    /// No agent of the kind asked for: one started beside, in the folder
    /// of what the thread's about, the thread its first prompt.
    private func startAgent(_ kind: AgentCatalog.Agent, for t: Block, prompt: String) {
        guard let th = t.thread else { return }
        let about = th.about.flatMap { hosts.block($0.block) }
        let host = about?.id.host ?? t.id.host
        guard let client = hosts.client(host) else { return }
        let cwd = about.flatMap { b -> String? in
            if let g = hosts.client(b.id.host)?.node.graph, let root = g.project(of: b.id) { return root }
            return b.place
        }
        let base = kind.command == AgentCatalog.agent(inCommand: desk.settings.agentCommand)?.command ? desk.settings.agentCommand : kind.command
        let command = base + " '" + prompt.replacingOccurrences(of: "'", with: "'\\''") + "'"
        let agent = client.newAgent(cwd: cwd, command: command)
        show(agent, lens: .agent, .beside, context: "asked in a thread")
        hosts.addToThread(t.id, .asked(agent: agent, name: kind.name), author: .manifold)
    }

    // MARK: Address These

    /// Threads handed to an agent at once (§3.12): the agent in the space
    /// (else one started), told to work through them in the threads.
    func addressThreads(_ ids: [BlockID], agent: BlockID? = nil) {
        let threads = ids.compactMap { hosts.block($0) }.filter { $0.thread?.resolved != true }
        guard !threads.isEmpty else { return toast.show("No open threads to hand over", action: "OK", for: 3) {} }
        let list = threads.map { t in Self.address(t.id) + " (" + (t.thread?.about.map { describe($0).title } ?? "the space") + ")" }
        let prompt = "[Manifold] Please address these \(threads.count) open thread\(threads.count == 1 ? "" : "s"): " + list.joined(separator: "; ")
            + ". For each: `mani thread read <ref>`, do what it asks, and reply in it with `mani thread reply <ref> \"…\"` — with --resolve only if you did it; "
            + "a question is a reply left open. Work through them oldest change first, then say briefly here what you did."
        if let a = agent ?? agentForAsking(in: threads[0]) {
            threadUI.asks.append(PendingAsk(agent: a, threads: threads.map(\.id), prompt: prompt))
            deliverAsks()
            toast.show("Handed \(threads.count) thread\(threads.count == 1 ? "" : "s") to \(hosts.block(a)?.displayTitle ?? "the agent")", action: "Show", for: 4) { [weak self] in self?.arrive(a, from: nil) }
        } else if let kind = AgentCatalog.agent(inCommand: desk.settings.agentCommand) ?? AgentCatalog.known.first {
            startAgent(kind, for: threads[0], prompt: prompt)
            for t in threads.dropFirst() { hosts.addToThread(t.id, .asked(agent: threads[0].id, name: kind.name), author: .manifold) }
        }
    }

    /// The agent a thread's handed to: one at work in its space.
    private func agentForAsking(in t: Block) -> BlockID? {
        let space = t.thread?.space ?? selected
        guard let a = space.flatMap({ hosts.arrangement($0) }) else { return nil }
        return a.placements.lazy.compactMap { self.hosts.block($0.block) }.first { $0.agent != nil && $0.terminal?.pid != nil }?.id
    }
}
