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
    /// How long since it was seen, for a pill at the right: none for one
    /// seen just now.
    var age: String? = nil
    /// How far in, in an outline (⌘P): 0 at the top.
    var level: Int = 0
    var run: () -> Void
    /// Found in its content: the lines holding the query, run together
    /// (two lines' worth shown), and the query, marked wherever it is.
    var excerpt: String? = nil
    var marked: String? = nil
    /// Dragged out of the list: the block (to bring; with ⇧ its path and
    /// link), or the file.
    var drag: (() -> NSPasteboardWriting?)? = nil
    /// The block it is, if one: its row is its summary card.
    var block: BlockID? = nil
    /// What kinds it's found as (FindKinds): a chip narrows to them.
    var kinds: [String] = []
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
    /// What its summary says (a terminal's last commands, a note's first
    /// lines, an agent's last words), lowercased: found as well as its name.
    var summary: String
    var age: String?
    /// How far from where you are (§3.5); lower is nearer.
    var distance: Int
    var recency: Int64
    /// Which of the finder's actions it runs; -1 for a file, opened by `path`.
    var action: Int
    var path: String?
    /// The block it is, if one.
    var block: BlockID?
    /// What kinds it's found as (FindKinds).
    var kinds: [String]

    init(symbol: String, title: String, detail: String, note: String, age: String? = nil, name: String, aliases: [String] = [], around: String, summary: String = "",
         distance: Int, recency: Int64, action: Int, path: String? = nil, block: BlockID? = nil, kinds: [String] = []) {
        self.block = block
        self.kinds = kinds
        self.age = age
        self.summary = summary.lowercased()
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
                               note: "file", name: name, around: path, distance: scratch ? 80 : 70, recency: 0, action: -1, path: path, kinds: ["file"])
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
    /// What a ranking found: the rows, and how many matched of each kind
    /// (whatever kinds it was narrowed to: the counts say what a chip
    /// more would find).
    struct Ranked {
        var rows: [FinderCandidate]
        var counts: [String: Int]
    }

    /// The best `limit` of the candidates for a query (§3.5), of the kinds
    /// in `only` if any: what the query names best first — the whole
    /// title, its start, a word's start, all its words, somewhere in it,
    /// its letters in order, only what's around it — and among equals the
    /// nearest, then the stronger match, then the latest. With nothing
    /// typed, the nearest and latest. Nil if given up on (`current`
    /// turned false).
    static func rank(_ query: String, _ candidates: [FinderCandidate], only: Set<String> = [], limit: Int = 60, current: () -> Bool = { true }) -> Ranked? {
        let q = query.lowercased().trimmingCharacters(in: .whitespaces)
        func wanted(_ c: FinderCandidate) -> Bool { only.isEmpty || c.kinds.contains(where: only.contains) }
        var counts: [String: Int] = [:]
        if q.isEmpty {
            for c in candidates { for k in c.kinds { counts[k, default: 0] += 1 } }
            let blocks = candidates.filter { $0.action >= 0 && wanted($0) }.sorted { $0.distance != $1.distance ? $0.distance < $1.distance : $0.recency > $1.recency }
            let files = candidates.lazy.filter { $0.action < 0 && wanted($0) }.prefix(max(0, limit - min(blocks.count, limit)))
            return Ranked(rows: Array(blocks.prefix(limit)) + files, counts: counts)
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
            guard Self.hasInOrder(letters, c.name) || Self.hasInOrder(letters, c.around) || c.aliases.contains(where: { Self.hasInOrder(letters, $0) })
                    || Self.hasInOrder(letters, c.summary) else { continue }
            let m = Self.match(q, qWords, ascii, c)
            guard m > 0 else { continue }
            for k in c.kinds { counts[k, default: 0] += 1 }
            guard wanted(c) else { continue }
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
        return Ranked(rows: best.map { candidates[$0.i] }, counts: counts)
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
        // In its summary, as said (every word of the query, in any order):
        // with the titles the query is only scattered in.
        if !c.summary.isEmpty, qWords.allSatisfy({ Self.contains(c.summary, $0) }) { return 300 }
        if let f = score(t) { return 200 + min(f, 150) / 2 }
        if let f = score(c.around) { return 100 + min(f, 150) / 3 }
        return 0
    }
}

