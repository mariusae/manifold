import Foundation
import Testing
@testable import ManifoldCore

// MARK: Rope

@Test func ropeCountsAndLines() {
    let r = Rope("hello\nwörld\n😀 end")
    #expect(r.count == "hello\nwörld\n😀 end".utf8.count)
    #expect(r.lineCount == 3)
    #expect(r.utf16Count == ("hello\nwörld\n😀 end" as NSString).length)
    #expect(r.lineText(0) == "hello")
    #expect(r.lineText(1) == "wörld")
    #expect(r.lineText(2) == "😀 end")
    #expect(r.line(at: 0) == 0)
    #expect(r.line(at: 6) == 1)
    #expect(r.line(at: r.count) == 2)
    #expect(r.offset(ofLine: 1) == 6)
    #expect(r.offset(ofLine: 2) == 13)
    #expect(r.offset(ofLine: 99) == r.count)
}

@Test func ropeEditsAcrossChunks() {
    var text = ""
    for i in 0..<3000 { text += "line \(i) with some text in it é\n" }
    var r = Rope(text)
    #expect(r.string == text)
    #expect(r.lineCount == 3001)
    r.replace(TextRange(0, 0), with: "START ")
    text = "START " + text
    #expect(r.string == text)
    let mid = text.utf8.count / 2
    let floorMid = r.floorBoundary(mid)
    r.replace(TextRange(floorMid, floorMid + 10), with: "X")
    var bytes = Array(text.utf8)
    bytes.replaceSubrange(floorMid..<floorMid + 10, with: Array("X".utf8))
    text = String(decoding: bytes, as: UTF8.self)
    #expect(r.string == text)
    r.replace(TextRange(0, r.count), with: "")
    #expect(r.isEmpty)
    #expect(r.lineCount == 1)
    r.replace(TextRange(0, 0), with: "a\nb")
    #expect(r.lineRange(1) == TextRange(2, 3))
}

@Test func ropeUTF16Offsets() {
    let r = Rope("a😀b\né")
    // a=1 unit, 😀=2 units (4 bytes), b=1, \n, é=1 (2 bytes).
    #expect(r.utf16Offset(ofByte: 0) == 0)
    #expect(r.utf16Offset(ofByte: 1) == 1)
    #expect(r.utf16Offset(ofByte: 5) == 3)
    #expect(r.utf16Offset(ofByte: r.count) == 6)
    #expect(r.byteOffset(ofUTF16: 3) == 5)
    #expect(r.byteOffset(ofUTF16: 1) == 1)
    #expect(r.byteOffset(ofUTF16: 6) == r.count)
    #expect(r.next(1) == 5)
    #expect(r.previous(5) == 1)
}

@Test func ropeFinds() {
    let r = Rope("one two One two")
    #expect(r.find("two", from: 0) == TextRange(4, 7))
    #expect(r.find("two", from: 5) == TextRange(12, 15))
    #expect(r.find("two", from: 15, backwards: true) == TextRange(12, 15))
    #expect(r.findAll("one", caseInsensitive: true).count == 2)
}

// MARK: Blocks and logs

private func stamp() -> Stamp { Stamp(wall: Int64(Date().timeIntervalSince1970 * 1000)) }

@Test func textBlockFollowsItsLog() {
    let node = Node()
    let id = BlockID()
    let shard = ShardID.block(id)
    #expect(node.append(.edit([.insert("x", at: 0)]), to: shard, at: stamp()) == nil, "a block begins with create")
    node.append(.create(kind: .text, title: nil, path: "/tmp/a.txt"), to: shard, at: stamp())
    node.append(.content("hello", encoding: "utf-8", lineEnding: "\n", fingerprint: "f1"), to: shard, at: stamp())
    var b = node.block(id)!
    #expect(b.text?.text.string == "hello")
    #expect(b.text?.isDirty == false)
    node.append(.edit([.insert(" world", at: 5)]), to: shard, at: stamp())
    b = node.block(id)!
    #expect(b.text?.text.string == "hello world")
    #expect(b.text?.isDirty == true)
    #expect(b.isHeld)
    node.append(.clean(version: b.text!.version, fingerprint: "f2"), to: shard, at: stamp())
    #expect(node.block(id)?.text?.isDirty == false)
    #expect(node.seq(shard) == 4)
    // A gap is refused; a repeat is harmless.
    #expect(!node.apply(Entry(seq: 9, at: stamp(), event: .title("x")), to: shard))
    #expect(node.apply(Entry(seq: 2, at: stamp(), event: .title("x")), to: shard))
    #expect(node.block(id)?.title == nil)
}

@Test func arrangementPlacesAndStacks() {
    var a = ArrangementState()
    let t1 = Placement(block: BlockID(), lens: .terminal)
    let t2 = Placement(block: BlockID(), lens: .terminal)
    let e = Placement(block: BlockID(), lens: .editor)
    a.apply(.place(t1, column: 0, at: 0))
    a.apply(.place(t2, column: 1, at: 0))
    #expect(a.columns.count == 2)
    #expect(a.fractions == [0.5, 0.5])
    #expect(a.focused == t2.id)
    // Beside t1: onto the column to its right.
    for ev in a.placing(e.block, lens: .editor, beside: t1.id, newPlacement: { e.id }) { a.apply(ev) }
    #expect(a.columns[1].map(\.id) == [t2.id, e.id])
    #expect(a.visible.map(\.id) == [t1.id, e.id])
    // Focusing t2 raises it in stacks.
    a.apply(.focus(t2.id))
    #expect(a.columns[1].last?.id == t2.id)
    // Placing the same block again on that column raises rather than repeats.
    let again = a.placing(e.block, lens: .editor, onColumn: 1, newPlacement: { "new" })
    #expect(again == [.focus(e.id)])
    a.apply(.remove(t2.id))
    #expect(a.columns[1].map(\.id) == [e.id])
    #expect(a.focused == e.id)
    a.apply(.remove(e.id))
    #expect(a.columns.count == 1)
    #expect(a.focused == t1.id)
    a.apply(.layout(.tiling))
    a.apply(.place(t2, column: 0, at: 0))
    #expect(a.visible.count == 2, "tiling shows everything")
    a.apply(.move(t2.id, column: 1, at: 0))
    #expect(a.columns.count == 2)
    a.apply(.fractions([0.3, 0.7]))
    a.apply(.moveColumn(from: 1, to: 0))
    #expect(a.columns[0].first?.id == t2.id)
    #expect(a.fractions == [0.7, 0.3])
}

