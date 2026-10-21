import AppKit
import ManifoldCore

/// A node of the neighborhood as drawn: a block, how far from the center.
struct GraphNode: Equatable {
    var id: BlockID
    var title: String
    var symbol: String
    var detail: String
    var distance: Int
    var isArrangement: Bool
}

/// An edge as drawn: between two nodes, of a kind (nil for the trail),
/// with what made it.
struct GraphEdge: Equatable {
    var from: BlockID
    var to: BlockID
    var kind: EdgeKind?
    var context: String?
    var at: Stamp?

    var label: String {
        switch kind {
        case .placed?: "placed in"
        case .contains?: "holds"
        case .link(let k)?: k.rawValue
        case nil: "then"
        }
    }
}

/// The neighborhood of a block to distance 2 (DESIGN.md §3.5): what to
/// draw, and how many more each node has past what's shown.
struct NeighborhoodModel {
    var center: BlockID
    var nodes: [GraphNode]
    var edges: [GraphEdge]
    var more: [BlockID: Int] = [:]

    func node(_ id: BlockID) -> GraphNode? { nodes.first { $0.id == id } }
}

/// The neighborhood in graph form, over the window: the block in the
/// middle, what it's joined to on a ring around it, and what those are
/// joined to on a ring beyond, each behind the node it hangs off. Not the
/// whole graph: two steps of it, which is as far as context reaches.
/// Click a node to make it the center and walk; double-click or ⏎ to go
/// to it; ⎋ to close.
final class NeighborhoodView: NSView {
    var onClose: (() -> Void)?
    var onGo: ((BlockID) -> Void)?
    /// The model for a center: the owner builds it from the graph.
    var source: ((BlockID) -> NeighborhoodModel)?

    private let panel = NSView()
    private let title = NSTextField(labelWithString: "")
    private let hint = NSTextField(labelWithString: "Click a block to look around it · double-click or ⏎ to go there · ⎋ closes")
    private let back = NSButton(title: "Back", target: nil, action: nil)
    private let close = NSButton(title: "Done", target: nil, action: nil)
    private let canvas = GraphCanvas()
    private var centers: [BlockID] = []

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
        title.font = .systemFont(ofSize: 13, weight: .semibold)
        title.textColor = Theme.text
        title.lineBreakMode = .byTruncatingMiddle
        hint.font = .systemFont(ofSize: 11.5)
        hint.textColor = Theme.secondaryText
        hint.alignment = .center
        back.target = self
        back.action = #selector(backClicked)
        back.bezelStyle = .rounded
        back.controlSize = .small
        back.font = .systemFont(ofSize: 11.5)
        close.target = self
        close.action = #selector(closeClicked)
        close.bezelStyle = .rounded
        close.keyEquivalent = "\u{1b}"
        canvas.onCenter = { [weak self] id in self?.center(on: id) }
        canvas.onGo = { [weak self] id in self?.onGo?(id) }
        for v in [title, hint, back, close, canvas] { panel.addSubview(v) }
    }

    required init?(coder: NSCoder) { fatalError() }

    /// Starts at a block, or walks to another.
    func center(on id: BlockID) {
        guard let model = source?(id) else { return }
        if centers.last != id { centers.append(id) }
        title.stringValue = "Around " + (model.node(id)?.title ?? id.description)
        back.isEnabled = centers.count > 1
        canvas.show(model)
        window?.makeFirstResponder(self)
    }

    func settleForScript() { canvas.settleForScript() }

    @objc private func backClicked() {
        guard centers.count > 1 else { return }
        centers.removeLast()
        let previous = centers.removeLast()
        center(on: previous)
    }

    @objc private func closeClicked() { onClose?() }

    override func layout() {
        super.layout()
        let w = min(1100, bounds.width - 60), h = min(760, bounds.height - 60)
        panel.frame = NSRect(x: (bounds.width - w) / 2, y: (bounds.height - h) / 2, width: w, height: h).integral
        back.frame = NSRect(x: 16, y: h - 38, width: 64, height: 24)
        title.frame = NSRect(x: 90, y: h - 36, width: w - 190, height: 20)
        close.frame = NSRect(x: w - 96, y: h - 40, width: 80, height: 28)
        hint.frame = NSRect(x: 16, y: 12, width: w - 32, height: 16)
        canvas.frame = NSRect(x: 8, y: 34, width: w - 16, height: h - 84)
    }

    override func mouseDown(with event: NSEvent) {
        if !panel.frame.contains(convert(event.locationInWindow, from: nil)) { onClose?() }
    }

    override var acceptsFirstResponder: Bool { true }

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 53: onClose?()
        case 36, 76: if let id = canvas.selected ?? canvas.model?.center { onGo?(id) }
        case 49: if let id = canvas.selected { center(on: id) }
        case 123, 124, 125, 126: canvas.moveSelection(event.keyCode)
        default:
            if event.modifierFlags.contains(.command), event.charactersIgnoringModifiers == "[" { backClicked() } else { super.keyDown(with: event) }
        }
    }
}

