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

    /// The tile (`tile`, its picture `image`) into `target` — or, `restoring`,
    /// out of it — over `host` (its terms, y up), over `d`. The strips are
    /// taken away when it's done.
    /// How long: the Dock's own, about half a second.
    static var duration: Double { Motion.spatial * 2.2 }

    /// A tile into its target or out of it, as `run`; true if it ran.
    @discardableResult
    static func run(_ p: GridView.Pictured, target: NSRect, restoring: Bool, in host: CALayer, scale: CGFloat) -> Bool {
        guard let image = image(of: p, scale: scale) else { return false }
        run(image, tile: p.whole, target: target, restoring: restoring, in: host, over: duration, scale: scale)
        return true
    }

    static func run(_ image: CGImage, tile: NSRect, target: NSRect, restoring: Bool, in host: CALayer, over d: Double,
                    scale: CGFloat, done: @escaping () -> Void = {}) {
        guard tile.width > 2, tile.height > 2, target.width > 0, target.height > 0 else { return done() }
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
        let samples = 36
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
        }
        CATransaction.commit()
        // The completion block runs once the animations above end.
        DispatchQueue.main.asyncAfter(deadline: .now() + d + 0.05) { container.removeFromSuperlayer() }
    }
}
