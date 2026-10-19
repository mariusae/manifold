import AppKit
import ManifoldCore

protocol DiffViewDelegate: AnyObject {
    /// Open the new side's file at a line, beside the diff.
    func diffView(_ view: DiffView, open path: String, line: Int)
    func diffViewReload(_ view: DiffView)
}

/// The diff lens (DESIGN.md §7.5): a file at two points, or a commit, as
/// rows of context, additions and removals with line numbers on both
/// sides, long stretches of context folded (click to unfold). Double-click
/// a row to open the file there.
final class DiffView: NSView, PaneContent, KeepsViewState {
    let keeper = ViewStateKeeper()
    let placement: PlacementID
    let block: BlockID
    weak var delegate: DiffViewDelegate?
    var source: () -> Block? = { nil }
    var theme: FontTheme { didSet { if theme != oldValue { rowsView.font = theme.font(.monospaced, size: 12); rowsView.needsDisplay = true } } }

    private let header = NSTextField(labelWithString: "")
    private let note = NSTextField(labelWithString: "")
    private let scroll = NSScrollView()
    private let rowsView = DiffRowsView()
    private var loadedAt: Stamp?
    private var unfolded = false

    var focusView: NSView { rowsView }
    var isDead: Bool { false }

    // MARK: Find

    private lazy var finder = FindHost(view: self, target: self)
    private var foundRows: [Int] = []
    private var foundAt: Int?

    @objc override func performTextFinderAction(_ sender: Any?) { finder.perform(sender) }

    init(placement: PlacementID, block: BlockID, theme: FontTheme) {
        self.placement = placement
        self.block = block
        self.theme = theme
        super.init(frame: .zero)
        wantsLayer = true
        themed { $0.layer?.backgroundColor = Theme.windowBackground.cgColor }
        header.font = .systemFont(ofSize: 12, weight: .medium)
        header.textColor = Theme.secondaryText
        header.lineBreakMode = .byTruncatingMiddle
        note.font = .systemFont(ofSize: 11.5)
        note.textColor = Theme.secondaryText
        note.alignment = .right
        addSubview(header)
        addSubview(note)
        rowsView.font = theme.font(.monospaced, size: 12)
        rowsView.onFold = { [weak self] in
            self?.unfolded = true
            self?.rebuild()
            self?.keeper.note(["unfolded": "1"])
        }
        rowsView.onOpen = { [weak self] row in
            guard let self, let b = self.source(), let subject = b.diff?.subject else { return }
            switch subject {
            case let .sides(_, new): self.delegate?.diffView(self, open: new.path, line: row.newLine ?? row.oldLine ?? 1)
            case let .commit(repo, _):
                if let file = self.rowsView.file(of: row) { self.delegate?.diffView(self, open: repo.appendingPathComponent(file), line: row.newLine ?? 1) }
            case .versions:
                if let path = b.path { self.delegate?.diffView(self, open: path, line: row.newLine ?? row.oldLine ?? 1) }
            }
        }
        scroll.documentView = rowsView
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        addSubview(scroll)
        scroll.watchScrolling { [weak self] x, y in self?.keeper.note(["scrollX": "\(x)", "scroll": "\(y)"]) }
        documentChanged()
    }

    required init?(coder: NSCoder) { fatalError() }

    func destroy() { keeper.flush() }

    private func restoreState() {
        guard !keeper.restored, !rowsView.rows.isEmpty else { return }
        keeper.restored = true
        if keeper.value("unfolded") == "1", !unfolded {
            unfolded = true
            rebuild()
        }
        let x = keeper.double("scrollX") ?? 0, y = keeper.double("scroll") ?? 0
        if x != 0 || y != 0 { DispatchQueue.main.async { [weak self] in self?.scroll.scrollTo(x: x, y: y) } }
    }

