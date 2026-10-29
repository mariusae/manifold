import AppKit
import WebKit

/// Something with a list that pages with ⌥↑ and ⌥↓ — a page of rows up or
/// down, the selection with them — while a field has the keyboard (⌘O's,
/// ⌘P's): `direction` -1 up, 1 down; false if there's nothing to page.
protocol OptionPaging: AnyObject {
    func page(_ direction: Int) -> Bool
}

/// ⌥↑ and ⌥↓ as Page Up and Page Down, as the Mac has them outside text
/// (§3): in a list, an outline, a preview — whatever scrolls — wherever
/// the keyboard is. Where text is typed they keep their own meaning: a
/// paragraph up or down in an editor, the shell's in a terminal; a web
/// page pages by itself; and a list a field searches (⌘O, ⌘P) moves its
/// selection a page (`OptionPaging`).
enum OptionKeysPage {
    private static var monitor: Any?

    static func start() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            guard event.modifierFlags.intersection([.command, .shift, .option, .control]) == .option,
                  event.keyCode == 125 || event.keyCode == 126,
                  let window = event.window, let responder = window.firstResponder else { return event }
            let down = event.keyCode == 125
            // A field searching a list: the list's page.
            for candidate in pagers(from: responder, in: window) where candidate.page(down ? 1 : -1) {
                last = "paged \(type(of: candidate))"
                return nil
            }
            // Text typed, a terminal, a web page: theirs.
            last = "left to \(type(of: responder))"
            if responder is TerminalView || responder is TextView { return event }
            if let t = responder as? NSTextView, t.isEditable || t.isFieldEditor { return event }
            if let v = responder as? NSView, sequence(first: v, next: \.superview).contains(where: { $0 is WKWebView }) { return event }
            // Anything else: Page Up or Page Down, along the responder chain;
            // or, where nothing takes those (a list pages in its own keyDown),
            // what it's in scrolled a page, the selection left where it is.
            let action = down ? #selector(NSResponder.scrollPageDown(_:)) : #selector(NSResponder.scrollPageUp(_:))
            if let target = NSApp.target(forAction: action) {
                last = "scrolled by \(type(of: target)) from \(type(of: responder))"
                return NSApp.sendAction(action, to: nil, from: nil) ? nil : event
            }
            if let v = responder as? NSView, let scroll = (v as? NSScrollView) ?? v.enclosingScrollView, scroll.hasVerticalScroller || scroll.verticalScroller != nil {
                page(scroll, down: down)
                last = "paged the scroll view \(type(of: responder)) is in, to \(Int(scroll.contentView.bounds.minY))"
                return nil
            }
            last = "nothing takes it from \(type(of: responder))"
            return event
        }
    }

    /// A scroll view a page up or down: what shows, less a line, so the
    /// line at the edge stays in sight.
    private static func page(_ scroll: NSScrollView, down: Bool) {
        let clip = scroll.contentView
        guard let doc = scroll.documentView else { return }
        let line = max(scroll.verticalLineScroll, 16)
        let step = max(line, clip.bounds.height - line)
        var origin = clip.bounds.origin
        origin.y += (down == doc.isFlipped ? step : -step)
        origin.y = min(max(origin.y, 0), max(0, doc.frame.height - clip.bounds.height))
        clip.scroll(to: origin)
        scroll.reflectScrolledClipView(clip)
    }

    /// Debugging: what the last ⌥↑ or ⌥↓ did.
    private(set) static var last = "none yet"

    /// What might page for the keyboard's holder: it, a field's (and its
    /// delegate) for a field being typed in, those up the responder chain,
    /// and the window's delegate.
    private static func pagers(from responder: NSResponder, in window: NSWindow) -> [OptionPaging] {
        var all: [AnyObject] = []
        var r: NSResponder? = responder
        if let t = responder as? NSTextView, t.isFieldEditor, let field = t.delegate as? NSTextField {
            all.append(field)
            if let d = field.delegate { all.append(d) }
            r = field
        }
        while let next = r {
            all.append(next)
            r = next.nextResponder
        }
        if let d = window.delegate { all.append(d) }
        return all.compactMap { $0 as? OptionPaging }
    }
}
