import AppKit
import ManifoldCore

/// A block's card, shown while the pointer rests on its row: a picture
/// of its tile when one is on screen (as Safari shows a tab), what it
/// is, where, when it was last seen, and a little of its text.
final class HoverCard: NSObject {
    static let shared = HoverCard()
    private let panel: NSPanel
    private let box = NSView()
    private let picture = NSImageView()
    private let title = NSTextField(labelWithString: "")
    private let detail = NSTextField(labelWithString: "")
    private let body = NSTextField(wrappingLabelWithString: "")
    private var pendingShow: DispatchWorkItem?

    private override init() {
        panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 320, height: 100), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        super.init()
        panel.hasShadow = true
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.isFloatingPanel = true
        panel.level = .popUpMenu
        panel.ignoresMouseEvents = true
        box.wantsLayer = true
        box.layer?.cornerRadius = 10
        box.layer?.borderWidth = 0.5
        box.themed {
            $0.layer?.backgroundColor = Theme.panel.cgColor
            $0.layer?.borderColor = Theme.panelBorder.cgColor
        }
        title.font = .systemFont(ofSize: 13, weight: .semibold)
        title.textColor = Theme.text
        title.lineBreakMode = .byTruncatingMiddle
        detail.font = .systemFont(ofSize: 11.5)
        detail.textColor = Theme.secondaryText
        detail.lineBreakMode = .byTruncatingMiddle
        body.font = .systemFont(ofSize: 12)
        body.textColor = Theme.text
        body.maximumNumberOfLines = 8
        picture.imageScaling = .scaleProportionallyUpOrDown
        picture.imageAlignment = .alignTop
        picture.wantsLayer = true
        picture.layer?.cornerRadius = 10
        picture.layer?.maskedCorners = [.layerMinXMaxYCorner, .layerMaxXMaxYCorner]
        picture.layer?.masksToBounds = true
        picture.isHidden = true
        for v in [picture, title, detail, body] { box.addSubview(v) }
        panel.contentView = box
    }

    /// A picture of a view as it draws now (an editor, a listing; not a
    /// terminal's Metal surface nor a web page, which give their own).
    static func picture(of view: NSView) -> NSImage? {
        guard view.superview != nil, !view.isHiddenOrHasHiddenAncestor, view.bounds.width > 20, view.bounds.height > 20 else { return nil }
        // A terminal draws into an IOSurface its layer shows (Ghostty's
        // IOSurfaceLayer): the picture is that surface, as it is.
        if let surface = ioSurface(in: view.layer) {
            let ci = CIImage(ioSurface: surface)
            if let cg = CIContext().createCGImage(ci, from: ci.extent) { return NSImage(cgImage: cg, size: view.bounds.size) }
        }
        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return nil }
        view.cacheDisplay(in: view.bounds, to: rep)
        let image = NSImage(size: view.bounds.size)
        image.addRepresentation(rep)
        return image
    }

    private static func ioSurface(in layer: CALayer?) -> IOSurface? {
        guard let layer else { return nil }
        if let c = layer.contents, CFGetTypeID(c as CFTypeRef) == IOSurfaceGetTypeID() { return (c as! IOSurface) }
        for sub in layer.sublayers ?? [] { if let s = ioSurface(in: sub) { return s } }
        return nil
    }

    /// What the card shows, kept so a picture that arrives late (a web
    /// page's snapshot) can be laid in.
    private struct Card {
        var key: String
        var title: String
        var detail: String
        var body: String
        var font: NSFont?
        var picture: NSImage?
        var rect: NSRect
        weak var window: NSWindow?
    }
    private var card: Card?

    /// Shows the card beside a rect (in window coordinates) after a moment.
    func show(key: String = "", title: String, detail: String, body: String, font: NSFont?, picture image: NSImage? = nil, beside rect: NSRect, in window: NSWindow) {
        pendingShow?.cancel()
        card = Card(key: key, title: title, detail: detail, body: body, font: font, picture: image, rect: rect, window: window)
        let work = DispatchWorkItem { [weak self] in self?.present() }
        pendingShow = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.45, execute: work)
    }

    /// A picture that arrived after the card was asked for: laid in, if
    /// the card is still that one's.
    func updatePicture(_ image: NSImage?, for key: String) {
        guard var c = card, c.key == key, let image else { return }
        c.picture = image
        card = c
        if panel.isVisible { present() }
    }

    private func present() {
        guard let c = card, let window = c.window else { return }
        let image = c.picture
        title.stringValue = c.title
        detail.stringValue = c.detail
        body.stringValue = c.body
        body.font = c.font ?? .systemFont(ofSize: 12)
        body.isHidden = c.body.isEmpty || image != nil
        // Wide with a picture, as Safari's preview of a tab is.
        let width: CGFloat = image == nil ? 320 : 440, pad: CGFloat = 12
        body.preferredMaxLayoutWidth = width - 2 * pad
        let bodyHeight = body.isHidden ? 0 : ceil(body.sizeThatFits(NSSize(width: width - 2 * pad, height: 240)).height)
        // The picture across the top, as wide as the card, no taller than it is wide.
        var pictureHeight: CGFloat = 0
        if let image, image.size.width > 0 {
            pictureHeight = min(width * 0.7, (width * image.size.height / image.size.width).rounded())
            picture.image = image
        }
        picture.isHidden = image == nil
        let height = pictureHeight + pad + 17 + 2 + (c.detail.isEmpty ? 0 : 16) + (body.isHidden ? 0 : 8 + bodyHeight) + pad
        picture.frame = NSRect(x: 0, y: height - pictureHeight, width: width, height: pictureHeight)
        title.frame = NSRect(x: pad, y: height - pictureHeight - pad - 17, width: width - 2 * pad, height: 17)
        detail.frame = NSRect(x: pad, y: height - pictureHeight - pad - 17 - 2 - 16, width: width - 2 * pad, height: 16)
        detail.isHidden = c.detail.isEmpty
        body.frame = NSRect(x: pad, y: pad, width: width - 2 * pad, height: bodyHeight)
        let rect = c.rect
        var origin = window.convertToScreen(NSRect(origin: NSPoint(x: rect.maxX + 8, y: rect.midY), size: .zero)).origin
        origin.y -= height / 2
        if let screen = window.screen {
            origin.y = max(screen.visibleFrame.minY + 8, min(origin.y, screen.visibleFrame.maxY - height - 8))
            if origin.x + width > screen.visibleFrame.maxX { origin.x = window.convertToScreen(NSRect(origin: NSPoint(x: rect.minX, y: 0), size: .zero)).origin.x - width - 8 }
        }
        panel.setFrame(NSRect(origin: origin, size: NSSize(width: width, height: height)), display: true)
        panel.orderFront(nil)
    }

    /// Debugging: the card's picture, written as a PNG.
    func debugWritePicture(to path: String) -> String {
        guard let image = card?.picture, let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:]) else { return "no picture" }
        do { try png.write(to: URL(fileURLWithPath: path)) } catch { return "\(error)" }
        return "wrote \(path)"
    }

    /// Debugging: whether the card is up, its size, and what it holds.
    var debugState: String {
        guard panel.isVisible, let c = card else { return "hidden" }
        return "shown \(Int(panel.frame.width))x\(Int(panel.frame.height)) picture=\(c.picture.map { "\(Int($0.size.width))x\(Int($0.size.height))" } ?? "none") title=\(c.title) body=\(c.body.prefix(60).replacingOccurrences(of: "\n", with: "⏎"))"
    }

    func hide() {
        pendingShow?.cancel()
        pendingShow = nil
        card = nil
        panel.orderOut(nil)
    }
}
