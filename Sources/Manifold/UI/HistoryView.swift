import AppKit
import ManifoldCore

/// An arrangement's history, over the window: a slider through its log,
/// and the arrangement as it was then, drawn as a diagram of its columns
/// (the layout then; the blocks are as they are now). Restore appends what
/// makes it so again.
final class HistoryView: NSView {
    var onClose: (() -> Void)?
    var onRestore: ((ArrangementState) -> Void)?
    var titleOf: (BlockID) -> String = { $0.description }
    var symbolOf: (Lens) -> String = { _ in "doc" }

    private let panel = NSView()
    private let slider = NSSlider()
    private let when = NSTextField(labelWithString: "")
    private let diagram = ArrangementDiagram()
    private let restore = NSButton(title: "Restore", target: nil, action: nil)
    private let close = NSButton(title: "Done", target: nil, action: nil)
    private var entries: [Entry] = []
    private var states: [ArrangementState] = []

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
        for v in [slider, when, diagram, restore, close] { panel.addSubview(v) }
    }

    required init?(coder: NSCoder) { fatalError() }

    func show(entries: [Entry]) {
        self.entries = entries
        var s = ArrangementState()
        states = entries.map { e in
            if case let .create(_, title, _) = e.event { s = ArrangementState(); s.title = title } else { s.apply(e.event) }
            return s
        }
        slider.minValue = 0
        slider.maxValue = Double(max(states.count - 1, 0))
        slider.integerValue = states.count - 1
        scrubbed()
    }

    @objc private func scrubbed() {
        let i = min(max(slider.integerValue, 0), states.count - 1)
        guard i >= 0 else { return }
        diagram.state = states[i]
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .short
        when.stringValue = "\(f.string(from: entries[i].at.date)) · change \(i + 1) of \(entries.count)"
        restore.isEnabled = i < states.count - 1
    }

    @objc private func restoreClicked() {
        let i = min(max(slider.integerValue, 0), states.count - 1)
        guard i >= 0 else { return }
        onRestore?(states[i])
    }

    @objc private func closeClicked() { onClose?() }

    override func layout() {
        super.layout()
        let w = min(760, bounds.width - 60), h = min(520, bounds.height - 60)
        panel.frame = NSRect(x: (bounds.width - w) / 2, y: (bounds.height - h) / 2, width: w, height: h).integral
        slider.frame = NSRect(x: 20, y: h - 44, width: w - 40, height: 24)
        when.frame = NSRect(x: 20, y: h - 66, width: w - 40, height: 16)
        diagram.frame = NSRect(x: 20, y: 56, width: w - 40, height: h - 132)
        close.frame = NSRect(x: w - 100, y: 16, width: 80, height: 28)
        restore.frame = NSRect(x: w - 196, y: 16, width: 88, height: 28)
    }

    override func mouseDown(with event: NSEvent) {
        if !panel.frame.contains(convert(event.locationInWindow, from: nil)) { onClose?() }
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { onClose?() } else { super.keyDown(with: event) }
    }

    override var acceptsFirstResponder: Bool { true }
}

/// An arrangement drawn small: its columns, each a stack of sheets with
/// titles, the top one whole.
final class ArrangementDiagram: NSView {
    var state = ArrangementState() { didSet { needsDisplay = true } }
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
