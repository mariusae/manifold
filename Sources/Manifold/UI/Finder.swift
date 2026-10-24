import AppKit
import ManifoldCore

/// Something the finder can go to: a block (recalled), an arrangement, or a
/// file not yet a block.
struct FinderItem {
    var symbol: String
    var title: String
    var detail: String
    /// A word on the right: "edited", "dormant", "named", or where it is.
    var note: String
    /// How far in, in an outline (⌘\): 0 at the top.
    var level: Int = 0
    var run: () -> Void
    /// Found in its content: the lines holding the query, run together
    /// (two lines' worth shown), and the query, marked wherever it is.
    var excerpt: String? = nil
    var marked: String? = nil
    /// Dragged out of the list: the block (to bring; with ⇧ its path and
    /// link), or the file.
    var drag: (() -> NSPasteboardWriting?)? = nil
}

/// Something to be found (§3.5): taken when the finder opens, and ranked
/// off the main thread as the query changes, so typing never waits on it.
struct FinderCandidate: Sendable {
    var symbol: String
    var title: String
    var detail: String
    var note: String
    /// What the query names, lowercased: the title, and words as good as
    /// its own (its kind, the agent at work in it); its words.
    var name: String
    var words: [String]
    /// Other names it answers to as surely as its title (the agent at work
    /// in it: "claude", "claude code"), lowercased.
    var aliases: [String] = []
    /// What's around it, lowercased: a path, a folder, a program.
    var around: String
    /// How far from where you are (§3.5); lower is nearer.
    var distance: Int
    var recency: Int64
    /// Which of the finder's actions it runs; -1 for a file, opened by `path`.
    var action: Int
    var path: String?
    /// The block it is, if one.
    var block: BlockID?

    init(symbol: String, title: String, detail: String, note: String, name: String, aliases: [String] = [], around: String, distance: Int, recency: Int64, action: Int, path: String? = nil, block: BlockID? = nil) {
        self.block = block
        self.aliases = aliases.map { $0.lowercased() }
        self.symbol = symbol
        self.title = title
        self.detail = detail
        self.note = note
        self.name = name.lowercased()
        self.words = self.name.split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init)
        self.around = around.lowercased()
        self.distance = distance
        self.recency = recency
        self.action = action
        self.path = path
    }

    /// A file under the folder: below the blocks, the system's scratch
    /// folders lower still.
    static func file(_ path: String) -> FinderCandidate {
        let name = path.lastPathComponent
        let scratch = path.hasPrefix("/tmp/") || path.hasPrefix("/private/tmp/") || path.hasPrefix("/private/var/folders/")
        return FinderCandidate(symbol: Finder.symbol(forFile: name), title: name, detail: path.deletingLastPathComponent.abbreviatingHome,
                               note: "file", name: name, around: path, distance: scratch ? 80 : 70, recency: 0, action: -1, path: path)
    }
}

/// A counter the main thread bumps and a ranking off it reads, to give up
/// on a query that's no longer the one typed.
final class FinderGeneration: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    func next() -> Int { lock.lock(); defer { lock.unlock() }; value += 1; return value }
    func isCurrent(_ v: Int) -> Bool { lock.lock(); defer { lock.unlock() }; return value == v }
}

