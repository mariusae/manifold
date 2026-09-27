import AppKit
import ManifoldCore

/// ⌘E: a stack's sheets as the cards of a file, within its column. The
/// sheets beneath the one chosen stand at the back, leaning away, only
/// their title bars showing; the chosen one stands in front of them, whole;
/// the ones passed over lie flat along the bottom. Each E flips the next
/// one down. The sheets are the panes' own views, scaled, so they stay live.
final class StackSwitcherView: NSView {
    private(set) var cards: [SwitcherCard]
    /// The card chosen, by its place in the stack (0 at the bottom).
    private(set) var selection: Int
    private let contentSize: NSSize
    private let background = SwitcherBackground()
    var onPick: ((UUID) -> Void)?

    /// Where each card is drawn from: the chosen place, eased toward
    /// `selection`, and how far the switcher is open (0 is the column as it
    /// was, the home card filling it).
    private var place: CGFloat
    private var openness: CGFloat = 0
    private var targetOpenness: CGFloat = 1
    /// The card that fills the column when closed: the top at first, the
    /// chosen one on the way out.
    private var home: Int
    private var link: CADisplayLink?
    private var lastTick: CFTimeInterval = 0
    private var onClosed: (() -> Void)?
    private(set) var isClosing = false
    private var scrolled: CGFloat = 0

    /// `panes` bottom to top, each with its view.
    init(panes: [(Pane, PaneContent)], contentSize: NSSize, selection: Int) {
        self.contentSize = contentSize
        self.selection = selection
        // Starting from the top, so the first choice flips down into place.
        place = CGFloat(panes.count - 1)
        home = panes.count - 1
        cards = panes.map { SwitcherCard(pane: $0.0, view: $0.1, contentSize: contentSize) }
        super.init(frame: .zero)
        wantsLayer = true
        layer?.masksToBounds = true
        addSubview(background)
        for (i, card) in cards.enumerated() {
            card.onClick = { [weak self] in self?.pick(i) }
            addSubview(card)
        }
    }

    required init?(coder: NSCoder) { fatalError() }

    var selectedPane: UUID { cards[selection].pane.id }

    /// Opens, the top sheet dropping down to show the others.
    func present() {
        targetOpenness = 1
        startAnimating()
    }

    /// Moves the choice along: down the stack by default.
    func move(_ delta: Int) {
        guard !isClosing else { return }
        selection = (selection + delta + cards.count) % cards.count
        startAnimating()
    }

    /// Closes on `pane`, which comes forward to fill the column, then calls
    /// `done`.
    func dismiss(to pane: UUID, done: @escaping () -> Void) {
        isClosing = true
        if let i = cards.firstIndex(where: { $0.pane.id == pane }) {
            home = i
            selection = i
        }
        targetOpenness = 0
        onClosed = done
        startAnimating()
    }

    /// Gives the panes' views back; `keeping`'s is left in `column`, where
    /// the switcher leaves it, filling the column.
    func tearDown(keeping: UUID? = nil, in column: NSView? = nil) {
        link?.invalidate()
        link = nil
        for card in cards {
            if card.pane.id == keeping, let column {
                card.hand(to: column, frame: convert(NSRect(origin: .zero, size: contentSize), to: column))
            } else {
                card.release()
            }
        }
    }

    private func pick(_ i: Int) {
        guard !isClosing else { return }
        selection = i
        onPick?(cards[i].pane.id)
    }

    // MARK: Animation

