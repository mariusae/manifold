import AppKit
import ManifoldCore
import WebKit
import ManifoldSyntax
import UniformTypeIdentifiers
import PDFKit

extension MainWindowController: WebViewDelegate {
    func webView(_ view: WebView, append events: [Event]) {
        hosts.append(events, to: .block(view.block))
    }

    func webViewBarChanged(_ view: WebView) { content.barChanged(view.placement) }

    func webView(_ view: WebView, open url: URL, over: Bool) {
        open(url.absoluteString, from: view.placement, here: true, as: over ? .over : .beside)
    }

    /// An attached host as the address bar names it: its label, without
    /// case, spaces as hyphens.
    static func addressName(_ label: String) -> String {
        label.lowercased().replacingOccurrences(of: " ", with: "-")
    }

    /// The other hosts attached, by the name the address bar knows them by —
    /// connected or not yet (one being reached again: a port forwarded from
    /// it waits for it, rather than the name being looked up as a site's).
    var addressHosts: [(name: String, client: HostClient)] {
        hosts.all.filter { !$0.transport.isLocal }.map { (Self.addressName(hosts.label(of: $0.host)), $0) }
    }

    func webView(_ view: WebView, hostNamed name: String) -> HostID? { hostNamedInAddress(name) }

    func webView(_ view: WebView, forward port: Int, on host: HostID, done: @escaping (Int?) -> Void) {
        forward(port, on: host, done: done)
    }

    func webView(_ view: WebView, remoteHost host: HostID) -> (label: String, connected: Bool)? {
        guard let c = hosts.client(host), c.isRemote else { return nil }
        return (hosts.label(of: host), c.link == .connected)
    }

    func webView(_ view: WebView, storeThrough host: HostID, done: @escaping (WKWebsiteDataStore?) -> Void) {
        guard let c = hosts.client(host), c.isRemote else { return done(nil) }
        WebStores.store(through: c, done)
    }

    /// Not listed with the forwards asked for, nor toasted: the page's.
    func webView(_ view: WebView, forwardForPage port: Int, on host: HostID, done: @escaping (Int?) -> Void) {
        guard let c = hosts.client(host) else { return done(nil) }
        c.forwards.forward(port, hidden: true, done: done)
    }

    func webView(_ view: WebView, forwardedFrom port: Int) -> (host: HostID, port: Int)? {
        for c in hosts.all where c.isRemote {
            if let f = c.forwards.forwards.values.first(where: { $0.local == port }) { return (c.host, f.remote) }
        }
        return nil
    }

    func webView(_ view: WebView, refusalOf name: String, port: Int, through host: HostID) -> HostProxy.Refusal? {
        hosts.client(host)?.proxy.refusal(host: name, port: port)
    }

    func webView(_ view: WebView, open url: URL, asPageOf host: HostID) {
        openWeb(url, place: .besideOpener(view.placement), here: true, on: host, viaHost: true)
    }

    /// A page on this Mac's localhost at a port forwarded from a host: by
    /// that host and its port, as it's typed.
    func webView(_ view: WebView, addressOf url: URL) -> String {
        guard let h = url.host, WebAddress.isLoopback(h), let port = url.port else { return url.absoluteString }
        for (name, c) in addressHosts {
            if let f = c.forwards.forwards.values.first(where: { $0.local == port }) {
                var rest = url.path.isEmpty ? "/" : url.path
                if let q = url.query { rest += "?" + q }
                if let fr = url.fragment { rest += "#" + fr }
                return "\(name):\(f.remote)\(rest == "/" ? "" : rest)"
            }
        }
        return url.absoluteString
    }

    func webView(_ view: WebView, visited url: URL, title: String?, again: Bool) {
        let address = webView(view, addressOf: url)
        if again { WebHistory.shared.titled(address, title) } else { WebHistory.shared.visited(address, title: title) }
    }

