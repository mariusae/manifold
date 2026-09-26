// Draws the app icon: panes of light "paper" fanned on a slate squircle,
// the front one a terminal.
import AppKit

let size: CGFloat = 1024
let out = CommandLine.arguments[1]
let image = NSImage(size: NSSize(width: size, height: size), flipped: false) { _ in
    let tile = NSRect(x: 100, y: 100, width: 824, height: 824)
    let squircle = NSBezierPath(roundedRect: tile, xRadius: 185, yRadius: 185)
    NSGraphicsContext.current?.saveGraphicsState()
    let shadow = NSShadow()
    shadow.shadowColor = NSColor.black.withAlphaComponent(0.3)
    shadow.shadowBlurRadius = 24
    shadow.shadowOffset = NSSize(width: 0, height: -10)
    shadow.set()
    NSGradient(starting: NSColor(calibratedRed: 0.36, green: 0.42, blue: 0.52, alpha: 1),
               ending: NSColor(calibratedRed: 0.17, green: 0.2, blue: 0.27, alpha: 1))!
        .draw(in: squircle, angle: -90)
    NSGraphicsContext.current?.restoreGraphicsState()

    // Two panes behind, one in front.
    for (i, alpha) in [(2, 0.55), (1, 0.8)] {
        let d = CGFloat(i) * 52
        let r = NSRect(x: 230 + d, y: 250 + d, width: 520, height: 420)
        NSColor(calibratedWhite: 0.97, alpha: alpha).setFill()
        NSBezierPath(roundedRect: r, xRadius: 36, yRadius: 36).fill()
    }
    let front = NSRect(x: 230, y: 250, width: 520, height: 420)
    NSGraphicsContext.current?.saveGraphicsState()
    let s2 = NSShadow()
    s2.shadowColor = NSColor.black.withAlphaComponent(0.35)
    s2.shadowBlurRadius = 30
    s2.shadowOffset = NSSize(width: 0, height: -12)
    s2.set()
    NSColor(calibratedWhite: 0.99, alpha: 1).setFill()
    NSBezierPath(roundedRect: front, xRadius: 36, yRadius: 36).fill()
    NSGraphicsContext.current?.restoreGraphicsState()

    // A prompt and a cursor.
    let prompt = NSAttributedString(string: ">", attributes: [
        .font: NSFont(name: "Menlo-Bold", size: 150)!,
        .foregroundColor: NSColor(calibratedRed: 0.2, green: 0.45, blue: 0.95, alpha: 1),
    ])
    prompt.draw(at: NSPoint(x: 290, y: 430))
    NSColor(calibratedWhite: 0.25, alpha: 1).setFill()
    NSRect(x: 400, y: 460, width: 80, height: 18).fill()
    return true
}
let rep = NSBitmapImageRep(data: image.tiffRepresentation!)!
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: out))
