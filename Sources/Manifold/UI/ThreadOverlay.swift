import AppKit
import ManifoldCore

/// The threads' overlay (§3.12), over the window from anywhere (⌥⌘M),
/// taking no tile: the place you're at (a terminal's command, a PDF's
/// page, a page's selection, else the tile; else the space), its threads,
/// or the composer for one. The space's timeline is the sidebar's. ⎋
/// closes it; its ↖↘ makes the thread a tile; a place in it clicked is
/// gone to, the overlay kept.
final class ThreadOverlayView: NSView {
    let chat = ThreadChatView()
    private let close = IconButton(symbol: "xmark", size: 10, target: nil, action: nil)
    private let popOut = IconButton(symbol: "arrow.up.left.and.arrow.down.right", size: 10, target: nil, action: nil)
    private let titleLabel = NSTextField(labelWithString: "")
    var onClose: (() -> Void)?
    var onPopOut: (() -> Void)?
    /// The place, and its threads, stepped through.
    var herePlace: ThreadPlace?
    var hereThreads: [BlockID] = []
    var hereTitle = "" { didSet { titleLabel.stringValue = hereTitle } }
    /// A thread to make a tile of (none yet: a new one's composer).
    var canPopOut = false { didSet { popOut.isEnabled = canPopOut; popOut.alphaValue = canPopOut ? 1 : 0.35 } }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.cornerRadius = 12
        layer?.masksToBounds = false
        shadow = NSShadow()
        layer?.shadowOpacity = 0.35
        layer?.shadowRadius = 18
        layer?.shadowOffset = NSSize(width: 0, height: -6)
        close.target = self
        close.action = #selector(closeClicked)
        close.toolTip = "Close (⎋)"
        popOut.target = self
        popOut.action = #selector(popOutClicked)
        popOut.toolTip = "Open as a Tile"
        titleLabel.font = .systemFont(ofSize: 13, weight: .semibold)
        titleLabel.textColor = Theme.text
        titleLabel.lineBreakMode = .byTruncatingMiddle
        chat.fits = false
        chat.showsTileButton = false
        for v in [titleLabel, popOut, close, chat] as [NSView] { addSubview(v) }
        themed { v in
            // Lighter than the window it's over, its edge a hairline.
            v.layer?.backgroundColor = Theme.panel.cgColor
            v.layer?.borderColor = Theme.panelBorder.cgColor
            v.layer?.borderWidth = 0.5
        }
    }

    required init?(coder: NSCoder) { fatalError() }

    @objc private func closeClicked() { onClose?() }
    @objc private func popOutClicked() { onPopOut?() }

    /// ⎋, wherever the keyboard is in it.
    override func cancelOperation(_ sender: Any?) { onClose?() }

    func focus() { window?.makeFirstResponder(chat.composer) }

    override func layout() {
        super.layout()
        let pad: CGFloat = 12
        let top = bounds.height - pad - 20
        close.frame = NSRect(x: bounds.width - pad - 18, y: top + 1, width: 18, height: 18)
        popOut.frame = NSRect(x: close.frame.minX - 24, y: top + 1, width: 18, height: 18)
        titleLabel.frame = NSRect(x: pad + 4, y: top + 1, width: max(0, popOut.frame.minX - pad - 12), height: 18)
        chat.frame = NSRect(x: 0, y: 0, width: bounds.width, height: top - 4)
    }

    // Clicks stop here, not on the tiles beneath.
    override func mouseDown(with event: NSEvent) {}
}

