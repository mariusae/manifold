import AppKit
import ManifoldCore
import UniformTypeIdentifiers

/// Insert Path (⌃⌘I, §3.8): over a terminal's cursor, a menu of the paths
/// where its shell is — the folder's own entries, and the last three put
/// in on that host, nearest the field — and a field at its foot that
/// finds any file or folder under it as you type. Nothing waits: the
/// folder's entries show as they come, and what's under them is looked
/// for only once something's typed, nearest first (`PathCrawl`), the
/// rows ranked again off the main thread as more is found. Chosen, the path is
/// typed at the cursor as the shell would have it: relative to the
/// folder when it's under it, else from `~`, quoted where it needs to be;
/// a folder with its slash, a file with a space after.
final class PathInserter: NSObject, NSTextFieldDelegate, NSTableViewDataSource, NSTableViewDelegate {
    static let shared = PathInserter()

    /// What a terminal gives it: where its shell is, on which host, the
    /// host's home, how to list a folder there, and how to type at the
    /// cursor.
    struct Source {
        var host: HostID
        var directory: String
        var home: String?
        var listFolder: (String, @escaping ([DirectoryEntry]?) -> Void) -> Void
        var type: (String) -> Void
    }

    /// A row: a path under the folder (relative), or one put in lately
    /// (absolute).
    private struct Row: Equatable {
        var path: String
        var isFolder: Bool
        var recent: Bool
    }

    private let panel = Panel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
    private let ground = NSVisualEffectView()
    private let table = NSTableView()
    private let scroll = NSScrollView()
    private let field = NSTextField()
    private let glass = NSImageView()
    private var source: Source?
    /// What's found under the folder, as it's found.
    private var crawl: PathCrawl?
    /// Crawls lately made, by host and folder: opened there again, what
    /// was found shows at once (and it goes on from there).
    private static var crawls: [String: (at: Date, crawl: PathCrawl)] = [:]
    /// Shown bottom up: the last row is nearest the field, and the best.
    private var rows: [Row] = []
    /// The ranking, off the main thread: the candidates it has (made there,
    /// as the crawl finds more), and which crawl's they are.
    private let ranker = PathRanker()
    private let ranking = DispatchQueue(label: "insertpath.ranking", qos: .userInteractive)
    private let generation = FinderGeneration()
    private var rankedFor: ObjectIdentifier?
    private var sent = 0
    /// More found while a query's up: ranked again a moment later, once
    /// for however much came.
    private var again: DispatchWorkItem?
    /// At the field's right: what's being looked through, or that nothing matched.
    private let status = NSTextField(labelWithString: "")
    private let spinner = NSProgressIndicator()

    private static let width: CGFloat = 320
    private static let rowHeight: CGFloat = 24
    private static let fieldHeight: CGFloat = 30
    private static let pad: CGFloat = 6
    private static let visibleRows = 12
    private static let recentCount = 3

    /// Takes the keyboard (the field), stays over its window, and goes when
    /// it's let go.
    private final class Panel: NSPanel {
        var onResign: (() -> Void)?
        override var canBecomeKey: Bool { true }
        override var canBecomeMain: Bool { false }
        override func resignKey() {
            super.resignKey()
            onResign?()
        }
    }

