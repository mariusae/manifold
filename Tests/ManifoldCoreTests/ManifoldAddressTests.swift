import Foundation
import Testing
@testable import ManifoldCore

@Suite struct ManifoldAddressTests {
    let block = BlockID(host: HostID("hvqrk5mm2nj"), ulid: "01M7H26D73H3TTEXV8X914R50J")

    @Test func aBlocksAddressNamesIt() {
        let a = ManifoldAddress.of(block, fragment: "line=12")
        #expect(a == "manifold://hvqrk5mm2nj/01M7H26D73H3TTEXV8X914R50J#line=12")
        #expect(ManifoldAddress.parse(a) == .block(block, fragment: "line=12"))
        // As notes write them: the same.
        #expect(ManifoldAddress.parse("manifold:hvqrk5mm2nj/01M7H26D73H3TTEXV8X914R50J") == .block(block, fragment: nil))
        #expect(BlockID.reference(a)?.block == block)
    }

    @Test func anotherHostsFileIsNamedByItsPath() {
        let a = ManifoldAddress.of(file: "/home/me/a b#1?.swift", on: HostID("devbox"), fragment: "line=3")
        #expect(a == "manifold://devbox/home/me/a%20b%231%3F.swift#line=3")
        #expect(ManifoldAddress.parse(a) == .file(host: HostID("devbox"), path: "/home/me/a b#1?.swift", fragment: "line=3"))
        #expect(ManifoldAddress.of(file: "/srv/x", on: HostID("devbox"), isDirectory: true) == "manifold://devbox/srv/x/")
        // Not a block's.
        #expect(BlockID.reference(a) == nil)
    }

    @Test func notAnAddress() {
        #expect(ManifoldAddress.parse("https://example.com/x") == nil)
        #expect(ManifoldAddress.parse("manifold://host") == nil)
        #expect(ManifoldAddress.parse("manifold:") == nil)
    }

    @Test func theReferencePatternTakesBothForms() throws {
        let re = try NSRegularExpression(pattern: BlockID.referencePattern)
        for s in ["manifold:hvqrk5mm2nj/01M7H26D73H3TTEXV8X914R50J#line=4", "manifold://hvqrk5mm2nj/01M7H26D73H3TTEXV8X914R50J#line=4"] {
            let m = re.firstMatch(in: s, range: NSRange(s.startIndex..., in: s))
            #expect(m.map { (s as NSString).substring(with: $0.range) } == s)
        }
    }
}