@Test func separatingColumns() {
    var a = ArrangementState()
    let p = (0..<3).map { _ in Placement(block: BlockID(), lens: .terminal) }
    for (i, x) in p.enumerated() { a.apply(.place(x, column: i, at: 0)) }
    a.apply(.focus(p[1].id))
    let others = a.separated()
    #expect(others.map { $0[0].id } == [p[0].id, p[2].id])
}

@Test func deskAndRegistry() {
    let node = Node()
    let host = HostID.local
    let a = BlockID(), b = BlockID()
    node.append(.order([a, b]), to: .desk(host), at: stamp())
    node.append(.select(b), to: .desk(host), at: stamp())
    node.append(.settled(b), to: .desk(host), at: stamp())
    node.append(.settled(a), to: .desk(host), at: stamp())
    #expect(node.desk(host).selected == b)
    #expect(node.desk(host).settled == [a, b])
    let now = stamp()
    node.append(.register(RegistryEntry(id: a, kind: .arrangement, created: now, lastSeen: now)), to: .registry(host), at: now)
    node.append(.seen([a], at: Stamp(wall: now.wall + 5)), to: .registry(host), at: now)
    #expect(node.registry(host).blocks[a]?.lastSeen.wall == now.wall + 5)
    #expect(node.leader(of: .desk(host)) == .client)
    #expect(node.leader(of: .registry(host)) == .host)
}

@Test func storeRoundTripsAndSnapshots() throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("manifold-store-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: dir) }
    let store = LogStore(directory: dir)
    let node = Node()
    let id = BlockID()
    let shard = ShardID.block(id)
    var written: [Entry] = []
    written.append(node.append(.create(kind: .text, title: "t", path: nil), to: shard, at: stamp())!)
    written.append(node.append(.content("abc", encoding: "utf-8", lineEnding: "\n", fingerprint: nil), to: shard, at: stamp())!)
    store.append(written, to: shard)
    store.snapshot(node, shard)
    let more = node.append(.edit([.insert("d", at: 3)]), to: shard, at: stamp())!
    store.append([more], to: shard)
    store.closeAll()

    let again = Node()
    let fresh = LogStore(directory: dir)
    #expect(fresh.shards() == [shard])
    #expect(fresh.load(shard, into: again))
    #expect(again.block(id)?.text?.text.string == "abcd")
    #expect(again.seq(shard) == 3)
    #expect(fresh.entries(shard).count == 3)
}

@Test func codecEncodesIds() throws {
    let id = BlockID(host: HostID("devbox"), ulid: "01ABC")
    let data = try Codec.encode([id])
    #expect(try Codec.decode([BlockID].self, from: data) == [id])
    #expect(BlockID(string: "devbox/01ABC") == id)
    let u1 = ULID.make(), u2 = ULID.make(now: Date().addingTimeInterval(2))
    #expect(u1.count == 26 && u2.count == 26)
    #expect(u1 < u2)
}

@Test func clockNeverRunsBackwards() {
    let c = Clock(host: .local)
    let a = c.now(), b = c.now()
    #expect(a < b)
    c.observe(Stamp(wall: a.wall + 10_000, logical: 3, host: HostID("other")))
    let d = c.now()
    #expect(d.wall >= a.wall + 10_000)
}

@Test func migratesOldState() throws {
    let json = """
    {"tabs":[{"id":"11111111-1111-1111-1111-111111111111","customTitle":"work",
      "columns":[{"id":"22222222-2222-2222-2222-222222222222","panes":[
        {"id":"33333333-3333-3333-3333-333333333333","kind":"terminal","cwd":"/tmp"},
        {"id":"44444444-4444-4444-4444-444444444444","kind":"editor","path":"/tmp/x.txt"}]}],
      "focusedPane":"33333333-3333-3333-3333-333333333333","fractions":[1]}],
     "selectedTab":"11111111-1111-1111-1111-111111111111","window":{"sidebarPinned":true}}
    """
    let out = Migration.migrate(stateJSON: Data(json.utf8), editorsDirectory: nil, readFile: { _ in "disk" },
                                host: .local, clock: Clock(host: .local))
    let node = Node()
    for (shard, entries) in out { #expect(node.apply(entries, to: shard)) }
    let arrangements = node.blocks(of: .arrangement)
    #expect(arrangements.count == 1)
    #expect(arrangements[0].title == "work")
    #expect(arrangements[0].arrangement?.columns[0].count == 2)
    #expect(node.blocks(of: .terminal).first?.terminal?.cwd == "/tmp")
    #expect(node.blocks(of: .text).first?.text?.text.string == "disk")
    #expect(node.desk(.local).window.sidebarPinned)
    #expect(node.desk(.local).selected == arrangements[0].id)
    #expect(node.registry(.local).blocks.count == 3)
}
