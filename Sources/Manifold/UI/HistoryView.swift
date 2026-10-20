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
    /// Logs of the blocks an arrangement placed, as they arrive, with the
    /// state each (compacted) log begins from.
    private var blockEntries: [BlockID: [Entry]] = [:]
    private var blockBases: [BlockID: Block] = [:]
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
        scroll.scrollerStyle = .legacy
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        scroll.automaticallyAdjustsContentInsets = false
        scroll.wantsLayer = true
        scroll.layer?.cornerRadius = 8
        scroll.isHidden = true
        for v in [slider, when, diagram, scroll, everything, compare, restore, close] { panel.addSubview(v) }
    }

    required init?(coder: NSCoder) { fatalError() }

    func show(entries: [Entry], base: ArrangementState? = nil) {
        self.entries = entries
        isText = false
        var s = base ?? ArrangementState()
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
    func showText(entries: [Entry], block: BlockID, base: Block? = nil) {
        self.entries = entries
        blockID = block
        isText = true
        diagram.isHidden = true
        everything.isHidden = true
        scroll.isHidden = false
        compare.isHidden = false
        textView.font = font
        var b: Block? = base
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
    func blockHistory(_ block: BlockID, _ entries: [Entry], base: Block? = nil) {
        blockEntries[block] = entries
        blockBases[block] = base
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
                    guard let log = blockEntries[p.block], !log.isEmpty || blockBases[p.block] != nil else { continue }
                    let then = Block.replaying(log, id: p.block, upTo: moment, base: blockBases[p.block])?.text?.text.string ?? ""
                    let now = Block.replaying(log, id: p.block, base: blockBases[p.block])?.text?.text.string ?? ""
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
        guard let log = blockEntries[block], !log.isEmpty || blockBases[block] != nil else { return nil }
        return Block.replaying(log, id: block, upTo: moment, base: blockBases[block])?.text?.text.string
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
        // The workspace as the window shows it: cards on a wash.
        let dark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        let stops = dark
            ? [NSColor(calibratedHue: 0.70, saturation: 0.35, brightness: 0.22, alpha: 1), NSColor(calibratedHue: 0.06, saturation: 0.3, brightness: 0.2, alpha: 1)]
            : [NSColor(calibratedHue: 0.72, saturation: 0.18, brightness: 0.98, alpha: 1), NSColor(calibratedHue: 0.07, saturation: 0.18, brightness: 1, alpha: 1)]
        NSGraphicsContext.current?.saveGraphicsState()
        NSBezierPath(roundedRect: bounds, xRadius: 8, yRadius: 8).addClip()
        NSGradient(starting: stops[0], ending: stops[1])?.draw(in: bounds, angle: -35)
        NSGraphicsContext.current?.restoreGraphicsState()
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
        for c in state.columns.indices {
            let w = usable * CGFloat(fractions[c])
            let rect = NSRect(x: x, y: gap, width: w, height: bounds.height - 2 * gap)
            drawColumn(c, in: rect)
            x += w + gap
        }
    }

    private func drawColumn(_ c: Int, in rect: NSRect) {
        let font = NSFont.systemFont(ofSize: 11.5, weight: .medium)
        let column = state.columns[c]
        guard !column.isEmpty else { return }
        let gap: CGFloat = 4
        let usable = rect.height - CGFloat(column.count - 1) * gap
        var y = rect.maxY
        for p in column {
            let h = max(20, usable * CGFloat(state.height(of: p.id)))
            let r = NSRect(x: rect.minX, y: y - h, width: rect.width, height: h)
            // A card as the grid draws one: rounded, borderless, the
            // focused one ringed in the accent.
            let path = NSBezierPath(roundedRect: r, xRadius: 6, yRadius: 6)
            Theme.panel.setFill()
            path.fill()
            if p.id == state.focused {
                Theme.accent.withAlphaComponent(0.45).setStroke()
                path.lineWidth = 1.5
                path.stroke()
            }
            drawTitle(p, in: r, font: font)
            y -= h + gap
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
