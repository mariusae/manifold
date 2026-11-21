import AppKit
import ManifoldCore

/// A thread's context — its **shelf** (§3.12): the agents in its
/// conversation, its lead first, and the references put there to stay part
/// of it, a chip each in a row under its place. Anything dropped on it is
/// added — an agent at work joins the conversation, anything else (a tile,
/// a file, a place, a page) is a reference — and a chip's × (or its menu)
/// takes it out. A chip clicked is gone to; an agent's, pointed at, rings
/// its tile. Those on the shelf are told everything said in the thread; a
/// comment asks the lead, or those it names.
final class ThreadShelfView: NSView {
    struct Item: Equatable {
        /// What it is: an agent's or a block's address (`manifold:…`), a
        /// file's (`manifold://host/path`), a page's.
        var address: String
        var title: String
        var image: NSImage?
        var symbol: String
        var agent: BlockID?
        var isLead = false
        /// What it is and does, under the pointer.
        var detail = ""
        /// An agent not running now: shown, dimmed.
        var quiet = false
    }

    var items: [Item] = [] { didSet { if items != oldValue { rebuild() } } }
    /// An address dropped (or chosen from +): added.
    var onAdd: (([String]) -> Void)?
    var onRemove: ((String) -> Void)?
    var onOpen: ((String) -> Void)?
    var onLead: ((BlockID) -> Void)?
    /// What + offers: the agents at work not in it.
    var addMenu: (() -> NSMenu?)?

    private var chips: [Chip] = []
    private let add = IconButton("plus", size: 10, tip: "Add an agent to the conversation — or drop anything here to keep it in the thread's context")
    private let hint = NSTextField.label("Drop agents and references here", font: UIType.footnote, color: Theme.tertiaryText)
    private var dropping = false { didSet { needsDisplay = true } }
    private var height: CGFloat = 22

    override init(frame: NSRect) {
        super.init(frame: frame)
        translatesAutoresizingMaskIntoConstraints = false
        add.target = self
        add.action = #selector(addClicked)
        addSubview(add)
        addSubview(hint)
        registerForDraggedTypes([.manifoldBlock] + Dragged.types)
        rebuild()
    }

    required init?(coder: NSCoder) { fatalError() }

    override var intrinsicContentSize: NSSize { NSSize(width: NSView.noIntrinsicMetric, height: height) }
    override var isFlipped: Bool { true }

    private func rebuild() {
        chips.forEach { $0.removeFromSuperview() }
        chips = items.map { item in
            let c = Chip(item)
            c.onOpen = { [weak self] in self?.onOpen?(item.address) }
            c.onRemove = { [weak self] in self?.onRemove?(item.address) }
            c.onLead = { [weak self] in item.agent.map { self?.onLead?($0) } }
            addSubview(c)
            return c
        }
        hint.isHidden = !items.isEmpty
        needsLayout = true
    }

    /// Chips laid out in rows, + after the last; as tall as they take.
    override func layout() {
        super.layout()
        var x: CGFloat = 0, y: CGFloat = 0
        let rowH: CGFloat = 22, gap: CGFloat = 5
        for c in chips {
            let w = min(c.wanted, bounds.width)
            if x > 0, x + w > bounds.width - 26 { x = 0; y += rowH + 4 }
            c.frame = NSRect(x: x, y: y, width: w, height: rowH)
            x += w + gap
        }
        add.frame = NSRect(x: x, y: y + 3, width: 16, height: 16)
        if !hint.isHidden {
            let s = hint.intrinsicContentSize
            hint.frame = NSRect(x: x + 22, y: y + (rowH - s.height) / 2, width: max(0, bounds.width - x - 22), height: s.height)
        }
        let h = y + rowH
        if h != height {
            height = h
            invalidateIntrinsicContentSize()
        }
    }

