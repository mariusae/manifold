import AppKit
import ManifoldCore
import WebKit

protocol WebViewDelegate: AnyObject {
    /// The page moved on (a link followed, an address typed): the block's
    /// log records where it is.
    func webView(_ view: WebView, append events: [Event])
    /// A link was ⇧⌘-clicked: opened as a block of its own, beside — or,
    /// with ⌥ too (`over`), over this one.
    func webView(_ view: WebView, open url: URL, over: Bool)
    /// Whether it can go back or forward, or loads, changed: its bar's
    /// buttons say so.
    func webViewBarChanged(_ view: WebView)
    /// What's typed in its address bar, completed: pages it's been to, the
    /// attached hosts.
    func webView(_ view: WebView, suggestionsFor typed: String) -> [PillSuggestion]
    /// The attached host a name in the address bar is (its label), if any.
    func webView(_ view: WebView, hostNamed name: String) -> HostID?
    /// A port of another host's brought here: the port here, or nil.
    func webView(_ view: WebView, forward port: Int, on host: HostID, done: @escaping (Int?) -> Void)
    /// An address as the bar shows it (a forwarded page by its host and
    /// port, `slowbox:3000/x`) and the history keeps it.
    func webView(_ view: WebView, addressOf url: URL) -> String
    /// A page shown (`again`: only its title come since): for the history.
    func webView(_ view: WebView, visited url: URL, title: String?, again: Bool)
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
    fileprivate var webForPrinting: WKWebView { web }

    /// A picture of the page as it is now, when it's ready (for a card).
    func snapshot(_ done: @escaping (NSImage?) -> Void) {
        web.takeSnapshot(with: nil) { image, _ in done(image) }
    }
    private var shownURL: String?

    var focusView: NSView { web }
    var isDead: Bool { false }

    init(placement: PlacementID, block: BlockID) {
        self.placement = placement
        self.block = block
        let config = WKWebViewConfiguration()
        // Safari's name and version after WebKit's: a page that doesn't know
        // a browser by the one alone (Google's) serves an old, plain version.
        config.applicationNameForUserAgent = Self.safari
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
        web = PageWebView(frame: .zero, configuration: config)
        super.init(frame: .zero)
        handler.onState = { [weak self] _ in self?.keepInteraction() }
        wantsLayer = true
        themed { $0.layer?.backgroundColor = Theme.windowBackground.cgColor }
        web.navigationDelegate = self
        web.uiDelegate = self
        // Its bar's buttons follow where it can go, and whether it loads.
        watching = [\WKWebView.canGoBack, \WKWebView.canGoForward, \WKWebView.isLoading].map { key in
            web.observe(key, options: []) { [weak self] _, _ in
                DispatchQueue.main.async { if let self { self.delegate?.webViewBarChanged(self) } }
            }
        }
        // Its title as the page sets it, which may be after it has loaded
        // (or as it changes): the block's, and the history's.
        watching.append(web.observe(\.title, options: []) { [weak self] _, _ in
            DispatchQueue.main.async { self?.titleChanged() }
        })
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
        var left: CGFloat = 0
        if let sidebar, !sidebar.isHidden {
            left = min(TileSidebar.width, (bounds.width / 3).rounded())
            sidebar.frame = NSRect(x: 0, y: 0, width: left, height: bounds.height)
        }
        web.frame = NSRect(x: left, y: 0, width: bounds.width - left, height: bounds.height)
        finder.layout(in: web.frame)
    }

    // MARK: The outline (§7.5)

    /// The page's headings, each chosen to go there: as ticks at the
    /// tile's upper right, and in the sidebar at its left.
    private lazy var headingsOutline: Outline = {
        let o = Outline()
        o.block = block
        o.onPick = { [weak self, weak o] i in
            self?.web.evaluateJavaScript("(function(){var h=document.querySelectorAll('h1,h2,h3,h4,h5,h6')[\(i)]; if(h){h.scrollIntoView({block:'start'});}})()")
            o?.current = i
        }
        return o
    }()
    var outline: Outline? { headingsOutline }
    private var sidebar: TileSidebar?
    var hasSidebar: Bool { true }
    var sidebarShown: Bool { sidebar?.isHidden == false }

