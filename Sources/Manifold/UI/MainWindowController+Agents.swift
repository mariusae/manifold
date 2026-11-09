import AppKit
import ManifoldCore
import WebKit
import ManifoldSyntax
import UniformTypeIdentifiers
import PDFKit

extension MainWindowController {
    // MARK: Asking an agent about a place (§2.5)

    /// What an agent is asked to do with a place: describe it (a note that
    /// describes it, shown with it), explain it (how it fits), or walk
    /// through it (a note of references, a step each).
    enum AgentAsk { case describe, explain, walk }

    @objc func describeWithAgent(_ sender: Any?) { askAgent(.describe) }
    @objc func explainWithAgent(_ sender: Any?) { askAgent(.explain) }
    @objc func walkWithAgent(_ sender: Any?) { askAgent(.walk) }

    /// The focused editor's place — its selection's, else the declaration
    /// the caret is in — handed to an agent with what to make of it: the
    /// agent in this space most lately used, else a new one beside. What
    /// it makes (notes, links with relations) comes back into the graph,
    /// and shows where it belongs.
    private func askAgent(_ ask: AgentAsk) {
        guard let f = focusedShown, let e = views[f.id] as? EditorView, let b = hosts.block(f.placement.block), let rope = b.text?.text else { return NSSound.beep() }
        let sel = e.textView.selections.last { !$0.isCaret }
        let wanted = sel.flatMap { Anchoring.anchor(range: $0.range, of: b) }
            ?? Anchoring.anchor(atLine: rope.line(at: e.textView.primarySelection.head), of: b)
        guard let wanted, let ref = reference(to: wanted, in: b.id) else { return NSSound.beep() }
        let name = Anchoring.name(of: wanted), file = b.path?.lastPathComponent ?? b.displayTitle
        let prompt: String
        switch ask {
        case .describe:
            prompt = "Describe \(ref) (\(name) in \(file)) for someone reading the code: what it does and how, as short pseudocode where that helps. "
                + "Put it in a note — mani new note --title \"\(name)\" --text \"…\" — then link the note to it: mani link @last \(ref) --as describes. Keep it brief."
        case .explain:
            prompt = "Explain \(ref) (\(name) in \(file)): why it's there, and how it fits with what uses it (mani refs \(ref) lists them, if the project is indexed). "
                + "Put it in a note — mani new note --title \"Why \(name)\" --text \"…\" — then link it: mani link @last \(ref) --as explains."
        case .walk:
            prompt = "Walk me through \(ref) (\(name) in \(file)): how a call to it unfolds, step by step. Make a note of the steps in order, each a reference to its place "
                + "(mani ref <file> --symbol <Type.method>; mani refs for its callers) and a sentence — mani new note --title \"How \(name) works\" --text \"…\". I'll step through it with ⌃⌘]."
        }
        if let agent = agentForAsking() {
            say(prompt, to: agent)
            toast.show("Asked \(hosts.block(agent)?.displayTitle ?? "the agent") about \(name)", action: "Show", for: 4) { [weak self] in self?.arrive(agent, from: nil) }
        } else {
            guard let client = hosts.client(b.id.host) else { return NSSound.beep() }
            let command = desk.settings.agentCommand + " " + prompt.shellQuoted
            let agent = client.newAgent(cwd: b.path?.deletingLastPathComponent ?? b.place, command: command)
            show(agent, lens: .agent, .here, context: "asked about \(name)")
        }
    }