    private override init() {
        super.init()
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = true
        panel.animationBehavior = .none
        panel.onResign = { [weak self] in self?.close(typing: nil) }

        // A menu's ground: the system's frosted one, rounded, a hairline at its edge.
        ground.material = .menu
        ground.state = .active
        ground.blendingMode = .behindWindow
        ground.wantsLayer = true
        ground.layer?.cornerRadius = 10
        ground.layer?.cornerCurve = .continuous
        ground.layer?.masksToBounds = true
        ground.layer?.borderWidth = 0.5
        ground.themed { v in v.layer?.borderColor = Theme.panelBorder.cgColor }
        panel.contentView = ground

        table.headerView = nil
        table.backgroundColor = .clear
        table.rowHeight = Self.rowHeight
        table.intercellSpacing = .zero
        table.style = .plain
        table.selectionHighlightStyle = .regular
        table.addTableColumn(NSTableColumn(identifier: .init("path")))
        table.dataSource = self
        table.delegate = self
        table.target = self
        table.action = #selector(clicked)
        table.refusesFirstResponder = true
        scroll.documentView = table
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.scrollerStyle = .overlay
        ground.addSubview(scroll)

        // The field at the foot, on a lighter ground, the folder as its placeholder.
        let well = NSView()
        well.wantsLayer = true
        well.layer?.cornerRadius = 7
        well.themed { v in v.layer?.backgroundColor = NSColor.dynamic(NSColor(white: 0, alpha: 0.06), NSColor(white: 1, alpha: 0.09)).cgColor }
        well.identifier = .init("well")
        ground.addSubview(well)
        glass.image = NSImage(systemSymbolName: "magnifyingglass", accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 12, weight: .medium))
        glass.contentTintColor = Theme.secondaryText
        ground.addSubview(glass)
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.font = .systemFont(ofSize: 13)
        field.delegate = self
        field.cell?.usesSingleLineMode = true
        field.cell?.lineBreakMode = .byTruncatingHead
        ground.addSubview(field)
        status.font = .systemFont(ofSize: 11)
        status.textColor = Theme.tertiaryText
        status.alignment = .right
        ground.addSubview(status)
        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isDisplayedWhenStopped = false
        ground.addSubview(spinner)
    }

    var isShowing: Bool { panel.isVisible }

    /// Opens over `caret` (in `window`), for a terminal's shell.
    func show(_ source: Source, over caret: NSRect, in window: NSWindow) {
        close(typing: nil)
        self.source = source
        field.stringValue = ""
        let shown = Self.shown(source.directory, home: source.home)
        field.placeholderString = shown.hasSuffix("/") ? shown : shown + "/"
        let key = "\(source.host.raw):\(source.directory)"
        if let kept = Self.crawls[key], Date().timeIntervalSince(kept.at) < 120 {
            crawl = kept.crawl
        } else {
            let list = source.listFolder
            let made = PathCrawl(root: source.directory, home: source.home) { path, done in
                list(path) { entries in DispatchQueue.main.async { done(entries) } }
            }
            Self.crawls[key] = (Date(), made)
            if Self.crawls.count > 6, let oldest = Self.crawls.min(by: { $0.value.at < $1.value.at })?.key { Self.crawls.removeValue(forKey: oldest) }
            crawl = made
        }
        crawl?.onChange = { [weak self] in self?.found() }
        refresh(keepingChoice: false)
        place(over: caret, in: window)
        if panel.parent !== window {
            panel.parent?.removeChildWindow(panel)
            window.addChildWindow(panel, ordered: .above)
        }
        panel.makeKeyAndOrderFront(nil)
        panel.makeFirstResponder(field)
    }

    /// Gone; with `typing`, that typed at the terminal's cursor first.
    private func close(typing text: String?) {
        guard panel.isVisible || text != nil else { return }
        // What's found is kept a while; looking further waits for a query.
        crawl?.going = false
        crawl?.onChange = nil
        crawl = nil
        again?.cancel()
        again = nil
        _ = generation.next()
        awaiting = false
        let source = self.source
        self.source = nil
        panel.parent?.removeChildWindow(panel)
        panel.orderOut(nil)
        if let text { source?.type(text) }
    }

    // MARK: Rows

    /// More found: the folder's own entries, or a folder gone into, shown
    /// as they come; for a query, ranked again a moment later — once for
    /// however much came meanwhile.
    private func found() {
        let query = field.stringValue.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty, !query.hasSuffix("/") else { return refresh(keepingChoice: true) }
        // Done looking: ranked now, the last time.
        if crawl?.finished == true {
            again?.cancel()
            again = nil
            return refresh(keepingChoice: true)
        }
        updateStatus()
        guard again == nil else { return }
        let work = DispatchWorkItem { [weak self] in
            self?.again = nil
            self?.refresh(keepingChoice: true)
        }
        again = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12, execute: work)
    }

    /// The rows for what's typed: nothing, the folder's own entries (its
    /// folders first) and then what was put in lately, nearest the field;
    /// a folder's path and a slash (⇥), that folder's; anything else, the
    /// best of what's found under the folder so far (and the recent), the
    /// best nearest the field — looking further while it's typed.
    /// `keepingChoice`: more came, not a key — the row chosen stays chosen.
    private func refresh(keepingChoice: Bool) {
        guard let source, let crawl else { return }
        let query = field.stringValue.trimmingCharacters(in: .whitespaces)
        let recent = Self.recents(on: source.host).suffix(Self.recentCount).map { Row(path: $0.path, isFolder: $0.isFolder, recent: true) }
        if query.isEmpty {
            crawl.going = false
            crawl.toward = nil
            _ = generation.next()
            awaiting = false
            return show(own(crawl, "") + recent, keepingChoice: keepingChoice)
        }
        crawl.going = true
        if query.hasSuffix("/"), case let folder = String(query.dropLast()), isFolder(folder, in: crawl) {
            crawl.toward = folder
            _ = generation.next()
            awaiting = false
            return show(own(crawl, folder), keepingChoice: keepingChoice)
        }
        crawl.toward = query.contains("/") ? query.deletingLastPathComponent : nil
        rank(query, recent: recent, in: crawl, keepingChoice: keepingChoice)
    }

    /// A folder's entries as rows: its folders, then its files, by name —
    /// none hidden.
    private func own(_ crawl: PathCrawl, _ folder: String) -> [Row] {
        let entries = (crawl.children[folder] ?? []).map { crawl.found[$0] }.filter { !$0.path.lastPathComponent.hasPrefix(".") }
        let folders = entries.filter(\.isFolder), files = entries.filter { !$0.isFolder }
        return Array((folders + files).prefix(400)).map { Row(path: $0.path, isFolder: $0.isFolder, recent: false) }
    }

    private func isFolder(_ path: String, in crawl: PathCrawl) -> Bool {
        if crawl.children[path] != nil { return true }
        let parent = path.contains("/") ? path.deletingLastPathComponent : ""
        return crawl.children[parent]?.contains { crawl.found[$0].path == path && crawl.found[$0].isFolder } ?? false
    }

    /// The best for a query, off the main thread: what the crawl found
    /// since the last ranking made candidates there, then all of them
    /// ranked — given up on if another query, or more found, comes first.
    private func rank(_ query: String, recent: [Row], in crawl: PathCrawl, keepingChoice: Bool) {
        let id = ObjectIdentifier(crawl)
        let fresh = rankedFor != id
        if fresh { sent = 0; rankedFor = id }
        let start = sent
        let new = Array(crawl.found[start...])
        sent = crawl.found.count
        let recentCandidates = recent.enumerated().map { i, r in
            FinderCandidate(symbol: "", title: r.path, detail: "", note: "", name: r.path.lastPathComponent, around: r.path,
                            distance: 0, recency: 0, action: -1 - i)
        }
        let gen = generation.next()
        awaiting = true
        let ranker = self.ranker, generation = self.generation
        ranking.async { [weak self] in
            ranker.add(new, from: start, fresh: fresh)
            guard let ranked = FinderRanking.rank(query, recentCandidates + ranker.candidates, limit: 60, current: { generation.isCurrent(gen) }) else { return }
            let picks = ranked.rows.map(\.action)
            DispatchQueue.main.async {
                guard let self, generation.isCurrent(gen), let crawl = self.crawl else { return }
                let rows = picks.reversed().compactMap { a -> Row? in
                    if a < 0 { return recent.indices.contains(-1 - a) ? recent[-1 - a] : nil }
                    return crawl.found.indices.contains(a) ? Row(path: crawl.found[a].path, isFolder: crawl.found[a].isFolder, recent: false) : nil
                }
                self.awaiting = false
                self.show(rows, keepingChoice: keepingChoice)
            }
        }
    }

    /// A ranking's under way: "No match" waits for it.
    private var awaiting = false

    /// The rows shown: the best (the last) chosen — or, as more comes in
    /// under a choice made, that one still.
    private func show(_ fresh: [Row], keepingChoice: Bool) {
        let chosen = keepingChoice && table.selectedRow >= 0 && table.selectedRow < rows.count && table.selectedRow != rows.count - 1 ? rows[table.selectedRow] : nil
        if fresh != rows {
            rows = fresh
            table.reloadData()
            layout()
        }
        updateStatus()
        guard !rows.isEmpty else { return }
        let row = chosen.flatMap { c in rows.firstIndex(of: c) } ?? rows.count - 1
        if table.selectedRow != row { table.selectRowIndexes([row], byExtendingSelection: false) }
        table.scrollRowToVisible(row)
    }

    /// At the field's right: the folder being listed, or how many have
    /// been looked through while it looks further; that nothing matched,
    /// when it's done looking.
    private func updateStatus() {
        guard let crawl else { return }
        let query = field.stringValue.trimmingCharacters(in: .whitespaces)
        let looking = crawl.children[""] == nil || (crawl.going && !crawl.finished)
        if crawl.children[""] == nil {
            status.stringValue = "Listing…"
        } else if looking {
            status.stringValue = "\(crawl.foldersListed.formatted()) folders"
        } else {
            status.stringValue = !query.isEmpty && rows.isEmpty && !awaiting ? "No match" : ""
        }
        if looking { spinner.startAnimation(nil) } else { spinner.stopAnimation(nil) }
        layoutField()
    }

    /// Sized to the rows, its foot (the field) where it was put.
    private func layout() {
        let visible = min(rows.count, Self.visibleRows)
        let listHeight = CGFloat(visible) * Self.rowHeight
        let height = Self.pad + listHeight + (visible > 0 ? Self.pad : 0) + Self.fieldHeight + Self.pad
        var frame = panel.frame
        if frame.height != height {
            if growsDown { frame.origin.y += frame.height - height }
            frame.size = NSSize(width: Self.width, height: height)
            panel.setFrame(frame, display: true)
        }
        ground.frame = NSRect(x: 0, y: 0, width: Self.width, height: height)
        scroll.frame = NSRect(x: 0, y: Self.pad + Self.fieldHeight + Self.pad, width: Self.width, height: listHeight)
        table.tableColumns[0].width = Self.width
        let well = NSRect(x: Self.pad, y: Self.pad, width: Self.width - 2 * Self.pad, height: Self.fieldHeight)
        ground.subviews.first { $0.identifier?.rawValue == "well" }?.frame = well
        glass.frame = NSRect(x: well.minX + 8, y: well.minY + (well.height - 16) / 2, width: 16, height: 16)
        layoutField()
    }

    /// The field, and at its right what it's doing.
    private func layoutField() {
        let well = NSRect(x: Self.pad, y: Self.pad, width: Self.width - 2 * Self.pad, height: Self.fieldHeight)
        let said = status.stringValue.isEmpty ? 0 : ceil(status.attributedStringValue.size().width) + 4
        let busy: CGFloat = spinner.isHidden || !spinnerShown ? 0 : 20
        status.frame = NSRect(x: well.maxX - 8 - said, y: well.minY + (well.height - 14) / 2, width: said, height: 14)
        spinner.frame = NSRect(x: status.frame.minX - (said > 0 ? 4 : 0) - 16, y: well.minY + (well.height - 16) / 2, width: 16, height: 16)
        let right = status.frame.minX - busy - (said > 0 || busy > 0 ? 6 : 0)
        field.frame = NSRect(x: glass.frame.maxX + 6, y: well.minY + (well.height - 18) / 2, width: max(40, right - glass.frame.maxX - 6), height: 18)
    }

    private var spinnerShown: Bool { status.stringValue != "" && status.stringValue != "No match" }

    /// Opened under the cursor, for want of room over it: it grows down.
    private var growsDown = false

    /// Its foot just over the cursor's line, its left a little before the
    /// cursor; under the line if there's no room over it.
    private func place(over caret: NSRect, in window: NSWindow) {
        layout()
        let content = window.contentView.map { $0.convert($0.bounds, to: nil) } ?? .zero
        let room = content.insetBy(dx: 8, dy: 8)
        let full = Self.pad + CGFloat(Self.visibleRows) * Self.rowHeight + 2 * Self.pad + Self.fieldHeight
        growsDown = caret.maxY + 4 + full > room.maxY && caret.minY - 4 - full > room.minY
        let height = panel.frame.height
        var frame = NSRect(x: caret.minX - 14, y: growsDown ? caret.minY - 4 - height : caret.maxY + 4, width: Self.width, height: height)
        frame.origin.x = min(max(frame.minX, room.minX), room.maxX - frame.width)
        panel.setFrame(window.convertToScreen(frame), display: false)
    }

    // MARK: Keys

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        switch selector {
        case #selector(NSResponder.moveUp(_:)): move(-1)
        case #selector(NSResponder.moveDown(_:)): move(1)
        case #selector(NSResponder.insertNewline(_:)): choose()
        case #selector(NSResponder.cancelOperation(_:)): close(typing: nil)
        // ⇥: into the folder chosen — what's under it, as typed.
        case #selector(NSResponder.insertTab(_:)): descend()
        default: return false
        }
        return true
    }

    func controlTextDidChange(_ obj: Notification) {
        again?.cancel()
        again = nil
        refresh(keepingChoice: false)
    }

    private func move(_ by: Int) {
        guard !rows.isEmpty else { return }
        let row = min(max(table.selectedRow + by, 0), rows.count - 1)
        table.selectRowIndexes([row], byExtendingSelection: false)
        table.scrollRowToVisible(row)
    }

    private func descend() {
        guard table.selectedRow >= 0, rows[table.selectedRow].isFolder, !rows[table.selectedRow].recent else { return NSSound.beep() }
        field.stringValue = rows[table.selectedRow].path + "/"
        refresh(keepingChoice: false)
    }

    @objc private func clicked() {
        guard table.clickedRow >= 0 else { return }
        table.selectRowIndexes([table.clickedRow], byExtendingSelection: false)
        choose()
    }

    /// The row chosen, typed — and kept as the latest put in on its host.
    private func choose() {
        guard let source, table.selectedRow >= 0, table.selectedRow < rows.count else { return }
        let row = rows[table.selectedRow]
        let absolute = row.recent ? row.path : source.directory.appendingPathComponent(row.path)
        Self.remember(absolute, isFolder: row.isFolder, on: source.host)
        close(typing: Self.typed(absolute, isFolder: row.isFolder, from: source.directory, home: source.home))
    }

    // MARK: Paths

    /// As the shell is given it: relative to the folder when under it,
    /// else from `~` when under home; quoted where it must be (a `~/`
    /// left outside the quotes, for the shell to expand); a folder with
    /// its slash, a file with a space after.
    static func typed(_ path: String, isFolder: Bool, from directory: String, home: String?) -> String {
        let shown = shown(path, from: directory, home: home)
        let quoted = shown.hasPrefix("~/") ? "~/" + TerminalView.shellQuoted(String(shown.dropFirst(2))) : TerminalView.shellQuoted(shown)
        return quoted + (isFolder ? "/" : " ")
    }

    /// A path as rows show it and the shell is given it: relative to the
    /// folder when under it, else from `~` when under home.
    static func shown(_ path: String, from directory: String, home: String?) -> String {
        let dir = directory.hasSuffix("/") ? directory : directory + "/"
        if path.hasPrefix(dir), path.count > dir.count { return String(path.dropFirst(dir.count)) }
        return shown(path, home: home)
    }

    /// From `~` when under home.
    static func shown(_ path: String, home: String?) -> String {
        guard let home else { return path }
        if path == home { return "~" }
        return path.hasPrefix(home + "/") ? "~/" + path.dropFirst(home.count + 1) : path
    }

    /// The paths last put in on a host, oldest first.
    private static func recents(on host: HostID) -> [(path: String, isFolder: Bool)] {
        let raw = UserDefaults.standard.stringArray(forKey: recentsKey(host)) ?? []
        return raw.map { $0.hasSuffix("/") && $0.count > 1 ? (String($0.dropLast()), true) : ($0, false) }
    }

    private static func remember(_ path: String, isFolder: Bool, on host: HostID) {
        let entry = isFolder ? path + "/" : path
        var raw = (UserDefaults.standard.stringArray(forKey: recentsKey(host)) ?? []).filter { $0 != entry }
        raw.append(entry)
        UserDefaults.standard.set(Array(raw.suffix(recentCount)), forKey: recentsKey(host))
    }

    private static func recentsKey(_ host: HostID) -> String { "insertPath.recent.\(host.raw)" }

    // MARK: Table

    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }
    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? { MenuRowView() }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let cell = tableView.makeView(withIdentifier: PathCell.identifier, owner: nil) as? PathCell ?? PathCell()
        let r = rows[row]
        let title = r.recent ? source.map { Self.shown(r.path, from: $0.directory, home: $0.home) } ?? r.path : r.path
        cell.show(title: title, icon: Self.icon(for: r.path, isFolder: r.isFolder), recent: r.recent)
        return cell
    }

    private static var icons: [String: NSImage] = [:]

    /// The Finder's icon for its kind — by its extension, so a remote
    /// host's file has one too.
    static func icon(for path: String, isFolder: Bool) -> NSImage {
        let ext = isFolder ? "/" : path.pathExtension.lowercased()
        if let i = icons[ext] { return i }
        let type: UTType = isFolder ? .folder : (UTType(filenameExtension: ext) ?? .data)
        let image = NSWorkspace.shared.icon(for: type)
        image.size = NSSize(width: 16, height: 16)
        icons[ext] = image
        return image
    }

    // MARK: Debugging

    /// "rows", "type <query>", "down", "up", "tab", "go", "close", "frame".
    func debug(_ arg: String) -> String {
        let words = arg.split(separator: " ", maxSplits: 1).map(String.init)
        switch words.first ?? "rows" {
        case "type": field.stringValue = words.count > 1 ? words[1] : ""; refresh(keepingChoice: false)
        case "down": move(1)
        case "up": move(-1)
        case "tab": descend()
        case "go": choose(); return "chose"
        case "close": close(typing: nil); return "closed"
        case "frame": return NSStringFromRect(panel.parent?.convertFromScreen(panel.frame) ?? .zero)
        case "picture":
            guard words.count > 1, let rep = ground.bitmapImageRepForCachingDisplay(in: ground.bounds) else { return "no" }
            ground.cacheDisplay(in: ground.bounds, to: rep)
            try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: words[1]))
            return "wrote \(words[1])"
        default: break
        }
        guard panel.isVisible else { return "not shown" }
        return "\(field.placeholderString ?? "") [\(field.stringValue)] \(crawl.map { "\($0.found.count) found in \($0.foldersListed) folders\($0.finished ? ", done" : "")" } ?? "-") · \(status.stringValue)\n"
            + rows.enumerated().map { i, r in (i == table.selectedRow ? "> " : "  ") + r.path + (r.isFolder ? "/" : "") + (r.recent ? " (recent)" : "") }.joined(separator: "\n")
    }
}

