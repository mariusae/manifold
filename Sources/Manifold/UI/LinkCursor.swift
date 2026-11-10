import AppKit
import ManifoldCore

/// The pointing hand over what ⌘ marks, with a badge at its lower right
/// saying what it goes to: a page (a globe), a mail, a block, a folder, a
/// file by its kind (code, a picture, a PDF…), a name in code (ƒ). One
/// cursor a badge, made once.
enum LinkCursor {
    private static var made: [String: NSCursor] = [:]

    /// The hand, badged with `symbol` (none: the plain hand).
    static func cursor(_ symbol: String?) -> NSCursor {
        guard let symbol else { return .pointingHand }
        if let c = made[symbol] { return c }
        let hand = NSCursor.pointingHand
        let base = hand.image
        let badge: CGFloat = 14
        // The badge against the hand's lower right — where the hand is drawn
        // in its image, which has room round it — and the image grown to
        // hold it: the hand where it was, the hot spot (from the top left)
        // the same.
        let drawn = visibleBounds(of: base)
        let r = NSRect(x: (drawn.maxX - badge * 0.45).rounded(), y: (drawn.maxY - badge * 0.45).rounded(), width: badge, height: badge)
        let size = NSSize(width: max(base.size.width, r.maxX + 1.5), height: max(base.size.height, r.maxY + 1.5))
        let image = NSImage(size: size, flipped: true) { _ in
            base.draw(in: NSRect(origin: .zero, size: base.size), from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
            NSColor.white.setFill()
            NSBezierPath(ovalIn: r.insetBy(dx: -1, dy: -1)).fill()
            NSColor(white: 0.18, alpha: 1).setFill()
            NSBezierPath(ovalIn: r).fill()
            let config = NSImage.SymbolConfiguration(pointSize: 8, weight: .bold).applying(.init(paletteColors: [.white]))
            if let s = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?.withSymbolConfiguration(config) {
                let z = s.size
                s.draw(in: NSRect(x: r.midX - z.width / 2, y: r.midY - z.height / 2, width: z.width, height: z.height),
                       from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
            }
            return true
        }
        let c = NSCursor(image: image, hotSpot: hand.hotSpot)
        made[symbol] = c
        return c
    }

    /// Where an image has anything drawn, in points from its top left.
    private static func visibleBounds(of image: NSImage) -> NSRect {
        guard let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return NSRect(origin: .zero, size: image.size) }
        let rep = NSBitmapImageRep(cgImage: cg)
        let w = rep.pixelsWide, h = rep.pixelsHigh
        var minX = w, minY = h, maxX = -1, maxY = -1
        for y in 0..<h {
            for x in 0..<w where (rep.colorAt(x: x, y: y)?.alphaComponent ?? 0) > 0.3 {
                minX = min(minX, x); maxX = max(maxX, x); minY = min(minY, y); maxY = max(maxY, y)
            }
        }
        guard maxX >= minX else { return NSRect(origin: .zero, size: image.size) }
        let sx = image.size.width / CGFloat(w), sy = image.size.height / CGFloat(h)
        return NSRect(x: CGFloat(minX) * sx, y: CGFloat(minY) * sy, width: CGFloat(maxX - minX + 1) * sx, height: CGFloat(maxY - minY + 1) * sy)
    }

    /// A code name's badge: somewhere to go to, as the language server says.
    static let symbol = "function"

    /// The badge for a link's target: an address by its scheme (a block's,
    /// its kind's), a folder, a file by its name.
    static func badge(for target: String, isDirectory: Bool?) -> String {
        if target.hasPrefix("manifold:") {
            return BlockID.link(target).flatMap { Drags.symbol?($0.0) } ?? "square.on.square"
        }
        if MainWindowController.isAddress(target) {
            let scheme = URL(string: target)?.scheme?.lowercased() ?? ""
            switch scheme {
            case "http", "https": return "globe"
            case "mailto": return "envelope"
            case "tel": return "phone"
            case "ssh", "sftp": return "server.rack"
            default: return "link"
            }
        }
        if isDirectory == true { return "folder" }
        let path = FileLocation.split(target)?.path ?? target
        return BrowserNode.glyph((path as NSString).lastPathComponent).symbol
    }

    /// Whether a path is a folder: this Mac's, looked at.
    static func isDirectory(_ path: String) -> Bool {
        var dir: ObjCBool = false
        return FileManager.default.fileExists(atPath: (path as NSString).expandingTildeInPath, isDirectory: &dir) && dir.boolValue
    }
}