/// One field that finds anything the attached hosts know, in one of two
/// scopes, each its own key: **names** (⌘O) — blocks by title and path,
/// workspaces by name, agents' turns by what was asked — ranked by how
/// well the query matches; **in blocks** (⇧⌘O) — lines in the texts of
/// the workspace's blocks. Either narrows to kinds: a kind's name, or its
/// start, then ⇥, is a chip before the query (⌫ at the start takes it
/// back), and the foot counts what each kind found, a click narrowing to
/// it. ↩ goes there.
final class Finder: NSObject, NSTextFieldDelegate, NSTableViewDataSource, NSTableViewDelegate {
    enum Scope: Int, CaseIterable {
        case names, blocks
    }

    /// Items for a query in the other scope (In Blocks), as the
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
    /// A block's summary card, for its row: asked for as rows show, kept
    /// while the finder is open.
    var summarize: ((BlockID) -> SummaryCardContent?)?
    private var summaries: [BlockID: SummaryCardContent?] = [:]
    private(set) var scope: Scope = .names
    /// The kinds it's narrowed to, as chips before the query, in the
    /// order chosen: what's of any of them is found.
    private var chosen: [FindKinds.Kind] = []
    /// A chip ⇥ just made, from the word typed: ⇥ again makes it the next
    /// kind the word begins, ⌫ the word again. Gone once anything's typed.
    private var completing: (word: String, index: Int)?
    /// How many of each kind the query found, before the chips narrowed it.
    private var counts: [String: Int] = [:]
    private let chipRow = NSView()
    private let countRow = NSView()
    var isShowing: Bool { panel.isVisible }
    /// ⌘P: the workspace as a hierarchy, filtered by a query, instead.
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
    private static let cardHeight: CGFloat = SummaryCard.height
    private static let visibleRows = 9
    private static let keys = "⇥ Kind    ↩ Go    ⌘↩ Beside    ⌥↩ Over    ⎋ Close"

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
        panel.onCommandReturn = { [weak self] in self?.openSelected() }

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
        field.font = UIType.display
        field.placeholderString = "Open quickly…"
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

