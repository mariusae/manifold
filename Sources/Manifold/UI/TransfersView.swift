import AppKit

/// Copies on their way (§8), at the foot of the sidebar: a row each — its
/// name, where it goes, how far it has got, a bar filling as it goes; ×
/// stops it (or, once it's ended, takes it away); a finished download's
/// row, clicked, shows it in the Finder. Four at most; more, counted.
final class TransfersView: NSView {
    static let rowHeight: CGFloat = 40
    static let maxRows = 4
    private var rows: [TransferRowView] = []
    private let more = NSTextField(labelWithString: "")

    override var isFlipped: Bool { true }

    override init(frame: NSRect) {
        super.init(frame: frame)
        more.font = .systemFont(ofSize: 11)
        more.textColor = Theme.secondaryText
        addSubview(more)
    }

    required init?(coder: NSCoder) { fatalError() }

    var items: [Transfers.Item] = [] {
        didSet {
            let shown = Array(items.suffix(Self.maxRows))
            // Rows kept for the copies still shown, so a hovered one stays put.
            var next: [TransferRowView] = []
            for item in shown {
                let row = rows.first { $0.item === item } ?? {
                    let r = TransferRowView(item: item)
                    addSubview(r)
                    return r
                }()
                row.refresh()
                next.append(row)
            }
            for r in rows where !next.contains(where: { $0 === r }) { r.removeFromSuperview() }
            rows = next
            let hidden = items.count - shown.count
            more.stringValue = hidden > 0 ? "and \(hidden) more" : ""
            more.isHidden = hidden == 0
            needsLayout = true
            needsDisplay = true
            updateAnimation()
        }
    }
    private var animation: Timer?

    /// A bar whose total isn't known yet moves on its own — while it can
    /// be seen (the sidebar put away, it ran on at 30 a second).
    private func updateAnimation() {
        let moving = items.contains { $0.isRunning && $0.fraction == nil } && window != nil && !isHiddenOrHasHiddenAncestor
        if moving, animation == nil {
            animation = Timer.scheduledTimer(withTimeInterval: 1.0 / 30, repeats: true) { [weak self] _ in
                guard let self else { return }
                guard self.window != nil, !self.isHiddenOrHasHiddenAncestor else { return self.updateAnimation() }
                self.rows.forEach { $0.needsDisplay = true }
            }
        } else if !moving {
            animation?.invalidate()
            animation = nil
        }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        updateAnimation()
    }

    override func viewDidUnhide() {
        super.viewDidUnhide()
        updateAnimation()
    }

    var wantedHeight: CGFloat {
        guard !rows.isEmpty else { return 0 }
        return CGFloat(rows.count) * Self.rowHeight + (more.isHidden ? 0 : 18) + 6
    }

    /// A hairline along the top: the rows apart from the tree above.
    override func draw(_ dirtyRect: NSRect) {
        guard !rows.isEmpty else { return }
        Theme.divider.setFill()
        NSRect(x: 12, y: 0, width: bounds.width - 24, height: 1).fill()
    }

    override func layout() {
        super.layout()
        var y: CGFloat = 2
        for r in rows {
            r.frame = NSRect(x: 0, y: y, width: bounds.width, height: Self.rowHeight)
            y += Self.rowHeight
        }
        more.frame = NSRect(x: 32, y: y, width: bounds.width - 40, height: 16)
    }
}

final class TransferRowView: NSView {
    let item: Transfers.Item
    private let icon = NSImageView()
    private let title = NSTextField(labelWithString: "")
    private let detail = NSTextField(labelWithString: "")
    private let close: IconButton
    private var hovering = false { didSet { refresh() } }

    override var isFlipped: Bool { true }

    init(item: Transfers.Item) {
        self.item = item
        close = IconButton(symbol: "xmark", size: 9, target: nil, action: nil)
        super.init(frame: .zero)
        close.target = self
        close.action = #selector(closeClicked)
        icon.image = Theme.symbol(item.symbol, size: 11, weight: .semibold)
        title.font = .systemFont(ofSize: 12, weight: .medium)
        title.textColor = Theme.text
        title.lineBreakMode = .byTruncatingMiddle
        detail.font = .monospacedDigitSystemFont(ofSize: 10.5, weight: .regular)
        detail.textColor = Theme.secondaryText
        detail.lineBreakMode = .byTruncatingTail
        for v in [icon, title, detail, close] { addSubview(v) }
        refresh()
    }

    required init?(coder: NSCoder) { fatalError() }

    func refresh() {
        title.stringValue = item.title
        let progress = item.progressText
        detail.stringValue = item.isRunning ? progress + " · " + item.detail : progress
        if case .failed = item.state { detail.textColor = Theme.statusError } else { detail.textColor = Theme.secondaryText }
        icon.contentTintColor = {
            switch item.state {
            case .failed: return Theme.statusError
            case .finished: return Theme.accent
            default: return Theme.secondaryText
            }
        }()
        if case .finished = item.state { icon.image = Theme.symbol("checkmark.circle.fill", size: 11) }
        // Always there: a copy is stopped with one click, hovered or not.
        close.toolTip = item.isRunning ? "Stop Copying" : "Dismiss"
        toolTip = item.isRunning ? "\(item.title) — \(item.detail)" : item.action.map { "Click: \($0.title)" }
        needsDisplay = true
        needsLayout = true
    }