enum FinderRanking {
    /// The best `limit` of the candidates for a query (§3.5): what the
    /// query names best first — the whole title, its start, a word's
    /// start, all its words, somewhere in it, its letters in order, only
    /// what's around it — and among equals the nearest, then the
    /// stronger match, then the latest. With nothing typed, the nearest
    /// and latest. Nil if given up on (`current` turned false).
    static func rank(_ query: String, _ candidates: [FinderCandidate], limit: Int = 60, current: () -> Bool = { true }) -> [FinderCandidate]? {
        let q = query.lowercased().trimmingCharacters(in: .whitespaces)
        if q.isEmpty {
            let blocks = candidates.filter { $0.action >= 0 }.sorted { $0.distance != $1.distance ? $0.distance < $1.distance : $0.recency > $1.recency }
            let files = candidates.lazy.filter { $0.action < 0 }.prefix(max(0, limit - min(blocks.count, limit)))
            return Array(blocks.prefix(limit)) + files
        }
        let letters = Array(q.utf8.filter { $0 != 32 })
        let qWords = q.split(separator: " ").map(String.init)
        let ascii = FileFinder.asciiQuery(q)
        // The best `limit` so far, best first: a match goes in where it
        // falls, or not at all — not every match sorted for the first few.
        var best: [Scored] = []
        best.reserveCapacity(limit + 1)
        for (i, c) in candidates.enumerated() {
            if i % 2000 == 0, !current() { return nil }
            // Every letter, in order, somewhere: else no match at all (cheap, first).
            guard Self.hasInOrder(letters, c.name) || Self.hasInOrder(letters, c.around) || c.aliases.contains(where: { Self.hasInOrder(letters, $0) }) else { continue }
            let m = Self.match(q, qWords, ascii, c)
            guard m > 0 else { continue }
            let band = m >= 600 ? 6 : m >= 520 ? 5 : m >= 500 ? 4 : m >= 480 ? 3 : m >= 400 ? 2 : m >= 200 ? 1 : 0
            let s = Scored(band: band, distance: c.distance, match: m, recency: c.recency, i: i)
            if best.count == limit, let last = best.last, !s.beats(last) { continue }
            var lo = 0, hi = best.count
            while lo < hi {
                let mid = (lo + hi) / 2
                if s.beats(best[mid]) { hi = mid } else { lo = mid + 1 }
            }
            best.insert(s, at: lo)
            if best.count > limit { best.removeLast() }
        }
        guard current() else { return nil }
        return best.map { candidates[$0.i] }
    }

    /// A match, by what it's ranked on: what the query names best, then
    /// the nearest, the stronger match, the latest — and among equals,
    /// the one listed first.
    private struct Scored {
        var band: Int, distance: Int, match: Int, recency: Int64, i: Int
        func beats(_ o: Scored) -> Bool {
            if band != o.band { return band > o.band }
            if distance != o.distance { return distance < o.distance }
            if match != o.match { return match > o.match }
            if recency != o.recency { return recency > o.recency }
            return i < o.i
        }
    }

    /// Whether `q` is in `s`, byte for byte (memmem) — Foundation's
    /// `contains` walked them a character at a time, most of a ranking.
    private static func contains(_ s: String, _ q: String) -> Bool {
        var s = s, q = q
        return s.withUTF8 { hay in
            q.withUTF8 { needle in
                guard !needle.isEmpty else { return true }
                guard let h = hay.baseAddress, let n = needle.baseAddress, hay.count >= needle.count else { return false }
                return memmem(h, hay.count, n, needle.count) != nil
            }
        }
    }

    private static func hasInOrder(_ letters: [UInt8], _ s: String) -> Bool {
        var i = 0
        for b in s.utf8 where i < letters.count && b == letters[i] { i += 1 }
        return i == letters.count
    }

    /// As FileFinder.nameMatch, over what's been lowercased once already.
    private static func match(_ q: String, _ qWords: [String], _ ascii: [UInt8]?, _ c: FinderCandidate) -> Int {
        func score(_ text: String) -> Int? {
            if let ascii, let s = FileFinder.asciiScore(ascii, text) { return s }
            return FileFinder.score(q, text)
        }
        // An alias named whole, or begun: as the title would be.
        if c.aliases.contains(q) { return 600 }
        if c.aliases.contains(where: { $0.hasPrefix(q) }) { return 520 }
        let t = c.name
        if t == q { return 600 }
        if t.hasPrefix(q) { return 520 }
        if c.words.contains(where: { $0.hasPrefix(q) }) { return 500 }
        if qWords.count > 1 {
            var i = 0, all = true
            for w in qWords {
                guard let j = c.words[i...].firstIndex(where: { $0.hasPrefix(w) }) else { all = false; break }
                i = j + 1
                if i > c.words.count { all = false; break }
            }
            if all { return 480 }
        }
        if Self.contains(t, q) { return 400 }
        if let f = score(t) { return 200 + min(f, 150) / 2 }
        if let f = score(c.around) { return 100 + min(f, 150) / 3 }
        return 0
    }
}

/// ⌘O: one field that finds anything the attached hosts know, in one of
/// three scopes (⇥ goes round them): **names** — blocks by title and
/// path, workspaces by name, processes, files under the focused folder
/// by name — ranked by how well the query matches; **in files** — lines
/// in the files under the project, as the host finds them; **in blocks**
/// — lines in the texts of the workspace's blocks. ↩ goes there.
final class Finder: NSObject, NSTextFieldDelegate, NSTableViewDataSource, NSTableViewDelegate {
    enum Scope: Int, CaseIterable {
        case names, contents, blocks
        var title: String {
            switch self {
            case .names: "Names"
            case .contents: "In Files"
            case .blocks: "In Blocks"
            }
        }
    }

