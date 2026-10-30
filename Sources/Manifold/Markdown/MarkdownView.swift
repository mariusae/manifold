import AppKit
import ManifoldMarkdown
import ManifoldCore
import WebKit

protocol MarkdownViewDelegate: AnyObject {
    /// A link to another Markdown file was followed.
    func markdownView(_ view: MarkdownView, follow url: URL, modifiers: NSEvent.ModifierFlags)
    /// A heading was gone to and is at the top (the pointer may follow).
    func markdownViewDidReveal(_ view: MarkdownView)
    /// An image dropped on the page, for the text to show.
    func markdownView(_ view: MarkdownView, image data: Data, kind: String)
    /// Markdown dropped on the page (a link, a reference, words), put at
    /// the end of the text; the blocks it names linked from it.
    func markdownView(_ view: MarkdownView, append markdown: String, naming blocks: [BlockID])
    /// ⌘[ (-1) or ⌘] (1): the page this tile showed before or after, as
    /// a link followed in place left it; false at either end.
    func markdownView(_ view: MarkdownView, history direction: Int) -> Bool
}

/// The page's web view, which leaves ⌘[ ⌘] to the preview: its own back
/// list is only ever the one page.
private final class PreviewWebView: WKWebView {
    override func responds(to selector: Selector!) -> Bool {
        if selector == #selector(goBack(_:)) || selector == #selector(goForward(_:)) { return false }
        return super.responds(to: selector)
    }
}

/// The preview lens on a text block: its Markdown rendered by cmark-gfm into
/// a web view, and rendered again as the text changes (edits in an editor
/// on the same block, or the file saved by another program), keeping the
/// scroll position.
final class MarkdownView: NSView, PaneContent, KeepsViewState, Snapshotting, WKNavigationDelegate {
    let placement: PlacementID
    let keeper = ViewStateKeeper()
    /// The page was (re)loaded: its scroll and selection go back after
    /// the first render.
    private var restorePending = true
    private(set) var block: BlockID
    private(set) var path: String
    weak var delegate: MarkdownViewDelegate?
    private let web: WKWebView

    /// The page for printing, fitted to the paper's width.
    var webPrint: NSPrintOperation {
        let info = (NSPrintInfo.shared.copy() as! NSPrintInfo)
        info.isVerticallyCentered = false
        let op = web.printOperation(with: info)
        op.view?.frame = web.bounds
        op.jobTitle = path.isEmpty ? "Note" : path.lastPathComponent
        return op
    }

    /// A picture of the page as it is now, when it's ready (for a card).
    func snapshot(_ done: @escaping (NSImage?) -> Void) {
        web.takeSnapshot(with: nil) { image, _ in done(image) }
    }

    /// The line of the text (from 0, a fraction into it) at the top of
    /// the page now, by where the page's elements came from.
    func topLine(_ done: @escaping (Double?) -> Void) {
        guard renderedVersion >= 0 else { return done(pendingTopLine) }
        web.evaluateJavaScript("manifoldTopLine()") { r, _ in done((r as? Double) ?? (r as? Int).map(Double.init)) }
    }

    /// The page scrolled so the text's `line` (from 0) is at the top: at
    /// once, or once the page is first shown.
    func scroll(toTopLine line: Double) {
        guard renderedVersion >= 0 else { pendingTopLine = line; return }
        web.evaluateJavaScript("manifoldToLine(\(line))")
    }

    /// A line of the text (from 1) gone to: at the top, a little of what's
    /// before it showing.
    func reveal(line: Int) {
        NavJumps.willJump?(self)
        scroll(toTopLine: max(0, Double(line - 1) - 2))
    }

    private var pendingTopLine: Double?

