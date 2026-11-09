import AppKit
import ManifoldCore
import WebKit
import ManifoldSyntax
import UniformTypeIdentifiers
import PDFKit

extension MainWindowController: GridDelegate {
    /// A tile as a summary card: its block's summary, and what only the
    /// window has — a terminal's last lines on its screen, a picture of a
    /// page or a PDF as it was last seen.
    func gridLinkSummary(_ block: BlockID) -> SummaryCardContent? { cardContent(for: block) }

    func gridSummary(_ placement: PlacementID) -> SummaryCardContent? {
        guard let p = arrangement?.placement(placement) else { return nil }
        return cardContent(for: p.block, view: views[placement], id: placement)
    }

    /// A place's card in a block (§3.11), as a note shows `![…](manifold:…#…)`:
    /// the place's summary — a command's with its output's last lines, a
    /// page's with its picture — else the block's own.
    func cardContent(for block: BlockID, at fragment: String?) -> SummaryCardContent? {
        guard let b = hosts.block(block), var at = fragment.flatMap(Locator.init(fragment:)), var s = b.summary(at: at) else { return cardContent(for: block) }
        if let id = at.anchorID, let legible = b.anchors?[id]?.legible { at = legible }
        var thumbnail: NSImage?
        if case let .command(id) = at, let t = views.values.first(where: { $0.block == block }) as? TerminalView, let out = t.transcript(ofCommand: id)?.1 {
            s.lines += out.split(separator: "\n").map { Block.oneLine(String($0)) }.filter { !$0.isEmpty }.suffix(2)
        }
        if case let .page(n) = at, block.host == host.host, let path = b.path,
           let page = PDFDocument(url: URL(fileURLWithPath: path))?.page(at: n - 1) {
            thumbnail = page.thumbnail(of: NSSize(width: 160, height: 200), for: .cropBox)
        }
        var c = SummaryCardContent(id: "", symbol: Theme.symbolName(for: b), summary: s, thumbnail: thumbnail)
        c.mark = StatusMark(of: b)
        return c
    }

    /// A block's summary card: its summary, and what only the window has —
    /// a terminal's last lines on its screen, a picture of a page or a PDF
    /// as it was last seen. `view`: its tile's, if it has one shown.
    func cardContent(for block: BlockID, view: PaneContent? = nil, id: PlacementID = "") -> SummaryCardContent? {
        guard let b = hosts.block(block) else { return nil }
        let view = view ?? views.values.first { $0.block == block }
        var s = b.summary()
        // A shell's screen says more than its command: its last lines (not
        // the prompt waiting at the end).
        if let t = view as? TerminalView, b.terminal?.turns?.isEmpty ?? true {
            var screen = t.visibleText.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            // The prompt waiting at the end, and every line that begins with
            // it — the prompt again, or a command the card says already.
            if b.terminal?.commands?.last?.isRunning != true, let prompt = screen.last {
                screen.removeAll { $0.hasPrefix(prompt) }
            }
            let tail = screen.suffix(2).map { String($0) }
            if !tail.isEmpty { s.lines = Array(s.lines.prefix(1)) + tail }
        }
        s.place = s.place.map { $0.abbreviatingHome }
        var thumbnail: NSImage?
        if s.wantsThumbnail {
            thumbnail = tilePictures[b.id] ?? view.flatMap { HoverCard.picture(of: $0, evenHidden: true) }
        }
        var c = SummaryCardContent(id: id, symbol: Theme.symbolName(for: b), summary: s, thumbnail: thumbnail)
        c.mark = StatusMark(of: b)
        // An $EDITOR's tile as its terminal, editing.
        if let t = stackedTerminal(id) {
            c.symbol = Theme.symbolName(for: t)
            c.summary.title = t.displayTitle
            c.mark?.pill = .note("Editing")
        }
        return c
    }

    func gridFocus(_ placement: PlacementID) { focus(placement) }

    func gridKeptPicture(_ block: BlockID) -> NSImage? { tilePictures[block] }

