import AppKit
import ManifoldMarkdown
import ManifoldCore
import WebKit

protocol MarkdownViewDelegate: AnyObject {
    /// A link to another Markdown file was followed.
    func markdownView(_ view: MarkdownView, follow url: URL)
}

/// The preview lens on a text block: its Markdown rendered by cmark-gfm into
/// a web view, and rendered again as the text changes (edits in an editor
/// on the same block, or the file saved by another program), keeping the
/// scroll position.
final class MarkdownView: NSView, PaneContent, WKNavigationDelegate {
    let placement: PlacementID
    private(set) var block: BlockID
    private(set) var path: String
    weak var delegate: MarkdownViewDelegate?
    private let web: WKWebView
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
        web = WKWebView(frame: .zero, configuration: config)
        super.init(frame: .zero)
        web.navigationDelegate = self
        web.setValue(false, forKey: "drawsBackground")
        wantsLayer = true
        themed { $0.layer?.backgroundColor = Theme.windowBackground.cgColor }
        addSubview(web)
        web.loadFileURL(MarkdownPage.shell, allowingReadAccessTo: URL(fileURLWithPath: "/"))
    }

    required init?(coder: NSCoder) { fatalError() }

    func destroy() {
        renderWork?.cancel()
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
        web.frame = bounds
    }

    /// Moved between lenses: the page is drawn again, as WebKit lets a view
    /// taken out of its window go blank.
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard window != nil, loaded else { return }
        // The page is loaded afresh (its scroll position kept by the view).
        loaded = false
        renderedVersion = -1
        web.loadFileURL(MarkdownPage.shell, allowingReadAccessTo: URL(fileURLWithPath: "/"))
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        loaded = false
        renderedVersion = -1
        web.loadFileURL(MarkdownPage.shell, allowingReadAccessTo: URL(fileURLWithPath: "/"))
    }

    /// Shows another block, from the top.
    func show(block: BlockID, path: String) {
        guard block != self.block || path != self.path else { return }
        self.block = block
        self.path = path
        renderedVersion = -1
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
        let js = "manifoldRender(\(json(body)), \(json(base)), \(scrollToTop));"
        web.evaluateJavaScript(MarkdownPage.script + MarkdownPage.themeScript(theme) + js)
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
        delegate?.markdownView(self, follow: url)
    }
}