    /// Scrolls to the page's `index`th heading (⌘P), the pointer
    /// following — not from the tile's own outline, where it stays.
    func scroll(toHeading index: Int, warping: Bool = true) {
        NavJumps.willJump?(self)
        web.evaluateJavaScript("(function(){var h=document.querySelectorAll('h1,h2,h3,h4,h5,h6')[\(index)]; if(h){h.scrollIntoView({block:'start'});}})()") { [weak self] _, _ in
            guard let self, warping else { return }
            self.delegate?.markdownViewDidReveal(self)
        }
    }
    private var loaded = false
    /// The text as last rendered, to skip renders that would show the same.
    private var renderedVersion = -1
    private var renderWork: DispatchWorkItem?
    /// The page's script, sent once a load (not with every render).
    private var scriptSent = false
    /// Mermaid given to the page (once a page has a diagram; again after a load).
    private var mermaidSent = false
    /// Renders asked for: one made on another thread is shown only if
    /// none has been asked for since.
    private var renderGeneration = 0
    /// Where the text comes from.
    var source: () -> (text: String, version: Int)? = { nil }
    /// Whether its file is still to be read by its host: "Reading…" meanwhile.
    var isUnread: () -> Bool = { false }
    private let note = BusyNote()
    var theme: FontTheme {
        didSet { if theme != oldValue, loaded { web.evaluateJavaScript(MarkdownPage.themeScript(theme)) } }
    }

    var focusView: NSView { web }
    var isDead: Bool { false }

    init(placement: PlacementID, block: BlockID, path: String, theme: FontTheme) {
        self.placement = placement
        self.block = block
        self.path = path
        self.theme = theme
        let config = WKWebViewConfiguration()
        // The document's own scripts don't run; ours (evaluateJavaScript) do.
        config.defaultWebpagePreferences.allowsContentJavaScript = false
        let handler = StateMessages()
        config.userContentController.add(handler, name: "manifoldState")
        let selectionOwner = WeakView()
        PageSelection.watch(config) { selectionOwner.view }
        // No scrollbar of the page's own: the scrubber is its scroll bar (§3.8).
        web = PreviewWebView(frame: .zero, configuration: config)
        super.init(frame: .zero)
        selectionOwner.view = self
        handler.onState = { [weak self] values in
            self?.keeper.note(values)
            if values["scroll"] != nil { self?.scheduleOutline() }
        }
        // The scrubber follows the page as it moves, and the outline marks
        // the heading you're in, with the headings as last read.
        handler.onScrolling = { [weak self] y in
            self?.scrollY = y
            guard let self, let o = self.lastOutline else { return }
            self.scrubber.update(total: o.total, offset: y, shown: o.shown)
            self.markCurrentHeading(at: y)
        }
        web.navigationDelegate = self
        web.setValue(false, forKey: "drawsBackground")
        web.unregisterDraggedTypes()
        // Things dropped on the page go into the text (at its end).
        registerForDraggedTypes(Dragged.types)
        wantsLayer = true
        themed { $0.layer?.backgroundColor = Theme.windowBackground.cgColor }
        addSubview(web)
        scrubber.onScroll = { [weak self] f in
            self?.web.evaluateJavaScript("window.scrollTo(0, \(f) * Math.max(document.documentElement.scrollHeight - window.innerHeight, 0));")
        }
        addSubview(scrubber)
        addSubview(note)
        // The note's outline (its headings and top-level items, as its
        // editor and outline have it): an entry gone to by its line.
        headingsOutline.onPick = { [weak self] i in
            guard let self, self.itemLines.indices.contains(i) else { return }
            NavJumps.willJump?(self)
            self.scroll(toTopLine: Double(self.itemLines[i]))
            self.headingsOutline.current = i
        }
        // An entry's place: the line it's on in the text.
        headingsOutline.block = block
        headingsOutline.placeFor = { [weak self] i in
            guard let lines = self?.itemLines, lines.indices.contains(i) else { return nil }
            return "line=\(lines[i] + 1)"
        }
        headingsOutline.menuFor = { [weak self] i in
            guard let self, self.itemLines.indices.contains(i) else { return nil }
            return Drags.linkMenu("Copy Link to This Place", self.block, "line=\(self.itemLines[i] + 1)")
        }
        scriptSent = false
        mermaidSent = false
        web.loadFileURL(MarkdownPage.shell, allowingReadAccessTo: URL(fileURLWithPath: "/"))
    }

    // MARK: The scrubber (§3.1)

    private let scrubber = ScrubberView(frame: .zero)
    private var outlineWork: DispatchWorkItem?
    /// The page's headings' tops and its size as last read, for following a
    /// scroll live.
    private var lastOutline: (tops: [Double], total: Double, shown: Double)?

