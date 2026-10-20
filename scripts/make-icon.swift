// Draws the app icon from its SVG (Resources/Icons/manifold-m.svg): a
// gradient M, its strokes a graph's edges and its ends three nodes, on a
// dark squircle. Rendered by WebKit, which draws SVG whole — its blurs
// (the glow, the shadow beneath) as well as its gradients, masks and
// clips — at 1024 points square, transparent around the squircle.
//
//   swift scripts/make-icon.swift <icon.svg> <out.png>
import AppKit
import WebKit

let args = CommandLine.arguments
guard args.count == 3 else {
    FileHandle.standardError.write(Data("usage: make-icon.swift <icon.svg> <out.png>\n".utf8))
    exit(2)
}
let size: CGFloat = 1024
let svg = try String(contentsOfFile: args[1], encoding: .utf8)

_ = NSApplication.shared
let web = WKWebView(frame: NSRect(x: 0, y: 0, width: size, height: size))
web.setValue(false, forKey: "drawsBackground")

final class Loaded: NSObject, WKNavigationDelegate {
    var done = false
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { done = true }
}
let loaded = Loaded()
web.navigationDelegate = loaded
// The SVG filling the page, whatever size it says it is.
let page = """
    <html><head><style>
    html, body { margin: 0; background: transparent; }
    svg { display: block; width: \(Int(size))px; height: \(Int(size))px; }
    </style></head><body>\(svg)</body></html>
    """
web.loadHTMLString(page, baseURL: nil)
while !loaded.done { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
// A moment for the blurs to be drawn.
RunLoop.main.run(until: Date().addingTimeInterval(0.3))

let config = WKSnapshotConfiguration()
config.rect = NSRect(x: 0, y: 0, width: size, height: size)
config.snapshotWidth = NSNumber(value: Double(size))
config.afterScreenUpdates = true
var snapshot: NSImage?
var failure: Error?
web.takeSnapshot(with: config) { image, error in
    snapshot = image
    failure = error
}
while snapshot == nil && failure == nil { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
guard let image = snapshot else {
    FileHandle.standardError.write(Data("make-icon: couldn't draw \(args[1]): \(failure.map { "\($0)" } ?? "?")\n".utf8))
    exit(1)
}

let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size), pixelsHigh: Int(size), bitsPerSample: 8,
                           samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                           bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
image.draw(in: NSRect(x: 0, y: 0, width: size, height: size))
NSGraphicsContext.restoreGraphicsState()
try rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: args[2]))
