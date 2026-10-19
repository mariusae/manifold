import AppKit
import ManifoldCore
import WebKit

protocol WebViewDelegate: AnyObject {
    /// The page moved on (a link followed, an address typed): the block's
    /// log records where it is.
    func webView(_ view: WebView, append events: [Event])
}

/// The web lens: an embedded browser on a web block, with an address bar,
/// back and forward, and find. Where it is goes in the block's log, so its
/// history is the pages it showed.
final class WebView: NSView, PaneContent, KeepsViewState, WKNavigationDelegate, NSTextFieldDelegate {
    let keeper = ViewStateKeeper()
    let placement: PlacementID
    let block: BlockID
    weak var delegate: WebViewDelegate?
    var source: () -> Block? = { nil }
    private let web: WKWebView
    private let bar = NSView()
    private let address = NSTextField()
    private let back = NSButton(title: "‹", target: nil, action: nil)
    private let forward = NSButton(title: "›", target: nil, action: nil)
    private let reload = NSButton(title: "↻", target: nil, action: nil)
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
        let handler = StateMessages()
        config.userContentController.add(handler, name: "manifoldState")
        web = WKWebView(frame: .zero, configuration: config)
        super.init(frame: .zero)
        handler.onState = { [weak self] _ in self?.keepInteraction() }
        wantsLayer = true
        themed { $0.layer?.backgroundColor = Theme.windowBackground.cgColor }
        web.navigationDelegate = self
        web.allowsBackForwardNavigationGestures = true
        bar.wantsLayer = true
        bar.themed { $0.layer?.backgroundColor = Theme.sheet(level: 0).cgColor }
        address.placeholderString = "Address"
        address.font = .systemFont(ofSize: 12.5)
        address.bezelStyle = .roundedBezel
        address.controlSize = .small
        address.delegate = self
        address.cell?.usesSingleLineMode = true
        address.cell?.lineBreakMode = .byTruncatingTail
        for b in [back, forward, reload] {
            b.bezelStyle = .rounded
            b.controlSize = .small
            b.target = self
        }
        back.action = #selector(goBack)
        forward.action = #selector(goForward)
        reload.action = #selector(reloadPage)
        for v in [back, forward, address, reload] { bar.addSubview(v) }
        addSubview(bar)
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

    override func layout() {
        super.layout()
        let h: CGFloat = 34
        bar.frame = NSRect(x: 0, y: bounds.height - h, width: bounds.width, height: h)
        back.frame = NSRect(x: 8, y: 5, width: 28, height: 24)
        forward.frame = NSRect(x: 38, y: 5, width: 28, height: 24)
        address.frame = NSRect(x: 74, y: 6, width: bounds.width - 74 - 46, height: 22)
        reload.frame = NSRect(x: bounds.width - 38, y: 5, width: 30, height: 24)
        web.frame = NSRect(x: 0, y: 0, width: bounds.width, height: bounds.height - h)
    }

    /// The block's log moved: a URL set there (from elsewhere) is loaded.
    func documentChanged() {
        guard let b = source(), let url = b.web?.url, url != shownURL else { return }
        shownURL = url
        address.stringValue = url
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

    func controlTextDidEndEditing(_ obj: Notification) {
        guard (obj.userInfo?["NSTextMovement"] as? Int) == NSTextMovement.return.rawValue else { return }
        var s = address.stringValue.trimmingCharacters(in: .whitespaces)
        guard !s.isEmpty else { return }
        if !s.contains("://") {
            s = s.contains(" ") || !s.contains(".") ? "https://duckduckgo.com/?q=" + (s.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? s) : "https://" + s
        }
        load(s)
        window?.makeFirstResponder(web)
    }

    @objc private func goBack() { web.goBack() }
    @objc private func goForward() { web.goForward() }
    @objc private func reloadPage() { web.reload() }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        back.isEnabled = web.canGoBack
        forward.isEnabled = web.canGoForward
        let url = web.url?.absoluteString ?? ""
        address.stringValue = url
        keepInteraction()
        var events: [Event] = []
        if url != shownURL {
            shownURL = url
            events.append(.url(url, viaHost: false))
        }
        if let title = web.title, !title.isEmpty, title != source()?.web?.title { events.append(.title(title)) }
        if !events.isEmpty { delegate?.webView(self, append: events) }
    }

    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        if let url = web.url?.absoluteString { address.stringValue = url }
    }
}
