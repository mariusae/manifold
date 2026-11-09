import AppKit

/// Where a comment is written (§3.12), as a chat app's: a rounded box
/// that grows with what's written (up to a point, then it scrolls), what
/// the comment is about as a card at its top — its icon, its name and
/// where it is — a quiet word at its foot (Resolve), and a round send
/// button. ↩ sends, ⇧↩ a new line, as the composer has it.
final class ChatBox: NSView {
    /// What it's about, as a card in it.
    struct Chip: Equatable {
        var symbol: String
        var image: NSImage?
        var title: String
        var detail: String
        /// A reference in what's written (its block's id): a × takes it out.
        var mention: String? = nil

        static func == (a: Chip, b: Chip) -> Bool { a.symbol == b.symbol && a.image === b.image && a.title == b.title && a.detail == b.detail && a.mention == b.mention }
    }

    /// A card for a block referred to in what's written (the window's).
    static var chipFor: ((String) -> Chip?)?

    let composer: ComposerTextView
    private let scroll = NSScrollView()
    let placeholder = NSTextField(labelWithString: "")
    private let send = SendButton()
    private var chipViews: [ChipView] = []
    /// At its foot, at the left (Resolve).
    var leading: [NSView] = [] {
        didSet {
            oldValue.forEach { $0.removeFromSuperview() }
            leading.forEach { addSubview($0) }
            needsLayout = true
        }
    }
    /// What it's about (a new thread's place), first.
    var chips: [Chip] = [] { didSet { if chips != oldValue { rebuildCards() } } }
    /// Then a card for each block referred to in what's written, as Dia's.
    private var mentionChips: [Chip] = []

    /// The references' cards made again from what's written.
    func updateMentions() {
        let made = composer.mentionedBlocks.compactMap { id -> Chip? in
            guard var c = Self.chipFor?(id) else { return nil }
            c.mention = id
            return c
        }
        guard made != mentionChips else { return }
        mentionChips = made
        rebuildCards()
    }

    private func rebuildCards() {
        chipViews.forEach { $0.removeFromSuperview() }
        chipViews = (chips + mentionChips).map { c in
            let v = ChipView(c)
            if let id = c.mention { v.onRemove = { [weak self] in self?.composer.removeMention(id) } }
            return v
        }
        chipViews.forEach { addSubview($0, positioned: .below, relativeTo: scroll) }
        needsLayout = true
        superview?.needsLayout = true
    }
    var onSend: (() -> Void)?
    /// The most its words take before they scroll.
    var maxText: CGFloat = 150
    var canSend = false { didSet { send.isEnabled = canSend } }

    static let pad: CGFloat = 10
    static let footHeight: CGFloat = 28
    static let chipHeight: CGFloat = 46

    init(composer: ComposerTextView) {
        self.composer = composer
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 14
        layer?.cornerCurve = .continuous
        layer?.masksToBounds = false
        layer?.shadowOpacity = 0.08
        layer?.shadowRadius = 6
        layer?.shadowOffset = NSSize(width: 0, height: -1)
        composer.drawsBackground = false
        composer.textContainerInset = NSSize(width: 0, height: 2)
        scroll.documentView = composer
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.borderType = .noBorder
        placeholder.font = composer.font ?? UIType.body
        placeholder.textColor = Theme.tertiaryText
        placeholder.lineBreakMode = .byTruncatingTail
        send.onClick = { [weak self] in self?.onSend?() }
        for v in [scroll, placeholder, send] as [NSView] { addSubview(v) }
        themed { v in
            // A shade off the panel it's on, its edge a hairline.
            v.layer?.backgroundColor = Theme.panel.blended(withFraction: 0.55, of: .textBackgroundColor)?.cgColor ?? Theme.panel.cgColor
            v.layer?.borderColor = Flat.line.cgColor
            v.layer?.borderWidth = 0.5
            v.layer?.shadowColor = NSColor.black.cgColor
        }
    }

    required init?(coder: NSCoder) { fatalError() }

    /// Its words' height, as they're laid out at its width.
    private var textHeight: CGFloat {
        guard let lm = composer.layoutManager, let tc = composer.textContainer else { return 22 }
        lm.ensureLayout(for: tc)
        let h = lm.usedRect(for: tc).height + composer.textContainerInset.height * 2
        return min(max(22, ceil(h)), maxText)
    }

    /// Its height at its width now: its card, its words, its foot.
    var wantedHeight: CGFloat {
        Self.pad + (chipViews.isEmpty ? 0 : Self.chipHeight + 8) + textHeight + 6 + Self.footHeight + Self.pad - 4
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        needsLayout = true
    }

