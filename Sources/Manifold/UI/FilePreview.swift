import AppKit
import ManifoldCore
import Quartz

/// A file as the Finder previews it (§7.4): Quick Look's view of it over
/// its name, its kind and size, and when it changed; a folder, its icon.
/// Markdown is rendered as a preview tile renders it, not by Quick Look
/// (whose page didn't scroll, its lines broken where the text's are); and
/// a file Quick Look doesn't know (an extension the system's never heard
/// of: .thrift, .bzl) that's text all the same — no NULs, UTF-8 — shown
/// as its text, not an icon.
/// A file on another host is fetched to a local copy first, when it's
/// small enough to (else its icon stands in).
final class FilePreviewView: NSView {
    /// A local URL for a path: the file itself here; a copy fetched from
    /// another host; nil when it can't be had. What it returns gives up.
    var resolve: (String, @escaping (URL?) -> Void) -> () -> Void = { p, done in done(URL(fileURLWithPath: p)); return {} }

    private var quickLook: QLPreviewView?
    /// Makes a Markdown page for a path, its text from the closure given
    /// (the tile's, so its links go as a preview's); nil: Quick Look's.
    var makePage: ((String, @escaping () -> (text: String, version: Int)?) -> MarkdownView?)?
    private var page: MarkdownView?
    /// A text file's words, where Quick Look would show only its icon.
    private var plain: NSScrollView?
    private var pageText: (text: String, version: Int)?
    private let icon = NSImageView()
    private let name = NSTextField.label(font: UIType.title, cut: .byTruncatingMiddle)
    private let info = NSTextField.label(font: UIType.detail, color: Theme.secondaryText)
    private let date = NSTextField.label(font: UIType.detail, color: Theme.secondaryText)
    private(set) var node: BrowserNode?
    private var token = 0
    /// Gives up on the file being fetched for the preview, if one is.
    private var cancel: (() -> Void)?
    /// When the last was shown: another soon after is the selection
    /// moving through, its preview put off till it stops.
    private var lastShown = Date.distantPast

    override init(frame: NSRect) {
        super.init(frame: frame)
        icon.imageScaling = .scaleProportionallyUpOrDown
        for v in [icon, name, info, date] { addSubview(v) }
    }

    required init?(coder: NSCoder) { fatalError() }

    /// Quick Look let go of (it holds the file).
    func close() {
        cancel?()
        cancel = nil
        quickLook?.close()
        quickLook?.removeFromSuperview()
        quickLook = nil
    }

    func show(_ n: BrowserNode?) {
        guard n?.path != node?.path || n?.entry != node?.entry else { return }
        node = n
        token += 1
        name.stringValue = n?.name ?? ""
        info.stringValue = n.map { $0.isDirectory ? "Folder" : "\($0.kind) · \($0.sizeText)" } ?? ""
        date.stringValue = n.map { "Modified " + $0.modifiedText } ?? ""
        icon.image = n?.icon
        icon.isHidden = n == nil
        quickLook?.isHidden = true
        page?.isHidden = true
        plain?.isHidden = true
        cancel?()
        cancel = nil
        let now = Date(), passing = now.timeIntervalSince(lastShown) < 0.25
        lastShown = now
        guard let n, !n.isDirectory else { return needsLayout = true }
        let t = token
        // Arrowing through: the name and kind at once, Quick Look (and a
        // remote file's fetch) once the selection stays a moment.
        DispatchQueue.main.asyncAfter(deadline: .now() + (passing ? 0.12 : 0)) { [weak self] in
            guard let self, self.token == t else { return }
            let stop = self.resolve(n.path) { [weak self] url in
                guard let self, self.token == t else { return }
                self.cancel = nil
                guard let url else { return }
                if Lens.isMarkdown(n.path), self.makePage != nil, n.entry.size <= 4_000_000 { return self.showPage(url, for: n, token: t) }
                if !Self.quickLookKnows(url) { return self.showPlainIfText(url, token: t) }
                let q = self.quickLook ?? self.makeQuickLook()
                q.previewItem = url as NSURL
                q.isHidden = false
                self.icon.isHidden = true
                self.needsLayout = true
            }
            if self.token == t { self.cancel = stop }
        }
        needsLayout = true
    }

