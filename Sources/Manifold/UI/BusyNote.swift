import AppKit

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

    private let spinner = NSProgressIndicator()
    private let label = NSTextField(labelWithString: "")
    private var pending: DispatchWorkItem?
    private(set) var state: State = .idle

    override init(frame: NSRect) {
        super.init(frame: frame)
        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isDisplayedWhenStopped = false
        label.font = UIType.row
        label.textColor = Theme.secondaryText
        label.alignment = .center
        label.lineBreakMode = .byTruncatingTail
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

    override func layout() {
        super.layout()
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
