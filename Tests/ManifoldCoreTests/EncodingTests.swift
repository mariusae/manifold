import Foundation
import Testing
@testable import ManifoldCore

/// The bytes the wire and the logs carry, written by hand here: they're
/// persisted, and spoken by servers of other builds, so they mustn't move.

@Test func integersGoInAndComeOutInTheirOrder() {
    var d = Data()
    d.appendBE(UInt32(0x0102_0304))
    d.appendLE(UInt32(0x0102_0304))
    d.appendBE(UInt16(0x0A0B))
    #expect([UInt8](d) == [1, 2, 3, 4, 4, 3, 2, 1, 0x0A, 0x0B])
    #expect(d.readBE(UInt32.self, at: 0) == 0x0102_0304)
    #expect(d.readLE(UInt32.self, at: 4) == 0x0102_0304)
    #expect(d.readBE(UInt16.self, at: 8) == 0x0A0B)
    #expect(d.readBE(UInt32.self, at: 7) == nil)
    // A slice reads from where it starts.
    #expect(d[4...].readLE(UInt32.self, at: 0) == 0x0102_0304)
}

@Test func aBackfillPieceIsItsRowsAfterItsRangeAndWidth() {
    let piece = BackfillPiece(from: 0x0102_0304_0506_0708, to: 9, width: 0x0A0B, rows: Data("ab".utf8))
    let bytes: [UInt8] = [1, 2, 3, 4, 5, 6, 7, 8, 0, 0, 0, 0, 0, 0, 0, 9, 0x0A, 0x0B, 0x61, 0x62]
    #expect([UInt8](piece.encoded) == bytes)
    #expect(BackfillPiece(Data(bytes)) == piece)
    #expect(BackfillPiece(Data(bytes.prefix(17))) == nil)
    // No rows (a seam's piece may have none): still a piece.
    #expect(BackfillPiece(Data(bytes.prefix(18)))?.rows.isEmpty == true)
}

@Test func framesAndMarksKeepTheirBytes() throws {
    let resize = Frame.resize(cols: 0x0102, rows: 0x0304)
    #expect([UInt8](resize.encoded) == [0, 0, 0, 4, FrameKind.resize.rawValue, 1, 2, 3, 4])
    #expect(resize.size?.cols == 0x0102 && resize.size?.rows == 0x0304)
    let mark = HistoryMark(epoch: 2, end: 0x0100, screen: true)
    #expect([UInt8](mark.frame.payload) == [0, 0, 0, 0, 0, 0, 0, 2, 0, 0, 0, 0, 0, 0, 1, 0, 1])
    #expect(HistoryMark(mark.frame) == mark)
    var decoder = FrameDecoder()
    decoder.append(resize.encoded + mark.frame.encoded)
    #expect(try decoder.next()?.size?.rows == 0x0304)
    #expect(try decoder.next().flatMap(HistoryMark.init) == mark)
    #expect(try decoder.next() == nil)
}

@Test func aLogIsItsEntriesEachAfterItsLength() throws {
    let host = HostID.local
    let entries = [
        Entry(seq: 1, at: Stamp(wall: 1, logical: 0, host: host), event: .create(kind: .text, title: "a", path: "/tmp/a")),
        Entry(seq: 2, at: Stamp(wall: 2, logical: 1, host: host), event: .cwd("/tmp")),
    ]
    var expected: [UInt8] = []
    for e in entries {
        let bytes = try Codec.encode(e)
        let n = bytes.count
        expected += [UInt8(n & 0xff), UInt8(n >> 8 & 0xff), UInt8(n >> 16 & 0xff), UInt8(n >> 24 & 0xff)] + [UInt8](bytes)
    }
    #expect([UInt8](LogStore.records(entries)) == expected)
    #expect(LogStore.records(Data(expected)) == entries)
    // Cut short (a write not finished): what's whole is read.
    #expect(LogStore.records(Data(expected.dropLast())) == [entries[0]])

    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("logs-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: dir) }
    let store = LogStore(directory: dir)
    let shard = ShardID.block(BlockID(host: host))
    store.append([entries[0]], to: shard)
    store.append([entries[1]], to: shard)
    store.closeAll()
    #expect([UInt8](try Data(contentsOf: dir.appendingPathComponent(shard.fileName + ".log"))) == expected)
    #expect(store.entries(shard) == entries)
}
