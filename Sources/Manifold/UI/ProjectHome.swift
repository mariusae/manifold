import AppKit
import ManifoldCore

/// What a project's homepage (§2.6) asks its tile to do.
enum ProjectAction {
    /// Its changes and commits, in a git tile of their own.
    case openGit
    case openCommit(GitCommit, repo: String)
    case openChange(GitStatusEntry, repo: String)
    /// Its index made again.
    case reindex
    /// Its settings: its indexer, and when it's indexed.
    case settings
}

/// How a project stands, as its homepage shows it: its repository's
/// state scoped to it, and its index's.
struct ProjectFacts: Equatable {
    var project: Project
    /// The repository's root (its git block's path), if it's in one.
    var repo: String?
    var git: GitState?
    /// How its index stands; nil until the host has said.
    var index: SCIPStatus?
    /// Why it has none to speak of (no indexer for its language).
    var indexMissing: String?
    /// Its git block asked for, and not come yet.
    var gitPending = false
}

/// The line under a project's header (§2.6): its branch, how far from
/// upstream, its changes, how its index stands — each a flat button
/// doing the obvious thing (the branch and changes open its git tile;
/// the index's makes it again).
final class ProjectStrip: NSView {
    var onAction: ((ProjectAction) -> Void)?
    private let branch = FlatButton("", symbol: "arrow.triangle.branch", font: UIType.detail)
    private let changes = FlatButton("", symbol: "plusminus", font: UIType.detail)
    private let index = FlatButton("", symbol: "circle.dashed", font: UIType.detail)
    private var reindexes = false
    static let height: CGFloat = 30

    override init(frame: NSRect) {
        super.init(frame: frame)
        for b in [branch, changes, index] {
            b.target = self
            addSubview(b)
        }
        branch.action = #selector(openGit)
        changes.action = #selector(openGit)
        index.action = #selector(reindex)
    }

    required init?(coder: NSCoder) { fatalError() }

    @objc private func openGit() { onAction?(.openGit) }
    @objc private func reindex() { if reindexes { onAction?(.reindex) } }

    func show(_ f: ProjectFacts) {
        if let g = f.git, f.repo != nil, g.error == nil || g.refreshedAt == nil {
            var words = g.branch ?? (g.refreshedAt == nil ? "Reading…" : "detached")
            if g.ahead > 0 { words += " ↑\(g.ahead)" }
            if g.behind > 0 { words += " ↓\(g.behind)" }
            branch.title = words
            branch.toolTip = (g.vcs == .sapling ? "Sapling" : "Git") + " repository at \(f.repo?.abbreviatingHome ?? "")"
                + (g.scope.map { " — this project is \($0) in it" } ?? "")
            changes.title = g.refreshedAt == nil ? "" : g.status.isEmpty ? "No changes" : g.status.count == 1 ? "1 change" : "\(g.status.count) changes"
            changes.isHidden = changes.title.isEmpty
        } else {
            branch.title = f.gitPending ? "Reading…" : "Not in a repository"
            branch.toolTip = f.git?.error
            changes.isHidden = true
        }
        let (symbol, words, tip, again) = Self.indexWords(f)
        index.symbolName = symbol
        index.title = words
        index.toolTip = tip
        reindexes = again
        needsLayout = true
    }

    /// The index's chip: its symbol, words, tip, and whether a click
    /// indexes it again.
    static func indexWords(_ f: ProjectFacts) -> (String, String, String?, Bool) {
        if let missing = f.indexMissing { return ("minus.circle", "No index", missing.prefix(1).uppercased() + missing.dropFirst(), false) }
        guard let s = f.index else { return ("circle.dashed", "Index…", nil, false) }
        let by = s.indexer.map { " · \($0)" } ?? ""
        switch s.state {
        case .none: return ("circle.dashed", "Not indexed — Index", "Make its index (SCIP)\(s.indexer.map { ", with the \($0) indexer" } ?? "")", true)
        case .indexing: return ("arrow.triangle.2.circlepath", "Indexing…" + by, nil, false)
        case .current:
            let when = s.at.map { Age.short(Stamp(wall: Int64($0.timeIntervalSince1970 * 1000))) } ?? ""
            return ("checkmark.circle", "Indexed" + (when.isEmpty ? "" : when == "now" ? " just now" : " \(when) ago") + by, "Index again", true)
        case .failed: return ("exclamationmark.triangle", "Indexing failed" + by, (s.message ?? "") + "\n\nClick to index again", true)
        }
    }