    private func startAnimating() {
        if link == nil {
            let link = displayLink(target: self, selector: #selector(tick(_:)))
            link.add(to: .main, forMode: .common)
            self.link = link
            lastTick = 0
        }
    }

    @objc private func tick(_ link: CADisplayLink) {
        let now = link.timestamp
        let dt = lastTick == 0 ? 1.0 / 60 : min(now - lastTick, 1.0 / 20)
        lastTick = now
        // Eased toward where they're going, quickly at first.
        place += (CGFloat(selection) - place) * CGFloat(1 - exp(-dt * 14))
        openness += (targetOpenness - openness) * CGFloat(1 - exp(-dt * (isClosing ? 20 : 14)))
        let settled = abs(place - CGFloat(selection)) < 0.002 && abs(openness - targetOpenness) < 0.002
        if settled {
            place = CGFloat(selection)
            openness = targetOpenness
            link.invalidate()
            self.link = nil
        }
        layoutCards()
        if settled, isClosing, let done = onClosed {
            onClosed = nil
            done()
        }
    }

    override func layout() {
        super.layout()
        background.frame = bounds
        layoutCards()
    }

    /// Where a card is, by its place relative to the chosen one (`r`):
    /// below 0, still to come, at the back; 0, chosen; above 0, passed over,
    /// lying flat along the bottom.
    private struct Pose {
        var top: CGFloat    // its top edge, down from the top
        var tilt: CGFloat   // how far it leans back, in degrees
        var fog: CGFloat    // how far it's faded into the background
        var alpha: CGFloat
    }

    private static let pileStep: CGFloat = 22
    private static let maxPile: CGFloat = 4
    private static let topMargin: CGFloat = 30
    private static let lean: CGFloat = 14
    /// How much of the cards passed over shows, nearest first.
    private static let shelf: [CGFloat] = [0, 58, 24, 6, -16]

    private func pose(_ r: CGFloat) -> Pose {
        let pile = min(place, Self.maxPile)
        let chosenTop = Self.topMargin + pile * Self.pileStep
        if r <= 0 {
            let slot = pile + r
            return Pose(top: Self.topMargin + slot * Self.pileStep, tilt: Self.lean,
                        fog: 0.08 + min(1, -r) * 0.4, alpha: max(0, min(1, slot + 1)))
        }
        // Passed over: down onto the shelf, flattening as it goes.
        func shelfTop(_ n: Int) -> CGFloat { bounds.height - Self.shelf[min(n, Self.shelf.count - 1)] }
        let n = Int(r.rounded(.down)), f = r - CGFloat(n)
        let from = n == 0 ? chosenTop : shelfTop(n)
        return Pose(top: from + (shelfTop(n + 1) - from) * f, tilt: n == 0 ? Self.lean * (1 - f) : 0,
                    fog: n == 0 ? 0.08 + 0.22 * f : 0.3, alpha: 1)
    }

    private func layoutCards() {
        guard contentSize.width > 0, contentSize.height > 0, bounds.width > 0 else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let p = openness
        background.alphaValue = p
        let width = (bounds.width * 0.84).rounded()
        let scale = width / contentSize.width
        let homeFrame = NSRect(origin: .zero, size: contentSize)
        for (i, card) in cards.enumerated() {
            let pose = pose(CGFloat(i) - place)
            let height = SwitcherCard.headerHeight + contentSize.height * scale
            var frame = NSRect(x: ((bounds.width - width) / 2).rounded(), y: bounds.height - pose.top - height,
                               width: width, height: height)
            var tilt = pose.tilt, fog = pose.fog, alpha = pose.alpha * p
            var chrome: CGFloat = 1
            if i == home {
                // Fills the column when closed, as it did before opening.
                let q = 1 - p
                frame = NSRect(x: frame.minX + (homeFrame.minX - frame.minX) * q,
                               y: frame.minY + (homeFrame.minY - frame.minY) * q,
                               width: frame.width + (homeFrame.width - frame.width) * q,
                               height: frame.height + (homeFrame.height - frame.height) * q)
                tilt *= p
                fog *= p
                alpha = pose.alpha + (1 - pose.alpha) * q
                chrome = p
            }
            card.chrome = chrome
            card.fog = fog
            card.alphaValue = alpha
            card.isHidden = alpha < 0.01
            card.frame = frame
            card.layoutSubtreeIfNeeded()
            card.lean(tilt)
        }
        CATransaction.commit()
    }

    // MARK: Mouse

    // The frontmost card under the mouse takes a click (the cards lean, so
    // this is approximate near their lower corners).
    override func hitTest(_ point: NSPoint) -> NSView? {
        guard let superview else { return nil }
        let local = convert(point, from: superview)
        guard bounds.contains(local) else { return nil }
        return cards.last { !$0.isHidden && $0.frame.contains(local) } ?? self
    }

    override func mouseDown(with event: NSEvent) {}

    override func scrollWheel(with event: NSEvent) {
        scrolled += event.scrollingDeltaY * (event.hasPreciseScrollingDeltas ? 1 : 12)
        while abs(scrolled) >= 36 {
            move(scrolled > 0 ? 1 : -1)
            scrolled -= scrolled > 0 ? 36 : -36
        }
    }
}

/// Behind the cards: a wash from the window's color down to a cool grey.
final class SwitcherBackground: NSView {
    override func draw(_ dirtyRect: NSRect) {
        NSGradient(starting: Theme.switcherBottom, ending: Theme.switcherTop)?.draw(in: bounds, angle: 90)
    }
}

/// A sheet in the switcher: a title bar with its icon and name, then the
/// pane itself, scaled to fit.
final class SwitcherCard: NSView {
    let pane: Pane
    private let paneView: PaneContent
    private let contentSize: NSSize
    private let holder = NSView()
    private let scaler = NSView()
    private let fogView = NSView()
    private let header = NSView()
    private let icon = NSImageView()
    private let title = NSTextField(labelWithString: "")
    var onClick: (() -> Void)?

    static let headerHeight: CGFloat = 24