    override func layout() {
        super.layout()
        header.frame = NSRect(x: 12, y: bounds.height - 24, width: bounds.width * 0.6, height: 16)
        note.frame = NSRect(x: bounds.width * 0.6 + 12, y: bounds.height - 24, width: bounds.width * 0.4 - 24, height: 16)
        scroll.frame = NSRect(x: 0, y: 0, width: bounds.width, height: bounds.height - 32)
        rowsView.minWidth = scroll.contentSize.width
        rowsView.relayout()
        finder.layout(in: bounds)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil { delegate?.diffViewReload(self) }
    }

    func documentChanged() {
        guard let b = source(), let d = b.diff else { return }
        header.stringValue = b.displayTitle
        guard d.loadedAt != loadedAt else { return }
        loadedAt = d.loadedAt
        rebuild()
    }

    private func rebuild() {
        guard let b = source(), let d = b.diff else { return }
        var rows: [DiffRow] = []
        if let e = d.error {
            note.stringValue = e
        } else if let patch = d.patch {
            rows = DiffRows.patch(patch)
        } else if let old = d.oldText, let new = d.newText {
            rows = DiffRows.sides(old: old, new: new, unfolded: unfolded)
        } else {
            note.stringValue = d.loadedAt == nil ? "Reading…" : ""
        }
        if d.error == nil, d.loadedAt != nil {
            let added = rows.filter { $0.kind == .added }.count, removed = rows.filter { $0.kind == .removed }.count
            note.stringValue = added + removed == 0 ? "No difference" : "+\(added) −\(removed)"
        }
        rowsView.rows = rows
        rowsView.relayout()
        if d.loadedAt != nil { restoreState() }
    }
}

/// The rows, drawn: two line-number gutters, then the text; colored by
/// kind.
final class DiffRowsView: NSView {
    var rows: [DiffRow] = [] { didSet { (pairs, rowLines) = Self.pair(rows) } }
    /// Rows found (⌘F), by index into `rows`, and the one gone to.
    var found: Set<Int> = [] { didSet { foundLines = Dictionary(found.map { ($0 < rowLines.count ? rowLines[$0] : $0, $0) }, uniquingKeysWith: { a, _ in a }); needsDisplay = true } }
    var current: Int? { didSet { currentLine = current.map { $0 < rowLines.count ? rowLines[$0] : $0 }; needsDisplay = true } }
    /// The same, by line on screen, side by side.
    private var foundLines: [Int: Int] = [:]
    private var currentLine: Int?
    /// Each row's line on screen, side by side.
    private var rowLines: [Int] = []
    var font: NSFont = .monospacedSystemFont(ofSize: 12, weight: .regular) { didSet { relayout() } }
    var minWidth: CGFloat = 0
    var onFold: (() -> Void)?
    var onOpen: ((DiffRow) -> Void)?
    private let rowHeight: CGFloat = 19
    private let gutter: CGFloat = 92
    /// Each side's gutter, side by side.
    private let sideGutter: CGFloat = 52
    private var widest: CGFloat = 0
    /// Rows paired for side-by-side: a removed line beside the added one
    /// that replaced it, or either alone; a context, hunk, file or fold
    /// row spanning both sides.
    private var pairs: [(left: DiffRow?, right: DiffRow?, span: DiffRow?)] = []
    /// Side by side when there's room for two columns of the widest line.
    private(set) var sideBySide = false

    private static func pair(_ rows: [DiffRow]) -> ([(left: DiffRow?, right: DiffRow?, span: DiffRow?)], [Int]) {
        var out: [(left: DiffRow?, right: DiffRow?, span: DiffRow?)] = []
        var lines = [Int](repeating: 0, count: rows.count)
        var i = 0
        while i < rows.count {
            let r = rows[i]
            switch r.kind {
            case .removed, .added:
                var removed: [Int] = [], added: [Int] = []
                while i < rows.count, case .removed = rows[i].kind { removed.append(i); i += 1 }
                while i < rows.count, case .added = rows[i].kind { added.append(i); i += 1 }
                for j in 0..<max(removed.count, added.count) {
                    if j < removed.count { lines[removed[j]] = out.count }
                    if j < added.count { lines[added[j]] = out.count }
                    out.append((j < removed.count ? rows[removed[j]] : nil, j < added.count ? rows[added[j]] : nil, nil))
                }
            default:
                lines[i] = out.count
                out.append((nil, nil, r))
                i += 1
            }
        }
        return (out, lines)
    }

