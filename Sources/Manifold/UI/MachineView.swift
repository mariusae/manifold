import AppKit
import ManifoldCore

/// The data's own colors (the machine view, §7.5), apart from the app's
/// tint: a series keeps its color whatever the tint. The first three of a
/// palette checked for telling apart (colorblind too), each stepped for
/// light and dark: blue the first series (busy, in, read, used), orange
/// the second (out, written), aqua the third (cached).
enum MachineInk {
    static let one = NSColor.dynamic(Theme.hex(0x2A78D6), Theme.hex(0x3987E5))
    static let two = NSColor.dynamic(Theme.hex(0xEB6834), Theme.hex(0xD95926))
    static let three = NSColor.dynamic(Theme.hex(0x1BAF7A), Theme.hex(0x199E70))
    static let track = NSColor.dynamic(NSColor(white: 0, alpha: 0.07), NSColor(white: 1, alpha: 0.09))
    static let surface = NSColor.dynamic(NSColor(white: 0, alpha: 0.025), NSColor(white: 1, alpha: 0.035))
    static let grid = NSColor.dynamic(NSColor(white: 0, alpha: 0.07), NSColor(white: 1, alpha: 0.08))
}

/// How the machine's numbers read.
enum MachineWords {
    static func memory(_ n: UInt64) -> String { ByteCountFormatter.string(fromByteCount: Int64(clamping: n), countStyle: .memory) }
    static func size(_ n: UInt64) -> String { ByteCountFormatter.string(fromByteCount: Int64(clamping: n), countStyle: .file) }
    static func rate(_ r: Double) -> String {
        guard r >= 1000 else { return "0 KB/s" }
        return ByteCountFormatter.string(fromByteCount: Int64(r), countStyle: .file) + "/s"
    }
    static func percent(_ f: Double) -> String { "\(Int((f * 100).rounded()))%" }
    static func cpu(_ c: Double) -> String { c < 0.05 ? "–" : c < 10 ? String(format: "%.1f", c) : "\(Int(c.rounded()))" }
    static func uptime(_ s: Double) -> String {
        let m = Int(s) / 60, h = m / 60, d = h / 24
        if d > 0 { return "\(d) d \(h % 24) h" }
        if h > 0 { return "\(h) h \(m % 60) min" }
        return "\(m) min"
    }
    static func ago(_ s: Double) -> String {
        let t = Int(s.rounded())
        return t < 2 ? "now" : t < 60 ? "\(t) s ago" : "\(t / 60):\(String(format: "%02d", t % 60)) ago"
    }
    /// A round number at or above the most: a rate graph's top.
    static func niceTop(_ v: Double, least: Double) -> Double {
        let x = max(v * 1.1, least)
        let p = pow(10, floor(log10(x)))
        for m in [1.0, 2, 2.5, 5, 10] where m * p >= x { return m * p }
        return 10 * p
    }
}

/// The machine's panels (§7.5), drawn: CPU — its last five minutes and
/// each core now —, memory, network, disks and, in a host's card, the
/// processes busiest. Laid out in as many columns as fit; `compact`, a
/// single band of small ones. The pointer over a graph reads it at that
/// moment; over a core, that core.
final class MachinePanels: NSView {
    enum Panel { case cpu, memory, network, disks, top }
    var panels: [Panel] = [.cpu, .memory, .network, .disks] { didSet { needsDisplay = true } }
    var compact = false { didSet { if compact != oldValue { needsDisplay = true } } }
    var sample: MachineSample? { didSet { needsDisplay = true } }
    var history: [MachinePoint] = [] { didSet { needsDisplay = true } }
    /// Said where there's nothing to show yet.
    var waiting = "Reading the machine…" { didSet { needsDisplay = true } }
    var minColumn: CGFloat = 230

    private var hover: NSPoint? { didSet { needsDisplay = true } }
    /// A graph's series, as drawn: its color, its readings, where a reading
    /// goes, and how it reads.
    typealias Series = (color: NSColor, values: [(at: Double, v: Double)], y: (Double) -> CGFloat, say: (Double) -> String)
    /// What the pointer can read, as drawn.
    private struct Readable {
        var rect: NSRect
        var series: [Series]
        var x: (Double) -> CGFloat
        var at: (CGFloat) -> Double
    }
    private var readables: [Readable] = []
    private var cells: [(rect: NSRect, core: Int)] = []