    /// Items for a query in the other scopes (In Files, In Blocks), as the
    /// controller finds them.
    var search: ((String, Scope) -> [FinderItem])?
    /// A row before the rest for a query, if it calls for one (a web address).
    var special: ((String) -> FinderItem?)?
    /// Opens a file chosen.
    var openFile: ((String) -> Void)?
    /// What can be found by name, taken when shown, and what each runs.
    private var corpus: [FinderCandidate] = [] { didSet { joined = nil } }
    private var actions: [() -> Void] = []
    /// The files under the folder, as candidates, once listed.
    private var fileCandidates: [FinderCandidate] = [] { didSet { joined = nil } }
    /// Both, joined once while they're as they are — not copied at every key.
    private var joined: [FinderCandidate]?
    private var all: [FinderCandidate] {
        if let joined { return joined }
        let j = corpus + fileCandidates
        joined = j
        return j
    }
    private var withFiles = false
    /// Paths that are blocks already, found as blocks rather than files.
    private var knownPaths: Set<String> = []
    private let generation = FinderGeneration()
    private let ranking = DispatchQueue(label: "finder.ranking", qos: .userInteractive)
    /// Listings of folders lately listed: shown at once when asked again,
    /// listed afresh behind.
    private static var listings: [String: (at: Date, files: [FinderCandidate])] = [:]
    /// The rows the panel has room for while open: full height for the
    /// finder (it never moves under you); for the outline, as many as it
    /// has shown, growing only.
    private var tallest = 0
    /// The scope or query changed: what's asked of a host can start.
    var onQueryChanged: ((String, Scope) -> Void)?
    private(set) var scope: Scope = .names
    private let scopes = FlatSegments(titles: Scope.allCases.map(\.title), font: .systemFont(ofSize: 11))
    var isShowing: Bool { panel.isVisible }
    /// ⌘\: the workspace as a hierarchy, filtered by a query, instead.
    private var outline: ((String) -> [FinderItem])?
    /// The row the outline begins at (where you are), while nothing is typed.
    private var outlineStart: Int?

    private let panel: PickerPanel
    private let field = NSTextField()
    private let table = NSTableView()
    private let scroll = ClippingScrollView()
    private let hint = NSTextField(labelWithString: "")
    private var root = ""
    private var shown: [FinderItem] = []
    private var listing = 0

    private static let width: CGFloat = 640
    private static let fieldHeight: CGFloat = 56
    private static let rowHeight: CGFloat = 46
    private static let excerptHeight: CGFloat = 88
    private static let visibleRows = 9

    override init() {
        panel = PickerPanel(contentRect: NSRect(x: 0, y: 0, width: Self.width, height: Self.fieldHeight),
                            styleMask: [.titled, .fullSizeContentView], backing: .buffered, defer: true)
        super.init()
        build()
    }

    private func build() {
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.isMovableByWindowBackground = true
        panel.level = .floating
        panel.hidesOnDeactivate = true
        panel.isReleasedWhenClosed = false
        panel.animationBehavior = .utilityWindow
        for button in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
            panel.standardWindowButton(button)?.isHidden = true
        }
        panel.onResign = { [weak self] in self?.close() }

        // Flat, as the other panels are: their background, not the glass.
        let background = FlatBackground()
        panel.contentView = background

        let glass = NSImageView(image: NSImage(systemSymbolName: "magnifyingglass", accessibilityDescription: nil)!
            .withSymbolConfiguration(.init(pointSize: 20, weight: .regular))!)
        glass.contentTintColor = Theme.secondaryText
        glass.frame = NSRect(x: 18, y: 0, width: 24, height: Self.fieldHeight)
        background.addSubview(glass)

        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.font = .systemFont(ofSize: 22, weight: .regular)
        field.placeholderString = "Find anything…"
        field.delegate = self
        field.cell?.usesSingleLineMode = true
        field.cell?.lineBreakMode = .byTruncatingTail
        background.addSubview(field)

