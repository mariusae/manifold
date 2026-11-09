import AppKit
import ManifoldCore

/// ⌘ held shows what can be gone to — an editor's names, a terminal's
/// paths and addresses — but not while ⌘ is held for shortcuts: once a
/// key goes down with it (⌘G and ⇧⌘G through a search, ⌘C), they're put
/// away until ⌘ is let go. Each view's ⌘ watcher tells it what it sees.
enum CommandLinks {
    /// A key went down with ⌘ since ⌘ did.
    private(set) static var shortcutting = false

    /// An event a view's ⌘ watcher saw, noted; whether links may show now.
    @discardableResult
    static func note(_ event: NSEvent) -> Bool {
        switch event.type {
        case .keyDown where event.modifierFlags.contains(.command): shortcutting = true
        case .flagsChanged where !event.modifierFlags.contains(.command): shortcutting = false
        default: break
        }
        return !shortcutting
    }

    /// How long after ⌘ goes down links wait to show, so a shortcut's ⌘
    /// doesn't flash them first.
    static let delay: TimeInterval = 0.15
}

/// A view's ⌘ watcher: ⌘ held with the pointer over the view (`inside`)
/// shows its links a moment after ⌘ goes down (`willShow` at once, to
/// look things up meanwhile), or at once when the pointer's brought in
/// with ⌘ held; while they show, the pointer moving or ⌘ again `update`s
/// them (`again`: ⌘, to read anew); ⌘ let go, the pointer gone, or a key
/// going down with it (`CommandLinks`), they're hidden.
final class CommandLinkWatcher {
    var inside: () -> Bool = { false }
    var willShow: () -> Void = {}
    var show: () -> Void = {}
    var update: (_ again: Bool) -> Void = { _ in }
    var hide: () -> Void = {}

    /// Whether the links show (or were asked to).
    private(set) var shown = false
    private let pending = Debouncer()
    private var monitor: Any?

    /// Watches in a window, or (nil) stops, hiding what shows.
    func watch(_ window: NSWindow?) {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        pending.cancel()
        guard let window else { return end() }
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.flagsChanged, .mouseMoved, .keyDown]) { [weak self, weak window] event in
            if let self, event.window === window { self.saw(event) }
            return event
        }
    }

    /// The links shown, now.
    func begin() {
        pending.cancel()
        shown = true
        show()
    }

    /// The links hidden, if they show.
    func end() {
        pending.cancel()
        guard shown else { return }
        shown = false
        hide()
    }

    private func saw(_ event: NSEvent) {
        let allowed = CommandLinks.note(event)
        // A key with ⌘ (⌘C, ⌘G): a shortcut, not links looked for.
        if event.type == .keyDown {
            pending.cancel()
            if event.modifierFlags.contains(.command) { end() }
            return
        }
        guard event.modifierFlags.contains(.command), allowed, inside() else { return end() }
        if shown {
            update(event.type == .flagsChanged)
        } else if event.type == .flagsChanged {
            // A moment after ⌘ goes down, if no key follows — or the links
            // would flash at every shortcut.
            willShow()
            pending.schedule(after: CommandLinks.delay) { [weak self] in
                guard let self, NSEvent.modifierFlags.contains(.command), !CommandLinks.shortcutting, self.inside() else { return }
                self.begin()
            }
        } else if event.type == .mouseMoved, !pending.isPending {
            // ⌘ held, the pointer brought in: at once.
            begin()
        }
    }
}
