import AppKit

/// What the window shows with no space at all: a word on what a space is,
/// and the ways to make one — a terminal, a folder, or a block found again.
final class EmptyStateView: NSView {
    private let heading = NSTextField(labelWithString: "No spaces")
    private let note = NSTextField(wrappingLabelWithString: "A space is a grid of tiles — terminals, files, notes, pages. Make one to begin, or find a block you had.")
    private let buttons: [FlatButton]

    init(target: AnyObject) {
        buttons = [
            FlatButton("New Terminal", symbol: Marks.terminal, style: .primary, target: target, action: #selector(MainWindowController.newTerminal(_:))),
            FlatButton("Open Folder…", symbol: "folder", target: target, action: #selector(MainWindowController.openFolder(_:))),
            FlatButton("Open Quickly…", symbol: "magnifyingglass", target: target, action: #selector(MainWindowController.openDocument(_:))),
        ]
        super.init(frame: .zero)
        heading.font = UIType.heading
        heading.textColor = Theme.text
        heading.alignment = .center
        note.font = UIType.body
        note.textColor = Theme.secondaryText
        note.alignment = .center
        for b in buttons { b.sizeToFit() }
        for v in [heading, note] + buttons { addSubview(v) }
    }

    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }

    override func layout() {
        super.layout()
        let width: CGFloat = 340
        note.preferredMaxLayoutWidth = width
        let noteHeight = note.intrinsicContentSize.height
        let row = buttons.reduce(0) { $0 + $1.frame.width } + CGFloat(buttons.count - 1) * 8
        let height = 22 + 8 + noteHeight + 18 + Flat.buttonHeight
        var y = ((bounds.height - height) / 2).rounded()
        heading.frame = NSRect(x: (bounds.width - width) / 2, y: y, width: width, height: 22)
        y += 30
        note.frame = NSRect(x: (bounds.width - width) / 2, y: y, width: width, height: noteHeight)
        y += noteHeight + 18
        var x = ((bounds.width - row) / 2).rounded()
        for b in buttons {
            b.frame.origin = NSPoint(x: x, y: y)
            x += b.frame.width + 8
        }
    }
}
