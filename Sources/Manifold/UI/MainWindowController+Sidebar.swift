import AppKit
import ManifoldCore
import WebKit
import ManifoldSyntax
import UniformTypeIdentifiers
import PDFKit

extension MainWindowController: SidebarDelegate {

    func sidebarOrganizationChanged(_ organization: Organization) { setOrganization(organization, show: false) }
    /// A space moved to `index` in its host's order (dragged in the strip).
    func moveSpace(_ arrangement: BlockID, to index: Int) {
        guard let client = hosts.client(of: arrangement) else { return }
        var order = client.desk.order
        guard let from = order.firstIndex(of: arrangement) else { return }
        order.remove(at: from)
        order.insert(arrangement, at: min(max(index, 0), order.count))
        client.setWorkspaceOrder(order)
    }

    /// A space moved to just before another of its host's (nil: after
    /// its host's last) — dragged in the strip.
    func moveSpace(_ arrangement: BlockID, before: BlockID?) {
        guard let client = hosts.client(of: arrangement) else { return }
        var order = client.desk.order
        guard let from = order.firstIndex(of: arrangement) else { return }
        order.remove(at: from)
        if let before, let k = order.firstIndex(of: before) {
            order.insert(arrangement, at: k)
        } else {
            // After the last of its host's shown in the strip (the order may
            // hold others, not on the desk).
            let last = order.lastIndex { $0.host == arrangement.host && allWorkspaces.contains($0) }
            order.insert(arrangement, at: last.map { $0 + 1 } ?? order.count)
        }
        client.setWorkspaceOrder(order)
    }

    func sidebarTogglePinned() {
        var state = hosts.state.window
        state.sidebarPinned.toggle()
        hosts.setWindow(state)
        if state.sidebarPinned {
            showSidebar(animated: false)
            setTrafficLights(visible: true, animated: true)
        } else {
            hideWork.cancel()
            hideSidebar(force: true)
        }
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = Motion.reduced ? 0 : Motion.base
            ctx.allowsImplicitAnimation = true
            layoutViews()
            root.layoutSubtreeIfNeeded()
        }
    }

    func sidebarResize(to width: CGFloat) {
        resizingWidth = min(max(width.rounded(), Theme.sidebarWidthRange.lowerBound), Theme.sidebarWidthRange.upperBound)
        hideWork.cancel()
        layoutViews()
    }

    func sidebarResizeEnded() {
        guard let width = resizingWidth else { return }
        var state = hosts.state.window
        state.sidebarWidth = Double(width)
        resizingWidth = nil
        if state != hosts.state.window { hosts.setWindow(state) }
        layoutViews()
        if let window {
            mouseMoved(to: root.convert(window.mouseLocationOutsideOfEventStream, from: nil))
        }
    }

    /// Something's being dragged (a tile, a row), or no longer.
    func dragChanged(_ dragging: Bool) {
        draggingTab = dragging
        // While anything is dragged, the grid catches it over every tile,
        // web views included.
        content.dragging = dragging
        if !dragging { scheduleHide() }
    }
}

extension MainWindowController: OrganizationViewDelegate {
    /// A row clicked: an arrangement is gone to; a tile is focused (in its
    /// arrangement); any other block is gone to where it is, or, with ⌘,
    /// brought here (§3.1).
    func organizationOpen(_ node: OrgNode, modifiers: NSEvent.ModifierFlags) {
        HoverCard.shared.hide()
        let d = Disposition(modifiers)
        if let arr = node.arrangement, d == .goTo {
            hideStateView()
            if let p = node.placement, let a = hosts.arrangement(arr), a.placement(p) != nil {
                // Out of its stack, from behind a maximized tile, focused,
                // and the pointer on it.
                land(on: p, in: arr, a)
                warpPointerToFocus()
            } else {
                if arr != selected { hosts.select(arr) }
                // A space's heading: the space in the inspector.
                if node.space != nil { inspect(.space(arr)) }
            }
            return
        }
        guard let block = node.block, let b = hosts.block(block) else { return }
        if b.kind == .arrangement { return hosts.select(block) }
        // The one rule: plain goes to it where it is (here, if nowhere);
        // ⌘ beside the focused tile; ⌥ over it; ⇧⌘ the system's app.
        follow(block, from: arrangement?.focused, d, context: "from the sidebar")
    }