    /// The page's headings and where it is, asked of the page a moment
    /// after it rendered, scrolled or changed size.
    private func scheduleOutline() {
        outlineWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.readOutline() }
        outlineWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15, execute: work)
    }

    /// The outline's entries' lines in the text, from 0.
    private var itemLines: [Int] = []

    /// The note's outline from its text (`NoteOutlineMarkdown.items`), each
    /// entry placed on the page by the element its line starts (the page's
    /// `data-sourcepos`), and where the page is.
    private func readOutline() {
        guard loaded else { return }
        let items = source().map { NoteOutlineMarkdown.items(in: $0.text) } ?? []
        let lines = items.map { $0.line + 1 }
        let js = "(function(L){var els=document.querySelectorAll('[data-sourcepos]'),first={};for(var i=0;i<els.length;i++){var m=/^(\\d+):/.exec(els[i].getAttribute('data-sourcepos'));if(m&&!(m[1] in first)){first[m[1]]=els[i];}}var t=[];for(var j=0;j<L.length;j++){var e=first[L[j]];t.push(e?e.getBoundingClientRect().top+window.scrollY:-1);}return {h:document.documentElement.scrollHeight,y:window.scrollY,v:window.innerHeight,t:t};})(\(lines))"
        web.evaluateJavaScript(js) { [weak self] r, _ in
            guard let self, let d = r as? [String: Any], let h = d["h"] as? Double, let y = d["y"] as? Double, let v = d["v"] as? Double else { return }
            // One not found on the page (inside something rendered whole) at
            // the one before it.
            var tops: [Double] = []
            for t in (d["t"] as? [Double]) ?? [] { tops.append(t >= 0 ? t : (tops.last ?? 0)) }
            self.itemLines = items.map(\.line)
            self.lastOutline = (tops, h, v)
            self.scrubber.update(total: h, offset: y, shown: v)
            self.headingsOutline.set(items.map(Outline.Item.init))
            self.markCurrentHeading(at: y)
        }
    }

    // MARK: The outline (§7.5)

    /// The page's headings, the one you're in marked: as ticks at the
    /// tile's upper right, and in the sidebar at its left.
    private let headingsOutline = Outline()
    var outline: Outline? { headingsOutline }
    private var sidebar: TileSidebar?
    private var sidebarRestored = false
    /// The page shows a note or a Markdown file, which things dropped go into.
    var takesDrops = false
    /// How far down the page is, as last seen.
    private var scrollY: Double = 0
    var navLocation: NavLocation? { .offset(scrollY) }
    func go(to location: NavLocation) {
        if case let .offset(y) = location { web.evaluateJavaScript("window.scrollTo(0, \(y));") }
    }
    var hasSidebar: Bool { true }
    var sidebarShown: Bool { sidebar?.isHidden == false }

    func toggleSidebar() {
        setSidebar(!sidebarShown)
        keeper.note(["outline": sidebarShown ? "1" : "0"], after: 0)
    }

    func setSidebar(_ shown: Bool) {
        guard shown != sidebarShown else { return }
        if shown, sidebar == nil {
            let s = TileSidebar(outline: headingsOutline)
            addSubview(s)
            sidebar = s
        }
        sidebar?.isHidden = !shown
        if shown { scheduleOutline() }
        needsLayout = true
    }

    /// The last heading at or above the top of the page as it shows.
    private func markCurrentHeading(at y: Double) {
        guard let o = lastOutline else { return }
        headingsOutline.current = o.tops.lastIndex { $0 <= y + 24 } ?? (o.tops.isEmpty ? nil : 0)
    }

    var debugSidebar: String { sidebar.map { $0.isHidden ? "hidden" : $0.debugEntries } ?? "none" }
    func debugSidebarPick(_ i: Int) -> String { sidebar?.debugPick(i) ?? "none" }

    required init?(coder: NSCoder) { fatalError() }

    func destroy() {
        renderWork?.cancel()
        keeper.flush()
    }

    /// The block's text may have changed: render it again, soon.
    func textChanged() {
        note.set(isUnread() ? .busy("Reading…") : .idle)
        guard let (_, version) = source(), version != renderedVersion else { return }
        // At most every 0.15 s while it changes, not put off by each change
        // (typing steadily, it was rendered after each pause, every key).
        if let w = renderWork, !w.isCancelled { return }
        let work = DispatchWorkItem { [weak self] in
            self?.renderWork = nil
            self?.render(scrollToTop: false)
        }
        renderWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15, execute: work)
    }

    override func layout() {
        super.layout()
        // The outline as it was kept, once the keeper can say.
        if !sidebarRestored {
            sidebarRestored = true
            if keeper.value("outline") == "1" { setSidebar(true) }
        }
        // The outline at the left, a third of the tile at most.
        var left: CGFloat = 0
        if let sidebar, !sidebar.isHidden {
            left = min(TileSidebar.width, (bounds.width / 3).rounded())
            sidebar.frame = NSRect(x: 0, y: 0, width: left, height: bounds.height)
        }
        web.frame = NSRect(x: left, y: 0, width: max(bounds.width - ScrubberView.width - left, 0), height: bounds.height)
        scrubber.frame = NSRect(x: bounds.width - ScrubberView.width, y: 0, width: ScrubberView.width, height: bounds.height)
        note.frame = web.frame
        note.set(isUnread() ? .busy("Reading…") : .idle)
        finder.layout(in: web.frame)
        scheduleOutline()
    }

    // MARK: Find

    private lazy var finder = FindHost(view: self, target: self)
    private var findQuery = (text: "", caseSensitive: false)

    @objc override func performTextFinderAction(_ sender: Any?) { finder.perform(sender) }

    /// ⌘[ ⌘]: back and forth along the pages this tile went to in place.
    @objc func goBack(_ sender: Any?) { if delegate?.markdownView(self, history: -1) != true { NSSound.beep() } }
    @objc func goForward(_ sender: Any?) { if delegate?.markdownView(self, history: 1) != true { NSSound.beep() } }

    /// Moved between lenses: the page is drawn again, as WebKit lets a view
    /// taken out of its window go blank.
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard window != nil, loaded else { return }
        // The page is loaded afresh; what was kept comes back after.
        keeper.flush()
        loaded = false
        renderedVersion = -1
        restorePending = true
        scriptSent = false
        mermaidSent = false
        web.loadFileURL(MarkdownPage.shell, allowingReadAccessTo: URL(fileURLWithPath: "/"))
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        loaded = false
        renderedVersion = -1
        restorePending = true
        scriptSent = false
        mermaidSent = false
        web.loadFileURL(MarkdownPage.shell, allowingReadAccessTo: URL(fileURLWithPath: "/"))
    }

    /// Shows another block, from the top.
    func show(block: BlockID, path: String) {
        guard block != self.block || path != self.path else { return }
        self.block = block
        self.path = path
        renderedVersion = -1
        keeper.restored = false
        restorePending = true
        render(scrollToTop: true)
    }

    /// The page made from the text — the HTML on another thread (a long
    /// note took the main thread for it at every change) — and shown.
    private func render(scrollToTop: Bool) {
        guard loaded else { return }
        renderGeneration &+= 1
        let generation = renderGeneration
        guard let (text, version) = source() else {
            return show(body: "<p class=\"missing\">\(escape(path)) can't be read.</p>", scrollToTop: scrollToTop)
        }
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let html = MarkdownRenderer.html(text, sourcePositions: true)
            DispatchQueue.main.async {
                guard let self, self.renderGeneration == generation, self.loaded else { return }
                self.renderedVersion = version
                self.show(body: self.resolvingImages(html), scrollToTop: scrollToTop)
            }
        }
    }

    private func show(body: String, scrollToTop: Bool) {
        let base = URL(fileURLWithPath: path).deletingLastPathComponent().absoluteString
        var js = "manifoldRender(\(json(body)), \(json(base)), \(scrollToTop && !restorePending));"
        if restorePending {
            // Back where it was: the scroll and the selection, then watching.
            restorePending = false
            let y = keeper.double("scroll").map { "\($0)" } ?? "null"
            let s = keeper.int("selStart").map { "\($0)" } ?? "null", e = keeper.int("selEnd").map { "\($0)" } ?? "null"
            js += " manifoldRestore(\(y), \(s), \(e)); manifoldWatch();"
            keeper.restored = true
        }
        // A line asked for before the page had any: there now.
        if let line = pendingTopLine {
            pendingTopLine = nil
            js += " manifoldToLine(\(line));"
        }
        let script = scriptSent ? "" : MarkdownPage.script
        scriptSent = true
        js += " window.manifoldPendingDiagrams || 0;"
        web.evaluateJavaScript(script + MarkdownPage.themeScript(theme) + js) { [weak self] result, _ in
            self?.scheduleOutline()
            // Diagrams waiting on Mermaid: given it (the page's scripts are
            // off; this is ours), then drawn.
            guard let self, (result as? Int ?? 0) > 0, !self.mermaidSent, let mermaid = Self.mermaid else { return }
            self.mermaidSent = true
            self.web.evaluateJavaScript(mermaid + ";0") { [weak self] _, _ in
                self?.web.evaluateJavaScript("manifoldDiagrams();") { [weak self] _, _ in self?.scheduleOutline() }
            }
        }
    }

    /// Mermaid, from the app's resources, read once (some 2.5 MB).
    private static let mermaid: String? = Bundle.main.url(forResource: "mermaid.min", withExtension: "js", subdirectory: "Mermaid")
        .flatMap { try? String(contentsOf: $0, encoding: .utf8) }

    /// Where a block's image is, for the page: this Mac's file, or another
    /// host's bytes once fetched (nil until then; `imagesArrived` after).
    var imageSource: ((BlockID) -> String?)?

    /// A block's card (a place's in it), for `![name](manifold:…)` naming
    /// one that isn't an image (§3.11).
    var cardFor: ((BlockID, String?) -> SummaryCardContent?)?
    /// The cards the page shows, by address, as they said when drawn.
    private var cardsShown: [String: BlockSummary] = [:]

    private static let embed = try! NSRegularExpression(pattern: #"<img src="(manifold:[^"]*)" alt="([^"]*)"[^>]*>"#)

    /// A reference written bare in the text (`manifold:host/id#place`).
    private static let bareReference = try! NSRegularExpression(pattern: #"(?<![(\[<"'=/\w])manifold:[A-Za-z0-9._-]+/[0-9A-HJKMNP-TV-Z]{26}(?:#[A-Za-z]+=[0-9]+)?"#)

    /// `<img src="manifold:…">`, a block a note shows: an image by the
    /// source the page can load; anything else as its card, a link. And a
    /// reference written bare, a link by its block's name.
    private func resolvingImages(_ html: String) -> String {
        let html = linkingReferences(html)
        guard html.contains("src=\"manifold:") else { cardsShown = [:]; return html }
        let ns = html as NSString
        var out = "", at = 0
        var cards: [String: BlockSummary] = [:]
        for m in Self.embed.matches(in: html, range: NSRange(location: 0, length: ns.length)) {
            out += ns.substring(with: NSRange(location: at, length: m.range.location - at))
            at = NSMaxRange(m.range)
            let address = ns.substring(with: m.range(at: 1))
            let link = BlockID.link(address)
            if let link, let content = cardFor?(link.block, link.fragment) {
                cards[address] = content.summary
                out += Self.cardHTML(content, href: address)
            } else {
                let source = link.flatMap { imageSource?($0.block) } ?? ""
                out += ns.substring(with: m.range).replacingOccurrences(of: "src=\"" + address + "\"", with: "src=\"" + source.replacingOccurrences(of: "\"", with: "%22") + "\"")
            }
        }
        cardsShown = cards
        return out + ns.substring(from: at)
    }

    private func linkingReferences(_ html: String) -> String {
        guard html.contains("manifold:") else { return html }
        let ns = html as NSString
        var out = "", at = 0
        for m in Self.bareReference.matches(in: html, range: NSRange(location: 0, length: ns.length)) {
            let address = ns.substring(with: m.range)
            guard let link = BlockID.link(address) else { continue }
            out += ns.substring(with: NSRange(location: at, length: m.range.location - at))
            at = NSMaxRange(m.range)
            let name = cardFor?(link.block, link.fragment)?.summary.title ?? address
            out += "<a href=\"\(address)\">\(escape(name))</a>"
        }
        return out + ns.substring(from: at)
    }

    /// The blocks' cards, as their summaries are now: the page drawn again
    /// if any changed.
    func refreshCards() {
        guard !cardsShown.isEmpty, let cardFor else { return }
        let changed = cardsShown.contains { address, shown in
            BlockID.link(address).flatMap { cardFor($0.block, $0.fragment)?.summary } != shown
        }
        if changed { render(scrollToTop: false) }
    }

    /// A card as the page shows it: the block's symbol, title and note,
    /// where it is, a few lines, a picture at the right.
    private static func cardHTML(_ c: SummaryCardContent, href: String) -> String {
        func esc(_ s: String) -> String {
            s.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: "\"", with: "&quot;")
        }
        let s = c.summary
        var h = "<a class=\"mcard\" href=\"\(esc(href))\"><span class=\"mcard-body\"><span class=\"mcard-head\">"
        if let icon = symbolURI(c.symbol) { h += "<img src=\"\(icon)\" alt=\"\">" }
        h += "<span class=\"mcard-title\">\(esc(s.title))</span>"
        if let note = s.note { h += "<span class=\"mcard-note \(s.tone.rawValue)\">\(esc(note))</span>" }
        h += "</span>"
        if let place = s.place, !place.isEmpty { h += "<span class=\"mcard-place\">\(esc(place.abbreviatingHome))</span>" }
        for line in s.lines.prefix(3) { h += "<span class=\"mcard-line\(s.code ? " code" : "")\">\(esc(line))</span>" }
        h += "</span>"
        if let t = c.thumbnail, let uri = pngURI(t, maxWidth: 240) { h += "<img class=\"mcard-thumb\" src=\"\(uri)\" alt=\"\">" }
        return h + "</a>"
    }

    private static var symbolURIs: [String: String] = [:]
    /// A symbol as the page can show it, grey (it reads on light and dark).
    private static func symbolURI(_ name: String) -> String? {
        if let u = symbolURIs[name] { return u }
        guard let image = Theme.symbol(name, size: 26, weight: .regular, color: NSColor(white: 0.5, alpha: 1)), let u = pngURI(image, maxWidth: 64) else { return nil }
        symbolURIs[name] = u
        return u
    }

    private static func pngURI(_ image: NSImage, maxWidth: CGFloat) -> String? {
        let scale = min(1, maxWidth / max(image.size.width, 1))
        let size = NSSize(width: max(1, (image.size.width * scale).rounded()), height: max(1, (image.size.height * scale).rounded()))
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width * 2), pixelsHigh: Int(size.height * 2), bitsPerSample: 8,
                                         samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return nil }
        rep.size = size
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        image.draw(in: NSRect(origin: .zero, size: size))
        NSGraphicsContext.restoreGraphicsState()
        return rep.representation(using: .png, properties: [:]).map { "data:image/png;base64," + $0.base64EncodedString() }
    }

    /// Another host's images came: the page drawn again with them.
    func imagesArrived() { render(scrollToTop: false) }

    private func json(_ s: String) -> String {
        let data = try! JSONSerialization.data(withJSONObject: [s])
        let array = String(decoding: data, as: UTF8.self)
        return String(array.dropFirst().dropLast())
    }

    private func escape(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
    }

    // MARK: WKNavigationDelegate

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        loaded = true
        render(scrollToTop: true)
    }

    /// Debugging: `js` run in the page; what the last such run gave.
    private var debugAnswer = "-"
    func debugEval(_ js: String) -> String {
        let last = debugAnswer
        web.evaluateJavaScript(js) { [weak self] r, e in self?.debugAnswer = e.map { "error: \($0)" } ?? "\(r ?? "nil")" }
        return last
    }

    /// Clicks the nth link on the page (for DebugControl).
    func debugClickLink(_ n: Int) {
        web.evaluateJavaScript("document.querySelectorAll('a')[\(n)]?.click();")
    }

    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        guard action.navigationType == .linkActivated, let url = action.request.url else {
            // The page itself loading.
            decisionHandler(action.request.url == MarkdownPage.shell ? .allow : .cancel)
            return
        }
        decisionHandler(.cancel)
        let docDir = URL(fileURLWithPath: path).deletingLastPathComponent().standardizedFileURL.path
        if url.isFileURL, let fragment = url.fragment, url.standardizedFileURL.path == docDir || url.standardizedFileURL.path == path {
            // A link within this document.
            web.evaluateJavaScript("manifoldScrollTo(\(json(fragment)));")
            return
        }
        delegate?.markdownView(self, follow: url, modifiers: action.modifierFlags)
    }
}

