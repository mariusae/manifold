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
final class DiffView: NSView, PaneContent {
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
        documentChanged()
    }

    required init?(coder: NSCoder) { fatalError() }

    func destroy() {}

    override func layout() {
        super.layout()
        header.frame = NSRect(x: 12, y: bounds.height - 24, width: bounds.width * 0.6, height: 16)
        note.frame = NSRect(x: bounds.width * 0.6 + 12, y: bounds.height - 24, width: bounds.width * 0.4 - 24, height: 16)
        scroll.frame = NSRect(x: 0, y: 0, width: bounds.width, height: bounds.height - 32)
        rowsView.minWidth = scroll.contentSize.width
        rowsView.relayout()
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
    }
}

/// The rows, drawn: two line-number gutters, then the text; colored by
/// kind.
final class DiffRowsView: NSView {
    var rows: [DiffRow] = []
    var font: NSFont = .monospacedSystemFont(ofSize: 12, weight: .regular) { didSet { relayout() } }
    var minWidth: CGFloat = 0
    var onFold: (() -> Void)?
    var onOpen: ((DiffRow) -> Void)?
    private let rowHeight: CGFloat = 19
    private let gutter: CGFloat = 92
    private var widest: CGFloat = 0

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }

    func relayout() {
        let attrs: [NSAttributedString.Key: Any] = [.font: font]
        widest = 0
        for r in rows.prefix(4000) where !r.text.isEmpty {
            widest = max(widest, (r.text as NSString).size(withAttributes: attrs).width)
        }
        let w = max(minWidth, gutter + widest + 40)
        frame = NSRect(x: 0, y: 0, width: w, height: max(CGFloat(rows.count) * rowHeight + 20, minWidth > 0 ? (enclosingScrollView?.contentSize.height ?? 0) : 0))
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
        let first = max(0, Int(dirtyRect.minY / rowHeight)), last = min(rows.count - 1, Int(dirtyRect.maxY / rowHeight))
        guard first <= last else { return }
        let numberFont = NSFont.monospacedDigitSystemFont(ofSize: font.pointSize * 0.85, weight: .regular)
        let textAttrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: Theme.text]
        let dimAttrs: [NSAttributedString.Key: Any] = [.font: numberFont, .foregroundColor: TextView.gutterText]
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

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        let p = convert(event.locationInWindow, from: nil)
        let i = Int(p.y / rowHeight)
        guard i >= 0, i < rows.count else { return }
        if case .fold = rows[i].kind { onFold?(); return }
        if event.clickCount == 2 { onOpen?(rows[i]) }
    }
}