    /// Edit ▸ Copy Contents (⇧⌘C): the focused block's content as text —
    /// what `mani read` gives: a file's text, a terminal's history, a
    /// page's, a listing, a search's hits — on the pasteboard, whatever
    /// the block is, and said so (or why not).
    @objc func copyContents(_ sender: Any?) {
        guard let f = focusedShown, let b = f.block else { return toast.show("Nothing focused to copy", action: "OK", for: 4) {} }
        let view = views[f.placement.id]
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let text = try await self.maniDesk.contents(of: b, view: view, all: true)
                let pb = NSPasteboard.general
                pb.clearContents()
                pb.setString(text, forType: .string)
                let n = text.split(separator: "\n", omittingEmptySubsequences: false).count
                self.toast.show("Copied “\(b.displayTitle)”: \(n) line\(n == 1 ? "" : "s")", action: "OK", for: 3) {}
            } catch let e as ManiDesk.Failure {
                self.toast.show("Couldn't copy: \(e.message)", action: "OK", for: 5) {}
            } catch {
                self.toast.show("Couldn't copy “\(b.displayTitle)”", action: "OK", for: 5) {}
            }
        }
    }

    func gridKeep(_ picture: NSImage, of block: BlockID) { tilePictures[block] = picture }

    func gridArrive(_ placement: PlacementID) { arrive(atTile: placement) }

    func gridShrinkToSummary(_ placement: PlacementID) { toggleSummary(placement) }

    /// ⇧⌘M: the focused tile down to its summary, or back.
    @objc func shrinkToSummary(_ sender: Any?) {
        guard let f = arrangement?.focused else { return NSSound.beep() }
        toggleSummary(f)
    }

    /// The content height a tile is given in summary: three of its lines.
    private static let summaryPoints: CGFloat = 60

    /// A tile down to its summary — its height given to the biggest other
    /// in its column — or, already there, back to the height it had (or,
    /// not shrunk here, grown a little, as going to it does).
    private func toggleSummary(_ placement: PlacementID) {
        guard let a = arrangement, a.full == nil, let body = contentHeight(of: placement, in: a) else { return NSSound.beep() }
        if body >= GridView.collapseBelow, body < GridView.summarizeBelow {
            if let back = unshrunk.removeValue(forKey: placement), let events = settingHeight(of: placement, share: back, in: a) {
                appendToSelected(events)
            } else {
                arrive(atTile: placement)
            }
            return
        }
        guard let events = settingHeight(of: placement, points: Self.summaryPoints, in: a) else { return NSSound.beep() }
        unshrunk[placement] = a.height(of: placement)
        appendToSelected(events)
    }

    /// Whether a tile is in summary: its content too short for itself.
    func isSummarized(_ placement: PlacementID) -> Bool {
        guard let a = arrangement, a.full == nil, let body = contentHeight(of: placement, in: a) else { return false }
        return body >= GridView.collapseBelow && body < GridView.summarizeBelow
    }

    /// A shown tile's content height, as the grid lays it out; nil for one
    /// docked, or alone in its column.
    func contentHeight(of placement: PlacementID, in a: ArrangementState) -> CGFloat? {
        guard let (c, _) = a.locate(placement) else { return nil }
        let shown = a.columns[c]
        let sum = shown.reduce(0.0) { $0 + a.height(of: $1.id) }
        let usable = content.bounds.height - 2 * GridView.inset - CGFloat(shown.count - 1) * GridView.gap
        guard shown.count > 1, sum > 0, usable > 0 else { return nil }
        return usable * CGFloat(a.height(of: placement) / sum) - GridView.barHeight
    }

    /// A shown tile given `points` of content (or a `share`, as heights
    /// are kept): what it gives up to its nearest neighbour showing its
    /// content (below, then above), what it takes from the biggest other
    /// in its column.
    func settingHeight(of placement: PlacementID, points: CGFloat? = nil, share: Double? = nil, in a: ArrangementState) -> [Event]? {
        guard let (c, _) = a.locate(placement) else { return nil }
        let shown = a.columns[c]
        let sum = shown.reduce(0.0) { $0 + a.height(of: $1.id) }
        let usable = content.bounds.height - 2 * GridView.inset - CGFloat(shown.count - 1) * GridView.gap
        let want = share ?? points.map { Double(($0 + GridView.barHeight) / usable) * sum } ?? a.height(of: placement)
        let delta = want - a.height(of: placement)
        guard usable > 0, let i = shown.firstIndex(where: { $0.id == placement }) else { return nil }
        let others = shown.filter { $0.id != placement }
        let showing = { (p: Placement) in usable * CGFloat(a.height(of: p.id) / sum) - GridView.barHeight >= GridView.summarizeBelow }
        let nearest = (1..<max(shown.count, 2)).lazy.flatMap { d in [i + d, i - d] }.filter { shown.indices.contains($0) }.map { shown[$0] }.first(where: showing)
        guard let other = (delta < 0 ? nearest : nil) ?? others.max(by: { a.height(of: $0.id) < a.height(of: $1.id) }) else { return nil }
        guard a.height(of: other.id) - delta > 0 else { return nil }
        return [.heights([placement: want, other.id: a.height(of: other.id) - delta])]
    }

    func gridCanDrop(_ arrangement: BlockID) -> Bool { arrangement != selected }

    /// Another arrangement dropped on this one: its columns come over.
    func gridDropArrangement(_ arrangement: BlockID, column: Int) {
        guard let id = selected, let source = hosts.arrangement(arrangement) else { return hosts.select(arrangement) }
        hosts.append(source.placements.map { .remove($0.id) }, to: .block(arrangement))
        hosts.append(.adopt(columns: source.columns, at: column), to: .block(id))
        removeFromDesk(arrangement, remember: false)
        hosts.select(id)
    }

    func gridMove(_ placement: PlacementID, column: Int, at: Int, newColumn: Bool) {
        guard let a = arrangement else { return }
        if a.placement(placement) == nil { return bringFromElsewhere(placement, column: column, at: at, newColumn: newColumn) }
        if newColumn || column >= a.columns.count {
            movePlacement(placement, toNewColumn: column, in: a)
        } else {
            appendToSelected(a.moving(placement, column: column, at: at))
        }
    }

    /// A tile dragged here from another workspace (one sprung open from
    /// the sidebar under the drag): its block placed where it was dropped,
    /// in `over`'s place (that one docked) if it was dropped on a tile, and
    /// taken from the workspace it came from — unless ⌥ copies it, shown in
    /// both.
    func bringFromElsewhere(_ placement: PlacementID, column: Int, at: Int, newColumn: Bool, over: PlacementID? = nil,
                                    copy: Bool = NSEvent.modifierFlags.contains(.option)) {
        guard let a = arrangement, let id = selected, let (block, from) = dragged(.placement(placement)), let from else { return }
        let lens = from.placement.lens
        if let t = a.tile(of: block, lens: lens) {
            // Here already: only gone from there.
            focus(t.id)
        } else {
            let new = ULID.make()
            if newColumn || column >= a.columns.count {
                show(block, lens: lens, .inNewColumn(column))
            } else {
                let below = at > 0 && at - 1 < a.columns[column].count ? a.columns[column][at - 1].id : nil
                appendToSelected(below.map { a.bringing(block, lens: lens, inColumn: column, below: $0, newPlacement: { new }) }
                                 ?? [.place(Placement(id: new, block: block, lens: lens), column: column, at: 0)])
                if let over, let now = hosts.arrangement(id), now.placement(new) != nil {
                    appendToSelected(now.replacing(over, with: new))
                }
            }
        }
        if !copy { takeOut(from.placement.id, of: from.arrangement) }
    }

    /// A tile taken off a space it was moved from; the space stays, emptied
    /// or not, until it's removed (§4).
    func takeOut(_ placement: PlacementID, of arrangement: BlockID) {
        hosts.append(.remove(placement), to: .block(arrangement))
    }

    /// A block from the sidebar dropped in the grid: brought there.
    func gridBring(_ block: BlockID, column: Int, at: Int, newColumn: Bool) {
        guard let b = hosts.block(block) else { return }
        place(block, lens: Lens.default(for: b.kind, path: b.path), column: column, at: at, newColumn: newColumn)
    }

    /// A block placed where a drop showed it going: at `at` in `column`,
    /// or a new column there (a workspace dropped, gone to; one already
    /// here, focused).
    func place(_ block: BlockID, lens: Lens, column: Int, at: Int, newColumn: Bool) {
        if hosts.block(block)?.kind == .arrangement { return hosts.select(block) }
        guard let a = arrangement else { return show(block, lens: lens, .here) }
        if newColumn || column >= a.columns.count { return show(block, lens: lens, .inNewColumn(column)) }
        let below = at > 0 && at - 1 < a.columns[column].count ? a.columns[column][at - 1].id : nil
        if let t = a.tile(of: block, lens: lens) { return focus(t.id) }
        if let below {
            appendToSelected(a.bringing(block, lens: lens, inColumn: column, below: below, newPlacement: { ULID.make() }))
        } else {
            appendToSelected([.place(Placement(block: block, lens: lens), column: column, at: 0)])
        }
    }

    /// ⌥-drag: the dragged tile takes a tile's place, that one docked.
    func gridCover(_ placement: PlacementID, over target: PlacementID) {
        if let a = arrangement, a.placement(placement) == nil, let (c, i) = a.locate(target) {
            return bringFromElsewhere(placement, column: c, at: i + 1, newColumn: false, over: target)
        }
        cover(placement, over: target)
    }

    /// Close Column, on a maximized tile's menu: it and every tile in its
    /// column taken off the space (as ⌘W takes one; the blocks keep).
    func gridCloseColumn(_ placement: PlacementID) {
        guard let a = arrangement, let id = selected, let (c, _) = a.locate(placement) else { return }
        let before = hosts.reachable()
        for p in a.columns[c] { noteClosing(p.id, in: id) }
        appendToSelected((a.full == placement ? [Event.full(nil)] : []) + a.columns[c].map { .remove($0.id) })
        afterClosing(reachedBefore: before)
    }

    /// A pill clicked: its tile grows a step, as acme's does.
    func gridGrow(_ placement: PlacementID) {
        guard let a = arrangement else { return }
        // Just filled (⌘- or ⌥-clicked): clicked, its column as it was (acme's).
        if unfill(placement) { return }
        appendToSelected(a.growing(placement))
    }

    /// A pill ⌘-clicked: its tile fills the column, the others docked.
    func gridFill(_ placement: PlacementID) { fill(placement, keepingBars: false) }

    /// A column as it was before a tile filled it — its tiles' shares, and
    /// those the filling docked — and as the filling left it, to tell it's
    /// still so.
    struct ColumnFill {
        var space: BlockID
        var tile: PlacementID
        var before: [PlacementID: Double]
        var docked: [PlacementID]
        var after: [PlacementID]
        var afterHeights: [PlacementID: Double]
    }

    /// A tile filling its column — the others docked (⌘-click), or down
    /// to their bars (`keepingBars`, ⌥-click) — the column as it was kept,
    /// for a click on its bar to put back.
    func fill(_ placement: PlacementID, keepingBars: Bool) {
        guard let a = arrangement, let space = selected, let (c, _) = a.locate(placement) else { return }
        let events = keepingBars ? a.squeezing(placement) : a.growing(placement, whole: true)
        guard !events.isEmpty else { return }
        var after = a
        for e in events { after.apply(e) }
        let column = a.columns[c]
        let left = after.locate(placement).map { after.columns[$0.0] } ?? []
        columnFill = ColumnFill(space: space, tile: placement,
                                before: Dictionary(uniqueKeysWithValues: column.map { ($0.id, a.height(of: $0.id)) }),
                                docked: column.map(\.id).filter { after.isDocked($0) },
                                after: left.map(\.id),
                                afterHeights: Dictionary(uniqueKeysWithValues: left.map { ($0.id, after.height(of: $0.id)) }))
        appendToSelected(events)
    }

    /// The column a tile filled put back as it was — those docked back
    /// where they were, every share as it was — if it's still as the
    /// filling left it; else (changed since) nothing, and forgotten.
    private func unfill(_ placement: PlacementID) -> Bool {
        guard let f = columnFill, f.tile == placement else { return false }
        columnFill = nil
        guard f.space == selected, let a = arrangement, let (c, _) = a.locate(placement),
              a.columns[c].map(\.id) == f.after,
              f.after.allSatisfy({ abs(a.height(of: $0) - (f.afterHeights[$0] ?? -1)) < 1e-6 }),
              f.docked.allSatisfy(a.isDocked) else { return false }
        appendToSelected(a.unfilling(f.docked, heights: f.before, focus: placement))
        return true
    }


    /// A bar ⌥-clicked: its tile takes the column but for the others'
    /// bars, which stay in the grid.
    func gridSqueeze(_ placement: PlacementID) { fill(placement, keepingBars: true) }

    func gridToggleFull(_ placement: PlacementID) {
        guard let a = arrangement else { return }
        appendToSelected([.full(a.full == placement ? nil : placement)])
    }

    /// ⌘M: the focused tile into the stack behind its nearest tile — the
    /// shown one above it in the column, else the column's first — as
    /// Stash in a pill's menu does; the focus goes to that tile.
    /// ⌘M: the focused tile docked (§3.1) — out of the grid, its room
    /// back where it came from, listed under its space in the sidebar;
    /// gone to again (⌃⇥, its row, a link), it goes back where it was.
    @objc func dockTile(_ sender: Any?) {
        guard let a = arrangement, let f = a.focused, a.locate(f) != nil else { return NSSound.beep() }
        dock(f)
    }

    func dock(_ placement: PlacementID) {
        guard let a = arrangement else { return }
        // Out of sight: pictured now, for a card of it (⌃⇥) to come from.
        if let v = views[placement] { picture([v]) }
        appendToSelected((a.full == placement ? [Event.full(nil)] : []) + a.docking(placement))
    }

    /// ⇧⌘↩: the focused tile over the whole arrangement, or back.
    @objc func toggleMaximize(_ sender: Any?) {
        guard let a = arrangement, let f = a.focused else { return }
        gridToggleFull(f)
    }

    func gridResized(fractions: [Double]) { appendToSelected([.fractions(fractions)]) }
    /// Debugging: the columns' widths set, as a divider dragged sets them.
    func debugSetFractions(_ f: [Double]) { gridResized(fractions: f) }
    /// A line between tiles dragged: the shares as it left them; a tile
    /// pushed to nothing, docked (its room to the tile that pushed it).
    func gridResized(heights: [PlacementID: Double]) {
        let gone = heights.filter { $0.value == 0 }.map(\.key).sorted()
        appendToSelected(gone.map { Event.dock($0, heir: nil) } + [.heights(heights.filter { $0.value > 0 })])
    }
    func gridDragChanged(_ dragging: Bool) { dragChanged(dragging) }

    /// Things dropped on the grid (§3.11), each a tile of its own where they
    /// landed, in order: a block brought (gone to the place in it); a file
    /// opened as Manifold opens it (one it doesn't, by the Mac's app for
    /// it); a page; a picture kept as an image block; words, a note.
    func gridOpen(_ d: Dragged, column: Int, at: Int, newColumn: Bool) {
        var slot = (column: column, at: at, newColumn: newColumn)
        // Each below the one before.
        func next(_ block: BlockID, _ lens: Lens) {
            place(block, lens: lens, column: slot.column, at: slot.at, newColumn: slot.newColumn)
            slot = (slot.column, slot.newColumn ? 1 : slot.at + 1, false)
        }
        if d.things.isEmpty {
            if !d.promised.isEmpty {
                return Promises.receive(d.promised) { [weak self] urls in
                    self?.gridOpen(files: urls.map(\.path), column: column, at: at, newColumn: newColumn)
                }
            }
            let place: Where = newColumn ? .inNewColumn(column) : .inColumn(min(column, max((arrangement?.columns.count ?? 1) - 1, 0)))
            return d.pictureData { [weak self] pictures in
                for (data, kind) in pictures { self?.keepDroppedImage(data, kind: kind, place: place) }
            }
        }
        for t in d.things {
            if t.block == nil, let c = t.commit {
                // A commit: its diff, made if it isn't yet.
                if let b = Drags.commitBlock?(c) { next(b, .diff) }
            } else if let b = t.block, let block = hosts.block(b) {
                next(b, Lens.default(for: block.kind, path: block.path))
                if let at = t.at { goTo(at, in: b) }
            } else if let f = t.file {
                guard let (b, lens) = pathBlock(f.path, isDirectory: f.isDirectory, on: f.host) else {
                    if f.host == host.host { NSWorkspace.shared.open(URL(fileURLWithPath: f.path)) }
                    continue
                }
                next(b, lens)
                if let at = t.at { goTo(at, in: b) }
            } else if let u = t.url {
                next(host.newWeb(url: u), .web)
            } else if let text = t.text {
                // Words dropped: a note of them, at home where the focused block is.
                next(host.newNote(home: focusedHost == host.host ? focusedCwd : nil, text: text), .editor)
            }
        }
    }

    var gridLocalHost: HostID { host.host }

    /// This Mac's files (from the Finder, written by another app) opened
    /// where they landed, as dropped things are.
    func gridOpen(files paths: [String], column: Int, at: Int, newColumn: Bool) {
        let things = paths.map { path -> DragThing in
            var dir: ObjCBool = false
            _ = FileManager.default.fileExists(atPath: path, isDirectory: &dir)
            return DragThing(title: path.lastPathComponent, file: .init(host: host.host, path: path, isDirectory: dir.boolValue), outside: true)
        }
        let pb = NSPasteboard(name: NSPasteboard.Name("com.manifold.opened-files"))
        pb.clearContents()
        pb.writeObjects(things.map(Drags.item))
        guard let d = Dragged(pb) else { return }
        gridOpen(d, column: column, at: at, newColumn: newColumn)
    }

    /// A picture dropped on the grid, kept as an image block (in
    /// Manifold's folder), shown once it's there.
    func keepDroppedImage(_ data: Data, kind: String, place: Where) {
        let id = BlockID(host: host.host)
        let name = newImageName(kind: kind)
        Transfers.shared.run(name, detail: "to \(hosts.label(of: host.host))", symbol: "photo") { [host] _, done in
            host.saveImage(data, block: id, name: name, folder: nil) { error, _ in done(error) }
            return nil
        } then: { [weak self] error in
            guard let self else { return }
            if let error { return self.toast.show("Couldn't keep the image: \(error)", action: "OK", for: 8) {} }
            self.showWhenMade(id, lens: .image, place: place, what: "the image")
        }
    }

    func gridShowMap(for placement: PlacementID) {
        guard let b = arrangement?.placement(placement)?.block else { return }
        showNeighborhood(around: b)
    }

    func gridDragAtLeftEdge() {
        if !sidebarShown { showSidebar(animated: true) }
    }

    /// A tile's pill clicked: its menu.
    /// ⌥-click on a pill: where the block is, as a path — the file or
    /// folder, then each folder up to the root (a terminal's working
    /// directory likewise); choosing one browses that folder here, as
    /// ⌘-clicking a document's title does in the Finder.
    func gridPathMenu(for placement: PlacementID) -> NSMenu? {
        guard let a = arrangement, let p = a.placement(placement), let b = hosts.block(p.block) else { return nil }
        let on = b.id.host
        guard let start = b.path ?? b.terminal?.cwd ?? b.home, start.hasPrefix("/") else { return nil }
        let menu = NSMenu()
        var path = start
        var first = true
        while true {
            let name = path == "/" ? "/" : path.lastPathComponent
            let isFolder = !first || b.path == nil || b.kind == .directory
            let here = path
            let item = ClosureMenuItem(name, symbol: isFolder ? "folder" : Theme.symbolName(for: b)) { [weak self] in
                guard let self else { return }
                if isFolder, let client = self.hosts.client(on) {
                    self.show(client.directoryBlock(for: here), lens: .directory, .here)
                } else {
                    self.focus(placement)
                }
            }
            item.indentationLevel = 0
            menu.addItem(item)
            if path == "/" { break }
            path = path.deletingLastPathComponent
            if path.isEmpty { path = "/" }
            first = false
        }
        return menu
    }

    func gridPillMenu(for placement: PlacementID) -> NSMenu? {
        guard let a = arrangement, let p = a.placement(placement), let id = selected else { return nil }
        let block = p.block
        let menu = NSMenu()
        let maximized = a.full == placement
        menu.addItem(ClosureMenuItem(maximized ? "Restore" : "Maximize", symbol: maximized ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right") { [weak self] in self?.gridToggleFull(placement) })
        // As the pill's clicks are (a column just filled, put back first).
        menu.addItem(ClosureMenuItem("Grow", symbol: "arrow.up.and.down") { [weak self] in self?.gridGrow(placement) })
        if maximized, let c = a.columnIndex(of: placement), a.columns[c].count > 1 {
            // Maximized, the column behind it: closed with it.
            menu.addItem(ClosureMenuItem("Close Column", symbol: "rectangle.stack.badge.minus") { [weak self] in self?.gridCloseColumn(placement) })
        }
        menu.addItem(ClosureMenuItem("Fill the Column", symbol: "rectangle.expand.vertical") { [weak self] in self?.gridFill(placement) })
        if !maximized, contentHeight(of: placement, in: a) != nil {
            let summarized = isSummarized(placement)
            menu.addItem(ClosureMenuItem(summarized ? "Show Content" : "Shrink to Summary", symbol: summarized ? "rectangle.expand.vertical" : "rectangle.compress.vertical",
                                         key: "M") { [weak self] in self?.toggleSummary(placement) })
        }
        if let t = hosts.block(block)?.text, t.isDirty {
            menu.addItem(.separator())
            if t.stale {
                menu.addItem(ClosureMenuItem("Reload", symbol: "arrow.clockwise") { [weak self] in self?.hosts.propose(.readFile(block)) })
                menu.addItem(ClosureMenuItem("Keep Mine", symbol: "square.and.arrow.down") { [weak self] in self?.save(block, from: placement) })
            } else {
                menu.addItem(ClosureMenuItem("Save", symbol: "square.and.arrow.down", key: "s") { [weak self] in self?.save(block, from: placement) })
            }
        }
        if let ws = selected {
            let on = isPinned(block, in: ws)
            let pin = ClosureMenuItem(on ? "Unpin" : "Pin in Space", symbol: on ? "pin.slash" : "pin", key: "t") { [weak self] in
                self?.setPinned(block, in: ws, !on)
            }
            pin.keyEquivalentModifierMask = [.command, .control]
            menu.addItem(pin)
        }
        if views[placement]?.outline != nil {
            menu.addItem(ClosureMenuItem("Find in Outline…", symbol: "list.bullet.rectangle", key: "P") { [weak self] in
                guard let self else { return }
                self.focus(placement)
                self.searchOutline(of: placement)
            })
        }
        if a.locate(placement) != nil {
            menu.addItem(ClosureMenuItem("Dock", symbol: "dock.arrow.down.rectangle", key: "m") { [weak self] in self?.dock(placement) })
        }
        menu.addItem(.separator())
        if let own = views[placement]?.pillItems, !own.isEmpty {
            for item in own { menu.addItem(item) }
            menu.addItem(.separator())
        }
        if hosts.block(block)?.statusRecord != nil {
            menu.addItem(ClosureMenuItem("Clear Status", symbol: "eraser") { [weak self] in self?.hosts.propose(.clearStatus(block)) })
        }
        if let last = hosts.block(block)?.terminal?.turns?.last {
            let sub = NSMenu()
            for item in turnItems(last, of: block, beside: placement) { sub.addItem(item) }
            let item = NSMenuItem(title: "Last Turn", action: nil, keyEquivalent: "")
            item.setSymbol("text.bubble", size: 12)
            item.submenu = sub
            menu.addItem(item)
        }
        if let o = hosts.block(block)?.output, o.markdown != nil, let agent = o.source, let id = o.command,
           let turn = hosts.block(agent)?.terminal?.turns?.first(where: { $0.id == id }) {
            for item in turnItems(turn, of: agent, beside: placement).dropFirst() { menu.addItem(item) }
        }
        if let snap = hosts.block(block)?.terminal?.snapshot {
            menu.addItem(ClosureMenuItem("Changes Since It Started", symbol: "plusminus") { [weak self] in
                self?.showAgentChanges(block, snap, beside: placement)
            })
        }
        let agents = NSMenu()
        for item in agentMenuItems() { agents.addItem(item) }
        let launch = NSMenuItem(title: "Launch Agent Here", action: nil, keyEquivalent: "")
        launch.setSymbol("sparkle", size: 12)
        launch.submenu = agents
        menu.addItem(launch)
        menu.addItem(ClosureMenuItem("Show the Neighborhood Map", symbol: "point.3.connected.trianglepath.dotted") { [weak self] in
            self?.showNeighborhood(around: block)
        })
        if let b = hosts.block(block), b.isNote {
            menu.addItem(ClosureMenuItem("Name…", symbol: "pencil") { [weak self] in self?.nameNote(placement) })
        }
        if let b = hosts.block(block), b.kind == .text, p.lens.isText {
            let viewing = p.lens == .preview
            menu.addItem(ClosureMenuItem(viewing ? "Edit" : "View", symbol: viewing ? "pencil" : "eye", key: "\r") { [weak self] in self?.toggleMode(placement) })
        }
        if let outline = outlinerItem(block, tile: placement) { menu.addItem(outline) }
        menu.addItem(.separator())
        for item in copyItems(for: block) { menu.addItem(item) }
        menu.addItem(.separator())
        menu.addItem(hostSubmenu(block.host))
        menu.addItem(ClosureMenuItem("Close Tile", symbol: "xmark", key: "w") { [weak self] in self?.closeTile(placement, in: id) })
        if hosts.block(block)?.kind == .text {
            let saveClose = ClosureMenuItem("Save and Close", symbol: "square.and.arrow.down", key: "w") { [weak self] in self?.saveAndClose(tile: placement) }
            saveClose.keyEquivalentModifierMask = [.command, .option]
            menu.addItem(saveClose)
        }
        let delete = ClosureMenuItem("Delete Block", symbol: "trash", key: "w") { [weak self] in self?.deleteBlock(block) }
        delete.keyEquivalentModifierMask = [.command, .shift]
        menu.addItem(delete)
        return menu
    }

    /// A block as a thing dragged (§3.11) — a tile ⇧-dragged, a sidebar
    /// row, a card, an outline's item (a place in it, by its words): the
    /// block, its file if it's one, the folder a terminal is in, a page's
    /// address. One the host is making now (a turn's) by its link alone,
    /// to land as it comes.
    func dragThing(_ id: BlockID, at: Locator? = nil, title: String? = nil) -> DragThing {
        let b = hosts.block(id)
        var t = DragThing(block: id, at: at, title: title ?? b?.displayTitle ?? "")
        guard let b else { return t }
        if let path = b.path, [.text, .image, .pdf, .directory].contains(b.kind) {
            t.file = .init(host: id.host, path: path, isDirectory: b.kind == .directory)
        } else if let dir = b.place, dir.hasPrefix("/") {
            t.folder = .init(host: id.host, path: dir, isDirectory: true)
        }
        t.url = b.web?.url
        t.text = at != nil ? title : b.web?.url
        // A commit's diff: the commit, its sha its words.
        if at == nil, case let .commit(repo, sha)? = b.diff?.subject {
            t.commit = .init(host: id.host, repo: repo, sha: sha, summary: t.title)
            t.text = sha
        }
        return t
    }

    /// Copy Link (a `manifold:` address that opens the block from any app
    /// on this Mac — Slack, Notes, a commit message); Copy Path and Reveal
    /// in Finder for what has a place.
    func copyItems(for block: BlockID) -> [NSMenuItem] {
        guard let b = hosts.block(block) else { return [] }
        var items: [NSMenuItem] = [ClosureMenuItem("Copy Link", symbol: "link") { [weak self] in self?.copyLink(to: block) }]
        if let path = b.path ?? b.terminal?.cwd ?? b.place {
            items.append(ClosureMenuItem("Copy Path", symbol: "doc.on.clipboard") {
                NSPasteboard.copy(path)
            })
            if block.host == host.host, FileManager.default.fileExists(atPath: path) {
                items.append(ClosureMenuItem("Reveal in Finder", symbol: "folder") {
                    NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
                })
            }
        }
        // A folder (a terminal's): looked through.
        if let dir = b.kind == .directory ? b.path : b.terminal?.cwd {
            items.append(ClosureMenuItem("Find in This Folder…", symbol: "magnifyingglass") { [weak self] in
                self?.findInFolder(dir, on: block.host, from: self?.arrangement?.placements(of: block).first?.id)
            })
        }
        // A file: opened with an app here (another host's, a copy sent
        // back when saved), or fetched to Downloads.
        if let path = b.path, [.text, .image, .pdf, .directory].contains(b.kind) {
            if b.kind != .directory { items.append(openWithItem(path, on: block.host)) }
            if block.host != host.host {
                items.append(ClosureMenuItem("Download", symbol: "arrow.down.circle") { [weak self] in
                    self?.download(path, on: block.host)
                })
            }
        }
        return items
    }

    /// A place's address on the clipboard, anchored (§2.5): as a link where
    /// links are taken (its name over it), as text elsewhere, as a block's
    /// link in a note.
    func copyLink(to place: Place) {
        guard let (id, at) = resolved(place) else { return }
        copyLink(to: id, fragment: at?.fragment)
    }

    /// The block's address on the clipboard: as a link where links are
    /// taken (its name over it), as text elsewhere, as a block's link in a note.
    func copyLink(to block: BlockID, fragment: String? = nil) {
        guard let b = hosts.block(block) else { return }
        let address = "manifold:\(block.description)" + (fragment.map { "#" + $0 } ?? "")
        let title = b.displayTitle.replacingOccurrences(of: "]", with: "\\]")
        let pb = NSPasteboard.general
        pb.clearContents()
        let item = NSPasteboardItem()
        item.setString(address, forType: .string)
        item.setString(address, forType: .URL)
        item.setString("<a href=\"\(address)\">\(b.displayTitle.replacingOccurrences(of: "<", with: "&lt;"))</a>", forType: .html)
        item.setString("[\(title)](\(address))", forType: .manifoldBlockLink)
        pb.writeObjects([item])
    }

    // MARK: Walks through code (§2.5)

    /// A walk under way: a note's references, in its text's order, each a
    /// step shown beside it in one tile (the walk's), the note keeping the
    /// keyboard — ⌃⌘] the next, ⌃⌘[ the one before.
    struct CodeWalk {
        var note: BlockID
        var notePlacement: PlacementID
        /// Each step's reference, and where it's written in the note.
        var steps: [(address: String, range: TextRange)]
        var index: Int
        var tile: PlacementID?
    }

    @objc func nextStep(_ sender: Any?) { step(1) }
    @objc func previousStep(_ sender: Any?) { step(-1) }

    /// The references a text holds, in order (a step again only when it
    /// isn't the one just before).
    static func steps(in text: Rope) -> [(address: String, range: TextRange)] {
        guard let re = try? NSRegularExpression(pattern: BlockID.referencePattern) else { return [] }
        let s = text.string, ns = s as NSString
        var out: [(String, TextRange)] = []
        for m in re.matches(in: s, range: NSRange(location: 0, length: ns.length)) {
            let address = ns.substring(with: m.range)
            guard out.last?.0 != address else { continue }
            let start = text.byteOffset(ofUTF16: m.range.location), end = text.byteOffset(ofUTF16: NSMaxRange(m.range))
            out.append((address, TextRange(start, end)))
        }
        return out
    }

    private func step(_ d: Int) {
        // The focused text's walk: begun at its first step, unless it's the
        // one under way (or the walk's own tile is focused).
        if let f = focusedShown, let b = f.block, b.kind == .text, f.placement.id != codeWalk?.tile, b.id != codeWalk?.note,
           let text = b.text?.text {
            let steps = Self.steps(in: text)
            guard !steps.isEmpty else { return NSSound.beep() }
            codeWalk = CodeWalk(note: b.id, notePlacement: f.placement.id, steps: steps, index: d > 0 ? -1 : steps.count, tile: nil)
        }
        guard var w = codeWalk else { return NSSound.beep() }
        // The note edited meanwhile: its references as they are now.
        if let text = hosts.block(w.note)?.text?.text { w.steps = Self.steps(in: text) }
        let i = w.index + d
        guard w.steps.indices.contains(i), let (id, fragment) = BlockID.link(w.steps[i].address), let b = hosts.block(id) else {
            codeWalk = w
            return NSSound.beep()
        }
        w.index = i
        let lens = Lens.default(for: b.kind, path: b.path)
        // In the walk's tile if it's still there, else a new one beside the note.
        if let tile = w.tile, let a = arrangement, let p = a.placement(tile) {
            if p.block != id {
                let next = ULID.make()
                replace(tile, with: id, lens: lens, as: next)
                w.tile = next
            }
        } else {
            show(id, lens: lens, .here, context: "a step of a walk")
            w.tile = arrangement?.tile(of: id, lens: lens)?.id
        }
        codeWalk = w
        // The keyboard back with the note, its step chosen in it.
        appendToSelected([.focus(w.notePlacement)])
        if let e = views[w.notePlacement] as? EditorView {
            e.textView.setSelections([Selection(w.steps[i].range.start, w.steps[i].range.end)])
        }
        if let fragment { goTo(fragment, in: id) }
        let name = fragment.flatMap { b.anchors?[$0] }.map(Anchoring.name(of:)) ?? b.displayTitle
        toast.show("Step \(i + 1) of \(w.steps.count): \(name)", action: "End Walk", for: 3) { [weak self] in self?.codeWalk = nil }
    }

    // MARK: Anchors (§2.5)

    /// A reference to a line of a text (from 0): to the declaration or
    /// heading there, else the line — its anchor found among the block's,
    /// or minted in its log.
    /// `exactly`: the line itself unless a declaration starts on it (a
    /// use of a symbol, not the function it's in).
    func reference(toLine line: Int, in id: BlockID, exactly: Bool = false) -> String? {
        guard let b = hosts.block(id), let wanted = Anchoring.anchor(atLine: line, of: b, exactly: exactly) else { return nil }
        return reference(to: wanted, in: id)
    }

    /// A reference to the place `wanted` is at: the block's anchor for it,
    /// or one minted in its log.
    func reference(to wanted: Anchor, in id: BlockID) -> String? {
        guard let b = hosts.block(id) else { return nil }
        if let a = Anchoring.existing(wanted, in: b) {
            if a.scip == nil { nameInIndex(a, of: id) }
            return Self.address(id, anchor: a.id)
        }
        var a = wanted
        a.id = Anchor.newID(taken: Set(b.anchors?.keys.map { $0 } ?? []))
        hosts.append([.anchor(a)], to: .block(id))
        nameInIndex(a, of: id)
        return Self.address(id, anchor: a.id)
    }

    /// A declaration's anchor given its name in the project's SCIP index,
    /// if there's one (asked of the host; nothing if not).
    private func nameInIndex(_ a: Anchor, of id: BlockID) {
        guard case .symbol = a.at, let b = hosts.block(id), let path = b.path, let rope = b.text?.text, let r = a.range,
              let language = SyntaxLanguage.forPath(path) else { return }
        let decl = SyntaxTree(language, text: rope, background: false).declarations().first { $0.range == r }
        let at = decl?.nameRange.start ?? r.start
        let line = rope.line(at: at)
        hosts.scip(.symbol(path: path, line: line, byte: at - rope.offset(ofLine: line)), on: id.host) { [weak self] result in
            guard let self, case .symbol(let s?) = result, var now = self.hosts.block(id)?.anchors?[a.id], now.scip != s.symbol else { return }
            now.scip = s.symbol
            self.hosts.append([.anchor(now)], to: .block(id))
        }
    }

    static func address(_ id: BlockID, anchor: String? = nil) -> String {
        "manifold:\(id)" + (anchor.map { "#" + $0 } ?? "")
    }

    /// An anchor gone to: where it is now (put right in its block if it
    /// was found elsewhere), or why not — the place gone. A text not read
    /// yet is waited for a moment.
    /// An anchor a reference names that its block hasn't got — made while
    /// a server from before anchors (protocol 61) dropped it — found again
    /// by the words of a link to it in the text it's followed from (the
    /// focused one, a walk's note), and kept under the same id, so every
    /// reference to it goes there from now on.
    private func recoverAnchor(_ anchor: String, in id: BlockID) -> Bool {
        guard let b = hosts.block(id), b.anchors?[anchor] == nil, let text = b.text, !text.isUnread,
              let re = try? NSRegularExpression(pattern: "\\[([^\\]\\n]+)\\]\\(manifold:[^)#\\s]*\\Q\(id.ulid)\\E#\(anchor)\\)") else { return false }
        let sources = [focusedShown?.block?.id, codeWalk?.note].compactMap { $0 }.compactMap { hosts.block($0)?.text?.text.string }
        for s in sources {
            guard let m = re.firstMatch(in: s, range: NSRange(location: 0, length: (s as NSString).length)) else { continue }
            let words = (s as NSString).substring(with: m.range(at: 1))
            guard var found = Anchoring.find(named: words, in: b) else { continue }
            found.id = anchor
            hosts.append([.anchor(found)], to: .block(id))
            nameInIndex(found, of: id)
            return true
        }
        return false
    }

    func goToAnchor(_ anchor: String, in id: BlockID, tries: Int = 20) {
        // An anchor just minted (a reference made and followed at once) is
        // waited for a moment, as a text not read yet is.
        guard let b = hosts.block(id), let a = b.anchors?[anchor], !(b.text?.isUnread ?? false) else {
            guard hosts.block(id) != nil else { return }
            // Not come after a while: lost, perhaps — found again by a link's words.
            if tries == 16, recoverAnchor(anchor, in: id) { return goToAnchor(anchor, in: id, tries: tries - 1) }
            guard tries > 0 else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in self?.goToAnchor(anchor, in: id, tries: tries - 1) }
            return
        }
        // A command's or a page's: gone to as that place is.
        switch a.at {
        case let .command(n): return goToCommand(n, in: id)
        case let .page(n): return goToPlace(.page(n - 1), in: id)
        default: break
        }
        guard let (range, putRight) = Anchoring.locate(a, in: b), let rope = b.text?.text else {
            // Gone from its file: where the index says it's defined now, if
            // it knows it (moved to another file).
            let gone = "“\(Anchoring.name(of: a))” is no longer in \(b.displayTitle)"
            guard let symbol = a.scip, let path = b.path else { return sayMissing(why: gone) }
            hosts.scip(.definition(symbol: symbol, path: path), on: id.host) { [weak self] result in
                guard let self else { return }
                guard case .locations(let found) = result, let there = found.first, there.path != path else { return self.sayMissing(why: gone) }
                self.open(path: there.path, line: there.line + 1, column: nil, on: id.host, from: self.arrangement?.focused, context: "moved")
                self.toast.show("“\(Anchoring.name(of: a))” moved to \(there.path.lastPathComponent)", action: "OK", for: 4) {}
            }
            return
        }
        if let putRight { hosts.append([.anchor(putRight)], to: .block(id)) }
        goToPlace(.line(rope.line(at: range.start) + 1), in: id)
    }

    /// A block gone to that isn't there: why (`Hosts.whyMissing`), by
    /// the pointer when a click in the window went to it, else at the
    /// window's foot (a link opened from another app).
    func sayMissing(_ id: BlockID) { sayMissing(why: hosts.whyMissing(id) ?? "There's nothing there") }

    func sayMissing(why: String) {
        let mouse: Set<NSEvent.EventType> = [.leftMouseDown, .leftMouseUp, .rightMouseDown, .rightMouseUp, .otherMouseDown, .otherMouseUp]
        if let e = NSApp.currentEvent, e.window === window, mouse.contains(e.type) {
            ReferenceTip.say(why, in: window)
        } else {
            toast.show(why, action: "OK", for: 6) {}
        }
    }

    func openLink(_ address: String) {
        guard BlockID.link(address) != nil else { return NSSound.beep() }
        open(address, from: arrangement?.focused)
    }

    /// Moves a placement into a new column at `index`.
    private func movePlacement(_ placement: PlacementID, toNewColumn index: Int, in a: ArrangementState) {
        guard let (sc, _) = a.locate(placement) else { return }
        let only = a.columns[sc].count == 1
        if only, index == sc || index == sc + 1 { return }
        // Past the end makes a new column; then it's moved into place.
        appendToSelected([.move(placement, column: a.columns.count, at: 0)])
        guard let now = arrangement else { return }
        let from = now.columns.count - 1
        var to = index
        if only, sc < index { to -= 1 }
        reorderColumn(from: from, to: min(to, from))
    }

}