        table.headerView = nil
        table.backgroundColor = .clear
        table.rowHeight = Self.rowHeight
        table.intercellSpacing = NSSize(width: 0, height: 2)
        table.style = .inset
        table.selectionHighlightStyle = .regular
        table.addTableColumn(NSTableColumn(identifier: .init("item")))
        table.dataSource = self
        table.setDraggingSourceOperationMask([.copy, .link, .generic], forLocal: false)
        table.delegate = self
        table.target = self
        table.action = #selector(clicked(_:))
        table.refusesFirstResponder = true
        scroll.documentView = table
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        background.addSubview(scroll)

        hint.font = .systemFont(ofSize: 11)
        hint.textColor = Theme.tertiaryText
        hint.alignment = .right
        background.addSubview(hint)
        scopes.selectedSegment = 0
        scopes.onChange = { [weak self] _ in self?.scopeChosen() }
        background.addSubview(scopes)
    }

    @objc private func scopeChosen() {
        scope = Scope(rawValue: scopes.selectedSegment) ?? .names
        queryChanged()
        panel.makeFirstResponder(field)
    }

    private func cycleScope() {
        scope = Scope(rawValue: (scope.rawValue + 1) % Scope.allCases.count) ?? .names
        scopes.selectedSegment = scope.rawValue
        queryChanged()
    }

    private func queryChanged() {
        onQueryChanged?(field.stringValue.trimmingCharacters(in: .whitespaces), scope)
        refresh()
    }

    /// Results came in (a host's search): listed again.
    func refreshResults() {
        guard panel.isVisible, scope != .names else { return }
        refresh()
    }

    // MARK: Showing

    /// Shows: what can be found by name (`corpus`, each running its
    /// action), and with `filesUnder`, the files under that folder too —
    /// from the last listing at once, listed afresh behind. `scopes`: the
    /// other scopes (In Files, In Blocks) on offer.
    func show(corpus: [FinderCandidate], actions: [() -> Void], filesUnder root: String?, knownPaths: Set<String> = [], scopes showScopes: Bool, placeholder: String, over window: NSWindow?) {
        self.corpus = corpus
        self.actions = actions
        self.root = root ?? ""
        self.knownPaths = knownPaths
        withFiles = root != nil
        outline = nil
        scope = .names
        scopes.selectedSegment = 0
        scopes.isHidden = !showScopes
        field.placeholderString = placeholder
        field.stringValue = ""
        shown = []
        // At its full height from the start: the files arriving, or the
        // rows thinning as you type, never move it.
        tallest = Self.visibleRows
        listing += 1
        fileCandidates = []
        if let root {
            if let cached = Self.listings[root] { fileCandidates = cached.files.filter { !knownPaths.contains($0.path ?? "") } }
            let token = listing
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                let found = FileFinder.list(root: root).map { FinderCandidate.file(root.appendingPathComponent($0)) }
                DispatchQueue.main.async {
                    Self.listings[root] = (Date(), found)
                    if Self.listings.count > 12, let oldest = Self.listings.min(by: { $0.value.at < $1.value.at })?.key { Self.listings.removeValue(forKey: oldest) }
                    guard let self, self.listing == token else { return }
                    self.fileCandidates = found.filter { !self.knownPaths.contains($0.path ?? "") }
                    self.refresh()
                }
            }
        }
        if let window {
            let frame = window.frame
            panel.setFrameOrigin(NSPoint(x: frame.midX - Self.width / 2, y: frame.maxY - frame.height * 0.18 - panel.frame.height))
        }
        refreshNow()
        panel.makeKeyAndOrderFront(nil)
        panel.makeFirstResponder(field)
    }

    /// Shows the workspace's outline (⌘\): tiles by column, and what is in
    /// them, as `provider` lists them for a query.
    func showOutline(_ provider: @escaping (String) -> [FinderItem], startingAt start: Int? = nil,
                     placeholder: String = "Go to a tile, or a heading in one…", over window: NSWindow?) {
        outline = provider
        outlineStart = start
        scopes.isHidden = true
        field.stringValue = ""
        field.placeholderString = placeholder
        shown = []
        tallest = 0
        listing += 1
        if let window {
            let frame = window.frame
            panel.setFrameOrigin(NSPoint(x: frame.midX - Self.width / 2, y: frame.maxY - frame.height * 0.18 - panel.frame.height))
        }
        refresh()
        panel.makeKeyAndOrderFront(nil)
        panel.makeFirstResponder(field)
    }

    /// Types a query and says what's listed (for DebugControl).
    func debugQuery(_ query: String) -> [String] {
        field.stringValue = query
        if outline == nil { onQueryChanged?(query, scope) }
        refreshNow()
        return shown.map { String(repeating: "  ", count: $0.level) + "\($0.title) — \($0.detail)" + ($0.note.isEmpty ? "" : " [\($0.note)]") + ($0.excerpt.map { " «\($0.prefix(80))»" } ?? "") }
    }

    /// Debugging: how long ranking a query takes, over how much.
    func debugTime(_ query: String) -> String {
        let all = self.all
        let start = Date()
        let n = FinderRanking.rank(query, all)?.count ?? 0
        return String(format: "%d candidates (%d files) → %d rows in %.1f ms", all.count, fileCandidates.count, n, Date().timeIntervalSince(start) * 1000)
    }

    /// The ranking alone over the files under `root`, for each query, as
    /// typed a letter at a time (for DebugControl).
    static func debugBench(root: String, queries: [String]) -> String {
        let all = FileFinder.list(root: root).map { FinderCandidate.file(root.appendingPathComponent($0)) }
        return queries.map { q -> String in
            let start = Date()
            let n = FinderRanking.rank(q, all)?.count ?? 0
            return String(format: "%@: %d of %d in %.1f ms", q, n, all.count, Date().timeIntervalSince(start) * 1000)
        }.joined(separator: "\n")
    }

    /// Chooses the selected row, or moves the selection (for DebugControl).
    func debugChoose() { openSelected() }
    /// Debugging: the panel as it looks, to a PNG.
    func debugPicture(_ path: String) -> String {
        guard let view = panel.contentView, let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return "no panel" }
        view.cacheDisplay(in: view.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
        return "wrote \(path)"
    }
    func debugScope(_ n: Int) {
        scope = Scope(rawValue: n) ?? .names
        scopes.selectedSegment = scope.rawValue
        queryChanged()
    }
    func debugMove(_ by: Int) { move(by) }

    func close() {
        listing += 1
        _ = generation.next()
        panel.orderOut(nil)
    }

    private func updateHint() {
        if outline != nil {
            hint.stringValue = "The workspace, by column and tile, headings within    ↩ Go    ⎋ Close"
            return
        }
        let folder = root.abbreviatingHome
        hint.stringValue = switch scope {
        case .names: !withFiles ? "Blocks and workspaces, and what to make    ↩ Go    ⎋ Close"
            : fileCandidates.isEmpty ? "Blocks, workspaces, and files in \(folder) (looking…)    ↩ Open    ⎋ Close"
            : "Blocks, workspaces, and files in \(folder)    ⇥ Scope    ↩ Open    ⎋ Close"
        case .contents: "Lines in the files under the project    ⇥ Scope    ↩ Open    ⎋ Close"
        case .blocks: "The blocks' texts, this workspace's first    ⇥ Scope    ↩ Go    ⎋ Close"
        }
    }

    /// Sizes the panel to its results, keeping its top where it is.
    private func layout() {
        tallest = max(tallest, min(shown.count, Self.visibleRows))
        let rows = tallest
        // Rows with an excerpt are taller: the panel is as tall as the first
        // rows it has room for.
        let excerpts = shown.prefix(rows).filter { $0.excerpt != nil }.count
        let listHeight = rows == 0 ? 0 : CGFloat(rows) * (Self.rowHeight + 2) + CGFloat(excerpts) * (Self.excerptHeight - Self.rowHeight) + 12
        let hintHeight: CGFloat = 24
        let height = Self.fieldHeight + listHeight + hintHeight
        var frame = panel.frame
        if frame.height != height {
            frame.origin.y += frame.height - height
            frame.size.height = height
            panel.setFrame(frame, display: true)
        }
        field.frame = NSRect(x: 52, y: height - Self.fieldHeight + 13, width: Self.width - 70, height: 30)
        scroll.frame = NSRect(x: 0, y: hintHeight, width: Self.width, height: listHeight)
        scopes.sizeToFit()
        scopes.frame = NSRect(x: 10, y: 1, width: scopes.frame.width, height: 22)
        hint.frame = NSRect(x: scopes.frame.maxX + 8, y: 4, width: Self.width - scopes.frame.maxX - 24, height: 16)
        panel.contentView?.subviews.first { $0 is NSImageView }?.frame.origin.y = height - Self.fieldHeight
    }

    // MARK: Finding

    /// The rows again for the query: by name, ranked off the main thread
    /// (each keystroke giving up on the last), the newest answer shown;
    /// the other scopes and the outline at once, being small.
    private func refresh() {
        let query = field.stringValue.trimmingCharacters(in: .whitespaces)
        guard outline == nil, scope == .names else { return show(outline.map { $0(query) } ?? search?(query, scope) ?? [], query: query) }
        let gen = generation.next()
        let all = self.all
        let generation = self.generation
        ranking.async { [weak self] in
            guard let ranked = FinderRanking.rank(query, all, current: { generation.isCurrent(gen) }) else { return }
            DispatchQueue.main.async {
                guard let self, generation.isCurrent(gen) else { return }
                self.show(self.items(ranked, query: query), query: query)
            }
        }
    }

    /// The same, here and now (opening, and for DebugControl).
    private func refreshNow() {
        let query = field.stringValue.trimmingCharacters(in: .whitespaces)
        guard outline == nil, scope == .names else { return show(outline.map { $0(query) } ?? search?(query, scope) ?? [], query: query) }
        _ = generation.next()
        show(items(FinderRanking.rank(query, all) ?? [], query: query), query: query)
    }

    private func items(_ ranked: [FinderCandidate], query: String) -> [FinderItem] {
        var items = ranked.map { c -> FinderItem in
            let run: () -> Void
            if let path = c.path, c.action < 0 { run = { [weak self] in self?.openFile?(path) } }
            else { let a = actions[c.action]; run = a }
            let drag: (() -> NSPasteboardWriting?)?
            if let id = c.block { drag = { Drags.block?(id, Drags.modifiers) } }
            else if let path = c.path, c.action < 0 { drag = { Drags.path?(path, false, .local, Drags.modifiers) } }
            else { drag = nil }
            return FinderItem(symbol: c.symbol, title: c.title, detail: c.detail, note: c.note, run: run, drag: drag)
        }
        if let first = special?(query) { items.insert(first, at: 0) }
        return items
    }

    /// Rows shown: reloaded only if they changed, the first selected.
    private func show(_ items: [FinderItem], query: String) {
        let same = items.count == shown.count && zip(items, shown).allSatisfy { $0.title == $1.title && $0.detail == $1.detail && $0.note == $1.note && $0.excerpt == $1.excerpt }
        shown = items
        if !same { table.reloadData() }
        if !shown.isEmpty, !same || table.selectedRow < 0 {
            let row = query.isEmpty && outline != nil ? min(outlineStart ?? 0, shown.count - 1) : 0
            table.selectRowIndexes([row], byExtendingSelection: false)
            table.scrollRowToVisible(row)
        }
        updateHint()
        layout()
    }

    // MARK: Keys

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        switch selector {
        case #selector(NSResponder.moveUp(_:)): move(-1)
        case #selector(NSResponder.moveDown(_:)): move(1)
        case #selector(NSResponder.insertNewline(_:)): openSelected()
        case #selector(NSResponder.cancelOperation(_:)): close()
        case #selector(NSResponder.insertTab(_:)) where outline == nil: cycleScope()
        default: return false
        }
        return true
    }

    func controlTextDidChange(_ obj: Notification) {
        if outline == nil { onQueryChanged?(field.stringValue.trimmingCharacters(in: .whitespaces), scope) }
        refresh()
    }

    private func move(_ by: Int) {
        guard !shown.isEmpty else { return }
        let row = min(max(table.selectedRow + by, 0), shown.count - 1)
        table.selectRowIndexes([row], byExtendingSelection: false)
        table.scrollRowToVisible(row)
    }

    @objc private func clicked(_ sender: Any?) {
        guard table.clickedRow >= 0 else { return }
        table.selectRowIndexes([table.clickedRow], byExtendingSelection: false)
        openSelected()
    }

    private func openSelected() {
        guard table.selectedRow >= 0, table.selectedRow < shown.count else { return }
        let item = shown[table.selectedRow]
        close()
        item.run()
    }

    // MARK: Table

    func numberOfRows(in tableView: NSTableView) -> Int { shown.count }
    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? { SelectionRowView() }
    func tableView(_ tableView: NSTableView, pasteboardWriterForRow row: Int) -> NSPasteboardWriting? {
        shown.indices.contains(row) ? shown[row].drag?() : nil
    }

    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
        shown.indices.contains(row) && shown[row].excerpt != nil ? Self.excerptHeight : Self.rowHeight
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let item = shown[row]
        if let excerpt = item.excerpt {
            let cell = tableView.makeView(withIdentifier: ExcerptCell.identifier, owner: nil) as? ExcerptCell ?? ExcerptCell()
            cell.show(item, excerpt: excerpt)
            return cell
        }
        let cell = tableView.makeView(withIdentifier: FileCell.identifier, owner: nil) as? FileCell ?? FileCell()
        cell.show(title: item.title, detail: item.detail, symbol: item.symbol, note: item.note, level: item.level)
        return cell
    }

    static func symbol(forFile name: String) -> String {
        switch (name as NSString).pathExtension.lowercased() {
        case "md", "markdown", "txt", "rtf": "doc.text"
        case "png", "jpg", "jpeg", "gif", "heic", "svg", "webp": "photo"
        case "json", "yaml", "yml", "toml", "plist", "xml": "curlybraces"
        case "sh", "zsh", "bash", "fish": "terminal"
        case "": "doc"
        default: "chevron.left.forwardslash.chevron.right"
        }
    }

    /// How well `query` matches `text`: 0 for not at all.
    static func score(_ query: String, _ text: String) -> Int {
        guard !query.isEmpty else { return 1 }
        return FileFinder.score(query.lowercased(), text.lowercased()) ?? 0
    }
}

