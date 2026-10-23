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

@Test func aStreamsFramesGoThroughInTurnSmallerThanEachAlone() throws {
    let enc = try #require(Zstd.Encoder()), dec = try #require(Zstd.Decoder())
    var alone = 0, together = 0, sent = 0
    for i in 1...500 {
        // Small frames, much alike: a terminal's output, a line or so each.
        let frame = Data("\u{1b}[1;34mdrwxr-xr-x\u{1b}[0m  12 marius  staff   384 Oct 23 09:\(i % 60) dir\(i)\r\n".utf8)
        let packed = try #require(enc.compress(frame))
        #expect(dec.decompress(packed) == frame)
        sent += frame.count
        together += packed.count
        alone += Zstd.compress(frame).count
    }
    #expect(together * 3 < alone)
    #expect(together * 4 < sent)
    // An empty frame goes too.
    #expect(dec.decompress(try #require(enc.compress(Data()))) == Data())
    print("stream frames: \(sent) bytes → \(together) together, \(alone) alone; encoder \(enc.memory >> 10) KB, decoder \(dec.memory >> 10) KB")
}

@Test func aDecoderTakesOnlyItsEncodersFramesInTurn() throws {
    let enc = try #require(Zstd.Encoder()), dec = try #require(Zstd.Decoder())
    let a = try #require(enc.compress(Data(repeating: 65, count: 10_000)))
    let b = try #require(enc.compress(Data(repeating: 65, count: 10_000)))
    // Not zstd at all.
    #expect(try #require(Zstd.Decoder()).decompress(Data("garbage, not a frame".utf8)) == nil)
    // Bigger than allowed.
    #expect(try #require(Zstd.Decoder()).decompress(a, limit: 100) == nil)
    #expect(dec.decompress(a) == Data(repeating: 65, count: 10_000))
    #expect(dec.decompress(b) == Data(repeating: 65, count: 10_000))
}

@Test func anEncodersEndFinishesItsDecoderAndANewPairGoesOn() throws {
    var enc = try #require(Zstd.Encoder())
    var dec = try #require(Zstd.Decoder())
    let line = Data("some output, again and again\r\n".utf8)
    #expect(dec.decompress(try #require(enc.compress(line))) == line)
    #expect(!dec.finished)
    #expect(dec.decompress(try #require(enc.end())) == Data())
    #expect(dec.finished)
    // Idle no more: both made anew.
    enc = try #require(Zstd.Encoder())
    dec = try #require(Zstd.Decoder())
    #expect(dec.decompress(try #require(enc.compress(line))) == line)
}