    /// Code ▸ Show Callers: the functions that call the declaration the
    /// caret is in (the project's index's, each named by its file's
    /// grammar), as a note of references beside — walked with ⌃⌘].
    @objc func showCallers(_ sender: Any?) {
        guard let f = focusedShown, let e = views[f.id] as? EditorView, let b = hosts.block(f.placement.block), let rope = b.text?.text,
              let path = b.path, let language = SyntaxLanguage.forPath(path) else { return NSSound.beep() }
        let caret = e.textView.primarySelection.head
        let decls = SyntaxTree(language, text: rope, background: false).declarations()
        let at = decls.last { $0.range.contains(caret) || $0.nameRange.contains(caret) }?.nameRange.start ?? caret
        let placement = f.id
        Task { @MainActor in
            do {
                // The symbol's search, its callers asked — the same browser
                // as its references, asked another way there.
                let (symbol, name) = try await maniDesk.symbolAt(b, offset: at)
                showRelation("callers", symbol: symbol, name: name, path: path, on: b.id.host, from: placement)
            } catch {
                toast.show("\(error is ManiDesk.Failure ? (error as! ManiDesk.Failure).message : "\(error)")", action: "OK", for: 6) {}
            }
        }
    }

    /// The agent to ask: the one in this space most lately settled on (a
    /// tile of its, still running), else any here.
    private func agentForAsking() -> BlockID? {
        guard let a = arrangement else { return nil }
        let agents = a.placements.filter { hosts.block($0.block)?.kind == .agent && hosts.block($0.block)?.terminal?.dormantSince == nil }
        guard !agents.isEmpty else { return nil }
        for place in settled where place.space == selected {
            if let tile = place.tile, let p = agents.first(where: { $0.id == tile }) { return p.block }
        }
        return agents.first?.block
    }

    /// New Note from Clipboard: its text as a note (a picture: an image block).
    @objc func newNoteFromClipboard(_ sender: Any?) {
        let pb = NSPasteboard.general
        if let s = pb.string(forType: .string), !s.isEmpty {
            show(host.newNote(home: focusedHost == host.host ? focusedCwd : nil, text: s), lens: .editor, .here)
        } else if case let images = TextView.images(on: pb), let (data, kind) = images.first {
            keepDroppedImage(data, kind: kind, place: .inColumn(max((arrangement?.columns.count ?? 1) - 1, 0)))
        } else {
            NSSound.beep()
        }
    }

    @objc func newNote(_ sender: Any?) {
        let client = hosts.client(focusedHost) ?? host
        let note = client.newNote(home: focusedCwd)
        if let f = focusedShown, let b = f.block, b.kind != .arrangement {
            hosts.link(from: b.id, to: note, kind: .linked, context: "new note")
        }
        show(note, lens: .editor, .here)
    }

    /// The links a block has by hand (§3.5), for its bar: what it links to
    /// (→) and what links to it (←), and a note's images and the note an
    /// image is in — the most recent first, whichever way.
    func links(of block: BlockID) -> [LinkCard] {
        // Straight from the graphs' edges: this runs for every tile on
        // every render.
        var seen = Set<BlockID>()
        var cards: [LinkCard] = []
        var stamps: [String: Stamp] = [:]
        // A note's images too (embeds), which aren't broken by hand.
        for kind in [LinkKind.linked, .embeds] {
            for c in hosts.all {
                for e in c.node.graph.edges(from: block, kind: .link(kind)) where e.isLive {
                    guard seen.insert(e.to).inserted, let b = hosts.block(e.to) else { continue }
                    cards.append(LinkCard(link: e.id, block: e.to, title: Self.linkTitle(b), symbol: Theme.symbolName(for: b), outbound: true, breakable: kind == .linked))
                    stamps[e.id] = e.at
                }
            }
            for c in hosts.all {
                for e in c.node.graph.edges(to: block, kind: .link(kind)) where e.isLive {
                    guard seen.insert(e.from).inserted, let b = hosts.block(e.from) else { continue }
                    cards.append(LinkCard(link: e.id, block: e.from, title: Self.linkTitle(b), symbol: Theme.symbolName(for: b), outbound: false, breakable: kind == .linked))
                    stamps[e.id] = e.at
                }
            }
        }
        // Stable: the edges' order among equal stamps, and unstamped last.
        return cards.enumerated().sorted { a, b in
            switch (stamps[a.element.link], stamps[b.element.link]) {
            case let (x?, y?) where x != y: return x > y
            case (_?, nil): return true
            case (nil, _?): return false
            default: return a.offset < b.offset
            }
        }.map(\.element)
    }