/// What the page says about its scroll and selection, as the keeper takes it.
final class StateMessages: NSObject, WKScriptMessageHandler {
    var onState: (([String: String]) -> Void)?
    /// The page moving, frame by frame: nothing to keep, only to follow.
    var onScrolling: ((Double) -> Void)?

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let dict = message.body as? [String: Any] else { return }
        // A code block's copy button.
        if let text = dict["copy"] as? String {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
            return
        }
        var values: [String: String] = [:]
        if let y = dict["scrolling"] as? Double { onScrolling?(y); return }
        if let y = dict["scroll"] as? Double { values["scroll"] = "\(Int(y.rounded()))" }
        if let s = dict["selStart"] as? Int, let e = dict["selEnd"] as? Int {
            values["selStart"] = s < 0 ? "" : "\(s)"
            values["selEnd"] = e < 0 ? "" : "\(e)"
        }
        if !values.isEmpty { onState?(values) }
    }
}

extension MarkdownView: Searchable {
    func search(_ query: String, caseSensitive: Bool, done: @escaping (Int?) -> Void) {
        findQuery = (query, caseSensitive)
        web.evaluateJavaScript(PageFind.search(query, caseSensitive: caseSensitive)) { n, _ in done(query.isEmpty ? nil : (n as? Int) ?? (n as? Double).map(Int.init)) }
    }

