import AppKit

/// A tile going into a small place — its row in the sidebar, a space's
/// square — and coming back (§3.1): as a tile closed goes, shrunk a little
/// and drifting toward where it's kept as it fades, and the same backwards
/// coming out. (It was the Dock's genie, drawn down a funnel: ceremony,
/// where a nudge toward the row says where it went.)
enum Genie {
    /// One picture of a tile, its parts drawn over its ground.
    static func image(of p: GridView.Pictured, scale: CGFloat) -> CGImage? {
        let whole = p.whole
        guard whole.width >= 1, whole.height >= 1 else { return nil }
        let w = Int((whole.width * scale).rounded()), h = Int((whole.height * scale).rounded())
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue) else { return nil }
        ctx.scaleBy(x: scale, y: scale)
        if let g = p.ground {
            ctx.setFillColor(g)
            ctx.fill(CGRect(origin: .zero, size: whole.size))
        }
        for (r, picture) in p.parts {
            let f = r.offsetBy(dx: -whole.minX, dy: -whole.minY)
            if let picture, CFGetTypeID(picture as CFTypeRef) == CGImage.typeID {
                ctx.draw(picture as! CGImage, in: f)
            } else if let ns = picture as? NSImage, let cg = ns.cgImage(forProposedRect: nil, context: nil, hints: nil) {
                ctx.draw(cg, in: f)
            }
        }
        return ctx.makeImage()
    }

    /// How long: a tile's closing's.
    static var duration: Double { Motion.base * 1.25 }

    /// How far it's got, through the run: at each of `samples + 1` even
    /// steps, how much of the tile (0–1) is past the boundary it was given
    /// — in the sidebar, for its row's title to be built up as it arrives.
    typealias Arrival = [Double]
    static let samples = 36

    /// A tile into its target or out of it, as `run`: tinted as it goes
    /// (`tint`), the way it arrives past `boundary` (an x or y, along the
    /// way it goes) returned; nil if it didn't run.
    /// How many have run (a tile's, into its target or out), for debugging.
    static var runs = 0

    @discardableResult
    static func run(_ p: GridView.Pictured, target: NSRect, restoring: Bool, in host: CALayer, scale: CGFloat,
                    tint: CGColor? = nil, boundary: CGFloat? = nil) -> Arrival? {
        runs += 1
        guard let image = image(of: p, scale: scale) else { return nil }
        return run(image, tile: p.whole, target: target, restoring: restoring, in: host, over: duration, scale: scale, tint: tint, boundary: boundary)
    }

    /// A layer's frame taken through `frames` (its host's terms) at
    /// `times`: its position and its size. `filling`: a sublayer's, filling
    /// its layer as that goes through them.
    private static func keyframes(_ frames: [CGRect], times: [NSNumber]?, easing: CAMediaTimingFunction? = nil,
                                  filling: Bool = false) -> (position: CAKeyframeAnimation, size: CAKeyframeAnimation) {
        let pos = CAKeyframeAnimation(keyPath: "position")
        pos.values = frames.map { NSValue(point: filling ? NSPoint(x: $0.width / 2, y: $0.height / 2) : NSPoint(x: $0.midX, y: $0.midY)) }
        let size = CAKeyframeAnimation(keyPath: "bounds.size")
        size.values = frames.map { NSValue(size: $0.size) }
        for x in [pos, size] {
            x.keyTimes = times
            if let easing { x.timingFunctions = Array(repeating: easing, count: max(0, frames.count - 1)) }
        }
        return (pos, size)
    }

    /// An animation run over `d` from `begin`, held as it starts before
    /// then and as it ends after — its layer taken away by the caller.
    private static func held<A: CAAnimation>(_ a: A, over d: Double, from begin: CFTimeInterval) -> A {
        a.duration = d
        a.beginTime = begin
        a.fillMode = .both
        a.isRemovedOnCompletion = false
        return a
    }

    /// A bar (a tile down to it) flown to `row` — or, `out`, from it: across
    /// as wide as it is, its left edge at the row's, then made the row's
    /// size, becoming on the way what the row shows (`rowPicture`), the
    /// tint over it as it goes; over `host`, over `d`.
    static func fly(_ p: GridView.Pictured, to row: NSRect, out: Bool = false, rowPicture: CGImage? = nil, tint: CGColor? = nil,
                    in host: CALayer, over d: Double, scale: CGFloat) {
        guard let image = image(of: p, scale: scale) else { return }
        flight(p.whole, image, ground: nil, to: row, rowPicture, ground: nil, out: out, tint: tint, fade: true,
               corner: Radius.control, in: host, over: d, scale: scale)
    }

    /// One thing flown into another's place and become it (§3.1) — a bar
    /// into its row, a tile into its card in a switcher: across at its own
    /// size till its corner's at the other's (level with it, if they're
    /// near the same height), then made the other's size, its picture
    /// giving way to the other's on the way. `out`: the same backwards —
    /// the other grown to its size where it is, then across into its
    /// place, becoming it. `fade`: gone at the end (into a row that's
    /// there); else kept as the other till the caller's done. Returns the
    /// layer flying (to be hurried or put away); `done` once it's there.
    @discardableResult
    static func flight(_ a: NSRect, _ aPicture: Any?, ground aGround: CGColor?, to b: NSRect, _ bPicture: Any?, ground bGround: CGColor?,
                       out: Bool = false, tint: CGColor? = nil, fade: Bool = false, corner: CGFloat = Radius.surface,
                       in host: CALayer, over d: Double, delay: Double = 0, scale: CGFloat, done: (() -> Void)? = nil) -> CALayer {
        // Level with it when they're about as tall (a bar, a row); else its
        // top corner at the other's.
        let level = a.height <= b.height * 2
        let landed = NSRect(x: b.minX, y: level ? b.midY - a.height / 2 : b.maxY - a.height, width: a.width, height: a.height)
        func back<T>(_ v: [T]) -> [T] { out ? v.reversed() : v }
        func backTimes(_ t: [Double]) -> [NSNumber] { (out ? t.reversed().map { 1 - $0 } : t).map { NSNumber(value: $0) } }
        let frames = back([a, landed, b])
        let keyTimes = backTimes([0, 0.55, 1])
        let begin = CACurrentMediaTime() + delay * Motion.slowdown
        let l = CALayer()
        l.cornerRadius = corner
        l.cornerCurve = .continuous
        l.masksToBounds = true
        l.zPosition = 45
        l.frame = frames.last!
        l.opacity = fade ? 0 : 1
        let moving = keyframes(frames, times: keyTimes, easing: Motion.flight)
        var parts: [CAAnimation] = [moving.position, moving.size]
        if fade {
            let o = CAKeyframeAnimation(keyPath: "opacity")
            o.values = back([1, 1, 0])
            o.keyTimes = backTimes([0, 0.88, 1])
            parts.append(o)
        }
        let group = held(CAAnimationGroup(), over: d, from: begin)
        group.animations = parts
        // Each picture filling it, the one giving way to the other on the
        // way; the tint over both, deepening as it goes. A picture of
        // another shape filled, not squashed (cut at its edges).
        func layer(_ contents: Any?, _ color: CGColor?, opacity: [Double], at t: [Double], gravity: CALayerContentsGravity) {
            let s = CALayer()
            s.contents = contents
            s.contentsScale = scale
            s.contentsGravity = gravity
            s.backgroundColor = color
            s.masksToBounds = true
            s.anchorPoint = .zero
            s.frame = CGRect(origin: .zero, size: frames.last!.size)
            s.opacity = Float(opacity.last!)
            let o = CAKeyframeAnimation(keyPath: "opacity")
            o.values = back(opacity)
            o.keyTimes = backTimes(t)
            let g = held(CAAnimationGroup(), over: d, from: begin)
            g.animations = [o, keyframes(frames, times: keyTimes, easing: Motion.flight).size]
            l.addSublayer(s)
            s.add(g, forKey: "fly")
        }
        let gravity: CALayerContentsGravity = level ? .resize : .resizeAspectFill
        layer(aPicture, aGround, opacity: bPicture == nil ? [1, 1, 1] : [1, 1, 0], at: [0, 0.35, 0.8], gravity: gravity)
        if let bPicture { layer(bPicture, bGround, opacity: [0, 0, 1], at: [0, 0.35, 0.8], gravity: gravity) }
        if let tint { layer(nil, tint, opacity: [0, 0.18, 0.22], at: [0, 0.5, 1], gravity: .resize) }
        CATransaction.begin()
        CATransaction.setCompletionBlock {
            if fade { l.removeFromSuperlayer() }
            done?()
        }
        host.addSublayer(l)
        l.add(group, forKey: "fly")
        CATransaction.commit()
        // (`d` is slowed already; the delay, given unslowed, isn't.)
        if fade { DispatchQueue.main.asyncAfter(deadline: .now() + d + delay * Motion.slowdown + 0.05) { l.removeFromSuperlayer() } }
        return l
    }

    /// The tile (`tile`, its picture `image`) toward `target` — or,
    /// `restoring`, back from it — over `host` (its terms, y up), over `d`:
    /// shrunk to 94% and drifted a little toward the target as it fades
    /// (as a tile closed is put away), taken away when done. Its arrival
    /// past `boundary`, for a row's words to come as it does: as it fades.
    @discardableResult
    static func run(_ image: CGImage, tile: NSRect, target: NSRect, restoring: Bool, in host: CALayer, over d: Double,
                    scale: CGFloat, tint: CGColor? = nil, boundary: CGFloat? = nil, done: @escaping () -> Void = {}) -> Arrival? {
        guard tile.width > 2, tile.height > 2, target.width > 0, target.height > 0 else { done(); return nil }
        let dx = target.midX - tile.midX, dy = target.midY - tile.midY, length = hypot(dx, dy)
        let k = length > 1 ? min(28, length * 0.1) / length : 0
        let small = tile.insetBy(dx: tile.width * 0.03, dy: tile.height * 0.03).offsetBy(dx: dx * k, dy: dy * k)
        let (from, to) = restoring ? (small, tile) : (tile, small)
        let l = CALayer()
        l.contents = image
        l.contentsScale = scale
        l.contentsGravity = .resize
        l.cornerRadius = Radius.surface
        l.cornerCurve = .continuous
        l.masksToBounds = true
        l.zPosition = 45
        l.frame = to
        l.opacity = restoring ? 1 : 0
        let now = CACurrentMediaTime()
        let moving = keyframes([from, to], times: [0, 1], easing: Motion.travel)
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = restoring ? 0 : 1
        fade.toValue = restoring ? 1 : 0
        fade.timingFunction = restoring ? Motion.appear : Motion.disappear
        CATransaction.begin()
        CATransaction.setCompletionBlock {
            l.removeFromSuperlayer()
            done()
        }
        host.addSublayer(l)
        for x in [moving.position, moving.size, fade] as [CAAnimation] { l.add(held(x, over: d, from: now), forKey: "go." + ((x as? CAPropertyAnimation)?.keyPath ?? "")) }
        CATransaction.commit()
        DispatchQueue.main.asyncAfter(deadline: .now() + d + 0.05) { l.removeFromSuperlayer() }
        guard boundary != nil else { return [] }
        return (0...samples).map { i in let t = Double(i) / Double(samples); return restoring ? 1 - t : t }
    }
}