    /// A linked block's name on a badge: a note by its title or first words.
    static func linkTitle(_ b: Block) -> String { b.kind == .text && b.path == nil ? noteTitle(b) : b.displayTitle }

    /// A block ⇧-dragged onto another: linked, from it to the target.
    func link(_ block: BlockID, to target: BlockID) {
        guard block != target else { return }
        hosts.link(from: block, to: target, kind: .linked, context: "⇧-dragged in")
    }

    /// Debugging: typed into the focused editor, as keys would be.
    func debugType(_ text: String) -> String {
        guard let e = debugFocusedEditor else { return "no editor focused" }
        e.debugType(text)
        return "typed \(text.count)"
    }

    /// Debugging: a thing dropped (§3.11) on the focused tile's view (at
    /// its caret, or its middle), or the grid's slot `column`/`at` —
    /// written as its source writes it: `block <id> [fragment]`, `file
    /// <host> <path> d|f` (a folder's entry), `finder <path>` (the Finder's),
    /// `text <words>`, `url <address>`, `image <path>` (a picture's data),
    /// `row <i>` (the shown floating list's), `from <terminal> <i>` (its
    /// outline's). `form`: that chosen from the palette; `palette`: the
    /// palette opened over the target's middle, its rows (then "pick <i>").
    func debugDrop(_ spec: [String], as form: DropForm?, grid slot: (Int, Int)?, palette: Bool = false) -> String {
        let pb = NSPasteboard(name: NSPasteboard.Name("com.manifold.debug-drop"))
        // "pick <i>": the open palette's row i dropped on.
        if spec.first == "pick", spec.count > 1, let i = Int(spec[1]) { return DropPalette.debugPick(i, pb) }
        pb.clearContents()
        let rest = spec.dropFirst().joined(separator: " ")
        var item: NSPasteboardWriting?
        var several: [NSPasteboardWriting]?
        switch spec.first {
        case "chosen":
            // "chosen <block> [sidebar|results]": the rows chosen in its tile
            // (a git block's, a search's, a folder's, its homepage's sidebar's
            // or search's), dragged together.
            guard spec.count > 1, let id = BlockID(string: spec[1]),
                  let v = views.values.first(where: { $0.block == id }) else { return "chosen <block> [sidebar|results]" }
            if let g = v as? GitView { several = g.debugDragItems }
            else if let d = v as? DirectoryView { several = d.debugDragItems(from: spec.count > 2 ? spec[2] : nil) }
            else if let r = v as? SearchView { several = r.debugDragItems }
            else if let m = v as? MediaView { several = m.debugPagesDrag }
            else { return "no rows to choose there" }
        case "block":
            guard spec.count > 1, let id = BlockID(string: spec[1]) else { return "no block" }
            item = spec.count > 2 ? Drags.place?(Place(block: id, at: Locator(fragment: spec[2]), name: hosts.block(id)?.displayTitle), nil) : Drags.block?(id, [.shift])
        case "place":
            // "place <host> <path> <fragment>": a place in a file (a hit's line), dragged.
            guard spec.count == 4 else { return "place <host> <path> <fragment>" }
            item = Drags.place?(Place(file: spec[2], on: HostID(spec[1]), at: Locator(fragment: spec[3])), nil)
        case "file":
            guard spec.count == 4 else { return "file <host> <path> d|f" }
            item = Drags.file(spec[2], isDirectory: spec[3] == "d", on: HostID(spec[1]))
        case "finder":
            let i = NSPasteboardItem()
            i.setString(URL(fileURLWithPath: rest).absoluteString, forType: .fileURL)
            item = i
        case "text":
            let i = NSPasteboardItem()
            i.setString(rest, forType: .string)
            item = i
        case "url":
            let i = NSPasteboardItem()
            i.setString(rest, forType: .URL)
            i.setString(rest, forType: .string)
            item = i
        case "image":
            guard let data = FileManager.default.contents(atPath: rest) else { return "can't read \(rest)" }
            let i = NSPasteboardItem()
            i.setData(data, forType: rest.lowercased().hasSuffix(".png") ? .png : .tiff)
            item = i
        case "row":
            let rows = FloatingList.shared.rows
            guard spec.count > 1, let n = Int(spec[1]), rows.indices.contains(n) else { return "no row" }
            item = rows[n].drag?([])
        case "from":
            guard spec.count == 3, let t = BlockID(string: spec[1]), let n = Int(spec[2]),
                  let source = views.values.first(where: { $0.block == t }) as? TerminalView else { return "from <terminal> <i>" }
            item = source.debugOutlineDrag(n)
        case "cell":
            // "cell <notebook> <i>": that cell dragged by its gutter.
            guard spec.count == 3, let t = BlockID(string: spec[1]), let n = Int(spec[2]),
                  let source = views.values.first(where: { $0.block == t }) as? NotebookView else { return "cell <notebook> <i>" }
            item = source.debugCellDrag(n)
        case "dot":
            // "dot <terminal> <command id>": that command's dot dragged.
            guard spec.count == 3, let t = BlockID(string: spec[1]), let n = Int(spec[2]),
                  let source = views.values.first(where: { $0.block == t }) as? TerminalView else { return "dot <terminal> <command id>" }
            item = source.debugDotDrag(n)
        default:
            return "drop block|place|file|finder|text|url|image|row|from|dot|chosen … [as <form>] [grid <column> <at>]"
        }
        let items = several ?? item.map { [$0] } ?? []
        guard !items.isEmpty else { return "nothing dragged" }
        pb.writeObjects(items)
        Dropping.debugChoice = form
        defer { Dropping.debugChoice = nil }
        if let (column, at) = slot {
            guard let d = Dragged(pb) else { return "not a thing" }
            let forms = content.dropForms(d, at: content.debugSlotPoint(column: column, at: at))
            guard !forms.isEmpty else { return "refused" }
            Dropping.take(d, forms, by: content, at: content.debugSlotPoint(column: column, at: at))
            return "offered \(forms.map(\.rawValue).joined(separator: ", "))"
        }
        guard let target = debugDropTarget else { return "the focused tile takes no drops" }
        if palette {
            DropPalette.close()
            DropPalette.open(over: target, pb, at: target.convert(NSPoint(x: target.visibleRect.midX, y: target.visibleRect.midY), to: nil))
            return DropPalette.debugState
        }
        return Dropping.debugDrop(pb, on: target, at: nil)
    }

