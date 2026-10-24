import AppKit
import ManifoldCore

/// What lies under the cards and the sidebar (§3.1): a wash of soft
/// colour, a few blurred pools of pastel light on a pale ground — or, in
/// the dark, deep tints on a near-black one — placed afresh each day by a
/// seed from the date, so no two days' desks are quite the same — and
/// lit by the hour: warmer while the sun is low, cooler when it's high
/// (Daylight), looked at again every few minutes and eased into.
final class BackdropView: NSView {
    /// The light it was last drawn in.
    private(set) var cast = Daylight.Cast.neutral
    /// The clock the light is read from: a debugging hour, or now.
    var clock: Date? { didSet { relight(fade: true) } }
    private var timer: Timer?
    private var wake: NSObjectProtocol?

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
        layerContentsPlacement = .scaleAxesIndependently
        cast = Daylight.cast(at: Date(), from: Daylight.place())
    }

    required init?(coder: NSCoder) { fatalError() }

    deinit {
        timer?.invalidate()
        if let wake { NSWorkspace.shared.notificationCenter.removeObserver(wake) }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        timer?.invalidate()
        timer = nil
        guard window != nil else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 300, repeats: true) { [weak self] _ in self?.relight(fade: true) }
        timer?.tolerance = 30
        if wake == nil {
            wake = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.relight(fade: true) }
            }
        }
        relight(fade: false)
    }

    /// The light looked at again; redrawn if it has moved, cross-faded
    /// over a few seconds so the change is never seen happening.
    func relight(fade: Bool) {
        let now = Daylight.cast(at: clock ?? Date(), from: Daylight.place())
        guard now != cast else { return }
        cast = now
        if fade, let layer {
            let t = CATransition()
            t.type = .fade
            t.duration = 4
            layer.add(t, forKey: "relight")
        }
        needsDisplay = true
    }

    /// A colour in the light: each channel, linearized, taken by the cast.
    private func lit(_ color: NSColor) -> CGColor {
        guard let c = color.usingColorSpace(.deviceRGB) else { return color.cgColor }
        func f(_ v: CGFloat, _ k: Double) -> CGFloat { CGFloat(pow(pow(Double(v), 2.2) * k, 1 / 2.2)) }
        return NSColor(deviceRed: f(c.redComponent, cast.red), green: f(c.greenComponent, cast.green),
                       blue: f(c.blueComponent, cast.blue), alpha: c.alphaComponent).cgColor
    }

    /// Drawn again when its size or the light changes — not at every
    /// frame set (the window lays out often, the size the same) or
    /// appearance passed down: each drawing is a full-window gradient on
    /// the CPU. In a live resize, the last drawing stretched till it ends.
    override func setFrameSize(_ newSize: NSSize) {
        let changed = newSize != frame.size
        super.setFrameSize(newSize)
        if changed, !inLiveResize { needsDisplay = true }
    }

    override func viewDidEndLiveResize() {
        super.viewDidEndLiveResize()
        needsDisplay = true
    }

    private var drawnDark: Bool?

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        if isDark != drawnDark { needsDisplay = true }
    }

    private var isDark: Bool { effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    /// A small deterministic generator, seeded by the day.
    private struct Seeded {
        var state: UInt64
        mutating func next() -> Double {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            return Double(state >> 11) / Double(1 << 53)
        }
    }

    /// Times drawn (debugging).
    static var draws = 0

    override func draw(_ dirtyRect: NSRect) {
        Self.draws += 1
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        let dark = isDark
        drawnDark = dark
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
        let colors = stops.map { h, s, b in lit(NSColor(calibratedHue: (h + turn + 1).truncatingRemainder(dividingBy: 1), saturation: s, brightness: b, alpha: 1)) }
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
            let c = lit(color)
            guard let g = CGGradient(colorsSpace: space, colors: [c.copy(alpha: 0.5)!, c.copy(alpha: 0)!] as CFArray, locations: [0, 1]) else { continue }
            ctx.drawRadialGradient(g, startCenter: center, startRadius: 0, endCenter: center, endRadius: radius, options: [])
        }
    }
}
