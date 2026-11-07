import Foundation
import Testing
@testable import ManifoldCore

@Suite struct PlaceTests {
    @Test func fragmentsReadAndSaid() {
        let all: [Locator] = [.anchor("k3x9q2"), .line(12), .lines(3, 7), .range(TextRange(10, 40)), .command(7), .page(3), .cell("01J")]
        for l in all { #expect(Locator(fragment: l.fragment) == l) }
        #expect(Locator(fragment: "line=12") == .line(12))
        #expect(Locator(fragment: "page=3") == .page(3))
        #expect(Locator(fragment: "command=7") == .command(7))
        #expect(Locator(fragment: "abc123") == .anchor("abc123"))
        #expect(Locator(fragment: "") == nil)
        #expect(Locator(fragment: "line=x") == nil)
        #expect(Locator(fragment: "lines=7-3") == nil)
        #expect(Locator(fragment: "column=3") == nil)
    }

    @Test func linesAndAnchors() {
        #expect(Locator.lines(4, 9).line == 4)
        #expect(Locator.page(2).line == nil)
        #expect(Locator.anchor("a").anchorID == "a")
        #expect(Locator.line(1).anchorID == nil)
    }

    @Test func subjects() {
        let host = HostID("h")
        let p = Place(file: "/src/a.swift", on: host, at: .line(3))
        #expect(p.file?.path == "/src/a.swift")
        #expect(p.block == nil)
        #expect(p.title == "a.swift")
        #expect(p.host == host)
        let data = try! JSONEncoder().encode(p)
        #expect(try! JSONDecoder().decode(Place.self, from: data) == p)
    }
}

@Suite struct PlaceWordsTests {
    @Test func said() {
        #expect(Locator.line(3).words == "line 3")
        #expect(Locator.lines(3, 3).words == "line 3")
        #expect(Locator.lines(3, 7).words == "lines 3–7")
        #expect(Locator.page(2).words == "page 2")
    }
}

@Suite struct ReferencePatternTests {
    @Test func legiblePlacesMatch() throws {
        let re = try NSRegularExpression(pattern: BlockID.referencePattern)
        let id = "manifold:h/01M6V9TDDDHJ8CRFR65JACEJ08"
        for f in ["line=12", "lines=3-7", "cell=jj23srzy", "range=10-40", "k7q2mx"] {
            let s = "see \(id)#\(f) here"
            let m = re.firstMatch(in: s, range: NSRange(s.startIndex..., in: s))
            #expect(m.map { (s as NSString).substring(with: $0.range) } == "\(id)#\(f)")
        }
    }
}
