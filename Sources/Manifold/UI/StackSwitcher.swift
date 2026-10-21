import AppKit
import ManifoldCore

/// ⌘E, or a right-click on a tile's title (§3.1): a stack's tiles as
/// cards hanging in the air over the stack's tile, its own bar put away.
/// Each hangs a title bar lower than the one behind it, all leaning back
/// a little alike; the cards in front of the chosen one are let down part
/// of the way, so more of it shows between them. Each E moves the
/// choice a card down; with the pointer, the card under it is chosen.
/// The cards hold the tiles' own views, scaled, so they stay live.
final class StackSwitcherView: NSView {
    /// A tile for a card: its placement, name, symbol and view.
    struct Entry {
        var id: PlacementID
        var title: String
        var symbol: String
        var view: PaneContent
    }

    private(set) var cards: [SwitcherCard]
    /// The card chosen, by its place in the stack (0 at the bottom).
    private(set) var selection: Int
    private let contentSize: NSSize
    private let background = SwitcherBackground()
    /// A card clicked, with the click's modifiers.
    var onPick: ((PlacementID, NSEvent.ModifierFlags) -> Void)?
    /// A click on none of the cards.
    var onCancel: (() -> Void)?
    /// The card under the pointer is the one chosen (opened by a right-click).
    var followsPointer = false {
        didSet { updateTrackingAreas() }
    }

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

    /// `entries` bottom to top, each with its view.
    init(entries: [Entry], contentSize: NSSize, selection: Int) {
        self.contentSize = contentSize
        self.selection = selection
        // Starting from the top, so the first choice flips down into place.
        place = CGFloat(entries.count - 1)
        home = entries.count - 1
        cards = entries.map { SwitcherCard(entry: $0, contentSize: contentSize) }
        super.init(frame: .zero)
        wantsLayer = true
        layer?.masksToBounds = true
        addSubview(background)
        for (i, card) in cards.enumerated() {
            card.onClick = { [weak self] mods in self?.pick(i, mods) }
            addSubview(card)
        }
    }

    required init?(coder: NSCoder) { fatalError() }

    var selectedID: PlacementID { cards[selection].id }
    /// The tile that was the stack's top: the last card.
    var topID: PlacementID { cards[cards.count - 1].id }

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

    /// Chooses a card outright (the pointer on it).
    func choose(_ i: Int) {
        guard !isClosing, i != selection, cards.indices.contains(i) else { return }
        selection = i
        startAnimating()
    }

    /// Closes on `pane`, which comes forward to fill the column, then calls
    /// `done`.
    func dismiss(to id: PlacementID, done: @escaping () -> Void) {
        isClosing = true
        if let i = cards.firstIndex(where: { $0.id == id }) {
            home = i
            selection = i
        }
        targetOpenness = 0
        onClosed = done
        startAnimating()
    }

    /// Gives the panes' views back; `keeping`'s is left in `column`, where
    /// the switcher leaves it, filling the column.
    func tearDown(keeping: PlacementID? = nil, in column: NSView? = nil) {
        link?.invalidate()
        link = nil
        for card in cards {
            if card.id == keeping, let column {
                card.hand(to: column, frame: convert(NSRect(origin: .zero, size: contentSize), to: column))
            } else {
                card.release()
            }
        }
    }

