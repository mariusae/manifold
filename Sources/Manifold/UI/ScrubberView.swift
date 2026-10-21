import AppKit
import ManifoldCore

/// One mark on a scrubber: where it is in the content, and what it is.
struct ScrubMark: Equatable {
    /// A key the owner knows the mark by.
    var id: Int
    /// Its place in the content, in the scrubber's units (a terminal's rows).
    var at: Double
    var title: String
    var detail: String?
    /// Drawn in the failure color.
    var failed = false
    /// Drawn in the accent, pulsing: still going.
    var running = false
}

/// A scroll bar that is also an outline, as Prism's is (§3.1): a strip down
/// a view's edge with the content's extent as its length, the part shown as
/// a knob, and ticks where the marks are — a terminal's commands. The
/// pointer over a tick names it in a tip beside the strip; a click goes
/// there; a click on the tip, a double-click, or ⌘-click opens it. The
/// knob drags as a scroll bar's does, and a click on the track jumps.
final class ScrubberView: NSView {
    static let width: CGFloat = 14

    /// The pointer rests on a mark (or none), at a y in the strip.
    var onHover: ((ScrubMark?, CGFloat) -> Void)?
    /// A mark was clicked: go there.
    var onPick: ((ScrubMark) -> Void)?
    /// A mark was opened: as its own block.
    var onOpen: ((ScrubMark) -> Void)?
    /// Scrolled to a fraction of the content, dragging or clicking the track.
    var onScroll: ((Double) -> Void)?
    /// A menu for a mark, on a right-click.
    var markMenu: ((ScrubMark) -> NSMenu?)?

    private var marks: [ScrubMark] = []
    private var placed: [(mark: ScrubMark, y: CGFloat)] = []
    /// The content's extent, and the part shown.
    private var total: Double = 1
    private var offset: Double = 0
    private var shown: Double = 1
    private(set) var hovered: Int?
    private var dragging: (grab: CGFloat, start: Double)?
    private var dragged = false
    private var pulse: Timer?
    /// Shown as macOS shows its overlay scroll bars: while the content
    /// scrolls or grows, while the pointer is on it, and a moment after;
    /// faded away otherwise. Always, when the system's scroll bars are
    /// the kind that stay.
    private var fade: Timer?
    private var pointerIn = false

