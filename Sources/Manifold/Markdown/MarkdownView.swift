import AppKit
import ManifoldMarkdown
import ManifoldCore
import WebKit

protocol MarkdownViewDelegate: AnyObject {
    /// A link to another Markdown file was followed.
    func markdownView(_ view: MarkdownView, open path: String)
}

/// A live preview of a Markdown file: rendered by cmark-gfm into a web view,
/// and rendered again whenever the file changes, keeping the scroll position.
final class MarkdownView: NSView, PaneContent, WKNavigationDelegate {
    let pane: UUID
    private(set) var path: String
    weak var delegate: MarkdownViewDelegate?
    private let web: WKWebView
    private var watcher: FileWatcher?
    private var loaded = false
    var theme: FontTheme {
        didSet { if theme != oldValue, loaded { web.evaluateJavaScript(MarkdownPage.themeScript(theme)) } }
    }

    var focusView: NSView { web }
    var isDead: Bool { false }

    init(pane: UUID, path: String, theme: FontTheme) {
        self.pane = pane
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
        watch()
    }

    required init?(coder: NSCoder) { fatalError() }

    func destroy() {
        watcher = nil
    }

    override func layout() {
        super.layout()
        web.frame = bounds
    }

    /// Shows another file, from the top.
    func show(path: String) {
        guard path != self.path else { return }
        self.path = path
        watch()
        render(scrollToTop: true)
    }

    private func watch() {
        watcher = FileWatcher(path: path) { [weak self] in self?.render(scrollToTop: false) }
    }

    private func render(scrollToTop: Bool) {
        guard loaded else { return }
        let body: String
        if let data = FileManager.default.contents(atPath: path) {
            body = MarkdownRenderer.html(String(decoding: data, as: UTF8.self))
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

    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        guard action.navigationType == .linkActivated, let url = action.request.url else {
            // The page itself loading.
            decisionHandler(action.request.url == MarkdownPage.shell ? .allow : .cancel)
            return
        }
        decisionHandler(.cancel)
        let docDir = URL(fileURLWithPath: path).deletingLastPathComponent().standardizedFileURL.path
        if url.isFileURL {
            let target = url.standardizedFileURL.path
            if let fragment = url.fragment, target == docDir || target == path {
                // A link within this document.
                web.evaluateJavaScript("manifoldScrollTo(\(json(fragment)));")
            } else if ["md", "markdown", "mdown", "mkd", "mdx"].contains(url.pathExtension.lowercased()) {
                delegate?.markdownView(self, open: target)
            } else {
                NSWorkspace.shared.open(url)
            }
        } else {
            NSWorkspace.shared.open(url)
        }
    }
}

/// Watches a file, calling back when it changes. Editors often save by
/// writing a new file and renaming it over the old one, so on a rename or
/// delete the path is watched afresh.
final class FileWatcher {
    private let path: String
    private let onChange: () -> Void
    private var source: DispatchSourceFileSystemObject?
    private var pending: DispatchWorkItem?

    init(path: String, onChange: @escaping () -> Void) {
        self.path = path
        self.onChange = onChange
        start(retries: 0)
    }

    deinit { source?.cancel() }

    private func start(retries: Int) {
        source?.cancel()
        source = nil
        let fd = open(path, O_EVTONLY)
        guard fd >= 0 else {
            // Gone, perhaps mid-save: look again shortly, for a while.
            if retries < 20 {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
                    self?.start(retries: retries + 1)
                }
            }
            return
        }
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd, eventMask: [.write, .extend, .delete, .rename, .attrib, .link], queue: .main)
        source.setEventHandler { [weak self, weak source] in
            guard let self, let source else { return }
            if !source.data.isDisjoint(with: [.delete, .rename]) {
                self.start(retries: 0)
            }
            self.changed()
        }
        source.setCancelHandler { close(fd) }
        source.resume()
        self.source = source
        if retries > 0 { changed() }
    }

    private func changed() {
        pending?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.onChange() }
        pending = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05, execute: work)
    }
}