    /// The address bar's completions, as Chrome's: first a page begun by
    /// what's typed (completed in the field) if there is one, then what's
    /// typed itself (the address, or a search), other pages it matches, the
    /// attached hosts (`slowbox:`, and their ports here before), and a
    /// search for it.
    func webView(_ view: WebView, suggestionsFor typed: String) -> [PillSuggestion] {
        let q = typed.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return [] }
        let plainQ = WebAddress.plain(q).lowercased()
        // The history, and pages open in tiles from before it was kept.
        var history = WebHistory.shared.matches(q, limit: 12)
        let known = Set(history.map { WebAddress.plain($0.address) })
        for b in hosts.blocks where b.kind == .web {
            guard let u = b.web?.url, let url = URL(string: u), !u.hasPrefix("file:") else { continue }
            let address = webView(view, addressOf: url), plain = WebAddress.plain(address)
            guard !known.contains(plain), !WebHistory.shared.forgotten.contains(plain), plain.lowercased().contains(plainQ) || (b.web?.title ?? "").lowercased().contains(plainQ) else { continue }
            history.append(WebHistory.Entry(address: address, title: b.web?.title ?? "", visits: 0, last: .distantPast))
        }
        func page(_ e: WebHistory.Entry, inline: Bool) -> PillSuggestion {
            let plain = WebAddress.plain(e.address)
            return PillSuggestion(fill: plain, title: plain, detail: e.title, symbol: "globe", inline: inline, commitText: e.address,
                                  remove: { WebHistory.shared.forget(e.address) })
        }
        var out: [PillSuggestion] = []
        var shown = Set<String>()
        let parsed = WebAddress.parse(q)
        if !q.contains(" "), !q.contains("://"), let i = history.firstIndex(where: { WebAddress.plain($0.address).lowercased().hasPrefix(plainQ) }) {
            let e = history.remove(at: i)
            out.append(page(e, inline: true))
            shown.insert(WebAddress.plain(e.address).lowercased())
        }
        // What's typed, as it would go — unless the page begun by it is it.
        let search = PillSuggestion(fill: q, title: q, detail: "Search DuckDuckGo", symbol: "magnifyingglass",
                                    run: { [weak view] in view?.search(q) })
        switch parsed {
        case _ where shown.contains(plainQ):
            break
        case .search:
            out.append(search)
        case let .page(address):
            out.append(PillSuggestion(fill: q, title: WebAddress.plain(address), symbol: "globe"))
        case let .hostPort(name, port, rest):
            let on = addressHosts.first { $0.name == name.lowercased() }
            out.append(PillSuggestion(fill: q, title: q, detail: on.map { "localhost:\(port)\(rest == "/" ? "" : rest) on \(hosts.label(of: $0.client.host))" } ?? "",
                                      symbol: on == nil ? "globe" : "network"))
        }
        shown.insert(WebAddress.plain(q).lowercased())
        for e in history where out.count < 6 {
            let plain = WebAddress.plain(e.address).lowercased()
            guard shown.insert(plain).inserted else { continue }
            out.append(page(e, inline: false))
        }
        // The hosts: a name begun (to type its port after), or its ports
        // forwarded before.
        for (name, c) in addressHosts {
            let label = hosts.label(of: c.host)
            if !q.contains(":"), name.hasPrefix(plainQ), shown.insert(name + ":").inserted {
                out.append(PillSuggestion(fill: name + ":", title: name + ":", detail: "a port on \(label)'s localhost", symbol: "network", fillsOnly: true))
            } else if plainQ.hasPrefix(name + ":") {
                var ports = Set(c.forwards.forwards.filter { !$0.value.hidden }.keys)
                for e in WebHistory.shared.entries.values where e.address.hasPrefix(name + ":") {
                    if let p = Int(e.address.dropFirst(name.count + 1).prefix { $0.isNumber }) { ports.insert(p) }
                }
                for p in ports.sorted() where "\(name):\(p)".hasPrefix(plainQ) && shown.insert("\(name):\(p)").inserted {
                    out.append(PillSuggestion(fill: "\(name):\(p)", title: "\(name):\(p)", detail: "localhost:\(p) on \(label)", symbol: "network"))
                }
            }
        }
        // A search for it, always on offer (last, if not first).
        if !out.contains(where: { $0.run != nil }) { out.append(search) }
        return Array(out.prefix(9))
    }
}

extension MainWindowController: SmartlogViewDelegate {
    func smartlogStart(_ view: SmartlogView) {
        guard let c = hosts.client(of: view.block), let b = hosts.block(view.block), let path = b.path else { return }
        c.propose(.smartlog(block: view.block, path: path))
    }

    /// This Mac's as the host gives it; another host's through its port,
    /// forwarded here (not listed with the forwards asked for).
    func smartlog(_ view: SmartlogView, localURL url: String, done: @escaping (URL?) -> Void) {
        guard var parts = URLComponents(string: url), let c = hosts.client(of: view.block) else { return done(nil) }
        if c.transport.isLocal { return done(parts.url) }
        guard let port = parts.port else { return done(nil) }
        c.forwards.forward(port, hidden: true) { local in
            guard let local else { return done(nil) }
            parts.host = "localhost"
            parts.port = local
            done(parts.url)
        }
    }

    func smartlog(_ view: SmartlogView, open url: URL) { NSWorkspace.shared.open(url) }

    func smartlog(_ view: SmartlogView, openFile path: String, line: Int?) {
        if let line, line > 0 {
            open(path: path, line: line, column: nil, on: view.block.host, from: view.placement, context: "\(path.lastPathComponent):\(line)")
        } else {
            open(path, from: view.placement)
        }
    }

    func smartlog(_ view: SmartlogView, revealFile path: String) {
        openDirectory((path as NSString).deletingLastPathComponent, from: view.placement, context: path.lastPathComponent)
    }
}