    /// Double-clicking an arrangement names it.
    func organizationActivate(_ node: OrgNode) -> Bool {
        guard let arr = node.space else { return false }
        renameSpace(arr)
        return true
    }

    /// A host's card: its machine, and a remote's link, live.
    func showHostCard(_ c: HostClient, beside rect: NSRect, in window: NSWindow) {
        var detail = c.isRemote ? HostDashboard.standing(c) : c.machineLatest.map { "\($0.hostname) · \($0.system)" } ?? "This Mac"
        if c.watching, !c.isRemote { detail = "Watching: \(c.fencedBy ?? "another Manifold") took over · " + detail }
        // How long its server has been running.
        if c.isConnected, let started = c.serverStarted { detail += " · server up " + HostDashboard.duration(Date().timeIntervalSince(started)) }
        HoverCard.shared.show(key: "host:\(c.host.raw)", title: hosts.label(of: c.host), detail: detail, body: "", font: nil,
                              lend: {
                                  let d = HostDashboard(client: c)
                                  return HoverCard.LiveLoan(view: d, size: d.size, width: HostDashboard.width) { $0.removeFromSuperview() }
                              },
                              beside: rect, in: window)
    }

    func organizationHover(_ node: OrgNode?, at rect: NSRect, in view: NSView) {
        // A host's row: its machine, and a remote's link, live.
        if let node, let c = hostClient(of: node), let window {
            return showHostCard(c, beside: rect, in: window)
        }
        guard let node, let id = node.block, let window else { return HoverCard.shared.hide() }
        showBlockCard(id, beside: rect, in: window)
    }

    /// A block's card beside a rect (a sidebar row, ⌘O's list): a picture
    /// of its tile, or the block itself live, over its summary card.
    func showBlockCard(_ id: BlockID, beside rect: NSRect, in window: NSWindow, delay: TimeInterval = 0.45, above: Bool = false) {
        guard let b = hosts.block(id) else { return HoverCard.shared.hide() }
        var detail = b.path?.deletingLastPathComponent.abbreviatingHome ?? b.kind.defaultTitle
        if let seen = hosts.client(of: id)?.node.graph.seen(id) { detail += " · " + Age.ago(seen) }
        if id.host != host.host { detail += " · on \(hosts.label(of: id.host))" }
        var body = ""
        var font: NSFont? = nil
        switch b.kind {
        case .text:
            body = String(b.text?.text.string.prefix(600) ?? "").split(separator: "\n", omittingEmptySubsequences: false).prefix(8).joined(separator: "\n")
            font = hosts.state.appearance.theme.font(hosts.state.appearance.editorFont, size: 12)
        case .terminal, .agent:
            body = b.terminal?.cwd?.abbreviatingHome ?? ""
        case .search:
            body = b.search.map { "\($0.hits.count) hits" } ?? ""
        case .arrangement:
            body = b.arrangement.map { a in a.visible.compactMap { self.hosts.block($0.block)?.displayTitle }.joined(separator: " · ") } ?? ""
        default: break
        }
        // Its tile, if one is on screen: a picture of it, as Safari shows a
        // tab — a terminal as the text on its screen, a page by its own
        // snapshot (which comes a moment later), the rest as they draw.
        // Out of sight (another space, stacked, down to its bar, or
        // nowhere): a terminal as its screen still holds it, the rest as
        // last pictured — no live view, the summary card saying the rest.
        let key = id.description
        var picture: NSImage? = nil
        if let shown = content.views.first(where: { $0.block == id && $0.superview != nil && !$0.isHiddenOrHasHiddenAncestor && $0.window === window }) {
            switch shown {
            case let t as TerminalView:
                picture = HoverCard.picture(of: t)
                if picture == nil {
                    body = t.visibleText
                    font = hosts.state.appearance.theme.font(.monospaced, size: 11)
                }
            case let page as Snapshotting:
                // A page's own picture (WebKit draws it apart), when it comes.
                page.snapshot { [weak self] image in
                    if let image { self?.tilePictures[id] = image }
                    HoverCard.shared.updatePicture(image, for: key)
                }
            default:
                picture = HoverCard.picture(of: shown)
            }
            if let picture { tilePictures[id] = picture }
        } else {
            // Out of sight: its last picture (a terminal's screen as it
            // holds it), and the summary card says the rest.
            if let t = view(of: id, as: TerminalView.self),
               let image = HoverCard.surfacePicture(of: t) {
                picture = image
            } else if let hidden = views.values.first(where: { $0.block == id && $0.window === window && !($0 is Snapshotting) }),
                      let image = HoverCard.picture(of: hidden, evenHidden: true) {
                // Still drawn, out of sight (another workspace's grid kept,
                // stacked): pictured now, as it is.
                picture = image
                tilePictures[id] = image
            } else if let kept = tilePictures[id] {
                picture = kept
            }
        }
        // Under it, the block in a few lines, as a switcher's cards have it
        // (an arrangement, which has none, as it was).
        let summary = b.kind == .arrangement ? nil : cardContent(for: id)
        HoverCard.shared.show(key: key, title: b.displayTitle, detail: detail, body: body, font: font, picture: picture,
                              summary: summary, beside: rect, in: window, delay: delay, above: above)
    }