    override func layout() {
        super.layout()
        var x: CGFloat = 8
        for b in [branch, changes, index] where !b.isHidden {
            b.sizeToFit()
            let w = min(b.frame.width, max(0, bounds.width - 8 - x))
            b.frame = NSRect(x: x, y: ((bounds.height - Flat.buttonHeight) / 2).rounded(), width: w, height: Flat.buttonHeight)
            x += w + 2
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        Theme.divider.setFill()
        NSRect(x: 0, y: 0, width: bounds.width, height: 1).fill()
    }

    var debugState: String {
        [branch, changes, index].filter { !$0.isHidden }.map(\.title).joined(separator: " | ")
    }
}

/// A project's sidebar (§2.6), at its homepage's right, as GitHub has
/// one: its changes and its recent commits — the project's alone, where
/// it's a folder in a bigger repository — each opened as a diff beside.
final class ProjectSidebar: NSView {
    var onAction: ((ProjectAction) -> Void)?
    private let scroll = ClippingScrollView()
    private let stack = FlippedView()
    private var shown: ProjectFacts?
    static let width: CGFloat = 280

    override init(frame: NSRect) {
        super.init(frame: frame)
        scroll.documentView = stack
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        addSubview(scroll)
    }

    required init?(coder: NSCoder) { fatalError() }

    func show(_ f: ProjectFacts) {
        guard f.git != shown?.git || f.repo != shown?.repo else { return }
        shown = f
        stack.subviews.forEach { $0.removeFromSuperview() }
        guard let g = f.git, g.refreshedAt != nil, f.repo != nil, g.error == nil else { return relayout() }
        let repo = f.repo ?? ""
        // Where a path of the repository's is, from the project's root.
        let scope = g.scope.map { $0 + "/" } ?? ""
        func inProject(_ path: String) -> String { path.hasPrefix(scope) ? String(path.dropFirst(scope.count)) : path }

        if !g.status.isEmpty {
            add(SectionLabel(g.status.count == 1 ? "1 change" : "\(g.status.count) changes"))
            for s in g.status.prefix(8) {
                let letter = s.isUntracked ? "?" : (s.workTree != " " ? s.workTree : s.index)
                let row = HomeRow(mark: letter, markColor: s.isUntracked ? Theme.secondaryText : (s.index != " " ? TextView.addedColor : TextView.modifiedColor),
                                  title: inProject(s.path), detail: nil)
                row.toolTip = repo.appendingPathComponent(s.path).abbreviatingHome
                row.onClick = { [weak self] in self?.onAction?(.openChange(s, repo: repo)) }
                add(row)
            }
            if g.status.count > 8 { add(more("and \(g.status.count - 8) more")) }
        }
        add(SectionLabel(g.log.isEmpty ? "No commits" : "Recent commits"))
        for c in g.log.prefix(10) {
            let when = Age.short(Stamp(wall: Int64(c.date * 1000)))
            let row = HomeRow(mark: nil, markColor: nil, title: c.summary, detail: "\(c.short) · \(c.author) · \(when == "now" ? "just now" : when + " ago")")
            row.toolTip = c.summary
            row.onClick = { [weak self] in self?.onAction?(.openCommit(c, repo: repo)) }
            add(row)
        }
        if !g.log.isEmpty { add(more(g.scope == nil ? "All commits" : "All commits here")) }
        relayout()
    }

    private func more(_ words: String) -> HomeRow {
        let row = HomeRow(mark: nil, markColor: nil, title: words + " →", detail: nil, quiet: true)
        row.onClick = { [weak self] in self?.onAction?(.openGit) }
        return row
    }

    private func add(_ v: NSView) { stack.addSubview(v) }

    private func relayout() {
        var y: CGFloat = 8
        let w = max(0, scroll.contentSize.width)
        for v in stack.subviews {
            let h = (v as? HomeRow)?.height ?? (v as? SectionLabel)?.height ?? 20
            if v is SectionLabel, y > 8 { y += 8 }
            v.frame = NSRect(x: 0, y: y, width: w, height: h)
            y += h
        }
        stack.frame = NSRect(x: 0, y: 0, width: w, height: max(y + 8, scroll.contentSize.height))
    }

