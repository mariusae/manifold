import AppKit
import ManifoldMarkdown
import ManifoldCore
import WebKit

protocol MarkdownViewDelegate: AnyObject {
    /// A link to another Markdown file was followed.
    func markdownView(_ view: MarkdownView, follow url: URL, modifiers: NSEvent.ModifierFlags)
    /// A heading was gone to and is at the top (the pointer may follow).
    func markdownViewDidReveal(_ view: MarkdownView)
}

/// The preview lens on a text block: its Markdown rendered by cmark-gfm into
/// a web view, and rendered again as the text changes (edits in an editor
/// on the same block, or the file saved by another program), keeping the
/// scroll position.
final class MarkdownView: NSView, PaneContent, KeepsViewState, WKNavigationDelegate {
    let placement: PlacementID
    let keeper = ViewStateKeeper()
    /// The page was (re)loaded: its scroll and selection go back after
    /// the first render.
    private var restorePending = true
    private(set) var block: BlockID
    private(set) var path: String
    weak var delegate: MarkdownViewDelegate?
    private let web: WKWebView

    /// A picture of the page as it is now, when it's ready (for a card).
    func snapshot(_ done: @escaping (NSImage?) -> Void) {
        web.takeSnapshot(with: nil) { image, _ in done(image) }
    }

    /// The index of the heading at the top of the page now (the last one
    /// at or above the viewport's top), for ⌘\ to begin there.
    func headingAtTop(_ done: @escaping (Int?) -> Void) {
        web.evaluateJavaScript("(function(){var hs=document.querySelectorAll('h1,h2,h3,h4,h5,h6');var at=-1;for(var i=0;i<hs.length;i++){if(hs[i].getBoundingClientRect().top<=24)at=i;}return at;})()") { r, _ in
            let i = (r as? Int) ?? (r as? Double).map(Int.init) ?? -1
            done(i >= 0 ? i : nil)
        }
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
    func reveal(line: Int) { scroll(toTopLine: max(0, Double(line - 1) - 2)) }

    private var pendingTopLine: Double?

    /// Scrolls to the page's `index`th heading (⌘\), the pointer
    /// following — not from the tile's own outline, where it stays.
    func scroll(toHeading index: Int, warping: Bool = true) {
        web.evaluateJavaScript("(function(){var h=document.querySelectorAll('h1,h2,h3,h4,h5,h6')[\(index)]; if(h){h.scrollIntoView({block:'start'});}})()") { [weak self] _, _ in
            guard let self, warping else { return }
            self.delegate?.markdownViewDidReveal(self)
        }
    }
    private var loaded = false
    /// The text as last rendered, to skip renders that would show the same.
    private var renderedVersion = -1
    private var renderWork: DispatchWorkItem?
    /// Where the text comes from.
    var source: () -> (text: String, version: Int)? = { nil }
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
        // No scrollbar of the page's own: the scrubber is its scroll bar (§3.8).
        web = WKWebView(frame: .zero, configuration: config)
        super.init(frame: .zero)
        handler.onState = { [weak self] values in
            self?.keeper.note(values)
            if values["scroll"] != nil { self?.scheduleOutline() }
        }
        // The scrubber follows the page as it moves, with the headings as last read.
        handler.onScrolling = { [weak self] y in
            guard let self, let o = self.lastOutline else { return }
            self.scrubber.update(marks: o.marks, total: o.total, offset: y, shown: o.shown)
            self.markCurrentHeading(at: y)
        }
        web.navigationDelegate = self
        web.setValue(false, forKey: "drawsBackground")
        web.unregisterDraggedTypes()
        wantsLayer = true
        themed { $0.layer?.backgroundColor = Theme.windowBackground.cgColor }
        addSubview(web)
        scrubber.onScroll = { [weak self] f in
            self?.web.evaluateJavaScript("window.scrollTo(0, \(f) * Math.max(document.documentElement.scrollHeight - window.innerHeight, 0));")
        }
        scrubber.onPick = { [weak self] mark in self?.scroll(toHeading: mark.id) }
        scrubber.onHover = { [weak self] mark, y in self?.hoverScrubber(mark, at: y) }
        tip.showsCopy = false
        tip.isHidden = true
        tip.onExit = { [weak self] in self?.tip.isHidden = true }
        addSubview(scrubber)
        addSubview(tip)
        web.loadFileURL(MarkdownPage.shell, allowingReadAccessTo: URL(fileURLWithPath: "/"))
    }

    // MARK: The scrubber (§3.1)

    private let scrubber = ScrubberView(frame: .zero)
    private let tip = ScrubTip(frame: .zero)
    private var outlineWork: DispatchWorkItem?
    /// The page's headings and size as last read, for following a scroll live.
    private var lastOutline: (marks: [ScrubMark], total: Double, shown: Double)?

