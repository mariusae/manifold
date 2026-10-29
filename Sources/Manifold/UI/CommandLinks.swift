import AppKit

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
