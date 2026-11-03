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

    // Loading through a host (§7.6).

    /// How a host stands for a page that may be loaded through it: what
    /// it's called, and whether it's reached now; nil for this Mac.
    func webView(_ view: WebView, remoteHost host: HostID) -> (label: String, connected: Bool)?
    /// The data store of pages loaded through a host, once they can be.
    func webView(_ view: WebView, storeThrough host: HostID, done: @escaping (WKWebsiteDataStore?) -> Void)
    /// A port of a host's own localhost brought here for a page loaded
    /// through it: without a word, as it's the page's doing.
    func webView(_ view: WebView, forwardForPage port: Int, on host: HostID, done: @escaping (Int?) -> Void)
    /// The host and port a port here is forwarded from, if it is.
    func webView(_ view: WebView, forwardedFrom port: Int) -> (host: HostID, port: Int)?
    /// Why the host couldn't connect to an address, lately, if it couldn't.
    func webView(_ view: WebView, refusalOf host: String, port: Int, through: HostID) -> HostProxy.Refusal?
    /// A page of another host's own, loaded through it, beside this one.
    func webView(_ view: WebView, open url: URL, asPageOf host: HostID)
}

/// The web lens: an embedded browser on a web block, with an address bar,
/// back and forward, and find. Where it is goes in the block's log, so its
/// history is the pages it showed.
///
/// A web block on another host loads through it unless it says not to
/// (`WebState.viaHost`, §7.6): its pages are in the host's data store
/// (`WebStores`), whose connections the host makes, and the host's own
/// localhost — which WebKit reaches without a proxy — at ports forwarded
/// here. The block keeps its pages' addresses as the host has them
/// (`localhost:3000`, not the port here). Loaded the other way, the
/// page is made again in a web view of the other store.
final class WebView: NSView, PaneContent, KeepsViewState, Snapshotting, WKNavigationDelegate {
    let keeper = ViewStateKeeper()
    let placement: PlacementID
    let block: BlockID
    weak var delegate: WebViewDelegate?
    var source: () -> Block? = { nil }
    /// The page's view, made again (`install`) to load the other way.
    private var web: WKWebView!
    /// Why a page couldn't be opened (a name not found, nothing listening),
    /// in its place until the next goes — not a blank page.
    private let failure = BusyNote()
    fileprivate var webForPrinting: WKWebView { web }

    /// A picture of the page as it is now, when it's ready (for a card).
    func snapshot(_ done: @escaping (NSImage?) -> Void) {
        web.takeSnapshot(with: nil) { image, _ in done(image) }
    }
    private var shownURL: String?

    /// The host the page is loaded through, or nil: from here.
    private(set) var through: HostID?
    /// The host's store asked for (the web view to be made in it): what
    /// was to be loaded meanwhile.
    private var awaitingStore = false
    private var loadWhenReady: String?
    /// A page that failed for the host being away, as the block keeps
    /// its address: loaded again once the host is back.
    private var retryWhenBack: String?

    var focusView: NSView { web }
    var isDead: Bool { false }

    init(placement: PlacementID, block: BlockID) {
        self.placement = placement
        self.block = block
        super.init(frame: .zero)
        wantsLayer = true
        themed { $0.layer?.backgroundColor = Theme.windowBackground.cgColor }
        addSubview(failure)
        install(nil)
        documentChanged()
    }

    required init?(coder: NSCoder) { fatalError() }

    /// A web view of the store given (WebKit's default if none) in place of
    /// the last, the page it showed let go of.
    private func install(_ store: WKWebsiteDataStore?) {
        let old = web
        // The keyboard, if the page had it, goes to the page that's here now.
        let hadKeyboard = old.map { o in (window?.firstResponder as? NSView)?.isDescendant(of: o) == true } ?? false
        old?.navigationDelegate = nil
        old?.uiDelegate = nil
        old?.stopLoading()
        old?.removeFromSuperview()
        watching = []
        let config = WKWebViewConfiguration()
        if let store { config.websiteDataStore = store }
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
        handler.onState = { [weak self] _ in self?.keepInteraction() }
        config.userContentController.add(handler, name: "manifoldState")
        let selectionOwner = WeakView()
        selectionOwner.view = self
        PageSelection.watch(config) { selectionOwner.view }
        let web: WKWebView = PageWebView(frame: old?.frame ?? .zero, configuration: config)
        self.web = web
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
        addSubview(web, positioned: .below, relativeTo: failure)
        if hadKeyboard { window?.makeFirstResponder(web) }
        needsLayout = true
    }

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
        failure.frame = web.frame
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

