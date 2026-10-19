import AppKit
import PDFKit
import ManifoldCore

protocol MediaViewDelegate: AnyObject {
    /// The file's bytes, from its host.
    func mediaView(_ view: MediaView, needsBytes done: @escaping (Data?) -> Void)
}

/// The image and PDF lenses (DESIGN.md §7.5): the file as its host has
/// it, read again each time it's shown. Images fit the view and zoom with
/// a pinch or ⌘+/−; PDFs page in PDFKit.
final class MediaView: NSView, PaneContent, KeepsViewState {
    let keeper = ViewStateKeeper()
    let placement: PlacementID
    let block: BlockID
    let kind: Lens
    weak var delegate: MediaViewDelegate?
    var source: () -> Block? = { nil }

    private let header = NSTextField(labelWithString: "")
    private let note = NSTextField(labelWithString: "")
    private let scroll: NSScrollView = {
        let s = NSScrollView()
        s.contentView = CenteringClipView()
        return s
    }()
    private let imageView = NSImageView()
    private var pdfView: PDFView?
    private var loaded = false
    private var fitted = false

    var focusView: NSView { pdfView ?? scroll }
    var isDead: Bool { false }

    init(placement: PlacementID, block: BlockID, kind: Lens) {
        self.placement = placement
        self.block = block
        self.kind = kind
        super.init(frame: .zero)
        wantsLayer = true
        themed { $0.layer?.backgroundColor = Theme.windowBackground.cgColor }
        header.font = .systemFont(ofSize: 12, weight: .medium)
        header.textColor = Theme.secondaryText
        header.lineBreakMode = .byTruncatingMiddle
        note.font = .systemFont(ofSize: 11.5)
        note.textColor = Theme.secondaryText
        note.alignment = .right
        addSubview(header)
        addSubview(note)
        if kind == .pdf {
            let p = PDFView()
            p.autoScales = true
            p.displayMode = .singlePageContinuous
            p.backgroundColor = Theme.windowBackground
            addSubview(p)
            pdfView = p
        } else {
            imageView.imageScaling = .scaleProportionallyUpOrDown
            imageView.imageAlignment = .alignCenter
            scroll.documentView = imageView
            scroll.allowsMagnification = true
            scroll.minMagnification = 0.1
            scroll.maxMagnification = 16
            scroll.hasVerticalScroller = true
            scroll.hasHorizontalScroller = true
            scroll.autohidesScrollers = true
            scroll.drawsBackground = false
            addSubview(scroll)
            scroll.watchScrolling { [weak self] x, y in
                guard let self, self.keeper.restored else { return }
                self.keeper.note(["scrollX": "\(x)", "scroll": "\(y)", "zoom": "\(self.scroll.magnification)"])
            }
        }
        if let p = pdfView {
            NotificationCenter.default.addObserver(forName: .PDFViewPageChanged, object: p, queue: .main) { [weak self] _ in
                guard let self, let doc = p.document, let page = p.currentPage else { return }
                self.keeper.note(["page": "\(doc.index(for: page))"])
            }
            NotificationCenter.default.addObserver(forName: .PDFViewScaleChanged, object: p, queue: .main) { [weak self] _ in
                self?.keeper.note(["zoom": "\(p.scaleFactor)", "autoscale": p.autoScales ? "1" : "0"])
            }
        }
    }

    required init?(coder: NSCoder) { fatalError() }

    func destroy() { keeper.flush() }

    /// Back as it was: the zoom and place in an image, the page of a PDF.
    private func restoreState() {
        guard !keeper.restored else { return }
        keeper.restored = true
        if let p = pdfView, let doc = p.document {
            if keeper.value("autoscale") == "0", let z = keeper.double("zoom") {
                p.autoScales = false
                p.scaleFactor = z
            }
            if let i = keeper.int("page"), let page = doc.page(at: i) { p.go(to: page) }
        } else if let z = keeper.double("zoom") {
            fitted = true
            scroll.magnification = z
            let x = keeper.double("scrollX") ?? 0, y = keeper.double("scroll") ?? 0
            DispatchQueue.main.async { [weak self] in self?.scroll.scrollTo(x: x, y: y) }
        }
    }

    override func layout() {
        super.layout()
        header.frame = NSRect(x: 12, y: bounds.height - 24, width: bounds.width * 0.6, height: 16)
        note.frame = NSRect(x: bounds.width * 0.6 + 12, y: bounds.height - 24, width: bounds.width * 0.4 - 24, height: 16)
        let content = NSRect(x: 0, y: 0, width: bounds.width, height: bounds.height - 32)
        pdfView?.frame = content
        scroll.frame = content
        if !fitted { fit() }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil { load() }
    }

    func documentChanged() {
        guard let b = source() else { return }
        header.stringValue = (b.path ?? "").abbreviatingHome
    }

    private func load() {
        guard let b = source(), b.path != nil else { return }
        note.stringValue = loaded ? note.stringValue : "Reading…"
        delegate?.mediaView(self) { [weak self] data in
            guard let self else { return }
            guard let data else {
                self.note.stringValue = "Couldn't read it"
                return
            }
            self.loaded = true
            if let pdfView = self.pdfView {
                let doc = PDFDocument(data: data)
                pdfView.document = doc
                self.note.stringValue = doc.map { "\($0.pageCount) page\($0.pageCount == 1 ? "" : "s")" } ?? "Not a PDF"
                self.restoreState()
            } else if let image = NSImage(data: data) {
                self.imageView.image = image
                let size = image.representations.first.map { NSSize(width: $0.pixelsWide, height: $0.pixelsHigh) } ?? image.size
                self.imageView.frame = NSRect(origin: .zero, size: size.width > 0 ? size : image.size)
                self.note.stringValue = "\(Int(size.width)) × \(Int(size.height))"
                self.fitted = false
                self.needsLayout = true
                self.layoutSubtreeIfNeeded()
                self.restoreState()
            } else {
                self.note.stringValue = "Not an image"
            }
        }
    }

    /// The whole image in view.
    private func fit() {
        guard pdfView == nil, let image = imageView.image, scroll.contentSize.width > 0 else { return }
        let size = imageView.frame.size
        guard size.width > 0, size.height > 0 else { return }
        let scale = min(scroll.contentSize.width / size.width, scroll.contentSize.height / size.height, 1)
        scroll.magnification = scale
        scroll.contentView.scroll(to: NSPoint(x: 0, y: 0))
        fitted = true
        _ = image
    }

    @objc func increaseFontSize(_ sender: Any?) { scroll.magnification *= 1.25 }
    @objc func decreaseFontSize(_ sender: Any?) { scroll.magnification /= 1.25 }
    @objc func resetFontSize(_ sender: Any?) { fitted = false; fit() }

    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 2, pdfView == nil {
            // Double-click: actual size, or back to fitting.
            if abs(scroll.magnification - 1) < 0.01 { fitted = false; fit() } else { scroll.magnification = 1 }
        }
        super.mouseDown(with: event)
    }
}

/// A clip view that keeps a document smaller than itself in the middle.
final class CenteringClipView: NSClipView {
    override func constrainBoundsRect(_ proposed: NSRect) -> NSRect {
        var r = super.constrainBoundsRect(proposed)
        guard let doc = documentView else { return r }
        let d = doc.frame
        if d.width < r.width { r.origin.x = d.minX - (r.width - d.width) / 2 }
        if d.height < r.height { r.origin.y = d.minY - (r.height - d.height) / 2 }
        return r
    }
}