    private func reveal() {
        fade?.invalidate()
        fade = nil
        if alphaValue != 1 {
            layer?.removeAllAnimations()
            alphaValue = 1
        }
        guard NSScroller.preferredScrollerStyle == .overlay, !pointerIn, dragging == nil else { return }
        fade = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.fade = nil
                NSAnimationContext.runAnimationGroup { ctx in
                    ctx.duration = 0.3
                    self.animator().alphaValue = 0
                }
            }
        }
    }

    override var isFlipped: Bool { true }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
    }

    required init?(coder: NSCoder) { fatalError() }

    func update(marks: [ScrubMark], total: Double, offset: Double, shown: Double) {
        let changed = marks != self.marks || total != self.total
        if total != self.total || offset != self.offset || shown != self.shown { reveal() }
        self.marks = marks.sorted { $0.at < $1.at }
        self.total = max(total, 1)
        self.offset = offset
        self.shown = max(shown, 1)
        if changed { place() } else { needsDisplay = true }
        let running = marks.contains(where: \.running)
        if running, pulse == nil {
            pulse = Timer.scheduledTimer(withTimeInterval: 0.6, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.needsDisplay = true }
            }
        } else if !running {
            pulse?.invalidate()
            pulse = nil
        }
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        place()
    }

    override func viewDidMoveToSuperview() {
        super.viewDidMoveToSuperview()
        if superview == nil { pulse?.invalidate(); pulse = nil; fade?.invalidate(); fade = nil } else { reveal() }
    }

    override func mouseEntered(with event: NSEvent) {
        pointerIn = true
        reveal()
    }

    private static let pad: CGFloat = 4

    private func position(_ at: Double) -> CGFloat {
        Self.pad + CGFloat(at / total) * max(1, bounds.height - 2 * Self.pad)
    }

    private func fraction(at y: CGFloat) -> Double {
        Double(min(1, max(0, (y - Self.pad) / max(1, bounds.height - 2 * Self.pad))))
    }

    /// Where each mark goes; of marks too close to tell apart, the later
    /// kept (a failure or a running one over a quiet one).
    private func place() {
        placed = []
        for mark in marks {
            let y = round(position(mark.at))
            if let last = placed.last, y - last.y < 4 {
                if mark.failed || mark.running || !(last.mark.failed || last.mark.running) { placed[placed.count - 1] = (mark, last.y) }
                continue
            }
            placed.append((mark, y))
        }
        if let h = hovered, h >= placed.count { hovered = nil }
        needsDisplay = true
    }

    private var knobRect: NSRect {
        let top = position(offset), bottom = position(offset + shown)
        return NSRect(x: 3, y: top, width: bounds.width - 6, height: max(bottom - top, 12))
    }

    override func draw(_ dirtyRect: NSRect) {
        // The track, a shade off the terminal's ground; the knob over it.
        Theme.scrubberTrack.setFill()
        NSBezierPath(roundedRect: bounds, xRadius: 0, yRadius: 0).fill()
        let knob = knobRect
        (dragging != nil ? Theme.handle : Theme.scrubberKnob).setFill()
        NSBezierPath(roundedRect: knob, xRadius: 4, yRadius: 4).fill()
        let dim = Date().timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 1.2) < 0.6
        for (i, item) in placed.enumerated() {
            let hot = i == hovered
            let color: NSColor = hot ? Theme.accent
                : item.mark.failed ? Theme.statusError
                : item.mark.running ? Theme.accent.withAlphaComponent(dim ? 0.45 : 1)
                : Theme.scrubberTick
            color.setFill()
            let length: CGFloat = hot ? bounds.width - 2 : item.mark.failed || item.mark.running ? 8 : 6
            let thickness: CGFloat = hot ? 2.5 : 1.5
            NSBezierPath(roundedRect: NSRect(x: (bounds.width - length) / 2, y: item.y - thickness / 2, width: length, height: thickness),
                         xRadius: thickness / 2, yRadius: thickness / 2).fill()
        }
    }

    // MARK: The pointer

    private func nearest(_ y: CGFloat) -> Int? {
        let best = placed.enumerated().min { abs($0.element.y - y) < abs($1.element.y - y) }
        guard let best, abs(best.element.y - y) <= 6 else { return nil }
        return best.offset
    }

    override func updateTrackingAreas() {
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
        super.updateTrackingAreas()
    }

    override func resetCursorRects() { addCursorRect(bounds, cursor: .arrow) }

    override func mouseMoved(with event: NSEvent) {
        guard dragging == nil else { return }
        let y = convert(event.locationInWindow, from: nil).y
        let index = nearest(y)
        if index != hovered {
            hovered = index
            needsDisplay = true
        }
        onHover?(index.map { placed[$0].mark }, index.map { placed[$0].y } ?? y)
    }

    override func mouseExited(with event: NSEvent) {
        pointerIn = false
        reveal()
        guard dragging == nil else { return }
        hovered = nil
        needsDisplay = true
        onHover?(nil, 0)
    }

    override func mouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        dragged = false
        if event.clickCount == 2 || event.modifierFlags.contains(.command), let i = nearest(p.y) {
            onOpen?(placed[i].mark)
            return
        }
        if knobRect.insetBy(dx: 0, dy: -2).contains(p) && nearest(p.y) == nil {
            dragging = (p.y, offset)
            needsDisplay = true
            return
        }
    }

    override func mouseDragged(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        if dragging == nil, !dragged {
            // A drag that began on a tick scrubs too.
            dragging = (p.y, offset)
        }
        guard let d = dragging else { return }
        dragged = true
        let rows = Double(p.y - d.grab) / Double(max(1, bounds.height - 2 * Self.pad)) * total
        let target = min(max(d.start + rows, 0), max(total - shown, 0))
        onScroll?(target / max(total - shown, 1))
    }

    override func mouseUp(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        let wasDragging = dragging != nil
        dragging = nil
        needsDisplay = true
        reveal()
        if dragged || wasDragging { return }
        if let i = nearest(p.y) {
            onPick?(placed[i].mark)
        } else {
            // On the track: the page there, as a scroll bar jumps.
            onScroll?(fraction(at: p.y))
        }
    }

    override func rightMouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        guard let i = nearest(p.y), let menu = markMenu?(placed[i].mark) else { return }
        hovered = i
        needsDisplay = true
        NSMenu.popUpContextMenu(menu, with: event, for: self)
    }

    /// Debugging: the marks as placed, one per line.
    var debugMarks: String {
        placed.map { "\($0.mark.id) @\(Int($0.mark.at)) y\(Int($0.y))\($0.mark.failed ? " failed" : "")\($0.mark.running ? " running" : "") \($0.mark.title)" }.joined(separator: "\n")
    }

    /// Debugging: as a click on the nth mark.
    func debugPick(_ n: Int) -> String {
        guard n >= 0, n < placed.count else { return "no mark \(n) of \(placed.count)" }
        onPick?(placed[n].mark)
        return "picked \(placed[n].mark.title)"
    }

    /// Debugging: as the pointer resting at a fraction of the strip.
    func debugHover(fraction: Double) -> ScrubMark? {
        let y = Self.pad + CGFloat(fraction) * (bounds.height - 2 * Self.pad)
        hovered = nearest(y)
        needsDisplay = true
        onHover?(hovered.map { placed[$0].mark }, hovered.map { placed[$0].y } ?? y)
        return hovered.map { placed[$0].mark }
    }
}