    override func layout() {
        super.layout()
        let w = bounds.width
        icon.frame = NSRect(x: 12, y: 6, width: 14, height: 14)
        close.frame = NSRect(x: w - 26, y: 4, width: 18, height: 18)
        title.frame = NSRect(x: 32, y: 4, width: w - 32 - 30, height: 16)
        detail.frame = NSRect(x: 32, y: 20, width: w - 32 - 12, height: 14)
    }

    override func draw(_ dirtyRect: NSRect) {
        if hovering {
            Theme.hover.setFill()
            Flat.rowBand(bounds).fill()
        }
        // The bar: under the words, filling as it goes; moving while how
        // much is to come isn't known yet.
        guard item.isRunning else { return }
        let track = NSRect(x: 32, y: bounds.height - 4, width: bounds.width - 32 - 12, height: 2)
        Theme.divider.setFill()
        NSBezierPath(roundedRect: track, xRadius: 1, yRadius: 1).fill()
        Theme.accent.setFill()
        if let f = item.fraction {
            var bar = track
            bar.size.width = max(2, track.width * f)
            NSBezierPath(roundedRect: bar, xRadius: 1, yRadius: 1).fill()
        } else {
            let t = Date().timeIntervalSince(item.started).truncatingRemainder(dividingBy: 1.4) / 1.4
            let bar = NSRect(x: track.minX + (track.width * 0.75) * t, y: track.minY, width: track.width * 0.25, height: 2)
            NSBezierPath(roundedRect: bar, xRadius: 1, yRadius: 1).fill()
        }
    }

    @objc private func closeClicked() { Transfers.shared.cancelOrDismiss(item) }

    override func updateTrackingAreas() {
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
        super.updateTrackingAreas()
    }

    override func mouseEntered(with event: NSEvent) { hovering = true }
    override func mouseExited(with event: NSEvent) { hovering = false }
    override func mouseDown(with event: NSEvent) {}
    override func mouseUp(with event: NSEvent) {
        guard bounds.contains(convert(event.locationInWindow, from: nil)), !item.isRunning, let action = item.action else { return }
        action.run()
        Transfers.shared.dismiss(item)
    }
}

/// The copies, small, at the window's lower left while the sidebar is
/// away: a ring filling as they go (red if one failed) and how many;
/// clicked, the sidebar comes out to show them.
final class TransfersBadge: NSView {
    var onClick: (() -> Void)?
    private let label = NSTextField(labelWithString: "")
    private var fraction: Double?
    private var failed = false

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.cornerRadius = Radius.surface
        layer?.cornerCurve = .continuous
        layer?.borderWidth = 0.5
        themed {
            $0.layer?.backgroundColor = Theme.panel.cgColor
            $0.layer?.borderColor = Theme.panelBorder.cgColor
        }
        label.font = .systemFont(ofSize: 11, weight: .medium)
        label.textColor = Theme.text
        addSubview(label)
    }

    required init?(coder: NSCoder) { fatalError() }

    func show(_ items: [Transfers.Item]) {
        let running = items.filter(\.isRunning)
        failed = items.contains { if case .failed = $0.state { return true } else { return false } }
        let totals = running.compactMap(\.total).reduce(0, +)
        fraction = totals > 0 ? min(1, Double(running.map(\.done).reduce(0, +)) / Double(totals)) : nil
        label.stringValue = failed && running.isEmpty ? "A copy failed"
            : running.count == 1 ? "Copying \(running[0].title)"
            : running.isEmpty ? "Copied" : "Copying \(running.count) things"
        toolTip = "Show them in the sidebar"
        needsDisplay = true
        needsLayout = true
    }

    var wantedSize: NSSize {
        NSSize(width: min(260, ceil(label.intrinsicContentSize.width) + 40), height: 24)
    }

    override func layout() {
        super.layout()
        label.frame = NSRect(x: 28, y: (bounds.height - 15) / 2, width: bounds.width - 36, height: 15)
    }

    override func draw(_ dirtyRect: NSRect) {
        let c = NSPoint(x: 15, y: bounds.midY), r: CGFloat = 6
        let track = NSBezierPath()
        track.appendArc(withCenter: c, radius: r, startAngle: 0, endAngle: 360)
        track.lineWidth = 2
        Theme.divider.setStroke()
        track.stroke()
        let ring = NSBezierPath()
        let f = failed ? 1 : fraction ?? 0.25
        ring.appendArc(withCenter: c, radius: r, startAngle: 90, endAngle: 90 - 360 * CGFloat(f), clockwise: true)
        ring.lineWidth = 2
        (failed ? Theme.statusError : Theme.accent).setStroke()
        ring.stroke()
    }

    override func mouseDown(with event: NSEvent) {}
    override func mouseUp(with event: NSEvent) { onClick?() }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .pointingHand) }
}
