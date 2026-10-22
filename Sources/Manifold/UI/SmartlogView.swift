import AppKit
import ManifoldCore
import WebKit

protocol SmartlogViewDelegate: AnyObject {
    /// The host's smartlog asked for (again): started, or the one running found.
    func smartlogStart(_ view: SmartlogView)
    /// Where to load the host's smartlog from here: as it is, for this Mac's;
    /// through a forwarded port, for another host's. Nil if it can't be.
    func smartlog(_ view: SmartlogView, localURL url: String, done: @escaping (URL?) -> Void)
    /// A link out of it (a pull request, a commit on GitHub).
    func smartlog(_ view: SmartlogView, open url: URL)
}

/// Sapling's Interactive Smartlog for a repository (§7.6), as a block of
/// its own: the page the host's `sl web` serves, with nothing of a browser
/// about it — no address, no back and forward, no browser's menu or
/// gestures — so it's a tile like any other. Until the host has it, or if
/// it can't, a line says so.
final class SmartlogView: NSView, PaneContent, WKNavigationDelegate, WKUIDelegate {
    let placement: PlacementID
    let block: BlockID
    weak var delegate: SmartlogViewDelegate?
    var source: () -> Block? = { nil }
    private let web: PlainWebView
    private let note = NSTextField(wrappingLabelWithString: "")
    /// The host's URL loaded (or being), and whether it has drawn.
    private var loaded: String?
    private var shown = false
    /// Asked the host again since the page last failed: once, not in a loop.
    private var retried = false

    var focusView: NSView { web }
    var isDead: Bool { false }

    init(placement: PlacementID, block: BlockID) {
        self.placement = placement
        self.block = block
        let config = WKWebViewConfiguration()
        config.preferences.isElementFullscreenEnabled = false
        web = PlainWebView(frame: .zero, configuration: config)
        super.init(frame: .zero)
        wantsLayer = true
        themed {
            $0.layer?.backgroundColor = Theme.windowBackground.cgColor
            $0.web.underPageBackgroundColor = Theme.windowBackground
        }
        web.navigationDelegate = self
        web.uiDelegate = self
        web.allowsBackForwardNavigationGestures = false
        web.allowsMagnification = false
        // Nothing white before the page draws.
        web.setValue(false, forKey: "drawsBackground")
        web.isHidden = true
        note.font = .systemFont(ofSize: 13)
        note.textColor = Theme.secondaryText
        note.alignment = .center
        addSubview(web)
        addSubview(note)
        refresh()
    }

    required init?(coder: NSCoder) { fatalError() }

    func destroy() {
        web.stopLoading()
        web.navigationDelegate = nil
        web.uiDelegate = nil
    }

    override func layout() {
        super.layout()
        web.frame = bounds
        let w = min(bounds.width - 40, 420)
        let h = note.sizeThatFits(NSSize(width: w, height: 200)).height
        note.frame = NSRect(x: (bounds.width - w) / 2, y: (bounds.height - h) / 2, width: w, height: h)
    }

    private func say(_ text: String) {
        note.stringValue = text
        note.isHidden = false
        web.isHidden = true
        needsLayout = true
    }

    /// The block as it stands: the page loaded once the host says where it
    /// is; what's wrong said, if it can't be.
    func refresh() {
        let s = source()?.smartlog
        if let error = s?.error { loaded = nil; return say(error) }
        guard let url = s?.url else { return say("Starting Interactive Smartlog…") }
        guard url != loaded else { return }
        loaded = url
        shown = false
        if web.isHidden { say("Opening Interactive Smartlog…") }
        delegate?.smartlog(self, localURL: url) { [weak self] local in
            guard let self, self.loaded == url else { return }
            guard let local else { return self.say("The host's smartlog can't be reached from here") }
            self.web.load(URLRequest(url: local))
        }
    }

    // MARK: The page

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        shown = true
        retried = false
        note.isHidden = true
        web.isHidden = false
    }

    /// Not there (the host's `sl web` stopped, say): asked for again, once.
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { failed() }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { failed() }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) { web.reload() }

    private func failed() {
        guard !retried else { return say("Interactive Smartlog stopped; it's asked for again when this tile is shown") }
        retried = true
        loaded = nil
        say("Starting Interactive Smartlog…")
        delegate?.smartlogStart(self)
    }

    /// The smartlog's own pages stay here; a link anywhere else (a pull
    /// request, a commit on the forge) goes out, as links do.
    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        guard let url = action.request.url, let here = web.url ?? (loaded.flatMap(URL.init(string:))) else { return decisionHandler(.allow) }
        if url.scheme == "about" || (url.host == here.host && url.port == here.port) || action.targetFrame?.isMainFrame == false {
            return decisionHandler(.allow)
        }
        decisionHandler(.cancel)
        delegate?.smartlog(self, open: url)
    }

    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for action: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        if let url = action.request.url { delegate?.smartlog(self, open: url) }
        return nil
    }

    func webView(_ webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping (Bool) -> Void) {
        let alert = NSAlert()
        alert.messageText = message
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Cancel")
        guard let window else { return completionHandler(alert.runModal() == .alertFirstButtonReturn) }
        alert.beginSheetModal(for: window) { completionHandler($0 == .alertFirstButtonReturn) }
    }

    func webView(_ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping () -> Void) {
        let alert = NSAlert()
        alert.messageText = message
        guard let window else { alert.runModal(); return completionHandler() }
        alert.beginSheetModal(for: window) { _ in completionHandler() }
    }

    /// Debugging: what it shows.
    var debugState: String {
        "loaded \(loaded ?? "-") shown \(shown) note \(note.isHidden ? "hidden" : "“\(note.stringValue)”") page \(web.url?.absoluteString ?? "-")"
    }

    var pillItems: [NSMenuItem] {
        [ClosureMenuItem("Reload Smartlog", symbol: "arrow.clockwise") { [weak self] in
            guard let self else { return }
            self.loaded = nil
            self.retried = false
            self.delegate?.smartlogStart(self)
        }]
    }
}

/// A web view with nothing of a browser's own: its menu keeps what's about
/// the text (copy, look up), not reload, back, or inspect.
final class PlainWebView: WKWebView {
    private static let kept: Set<String> = ["WKMenuItemIdentifierCopy", "WKMenuItemIdentifierCut", "WKMenuItemIdentifierPaste",
                                            "WKMenuItemIdentifierLookUp", "WKMenuItemIdentifierTranslate", "WKMenuItemIdentifierShareMenu"]

    override func willOpenMenu(_ menu: NSMenu, with event: NSEvent) {
        for item in menu.items {
            guard let id = item.identifier?.rawValue, id.hasPrefix("WKMenuItemIdentifier"), !Self.kept.contains(id) else { continue }
            menu.removeItem(item)
        }
        // No separators left at the ends, or two together.
        while menu.items.first?.isSeparatorItem == true { menu.removeItem(at: 0) }
        while menu.items.last?.isSeparatorItem == true { menu.removeItem(at: menu.items.count - 1) }
        var i = 1
        while i < menu.items.count {
            if menu.items[i].isSeparatorItem, menu.items[i - 1].isSeparatorItem { menu.removeItem(at: i) } else { i += 1 }
        }
        super.willOpenMenu(menu, with: event)
    }
}
