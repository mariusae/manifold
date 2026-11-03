import AppKit
import ManifoldCore

/// The inspector (§3.5, ⌥⌘I): the focused block's properties in a window
/// of its own, as a Mac app's inspector is — a small panel floating over
/// every window (Manifold's and other apps'), staying up when Manifold
/// isn't in front, taking the keyboard only when a field in it needs it,
/// closed by its own button or ⌥⌘I again, its place and size kept. Its
/// rows are the sidebar's (`OrganizationView`): a click goes to what a
/// row names, or does what it says.
final class InspectorPanel: NSPanel {
    let list = OrganizationView()
    private let icon = NSImageView()
    private let name = NSTextField(labelWithString: "")
    private let what = NSTextField(labelWithString: "")
    private let header = NSView()
    /// Told when it's closed by its own button.
    var onClose: (() -> Void)?

    init() {
        super.init(contentRect: NSRect(x: 0, y: 0, width: 340, height: 600),
                   styleMask: [.titled, .closable, .resizable, .utilityWindow, .nonactivatingPanel],
                   backing: .buffered, defer: false)
        title = "Inspector"
        isFloatingPanel = true
        level = .floating
        hidesOnDeactivate = false
        becomesKeyOnlyIfNeeded = true
        isReleasedWhenClosed = false
        collectionBehavior = [.fullScreenAuxiliary, .canJoinAllSpaces]
        minSize = NSSize(width: 260, height: 240)
        let content = NSView()
        content.wantsLayer = true
        content.themed { $0.layer?.backgroundColor = Theme.panel.cgColor }
        icon.imageScaling = .scaleProportionallyDown
        name.font = UIType.heading
        name.textColor = Theme.text
        name.lineBreakMode = .byTruncatingMiddle
        what.font = UIType.detail
        what.textColor = Theme.secondaryText
        what.lineBreakMode = .byTruncatingTail
        for v in [icon, name, what] { header.addSubview(v) }
        content.addSubview(header)
        content.addSubview(list)
        contentView = content
        setFrameAutosaveName("Inspector")
        if frame.origin == .zero { center() }
    }

    /// What it shows: the block's name, what and where it is, its rows.
    func show(title: String, subtitle: String, symbol: String?, nodes: [OrgNode], open: Set<String>) {
        name.stringValue = title
        what.stringValue = subtitle
        icon.image = symbol.flatMap { Theme.symbol($0, size: 18, weight: .regular, color: Theme.secondaryText) }
        list.flat = true
        list.show(nodes, openByDefault: open)
        layoutContent()
    }

    override func close() {
        super.close()
        onClose?()
    }

    override func setFrame(_ frameRect: NSRect, display flag: Bool) {
        super.setFrame(frameRect, display: flag)
        layoutContent()
    }

    private func layoutContent() {
        guard let content = contentView else { return }
        let b = content.bounds, h: CGFloat = 54
        header.frame = NSRect(x: 0, y: b.height - h, width: b.width, height: h)
        icon.frame = NSRect(x: 14, y: (h - 24) / 2, width: 24, height: 24)
        name.frame = NSRect(x: 46, y: h / 2 + 1, width: b.width - 60, height: 19)
        what.frame = NSRect(x: 46, y: h / 2 - 17, width: b.width - 60, height: 16)
        list.frame = NSRect(x: 0, y: 0, width: b.width, height: b.height - h)
    }

    var debugState: String {
        "\(isVisible ? "shown" : "hidden") \(Int(frame.width))×\(Int(frame.height)) level \(level.rawValue): \(name.stringValue) — \(what.stringValue)"
    }
}