/// A row of the menu: its icon, its path — the folders it's in dimmer
/// than its name — and, for one put in lately, a clock at the right.
private final class PathCell: NSTableCellView {
    static let identifier = NSUserInterfaceItemIdentifier("PathCell")
    private let icon = NSImageView()
    private let label = NSTextField(labelWithString: "")
    private let clock = NSImageView()
    private var title = ""

    init() {
        super.init(frame: .zero)
        identifier = Self.identifier
        label.lineBreakMode = .byTruncatingHead
        label.maximumNumberOfLines = 1
        clock.image = NSImage(systemSymbolName: "clock.arrow.circlepath", accessibilityDescription: "Recent")?
            .withSymbolConfiguration(.init(pointSize: 12, weight: .regular))
        for v in [icon, label, clock] { addSubview(v) }
    }

    required init?(coder: NSCoder) { fatalError() }

    func show(title: String, icon image: NSImage, recent: Bool) {
        self.title = title
        icon.image = image
        clock.isHidden = !recent
        restyle()
        needsLayout = true
    }

    override var backgroundStyle: NSView.BackgroundStyle {
        didSet { restyle() }
    }

    /// On the accent when chosen: white, as a menu's chosen item is.
    private func restyle() {
        let chosen = backgroundStyle == .emphasized
        let text = chosen ? NSColor.white : Theme.text
        let dim = chosen ? NSColor.white.withAlphaComponent(0.75) : Theme.secondaryText
        let s = NSMutableAttributedString(string: title, attributes: [.font: NSFont.systemFont(ofSize: 13), .foregroundColor: text])
        if let slash = title.dropLast().lastIndex(of: "/"), !title.hasPrefix("~") || title.filter({ $0 == "/" }).count > 1 {
            let n = title.distance(from: title.startIndex, to: title.index(after: slash))
            s.addAttribute(.foregroundColor, value: dim, range: NSRange(location: 0, length: (String(title.prefix(n)) as NSString).length))
        }
        label.attributedStringValue = s
        clock.contentTintColor = dim
    }

