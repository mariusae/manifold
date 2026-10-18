import AppKit
import ManifoldCore

/// A block's history, over the window (§3.4): a slider through its log,
/// and the block as it was then. For an arrangement, a diagram of its
/// columns (the layout then; the blocks as they are now, or, with
/// "everything as it was", each file's text rewound to the same moment);
/// for a text block, the text then, read-only, with a diff against now
/// a button away. Restore appends what makes it so again.
final class HistoryView: NSView {
    var onClose: (() -> Void)?
    /// Restore an arrangement: the state, and the moment to rewind the
    /// files to, if asked.
    var onRestore: ((ArrangementState, Stamp?) -> Void)?
    /// Restore a text block to the text it had.
    var onRestoreText: ((String) -> Void)?
    /// Compare the text then with now.
    var onCompare: ((Stamp) -> Void)?
    /// Asked for a block's own log (for "everything as it was").
    var onNeedBlock: ((BlockID) -> Void)?
    var titleOf: (BlockID) -> String = { $0.description }
    var symbolOf: (Lens) -> String = { _ in "doc" }
    var font: NSFont = .monospacedSystemFont(ofSize: 12, weight: .regular)

    private let panel = NSView()
    private let slider = NSSlider()
    private let when = NSTextField(labelWithString: "")
    private let diagram = ArrangementDiagram()
    private let scroll = NSScrollView()
    private let textView = TextView()
    private let textDocument = StaticDocument()
    private let everything = NSButton(checkboxWithTitle: "Everything as it was", target: nil, action: nil)
    private let compare = NSButton(title: "Compare with Now", target: nil, action: nil)
    private let restore = NSButton(title: "Restore", target: nil, action: nil)
    private let close = NSButton(title: "Done", target: nil, action: nil)
    private var entries: [Entry] = []
    private var states: [ArrangementState] = []
    private var texts: [String] = []
    private var isText = false
    /// Logs of the blocks an arrangement placed, as they arrive.
    private var blockEntries: [BlockID: [Entry]] = [:]
    private var blockID: BlockID?

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        panel.wantsLayer = true
        themed {
            $0.layer?.backgroundColor = Theme.scrim.cgColor
            $0.panel.layer?.backgroundColor = Theme.panel.cgColor
            $0.panel.layer?.borderColor = Theme.panelBorder.cgColor
        }
        panel.layer?.cornerRadius = 12
        panel.layer?.cornerCurve = .continuous
        panel.layer?.borderWidth = 0.5
        addSubview(panel)
        slider.target = self
        slider.action = #selector(scrubbed)
        slider.isContinuous = true
        when.font = .systemFont(ofSize: 12)
        when.textColor = Theme.secondaryText
        when.alignment = .center
        restore.target = self
        restore.action = #selector(restoreClicked)
        restore.bezelStyle = .rounded
        close.target = self
        close.action = #selector(closeClicked)
        close.bezelStyle = .rounded
        close.keyEquivalent = "\u{1b}"
        diagram.titleOf = { [weak self] in self?.titleOf($0) ?? "?" }
        diagram.symbolOf = { [weak self] in self?.symbolOf($0) ?? "doc" }
        everything.target = self
        everything.action = #selector(scrubbed)
        everything.font = .systemFont(ofSize: 12)
        everything.toolTip = "Each file rewound to this moment too"
        compare.target = self
        compare.action = #selector(compareClicked)
        compare.bezelStyle = .rounded
        compare.isHidden = true
        textView.document = textDocument
        textView.isEditable = false
        textView.autoresizingMask = [.width]
        scroll.documentView = textView
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        scroll.automaticallyAdjustsContentInsets = false
        scroll.wantsLayer = true
        scroll.layer?.cornerRadius = 8
        scroll.isHidden = true
        for v in [slider, when, diagram, scroll, everything, compare, restore, close] { panel.addSubview(v) }
    }

    required init?(coder: NSCoder) { fatalError() }

    func show(entries: [Entry]) {
        self.entries = entries
        isText = false
        var s = ArrangementState()
        states = entries.map { e in
            if case let .create(_, title, _) = e.event { s = ArrangementState(); s.title = title } else { s.apply(e.event) }
            return s
        }
        // The files ever placed: their logs, for "everything as it was".
        var asked: Set<BlockID> = []
        for st in states {
            for p in st.placements where p.lens == .editor || p.lens == .preview { asked.insert(p.block) }
        }
        for b in asked where blockEntries[b] == nil {
            blockEntries[b] = []
            onNeedBlock?(b)
        }
        slider.minValue = 0
        slider.maxValue = Double(max(states.count - 1, 0))
        slider.integerValue = states.count - 1
        scrubbed()
    }

    /// A text block's history: the text as it was, read-only.
    func showText(entries: [Entry], block: BlockID) {
        self.entries = entries
        blockID = block
        isText = true
        diagram.isHidden = true
        everything.isHidden = true
        scroll.isHidden = false
        compare.isHidden = false
        textView.font = font
        var b: Block?
        texts = entries.map { e in
            if case let .create(kind, title, path) = e.event {
                b = Block(id: block, kind: kind, created: e.at, title: title, path: path)
            } else {
                b?.apply(e.event, at: e.at)
            }
            return b?.text?.text.string ?? ""
        }
        slider.minValue = 0
        slider.maxValue = Double(max(texts.count - 1, 0))
        slider.integerValue = texts.count - 1
        scrubbed()
    }

    /// A placed block's log arrived.
    func blockHistory(_ block: BlockID, _ entries: [Entry]) {
        blockEntries[block] = entries
        scrubbed()
    }

    private var index: Int { min(max(slider.integerValue, 0), (isText ? texts.count : states.count) - 1) }

    @objc private func scrubbed() {
        let i = index
        guard i >= 0, i < entries.count else { return }
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .short
        var note = "\(f.string(from: entries[i].at.date)) · change \(i + 1) of \(entries.count)"
        if isText {
            textDocument.rope = Rope(texts[i])
            textDocument.version += 1
            textView.documentChanged()
            restore.isEnabled = i < texts.count - 1
            compare.isEnabled = i < texts.count - 1
            restore.title = "Restore This Text"
        } else {
            diagram.state = states[i]
            let moment = entries[i].at
            if everything.state == .on {
                // How many of the placed files read differently then.
                var differ = 0
                for p in states[i].placements where p.lens == .editor || p.lens == .preview {
                    guard let log = blockEntries[p.block], !log.isEmpty else { continue }
                    let then = Block.replaying(log, id: p.block, upTo: moment)?.text?.text.string ?? ""
                    let now = Block.replaying(log, id: p.block)?.text?.text.string ?? ""
                    if then != now { differ += 1 }
                }
                if differ > 0 { note += " · \(differ) file\(differ == 1 ? "" : "s") read differently" }
                diagram.rewoundTo = moment
            } else {
                diagram.rewoundTo = nil
            }
            restore.isEnabled = i < states.count - 1 || everything.state == .on
        }
        when.stringValue = note
    }

    @objc private func restoreClicked() {
        let i = index
        guard i >= 0 else { return }
        if isText {
            onRestoreText?(texts[i])
        } else {
            onRestore?(states[i], everything.state == .on ? entries[i].at : nil)
        }
    }

    @objc private func compareClicked() {
        let i = index
        guard i >= 0, i < entries.count else { return }
        onCompare?(entries[i].at)
    }

    /// The text a placed block had at a moment, from its log.
    func text(of block: BlockID, at moment: Stamp) -> String? {
        guard let log = blockEntries[block], !log.isEmpty else { return nil }
        return Block.replaying(log, id: block, upTo: moment)?.text?.text.string
    }

    @objc private func closeClicked() { onClose?() }

    override func layout() {
        super.layout()
        let w = min(760, bounds.width - 60), h = min(520, bounds.height - 60)
        panel.frame = NSRect(x: (bounds.width - w) / 2, y: (bounds.height - h) / 2, width: w, height: h).integral
        slider.frame = NSRect(x: 20, y: h - 44, width: w - 40, height: 24)
        when.frame = NSRect(x: 20, y: h - 66, width: w - 40, height: 16)
        diagram.frame = NSRect(x: 20, y: 56, width: w - 40, height: h - 132)
        scroll.frame = diagram.frame
        textView.frame.size.width = scroll.contentSize.width
        close.frame = NSRect(x: w - 100, y: 16, width: 80, height: 28)
        let restoreWidth: CGFloat = isText ? 150 : 88
        restore.frame = NSRect(x: w - 108 - restoreWidth, y: 16, width: restoreWidth, height: 28)
        compare.frame = NSRect(x: restore.frame.minX - 160, y: 16, width: 150, height: 28)
        everything.frame = NSRect(x: 20, y: 20, width: 220, height: 20)
    }

    override func mouseDown(with event: NSEvent) {
        if !panel.frame.contains(convert(event.locationInWindow, from: nil)) { onClose?() }
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { onClose?() } else { super.keyDown(with: event) }
    }

    override var acceptsFirstResponder: Bool { true }
}

