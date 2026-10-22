import AppKit
import Carbon
import ManifoldCore

/// Secure Keyboard Entry (§9): while it's on, other apps can't read what
/// you type. On by hand (the app menu), as Terminal's is; and on by itself
/// while the focused terminal's program reads a password (its host says
/// when). Only while Manifold is in front: the keyboard is everyone's
/// again when another app is.
final class SecureInput {
    static let shared = SecureInput()

    /// On by hand, kept.
    var always: Bool {
        get { UserDefaults.standard.bool(forKey: "SecureKeyboardEntry") }
        set { UserDefaults.standard.set(newValue, forKey: "SecureKeyboardEntry"); update() }
    }
    /// The terminals reading a password now.
    private(set) var reading: Set<BlockID> = []
    /// The block whose tile has the keyboard.
    var focused: BlockID? { didSet { if focused != oldValue { update() } } }
    /// A terminal started or stopped reading a password (its tile marks it).
    var onChange: ((BlockID) -> Void)?
    private var enabled = false

    init() {
        let nc = NotificationCenter.default
        nc.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in self?.update() }
        nc.addObserver(forName: NSApplication.didResignActiveNotification, object: nil, queue: .main) { [weak self] _ in self?.update() }
    }

    func set(_ block: BlockID, readingPassword on: Bool) {
        if on { reading.insert(block) } else { reading.remove(block) }
        update()
        onChange?(block)
    }

    var isOn: Bool { enabled }

    private func update() {
        let want = NSApp.isActive && (always || focused.map(reading.contains) == true)
        guard want != enabled else { return }
        enabled = want
        if want { EnableSecureEventInput() } else { DisableSecureEventInput() }
    }
}
