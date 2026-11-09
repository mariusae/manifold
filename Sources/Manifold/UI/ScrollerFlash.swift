import AppKit
import ObjectiveC

/// Overlay scrollers flash when a scroll view comes back into sight
/// (AppKit's way of saying "this scrolls"). A space switched to brings its
/// whole grid back at once — every tile's scrollers flashing together — so
/// that unhiding is done quietly.
///
/// The flash is NSScrollView's viewDidUnhide asking its scrollers
/// (NSScrollerImpPair's _flashScrollersIfNewlyVisible), synchronously —
/// not the public flashScrollers; if a later AppKit has no such method,
/// nothing is hooked and the scrollers flash as before.
enum ScrollerFlash {
    nonisolated(unsafe) private static var quiet = false

    /// `body` run with scrollers coming into sight not flashing.
    static func quietly(_ body: () -> Void) {
        quiet = true
        defer { quiet = false }
        body()
    }

    /// Once, at launch.
    static func install() {
        let sel = NSSelectorFromString("_flashScrollersIfNewlyVisible")
        guard let pair = NSClassFromString("NSScrollerImpPair"),
              let method = class_getInstanceMethod(pair, sel) else { return }
        typealias Flash = @convention(c) (AnyObject, Selector) -> Void
        let original = unsafeBitCast(method_getImplementation(method), to: Flash.self)
        let quieted: @convention(block) (AnyObject) -> Void = { this in
            if !quiet { original(this, sel) }
        }
        method_setImplementation(method, imp_implementationWithBlock(quieted))
    }
}