/// What a hovered tick is: its words, beside the strip. Clicking it opens
/// the mark; the tip stays while the pointer is on it.
final class ScrubTip: NSView {
    private let label = NSTextField(labelWithString: "")
    private let detail = NSTextField(labelWithString: "")
    /// Copies the command and its output.
    private let copyButton = IconButton(symbol: "doc.on.doc", size: 11, weight: .regular, target: nil, action: nil)
    var onCopy: (() -> Void)?
    /// Whether there's something to copy (a command's transcript).
    var showsCopy = true { didSet { copyButton.isHidden = !showsCopy; needsLayout = true } }
    var onClick: (() -> Void)?
    var onEnter: (() -> Void)?
    var onExit: (() -> Void)?

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.cornerRadius = 7
        layer?.cornerCurve = .continuous
        layer?.borderWidth = 0.5
        layer?.zPosition = 7
        shadow = {
            let shadow = NSShadow()
            shadow.shadowColor = NSColor.black.withAlphaComponent(0.14)
            shadow.shadowBlurRadius = 10
            shadow.shadowOffset = NSSize(width: 0, height: -2)
            return shadow
        }()
        label.lineBreakMode = .byTruncatingTail
        label.maximumNumberOfLines = 1
        label.font = FontTheme.code(12)
        detail.font = .systemFont(ofSize: 11)
        detail.textColor = Theme.secondaryText
        detail.lineBreakMode = .byTruncatingTail
        detail.maximumNumberOfLines = 1
        copyButton.target = self
        copyButton.action = #selector(copyClicked)
        copyButton.toolTip = "Copy the command and its output"
        addSubview(label)
        addSubview(detail)
        addSubview(copyButton)
    }

    @objc private func copyClicked() { onCopy?() }

    required init?(coder: NSCoder) { fatalError() }

    func show(_ mark: ScrubMark) {
        label.stringValue = mark.title
        label.textColor = mark.failed ? Theme.statusError : Theme.text
        detail.stringValue = mark.detail ?? ""
        detail.isHidden = mark.detail == nil
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.backgroundColor = Theme.panel.cgColor
            layer?.borderColor = Theme.panelBorder.cgColor
        }
        needsLayout = true
    }

    override var fittingSize: NSSize {
        let w = max(label.intrinsicContentSize.width, detail.isHidden ? 0 : detail.intrinsicContentSize.width)
        let h = label.intrinsicContentSize.height + (detail.isHidden ? 0 : detail.intrinsicContentSize.height + 1)
        return NSSize(width: min(480, ceil(w) + 28 + (showsCopy ? 26 : 0)), height: ceil(h) + 10)
    }

    override func layout() {
        super.layout()
        let lh = label.intrinsicContentSize.height, dh = detail.isHidden ? 0 : detail.intrinsicContentSize.height + 1
        let top = (bounds.height - lh - dh) / 2
        let room: CGFloat = showsCopy ? 26 : 0
        label.frame = NSRect(x: 11, y: bounds.height - top - lh, width: bounds.width - 22 - room, height: lh)
        detail.frame = NSRect(x: 11, y: bounds.height - top - lh - dh, width: bounds.width - 22 - room, height: max(dh - 1, 0))
        copyButton.frame = NSRect(x: bounds.width - 30, y: (bounds.height - 20) / 2, width: 20, height: 20)
    }

    override func updateTrackingAreas() {
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
        super.updateTrackingAreas()
    }

    override func resetCursorRects() { addCursorRect(bounds, cursor: .pointingHand) }
    override func mouseEntered(with event: NSEvent) { onEnter?() }
    override func mouseExited(with event: NSEvent) { onExit?() }
    override func mouseDown(with event: NSEvent) {}
    override func mouseUp(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        if bounds.contains(p), copyButton.isHidden || !copyButton.frame.contains(p) { onClick?() }
    }
}


/// The headings of a Markdown text, by line: what an outline of it is
/// made of (⌘\, the scrubber).
enum MarkdownOutline {
    struct Heading { var line: Int; var level: Int; var text: String }

    static func headings(in text: String) -> [Heading] {
        var out: [Heading] = []
        var inFence = false
        var line = 0
        for raw in text.split(separator: "\n", omittingEmptySubsequences: false) {
            defer { line += 1 }
            if raw.hasPrefix("```") { inFence.toggle() }
            guard !inFence, raw.hasPrefix("#") else { continue }
            let level = raw.prefix { $0 == "#" }.count
            guard level <= 6, raw.dropFirst(level).first == " " else { continue }
            out.append(Heading(line: line, level: level, text: raw.dropFirst(level).trimmingCharacters(in: .whitespaces)))
        }
        return out
    }
}