    static let gap: CGFloat = 8
    static let span: Double = 300

    override var isFlipped: Bool { true }

    override func updateTrackingAreas() {
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
        super.updateTrackingAreas()
    }

    override func mouseMoved(with event: NSEvent) { hover = convert(event.locationInWindow, from: nil) }
    override func mouseExited(with event: NSEvent) { hover = nil }
    func debugHover(_ p: NSPoint) { hover = p }

    // MARK: Layout

    private func columns(_ width: CGFloat) -> Int {
        let least: CGFloat = compact ? 140 : minColumn
        return max(1, min(compact ? 4 : 3, Int((width + Self.gap) / (least + Self.gap))))
    }

    /// Each panel's place: CPU across the top (but compact), the rest in
    /// rows under it.
    func frames(width: CGFloat) -> [(Panel, NSRect)] {
        let cols = columns(width)
        let colWidth = (width - CGFloat(cols - 1) * Self.gap) / CGFloat(cols)
        var out: [(Panel, NSRect)] = []
        var y: CGFloat = 0
        var col = 0
        let rowHeight: CGFloat = compact ? 66 : 118
        for p in panels {
            if p == .cpu, !compact {
                if col > 0 { y += rowHeight + Self.gap; col = 0 }
                let h: CGFloat = cols == 1 ? 196 : 140
                out.append((p, NSRect(x: 0, y: y, width: width, height: h)))
                y += h + Self.gap
                continue
            }
            out.append((p, NSRect(x: CGFloat(col) * (colWidth + Self.gap), y: y, width: colWidth, height: rowHeight)))
            col += 1
            if col == cols { col = 0; y += rowHeight + Self.gap }
        }
        // A last row not full: its panels share the whole width.
        if col > 0 {
            let last = out.suffix(col).map(\.0)
            let w = (width - CGFloat(col - 1) * Self.gap) / CGFloat(col)
            out.removeLast(col)
            for (i, p) in last.enumerated() { out.append((p, NSRect(x: CGFloat(i) * (w + Self.gap), y: y, width: w, height: rowHeight))) }
        }
        return out
    }

    func height(for width: CGFloat) -> CGFloat {
        frames(width: width).map(\.1.maxY).max() ?? 0
    }

    // MARK: Drawing

    override func draw(_ dirtyRect: NSRect) {
        readables = []
        cells = []
        guard let s = sample else {
            let a = NSAttributedString(string: waiting, attributes: [.font: UIType.detail, .foregroundColor: Theme.secondaryText])
            let size = a.size()
            a.draw(at: NSPoint(x: (bounds.midX - size.width / 2).rounded(), y: (bounds.midY - size.height / 2).rounded()))
            return
        }
        for (p, r) in frames(width: bounds.width) where r.intersects(dirtyRect) {
            MachineInk.surface.setFill()
            NSBezierPath(roundedRect: r, xRadius: Radius.surface, yRadius: Radius.surface).fill()
            let inner = r.insetBy(dx: 11, dy: 9)
            switch p {
            case .cpu: drawCPU(s, inner)
            case .memory: drawMemory(s, inner)
            case .network: drawNetwork(s, inner)
            case .disks: drawDisks(s, inner)
            case .top: drawTop(s, inner)
            }
        }
        drawHover()
    }

    private var now: Double { sample?.at ?? history.last?.at ?? Date().timeIntervalSince1970 }

