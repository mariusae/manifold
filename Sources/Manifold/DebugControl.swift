import AppKit
import CoreImage
import GhosttyKit
import ManifoldCore

/// A development aid, on only when MANIFOLD_DEBUG is set: a socket at
/// $MANIFOLD_DIR/app-debug.sock taking one command per connection, for
/// driving and inspecting the app from scripts.
///
///   snapshot <path>      write a PNG of the window, terminals included
///   action <selector>    send an action (e.g. "newTab:") to the responder chain
///   text <string>        type into the focused terminal
///   sidebar show|hide    reveal or hide the floating sidebar
///   sidebar width <n>    resize the sidebar, as its handle would
///   contrast <mode>      set contrast correction (off, typical, deuteranopia)
///   focus                render as focused, without activating the app
///   open <target>        as if command-clicked in the focused terminal
///   peek <column>        list what's beneath a column's top, as hovering does
///   dump                 describe the window's views
enum DebugControl {
    private static var listener: DispatchSourceRead?

    static func start(controller: @escaping () -> MainWindowController?) {
        guard ProcessInfo.processInfo.environment["MANIFOLD_DEBUG"] != nil else { return }
        let path = Paths.directory.appendingPathComponent("app-debug.sock").path
        guard let fd = try? UnixSocket.listen(path: path) else { return }
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: .main)
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
        source.setEventHandler {
          while true {
            let c = accept(fd, nil, nil)
            guard c >= 0 else { return }
            _ = fcntl(c, F_SETFL, fcntl(c, F_GETFL) & ~O_NONBLOCK)
            var data = Data()
            var buf = [UInt8](repeating: 0, count: 4096)
            while true {
                let n = read(c, &buf, buf.count)
                if n <= 0 { break }
                data.append(contentsOf: buf[0..<n])
                if data.last == 0x0A { break }
            }
            let line = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .newlines)
            let reply = run(line, controller()) + "\n"
            _ = reply.withCString { write(c, $0, strlen($0)) }
            close(c)
          }
        }
        source.resume()
        listener = source
    }

    private static func run(_ line: String, _ wc: MainWindowController?) -> String {
        let parts = line.split(separator: " ", maxSplits: 1).map(String.init)
        guard let cmd = parts.first else { return "empty" }
        let arg = parts.count > 1 ? parts[1] : ""
        switch cmd {
        case "snapshot":
            guard let window = wc?.window else { return "no window" }
            return snapshot(window, to: arg.isEmpty ? "/tmp/manifold.png" : arg)
        case "action":
            let sel = Selector(arg)
            let start: NSResponder? = wc?.window?.firstResponder ?? wc?.window
            let ok = start?.tryToPerform(sel, with: nil) ?? false
            return ok ? "ok" : "not handled"
        case "text":
            guard let t = wc?.debugFocusedTerminal, let s = t.surface else { return "no terminal focused" }
            let text = arg.replacingOccurrences(of: "\\r", with: "\r").replacingOccurrences(of: "\\n", with: "\n")
            // As key presses, so it isn't treated as a paste.
            for ch in text {
                var ev = ghostty_input_key_s()
                ev.action = GHOSTTY_ACTION_PRESS
                ev.mods = GHOSTTY_MODS_NONE
                ev.consumed_mods = GHOSTTY_MODS_NONE
                if ch == "\r" || ch == "\n" {
                    ev.keycode = 36
                    _ = ghostty_surface_key(s, ev)
                } else {
                    ev.keycode = 0xFFFF
                    ev.unshifted_codepoint = ch.unicodeScalars.first!.value
                    _ = String(ch).withCString { p in
                        ev.text = p
                        return ghostty_surface_key(s, ev)
                    }
                }
            }
            return "ok"
        case "sidebar":
            if arg.hasPrefix("width "), let w = Double(arg.dropFirst(6)) {
                // As if the resize handle were dragged there and let go.
                wc?.sidebarResize(to: CGFloat(w))
                wc?.sidebarResizeEnded()
                return "ok"
            }
            wc?.debugSidebar(show: arg == "show")
            return "ok"
        case "hittest":
            // x y in window coordinates from the top-left.
            let xy = arg.split(separator: " ").compactMap { Double($0) }
            guard xy.count == 2, let frameView = wc?.window?.contentView?.superview else { return "usage: hittest x y" }
            let p = NSPoint(x: xy[0], y: frameView.bounds.height - xy[1])
            return String(describing: frameView.hitTest(p).map { type(of: $0) })
        case "titlebar":
            guard let b = wc?.window?.standardWindowButton(.closeButton) else { return "no buttons" }
            var out = ""
            var v: NSView? = b
            while let view = v {
                out += "\(type(of: view)) frame=\(view.frame) inWindow=\(view.convert(view.bounds, to: nil)) clips=\(view.clipsToBounds)\n"
                v = view.superview
            }
            return out
        case "contrast":
            guard let mode = ContrastCorrection(rawValue: arg) else { return "off, typical or deuteranopia" }
            let item = NSMenuItem()
            item.representedObject = mode.rawValue
            wc?.setContrastCorrection(item)
            return "ok"
        case "focus":
            // Tells ghostty the app and terminal have focus, without
            // activating the app, so focused rendering can be checked.
            guard let t = wc?.debugFocusedTerminal, let s = t.surface, let app = GhosttyRuntime.shared.app else { return "no terminal" }
            ghostty_app_set_focus(app, true)
            ghostty_surface_set_focus(s, true)
            return "ok"
        case "sheet":
            // Describes the sheet on the window, or types into it and presses
            // a button: "sheet", "sheet type <text>", "sheet press <title>".
            guard let sheet = wc?.window?.attachedSheet else { return "no sheet" }
            let fields = allSubviews(sheet.contentView).compactMap { $0 as? NSTextField }.filter(\.isEditable)
            let buttons = allSubviews(sheet.contentView).compactMap { $0 as? NSButton }
            if arg.hasPrefix("type ") {
                fields.first?.stringValue = String(arg.dropFirst(5))
                return "ok"
            }
            if arg.hasPrefix("press ") {
                guard let b = buttons.first(where: { $0.title == String(arg.dropFirst(6)) }) else { return "no button" }
                b.performClick(nil)
                return "ok"
            }
            return "fields: \(fields.map(\.stringValue)) buttons: \(buttons.map(\.title))"
        case "open":
            // As if the target were command-clicked in the focused terminal.
            guard let wc, let t = wc.debugFocusedTerminal else { return "no terminal focused" }
            wc.open(arg, from: t.pane)
            return "ok"
        case "peek":
            wc?.debugPeek(Int(arg) ?? 0)
            return "ok"
        case "dump":
            guard let v = wc?.window?.contentView else { return "no window" }
            return describe(v, 0) + "\nfirstResponder: \(String(describing: wc?.window?.firstResponder))"
        default:
            return "unknown command"
        }
    }

    private static func allSubviews(_ v: NSView?) -> [NSView] {
        guard let v else { return [] }
        return v.subviews + v.subviews.flatMap { allSubviews($0) }
    }

    private static func describe(_ v: NSView, _ depth: Int) -> String {
        var s = String(repeating: "  ", count: depth) + "\(type(of: v)) \(v.frame)\(v.isHidden ? " hidden" : "")"
        if let t = v as? TerminalView { s += " pane=\(t.pane) surface=\(t.surface != nil)" }
        if let keys = v.layer?.animationKeys(), !keys.isEmpty { s += " animating=\(keys)" }
        for sub in v.subviews where depth < 4 { s += "\n" + describe(sub, depth + 1) }
        return s
    }

    /// Draws the window's views, then the terminals' rendered frames (which
    /// live in IOSurfaces AppKit can't draw), then the overlays on top.
    private static func snapshot(_ window: NSWindow, to path: String) -> String {
        // The frame view, so the title bar's buttons are drawn too.
        guard let root = window.contentView?.superview else { return "no content" }
        let scale = window.backingScaleFactor
        let size = root.bounds.size
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width * scale), pixelsHigh: Int(size.height * scale),
                                   bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                   colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        rep.size = size
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        let ctx = NSGraphicsContext.current!.cgContext

        func draw(_ v: NSView) {
            guard !v.isHidden, v.alphaValue > 0 else { return }
            let r = v.convert(v.bounds, to: root)
            if let t = v as? TerminalView {
                if let contents = t.layer?.contents, CFGetTypeID(contents as CFTypeRef) == IOSurfaceGetTypeID() {
                    let ci = CIImage(ioSurface: contents as! IOSurface)
                    if let cg = CIContext().createCGImage(ci, from: ci.extent) { ctx.draw(cg, in: r) }
                }
                return
            }
            let img = v.bitmapImageRepForCachingDisplay(in: v.bounds)!
            // Draw this view alone, then its subviews in order.
            let hidden = v.subviews.map(\.isHidden)
            v.subviews.forEach { $0.isHidden = true }
            v.cacheDisplay(in: v.bounds, to: img)
            for (s, h) in zip(v.subviews, hidden) { s.isHidden = h }
            if let cg = img.cgImage {
                ctx.saveGState()
                ctx.setAlpha(v.alphaValue)
                ctx.draw(cg, in: r)
                ctx.restoreGState()
            }
            for sub in v.subviews { draw(sub) }
        }
        draw(root)
        NSGraphicsContext.restoreGraphicsState()
        do {
            try rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: path))
            return "wrote \(path)"
        } catch {
            return "\(error)"
        }
    }
}