    /// The focused tile's view that takes things dropped.
    private var debugDropTarget: DropTaking? {
        guard let f = focusedShown, let v = views[f.placement.id] else { return nil }
        if let e = v as? EditorView { return e.textView }
        if let o = v as? OutlineNoteView { return o.dropTarget }
        return v as? DropTaking
    }

    func debugContents(_ name: String) -> String {
        let last = debugContentsAnswer
        let b: Block? = BlockID(string: name).flatMap { hosts.block($0) } ?? focusedShown?.block
        guard let b else { return "nothing focused" }
        let view = views.first { $0.value.block == b.id }?.value
        Task { @MainActor [weak self] in
            do { self?.debugContentsAnswer = try await self?.maniDesk.contents(of: b, view: view, all: true) ?? "" } catch let e as ManiDesk.Failure { self?.debugContentsAnswer = "failure: " + e.message } catch {}
        }
        return last
    }

    /// What to call a note: its title, else its first line (`Block.noteTitle`), else "Note".
    static func noteTitle(_ b: Block) -> String {
        if let t = b.title, !t.isEmpty { return t }
        return b.text.flatMap { Block.noteTitle(from: $0.text) } ?? b.displayTitle
    }

    /// A linked block from a tile's badge: gone to where it is; placed
    /// nowhere, opened beside the tile.
    /// A tile's link clicked, as every link goes: to it (or, if it's
    /// nowhere, beside); ⌘ beside; ⌥ over; ⇧⌘ to the system's app.
    func gridOpenLink(_ block: BlockID, from placement: PlacementID, modifiers: NSEvent.ModifierFlags) {
        follow(block, from: placement, Disposition(modifiers), context: "from its links")
    }

