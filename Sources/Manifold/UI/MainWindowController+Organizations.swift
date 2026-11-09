import AppKit
import ManifoldCore
import WebKit
import ManifoldSyntax
import UniformTypeIdentifiers
import PDFKit

extension MainWindowController {
    // MARK: Organizations (§3.6)


    var organization: Organization {
        // One no longer known (the inspector, once the sidebar's): the desk.
        Organization(rawValue: hosts.state.window.organization ?? "") ?? .desk
    }

    @objc func organizeByDesk(_ sender: Any?) { setOrganization(.desk) }

    /// View ▸ Inspector (⌥⌘I): the focused block's properties in a window
    /// of their own, over everything, following the focus; again, put away.
    @objc func toggleInspector(_ sender: Any?) {
        if let p = inspector, p.isVisible { return p.close() }
        let p = inspector ?? InspectorPanel()
        if inspector == nil {
            p.onOpen = { [weak self] node in
                if let action = node.action { action() } else { self?.organizationOpen(node, modifiers: []) }
            }
            inspector = p
        }
        p.orderFront(nil)
        refreshInspector(now: true)
    }
    @objc func organizeByFiles(_ sender: Any?) { setOrganization(.files) }
    @objc func organizeByThreads(_ sender: Any?) { setOrganization(.threads) }

    func setOrganization(_ org: Organization, show: Bool = true) {
        var state = hosts.state.window
        state.organization = org.rawValue
        if state != hosts.state.window { hosts.setWindow(state) }
        sidebar.setOrganization(org)
        // The timeline's New rule where it is now, coming to it.
        if org == .threads { sidebar.timeline.marksWhenOpened = nil }
        if show, !sidebarShown { showSidebar(animated: true) }
        refreshOrganization(now: true)
    }

    /// The sidebar's tree again, a moment after the last change (the
    /// desk's sooner: it follows the focus).
    func refreshOrganization(now: Bool = false) {
        refreshInspector(now: now)
        let org = organization
        if sidebar.organization != org { sidebar.setOrganization(org) }
        organizationWork?.cancel()
        // Put away, it isn't made: it's made when it shows again.
        guard sidebarShown || pinned else { return organizationStale = true }
        organizationStale = false
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            // Held (a row closing): made once it's shut.
            let wait = self.sidebarHeldUntil - CACurrentMediaTime()
            if wait > 0 {
                DispatchQueue.main.asyncAfter(deadline: .now() + wait) { [weak self] in self?.refreshOrganization(now: true) }
                return
            }
            let (nodes, open) = self.organizationTree(org)
            let selected = org == .desk ? self.deskSelectedRow : nil
            if org == .closed {
                let reachable = self.hosts.reachable()
                self.sidebar.setFoot(closed: self.hosts.all.reduce(0) { $0 + self.closedItems(on: $1, reachable: reachable).count })
            }
            self.refreshSidebarThreads()
            // Flat, with sections, where rows are blocks by place or state;
            // a tree with chevrons where the nesting is the point (folders, links).
            self.sidebar.organizationView.flat = org != .files
            self.sidebar.organizationView.show(nodes, openByDefault: open, selected: selected)
            if org == .desk { self.showSpaceHeading() }
            self.refreshSpaceStrip()
            self.organizationShownFor = selected
        }
        organizationWork = work
        // The desk follows the focus at once; anything else (an edit's dot,
        // a note's first line, a status) a moment after the changes stop —
        // a key at a time, each made the whole tree again.
        let follows = org == .desk && deskSelectedRow != organizationShownFor
        if now { work.perform() } else { DispatchQueue.main.asyncAfter(deadline: .now() + (follows ? 0.05 : 0.25), execute: work) }
    }

    /// The space's heading: its name, and the host it's on — a remote's
    /// ping times by it, and what's wrong with its link if anything; the
    /// pointer on the host, its card.
    private func showSpaceHeading() {
        guard let id = selected, let a = hosts.arrangement(id) else { return sidebar.setSpace(title: "", host: "", standing: nil, pings: nil) }
        let c = hosts.client(of: id)
        var standing: String?
        if let c, c.isRemote {
            switch c.link {
            case .connecting: standing = "connecting…"
            case .unreachable: standing = "can't be reached"
            case .connected: standing = c.watching ? "watching" : nil
            }
        }
        sidebar.setSpace(title: title(of: a), host: hosts.label(of: id.host), standing: standing,
                         pings: c?.isRemote == true ? { [weak c] in c?.pings ?? [] } : nil, remote: c?.isRemote == true)
        if sidebar.spaceHost.onHover == nil {
            sidebar.spaceHost.onHover = { [weak self] rect in
                guard let self, let rect, let window = self.window, let host = self.selected?.host, let c = self.hosts.client(host) else { return HoverCard.shared.hide() }
                self.showHostCard(c, beside: rect, in: window)
            }
        }
    }


    /// The desk row for the focused tile of the selected arrangement.
    private var deskSelectedRow: String? {
        guard let id = selected, let a = walkPreview ?? hosts.arrangement(id) else { return nil }
        if let f = a.focusedPlacement { return "arr/\(id)/tile/\(f.id)" }
        return "arr/\(id)"
    }

    static func age(_ stamp: Stamp?) -> Double? {
        guard let stamp else { return nil }
        let hours = Date().timeIntervalSince(stamp.date) / 3600
        return min(1, max(0, (hours - 1) / 167))
    }

    func node(for block: Block, id: String? = nil, detail: String? = nil) -> OrgNode {
        let seen = hosts.client(of: block.id)?.node.graph.seen(block.id)
        let n = OrgNode(id: id ?? block.id.description, block: block.id, title: Self.linkTitle(block),
                        symbol: Theme.symbolName(for: block), detail: detail ?? "", age: Self.age(seen))
        n.dirty = block.text?.isDirty == true
        n.stale = block.text?.stale == true
        n.image = block.web.flatMap { Favicons.image(forPage: $0.url) }
        n.look = StatusGlyph.look(of: block)
        n.blocked = block.statusRecord?.kind
        n.tooltip = StatusGlyph.tooltip(block)
        n.trailing = StatusGlyph.at(of: block).map(Age.short)
        return n
    }

    /// Every block with something to say, by status group, the unread
    /// first and the newest next.
    func statusGroups() -> [StatusGroup: [(Block, StatusRecord?, Stamp)]] {
        var groups: [StatusGroup: [(Block, StatusRecord?, Stamp)]] = [:]
        for c in hosts.all {
            for b in c.node.blocks {
                guard let look = StatusGlyph.look(of: b) else { continue }
                let r = b.statusRecord
                let at = r?.at ?? b.terminal?.dormantSince ?? b.created
                groups[StatusGroup(look), default: []].append((b, r, at))
            }
        }
        return groups.mapValues { items in
            items.sorted { a, b in
                let ua = a.1?.wantsAttention ?? false, ub = b.1?.wantsAttention ?? false
                return ua != ub ? ua : a.2 > b.2
            }
        }
    }
}