    func findNext(forward: Bool) {
        guard !findQuery.text.isEmpty else { return }
        web.evaluateJavaScript(PageFind.next(findQuery.text, caseSensitive: findQuery.caseSensitive, forward: forward))
    }

    func endSearch() {
        web.evaluateJavaScript(PageFind.end)
        window?.makeFirstResponder(web)
    }

    func textForFind(_ done: @escaping (String?) -> Void) {
        web.evaluateJavaScript(PageFind.selection) { s, _ in done((s as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)) }
    }
}

extension MarkdownView: Printable {
    /// The page as rendered.
    func printOperation() -> NSPrintOperation? { webPrint }
}

/// Things dropped on the page go into its text, at the end, as a note
/// takes them (§3.11): a block's link, a picture kept and shown — ⌃ for
/// the rest. A page that isn't a text's hands them on to the grid.
extension MarkdownView: DropTaking {
    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation { Dropping.updated(self, sender) }
    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation { Dropping.updated(self, sender) }
    override func draggingExited(_ sender: NSDraggingInfo?) { Dropping.exited(self, sender) }
    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool { Dropping.perform(self, sender) }

    func dropForms(_ d: Dragged, at p: NSPoint) -> [DropForm] { takesDrops ? Dropping.noteForms(d) : [] }

    func dropHint(_ form: DropForm, _ d: Dragged) -> String { Dropping.hint(form, d).replacingOccurrences(of: " here", with: " at the end") }

    func dropPut(_ d: Dragged, as form: DropForm, at p: NSPoint?) {
        var named: [BlockID] = []
        Dropping.noteText(d, as: form, keep: { [weak self] data, kind in
            guard let self else { return }
            self.delegate?.markdownView(self, image: data, kind: kind)
        }, insert: { [weak self] markdown in
            guard let self else { return }
            // (The blocks named come after the text: linked once it's in.)
            DispatchQueue.main.async { self.delegate?.markdownView(self, append: markdown, naming: named) }
        }, linked: { named.append($0) })
    }
}

extension MarkdownView {
    func maniSelection() async -> ManiSelected? {
        await PageSelection.text(in: web).map { ManiSelected(text: $0) }
    }
}

extension MarkdownView: FollowsFontTheme {
    func fontThemeChanged() {
        if loaded { web.evaluateJavaScript(MarkdownPage.themeScript(theme)) }
    }
}
