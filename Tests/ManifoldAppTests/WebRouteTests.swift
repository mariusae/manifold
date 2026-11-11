import Foundation
import Testing
import class WebKit.WKWebsiteDataStore
import ManifoldCore
@testable import Manifold

// I-5, M29 (STATE-MACHINES.md): a web block loaded through its host whose
// store can't be had isn't stuck: another address wanted asks again.

@MainActor
private final class Host: WebViewDelegate {
    var storesAsked = 0
    /// What each ask for the store gets, in turn (nil: the proxy couldn't start).
    var stores: [WKWebsiteDataStore?] = []

    func webView(_ view: WebView, append events: [Event]) {}
    func webView(_ view: WebView, open url: URL, over: Bool) {}
    func webView(_ view: WebView, openInBrowserAndClose address: String) {}
    func webViewBarChanged(_ view: WebView) {}
    func webView(_ view: WebView, suggestionsFor typed: String) -> [PillSuggestion] { [] }
    func webView(_ view: WebView, hostNamed name: String) -> HostID? { nil }
    func webView(_ view: WebView, forward port: Int, on host: HostID, done: @escaping (Int?) -> Void) { done(nil) }
    func webView(_ view: WebView, addressOf url: URL) -> String { url.absoluteString }
    func webView(_ view: WebView, visited url: URL, title: String?, again: Bool) {}
    func webView(_ view: WebView, remoteHost host: HostID) -> (label: String, connected: Bool)? { ("far", true) }
    func webView(_ view: WebView, storeThrough host: HostID, done: @escaping (WKWebsiteDataStore?) -> Void) {
        storesAsked += 1
        let store = stores.isEmpty ? nil : stores.removeFirst()
        DispatchQueue.main.async { done(store) }
    }
    func webView(_ view: WebView, forwardForPage port: Int, on host: HostID, done: @escaping (Int?) -> Void) { done(nil) }
    func webView(_ view: WebView, forwardedFrom port: Int) -> (host: HostID, port: Int)? { nil }
    func webView(_ view: WebView, refusalOf host: String, port: Int, through: HostID) -> HostProxy.Refusal? { nil }
    func webView(_ view: WebView, open url: URL, asPageOf host: HostID) {}
}

@MainActor
@Test func aPageWhoseHostsStoreCantBeHadAsksAgainForAnotherAddress() async throws {
    let far = HostID("far")
    var block = Block(id: BlockID(host: far), kind: .web, created: Stamp(wall: 0, host: far))
    block.apply(.url("https://example.invalid/one", viaHost: true), at: Stamp(wall: 1, host: far))
    let host = Host()
    host.stores = [nil, .nonPersistent()]
    let view = WebView(placement: PlacementID(), block: block.id)
    view.delegate = host
    view.source = { block }
    view.documentChanged()
    try await Task.sleep(for: .milliseconds(200))
    #expect(host.storesAsked == 1)
    #expect(view.store == .unavailable("Can't load pages through far: its proxy here couldn't start", for: "https://example.invalid/one"))

    // The same address again (any other change to the block): not asked
    // again and again.
    view.documentChanged()
    try await Task.sleep(for: .milliseconds(200))
    #expect(host.storesAsked == 1)

    // Another address typed: asked again, and this time it's there.
    block.apply(.url("https://example.invalid/two", viaHost: true), at: Stamp(wall: 2, host: far))
    view.documentChanged()
    try await Task.sleep(for: .milliseconds(200))
    #expect(host.storesAsked == 2)
    #expect(view.store == .ready)
}