extension MainWindowController {
    /// ⌥⌘M where there's no editor's or diff's place: the overlay, on the
    /// place you're at (`place`, else the space), or a thread asked for.
    func showThreadOverlay(_ place: ThreadPlace?, thread: BlockID? = nil, tab: Int? = nil) {
        if let o = threadUI.overlay, o.superview != nil, place == nil, thread == nil { return closeThreadOverlay() }
        threadUI.popover?.close()
        let o = threadUI.overlay ?? ThreadOverlayView()
        threadUI.overlay = o
        o.onClose = { [weak self] in self?.closeThreadOverlay() }
        o.chat.composer.onCancel = { [weak self] in self?.closeThreadOverlay() }
        o.onPopOut = { [weak self, weak o] in
            guard let self, let id = o?.chat.threadID else { return }
            self.closeThreadOverlay()
            self.popOutThread(id)
        }
        // The thread asked for, else the place given — else the space.
        var here: ThreadPlace? = thread == nil ? place : nil
        if thread == nil, here == nil, let space = selected {
            here = ThreadPlace(block: space, title: hosts.arrangement(space).map(title(of:)))
        }
        o.herePlace = here
        o.hereThreads = thread.map { [$0] } ?? here.map { p in hosts.threads(about: p.block, anchor: p.anchor).sorted { $0.created > $1.created }.map(\.id) } ?? []
        let openHere = o.hereThreads.first { hosts.block($0)?.thread?.resolved != true } ?? o.hereThreads.first
        o.chat.threadID = openHere
        o.chat.newPlace = openHere == nil ? here : nil
        o.chat.newSpace = selected
        o.canPopOut = openHere != nil
        o.hereTitle = (thread.flatMap { hosts.block($0)?.thread?.title } ?? openHere.flatMap { hosts.block($0)?.thread?.title })
            ?? ((thread.flatMap { hosts.block($0)?.thread?.about } ?? here).map { describe($0).title } ?? "")
        if o.superview == nil {
            root.addSubview(o)
            layoutThreadOverlay()
        }
        watch(o.chat)
        DispatchQueue.main.async { o.focus() }
    }

    func closeThreadOverlay() {
        guard let o = threadUI.overlay else { return }
        o.removeFromSuperview()
        threadUI.overlay = nil
        if let f = arrangement?.focused, let v = views[f] { window?.makeFirstResponder(v.focusView) }
    }

    /// Where it sits: over the middle of the window, most of its height.
    func layoutThreadOverlay() {
        guard let o = threadUI.overlay, o.superview != nil else { return }
        let b = root.bounds
        let w = min(560, b.width - 40), h = min(max(360, b.height * 0.72), b.height - 60)
        o.frame = NSRect(x: (b.midX - w / 2).rounded(), y: (b.midY - h / 2 + 10).rounded(), width: w, height: h)
        o.autoresizingMask = [.minXMargin, .maxXMargin, .minYMargin, .maxYMargin]
    }

    /// Debugging the overlay: `overlay` (⌥⌘M), `overlay thread <id>`, `overlay tab <0|1>`,
    /// `overlay send <text>`, `overlay close`; and what it shows.
    func debugOverlay(_ arg: String) -> String {
        let w = arg.split(separator: " ", maxSplits: 1).map(String.init)
        switch w.first {
        case nil: commentHere(nil)
        case "close": closeThreadOverlay()
        case "type":
            // "threadoverlay type <text>": typed into the composer; "accept": the @ list's choice.
            threadUI.overlay?.chat.composer.debugType(w.count > 1 ? w[1] : "")
            return threadUI.overlay?.chat.composer.mentions.debugRows ?? "no overlay"
        case "accept":
            threadUI.overlay?.chat.composer.debugAccept()
            return threadUI.overlay.map { "“\($0.chat.composer.message)” blocks \($0.chat.composer.mentionedBlocks.count)" } ?? "no overlay"
        case "mentions", "message":
            // The composer's `@` list, or what it would send.
            guard let o = threadUI.overlay else { return "no overlay" }
            let c = o.chat.composer
            if w[0] == "mentions", let path = w.dropFirst().first { return c.mentions.debugPicture(path) }
            return w[0] == "mentions" ? c.mentions.debugRows : "“\(c.message)” · shown “\(c.string)”"
        case "thread":
            // "overlay thread <id's end>": that thread read in it.
            let end = w.dropFirst().first ?? ""
            guard let t = hosts.threads.first(where: { $0.id.ulid.hasSuffix(end) }) else { return "no thread \(end)" }
            showThreadOverlay(nil, thread: t.id)
        case "popout": threadUI.overlay?.onPopOut?()
        case "send":
            guard let o = threadUI.overlay else { return "no overlay" }
            let text = w.dropFirst().first ?? ""
            threadChat(o.chat, send: text)
        default: break
        }
        guard let o = threadUI.overlay, o.superview != nil else { return "no overlay" }
        return "overlay \(Int(o.frame.width))x\(Int(o.frame.height)) · “\(o.hereTitle)” · thread \(o.chat.threadID.map { String($0.ulid.suffix(6)) } ?? "new") · \(o.hereThreads.count) here · pop out \(o.canPopOut)"
    }
}