/// The drawing: nodes on rings, edges between them, eased from where they
/// were to where they go when the center changes.
final class GraphCanvas: NSView {
    private(set) var model: NeighborhoodModel?
    var onCenter: ((BlockID) -> Void)?
    var onGo: ((BlockID) -> Void)?
    private(set) var selected: BlockID? { didSet { if selected != oldValue { needsDisplay = true } } }
    private var hovered: BlockID? { didSet { if hovered != oldValue { needsDisplay = true } } }

    /// Where each node is, and where it's going.
    private var positions: [BlockID: NSPoint] = [:]
    private var targets: [BlockID: NSPoint] = [:]
    private var timer: Timer?
    private var lastTick: CFTimeInterval = 0

    override var isFlipped: Bool { true }

    static let nodeSize = NSSize(width: 164, height: 34)
    static let centerSize = NSSize(width: 200, height: 42)

    func show(_ model: NeighborhoodModel) {
        let old = self.model
        self.model = model
        selected = nil
        hovered = nil
        targets = layout(model)
        // Nodes new to the picture start where the old center was, or at the
        // center; those staying ease from where they were.
        let from = old.flatMap { positions[$0.center] } ?? NSPoint(x: bounds.midX, y: bounds.midY)
        var next: [BlockID: NSPoint] = [:]
        for n in model.nodes { next[n.id] = positions[n.id] ?? from }
        positions = next
        run()
    }

    /// Rings: the center; distance 1 evenly around it; distance 2 beyond,
    /// each spread through the sector behind the node it hangs off.
    private func layout(_ model: NeighborhoodModel) -> [BlockID: NSPoint] {
        var out: [BlockID: NSPoint] = [:]
        let c = NSPoint(x: bounds.midX, y: bounds.midY)
        out[model.center] = c
        // Rings wide enough for the cards: ellipses, broader than tall.
        let ry1 = min(bounds.height * 0.24, 190)
        let rx1 = min(max(ry1 * 1.5, Self.centerSize.width / 2 + Self.nodeSize.width / 2 + 60), bounds.width / 2 - Self.nodeSize.width)
        let ry2 = min(bounds.height * 0.46, ry1 + 130)
        let rx2 = min(max(rx1 + Self.nodeSize.width + 70, ry2 * 1.5), bounds.width / 2 - Self.nodeSize.width / 2 - 8)
        let ring1 = model.nodes.filter { $0.distance == 1 }
        let ring2 = model.nodes.filter { $0.distance == 2 }
        guard !ring1.isEmpty else { return out }
        // Each outer node hangs off the first inner node it's joined to.
        var parent: [BlockID: BlockID] = [:]
        for n in ring2 {
            let inner = Set(ring1.map(\.id))
            let e = model.edges.first { e in (e.from == n.id && inner.contains(e.to)) || (e.to == n.id && inner.contains(e.from)) }
            if let e { parent[n.id] = e.from == n.id ? e.to : e.from }
        }
        let sector = 2 * .pi / CGFloat(ring1.count)
        // Wider sectors for inner nodes with more hanging off them would be
        // fairer; even ones read more calmly. One or two go left and right;
        // more start at the top.
        let start: CGFloat = ring1.count <= 2 ? .pi : -.pi / 2
        for (i, n) in ring1.enumerated() {
            let a = start + sector * CGFloat(i)
            out[n.id] = NSPoint(x: c.x + rx1 * cos(a), y: c.y + ry1 * sin(a))
            let children = ring2.filter { parent[$0.id] == n.id }
            let spread = sector * 0.85
            for (j, ch) in children.enumerated() {
                let t = children.count == 1 ? 0 : (CGFloat(j) / CGFloat(children.count - 1) - 0.5)
                let b = a + t * spread
                out[ch.id] = NSPoint(x: c.x + rx2 * cos(b), y: c.y + ry2 * sin(b))
            }
        }
        // Outer nodes joined only to other outer nodes: at the bottom, in a row.
        let orphans = ring2.filter { parent[$0.id] == nil }
        for (j, n) in orphans.enumerated() {
            out[n.id] = NSPoint(x: c.x + (CGFloat(j) - CGFloat(orphans.count - 1) / 2) * (Self.nodeSize.width + 12), y: bounds.maxY - 30)
        }
        return out
    }