    func toggleSidebar() {
        if sidebar == nil {
            let s = TileSidebar(outline: headingsOutline, emptyText: "No headings")
            s.isHidden = true
            addSubview(s)
            sidebar = s
        }
        sidebar?.isHidden.toggle()
        readHeadings()
        needsLayout = true
    }

    var debugSidebar: String { sidebar.map { $0.isHidden ? "hidden" : $0.debugEntries } ?? "none" }

    /// The headings as the page has them now (after each load, too).
    private func readHeadings() {
        let js = "(function(){var hs=document.querySelectorAll('h1,h2,h3,h4,h5,h6');var m=[];for(var i=0;i<hs.length;i++){m.push([hs[i].tagName,hs[i].textContent.trim().slice(0,160)]);}return m;})()"
        web.evaluateJavaScript(js) { [weak self] r, _ in
            let rows = (r as? [[Any]]) ?? []
            let headings = rows.compactMap { row -> (title: String, level: Int)? in
                guard row.count == 2, let tag = row[0] as? String, let text = row[1] as? String, !text.isEmpty else { return nil }
                return (text, Int(tag.dropFirst()) ?? 1)
            }
            self?.headingsOutline.set(Outline.headings(headings))
        }
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
    /// What was typed in the pill: an address (`localhost:3000` and the
    /// like as one), a port on an attached host's localhost (`slowbox:3000/x`,
    /// forwarded here first), or words to search for.
    private func go(_ typed: String) {
        let s = typed.trimmingCharacters(in: .whitespaces)
        guard !s.isEmpty else { return }
        switch WebAddress.parse(s) {
        case let .page(address):
            load(address)
        case let .search(words):
            search(words)
            return
        case let .hostPort(name, port, rest):
            if let h = delegate?.webView(self, hostNamed: name) {
                delegate?.webView(self, forward: port, on: h) { [weak self] local in
                    guard let local else { return }
                    self?.load("http://localhost:\(local)\(rest)")
                }
            } else {
                load("http://\(name):\(port)\(rest)")
            }
        }
        window?.makeFirstResponder(web)
    }

    private func titleChanged() {
        guard let title = web.title, !title.isEmpty, !web.isLoading || web.url?.absoluteString == shownURL else { return }
        if title != source()?.web?.title { delegate?.webView(self, append: [.title(title)]) }
        if let u = web.url { delegate?.webView(self, visited: u, title: title, again: true) }
    }

    /// Words looked for (a search engine's page).
    func search(_ words: String) {
        load("https://duckduckgo.com/?q=" + (words.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? words))
        window?.makeFirstResponder(web)
    }

    @objc func goBack(_ sender: Any?) { web.goBack() }
    @objc func goForward(_ sender: Any?) { web.goForward() }
    @objc func reloadPage(_ sender: Any?) { web.reload() }
    @objc func stopLoading(_ sender: Any?) { web.stopLoading() }

    private var watching: [NSKeyValueObservation] = []

    /// Back, forward, and reload — stop, while it loads — on its bar.
    var barButtons: [BarButton] {
        [BarButton(symbol: "chevron.left", tooltip: "Back (⌘[)", enabled: web.canGoBack) { [weak self] in self?.web.goBack() },
         BarButton(symbol: "chevron.right", tooltip: "Forward (⌘])", enabled: web.canGoForward) { [weak self] in self?.web.goForward() },
         web.isLoading
            ? BarButton(symbol: "xmark", tooltip: "Stop Loading", enabled: true) { [weak self] in self?.web.stopLoading() }
            : BarButton(symbol: "arrow.clockwise", tooltip: "Reload", enabled: true) { [weak self] in self?.web.reload() }]
    }

    /// "Version/26.1 Safari/605.1.15", from the Safari that's installed.
    static let safari: String = {
        let info = NSDictionary(contentsOfFile: "/Applications/Safari.app/Contents/Info.plist")
            ?? NSDictionary(contentsOfFile: "/System/Volumes/Preboot/Cryptexes/App/System/Applications/Safari.app/Contents/Info.plist")
        let version = info?["CFBundleShortVersionString"] as? String ?? "26.0"
        return "Version/\(version) Safari/605.1.15"
    }()

    /// The pill, clicked, is the address to type over (⌘L too).
    var pillEdit: PillEdit? {
        let text = web.url.map { delegate?.webView(self, addressOf: $0) ?? $0.absoluteString } ?? shownURL ?? ""
        var e = PillEdit(text: text, placeholder: "Address, or words to search for") { [weak self] in self?.go($0) }
        e.suggest = { [weak self] typed in
            guard let self else { return [] }
            return self.delegate?.webView(self, suggestionsFor: typed) ?? []
        }
        return e
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
        if action.modifierFlags.contains(.shift) { delegate?.webView(self, open: url, over: action.modifierFlags.contains(.option)) } else { NSWorkspace.shared.open(url) }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        let url = web.url?.absoluteString ?? ""
        keepInteraction()
        readHeadings()
        var events: [Event] = []
        if url != shownURL {
            shownURL = url
            events.append(.url(url, viaHost: false))
        }
        if let title = web.title, !title.isEmpty, title != source()?.web?.title { events.append(.title(title)) }
        if let u = web.url { delegate?.webView(self, visited: u, title: web.title, again: false) }
        if !events.isEmpty { delegate?.webView(self, append: events) }
    }

}

/// What a page asks of its window: a new one (a link with
/// `target=_blank`, `window.open`) is a web block beside this one; an
/// alert, a confirmation, a question and a file to upload are asked
/// over the window, as Safari asks them.
extension WebView: WKUIDelegate {
    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for action: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        if let url = action.request.url, url.absoluteString != "about:blank" {
            delegate?.webView(self, open: url, over: false)
        }
        return nil
    }

