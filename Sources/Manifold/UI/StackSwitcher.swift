import AppKit
import ManifoldCore

/// ⌘E: a stack's sheets laid out side by side within its column, as iOS
/// lays out apps, the top of the stack on the right. The sheets are the
/// panes' own views, scaled down, so they stay live. The chosen one is in
/// the middle; its neighbours run off the column's edges.
final class StackSwitcherView: NSView {
    private(set) var cards: [SwitcherCard]
    private(set) var selection: Int
    private let contentSize: NSSize
    var onPick: ((UUID) -> Void)?

    /// `panes` bottom to top, each with its view.
    init(panes: [(Pane, PaneContent)], contentSize: NSSize, selection: Int) {
        self.contentSize = contentSize
        self.selection = selection
        cards = panes.map { SwitcherCard(pane: $0.0, view: $0.1, contentSize: contentSize) }
        super.init(frame: .zero)
        wantsLayer = true
        themed { $0.layer?.backgroundColor = Theme.switcherBackground.cgColor }
        layer?.masksToBounds = true
        for (i, card) in cards.enumerated() {
            card.onClick = { [weak self] in
                guard let self else { return }
                self.selection = i
                self.onPick?(card.pane.id)
            }
            addSubview(card)
        }
        raiseSelected()
    }

    required init?(coder: NSCoder) { fatalError() }

    var selectedPane: UUID { cards[selection].pane.id }

    /// Moves the choice along: down the stack (to the left) by default.
    func move(_ delta: Int) {
        selection = (selection + delta + cards.count) % cards.count
        raiseSelected()
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.22
            ctx.timingFunction = CAMediaTimingFunction(controlPoints: 0.2, 0.9, 0.3, 1)
            ctx.allowsImplicitAnimation = true
            layoutCards(animated: true)
        }
    }

    /// Gives the panes' views back.
    func tearDown() {
        for card in cards { card.release() }
    }

    override func layout() {
        super.layout()
        layoutCards(animated: false)
    }

    private func raiseSelected() {
        // Nearer the top of the stack sits in front; the choice above all.
        for card in cards { addSubview(card) }
        addSubview(cards[selection])
    }

    private func layoutCards(animated: Bool) {
        guard contentSize.width > 0, contentSize.height > 0 else { return }
        let scale = min(0.66, bounds.width * 0.66 / contentSize.width, bounds.height * 0.66 / contentSize.height)
        let size = NSSize(width: contentSize.width * scale, height: contentSize.height * scale)
        let step = size.width * 0.74
        for (i, card) in cards.enumerated() {
            let offset = CGFloat(i - selection)
            let shrink: CGFloat = i == selection ? 1 : 0.9
            let w = size.width * shrink, h = size.height * shrink
            let midX = bounds.midX + offset * step
            let frame = NSRect(x: midX - w / 2, y: bounds.midY - h / 2 - 12, width: w, height: h + SwitcherCard.labelHeight)
            if animated {
                card.animator().frame = frame.integral
                card.animator().alphaValue = i == selection ? 1 : 0.8
            } else {
                card.frame = frame.integral
                card.alphaValue = i == selection ? 1 : 0.8
            }
            card.chosen = i == selection
        }
    }

    // Clicks outside the cards do nothing (and don't reach what's beneath).
    override func mouseDown(with event: NSEvent) {}
    override func scrollWheel(with event: NSEvent) {}
}

/// A sheet in the switcher: its icon and title above, then the pane itself,
/// scaled to fit.
final class SwitcherCard: NSView {
    let pane: Pane
    private let paneView: PaneContent
    private let contentSize: NSSize
    private let holder = NSView()
    private let scaler = NSView()
    private let icon = NSImageView()
    private let title = NSTextField(labelWithString: "")
    var onClick: (() -> Void)?
    var chosen = false { didSet { updateChrome() } }

    static let labelHeight: CGFloat = 26

    init(pane: Pane, view: PaneContent, contentSize: NSSize) {
        self.pane = pane
        self.paneView = view
        self.contentSize = contentSize
        super.init(frame: .zero)
        holder.wantsLayer = true
        holder.layer?.cornerRadius = 12
        holder.layer?.cornerCurve = .continuous
        holder.layer?.masksToBounds = true
        holder.layer?.borderWidth = 0.5
        holder.themed { $0.layer?.backgroundColor = Theme.windowBackground.cgColor }
        wantsLayer = true
        shadow = {
            let s = NSShadow()
            s.shadowColor = NSColor(white: 0, alpha: 0.22)
            s.shadowBlurRadius = 18
            s.shadowOffset = NSSize(width: 0, height: -6)
            return s
        }()
        addSubview(holder)
        holder.addSubview(scaler)
        scaler.addSubview(view)
        view.frame = NSRect(origin: .zero, size: contentSize)

        icon.image = Theme.symbol(Theme.symbolName(for: pane.kind), size: 13)
        icon.contentTintColor = Theme.secondaryText
        title.stringValue = pane.displayTitle
        title.font = .systemFont(ofSize: 13, weight: .medium)
        title.textColor = Theme.text
        title.lineBreakMode = .byTruncatingTail
        addSubview(icon)
        addSubview(title)
        updateChrome()
    }

    required init?(coder: NSCoder) { fatalError() }

    /// Takes the pane's view back out.
    func release() {
        if paneView.superview === scaler { paneView.removeFromSuperview() }
    }

    override func layout() {
        super.layout()
        let body = NSRect(x: 0, y: 0, width: bounds.width, height: bounds.height - Self.labelHeight)
        holder.frame = body
        // The pane keeps its size; the scaler draws it smaller.
        scaler.frame = holder.bounds
        scaler.setBoundsSize(contentSize)
        paneView.frame = NSRect(origin: .zero, size: contentSize)
        icon.frame = NSRect(x: 2, y: body.maxY + 6, width: 16, height: 16)
        title.frame = NSRect(x: 24, y: body.maxY + 5, width: bounds.width - 26, height: 17)
    }

    private func updateChrome() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            holder.layer?.borderColor = (chosen ? Theme.accent.withAlphaComponent(0.8) : Theme.panelBorder).cgColor
        }
        holder.layer?.borderWidth = chosen ? 2 : 0.5
    }

    // The card takes the click, not the pane inside it.
    override func hitTest(_ point: NSPoint) -> NSView? {
        frame.contains(point) ? self : nil
    }

    override func mouseDown(with event: NSEvent) {}
    override func mouseUp(with event: NSEvent) { onClick?() }
}
