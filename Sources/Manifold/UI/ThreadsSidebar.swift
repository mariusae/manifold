import AppKit
import ManifoldCore

/// The sidebar's Threads (§3.12, ⌥⌘3, the foot row): the space's threads
/// listed by title — the open ones by what was said last, newest first;
/// then the resolved, closed — or the space's timeline, as Quip keeps a
/// document's conversation: every entry interleaved, newest last, a New
/// rule above what you haven't seen.
extension MainWindowController {
    private static let threadsTimelineKey = "ThreadsSidebarTimeline"

    /// Threads shown in the sidebar as the timeline rather than the list.
    var threadsTimelineMode: Bool {
        UserDefaults.standard.bool(forKey: Self.threadsTimelineKey)
    }

    func setThreadsMode(timeline: Bool) {
        UserDefaults.standard.set(timeline, forKey: Self.threadsTimelineKey)
        sidebar.threadsTimeline = timeline
        sidebar.timeline.marksWhenOpened = nil
        refreshOrganization(now: true)
    }

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

    /// The list: a row a thread, by its first words, where it's about and
    /// how long since it was written in; a count of what's not seen.
    func threadsTree() -> ([OrgNode], Set<String>) {
        guard selected != nil else { return ([OrgNode(id: "threads:none", title: "No space", symbol: "circle.dashed")], []) }
        let all = sidebarThreads()
        let new = OrgNode(id: "threads:new", title: "New Thread About This Space…", symbol: "plus.bubble")
        new.action = { [weak self] in self?.newThreadAboutSpace() }
        new.tooltip = "Or select something and press ⌥⌘M to comment on it"
        guard !all.isEmpty else { return ([new], []) }
        func latest(_ t: Block) -> Stamp { t.thread?.lastActivity ?? t.created }
        let open = all.filter { $0.thread?.resolved != true }.sorted { latest($0) > latest($1) }
        let resolved = all.filter { $0.thread?.resolved == true }.sorted { latest($0) > latest($1) }
        var nodes: [OrgNode] = [new]
        var expanded: Set<String> = []
        for (id, title, threads) in [("threads:open", "Open", open), ("threads:resolved", "Resolved", resolved)] where !threads.isEmpty {
            let s = OrgNode(id: id, title: title, symbol: "", count: threads.count, isGroup: true, children: threads.map(threadRow))
            s.style = .section
            nodes.append(s)
            if id == "threads:open" { expanded.insert(id) }
        }
        return (nodes, expanded)
    }

    private func threadRow(_ t: Block) -> OrgNode {
        let th = t.thread
        let resolved = th?.resolved == true
        let unseen = hosts.unseen(t).count
        let place = th?.about.map { describe($0) }
        var detail = place?.title ?? ""
        if let drift = place?.drift { detail += " — " + drift }
        let n = OrgNode(id: "thread/\(t.id)", block: t.id, title: th?.title ?? "Thread", symbol: resolved ? "checkmark.bubble" : "text.bubble",
                        detail: detail, count: unseen > 0 ? unseen : nil, age: Self.age(th?.lastActivity))
        n.emphasis = unseen > 0
        n.dimmed = resolved
        n.trailing = th?.lastActivity.map(Age.short)
        if let last = th?.lastComment, let text = last.comment {
            let who = last.author.isYou ? "You" : last.author.name
            n.tooltip = who + ": " + String(text.prefix(200)) + "\n\(th?.comments.count ?? 0) comments"
        }
        let id = t.id
        // Clicked, read in the overlay (its place a click from there); ⌘,
        // a tile beside; ⌥, the place itself.
        n.action = { [weak self] in
            guard let self else { return }
            let mods = NSApp.currentEvent?.modifierFlags ?? []
            if mods.contains(.command) {
                self.show(id, lens: .thread, .beside, kind: .opened, context: "from the sidebar")
            } else if mods.contains(.option) {
                self.goToPlace(ofThread: id)
            } else {
                self.showThreadOverlay(nil, thread: id)
            }
        }
        return n
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
        sidebar.threadsTimeline = threadsTimelineMode
        sidebar.setThreadsFilter(narrowed: sidebar.timeline.filter != .all || sidebar.timeline.model.scope != 0,
                                 unseen: sidebarThreads().reduce(0) { $0 + hosts.unseen($1).count })
        guard organization == .threads, threadsTimelineMode else { return }
        let v = sidebar.timeline
        if v.space != space {
            v.space = space
            v.marksWhenOpened = nil
            v.choose(nil)
        }
        watch(v)
    }

    /// Debugging the sidebar's threads: `sidebarthreads [list|timeline|close]`
    /// and what it shows.
    func debugSidebarThreads(_ arg: String) -> String {
        switch arg {
        case "list": setOrganization(.threads); setThreadsMode(timeline: false)
        case "timeline": setOrganization(.threads); setThreadsMode(timeline: true)
        case "close": setOrganization(.desk)
        default: break
        }
        guard organization == .threads else { return "not shown" }
        if threadsTimelineMode {
            let m = sidebar.timeline.model
            return "timeline · \(m.title) · \(m.runs.count) runs · \(m.unseen) unseen · " + m.runs.map { $0.placeTitle + ($0.firstUnseen != nil ? " NEW" : "") }.joined(separator: " | ")
        }
        let (nodes, _) = threadsTree()
        return "list · " + nodes.map { n in n.title + (n.children.isEmpty ? "" : ": " + n.children.map { c in c.title + " [" + c.detail + "]" + (c.count.map { " (\($0))" } ?? "") + " " + (c.trailing ?? "") }.joined(separator: "; ")) }.joined(separator: "\n")
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