/// An item in the list: its title, where it is under it, and a note at
/// the right. Laid out by hand, its symbols cached: rows are made and
/// filled with every keystroke.
final class FileCell: NSTableCellView {
    static let identifier = NSUserInterfaceItemIdentifier("FileCell")
    private let symbol = NSImageView()
    private let title = NSTextField(labelWithString: "")
    private let detail = NSTextField(labelWithString: "")
    private let note = NSTextField(labelWithString: "")
    private var level = 0
    private var symbolName = ""
    private static var images: [String: NSImage] = [:]

    /// A symbol's image, made once.
    static func image(_ name: String) -> NSImage {
        if let i = images[name] { return i }
        // A coding agent's mark, at the size the row's symbols are.
        let i = (name.hasPrefix(AgentIcons.prefix) ? AgentIcons.image(String(name.dropFirst(AgentIcons.prefix.count)), size: 15) : nil)
            ?? NSImage(systemSymbolName: name, accessibilityDescription: nil) ?? NSImage()
        images[name] = i
        return i
    }

    init() {
        super.init(frame: .zero)
        identifier = Self.identifier
        symbol.symbolConfiguration = .init(pointSize: 16, weight: .regular)
        symbol.contentTintColor = Theme.secondaryText
        title.font = .systemFont(ofSize: 14, weight: .medium)
        title.textColor = Theme.text
        detail.font = .systemFont(ofSize: 12)
        detail.textColor = Theme.secondaryText
        note.font = .systemFont(ofSize: 11)
        note.textColor = Theme.tertiaryText
        note.alignment = .right
        for field in [title, detail, note] {
            field.lineBreakMode = .byTruncatingMiddle
            field.maximumNumberOfLines = 1
            field.cell?.usesSingleLineMode = true
        }
        for view in [symbol, title, detail, note] { addSubview(view) }
    }

