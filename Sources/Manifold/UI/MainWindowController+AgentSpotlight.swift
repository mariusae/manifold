import AppKit
import ManifoldCore

extension MainWindowController {
    /// An agent's tile ringed in its colour (`AgentLook.spotlight`), if it's
    /// on screen in the space shown; nil takes the ring away.
    func spotlightAgent(_ id: BlockID?) {
        Self.spotlightRing?.removeFromSuperlayer()
        Self.spotlightRing = nil
        guard let id, let b = hosts.block(id), let color = AgentLook.color(of: b), let a = arrangement,
              let p = a.placements.first(where: { $0.block == id }), let v = views[p.id], v.window != nil,
              !v.isHiddenOrHasHiddenAncestor, let host = root.layer else { return }
        // The tile: its view and the bar over it.
        let r = root.convert(v.bounds, from: v).insetBy(dx: -3, dy: -3)
        let tile = NSRect(x: r.minX, y: r.minY, width: r.width, height: r.height + TileMetrics.strip)
        let ring = CALayer()
        ring.frame = tile
        ring.cornerRadius = Radius.surface + 3
        ring.borderWidth = 2.5
        root.effectiveAppearance.performAsCurrentDrawingAppearance {
            ring.borderColor = color.cgColor
            ring.shadowColor = color.cgColor
        }
        ring.shadowOpacity = 0.6
        ring.shadowRadius = 8
        ring.shadowOffset = .zero
        ring.zPosition = 1000
        host.addSublayer(ring)
        Self.spotlightRing = ring
    }

    nonisolated(unsafe) static var spotlightRing: CALayer?
}
