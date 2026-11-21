import AppKit
import ManifoldCore

extension MainWindowController {
    /// An agent's tile ringed in its colour (`AgentLook.spotlight`), if it's
    /// on screen in the space shown; nil takes the ring away.
    func spotlightAgent(_ id: BlockID?) {
        guard let id, let a = arrangement, let p = a.placements.first(where: { $0.block == id }) else { spotlightTile(nil); return }
        spotlightTile(p.id)
    }

    /// A tile ringed — an agent's in its colour, the rest in the accent —
    /// if it's on screen in the space shown and open (not docked, not down
    /// to its bar); nil takes the ring away. Whether it was.
    @discardableResult
    func spotlightTile(_ placement: PlacementID?) -> Bool {
        Self.spotlightPending?.cancel()
        Self.spotlightPending = nil
        Self.spotlightRing?.removeFromSuperlayer()
        Self.spotlightRing = nil
        guard let placement, let a = arrangement, let p = a.placement(placement), a.locate(placement) != nil,
              !a.docked.contains(where: { $0.placement.id == placement }),
              let v = views[p.id], v.window != nil, !v.isHiddenOrHasHiddenAncestor, v.bounds.height > 1,
              let host = stage.layer else { return false }
        let color = hosts.block(p.block).flatMap(AgentLook.color(of:)) ?? Tints.accent
        // The tile: its view and the bar over it.
        // In the tiles' own layer, not the window's: the sidebar slid out
        // over them is over it too.
        let r = stage.convert(v.bounds, from: v).insetBy(dx: -3, dy: -3)
        let tile = NSRect(x: r.minX, y: r.minY, width: r.width, height: r.height + TileMetrics.strip)
        let ring = CALayer()
        ring.frame = tile
        ring.cornerRadius = Radius.surface + 3
        ring.borderWidth = 2.5
        root.effectiveAppearance.performAsCurrentDrawingAppearance {
            ring.borderColor = color.cgColor
        }
        ring.zPosition = 1000
        // After the pointer has rested a moment, as a card waits (running
        // down the sidebar flashed rings across the grid); a plain ring.
        let show = DispatchWorkItem {
            host.addSublayer(ring)
            Self.spotlightRing = ring
        }
        Self.spotlightPending = show
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.45, execute: show)
        return true
    }

    nonisolated(unsafe) static var spotlightRing: CALayer?
    nonisolated(unsafe) static var spotlightPending: DispatchWorkItem?
}
