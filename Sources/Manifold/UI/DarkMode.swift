import AppKit
import ManifoldCore

extension ColorScheme {
    var title: String {
        switch self {
        case .system: "Match System"
        case .light: "Light"
        case .dark: "Dark"
        }
    }

    /// The app's appearance: nil follows the system.
    var appearance: NSAppearance? {
        switch self {
        case .system: nil
        case .light: NSAppearance(named: .aqua)
        case .dark: NSAppearance(named: .darkAqua)
        }
    }
}

extension NSAppearance {
    var isDark: Bool { bestMatch(from: [.aqua, .darkAqua]) == .darkAqua }
}

extension NSColor {
    /// One color in light, another in dark.
    static func dynamic(_ light: NSColor, _ dark: NSColor) -> NSColor {
        NSColor(name: nil) { $0.isDark ? dark : light }
    }
}

extension Notification.Name {
    /// The app went from light to dark or back.
    static let manifoldAppearanceChanged = Notification.Name("ManifoldAppearanceChanged")
}

/// Watches the app's appearance (which follows the system unless one is
/// chosen) and says when it goes between light and dark.
final class AppearanceWatcher {
    static let shared = AppearanceWatcher()
    private var observation: NSKeyValueObservation?
    private(set) var isDark = NSApp.effectiveAppearance.isDark

    func start() {
        observation = NSApp.observe(\.effectiveAppearance) { [weak self] app, _ in
            // Windows take on the new appearance just after the app does.
            DispatchQueue.main.async {
                guard let self, app.effectiveAppearance.isDark != self.isDark else { return }
                self.isDark = app.effectiveAppearance.isDark
                NotificationCenter.default.post(name: .manifoldAppearanceChanged, object: nil)
            }
        }
    }
}

extension NSObjectProtocol where Self: NSView {
    /// Sets colors that a layer holds (which, unlike drawing, don't follow
    /// the appearance by themselves): now, and again whenever light and dark
    /// switch.
    func themed(_ apply: @escaping (Self) -> Void) {
        let hooks = ThemeHooks.of(self)
        hooks.apply.append { [weak self] in if let self { apply(self) } }
        effectiveAppearance.performAsCurrentDrawingAppearance { apply(self) }
    }
}

private final class ThemeHooks {
    var apply: [() -> Void] = []
    private var observer: NSObjectProtocol?
    /// The view's own appearance watched: the app's notice comes a turn
    /// after the app's appearance changes, and a window may not have taken
    /// it on yet — the colors set then were the old appearance's (a bar
    /// left dark in the light, after the system switched).
    private var appearance: NSKeyValueObservation?
    private static var key = 0

    static func of(_ view: NSView) -> ThemeHooks {
        if let hooks = objc_getAssociatedObject(view, &key) as? ThemeHooks { return hooks }
        let hooks = ThemeHooks()
        // The tint or the like changed (the notice), or the view's light
        // or dark (its own appearance).
        hooks.observer = NotificationCenter.default.addObserver(
            forName: .manifoldAppearanceChanged, object: nil, queue: .main
        ) { [weak hooks, weak view] _ in
            guard let hooks, let view else { return }
            hooks.reapply(view)
        }
        hooks.appearance = view.observe(\.effectiveAppearance) { [weak hooks] view, _ in
            guard let hooks else { return }
            if Thread.isMainThread { hooks.reapply(view) } else { DispatchQueue.main.async { hooks.reapply(view) } }
        }
        objc_setAssociatedObject(view, &key, hooks, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        return hooks
    }

    private func reapply(_ view: NSView) {
        view.effectiveAppearance.performAsCurrentDrawingAppearance { apply.forEach { $0() } }
    }

    deinit {
        if let observer { NotificationCenter.default.removeObserver(observer) }
        appearance?.invalidate()
    }
}