/// A text as the history view shows it: a rope and nothing else.
final class StaticDocument: TextViewDocument {
    var rope = Rope()
    var version = 0
    func apply(_ edits: [TextEdit]) {}
}

/// An arrangement drawn small: its columns, each a stack of sheets with
/// titles, the top one whole.
final class ArrangementDiagram: NSView {
    var state = ArrangementState() { didSet { needsDisplay = true } }
    /// Set when the files are to be shown as of a moment: a note on each.
    var rewoundTo: Stamp? { didSet { needsDisplay = true } }
    var titleOf: (BlockID) -> String = { $0.description }
    var symbolOf: (Lens) -> String = { _ in "doc" }

    override func draw(_ dirtyRect: NSRect) {
        Theme.sheet(level: 2).setFill()
        NSBezierPath(roundedRect: bounds, xRadius: 8, yRadius: 8).fill()
        let n = state.columns.count
        guard n > 0 else {
            let s = NSAttributedString(string: state.isNamed ? "“\(state.title!)”, empty" : "Empty",
                                       attributes: [.font: NSFont.systemFont(ofSize: 13), .foregroundColor: Theme.secondaryText])
            let size = s.size()
            s.draw(at: NSPoint(x: bounds.midX - size.width / 2, y: bounds.midY - size.height / 2))
            return
        }
        let gap: CGFloat = 10
        let usable = bounds.width - gap * CGFloat(n + 1)
        var x = gap
        let fractions = state.fractions.count == n ? state.fractions : Array(repeating: 1 / Double(n), count: n)
        for (c, column) in state.columns.enumerated() {
            let w = usable * CGFloat(fractions[c])
            let rect = NSRect(x: x, y: gap, width: w, height: bounds.height - 2 * gap)
            drawColumn(column, in: rect)
            x += w + gap
        }
    }