    required init?(coder: NSCoder) { fatalError() }

    func show(title text: String, detail folder: String, symbol name: String, note text2: String, level: Int = 0) {
        if name != symbolName {
            symbolName = name
            let image = Self.image(name)
            symbol.image = image
        }
        if title.stringValue != text { title.stringValue = text }
        if detail.stringValue != folder { detail.stringValue = folder }
        detail.isHidden = folder.isEmpty
        if note.stringValue != text2 { note.stringValue = text2 }
        if self.level != level { self.level = level; needsLayout = true }
        needsLayout = true
    }

    override func layout() {
        super.layout()
        let h = bounds.height, w = bounds.width
        let x = 8 + CGFloat(level) * 22
        symbol.frame = NSRect(x: x, y: (h - 22) / 2, width: 22, height: 22)
        let noteWidth = min(160, ceil(note.attributedStringValue.size().width) + 4)
        note.frame = NSRect(x: w - 12 - noteWidth, y: (h - 15) / 2, width: noteWidth, height: 15)
        let textX = x + 32, textWidth = max(0, note.frame.minX - 8 - textX)
        if detail.isHidden {
            title.frame = NSRect(x: textX, y: (h - 19) / 2, width: textWidth, height: 19)
        } else {
            title.frame = NSRect(x: textX, y: h - 5 - 19, width: textWidth, height: 19)
            detail.frame = NSRect(x: textX, y: h - 5 - 19 - 1 - 16, width: textWidth, height: 16)
        }
    }
}

