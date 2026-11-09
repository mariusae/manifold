import Foundation

/// Work done once things settle: each `schedule` puts off what was
/// scheduled before it, so only the last runs — `delay` after it. Used
/// from its queue alone (the main one, by default).
public final class Debouncer {
    private let queue: DispatchQueue
    private var work: DispatchWorkItem?

    public init(queue: DispatchQueue = .main) { self.queue = queue }

    /// Whether something's waiting to run.
    public var isPending: Bool { work != nil }

    public func schedule(after delay: TimeInterval, _ f: @escaping () -> Void) {
        work?.cancel()
        var item: DispatchWorkItem?
        item = DispatchWorkItem { [weak self] in
            if let self, self.work === item { self.work = nil }
            f()
        }
        work = item
        queue.asyncAfter(deadline: .now() + delay, execute: item!)
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
