import AppKit
import ManifoldCore
import WebKit
import ManifoldSyntax
import UniformTypeIdentifiers
import PDFKit

extension MainWindowController {
    // MARK: Debugging aids

    var debugFocusedBlock: BlockID? { focusedShown?.placement.block }
    var debugFocusedMarkdown: MarkdownView? { focusedShown.flatMap { views[$0.id] as? MarkdownView } }
    var debugFocusedView: NSView? { focusedView }
    var debugFocusedWebView: WKWebView? {
        guard let v = debugFocusedView else { return nil }
        func find(_ v: NSView) -> WKWebView? { (v as? WKWebView) ?? v.subviews.lazy.compactMap(find).first }
        return find(v)
    }

    var debugFocusedPlacement: Shown? { focusedShown }
    var debugOrganization: OrganizationView { sidebar.organizationView }
    /// Debugging: the focused tile's pill menu, or the item so titled chosen.
    func debugPillMenu(_ title: String) -> String {
        guard let f = focusedShown, let menu = gridPillMenu(for: f.id) else { return "no menu" }
        if title.isEmpty {
            return menu.items.flatMap { i -> [String] in
                [i.isSeparatorItem ? "---" : i.title] + (i.submenu?.items.map { "  " + $0.title + ($0.isEnabled ? "" : " (off)") } ?? [])
            }.joined(separator: "\n")
        }
        guard let item = menu.items.first(where: { $0.title == title }) as? ClosureMenuItem else { return "no such item" }
        item.perform()
        return "chose \(title)"
    }

    /// Whether a block is in sight: Manifold in front, its window shown
    /// and not covered (by another's window), the screen awake and not
    /// locked, and a tile of it showing in the workspace (not docked, not
    /// behind a maximized one).
    func inSight(_ block: BlockID) -> Bool {
        guard NSApp.isActive, let window, window.isVisible, !window.isMiniaturized, window.occlusionState.contains(.visible),
              !Self.screenAway(window.screen), stateView == nil, let a = arrangement else { return false }
        return a.placements(of: block).contains { a.locate($0.id) != nil && (a.full == nil || a.full == $0.id) }
    }

    /// The screen locked, or the window's display asleep: what's in front
    /// isn't seen.
    static func screenAway(_ screen: NSScreen?) -> Bool {
        let session = CGSessionCopyCurrentDictionary() as? [String: Any]
        if session?["CGSSessionScreenIsLocked"] as? Bool == true { return true }
        let display = screen?.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID ?? CGMainDisplayID()
        return CGDisplayIsAsleep(display) != 0
    }

    /// A notification clicked: to the block, and the command if one.
    func openFromNotification(_ block: BlockID, command: Int?) {
        NSApp.activate()
        window?.makeKeyAndOrderFront(nil)
        goTo(block)
        if let command { goToCommand(command, in: block) }
    }

    /// Paths from outside (the Dock icon, Open With): each opened in the
    /// workspace shown, from the focused tile, as a path clicked there is.
    func openPaths(_ paths: [String]) {
        // From outside: placed here, linked from nothing (the focused tile
        // has nothing to do with them).
        for path in paths { open(path, from: nil, here: false, over: false) }
    }

    /// Debugging: "host path d|f" as if a folder's entry were dropped
    /// at the end of the first column.
    func debugGridPath(_ arg: String) -> String {
        let f = arg.split(separator: " ").map(String.init)
        guard f.count == 3 else { return "usage: gridpath <host> <path> d|f" }
        let pb = NSPasteboard(name: NSPasteboard.Name("com.manifold.debug-drop"))
        pb.clearContents()
        pb.writeObjects([Drags.file(f[1], isDirectory: f[2] == "d", on: HostID(f[0]))])
        guard let d = Dragged(pb) else { return "not a thing" }
        gridOpen(d, column: 0, at: 99, newColumn: false)
        return "opened"
    }

    func debugOpenPaths(_ arg: String) -> String {
        openPaths(arg.split(separator: " ").map(String.init))
        return "opened"
    }

