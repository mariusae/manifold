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
        let day = Int(Date().timeIntervalSince1970 / 86400)
        var r = Seeded(state: UInt64(day) &* 2654435761 &+ 97)
        // A wash from the upper left to the lower right — lavender to rose
        // to peach to cream, or in the dark, indigo to plum to umber to
        // near-black — its hues turned a little by the day, and a pool or
        // two of light laid over it.
        let turn = CGFloat(r.next() - 0.5) * 0.06
        let stops: [(CGFloat, CGFloat, CGFloat)] = dark
            ? [(0.70, 0.40, 0.26), (0.92, 0.35, 0.24), (0.06, 0.35, 0.22), (0.08, 0.15, 0.12)]
            : [(0.72, 0.28, 0.97), (0.95, 0.24, 0.99), (0.07, 0.28, 1.0), (0.12, 0.14, 1.0)]
        let space = CGColorSpaceCreateDeviceRGB()
        let colors = stops.map { h, s, b in NSColor(calibratedHue: (h + turn + 1).truncatingRemainder(dividingBy: 1), saturation: s, brightness: b, alpha: 1).cgColor }
        if let g = CGGradient(colorsSpace: space, colors: colors as CFArray, locations: [0, 0.4, 0.75, 1]) {
            ctx.drawLinearGradient(g, start: CGPoint(x: 0, y: bounds.height), end: CGPoint(x: bounds.width, y: 0), options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
        }
        let w = bounds.width, h = bounds.height
        for _ in 0..<2 {
            let hue = (stops[Int(r.next() * 3)].0 + turn + 1).truncatingRemainder(dividingBy: 1)
            let color = dark
                ? NSColor(calibratedHue: hue, saturation: 0.5, brightness: 0.4, alpha: 1)
                : NSColor(calibratedHue: hue, saturation: 0.18, brightness: 1, alpha: 1)
            let center = CGPoint(x: CGFloat(r.next()) * w, y: CGFloat(r.next()) * h)
            let radius = max(w, h) * (0.3 + 0.3 * CGFloat(r.next()))
            guard let c = color.usingColorSpace(.deviceRGB),
                  let g = CGGradient(colorsSpace: space, colors: [c.withAlphaComponent(0.5).cgColor, c.withAlphaComponent(0).cgColor] as CFArray, locations: [0, 1]) else { continue }
            ctx.drawRadialGradient(g, startCenter: center, startRadius: 0, endCenter: center, endRadius: radius, options: [])
        }
    }
}
