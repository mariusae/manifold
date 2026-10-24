import AppKit
import ManifoldCore

// mani <command> [flags] [args]: Manifold's command (`Mani`), as the app
// has it in its Helpers. What's here is how it reaches the host: starting
// Manifold (and so the server) if need be, and bringing it forward when
// what it opens isn't beside a terminal of its own.

/// The app this command belongs to: it lives in Manifold.app/Contents/Helpers.
func appURL() -> URL? {
    if let exe = Bundle.main.executableURL?.resolvingSymlinksInPath() {
        let app = exe.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        if app.pathExtension == "app" { return app }
    }
    return NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.manifold.app")
}

/// Starts or brings forward the app, and waits for it to answer.
func launchApp(activate: Bool) {
    guard let url = appURL() else { Mani.fail("can't find Manifold.app") }
    let config = NSWorkspace.OpenConfiguration()
    config.activates = activate
    let done = DispatchSemaphore(value: 0)
    NSWorkspace.shared.openApplication(at: url, configuration: config) { _, error in
        if let error { Mani.fail("can't open \(url.path): \(error.localizedDescription)") }
        done.signal()
    }
    done.wait()
}

/// Connects to the host, starting the app (and so the server) if need be.
func connect() -> Int32 {
    if let fd = try? UnixSocket.connect(path: Paths.socket) { return fd }
    launchApp(activate: Mani.here == nil)
    for _ in 0..<100 {
        if let fd = try? UnixSocket.connect(path: Paths.socket) { return fd }
        usleep(100_000)
    }
    Mani.fail("Manifold didn't start (see \(Paths.log.path))")
}

Mani.main(Array(CommandLine.arguments.dropFirst()), platform: Mani.Platform(
    request: { body in
        // The app must be attached for the host to pass the request on.
        var fd = connect()
        let beside = Mani.here != nil
        if !beside { launchApp(activate: true) }
        var status = body(fd)
        if status != 0, !beside {
            // The app was starting: give it a moment and ask again.
            close(fd)
            sleep(2)
            fd = connect()
            status = body(fd)
        }
        return status
    },
    bringForward: { launchApp(activate: true) }))