    private func drawColumn(_ column: [Placement], in rect: NSRect) {
        let font = NSFont.systemFont(ofSize: 11.5, weight: .medium)
        if state.layout == .stacks {
            // Beneath first, each a little higher and narrower, the top whole.
            let beneath = Array(column.dropLast().suffix(3).reversed())
            for (i, p) in beneath.enumerated().reversed() {
                let inset = CGFloat(6 * (i + 1))
                let y = rect.maxY - CGFloat(22 * (i + 1))
                let r = NSRect(x: rect.minX + inset, y: y - 18, width: rect.width - 2 * inset, height: 18 + 22)
                let path = NSBezierPath(roundedRect: r, xRadius: 5, yRadius: 5)
                Theme.sheet(level: i).setFill()
                path.fill()
                Theme.sheetEdge(hovered: false).setStroke()
                path.stroke()
                let s = NSAttributedString(string: titleOf(p.block), attributes: [.font: font, .foregroundColor: Theme.secondaryText])
                s.draw(in: NSRect(x: r.minX + 8, y: r.maxY - 18, width: r.width - 16, height: 16))
            }
            guard let top = column.last else { return }
            let topY = rect.maxY - CGFloat(22 * beneath.count)
            let r = NSRect(x: rect.minX, y: rect.minY, width: rect.width, height: topY - rect.minY)
            let path = NSBezierPath(roundedRect: r, xRadius: 5, yRadius: 5)
            Theme.windowBackground.setFill()
            path.fill()
            Theme.sheetEdge(hovered: true).setStroke()
            path.stroke()
            drawTitle(top, in: r, font: font)
        } else {
            let h = (rect.height - CGFloat(column.count - 1) * 4) / CGFloat(max(column.count, 1))
            var y = rect.maxY
            for p in column {
                let r = NSRect(x: rect.minX, y: y - h, width: rect.width, height: h)
                let path = NSBezierPath(roundedRect: r, xRadius: 5, yRadius: 5)
                Theme.windowBackground.setFill()
                path.fill()
                Theme.sheetEdge(hovered: false).setStroke()
                path.stroke()
                drawTitle(p, in: r, font: font)
                y -= h + 4
            }
        }
    }

    private func drawTitle(_ p: Placement, in r: NSRect, font: NSFont) {
        let focused = p.id == state.focused
        if let icon = Theme.symbol(symbolOf(p.lens), size: 11) {
            let tinted = icon.copy() as! NSImage
            tinted.isTemplate = true
            tinted.draw(in: NSRect(x: r.minX + 8, y: r.maxY - 20, width: 14, height: 13))
        }
        let s = NSAttributedString(string: titleOf(p.block), attributes: [
            .font: focused ? NSFont.systemFont(ofSize: 11.5, weight: .semibold) : font, .foregroundColor: Theme.text])
        s.draw(in: NSRect(x: r.minX + 26, y: r.maxY - 22, width: r.width - 34, height: 16))
    }
}
