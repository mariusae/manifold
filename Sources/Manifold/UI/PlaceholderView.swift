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
    private let button = FlatButton("Attach", style: .primary)

    init(placement: PlacementID, block: BlockID, label: String) {
        self.placement = placement
        self.block = block
        super.init(frame: .zero)
        wantsLayer = true
        themed { $0.layer?.backgroundColor = Theme.sheet(level: 0).cgColor }
        title.stringValue = "On \(label)"
        title.font = UIType.heading
        title.textColor = Theme.text
        title.alignment = .center
        note.stringValue = "Not attached to that host."
        note.font = UIType.body
        // On the sheet's grey, the secondary grey wouldn't read in the dark.
        note.textColor = Theme.text
        note.alignment = .center
        button.target = self
        button.action = #selector(attachClicked)
        button.isHidden = HostsFile.load().destination(of: block.host) == nil
        for v in [title, note, button] { addSubview(v) }
    }

    required init?(coder: NSCoder) { fatalError() }

    @objc private func attachClicked() { onAttach?() }

    /// The block on its way (just made, its host a round trip off): the
    /// tile's own paper, and nothing said unless it takes a while.
    func waitQuietly(paper: NSColor) {
        themed { $0.layer?.backgroundColor = paper.cgColor }
        for v in [title, note, button] as [NSView] { v.alphaValue = 0 }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
            guard let self, self.window != nil else { return }
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = Motion.base
                for v in [self.title, self.note, self.button] as [NSView] { v.animator().alphaValue = 1 }
            }
        }
    }

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