    func webView(_ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping () -> Void) {
        ask(message, from: frame, buttons: ["OK"]) { _ in completionHandler() }
    }

    func webView(_ webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping (Bool) -> Void) {
        ask(message, from: frame, buttons: ["OK", "Cancel"]) { completionHandler($0 == .alertFirstButtonReturn) }
    }

    func webView(_ webView: WKWebView, runJavaScriptTextInputPanelWithPrompt prompt: String, defaultText: String?,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping (String?) -> Void) {
        let field = NSTextField(string: defaultText ?? "")
        field.frame = NSRect(x: 0, y: 0, width: 280, height: 22)
        ask(prompt, from: frame, buttons: ["OK", "Cancel"], accessory: field) {
            completionHandler($0 == .alertFirstButtonReturn ? field.stringValue : nil)
        }
    }

    func webView(_ webView: WKWebView, runOpenPanelWith parameters: WKOpenPanelParameters,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping ([URL]?) -> Void) {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = parameters.allowsMultipleSelection
        panel.canChooseDirectories = parameters.allowsDirectories
        guard let window else { return completionHandler(panel.runModal() == .OK ? panel.urls : nil) }
        panel.beginSheetModal(for: window) { completionHandler($0 == .OK ? panel.urls : nil) }
    }

    /// The page's question as a sheet, headed by the site that asks.
    private func ask(_ message: String, from frame: WKFrameInfo, buttons: [String], accessory: NSView? = nil,
                     done: @escaping (NSApplication.ModalResponse) -> Void) {
        let alert = NSAlert()
        alert.messageText = frame.securityOrigin.host.isEmpty ? "This page says" : "\(frame.securityOrigin.host) says"
        alert.informativeText = message
        for b in buttons { alert.addButton(withTitle: b) }
        alert.accessoryView = accessory
        guard let window else { return done(alert.runModal()) }
        alert.beginSheetModal(for: window, completionHandler: done)
        if let accessory { alert.window.initialFirstResponder = accessory }
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

extension WebView: Printable {
    /// The page as it shows.
    func printOperation() -> NSPrintOperation? {
        let info = (NSPrintInfo.shared.copy() as! NSPrintInfo)
        info.isVerticallyCentered = false
        let op = webForPrinting.printOperation(with: info)
        op.view?.frame = webForPrinting.bounds
        return op
    }
}

/// A web tile's page: the app's own keys are the app's — ⌘L edits the
/// address (WebKit would take it, before the menu sees it).
final class PageWebView: WKWebView {
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let mods = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if mods == .command, event.charactersIgnoringModifiers?.lowercased() == "l" { return false }
        return super.performKeyEquivalent(with: event)
    }
}
