import AppKit
import GhosttyKit
import QuartzCore

/// The glow over keystrokes shown before the host has echoed them
/// (`EchoPrediction`), on a link slow enough that the wait shows: a soft
/// light over each such cell, there at once, fading as the host's echo
/// takes its place. Over the terminal's own drawing; clicks go through.
final class PredictionGlow: NSView {
    private var glows: [Int: CALayer] = [:]

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

    /// A cell's light: a blurred round over it — lightening what's under it
    /// on a dark screen, tinting it on a light one.
    private static func glowLayer(_ rect: CGRect, dark: Bool) -> CALayer {
        let l = CALayer()
        l.frame = rect
        l.opacity = 0
        let shape = CGPath(roundedRect: CGRect(origin: .zero, size: rect.size).insetBy(dx: rect.width * 0.05, dy: rect.height * 0.12),
                           cornerWidth: rect.width * 0.4, cornerHeight: rect.width * 0.4, transform: nil)
        l.shadowPath = shape
        l.shadowOffset = .zero
        l.shadowRadius = max(3, rect.height * 0.3)
        l.shadowOpacity = dark ? 0.9 : 0.35
        l.shadowColor = (dark ? NSColor(srgbRed: 0.45, green: 0.75, blue: 1.0, alpha: 1) : Theme.accent).cgColor
        l.compositingFilter = dark ? "screenBlendMode" : "multiplyBlendMode"
        return l
    }

    /// Debugging: the glows drawn into a snapshot (which draws views, not
    /// their layers), at `r` (this view's place in it) — as Core Animation
    /// does them: each round's blur alone, blended.
    func drawSnapshot(_ ctx: CGContext, in r: CGRect) {
        for l in glows.values {
            guard let shape = l.shadowPath, let color = l.shadowColor else { continue }
            ctx.saveGState()
            ctx.setBlendMode(l.compositingFilter as? String == "screenBlendMode" ? .screen : .multiply)
            ctx.setAlpha(CGFloat(l.presentation()?.opacity ?? l.opacity))
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
