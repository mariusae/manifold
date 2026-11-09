import AppKit
import ManifoldCore

/// What a view shows while it waits on its host — a folder being listed, a
/// file being read, a shell being reached: a small spinner and a word in the
/// middle of it; or, with no spinner, why there's nothing (a folder that
/// isn't there, one that's empty). Busy, it shows only after a moment, so an
/// answer that comes at once (this Mac's, mostly) shows nothing; meanwhile a
/// view still empty isn't taken for an empty folder or file, or a fault.
/// The pointer and clicks go through it to the view.
final class BusyNote: NSView {
    enum State: Equatable {
        case idle
        case busy(String)
        case message(String)
    }

    static let delay: TimeInterval = 0.3

    /// Another host's link, for a view waiting on it: what the host is
    /// called, and how much has come over the link in all. Given by the
    /// window; nil for This Mac's (nothing to wait on but the disk).
    static var link: ((HostID) -> (label: String, bytes: Int64)?)?
    /// The host the view waits on: busy, and the host another one, it says
    /// how much has come from there since, over a bar going — a big file
    /// on a slow link is seen coming, not taken for stuck.
    var host: HostID?
    private let bar = NSProgressIndicator()
    private var counting: Timer?
    private var counted: (words: String, from: String, since: Int64)?

    private let spinner = NSProgressIndicator()
    private let label = NSTextField.label(font: UIType.row, color: Theme.secondaryText, align: .center)
    private var pending: DispatchWorkItem?
    private(set) var state: State = .idle

    override init(frame: NSRect) {
        super.init(frame: frame)
        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isDisplayedWhenStopped = false
        bar.style = .bar
        bar.controlSize = .small
        bar.isIndeterminate = true
        bar.isHidden = true
        addSubview(bar)
        addSubview(spinner)
        addSubview(label)
        isHidden = true
    }

    required init?(coder: NSCoder) { fatalError() }

    func set(_ s: State) {
        guard s != state else { return }
        let showing = !isHidden
        state = s
        pending?.cancel()
        pending = nil
        counting?.invalidate()
        counting = nil
        counted = nil
        bar.stopAnimation(nil)
        bar.isHidden = true
        switch s {
        case .idle:
            spinner.stopAnimation(nil)
            isHidden = true
        case let .message(text):
            label.stringValue = text
            spinner.stopAnimation(nil)
            spinner.isHidden = true
            isHidden = false
        case let .busy(text):
            label.stringValue = text
            spinner.isHidden = false
            // Waiting on another host: how much has come from it, counted.
            if let host, let l = Self.link?(host) {
                counted = (text.hasSuffix("…") ? String(text.dropLast()) : text, l.label, l.bytes)
                let timer = Timer(timeInterval: 0.25, repeats: true) { [weak self] _ in
                    MainActor.unchecked { self?.count() }
                }
                RunLoop.main.add(timer, forMode: .common)
                counting = timer
            }
            if showing {
                spinner.startAnimation(nil)
            } else {
                let work = DispatchWorkItem { [weak self] in
                    self?.isHidden = false
                    self?.spinner.startAnimation(nil)
                }
                pending = work
                DispatchQueue.main.asyncAfter(deadline: .now() + Self.delay, execute: work)
            }
        }
        needsLayout = true
    }

    /// What's come from the host since it began waiting: said, once it's
    /// enough to be worth saying, over the bar.
    private func count() {
        guard let c = counted, let host, let now = Self.link?(host)?.bytes else { return }
        let n = now - c.since
        guard n >= 64 << 10 else { return }
        label.stringValue = "\(c.words) from \(c.from) — \(ByteCountFormatter.string(fromByteCount: n, countStyle: .file))"
        if bar.isHidden {
            bar.isHidden = false
            spinner.stopAnimation(nil)
            spinner.isHidden = true
            bar.startAnimation(nil)
        }
        needsLayout = true
    }

    override func layout() {
        super.layout()
        if !bar.isHidden {
            // The words over the bar, both in the middle.
            let lh = ceil(label.intrinsicContentSize.height)
            let lw = min(ceil(label.intrinsicContentSize.width) + 4, max(0, bounds.width - 24))
            let w = min(220, max(0, bounds.width - 48))
            let top = ((bounds.height + lh + 6 + 12) / 2).rounded()
            label.frame = NSRect(x: ((bounds.width - lw) / 2).rounded(), y: top - lh, width: lw, height: lh)
            bar.frame = NSRect(x: ((bounds.width - w) / 2).rounded(), y: top - lh - 6 - 12, width: w, height: 12)
            return
        }
        let lh = ceil(label.intrinsicContentSize.height)
        let sw: CGFloat = spinner.isHidden ? 0 : 16 + 8
        let lw = min(ceil(label.intrinsicContentSize.width) + 4, max(0, bounds.width - 24 - sw))
        let x = ((bounds.width - sw - lw) / 2).rounded()
        let y = ((bounds.height - lh) / 2).rounded()
        spinner.frame = NSRect(x: x, y: ((bounds.height - 16) / 2).rounded(), width: 16, height: 16)
        label.frame = NSRect(x: x + sw, y: y, width: lw, height: lh)
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    /// Debugging: what it says, and whether it shows yet.
    var debugState: String {
        switch state {
        case .idle: "idle"
        case let .busy(t): "busy “\(t)” \(isHidden ? "pending" : "shown")"
        case let .message(t): "message “\(t)”"
        }
    }
}
