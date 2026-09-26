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
///   click x y [count]    click (count times, as a multi-click) in the window
///   front                bring the window forward; print its screen rect
///   dragimage <path>     write the drag image for the focused pane
///   type <text>          type into the focused text view (\n for newlines)
///   picker               open the ⌘O picker
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
            // Drawing hides views one by one, which would take the keyboard
            // from the one that has it; give it back.
            let responder = window.firstResponder
            defer { window.makeFirstResponder(responder) }
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
        case "click":
            // "click x y [count]": a left click at window coordinates from the
            // top-left, sent through the window as a real one would be.
            let a = arg.split(separator: " ").compactMap { Double($0) }
            guard a.count >= 2, let window = wc?.window else { return "usage: click x y [count]" }
            let p = NSPoint(x: a[0], y: window.contentView!.bounds.height - a[1])
            let count = a.count > 2 ? Int(a[2]) : 1
            for n in 1...count {
                for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                    if let e = NSEvent.mouseEvent(with: type, location: p, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                                  windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: n, pressure: 1) {
                        window.sendEvent(e)
                    }
                }
            }
            return "frame \(window.frame)"
        case "front":
            // Brings the window in front without activating the app, and says
            // where it is on screen (from the top-left, as screencapture takes it).
            guard let window = wc?.window, let screen = window.screen ?? NSScreen.main else { return "no window" }
            window.orderFrontRegardless()
            let f = window.frame
            return "\(Int(f.minX)),\(Int(screen.frame.height - f.maxY)),\(Int(f.width)),\(Int(f.height))"
        case "dragimage":
            // Writes the image a dragged sheet shows, for the focused pane.
            guard let pane = wc?.debugFocusedPane else { return "no pane" }
            let image = SheetDragImage.make(for: pane)
            let rep = NSBitmapImageRep(data: image.tiffRepresentation!)!
            try? rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: arg))
            return "wrote \(arg)"
        case "type":
            // Types into whatever text view has the keyboard (an editor, say).
            guard let tv = wc?.window?.firstResponder as? NSTextView else { return "no text view focused" }
            tv.insertText(arg.replacingOccurrences(of: "\\n", with: "\n"), replacementRange: tv.selectedRange())
            return "ok"
        case "scheme":
            guard let scheme = ColorScheme(rawValue: arg) else { return "system, light or dark" }
            let item = NSMenuItem()
            item.representedObject = scheme.rawValue
            wc?.setColorScheme(item)
            return "ok"
        case "theme":
            guard let theme = FontTheme(rawValue: arg) else { return "mona, recursive, go or system" }
            let item = NSMenuItem()
            item.representedObject = theme.rawValue
            wc?.setTheme(item)
            return "ok"
        case "editorfont":
            guard let font = EditorFont(rawValue: arg) else { return "proportional or monospaced" }
            let item = NSMenuItem()
            item.representedObject = font.rawValue
            wc?.setEditorFont(item)
            return "ok"
        case "cmdclick":
            // "cmdclick x y": ⌘ down, the mouse moved there, and a ⌘-click,
            // all through the window (window coordinates from the top-left).
            let a = arg.split(separator: " ").compactMap { Double($0) }
            guard a.count == 2, let window = wc?.window else { return "usage: cmdclick x y" }
            let p = NSPoint(x: a[0], y: window.contentView!.bounds.height - a[1])
            let now = ProcessInfo.processInfo.systemUptime
            let t = window.contentView?.hitTest(p) as? TerminalView
            if let flags = NSEvent.keyEvent(with: .flagsChanged, location: p, modifierFlags: .command, timestamp: now,
                                            windowNumber: window.windowNumber, context: nil, characters: "",
                                            charactersIgnoringModifiers: "", isARepeat: false, keyCode: 0x37) {
                t?.flagsChanged(with: flags)
            }
            if let moved = NSEvent.mouseEvent(with: .mouseMoved, location: p, modifierFlags: .command, timestamp: now,
                                              windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 0, pressure: 0) {
                t?.mouseMoved(with: moved)
            }
            for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                if let e = NSEvent.mouseEvent(with: type, location: p, modifierFlags: .command, timestamp: now,
                                              windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1) {
                    window.sendEvent(e)
                }
            }
            return t == nil ? "no terminal there" : "ok"
        case "caret":
            // Where the focused text view's caret is: line and column, from 1.
            guard let tv = wc?.window?.firstResponder as? NSTextView else { return "no text view focused" }
            let s = tv.string as NSString
            let loc = tv.selectedRange().location
            let before = s.substring(to: loc)
            let line = before.components(separatedBy: "\n").count
            let column = loc - (before as NSString).range(of: "\n", options: .backwards).location
            return "line \(line) column \(before.contains("\n") ? column : loc + 1)"
        case "putaway":
            // "putaway <minutes>": as if every hidden sheet were last seen that long ago.
            wc?.debugPutAway(agingBy: Double(arg) ?? 120)
            return "ok"
        case "switcher":
            return wc?.debugSwitcher(arg) ?? "no window"
        case "chain":
            // The responder chain from the first responder.
            var r: NSResponder? = wc?.window?.firstResponder
            var out: [String] = []
            while let x = r { out.append("\(type(of: x))"); r = x.nextResponder }
            return out.joined(separator: " → ")
        case "picker":
            // "picker" opens it; "picker <query>" says what it lists for one.
            if arg.isEmpty {
                wc?.openDocument(nil)
                return "ok"
            }
            return (wc?.debugPicker(arg == "-" ? "" : arg) ?? []).prefix(8).joined(separator: " | ")
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
