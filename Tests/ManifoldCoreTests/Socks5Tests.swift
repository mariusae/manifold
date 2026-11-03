import Foundation
import Testing
@testable import ManifoldCore

/// What was read, or how it stopped short.
private func said<T>(_ r: Socks5.Read<T>) -> String {
    switch r {
    case .more: "more"
    case .bad: "bad"
    case let .done(v, length): "\(v) \(length)"
    }
}

@Test func aClientsGreetingIsReadAsItComes() {
    #expect(said(Socks5.greeting(Data())) == "more")
    #expect(said(Socks5.greeting(Data([5]))) == "more")
    #expect(said(Socks5.greeting(Data([5, 2, 0]))) == "more")
    #expect(said(Socks5.greeting(Data([5, 2, 0, 2]))) == "[0, 2] 4")
    // What comes after it is the next message's.
    #expect(said(Socks5.greeting(Data([5, 1, 2, 1, 8]))) == "[2] 3")
    #expect(said(Socks5.greeting(Data([4, 1, 0]))) == "bad")
    #expect(said(Socks5.greeting(Data([5, 0]))) == "bad")
}

@Test func aClientsNameAndPasswordAreRead() {
    let whole = Data([1, 8] + Array("manifold".utf8) + [6] + Array("s3cret".utf8))
    #expect(said(Socks5.credentials(whole)) == "(user: \"manifold\", password: \"s3cret\") 17")
    for cut in 0..<whole.count { #expect(said(Socks5.credentials(whole.prefix(cut))) == "more") }
    #expect(said(Socks5.credentials(Data([5, 1, 0]))) == "bad")
}

@Test func whereAClientAsksToGoIsReadByAddressOrByName() {
    let v4 = Data([5, 1, 0, 1, 10, 0, 0, 5, 0x1F, 0x90])
    #expect(said(Socks5.request(v4)) == "\(Socks5.Request(command: 1, host: "10.0.0.5", port: 8080)) 10")
    let name = Data([5, 1, 0, 3, 9] + Array("wiki.corp".utf8) + [1, 0xBB])
    #expect(said(Socks5.request(name)) == "\(Socks5.Request(command: 1, host: "wiki.corp", port: 443)) 16")
    for cut in 0..<name.count { #expect(said(Socks5.request(name.prefix(cut))) == "more") }
    var v6 = Data([5, 1, 0, 4])
    v6.append(contentsOf: [UInt8](repeating: 0, count: 15) + [1])
    v6.append(contentsOf: [0, 80])
    #expect(said(Socks5.request(v6)) == "\(Socks5.Request(command: 1, host: "::1", port: 80)) 22")
    // BIND and UDP are read, to be refused.
    #expect(said(Socks5.request(Data([5, 2, 0, 1, 1, 2, 3, 4, 0, 1]))) == "\(Socks5.Request(command: 2, host: "1.2.3.4", port: 1)) 10")
    #expect(said(Socks5.request(Data([5, 1, 0, 9, 0, 0]))) == "bad")
    #expect(said(Socks5.request(Data([5, 1, 0, 3, 0, 0, 80]))) == "bad")
    #expect(said(Socks5.request(Data([5, 1, 1, 1, 1, 2, 3, 4, 0, 1]))) == "bad")
}

@Test func theServersAnswersAreAsTheRFCsHaveThem() {
    #expect(Socks5.chose(Socks5.usernamePassword) == Data([5, 2]))
    #expect(Socks5.chose(Socks5.noMethod) == Data([5, 0xFF]))
    #expect(Socks5.authenticated(true) == Data([1, 0]))
    #expect(Socks5.authenticated(false) == Data([1, 1]))
    #expect(Socks5.Reply.succeeded.bytes == Data([5, 0, 0, 1, 0, 0, 0, 0, 0, 0]))
    #expect(Socks5.Reply(.refused).bytes[1] == 5)
    #expect(Socks5.Reply(.notFound) == .hostUnreachable)
    #expect(Socks5.Reply(.timedOut) == .ttlExpired)
}