    /// Where a row is on screen, to scroll it into view.
    func rect(ofRow i: Int) -> NSRect {
        let line = sideBySide ? (i < rowLines.count ? rowLines[i] : 0) : i
        return NSRect(x: 0, y: CGFloat(line) * rowHeight, width: bounds.width, height: rowHeight)
    }

    static let foundBackground = NSColor.dynamic(NSColor(srgbRed: 1, green: 0.95, blue: 0.6, alpha: 1), NSColor(srgbRed: 0.45, green: 0.4, blue: 0.1, alpha: 1))
    static let currentBackground = NSColor.dynamic(NSColor(srgbRed: 1, green: 0.85, blue: 0.3, alpha: 1), NSColor(srgbRed: 0.7, green: 0.55, blue: 0.1, alpha: 1))

    private var lineCount: Int { sideBySide ? pairs.count : rows.count }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }

    func relayout() {
        let attrs: [NSAttributedString.Key: Any] = [.font: font]
        widest = 0
        for r in rows.prefix(4000) where !r.text.isEmpty {
            widest = max(widest, (r.text as NSString).size(withAttributes: attrs).width)
        }
        sideBySide = minWidth >= 2 * (sideGutter + min(widest, 300) + 16) && minWidth >= 700
        let w = sideBySide ? minWidth : max(minWidth, gutter + widest + 40)
        frame = NSRect(x: 0, y: 0, width: w, height: max(CGFloat(lineCount) * rowHeight + 20, minWidth > 0 ? (enclosingScrollView?.contentSize.height ?? 0) : 0))
        needsDisplay = true
    }

    /// The file a row (in a patch) is under.
    func file(of row: DiffRow) -> String? {
        guard let i = rows.firstIndex(of: row) else { return nil }
        for j in stride(from: i, through: 0, by: -1) {
            if case let .file(name) = rows[j].kind { return name }
        }
        return nil
    }

    static let addedBackground = NSColor.dynamic(NSColor(srgbRed: 0.86, green: 0.96, blue: 0.87, alpha: 1), NSColor(srgbRed: 0.13, green: 0.26, blue: 0.16, alpha: 1))
    static let removedBackground = NSColor.dynamic(NSColor(srgbRed: 0.99, green: 0.88, blue: 0.88, alpha: 1), NSColor(srgbRed: 0.3, green: 0.14, blue: 0.14, alpha: 1))
    static let hunkBackground = NSColor.dynamic(NSColor(srgbRed: 0.91, green: 0.94, blue: 0.99, alpha: 1), NSColor(srgbRed: 0.15, green: 0.19, blue: 0.27, alpha: 1))

    override func draw(_ dirtyRect: NSRect) {
        guard !rows.isEmpty else { return }
        let numberFont = NSFont.monospacedDigitSystemFont(ofSize: font.pointSize * 0.85, weight: .regular)
        let textAttrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: Theme.text]
        let dimAttrs: [NSAttributedString.Key: Any] = [.font: numberFont, .foregroundColor: TextView.gutterText]
        if sideBySide { return drawSides(dirtyRect, textAttrs: textAttrs, dimAttrs: dimAttrs) }
        let first = max(0, Int(dirtyRect.minY / rowHeight)), last = min(rows.count - 1, Int(dirtyRect.maxY / rowHeight))
        guard first <= last else { return }
        for i in first...last {
            let r = rows[i]
            let y = CGFloat(i) * rowHeight
            let band = NSRect(x: 0, y: y, width: bounds.width, height: rowHeight)
            var attrs = textAttrs
            var marker = " "
            switch r.kind {
            case .added: Self.addedBackground.setFill(); band.fill(); marker = "+"
            case .removed: Self.removedBackground.setFill(); band.fill(); marker = "−"
            case .hunk: Self.hunkBackground.setFill(); band.fill(); attrs[.foregroundColor] = Theme.secondaryText
            case .file:
                Theme.hover.setFill(); band.fill()
                attrs[.font] = NSFont.systemFont(ofSize: font.pointSize, weight: .semibold)
            case .fold: attrs[.foregroundColor] = Theme.secondaryText
            case .context: break
            }
            if found.contains(i) {
                (i == current ? Self.currentBackground : Self.foundBackground).setFill()
                NSRect(x: gutter - 4, y: y, width: bounds.width - gutter + 4, height: rowHeight).fill()
            }
            let textY = y + (rowHeight - font.pointSize * 1.2) / 2 - 1
            switch r.kind {
            case let .file(name):
                (name as NSString).draw(at: NSPoint(x: 12, y: textY), withAttributes: attrs)
            case let .fold(n):
                ("⋯ \(n) unchanged line\(n == 1 ? "" : "s")" as NSString).draw(at: NSPoint(x: gutter, y: textY), withAttributes: attrs)
            case .hunk:
                ("@@ −\(r.oldLine ?? 0) +\(r.newLine ?? 0) @@ \(r.text)" as NSString).draw(at: NSPoint(x: gutter, y: textY), withAttributes: attrs)
            default:
                if let o = r.oldLine {
                    let s = NSAttributedString(string: "\(o)", attributes: dimAttrs)
                    s.draw(at: NSPoint(x: 40 - s.size().width, y: textY + 1))
                }
                if let n = r.newLine {
                    let s = NSAttributedString(string: "\(n)", attributes: dimAttrs)
                    s.draw(at: NSPoint(x: 76 - s.size().width, y: textY + 1))
                }
                (marker as NSString).draw(at: NSPoint(x: gutter - 12, y: textY), withAttributes: attrs)
                (r.text as NSString).draw(at: NSPoint(x: gutter, y: textY), withAttributes: attrs)
            }
        }
    }

    /// Old on the left, new on the right, a line between; a removed line
    /// faces the added one that replaced it.
    private func drawSides(_ dirtyRect: NSRect, textAttrs: [NSAttributedString.Key: Any], dimAttrs: [NSAttributedString.Key: Any]) {
        let first = max(0, Int(dirtyRect.minY / rowHeight)), last = min(pairs.count - 1, Int(dirtyRect.maxY / rowHeight))
        guard first <= last else { return }
        let half = (bounds.width / 2).rounded()
        let textY = { (y: CGFloat) in y + (self.rowHeight - self.font.pointSize * 1.2) / 2 - 1 }
        func side(_ row: DiffRow?, x: CGFloat, width: CGFloat, y: CGFloat, number: Int?) {
            guard let row else { return }
            let band = NSRect(x: x, y: y, width: width, height: rowHeight)
            var marker = " "
            switch row.kind {
            case .added: Self.addedBackground.setFill(); band.fill(); marker = "+"
            case .removed: Self.removedBackground.setFill(); band.fill(); marker = "−"
            default: break
            }
            if let number {
                let s = NSAttributedString(string: "\(number)", attributes: dimAttrs)
                s.draw(at: NSPoint(x: x + 36 - s.size().width, y: textY(y) + 1))
            }
            (marker as NSString).draw(at: NSPoint(x: x + sideGutter - 12, y: textY(y)), withAttributes: textAttrs)
            NSGraphicsContext.current?.saveGraphicsState()
            NSBezierPath(rect: NSRect(x: x + sideGutter, y: y, width: max(0, width - sideGutter - 8), height: rowHeight)).addClip()
            (row.text as NSString).draw(at: NSPoint(x: x + sideGutter, y: textY(y)), withAttributes: textAttrs)
            NSGraphicsContext.current?.restoreGraphicsState()
        }
        for i in first...last {
            if let line = foundLines[i] {
                (line == currentLine ? Self.currentBackground : Self.foundBackground).setFill()
                NSRect(x: 0, y: CGFloat(i) * rowHeight, width: bounds.width, height: rowHeight).fill()
            }
            let pair = pairs[i]
            let y = CGFloat(i) * rowHeight
            if let r = pair.span {
                var attrs = textAttrs
                let band = NSRect(x: 0, y: y, width: bounds.width, height: rowHeight)
                switch r.kind {
                case .hunk:
                    Self.hunkBackground.setFill(); band.fill(); attrs[.foregroundColor] = Theme.secondaryText
                    ("@@ −\(r.oldLine ?? 0) +\(r.newLine ?? 0) @@ \(r.text)" as NSString).draw(at: NSPoint(x: sideGutter, y: textY(y)), withAttributes: attrs)
                case let .file(name):
                    Theme.hover.setFill(); band.fill()
                    attrs[.font] = NSFont.systemFont(ofSize: font.pointSize, weight: .semibold)
                    (name as NSString).draw(at: NSPoint(x: 12, y: textY(y)), withAttributes: attrs)
                case let .fold(n):
                    attrs[.foregroundColor] = Theme.secondaryText
                    ("⋯ \(n) unchanged line\(n == 1 ? "" : "s")" as NSString).draw(at: NSPoint(x: sideGutter, y: textY(y)), withAttributes: attrs)
                default:
                    // Context: the same line on both sides, numbered each way.
                    side(r, x: 0, width: half, y: y, number: r.oldLine)
                    side(r, x: half, width: bounds.width - half, y: y, number: r.newLine)
                }
            } else {
                side(pair.left, x: 0, width: half, y: y, number: pair.left?.oldLine)
                side(pair.right, x: half, width: bounds.width - half, y: y, number: pair.right?.newLine)
            }
        }
        Theme.divider.setFill()
        NSRect(x: half - 0.5, y: dirtyRect.minY, width: 1, height: dirtyRect.height).fill()
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        let p = convert(event.locationInWindow, from: nil)
        let i = Int(p.y / rowHeight)
        let row: DiffRow?
        if sideBySide {
            guard i >= 0, i < pairs.count else { return }
            let pair = pairs[i]
            row = pair.span ?? (p.x < bounds.width / 2 ? pair.left ?? pair.right : pair.right ?? pair.left)
        } else {
            guard i >= 0, i < rows.count else { return }
            row = rows[i]
        }
        guard let row else { return }
        if case .fold = row.kind { onFold?(); return }
        if event.clickCount == 2 { onOpen?(row) }
    }
}