/// What's found in a file's or a block's content, as a search of a
/// site shows it: the name (the query marked in it), where it is, the
/// matching lines — two lines' worth at most — each match marked.
final class ExcerptCell: NSTableCellView {
    static let identifier = NSUserInterfaceItemIdentifier("ExcerptCell")
    private let symbol = NSImageView()
    private let title = NSTextField(labelWithString: "")
    private let detail = NSTextField(labelWithString: "")
    private let excerpt = NSTextField(wrappingLabelWithString: "")
    private let note = NSTextField(labelWithString: "")

    init() {
        super.init(frame: .zero)
        identifier = Self.identifier
        symbol.symbolConfiguration = .init(pointSize: 15, weight: .regular)
        symbol.contentTintColor = Theme.secondaryText
        title.lineBreakMode = .byTruncatingTail
        title.maximumNumberOfLines = 1
        detail.font = .systemFont(ofSize: 11, weight: .medium)
        detail.textColor = Theme.tertiaryText
        detail.lineBreakMode = .byTruncatingMiddle
        excerpt.maximumNumberOfLines = 2
        excerpt.lineBreakMode = .byTruncatingTail
        excerpt.cell?.truncatesLastVisibleLine = true
        note.font = .systemFont(ofSize: 11)
        note.textColor = Theme.tertiaryText
        note.alignment = .right
        for v in [symbol, title, detail, excerpt, note] { addSubview(v) }
    }

