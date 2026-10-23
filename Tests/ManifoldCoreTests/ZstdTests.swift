import Foundation
import Testing
@testable import ManifoldCore

@Test func terminalOutputGoesThroughZstdSmallerAndComesBackAsItWas() throws {
    // Like a terminal's history: lines, colors, the same again and again.
    var text = ""
    for i in 1...2_000 { text += "\u{1b}[32m\(i)\u{1b}[0m some output, line \(i % 7)\r\n" }
    let data = Data(text.utf8)
    let packed = Zstd.compress(data)
    #expect(packed.count * 5 < data.count)
    #expect(Zstd.decompress(packed) == data)
    #expect(Zstd.decompress(Zstd.compress(Data())) == Data())
}

@Test func whatIsntZstdOrIsTooBigIsntTakenForIt() {
    #expect(Zstd.decompress(Data("not zstd at all".utf8)) == nil)
    #expect(Zstd.decompress(Data()) == nil)
    let big = Zstd.compress(Data(count: 1 << 20))
    #expect(Zstd.decompress(big, limit: 1 << 10) == nil)
    // Cut short.
    let packed = Zstd.compress(Data("hello, hello, hello".utf8))
    #expect(Zstd.decompress(packed.prefix(packed.count - 2)) == nil)
}
