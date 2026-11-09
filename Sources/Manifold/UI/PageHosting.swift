import AppKit
import WebKit

/// A view only it can draw (a page, in its own process): a picture of it
/// comes a moment later, from it.
protocol Snapshotting: AnyObject {
    func snapshot(_ done: @escaping (NSImage?) -> Void)
}

/// A tile whose content is a web page (a web tile, a Markdown preview):
/// found in, pictured, printed and its selection read, all by the page.
protocol PageHosting: PaneContent, Searchable, Snapshotting, Printable {
    /// The page, made if it isn't yet.
    var page: WKWebView { get }
    /// What's being found in it (⌘F).
    var pageFinder: PageFinder { get }
    /// The print job's name, if not WebKit's own.
    var printTitle: String? { get }
}

extension PageHosting {
    var printTitle: String? { nil }

    func search(_ query: String, caseSensitive: Bool, done: @escaping (Int?) -> Void) {
        pageFinder.search(query, caseSensitive: caseSensitive, in: page, done: done)
    }

    func findNext(forward: Bool) { pageFinder.findNext(forward: forward, in: page) }

    func endSearch() {
        pageFinder.end(in: page)
        window?.makeFirstResponder(page)
    }

    func textForFind(_ done: @escaping (String?) -> Void) { pageFinder.selection(in: page, done) }

    /// A picture of the page as it is now, when it's ready (for a card).
    func snapshot(_ done: @escaping (NSImage?) -> Void) {
        page.takeSnapshot(with: nil) { image, _ in done(image) }
    }

    /// The page as it shows, fitted to the paper's width.
    func printOperation() -> NSPrintOperation? {
        let info = (NSPrintInfo.shared.copy() as! NSPrintInfo)
        info.isVerticallyCentered = false
        let op = page.printOperation(with: info)
        op.view?.frame = page.bounds
        if let printTitle { op.jobTitle = printTitle }
        return op
    }

    func maniSelection() async -> ManiSelected? {
        await PageSelection.text(in: page).map { ManiSelected(text: $0) }
    }
}

/// Find (⌘F) in a web page, for the find pill: the query kept between
/// steps, the page searched by script (`PageFind`).
final class PageFinder {
    private var query = (text: "", caseSensitive: false)

    func search(_ text: String, caseSensitive: Bool, in web: WKWebView, done: @escaping (Int?) -> Void) {
        query = (text, caseSensitive)
        web.evaluateJavaScript(PageFind.search(text, caseSensitive: caseSensitive)) { n, _ in
            done(text.isEmpty ? nil : (n as? Int) ?? (n as? Double).map(Int.init))
        }
    }

    func findNext(forward: Bool, in web: WKWebView) {
        guard !query.text.isEmpty else { return }
        web.evaluateJavaScript(PageFind.next(query.text, caseSensitive: query.caseSensitive, forward: forward))
    }

    func end(in web: WKWebView) { web.evaluateJavaScript(PageFind.end) }

    /// The page's selection, for ⌘E.
    func selection(in web: WKWebView, _ done: @escaping (String?) -> Void) {
        web.evaluateJavaScript(PageFind.selection) { s, _ in done((s as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)) }
    }
}
