import AppKit
import ManifoldCore

/// The sidebar's Threads (§3.12, ⌥⌘3): the space's timeline, as Quip
/// keeps a document's conversation — every entry interleaved, newest
/// last, a New rule above what you haven't seen. (The list by title is
/// the footer's menu: one way to each thing, as Dia's.)
extension MainWindowController {

    /// The threads the sidebar shows, by its filter: the space's or its
    /// project's; all, the open, or the unread.
    func sidebarThreads() -> [Block] {
        guard let space = selected else { return [] }
        let v = sidebar.timeline
        var all = hosts.threads(inSpace: space)
        if v.model.scope == 1, let p = project(ofSpace: space) { all = hosts.threads(inProject: p.root, on: p.host) }
        switch v.filter {
        case .all: return all
        case .open: return all.filter { $0.thread?.resolved != true }
        case .unread: return all.filter { !hosts.unseen($0).isEmpty }
        }
    }

    /// The threads' filter, as their header's button offers it.
    func sidebarThreadsFilterMenu() -> NSMenu {
        let menu = NSMenu()
        let v = sidebar.timeline
        for (f, title) in [(ThreadTimelineView.Filter.all, "All Threads"), (.open, "Open"), (.unread, "Unread")] {
            let item = ClosureMenuItem(title) { [weak self] in
                guard let self else { return }
                self.sidebar.timeline.filter = f
                self.sidebarThreadsChanged()
            }
            item.state = v.filter == f ? .on : .off
            menu.addItem(item)
        }
        if let space = selected, let p = project(ofSpace: space) {
            menu.addItem(.separator())
            for (i, title) in ["In This Space", "In " + p.root.lastPathComponent].enumerated() {
                let item = ClosureMenuItem(title) { [weak self] in
                    guard let self else { return }
                    self.sidebar.timeline.setScope(i)
                    self.sidebarThreadsChanged()
                }
                item.state = v.model.scope == i ? .on : .off
                menu.addItem(item)
            }
        }
        return menu
    }

    func sidebarMarkThreadsRead() { hosts.markSeen(sidebarThreads()) }

    private func sidebarThreadsChanged() {
        sidebar.timeline.marksWhenOpened = nil
        refreshSidebarThreads()
        refreshOrganization(now: true)
    }

    /// The composer for a thread about the space, in the overlay.
    func newThreadAboutSpace() {
        guard let space = selected else { return NSSound.beep() }
        showThreadOverlay(ThreadPlace(block: space, title: hosts.arrangement(space).map(title(of:))), tab: 0)
    }

    /// The foot row's count, the header's words, and the timeline, when
    /// it's what shows.
    func refreshSidebarThreads() {
        let space = selected
        let all = space.map { hosts.threads(inSpace: $0) } ?? []
        sidebar.setFoot(threads: all.count, open: all.filter { $0.thread?.resolved != true }.count,
                        unseen: all.filter { !hosts.unseen($0).isEmpty }.count)
        sidebar.setThreadsFilter(narrowed: sidebar.timeline.filter != .all || sidebar.timeline.model.scope != 0,
                                 unseen: sidebarThreads().reduce(0) { $0 + hosts.unseen($1).count })
        guard organization == .threads else { return }
        let v = sidebar.timeline
        if v.space != space {
            v.space = space
            v.marksWhenOpened = nil
            v.choose(nil)
        }
        watch(v)
    }

    /// Debugging the sidebar's threads: `sidebarthreads [timeline|close]`
    /// and what it shows.
    func debugSidebarThreads(_ arg: String) -> String {
        switch arg {
        case "timeline", "list": setOrganization(.threads)
        case "close": setOrganization(.desk)
        default:
            // "sidebarthreads head <i>|popout <i>": run i's heading clicked, or its pop-out.
            let w = arg.split(separator: " ")
            let runs = sidebar.timeline.model.runs
            if w.count == 2, let i = Int(w[1]), runs.indices.contains(i) {
                if w[0] == "head" { timeline(sidebar.timeline, goToPlaceOf: runs[i].thread.id) }
                if w[0] == "popout" { timeline(sidebar.timeline, popOut: runs[i].thread.id) }
            }
        }
        guard organization == .threads else { return "not shown" }
        let m = sidebar.timeline.model
        return sidebar.timeline.box.debugState + "\ntimeline · \(m.title) · \(m.runs.count) runs · \(m.unseen) unseen · " + m.runs.map { $0.placeTitle + ($0.firstUnseen != nil ? " NEW" : "") }.joined(separator: " | ")
    }
}

extension MainWindowController {
    /// Debugging the focused diff: folding, selecting, scrolling across, copying, dragging.
    func debugDiffView(_ arg: String) -> String {
        guard let f = arrangement?.focused, let d = views[f] as? DiffView else { return "no diff focused" }
        let w = arg.split(separator: " ", maxSplits: 1).map(String.init)
        switch w.first {
        case "fold": return d.debugFold(w.count > 1 ? w[1] : nil)
        case "select":
            let n = (w.count > 1 ? w[1] : "").split(separator: " ").compactMap { Int($0) }
            guard n.count == 5 else { return "usage: select <side> <line> <col> <line> <col>" }
            return d.debugSelect(side: n[0], from: (n[1], n[2]), to: (n[3], n[4]))
        case "pointer", "click":
            let n = (w.count > 1 ? w[1] : "").split(separator: " ").compactMap { Int($0) }
            guard n.count == 3, let rows = d.focusView as? DiffRowsView else { return "usage: pointer|click <side> <line> <col>" }
            return rows.debugPointer(side: n[0], line: n[1], col: n[2], click: w[0] == "click")
        case "above": return d.debugMore(above: Int(w.count > 1 ? w[1] : ""), below: nil)
        case "below": return d.debugMore(above: nil, below: w.count > 1 ? w[1] : nil)
        case "across": return d.debugScrollAcross(CGFloat(Double(w.count > 1 ? w[1] : "0") ?? 0))
        case "copy":
            NSApp.sendAction(#selector(DiffRowsView.copy(_:)), to: d.focusView, from: nil)
            return NSPasteboard.general.string(forType: .string) ?? "nothing"
        case "drag":
            guard let p = d.place(rows: d.selectedRows) else { return "no place for rows \(d.selectedRows): file \(d.selectedRows.first.flatMap(d.filePath(ofRow:)) ?? "-"), rows \(d.selectedRows.map { "\(d.rows[$0].kind) \(d.rows[$0].oldLine.map(String.init) ?? "-")/\(d.rows[$0].newLine.map(String.init) ?? "-")" })" }
            guard let item = Drags.place?(p, d.selectedText) else { return "no drag" }
            let thing = item.data(forType: .manifoldThing).flatMap { String(data: $0, encoding: .utf8) } ?? "-"
            return "string: \(item.string(forType: .string) ?? "-")\nthing: \(thing)"
        default: return d.debugFold(nil)
        }
    }
}
