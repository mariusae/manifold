import CryptoKit
import Foundation
import ManifoldCore
import Network
import WebKit

/// Where pages loaded through a host (§7.6) keep their cookies, caches
/// and logins, and how they get there: a website data store of the
/// host's own — the same one from launch to launch, by the host's id —
/// whose every connection goes through the host's proxy (`HostProxy`).
/// Pages loaded from here keep WebKit's default store, so a site's
/// sign-in through a host and from here are each its own.
enum WebStores {
    private static var stores: [HostID: WKWebsiteDataStore] = [:]
    /// The proxy each store was last pointed at: its port and password
    /// (another, should the host be attached again).
    private static var through: [HostID: String] = [:]

    /// The host's store, once its proxy listens (nil: it can't). Nothing
    /// is loaded in it before then, so nothing goes around the host.
    static func store(through client: HostClient, _ done: @escaping (WKWebsiteDataStore?) -> Void) {
        let proxy = client.proxy, host = client.host
        proxy.whenListening { port in
            guard let port, let p = NWEndpoint.Port(rawValue: UInt16(port)) else { return done(nil) }
            let store = made(host)
            // Set again only when it changed (the proxy listening anew).
            let key = "\(port) \(proxy.password)"
            if through[host] != key {
                var config = ProxyConfiguration(socksv5Proxy: .hostPort(host: "127.0.0.1", port: p))
                config.applyCredential(username: proxy.user, password: proxy.password)
                store.proxyConfigurations = [config]
                through[host] = key
            }
            done(store)
        }
    }

    /// Everything pages loaded through a host keep — cookies and sign-ins,
    /// what sites store, caches — forgotten; with no host, what pages
    /// loaded from here keep (WebKit's default store).
    static func clear(through host: HostID?, _ done: @escaping () -> Void) {
        let store = host.map(made) ?? .default()
        store.removeData(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(), modifiedSince: .distantPast, completionHandler: done)
    }

    /// The sites a store keeps anything of, for debugging.
    static func sites(through host: HostID?, _ done: @escaping ([String]) -> Void) {
        let store = host.map(made) ?? .default()
        store.fetchDataRecords(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes()) { done($0.map(\.displayName).sorted()) }
    }

    /// A host's store, made if it isn't yet, and kept: each is made once,
    /// its proxy set when a page first asks for it. (Whether one was ever
    /// made isn't asked of WebKit: its list of them, asked before any web
    /// view has been made, crashes.)
    private static func made(_ host: HostID) -> WKWebsiteDataStore {
        if let store = stores[host] { return store }
        let store = WKWebsiteDataStore(forIdentifier: identifier(of: host))
        stores[host] = store
        return store
    }

    /// A store's id, from its host's: a UUID made of the id's hash.
    static func identifier(of host: HostID) -> UUID {
        var b = Array(SHA256.hash(data: Data("manifold.web.\(host.raw)".utf8)).prefix(16))
        b[6] = (b[6] & 0x0F) | 0x50
        b[8] = (b[8] & 0x3F) | 0x80
        return UUID(uuid: (b[0], b[1], b[2], b[3], b[4], b[5], b[6], b[7], b[8], b[9], b[10], b[11], b[12], b[13], b[14], b[15]))
    }
}
