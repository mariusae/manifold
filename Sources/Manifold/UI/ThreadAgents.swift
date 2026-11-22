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
        /// When it was asked: one to an agent not here yet (just made, the
        /// host's word on the way) waits a while for it.
        var made = Date()
    }

    static let asksInARow = 3

    /// Whether an agent is running in its terminal now — what an ask is
    /// typed into: the terminal runs the agent in place of a shell, or its
    /// shell's command running now is the agent's (`claude` typed at a
    /// prompt). An agent that's ended, its shell back, is not asked: what's
    /// typed would run as a command line (backticks and all).
    static func agentRuns(_ b: Block) -> Bool {
        guard let a = b.agent, let t = b.terminal, t.pid != nil else { return false }
        if t.command != nil { return true }
        // Agent prompts are recorded as commands too, nested inside the
        // shell command that launched the agent. A completed turn doesn't
        // mean the agent exited; inspect the latest shell command instead.
        let turns = Set(t.turns?.map(\.id) ?? [])
        guard let running = t.commands?.last(where: { !turns.contains($0.id) }), running.isRunning,
              let program = CommandProgram.program(in: running.text) else { return false }
        return program == a.command || (program as NSString).lastPathComponent == a.command
    }

    // MARK: A project's agents (§3.12)

    /// The project a block is pinned in (§2.6), if one: its block's
    /// `pinned` link to it. An agent pinned in a project is the project's
    /// own — kept by it, asked in its threads.
    func project(pinning id: BlockID) -> Project? {
        for c in hosts.all {
            for e in c.node.graph.edges(to: id, kind: .link(.pinned)) {
                if let p = c.desk.projects.first(where: { $0.block == e.from }) { return p }
            }
        }
        return nil
    }

    /// The project an agent is pinned in, if one.
    func project(holding agent: BlockID) -> Project? { project(pinning: agent) }

    /// What's pinned in a project, in the order pinned.
    func pinned(in project: Project) -> [BlockID] {
        project.block.map { pins(of: $0).map(\.to) } ?? []
    }

    /// The project a block is in, as its host has it.
    func project(of block: BlockID) -> Project? {
        guard let c = hosts.client(block.host), let root = c.node.graph.project(of: block) else { return nil }
        return c.desk.projects.first { $0.root == root }
    }

    /// The project a thread's about: its place's.
    func project(ofThread t: Block) -> Project? {
        t.thread?.about.flatMap { project(of: $0.block) }
    }

    /// A project's agents: those pinned in it, as blocks here.
    func agents(of project: Project, on host: HostID) -> [Block] {
        pinned(in: project).compactMap { hosts.block($0) }.filter { $0.agent != nil }
    }

    /// Whether an agent can be asked: it's running, or it's a project's —
    /// asleep, it's started again where it left off (the host holds what's
    /// typed till it's ready).
    func askable(_ b: Block) -> Bool {
        Self.agentRuns(b) || (b.agent != nil && project(holding: b.id) != nil)
    }

    /// A comment written in a thread (by you, or an agent through mani):
    /// the agents it asks, asked.
    /// `asks`: the thread made the agent's thread (Ask, as it was made).
    /// `agent`: which of its kind it asks, chosen as it was made.
    func askAgents(in id: BlockID, comment: String, author: ThreadAuthor, asks: AgentCatalog.Agent? = nil, agent chosen: BlockID? = nil, tries: Int = 30) {
        // A thread just made: once it's come.
        guard var t = hosts.block(id), t.thread != nil else {
            guard tries > 0 else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
                self?.askAgents(in: id, comment: comment, author: author, asks: asks, agent: chosen, tries: tries - 1)
            }
            return
        }
        if let asks, asksAgent(of: t)?.command != asks.command {
            annotateThread(id, [Self.asksKey: asks.command])
            t.annotations = (t.annotations ?? [:]).merging([Self.asksKey: asks.command]) { $1 }
        }
        if let chosen, participants(of: t).first != chosen {
            setParticipants([chosen] + participants(of: t).filter { $0 != chosen }, of: id)
            t.annotations = (t.annotations ?? [:]).merging([Self.asksAgentKey: chosen.description]) { $1 }
        }
        guard let th = t.thread else { return }
        var asked: [BlockID] = []
        var starting: [AgentCatalog.Agent] = []
        // Tagged: a pill of an agent's terminal, or a word naming one — a
        // participant of that kind first, else one near.
        var parts = participants(of: t)
        for m in Mention.find(in: comment) {
            if case .block(let b) = m.target, hosts.block(b)?.agent != nil, b != author.agentBlock, !asked.contains(b) { asked.append(b) }
        }
        for word in ThreadText.tags(in: comment) {
            guard let kind = Self.agentKind(word, usual: desk.settings.agentCommand) else { continue }
            let mine = parts.first { hosts.block($0)?.agent?.command == kind.command && hosts.block($0).map(askable) == true }
            if let a = mine ?? agentFor(kind, near: th), a != author.agentBlock {
                if !asked.contains(a) { asked.append(a) }
            } else if author.isYou {
                starting.append(kind)
            }
        }
        // Tagged, they're in it from now on (by you, or by an agent bringing
        // in another — a coordinator its worker).
        let invited = asked.filter { !parts.contains($0) }
        if !invited.isEmpty {
            parts += invited
            setParticipants(parts, of: id)
        }
        // Untagged, yours: the thread's participants asked — its lead (the
        // first of them at work), or all of them, as it says — else one of
        // its kind near, made its lead, else one started.
        // With agents on its shelf, a comment that names no one asks the lead
        // (§3.12) — whether or not the thread was made asking.
        if author.isYou, asked.isEmpty, starting.isEmpty, !parts.isEmpty || asksAgent(of: t) != nil {
            let working = parts.filter { hosts.block($0).map(askable) == true }
            if !working.isEmpty {
                asked = asksAll(t) ? working : [working[0]]
            } else if let kind = asksAgent(of: t) ?? parts.compactMap({ hosts.block($0)?.agent }).first {
                if let a = agentFor(kind, near: th) {
                    asked = [a]
                    parts.insert(a, at: 0)
                    setParticipants(parts, of: id)
                } else {
                    starting.append(kind)
                }
            }
        }
        guard !asked.isEmpty || !starting.isEmpty else { return }
        // A loop: agents asking agents, with no word from you.
        if !author.isYou, th.asksSinceYou >= Self.asksInARow {
            if case .stopped? = th.entries.last?.kind { return }
            hosts.addToThread(id, .stopped("Asking stopped: \(Self.asksInARow) asks in a row without you — reply to ask again"), author: .manifold)
            return
        }
        let line = prompt(for: t, comment: comment, author: author)
        for a in asked {
            if author.isYou { AgentRecency.talked(to: a) }
            ask(a, threads: [id], prompt: line)
        }
        for kind in starting { startAgent(kind, for: t, prompt: line) }
    }

    /// The kind of agent a tag names: `@claude`, `@codex`; `@agent`, the
    /// one Settings names (its agent command), else Claude Code.
    static func agentKind(_ word: String, usual: String = "") -> AgentCatalog.Agent? {
        let w = word.lowercased()
        if w == "agent" { return AgentCatalog.agent(inCommand: usual) ?? AgentCatalog.agent(inCommand: "claude") }
        return AgentCatalog.known.first { w == $0.command || w == $0.name.lowercased() || $0.name.lowercased().hasPrefix(w) }
    }

    /// An agent of a kind to ask about a thread: one running in the
    /// thread's space, else in the project of what it's about, else any.
    private func agentFor(_ kind: AgentCatalog.Agent, near th: ThreadState) -> BlockID? {
        // The project's own, of its place (§3.12), the last talked to first.
        if let about = th.about?.block, let p = project(of: about) {
            let own = agents(of: p, on: about.host).filter { $0.agent?.command == kind.command }
            if let b = own.max(by: { AgentRecency.when($0.id) < AgentRecency.when($1.id) }) { return b.id }
        }
        let running = hosts.blocks.filter { b in
            guard let a = b.agent, a.command == kind.command, Self.agentRuns(b), b.terminal?.dormantSince == nil else { return false }
            return true
        }
        guard !running.isEmpty else { return nil }
        // In the space, the first in its grid's order — the same each time.
        if let space = th.space, let a = hosts.arrangement(space) {
            if let b = a.placements.lazy.compactMap({ p in running.first { $0.id == p.block } }).first { return b.id }
        }
        if let about = th.about?.block, let g = hosts.client(about.host)?.node.graph, let root = g.project(of: about) {
            if let b = running.first(where: { g.project(of: $0.id) == root }) { return b.id }
        }
        return running.first?.id
    }

    // MARK: Participants (§3.12)

    /// An agent brought into a thread (its participants' ⌄, a tile dropped
    /// on it): in it from now on, and told — the thread read for what it's
    /// about, not answered till it's asked — so it needn't be primed apart.
    /// An agent brought into a thread's conversation (its shelf, §3.12):
    /// told from then on of everything said there (at its next prompt), the
    /// thread saying it was brought in — not typed to, not interrupted.
    func invite(_ agent: BlockID, to thread: BlockID, author: ThreadAuthor = Hosts.you) {
        guard let t = hosts.block(thread), let b = hosts.block(agent), b.agent != nil else { return }
        var parts = participants(of: t)
        guard !parts.contains(agent) else { return }
        parts.append(agent)
        setParticipants(parts, of: thread)
        if asksAgent(of: t) == nil, let command = b.agent?.command { annotateThread(thread, [Self.asksKey: command]) }
        hosts.addToThread(thread, .context(added: true, address: Self.address(agent), title: AgentLook.name(of: b)), author: author)
    }

    /// Things put on a thread's shelf, by their addresses: an agent into
    /// its conversation, anything else into its context (a reference kept
    /// with it, read with it by those asked) — each said in the thread.
    func addToContext(_ thread: BlockID, _ addresses: [String], author: ThreadAuthor = Hosts.you) {
        guard let t = hosts.block(thread) else { return }
        var refs = shelfReferences(of: t)
        var added: [(String, String)] = []
        for address in addresses {
            if let (id, fragment) = BlockID.link(address), fragment == nil, hosts.block(id)?.agent != nil {
                invite(id, to: thread, author: author)
                continue
            }
            guard !refs.contains(where: { sameShelfItem($0, address) }), address != Self.address(thread) else { continue }
            refs.append(address)
            added.append((address, contextTitle(address)))
        }
        guard !added.isEmpty else { return }
        setShelf(thread, references: refs)
        for (address, title) in added { hosts.addToThread(thread, .context(added: true, address: address, title: title), author: author) }
    }

    /// One taken off a thread's shelf: an agent out of its conversation (no
    /// longer told), a reference out of its context.
    func removeFromContext(_ thread: BlockID, _ address: String, author: ThreadAuthor = Hosts.you) {
        guard let t = hosts.block(thread) else { return }
        let title = contextTitle(address)
        if let (id, _) = BlockID.link(address), participants(of: t).contains(id) {
            setParticipants(participants(of: t).filter { $0 != id }, of: thread)
        } else {
            let refs = shelfReferences(of: t)
            guard refs.contains(where: { sameShelfItem($0, address) }) else { return }
            setShelf(thread, references: refs.filter { !sameShelfItem($0, address) })
        }
        hosts.addToThread(thread, .context(added: false, address: address, title: title), author: author)
    }

    /// Whether two addresses are the same thing on a shelf: the same, or a
    /// file's and its block's (the shelf keeps blocks; a file put there
    /// by its path is its block from then on).
    func sameShelfItem(_ a: String, _ b: String) -> Bool {
        if a == b { return true }
        func file(_ s: String) -> (HostID, String)? {
            if case let .file(h, path, _)? = ManifoldAddress.parse(s) { return (h, path.count > 1 && path.hasSuffix("/") ? String(path.dropLast()) : path) }
            if let (id, frag) = BlockID.link(s), frag == nil, let p = hosts.block(id)?.path { return (id.host, p) }
            return nil
        }
        guard let x = file(a), let y = file(b) else { return false }
        return x.0 == y.0 && x.1 == y.1
    }

    /// What a thing on a shelf is called: an agent by its name, a block by
    /// its title (and the place in it), a file by its name, a page by its address.
    func contextTitle(_ address: String) -> String {
        if case let .file(_, path, _)? = ManifoldAddress.parse(address) { return path.lastPathComponent.isEmpty ? path : path.lastPathComponent }
        if let (id, fragment) = BlockID.link(address), let b = hosts.block(id) {
            if b.agent != nil { return AgentLook.name(of: b) }
            return Self.linkTitle(b) + (fragment.map { " · " + $0.replacingOccurrences(of: "=", with: " ") } ?? "")
        }
        return address
    }

    /// A thread's shelf, as its chat shows it: the agents in its
    /// conversation, the lead first, then what's kept in its context.
    func contextItems(of t: Block) -> [ThreadShelfView.Item] {
        // Every agent put there, running or not (one gone quiet stays, dimmed).
        let parts = participants(of: t)
        var out: [ThreadShelfView.Item] = parts.enumerated().compactMap { i, id in
            guard let b = hosts.block(id) else { return nil }
            let runs = Self.agentRuns(b)
            return ThreadShelfView.Item(address: Self.address(id), title: AgentLook.name(of: b), image: AgentLook.face(of: b, size: 15),
                                        symbol: "sparkle", agent: id, isLead: i == 0 && parts.count > 1 && !asksAll(t),
                                        detail: runs ? AgentLook.description(of: b) : "asleep: a comment asks another of its kind, or starts one", quiet: !runs)
        }
        for address in shelfReferences(of: t) {
            var symbol = "doc"
            var image: NSImage?
            if case let .file(_, path, _)? = ManifoldAddress.parse(address) {
                symbol = path.hasSuffix("/") ? "folder" : Theme.symbolName(for: BlockKind.forFile(path), path: path)
            } else if let (id, _) = BlockID.link(address), let b = hosts.block(id) {
                symbol = Theme.symbolName(for: b)
                image = b.web.flatMap { Favicons.image(forPage: $0.url) }
            } else if address.hasPrefix("http") {
                symbol = "globe"
            }
            out.append(ThreadShelfView.Item(address: address, title: contextTitle(address), image: image, symbol: symbol))
        }
        return out
    }

    /// Asked of an agent answering in a thread: what it names, linked —
    /// shown as the thing's pill in the comment, and gone to when clicked.
    static let linkHint = "Wherever you refer to something — a file, a declaration, a line, a block — link it, so it's clickable in the thread: `mani ref <file> --symbol Type.method --markdown` (or `--line N`, `--heading`), or a `manifold:` reference you were given, as `[name](manifold:…)`."

    /// The line typed into an agent's terminal: which thread, about what,
    /// what was said, and how to answer — on one line.
    private func prompt(for t: Block, comment: String, author: ThreadAuthor) -> String {
        let ref = Self.address(t.id)
        let about = t.thread?.about.map { describe($0).title } ?? "the space"
        let said = comment.replacingOccurrences(of: "\n", with: " ").prefix(400)
        return "[Manifold thread \(ref), about \(about)] \(author.isYou ? "The user" : author.shownName) wrote: \"\(said)\" — "
            + "read it with `mani thread read \(ref)`, and answer in the thread with `mani thread reply \(ref) \"…\"` (--resolve only if you did what it asks). "
            + "The reply is Markdown, shown as GitHub shows a comment: a list as `- ` lines, code in backticks or fences. "
            + Self.linkHint
    }

    /// Words typed into an agent's prompt and sent: the words, then
    /// Return a moment after — in one write, an agent's prompt (Claude
    /// Code's) takes it all as a paste, the Return a new line in it. A
    /// long line given longer to land. An agent that reports how it
    /// stands (its hooks) and hasn't started on it a moment later — its
    /// prompt still settling from the turn before, the Return taken into
    /// the paste — is given Return again, twice at most; still not started,
    /// it's said (and in `threads`): what was typed is waiting in its prompt.
    /// `waking`: an agent asleep, which the host starts again and types
    /// to once it's ready — no Return again, no saying it didn't take it.
    func say(_ text: String, to agent: BlockID, threads: [BlockID] = [], waking: Bool = false) {
        hosts.propose(.input(block: agent, text: Self.typed(text)))
        let reports = hosts.block(agent)?.statusRecord != nil && !waking
        let landed = 0.3 + min(0.7, Double(text.count) / 2000)
        DispatchQueue.main.asyncAfter(deadline: .now() + landed) { [weak self] in
            guard let self else { return }
            // How it stood as Return went: a report after it, a new one; a
            // turn more, taken.
            let before = self.hosts.block(agent)?.statusRecord
            let turns = self.hosts.block(agent)?.terminal?.turns?.count ?? 0
            self.hosts.propose(.input(block: agent, text: "\r"))
            guard reports else { return }
            self.pressAgain(agent, since: before, turns: turns, tries: 2, threads: threads)
        }
    }

    /// What's typed into an agent for `text`: as it is on one line; with
    /// more, a bracketed paste — a line break typed is Return, which would
    /// send its first line alone (the agents' prompts take pastes: Claude
    /// Code's "[Pasted text +3 lines]").
    static func typed(_ text: String) -> String {
        guard text.contains("\n") else { return text }
        let clean = text.replacingOccurrences(of: "\u{1b}[201~", with: "")
        return "\u{1b}[200~" + clean + "\u{1b}[201~"
    }

    /// Return again if the agent hasn't said it's started since it said
    /// `since` (its report then; another host's clock isn't this Mac's);
    /// out of tries and still not, the send failed — said.
    private func pressAgain(_ agent: BlockID, since: StatusRecord?, turns: Int, tries: Int, threads: [BlockID]) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
            guard let self, let b = self.hosts.block(agent), Self.agentRuns(b), let r = b.statusRecord else { return }
            // Begun since — a turn more, or a report other than idle (working,
            // asking something, or done already, a quick one): taken.
            if (b.terminal?.turns?.count ?? 0) > turns || (r != since && r.state != .idle) { return }
            guard tries > 0 else { return self.notTaken(agent, threads: threads) }
            self.hosts.propose(.input(block: agent, text: "\r"))
            self.pressAgain(agent, since: since, turns: turns, tries: tries - 1, threads: threads)
        }
    }

    /// An ask typed in that the agent never started on (Return taken into
    /// a paste, its prompt busy): said where it was asked from and here,
    /// the agent a click away — what was typed is still in its prompt.
    private func notTaken(_ agent: BlockID, threads: [BlockID]) {
        let name = hosts.block(agent).map(AgentLook.name(of:)) ?? "The agent"
        for id in threads {
            hosts.addToThread(id, .stopped("\(name) didn't start on it: the ask is still in its prompt — press Return there to send it"), author: .manifold)
        }
        toast.show("\(name) didn't take the ask — it's still in its prompt", action: "Show", for: 8) { [weak self] in self?.arrive(agent, from: nil) }
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
            // Typed only into the agent itself: not into a shell it's left —
            // or a project's asleep, which the host starts again for it.
            guard let b = hosts.block(a.agent) else {
                if Date().timeIntervalSince(a.made) < 30 { waiting.append(a) }
                continue
            }
            guard askable(b) else { continue }
            let state = b.statusState
            if Self.agentRuns(b), state == .working || state == .blocked { waiting.append(a); continue }
            byAgent[a.agent, default: []].append(a)
        }
        threadUI.asks = waiting
        for (agent, asks) in byAgent {
            // Its lines as written: `say` pastes what has more than one.
            let text = (asks.count == 1 ? asks[0].prompt : asks.map(\.prompt).joined(separator: "\n\n— and: "))
                .replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
            // Its name, as the threads call it: with other agents in them, which one it is.
            let named = hosts.block(agent).flatMap(AgentIdentity.name(of:))
            let name = named ?? hosts.block(agent)?.agent?.name ?? "The agent"
            // Asked from threads: which of their agents it is. From its own
            // conversation (no thread), nothing to say.
            let fromThreads = asks.contains { !$0.threads.isEmpty }
            let who = fromThreads ? named.map { "(You are \($0) in these threads.) " } ?? "" : ""
            let waking = hosts.block(agent).map(Self.agentRuns) == false
            say(who + text, to: agent, threads: Array(Set(asks.flatMap(\.threads))), waking: waking)
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
        // In a project: one of its own (§3.12), started with nothing showing
        // it — its pill on the project's line — and asked once it's ready.
        if let about, let p = project(of: about.id), about.id.host == host {
            let usual = desk.settings.agentCommand
            let command = AgentCatalog.agent(inCommand: usual)?.command == kind.command ? usual : kind.command
            let agent = client.newProjectAgent(root: p.root, command: command)
            var parts = participants(of: t)
            if !parts.contains(agent) {
                if parts.contains(where: { hosts.block($0).map(askable) == true }) { parts.append(agent) } else { parts.insert(agent, at: 0) }
                setParticipants(parts, of: t.id)
            }
            threadUI.asks.append(PendingAsk(agent: agent, threads: [t.id], prompt: prompt))
            // Once its block's here (the host made it): asked.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in self?.deliverAsks() }
            return
        }
        let cwd = about.flatMap { b -> String? in
            if let g = hosts.client(b.id.host)?.node.graph, let root = g.project(of: b.id) { return root }
            return b.place
        }
        let base = kind.command == AgentCatalog.agent(inCommand: desk.settings.agentCommand)?.command ? desk.settings.agentCommand : kind.command
        let command = AgentCatalog.command(base, prompt: prompt)
        let agent = client.newAgent(cwd: cwd, command: command)
        // In the thread from now on: its lead, if it had none at work.
        var parts = participants(of: t)
        if !parts.contains(agent) {
            if parts.contains(where: { hosts.block($0).map(Self.agentRuns) == true }) { parts.append(agent) } else { parts.insert(agent, at: 0) }
            setParticipants(parts, of: t.id)
        }
        show(agent, lens: .agent, .here, context: "asked in a thread")
        hosts.addToThread(t.id, .asked(agent: agent, name: kind.name), author: .manifold)
    }

    // MARK: Address These

    /// Threads handed to an agent at once (§3.12): the agent in the space
    /// (else one started), told to work through them in the threads.
    func addressThreads(_ ids: [BlockID], agent: BlockID? = nil) {
        let threads = ids.compactMap { hosts.block($0) }.filter { $0.thread?.resolved != true }
        guard !threads.isEmpty else { return toast.say("No open threads to hand over", .brief) }
        let list = threads.map { t in Self.address(t.id) + " (" + (t.thread?.about.map { describe($0).title } ?? "the space") + ")" }
        let prompt = "[Manifold] Please address these \(threads.count) open thread\(threads.count == 1 ? "" : "s"): " + list.joined(separator: "; ")
            + ". For each: `mani thread read <ref>`, do what it asks, and reply in it with `mani thread reply <ref> \"…\"` — with --resolve only if you did it; "
            + "a question is a reply left open. " + Self.linkHint + " Work through them oldest change first, then say briefly here what you did."
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
        return a.placements.lazy.compactMap { self.hosts.block($0.block) }.first { Self.agentRuns($0) }?.id
    }
}
