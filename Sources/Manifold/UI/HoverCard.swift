import AppKit
import ManifoldCore

/// A block's card, shown while the pointer rests on its row: the block
/// itself, live — its own view lent, scaled to the card — when it's out of
/// sight; a picture of its tile when that's on screen (as Safari shows a
/// tab); what it is, where, when it was last seen, and a little of its text.
/// It's drawn in the window it's for, over everything in it, so a view
/// lent to it stays in its window (a terminal's surface keeps drawing).
final class HoverCard: NSObject {
    static let shared = HoverCard()
    private let box = CardView()
    private let picture = NSImageView()
    /// Where a lent view goes: its own size kept, drawn smaller.
    private let liveHolder = NSView()
    private let scaler = NSView()
    private let title = NSTextField(labelWithString: "")
    private let detail = NSTextField(labelWithString: "")
    private let body = NSTextField(wrappingLabelWithString: "")
    /// A block's summary card, under its picture, in place of the title,
    /// detail and text.
    private var summaryCard: SummaryCard?
    private var pendingShow: DispatchWorkItem?

    /// A view lent to the card while it shows, given back when it goes.
    struct LiveLoan {
        let view: NSView
        /// Its own size, kept: the card draws it scaled.
        let size: NSSize
        let giveBack: (NSView) -> Void
    }
    private var loan: LiveLoan?

    private override init() {
        super.init()
        Flat.float(box)
        title.font = UIType.title
        title.textColor = Theme.text
        title.lineBreakMode = .byTruncatingMiddle
        detail.font = .systemFont(ofSize: 11.5)
        detail.textColor = Theme.secondaryText
        detail.lineBreakMode = .byTruncatingMiddle
        body.font = .systemFont(ofSize: 12)
        body.textColor = Theme.text
        body.maximumNumberOfLines = 8
        for v in [picture, liveHolder] {
            v.wantsLayer = true
            v.layer?.cornerRadius = 10
            v.layer?.cornerCurve = .continuous
            v.layer?.maskedCorners = [.layerMinXMaxYCorner, .layerMaxXMaxYCorner]
            v.layer?.masksToBounds = true
            v.isHidden = true
        }
        picture.imageScaling = .scaleProportionallyUpOrDown
        picture.imageAlignment = .alignTop
        liveHolder.themed { $0.layer?.backgroundColor = Theme.windowBackground.cgColor }
        liveHolder.addSubview(scaler)
        for v in [picture, liveHolder, title, detail, body] { box.addSubview(v) }
        box.isHidden = true
        // In the window, it's behind whatever app is in front; still, a
        // lent view goes home the moment Manifold isn't in front.
        NotificationCenter.default.addObserver(forName: NSApplication.didResignActiveNotification, object: nil, queue: .main) { [weak self] _ in
            self?.hide()
        }
    }

