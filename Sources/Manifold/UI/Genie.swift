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

    /// Frames a sublayer through, filling its layer as that goes through `frames`.
    private static func filling(_ frames: [CGRect], times: [NSNumber]?, d: Double, begin: CFTimeInterval) -> [CAAnimation] {
        let pos = CAKeyframeAnimation(keyPath: "position")
        pos.values = frames.map { NSValue(point: NSPoint(x: $0.width / 2, y: $0.height / 2)) }
        let size = CAKeyframeAnimation(keyPath: "bounds.size")
        size.values = frames.map { NSValue(size: $0.size) }
        for x in [pos, size] {
            x.keyTimes = times
            x.duration = d
            x.beginTime = begin
            x.fillMode = .both
            x.isRemovedOnCompletion = false
        }
        return [pos, size]
    }

    /// A bar (a tile down to it) flown to `row` — or, `out`, from it: across
    /// as wide as it is, its left edge at the row's, then made the row's
    /// size, becoming on the way what the row shows (`rowPicture`), the
    /// tint over it as it goes; over `host`, over `d`.
    static func fly(_ p: GridView.Pictured, to row: NSRect, out: Bool = false, rowPicture: CGImage? = nil, tint: CGColor? = nil,
                    in host: CALayer, over d: Double, scale: CGFloat) {
        guard let image = image(of: p, scale: scale) else { return }
        let from = p.whole
        let landed = NSRect(x: row.minX, y: row.midY - from.height / 2, width: from.width, height: from.height)
        // Into the row; out of it, the same backwards.
        var frames = [from, landed, row]
        var times: [Double] = [0, 0.55, 1]
        func back<T>(_ v: [T]) -> [T] { out ? v.reversed() : v }
        func backTimes(_ t: [Double]) -> [NSNumber] { (out ? t.reversed().map { 1 - $0 } : t).map { NSNumber(value: $0) } }
        frames = back(frames)
        let keyTimes = backTimes(times)
        times = []
        let begin = CACurrentMediaTime()
        let ease = CAMediaTimingFunction(name: .easeInEaseOut)
        let l = CALayer()
        l.cornerRadius = Radius.control
        l.masksToBounds = true
        l.zPosition = 45
        l.frame = frames.last!
        l.opacity = 0
        let pos = CAKeyframeAnimation(keyPath: "position")
        pos.values = frames.map { NSValue(point: NSPoint(x: $0.midX, y: $0.midY)) }
        let size = CAKeyframeAnimation(keyPath: "bounds.size")
        size.values = frames.map { NSValue(size: $0.size) }
        for x in [pos, size] { x.keyTimes = keyTimes; x.timingFunctions = [ease, ease] }
        let fade = CAKeyframeAnimation(keyPath: "opacity")
        fade.values = back([1, 1, 0])
        fade.keyTimes = backTimes([0, 0.88, 1])
        let group = CAAnimationGroup()
        group.animations = [pos, size, fade]
        group.duration = d
        group.beginTime = begin
        group.fillMode = .both
        group.isRemovedOnCompletion = false
        // Each picture filling it, the bar giving way to the row's on the
        // way there; the tint over both, deepening as it goes.
        func layer(_ contents: Any?, _ color: CGColor?, opacity: [Double], at t: [Double]) {
            let s = CALayer()
            s.contents = contents
            s.contentsScale = scale
            s.contentsGravity = .resize
            s.backgroundColor = color
            s.anchorPoint = .zero
            s.frame = CGRect(origin: .zero, size: frames.last!.size)
            s.opacity = Float(opacity.last!)
            let o = CAKeyframeAnimation(keyPath: "opacity")
            o.values = back(opacity)
            o.keyTimes = backTimes(t)
            let fill = CAKeyframeAnimation(keyPath: "bounds.size")
            fill.values = frames.map { NSValue(size: $0.size) }
            fill.keyTimes = keyTimes
            fill.timingFunctions = [ease, ease]
            let g = CAAnimationGroup()
            g.animations = [o, fill]
            g.duration = d
            g.beginTime = begin
            g.fillMode = .both
            g.isRemovedOnCompletion = false
            l.addSublayer(s)
            s.add(g, forKey: "fly")
        }
        layer(image, nil, opacity: rowPicture == nil ? [1, 1, 1] : [1, 1, 0], at: [0, 0.35, 0.8])
        if let rowPicture { layer(rowPicture, nil, opacity: [0, 0, 1], at: [0, 0.35, 0.8]) }
        if let tint { layer(nil, tint, opacity: [0, 0.18, 0.22], at: [0, 0.5, 1]) }
        CATransaction.begin()
        CATransaction.setCompletionBlock { l.removeFromSuperlayer() }
        host.addSublayer(l)
        l.add(group, forKey: "fly")
        CATransaction.commit()
        DispatchQueue.main.asyncAfter(deadline: .now() + d + 0.05) { l.removeFromSuperlayer() }
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
            let pos = CAKeyframeAnimation(keyPath: "position")
            pos.values = frames.map { NSValue(point: NSPoint(x: $0.midX, y: $0.midY)) }
            let size = CAKeyframeAnimation(keyPath: "bounds.size")
            size.values = frames.map { NSValue(size: $0.size) }
            // Faded only at the very end of going in (or the very start of
            // coming out), where it's as small as the target.
            let fade = CAKeyframeAnimation(keyPath: "opacity")
            fade.values = restoring ? [0, 1, 1] : [1, 1, 0]
            fade.keyTimes = restoring ? [0, 0.12, 1] : [0, 0.88, 1]
            for x in [pos, size] { x.keyTimes = times }
            for x in [pos, size, fade] as [CAKeyframeAnimation] {
                x.duration = d
                x.beginTime = now
                x.fillMode = .both
                x.isRemovedOnCompletion = false
                x.calculationMode = .linear
                strip.add(x, forKey: "genie." + (x.keyPath ?? ""))
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
                for x in filling(frames, times: times, d: d, begin: now) { t.add(x, forKey: "fill." + ((x as? CAPropertyAnimation)?.keyPath ?? "")) }
                let o = CAKeyframeAnimation(keyPath: "opacity")
                o.values = restoring ? [0.22, 0.22, 0] : [0, 0.16, 0.22]
                o.keyTimes = restoring ? [0, 0.4, 1] : [0, 0.4, 1]
                o.duration = d
                o.beginTime = now
                o.fillMode = .both
                o.isRemovedOnCompletion = false
                t.add(o, forKey: "tint")
            }
        }
        CATransaction.commit()
        // The completion block runs once the animations above end.
        DispatchQueue.main.asyncAfter(deadline: .now() + d + 0.05) { container.removeFromSuperlayer() }
        return line == nil ? [] : arrived
    }
}