    private func pick(_ i: Int, _ mods: NSEvent.ModifierFlags) {
        guard !isClosing else { return }
        selection = i
        onPick?(cards[i].id, mods)
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

    /// Where a card hangs: its top edge, down from the top; how far it
    /// leans back; how far it's faded into the background.
    private struct Pose {
        var top: CGFloat
        var tilt: CGFloat
        var fog: CGFloat
    }

    private static let topMargin: CGFloat = 18
    /// How much lower each card hangs than the one behind it: its title bar.
    private static let hangStep: CGFloat = 26
    /// The most cards fanned out; further back, they hang together at the top.
    private static let mostFanned = 7
    private static let lean: CGFloat = 9

    /// Card `i` (0 at the back), with the choice at `place`: every card
    /// hangs a step lower than the one behind it; those in front of the
    /// choice are let down by `reveal`, so it shows between them, the more
    /// the nearer the choice is to passing them.
    private func pose(_ i: Int, reveal: CGFloat) -> Pose {
        let back = max(0, cards.count - Self.mostFanned)
        let slot = CGFloat(max(0, i - back))
        let r = CGFloat(i) - place
        let letDown = max(0, min(1, r))
        // Every card hangs at the same lean, the chosen one too: it only
        // shows more of itself.
        return Pose(top: Self.topMargin + slot * Self.hangStep + letDown * reveal,
                    tilt: Self.lean,
                    fog: r < 0 ? 0.06 + min(1, -r) * 0.3 : 0.12 * min(1, r))
    }

    private func layoutCards() {
        guard contentSize.width > 0, contentSize.height > 0, bounds.width > 0 else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let p = openness
        background.alphaValue = p
        // As wide as the column: each card the tile at its own size, leaning
        // back from its top edge, its foot running off below the column's.
        let width = bounds.width
        let scale = width / contentSize.width
        let homeFrame = NSRect(origin: .zero, size: contentSize)
        let height = SwitcherCard.headerHeight + contentSize.height * scale
        // How far the cards in front are let down: enough for the chosen
        // one's title and the top of what's in it to peek out.
        let reveal = max(Self.hangStep * 2, (height * 0.3).rounded())
        for (i, card) in cards.enumerated() {
            let pose = pose(i, reveal: reveal)
            var frame = NSRect(x: ((bounds.width - width) / 2).rounded(), y: bounds.height - pose.top - height,
                               width: width, height: height)
            var tilt = pose.tilt, fog = pose.fog, alpha = p
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
                alpha = 1
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

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseDown(with event: NSEvent) {}
    /// A click on none of the cards lets the stack be.
    override func mouseUp(with event: NSEvent) { onCancel?() }

    override func updateTrackingAreas() {
        trackingAreas.forEach(removeTrackingArea)
        if followsPointer {
            addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseMoved, .activeInKeyWindow, .inVisibleRect], owner: self))
        }
        super.updateTrackingAreas()
    }

    /// With the pointer: the frontmost card under it is chosen (its title
    /// bar among the others', or the part of it that shows).
    override func mouseMoved(with event: NSEvent) {
        guard followsPointer else { return }
        let p = convert(event.locationInWindow, from: nil)
        if let i = cards.lastIndex(where: { !$0.isHidden && $0.frame.contains(p) }) { choose(i) }
    }

    /// Debugging: the pointer resting on card `i`, and the cards' tops after.
    func debugHover(_ i: Int) -> String {
        choose(i)
        place = CGFloat(selection)
        openness = targetOpenness
        layoutCards()
        return "chose \(selection): " + cards.map { "\(Int(bounds.height - $0.frame.maxY))\($0.debugPaneHidden ? " (content hidden)" : "")" }.joined(separator: " ")
    }

    override func scrollWheel(with event: NSEvent) {
        scrolled += event.scrollingDeltaY * (event.hasPreciseScrollingDeltas ? 1 : 12)
        while abs(scrolled) >= 36 {
            move(scrolled > 0 ? 1 : -1)
            scrolled -= scrolled > 0 ? 36 : -36
        }
    }
}

/// Behind the cards: a wash from the window's color down to a cool grey.
/// Behind the cards: nothing of its own — the window's background shows,
/// so the fan reads as the tile opened, not a window over it.
final class SwitcherBackground: NSView {
    override func draw(_ dirtyRect: NSRect) {}
}

/// A sheet in the switcher: a title bar with its icon and name, then the
/// pane itself, scaled to fit.
final class SwitcherCard: NSView {
    let id: PlacementID
    private let paneView: PaneContent
    private let contentSize: NSSize
    private let holder = NSView()
    private let scaler = NSView()
    private let fogView = NSView()
    private let header = NSView()
    private let icon = NSImageView()
    private let title = NSTextField(labelWithString: "")
    var onClick: ((NSEvent.ModifierFlags) -> Void)?

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

    init(entry: StackSwitcherView.Entry, contentSize: NSSize) {
        self.id = entry.id
        self.paneView = entry.view
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
        scaler.addSubview(entry.view)
        entry.view.isHidden = false
        entry.view.frame = NSRect(origin: .zero, size: contentSize)
        fogView.wantsLayer = true
        fogView.themed { $0.layer?.backgroundColor = Theme.switcherFog.cgColor }
        fogView.alphaValue = 0
        holder.addSubview(fogView)

        header.wantsLayer = true
        header.themed { $0.layer?.backgroundColor = Theme.switcherHeader.cgColor }
        holder.addSubview(header)
        icon.image = Theme.symbol(entry.symbol, size: 11)
        icon.contentTintColor = Theme.secondaryText
        title.stringValue = entry.title
        title.font = .systemFont(ofSize: 11.5, weight: .semibold)
        title.textColor = Theme.text
        title.lineBreakMode = .byTruncatingTail
        header.addSubview(icon)
        header.addSubview(title)
    }

    required init?(coder: NSCoder) { fatalError() }

    var debugPaneHidden: Bool { paneView.isHidden }

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

    /// A click on a card in a window not yet active takes the card too.
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseDown(with event: NSEvent) {}
    override func mouseUp(with event: NSEvent) { onClick?(event.modifierFlags) }
}
