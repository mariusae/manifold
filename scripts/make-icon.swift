// Draws the app icon: a manifold — a Klein bottle in its figure-eight
// immersion — as a shaded wire mesh of pale paper on a slate squircle,
// the surface lit from the upper left, its far side showing through
// where the mesh opens.
import AppKit

let size: CGFloat = 1024
let out = CommandLine.arguments[1]

struct V3 { var x, y, z: Double }

/// The figure-eight Klein bottle: a circle swept around a ring, turning
/// over once as it goes, so the surface closes on itself with no inside.
func surface(_ u: Double, _ v: Double) -> V3 {
    let r = 2.4
    let a = r + cos(u / 2) * sin(v) - sin(u / 2) * sin(2 * v)
    return V3(x: a * cos(u), y: a * sin(u), z: sin(u / 2) * sin(v) + cos(u / 2) * sin(2 * v))
}

/// Turned to show its twist: tipped toward the viewer, and a little around.
func rotate(_ p: V3) -> V3 {
    let tilt = -1.05, turn = 0.55
    var x = p.x, y = p.y, z = p.z
    // Around z.
    (x, y) = (x * cos(turn) - y * sin(turn), x * sin(turn) + y * cos(turn))
    // Around x.
    (y, z) = (y * cos(tilt) - z * sin(tilt), y * sin(tilt) + z * cos(tilt))
    return V3(x: x, y: y, z: z)
}

struct Quad {
    var points: [CGPoint]
    var depth: Double
    var shade: Double
    var front: Bool
}

let nu = 72, nv = 28
var quads: [Quad] = []
let center = CGPoint(x: size / 2, y: size / 2 + 10)
let scale: Double = 106
let eye: Double = 14
func project(_ p: V3) -> CGPoint {
    let k = eye / (eye - p.z)
    return CGPoint(x: center.x + CGFloat(p.x * scale * k), y: center.y + CGFloat(p.y * scale * k))
}
let light = V3(x: -0.45, y: 0.6, z: 0.66)
for i in 0..<nu {
    for j in 0..<nv {
        let u0 = Double(i) / Double(nu) * 2 * .pi, u1 = Double(i + 1) / Double(nu) * 2 * .pi
        let v0 = Double(j) / Double(nv) * 2 * .pi, v1 = Double(j + 1) / Double(nv) * 2 * .pi
        let corners = [surface(u0, v0), surface(u1, v0), surface(u1, v1), surface(u0, v1)].map(rotate)
        // The normal, from two edges; lit by how much it faces the light.
        let e1 = V3(x: corners[1].x - corners[0].x, y: corners[1].y - corners[0].y, z: corners[1].z - corners[0].z)
        let e2 = V3(x: corners[3].x - corners[0].x, y: corners[3].y - corners[0].y, z: corners[3].z - corners[0].z)
        var n = V3(x: e1.y * e2.z - e1.z * e2.y, y: e1.z * e2.x - e1.x * e2.z, z: e1.x * e2.y - e1.y * e2.x)
        let len = max(sqrt(n.x * n.x + n.y * n.y + n.z * n.z), 1e-9)
        n = V3(x: n.x / len, y: n.y / len, z: n.z / len)
        // A one-sided surface has no outside: the normal is taken toward the viewer.
        let front = n.z >= 0
        if !front { n = V3(x: -n.x, y: -n.y, z: -n.z) }
        let lit = max(0, n.x * light.x + n.y * light.y + n.z * light.z)
        quads.append(Quad(points: corners.map(project), depth: corners.map(\.z).reduce(0, +) / 4, shade: 0.35 + 0.65 * lit, front: front))
    }
}
quads.sort { $0.depth < $1.depth }

let image = NSImage(size: NSSize(width: size, height: size), flipped: false) { _ in
    let tile = NSRect(x: 100, y: 100, width: 824, height: 824)
    let squircle = NSBezierPath(roundedRect: tile, xRadius: 185, yRadius: 185)
    NSGraphicsContext.current?.saveGraphicsState()
    let shadow = NSShadow()
    shadow.shadowColor = NSColor.black.withAlphaComponent(0.3)
    shadow.shadowBlurRadius = 24
    shadow.shadowOffset = NSSize(width: 0, height: -10)
    shadow.set()
    NSGradient(starting: NSColor(calibratedRed: 0.33, green: 0.39, blue: 0.5, alpha: 1),
               ending: NSColor(calibratedRed: 0.14, green: 0.17, blue: 0.24, alpha: 1))!
        .draw(in: squircle, angle: -90)
    NSGraphicsContext.current?.restoreGraphicsState()

    NSGraphicsContext.current?.saveGraphicsState()
    squircle.addClip()
    // The surface's shadow on the slate.
    let s2 = NSShadow()
    s2.shadowColor = NSColor.black.withAlphaComponent(0.35)
    s2.shadowBlurRadius = 40
    s2.shadowOffset = NSSize(width: 0, height: -18)
    s2.set()
    let whole = NSBezierPath()
    for q in quads {
        whole.move(to: q.points[0])
        for p in q.points.dropFirst() { whole.line(to: p) }
        whole.close()
    }
    NSColor(calibratedWhite: 0.9, alpha: 1).setFill()
    whole.fill()
    NSShadow().set()

    // Each cell of the mesh, far to near: paper lit by its facing, the
    // far side a touch cooler; the mesh lines in slate.
    for q in quads {
        let path = NSBezierPath()
        path.move(to: q.points[0])
        for p in q.points.dropFirst() { path.line(to: p) }
        path.close()
        let s = CGFloat(q.shade)
        let paper = q.front
            ? NSColor(calibratedRed: 0.55 + 0.44 * s, green: 0.53 + 0.44 * s, blue: 0.47 + 0.44 * s, alpha: 1)
            : NSColor(calibratedRed: 0.5 + 0.38 * s, green: 0.52 + 0.38 * s, blue: 0.55 + 0.38 * s, alpha: 1)
        paper.setFill()
        path.fill()
        NSColor(calibratedRed: 0.16, green: 0.2, blue: 0.28, alpha: q.front ? 0.75 : 0.5).setStroke()
        path.lineWidth = q.front ? 2.2 : 1.6
        path.lineJoinStyle = .round
        path.stroke()
    }
    NSGraphicsContext.current?.restoreGraphicsState()
    return true
}
let rep = NSBitmapImageRep(data: image.tiffRepresentation!)!
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: out))
