import AppKit
import Quartz

/// A file as the Finder previews it (§7.4): Quick Look's view of it over
/// its name, its kind and size, and when it changed; a folder, its icon.
/// A file on another host is fetched to a local copy first, when it's
/// small enough to (else its icon stands in).
final class FilePreviewView: NSView {
    /// A local URL for a path: the file itself here; a copy fetched from
    /// another host; nil when it can't be had.
    var resolve: (String, @escaping (URL?) -> Void) -> Void = { p, done in done(URL(fileURLWithPath: p)) }

    private var quickLook: QLPreviewView?
    private let icon = NSImageView()
    private let name = NSTextField(labelWithString: "")
    private let info = NSTextField(labelWithString: "")
    private let date = NSTextField(labelWithString: "")
    private(set) var node: BrowserNode?
    private var token = 0

    override init(frame: NSRect) {
        super.init(frame: frame)
        icon.imageScaling = .scaleProportionallyUpOrDown
        name.font = .systemFont(ofSize: 13, weight: .semibold)
        name.textColor = Theme.text
        name.lineBreakMode = .byTruncatingMiddle
        for f in [info, date] {
            f.font = .systemFont(ofSize: 11.5)
            f.textColor = Theme.secondaryText
            f.lineBreakMode = .byTruncatingTail
        }
        for v in [icon, name, info, date] { addSubview(v) }
    }

    required init?(coder: NSCoder) { fatalError() }

    /// Quick Look let go of (it holds the file).
    func close() {
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
        guard let n, !n.isDirectory else { return needsLayout = true }
        let t = token
        resolve(n.path) { [weak self] url in
            guard let self, self.token == t, let url else { return }
            let q = self.quickLook ?? self.makeQuickLook()
            q.previewItem = url as NSURL
            q.isHidden = false
            self.icon.isHidden = true
            self.needsLayout = true
        }
        needsLayout = true
    }

    /// Debugging: what Quick Look was given, and whether it shows.
    var debugState: String {
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
        let side = min(area.width, area.height, 128)
        icon.frame = NSRect(x: area.midX - side / 2, y: area.midY - side / 2, width: side, height: side)
    }
}

/// The browser's preview column (§7.4): the preview of whatever leaf the
/// browser has selected, as it sets it.
final class FilePreviewController: NSViewController {
    let preview = FilePreviewView()
    var nodeShown: ((BrowserNode?) -> Void)?

    override func loadView() {
        // The browser sizes the column, not the view in it: it fills it.
        preview.frame = NSRect(x: 0, y: 0, width: 260, height: 400)
        preview.autoresizingMask = [.width, .height]
        view = preview
    }

    override var representedObject: Any? {
        didSet { preview.show(representedObject as? BrowserNode) }
    }
}
