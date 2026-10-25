import AppKit
import PDFKit
import ManifoldCore

protocol MediaViewDelegate: AnyObject {
    /// The file's bytes, from its host.
    func mediaView(_ view: MediaView, needsBytes done: @escaping (Data?) -> Void)
}

/// The image and PDF lenses (DESIGN.md §7.5): the file as its host has
/// it, read again each time it's shown. Images fit the view and zoom with
/// a pinch or ⌘+/−; PDFs page in PDFKit, as Preview shows them: the page
/// and how many, back and forward, the zoom, how pages are laid out, ⌘F
/// to find, and a sidebar of the contents and the pages.
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
        let s = ClippingScrollView()
        s.contentView = CenteringClipView()
        return s
    }()
    private let imageView = NSImageView()
    private var pdfView: PDFView?
    private var loaded = false
    private var fitted = false
    fileprivate var pdfDocument: PDFDocument? { pdfView?.document }
    fileprivate var pdfSelectionText: String? { pdfView?.currentSelection?.string }
    fileprivate var shownImage: NSImage? { pdfView == nil ? imageView.image : nil }

    // A PDF's controls, along the top (see the extension below).
    fileprivate let previousButton = IconButton(symbol: "chevron.left", size: 11, target: nil, action: nil)
    fileprivate let nextButton = IconButton(symbol: "chevron.right", size: 11, target: nil, action: nil)
    fileprivate let pageBox = FlatFieldBox(symbol: nil, clears: false, fontSize: 11.5)
    fileprivate var pageField: FlatField { pageBox.field }
    fileprivate let pageCount = NSTextField(labelWithString: "")
    fileprivate let zoomOutButton = IconButton(symbol: "minus.magnifyingglass", size: 12, weight: .regular, target: nil, action: nil)
    fileprivate let zoomInButton = IconButton(symbol: "plus.magnifyingglass", size: 12, weight: .regular, target: nil, action: nil)
    fileprivate let zoomLabel = NSTextField(labelWithString: "")
    fileprivate let layoutButton = IconButton(symbol: "doc.on.doc", size: 11, weight: .regular, target: nil, action: nil)
    fileprivate var sidebar: TileSidebar?
    fileprivate var sidebarRestored = false
    /// The table of contents, flattened: each entry's item and its page.
    fileprivate var contents: [(item: PDFOutline, page: Int?)] = []
    /// A PDF's table of contents, the entry whose page shows marked: as
    /// ticks at the tile's upper right, and in the sidebar at its left.
    private lazy var contentsOutline: Outline = {
        let o = Outline()
        o.onPick = { [weak self] i in
            guard let self, self.contents.indices.contains(i), let d = self.contents[i].item.destination else { return }
            NavJumps.willJump?(self)
            self.pdfView?.go(to: d)
            self.contentsOutline.current = i
            self.window?.makeFirstResponder(self.pdfView)
        }
        o.menuFor = { [weak self] i in
            guard let self, self.contents.indices.contains(i), let page = self.contents[i].page else { return nil }
            return Drags.linkMenu("Copy Link to This Page", self.block, "page=\(page + 1)")
        }
        o.block = block
        o.placeFor = { [weak self] i in
            guard let self, self.contents.indices.contains(i), let page = self.contents[i].page else { return nil }
            return "page=\(page + 1)"
        }
        return o
    }()
    fileprivate lazy var finder: FindHost = {
        let f = FindHost(view: self, target: self)
        // Below the controls, over the pages.
        f.area = { [weak self] in self?.pdfView?.frame ?? .zero }
        return f
    }()
    fileprivate var found: [PDFSelection] = []
    fileprivate var foundAt = 0

    var focusView: NSView { pdfView ?? scroll }
    var isDead: Bool { false }

    init(placement: PlacementID, block: BlockID, kind: Lens) {
        self.placement = placement
        self.block = block
        self.kind = kind
        super.init(frame: .zero)
        wantsLayer = true
        themed { $0.layer?.backgroundColor = Theme.windowBackground.cgColor }
        header.font = UIType.label
        header.textColor = Theme.secondaryText
        header.lineBreakMode = .byTruncatingMiddle
        note.font = UIType.detail
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
            NotificationCenter.default.addObserver(forName: .PDFViewSelectionChanged, object: p, queue: .main) { [weak self] _ in
                guard let self, self.pdfView?.currentSelection?.string?.isEmpty == false else { return }
                NotificationCenter.default.post(name: .manifoldSelectionMade, object: self)
            }
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
                self.pageChanged()
            }
            NotificationCenter.default.addObserver(forName: .PDFViewScaleChanged, object: p, queue: .main) { [weak self] _ in
                self?.keeper.note(["zoom": "\(p.scaleFactor)", "autoscale": p.autoScales ? "1" : "0"])
                self?.scaleChanged()
            }
            makeControls()
        }
    }

    required init?(coder: NSCoder) { fatalError() }

    func destroy() { keeper.flush() }

    /// Back as it was: the zoom and place in an image, the page of a PDF.
    private func restoreState() {
        guard !keeper.restored else { return }
        keeper.restored = true
        if let p = pdfView, let doc = p.document {
            if let m = keeper.int("display").flatMap(PDFDisplayMode.init(rawValue:)) { p.displayMode = m }
            if keeper.value("book") == "1" { p.displaysAsBook = true }
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
        var content = NSRect(x: 0, y: 0, width: bounds.width, height: bounds.height - Self.barHeight)
        if pdfView != nil {
            layoutControls()
            if !sidebarRestored {
                sidebarRestored = true
                if keeper.value("outline") == "1" { setSidebar(true) }
            }
            if let sidebar, !sidebar.isHidden {
                let w = min(TileSidebar.width, (bounds.width / 3).rounded())
                sidebar.frame = NSRect(x: 0, y: 0, width: w, height: content.height)
                content.origin.x = w
                content.size.width -= w
            }
        } else {
            header.frame = NSRect(x: 12, y: bounds.height - 24, width: bounds.width * 0.6, height: 16)
            note.frame = NSRect(x: bounds.width * 0.6 + 12, y: bounds.height - 24, width: bounds.width * 0.4 - 24, height: 16)
        }
        pdfView?.frame = content
        scroll.frame = content
        if pdfView != nil { finder.layout(in: content) }
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
                self.note.stringValue = doc == nil ? "Not a PDF" : ""
                self.restoreState()
                self.documentLoaded()
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

    @objc func increaseFontSize(_ sender: Any?) { if let p = pdfView { p.zoomIn(nil) } else { scroll.magnification *= 1.25 } }
    @objc func decreaseFontSize(_ sender: Any?) { if let p = pdfView { p.zoomOut(nil) } else { scroll.magnification /= 1.25 } }
    @objc func resetFontSize(_ sender: Any?) { if let p = pdfView { p.autoScales = true } else { fitted = false; fit() } }

    /// An image dragged out of its tile: its file (here), else the picture,
    /// for the Finder, Mail, a note.
    override func mouseDragged(with event: NSEvent) {
        guard pdfView == nil, let image = imageView.image, let start = mouseDownAt else { return }
        let p = event.locationInWindow
        guard hypot(p.x - start.x, p.y - start.y) > 4 else { return }
        mouseDownAt = nil
        let item = NSPasteboardItem()
        if isLocal, let path = source()?.path, FileManager.default.fileExists(atPath: path) {
            item.setString(URL(fileURLWithPath: path).absoluteString, forType: .fileURL)
        }
        if let tiff = image.tiffRepresentation { item.setData(tiff, forType: .tiff) }
        let drag = NSDraggingItem(pasteboardWriter: item)
        let size = NSSize(width: min(image.size.width, 160), height: min(image.size.width, 160) * image.size.height / max(image.size.width, 1))
        let at = convert(event.locationInWindow, from: nil)
        drag.setDraggingFrame(NSRect(x: at.x - size.width / 2, y: at.y - size.height / 2, width: size.width, height: size.height), contents: image)
        beginDraggingSession(with: [drag], event: event, source: self)
    }

    /// Whether the block's host is this Mac (set by the window).
    var isLocal = true
    private var mouseDownAt: NSPoint?

    override func mouseDown(with event: NSEvent) {
        mouseDownAt = event.locationInWindow
        if event.clickCount == 2, pdfView == nil {
            // Double-click: actual size, or back to fitting.
            if abs(scroll.magnification - 1) < 0.01 { fitted = false; fit() } else { scroll.magnification = 1 }
        }
        super.mouseDown(with: event)
    }
}

// MARK: A PDF, as Preview shows it

extension MediaView: Searchable {
    fileprivate func makeControls() {
        previousButton.toolTip = "Previous Page"
        nextButton.toolTip = "Next Page"
        zoomOutButton.toolTip = "Zoom Out (⌘−)"
        zoomInButton.toolTip = "Zoom In (⌘+)"
        layoutButton.toolTip = "Page Layout"
        for (b, sel) in [(previousButton, #selector(previousPage)), (nextButton, #selector(nextPage)), (zoomOutButton, #selector(zoomOutClicked)),
                         (zoomInButton, #selector(zoomInClicked)), (layoutButton, #selector(layoutClicked))] {
            b.target = self
            b.action = sel
        }
        pageField.font = .monospacedDigitSystemFont(ofSize: 11.5, weight: .regular)
        pageField.alignment = .center
        pageField.target = self
        pageField.action = #selector(pageEntered)
        pageBox.toolTip = "Go to Page"
        pageCount.font = .monospacedDigitSystemFont(ofSize: 11.5, weight: .regular)
        pageCount.textColor = Theme.secondaryText
        zoomLabel.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        zoomLabel.textColor = Theme.secondaryText
        zoomLabel.alignment = .center
        for v in [previousButton, nextButton, pageBox, pageCount, zoomOutButton, zoomInButton, zoomLabel, layoutButton] {
            v.isHidden = true
            addSubview(v)
        }
    }

    /// Along the top: the path at the left; the page, the zoom and the
    /// layout at the right, the zoom going first as the tile narrows.
    fileprivate func layoutControls() {
        let y = bounds.height - 28
        let mid = y + 10
        var right = bounds.width - 10
        let ready = pdfView?.document != nil
        func place(_ v: NSView, width: CGFloat, height: CGFloat = 20) {
            v.frame = NSRect(x: right - width, y: (mid - height / 2).rounded(), width: width, height: height)
            right -= width
        }
        for v in [previousButton, nextButton, pageBox, pageCount, zoomOutButton, zoomInButton, zoomLabel, layoutButton] { v.isHidden = !ready }
        let showZoom = ready && bounds.width >= 420
        let showPages = ready && bounds.width >= 260
        layoutButton.isHidden = !showZoom
        for v in [zoomOutButton, zoomInButton, zoomLabel] { v.isHidden = !showZoom }
        for v in [previousButton, nextButton, pageBox, pageCount] { v.isHidden = !showPages }
        if showZoom {
            place(layoutButton, width: 22)
            right -= 10
            place(zoomInButton, width: 22)
            place(zoomLabel, width: 44, height: 14)
            place(zoomOutButton, width: 22)
            right -= 12
        }
        if showPages {
            place(nextButton, width: 22)
            let cw = ceil(pageCount.intrinsicContentSize.width)
            place(pageCount, width: cw, height: 14)
            right -= 4
            let digits = CGFloat(max(String(pdfView?.document?.pageCount ?? 1).count, 2))
            place(pageBox, width: 16 + digits * 8, height: 22)
            right -= 2
            place(previousButton, width: 22)
            right -= 8
        }
        header.frame = NSRect(x: 12, y: bounds.height - 24, width: max(0, right - 12), height: 16)
        note.frame = .zero
    }

    /// The document in: its pages counted, its contents read, the
    /// sidebar filled.
    fileprivate func documentLoaded() {
        guard let p = pdfView, let doc = p.document else { return }
        pageCount.stringValue = "of \(doc.pageCount)"
        contents = []
        func walk(_ o: PDFOutline, _ level: Int) {
            for i in 0..<o.numberOfChildren {
                guard let c = o.child(at: i) else { continue }
                contents.append((c, c.destination?.page.map { doc.index(for: $0) }))
                levels.append(level)
                walk(c, level + 1)
            }
        }
        var levels: [Int] = []
        if let root = doc.outlineRoot { walk(root, 0) }
        contentsOutline.set(zip(contents, levels).map { Outline.Item(title: $0.0.item.label ?? "Untitled", level: min($0.1, 4)) })
        // The contents first when there are any, unless the pages were chosen.
        if keeper.value("sidebarPage") == nil { sidebar?.show(page: contents.isEmpty ? .pages : .contents) }
        pageChanged()
        scaleChanged()
        needsLayout = true
    }

    fileprivate func pageChanged() {
        guard let p = pdfView, let doc = p.document, let page = p.currentPage else { return }
        let i = doc.index(for: page)
        if pageField.currentEditor() == nil { pageField.stringValue = "\(i + 1)" }
        previousButton.isEnabled = p.canGoToPreviousPage
        nextButton.isEnabled = p.canGoToNextPage
        contentsOutline.current = contents.lastIndex { ($0.page ?? .max) <= i }
    }

    fileprivate func scaleChanged() {
        guard let p = pdfView else { return }
        zoomLabel.stringValue = "\(Int((p.scaleFactor * 100).rounded()))%"
        zoomLabel.toolTip = p.autoScales ? "Fits the tile" : nil
    }

    @objc fileprivate func previousPage() { pdfView?.goToPreviousPage(nil) }
    @objc fileprivate func nextPage() { pdfView?.goToNextPage(nil) }
    @objc fileprivate func zoomInClicked() { pdfView?.zoomIn(nil) }
    @objc fileprivate func zoomOutClicked() { pdfView?.zoomOut(nil) }

    @objc fileprivate func pageEntered() {
        guard let p = pdfView, let doc = p.document else { return }
        NavJumps.willJump?(self)
        if let n = Int(pageField.stringValue.trimmingCharacters(in: .whitespaces)), let page = doc.page(at: min(max(n, 1), doc.pageCount) - 1) {
            p.go(to: page)
        }
        pageChanged()
        window?.makeFirstResponder(p)
    }

    /// How pages are laid out, as Preview's View menu has it, and the zoom.
    @objc fileprivate func layoutClicked() {
        guard let p = pdfView else { return }
        let menu = NSMenu()
        for (title, mode) in [("Single Page", PDFDisplayMode.singlePage), ("Continuous Scroll", .singlePageContinuous),
                              ("Two Pages", .twoUp), ("Two Pages, Continuous", .twoUpContinuous)] {
            let item = ClosureMenuItem(title, symbol: nil) { [weak self] in self?.setDisplay(mode) }
            item.state = p.displayMode == mode ? .on : .off
            menu.addItem(item)
        }
        let book = ClosureMenuItem("Book Layout", symbol: nil) { [weak self] in
            guard let p = self?.pdfView else { return }
            p.displaysAsBook.toggle()
            self?.keeper.note(["book": p.displaysAsBook ? "1" : "0"])
        }
        book.state = p.displaysAsBook ? .on : .off
        menu.addItem(book)
        menu.addItem(.separator())
        menu.addItem(ClosureMenuItem("Actual Size", symbol: nil) { [weak self] in
            self?.pdfView?.autoScales = false
            self?.pdfView?.scaleFactor = 1
        })
        menu.addItem(ClosureMenuItem("Zoom to Fit", symbol: nil) { [weak self] in self?.pdfView?.autoScales = true })
        menu.addItem(.separator())
        menu.addItem(ClosureMenuItem("Rotate Left", symbol: nil) { [weak self] in self?.rotate(-90) })
        menu.addItem(ClosureMenuItem("Rotate Right", symbol: nil) { [weak self] in self?.rotate(90) })
        menu.popUp(positioning: nil, at: NSPoint(x: layoutButton.frame.minX, y: layoutButton.frame.minY - 4), in: self)
    }

    fileprivate func setDisplay(_ mode: PDFDisplayMode) {
        pdfView?.displayMode = mode
        keeper.note(["display": "\(mode.rawValue)"])
    }

    /// Every page turned, as shown here (the file isn't changed).
    fileprivate func rotate(_ degrees: Int) {
        guard let p = pdfView, let doc = p.document else { return }
        let at = p.currentPage
        for i in 0..<doc.pageCount { doc.page(at: i)?.rotation += degrees }
        p.layoutDocumentView()
        if let at { p.go(to: at) }
    }

    // MARK: The sidebar

    // An image's is empty, and shows nothing.
    var outline: Outline? { contentsOutline }
    /// Under the bar of page and zoom.
    var outlineInset: CGFloat { Self.barHeight }
    static let barHeight: CGFloat = 32
    var hasSidebar: Bool { pdfView != nil }
    var sidebarShown: Bool { sidebar?.isHidden == false }

    func toggleSidebar() {
        setSidebar(!sidebarShown)
        keeper.note(["outline": sidebarShown ? "1" : "0"], after: 0)
    }

    /// The contents and the pages at the tile's left: the contents first
    /// when there are any, else the pages.
    fileprivate func setSidebar(_ shown: Bool) {
        guard let p = pdfView, shown != sidebarShown else { return }
        if shown, sidebar == nil {
            let thumbs = PDFThumbnailView()
            thumbs.pdfView = p
            thumbs.thumbnailSize = NSSize(width: 120, height: 150)
            thumbs.backgroundColor = .clear
            let s = TileSidebar(outline: contentsOutline, pages: thumbs, emptyText: "No table of contents")
            s.onPageChange = { [weak self] page in self?.keeper.note(["sidebarPage": page.rawValue]) }
            addSubview(s)
            sidebar = s
            if let kept = keeper.value("sidebarPage").flatMap(TileSidebar.Page.init(rawValue:)) { s.show(page: kept) }
            if pdfView?.document != nil { documentLoaded() }
        }
        sidebar?.isHidden = !shown
        needsLayout = true
    }

    // MARK: Find (⌘F)

    @objc override func performTextFinderAction(_ sender: Any?) {
        guard pdfView != nil else { return super.performTextFinderAction(sender) }
        finder.perform(sender)
    }

    func search(_ query: String, caseSensitive: Bool, done: @escaping (Int?) -> Void) {
        guard let p = pdfView, let doc = p.document else { return done(nil) }
        found = query.isEmpty ? [] : doc.findString(query, withOptions: caseSensitive ? [] : [.caseInsensitive])
        // From the page showing on.
        let here = p.currentPage.map { doc.index(for: $0) } ?? 0
        foundAt = found.firstIndex { s in s.pages.first.map { doc.index(for: $0) >= here } ?? false } ?? 0
        showFound()
        done(found.count)
    }

    func findNext(forward: Bool) {
        guard !found.isEmpty else { return }
        foundAt = (foundAt + (forward ? 1 : -1) + found.count) % found.count
        showFound()
    }

    /// A page is paper whatever the appearance: every match a strong
    /// yellow, the one gone to a blue — apart by hue and lightness both,
    /// for eyes that don't tell red from green.
    static let pdfMatch = NSColor(srgbRed: 1, green: 0.84, blue: 0, alpha: 0.8)
    static let pdfCurrentMatch = NSColor(srgbRed: 0.2, green: 0.56, blue: 1, alpha: 0.7)

    fileprivate func showFound() {
        guard let p = pdfView else { return }
        for (i, s) in found.enumerated() { s.color = i == foundAt ? Self.pdfCurrentMatch : Self.pdfMatch }
        p.highlightedSelections = found.isEmpty ? nil : found
        guard found.indices.contains(foundAt) else { return }
        p.go(to: found[foundAt])
    }

    func endSearch() {
        found = []
        pdfView?.highlightedSelections = nil
        if let p = pdfView { window?.makeFirstResponder(p) }
    }

    func textForFind(_ done: @escaping (String?) -> Void) { done(pdfView?.currentSelection?.string) }

    // MARK: Debugging

    /// "page N", "next", "previous", "zoom in|out|fit", "display N",
    /// "sidebar", "pages", "contents", "pick N", "find <query>",
    /// "findnext": done, then how it stands.
    func debugPDF(_ arg: String) -> String {
        guard let p = pdfView else { return "not a PDF" }
        let words = arg.split(separator: " ", maxSplits: 1).map(String.init)
        switch words.first {
        case "page": if let n = words.count > 1 ? Int(words[1]) : nil { pageField.stringValue = "\(n)"; pageEntered() }
        case "next": nextPage()
        case "previous": previousPage()
        case "zoom":
            if words.count > 1 { words[1] == "in" ? p.zoomIn(nil) : words[1] == "out" ? p.zoomOut(nil) : (p.autoScales = true) }
        case "display": if let n = words.count > 1 ? Int(words[1]) : nil, let m = PDFDisplayMode(rawValue: n) { setDisplay(m) }
        case "sidebar": toggleSidebar()
        case "pages": sidebar?.show(page: .pages)
        case "contents": sidebar?.show(page: .contents)
        case "pick": _ = sidebar?.debugPick(words.count > 1 ? Int(words[1]) ?? 0 : 0)
        case "find": search(words.count > 1 ? words[1] : "", caseSensitive: false) { _ in }
        case "findnext": findNext(forward: true)
        default: break
        }
        layoutSubtreeIfNeeded()
        let page = p.currentPage.flatMap { pg in p.document.map { $0.index(for: pg) + 1 } } ?? 0
        var lines = ["page \(page) \(pageCount.stringValue) field \(pageField.stringValue) zoom \(zoomLabel.stringValue) display \(p.displayMode.rawValue) found \(found.count) at \(foundAt)"]
        let shown: [(String, NSView)] = [("prev", previousButton), ("field", pageBox), ("zoom", zoomLabel), ("layout", layoutButton)]
        lines.append("controls " + shown.map { "\($0.0)\($0.1.isHidden ? "-" : "+")" }.joined(separator: " ") + " header \(Int(header.frame.width))")
        if let sidebar, !sidebar.isHidden { lines.append(sidebar.debugEntries) } else { lines.append("sidebar hidden") }
        return lines.joined(separator: "\n")
    }
}

extension MediaView {
    /// A PDF's page.
    var navLocation: NavLocation? {
        guard let p = pdfView, let doc = p.document, let page = p.currentPage else { return nil }
        return .page(doc.index(for: page))
    }

    func go(to location: NavLocation) {
        if case let .page(i) = location, let p = pdfView, let page = p.document?.page(at: i) { p.go(to: page) }
    }
}

extension MediaView: Printable {
    /// A PDF's pages, fitted to the paper; an image, fitted to a page.
    func printOperation() -> NSPrintOperation? {
        let info = (NSPrintInfo.shared.copy() as! NSPrintInfo)
        if let doc = pdfDocument { return doc.printOperation(for: info, scalingMode: .pageScaleToFit, autoRotate: true) }
        guard let image = shownImage else { return nil }
        info.horizontalPagination = .fit
        info.verticalPagination = .fit
        let view = NSImageView(frame: NSRect(origin: .zero, size: image.size))
        view.image = image
        view.imageScaling = .scaleProportionallyUpOrDown
        return NSPrintOperation(view: view, printInfo: info)
    }

    /// ⌘C: the image, or the PDF's selected text, on the clipboard.
    @objc func copy(_ sender: Any?) {
        if let pdf = pdfDocument, let s = pdfSelectionText {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(s, forType: .string)
            _ = pdf
        } else if let image = shownImage {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.writeObjects([image])
        } else {
            NSSound.beep()
        }
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

extension MediaView: NSDraggingSource {
    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation { [.copy, .generic] }
}

extension MediaView {
    func maniSelection() async -> ManiSelected? {
        guard let sel = pdfView?.currentSelection, let text = sel.string, !text.isEmpty else { return nil }
        let page = sel.pages.first.flatMap { pdfDocument?.index(for: $0) }.map { $0 + 1 }
        return ManiSelected(text: text, page: page)
    }

    /// A PDF's text, its pages (all, or those asked for) one after another.
    func maniText(_ options: ManiReadOptions) async -> String? {
        guard let doc = pdfDocument else { return nil }
        return MediaView.text(of: doc, pages: options.pages)
    }

    static func text(of doc: PDFDocument, pages: ClosedRange<Int>?) -> String {
        let all = 1...max(doc.pageCount, 1)
        let range = pages.map { $0.clamped(to: all) } ?? all
        return range.compactMap { doc.page(at: $0 - 1)?.string }.joined(separator: "\n\u{0C}\n")
    }
}