    /// `evenHidden`: in a grid kept hidden (a workspace just left), which
    /// still draws as it did.
    func rememberPicture(of view: PaneContent, evenHidden: Bool = false) {
        if let page = view as? Snapshotting {
            page.snapshot { [weak self] image in if let image { self?.tilePictures[view.block] = image } }
        } else if let image = HoverCard.picture(of: view, evenHidden: evenHidden) {
            tilePictures[view.block] = image
        }
        // Kept for the blocks still about.
        if tilePictures.count > 200 { tilePictures = tilePictures.filter { hosts.block($0.key) != nil } }
    }

    /// A host's row's host.
    func hostClient(of node: OrgNode) -> HostClient? {
        guard node.id.hasPrefix("host:") else { return nil }
        return hosts.all.first { "host:\($0.host.raw)" == node.id }
    }

    func organizationMenu(for node: OrgNode) -> NSMenu? {
        let menu = NSMenu()
        if let c = hostClient(of: node) {
            menu.addItem(ClosureMenuItem("Show in Inspector", symbol: "info.circle") { [weak self] in self?.inspect(.host(c.host.raw), open: true) })
            menu.addItem(.separator())
            if c.watching {
                menu.addItem(ClosureMenuItem("Take Over", symbol: "hand.raised") { [weak self] in self?.takeOver(c) })
                menu.addItem(.separator())
            }
            guard c.isRemote else {
                for item in hostItems(c.host, ownRow: true) { menu.addItem(item) }
                return menu
            }
            if c.link != .connected {
                menu.addItem(ClosureMenuItem("Try Again Now", symbol: "arrow.clockwise") { [weak self] in
                    c.retryNow()
                    self?.refreshOrganization(now: true)
                })
            }
            menu.addItem(ClosureMenuItem("Open Home Folder", symbol: "house") { [weak self] in
                guard let self, let home = c.home else { return }
                self.openDirectory(home, on: c.host)
            })
            let there = ClosureMenuItem("New Space on \(hosts.label(of: c.host))", symbol: "plus.rectangle.on.rectangle") { [weak self] in
                self?.newWorkspace(on: c.host, cwd: nil)
            }
            there.isEnabled = c.link == .connected
            menu.addItem(there)
            let preferences = ClosureMenuItem("Preferences for \(hosts.label(of: c.host))…", symbol: "gearshape") { [weak self] in
                self?.editPreferences(c.host)
            }
            preferences.isEnabled = c.link == .connected
            menu.addItem(preferences)
            if c.keepsEnvironment {
                let env = ClosureMenuItem("Add Environment Variable…", symbol: "dollarsign.square") { [weak self] in
                    self?.addEnvironmentVariable(c.host)
                }
                env.isEnabled = c.link == .connected
                menu.addItem(env)
            }
            menu.addItem(.separator())
            for item in hostItems(c.host, ownRow: true) { menu.addItem(item) }
            menu.addItem(ClosureMenuItem("Detach from \(hosts.label(of: c.host))…", symbol: "xmark") { [weak self] in
                self?.detach(c.host)
            })
            return menu
        }
        if let arr = node.space {
            menu.addItem(ClosureMenuItem("Rename Space…", symbol: "pencil") { [weak self] in self?.renameSpace(arr) })
            menu.addItem(ClosureMenuItem("Show in Inspector", symbol: "info.circle") { [weak self] in self?.inspect(.space(arr), open: true) })
            menu.addItem(.separator())
            menu.addItem(ClosureMenuItem("Remove Space", symbol: "xmark") { [weak self] in self?.removeFromDesk(arr) })
            menu.addItem(.separator())
            menu.addItem(hostSubmenu(arr.host))
            return menu
        }
        guard let id = node.block else { return nil }
        if let arr = node.arrangement, node.style == .row {
            menu.addItem(pinItem(id, in: arr))
            menu.addItem(.separator())
        }
        if let clear = clearStatusItem(id) {
            menu.addItem(clear)
            menu.addItem(.separator())
        }
        // A note: as an outline, or as text — its tile here turned, else opened so.
        if let outline = outlinerItem(id, tile: node.arrangement == selected ? node.placement : nil) {
            menu.addItem(outline)
            menu.addItem(.separator())
        }
        if let arr = node.arrangement, let p = node.placement {
            // Docked: put back where it was, as a click on its row does.
            if node.docked {
                menu.addItem(ClosureMenuItem("Put Back", symbol: "arrow.up.left.square") { [weak self] in self?.organizationOpen(node, modifiers: []) })
            }
            menu.addItem(ClosureMenuItem("Close Tile", symbol: "xmark") { [weak self] in self?.closeTile(p, in: arr) })
            menu.addItem(.separator())
        } else {
            menu.addItem(ClosureMenuItem("Go To", symbol: "arrow.right.circle") { [weak self] in self?.organizationOpen(node, modifiers: []) })
            menu.addItem(ClosureMenuItem("Show Beside", symbol: "rectangle.split.2x1") { [weak self] in self?.organizationOpen(node, modifiers: [.command]) })
            menu.addItem(ClosureMenuItem("Show Over", symbol: "square.stack") { [weak self] in self?.organizationOpen(node, modifiers: [.option]) })
            menu.addItem(.separator())
        }
        // A file's (a folder's): what a link to it has — copied, in a note,
        // an agent asked, Quick Look, its folder — as ⌘-right-click has it.
        if let path = LinkMenus.pathOf?(id) {
            LinkMenus.append(path, from: node.placement, on: id.host, to: menu, skipping: ["Open", "Open Over"])
            menu.addItem(.separator())
        }
        menu.addItem(neighborhoodItem(id))
        menu.addItem(.separator())
        menu.addItem(hostSubmenu(id.host))
        return menu
    }