    /// The page's headings and where it is, asked of the page a moment
    /// after it rendered, scrolled or changed size.
    private func scheduleOutline() {
        outlineWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.readOutline() }
        outlineWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15, execute: work)
    }

    private func readOutline() {
        guard loaded else { return }
        let js = "(function(){var hs=document.querySelectorAll('h1,h2,h3,h4,h5,h6');var m=[];for(var i=0;i<hs.length;i++){m.push([hs[i].offsetTop,hs[i].tagName,hs[i].textContent.trim().slice(0,160)]);}return {h:document.documentElement.scrollHeight,y:window.scrollY,v:window.innerHeight,m:m};})()"
        web.evaluateJavaScript(js) { [weak self] r, _ in
            guard let self, let d = r as? [String: Any], let h = d["h"] as? Double, let y = d["y"] as? Double, let v = d["v"] as? Double else { return }
            let marks = ((d["m"] as? [[Any]]) ?? []).enumerated().compactMap { i, row -> ScrubMark? in
                guard row.count == 3, let top = row[0] as? Double, let text = row[2] as? String else { return nil }
                return ScrubMark(id: i, at: top, title: text, detail: nil)
            }
            self.lastOutline = (marks, h, v)
            self.scrubber.update(marks: marks, total: h, offset: y, shown: v)
            self.headingLevels = ((d["m"] as? [[Any]]) ?? []).compactMap { row in
                guard row.count == 3, let tag = row[1] as? String, let text = row[2] as? String else { return nil }
                return (text, Int(tag.dropFirst()) ?? 1)
            }
            self.fillSidebar(at: y)
        }
    }

    // MARK: The outline (§7.5)

    /// The page's headings at the tile's left, each clicked to go there,
    /// the one you're in marked.
    private var sidebar: TileSidebar?
    private var headingLevels: [(title: String, level: Int)] = []
    private var sidebarRestored = false
    var hasSidebar: Bool { true }
    var sidebarShown: Bool { sidebar?.isHidden == false }

    func toggleSidebar() {
        setSidebar(!sidebarShown)
        keeper.note(["outline": sidebarShown ? "1" : "0"], after: 0)
    }

    func setSidebar(_ shown: Bool) {
        guard shown != sidebarShown else { return }
        if shown, sidebar == nil {
            let s = TileSidebar()
            s.onPick = { [weak self] i in
                self?.scroll(toHeading: i, warping: false)
                self?.sidebar?.current = i
            }
            addSubview(s)
            sidebar = s
        }
        sidebar?.isHidden = !shown
        if shown { scheduleOutline() }
        needsLayout = true
    }

    private func fillSidebar(at y: Double) {
        guard let sidebar, !sidebar.isHidden else { return }
        sidebar.set(TileSidebar.entries(headingLevels))
        markCurrentHeading(at: y)
    }

    /// The last heading at or above the top of the page as it shows.
    private func markCurrentHeading(at y: Double) {
        guard let sidebar, !sidebar.isHidden, let o = lastOutline else { return }
        sidebar.current = o.marks.lastIndex { $0.at <= y + 24 } ?? (o.marks.isEmpty ? nil : 0)
    }

    var debugSidebar: String { sidebar.map { $0.isHidden ? "hidden" : $0.debugEntries } ?? "none" }
    func debugSidebarPick(_ i: Int) -> String { sidebar?.debugPick(i) ?? "none" }

    private func hoverScrubber(_ mark: ScrubMark?, at y: CGFloat) {
        guard let mark else { tip.isHidden = true; return }
        tip.show(mark)
        let size = tip.fittingSize
        let point = convert(NSPoint(x: 0, y: y), from: scrubber)
        let top = min(max(point.y - size.height / 2, 0), bounds.height - size.height)
        tip.frame = NSRect(x: scrubber.frame.minX - size.width - 4, y: round(top), width: size.width, height: size.height)
        tip.isHidden = false
    }

    required init?(coder: NSCoder) { fatalError() }

    func destroy() {
        renderWork?.cancel()
        keeper.flush()
    }

    /// The block's text may have changed: render it again, soon.
    func textChanged() {
        guard let (_, version) = source(), version != renderedVersion else { return }
        renderWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.render(scrollToTop: false) }
        renderWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08, execute: work)
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
        finder.layout(in: web.frame)
        scheduleOutline()
    }

    // MARK: Find

    private lazy var finder = FindHost(view: self, target: self)
    private var findQuery = (text: "", caseSensitive: false)

    @objc override func performTextFinderAction(_ sender: Any?) { finder.perform(sender) }

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
        web.loadFileURL(MarkdownPage.shell, allowingReadAccessTo: URL(fileURLWithPath: "/"))
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        loaded = false
        renderedVersion = -1
        restorePending = true
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

    private func render(scrollToTop: Bool) {
        guard loaded else { return }
        let body: String
        if let (text, version) = source() {
            renderedVersion = version
            body = resolvingImages(MarkdownRenderer.html(text, sourcePositions: true))
        } else {
            body = "<p class=\"missing\">\(escape(path)) can't be read.</p>"
        }
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
        web.evaluateJavaScript(MarkdownPage.script + MarkdownPage.themeScript(theme) + js) { [weak self] _, _ in self?.scheduleOutline() }
    }

    /// Where a block's image is, for the page: this Mac's file, or another
    /// host's bytes once fetched (nil until then; `imagesArrived` after).
    var imageSource: ((BlockID) -> String?)?

    /// `<img src="manifold:…">`, an image a note shows by its block: the
    /// source the page can load.
    private func resolvingImages(_ html: String) -> String {
        guard html.contains("src=\"manifold:"), let imageSource else { return html }
        var out = ""
        var rest = Substring(html)
        while let r = rest.range(of: "src=\"manifold:") {
            out += rest[..<r.lowerBound]
            guard let end = rest[r.upperBound...].firstIndex(of: "\"") else { break }
            let address = String(rest[r.upperBound..<end])
            let source = BlockID.link("manifold:" + address).flatMap { imageSource($0.block) } ?? ""
            out += "src=\"" + source.replacingOccurrences(of: "\"", with: "%22") + "\""
            rest = rest[rest.index(after: end)...]
        }
        return out + rest
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