    /// × on a badge's link: the edge ends, in both readings at once.
    func gridBreakLink(_ link: String) { hosts.propose(.unlink(link)) }


    /// Saves a text block: through an editor on it (this tile's first),
    /// which keeps its own count of what's saved and names a note's file;
    /// else straight to its file.
    func save(_ block: BlockID, from placement: PlacementID) {
        let editors = views.values.compactMap { $0 as? EditorView }.filter { $0.block == block }
        if let e = editors.first(where: { $0.placement == placement }) ?? editors.first { return e.saveDocument(nil) }
        guard let b = hosts.block(block), b.path != nil, !b.needsRead, let t = b.text else { return NSSound.beep() }
        hosts.propose(.writeFile(block, version: t.version))
    }

    /// The bar's ×: the tile taken off, as ⌘W takes the focused one.
    func gridClose(_ placement: PlacementID) {
        guard let id = selected else { return }
        closeTile(placement, in: id)
    }

    /// A tile's × clicked: closed, and the pointer onto the × of the tile
    /// that takes its place — the one behind it, else below, else above,
    /// else the next column's, as the arrangement hands the focus on — so
    /// clicking again closes that one, and a column empties a click at a
    /// time.
    func gridCloseClicked(_ placement: PlacementID) {
        guard let id = selected, var after = arrangement else { return }
        // Who'd have the focus, were it this tile's.
        after.apply(.focus(placement))
        after.apply(.remove(placement))
        let heir = after.focused
        closeTile(placement, in: id)
        guard let heir, let window else { return }
        render()
        DispatchQueue.main.async { [weak self] in
            guard let self, self.arrangement?.placement(heir) != nil, let p = self.content.closeButtonInWindow(heir) else { return }
            Pointer.warp(to: window.convertPoint(toScreen: p))
        }
    }

    /// A tile closed, however it's asked for (⌘W, its ×, its menu, the
    /// sidebar's): kept to reopen (⇧⌘T), and what it leaves to be
    /// collected said, with Restore, if it had edits or a job running.
    /// ⇧⌘S: the focused editor (or a menu's) saved, then its tile closed —
    /// once the file is written, not before: an `$EDITOR`'s command, which
    /// reads it, ends as the tile goes. A file with nothing unsaved just
    /// closes; a note with no file is saved as one first (⌘S's panel);
    /// a save that fails leaves the tile, and says so.
    @objc func saveAndClose(_ sender: Any?) {
        guard let p = ((sender as? NSMenuItem)?.representedObject as? PlacementID) ?? arrangement?.focused else { return NSSound.beep() }
        saveAndClose(tile: p)
    }

    func saveAndClose(tile p: PlacementID) {
        guard let ws = selected, let shown = arrangement?.placement(p), let b = hosts.block(shown.block),
              b.kind == .text, b.text != nil else { return NSSound.beep() }
        if b.path != nil, b.text?.isDirty != true { return closeTile(p, in: ws) }
        if let e = views[p] as? EditorView { e.saveDocument(nil) } else { save(b.id, from: p) }
        savingToClose[p] = (b.id, ws, Date().addingTimeInterval(b.path == nil ? 600 : 15))
        closeOnceSaved()
    }