extension DiffView: Searchable {
    /// Rows holding the query, highlighted; the first from the one gone to
    /// (or the top) scrolled to.
    func search(_ query: String, caseSensitive: Bool, done: @escaping (Int?) -> Void) {
        guard !query.isEmpty else {
            foundRows = []
            foundAt = nil
            rowsView.found = []
            rowsView.current = nil
            return done(nil)
        }
        let options: String.CompareOptions = caseSensitive ? [] : [.caseInsensitive]
        foundRows = rowsView.rows.indices.filter { rowsView.rows[$0].text.range(of: query, options: options) != nil }
        rowsView.found = Set(foundRows)
        let from = foundAt == nil ? 0 : (rowsView.current ?? 0)
        foundAt = foundRows.firstIndex { $0 >= from } ?? (foundRows.isEmpty ? nil : 0)
        goToFound()
        done(foundRows.count)
    }

    func findNext(forward: Bool) {
        guard !foundRows.isEmpty else { return }
        let n = foundRows.count
        foundAt = ((foundAt ?? (forward ? -1 : 0)) + (forward ? 1 : n - 1)) % n
        goToFound()
    }

    private func goToFound() {
        guard let at = foundAt, at < foundRows.count else { rowsView.current = nil; return }
        let row = foundRows[at]
        rowsView.current = row
        rowsView.scrollToVisible(rowsView.rect(ofRow: row).insetBy(dx: 0, dy: -60))
    }

    func endSearch() {
        foundRows = []
        foundAt = nil
        rowsView.found = []
        rowsView.current = nil
        window?.makeFirstResponder(rowsView)
    }

    func textForFind(_ done: @escaping (String?) -> Void) { done(nil) }
}
