import Foundation

/// Work done once things settle: each `schedule` puts off what was
/// scheduled before it, so only the last runs — `delay` after it. Used
/// from its queue alone (the main one, by default).
public final class Debouncer {
    private let queue: DispatchQueue
    private var work: DispatchWorkItem?
    /// What's waiting, to be run now by `flush`.
    private var waiting: (() -> Void)?

    public init(queue: DispatchQueue = .main) { self.queue = queue }

    /// Whether something's waiting to run.
    public var isPending: Bool { work != nil }

    public func schedule(after delay: TimeInterval, _ f: @escaping () -> Void) {
        work?.cancel()
        var item: DispatchWorkItem?
        item = DispatchWorkItem { [weak self] in
            if let self, self.work === item {
                self.work = nil
                self.waiting = nil
            }
            f()
        }
        work = item
        waiting = f
        queue.asyncAfter(deadline: .now() + delay, execute: item!)
    }

    /// What's waiting, run now in its place (once: not again at its
    /// time); nothing if nothing waits, or it was cancelled.
    public func flush() {
        guard let f = waiting else { return }
        cancel()
        f()
    }

    /// `f` now, in place of whatever was waiting.
    public func runNow(_ f: () -> Void) {
        cancel()
        f()
    }

    /// What's waiting, not run.
    public func cancel() {
        work?.cancel()
        work = nil
        waiting = nil
    }
}

/// A `Debouncer` for each key: each key's work put off by the next
/// scheduled for it. Used from its queue alone.
public final class KeyedDebouncer<Key: Hashable> {
    private let queue: DispatchQueue
    private var work: [Key: DispatchWorkItem] = [:]

    public init(queue: DispatchQueue = .main) { self.queue = queue }

    public func isPending(_ key: Key) -> Bool { work[key] != nil }

    public func schedule(_ key: Key, after delay: TimeInterval, _ f: @escaping () -> Void) {
        work[key]?.cancel()
        var item: DispatchWorkItem?
        item = DispatchWorkItem { [weak self] in
            if let self, self.work[key] === item { self.work[key] = nil }
            f()
        }
        work[key] = item
        queue.asyncAfter(deadline: .now() + delay, execute: item!)
    }

    public func cancel(_ key: Key) {
        work.removeValue(forKey: key)?.cancel()
    }

    public func cancelAll() {
        work.values.forEach { $0.cancel() }
        work = [:]
    }
}
