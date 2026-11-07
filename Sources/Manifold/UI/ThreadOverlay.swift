import AppKit
import ManifoldCore

/// The threads' overlay (§3.12), over the window from anywhere (⌥⌘M),
/// taking no tile: Here — the place you're at (a terminal's command, a
/// PDF's page, a page's selection, else the tile), its threads, or the
/// composer for one — and Space, the space's timeline. ⎋ closes it; a
/// place in it clicked is gone to, the overlay kept.
final class ThreadOverlayView: NSView {
    let chat = ThreadChatView()
    let timeline = ThreadTimelineView()
    private let tabs = NSSegmentedControl(labels: ["Here", "Space"], trackingMode: .selectOne, target: nil, action: nil)
    private let close = IconButton(symbol: "xmark", size: 10, target: nil, action: nil)
    private let titleLabel = NSTextField(labelWithString: "")
    var onClose: (() -> Void)?
    var onTab: ((Int) -> Void)?
    /// Here's place, and its threads, stepped through.
    var herePlace: ThreadPlace?
    var hereThreads: [BlockID] = []
    var hereTitle = "" { didSet { titleLabel.stringValue = hereTitle } }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.cornerRadius = 12
        layer?.masksToBounds = false
        shadow = NSShadow()
        layer?.shadowOpacity = 0.35
        layer?.shadowRadius = 18
        layer?.shadowOffset = NSSize(width: 0, height: -6)
        tabs.segmentStyle = .rounded
        tabs.controlSize = .small
        tabs.target = self
        tabs.action = #selector(tabChosen)
        close.target = self
        close.action = #selector(closeClicked)
        close.toolTip = "Close (⎋)"
        titleLabel.font = UIType.caption
        titleLabel.textColor = Theme.secondaryText
        titleLabel.lineBreakMode = .byTruncatingMiddle
        chat.fits = false
        for v in [tabs, titleLabel, close, chat, timeline] as [NSView] { addSubview(v) }
        themed { v in
            v.layer?.backgroundColor = Theme.sheet(level: 2).cgColor
            v.layer?.borderColor = Theme.divider.cgColor
            v.layer?.borderWidth = 1
        }
    }

    required init?(coder: NSCoder) { fatalError() }

    var tab: Int {
        get { tabs.selectedSegment }
        set {
            tabs.selectedSegment = newValue
            chat.isHidden = newValue != 0
            titleLabel.isHidden = newValue != 0
            timeline.isHidden = newValue != 1
            needsLayout = true
        }
    }

    var hasHere: Bool = true { didSet { tabs.setEnabled(hasHere, forSegment: 0) } }

    @objc private func tabChosen() {
        tab = tabs.selectedSegment
        onTab?(tab)
    }

    @objc private func closeClicked() { onClose?() }

    /// ⎋, wherever the keyboard is in it.
    override func cancelOperation(_ sender: Any?) { onClose?() }

    func focus() { window?.makeFirstResponder(tab == 0 ? chat.composer : timeline.composer) }

    override func layout() {
        super.layout()
        let pad: CGFloat = 10
        tabs.sizeToFit()
        let top = bounds.height - pad - 22
        tabs.frame = NSRect(x: pad + 2, y: top, width: tabs.frame.width, height: 22)
        close.frame = NSRect(x: bounds.width - pad - 18, y: top + 2, width: 18, height: 18)
        titleLabel.frame = NSRect(x: tabs.frame.maxX + 10, y: top + 3, width: max(0, close.frame.minX - tabs.frame.maxX - 20), height: 16)
        let content = NSRect(x: 0, y: 0, width: bounds.width, height: top - 4)
        chat.frame = content
        timeline.frame = content
    }

    // Clicks stop here, not on the tiles beneath.
    override func mouseDown(with event: NSEvent) {}
}

extension MainWindowController {
    /// ⌥⌘M where there's no editor's or diff's place: the overlay, on the
    /// place you're at (`place`, else the focused tile's), or the space.
    func showThreadOverlay(_ place: ThreadPlace?, thread: BlockID? = nil, tab: Int? = nil) {
        if let o = threadUI.overlay, o.superview != nil, place == nil, thread == nil, tab == nil { return closeThreadOverlay() }
        threadUI.popover?.close()
        let o = threadUI.overlay ?? ThreadOverlayView()
        threadUI.overlay = o
        o.onClose = { [weak self] in self?.closeThreadOverlay() }
        o.chat.composer.onCancel = { [weak self] in self?.closeThreadOverlay() }
        o.timeline.composer.onCancel = { [weak self] in self?.closeThreadOverlay() }
        o.onTab = { [weak self, weak o] t in
            guard let self, let o else { return }
            if t == 1 { self.refresh(o.timeline) }
            o.focus()
        }
        o.timeline.space = selected
        o.timeline.marksWhenOpened = nil
        // Here: the thread asked for, else the place given or under the caret.
        let here: ThreadPlace? = thread == nil ? place : nil
        o.herePlace = here
        o.hereThreads = thread.map { [$0] } ?? here.map { p in hosts.threads(about: p.block, anchor: p.anchor).sorted { $0.created > $1.created }.map(\.id) } ?? []
        o.hasHere = here != nil || thread != nil
        let openHere = o.hereThreads.first { hosts.block($0)?.thread?.resolved != true } ?? o.hereThreads.first
        o.chat.threadID = openHere
        o.chat.newPlace = openHere == nil ? here : nil
        o.chat.newSpace = selected
        o.hereTitle = (thread.flatMap { hosts.block($0)?.thread?.about } ?? here).map { describe($0).title } ?? ""
        o.tab = tab ?? (o.hasHere ? 0 : 1)
        if o.superview == nil {
            root.addSubview(o)
            layoutThreadOverlay()
        }
        watch(o.chat)
        watch(o.timeline)
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

    /// Debugging the overlay: `overlay` (⌥⌘M), `overlay tab <0|1>`,
    /// `overlay send <text>`, `overlay close`; and what it shows.
    func debugOverlay(_ arg: String) -> String {
        let w = arg.split(separator: " ", maxSplits: 1).map(String.init)
        switch w.first {
        case nil: commentHere(nil)
        case "close": closeThreadOverlay()
        case "tab":
            if let o = threadUI.overlay { o.tab = Int(w.dropFirst().first ?? "0") ?? 0; o.onTab?(o.tab) }
        case "send":
            guard let o = threadUI.overlay else { return "no overlay" }
            let text = w.dropFirst().first ?? ""
            if o.tab == 0 { threadChat(o.chat, send: text) } else { timeline(o.timeline, send: text, to: o.timeline.chosen) }
        default: break
        }
        guard let o = threadUI.overlay, o.superview != nil else { return "no overlay" }
        return "overlay \(Int(o.frame.width))x\(Int(o.frame.height)) · tab \(o.tab == 0 ? "here" : "space") · here “\(o.hereTitle)” \(o.hasHere ? "" : "(none)") · thread \(o.chat.threadID.map { String($0.ulid.suffix(6)) } ?? "new") · \(o.hereThreads.count) here · timeline runs \(o.timeline.model.runs.count)"
    }
}
