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
///   org rows | org click <row> [cmd|double]   the sidebar's rows, clicked
///   click x y [count]    click (count times, as a multi-click) in the window
///   front                bring the window forward; print its screen rect
///   dragimage <path>     write the drag image for the focused pane
///   type <text>          type into the focused text view (\n for newlines)
///   picker               open the ⌘O picker
///   dump                 describe the window's views
///   state                describe the desk and the selected arrangement
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
            // "snapshot <path> picker": the picker's panel instead.
            if arg.hasSuffix(" picker") {
                guard let panel = NSApp.windows.first(where: { $0 is PickerPanel && $0.isVisible }) else { return "no picker" }
                return snapshot(panel, to: String(arg.dropLast(7)))
            }
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
                    // Return, as the key (a shell under the kitty keyboard
                    // protocol wants the key, not the character).
                    for type in [NSEvent.EventType.keyDown, .keyUp] {
                        if let e = NSEvent.keyEvent(with: type, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                                    windowNumber: t.window?.windowNumber ?? 0, context: nil, characters: "\r",
                                                    charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: 36) {
                            if type == .keyDown { t.keyDown(with: e) } else { t.keyUp(with: e) }
                        }
                    }
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
        case "mouse":
            // Where the pointer is, in window coordinates from the top-left.
            guard let window = wc?.window else { return "no window" }
            let p = window.convertPoint(fromScreen: NSEvent.mouseLocation)
            return "\(Int(p.x)) \(Int(window.contentView!.bounds.height - p.y))"
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
            wc.open(arg, from: t.placement)
            return "ok"
        case "graph":
            // "graph": the focused block's neighborhood, raw.
            guard let wc, let block = wc.debugFocusedBlock else { return "nothing focused" }
            let n = wc.hosts.neighborhood(of: block)
            var lines = ["block \(block)"]
            for (k, es) in n.outbound { for e in es { lines.append("out \(k) → \(e.to) [\(e.context ?? "")] from \(e.shard) id \(e.id)") } }
            for (k, es) in n.inbound { for e in es { lines.append("in \(k) ← \(e.from) [\(e.context ?? "")] from \(e.shard) id \(e.id)") } }
            for t in n.before { lines.append("before \(t.block) ×\(t.count)") }
            for t in n.after { lines.append("after \(t.block) ×\(t.count)") }
            lines.append("hosts: " + wc.hosts.all.map { $0.host.raw }.joined(separator: ", "))
            return lines.joined(separator: "\n")
        case "js":
            // "js <code>": runs it in the focused preview's or web block's page.
            guard let wc, let web = wc.debugFocusedWebView else { return "no page focused" }
            let done = DispatchSemaphore(value: 0)
            var out = ""
            web.evaluateJavaScript(arg) { r, e in out = e.map { "error: \($0.localizedDescription)" } ?? "\(r ?? "")"; done.signal() }
            // Pumped on the main thread: the socket is handled there too.
            while done.wait(timeout: .now()) != .success { RunLoop.main.run(mode: .default, before: Date(timeIntervalSinceNow: 0.02)) }
            return out
        case "views":
            // The focused placement's kept lens state.
            guard let wc, let f = wc.debugFocusedPlacement?.id, let b = wc.debugFocusedBlock else { return "nothing focused" }
            return (wc.hosts.block(b)?.views?[f] ?? [:]).map { "\($0.key)=\($0.value.prefix(60))" }.sorted().joined(separator: "\n")
        case "tablesel":
            // The focused lens's table: its selected row.
            guard let wc, let v = wc.debugFocusedView else { return "nothing focused" }
            func find(_ v: NSView) -> NSTableView? { (v as? NSTableView) ?? v.subviews.lazy.compactMap(find).first }
            guard let t = find(v) else { return "no table" }
            return "row \(t.selectedRow) of \(t.numberOfRows)"
        case "mdlink":
            // "mdlink <n>": clicks the nth link in the focused preview, as a reader would.
            guard let wc, let m = wc.debugFocusedMarkdown else { return "no preview focused" }
            m.debugClickLink(Int(arg) ?? 0)
            return "ok"
        case "hood":
            // "hood": the focused block's neighborhood view, settled, and its model.
            return wc?.debugNeighborhood(settle: true) ?? "no window"
        case "stack":
            // "stack": the focused tile's column, each tile with its share
            // (0: stashed); "stack swap": the first stashed tile behind the
            // focused one takes the top, as ⇧-click on its pill does.
            guard let wc else { return "no window" }
            return wc.debugStack(swap: arg == "swap")
        case "focused":
            return wc?.debugFocusedBlock?.description ?? "nothing focused"
        case "scrub":
            // "scrub": the focused terminal's scrubber; "scrub hover <f>",
            // "scrub go|open <id>", "scrub locate", "scrub row <n>".
            let a = arg.split(separator: " ", maxSplits: 1).map(String.init)
            if let t = wc?.debugFocusedTerminal { return t.debugScrub(a.first ?? "", a.count > 1 ? a[1] : "") }
            if let e = wc?.debugFocusedEditor { return e.debugScrub(a.first ?? "", a.count > 1 ? a[1] : "") }
            return "no terminal or editor focused"
        case "org":
            // "org rows": the sidebar's rows; "org click <row> [cmd|double]".
            let a = arg.split(separator: " ").map(String.init)
            guard let wc else { return "no window" }
            if a.first == "rows" { return wc.debugOrganization.debugRows() }
            if a.first == "click", a.count >= 2, let row = Int(a[1]) {
                return wc.debugOrganization.debugClick(row: row, command: a.contains("cmd"), double: a.contains("double"))
            }
            if a.first == "expand", a.count >= 2, let row = Int(a[1]) { return wc.debugOrganization.debugExpand(row: row) }
            if a.first == "hover", a.count >= 2, let row = Int(a[1]) { return wc.debugOrganization.debugHover(row: row) }
            if a.first == "menu", a.count >= 2, let row = Int(a[1]) { return wc.debugOrganization.debugMenu(row: row, choose: a.dropFirst(2).joined(separator: " ")) }
            return "usage: org rows | org click <row> [cmd|double] | org expand <row> | org hover <row> | org menu <row> [title]"
        case "run":
            // "run <title prefix>": a palette item, by its title.
            return wc?.debugRunPaletteItem(arg) ?? "no window"
        case "sv":
            // "sv list|overview|leave": the state view's mode, or leaving it.
            guard let wc else { return "no window" }
            switch arg {
            case "list": wc.debugStateView(mode: .list)
            case "overview": wc.debugStateView(mode: .overview)
            case "leave": wc.hideStateView()
            default: return "usage: sv list|overview|leave"
            }
            return "ok"
        case "attend":
            // As focusing the block with the window key does: dismisses
            // its done or failed status.
            guard let wc, let b = wc.debugFocusedBlock else { return "nothing focused" }
            wc.hosts.propose(.attend(b))
            return "ok"
        case "attend":
            // As focusing the block with the window key does: dismisses
            // its done or failed status.
            guard let wc, let b = wc.debugFocusedBlock else { return "nothing focused" }
            wc.hosts.propose(.attend(b))
            return "ok"
        case "scroll":
            // "scroll x y dy": a wheel turned dy lines over that point (window
            // coordinates from the top-left), to the view there.
            let a = arg.split(separator: " ").compactMap { Double($0) }
            guard a.count == 3, let window = wc?.window, let content = window.contentView else { return "usage: scroll x y dy" }
            let p = NSPoint(x: a[0], y: content.bounds.height - a[1])
            guard let cg = CGEvent(scrollWheelEvent2Source: nil, units: .line, wheelCount: 1, wheel1: Int32(a[2]), wheel2: 0, wheel3: 0),
                  let e = NSEvent(cgEvent: cg), let hit = content.hitTest(p) else { return "no event" }
            hit.scrollWheel(with: e)
            return "scrolled \(type(of: hit))"
        case "hover":
            // "hover x y": the pointer moved there (window coordinates from the top-left).
            let a = arg.split(separator: " ").compactMap { Double($0) }
            guard a.count == 2, let window = wc?.window else { return "usage: hover x y" }
            let p = NSPoint(x: a[0], y: window.contentView!.bounds.height - a[1])
            if let e = NSEvent.mouseEvent(with: .mouseMoved, location: p, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                          windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 0, pressure: 0) {
                window.sendEvent(e)
                wc?.debugHover(e)
            }
            return "ok"
        case "click":
            // "click x y [count] [cmd] [shift]": a left click at window
            // coordinates from the top-left, sent through the window as a
            // real one would be.
            let words = arg.split(separator: " ")
            let a = words.compactMap { Double($0) }
            guard a.count >= 2, let window = wc?.window else { return "usage: click x y [count] [cmd] [shift]" }
            let p = NSPoint(x: a[0], y: window.contentView!.bounds.height - a[1])
            let count = a.count > 2 ? Int(a[2]) : 1
            var mods: NSEvent.ModifierFlags = []
            if words.contains("cmd") { mods.insert(.command) }
            if words.contains("shift") { mods.insert(.shift) }
            for n in 1...count {
                for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                    if let e = NSEvent.mouseEvent(with: type, location: p, modifierFlags: mods, timestamp: ProcessInfo.processInfo.systemUptime,
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
            // Writes the image a dragged sheet shows, for the focused placement.
            guard let pane = wc?.debugFocusedPlacement else { return "no placement" }
            let image = BlockDragImage.make(for: pane)
            let rep = NSBitmapImageRep(data: image.tiffRepresentation!)!
            try? rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: arg))
            return "wrote \(arg)"
        case "type":
            // Types into whatever text view has the keyboard (an editor, say).
            let typed = arg.replacingOccurrences(of: "\\n", with: "\n")
            if let tv = wc?.window?.firstResponder as? TextView {
                for ch in typed {
                    if ch == "\n" { tv.doCommand(by: #selector(NSResponder.insertNewline(_:))) } else { tv.insertText(String(ch), replacementRange: NSRange(location: NSNotFound, length: 0)) }
                }
                return "ok"
            }
            guard let tv = wc?.window?.firstResponder as? NSTextView else { return "no text view focused" }
            tv.insertText(typed, replacementRange: tv.selectedRange())
            return "ok"
        case "rename":
            // "rename <name>": the symbol at the focused editor's caret, through its language server.
            guard let tv = wc?.window?.firstResponder as? TextView else { return "no text view focused" }
            var v: NSView? = tv
            while let n = v, !(n is EditorView) { v = n.superview }
            guard let editor = v as? EditorView else { return "no editor" }
            editor.rename(at: tv.primarySelection.head, to: arg)
            return "ok"
        case "press":
            // "press return|tab|escape|up|down|<char>": a key event through
            // the window, as typed (so popups see it).
            guard let window = wc?.window else { return "no window" }
            let codes: [String: (String, UInt16)] = ["return": ("\r", 36), "tab": ("\t", 48), "escape": ("\u{1B}", 53), "space": (" ", 49),
                                                     "left": (String(UnicodeScalar(NSLeftArrowFunctionKey)!), 123),
                                                     "right": (String(UnicodeScalar(NSRightArrowFunctionKey)!), 124),
                                                     "up": (String(UnicodeScalar(NSUpArrowFunctionKey)!), 126),
                                                     "down": (String(UnicodeScalar(NSDownArrowFunctionKey)!), 125)]
            let (chars, code) = codes[arg] ?? (arg, 0)
            for type in [NSEvent.EventType.keyDown, .keyUp] {
                if let e = NSEvent.keyEvent(with: type, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                            windowNumber: window.windowNumber, context: nil, characters: chars,
                                            charactersIgnoringModifiers: chars, isARepeat: false, keyCode: code) {
                    window.sendEvent(e)
                }
            }
            return "ok"
        case "key":
            // "key <selector>": a standard key command to the focused text view.
            guard let tv = wc?.window?.firstResponder as? TextView else { return "no text view focused" }
            tv.doCommand(by: Selector(arg))
            return "ok"
        case "editor":
            // The focused editor's text, selections, and undo depth.
            guard let tv = wc?.window?.firstResponder as? TextView else { return "no text view focused" }
            return "selections \(tv.selections.map { "\($0.min)-\($0.max)" }) undo \(tv.undoDepth) line \(tv.caretLine + 1) col \(tv.caretColumn)\n" + tv.text.string
        case "scheme":
            guard let scheme = ColorScheme(rawValue: arg) else { return "system, light or dark" }
            let item = NSMenuItem()
            item.representedObject = scheme.rawValue
            wc?.setColorScheme(item)
            return "ok"
        case "theme":
            guard let theme = FontTheme(rawValue: arg) else { return "notes, tiempos, mona, recursive, go or system" }
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
            if let tv = wc?.window?.firstResponder as? TextView { return "line \(tv.caretLine + 1) column \(tv.caretColumn)" }
            guard let tv = wc?.window?.firstResponder as? NSTextView else { return "no text view focused" }
            let s = tv.string as NSString
            let loc = tv.selectedRange().location
            let before = s.substring(to: loc)
            let line = before.components(separatedBy: "\n").count
            let column = loc - (before as NSString).range(of: "\n", options: .backwards).location
            return "line \(line) column \(before.contains("\n") ? column : loc + 1)"
        case "collect":
            wc?.debugCollect(agingBy: Double(arg) ?? 120)
            return "ok"
        case "state":
            return wc?.debugDescribe() ?? "no window"
        case "attach":
            guard let dest = Destination(arg) else { return "usage: attach user@host | provider:name" }
            wc?.attach(dest)
            return "ok"
        case "hosts":
            guard let wc else { return "no window" }
            return wc.hosts.all.map { "\($0.host) \($0.isRemote ? ($0.destination?.description ?? "") : "local") \($0.isConnected ? "connected" : "offline") \($0.node.blocks.count) blocks" }.joined(separator: "\n")
                + (wc.hosts.errors.isEmpty ? "" : "\nerrors: \(wc.hosts.errors)")
        case "recall":
            guard let id = BlockID(string: arg) else { return "usage: recall host/ulid" }
            wc?.recall(id)
            return "ok"
        case "chain":
            // The responder chain from the first responder.
            var r: NSResponder? = wc?.window?.firstResponder
            var out: [String] = []
            while let x = r { out.append("\(type(of: x))"); r = x.nextResponder }
            return out.joined(separator: " → ")
        case "remoting":
            // "remoting add" presses +; "remoting" lists the rows.
            return wc?.debugRemoting(arg) ?? "no window"
        case "picker":
            // "picker" opens it; "picker <query>" says what it lists for one.
            // "picker go" chooses the selected row; "picker down"/"up" move it.
            if arg.isEmpty {
                wc?.openDocument(nil)
                return "ok"
            }
            if arg == "go" {
                wc?.debugFinderChoose()
                return "ok"
            }
            if arg.hasPrefix("scope "), let n = Int(arg.dropFirst(6)) {
                wc?.debugFinderScope(n)
                return "ok"
            }
            if arg == "down" || arg == "up" {
                wc?.debugFinderMove(arg == "down" ? 1 : -1)
                return "ok"
            }
            return (wc?.debugFinder(arg == "-" ? "" : arg) ?? []).prefix(12).joined(separator: " | ")
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
        var s = String(repeating: "  ", count: depth) + "\(type(of: v)) \(v.frame)\(v.isHidden ? " hidden" : "")\(v.alphaValue < 1 ? " alpha \(v.alphaValue)" : "")"
        if let t = v as? TerminalView { s += " block=\(t.block) surface=\(t.surface != nil)" }
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
            guard v.bounds.width >= 1, v.bounds.height >= 1, let img = v.bitmapImageRepForCachingDisplay(in: v.bounds) else { return }
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
        // Child windows (popups) over it, where they are on screen.
        for child in window.childWindows ?? [] {
            guard child.isVisible, let cv = child.contentView, cv.bounds.width >= 1, cv.bounds.height >= 1,
                  let img = cv.bitmapImageRepForCachingDisplay(in: cv.bounds) else { continue }
            cv.cacheDisplay(in: cv.bounds, to: img)
            let origin = window.convertPoint(fromScreen: child.frame.origin)
            let r = NSRect(x: origin.x, y: origin.y, width: child.frame.width, height: child.frame.height)
            let inRoot = root.convert(r, from: nil)
            if let cg = img.cgImage { ctx.draw(cg, in: inRoot) }
        }
        NSGraphicsContext.restoreGraphicsState()
        do {
            try rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: path))
            return "wrote \(path)"
        } catch {
            return "\(error)"
        }
    }
}