    override func layout() {
        super.layout()
        if let model { targets = layout(model); run() }
    }

    private func run() {
        guard timer == nil, window != nil else { needsDisplay = true; return }
        lastTick = 0
        let t = Timer(timeInterval: 1.0 / 60, repeats: true) { [weak self] _ in self?.tick() }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    private func tick() {
        let now = CACurrentMediaTime()
        let dt = lastTick == 0 ? 1.0 / 60 : min(now - lastTick, 1.0 / 20)
        lastTick = now
        var settled = true
        for (id, t) in targets {
            let p = positions[id] ?? t
            let np = NSPoint(x: p.x + (t.x - p.x) * CGFloat(1 - exp(-dt * 12)), y: p.y + (t.y - p.y) * CGFloat(1 - exp(-dt * 12)))
            positions[id] = np
            if abs(np.x - t.x) > 0.3 || abs(np.y - t.y) > 0.3 { settled = false }
        }
        if settled {
            positions = targets
            timer?.invalidate()
            timer = nil
        }
        needsDisplay = true
    }

    /// Settles every node where it's going, for a script's picture.
    func settleForScript() {
        positions = targets
        timer?.invalidate()
        timer = nil
        needsDisplay = true
    }

    override func removeFromSuperview() {
        timer?.invalidate()
        timer = nil
        super.removeFromSuperview()
    }

    private func rect(of id: BlockID) -> NSRect? {
        guard let p = positions[id], let model else { return nil }
        let size = id == model.center ? Self.centerSize : Self.nodeSize
        return NSRect(x: p.x - size.width / 2, y: p.y - size.height / 2, width: size.width, height: size.height)
    }

    static func color(_ kind: EdgeKind?) -> NSColor {
        switch kind {
        case .placed?, .contains?: Theme.secondaryText
        case .link(.opened)?: Theme.accent
        case .link(.linked)?: NSColor.systemPurple
        case nil: Theme.secondaryText
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let model else { return }
        let focus = hovered ?? selected
        // Edges first, under the nodes; those at the pointed-at node brighter.
        for e in model.edges {
            guard let a = rect(of: e.from), let b = rect(of: e.to) else { continue }
            let near = focus == nil || e.from == focus || e.to == focus
            let color = Self.color(e.kind).withAlphaComponent(near ? 0.75 : 0.18)
            let (p1, p2) = Self.clip(from: a, to: b)
            let path = NSBezierPath()
            path.move(to: p1)
            path.line(to: p2)
            path.lineWidth = near ? 1.5 : 1
            if e.kind == nil { path.setLineDash([4, 3], count: 2, phase: 0) }
            color.setStroke()
            path.stroke()
            // An arrowhead at the end it points to.
            let angle = atan2(p2.y - p1.y, p2.x - p1.x)
            let head = NSBezierPath()
            head.move(to: p2)
            head.line(to: NSPoint(x: p2.x - 8 * cos(angle - 0.4), y: p2.y - 8 * sin(angle - 0.4)))
            head.line(to: NSPoint(x: p2.x - 8 * cos(angle + 0.4), y: p2.y - 8 * sin(angle + 0.4)))
            head.close()
            color.setFill()
            head.fill()
            // The kind, and what made it, along a pointed-at edge.
            if focus != nil, near {
                var words = e.label
                if let c = e.context, !c.isEmpty { words += " · " + c }
                if let at = e.at { words += " · " + Age.ago(at) }
                let text = NSAttributedString(string: String(words.prefix(60)), attributes: [.font: NSFont.systemFont(ofSize: 10.5), .foregroundColor: Theme.text])
                let size = text.size()
                let mid = NSPoint(x: (p1.x + p2.x) / 2, y: (p1.y + p2.y) / 2)
                let box = NSRect(x: mid.x - size.width / 2 - 4, y: mid.y - size.height / 2 - 1, width: size.width + 8, height: size.height + 2)
                Theme.panel.withAlphaComponent(0.92).setFill()
                NSBezierPath(roundedRect: box, xRadius: 4, yRadius: 4).fill()
                text.draw(at: NSPoint(x: box.minX + 4, y: box.minY + 1))
            }
        }
        for n in model.nodes {
            guard let r = rect(of: n.id) else { continue }
            let isCenter = n.id == model.center
            let path = NSBezierPath(roundedRect: r, xRadius: 8, yRadius: 8)
            NSGraphicsContext.saveGraphicsState()
            let shadow = NSShadow()
            shadow.shadowColor = NSColor.black.withAlphaComponent(isCenter ? 0.18 : 0.1)
            shadow.shadowBlurRadius = isCenter ? 8 : 4
            shadow.shadowOffset = NSSize(width: 0, height: 1.5)
            shadow.set()
            (n.id == focus ? Theme.selected : n.isArrangement ? Theme.sheet(level: 1) : Theme.windowBackground).setFill()
            path.fill()
            NSGraphicsContext.restoreGraphicsState()
            if n.distance == 2 { NSGraphicsContext.current?.cgContext.setAlpha(0.8) }
            defer { if n.distance == 2 { NSGraphicsContext.current?.cgContext.setAlpha(1) } }
            (isCenter ? Theme.accent : Theme.panelBorder).setStroke()
            path.lineWidth = isCenter ? 1.5 : 0.5
            path.stroke()
            if let icon = Theme.symbol(n.symbol, size: isCenter ? 13 : 11) {
                let tinted = icon.copy() as! NSImage
                tinted.isTemplate = true
                NSGraphicsContext.saveGraphicsState()
                Theme.secondaryText.set()
                tinted.draw(in: NSRect(x: r.minX + 10, y: r.midY - 7, width: 14, height: 14), from: .zero, operation: .sourceOver, fraction: 0.9, respectFlipped: true, hints: nil)
                NSGraphicsContext.restoreGraphicsState()
            }
            let truncating = NSMutableParagraphStyle()
            truncating.lineBreakMode = .byTruncatingTail
            let text = NSAttributedString(string: n.title, attributes: [
                .font: NSFont.systemFont(ofSize: isCenter ? 13 : 12, weight: isCenter ? .semibold : .medium), .foregroundColor: Theme.text, .paragraphStyle: truncating])
            let extra = model.more[n.id].map { " +\($0)" } ?? ""
            let h = ceil(text.size().height)
            let moreText = NSAttributedString(string: extra, attributes: [.font: NSFont.systemFont(ofSize: 10.5), .foregroundColor: Theme.secondaryText])
            let moreWidth = extra.isEmpty ? 0 : ceil(moreText.size().width) + 4
            text.draw(with: NSRect(x: r.minX + 30, y: r.midY - h / 2, width: r.width - 38 - moreWidth, height: h), options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
            if !extra.isEmpty { moreText.draw(at: NSPoint(x: r.maxX - 8 - moreWidth + 4, y: r.midY - h / 2 + 1)) }
        }
        // A legend of the kinds in the picture.
        var x: CGFloat = 12
        var seen: [EdgeKind?] = []
        for e in model.edges where !seen.contains(e.kind) {
            seen.append(e.kind)
            let swatch = NSRect(x: x, y: bounds.maxY - 14, width: 14, height: 3)
            Self.color(e.kind).setFill()
            swatch.fill()
            let t = NSAttributedString(string: e.label, attributes: [.font: NSFont.systemFont(ofSize: 10.5), .foregroundColor: Theme.secondaryText])
            t.draw(at: NSPoint(x: x + 18, y: bounds.maxY - 20))
            x += 18 + ceil(t.size().width) + 16
        }
    }

    /// Where a line between two cards leaves one and meets the other.
    private static func clip(from a: NSRect, to b: NSRect) -> (NSPoint, NSPoint) {
        func edgePoint(_ r: NSRect, toward p: NSPoint) -> NSPoint {
            let c = NSPoint(x: r.midX, y: r.midY)
            let dx = p.x - c.x, dy = p.y - c.y
            guard dx != 0 || dy != 0 else { return c }
            let sx = dx == 0 ? .greatestFiniteMagnitude : (r.width / 2 + 3) / abs(dx)
            let sy = dy == 0 ? .greatestFiniteMagnitude : (r.height / 2 + 3) / abs(dy)
            let s = min(sx, sy)
            return NSPoint(x: c.x + dx * s, y: c.y + dy * s)
        }
        return (edgePoint(a, toward: NSPoint(x: b.midX, y: b.midY)), edgePoint(b, toward: NSPoint(x: a.midX, y: a.midY)))
    }

    // MARK: The pointer and keys

    private func node(at p: NSPoint) -> BlockID? {
        guard let model else { return nil }
        // The center is drawn last among equals; test it first.
        if let r = rect(of: model.center), r.contains(p) { return model.center }
        return model.nodes.first { rect(of: $0.id)?.contains(p) ?? false }?.id
    }

    override func updateTrackingAreas() {
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self))
        super.updateTrackingAreas()
    }

    override func mouseMoved(with event: NSEvent) {
        hovered = node(at: convert(event.locationInWindow, from: nil))
        if hovered != nil { NSCursor.pointingHand.set() } else { NSCursor.arrow.set() }
    }

    override func mouseExited(with event: NSEvent) { hovered = nil }

    override func mouseDown(with event: NSEvent) {
        guard let id = node(at: convert(event.locationInWindow, from: nil)) else { return }
        if event.clickCount == 2 || event.modifierFlags.contains(.command) {
            onGo?(id)
        } else if id == model?.center {
            selected = id
        } else {
            selected = id
            onCenter?(id)
        }
    }

    /// Arrow keys: the nearest node in that direction from the selected
    /// one (the center, to begin with).
    func moveSelection(_ keyCode: UInt16) {
        guard let model, let from = positions[selected ?? model.center] else { return }
        var best: (BlockID, CGFloat)?
        for n in model.nodes where n.id != (selected ?? model.center) {
            guard let p = positions[n.id] else { continue }
            let dx = p.x - from.x, dy = p.y - from.y
            let ok: Bool
            switch keyCode {
            case 123: ok = dx < -10 && abs(dy) < abs(dx) * 1.5
            case 124: ok = dx > 10 && abs(dy) < abs(dx) * 1.5
            case 126: ok = dy < -10 && abs(dx) < abs(dy) * 1.5
            default: ok = dy > 10 && abs(dx) < abs(dy) * 1.5
            }
            guard ok else { continue }
            let d = dx * dx + dy * dy
            if best == nil || d < best!.1 { best = (n.id, d) }
        }
        if let best { selected = best.0 }
    }
}
