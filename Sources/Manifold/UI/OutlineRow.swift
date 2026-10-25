import AppKit
import ManifoldCore

/// An outline's entry as a row shows it (a tile's sidebar, the outline
/// search): a command, a heading, a symbol.
struct OutlineEntry: Equatable {
    /// A command's id, or an entry's index in its outline.
    var id: Int
    /// A heading's line (0-based) in the text; nil for code (a command).
    var line: Int?
    var title: String
    var detail: String
    var level = 0
    var failed = false
    var running = false
}

/// An outline row: a mark, the words, and the outcome in grey at the right.
final class OutlineRow: NSTableCellView {
    private let mark = NSView()
    private let title = NSTextField(labelWithString: "")
    private let detail = NSTextField(labelWithString: "")
    private var level = 0

    override init(frame: NSRect) {
        super.init(frame: frame)
        mark.wantsLayer = true
        mark.layer?.cornerRadius = Radius.hair
        title.font = UIType.body
        title.textColor = Theme.text
        title.lineBreakMode = .byTruncatingTail
        detail.font = .monospacedDigitSystemFont(ofSize: 10.5, weight: .regular)
        detail.textColor = Theme.secondaryText
        detail.alignment = .right
        for v in [mark, title, detail] { addSubview(v) }
    }

    required init?(coder: NSCoder) { fatalError() }

    func show(_ e: OutlineEntry) {
        level = e.level
        title.stringValue = e.title
        title.font = e.line != nil ? .systemFont(ofSize: e.level == 0 ? 12.5 : 12, weight: e.level == 0 ? .semibold : .regular) : FontTheme.code(11.5)
        detail.stringValue = e.detail
        detail.isHidden = e.detail.isEmpty
        mark.layer?.backgroundColor = (e.failed ? Theme.statusError : e.running ? Theme.accent : Theme.secondaryText.withAlphaComponent(0.6)).cgColor
        toolTip = e.title
        needsLayout = true
    }

    override func layout() {
        super.layout()
        let h = bounds.height
        let x = 12 + CGFloat(level) * 14
        mark.frame = NSRect(x: x, y: (h - 3) / 2, width: 3, height: 3)
        var right = bounds.width - 10
        if !detail.isHidden {
            let w = min(140, ceil((detail.stringValue as NSString).size(withAttributes: [.font: detail.font!]).width) + 2)
            detail.frame = NSRect(x: right - w, y: (h - 14) / 2, width: w, height: 14)
            right -= w + 8
        }
        title.frame = NSRect(x: x + 10, y: (h - 16) / 2, width: max(0, right - x - 10), height: 16)
    }
}
