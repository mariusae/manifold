// Draws the app icon: a manifold, abstracted — a Möbius band as a sheet
// of pale glass, its threads drawn along it in ink — over the wash the
// desk wears (§3.1): lavender to rose to peach to cream across a
// squircle, with a pool of light.
import AppKit

let size: CGFloat = 1024
let out = CommandLine.arguments[1]

struct V3 { var x, y, z: Double }

/// The band: a segment swept around a ring, turning over half a time
/// as it goes, so the sheet comes back to itself with the other face up.
func surface(_ u: Double, _ w: Double) -> V3 {
    let r = 1.9, half = 1.25
    let a = r + half * w * cos(u / 2)
    return V3(x: a * cos(u), y: a * sin(u), z: half * w * sin(u / 2))
}

/// Tipped toward the viewer and turned a little, to show the twist.
func rotate(_ p: V3) -> V3 {
    let tilt = -0.7, turn = 1.3
    var x = p.x, y = p.y, z = p.z
    (x, y) = (x * cos(turn) - y * sin(turn), x * sin(turn) + y * cos(turn))
    (y, z) = (y * cos(tilt) - z * sin(tilt), y * sin(tilt) + z * cos(tilt))
    return V3(x: x, y: y, z: z)
}

/// A strip across the band at one turn of it: the sheet there, and the
/// threads' points along its width.
struct Strip {
    var quad: [CGPoint]
    var threads: [[CGPoint]]
    var depth: Double
    var lit: Double
}

let nu = 180, nw = 5
let center = CGPoint(x: size / 2, y: size / 2 + 10)
let scale: Double = 128
let eye: Double = 15
func project(_ p: V3) -> CGPoint {
    let k = eye / (eye - p.z)
    return CGPoint(x: center.x + CGFloat(p.x * scale * k), y: center.y + CGFloat(p.y * scale * k))
}
let light = V3(x: -0.4, y: 0.55, z: 0.73)

var strips: [Strip] = []
for i in 0..<nu {
    let u0 = Double(i) / Double(nu) * 2 * .pi, u1 = (Double(i) + 1.02) / Double(nu) * 2 * .pi
    let corners = [surface(u0, -1), surface(u1, -1), surface(u1, 1), surface(u0, 1)].map(rotate)
    let e1 = V3(x: corners[1].x - corners[0].x, y: corners[1].y - corners[0].y, z: corners[1].z - corners[0].z)
    let e2 = V3(x: corners[3].x - corners[0].x, y: corners[3].y - corners[0].y, z: corners[3].z - corners[0].z)
    var n = V3(x: e1.y * e2.z - e1.z * e2.y, y: e1.z * e2.x - e1.x * e2.z, z: e1.x * e2.y - e1.y * e2.x)
    let len = max(sqrt(n.x * n.x + n.y * n.y + n.z * n.z), 1e-9)
    n = V3(x: n.x / len, y: n.y / len, z: n.z / len)
    if n.z < 0 { n = V3(x: -n.x, y: -n.y, z: -n.z) }
    let lit = max(0, n.x * light.x + n.y * light.y + n.z * light.z)
    var threads: [[CGPoint]] = []
    for j in 0...nw {
        let w = -1 + 2 * Double(j) / Double(nw)
        threads.append([rotate(surface(u0, w)), rotate(surface(u1, w))].map(project))
    }
    strips.append(Strip(quad: corners.map(project), threads: threads, depth: corners.map(\.z).reduce(0, +) / 4, lit: lit))
}
strips.sort { $0.depth < $1.depth }

let ink = NSColor(calibratedRed: 0.2, green: 0.16, blue: 0.3, alpha: 1)