    // MARK: Items a block's menus share (its pill's, its sidebar row's)

    /// Pin in Space, or Unpin; with its key (⌃⌘T) where the tile's focused.
    func pinItem(_ block: BlockID, in space: BlockID, key: Bool = false) -> NSMenuItem {
        let on = isPinned(block, in: space)
        let item = ClosureMenuItem(on ? "Unpin" : "Pin in Space", symbol: on ? "pin.slash" : "pin", key: key ? "t" : "") { [weak self] in
            self?.setPinned(block, in: space, !on)
        }
        if key { item.keyEquivalentModifierMask = [.command, .control] }
        return item
    }

    /// Clear Status, if it has one.
    func clearStatusItem(_ block: BlockID) -> NSMenuItem? {
        guard hosts.block(block)?.statusRecord != nil else { return nil }
        return ClosureMenuItem("Clear Status", symbol: "eraser") { [weak self] in self?.hosts.propose(.clearStatus(block)) }
    }

    func neighborhoodItem(_ block: BlockID) -> NSMenuItem {
        ClosureMenuItem("Show the Neighborhood Map", symbol: "point.3.connected.trianglepath.dotted") { [weak self] in
            self?.showNeighborhood(around: block)
        }
    }

    // MARK: Drops on the sidebar (§3.6)

