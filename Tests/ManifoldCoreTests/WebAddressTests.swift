import Testing
@testable import ManifoldCore

@Test func addressesTypedAreTakenAsABrowserTakesThem() {
    #expect(WebAddress.parse("localhost:3000") == .hostPort(name: "localhost", port: 3000, rest: "/"))
    #expect(WebAddress.parse("slowbox:3000/api/x?y=1") == .hostPort(name: "slowbox", port: 3000, rest: "/api/x?y=1"))
    #expect(WebAddress.parse("localhost") == .page("http://localhost"))
    #expect(WebAddress.parse("localhost/x") == .page("http://localhost/x"))
    #expect(WebAddress.parse("10.0.0.5") == .page("http://10.0.0.5"))
    #expect(WebAddress.parse("10.0.0.5:8080/x") == .hostPort(name: "10.0.0.5", port: 8080, rest: "/x"))
    #expect(WebAddress.parse("example.com/x") == .page("https://example.com/x"))
    #expect(WebAddress.parse("http://example.com") == .page("http://example.com"))
    #expect(WebAddress.parse("about:blank") == .page("about:blank"))
    #expect(WebAddress.parse("manifold") == .search("manifold"))
    #expect(WebAddress.parse("swift actors") == .search("swift actors"))
    #expect(WebAddress.parse("box:99999") == .search("box:99999"))
    #expect(WebAddress.plain("https://www.example.com/") == "example.com")
    #expect(WebAddress.plain("http://localhost:3000/a/") == "localhost:3000/a/")
}