    /// A picture of a view as it draws now (an editor, a listing; not a
    /// terminal's Metal surface nor a web page, which give their own).
    static func picture(of view: NSView, evenHidden: Bool = false) -> NSImage? {
        guard view.superview != nil, evenHidden || !view.isHiddenOrHasHiddenAncestor, view.bounds.width > 20, view.bounds.height > 20 else { return nil }
        // A terminal draws into an IOSurface its layer shows (Ghostty's
        // IOSurfaceLayer): the picture is that surface, as it is.
        if let surface = ioSurface(in: view.layer), let cg = halfSize(surface) { return NSImage(cgImage: cg, size: view.bounds.size) }
        // At one pixel a point: a card shows it smaller than the tile, and
        // drawing a quarter of the pixels is that much quicker.
        let w = Int(view.bounds.width), h = Int(view.bounds.height)
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: w, pixelsHigh: h, bitsPerSample: 8, samplesPerPixel: 4,
                                         hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return nil }
        rep.size = view.bounds.size
        view.cacheDisplay(in: view.bounds, to: rep)
        let image = NSImage(size: view.bounds.size)
        image.addRepresentation(rep)
        return image
    }

    /// One context for every surface pictured: making one costs more than
    /// the picture does.
    private static let imaging = CIContext()

    /// A terminal's screen as its surface last held it, on screen or not
    /// (another workspace's, stacked away).
    static func surfacePicture(of view: NSView) -> NSImage? {
        guard view.bounds.width > 20, view.bounds.height > 20, let surface = ioSurface(in: view.layer), let cg = halfSize(surface) else { return nil }
        return NSImage(cgImage: cg, size: view.bounds.size)
    }

    /// A surface read back at half its size (a quarter of the pixels): a
    /// card's picture, smaller than the tile.
    private static func halfSize(_ surface: IOSurface) -> CGImage? {
        let ci = CIImage(ioSurface: surface).transformed(by: CGAffineTransform(scaleX: 0.5, y: 0.5))
        return imaging.createCGImage(ci, from: ci.extent.integral)
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
        var summary: SummaryCardContent?
        /// The block's own view, asked for when the card comes up.
        var lend: (() -> LiveLoan?)?
        var rect: NSRect
        weak var window: NSWindow?
    }
    private var card: Card?

    /// Shows the card beside a rect (in window coordinates) after a moment;
    /// `lend`, asked then, lends the block's own view to show live.
    func show(key: String = "", title: String, detail: String, body: String, font: NSFont?, picture image: NSImage? = nil,
              summary: SummaryCardContent? = nil, lend: (() -> LiveLoan?)? = nil, beside rect: NSRect, in window: NSWindow,
              delay: TimeInterval = 0.45) {
        pendingShow?.cancel()
        // The same block's card, already up: left as it is.
        if card?.key == key, !key.isEmpty, !box.isHidden {
            card?.rect = rect
            return
        }
        giveBack()
        box.isHidden = true
        card = Card(key: key, title: title, detail: detail, body: body, font: font, picture: image, summary: summary, lend: lend, rect: rect, window: window)
        let work = DispatchWorkItem { [weak self] in self?.present() }
        pendingShow = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    /// A picture that arrived after the card was asked for: laid in, if
    /// the card is still that one's.
    func updatePicture(_ image: NSImage?, for key: String) {
        guard var c = card, c.key == key, let image else { return }
        c.picture = image
        card = c
        if !box.isHidden { present() }
    }

    private func present() {
        guard let c = card, let window = c.window, let root = window.contentView else { return }
        // The block itself, live, if it lends its view.
        if loan == nil, let l = c.lend?() {
            loan = l
            l.view.removeFromSuperview()
            l.view.frame = NSRect(origin: .zero, size: l.size)
            l.view.isHidden = false
            scaler.addSubview(l.view)
            // Laid out afresh at the size it's given (one hidden in a stack had none).
            l.view.needsLayout = true
            l.view.layoutSubtreeIfNeeded()
        }
        let image = loan == nil ? c.picture : nil
        // A summary: its card under the picture, the text fields put away.
        summaryCard?.removeFromSuperview()
        summaryCard = nil
        if var s = c.summary {
            // Its own picture only where the card has none above it.
            if image != nil || loan != nil { s.thumbnail = nil }
            let card = SummaryCard(s)
            card.plain = true
            box.addSubview(card)
            summaryCard = card
        }
        let summarized = summaryCard != nil
        title.isHidden = summarized
        title.stringValue = c.title
        detail.stringValue = c.detail
        body.stringValue = c.body
        body.font = c.font ?? .systemFont(ofSize: 12)
        body.isHidden = c.body.isEmpty || image != nil || loan != nil
        // Wide with a picture or the block itself, as Safari's preview of a tab is.
        let width: CGFloat = image == nil && loan == nil ? 320 : 480, pad: CGFloat = 12
        body.preferredMaxLayoutWidth = width - 2 * pad
        let bodyHeight = body.isHidden ? 0 : ceil(body.sizeThatFits(NSSize(width: width - 2 * pad, height: 240)).height)
        // Across the top, as wide as the card, no taller than most of its width.
        var topHeight: CGFloat = 0
        if let l = loan, l.size.width > 0 {
            topHeight = min(width * 0.72, (width * l.size.height / l.size.width).rounded())
        } else if let image, image.size.width > 0 {
            topHeight = min(width * 0.7, (width * image.size.height / image.size.width).rounded())
            picture.image = image
        }
        picture.isHidden = image == nil || loan != nil
        liveHolder.isHidden = loan == nil
        if summarized { body.isHidden = true }
        let cardHeight = summaryCard.map { SummaryCard.height(for: $0.content) } ?? SummaryCard.height
        let height = summarized ? topHeight + cardHeight
            : topHeight + pad + 17 + 2 + (c.detail.isEmpty ? 0 : 16) + (body.isHidden ? 0 : 8 + bodyHeight) + pad
        let top = NSRect(x: 0, y: height - topHeight, width: width, height: topHeight)
        picture.frame = top
        liveHolder.frame = top
        if let l = loan {
            // Scaled to the card's width, its top at the card's top.
            let scale = width / l.size.width
            scaler.frame = NSRect(x: 0, y: topHeight - l.size.height * scale, width: width, height: l.size.height * scale)
            scaler.setBoundsSize(l.size)
        }
        title.frame = NSRect(x: pad, y: height - topHeight - pad - 17, width: width - 2 * pad, height: 17)
        detail.frame = NSRect(x: pad, y: height - topHeight - pad - 17 - 2 - 16, width: width - 2 * pad, height: 16)
        detail.isHidden = c.detail.isEmpty || summarized
        summaryCard?.frame = NSRect(x: 0, y: 0, width: width, height: cardHeight)
        body.frame = NSRect(x: pad, y: pad, width: width - 2 * pad, height: bodyHeight)
        // Beside the row, in the window, kept inside it.
        let rect = root.convert(c.rect, from: nil)
        var origin = NSPoint(x: rect.maxX + 8, y: rect.midY - height / 2)
        origin.y = max(8, min(origin.y, root.bounds.height - height - 8))
        if origin.x + width > root.bounds.width - 8 { origin.x = max(8, rect.minX - width - 8) }
        if box.superview !== root || root.subviews.last !== box { root.addSubview(box, positioned: .above, relativeTo: nil) }
        box.frame = NSRect(origin: origin, size: NSSize(width: width, height: height))
        box.isHidden = false
    }

    /// The lent view home, as it was.
    private func giveBack() {
        guard let l = loan else { return }
        loan = nil
        if l.view.superview === scaler { l.view.removeFromSuperview() }
        l.giveBack(l.view)
    }

    /// Debugging: the card's picture (or what it shows live), written as a PNG.
    func debugWritePicture(to path: String) -> String {
        let image = loan != nil && !box.isHidden ? Self.liveImage(of: liveHolder) : card?.picture
        guard let image, let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:]) else { return "no picture" }
        do { try png.write(to: URL(fileURLWithPath: path)) } catch { return "\(error)" }
        return "wrote \(path)"
    }

    /// The live area as Core Animation draws it (a terminal's surface included).
    private static func liveImage(of view: NSView) -> NSImage? {
        guard let layer = view.layer, let scale = view.window?.backingScaleFactor else { return nil }
        let w = Int(view.bounds.width * scale), h = Int(view.bounds.height * scale)
        guard w > 0, h > 0, let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.scaleBy(x: scale, y: scale)
        view.effectiveAppearance.performAsCurrentDrawingAppearance { layer.render(in: ctx) }
        return ctx.makeImage().map { NSImage(cgImage: $0, size: view.bounds.size) }
    }

    /// Debugging: whether the card is up, its size, and what it holds.
    var debugState: String {
        guard let c = card else { return "hidden" }
        let what = loan.map { "live \(String(describing: type(of: $0.view))) \(Int($0.size.width))x\(Int($0.size.height))" }
            ?? "picture=" + (c.picture.map { "\(Int($0.size.width))x\(Int($0.size.height))" } ?? "none")
        return (box.isHidden ? "held, not shown" : "shown \(Int(box.frame.width))x\(Int(box.frame.height))") + " \(what) title=\(c.title) body=\(c.body.prefix(60).replacingOccurrences(of: "\n", with: "⏎"))"
    }

    func hide() {
        pendingShow?.cancel()
        pendingShow = nil
        card = nil
        box.isHidden = true
        giveBack()
    }
}

/// The card's box: takes no clicks, so the pointer goes through it.
private final class CardView: NSView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}
