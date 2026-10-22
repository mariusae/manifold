import Foundation

/// Every copy on its way (§8) — an upload, a download, a copy within a
/// host or between two — as it goes: shown at the bottom of the sidebar
/// with how far it has got, and stopped from there. On the main thread;
/// the work itself is elsewhere (Transfer).
final class Transfers {
    static let shared = Transfers()
    /// Posted (on the main thread) when what's shown changes.
    static let changed = Notification.Name("ManifoldTransfersChanged")
    /// A copy shows once it has taken this long (a quick one never does).
    static let showAfter: TimeInterval = 0.3
    /// A finished one stays this long; a failed one until it's dismissed.
    static let keepFinished: TimeInterval = 6

    enum State: Equatable { case running, finished, failed(String), cancelled }

    final class Item {
        let id = UUID()
        let title: String
        /// Where it goes or comes from ("to box:~/src").
        let detail: String
        let symbol: String
        let started = Date()
        fileprivate(set) var done: Int64 = 0
        fileprivate(set) var total: Int64?
        fileprivate(set) var state: State = .running
        fileprivate(set) var ended: Date?
        /// Bytes a second, smoothed.
        fileprivate(set) var rate: Double = 0
        fileprivate var lastSample: (at: Date, done: Int64)?
        /// Stops it (while it runs).
        var cancel: (() -> Void)?
        /// What a click does once it's done (Show in Finder).
        var action: (title: String, run: () -> Void)?

        init(title: String, detail: String, symbol: String) {
            self.title = title
            self.detail = detail
            self.symbol = symbol
        }

        var isRunning: Bool { state == .running }
        var fraction: Double? { total.map { $0 > 0 ? min(1, Double(done) / Double($0)) : (isRunning ? 0 : 1) } }

        /// Seconds left at the present rate, if it can be told.
        var remaining: TimeInterval? {
            guard isRunning, let total, rate > 0, Date().timeIntervalSince(started) > 1.5 else { return nil }
            return Double(total - done) / rate
        }
    }

    private(set) var items: [Item] = []

    /// What the sidebar shows: those running long enough to be worth it,
    /// and those that ended and haven't gone yet.
    var visible: [Item] {
        let now = Date()
        return items.filter { !$0.isRunning || now.timeIntervalSince($0.started) >= Self.showAfter }
    }

    var running: [Item] { items.filter(\.isRunning) }

    func begin(_ title: String, detail: String, symbol: String) -> Item {
        let item = Item(title: title, detail: detail, symbol: symbol)
        items.append(item)
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.showAfter) { [weak self] in
            if item.isRunning { self?.post() }
        }
        return item
    }

    func update(_ item: Item, done: Int64, total: Int64?) {
        guard item.isRunning else { return }
        let now = Date()
        if let last = item.lastSample, now.timeIntervalSince(last.at) >= 0.25 {
            let r = Double(done - last.done) / now.timeIntervalSince(last.at)
            item.rate = item.rate == 0 ? r : 0.7 * item.rate + 0.3 * r
            item.lastSample = (now, done)
        } else if item.lastSample == nil {
            item.lastSample = (now, done)
        }
        item.done = done
        if let total { item.total = total }
        post()
    }

    /// Ended: done, failed (why), or stopped.
    func finish(_ item: Item, error: String?) {
        guard item.isRunning else { return }
        item.state = error == nil ? .finished : error == "cancelled" ? .cancelled : .failed(error!)
        item.ended = Date()
        item.cancel = nil
        if error == nil, let total = item.total { item.done = total }
        // A quick one that worked never shows; one that failed always does.
        let shown = Date().timeIntervalSince(item.started) >= Self.showAfter
        if error == nil || error == "cancelled" {
            if !shown { items.removeAll { $0 === item } }
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.keepFinished) { [weak self] in self?.dismiss(item) }
        }
        post()
    }

    func dismiss(_ item: Item) {
        guard !item.isRunning else { return }
        items.removeAll { $0 === item }
        post()
    }

    /// Stopped, if it runs; else taken away.
    func cancelOrDismiss(_ item: Item) {
        if item.isRunning { item.cancel?() } else { dismiss(item) }
    }

    private var posting = false

    /// Said at most every tenth of a second.
    private func post() {
        guard !posting else { return }
        posting = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
            self?.posting = false
            NotificationCenter.default.post(name: Self.changed, object: nil)
        }
    }

    /// A copy run with its row: `work` is given a progress reporter (from
    /// any thread) and a way to say it's done (from any thread), and gives
    /// back how to stop it.
    @discardableResult
    func run(_ title: String, detail: String, symbol: String,
             _ work: (_ progress: @escaping (Int64, Int64?) -> Void, _ done: @escaping (String?) -> Void) -> (() -> Void)?,
             then: ((String?) -> Void)? = nil) -> Item {
        let item = begin(title, detail: detail, symbol: symbol)
        let progress: (Int64, Int64?) -> Void = { [weak self] done, total in
            DispatchQueue.main.async { self?.update(item, done: done, total: total) }
        }
        let done: (String?) -> Void = { [weak self] error in
            DispatchQueue.main.async {
                self?.finish(item, error: error)
                then?(error)
            }
        }
        item.cancel = work(progress, done)
        return item
    }
}

extension Transfers.Item {
    /// How far it has got, in words: "12.3 of 40 MB · 1.2 MB/s · 20 s left".
    var progressText: String {
        let f = ByteCountFormatter()
        f.countStyle = .file
        switch state {
        case .finished: return "Done · " + f.string(fromByteCount: total ?? done)
        case .cancelled: return "Stopped"
        case let .failed(why): return why == "exists" ? "Already there" : why
        case .running:
            var parts: [String] = []
            if let total, total > 0 {
                parts.append("\(f.string(fromByteCount: done)) of \(f.string(fromByteCount: total))")
            } else if done > 0 {
                parts.append(f.string(fromByteCount: done))
            } else {
                parts.append("Starting…")
            }
            if rate > 0 { parts.append(f.string(fromByteCount: Int64(rate)) + "/s") }
            if let left = remaining {
                parts.append(left < 60 ? "\(max(1, Int(left))) s left" : "\(Int(left / 60)) min left")
            }
            return parts.joined(separator: " · ")
        }
    }
}