    override func layout() {
        super.layout()
        let h = bounds.height
        icon.frame = NSRect(x: 12, y: (h - 16) / 2, width: 16, height: 16)
        clock.frame = NSRect(x: bounds.width - 12 - 16, y: (h - 16) / 2, width: 16, height: 16)
        let right = clock.isHidden ? bounds.width - 12 : clock.frame.minX - 6
        label.frame = NSRect(x: icon.frame.maxX + 8, y: (h - 17) / 2, width: max(0, right - icon.frame.maxX - 8), height: 17)
    }
}

/// A menu's chosen row: the accent, rounded, inset from the menu's edges.
private final class MenuRowView: NSTableRowView {
    override func drawSelection(in dirtyRect: NSRect) {
        guard selectionHighlightStyle != .none else { return }
        Theme.accent.setFill()
        NSBezierPath(roundedRect: bounds.insetBy(dx: 5, dy: 0.5), xRadius: 5, yRadius: 5).fill()
    }
    // Chosen, its cell's text is white (`.emphasized`), whatever has the keyboard.
    override var isEmphasized: Bool { get { true } set {} }
}

/// The candidates a ranking is over, made on the ranking's own queue as
/// the crawl finds more — never on the main thread.
private final class PathRanker: @unchecked Sendable {
    var candidates: [FinderCandidate] = []

    /// What was found from `start` on (its index there its action); a
    /// crawl's first, the last one's thrown away.
    func add(_ found: [PathCrawl.Found], from start: Int, fresh: Bool) {
        if fresh { candidates = [] }
        candidates.reserveCapacity(start + found.count)
        for (i, f) in found.enumerated() {
            candidates.append(FinderCandidate(symbol: "", title: f.path, detail: "", note: "", name: f.path.lastPathComponent, around: f.path,
                                              distance: f.depth, recency: Int64(f.modified), action: start + i))
        }
    }
}
