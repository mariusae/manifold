import AppKit

/// A picture standing in for something as it goes or comes (§3.1) — a
/// tile closed or moved away, a tile's content giving way to its summary,
/// a card held till its tile is laid out — and the few ways one is seen
/// to go: faded, swelled or shrunk about its middle.
enum Ghost {
    /// A layer showing `picture` at `frame` (its host's terms) on `ground`,
    /// cut at its edges, `z` over the rest.
    static func layer(_ picture: Any?, at frame: NSRect, ground: CGColor?, z: CGFloat,
                      gravity: CALayerContentsGravity = .resize, scale: CGFloat = 2) -> CALayer {
        let g = CALayer()
        g.contents = picture
        g.contentsGravity = gravity
        g.contentsScale = scale
        g.backgroundColor = ground
        g.frame = frame
        g.masksToBounds = true
        g.zPosition = z
        return g
    }

    /// A picture of `v` as it draws, at `frame` (its own, by default), on
    /// its ground and rounded as it is; nil if it can't be pictured.
    static func picture(of v: NSView, at frame: NSRect? = nil, z: CGFloat, gravity: CALayerContentsGravity = .resize) -> CALayer? {
        guard let picture = GridView.ghostPicture(of: v) else { return nil }
        let g = layer(picture, at: frame ?? v.frame, ground: GridView.ground(of: v), z: z, gravity: gravity, scale: v.backingScale)
        g.cornerRadius = v.layer?.cornerRadius ?? 0
        g.maskedCorners = v.layer?.maskedCorners ?? []
        return g
    }

    /// `l` faded out over `d` (after `delay`, unslowed) and left so; taken
    /// away once it's gone, if `removing`.
    static func fadeOut(_ l: CALayer, over d: Double, delay: Double = 0, timing: CAMediaTimingFunction? = nil,
                        removing: Bool = true, key: String = "fadeOut") {
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 1
        fade.toValue = 0
        fade.duration = d
        fade.timingFunction = timing
        if delay > 0 {
            fade.beginTime = CACurrentMediaTime() + delay
            fade.fillMode = .backwards
        }
        CATransaction.begin()
        // Its own opacity set without an implicit fade over the one here.
        CATransaction.setDisableActions(true)
        if removing { CATransaction.setCompletionBlock { l.removeFromSuperlayer() } }
        l.opacity = 0
        l.add(fade, forKey: key)
        CATransaction.commit()
    }

    /// `l` faded in over `d`, from nothing to as it is.
    static func fadeIn(_ l: CALayer, over d: Double, timing: CAMediaTimingFunction? = nil, key: String = "fadeIn") {
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 0
        fade.toValue = 1
        fade.duration = d
        fade.timingFunction = timing
        l.add(fade, forKey: key)
    }

    /// The transform that scales a layer whose position is `o` by `k`
    /// about the point `c` (both its host's terms), not its own anchor.
    static func scale(_ k: CGFloat, about c: CGPoint, at o: CGPoint) -> CATransform3D {
        CATransform3DScale(CATransform3DMakeTranslation((c.x - o.x) * (1 - k), (c.y - o.y) * (1 - k), 0), k, k, 1)
    }

    /// The rect that holds them all; nil for none.
    static func union(_ rects: [NSRect]) -> NSRect? {
        rects.dropFirst().reduce(rects.first) { $0?.union($1) }
    }

    /// The parts of one thing going, as one: scaled by `k` about the
    /// middle of them all as they fade out over `d` (the fade over `fade`,
    /// if shorter), then taken away. `coming`: the same backwards — from
    /// that size, faded in, to as they are (and kept: a view's own layers).
    static func burst(_ parts: [CALayer], scale k: CGFloat, over d: Double, fade: Double? = nil,
                      fading: CAMediaTimingFunction, moving: CAMediaTimingFunction, coming: Bool = false, key: String) {
        guard let card = union(parts.map(\.frame)) else { return }
        let c = CGPoint(x: card.midX, y: card.midY)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        if !coming { CATransaction.setCompletionBlock { parts.forEach { $0.removeFromSuperlayer() } } }
        for l in parts {
            let f = CABasicAnimation(keyPath: "opacity")
            f.fromValue = coming ? 0 : 1
            f.toValue = coming ? 1 : 0
            f.duration = fade ?? d
            f.timingFunction = fading
            let scaled = scale(k, about: c, at: l.position)
            let move = CABasicAnimation(keyPath: "transform")
            move.fromValue = coming ? scaled : CATransform3DIdentity
            move.toValue = coming ? CATransform3DIdentity : scaled
            move.duration = d
            move.timingFunction = moving
            let g = CAAnimationGroup()
            g.animations = [f, move]
            g.duration = d
            if !coming { l.opacity = 0 }
            l.add(g, forKey: key)
        }
        CATransaction.commit()
    }
}
