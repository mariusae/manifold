import AppKit
import Testing
@testable import Manifold

// I-7, M30 (STATE-MACHINES.md): a toast shown while the last one fades out
// stays shown — the fade's end hides only what it began to hide.

@MainActor
@Test func aToastShownAsTheLastOneFadesStaysShown() async throws {
    let toast = ToastView()
    let host = NSView(frame: NSRect(x: 0, y: 0, width: 400, height: 100))
    host.addSubview(toast)
    toast.show("Deleted", action: "Undo", for: 8) {}
    #expect(!toast.isHidden)
    // Its action taken (`act` hides, then acts), the action saying
    // something: shown again inside the fade.
    toast.hide()
    toast.show("Restored", action: "OK", for: 8) {}
    try await Task.sleep(for: .milliseconds(600))
    #expect(!toast.isHidden, "the new toast was hidden by the old one's fade")
    #expect(toast.alphaValue == 1)
}
