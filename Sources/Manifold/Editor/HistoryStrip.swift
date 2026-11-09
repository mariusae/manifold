import AppKit
import ManifoldCore

/// A file's history along the foot of its editor, when asked for (⌥⌘Y):
/// the commits that changed it as ticks, the oldest at the left and the
/// file as it is now at the right end; a knob on the one shown, dragged or
/// clicked to another (a tick under the pointer says what it is). Older
/// and newer a step at a time, Now, and Close.
final class HistoryStrip: NSView {
    /// Newest first, as the log has them.
    var revisions: [FileRevision] = [] { didSet { needsDisplay = true; say() } }
    /// More, older, still to be asked for.
    var more = false
    /// The commit shown (an index into `revisions`), nil for now.
    var position: Int? { didSet { needsDisplay = true; say() } }
    /// Waiting on the host for the one chosen.
    var loading = false { didSet { if loading != oldValue { say() } } }
    var onChoose: ((Int?) -> Void)?
    var onClose: (() -> Void)?
    /// The oldest reached, and more there: asked for.
    var onMore: (() -> Void)?

    static let height: CGFloat = 30
    private let label = NSTextField(labelWithString: "")
    private let older = IconButton("chevron.left", tip: "Older ([)")
    private let newer = IconButton("chevron.right", tip: "Newer (])")
    private let now = FlatButton("Now", font: UIType.detail)
    private let close = IconButton.close(tip: "Close History (⎋)")
    private var hovered: Int?

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        themed { $0.layer?.backgroundColor = Theme.windowBackground.blended(withFraction: 0.04, of: Theme.text)?.cgColor }
        label.font = UIType.detail
        label.lineBreakMode = .byTruncatingTail
        now.toolTip = "The file as it is now"
        older.target = self; older.action = #selector(olderClicked)
        newer.target = self; newer.action = #selector(newerClicked)
        now.target = self; now.action = #selector(nowClicked)
        close.target = self; close.action = #selector(closeClicked)
        for v in [label, older, newer, now, close] as [NSView] { addSubview(v) }
    }

    required init?(coder: NSCoder) { fatalError() }

    @objc private func olderClicked() { step(older: true) }
    @objc private func newerClicked() { step(older: false) }
    @objc private func nowClicked() { onChoose?(nil) }
    @objc private func closeClicked() { onClose?() }

    /// A commit further back, or nearer now.
    func step(older: Bool) {
        if older {
            let next = (position ?? -1) + 1
            if next < revisions.count { onChoose?(next) } else if more { onMore?() }
        } else if let p = position {
            onChoose?(p == 0 ? nil : p - 1)
        }
    }

    // MARK: Layout

    /// The track: between the label (a third of the strip) and the buttons.
    private var track: NSRect {
        let left = (bounds.width * 0.38).rounded()
        let right = bounds.width - 8 - 18 - 6 - now.frame.width - 6 - 18 - 2 - 18 - 10
        return NSRect(x: left, y: 0, width: max(40, right - left), height: bounds.height)
    }

    override func layout() {
        super.layout()
        now.sizeToFit()
        let h = bounds.height
        var x = bounds.width - 8
        func place(_ v: NSView, _ w: CGFloat, _ height: CGFloat = 18) {
            x -= w
            v.frame = NSRect(x: x, y: ((h - height) / 2).rounded(), width: w, height: height)
        }
        place(close, 18)
        x -= 6
        place(now, now.frame.width, Flat.buttonHeight)
        x -= 6
        place(newer, 18)
        x -= 2
        place(older, 18)
        label.frame = NSRect(x: 10, y: ((h - 16) / 2).rounded(), width: track.minX - 20, height: 16)
    }

    /// Where a commit's tick is: the oldest at the left, now at the right end.
    private func x(ofSlot slot: Int) -> CGFloat {
        let t = track, slots = CGFloat(revisions.count + 1)
        return t.minX + (CGFloat(slot) + 0.5) * t.width / slots
    }
    private func slot(of index: Int?) -> Int { index.map { revisions.count - 1 - $0 } ?? revisions.count }
    private func index(ofSlot slot: Int) -> Int? { slot >= revisions.count ? nil : revisions.count - 1 - slot }

    private func slot(at p: NSPoint) -> Int {
        let t = track, slots = revisions.count + 1
        return max(0, min(slots - 1, Int((p.x - t.minX) / (t.width / CGFloat(slots)))))
    }

    // MARK: Drawing

    override func draw(_ dirtyRect: NSRect) {
        // A hairline at its top, against the text.
        Theme.divider.setFill()
        NSRect(x: 0, y: bounds.height - 1, width: bounds.width, height: 1).fill()
        guard !revisions.isEmpty else { return }
        let t = track, mid = (bounds.height / 2).rounded()
        Theme.text.withAlphaComponent(0.18).setFill()
        NSRect(x: t.minX, y: mid - 0.5, width: t.width, height: 1).fill()
        // A tick for each commit; now's, taller.
        for s in 0...revisions.count {
            let x = x(ofSlot: s).rounded()
            let isNow = s == revisions.count
            (isNow ? Theme.text.withAlphaComponent(0.6) : Theme.text.withAlphaComponent(s == slot(of: hovered) ? 0.7 : 0.35)).setFill()
            let tall: CGFloat = isNow ? 12 : 7
            NSRect(x: x - 0.5, y: mid - tall / 2, width: 1, height: tall).fill()
        }
        // More, older, beyond the left end.
        if more {
            let s = NSAttributedString(string: "…", attributes: [.font: UIType.detail, .foregroundColor: Theme.secondaryText])
            s.draw(at: NSPoint(x: t.minX - s.size().width - 2, y: mid - s.size().height / 2))
        }
        // The knob, on the one shown: the accent's while back in time.
        let kx = x(ofSlot: slot(of: position))
        let knob = NSRect(x: kx - 6, y: mid - 6, width: 12, height: 12)
        (position == nil ? Theme.text.withAlphaComponent(0.75) : Theme.accent).setFill()
        NSBezierPath(ovalIn: knob).fill()
    }

    /// What it says: the commit shown, or hovered — its id, author, age and
    /// summary — or that it's the file as it is.
    private func say() {
        let shown = hovered ?? position
        let accent = position != nil && hovered == nil
        guard let i = shown, revisions.indices.contains(i) else {
            label.stringValue = revisions.isEmpty ? "Reading the file's history…" : "Now — the file as it is (\(revisions.count)\(more ? "+" : "") commit\(revisions.count == 1 ? "" : "s") back)"
            label.textColor = Theme.secondaryText
            return
        }
        let r = revisions[i]
        let age = Age.short(Stamp(wall: Int64(r.at * 1000)))
        label.stringValue = "\(r.short) · \(r.author) · \(age) ago — \(r.summary)" + (loading && accent ? "  (reading…)" : "")
        label.textColor = accent ? Theme.accent : Theme.text
    }

    // MARK: The pointer

    override func updateTrackingAreas() {
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self))
        super.updateTrackingAreas()
    }

    override func mouseMoved(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        let h = track.contains(p) ? index(ofSlot: slot(at: p)) : nil
        if h != hovered { hovered = h; needsDisplay = true; say() }
    }

    override func mouseExited(with event: NSEvent) {
        if hovered != nil { hovered = nil; needsDisplay = true; say() }
    }

    override func mouseDown(with event: NSEvent) { choose(at: event) }
    override func mouseDragged(with event: NSEvent) { choose(at: event) }

    private func choose(at event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        guard track.insetBy(dx: -8, dy: 0).contains(NSPoint(x: p.x, y: bounds.midY)), !revisions.isEmpty else { return }
        let i = index(ofSlot: slot(at: p))
        if i != position { onChoose?(i) }
        if i == revisions.count - 1, more { onMore?() }
    }

    override func resetCursorRects() { addCursorRect(track, cursor: .pointingHand) }
}