    @objc private func addClicked() {
        guard let menu = addMenu?(), !menu.items.isEmpty else { return NSSound.beep() }
        menu.delegate = AgentMenuSpotlight.shared
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: add.frame.maxY + 4), in: self)
    }

    override func draw(_ dirtyRect: NSRect) {
        guard dropping else { return }
        Theme.accent.withAlphaComponent(0.12).setFill()
        let r = NSBezierPath(roundedRect: bounds.insetBy(dx: -3, dy: -2), xRadius: Radius.control, yRadius: Radius.control)
        r.fill()
        Theme.accent.setStroke()
        r.lineWidth = 1
        r.stroke()
    }

    // MARK: Dropped on

    /// What a drag carries, as addresses: a tile's block (its bar dragged),
    /// each thing's block (at its place), file, page.
    private func addresses(_ sender: NSDraggingInfo) -> [String] { Self.addresses(sender.draggingPasteboard) }

    /// What a pasteboard carries, as addresses (a drag's, onto a shelf or a
    /// project's Pinned).
    static func addresses(_ pb: NSPasteboard) -> [String] {
        if let s = pb.string(forType: .manifoldBlock), let id = BlockID(string: s) { return [MainWindowController.address(id)] }
        guard let d = Dragged(pb) else { return [] }
        return d.things.compactMap { t -> String? in
            if let b = t.block { return MainWindowController.address(b, anchor: t.at?.fragment) }
            if let f = t.file { return ManifoldAddress.of(file: f.path, on: f.host, isDirectory: f.isDirectory) }
            return t.url
        }
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation { draggingUpdated(sender) }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        let ok = !addresses(sender).isEmpty
        dropping = ok
        return ok ? .link : []
    }

    override func draggingExited(_ sender: NSDraggingInfo?) { dropping = false }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        dropping = false
        let found = addresses(sender)
        guard !found.isEmpty else { return false }
        onAdd?(found)
        return true
    }

    /// The pointer onto chip `n` (the others left), or off them all (-1):
    /// as a tracking area would say, which a posted move doesn't stir.
    func debugHover(_ n: Int) -> String {
        guard let e = NSEvent.enterExitEvent(with: .mouseEntered, location: .zero, modifierFlags: [], timestamp: 0,
                                             windowNumber: window?.windowNumber ?? 0, context: nil, eventNumber: 0, trackingNumber: 0, userData: nil) else { return "no event" }
        for (i, c) in chips.enumerated() where i != n { c.mouseExited(with: e) }
        if chips.indices.contains(n) { chips[n].mouseEntered(with: e) }
        return chips.indices.contains(n) ? "hovering \(chips[n].item.title) (\(chips[n].frame.width) wide)" : "off"
    }

    var debugState: String {
        items.map { ($0.isLead ? "*" : "") + ($0.agent != nil ? "agent " : "") + $0.title }.joined(separator: " | ")
    }

    /// One thing on the shelf: its face or symbol, its name; × under the pointer.
    private final class Chip: NSView {
        let item: Item
        var onOpen: (() -> Void)?
        var onRemove: (() -> Void)?
        var onLead: (() -> Void)?
        private let icon = NSImageView()
        private let label: NSTextField
        private let close = IconButton("xmark", size: 8, tip: "Take out of the thread's context")
        private var hovering = false { didSet { close.isHidden = !hovering; needsDisplay = true } }

        init(_ item: Item) {
            self.item = item
            label = NSTextField.label((item.isLead ? "★ " : "") + item.title, font: .systemFont(ofSize: 11, weight: item.agent != nil ? .semibold : .regular),
                                      color: Theme.text)
            super.init(frame: .zero)
            label.lineBreakMode = .byTruncatingTail
            icon.image = item.image ?? Theme.symbol(item.symbol, size: 11, weight: .medium, color: Theme.secondaryText)
            icon.imageScaling = .scaleProportionallyUpOrDown
            close.isHidden = true
            close.target = self
            close.action = #selector(closeClicked)
            for v in [icon, label, close] as [NSView] { addSubview(v) }
            if item.quiet { icon.alphaValue = 0.45; label.textColor = Theme.tertiaryText }
            // An agent's says what it is; a reference shows its card instead.
            toolTip = item.agent != nil
                ? "\(item.title)\(item.isLead ? ", the lead — asked by a comment that names no one" : "")\(item.detail.isEmpty ? "" : " · " + item.detail) — click to go to it"
                : nil
        }

        required init?(coder: NSCoder) { fatalError() }

        /// Its icon's room, its name — whole, up to a point, then cut with
        /// "…" (a commit's subject, a long title) — and room for × at its end.
        var wanted: CGFloat { 27 + min(ceil(label.intrinsicContentSize.width), Self.longest) + 4 + 18 }
        static let longest: CGFloat = 200

        override func layout() {
            super.layout()
            icon.frame = NSRect(x: 7, y: (bounds.height - 15) / 2, width: 15, height: 15)
            let lh = ceil(label.intrinsicContentSize.height)
            label.frame = NSRect(x: 27, y: (bounds.height - lh) / 2, width: max(0, bounds.width - 27 - 18), height: lh)
            close.frame = NSRect(x: bounds.width - 16, y: (bounds.height - 12) / 2, width: 12, height: 12)
        }

        override func draw(_ dirtyRect: NSRect) {
            let r = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: bounds.height / 2, yRadius: bounds.height / 2)
            (item.agent.flatMap { AgentLook.block?($0) }.flatMap(AgentLook.color(of:))?.withAlphaComponent(hovering ? 0.22 : 0.14)
                ?? Theme.text.withAlphaComponent(hovering ? 0.1 : 0.06)).setFill()
            r.fill()
        }

        override func updateTrackingAreas() {
            super.updateTrackingAreas()
            trackingAreas.forEach(removeTrackingArea)
            addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self))
        }

        override func mouseEntered(with event: NSEvent) {
            hovering = true
            if let a = item.agent { AgentLook.spotlight?(a) }
            // A reference's card (§7): a block's, a file's or a folder's, a page's.
            if item.agent == nil, let window { ReferenceCards.showAddress?(item.address, convert(bounds, to: nil), window) }
        }

        /// Taken off (the shelf redrawn, the tile closed) under the pointer: its card goes too.
        override func viewWillMove(toWindow newWindow: NSWindow?) {
            if newWindow == nil, hovering {
                if item.agent != nil { AgentLook.spotlight?(nil) }
                if item.agent == nil { ReferenceCards.hide?() }
            }
            super.viewWillMove(toWindow: newWindow)
        }

        override func mouseExited(with event: NSEvent) {
            hovering = false
            if item.agent != nil { AgentLook.spotlight?(nil) }
            if item.agent == nil { ReferenceCards.hide?() }
        }

        override func mouseUp(with event: NSEvent) {
            if item.agent == nil { ReferenceCards.hide?() }
            if bounds.contains(convert(event.locationInWindow, from: nil)) { onOpen?() }
        }

        override func menu(for event: NSEvent) -> NSMenu? {
            let menu = NSMenu()
            menu.addItem(ClosureMenuItem(item.agent != nil ? "Go to \(item.title)" : "Open", symbol: nil) { [weak self] in self?.onOpen?() })
            if item.agent != nil, !item.isLead {
                menu.addItem(ClosureMenuItem("Make the Lead", symbol: "star") { [weak self] in self?.onLead?() })
            }
            menu.addItem(.separator())
            menu.addItem(ClosureMenuItem("Take Out of the Context", symbol: "minus.circle") { [weak self] in self?.onRemove?() })
            return menu
        }

        @objc private func closeClicked() { onRemove?() }
    }
}
