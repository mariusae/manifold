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

    /// The index of the heading at the top of the page now (the last one
    /// at or above the viewport's top), for ⌘\ to begin there.
    func headingAtTop(_ done: @escaping (Int?) -> Void) {
        web.evaluateJavaScript("(function(){var hs=document.querySelectorAll('h1,h2,h3,h4,h5,h6');var at=-1;for(var i=0;i<hs.length;i++){if(hs[i].getBoundingClientRect().top<=24)at=i;}return at;})()") { r, _ in
            let i = (r as? Int) ?? (r as? Double).map(Int.init) ?? -1
            done(i >= 0 ? i : nil)
        }
    }

    /// Scrolls to the page's `index`th heading (⌘\).
    func scroll(toHeading index: Int) {
        web.evaluateJavaScript("(function(){var h=document.querySelectorAll('h1,h2,h3,h4,h5,h6')[\(index)]; if(h){h.scrollIntoView({block:'start'});}})()") { [weak self] _, _ in
            guard let self else { return }
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
        // A scrollbar that shows (§3.1), as the lenses' do.
        config.userContentController.addUserScript(WKUserScript(source: "(function(){var s=document.createElement('style');s.textContent='::-webkit-scrollbar{width:12px;height:12px}::-webkit-scrollbar-thumb{background:rgba(127,127,127,.5);border-radius:7px;border:3px solid transparent;background-clip:content-box}::-webkit-scrollbar-thumb:hover{background:rgba(127,127,127,.8);background-clip:content-box}::-webkit-scrollbar-track{background:transparent}';(document.head||document.documentElement).appendChild(s);})();", injectionTime: .atDocumentEnd, forMainFrameOnly: true))
        web = WKWebView(frame: .zero, configuration: config)
        super.init(frame: .zero)
        handler.onState = { [weak self] values in
            self?.keeper.note(values)
            if values["scroll"] != nil { self?.scheduleOutline() }
        }
        web.navigationDelegate = self
        web.setValue(false, forKey: "drawsBackground")
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
            self.scrubber.update(marks: marks, total: h, offset: y, shown: v)
        }
    }

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
        web.frame = NSRect(x: 0, y: 0, width: max(bounds.width - ScrubberView.width, 0), height: bounds.height)
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
            body = MarkdownRenderer.html(text)
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
        web.evaluateJavaScript(MarkdownPage.script + MarkdownPage.themeScript(theme) + js) { [weak self] _, _ in self?.scheduleOutline() }
    }

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

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let dict = message.body as? [String: Any] else { return }
        var values: [String: String] = [:]
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
