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

    /// The wash, and the pools over it: gradients Core Animation draws on
    /// the GPU, at any size — drawn here on the CPU, a full-window gradient
    /// at the screen's resolution and depth took half a second, and was
    /// drawn again at every size change that wasn't a live resize (a zoom,
    /// full screen, a display), every theme or tint, every change of light.
    private let wash = CAGradientLayer()
    private let pools = [CAGradientLayer(), CAGradientLayer()]
    /// Each pool's centre and radius, as fractions of the view (its centre
    /// across and up; its radius of the longer side).
    private var poolPlaces: [(x: CGFloat, y: CGFloat, r: CGFloat)] = []

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        // From the upper left to the lower right (y up).
        wash.startPoint = CGPoint(x: 0, y: 1)
        wash.endPoint = CGPoint(x: 1, y: 0)
        wash.locations = [0, 0.4, 0.75, 1]
        layer?.addSublayer(wash)
        for p in pools {
            p.type = .radial
            p.locations = [0, 1]
            layer?.addSublayer(p)
        }
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
        shade()
    }

    /// A colour in the light: each channel, linearized, taken by the cast.
    private func lit(_ color: NSColor) -> CGColor {
        guard let c = color.usingColorSpace(.deviceRGB) else { return color.cgColor }
        func f(_ v: CGFloat, _ k: Double) -> CGFloat { CGFloat(pow(pow(Double(v), 2.2) * k, 1 / 2.2)) }
        return NSColor(deviceRed: f(c.redComponent, cast.red), green: f(c.greenComponent, cast.green),
                       blue: f(c.blueComponent, cast.blue), alpha: c.alphaComponent).cgColor
    }

    /// Its gradients fill it, the pools kept round, as its size changes:
    /// placed, not drawn.
    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        place()
    }

    private func place() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        wash.frame = bounds
        let w = max(bounds.width, 1), h = max(bounds.height, 1), long = max(w, h)
        for (p, at) in zip(pools, poolPlaces) {
            p.frame = bounds
            p.startPoint = CGPoint(x: at.x, y: at.y)
            p.endPoint = CGPoint(x: at.x + at.r * long / w, y: at.y + at.r * long / h)
        }
        CATransaction.commit()
    }

    private var drawnDark: Bool?

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        if isDark != drawnDark { shade() }
    }

    override func viewDidMoveToSuperview() {
        super.viewDidMoveToSuperview()
        if drawnDark == nil { shade() }
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

    /// Times shaded (debugging).
    static var draws = 0

    /// Its colours made again (the theme, the day, the light, the tint, the
    /// appearance), and given to its gradients.
    private func shade() {
        Self.draws += 1
        let dark = isDark
        drawnDark = dark
        let day = Int(Date().timeIntervalSince1970 / 86400)
        var r = Seeded(state: UInt64(day) &* 2654435761 &+ 97)
        // The theme's wash from the upper left to the lower right (Paper's
        // lavender to rose to peach to cream, or in the dark, indigo to
        // plum to umber to near-black), its hues turned a little by the
        // day, and a pool or two of light laid over it.
        let wash = Palette.current.backdrop.wash(dark: dark)
        var places: [(x: CGFloat, y: CGFloat, r: CGFloat)] = []
        defer { poolPlaces = places; place() }
        let turn = CGFloat(r.next() - 0.5) * 0.06
        let stops = wash.stops
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        self.wash.colors = Self.colors(of: wash, turn: turn).map(lit)
        // The tint's hue and how colored it is (graphite: hardly).
        var tintHue: CGFloat = 0, tintSaturation: CGFloat = 0
        effectiveAppearance.performAsCurrentDrawingAppearance {
            let t = Tints.accent.usingColorSpace(.sRGB) ?? Tints.accent
            var b: CGFloat = 0, a: CGFloat = 0
            t.getHue(&tintHue, saturation: &tintSaturation, brightness: &b, alpha: &a)
        }
        for (pool, layer) in pools.enumerated() {
            let hue = (stops[Int(r.next() * 3)].0 + turn + 1).truncatingRemainder(dividingBy: 1)
            // The first pool is the tint's — a little more colored than the
            // wash's own, so it reads as the tint.
            let color: NSColor = pool == 0
                ? NSColor(calibratedHue: tintHue, saturation: wash.tintPool.saturation * tintSaturation, brightness: wash.tintPool.brightness, alpha: 1)
                : NSColor(calibratedHue: hue, saturation: wash.pool.saturation, brightness: wash.pool.brightness, alpha: 1)
            places.append((CGFloat(r.next()), CGFloat(r.next()), 0.3 + 0.3 * CGFloat(r.next())))
            let c = lit(color)
            layer.colors = [c.copy(alpha: 0.5)!, c.copy(alpha: 0)!]
        }
    }
}