    /// The block's log moved: a URL set there (from elsewhere) is loaded,
    /// the way the block says — from here, or through its host, the web
    /// view made again when that changed. A page that failed for its host
    /// being away is loaded again once the host is back.
    func documentChanged() {
        guard let b = source(), let url = b.web?.url else { return }
        let wanted = b.web?.viaHost == true && delegate?.webView(self, remoteHost: block.host) != nil ? block.host : nil
        if wanted != through { return reroute(to: wanted) }
        if let again = retryWhenBack, let h = through, delegate?.webView(self, remoteHost: h)?.connected == true {
            retryWhenBack = nil
            load(again)
        }
        guard !awaitingStore, url != shownURL else { return }
        shownURL = url
        if !keeper.restored {
            keeper.restored = true
            // Back as it was, if what was kept is of this page.
            if let kept = keeper.value("interactionURL"), let s = keeper.value("interaction"), let data = Data(base64Encoded: s) {
                return restore(data, of: kept, for: url)
            }
        }
        load(url)
    }

    /// Loads, forwards and stores asked for before the way of loading last
    /// changed are let go of when they come.
    private var generation = 0

    /// The page made again, in a web view of the way's store — the host's,
    /// once its proxy listens (nothing loaded before, and nothing left
    /// loading the other way meanwhile) — and what the block shows loaded
    /// there.
    private func reroute(to host: HostID?) {
        through = host
        generation += 1
        shownURL = nil
        retryWhenBack = nil
        loadWhenReady = nil
        failure.set(.idle)
        // The page loaded the other way goes now, not once this way's ready.
        if host == nil || web.url != nil || web.isLoading { install(nil) }
        guard let host else {
            awaitingStore = false
            return documentChanged()
        }
        awaitingStore = true
        let label = delegate?.webView(self, remoteHost: host)?.label ?? "its host"
        failure.set(.busy("Loading through \(label)…"))
        let gen = generation
        delegate?.webView(self, storeThrough: host) { [weak self] store in
            guard let self, self.generation == gen else { return }
            guard let store else {
                // Nothing goes from here instead: said, and left at that.
                return self.showFailure("Can't load pages through \(label): its proxy here couldn't start")
            }
            self.awaitingStore = false
            self.failure.set(.idle)
            self.install(store)
            let typed = self.loadWhenReady
            self.loadWhenReady = nil
            self.documentChanged()
            if let typed { self.load(typed) }
        }
    }

    /// WebKit's account of the page put back if it's of the page the block
    /// shows (a page of the host's own localhost once its port is here
    /// again, if it's here at the same port), else the page loaded afresh.
    private func restore(_ data: Data, of kept: String, for url: String) {
        guard let u = URL(string: url) else { return load(url) }
        let gen = generation
        here(u) { [weak self] local in
            guard let self, self.generation == gen else { return }
            if local?.absoluteString == kept {
                self.web.interactionState = data
            } else {
                self.load(url)
            }
        }
    }

    /// An address as the block keeps it, loaded: a page kept as a file
    /// read from there, with its folder; a page of the host's own
    /// localhost, loaded through it, at the port it's forwarded to here.
    private func load(_ url: String) {
        if awaitingStore {
            loadWhenReady = url
            return
        }
        retryWhenBack = nil
        guard let u = URL(string: url) else { return }
        if u.isFileURL {
            web.loadFileURL(u, allowingReadAccessTo: u.deletingLastPathComponent())
            return
        }
        let gen = generation
        here(u) { [weak self] local in
            guard let self, self.generation == gen else { return }
            guard let local else {
                let label = self.through.flatMap { self.delegate?.webView(self, remoteHost: $0)?.label } ?? "its host"
                return self.showFailure("Can't open \(WebAddress.plain(url)): its port couldn't be brought here from \(label)")
            }
            self.web.load(URLRequest(url: local))
        }
    }

    /// Where a page at an address (as the block keeps it) is loaded from,
    /// here: the address, or — the host's own localhost, through the host,
    /// which WebKit would take for this Mac's — the port forwarded here.
    private func here(_ u: URL, _ done: @escaping (URL?) -> Void) {
        guard let h = through, u.scheme == "http" || u.scheme == "https", let name = u.host, WebAddress.isLoopback(name) else { return done(u) }
        let port = u.port ?? (u.scheme == "https" ? 443 : 80)
        delegate?.webView(self, forwardForPage: port, on: h) { local in
            guard let local, var parts = URLComponents(url: u, resolvingAgainstBaseURL: false) else { return done(nil) }
            parts.host = "localhost"
            parts.port = local
            done(parts.url)
        }
    }