        hint.font = UIType.footnote
        hint.textColor = Theme.tertiaryText
        hint.alignment = .right
        hint.lineBreakMode = .byTruncatingHead
        background.addSubview(hint)
        background.addSubview(chipRow)
        background.addSubview(countRow)
    }

    // MARK: Kinds

    /// ⇥: the word at the query's end, if it begins a kind's name, made a
    /// chip; ⇥ again, the next kind it begins.
    private func completeKind() {
        if let (word, index) = completing, !chosen.isEmpty {
            let options = FindKinds.starting(word).filter { k in !chosen.dropLast().contains(k) }
            guard options.count > 1 else { return NSSound.beep() }
            let next = (index + 1) % options.count
            chosen[chosen.count - 1] = options[next]
            completing = (word, next)
            return kindsChanged()
        }
        let text = field.stringValue
        let word = text.split(separator: " ", omittingEmptySubsequences: false).last.map(String.init) ?? ""
        guard let first = FindKinds.starting(word).first(where: { !chosen.contains($0) }) else { return NSSound.beep() }
        chosen.append(first)
        completing = (word, FindKinds.starting(word).filter { !chosen.dropLast().contains($0) }.firstIndex(of: first) ?? 0)
        field.stringValue = String(text.dropLast(word.count))
        field.currentEditor()?.selectedRange = NSRange(location: (field.stringValue as NSString).length, length: 0)
        kindsChanged()
    }

    /// ⌫ at the query's start: the last chip gone — the word it was made
    /// from back, if ⇥ only just made it.
    private func removeLastKind() {
        guard !chosen.isEmpty else { return }
        chosen.removeLast()
        if let (word, _) = completing {
            field.stringValue = word + field.stringValue
            field.currentEditor()?.selectedRange = NSRange(location: (word as NSString).length, length: 0)
        }
        completing = nil
        kindsChanged()
    }

    /// A kind clicked, at the foot or as a chip: narrowed to, or no longer.
    private func toggle(_ kind: FindKinds.Kind) {
        if let i = chosen.firstIndex(of: kind) { chosen.remove(at: i) } else { chosen.append(kind) }
        completing = nil
        kindsChanged()
        panel.makeFirstResponder(field)
        field.currentEditor()?.selectedRange = NSRange(location: (field.stringValue as NSString).length, length: 0)
    }

    private func kindsChanged() {
        layoutChips()
        layout()
        queryChanged()
    }

    private var only: Set<String> { Set(chosen.map(\.name)) }

    /// The chips, before the query.
    private func layoutChips() {
        chipRow.subviews.forEach { $0.removeFromSuperview() }
        var x: CGFloat = 0
        for k in chosen {
            let chip = KindToken(kind: k, style: .chip)
            chip.toolTip = "Only \(k.title.lowercased())s — click or ⌫ to remove"
            chip.onClick = { [weak self] in self?.toggle(k) }
            chip.frame = NSRect(origin: NSPoint(x: x, y: 0), size: chip.wanted)
            chipRow.addSubview(chip)
            x = chip.frame.maxX + 4
        }
        chipRow.frame.size = NSSize(width: x, height: KindToken.chipHeight)
    }

    /// The counts at the foot: each kind the query found (and any chosen
    /// one that found none), once something's typed or chosen — in the
    /// table's order, those that found fewest left out if they don't all
    /// fit (never a chosen one).
    private func layoutCounts(width: CGFloat) {
        countRow.subviews.forEach { $0.removeFromSuperview() }
        let query = field.stringValue.trimmingCharacters(in: .whitespaces)
        guard outline == nil, !query.isEmpty || !chosen.isEmpty else { countRow.frame.size.width = 0; return }
        var tokens = FindKinds.all.compactMap { k -> KindToken? in
            let n = counts[k.name] ?? 0, on = chosen.contains(k)
            guard n > 0 || on else { return nil }
            let token = KindToken(kind: k, style: .count(n, on: on))
            token.toolTip = "\(n) \(k.title.lowercased())\(n == 1 ? "" : "s") — click for \(on ? "every kind again" : "only these")"
            token.onClick = { [weak self] in self?.toggle(k) }
            return token
        }
        func total() -> CGFloat { tokens.reduce(0) { $0 + $1.wanted.width + 2 } }
        while total() > width, let fewest = tokens.indices.filter({ !chosen.contains(tokens[$0].kind) })
                .min(by: { (counts[tokens[$0].kind.name] ?? 0) < (counts[tokens[$1].kind.name] ?? 0) }) {
            tokens.remove(at: fewest)
        }
        var x: CGFloat = 0
        for token in tokens {
            token.frame = NSRect(origin: NSPoint(x: x, y: 0), size: token.wanted)
            countRow.addSubview(token)
            x = token.frame.maxX + 2
        }
        countRow.frame.size = NSSize(width: x, height: KindToken.countHeight)
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

    /// Debugging: the chips and the counts.
    func debugKinds() -> String {
        let shownCounts = countRow.subviews.compactMap { ($0 as? KindToken)?.said }
        return "chips: [\(chosen.map(\.name).joined(separator: ", "))] field: \"\(field.stringValue)\" counts: \(shownCounts.joined(separator: " "))"
    }
    func debugTab() { completeKind() }
    func debugBackspace() {
        if field.stringValue.isEmpty || field.currentEditor()?.selectedRange.location == 0 { removeLastKind() }
    }
    func debugClickCount(_ name: String) {
        guard let k = FindKinds.named(name) else { return }
        toggle(k)
    }

    // MARK: Showing

    /// Shows, in a scope: what can be found by name (`corpus`, each
    /// running its action), and with `filesUnder`, the files under that
    /// folder too — from the last listing at once, listed afresh behind.
    /// Shown already, in the other scope: the query and its chips kept.
    func show(corpus: [FinderCandidate], actions: [() -> Void], filesUnder root: String?, knownPaths: Set<String> = [], scope: Scope = .names, placeholder: String, over window: NSWindow?) {
        let switching = panel.isVisible && outline == nil && scope != self.scope
        self.corpus = corpus
        self.actions = actions
        self.root = root ?? ""
        self.knownPaths = knownPaths
        withFiles = root != nil
        outline = nil
        self.scope = scope
        field.placeholderString = placeholder
        if !switching {
            field.stringValue = ""
            chosen = []
        }
        completing = nil
        counts = [:]
        layoutChips()
        shown = []
        summaries = [:]
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
        if let window, !switching {
            let frame = window.frame
            panel.setFrameOrigin(NSPoint(x: frame.midX - Self.width / 2, y: frame.maxY - frame.height * 0.18 - panel.frame.height))
        }
        if switching { onQueryChanged?(field.stringValue.trimmingCharacters(in: .whitespaces), scope) }
        refreshNow()
        panel.makeKeyAndOrderFront(nil)
        panel.makeFirstResponder(field)
        field.currentEditor()?.selectedRange = NSRange(location: (field.stringValue as NSString).length, length: 0)
    }

    /// Shows the workspace's outline (⌘P): tiles by column, and what is in
    /// them, as `provider` lists them for a query.
    /// One outline to go through; `wider`, another ⇥ goes to and back (⌘P:
    /// the focused tile's own, then the whole space's).
    struct OutlineScope {
        var provider: (String) -> [FinderItem]
        var start: Int?
        var placeholder: String
        var hint: String
        /// The keys it takes, at the hint's end, if not ↩'s going.
        var keys: String? = nil
    }
    private var outlineScope: OutlineScope?
    private var otherOutline: OutlineScope?

    func showOutline(_ scope: OutlineScope, wider: OutlineScope? = nil, over window: NSWindow?) {
        outlineScope = scope
        otherOutline = wider
        showOutline(scope.provider, startingAt: scope.start, placeholder: scope.placeholder, over: window)
    }

    /// ⇥ in an outline with another to go to: that one, the query kept.
    private func switchOutline() {
        guard let other = otherOutline, let now = outlineScope else { return }
        outlineScope = other
        otherOutline = now
        outline = other.provider
        outlineStart = other.start
        field.placeholderString = other.placeholder
        shown = []
        table.reloadData()
        refresh()
    }

    func showOutline(_ provider: @escaping (String) -> [FinderItem], startingAt start: Int? = nil,
                     placeholder: String = "Go to a tile, or a place in its outline…", over window: NSWindow?) {
        if outlineScope?.placeholder != placeholder { outlineScope = nil; otherOutline = nil }
        outline = provider
        outlineStart = start
        chosen = []
        completing = nil
        layoutChips()
        field.stringValue = ""
        field.placeholderString = placeholder
        shown = []
        summaries = [:]
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
        completing = nil
        if outline == nil { onQueryChanged?(query, scope) }
        refreshNow()
        return shown.map { String(repeating: "  ", count: $0.level) + "\($0.title) — \($0.detail)" + ($0.note.isEmpty ? "" : " [\($0.note)]") + ($0.excerpt.map { " «\($0.prefix(80))»" } ?? "") }
    }

    /// Debugging: how long ranking a query takes, over how much.
    func debugTime(_ query: String) -> String {
        let all = self.all
        let start = Date()
        let n = FinderRanking.rank(query, all, only: only)?.rows.count ?? 0
        return String(format: "%d candidates (%d files) → %d rows in %.1f ms", all.count, fileCandidates.count, n, Date().timeIntervalSince(start) * 1000)
    }

    /// The ranking alone over the files under `root`, for each query, as
    /// typed a letter at a time (for DebugControl).
    static func debugBench(root: String, queries: [String]) -> String {
        let all = FileFinder.list(root: root).map { FinderCandidate.file(root.appendingPathComponent($0)) }
        return queries.map { q -> String in
            let start = Date()
            let n = FinderRanking.rank(q, all)?.rows.count ?? 0
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
        queryChanged()
    }
    func debugMove(_ by: Int) { move(by) }

    /// A row's block's summary card, made once; none for one with nothing
    /// to say beyond its name (a workspace: its row says what it holds).
    private func summary(for item: FinderItem) -> SummaryCardContent? {
        guard let id = item.block else { return nil }
        if let known = summaries[id] { return known }
        let made = summarize?(id).flatMap { $0.summary.lines.isEmpty ? nil : $0 }
        summaries[id] = made
        return made
    }

    func close() {
        listing += 1
        _ = generation.next()
        panel.orderOut(nil)
    }

    private func updateHint() {
        if outline != nil {
            let what = outlineScope?.hint ?? "The space, by column and tile, headings within"
            hint.stringValue = what + (otherOutline != nil ? "    ⇥ \(otherOutline!.placeholder.hasPrefix("Go to a tile") ? "The space" : "This tile")" : "") + "    " + (outlineScope?.keys ?? "↩ Go    ⎋ Close")
            return
        }
        // With the counts at the foot, the keys alone.
        let keys = Self.keys
        let what = switch scope {
        case .names: "Blocks and spaces by name    ⇧⌘O In them    "
        case .blocks: "In blocks, this space's first    ⌘O By name    "
        }
        hint.stringValue = (countRow.frame.width > 0 ? "" : what) + keys
    }

    /// Sizes the panel to its results, keeping its top where it is.
    private func layout() {
        tallest = max(tallest, min(shown.count, Self.visibleRows))
        let rows = tallest
        // Rows with an excerpt are taller: the panel is as tall as the first
        // rows it has room for.
        let excerpts = shown.prefix(rows).filter { $0.excerpt != nil }.count
        // And a little more, for the blocks' cards, taller than a line.
        let listHeight = rows == 0 ? 0 : CGFloat(rows) * (Self.rowHeight + 2) + CGFloat(excerpts) * (Self.excerptHeight - Self.rowHeight)
            + (outline == nil ? Self.cardHeight - Self.rowHeight : 0) + 12
        let hintHeight: CGFloat = 24
        let height = Self.fieldHeight + listHeight + hintHeight
        var frame = panel.frame
        if frame.height != height {
            frame.origin.y += frame.height - height
            frame.size.height = height
            panel.setFrame(frame, display: true)
        }
        // The chips before the query, its first letter after them.
        let chipsWidth = chipRow.frame.width
        chipRow.frame.origin = NSPoint(x: 52, y: height - Self.fieldHeight + (Self.fieldHeight - KindToken.chipHeight) / 2)
        field.frame = NSRect(x: 52 + chipsWidth, y: height - Self.fieldHeight + 13, width: Self.width - 70 - chipsWidth, height: 30)
        scroll.frame = NSRect(x: 0, y: hintHeight, width: Self.width, height: listHeight)
        // The counts in what the keys leave them.
        let keysWidth = ceil((Self.keys as NSString).size(withAttributes: [.font: UIType.footnote]).width)
        layoutCounts(width: Self.width - keysWidth - 40)
        countRow.frame.origin = NSPoint(x: 10, y: (hintHeight - KindToken.countHeight) / 2)
        updateHint()
        let hintX = countRow.frame.width > 0 ? countRow.frame.maxX + 12 : 10
        hint.frame = NSRect(x: hintX, y: 4, width: Self.width - hintX - 16, height: 16)
        panel.contentView?.subviews.first { $0 is NSImageView }?.frame.origin.y = height - Self.fieldHeight
    }

    // MARK: Finding

    /// The rows again for the query: by name, ranked off the main thread
    /// (each keystroke giving up on the last), the newest answer shown;
    /// the other scopes and the outline at once, being small.
    private func refresh() {
        let query = field.stringValue.trimmingCharacters(in: .whitespaces)
        if let outline { return show(outline(query), query: query) }
        guard scope == .names else { return showSearched(query) }
        let gen = generation.next()
        let all = self.all
        let only = self.only
        let generation = self.generation
        ranking.async { [weak self] in
            guard let ranked = FinderRanking.rank(query, all, only: only, current: { generation.isCurrent(gen) }) else { return }
            DispatchQueue.main.async {
                guard let self, generation.isCurrent(gen) else { return }
                self.counts = ranked.counts
                self.show(self.items(ranked.rows, query: query), query: query)
            }
        }
    }

    /// The same, here and now (opening, and for DebugControl).
    private func refreshNow() {
        let query = field.stringValue.trimmingCharacters(in: .whitespaces)
        if let outline { return show(outline(query), query: query) }
        guard scope == .names else { return showSearched(query) }
        _ = generation.next()
        let ranked = FinderRanking.rank(query, all, only: only)
        counts = ranked?.counts ?? [:]
        show(items(ranked?.rows ?? [], query: query), query: query)
    }

    /// In Blocks: what the controller finds, counted by kind, then
    /// narrowed to the chips'.
    private func showSearched(_ query: String) {
        let found = search?(query, scope) ?? []
        var counts: [String: Int] = [:]
        for item in found { for k in item.kinds { counts[k, default: 0] += 1 } }
        self.counts = counts
        let only = self.only
        show(only.isEmpty ? found : found.filter { $0.kinds.contains(where: only.contains) }, query: query)
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
            return FinderItem(symbol: c.symbol, title: c.title, detail: c.detail, note: c.note, age: c.age, run: run, drag: drag, block: c.block, kinds: c.kinds)
        }
        if only.isEmpty || only.contains("web"), let first = special?(query) { items.insert(first, at: 0) }
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
        // ↩ goes; ⌥↩ (which the field calls this) puts it over.
        case #selector(NSResponder.insertNewline(_:)), #selector(NSResponder.insertNewlineIgnoringFieldEditor(_:)): openSelected()
        case #selector(NSResponder.cancelOperation(_:)): close()
        case #selector(NSResponder.insertTab(_:)) where outline == nil: completeKind()
        case #selector(NSResponder.insertTab(_:)) where otherOutline != nil: switchOutline()
        // ⌫ with nothing before the cursor: the last chip.
        case #selector(NSResponder.deleteBackward(_:)) where outline == nil && !chosen.isEmpty
                && textView.selectedRange() == NSRange(location: 0, length: 0):
            removeLastKind()
        default: return false
        }
        return true
    }

    func controlTextDidChange(_ obj: Notification) {
        completing = nil
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
        guard shown.indices.contains(row) else { return Self.rowHeight }
        let item = shown[row]
        if item.excerpt != nil { return Self.excerptHeight }
        if item.block != nil, let s = summary(for: item) { return SummaryCard.height(for: s) }
        return Self.rowHeight
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let item = shown[row]
        if let excerpt = item.excerpt {
            let cell = tableView.makeView(withIdentifier: ExcerptCell.identifier, owner: nil) as? ExcerptCell ?? ExcerptCell()
            cell.show(item, excerpt: excerpt)
            return cell
        }
        if var content = summary(for: item) {
            // A block: its card, where the finder's own word (here, linked,
            // recent) stands, after any state of its own; its age in a pill.
            let state = content.summary.note.flatMap { $0.range(of: #"^(now|\d+[mhd])$"#, options: .regularExpression) == nil ? $0 : nil }
            // ("edited" said once: the card's "unsaved" says it.)
            let word = state == "unsaved" ? item.note.replacingOccurrences(of: #"^edited( · )?"#, with: "", options: .regularExpression) : item.note
            content.summary.note = [state, word.isEmpty ? nil : word].compactMap { $0 }.joined(separator: " · ")
            if content.summary.note?.isEmpty == true { content.summary.note = nil }
            content.age = item.age
            let cell = tableView.makeView(withIdentifier: CardCell.identifier, owner: nil) as? CardCell ?? CardCell()
            cell.show(content)
            return cell
        }
        let cell = tableView.makeView(withIdentifier: FileCell.identifier, owner: nil) as? FileCell ?? FileCell()
        cell.show(title: item.title, detail: item.detail, symbol: item.symbol, note: item.note, level: item.level, age: item.age)
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
    private let agePill = AgePill()
    private var level = 0
    private var symbolName = ""
    private static var images: [String: NSImage] = [:]
    // As a summary card sets them, a file's row and a block's alike.
    private static let titleFont = UIType.title
    private static let detailFont = UIType.detail

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
        symbol.symbolConfiguration = .init(pointSize: UIType.symbolSize, weight: .medium)
        symbol.contentTintColor = Theme.secondaryText
        title.font = Self.titleFont
        title.textColor = Theme.text
        detail.font = Self.detailFont
        detail.textColor = Theme.secondaryText
        note.font = UIType.detail
        note.textColor = Theme.tertiaryText
        note.alignment = .right
        for field in [title, detail, note] {
            field.lineBreakMode = .byTruncatingMiddle
            field.maximumNumberOfLines = 1
            field.cell?.usesSingleLineMode = true
        }
        for view in [symbol, title, detail, note, agePill] { addSubview(view) }
    }

    required init?(coder: NSCoder) { fatalError() }

    func show(title text: String, detail folder: String, symbol name: String, note text2: String, level: Int = 0, age: String? = nil) {
        if name != symbolName {
            symbolName = name
            let image = Self.image(name)
            symbol.image = image
        }
        if title.stringValue != text { title.stringValue = text }
        if detail.stringValue != folder { detail.stringValue = folder }
        detail.isHidden = folder.isEmpty
        agePill.text = age
        if note.stringValue != text2 { note.stringValue = text2 }
        if self.level != level { self.level = level; needsLayout = true }
        needsLayout = true
    }

    override func layout() {
        super.layout()
        let h = bounds.height, w = bounds.width
        let x = 8 + CGFloat(level) * 22
        symbol.frame = NSRect(x: x, y: (h - 22) / 2, width: 22, height: 22)
        var right = w - 12
        if let size = agePill.wanted {
            agePill.frame = NSRect(x: right - size.width, y: ((h - size.height) / 2).rounded(), width: size.width, height: size.height)
            right = agePill.frame.minX - 6
        }
        agePill.isHidden = agePill.wanted == nil
        let noteWidth = min(160, ceil(note.attributedStringValue.size().width) + 4)
        note.frame = NSRect(x: right - noteWidth, y: (h - 15) / 2, width: noteWidth, height: 15)
        let textX = x + 32, textWidth = max(0, note.frame.minX - 8 - textX)
        if detail.isHidden {
            title.frame = NSRect(x: textX, y: (h - 19) / 2, width: textWidth, height: 19)
        } else {
            title.frame = NSRect(x: textX, y: h - 5 - 19, width: textWidth, height: 19)
            detail.frame = NSRect(x: textX, y: h - 5 - 19 - 1 - 16, width: textWidth, height: 16)
        }
    }
}

/// The chosen block's row, opened into its summary card (the row's
/// highlight its ground).
final class CardCell: NSTableCellView {
    static let identifier = NSUserInterfaceItemIdentifier("CardCell")
    private var card: SummaryCard?

    init() {
        super.init(frame: .zero)
        identifier = Self.identifier
    }

    required init?(coder: NSCoder) { fatalError() }

    func show(_ content: SummaryCardContent) {
        if let card { card.content = content } else {
            let c = SummaryCard(content)
            c.plain = true
            addSubview(c)
            card = c
        }
        needsLayout = true
    }

    /// Its symbol and title where the rows' are.
    override func layout() {
        super.layout()
        card?.frame = NSRect(x: 6, y: 0, width: bounds.width - 6, height: bounds.height)
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
        symbol.symbolConfiguration = .init(pointSize: UIType.symbolSize, weight: .medium)
        symbol.contentTintColor = Theme.secondaryText
        title.lineBreakMode = .byTruncatingTail
        title.maximumNumberOfLines = 1
        detail.font = UIType.caption
        detail.textColor = Theme.tertiaryText
        detail.lineBreakMode = .byTruncatingMiddle
        excerpt.maximumNumberOfLines = 2
        excerpt.lineBreakMode = .byTruncatingTail
        excerpt.cell?.truncatesLastVisibleLine = true
        note.font = UIType.detail
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
            s.addAttributes([.font: bold, .foregroundColor: Tints.accentText], range: r)
            range = NSRange(location: r.upperBound, length: ns.length - r.upperBound)
        }
        return s
    }

    func show(_ item: FinderItem, excerpt text: String) {
        symbol.image = FileCell.image(item.symbol)
        title.attributedStringValue = Self.marking(item.title, item.marked, font: UIType.title,
                                                   bold: .systemFont(ofSize: 13, weight: .bold), color: Theme.text)
        detail.stringValue = item.detail.uppercased()
        excerpt.attributedStringValue = Self.marking(text, item.marked, font: UIType.body,
                                                     bold: .systemFont(ofSize: 12, weight: .semibold), color: Theme.secondaryText)
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
    /// ⌘↩ (⇧⌘↩, ⌥⌘↩): the row chosen beside (in the system's app, over) —
    /// before the menu's Edit or View, or Maximize, takes it.
    var onCommandReturn: (() -> Void)?
    override var canBecomeKey: Bool { true }
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if event.keyCode == 36, event.modifierFlags.intersection([.command, .control]) == .command, let onCommandReturn {
            onCommandReturn()
            return true
        }
        return super.performKeyEquivalent(with: event)
    }
    override func resignKey() {
        super.resignKey()
        onResign?()
    }
}

/// A kind, as the finder shows it: a chip before the query (its symbol and
/// name, on the tint), or a count at the foot (its symbol and how many,
/// in the accent once chosen). Clicked, toggled.
final class KindToken: NSView {
    enum Style: Equatable {
        case chip
        case count(Int, on: Bool)
    }
    static let chipHeight: CGFloat = 26
    static let countHeight: CGFloat = 18
    let kind: FindKinds.Kind
    let style: Style
    var onClick: (() -> Void)?
    private var hovered = false { didSet { if hovered != oldValue { needsDisplay = true } } }

    init(kind: FindKinds.Kind, style: Style) {
        self.kind = kind
        self.style = style
        super.init(frame: .zero)
    }

    required init?(coder: NSCoder) { fatalError() }

    private var label: String {
        switch style {
        case .chip: kind.title
        case let .count(n, _): "\(n)"
        }
    }
    private var font: NSFont { style == .chip ? UIType.title : UIType.footnote }
    private var symbolSize: CGFloat { style == .chip ? 13 : 11 }
    private var color: NSColor {
        switch style {
        case .chip: Theme.text
        case let .count(_, on): on ? Theme.accent : hovered ? Theme.secondaryText : Theme.tertiaryText
        }
    }

    var wanted: NSSize {
        let text = ceil((label as NSString).size(withAttributes: [.font: font]).width)
        return style == .chip ? NSSize(width: 8 + 16 + 4 + text + 10, height: Self.chipHeight)
            : NSSize(width: 5 + 14 + 3 + text + 6, height: Self.countHeight)
    }

    var said: String {
        if case let .count(n, on) = style { return "\(kind.name)=\(n)\(on ? "*" : "")" }
        return kind.name
    }

    override func draw(_ dirtyRect: NSRect) {
        let h = bounds.height
        switch style {
        case .chip:
            (hovered ? Theme.selection.blended(withFraction: 0.25, of: Theme.accent) ?? Theme.selection : Theme.selection).setFill()
            NSBezierPath(roundedRect: bounds, xRadius: 6, yRadius: 6).fill()
        case let .count(_, on):
            if on || hovered {
                (on ? Theme.selection : Theme.hover).setFill()
                NSBezierPath(roundedRect: bounds, xRadius: 4, yRadius: 4).fill()
            }
        }
        let iconX: CGFloat = style == .chip ? 8 : 5, iconWidth: CGFloat = style == .chip ? 16 : 14
        if let image = NSImage(systemSymbolName: kind.symbol, accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: symbolSize, weight: .medium).applying(.init(paletteColors: [color]))) {
            let size = image.size
            image.draw(in: NSRect(x: iconX + (iconWidth - size.width) / 2, y: ((h - size.height) / 2).rounded(), width: size.width, height: size.height))
        }
        let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color]
        let textHeight = (label as NSString).size(withAttributes: attrs).height
        (label as NSString).draw(at: NSPoint(x: iconX + iconWidth + (style == .chip ? 4 : 3), y: ((h - textHeight) / 2).rounded()), withAttributes: attrs)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
    }
    override func mouseEntered(with event: NSEvent) { hovered = true }
    override func mouseExited(with event: NSEvent) { hovered = false }
    override func mouseDown(with event: NSEvent) { onClick?() }
    // A click in the panel goes to it, not to moving the panel.
    override var mouseDownCanMoveWindow: Bool { false }
}
