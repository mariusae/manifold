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
    /// A path: cut short at its head, the file's name kept.
    var path = false
}

/// An outline row: a mark, the words, and the outcome in grey at the right.
final class OutlineRow: NSTableCellView {
    private let mark = NSView()
    /// The mark's color (a layer's, so set again when light and dark switch).
    private var markColor: NSColor = Theme.secondaryText.withAlphaComponent(0.6)
    private let title = NSTextField(labelWithString: "")
    private let detail = NSTextField.label(font: .monospacedDigitSystemFont(ofSize: 10.5, weight: .regular), color: Theme.secondaryText, align: .right)
    private var level = 0

    override init(frame: NSRect) {
        super.init(frame: frame)
        mark.wantsLayer = true
        mark.layer?.cornerRadius = Radius.hair
        themed { $0.mark.layer?.backgroundColor = $0.markColor.cgColor }
        title.font = UIType.body
        title.textColor = Theme.text
        title.lineBreakMode = .byTruncatingTail
        for v in [mark, title, detail] { addSubview(v) }
    }

    required init?(coder: NSCoder) { fatalError() }

    /// A heading over what's under it: the family's next face up (Ideal's
    /// Medium from its Book — its Bold, steps on, is a shout here).
    private static func heavier(_ f: NSFont) -> NSFont {
        guard let family = f.familyName, !family.hasPrefix(".") else { return .systemFont(ofSize: f.pointSize, weight: .semibold) }
        let weight = FontFace.weightClass(f.fontName) ?? 400
        guard let next = FontFace.faces(of: family, role: .technical).first(where: { $0.weight > weight }),
              let font = NSFont(name: next.postScript, size: f.pointSize) else { return f }
        return font
    }

    func show(_ e: OutlineEntry) {
        level = e.level
        // Set as the text it's from is (its quotes curled), but a command's as typed.
        title.stringValue = e.line != nil ? InlineMarkdown.curled(e.title) : e.title
        title.lineBreakMode = e.path ? .byTruncatingHead : .byTruncatingTail
        // What a text says of itself in the technical face, as a
        // conversation's steps are — the outline's own words (a lens's
        // chrome) in the system's; a command, code.
        if e.line != nil {
            let f = FontTheme.current.technicalFont(size: e.level == 0 ? 12 : 11.5)
            title.font = e.level == 0 ? Self.heavier(f) : f
        } else {
            title.font = FontTheme.code(11.5)
        }
        detail.stringValue = e.detail
        detail.isHidden = e.detail.isEmpty
        markColor = e.failed ? Theme.statusError : e.running ? Theme.accent : Theme.secondaryText.withAlphaComponent(0.6)
        effectiveAppearance.performAsCurrentDrawingAppearance { mark.layer?.backgroundColor = markColor.cgColor }
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