    /// A page's address as the block keeps it: loaded through the host
    /// (or as if through `host`), one at a port forwarded here from the
    /// host's localhost goes by the port there, as the host has it.
    private func kept(_ url: URL) -> String { kept(url, as: through) }

    private func kept(_ url: URL, as host: HostID?) -> String {
        guard let h = host, let name = url.host, WebAddress.isLoopback(name), let port = url.port,
              let from = delegate?.webView(self, forwardedFrom: port), from.host == h,
              var parts = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return url.absoluteString }
        parts.port = from.port == (url.scheme == "https" ? 443 : 80) ? nil : from.port
        return parts.url?.absoluteString ?? url.absoluteString
    }

    /// What was typed in the pill: an address (`localhost:3000` and the
    /// like as one), a port on an attached host's localhost (`slowbox:3000/x`),
    /// or words to search for.
    private func go(_ typed: String) {
        let s = typed.trimmingCharacters(in: .whitespaces)
        guard !s.isEmpty else { return }
        switch WebAddress.parse(s) {
        case let .page(address):
            // An attached host's name in a whole address (http://anotherone:8080/,
            // typed or a page completed): its own localhost, as host:port is.
            if let url = URL(string: address), let name = url.host, url.scheme == "http" || url.scheme == "https",
               let h = delegate?.webView(self, hostNamed: name) {
                let port = url.port ?? (url.scheme == "https" ? 443 : 80)
                var rest = url.path.isEmpty ? "/" : url.path
                if let q = url.query { rest += "?" + q }
                if let f = url.fragment { rest += "#" + f }
                localhost(port, on: h, scheme: url.scheme ?? "http", rest: rest)
                break
            }
            load(address)
        case let .search(words):
            search(words)
            return
        case let .hostPort(name, port, rest):
            if let h = delegate?.webView(self, hostNamed: name) {
                localhost(port, on: h, scheme: "http", rest: rest)
            } else {
                load("http://\(name):\(port)\(rest)")
            }
        }
        window?.makeFirstResponder(web)
    }

    /// A port of an attached host's own localhost: the page's own host's,
    /// loaded through it as the page's address. Another's, from a page
    /// loaded through a host — where every localhost is that host's — is
    /// a page of that host's own, beside; from a page loaded from here,
    /// it's forwarded here (as asked: said so) and loaded at the port here.
    private func localhost(_ port: Int, on h: HostID, scheme: String, rest: String) {
        if h == through { return load("\(scheme)://localhost:\(port)\(rest)") }
        if through != nil, let url = URL(string: "\(scheme)://localhost:\(port)\(rest)") {
            delegate?.webView(self, open: url, asPageOf: h)
            return
        }
        delegate?.webView(self, forward: port, on: h) { [weak self] local in
            guard let local else { return }
            self?.load("\(scheme)://localhost:\(local)\(rest)")
        }
    }

    private func titleChanged() {
        guard let title = web.title, !title.isEmpty, !web.isLoading || web.url.map(kept) == shownURL else { return }
        if title != source()?.web?.title { delegate?.webView(self, append: [.title(title)]) }
        if let u = web.url { delegate?.webView(self, visited: u, title: title, again: true) }
    }

    /// Loaded through the block's host, or from here (§7.6): the block's
    /// choice, kept with the page it's on.
    func loadThroughHost(_ on: Bool) {
        guard source()?.web?.viaHost != on else { return }
        // The address as the host has it, whichever way it was loaded (a
        // port of the host's forwarded here, typed from here, by its port
        // there): from here, then, it's this Mac's.
        let url = web.url.map { kept($0, as: block.host) } ?? shownURL ?? source()?.web?.url
        delegate?.webView(self, append: [.url(url, viaHost: on)])
    }

    /// Words looked for (a search engine's page).
    func search(_ words: String) {
        load("https://duckduckgo.com/?q=" + (words.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? words))
        window?.makeFirstResponder(web)
    }

    @objc func goBack(_ sender: Any?) { web.goBack() }
    @objc func goForward(_ sender: Any?) { web.goForward() }
    @objc func reloadPage(_ sender: Any?) { web.reload() }
    /// Reload, from the server: nothing taken from the cache.
    func reloadFromOrigin() { web.reloadFromOrigin() }
    @objc func stopLoading(_ sender: Any?) { web.stopLoading() }

    /// ⌘+, ⌘−, ⌘0: the page zoomed a step, as Safari steps it, or back.
    private static let zooms: [CGFloat] = [0.5, 0.75, 0.85, 1, 1.15, 1.25, 1.5, 1.75, 2, 2.5, 3]
    @objc func increaseFontSize(_ sender: Any?) { web.pageZoom = Self.zooms.first { $0 > web.pageZoom + 0.001 } ?? web.pageZoom }
    @objc func decreaseFontSize(_ sender: Any?) { web.pageZoom = Self.zooms.last { $0 < web.pageZoom - 0.001 } ?? web.pageZoom }
    @objc func resetFontSize(_ sender: Any?) { web.pageZoom = 1 }
    var debugZoom: CGFloat { web.pageZoom }
    /// Debugging: how the page is loaded, the address the block keeps, the
    /// one WebKit has, and the store it's in.
    var debugRoute: String {
        let store = web.configuration.websiteDataStore
        return [through.map { "through \($0.raw)" } ?? "from here", awaitingStore ? "waiting for its store" : nil,
                "block \(source()?.web?.url ?? "none")", "shown \(web.url?.absoluteString ?? "none")",
                "store \(store.identifier?.uuidString ?? (store.isPersistent ? "default" : "ephemeral"))",
                { if case let .message(m) = failure.state { "says \(m)" } else { nil } }()].compactMap { $0 }.joined(separator: "\n")
    }

    private var watching: [NSKeyValueObservation] = []

    /// Back, forward, and reload — stop, while it loads — on its bar; ⇧
    /// held on reload, from the server, the cache passed over. Before
    /// them, on another host's block, how it's loaded (§7.6): through the
    /// host, or from here — clicked, the other way.
    var barButtons: [BarButton] {
        let page = [BarButton(symbol: "chevron.left", tooltip: "Back (⌘[)", enabled: web.canGoBack) { [weak self] in self?.web.goBack() },
         BarButton(symbol: "chevron.right", tooltip: "Forward (⌘])", enabled: web.canGoForward) { [weak self] in self?.web.goForward() },
         web.isLoading
            ? BarButton(symbol: "xmark", tooltip: "Stop Loading", enabled: true) { [weak self] in self?.web.stopLoading() }
            : BarButton(symbol: "arrow.clockwise", tooltip: "Reload (⇧-click: from the Server)", enabled: true) { [weak self] in
                if NSApp.currentEvent?.modifierFlags.contains(.shift) == true { self?.web.reloadFromOrigin() } else { self?.web.reload() }
            }]
        guard let remote = delegate?.webView(self, remoteHost: block.host) else { return page }
        let way = through != nil
            ? BarButton(symbol: "server.rack", tooltip: "Loaded through \(remote.label) — click to load from This Mac", enabled: true) { [weak self] in self?.loadThroughHost(false) }
            : BarButton(symbol: "laptopcomputer", tooltip: "Loaded from This Mac — click to load through \(remote.label)", enabled: true) { [weak self] in self?.loadThroughHost(true) }
        return [way] + page
    }

    /// "Version/26.1 Safari/605.1.15", from the Safari that's installed.
    static let safari: String = {
        let info = NSDictionary(contentsOfFile: "/Applications/Safari.app/Contents/Info.plist")
            ?? NSDictionary(contentsOfFile: "/System/Volumes/Preboot/Cryptexes/App/System/Applications/Safari.app/Contents/Info.plist")
        let version = info?["CFBundleShortVersionString"] as? String ?? "26.0"
        return "Version/\(version) Safari/605.1.15"
    }()

    /// The pill, clicked, is the address to type over (⌘L too): through a
    /// host, as the host has it, and said to be its.
    var pillEdit: PillEdit? {
        let text = web.url.map { through != nil ? kept($0) : delegate?.webView(self, addressOf: $0) ?? $0.absoluteString } ?? shownURL ?? ""
        let on = through.flatMap { delegate?.webView(self, remoteHost: $0)?.label }
        var e = PillEdit(text: text, placeholder: on.map { "Address on \($0), or words to search for" } ?? "Address, or words to search for") { [weak self] in self?.go($0) }
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
        if let remote = delegate?.webView(self, remoteHost: block.host) {
            let on = through != nil
            let way = ClosureMenuItem("Load Through \(remote.label)", symbol: "server.rack") { [weak self] in self?.loadThroughHost(!on) }
            way.state = on ? .on : .off
            items.append(way)
        }
        if let url = web.url.map(kept) {
            items.append(ClosureMenuItem("Copy Address", symbol: "doc.on.doc") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(url, forType: .string)
            })
        }
        return items
    }

    /// A link in the page, as every link goes: a plain click follows it
    /// here, in the page, as a browser does; ⌘ a page beside, ⌥ (⌥⌘) over;
    /// ⇧⌘ the system's browser. Through a host, the page going to a port of
    /// the host's localhost not yet here has it brought here first.
    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        guard action.navigationType == .linkActivated, let url = action.request.url,
              !action.modifierFlags.isDisjoint(with: [.command, .option]) else {
            if through != nil, action.targetFrame?.isMainFrame == true, let url = action.request.url,
               url.scheme == "http" || url.scheme == "https", let name = url.host, WebAddress.isLoopback(name),
               delegate?.webView(self, forwardedFrom: url.port ?? (url.scheme == "https" ? 443 : 80))?.host != through {
                decisionHandler(.cancel)
                return load(url.absoluteString)
            }
            decisionHandler(.allow)
            return
        }
        decisionHandler(.cancel)
        if action.modifierFlags.isSuperset(of: [.command, .shift]) { NSWorkspace.shared.open(url) } else {
            delegate?.webView(self, open: URL(string: kept(url)) ?? url, over: action.modifierFlags.contains(.option))
        }
    }

    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        failure.set(.idle)
        web.isHidden = false
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { failed(error) }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { failed(error) }

    /// A page that couldn't be opened: said, in its place. (One left for
    /// another, or handed to another app, isn't a failure.) Through a
    /// host, why the host couldn't, as WebKit can't say it — and one that
    /// failed for the host being away is loaded again when it's back.
    private func failed(_ error: Error) {
        let e = error as NSError
        guard !(e.domain == NSURLErrorDomain && e.code == NSURLErrorCancelled), !(e.domain == "WebKitErrorDomain" && e.code == 102) else { return }
        let url = (e.userInfo[NSURLErrorFailingURLErrorKey] as? URL) ?? (e.userInfo[NSURLErrorFailingURLStringErrorKey] as? String).flatMap(URL.init(string:))
        let shown = url.map { through != nil ? kept($0) : delegate?.webView(self, addressOf: $0) ?? $0.absoluteString }.map(WebAddress.plain) ?? "the page"
        var why = e.localizedDescription
        if let h = through, let remote = delegate?.webView(self, remoteHost: h) {
            var away = !remote.connected
            if away {
                why = "\(remote.label) can't be reached now"
            } else if let url, let name = url.host,
                      let refusal = delegate?.webView(self, refusalOf: name, port: url.port ?? (url.scheme == "https" ? 443 : 80), through: h) {
                why = Self.why(refusal, name: name, port: url.port ?? (url.scheme == "https" ? 443 : 80), on: remote.label)
                away = refusal == .unreached
            }
            if away { retryWhenBack = url.map(kept) ?? shownURL }
        }
        showFailure("Can't open \(shown): \(why)")
    }

    /// Why a host couldn't connect, in words.
    static func why(_ refusal: HostProxy.Refusal, name: String, port: Int, on label: String) -> String {
        switch refusal {
        case .host(.notFound): "\(label) doesn't know the name \(name)"
        case .host(.refused): "\(name) refused \(label)'s connection at port \(port)"
        case .host(.unreachable): "\(label) has no way to \(name)"
        case .host(.timedOut): "\(name) didn't answer \(label) in time"
        case .host(.failed): "\(label) couldn't connect to \(name)"
        case .unreached: "\(label) can't be reached now"
        }
    }

    /// Said in the page's place, the page hidden, until the next goes.
    private func showFailure(_ text: String) {
        failure.set(.message(text))
        web.isHidden = true
        // The last page's headings went with it.
        headingsOutline.set([])
        delegate?.webViewBarChanged(self)
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        let url = web.url.map(kept) ?? ""
        keepInteraction()
        readHeadings()
        var events: [Event] = []
        if url != shownURL {
            shownURL = url
            events.append(.url(url, viaHost: source()?.web?.viaHost ?? false))
        }
        if let title = web.title, !title.isEmpty, title != source()?.web?.title { events.append(.title(title)) }
        if let u = web.url { delegate?.webView(self, visited: u, title: web.title, again: false) }
        if !events.isEmpty { delegate?.webView(self, append: events) }
        // Its site's icon, by the page's own hand (it reaches what the page does).
        web.callAsyncJavaScript(Favicons.script, arguments: [:], in: nil, in: .defaultClient) { result in
            if case .success(let value) = result, let data = value as? String { Favicons.take(data, forPage: url) }
        }
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
            delegate?.webView(self, open: URL(string: kept(url)) ?? url, over: false)
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

extension WebView {
    func maniSelection() async -> ManiSelected? {
        await PageSelection.text(in: web).map { ManiSelected(text: $0) }
    }

    func maniText(_ options: ManiReadOptions) async -> String? { await PageSelection.pageText(in: web) }
}