    private func say(_ s: String, _ p: NSPoint, font: NSFont = UIType.footnote, color: NSColor = Theme.secondaryText, right: Bool = false, width: CGFloat? = nil) {
        let a = NSAttributedString(string: s, attributes: [.font: font, .foregroundColor: color])
        var x = p.x
        if right { x -= a.size().width }
        if let width {
            let style = NSMutableParagraphStyle()
            style.lineBreakMode = .byTruncatingTail
            let b = NSAttributedString(string: s, attributes: [.font: font, .foregroundColor: color, .paragraphStyle: style])
            b.draw(with: NSRect(x: x, y: p.y, width: width, height: font.pointSize + 5), options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
        } else {
            a.draw(at: NSPoint(x: x, y: p.y))
        }
    }

    /// A panel's head: its name, a line under it, and its number at the right.
    /// Returns where what's under it begins.
    private func head(_ title: String, _ hero: String, detail: String?, in r: NSRect) -> CGFloat {
        let heroFont = NSFont.monospacedDigitSystemFont(ofSize: compact ? 13 : 16, weight: .medium)
        let heroWidth = NSAttributedString(string: hero, attributes: [.font: heroFont]).size().width
        // The name cut short before the number, in a narrow panel.
        say(title.uppercased(), NSPoint(x: r.minX, y: r.minY + 1), font: .systemFont(ofSize: 10, weight: .semibold), color: Theme.secondaryText, width: max(0, r.width - heroWidth - 8))
        say(hero, NSPoint(x: r.maxX, y: r.minY - (compact ? 1 : 3)), font: heroFont, color: Theme.text, right: true)
        guard let detail, !compact else { return r.minY + (compact ? 18 : 20) }
        say(detail, NSPoint(x: r.minX, y: r.minY + 15), font: .systemFont(ofSize: 10.5), color: Theme.tertiaryText, width: r.width)
        return r.minY + 34
    }

    /// A swatch and its words, for a legend; returns where the next goes.
    @discardableResult
    private func key(_ color: NSColor?, _ words: String, at p: NSPoint) -> CGFloat {
        var x = p.x
        if let color {
            color.setFill()
            NSBezierPath(roundedRect: NSRect(x: x, y: p.y + 4, width: 7, height: 7), xRadius: 2, yRadius: 2).fill()
            x += 11
        }
        let a = NSAttributedString(string: words, attributes: [.font: NSFont.monospacedDigitSystemFont(ofSize: 10.5, weight: .regular), .foregroundColor: Theme.secondaryText])
        a.draw(at: NSPoint(x: x, y: p.y))
        return x + a.size().width + 12
    }

    /// History over a span, as a line with a wash under it (or, `down`,
    /// hanging from the top: the lower half of a mirrored graph); runs
    /// broken where readings stopped (the host away).
    private func area(_ values: [(at: Double, v: Double)], in r: NSRect, top: Double, color: NSColor, down: Bool = false) -> Series {
        let x: (Double) -> CGFloat = { [now] at in r.minX + r.width * CGFloat(1 - min(1, max(0, (now - at) / Self.span))) }
        let y: (Double) -> CGFloat = { v in
            let f = CGFloat(min(max(v / max(top, 1e-9), 0), 1))
            return down ? r.minY + r.height * f : r.maxY - r.height * f
        }
        let base = down ? r.minY : r.maxY
        let line = NSBezierPath()
        line.lineWidth = 1.5
        line.lineJoinStyle = .round
        var run: [NSPoint] = []
        func end() {
            guard let first = run.first, let last = run.last else { return }
            let wash = NSBezierPath()
            wash.move(to: NSPoint(x: first.x, y: base))
            for p in run { wash.line(to: p) }
            wash.line(to: NSPoint(x: last.x, y: base))
            wash.close()
            color.withAlphaComponent(0.16).setFill()
            wash.fill()
            line.move(to: first)
            for p in run.dropFirst() { line.line(to: p) }
            run = []
        }
        var previous: Double?
        for p in values where now - p.at <= Self.span + 4 {
            if let previous, p.at - previous > 6 { end() }
            run.append(NSPoint(x: x(p.at), y: y(p.v)))
            previous = p.at
        }
        end()
        color.setStroke()
        line.stroke()
        return (color, values, y, { _ in "" })
    }

    private func readable(_ r: NSRect, _ series: [Series]) {
        let now = self.now
        readables.append(Readable(rect: r, series: series,
                                  x: { at in r.minX + r.width * CGFloat(1 - min(1, max(0, (now - at) / Self.span))) },
                                  at: { x in now - Double((r.maxX - x) / max(r.width, 1)) * Self.span }))
    }

    private func gridLines(_ r: NSRect, _ fractions: [CGFloat]) {
        MachineInk.grid.setFill()
        for f in fractions { NSRect(x: r.minX, y: (r.maxY - r.height * f).rounded() - 0.25, width: r.width, height: 0.5).fill() }
    }

    // MARK: Panels

    private func drawCPU(_ s: MachineSample, _ r: NSRect) {
        var detail = "\(s.processor) · \(s.cores.count) cores"
        if let f = s.frequency { detail += String(format: " · %.1f GHz", f) }
        detail += " · up " + MachineWords.uptime(s.uptime)
        let top = head("CPU", MachineWords.percent(s.now.cpu), detail: detail, in: r)
        let body = NSRect(x: r.minX, y: top, width: r.width, height: r.maxY - top)
        if compact {
            let chart = NSRect(x: body.minX, y: body.minY + 2, width: body.width, height: body.height - 2)
            var e = area(history.map { ($0.at, $0.cpu) }, in: chart, top: 1, color: MachineInk.one)
            e.say = { MachineWords.percent($0) }
            readable(chart, [e])
            return
        }
        // The cores, at the right (or under, if narrow); the graph beside them.
        let n = max(s.cores.count, 1)
        let wide = r.width >= 420
        let gridWidth: CGFloat = wide ? min(r.width * 0.42, max(120, CGFloat(n).squareRoot() * 26)) : r.width
        let gridRect = wide ? NSRect(x: body.maxX - gridWidth, y: body.minY, width: gridWidth, height: body.height - 16)
            : NSRect(x: body.minX, y: body.maxY - 46, width: body.width, height: 46)
        let chart = wide ? NSRect(x: body.minX, y: body.minY + 2, width: body.width - gridWidth - 16, height: body.height - 20)
            : NSRect(x: body.minX, y: body.minY + 2, width: body.width, height: body.height - 46 - 26)
        gridLines(chart, [0, 0.5, 1])
        say("100%", NSPoint(x: chart.minX + 2, y: chart.minY + 1), font: .systemFont(ofSize: 9), color: Theme.tertiaryText)
        var busy = area(history.map { ($0.at, $0.cpu) }, in: chart, top: 1, color: MachineInk.one)
        busy.say = { "busy " + MachineWords.percent($0) }
        let kernel: Series = (MachineInk.one.withAlphaComponent(0.6), history.map { (at: $0.at, v: $0.system) }, busy.y, { "kernel " + MachineWords.percent($0) })
        // The kernel's part: a deeper wash, no line.
        let path = NSBezierPath()
        var started = false
        var lastX: CGFloat = chart.minX
        var firstX: CGFloat = chart.minX
        for p in history where now - p.at <= Self.span {
            let pt = NSPoint(x: chart.minX + chart.width * CGFloat(1 - (now - p.at) / Self.span), y: busy.y(p.system))
            if !started { path.move(to: NSPoint(x: pt.x, y: chart.maxY)); firstX = pt.x; started = true }
            path.line(to: pt)
            lastX = pt.x
        }
        if started {
            path.line(to: NSPoint(x: lastX, y: chart.maxY))
            path.line(to: NSPoint(x: firstX, y: chart.maxY))
            MachineInk.one.withAlphaComponent(0.22).setFill()
            path.fill()
        }
        readable(chart, [busy, kernel])
        let loads = s.loads.map { String(format: $0 >= 100 ? "%.0f" : "%.2f", $0) }.joined(separator: "  ")
        var x = key(nil, "load " + loads, at: NSPoint(x: chart.minX, y: chart.maxY + 4))
        x = key(MachineInk.one, "busy", at: NSPoint(x: x, y: chart.maxY + 4))
        key(MachineInk.one.withAlphaComponent(0.4), "kernel", at: NSPoint(x: x, y: chart.maxY + 4))
        drawCores(s.cores, in: gridRect)
    }

    /// Each core a cell, deeper the busier, in as square a grid as fits.
    private func drawCores(_ cores: [Double], in r: NSRect) {
        let n = cores.count
        guard n > 0, r.width > 10, r.height > 10 else { return }
        let gap: CGFloat = 2
        var best = (cols: n, size: CGFloat(0))
        for cols in 1...n {
            let rows = (n + cols - 1) / cols
            let size = min((r.width - CGFloat(cols - 1) * gap) / CGFloat(cols), (r.height - CGFloat(rows - 1) * gap) / CGFloat(rows))
            if size > best.size { best = (cols, size) }
        }
        let size = min(floor(best.size), 26)
        let cols = best.cols
        let rows = (n + cols - 1) / cols
        let used = NSSize(width: CGFloat(cols) * size + CGFloat(cols - 1) * gap, height: CGFloat(rows) * size + CGFloat(rows - 1) * gap)
        let origin = NSPoint(x: r.maxX - used.width, y: r.minY + (r.height - used.height) / 2)
        let radius = min(3, size / 4)
        for (i, load) in cores.enumerated() {
            let cell = NSRect(x: origin.x + CGFloat(i % cols) * (size + gap), y: origin.y + CGFloat(i / cols) * (size + gap), width: size, height: size)
            MachineInk.track.setFill()
            NSBezierPath(roundedRect: cell, xRadius: radius, yRadius: radius).fill()
            MachineInk.one.withAlphaComponent(0.12 + 0.88 * CGFloat(min(max(load, 0), 1))).setFill()
            if load > 0.005 { NSBezierPath(roundedRect: cell, xRadius: radius, yRadius: radius).fill() }
            cells.append((cell, i))
        }
    }

    private func bar(_ r: NSRect, _ parts: [(Double, NSColor)]) {
        MachineInk.track.setFill()
        NSBezierPath(roundedRect: r, xRadius: min(4, r.height / 2), yRadius: min(4, r.height / 2)).fill()
        var x = r.minX
        for (f, color) in parts where f > 0.002 {
            let w = max(2, r.width * CGFloat(min(f, 1)))
            color.setFill()
            NSBezierPath(roundedRect: NSRect(x: x, y: r.minY, width: min(w, r.maxX - x), height: r.height), xRadius: min(4, r.height / 2), yRadius: min(4, r.height / 2)).fill()
            x += w + 2
            if x >= r.maxX { break }
        }
    }

    private func drawMemory(_ s: MachineSample, _ r: NSRect) {
        let m = s.memory
        let top = head("Memory", MachineWords.percent(m.usedFraction), detail: "\(MachineWords.memory(m.used)) of \(MachineWords.memory(m.total))", in: r)
        let total = Double(max(m.total, 1))
        if compact {
            bar(NSRect(x: r.minX, y: r.maxY - 8, width: r.width, height: 6), [(Double(m.used) / total, MachineInk.one), (Double(m.cached) / total, MachineInk.three)])
            let chart = NSRect(x: r.minX, y: top + 2, width: r.width, height: r.maxY - 8 - 6 - top - 2)
            var e = area(history.map { ($0.at, $0.memory) }, in: chart, top: 1, color: MachineInk.one)
            e.say = { "used " + MachineWords.percent($0) }
            readable(chart, [e])
            return
        }
        bar(NSRect(x: r.minX, y: top, width: r.width, height: 9), [(Double(m.used) / total, MachineInk.one), (Double(m.cached) / total, MachineInk.three)])
        var x = key(MachineInk.one, "used \(MachineWords.memory(m.used))", at: NSPoint(x: r.minX, y: top + 14))
        x = key(MachineInk.three, "cached \(MachineWords.memory(m.cached))", at: NSPoint(x: x, y: top + 14))
        if x + 60 < r.maxX { key(nil, "free \(MachineWords.memory(m.available))", at: NSPoint(x: x - 2, y: top + 14)) }
        var y = top + 32
        if m.swapTotal > 0 {
            say("swap", NSPoint(x: r.minX, y: y - 2), font: .systemFont(ofSize: 10.5), color: Theme.secondaryText)
            let label = "\(MachineWords.memory(m.swapUsed)) of \(MachineWords.memory(m.swapTotal))"
            let lw = NSAttributedString(string: label, attributes: [.font: NSFont.monospacedDigitSystemFont(ofSize: 10.5, weight: .regular)]).size().width
            say(label, NSPoint(x: r.maxX, y: y - 2), font: .monospacedDigitSystemFont(ofSize: 10.5, weight: .regular), right: true)
            bar(NSRect(x: r.minX + 34, y: y + 3, width: max(10, r.width - 34 - lw - 8), height: 5), [(Double(m.swapUsed) / Double(m.swapTotal), MachineInk.one.withAlphaComponent(0.6))])
            y += 16
        }
        let chart = NSRect(x: r.minX, y: y + 4, width: r.width, height: r.maxY - y - 4)
        guard chart.height >= 24 else { return }
        var e = area(history.map { ($0.at, $0.memory) }, in: chart, top: 1, color: MachineInk.one)
        e.say = { "used " + MachineWords.percent($0) }
        readable(chart, [e])
    }

    /// In above the middle, out below it, on one scale.
    private func mirrored(_ r: NSRect, up: [(at: Double, v: Double)], down: [(at: Double, v: Double)], upWord: String, downWord: String) {
        let most = (up + down).filter { now - $0.at <= Self.span }.map(\.v).max() ?? 0
        let top = MachineWords.niceTop(most, least: 10_000)
        let half = (r.height / 2).rounded()
        let upper = NSRect(x: r.minX, y: r.minY, width: r.width, height: half)
        let lower = NSRect(x: r.minX, y: r.minY + half, width: r.width, height: r.height - half)
        MachineInk.grid.setFill()
        NSRect(x: r.minX, y: upper.maxY - 0.25, width: r.width, height: 0.5).fill()
        var a = area(up, in: upper, top: top, color: MachineInk.one)
        var b = area(down, in: lower, top: top, color: MachineInk.two, down: true)
        a.say = { upWord + " " + MachineWords.rate($0) }
        b.say = { downWord + " " + MachineWords.rate($0) }
        say(MachineWords.rate(top), NSPoint(x: r.minX + 2, y: r.minY), font: .systemFont(ofSize: 9), color: Theme.tertiaryText)
        readable(r, [a, b])
    }

    private func drawNetwork(_ s: MachineSample, _ r: NSRect) {
        let top = head("Network", "↓ " + MachineWords.rate(s.now.netIn), detail: "↑ \(MachineWords.rate(s.now.netOut)) · \(MachineWords.size(s.netInTotal)) in, \(MachineWords.size(s.netOutTotal)) out", in: r)
        let chart = NSRect(x: r.minX, y: top + 2, width: r.width, height: r.maxY - top - (compact ? 2 : 18))
        mirrored(chart, up: history.map { ($0.at, $0.netIn) }, down: history.map { ($0.at, $0.netOut) }, upWord: "in", downWord: "out")
        guard !compact else { return }
        let x = key(MachineInk.one, "in", at: NSPoint(x: r.minX, y: r.maxY - 13))
        key(MachineInk.two, "out", at: NSPoint(x: x, y: r.maxY - 13))
    }

    private func drawDisks(_ s: MachineSample, _ r: NSRect) {
        let io = s.now.diskRead + s.now.diskWrite
        let top = head("Disks", MachineWords.rate(io), detail: "read \(MachineWords.rate(s.now.diskRead)) · written \(MachineWords.rate(s.now.diskWrite))", in: r)
        var y = top
        let disks = s.disks.sorted { ($0.mount == "/" ? 0 : 1, $0.mount) < ($1.mount == "/" ? 0 : 1, $1.mount) }
        let rows = compact ? 0 : min(disks.count, max(0, Int((r.maxY - top - 24) / 15)))
        for d in disks.prefix(rows) {
            let name = d.mount == "/" ? "/" : (d.mount as NSString).lastPathComponent
            say(name, NSPoint(x: r.minX, y: y - 1), font: .systemFont(ofSize: 10.5), color: Theme.secondaryText, width: 64)
            let label = "\(MachineWords.size(d.used)) of \(MachineWords.size(d.total))"
            let font = NSFont.monospacedDigitSystemFont(ofSize: 10.5, weight: .regular)
            let lw = NSAttributedString(string: label, attributes: [.font: font]).size().width
            say(label, NSPoint(x: r.maxX, y: y - 1), font: font, right: true)
            bar(NSRect(x: r.minX + 68, y: y + 4, width: max(10, r.width - 68 - lw - 8), height: 5), [(d.usedFraction, MachineInk.one)])
            y += 15
        }
        let chart = NSRect(x: r.minX, y: y + 3, width: r.width, height: r.maxY - y - 3)
        guard chart.height >= 24 else { return }
        mirrored(chart, up: history.map { ($0.at, $0.diskRead) }, down: history.map { ($0.at, $0.diskWrite) }, upWord: "read", downWord: "written")
    }

    private func drawTop(_ s: MachineSample, _ r: NSRect) {
        let top = head("Processes", "\(s.processCount)", detail: nil, in: r)
        let font = NSFont.monospacedDigitSystemFont(ofSize: 10.5, weight: .regular)
        var y = top - 2
        for p in s.processes.prefix(Int((r.maxY - y) / 15)) {
            say(MachineWords.memory(p.memory), NSPoint(x: r.maxX, y: y), font: font, right: true)
            say(MachineWords.cpu(p.cpu) + (p.cpu >= 0.05 ? "%" : ""), NSPoint(x: r.maxX - 64, y: y), font: font, color: Theme.text, right: true)
            say(p.name, NSPoint(x: r.minX, y: y), font: .systemFont(ofSize: 11), color: Theme.text, width: max(0, r.width - 64 - 44))
            y += 15
        }
    }

    // MARK: The pointer

    private func drawHover() {
        guard let h = hover else { return }
        if let c = cells.first(where: { $0.rect.insetBy(dx: -1, dy: -1).contains(h) }), let s = sample, c.core < s.cores.count {
            NSColor.labelColor.withAlphaComponent(0.6).setStroke()
            let ring = NSBezierPath(roundedRect: c.rect.insetBy(dx: -1, dy: -1), xRadius: 3, yRadius: 3)
            ring.lineWidth = 1
            ring.stroke()
            tip(["core \(c.core) · \(MachineWords.percent(s.cores[c.core]))"], over: c.rect)
            return
        }
        guard let r = readables.first(where: { $0.rect.contains(h) }) else { return }
        let at = r.at(h.x)
        // The reading nearest the pointer's moment.
        var lines: [String] = []
        var x: CGFloat?
        for s in r.series {
            guard let p = s.values.min(by: { abs($0.at - at) < abs($1.at - at) }), abs(p.at - at) < 6 else { continue }
            x = x ?? r.x(p.at)
            s.color.setFill()
            let y = s.y(p.v)
            Theme.windowBackground.setFill()
            NSBezierPath(ovalIn: NSRect(x: r.x(p.at) - 4, y: y - 4, width: 8, height: 8)).fill()
            s.color.setFill()
            NSBezierPath(ovalIn: NSRect(x: r.x(p.at) - 3, y: y - 3, width: 6, height: 6)).fill()
            lines.append(s.say(p.v))
        }
        guard let x else { return }
        Theme.secondaryText.withAlphaComponent(0.35).setFill()
        NSRect(x: x - 0.25, y: r.rect.minY, width: 0.5, height: r.rect.height).fill()
        tip([MachineWords.ago(now - at)] + lines, over: NSRect(x: x, y: r.rect.minY, width: 0, height: r.rect.height))
    }

    /// A small label above what it reads, else below it, else beside it
    /// (a short chart has no room over or under), kept inside the view.
    private func tip(_ lines: [String], over a: NSRect) {
        let font = NSFont.monospacedDigitSystemFont(ofSize: 10.5, weight: .medium)
        let text = NSAttributedString(string: lines.joined(separator: "\n"), attributes: [.font: font, .foregroundColor: Theme.text])
        let size = text.size()
        var box = NSRect(x: a.midX - size.width / 2 - 7, y: a.minY - 4 - size.height - 8, width: size.width + 14, height: size.height + 8)
        if box.minY < 2 { box.origin.y = a.maxY + 4 }
        if box.maxY > bounds.height - 2 {
            box.origin.x = a.maxX + 8 + box.width <= bounds.width - 2 ? a.maxX + 8 : a.minX - 8 - box.width
            box.origin.y = a.minY
        }
        box.origin.x = min(max(box.minX, 2), bounds.width - box.width - 2)
        box.origin.y = min(max(box.minY, 2), bounds.height - box.height - 2)
        Theme.panel.setFill()
        let path = NSBezierPath(roundedRect: box, xRadius: Radius.control, yRadius: Radius.control)
        path.fill()
        Theme.panelBorder.setStroke()
        path.lineWidth = 0.5
        path.stroke()
        text.draw(at: NSPoint(x: box.minX + 7, y: box.minY + 4))
    }
}

