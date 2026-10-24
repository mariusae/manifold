import AppKit
import WebKit
import ManifoldCore

protocol PanelViewDelegate: AnyObject {
    /// Something done in a panel: what (`event`: click, change, emit, with
    /// the widget's id and value), the values it changed (by id, as JSON),
    /// and the command the widget runs, if it has one.
    func panel(_ view: PanelView, event: [String: Any], changed: [String: String], run: String?)
}

/// A `ui` block (§7.8): the widgets `mani ui` describes, drawn with the
/// system's controls, in a column — labels and Markdown, buttons, fields,
/// text, checkboxes, choices, sliders, progress, tables and lists, images,
/// rows and groups of them, and pages of HTML for what they can't do.
/// What's done in it is told to the delegate (and so to `mani ui wait`
/// and the widgets' commands); values set from the shell show as they
/// come, but not over a field being typed in.
final class PanelView: NSView, PaneContent {
    let placement: PlacementID
    let block: BlockID
    weak var delegate: PanelViewDelegate?
    var source: () -> Block? = { nil }

    private let scroll = NSScrollView()
    private let document = FlippedView()
    private let stack = NSStackView()
    private var shownSpec: String?
    private var shownValues: [String: String] = [:]
    /// The widgets with ids, to set their values as they change.
    private var controls: [String: Control] = [:]
    private var tables: [TableSource] = []

    var focusView: NSView { self }
    var isDead: Bool { false }
    var navLocation: NavLocation? { nil }
    func go(to location: NavLocation) {}
    func destroy() {}

