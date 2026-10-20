import AppKit

/// What lies under the cards and the sidebar (§3.1): a wash of soft
/// colour, a few blurred pools of pastel light on a pale ground — or, in
/// the dark, deep tints on a near-black one — placed afresh each day by a
/// seed from the date, so no two days' desks are quite the same.
final class BackdropView: NSView {
    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
    }

    required init?(coder: NSCoder) { fatalError() }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        needsDisplay = true
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    /// A small deterministic generator, seeded by the day.
    private struct Seeded {
        var state: UInt64
        mutating func next() -> Double {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            return Double(state >> 11) / Double(1 << 53)
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        let dark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        let ground = dark ? NSColor(calibratedWhite: 0.11, alpha: 1) : NSColor(calibratedRed: 0.975, green: 0.965, blue: 0.96, alpha: 1)
        ground.setFill()
        bounds.fill()
        let day = Int(Date().timeIntervalSince1970 / 86400)
        var r = Seeded(state: UInt64(day) &* 2654435761 &+ 97)
        // Hues of the wash: rose, peach, lavender, a cool blue, a mint — a
        // few of them, each a pool somewhere, larger than the gaps between.
        let hues: [CGFloat] = [0.95, 0.07, 0.72, 0.58, 0.42]
        let space = CGColorSpaceCreateDeviceRGB()
        let w = bounds.width, h = bounds.height
        let pools = 4 + Int(r.next() * 2)
        for i in 0..<pools {
            let hue = hues[(i + Int(r.next() * Double(hues.count))) % hues.count]
            let color = dark
                ? NSColor(calibratedHue: hue, saturation: 0.45, brightness: 0.32, alpha: 1)
                : NSColor(calibratedHue: hue, saturation: 0.22, brightness: 1, alpha: 1)
            let center = CGPoint(x: CGFloat(r.next()) * w, y: CGFloat(r.next()) * h)
            let radius = max(w, h) * (0.35 + 0.35 * CGFloat(r.next()))
            let strength: CGFloat = dark ? 0.55 : 0.6
            guard let c = color.usingColorSpace(.deviceRGB),
                  let gradient = CGGradient(colorsSpace: space, colors: [c.withAlphaComponent(strength).cgColor, c.withAlphaComponent(0).cgColor] as CFArray, locations: [0, 1]) else { continue }
            ctx.drawRadialGradient(gradient, startCenter: center, startRadius: 0, endCenter: center, endRadius: radius, options: [])
        }
    }
}