    required init?(coder: NSCoder) { fatalError() }

    /// Text with each occurrence of `query` (any case) in the accent, bold.
    static func marking(_ text: String, _ query: String?, font: NSFont, bold: NSFont, color: NSColor) -> NSAttributedString {
        let s = NSMutableAttributedString(string: text, attributes: [.font: font, .foregroundColor: color])
        guard let query, !query.isEmpty else { return s }
        let ns = text as NSString
        var range = NSRange(location: 0, length: ns.length)
        while true {
            let r = ns.range(of: query, options: [.caseInsensitive, .diacriticInsensitive], range: range)
            guard r.location != NSNotFound else { break }
            s.addAttributes([.font: bold, .foregroundColor: Theme.accent], range: r)
            range = NSRange(location: r.upperBound, length: ns.length - r.upperBound)
        }
        return s
    }

    func show(_ item: FinderItem, excerpt text: String) {
        symbol.image = FileCell.image(item.symbol)
        title.attributedStringValue = Self.marking(item.title, item.marked, font: .systemFont(ofSize: 14, weight: .semibold),
                                                   bold: .systemFont(ofSize: 14, weight: .bold), color: Theme.text)
        detail.stringValue = item.detail.uppercased()
        excerpt.attributedStringValue = Self.marking(text, item.marked, font: .systemFont(ofSize: 12.5),
                                                     bold: .systemFont(ofSize: 12.5, weight: .semibold), color: Theme.secondaryText)
        note.stringValue = item.note
        needsLayout = true
    }

    override func layout() {
        super.layout()
        let h = bounds.height, w = bounds.width
        symbol.frame = NSRect(x: 8, y: h - 8 - 20, width: 22, height: 20)
        let noteWidth = min(120, ceil(note.attributedStringValue.size().width) + 4)
        note.frame = NSRect(x: w - 12 - noteWidth, y: h - 8 - 17, width: noteWidth, height: 15)
        let x: CGFloat = 40, right = w - 14
        title.frame = NSRect(x: x, y: h - 7 - 19, width: max(0, note.frame.minX - 8 - x), height: 19)
        detail.frame = NSRect(x: x, y: title.frame.minY - 15, width: max(0, right - x), height: 14)
        excerpt.preferredMaxLayoutWidth = max(0, right - x)
        excerpt.frame = NSRect(x: x, y: 6, width: max(0, right - x), height: detail.frame.minY - 8)
    }
}

/// The finder's window: floating, with no title bar to speak of, that can
/// take the keyboard and gives it back when it loses it.
final class PickerPanel: NSPanel {
    var onResign: (() -> Void)?
    override var canBecomeKey: Bool { true }
    override func resignKey() {
        super.resignKey()
        onResign?()
    }
}
