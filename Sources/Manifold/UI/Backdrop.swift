import AppKit
import ManifoldCore

/// What lies under the cards and the sidebar (§3.1): a wash of soft
/// colour, a few blurred pools of pastel light on a pale ground — or, in
/// the dark, deep tints on a near-black one — placed afresh each day by a
/// seed from the date, so no two days' desks are quite the same — and
/// lit by the hour: warmer while the sun is low, cooler when it's high
/// (Daylight), looked at again every few minutes and eased into. One of
/// the pools is the app's tint.
final class BackdropView: NSView {
    /// The light it was last drawn in.
    private(set) var cast = Daylight.Cast.neutral
    /// The clock the light is read from: a debugging hour, or now.
    var clock: Date? { didSet { relight(fade: true) } }
    private var timer: Timer?
    private var wake: NSObjectProtocol?
    private var tinted: NSObjectProtocol?
    private var themed: NSObjectProtocol?

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
        layerContentsPlacement = .scaleAxesIndependently
        cast = Daylight.cast(at: Date(), from: Daylight.place())
        // The tint changed: its pool drawn again, cross-faded.
        tinted = NotificationCenter.default.addObserver(forName: .manifoldTintChanged, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.redraw(fade: true) }
        }
        // Another theme: its wash, cross-faded.
        themed = NotificationCenter.default.addObserver(forName: .manifoldPaletteChanged, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.redraw(fade: true) }
        }
    }

    required init?(coder: NSCoder) { fatalError() }

    deinit {
        timer?.invalidate()
        if let wake { NSWorkspace.shared.notificationCenter.removeObserver(wake) }
        if let tinted { NotificationCenter.default.removeObserver(tinted) }
        if let themed { NotificationCenter.default.removeObserver(themed) }
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
        redraw(fade: fade, over: 4)
    }

    private func redraw(fade: Bool, over duration: CFTimeInterval = 0.6) {
        if fade, let layer {
            let t = CATransition()
            t.type = .fade
            t.duration = duration
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

    /// A wash's colours, its hues turned by `turn`, before the light.
    static func colors(of wash: Palette.Backdrop.Wash, turn: CGFloat = 0) -> [NSColor] {
        wash.stops.map { h, s, b in NSColor(calibratedHue: (h + turn + 1).truncatingRemainder(dividingBy: 1), saturation: s, brightness: b, alpha: 1) }
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
        // The theme's wash from the upper left to the lower right (Paper's
        // lavender to rose to peach to cream, or in the dark, indigo to
        // plum to umber to near-black), its hues turned a little by the
        // day, and a pool or two of light laid over it.
        let wash = Palette.current.backdrop.wash(dark: dark)
        let turn = CGFloat(r.next() - 0.5) * 0.06
        let stops = wash.stops
        let space = CGColorSpaceCreateDeviceRGB()
        let colors = Self.colors(of: wash, turn: turn).map(lit)
        if let g = CGGradient(colorsSpace: space, colors: colors as CFArray, locations: [0, 0.4, 0.75, 1]) {
            ctx.drawLinearGradient(g, start: CGPoint(x: 0, y: bounds.height), end: CGPoint(x: bounds.width, y: 0), options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
        }
        let w = bounds.width, h = bounds.height
        // The tint's hue and how colored it is (graphite: hardly).
        var tintHue: CGFloat = 0, tintSaturation: CGFloat = 0
        effectiveAppearance.performAsCurrentDrawingAppearance {
            let t = Tints.accent.usingColorSpace(.sRGB) ?? Tints.accent
            var b: CGFloat = 0, a: CGFloat = 0
            t.getHue(&tintHue, saturation: &tintSaturation, brightness: &b, alpha: &a)
        }
        for pool in 0..<2 {
            let hue = (stops[Int(r.next() * 3)].0 + turn + 1).truncatingRemainder(dividingBy: 1)
            // The first pool is the tint's — a little more colored than the
            // wash's own, so it reads as the tint.
            let color: NSColor = pool == 0
                ? NSColor(calibratedHue: tintHue, saturation: wash.tintPool.saturation * tintSaturation, brightness: wash.tintPool.brightness, alpha: 1)
                : NSColor(calibratedHue: hue, saturation: wash.pool.saturation, brightness: wash.pool.brightness, alpha: 1)
            let center = CGPoint(x: CGFloat(r.next()) * w, y: CGFloat(r.next()) * h)
            let radius = max(w, h) * (0.3 + 0.3 * CGFloat(r.next()))
            let c = lit(color)
            guard let g = CGGradient(colorsSpace: space, colors: [c.copy(alpha: 0.5)!, c.copy(alpha: 0)!] as CFArray, locations: [0, 1]) else { continue }
            ctx.drawRadialGradient(g, startCenter: center, startRadius: 0, endCenter: center, endRadius: radius, options: [])
        }
    }
}