let image = NSImage(size: NSSize(width: size, height: size), flipped: false) { _ in
    guard let ctx = NSGraphicsContext.current?.cgContext else { return false }
    let tile = NSRect(x: 100, y: 100, width: 824, height: 824)
    let squircle = NSBezierPath(roundedRect: tile, xRadius: 185, yRadius: 185)

    // The wash, as the desk's: lavender, rose, peach, cream, from the
    // upper left; a pool of light toward the lower right.
    NSGraphicsContext.current?.saveGraphicsState()
    let shadow = NSShadow()
    shadow.shadowColor = NSColor.black.withAlphaComponent(0.25)
    shadow.shadowBlurRadius = 24
    shadow.shadowOffset = NSSize(width: 0, height: -10)
    shadow.set()
    NSColor.white.setFill()
    squircle.fill()
    NSGraphicsContext.current?.restoreGraphicsState()

    NSGraphicsContext.current?.saveGraphicsState()
    squircle.addClip()
    let space = CGColorSpaceCreateDeviceRGB()
    let stops: [(CGFloat, CGFloat, CGFloat)] = [(0.72, 0.30, 0.96), (0.95, 0.26, 0.99), (0.07, 0.30, 1.0), (0.12, 0.14, 1.0)]
    let colors = stops.map { h, s, b in NSColor(calibratedHue: h, saturation: s, brightness: b, alpha: 1).cgColor }
    if let g = CGGradient(colorsSpace: space, colors: colors as CFArray, locations: [0, 0.4, 0.75, 1]) {
        ctx.drawLinearGradient(g, start: CGPoint(x: tile.minX, y: tile.maxY), end: CGPoint(x: tile.maxX, y: tile.minY), options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
    }
    if let pool = NSColor(calibratedHue: 0.1, saturation: 0.16, brightness: 1, alpha: 1).usingColorSpace(.deviceRGB),
       let g = CGGradient(colorsSpace: space, colors: [pool.withAlphaComponent(0.7).cgColor, pool.withAlphaComponent(0).cgColor] as CFArray, locations: [0, 1]) {
        let c = CGPoint(x: tile.midX + 170, y: tile.midY - 200)
        ctx.drawRadialGradient(g, startCenter: c, startRadius: 0, endCenter: c, endRadius: 520, options: [])
    }

    // The band's shadow on the wash.
    let s2 = NSShadow()
    s2.shadowColor = ink.withAlphaComponent(0.3)
    s2.shadowBlurRadius = 48
    s2.shadowOffset = NSSize(width: 0, height: -26)
    s2.set()
    let whole = NSBezierPath()
    for st in strips {
        whole.move(to: st.quad[0])
        for p in st.quad.dropFirst() { whole.line(to: p) }
        whole.close()
    }
    whole.windingRule = .nonZero
    NSColor.white.withAlphaComponent(0.01).setFill()
    whole.fill()
    NSShadow().set()

    // The sheet, far to near, a strip at a time: pale glass, whiter
    // where it faces the light, with its threads laid on it in ink —
    // fainter and finer the farther, the edges heavier than the rest.
    for st in strips {
        let near = max(0, min(1, (st.depth + 2.6) / 5.2))
        let path = NSBezierPath()
        path.move(to: st.quad[0])
        for p in st.quad.dropFirst() { path.line(to: p) }
        path.close()
        NSColor(calibratedWhite: 1, alpha: 0.5 + 0.35 * CGFloat(st.lit) * (0.5 + 0.5 * CGFloat(near))).setFill()
        // Filled without antialiasing, so strips meet without a seam.
        ctx.setShouldAntialias(false)
        path.fill()
        ctx.setShouldAntialias(true)
        for (j, t) in st.threads.enumerated() {
            let edge = j == 0 || j == nw
            let line = NSBezierPath()
            line.move(to: t[0])
            line.line(to: t[1])
            line.lineWidth = (edge ? 5 : 2.5) + (edge ? 7 : 4) * CGFloat(near)
            line.lineCapStyle = .round
            ink.withAlphaComponent((edge ? 0.5 : 0.3) + 0.5 * CGFloat(near)).setStroke()
            line.stroke()
        }
    }
    NSGraphicsContext.current?.restoreGraphicsState()
    return true
}
let rep = NSBitmapImageRep(data: image.tiffRepresentation!)!
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: out))
