import AppKit

/// The genie (§3.1), as the Dock's minimize: a tile going into a small
/// place — its row in the sidebar, a space's square — is drawn down a
/// funnel into it, and one coming back pours out of it. The tile's picture
/// is cut into thin strips across the way it goes; each strip slides
/// along that way and is as tall (or wide) as the funnel where it is: the
/// tile's own span far from the target, the target's at it, a smooth step
/// between. The funnel first bends into the tile's near edge, then the
/// strips pour down it, the nearest first.
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

    /// How long: the Dock's own, about half a second.
    static var duration: Double { Motion.spatial * 2.2 }

    /// How far it's got, through the run: at each of `samples + 1` even
    /// steps, how much of the tile (0–1) is past the boundary it was given
    /// — in the sidebar, for its row's title to be built up as it arrives.
    typealias Arrival = [Double]
    static let samples = 36

    /// A tile into its target or out of it, as `run`: tinted as it goes
    /// (`tint`), the way it arrives past `boundary` (an x or y, along the
    /// way it goes) returned; nil if it didn't run.
    @discardableResult
    static func run(_ p: GridView.Pictured, target: NSRect, restoring: Bool, in host: CALayer, scale: CGFloat,
                    tint: CGColor? = nil, boundary: CGFloat? = nil) -> Arrival? {
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

    /// The tile (`tile`, its picture `image`) into `target` — or, `restoring`,
    /// out of it — over `host` (its terms, y up), over `d`. The strips are
    /// taken away when it's done.
    @discardableResult
    static func run(_ image: CGImage, tile: NSRect, target: NSRect, restoring: Bool, in host: CALayer, over d: Double,
                    scale: CGFloat, tint: CGColor? = nil, boundary: CGFloat? = nil, done: @escaping () -> Void = {}) -> Arrival? {
        guard tile.width > 2, tile.height > 2, target.width > 0, target.height > 0 else { done(); return nil }
        // Along x when the target is more to the side than above or below.
        let alongX = abs(target.midX - tile.midX) >= abs(target.midY - tile.midY)
        // In the way's terms, the target below: `a` along, `c` across.
        let flip = alongX ? target.midX > tile.midX : target.midY > tile.midY
        func a(_ r: NSRect) -> (CGFloat, CGFloat) {
            let lo = alongX ? r.minX : r.minY, hi = alongX ? r.maxX : r.maxY
            return flip ? (-hi, -lo) : (lo, hi)
        }
        func c(_ r: NSRect) -> (CGFloat, CGFloat) { alongX ? (r.minY, r.maxY) : (r.minX, r.maxX) }
        let (sa0, sa1) = a(tile), (ta0, ta1) = a(target)
        let (sc0, sc1) = c(tile), (tc0, tc1) = c(target)
        let length = sa1 - sa0
        let n = Int(min(200, max(40, length / 2.5)))
        let samples = Self.samples
        // Past the boundary, in the way's terms.
        let line: CGFloat? = boundary.map { flip ? -$0 : $0 }
        var arrived = [Double](repeating: 0, count: samples + 1)
        // The funnel's mouth: at the tile's near edge, then moving into it
        // as it bends (the first part), so the tile's near end narrows
        // before anything moves.
        let bend = 0.3
        func smooth(_ t: CGFloat) -> CGFloat { let t = min(max(t, 0), 1); return t * t * (3 - 2 * t) }
        func ease(_ t: CGFloat) -> CGFloat {
            let t = min(max(t, 0), 1)
            return t < 0.5 ? 4 * t * t * t : 1 - pow(-2 * t + 2, 3) / 2
        }
        func funnel(_ at: CGFloat, _ p: CGFloat) -> (CGFloat, CGFloat) {
            let mouth = sa0 + length * 0.55 * smooth(p / bend)
            let from = min(ta1, mouth - 1)
            let t = smooth((at - from) / max(mouth - from, 1))
            return (tc0 + (sc0 - tc0) * t, tc1 + (sc1 - tc1) * t)
        }
        // An edge (0, the near end; 1, the far) at `p`: the near ones first.
        let lag: CGFloat = 0.55
        func edge(_ u: CGFloat, _ p: CGFloat) -> CGFloat {
            let q = (p - bend * 0.5) / (1 - bend * 0.5) * (1 + lag) - lag * u
            let s = ease(q)
            return (sa0 + u * length) + ((ta0 + u * (ta1 - ta0)) - (sa0 + u * length)) * s
        }
        func rect(_ lo: CGFloat, _ hi: CGFloat, _ c0: CGFloat, _ c1: CGFloat) -> CGRect {
            let x0 = flip ? -hi : lo, x1 = flip ? -lo : hi
            let r = alongX ? CGRect(x: x0, y: c0, width: x1 - x0, height: c1 - c0) : CGRect(x: c0, y: x0, width: c1 - c0, height: x1 - x0)
            // A hair over the next, for no seam between them.
            return alongX ? r.insetBy(dx: -0.35, dy: 0) : r.insetBy(dx: 0, dy: -0.35)
        }

        let now = CACurrentMediaTime()
        let container = CALayer()
        container.frame = host.bounds
        container.zPosition = 45
        host.addSublayer(container)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        CATransaction.setCompletionBlock {
            container.removeFromSuperlayer()
            done()
        }
        let times = (0...samples).map { NSNumber(value: Double($0) / Double(samples)) }
        for i in 0..<n {
            let u0 = CGFloat(i) / CGFloat(n), u1 = CGFloat(i + 1) / CGFloat(n)
            var frames: [CGRect] = []
            for k in 0...samples {
                var p = CGFloat(k) / CGFloat(samples)
                if restoring { p = 1 - p }
                let lo = edge(u0, p), hi = edge(u1, p)
                let (c0, c1) = funnel((lo + hi) / 2, p)
                frames.append(rect(lo, hi, c0, c1))
                if let line, (lo + hi) / 2 <= line { arrived[k] += 1 / Double(n) }
            }
            let strip = CALayer()
            strip.contents = image
            strip.contentsScale = scale
            strip.contentsGravity = .resize
            // The strip's part of the picture (its unit square, y up): from
            // the near end — the right or the top, flipped.
            let f0 = flip ? 1 - u1 : u0, f1 = flip ? 1 - u0 : u1
            strip.contentsRect = alongX ? CGRect(x: f0, y: 0, width: f1 - f0, height: 1) : CGRect(x: 0, y: f0, width: 1, height: f1 - f0)
            strip.frame = frames.last!
            strip.opacity = restoring ? 1 : 0
            container.addSublayer(strip)
            let moving = keyframes(frames, times: times)
            // Faded only at the very end of going in (or the very start of
            // coming out), where it's as small as the target.
            let fade = CAKeyframeAnimation(keyPath: "opacity")
            fade.values = restoring ? [0, 1, 1] : [1, 1, 0]
            fade.keyTimes = restoring ? [0, 0.12, 1] : [0, 0.88, 1]
            for x in [moving.position, moving.size, fade] {
                x.calculationMode = .linear
                strip.add(held(x, over: d, from: now), forKey: "genie." + (x.keyPath ?? ""))
            }
            // The tint over it, deepening as it goes in (lifting as it
            // comes out): the tile marked, as its row is, going there.
            if let tint {
                let t = CALayer()
                t.backgroundColor = tint
                t.anchorPoint = CGPoint(x: 0.5, y: 0.5)
                t.frame = CGRect(origin: .zero, size: frames.last!.size)
                t.opacity = restoring ? 0 : 0.22
                strip.addSublayer(t)
                let filling = keyframes(frames, times: times, filling: true)
                for x in [filling.position, filling.size] { t.add(held(x, over: d, from: now), forKey: "fill." + (x.keyPath ?? "")) }
                let o = CAKeyframeAnimation(keyPath: "opacity")
                o.values = restoring ? [0.22, 0.22, 0] : [0, 0.16, 0.22]
                o.keyTimes = [0, 0.4, 1]
                t.add(held(o, over: d, from: now), forKey: "tint")
            }
        }
        CATransaction.commit()
        // The completion block runs once the animations above end.
        DispatchQueue.main.asyncAfter(deadline: .now() + d + 0.05) { container.removeFromSuperlayer() }
        return line == nil ? [] : arrived
    }
}