    /// The block a dragged item stands for, and the placement to take
    /// away if it's a column's block being moved.
    func dragged(_ item: OrgDragItem) -> (block: BlockID, from: (arrangement: BlockID, placement: Placement)?)? {
        switch item {
        case .block(let b): return (b, nil)
        case .arrangement(let a): return (a, nil)
        case .host: return nil
        case .placement(let p):
            for id in allWorkspaces {
                if let a = hosts.arrangement(id), let placed = a.placement(p) { return (placed.block, (id, placed)) }
            }
            return nil
        }
    }

    func organizationCanDrop(_ item: OrgDragItem, onto node: OrgNode?, at index: Int) -> Bool {
        // Hosts reordered among themselves, wherever they head the rows.
        if case .host = item { return (organization == .desk || organization == .files) && node == nil && index >= 0 }
        guard organization == .desk else { return false }
        switch item {
        case .host:
            return false
        case .arrangement(let a):
            // Reordered among the top-level rows, or among its host's.
            if let node { return node.id == "host:\(a.host.raw)" && index >= 0 }
            return index >= 0
        case .block, .placement:
            if let node { return node.arrangement != nil || node.id.hasPrefix("host:") }
            return index >= 0
        }
    }

    func organizationSpring(_ node: OrgNode) {
        guard let arr = node.arrangement, arr != selected else { return }
        hosts.select(arr)
    }

    func organizationDrop(_ item: OrgDragItem, onto node: OrgNode?, at index: Int, copy: Bool) -> Bool {
        if case .host(let h) = item {
            // Among the hosts as the sidebar shows them.
            var order = hosts.ordered.map(\.host)
            guard node == nil, let from = order.firstIndex(of: h) else { return false }
            order.remove(at: from)
            order.insert(h, at: min(from < index ? index - 1 : index, order.count))
            hosts.setHostOrder(order)
            return true
        }
        if case .arrangement(let a) = item {
            if let node {
                // Among its host's workspaces, which lead its rows.
                guard node.id == "host:\(a.host.raw)", let client = hosts.client(of: a),
                      let from = client.desk.order.firstIndex(of: a) else { return false }
                let to = min(from < index ? index - 1 : index, client.desk.order.count - 1)
                if to != from { moveSpace(a, to: to) }
                return true
            }
            guard let from = allWorkspaces.firstIndex(of: a) else { return false }
            let to = from < index ? index - 1 : index
            if to != from { moveSpace(a, to: to) }
            return true
        }
        guard let (block, from) = dragged(item), let b = hosts.block(block), b.kind != .arrangement else { return false }
        let lens = from?.placement.lens ?? b.defaultLens
        if let node, let arr = node.arrangement {
            // Onto a column: shown there; onto an arrangement: in its
            // focused column. Moved from where it was, or with ⌥ copied —
            // there as well as here.
            let place: Where = node.column.map { .inColumn($0) } ?? .here
            show(block, lens: lens, place, in: arr)
            if let from, from.arrangement != arr, !copy { takeOut(from.placement.id, of: from.arrangement) }
            hosts.select(arr)
            return true
        }
        guard node == nil else { return false }
        // Between arrangements: one of its own there.
        if !copy, let from, hosts.arrangement(from.arrangement)?.placements.count == 1 {
            moveSpace(from.arrangement, to: index)
            return true
        }
        if let from, !copy { takeOut(from.placement.id, of: from.arrangement) }
        let n = host.newArrangement()
        show(block, lens: lens, .here, in: n)
        moveSpace(n, to: index)
        hosts.select(n)
        return true
    }

    func organizationDragChanged(_ dragging: Bool) { dragChanged(dragging) }

    func organizationOpen(files: [String], in workspace: BlockID) {
        if selected != workspace { hosts.select(workspace) }
        render()
        let column = max((arrangement?.columns.count ?? 1) - 1, 0)
        gridOpen(files: files, column: column, at: Int.max, newColumn: false)
    }

    func organizationPathItem(for block: BlockID, modifiers: NSEvent.ModifierFlags) -> NSPasteboardItem? {
        Drags.item(dragThing(block))
    }
}
