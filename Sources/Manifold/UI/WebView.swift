import AppKit
import ManifoldCore
import WebKit

protocol WebViewDelegate: AnyObject {
    /// The page moved on (a link followed, an address typed): the block's
    /// log records where it is.
    func webView(_ view: WebView, append events: [Event])
    /// A link was ⇧⌘-clicked: opened as a block of its own, beside.
    func webView(_ view: WebView, open url: URL)
}

/// The web lens: an embedded browser on a web block, with an address bar,
/// back and forward, and find. Where it is goes in the block's log, so its
/// history is the pages it showed.
final class WebView: NSView, PaneContent, KeepsViewState, WKNavigationDelegate {
    let keeper = ViewStateKeeper()
    let placement: PlacementID
    let block: BlockID
    weak var delegate: WebViewDelegate?
    var source: () -> Block? = { nil }
    private let web: WKWebView
    private var shownURL: String?

    var focusView: NSView { web }
    var isDead: Bool { false }

    init(placement: PlacementID, block: BlockID) {
        self.placement = placement
        self.block = block
        let config = WKWebViewConfiguration()
        // Scrolling is told of, so the page's state is kept as it moves.
        let watch = WKUserScript(source: """
            (function () { var t; window.addEventListener('scroll', function () {
              clearTimeout(t); t = setTimeout(function () { try { window.webkit.messageHandlers.manifoldState.postMessage({ scroll: window.scrollY }); } catch (e) {} }, 400);
            }); })();
            """, injectionTime: .atDocumentEnd, forMainFrameOnly: true)
        config.userContentController.addUserScript(watch)
        // A scrollbar that shows (§3.1), as the lenses' do.
        config.userContentController.addUserScript(WKUserScript(source: "(function(){var s=document.createElement('style');s.textContent='::-webkit-scrollbar{width:12px;height:12px}::-webkit-scrollbar-thumb{background:rgba(127,127,127,.5);border-radius:7px;border:3px solid transparent;background-clip:content-box}::-webkit-scrollbar-thumb:hover{background:rgba(127,127,127,.8);background-clip:content-box}::-webkit-scrollbar-track{background:transparent}';(document.head||document.documentElement).appendChild(s);})();", injectionTime: .atDocumentEnd, forMainFrameOnly: true))
        let handler = StateMessages()
        config.userContentController.add(handler, name: "manifoldState")
        web = WKWebView(frame: .zero, configuration: config)
        super.init(frame: .zero)
        handler.onState = { [weak self] _ in self?.keepInteraction() }
        wantsLayer = true
        themed { $0.layer?.backgroundColor = Theme.windowBackground.cgColor }
        web.navigationDelegate = self
        web.allowsBackForwardNavigationGestures = true
        // Nothing is dropped on a page: WebKit takes no part in drags.
        web.unregisterDraggedTypes()
        addSubview(web)
        documentChanged()
    }

    required init?(coder: NSCoder) { fatalError() }

    func destroy() { keeper.flush() }

    /// WebKit's whole account of the page — its history, its scroll — kept
    /// by the placement, to be the same page again.
    private func keepInteraction() {
        guard keeper.restored, let data = web.interactionState as? Data else { return }
        keeper.note(["interaction": data.base64EncodedString(), "interactionURL": web.url?.absoluteString ?? ""], after: 1)
    }

    /// The page has the whole tile; the pill is its address (§3.1).
    override func layout() {
        super.layout()
        web.frame = bounds
        finder.layout(in: bounds)
    }

    // MARK: Find

    private lazy var finder = FindHost(view: self, target: self)
    private var findQuery = (text: "", caseSensitive: false)

    @objc override func performTextFinderAction(_ sender: Any?) { finder.perform(sender) }

    /// The block's log moved: a URL set there (from elsewhere) is loaded.
    func documentChanged() {
        guard let b = source(), let url = b.web?.url, url != shownURL else { return }
        shownURL = url
        if !keeper.restored {
            keeper.restored = true
            // Back as it was, if what was kept is of this page.
            if keeper.value("interactionURL") == url, let s = keeper.value("interaction"), let data = Data(base64Encoded: s) {
                web.interactionState = data
                return
            }
        }
        load(url)
    }

    /// A page kept as a file is read from there, with its folder.
    private func load(_ url: String) {
        guard let u = URL(string: url) else { return }
        if u.isFileURL {
            web.loadFileURL(u, allowingReadAccessTo: u.deletingLastPathComponent())
        } else {
            web.load(URLRequest(url: u))
        }
    }

    /// What was typed into the pill: an address, or words to search for.
    private func go(_ typed: String) {
        var s = typed.trimmingCharacters(in: .whitespaces)
        guard !s.isEmpty else { return }
        if !s.contains("://") {
            s = s.contains(" ") || !s.contains(".") ? "https://duckduckgo.com/?q=" + (s.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? s) : "https://" + s
        }
        load(s)
        window?.makeFirstResponder(web)
    }

    @objc func goBack(_ sender: Any?) { web.goBack() }
    @objc func goForward(_ sender: Any?) { web.goForward() }
    @objc func reloadPage(_ sender: Any?) { web.reload() }

    /// The pill, clicked, is the address to type over (⌘L too).
    var pillEdit: PillEdit? {
        PillEdit(text: web.url?.absoluteString ?? shownURL ?? "", placeholder: "Address, or words to search for") { [weak self] in self?.go($0) }
    }

    var pillItems: [NSMenuItem] {
        var items: [NSMenuItem] = []
        let b = ClosureMenuItem("Back", symbol: "chevron.left") { [weak self] in self?.goBack(nil) }
        b.isEnabled = web.canGoBack
        let f = ClosureMenuItem("Forward", symbol: "chevron.right") { [weak self] in self?.goForward(nil) }
        f.isEnabled = web.canGoForward
        items += [b, f, ClosureMenuItem("Reload", symbol: "arrow.clockwise") { [weak self] in self?.reloadPage(nil) }]
        if let url = web.url?.absoluteString {
            items.append(ClosureMenuItem("Copy Address", symbol: "doc.on.doc") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(url, forType: .string)
            })
        }
        return items
    }

    /// ⌘-click on a link: the system's handler; ⇧⌘-click: a web block
    /// beside this one; a plain click follows it here.
    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        guard action.navigationType == .linkActivated, let url = action.request.url, action.modifierFlags.contains(.command) else {
            decisionHandler(.allow)
            return
        }
        decisionHandler(.cancel)
        if action.modifierFlags.contains(.shift) { delegate?.webView(self, open: url) } else { NSWorkspace.shared.open(url) }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        let url = web.url?.absoluteString ?? ""
        keepInteraction()
        var events: [Event] = []
        if url != shownURL {
            shownURL = url
            events.append(.url(url, viaHost: false))
        }
        if let title = web.title, !title.isEmpty, title != source()?.web?.title { events.append(.title(title)) }
        if !events.isEmpty { delegate?.webView(self, append: events) }
    }

}

extension WebView: Searchable {
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
