import AppKit
import GhosttyKit
import QuartzCore

/// The glow over keystrokes shown before the host has echoed them
/// (`EchoPrediction`), on a link slow enough that the wait shows: a soft
/// light over each such cell, there at once, fading as the host's echo
/// takes its place. A selection copied pulses with it too, around it
/// (`pulse`). Over
/// the terminal's own drawing; clicks go through.
final class PredictionGlow: NSView {
    private var glows: [Int: CALayer] = [:]
    private var pulses: [CALayer] = []

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.masksToBounds = false
    }

    required init?(coder: NSCoder) { fatalError() }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    static let fadeIn: TimeInterval = 0.06, fadeOut: TimeInterval = 0.28

    /// The cells (columns and rows of the screen) glowing now; none, or not
    /// `glow`: all fade.
    func show(_ cells: [(x: Int, y: Int)], glow: Bool, info: ghostty_manifold_info_s) {
        let keep = glow ? Set(cells.map { $0.y << 16 | $0.x }) : []
        for (key, l) in glows where !keep.contains(key) {
            glows[key] = nil
            fade(l, to: 0, over: Self.fadeOut) { l.removeFromSuperlayer() }
        }
        guard glow, let root = layer else { return }
        let dark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        let cw = CGFloat(info.cell_width), ch = CGFloat(info.cell_height)
        for c in cells {
            let key = c.y << 16 | c.x
            // The terminal view isn't flipped: rows counted from the top.
            let rect = CGRect(x: CGFloat(info.pad_left) + CGFloat(c.x) * cw,
                              y: bounds.height - CGFloat(info.pad_top) - CGFloat(c.y + 1) * ch,
                              width: cw, height: ch)
            if let l = glows[key] {
                l.frame = rect
                continue
            }
            let l = Self.glowLayer(rect, dark: dark)
            root.addSublayer(l)
            glows[key] = l
            fade(l, to: 1, over: Self.fadeIn)
        }
    }

    static let pulseIn: TimeInterval = 0.12, pulseOut: TimeInterval = 0.6

    /// Around a selection (rows of cells, the columns from one to past
    /// another) a glow lit at once and fading: a selection just copied.
    /// One shape, the rows joined; the light outside it only (inside, the
    /// highlight stays as it is).
    func pulse(around runs: [(y: Int, from: Int, to: Int)], info: ghostty_manifold_info_s) {
        guard !runs.isEmpty, let root = layer else { return }
        let dark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        let cw = CGFloat(info.cell_width), ch = CGFloat(info.cell_height)
        var shape = CGPath(rect: .null, transform: nil)
        for r in runs {
            var rect = CGRect(x: CGFloat(info.pad_left) + CGFloat(r.from) * cw,
                              y: bounds.height - CGFloat(info.pad_top) - CGFloat(r.y + 1) * ch,
                              width: CGFloat(r.to - r.from) * cw, height: ch)
            // The padding takes its edge cells' color (padding-color =
            // extend), the highlight's too: so out to the view's edges where
            // the selection reaches the grid's, or the glow lights it there.
            if r.from == 0 { rect = CGRect(x: 0, y: rect.minY, width: rect.maxX, height: rect.height) }
            if r.to >= Int(info.cols) { rect.size.width = bounds.width - rect.minX }
            if r.y == 0 { rect.size.height = bounds.height - rect.minY }
            if r.y == Int(info.rows) - 1 { rect = CGRect(x: rect.minX, y: 0, width: rect.width, height: rect.maxY) }
            shape = shape.isEmpty ? CGPath(rect: rect, transform: nil) : shape.union(CGPath(rect: rect, transform: nil))
        }
        let l = Self.style(CALayer(), cellHeight: ch, dark: dark)
        l.frame = bounds
        l.shadowPath = shape
        l.shadowRadius = max(4, ch * 0.45)
        // On light paper, outside the highlight, the tint needs more to show.
        if !dark { l.shadowOpacity = 0.75 }
        l.opacity = 0
        // Outside the selection only: the window, less it.
        let outside = CGMutablePath()
        outside.addRect(bounds.insetBy(dx: -ch * 2, dy: -ch * 2))
        outside.addPath(shape)
        let mask = CAShapeLayer()
        mask.frame = bounds
        mask.path = outside
        mask.fillRule = .evenOdd
        l.mask = mask
        root.addSublayer(l)
        pulses.append(l)
        let a = CAKeyframeAnimation(keyPath: "opacity")
        a.values = [0, 1, 0]
        let total = Self.pulseIn + Self.pulseOut
        a.keyTimes = [0, NSNumber(value: Self.pulseIn / total), 1]
        a.duration = total
        a.timingFunctions = [CAMediaTimingFunction(name: .easeOut), CAMediaTimingFunction(name: .easeIn)]
        CATransaction.begin()
        CATransaction.setCompletionBlock { [weak self] in
            l.removeFromSuperlayer()
            self?.pulses.removeAll { $0 === l }
        }
        l.add(a, forKey: "pulse")
        CATransaction.commit()
    }

    /// A cell's (or a run of cells') round: set in a little from its edges.
    private static func round(_ rect: CGRect, cell: CGFloat) -> CGPath {
        CGPath(roundedRect: rect.insetBy(dx: cell * 0.05, dy: rect.height * 0.12),
               cornerWidth: cell * 0.4, cornerHeight: cell * 0.4, transform: nil)
    }

    /// A cell's light: a blurred round over it — lightening what's under it
    /// on a dark screen, tinting it on a light one.
    private static func glowLayer(_ rect: CGRect, dark: Bool) -> CALayer {
        let l = style(CALayer(), cellHeight: rect.height, dark: dark)
        l.frame = rect
        l.opacity = 0
        l.shadowPath = round(CGRect(origin: .zero, size: rect.size), cell: rect.width)
        return l
    }

    /// The glow's look, on a layer whose shadow is the light.
    private static func style(_ l: CALayer, cellHeight: CGFloat, dark: Bool) -> CALayer {
        l.shadowOffset = .zero
        l.shadowRadius = max(3, cellHeight * 0.3)
        l.shadowOpacity = dark ? 0.9 : 0.35
        l.shadowColor = (dark ? NSColor(srgbRed: 0.45, green: 0.75, blue: 1.0, alpha: 1) : Theme.accent).cgColor
        l.compositingFilter = dark ? "screenBlendMode" : "multiplyBlendMode"
        return l
    }

    /// Debugging: the glows drawn into a snapshot (which draws views, not
    /// their layers), at `r` (this view's place in it) — as Core Animation
    /// does them: each round's blur alone, blended.
    func drawSnapshot(_ ctx: CGContext, in r: CGRect) {
        for l in Array(glows.values) + pulses {
            guard let shape = l.shadowPath, let color = l.shadowColor else { continue }
            ctx.saveGState()
            ctx.setBlendMode(l.compositingFilter as? String == "screenBlendMode" ? .screen : .multiply)
            ctx.setAlpha(CGFloat(l.presentation()?.opacity ?? l.opacity))
            // Masked (a selection's glow: outside it only), as it is on screen.
            if let mask = l.mask as? CAShapeLayer, let p = mask.path {
                var move = CGAffineTransform(translationX: r.minX + l.frame.minX, y: r.minY + l.frame.minY)
                if let moved = p.copy(using: &move) {
                    ctx.addPath(moved)
                    ctx.clip(using: mask.fillRule == .evenOdd ? .evenOdd : .winding)
                }
            }
            // Drawn far off, its shadow back in place: the blur only.
            let far: CGFloat = 100_000
            ctx.setShadow(offset: CGSize(width: far, height: 0), blur: l.shadowRadius * 2, color: color.copy(alpha: CGFloat(l.shadowOpacity)))
            ctx.translateBy(x: r.minX + l.frame.minX - far, y: r.minY + l.frame.minY)
            ctx.addPath(shape)
            ctx.setFillColor(color)
            ctx.fillPath()
            ctx.restoreGState()
        }
    }

    private func fade(_ l: CALayer, to opacity: Float, over duration: TimeInterval, done: (() -> Void)? = nil) {
        CATransaction.begin()
        CATransaction.setCompletionBlock(done)
        let a = CABasicAnimation(keyPath: "opacity")
        a.fromValue = l.presentation()?.opacity ?? l.opacity
        a.toValue = opacity
        a.duration = duration
        a.timingFunction = CAMediaTimingFunction(name: opacity > 0 ? .easeOut : .easeIn)
        l.opacity = opacity
        l.add(a, forKey: "fade")
        CATransaction.commit()
    }
}
