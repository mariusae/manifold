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
final class WebView: NSView, PaneContent, WKNavigationDelegate, NSTextFieldDelegate {
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
        web = WKWebView(frame: .zero, configuration: config)
        super.init(frame: .zero)
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

    func destroy() {}

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
        if let u = URL(string: url) { web.load(URLRequest(url: u)) }
    }

    func controlTextDidEndEditing(_ obj: Notification) {
        guard (obj.userInfo?["NSTextMovement"] as? Int) == NSTextMovement.return.rawValue else { return }
        var s = address.stringValue.trimmingCharacters(in: .whitespaces)
        guard !s.isEmpty else { return }
        if !s.contains("://") {
            s = s.contains(" ") || !s.contains(".") ? "https://duckduckgo.com/?q=" + (s.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? s) : "https://" + s
        }
        if let u = URL(string: s) { web.load(URLRequest(url: u)) }
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
