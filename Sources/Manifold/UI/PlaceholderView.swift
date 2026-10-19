import AppKit
import ManifoldCore

/// A tile for a block on a host this client isn't attached to (§8): the
/// host's label, and a way to attach. Made again as the real thing once
/// the block is known.
final class PlaceholderView: NSView, PaneContent {
    let placement: PlacementID
    let block: BlockID
    var focusView: NSView { self }
    /// Whether the block has since become known: then this is dead.
    var known: () -> Bool = { false }
    var isDead: Bool { known() }
    var onAttach: (() -> Void)?
    private let title = NSTextField(labelWithString: "")
    private let note = NSTextField(labelWithString: "")
    private let button = NSButton(title: "Attach", target: nil, action: nil)

    init(placement: PlacementID, block: BlockID, label: String) {
        self.placement = placement
        self.block = block
        super.init(frame: .zero)
        wantsLayer = true
        themed { $0.layer?.backgroundColor = Theme.sheet(level: 0).cgColor }
        title.stringValue = "On \(label)"
        title.font = .systemFont(ofSize: 14, weight: .semibold)
        title.textColor = Theme.text
        title.alignment = .center
        note.stringValue = "Not attached to that host."
        note.font = .systemFont(ofSize: 12)
        note.textColor = Theme.secondaryText
        note.alignment = .center
        button.bezelStyle = .rounded
        button.controlSize = .small
        button.target = self
        button.action = #selector(attachClicked)
        button.isHidden = HostsFile.load().destination(of: block.host) == nil
        for v in [title, note, button] { addSubview(v) }
    }

    required init?(coder: NSCoder) { fatalError() }

    @objc private func attachClicked() { onAttach?() }

    /// What's said under the host's name, as its standing changes.
    func set(note text: String, canAttach: Bool) {
        if note.stringValue != text { note.stringValue = text; needsLayout = true }
        button.isHidden = !canAttach
    }

    override func layout() {
        super.layout()
        let mid = bounds.midY
        title.sizeToFit()
        note.sizeToFit()
        button.sizeToFit()
        title.frame = NSRect(x: 0, y: mid + 8, width: bounds.width, height: title.frame.height)
        note.frame = NSRect(x: 0, y: mid - 12, width: bounds.width, height: note.frame.height)
        button.frame = NSRect(x: (bounds.width - button.frame.width) / 2, y: mid - 44, width: button.frame.width, height: button.frame.height)
    }

    func destroy() {}
}
