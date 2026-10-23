import AppKit
import ManifoldCore

/// A text block's history, over the window: a slider through its log,
/// and the text as it was then, read-only, with a diff against now a
/// button away. Restore appends what makes it so again.
final class HistoryView: NSView {
    var onClose: (() -> Void)?
    /// Restore a text block to the text it had.
    var onRestoreText: ((String) -> Void)?
    /// Compare the text then with now.
    var onCompare: ((Stamp) -> Void)?
    /// The text then, as a block of its own.
    var onOpen: ((String, Stamp) -> Void)?
    var titleOf: (BlockID) -> String = { $0.description }
    var symbolOf: (Lens) -> String = { _ in "doc" }
    var font: NSFont = .monospacedSystemFont(ofSize: 12, weight: .regular)

    private let panel = NSView()
    private let slider: NSSlider = {
        let s = NSSlider()
        s.cell = FlatSliderCell()
        return s
    }()
    private let when = NSTextField(labelWithString: "")
    private let scroll = ClippingScrollView()
    private let textView = TextView()
    private let textDocument = StaticDocument()
    private let compare = FlatButton("Compare with Now")
    private let open = FlatButton("Open This Version")
    private let restore = FlatButton("Restore This Text")
    private let close = FlatButton("Done")
    private var entries: [Entry] = []
    private var texts: [String] = []
    private var blockID: BlockID?

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        themed { $0.layer?.backgroundColor = Theme.scrim.cgColor }
        Flat.float(panel)
        addSubview(panel)
        slider.target = self
        slider.action = #selector(scrubbed)
        slider.isContinuous = true
        when.font = .systemFont(ofSize: 12)
        when.textColor = Theme.secondaryText
        when.alignment = .center
        restore.target = self
        restore.action = #selector(restoreClicked)
        close.target = self
        close.action = #selector(closeClicked)
        close.keyEquivalent = "\u{1b}"
        compare.target = self
        compare.action = #selector(compareClicked)
        open.target = self
        open.action = #selector(openClicked)
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
        for v in [slider, when, scroll, open, compare, restore, close] { panel.addSubview(v) }
    }

    required init?(coder: NSCoder) { fatalError() }

    /// A text block's history: the text as it was, read-only.
    func showText(entries: [Entry], block: BlockID, base: Block? = nil) {
        self.entries = entries
        blockID = block
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

    private var index: Int { min(max(slider.integerValue, 0), texts.count - 1) }

    @objc private func scrubbed() {
        let i = index
        guard i >= 0, i < entries.count else { return }
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .short
        let note = "\(f.string(from: entries[i].at.date)) · change \(i + 1) of \(entries.count)"
        textDocument.rope = Rope(texts[i])
        textDocument.version += 1
        textView.documentChanged()
        restore.isEnabled = i < texts.count - 1
        compare.isEnabled = i < texts.count - 1
        open.isEnabled = i < texts.count - 1
        when.stringValue = note
    }

    @objc private func restoreClicked() {
        let i = index
        guard i >= 0, i < texts.count else { return }
        onRestoreText?(texts[i])
    }

    @objc private func compareClicked() {
        let i = index
        guard i >= 0, i < entries.count else { return }
        onCompare?(entries[i].at)
    }

    @objc private func openClicked() {
        let i = index
        guard i >= 0, i < entries.count, i < texts.count else { return }
        onOpen?(texts[i], entries[i].at)
    }

    @objc private func closeClicked() { onClose?() }

    override func layout() {
        super.layout()
        let w = min(760, bounds.width - 60), h = min(520, bounds.height - 60)
        panel.frame = NSRect(x: (bounds.width - w) / 2, y: (bounds.height - h) / 2, width: w, height: h).integral
        slider.frame = NSRect(x: 20, y: h - 44, width: w - 40, height: 24)
        when.frame = NSRect(x: 20, y: h - 66, width: w - 40, height: 16)
        scroll.frame = NSRect(x: 20, y: 56, width: w - 40, height: h - 132)
        textView.frame.size.width = scroll.contentSize.width
        // The buttons along the foot, from the right, each its own width.
        var right = w - 20
        for b in [close, restore, compare, open] {
            let bw = max(64, b.intrinsicContentSize.width)
            b.frame = NSRect(x: right - bw, y: 18, width: bw, height: Flat.buttonHeight)
            right -= bw + 8
        }
        open.isHidden = open.frame.minX < 20
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