    override func layout() {
        super.layout()
        scroll.frame = bounds.insetBy(dx: 0, dy: 0)
        relayout()
    }

    override func draw(_ dirtyRect: NSRect) {
        Theme.divider.setFill()
        NSRect(x: 0, y: 0, width: 1, height: bounds.height).fill()
    }

    var debugState: String {
        stack.subviews.map { ($0 as? HomeRow)?.debugState ?? ($0 as? SectionLabel)?.stringValue.uppercased() ?? "?" }.joined(separator: "\n")
    }
}

/// A heading in a homepage's sidebar.
private final class SectionLabel: NSTextField {
    let height: CGFloat = 24
    init(_ words: String) {
        super.init(frame: .zero)
        isEditable = false
        isBordered = false
        drawsBackground = false
        stringValue = words
        font = UIType.caption
        textColor = Theme.secondaryText
    }
    required init?(coder: NSCoder) { fatalError() }
    override func draw(_ dirtyRect: NSRect) {
        let r = NSRect(x: 14, y: 6, width: bounds.width - 28, height: 14)
        (stringValue as NSString).draw(with: r, options: [.truncatesLastVisibleLine, .usesLineFragmentOrigin],
                                       attributes: [.font: UIType.caption, .foregroundColor: Theme.secondaryText])
    }
}

/// A row of a homepage's sidebar: a mark (a change's letter), its words
/// and a detail under them, a faint band under the pointer; clicked, it
/// does its thing.
final class HomeRow: NSView {
    var onClick: (() -> Void)?
    private let mark: String?
    private let markColor: NSColor?
    private let title: String
    private let detail: String?
    private let quiet: Bool
    private var hovering = false { didSet { if hovering != oldValue { needsDisplay = true } } }
    var height: CGFloat { detail == nil ? 24 : 40 }

    init(mark: String?, markColor: NSColor?, title: String, detail: String?, quiet: Bool = false) {
        self.mark = mark
        self.markColor = markColor
        self.title = title
        self.detail = detail
        self.quiet = quiet
        super.init(frame: .zero)
    }

    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }

    override func updateTrackingAreas() {
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
        super.updateTrackingAreas()
    }

    override func mouseEntered(with event: NSEvent) { hovering = true }
    override func mouseExited(with event: NSEvent) { hovering = false }
    override func mouseDown(with event: NSEvent) {}
    override func mouseUp(with event: NSEvent) {
        if bounds.contains(convert(event.locationInWindow, from: nil)) { onClick?() }
    }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .pointingHand) }

    override func draw(_ dirtyRect: NSRect) {
        if hovering {
            Flat.hovered.setFill()
            NSBezierPath(roundedRect: bounds.insetBy(dx: 6, dy: 1), xRadius: Radius.control, yRadius: Radius.control).fill()
        }
        var x: CGFloat = 14
        if let mark {
            let a: [NSAttributedString.Key: Any] = [.font: NSFont.monospacedSystemFont(ofSize: 11, weight: .semibold), .foregroundColor: markColor ?? Theme.secondaryText]
            (mark as NSString).draw(at: NSPoint(x: x, y: 5), withAttributes: a)
            x += 16
        }
        let para = NSMutableParagraphStyle()
        para.lineBreakMode = quiet ? .byTruncatingTail : (mark != nil ? .byTruncatingMiddle : .byTruncatingTail)
        let titleAttrs: [NSAttributedString.Key: Any] = [.font: UIType.body, .foregroundColor: quiet ? Tints.accentText : Theme.text, .paragraphStyle: para]
        (title as NSString).draw(in: NSRect(x: x, y: 4, width: bounds.width - x - 12, height: 16), withAttributes: titleAttrs)
        if let detail {
            let detailAttrs: [NSAttributedString.Key: Any] = [.font: UIType.footnote, .foregroundColor: Theme.secondaryText, .paragraphStyle: para]
            (detail as NSString).draw(in: NSRect(x: x, y: 21, width: bounds.width - x - 12, height: 15), withAttributes: detailAttrs)
        }
    }

    var debugState: String { (mark.map { $0 + " " } ?? "") + title + (detail.map { " — " + $0 } ?? "") }
}