    /// Markdown, read (off the main thread) and rendered.
    private func showPage(_ url: URL, for n: BrowserNode, token t: Int) {
        DispatchQueue.global(qos: .userInitiated).async {
            let text = (try? Data(contentsOf: url)).map { String(decoding: $0, as: UTF8.self) }
            DispatchQueue.main.async { [weak self] in
                guard let self, self.token == t, let text else { return }
                self.pageText = (text, (self.pageText?.version ?? 0) + 1)
                if self.page == nil, let p = self.makePage?(n.path, { [weak self] in self?.pageText }) {
                    self.addSubview(p)
                    self.page = p
                }
                guard let p = self.page else { return }
                p.show(block: p.block, path: n.path)
                p.textChanged()
                p.isHidden = false
                self.icon.isHidden = true
                self.needsLayout = true
            }
        }
    }

    /// Whether Quick Look has something to show for it beyond its icon:
    /// a type the system knows as text, code, a picture, a document.
    static func quickLookKnows(_ url: URL) -> Bool {
        guard let type = UTType(filenameExtension: url.pathExtension), !type.isDynamic else { return false }
        return [.text, .sourceCode, .image, .movie, .audio, .pdf, .compositeContent, .presentation, .spreadsheet, .archive, .font, .threeDContent]
            .contains { type.conforms(to: $0) }
    }

    /// Whether the start of some bytes is text: no NULs, and UTF-8 but
    /// for a character cut off at its end.
    static func looksLikeText(_ data: Data) -> Bool {
        guard !data.contains(0) else { return false }
        if String(data: data, encoding: .utf8) != nil { return true }
        // Cut mid-character at the end: what's before it.
        for cut in 1...3 where data.count > cut {
            if String(data: data.dropLast(cut), encoding: .utf8) != nil { return true }
        }
        return false
    }

    /// Its words, if it's text (its first 512 KB); else Quick Look's icon.
    private func showPlainIfText(_ url: URL, token t: Int) {
        DispatchQueue.global(qos: .userInitiated).async {
            let handle = try? FileHandle(forReadingFrom: url)
            let data = (try? handle?.read(upToCount: 512 * 1024)) ?? nil
            try? handle?.close()
            let text = data.flatMap { Self.looksLikeText($0.prefix(8192)) ? String(decoding: $0, as: UTF8.self) : nil }
            DispatchQueue.main.async { [weak self] in
                guard let self, self.token == t else { return }
                guard let text else {
                    let q = self.quickLook ?? self.makeQuickLook()
                    q.previewItem = url as NSURL
                    q.isHidden = false
                    self.icon.isHidden = true
                    self.needsLayout = true
                    return
                }
                let scroll = self.plain ?? self.makePlain()
                let tv = scroll.documentView as! NSTextView
                tv.string = text
                tv.font = FontTheme.current.technicalFont(size: 11.5)
                tv.textColor = Theme.text
                tv.scroll(.zero)
                scroll.isHidden = false
                self.icon.isHidden = true
                self.needsLayout = true
            }
        }
    }

    private func makePlain() -> NSScrollView {
        let scroll = NSTextView.scrollableTextView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        let tv = scroll.documentView as! NSTextView
        tv.isEditable = false
        tv.isSelectable = true
        tv.drawsBackground = false
        tv.isRichText = false
        tv.textContainerInset = NSSize(width: 4, height: 6)
        addSubview(scroll)
        plain = scroll
        return scroll
    }

    /// Debugging: what Quick Look was given, and whether it shows.
    var debugState: String {
        if let page, !page.isHidden { return "page \(page.path.lastPathComponent)" }
        if let plain, !plain.isHidden { return "text \((plain.documentView as? NSTextView)?.string.count ?? 0) characters" }
        guard let q = quickLook else { return "no quick look" }
        return "quick look \((q.previewItem?.previewItemURL)?.lastPathComponent ?? "nothing")\(q.isHidden ? " hidden" : "")"
    }

    private func makeQuickLook() -> QLPreviewView {
        let q = QLPreviewView(frame: .zero, style: .compact)!
        q.shouldCloseWithWindow = false
        q.autostarts = true
        addSubview(q)
        quickLook = q
        return q
    }

    override func layout() {
        super.layout()
        let pad: CGFloat = 14
        let infoHeight: CGFloat = 58
        let w = bounds.width - 2 * pad
        date.frame = NSRect(x: pad, y: pad, width: w, height: 15)
        info.frame = NSRect(x: pad, y: date.frame.maxY + 2, width: w, height: 15)
        name.frame = NSRect(x: pad, y: info.frame.maxY + 2, width: w, height: 18)
        let area = NSRect(x: pad, y: pad + infoHeight, width: w, height: max(0, bounds.height - infoHeight - 2 * pad))
        quickLook?.frame = area
        page?.frame = area
        plain?.frame = area
        let side = min(area.width, area.height, 128)
        icon.frame = NSRect(x: area.midX - side / 2, y: area.midY - side / 2, width: side, height: side)
    }
}