    /// How much of the card's chrome shows: its title bar, corners, and
    /// shadow (none when filling the column).
    var chrome: CGFloat = 1 {
        didSet {
            guard chrome != oldValue else { return }
            holder.layer?.cornerRadius = 8 * chrome
            layer?.shadowOpacity = Float(0.22 * chrome)
            needsLayout = true
        }
    }
    var fog: CGFloat = 0 { didSet { fogView.alphaValue = fog } }

    init(pane: Pane, view: PaneContent, contentSize: NSSize) {
        self.pane = pane
        self.paneView = view
        self.contentSize = contentSize
        super.init(frame: .zero)
        wantsLayer = true
        layer?.shadowOpacity = 0.22
        layer?.shadowRadius = 10
        layer?.shadowOffset = CGSize(width: 0, height: -3)
        holder.wantsLayer = true
        holder.layer?.cornerRadius = 8
        holder.layer?.cornerCurve = .continuous
        holder.layer?.masksToBounds = true
        holder.layer?.borderWidth = 0.5
        holder.themed {
            $0.layer?.backgroundColor = Theme.windowBackground.cgColor
            $0.layer?.borderColor = Theme.panelBorder.cgColor
        }
        addSubview(holder)
        holder.addSubview(scaler)
        scaler.addSubview(view)
        view.frame = NSRect(origin: .zero, size: contentSize)
        fogView.wantsLayer = true
        fogView.themed { $0.layer?.backgroundColor = Theme.switcherFog.cgColor }
        fogView.alphaValue = 0
        holder.addSubview(fogView)

        header.wantsLayer = true
        header.themed { $0.layer?.backgroundColor = Theme.switcherHeader.cgColor }
        holder.addSubview(header)
        icon.image = Theme.symbol(Theme.symbolName(for: pane.kind), size: 11)
        icon.contentTintColor = Theme.secondaryText
        title.stringValue = pane.displayTitle
        title.font = .systemFont(ofSize: 11.5, weight: .semibold)
        title.textColor = Theme.text
        title.lineBreakMode = .byTruncatingTail
        header.addSubview(icon)
        header.addSubview(title)
    }

    required init?(coder: NSCoder) { fatalError() }

    /// Takes the pane's view back out.
    func release() {
        if paneView.superview === scaler { paneView.removeFromSuperview() }
    }

    /// Leaves the pane's view in `column`, at `frame`, unscaled.
    func hand(to column: NSView, frame: NSRect) {
        column.addSubview(paneView)
        paneView.frame = frame
    }

    /// Leans the card back from its top edge, in perspective. The lean is
    /// the card's transform for what's in it, not the card's own: AppKit
    /// doesn't draw a view whose own layer is turned in depth.
    func lean(_ degrees: CGFloat) {
        guard let layer else { return }
        guard degrees > 0.01 else {
            layer.sublayerTransform = CATransform3DIdentity
            return
        }
        // About the middle of the top edge, wherever AppKit put the anchor.
        let w = bounds.width, h = bounds.height
        let axis = CGPoint(x: w / 2 - layer.anchorPoint.x * w, y: h - layer.anchorPoint.y * h)
        var t = CATransform3DMakeTranslation(-axis.x, -axis.y, 0)
        t = CATransform3DConcat(t, CATransform3DMakeRotation(degrees * .pi / 180, 1, 0, 0))
        var perspective = CATransform3DIdentity
        perspective.m34 = -1 / 1000
        t = CATransform3DConcat(t, perspective)
        t = CATransform3DConcat(t, CATransform3DMakeTranslation(axis.x, axis.y, 0))
        layer.sublayerTransform = t
    }

    override func layout() {
        super.layout()
        holder.frame = bounds
        let hh = (Self.headerHeight * chrome).rounded()
        header.frame = NSRect(x: 0, y: bounds.height - hh, width: bounds.width, height: hh)
        header.alphaValue = chrome
        let body = NSRect(x: 0, y: 0, width: bounds.width, height: bounds.height - hh)
        // The pane keeps its size; the scaler draws it smaller.
        scaler.frame = body
        scaler.setBoundsSize(contentSize)
        paneView.frame = NSRect(origin: .zero, size: contentSize)
        fogView.frame = body
        title.sizeToFit()
        let tw = min(title.frame.width, bounds.width - 60)
        let x = ((bounds.width - 21 - tw) / 2).rounded()
        icon.frame = NSRect(x: x, y: (hh - 14) / 2, width: 16, height: 14)
        title.frame = NSRect(x: x + 21, y: ((hh - title.frame.height) / 2).rounded(), width: tw,
                             height: title.frame.height)
    }

    // The card takes the click, not the pane inside it.
    override func hitTest(_ point: NSPoint) -> NSView? {
        frame.contains(point) ? self : nil
    }

    override func mouseDown(with event: NSEvent) {}
    override func mouseUp(with event: NSEvent) { onClick?() }
}