    private func closeOnceSaved() {
        for (p, w) in savingToClose {
            guard let b = hosts.block(w.block), hosts.arrangement(w.space)?.placement(p) != nil else {
                savingToClose.removeValue(forKey: p)
                continue
            }
            if b.statusRecord?.state == .error {
                savingToClose.removeValue(forKey: p)
                toast.show("Couldn't save “\(b.displayTitle)”: its tile stays", action: "OK", for: 6) {}
            } else if b.path != nil, b.text?.isDirty == false {
                savingToClose.removeValue(forKey: p)
                closeTile(p, in: w.space)
            } else if Date() > w.until {
                savingToClose.removeValue(forKey: p)
            }
        }
        guard !savingToClose.isEmpty else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in self?.closeOnceSaved() }
    }

    func closeTile(_ placement: PlacementID, in id: BlockID) {
        guard let a = hosts.arrangement(id), a.placement(placement) != nil else { return }
        let before = hosts.reachable()
        noteClosing(placement, in: id)
        hosts.append([.remove(placement)], to: .block(id))
        afterClosing(reachedBefore: before)
    }

    func gridLink(_ block: BlockID, to target: PlacementID) {
        guard let t = shown(target)?.block else { return }
        link(block, to: t.id)
    }

    /// Edit Address: the focused tile's pill edits what it offers (a page's address).
    @objc func editAddress(_ sender: Any?) {
        if !content.editFocusedPill() { NSSound.beep() }
    }

    /// ⌘L: in an editor, Go to Line; elsewhere, the tile's address edited
    /// (a page's, as a browser's ⌘L).
    @objc func goToLineOrAddress(_ sender: Any?) {
        if let e = arrangement?.focused.flatMap({ views[$0] }) as? EditorView { return e.goToLine(sender) }
        editAddress(sender)
    }

    /// Open Folder…: a folder chosen, browsed beside the focused block.
    @objc func openFolder(_ sender: Any?) {
        guard let window else { return }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Browse"
        if let cwd = focusedCwd { panel.directoryURL = URL(fileURLWithPath: cwd) }
        panel.beginSheetModal(for: window) { [weak self] response in
            guard let self, response == .OK, let url = panel.url else { return }
            self.show(self.host.directoryBlock(for: url.path), lens: .directory, .here)
        }
    }

    /// Browse This Folder: the focused block's folder, beside it.
    @objc func browseFocusedFolder(_ sender: Any?) {
        guard let cwd = focusedCwd, let client = hosts.client(focusedHost) else { return NSSound.beep() }
        show(client.directoryBlock(for: cwd), lens: .directory, .here)
    }

    /// ⌘W: the focused tile taken off, its column showing what it showed
    /// before (its block kept while a space reaches it). With another
    /// window in front — Settings, a panel — that window closes instead:
    /// the action comes here by way of the main window.
    @objc func closePaneOrTab(_ sender: Any?) {
        if let key = NSApp.keyWindow, key !== window, key.styleMask.contains(.closable) { return key.performClose(sender) }
        guard let a = arrangement, let id = selected else { return }
        let before = hosts.reachable()
        if let f = a.focused {
            // Taken off, a tile's room goes back where it came from — to a
            // tile docked under it (a terminal its `$EDITOR` was over),
            // which comes back in its place and takes the focus (the
            // model's doing); else to its neighbours.
            let block = a.placement(f)?.block
            noteClosing(f, in: id)
            hosts.append([.remove(f)], to: .block(id))
        }
        afterClosing(reachedBefore: before)
    }

    /// ⌘D: the focused tile's block deleted (or `sender`'s, a menu's).
    @objc func deleteFocusedBlock(_ sender: Any?) {
        let block = ((sender as? NSMenuItem)?.representedObject as? PlacementID).flatMap { arrangement?.placement($0)?.block }
            ?? focusedShown?.placement.block
        guard let block else { return NSSound.beep() }
        deleteBlock(block)
    }
}
