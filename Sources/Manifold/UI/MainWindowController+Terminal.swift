import AppKit
import ManifoldCore
import WebKit
import ManifoldSyntax
import UniformTypeIdentifiers
import PDFKit

extension MainWindowController: TerminalViewDelegate {
    func terminal(_ view: TerminalView, open target: String, over: Bool) {
        open(target, from: view.placement, as: Self.commandClick(over: over))
    }

    /// A terminal's link click, ⌘ being what makes it one: beside, ⌥⌘
    /// over, ⇧⌘ the system's app — read off the click if it's in hand.
    static func commandClick(over: Bool) -> Disposition {
        if let d = disposition, d != .goTo { return d }
        return over ? .over : .beside
    }

    /// A ⌘-clicked word that isn't a link to ghostty or to the terminal's
    /// reading of its screen (which takes the names it shows, looked for on
    /// their host): a folder by that name where the terminal is opens as a
    /// listing; anything else, nothing. On another host, nothing.
    func terminal(_ view: TerminalView, openFolder name: String, over: Bool) {
        let word = name.trimmingCharacters(in: CharacterSet(charactersIn: "'\"`,;"))
        guard !word.isEmpty, view.block.host == host.host else { return }
        var path = (word as NSString).expandingTildeInPath
        if !path.hasPrefix("/"), let base = hosts.block(view.block)?.terminal?.cwd { path = (base as NSString).appendingPathComponent(path) }
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDir), isDir.boolValue else { return }
        open(word, from: view.placement, as: Self.commandClick(over: over))
    }

    /// A command's output as a block of its own (§3.8): the host captures
    /// what the terminal received for it — colours and all — into an
    /// output block, linked from the terminal; shown read-only, with Copy
    /// and the way back. One per command: asked again, the one there is.
    func terminal(_ view: TerminalView, show command: ShellCommand, output: String, beside: PlacementID?) {
        let place: Where = beside != nil ? .here : opener(view.placement)
        // An agent's turn: the turn, as a block of its own, not the TUI's bytes.
        if hosts.block(view.block)?.terminal?.turns?.contains(where: { $0.id == command.id }) == true {
            return showTurn(command.id, of: view.block, place: place)
        }
        let (id, made) = outputBlock(of: command, in: view.block, output: output)
        let context = "command \(command.id)"
        if made { return show(id, lens: .output, place, kind: .opened, context: context) }
        // Shown once the host has made it (a moment).
        showWhenMade(id, lens: .output, place: place, context: context, what: "the command's output")
    }

    /// The block of a command's output, made by the host if there's none.
    func outputBlockID(of command: ShellCommand, in terminal: BlockID) -> BlockID {
        outputBlock(of: command, in: terminal, output: "").id
    }

    /// A command's output as a block (§3.8): the one made before, else one
    /// the host is asked to make now (`made` false: not here yet).
    private func outputBlock(of command: ShellCommand, in terminal: BlockID, output: String) -> (id: BlockID, made: Bool) {
        let context = "command \(command.id)"
        if let made = hosts.neighborhood(of: terminal).outbound[.link(.opened)]?.first(where: { $0.context == context && hosts.block($0.to)?.kind == .output }) {
            return (made.to, true)
        }
        let id = BlockID(host: terminal.host)
        hosts.propose(.captureOutput(block: id, terminal: terminal, command: command.id, fallback: output))
        return (id, false)
    }

    /// An agent's turn as its own block: the one made before, else one the
    /// host makes now; either brought up to date.
    private func turnBlock(_ turn: Int, of agent: BlockID) -> (id: BlockID, made: Bool) {
        let context = "turn \(turn)"
        let made = hosts.neighborhood(of: agent).outbound[.link(.opened)]?.first(where: { $0.context == context && hosts.block($0.to)?.kind == .output })?.to
        let id = made ?? BlockID(host: agent.host)
        hosts.propose(.captureTurn(block: id, agent: agent, turn: turn))
        return (id, made != nil)
    }

    /// An agent's turn as its own block (§3.8): the one made before, brought
    /// up to date, else one the host makes now.
    func showTurn(_ turn: Int, of agent: BlockID, place: Where) {
        let context = "turn \(turn)"
        let (id, made) = turnBlock(turn, of: agent)
        if made { return show(id, lens: .output, place, kind: .opened, context: context) }
        showWhenMade(id, lens: .output, place: place, context: context, what: "the turn",
                     made: { [weak self] in self?.hosts.block(id)?.output?.markdown != nil })
    }

    /// Changes in This Turn: the working tree between the turn's two
    /// checkpoints (as it is now, while it runs), as a diff block.
    func showTurnChanges(_ turn: AgentTurn, of agent: BlockID, beside placement: PlacementID?) {
        guard let repo = turn.repo, let before = turn.before, let client = hosts.client(of: agent) else { return NSSound.beep() }
        let first = turn.headline ?? "Turn"
        let diff = client.diffBlock(.trees(repo: repo, from: before, to: turn.after, title: "Turn: " + String(first.prefix(60))))
        hosts.link(from: agent, to: diff, kind: .opened, context: "changes in turn \(turn.id)")
        show(diff, lens: .diff, .besideOrHere(placement), context: "changes in turn \(turn.id)")
    }

    /// Undo This Turn: asked first; then the turn's changes taken back.
    func undoTurn(_ turn: AgentTurn, of agent: BlockID) {
        guard turn.before != nil, turn.after != nil else { return NSSound.beep() }
        let first = turn.headline ?? "the turn"
        let n = turn.files?.count ?? 0
        confirm("Undo “\(first.prefix(80))”?",
                "What the turn changed in \(turn.repo?.lastPathComponent ?? "the repository") (\(n) file\(n == 1 ? "" : "s")) is taken back, as the working tree was before it — later changes kept. If later work changed the same lines, nothing is touched and Manifold says so.",
                button: "Undo Turn") { [weak self] in
            self?.hosts.propose(.undoTurn(agent: agent, turn: turn.id)) { error in
                DispatchQueue.main.async {
                    self?.toast.say(error.map { "Couldn't undo the turn: \($0)" } ?? "Turn undone", error == nil ? .brief : .long)
                }
            }
        }
    }

    /// The menu of an agent's turn: shown, its changes, undone.
    func turnItems(_ turn: AgentTurn, of agent: BlockID, beside placement: PlacementID?) -> [NSMenuItem] {
        var items: [NSMenuItem] = [ClosureMenuItem("Show Turn", symbol: "text.bubble") { [weak self] in
            self?.showTurn(turn.id, of: agent, place: .besideOrHere(placement))
        }]
        if turn.before != nil {
            items.append(ClosureMenuItem("Changes in This Turn", symbol: "plusminus") { [weak self] in self?.showTurnChanges(turn, of: agent, beside: placement) })
        }
        let undo = ClosureMenuItem("Undo This Turn…", symbol: "arrow.uturn.backward") { [weak self] in self?.undoTurn(turn, of: agent) }
        undo.isEnabled = turn.before != nil && turn.after != nil
        items.append(undo)
        return items
    }

    /// A block the host is making, shown as soon as it exists here.
    /// `context`: the link the host made for it, said again — a link of
    /// another context would take its place, and the block then not be
    /// found to show again. `made`: when it counts as made (a turn, once
    /// its transcript is in); by default, once the block exists.
    func showWhenMade(_ id: BlockID, lens: Lens, place: Where, context: String? = nil, what: String = "it", made: (() -> Bool)? = nil) {
        let place = inNewColumn ? Where.beside : place
        inNewColumn = false
        // In the space it was asked for in, wherever you are once it's made.
        let space = selected
        whenMade(id, what: what, made: made ?? { [weak self] in self?.hosts.block(id) != nil }) { [weak self] in
            guard let self else { return }
            self.show(id, lens: lens, place, kind: .opened, context: context,
                      in: space.flatMap { self.hosts.arrangement($0) != nil && self.allWorkspaces.contains($0) ? $0 : nil })
        }
    }

    /// The space a tile is in (on screen or docked), if it's on the desk.
    func spaceHolding(_ placement: PlacementID) -> BlockID? {
        allWorkspaces.first { hosts.arrangement($0)?.placement(placement) != nil }
    }

    /// Something a host is making for a click (a command's output, a turn,
    /// a notebook): done once it's made. A moment in, a word at the foot
    /// of the window says what's awaited, and from where, so the click
    /// isn't taken for nothing; after half a minute it's given up, saying so.
    /// `then` once `made` holds — looked at with each change that comes
    /// (the host's reply is one), not every 50 ms; past half a second it's
    /// said what's awaited, past 30 that it didn't come.
    func whenMade(_ id: BlockID, what: String, made: @escaping () -> Bool, then: @escaping () -> Void) {
        if made() { return then() }
        madeWaits.append(MadeWait(id: id, what: what, made: made, then: then, started: Date()))
        checkMadeWaits()
    }


    /// The waits whose blocks have come, done; the rest said, or given up.
    func checkMadeWaits() {
        guard !madeWaits.isEmpty else { madeWaitTimer?.invalidate(); madeWaitTimer = nil; return }
        var still: [MadeWait] = []
        for var w in madeWaits {
            if w.made() {
                if w.said { toast.hide() }
                w.then()
                continue
            }
            let waited = Date().timeIntervalSince(w.started)
            let host = hosts.label(of: w.id.host)
            if waited > 30 {
                toast.say("\(host) didn't make \(w.what) in time", .long)
                continue
            }
            if !w.said, waited > 0.5 {
                w.said = true
                toast.say("Getting \(w.what) from \(host)…", .long)
            }
            still.append(w)
        }
        madeWaits = still
        if madeWaits.isEmpty {
            madeWaitTimer?.invalidate()
            madeWaitTimer = nil
        } else if madeWaitTimer == nil {
            // For what's said, and giving up: the blocks come with changes.
            madeWaitTimer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in self?.checkMadeWaits() }
        }
    }

    func terminal(_ view: TerminalView, menuFor command: ShellCommand) -> NSMenu? {
        let menu = NSMenu()
        // Its items enabled as they say (Run Again isn't, while one runs).
        menu.autoenablesItems = false
        let linkItem = ClosureMenuItem("Copy Link to This \(hosts.block(view.block)?.terminal?.turns?.contains(where: { $0.id == command.id }) == true ? "Turn" : "Command")", symbol: "link") { [weak self] in
            self?.copyLink(to: Place(block: view.block, at: .command(command.id)))
        }
        defer { menu.addItem(.separator()); menu.addItem(linkItem) }
        if let turn = hosts.block(view.block)?.terminal?.turns?.first(where: { $0.id == command.id }) {
            for item in turnItems(turn, of: view.block, beside: view.placement) { menu.addItem(item) }
        } else {
            // The command sent to the shell again: run, or typed at the prompt
            // to be changed first — not while one runs (it'd go to that program).
            let busy = view.commands.last?.isRunning ?? false
            for (title, symbol, run) in [("Run Again", "arrow.clockwise", true), ("Type at Prompt", "text.cursor", false)] {
                let item = ClosureMenuItem(title, symbol: symbol) { [weak self, weak view] in
                    guard let self, let view else { return }
                    self.hosts.propose(.input(block: view.block, text: command.text + (run ? "\r" : "")))
                    self.focus(view.placement)
                }
                item.isEnabled = !busy
                if busy { item.toolTip = "A command is running in this terminal" }
                menu.addItem(item)
            }
            menu.addItem(.separator())
            menu.addItem(ClosureMenuItem("Open as Block", symbol: "text.alignleft") { [weak view] in _ = view?.showOutput(ofCommand: command.id, beside: view?.placement) })
            menu.addItem(ClosureMenuItem("Copy Command", symbol: "doc.on.clipboard") {
                NSPasteboard.copy(command.text)
            })
        }
        return menu
    }

    func terminalDidFocus(_ view: TerminalView) {
        guard let a = arrangement, a.placement(view.placement) != nil, a.focused != view.placement else { return }
        focus(view.placement)
    }

    func terminalDidClose(_ view: TerminalView) {
        guard views[view.placement] === view else { return }
        views.removeValue(forKey: view.placement)
        view.removeFromSuperview()
        recentlyClosed.insert(view.block)
        render()
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
            self?.recentlyClosed.remove(view.block)
            self?.render()
        }
    }
}