    override func layout() {
        super.layout()
        let pad = Self.pad, w = bounds.width - pad * 2
        var y = bounds.height - pad
        // The cards in a row, as many as fit; the rest cut at the edge.
        if !chipViews.isEmpty {
            var x = pad
            for chip in chipViews {
                let cw = min(200, chip.wantedWidth)
                chip.frame = NSRect(x: x, y: y - Self.chipHeight, width: cw, height: Self.chipHeight)
                chip.isHidden = x >= pad + w - 30
                x += cw + 8
            }
            y -= Self.chipHeight + 8
        }
        let foot = pad - 4
        send.frame = NSRect(x: bounds.width - pad + 2 - Self.footHeight, y: foot, width: Self.footHeight, height: Self.footHeight)
        var x = pad - 4
        for v in leading {
            if v.isHidden { continue }
            (v as? NSControl)?.sizeToFit()
            let size = v is NSControl ? v.frame.size : v.fittingSize
            v.frame = NSRect(x: x, y: foot + (Self.footHeight - size.height) / 2, width: size.width, height: size.height)
            x += v.frame.width + 6
        }
        let textBottom = foot + Self.footHeight + 6
        let th = max(22, y - textBottom)
        scroll.frame = NSRect(x: pad - 4, y: textBottom, width: w + 4, height: th)
        composer.minSize = NSSize(width: scroll.contentSize.width, height: th)
        composer.frame.size.width = scroll.contentSize.width
        placeholder.sizeToFit()
        placeholder.frame = NSRect(x: pad + 1, y: scroll.frame.maxY - placeholder.frame.height - 2,
                                   width: min(placeholder.frame.width, w - 4), height: placeholder.frame.height)
    }

    override func mouseDown(with event: NSEvent) { window?.makeFirstResponder(composer) }

    var debugState: String {
        "box \(frame.integral) placeholder “\(placeholder.stringValue)” hidden \(placeholder.isHidden) at \(placeholder.frame.integral) text “\(composer.string)” send \(canSend)"
    }
}

/// The round send button: the accent, an arrow up; quiet till there's
/// something to send.
final class SendButton: ClickView {
    override init(frame: NSRect) {
        super.init(frame: frame)
        isEnabled = false
        toolTip = "Send (↩)"
    }

    required init?(coder: NSCoder) { fatalError() }

    override func draw(_ dirtyRect: NSRect) {
        let r = bounds.insetBy(dx: 1, dy: 1)
        let fill = isEnabled ? (pressed ? Theme.accent.blended(withFraction: 0.2, of: .black) ?? Theme.accent : Theme.accent) : Theme.text.withAlphaComponent(0.12)
        fill.setFill()
        NSBezierPath(ovalIn: r).fill()
        let ink: NSColor = isEnabled ? .white : Theme.tertiaryText
        if let image = Theme.symbol("arrow.up", size: 12, weight: .bold, color: ink) {
            image.draw(centeredAt: NSPoint(x: r.midX, y: r.midY))
        }
    }

}

/// What a comment's about, as a card in the box: its icon on a little
/// square, its name over where it is.
final class ChipView: NSView {
    private let icon = NSImageView()
    private let title = NSTextField.label(font: UIType.label)
    private let detail = NSTextField.label(font: UIType.detail, color: Theme.secondaryText)
    private let square = NSView()
    /// Taken out (a reference's card), by its × under the pointer.
    var onRemove: (() -> Void)? { didSet { remove.isHidden = true } }
    private let remove = IconButton.clear(tip: "Remove")

    init(_ chip: ChatBox.Chip) {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 10
        layer?.cornerCurve = .continuous
        square.wantsLayer = true
        square.layer?.cornerRadius = 7
        square.layer?.cornerCurve = .continuous
        icon.image = chip.image ?? Theme.symbol(chip.symbol, size: 13, weight: .regular)
        icon.imageScaling = .scaleProportionallyDown
        icon.contentTintColor = Theme.secondaryText
        title.stringValue = chip.title
        detail.stringValue = chip.detail
        detail.isHidden = chip.detail.isEmpty
        for v in [square, icon, title, detail, remove] as [NSView] { addSubview(v) }
        remove.isHidden = true
        remove.contentTintColor = Theme.secondaryText
        remove.onClick = { [weak self] in self?.onRemove?() }
        themed { v in
            v.layer?.backgroundColor = Theme.text.withAlphaComponent(0.05).cgColor
            v.square.layer?.backgroundColor = Theme.panel.blended(withFraction: 0.6, of: .textBackgroundColor)?.cgColor
            v.square.layer?.borderColor = Flat.line.cgColor
            v.square.layer?.borderWidth = 0.5
        }
    }

    required init?(coder: NSCoder) { fatalError() }

    override func updateTrackingAreas() {
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
        super.updateTrackingAreas()
    }

    override func mouseEntered(with event: NSEvent) { if onRemove != nil { remove.isHidden = false } }
    override func mouseExited(with event: NSEvent) { remove.isHidden = true }

    var wantedWidth: CGFloat {
        title.sizeToFit()
        detail.sizeToFit()
        return min(300, 8 + 32 + 10 + max(title.frame.width, detail.isHidden ? 0 : detail.frame.width) + 14)
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        needsLayout = true
    }

    override func layout() {
        super.layout()
        let h = bounds.height
        square.frame = NSRect(x: 7, y: (h - 32) / 2, width: 32, height: 32)
        remove.frame = NSRect(x: bounds.width - 20, y: bounds.height - 20, width: 18, height: 18)
        icon.frame = square.frame.insetBy(dx: 8, dy: 8)
        let x = square.frame.maxX + 10, w = max(0, bounds.width - x - 10)
        if detail.isHidden {
            title.frame = NSRect(x: x, y: (h - 17) / 2, width: w, height: 17)
        } else {
            title.frame = NSRect(x: x, y: h / 2, width: w, height: 17)
            detail.frame = NSRect(x: x, y: h / 2 - 16, width: w, height: 15)
        }
    }
}