    /// The Dock icon's menu: every workspace on the desk, under its host's
    /// name when there's more than one, the one shown checked; chosen, it's
    /// gone to, Manifold coming to the front.
    func dockMenu() -> NSMenu {
        let menu = NSMenu()
        let byHost = hosts.ordered.map { c in (c, c.desk.order.filter { $0.host == c.host }.filter { hosts.arrangement($0) != nil }) }.filter { !$0.1.isEmpty }
        // Titles alike (a few workspaces in ~) told apart by what's focused in each.
        var seen: [String: Int] = [:]
        for id in byHost.flatMap(\.1) { if let a = hosts.arrangement(id) { seen[title(of: a), default: 0] += 1 } }
        func name(_ a: ArrangementState) -> String {
            let t = title(of: a)
            guard seen[t, default: 0] > 1, let f = a.focusedPlacement, let b = hosts.block(f.block), b.displayTitle != t else { return t }
            return "\(t) — \(b.displayTitle)"
        }
        for (c, ids) in byHost {
            if byHost.count > 1 {
                if menu.numberOfItems > 0 { menu.addItem(.separator()) }
                menu.addItem(NSMenuItem.sectionHeader(title: hosts.label(of: c.host)))
            }
            for id in ids {
                guard let a = hosts.arrangement(id) else { continue }
                let item = NSMenuItem(title: name(a), action: #selector(dockChoose(_:)), keyEquivalent: "")
                item.target = self
                item.representedObject = id
                item.state = id == selected ? .on : .off
                menu.addItem(item)
            }
        }
        return menu
    }

    @objc private func dockChoose(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? BlockID else { return }
        NSApp.activate()
        window?.makeKeyAndOrderFront(nil)
        goTo(id)
    }

    /// Debugging: the Dock menu's items, or the one titled so chosen.
    func debugDockMenu(_ title: String) -> String {
        let menu = dockMenu()
        if !title.isEmpty {
            guard let item = menu.items.first(where: { $0.title == title && $0.action != nil }) else { return "no \(title)" }
            dockChoose(item)
            return "chose \(title)"
        }
        return menu.items.map { $0.isSeparatorItem ? "—" : $0.isSectionHeader ? "[\($0.title)]" : ($0.state == .on ? "✓ " : "  ") + $0.title }.joined(separator: "\n")
    }

    /// Debugging: every workspace on the desk, its tiles' placements and titles.
    func debugWorkspaces() -> String {
        allWorkspaces.compactMap { id -> String? in
            guard let a = hosts.arrangement(id) else { return nil }
            let tiles = a.columns.map { col in col.map { "\($0.id)=\(hosts.block($0.block)?.displayTitle ?? "?")" }.joined(separator: ", ") }
            return "\(id == selected ? "*" : " ")\(id) \(title(of: a)): " + tiles.map { "[\($0)]" }.joined(separator: " ")
        }.joined(separator: "\n")
    }

    /// Debugging: a tile dropped on a workspace's row in the sidebar (or
    /// between the rows, "new"), moved or copied.
    func debugBlockDrop(_ placement: PlacementID, onto arrangement: BlockID?, copy: Bool) -> String {
        let node = arrangement.map { a -> OrgNode in
            let n = OrgNode(id: "ws:\(a)", block: a, title: "", symbol: "")
            n.arrangement = a
            return n
        }
        let item = OrgDragItem.placement(placement)
        guard organizationCanDrop(item, onto: node, at: node == nil ? 0 : -1) else { return "refused" }
        return organizationDrop(item, onto: node, at: node == nil ? 0 : -1, copy: copy) ? "ok" : "failed"
    }

    /// Debugging: a tile from another workspace dropped in this one's grid.
    func debugGridDrop(_ placement: PlacementID, column: Int, at: Int, copy: Bool) -> String {
        bringFromElsewhere(placement, column: column, at: at, newColumn: false, copy: copy)
        return "ok"
    }

    /// A synthesized move: to the grid, and to whatever view
    /// is under the point that takes moves of its own (a scrubber, a
    /// command's dot).
    func debugHover(_ event: NSEvent) {
        content.mouseMoved(with: event)
        guard let root = window?.contentView, let hit = root.hitTest(root.convert(event.locationInWindow, from: nil)) else { return }
        var v: NSView? = hit
        while let view = v, view !== content {
            if view is ScrubberView || view is OutlineTicks || view is CommandDots || view is FloatingListRow || view is LinkBadge || view is CardColumnView || view is OrganizationView { view.mouseMoved(with: event); break }
            if let badge = view.superview as? LinkBadge { badge.mouseMoved(with: event); break }
            v = view.superview
        }
    }

    /// Debugging: the focused search's preview; "searchpreview <n>", the nth hit chosen.
    func debugSearchPreview(_ arg: String) -> String {
        guard let s = arrangement?.focused.flatMap({ views[$0] as? SearchView }) else { return "no search focused" }
        return s.debugPreview(arg)
    }

    /// Debugging: the focused notebook, told `arg` (see NotebookView.debug).
    func debugNotebook(_ arg: String) -> String {
        guard let n = arrangement?.focused.flatMap({ views[$0] as? NotebookView }) else { return "no notebook focused" }
        return n.debug(arg)
    }

    /// Debugging: the focused tile's address bar — "begin" (its pill a
    /// field), "type <text>", "key <down|up|tab|return|escape|delete|shiftdelete>",
    /// or nothing: the field and its completions.
    func debugOmni(_ arg: String) -> String {
        guard let f = arrangement?.focused, let pill = content.debugPill(f), let v = views[f] else { return "no tile focused" }
        let words = arg.split(separator: " ", maxSplits: 1).map(String.init)
        switch words.first {
        case "begin":
            guard let e = v.pillEdit else { return "no address to edit" }
            pill.beginEditing(e)
        case "type": pill.debugType(words.count > 1 ? words[1] : "")
        case "key": pill.debugKey(words.count > 1 ? words[1] : "")
        default: break
        }
        return pill.debugCompletions
    }

    /// Debugging: the focused tile's icon's handle — "on", "off", or
    /// nothing: how it is.
    func debugHandle(_ arg: String) -> String {
        guard let f = arrangement?.focused, let pill = content.debugPill(f) else { return "no tile focused" }
        return pill.debugHandle(arg)
    }

    func debugTicks(_ arg: String) -> String {
        let words = arg.split(separator: " ", maxSplits: 1).map(String.init)
        switch words.first {
        case "rows": return FloatingList.shared.debugRows
        case "click": return FloatingList.shared.debugClick(words.count > 1 ? words[1] : "")
        case "pointer": return FloatingList.shared.debugPointer(arg)
        case "leave": return FloatingList.shared.debugPointer("leave")
        default: break
        }
        guard let f = arrangement?.focused else { return "no tile focused" }
        guard let t = content.debugTicks(f) else { return "no outline" }
        if words.first == "open" {
            t.open()
            return FloatingList.shared.debugRows
        }
        return "frame \(NSStringFromRect(t.frame))\n" + t.debugState
    }

    /// Debugging: the focused tile's own sidebar — "toggle", "pick N",
    /// or nothing: what it lists. "pdf …": the focused PDF's controls.
    func debugTileSidebar(_ arg: String) -> String {
        guard let f = arrangement?.focused, let v = views[f] else { return "nothing focused" }
        if arg.hasPrefix("pdf") { return (v as? MediaView)?.debugPDF(String(arg.dropFirst(3)).trimmingCharacters(in: .whitespaces)) ?? "no PDF focused" }
        if arg == "toggle" { toggleTileSidebar(nil) }
        if arg.hasPrefix("choose ") {
            // "choose <i> <i>…": those entries chosen together; what dragging them writes.
            func find(_ v: NSView) -> TileSidebar? { v as? TileSidebar ?? v.subviews.lazy.compactMap(find).first }
            guard let side = find(v) else { return "no sidebar shown" }
            return side.debugChoose(arg.dropFirst(7).split(separator: " ").compactMap { Int($0) })
        }
        let pick = arg.hasPrefix("pick ") ? Int(arg.dropFirst(5)) : nil
        switch v {
        case let e as EditorView:
            if let pick { _ = e.debugSidebarPick(pick) }
            return e.debugSidebar
        case let m as MarkdownView:
            if let pick { _ = m.debugSidebarPick(pick) }
            return m.debugSidebar
        case let p as MediaView:
            return p.debugPDF(pick.map { "pick \($0)" } ?? "")
        case let d as DiffView:
            return d.debugSidebar
        case let t as TerminalView:
            if let pick { _ = t.debugSidebarPick(pick) }
            return t.debugSidebar
        case let w as WebView:
            return w.debugSidebar
        default:
            return "no sidebar here"
        }
    }

    func debugGitView(_ arg: String) -> String {
        guard let g = arrangement?.focused.flatMap({ views[$0] as? GitView }) else { return "no git tile focused" }
        return g.debug(arg)
    }

    /// Debugging: the focused folder view, told `arg` (see DirectoryView.debug).
    func debugDirectory(_ arg: String) -> String {
        // "dir show <host>:<path>": a folder tile of that host's, made here.
        if arg.hasPrefix("show ") {
            let parts = arg.dropFirst(5).split(separator: ":", maxSplits: 1).map(String.init)
            guard parts.count == 2 else { return "usage: dir show <host>:<path>" }
            show(hosts.directoryBlock(for: parts[1], on: HostID(parts[0])), lens: .directory, .here)
            return "ok"
        }
        guard let d = arrangement?.focused.flatMap({ views[$0] as? DirectoryView }) else { return "no folder focused" }
        return d.debug(arg)
    }

    /// Debugging: the output tiles, as shown; "raw", what each holds,
    /// escaped; "copy" and "back", the focused one's buttons pressed.
    func debugOutputs(_ verb: String) -> String {
        let focused = (focusedView as? OutputView)
        if verb == "copy" { return focused?.debugCopy() ?? "no output focused" }
        if verb == "back" { focused?.debugBack(); return focused == nil ? "no output focused" : "ok" }
        if verb.hasPrefix("find ") { return focused?.debugFind(String(verb.dropFirst(5))) ?? "no output focused" }
        return views.values.compactMap { v -> String? in
            guard let o = v as? OutputView else { return nil }
            guard verb == "raw" else { return o.debugDescription_ }
            return hosts.block(o.block)?.output.map { $0.line + ": " + $0.output.debugDescription } ?? "?"
        }.joined(separator: "\n---\n")
    }
    var debugFocusedTerminal: TerminalView? { (focusedView as? TerminalView) }
    var debugFocusedEditor: EditorView? { (focusedView as? EditorView) }

    func debugSidebar(show: Bool) {
        if show { showSidebar(animated: false) } else { hideWork.cancel(); hideSidebar() }
    }

    var debugPills: String { content.debugPills }
    var debugTiles: String { content.debugTiles }
    func debugLanguages(_ path: String, done: @escaping ([Linguist.Count]?) -> Void) { host.languages(path, done: done) }


    /// Debugging: a shown tile, by its title, given this much content
    /// height — taken from or given to the biggest other in its column.
    func debugTileHeight(_ title: String, _ points: CGFloat) -> String {
        guard let a = arrangement else { return "no workspace" }
        for (c, column) in a.columns.enumerated() {
            guard let p = column.first(where: { hosts.block($0.block)?.displayTitle == title }) else { continue }
            guard let events = settingHeight(of: p.id, points: points, in: a) else { return "alone" }
            appendToSelected(events)
            return "ok"
        }
        return "no tile \(title)"
    }
    var debugDirty: String { content.debugDirty }
    func debugPushDown(column: Int, row: Int) -> String { content.debugPushDown(column: column, row: row) }
    func debugDirtyClick() -> String {
        guard let f = focusedShown, let t = hosts.block(f.placement.block)?.text, t.isDirty else { return "nothing dirty focused" }
        save(f.placement.block, from: f.id)
        return "ok"
    }

    /// Debugging: the focused text's top line (from 0), as ⌘↩ carries it.
    func debugTopLine() -> String {
        guard let f = focusedShown else { return "nothing focused" }
        if let e = views[f.id] as? EditorView {
            // (And the lines pinned over its top, from 1, and how many rows they take.)
            let pinned = e.pinned.isHidden ? "" : " pinned " + e.pinned.lines.map { String($0 + 1) }.joined(separator: ",") + String(format: " room %.0f", e.pinnedRoom(e.caretLine - 1))
            return String(format: "editor%@ %.2f caret %d", e.viewing ? " viewing" : "", e.topLine, e.caretLine) + pinned
        }
        guard let m = views[f.id] as? MarkdownView else { return "not a text" }
        var line: Double?? = nil
        m.topLine { line = .some($0) }
        let deadline = Date().addingTimeInterval(2)
        while line == nil, Date() < deadline { RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.02)) }
        return String(format: "page %.2f", (line ?? nil) ?? -1)
    }
    func debugFollowLink(toPlacementEndingIn suffix: String, modifiers: NSEvent.ModifierFlags = []) -> String {
        guard let a = arrangement, let f = a.focused, let t = a.placements.first(where: { $0.id.hasSuffix(suffix) }) else { return "no \(suffix)" }
        gridOpenLink(t.block, from: f, modifiers: modifiers)
        return debugDock("")
    }

    var debugSurface: NSView? { content }

    func debugReadd() -> String {
        guard let f = arrangement?.focused else { return "nothing focused" }
        return content.debugReadd(f)
    }

    func debugBadge(_ arg: String) -> String {
        // "badge on <placement suffix> …": that tile's badge, not the focused one's.
        let w = arg.split(separator: " ", maxSplits: 2).map(String.init)
        if w.first == "on", w.count > 1, let p = arrangement?.placements.first(where: { $0.id.hasSuffix(w[1]) }) {
            return content.debugBadge(p.id, w.count > 2 ? w[2] : "")
        }
        guard let f = arrangement?.focused else { return "nothing focused" }
        return content.debugBadge(f, arg)
    }

    func debugFocus(placementEndingIn suffix: String) -> Bool {
        guard let p = arrangement?.placements.first(where: { $0.id.hasSuffix(suffix) }) else { return false }
        gridFocus(p.id)
        return true
    }

    /// Debugging docking (§3.1): `dock` the space as it is; `dock it`, the
    /// focused tile docked; `dock back <suffix>`, that tile gone to.
    func debugDock(_ arg: String) -> String {
        let w = arg.split(separator: " ").map(String.init)
        if w.first == "it" { dockTile(nil) }
        // "dock click": the focused tile's bar clicked (grown a step, or a fill undone).
        if w.first == "click", let f = arrangement?.focused { gridGrow(f) }
        if w.first == "back", w.count > 1, let p = arrangement?.placements.first(where: { $0.id.hasSuffix(w[1]) }) { focus(p.id) }
        guard let b = arrangement else { return "no space" }
        func name(_ p: Placement) -> String { "\(hosts.block(p.block)?.displayTitle ?? "?")#\(p.id.suffix(4))" }
        let grid = b.columns.map { col in col.map { "\($0.id == b.focused ? "*" : " ")\(name($0)) \(Int((b.heights[$0.id] ?? 0) * 100))%" }.joined(separator: " | ") }
        let docked = b.docked.map { d in
            "\(name(d.placement)) (col \(d.column), under \(d.above.map { String($0.suffix(4)) } ?? "-"), \(Int(d.height * 100))%\(d.under.map { ", over it \($0.suffix(4))" } ?? ""))"
        }
        return grid.enumerated().map { "col \($0.offset): \($0.element)" }.joined(separator: "\n") + "\ndocked: " + (docked.isEmpty ? "none" : docked.joined(separator: "; "))
    }

    func debugDescribe() -> String {
        var out = "selected \(selected.map(\.description) ?? "none") theme \(hosts.state.appearance.theme.rawValue)\n"
        if let a = arrangement {
            for (c, column) in a.columns.enumerated() {
                out += "column \(c): " + column.map { p in
                    let b = hosts.block(p.block)
                    let mark = p.id == a.focused ? "*" : ""
                    return "\(p.lens.rawValue)=\(b?.displayTitle ?? "?")\(mark) \(Int((a.heights[p.id] ?? 0) * 100))%"
                }.joined(separator: " | ") + "\n"
            }
        }
        out += "desk: " + allWorkspaces.map { hosts.arrangement($0).map { title(of: $0) } ?? "?" }.joined(separator: ", ")
        return out
    }
}
