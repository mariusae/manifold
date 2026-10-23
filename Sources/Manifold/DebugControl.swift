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
            // Laid out first, as a display would be (with the display asleep,
            // none comes, and what's drawn is from before the last change).
            window.contentView?.layoutSubtreeIfNeeded()
            return snapshot(window, to: arg.isEmpty ? "/tmp/manifold.png" : arg)
        case "action":
            let sel = Selector(arg)
            let start: NSResponder? = wc?.window?.firstResponder ?? wc?.window
            let ok = start?.tryToPerform(sel, with: nil) ?? false
            return ok ? "ok" : "not handled"
        case "smartlog":
            // The focused smartlog tile: what it shows.
            guard let s = wc?.debugFocusedView as? SmartlogView else { return "no smartlog focused" }
            return s.debugState
        case "screen":
            // What the focused terminal shows, as text.
            guard let t = wc?.debugFocusedTerminal else { return "no terminal focused" }
            // Its identity first: whether it's the same view as before.
            return "view \(UInt(bitPattern: ObjectIdentifier(t).hashValue))\n" + t.visibleText
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
            if arg.hasPrefix("search ") { return wc?.debugSidebarView.debugTypeFilter(String(arg.dropFirst(7))) ?? "no window" }
            // "sidebar pin": pinned, or not, as its pin button does.
            if arg == "pin" { wc?.sidebarTogglePinned(); return "ok" }
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
            if arg.hasPrefix("text ") {
                // "sheet text <text>": into its text area ("\n" a new line).
                guard let tv = allSubviews(sheet.contentView).compactMap({ $0 as? NSTextView }).first(where: { !$0.isFieldEditor }) else { return "no text area" }
                tv.string = String(arg.dropFirst(5)).replacingOccurrences(of: "\\n", with: "\n")
                return "ok"
            }
            if arg.hasPrefix("press ") {
                guard let b = buttons.first(where: { $0.title == String(arg.dropFirst(6)) }) else { return "no button" }
                b.performClick(nil)
                return "ok"
            }
            let words = allSubviews(sheet.contentView).compactMap { $0 as? NSTextField }.filter { !$0.isEditable && !$0.stringValue.isEmpty }.map(\.stringValue)
            return "fields: \(fields.map(\.stringValue)) buttons: \(buttons.map(\.title)) says: \(words)"
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
            // Five seconds at most: a page that never answers (not loaded) isn't waited on forever.
            let end = Date().addingTimeInterval(5)
            while done.wait(timeout: .now()) != .success {
                guard Date() < end else { return "no answer in 5 s" }
                RunLoop.main.run(mode: .default, before: Date(timeIntervalSinceNow: 0.02))
            }
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
            // "stack next": ⌥-click on the focused tile's pill; "stack hold"
            // and "stack release": ⌥ taken as held, or let go.
            guard let wc else { return "no window" }
            let a = arg.split(separator: " ").map(String.init)
            if a.first == "hold" || a.first == "release" { wc.debugOptionHeld = a.first == "hold" }
            // "stack focus <placement suffix>": that tile focused.
            if a.first == "focus", a.count > 1, !wc.debugFocus(placementEndingIn: a[1]) { return "no \(a[1])" }
            return wc.debugStack(swap: a.first == "swap" || a.first == "next", index: a.first == "next" ? -1 : a.count > 1 ? Int(a[1]) ?? 0 : 0)
        case "type":
            // "type <text>": into the focused editor.
            return wc?.debugType(arg.replacingOccurrences(of: "\\n", with: "\n")) ?? "no window"
        case "drop":
            // "drop <block>": a block ⇧-dragged into the focused editor;
            // "drop row N": the shown outline's item N, ⇧-dragged there.
            if arg.hasPrefix("row "), let i = Int(arg.dropFirst(4)) { return wc?.debugDropRow(i) ?? "no window" }
            guard let id = BlockID(string: arg) else { return "usage: drop <host/ulid>" }
            return wc?.debugDrop(id) ?? "no window"
        case "pills":
            return wc?.debugPills ?? "no window"
        case "dirty":
            // "dirty": each tile's dirty dot; "dirty click": the focused one's clicked.
            return arg == "click" ? wc?.debugDirtyClick() ?? "no window" : wc?.debugDirty ?? "no window"
        case "find":
            // "find <query>": the focused editor's find pill, typed in.
            guard let e = wc?.debugFocusedEditor else { return "no editor focused" }
            e.debugFind(arg)
            return "first responder \(type(of: e.window?.firstResponder.map { $0 } as Any))"
        case "topline":
            return wc?.debugTopLine() ?? "no window"
        case "agents":
            // Launch Agent Here, as it would open now.
            return wc?.agentMenuItems().map { $0.title + ($0.isEnabled ? "" : " (disabled)") }.joined(separator: "\n") ?? "no window"
        case "pushdown":
            // "pushdown c r": the line under column c's rth shown tile dragged down past the next.
            let a = arg.split(separator: " ").compactMap { Int($0) }
            guard a.count == 2, let wc else { return "usage: pushdown column row" }
            return wc.debugPushDown(column: a[0], row: a[1])
        case "termmenu":
            // The focused terminal's right-click menu, its items and submenus listed.
            guard let t = wc?.debugFocusedTerminal, let window = wc?.window else { return "no terminal focused" }
            let p = t.convert(NSPoint(x: 20, y: 20), to: nil)
            guard let e = NSEvent.mouseEvent(with: .rightMouseDown, location: p, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1),
                  let menu = t.menu(for: e) else { return "no menu" }
            func list(_ m: NSMenu, _ depth: Int) -> [String] {
                m.items.flatMap { i -> [String] in
                    [String(repeating: "  ", count: depth) + (i.isSeparatorItem ? "—" : i.title)] + (i.submenu.map { list($0, depth + 1) } ?? [])
                }
            }
            return list(menu, 0).joined(separator: "\n")
        case "outline":
            // The focused block's outline lens, beside its tile; "outline
            // entries", "outline click <n>": the outline lens on screen.
            guard let wc else { return "no window" }
            let words = arg.split(separator: " ").map(String.init)
            if let o = wc.debugOutlineLens {
                if words.first == "entries" { return o.debugEntries }
                if words.first == "click", words.count > 1, let n = Int(words[1]) { return o.debugClick(n) }
            }
            guard let f = wc.debugFocusedPlacement else { return "nothing focused" }
            wc.showOutline(of: f.placement.block, beside: f.id)
            return "ok"
        case "layerimage":
            // "layerimage <path>": the surface as Core Animation draws it, its
            // own layers (the sheets) included.
            guard let wc, let view = wc.debugSurface, let layer = view.layer else { return "no surface" }
            let scale = view.window?.backingScaleFactor ?? 2
            let w = Int(view.bounds.width * scale), h = Int(view.bounds.height * scale)
            guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return "no context" }
            ctx.setFillColor(NSColor.white.cgColor)
            ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
            ctx.scaleBy(x: scale, y: scale)
            view.effectiveAppearance.performAsCurrentDrawingAppearance { layer.render(in: ctx) }
            guard let img = ctx.makeImage(), let data = NSBitmapImageRep(cgImage: img).representation(using: .png, properties: [:]) else { return "no image" }
            try? data.write(to: URL(fileURLWithPath: arg))
            return "wrote \(arg)"
        case "orgdrop":
            // "orgdrop host <session> <index>": a host's row dropped among the hosts;
            // "orgdrop ws <workspace> <host session> <index>": a workspace's among its host's rows.
            let a = arg.split(separator: " ").map(String.init)
            guard let wc, a.count >= 3, let index = Int(a.last!) else { return "usage: orgdrop host <session> <i> | ws <workspace> <host> <i>" }
            if a[0] == "host" { return wc.organizationDrop(.host(HostID(a[1])), onto: nil, at: index, copy: false) ? "ok" : "refused" }
            guard a[0] == "ws", a.count == 4, let ws = BlockID(string: a[1]) else { return "usage" }
            let node = OrgNode(id: "host:\(a[2])", title: "", symbol: "")
            return wc.organizationCanDrop(.arrangement(ws), onto: node, at: index) && wc.organizationDrop(.arrangement(ws), onto: node, at: index, copy: false) ? "ok" : "refused"
        case "mousebutton":
            // "mousebutton <n>": an other-button press (3 back, 4 forward) in the window, through the app.
            guard let window = wc?.window, let n = Int64(arg),
                  let base = NSEvent.mouseEvent(with: .otherMouseDown, location: NSPoint(x: window.frame.width / 2, y: window.frame.height / 2),
                                                modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                                                context: nil, eventNumber: 0, clickCount: 1, pressure: 1),
                  let cg = base.cgEvent else { return "usage: mousebutton <n>" }
            cg.setIntegerValueField(.mouseEventButtonNumber, value: n)
            guard let e = NSEvent(cgEvent: cg) else { return "no event" }
            NSApp.postEvent(e, atStart: false)
            return "posted button \(e.buttonNumber) to window \(e.window === window ? "ok" : "none")"
        case "resetserver":
            // "resetserver <host label or id>": Reset Server, unasked.
            guard let wc else { return "no window" }
            guard let c = wc.hosts.remotes.values.first(where: { $0.host.raw == arg || wc.hosts.label(of: $0.host) == arg }) else { return "no such remote" }
            wc.hosts.resetServer(c.host)
            return "resetting \(c.host)"
        case "resetgraph":
            // "resetgraph <host label or id>": Reset Graph, unasked.
            guard let wc else { return "no window" }
            guard let c = wc.hosts.all.first(where: { $0.host.raw == arg || wc.hosts.label(of: $0.host) == arg }) else { return "no such host" }
            // Answered on this thread, later: see graphcount.
            wc.hosts.resetGraph(on: c.host) { e in if let e { NSLog("resetgraph: %@", e) } }
            return "asked"
        case "graphcount":
            guard let wc else { return "no window" }
            return wc.hosts.all.map { "\(wc.hosts.label(of: $0.host)): \($0.node.links($0.host).links.count) links, \($0.node.registry($0.host).trail.count) steps" }.joined(separator: "\n")
        case "pillmenu":
            // "pillmenu [title]": the focused tile's menu, or that item chosen.
            return wc?.debugPillMenu(arg) ?? "no window"
        case "workspaces":
            return wc?.debugWorkspaces() ?? "no window"
        case "print":
            // "print <out.pdf>": the focused tile printed to a PDF, no panel.
            guard let wc, let op = wc.debugPrintOperation else { return "not printable" }
            op.printInfo.jobDisposition = .save
            op.printInfo.dictionary()[NSPrintInfo.AttributeKey.jobSavingURL] = URL(fileURLWithPath: arg)
            op.showsPrintPanel = false
            op.showsProgressPanel = false
            // As ⌘P runs it (a web page's must be): modal for the window.
            guard let window = wc.window else { return "no window" }
            op.runModal(for: window, delegate: nil, didRun: nil, contextInfo: nil)
            return "printing"
        case "noteimage":
            // "noteimage <file>": the image put in the focused editor, as a paste would.
            guard let e = wc?.debugFocusedEditor, let data = try? Data(contentsOf: URL(fileURLWithPath: arg)) else { return "no editor focused, or no file" }
            e.textView.onImage?(data, arg.pathExtension.lowercased())
            return "kept"
        case "handlers":
            return CrashGuard.debugHandlers
        case "crash":
            // A deliberate crash (a Swift trap), for the crash guard.
            let nothing: Int? = arg == "never" ? 1 : nil
            return "\(nothing!)"
        case "turns":
            // "turns <agent>": its turns; "turns <agent> show N": the turn's block, its Markdown;
            // "turns <agent> undo N": undone, no asking.
            let a = arg.split(separator: " ").map(String.init)
            guard let wc, let first = a.first, let id = BlockID(string: first), let b = wc.hosts.block(id) else { return "no such block" }
            if a.count == 2, a[1] == "todo" {
                let note = wc.hosts.links.first { $0.from == id && $0.context == "to-do list" }?.to
                return note.flatMap { n in wc.hosts.block(n).map { "\($0.displayTitle)\n" + ($0.text?.text.string ?? "") } } ?? "no to-do note"
            }
            if a.count == 3, let n = Int(a[2]) {
                if a[1] == "show" {
                    wc.showTurn(n, of: id, place: .here)
                    return "showing"
                }
                if a[1] == "undo" {
                    wc.hosts.propose(.undoTurn(agent: id, turn: n)) { e in NSLog("undo turn: %@", e ?? "ok") }
                    return "undoing"
                }
                if a[1] == "todo" {
                    let note = wc.hosts.links.first { $0.from == id && $0.context == "to-do list" }?.to
                    return note.flatMap { n in wc.hosts.block(n).map { "\($0.displayTitle)\n" + ($0.text?.text.string ?? "") } } ?? "no to-do note"
                }
                if a[1] == "count" {
                    return "\(wc.hosts.blocks.filter { $0.output?.source == id && $0.output?.command == n }.count) blocks"
                }
                if a[1] == "md" {
                    return wc.hosts.blocks.first { $0.output?.source == id && $0.output?.command == n }?.output?.markdown ?? "no block"
                }
            }
            return (b.terminal?.turns ?? []).map { t in
                "\(t.id) \(t.prompt.prefix(40)) repo=\(t.repo ?? "-") before=\(t.before?.prefix(7) ?? "-") after=\(t.after?.prefix(7) ?? "-") files=\(t.files ?? []) said=\(t.message?.prefix(30) ?? "-")"
            }.joined(separator: "\n")
        case "agenttest":
            // "agenttest <repo>": an agent running `sleep 600` there; its id.
            guard let wc else { return "no window" }
            let id = BlockID(host: wc.hosts.local.host)
            wc.hosts.local.propose(.newAgent(block: id, cwd: arg, command: "sleep 600"))
            return id.description
        case "uncommitted":
            // "uncommitted <repo>": its outstanding changes' diff block, shown.
            guard let wc, let client = wc.hosts.client(wc.host.host) else { return "no window" }
            let d = client.diffBlock(.uncommitted(repo: arg))
            wc.show(d, lens: .diff, .here)
            return d.description
        case "agentchanges":
            // "agentchanges <agent>": its changes' diff block made; its patch so far.
            guard let wc, let id = BlockID(string: arg), let snap = wc.hosts.block(id)?.terminal?.snapshot else { return "no snapshot" }
            wc.showAgentChanges(id, snap, beside: wc.debugFocusedPlacement?.placement.id ?? "")
            let d = wc.hosts.blocks.first { $0.kind == .diff && $0.diff?.subject == .since(repo: snap.repo, tree: snap.tree, title: "Changes by \(wc.hosts.block(id)?.displayTitle ?? "the agent") in \(snap.repo.lastPathComponent)") }
            return "snapshot \(snap.tree.prefix(10)) of \(snap.repo)\n" + (d?.diff?.patch ?? d?.diff?.error ?? "(not loaded yet)")
        case "forward":
            // "forward <port>": this host's port through a tunnel (see the log).
            guard let wc, let port = Int(arg) else { return "usage: forward <port>" }
            wc.hosts.local.forwards.forward(port) { local in NSLog("forwarded %d to %@", port, local.map(String.init) ?? "nothing") }
            return "forwarding"
        case "copyinto":
            // "copyinto [host:]<folder> <local path>…": as if dropped on the
            // folder (this host's, or another's).
            let a = arg.split(separator: " ").map(String.init)
            guard let wc, a.count >= 2 else { return "usage: copyinto [host:]<folder> <path>…" }
            let target = a[0].split(separator: ":", maxSplits: 1).map(String.init)
            let (on, folder) = target.count == 2 ? (HostID(target[0]), target[1]) : (wc.hosts.local.host, a[0])
            wc.copy(a.dropFirst().map { .local(URL(fileURLWithPath: $0)) }, into: folder, on: on)
            return "copying"
        case "copyentry":
            // "copyentry <host>:<path> <host>:<folder>": a host's entry dropped on a
            // folder of another's (or the same's), as a drag between folder tiles.
            let a = arg.split(separator: " ").map { $0.split(separator: ":", maxSplits: 1).map(String.init) }
            guard let wc, a.count == 2, a[0].count == 2, a[1].count == 2 else { return "usage: copyentry <host>:<path> <host>:<folder>" }
            var isDir: ObjCBool = false
            FileManager.default.fileExists(atPath: a[0][1], isDirectory: &isDir)
            wc.copy([.entry(host: HostID(a[0][0]), path: a[0][1], isDirectory: isDir.boolValue)], into: a[1][1], on: HostID(a[1][0]))
            return "copying"
        case "revision":
            // "revision <repo> <path> <rev>": the file as the revision has it, beside the focused tile.
            let a = arg.split(separator: " ").map(String.init)
            guard let wc, a.count == 3, let v = wc.debugFocusedView as? PaneContent else { return "usage: revision <repo> <path> <rev> (a tile focused)" }
            wc.showRevision(a[1], repo: a[0], revision: a[2], from: v)
            return "showing"
        case "moveinto":
            // "moveinto <folder> <path>": as if this host's entry were dropped on the folder.
            let a = arg.split(separator: " ").map(String.init)
            guard let wc, a.count == 2 else { return "usage: moveinto <folder> <path>" }
            var dir: ObjCBool = false
            FileManager.default.fileExists(atPath: a[1], isDirectory: &dir)
            wc.copy([.entry(host: wc.hosts.local.host, path: a[1], isDirectory: dir.boolValue)], into: a[0], on: wc.hosts.local.host, moving: true)
            return "moving"
        case "rtt":
            // "rtt <host>": a ping's round trip on the control stream now, and
            // the pacing, said in the log when the pong comes (the link is
            // served on this thread: it can't be waited for here).
            guard let wc, let c = wc.hosts.client(HostID(arg)) else { return "no such host" }
            c.debugRoundTrip { t, pacing in NSLog("rtt %@: %@ · %@", arg, t.map { String(format: "%.0f ms", $0 * 1000) } ?? "-", pacing) }
            return "measuring (see the log)"
        case "fetch":
            // "fetch <remote path> <local path> [host]": in pieces, from this
            // host's server (or another's).
            let a = arg.split(separator: " ").map(String.init)
            guard let wc, a.count == 2 || a.count == 3 else { return "usage: fetch <remote> <local> [host]" }
            guard let c = a.count == 3 ? wc.hosts.client(HostID(a[2])) : wc.hosts.local else { return "no such host" }
            Transfers.shared.run(a[0].lastPathComponent, detail: "fetched", symbol: "arrow.down") { progress, done in
                Transfer.download(a[0], on: c, to: URL(fileURLWithPath: a[1]), progress: progress, done: done)
            } then: { e in NSLog("fetch: %@", e ?? "ok") }
            return "fetching"
        case "transfers":
            // The copies shown (and those too quick to be), as the sidebar has them;
            // "transfers stop": the first that runs, stopped.
            if arg == "stop" { Transfers.shared.running.first?.cancel?(); return "stopping" }
            return Transfers.shared.items.map { "\($0.title) [\($0.detail)] \($0.progressText)" }.joined(separator: "\n")
        case "localcopy":
            // "localcopy <path>": fetched to a watched copy (no app opened); says where.
            guard let wc else { return "no window" }
            LocalCopies.shared.onSentBack = { name, _, e in NSLog("sent back %@: %@", name, e ?? "ok") }
            LocalCopies.shared.open(arg, on: wc.hosts.local, label: "here") { url, e in NSLog("local copy: %@", url?.path ?? (e ?? "?")) }
            return "fetching (see the log)"
        case "notifications":
            return (NSApp.delegate as? AppDelegate)?.debugNotifications ?? "?"
        case "nudge":
            // As if the Mac woke: the hosts tried or checked now.
            wc?.hosts.nudgeHosts(after: 0)
            return "nudged"
        case "openlink":
            // "openlink manifold:host/ulid[#command=N]": as from another app.
            wc?.openLink(arg)
            return "ok"
        case "copylink":
            // The focused block's link copied: what the clipboard holds.
            guard let wc, let b = wc.debugFocusedBlock else { return "nothing focused" }
            wc.copyLink(to: b)
            let pb = NSPasteboard.general
            return (pb.types ?? []).map { "\($0.rawValue): \(pb.string(forType: $0) ?? "")" }.joined(separator: "\n")
        case "gridpath":
            return wc?.debugGridPath(arg) ?? "no window"
        case "dockopen":
            // "dockopen <path> …": as if dropped on the Dock icon.
            return wc?.debugOpenPaths(arg) ?? "no window"
        case "dockmenu":
            // "dockmenu [title]": the Dock icon's menu, or that workspace chosen.
            return wc?.debugDockMenu(arg) ?? "no window"
        case "blockdrop":
            // "blockdrop <placement> <workspace|new> [copy]": dropped on the sidebar.
            let a = arg.split(separator: " ").map(String.init)
            guard let wc, a.count >= 2 else { return "usage: blockdrop <placement> <workspace|new> [copy]" }
            return wc.debugBlockDrop(a[0], onto: a[1] == "new" ? nil : BlockID(string: a[1]), copy: a.contains("copy"))
        case "griddrop":
            // "griddrop <placement> <column> <at> [copy]": from another workspace into this grid.
            let a = arg.split(separator: " ").map(String.init)
            guard let wc, a.count >= 3, let c = Int(a[1]), let at = Int(a[2]) else { return "usage: griddrop <placement> <column> <at> [copy]" }
            return wc.debugGridDrop(a[0], column: c, at: at, copy: a.contains("copy"))
        case "sun":
            // "sun [HH:MM|now]": the backdrop's light, at that hour today if given.
            return wc?.debugSun(arg) ?? "no window"
        case "history":
            // This client's focus history; "history back|forward" goes along it.
            guard let wc else { return "no window" }
            if arg == "back" { wc.navigateBack(nil) } else if arg == "forward" { wc.navigateForward(nil) }
            return wc.debugHistory()
        case "links":
            // ⌘ held over the focused editor: the names shown as links.
            guard let e = wc?.debugFocusedEditor else { return "no editor focused" }
            return e.debugLinks(keep: arg == "keep")
        case "pointertarget":
            // Where the pointer would be warped for the focused tile, not moving it.
            return wc?.debugPointerTarget() ?? "no window"
        case "readd":
            // The focused tile's view put back on top of the grid, as a view made afresh is.
            return wc?.debugReadd() ?? "no window"
        case "rightclick":
            // The focused tile's title right-clicked: the stack's fan, or the menu.
            return wc?.debugRightClick() ?? "no window"
        case "switcher":
            // "switcher hover <i>": the open switcher's pointer on card i (0 at the back).
            let a = arg.split(separator: " ")
            guard a.first == "hover", let i = a.dropFirst().first.flatMap({ Int($0) }), let wc else { return "usage: switcher hover <i>" }
            return wc.debugSwitcherHover(i)
        case "badge":
            // "badge": the focused tile's link badge fanned, its links listed;
            // "badge break n": the nth link's × clicked.
            return wc?.debugBadge(arg) ?? "no window"
        case "focused":
            // The focused block, and whether the window is key (status is
            // attended to only while it is).
            return (wc?.debugFocusedBlock?.description ?? "nothing focused") + (wc?.window?.isKeyWindow == true ? " key" : " not key")
                + " responder " + (wc?.window?.firstResponder.map { String(describing: type(of: $0)) } ?? "none")
        case "scrub":
            // "scrub": the focused terminal's scrubber; "scrub hover <f>",
            // "scrub go|open <id>", "scrub locate", "scrub row <n>".
            let a = arg.split(separator: " ", maxSplits: 1).map(String.init)
            if let t = wc?.debugFocusedTerminal { return t.debugScrub(a.first ?? "", a.count > 1 ? a[1] : "") }
            if let e = wc?.debugFocusedEditor { return e.debugScrub(a.first ?? "", a.count > 1 ? a[1] : "") }
            return "no terminal or editor focused"
        case "org":
            // "org rows": the sidebar's rows; "org click <row> [cmd|double]";
            // "org show kept|closed|desk|files|inbox".
            let a = arg.split(separator: " ").map(String.init)
            guard let wc else { return "no window" }
            if a.first == "show", a.count >= 2, let org = Organization(rawValue: a[1]) { wc.setOrganization(org); return "ok" }
            if a.first == "rows" { return wc.debugOrganization.debugRows() }
            if a.first == "click", a.count >= 2, let row = Int(a[1]) {
                return wc.debugOrganization.debugClick(row: row, command: a.contains("cmd"), double: a.contains("double"))
            }
            if a.first == "expand", a.count >= 2, let row = Int(a[1]) { return wc.debugOrganization.debugExpand(row: row) }
            if a.first == "collapse", a.count >= 2, let row = Int(a[1]) { return wc.debugOrganization.debugCollapse(row: row) }
            if a.first == "deep", a.count >= 2, let row = Int(a[1]) { return wc.debugOrganization.debugExpand(row: row, deep: true) }
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
        case "holds":
            // Every host's holds, as its registry has them.
            guard let wc else { return "no window" }
            return wc.hosts.all.map { c in "\(c.host): " + c.registry.holds.values.map { "\($0.id) \($0.block) by \($0.holder)" }.joined(separator: " | ") }.joined(separator: "\n")
        case "collectafter":
            // "collectafter <minutes>": the local host's grace, for trying collection out.
            guard let wc, let m = Int(arg) else { return "usage: collectafter <minutes>" }
            var s = wc.hosts.local.desk.settings
            s.collectAfterMinutes = m
            wc.hosts.local.setSettings(s)
            return "ok"
        case "lastwarp":
            guard let p = Pointer.lastWarp, let window = wc?.window else { return "none" }
            let w = window.convertPoint(fromScreen: p)
            return "\(Int(w.x)) \(Int(window.contentView!.bounds.height - w.y))"
        case "openfile":
            // "openfile <path>": opened as ⌘O opens a file it found.
            guard let wc else { return "no window" }
            wc.open(arg, from: nil)
            return "ok"
        case "over":
            // "over <path or address>": opened over the focused tile, as ⌥-click does.
            guard let wc, let f = wc.debugFocusedPlacement else { return "nothing focused" }
            wc.open(arg, from: f.id, over: true)
            return "ok"
        case "workspace":
            // "workspace <n>": the nth workspace selected, as ⌘n does.
            guard let wc, let n = Int(arg) else { return "usage: workspace <n>" }
            let item = NSMenuItem()
            item.tag = n
            wc.selectTabByNumber(item)
            return "ok"
        case "inbox":
            // The Inbox in ⌘J's order; "inbox next": ⌘J.
            guard let wc else { return "no window" }
            if arg == "next" { wc.nextInInbox(nil) }
            return wc.inboxOrder().map { b in
                let block = wc.hosts.block(b)
                return "\(block?.displayTitle ?? "?") \(block?.statusRecord.map { "\($0.state)\($0.read == true ? " read" : "")" } ?? "") \(b)"
            }.joined(separator: "\n")
        case "nb":
            return wc?.debugNotebook(arg) ?? "no window"
        case "searchpreview":
            return wc?.debugSearchPreview(arg) ?? "no window"
        case "dir":
            return wc?.debugDirectory(arg) ?? "no window"
        case "tilesidebar":
            return wc?.debugTileSidebar(arg) ?? "no window"
        case "keyequiv":
            // "keyequiv <key>": the key with ⌘ through the main menu, as typed; which item took it.
            guard let window = wc?.window, let key = arg.first.map(String.init),
                  let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .command, timestamp: ProcessInfo.processInfo.systemUptime,
                                               windowNumber: window.windowNumber, context: nil, characters: key, charactersIgnoringModifiers: key,
                                               isARepeat: false, keyCode: 37) else { return "usage: keyequiv <key>" }
            if window.performKeyEquivalent(with: event) { return "a view took it" }
            return NSApp.mainMenu?.performKeyEquivalent(with: event) == true ? "the menu took it" : "nothing took it"
        case "omni":
            // The focused tile's address bar: "begin", "type <text>", "key <k>".
            return wc?.debugOmni(arg) ?? "no window"
        case "ticks":
            // "ticks": the focused tile's outline ticks and items; "ticks
            // open", its outline over them; "ticks rows", the list shown;
            // "ticks click N" a row clicked, "ticks click menu N" its menu.
            return wc?.debugTicks(arg) ?? "no window"
        case "outputs":
            return wc?.debugOutputs(arg) ?? "no window"
        case "card":
            if arg.hasPrefix("/") { return HoverCard.shared.debugWritePicture(to: arg) }
            if arg == "hide" { HoverCard.shared.hide(); return "hidden" }
            return HoverCard.shared.debugState
        case "closed":
            // The closed stack, and what nothing reaches.
            return wc?.debugClosed ?? "no window"
        case "reopen":
            wc?.reopenClosed(nil)
            return "ok"
        case "toast":
            return wc?.debugToast ?? "none"
        case "pin":
            wc?.togglePin(nil)
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
            if words.contains("alt") { mods.insert(.option) }
            // "only": the one click, the count-th in a row (as a click
            // in place after others is).
            for n in (words.contains("only") ? count...count : 1...count) {
                for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                    if let e = NSEvent.mouseEvent(with: type, location: p, modifierFlags: mods, timestamp: ProcessInfo.processInfo.systemUptime,
                                                  windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: n, pressure: 1) {
                        NSApp.postEvent(e, atStart: false)
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
            // "cmd+g", "cmd+shift+g": with modifiers, through the app, as
            // the menus and the views' key equivalents see a press.
            var mods: NSEvent.ModifierFlags = []
            var key = arg
            while let plus = key.firstIndex(of: "+"), key.count > 1 {
                switch key[..<plus] {
                case "cmd": mods.insert(.command)
                case "shift": mods.insert(.shift)
                case "opt": mods.insert(.option)
                case "ctrl": mods.insert(.control)
                default: break
                }
                key = String(key[key.index(after: plus)...])
            }
            let codes: [String: (String, UInt16)] = ["return": ("\r", 36), "tab": ("\t", 48), "escape": ("\u{1B}", 53), "space": (" ", 49),
                                                     "pagedown": (String(UnicodeScalar(NSPageDownFunctionKey)!), 121),
                                                     "pageup": (String(UnicodeScalar(NSPageUpFunctionKey)!), 116),
                                                     "left": (String(UnicodeScalar(NSLeftArrowFunctionKey)!), 123),
                                                     "right": (String(UnicodeScalar(NSRightArrowFunctionKey)!), 124),
                                                     "up": (String(UnicodeScalar(NSUpArrowFunctionKey)!), 126),
                                                     "down": (String(UnicodeScalar(NSDownArrowFunctionKey)!), 125)]
            let (chars, code) = codes[key] ?? (key, 0)
            var took = "ok"
            for type in [NSEvent.EventType.keyDown, .keyUp] {
                if let e = NSEvent.keyEvent(with: type, location: .zero, modifierFlags: mods, timestamp: ProcessInfo.processInfo.systemUptime,
                                            windowNumber: window.windowNumber, context: nil, characters: chars,
                                            charactersIgnoringModifiers: chars, isARepeat: false, keyCode: code) {
                    if mods.isEmpty { window.sendEvent(e) } else if type == .keyDown {
                        // As AppKit offers a key equivalent: the window's views, then the menus.
                        if window.performKeyEquivalent(with: e) { took = "a view" }
                        else if NSApp.mainMenu?.performKeyEquivalent(with: e) == true { took = "the menus" }
                        else { took = "nothing" }
                    }
                }
            }
            return took
        case "key":
            // "key <selector>": a standard key command to the focused text view.
            guard let tv = wc?.window?.firstResponder as? TextView else { return "no text view focused" }
            if arg.hasPrefix("cmd+") || arg.hasPrefix("cmd+shift+") {
                // "key cmd+b", "key cmd+shift+x": a shortcut, as a key press.
                let shift = arg.contains("shift+")
                let ch = String(arg.split(separator: "+").last ?? "")
                var flags: NSEvent.ModifierFlags = [.command]
                if shift { flags.insert(.shift) }
                guard let window = wc?.window, let e = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil, characters: ch, charactersIgnoringModifiers: ch, isARepeat: false, keyCode: 0) else { return "no event" }
                tv.keyDown(with: e)
                return "ok"
            }
            // Menu actions, as the Edit menu sends them; the rest as key commands.
            if arg == "paste:" { tv.paste(nil) } else { tv.doCommand(by: Selector(arg)) }
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
            guard let theme = FontTheme(rawValue: arg) else { return "notes, tiempos, tiemposFira, tiemposJetBrains, tiemposAnthrosevka, mona, recursive, go or system" }
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
            if arg == "graph" { wc?.newTab(nil); return "ok" }
            if arg.hasPrefix("picture ") { return wc?.debugFinderPicture(String(arg.dropFirst(8))) ?? "no window" }
            if arg.hasPrefix("time ") { return wc?.debugFinderTime(String(arg.dropFirst(5))) ?? "no window" }
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

        // Clipped only where the screen clips: by a view or layer that clips
        // to its bounds (not, any more, by a scroll view's clip view, which
        // on the screen lets its rows run on past it).
        func draw(_ v: NSView, clip: NSRect) {
            guard !v.isHidden, v.alphaValue > 0 else { return }
            let r = v.convert(v.bounds, to: root)
            let clips = v.clipsToBounds || v.layer?.masksToBounds == true
            let inside = clips ? clip.intersection(r) : clip
            guard !inside.isEmpty else { return }
            ctx.saveGState()
            defer { ctx.restoreGState() }
            ctx.clip(to: inside)
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
            for sub in v.subviews { draw(sub, clip: inside) }
        }
        draw(root, clip: root.bounds)
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