    init(placement: PlacementID, block: BlockID) {
        self.placement = placement
        self.block = block
        super.init(frame: .zero)
        wantsLayer = true
        themed { $0.layer?.backgroundColor = Theme.windowBackground.cgColor }
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.documentView = document
        addSubview(scroll)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false
        document.addSubview(stack)
        document.translatesAutoresizingMaskIntoConstraints = false
        let clip = scroll.contentView
        NSLayoutConstraint.activate([
            document.leadingAnchor.constraint(equalTo: clip.leadingAnchor),
            document.trailingAnchor.constraint(equalTo: clip.trailingAnchor),
            document.topAnchor.constraint(equalTo: clip.topAnchor),
            stack.leadingAnchor.constraint(equalTo: document.leadingAnchor, constant: 20),
            stack.trailingAnchor.constraint(equalTo: document.trailingAnchor, constant: -20),
            stack.topAnchor.constraint(equalTo: document.topAnchor, constant: 18),
            stack.bottomAnchor.constraint(equalTo: document.bottomAnchor, constant: -18),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        scroll.frame = bounds
    }

    /// The block changed: drawn again if its widgets did, else its values set.
    func documentChanged() {
        guard let ui = source()?.ui else { return }
        if ui.spec != shownSpec {
            build(ui)
        } else if ui.values != shownValues {
            for (id, json) in ui.values where shownValues[id] != json { controls[id]?.set(Self.parse(json)) }
            shownValues = ui.values
        }
    }

    // MARK: Building

    private func build(_ ui: UIState) {
        shownSpec = ui.spec
        shownValues = ui.values
        controls = [:]
        tables = []
        stack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        guard let data = ui.spec.data(using: .utf8), let spec = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            stack.addArrangedSubview(NSTextField(wrappingLabelWithString: "This panel's widgets aren't JSON that can be read."))
            return
        }
        for item in spec["items"] as? [[String: Any]] ?? [] {
            if let v = widget(item, values: ui.values) { add(v, to: stack) }
        }
    }

    private func add(_ v: NSView, to stack: NSStackView) {
        stack.addArrangedSubview(v)
        if stack.orientation == .vertical, v.wantsFullWidth {
            v.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }
    }

    /// A widget's value: what's been set or changed, else what it began with.
    private func value(_ item: [String: Any], _ values: [String: String]) -> Any? {
        if let id = item["id"] as? String, let json = values[id] { return Self.parse(json) }
        return item["value"]
    }

    private func widget(_ item: [String: Any], values: [String: String]) -> NSView? {
        let type = item["type"] as? String ?? "label"
        let id = item["id"] as? String
        let label = item["label"] as? String
        let enabled = !(item["disabled"] as? Bool ?? false)
        var view: NSView
        switch type {
        case "label":
            let text = (value(item, values) as? String) ?? (item["text"] as? String) ?? label ?? ""
            let l = NSTextField(wrappingLabelWithString: text)
            l.isSelectable = true
            if item["style"] as? String == "heading" { l.font = .systemFont(ofSize: 14, weight: .semibold) }
            if item["style"] as? String == "secondary" { l.textColor = Theme.secondaryText }
            l.fullWidth = true
            if let id { controls[id] = Control(set: { l.stringValue = Self.string($0) }) }
            view = l
        case "markdown":
            let text = (value(item, values) as? String) ?? (item["text"] as? String) ?? ""
            let l = NSTextField(wrappingLabelWithString: "")
            l.isSelectable = true
            l.allowsEditingTextAttributes = true
            func render(_ s: String) {
                let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
                if let a = try? AttributedString(markdown: s, options: options) {
                    let ns = NSMutableAttributedString(a)
                    ns.addAttribute(.font, value: NSFont.systemFont(ofSize: NSFont.systemFontSize), range: NSRange(location: 0, length: ns.length))
                    ns.enumerateAttribute(.inlinePresentationIntent, in: NSRange(location: 0, length: ns.length)) { v, r, _ in
                        guard let raw = v as? Int else { return }
                        let intent = InlinePresentationIntent(rawValue: UInt(raw))
                        if intent.contains(.stronglyEmphasized) { ns.addAttribute(.font, value: NSFont.boldSystemFont(ofSize: NSFont.systemFontSize), range: r) }
                        if intent.contains(.code) { ns.addAttribute(.font, value: NSFont.monospacedSystemFont(ofSize: NSFont.systemFontSize - 1, weight: .regular), range: r) }
                    }
                    ns.addAttribute(.foregroundColor, value: NSColor.labelColor, range: NSRange(location: 0, length: ns.length))
                    l.attributedStringValue = ns
                } else {
                    l.stringValue = s
                }
            }
            render(text)
            l.fullWidth = true
            if let id { controls[id] = Control(set: { render(Self.string($0)) }) }
            view = l
        case "button":
            let b = ActionButton(title: label ?? id ?? "Button") { [weak self] in
                self?.tell(["event": "click", "id": id ?? ""], changed: [:], item: item)
            }
            b.bezelStyle = .rounded
            if item["style"] as? String == "primary" { b.keyEquivalent = "\r" }
            b.isEnabled = enabled
            view = b
        case "field", "text":
            let multiline = type == "text"
            let initial = Self.string(value(item, values) ?? "")
            if multiline {
                let s = NSTextView.scrollableTextView()
                let tv = s.documentView as! NSTextView
                tv.string = initial
                tv.font = .systemFont(ofSize: NSFont.systemFontSize)
                tv.isRichText = false
                tv.isEditable = enabled
                s.borderType = .bezelBorder
                s.heightAnchor.constraint(equalToConstant: CGFloat(item["height"] as? Double ?? 90)).isActive = true
                let watcher = EndEditing { [weak self, weak tv] in
                    guard let self, let tv, let id else { return }
                    self.changed(id, tv.string, item: item)
                }
                tv.delegate = watcher
                objc_setAssociatedObject(tv, &Self.watcherKey, watcher, .OBJC_ASSOCIATION_RETAIN)
                if let id { controls[id] = Control(set: { [weak tv] v in if tv?.window?.firstResponder !== tv { tv?.string = Self.string(v) } }) }
                s.fullWidth = true
                view = s
            } else {
                let f = NSTextField(string: initial)
                f.placeholderString = item["placeholder"] as? String
                f.isEnabled = enabled
                let watcher = EndEditing { [weak self, weak f] in
                    guard let self, let f, let id else { return }
                    self.changed(id, f.stringValue, item: item)
                }
                f.delegate = watcher
                objc_setAssociatedObject(f, &Self.watcherKey, watcher, .OBJC_ASSOCIATION_RETAIN)
                if let id { controls[id] = Control(set: { [weak f] v in if f?.currentEditor() == nil { f?.stringValue = Self.string(v) } }) }
                f.fullWidth = true
                view = f
            }
            view = labeled(label, view)
        case "checkbox":
            let c = ActionButton(checkboxTitle: label ?? id ?? "") { _ in }
            c.state = (value(item, values) as? Bool ?? false) ? .on : .off
            c.onClick = { [weak self, weak c] in
                guard let self, let c, let id else { return }
                self.changed(id, c.state == .on, item: item)
            }
            c.isEnabled = enabled
            if let id { controls[id] = Control(set: { [weak c] v in c?.state = (v as? Bool ?? false) ? .on : .off }) }
            view = c
        case "select":
            let options = (item["options"] as? [Any] ?? []).map(Self.string)
            let p = NSPopUpButton()
            p.addItems(withTitles: options)
            if let v = value(item, values).map(Self.string), options.contains(v) { p.selectItem(withTitle: v) }
            p.isEnabled = enabled
            let target = ClosureTarget { [weak self, weak p] in
                guard let self, let p, let id, let t = p.titleOfSelectedItem else { return }
                self.changed(id, t, item: item)
            }
            p.target = target
            p.action = #selector(ClosureTarget.fire)
            objc_setAssociatedObject(p, &Self.watcherKey, target, .OBJC_ASSOCIATION_RETAIN)
            if let id { controls[id] = Control(set: { [weak p] v in p?.selectItem(withTitle: Self.string(v)) }) }
            view = labeled(label, p)
        case "slider":
            let minimum = item["min"] as? Double ?? 0, maximum = item["max"] as? Double ?? 1
            let step = item["step"] as? Double
            let s = NSSlider(value: value(item, values) as? Double ?? minimum, minValue: minimum, maxValue: maximum, target: nil, action: nil)
            s.isContinuous = false
            s.isEnabled = enabled
            let shown = NSTextField(labelWithString: "")
            shown.textColor = Theme.secondaryText
            shown.font = .monospacedDigitSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .regular)
            func show(_ v: Double) { shown.stringValue = step.map { $0 >= 1 } == true ? String(Int(v.rounded())) : String(format: "%.2f", v) }
            show(s.doubleValue)
            let target = ClosureTarget { [weak self, weak s] in
                guard let self, let s, let id else { return }
                var v = s.doubleValue
                if let step, step > 0 { v = (v / step).rounded() * step; s.doubleValue = v }
                show(v)
                self.changed(id, v, item: item)
            }
            s.target = target
            s.action = #selector(ClosureTarget.fire)
            objc_setAssociatedObject(s, &Self.watcherKey, target, .OBJC_ASSOCIATION_RETAIN)
            if let id { controls[id] = Control(set: { [weak s] v in if let d = v as? Double { s?.doubleValue = d; show(d) } }) }
            let row = NSStackView(views: [s, shown])
            s.widthAnchor.constraint(greaterThanOrEqualToConstant: 160).isActive = true
            row.fullWidth = true
            view = labeled(label, row)
        case "progress":
            let p = NSProgressIndicator()
            p.style = .bar
            p.minValue = 0
            p.maxValue = 1
            func set(_ v: Any?) {
                if let d = v as? Double {
                    p.isIndeterminate = false
                    p.stopAnimation(nil)
                    p.doubleValue = d
                } else {
                    p.isIndeterminate = true
                    p.startAnimation(nil)
                }
            }
            set(value(item, values))
            if let id { controls[id] = Control(set: set) }
            p.fullWidth = true
            view = labeled(label, p)
        case "table", "list":
            let columns = type == "list" ? [""] : (item["columns"] as? [Any] ?? []).map(Self.string)
            let rows: [[String]] = type == "list"
                ? (item["items"] as? [Any] ?? []).map { [Self.string($0)] }
                : (item["rows"] as? [[Any]] ?? []).map { $0.map(Self.string) }
            let table = NSTableView()
            table.headerView = type == "list" ? nil : NSTableHeaderView()
            table.usesAlternatingRowBackgroundColors = true
            table.style = .inset
            for (i, title) in columns.enumerated() {
                let c = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("\(i)"))
                c.title = title
                table.addTableColumn(c)
            }
            let select = item["select"] as? String
            table.allowsMultipleSelection = select == "multiple"
            table.allowsEmptySelection = true
            let source = TableSource(rows: rows) { [weak self, weak table] in
                guard let self, let table, let id, select != nil else { return }
                let picked = table.selectedRowIndexes.map { $0 }
                self.changed(id, select == "multiple" ? picked : (picked.first as Any? ?? NSNull()), item: item)
            }
            tables.append(source)
            table.dataSource = source
            table.delegate = source
            if select == nil { table.selectionHighlightStyle = .none }
            func pick(_ v: Any?) {
                let rowsPicked = (v as? [Int]) ?? (v as? Int).map { [$0] } ?? []
                source.quiet = true
                table.selectRowIndexes(IndexSet(rowsPicked.filter { $0 < rows.count }), byExtendingSelection: false)
                source.quiet = false
            }
            let s = NSScrollView()
            s.documentView = table
            s.hasVerticalScroller = true
            s.borderType = .bezelBorder
            let height = min(CGFloat(rows.count) * 24 + (type == "list" ? 6 : 30), CGFloat(item["height"] as? Double ?? 280))
            s.heightAnchor.constraint(equalToConstant: max(height, 48)).isActive = true
            table.reloadData()
            pick(value(item, values))
            if let id { controls[id] = Control(set: pick) }
            s.fullWidth = true
            view = labeled(label, s)
        case "image":
            let iv = NSImageView()
            iv.imageScaling = .scaleProportionallyDown
            if let path = item["path"] as? String { iv.image = NSImage(contentsOfFile: path.expandingTildeInPath) }
            if let h = item["height"] as? Double { iv.heightAnchor.constraint(equalToConstant: CGFloat(h)).isActive = true }
            view = iv
        case "row":
            let row = NSStackView()
            row.orientation = .horizontal
            row.spacing = 10
            row.alignment = .centerY
            for child in item["items"] as? [[String: Any]] ?? [] {
                if let v = widget(child, values: values) { row.addArrangedSubview(v) }
            }
            view = row
        case "group":
            let inner = NSStackView()
            inner.orientation = .vertical
            inner.alignment = .leading
            inner.spacing = 10
            for child in item["items"] as? [[String: Any]] ?? [] {
                if let v = widget(child, values: values) { add(v, to: inner) }
            }
            let box = NSBox()
            box.title = label ?? ""
            box.titlePosition = label == nil ? .noTitle : .atTop
            box.contentView = inner
            box.contentViewMargins = NSSize(width: 10, height: 10)
            box.fullWidth = true
            view = box
        case "divider":
            let line = NSBox()
            line.boxType = .separator
            line.fullWidth = true
            view = line
        case "html":
            let config = WKWebViewConfiguration()
            let bridge = HTMLBridge { [weak self] name, v in
                self?.tell(["event": "emit", "id": id ?? "", "name": name, "value": v as Any], changed: [:], item: item)
            }
            config.userContentController.add(bridge, name: "mani")
            config.userContentController.addUserScript(WKUserScript(source: """
                window.mani = { emit: function (name, value) { window.webkit.messageHandlers.mani.postMessage({ name: String(name), value: value === undefined ? null : value }); } };
                """, injectionTime: .atDocumentStart, forMainFrameOnly: true))
            let web = WKWebView(frame: .zero, configuration: config)
            web.setValue(false, forKey: "drawsBackground")
            web.loadHTMLString((item["html"] as? String) ?? "", baseURL: nil)
            web.heightAnchor.constraint(equalToConstant: CGFloat(item["height"] as? Double ?? 220)).isActive = true
            web.fullWidth = true
            view = web
        default:
            let l = NSTextField(labelWithString: "(no widget \(type))")
            l.textColor = Theme.secondaryText
            view = l
        }
        if let tip = item["tip"] as? String { view.toolTip = tip }
        if let run = item["run"] as? String { view.toolTip = (view.toolTip.map { $0 + "\n" } ?? "") + "Runs: " + run }
        return view
    }

    /// A widget with its label above it.
    private func labeled(_ label: String?, _ v: NSView) -> NSView {
        guard let label, !label.isEmpty else { return v }
        let l = NSTextField(labelWithString: label)
        l.font = .systemFont(ofSize: NSFont.smallSystemFontSize, weight: .medium)
        l.textColor = Theme.secondaryText
        let s = NSStackView(views: [l, v])
        s.orientation = .vertical
        s.alignment = .leading
        s.spacing = 4
        if v.wantsFullWidth {
            v.widthAnchor.constraint(equalTo: s.widthAnchor).isActive = true
            s.fullWidth = true
        }
        return s
    }

    // MARK: Telling

    private func changed(_ id: String, _ value: Any, item: [String: Any]) {
        let json = Self.json(value)
        shownValues[id] = json
        tell(["event": "change", "id": id, "value": value], changed: [id: json], item: item)
    }

    private func tell(_ event: [String: Any], changed: [String: String], item: [String: Any]) {
        delegate?.panel(self, event: event, changed: changed, run: item["run"] as? String)
    }

    // MARK: Values

    static func parse(_ json: String) -> Any? {
        guard let data = json.data(using: .utf8) else { return nil }
        return try? JSONSerialization.jsonObject(with: data, options: .fragmentsAllowed)
    }

    static func json(_ value: Any) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: tidy(value), options: [.fragmentsAllowed, .withoutEscapingSlashes]) else { return "null" }
        return String(decoding: data, as: UTF8.self)
    }

    /// Fractions as they'd be written (0.3, not JSON's 0.29999999999999999),
    /// all the way down.
    static func tidy(_ value: Any) -> Any {
        switch value {
        case let n as NSNumber where CFGetTypeID(n) != CFBooleanGetTypeID() && CFNumberIsFloatType(n):
            let d = n.doubleValue
            return d.isFinite && d != d.rounded() ? NSDecimalNumber(string: "\(d)") : n
        case let a as [Any]: return a.map(tidy)
        case let o as [String: Any]: return o.mapValues(tidy)
        default: return value
        }
    }

    static func string(_ v: Any?) -> String {
        switch v {
        case let s as String: s
        case let n as NSNumber: n.stringValue
        case nil, is NSNull: ""
        default: json(v!)
        }
    }

    private static var watcherKey = 0

    private struct Control {
        var set: (Any?) -> Void
    }

    /// Ends of editing, for a field or text.
    private final class EndEditing: NSObject, NSTextFieldDelegate, NSTextViewDelegate {
        let done: () -> Void
        init(_ done: @escaping () -> Void) { self.done = done }
        func controlTextDidEndEditing(_ obj: Notification) { done() }
        func textDidEndEditing(_ notification: Notification) { done() }
    }

    private final class ClosureTarget: NSObject {
        let action: () -> Void
        init(_ action: @escaping () -> Void) { self.action = action }
        @objc func fire() { action() }
    }

    private final class HTMLBridge: NSObject, WKScriptMessageHandler {
        let emit: (String, Any?) -> Void
        init(_ emit: @escaping (String, Any?) -> Void) { self.emit = emit }
        func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
            guard let body = message.body as? [String: Any] else { return }
            emit(body["name"] as? String ?? "", body["value"] is NSNull ? nil : body["value"])
        }
    }

    private final class TableSource: NSObject, NSTableViewDataSource, NSTableViewDelegate {
        let rows: [[String]]
        let picked: () -> Void
        var quiet = false
        init(rows: [[String]], picked: @escaping () -> Void) {
            self.rows = rows
            self.picked = picked
        }
        func numberOfRows(in tableView: NSTableView) -> Int { rows.count }
        func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
            let i = Int(tableColumn?.identifier.rawValue ?? "0") ?? 0
            let cell = NSTextField(labelWithString: i < rows[row].count ? rows[row][i] : "")
            cell.lineBreakMode = .byTruncatingTail
            return cell
        }
        func tableViewSelectionDidChange(_ notification: Notification) {
            if !quiet { picked() }
        }
    }
}

/// A button whose click is a closure (a push button, or a checkbox).
private final class ActionButton: NSButton {
    var onClick: () -> Void = {}

    convenience init(title: String, _ action: @escaping () -> Void) {
        self.init(frame: .zero)
        self.title = title
        setButtonType(.momentaryPushIn)
        onClick = action
        target = self
        self.action = #selector(clicked)
    }

    convenience init(checkboxTitle title: String, _ unused: (Bool) -> Void) {
        self.init(frame: .zero)
        self.title = title
        setButtonType(.switch)
        target = self
        action = #selector(clicked)
    }

    @objc private func clicked() { onClick() }
}

private var fullWidthKey = 0

private extension NSView {
    /// Stretched across its column, as a field or a table is.
    var fullWidth: Bool {
        get { wantsFullWidth }
        set { objc_setAssociatedObject(self, &fullWidthKey, newValue, .OBJC_ASSOCIATION_RETAIN) }
    }

    var wantsFullWidth: Bool { (objc_getAssociatedObject(self, &fullWidthKey) as? Bool) ?? false }
}
