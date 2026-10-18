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

// MARK: Language servers

@Test func ropeLSPPositions() {
    let r = Rope("ab\nwörld 😀x\nend")
    // Line and UTF-16 character, from 0, both ways.
    #expect(r.lspPosition(ofByte: 0) == (0, 0))
    #expect(r.lspPosition(ofByte: 3) == (1, 0))
    let x = "ab\nwörld 😀".utf8.count
    #expect(r.lspPosition(ofByte: x) == (1, 8))
    #expect(r.byteOffset(line: 1, character: 8) == x)
    #expect(r.byteOffset(line: 1, character: 2) == 3 + "wö".utf8.count)
    #expect(r.byteOffset(line: 2, character: 99) == r.count)
    #expect(r.byteOffset(line: 99, character: 0) == r.count)
}

@Test func languageByExtensionAndRoot() throws {
    let configs = LanguageServerConfig.defaults
    #expect(LanguageServerConfig.language(for: "/x/y/Foo.SWIFT", in: configs)?.id == "swift")
    #expect(LanguageServerConfig.language(for: "/x/y/foo.rs", in: configs)?.id == "rust")
    #expect(LanguageServerConfig.language(for: "/x/y/foo", in: configs) == nil)
    var off = configs
    off[0].enabled = false
    #expect(LanguageServerConfig.language(for: "/x/y/Foo.swift", in: off) == nil)

    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("mf-root-\(UUID().uuidString)").path
    try FileManager.default.createDirectory(atPath: dir + "/pkg/Sources/M", withIntermediateDirectories: true)
    FileManager.default.createFile(atPath: dir + "/pkg/Package.swift", contents: Data())
    FileManager.default.createFile(atPath: dir + "/pkg/Sources/M/a.swift", contents: Data())
    let swift = configs.first { $0.id == "swift" }!
    #expect(swift.root(of: dir + "/pkg/Sources/M/a.swift") == dir + "/pkg")
    // Nothing marks a root: the file's own directory.
    FileManager.default.createFile(atPath: dir + "/lone.swift", contents: Data())
    #expect(swift.root(of: dir + "/lone.swift") == dir)
    try? FileManager.default.removeItem(atPath: dir)
}

// MARK: Diffs

@Test func lineDiffHunks() {
    #expect(LineDiff.hunks(old: "a\nb\nc\n", new: "a\nb\nc\n").isEmpty)
    // One line changed in the middle.
    #expect(LineDiff.hunks(old: "a\nb\nc\n", new: "a\nB\nc\n") == [DiffHunk(oldStart: 1, oldCount: 1, newStart: 1, newCount: 1)])
    // Inserted at the end, deleted at the start.
    #expect(LineDiff.hunks(old: "a\nb\n", new: "a\nb\nc\nd\n") == [DiffHunk(oldStart: 2, oldCount: 0, newStart: 2, newCount: 2)])
    #expect(LineDiff.hunks(old: "a\nb\nc\n", new: "b\nc\n") == [DiffHunk(oldStart: 0, oldCount: 1, newStart: 0, newCount: 0)])
    // Two separate changes.
    let h = LineDiff.hunks(old: "a\nb\nc\nd\ne\nf\n", new: "a\nX\nc\nd\ne\nY\nf\n")
    #expect(h == [DiffHunk(oldStart: 1, oldCount: 1, newStart: 1, newCount: 1),
                  DiffHunk(oldStart: 5, oldCount: 0, newStart: 5, newCount: 1)])
    // Every hunk, applied, turns old into new.
    let old = (0..<60).map { "line \($0)" }
    var new = old
    new.remove(at: 3); new.insert("new 1", at: 10); new[20] = "changed"; new.append("tail")
    let hunks = LineDiff.hunks(old: old.map { $0[...] }, new: new.map { $0[...] })
    var rebuilt = old
    for hk in hunks.reversed() {
        rebuilt.replaceSubrange(hk.oldStart..<(hk.oldStart + hk.oldCount), with: new[hk.newStart..<(hk.newStart + hk.newCount)])
    }
    #expect(rebuilt == new)
    let marks = GutterMark.marks(hunks)
    #expect(marks.contains(GutterMark(line: 3, count: 0, kind: .deleted)))
    #expect(marks.contains(GutterMark(line: 10, count: 1, kind: .added)))
    #expect(marks.contains(GutterMark(line: 20, count: 1, kind: .modified)))
}

@Test func diffRowsFoldContextAndReadPatches() {
    let old = (1...20).map(String.init).joined(separator: "\n") + "\n"
    let new = (1...20).map { $0 == 10 ? "ten" : String($0) }.joined(separator: "\n") + "\n"
    let rows = DiffRows.sides(old: old, new: new)
    // Three lines of context each side of the change, the rest folded.
    #expect(rows.first?.kind == .fold(6))
    #expect(rows.filter { $0.kind == .context }.count == 6)
    #expect(rows.contains { $0.kind == .removed && $0.text == "10" && $0.oldLine == 10 })
    #expect(rows.contains { $0.kind == .added && $0.text == "ten" && $0.newLine == 10 })
    #expect(rows.last?.kind == .fold(7))
    #expect(DiffRows.sides(old: old, new: new, unfolded: true).filter { $0.kind == .context }.count == 19)

    let patch = """
    commit abc
    Author: Me

        Did a thing

    diff --git a/x.txt b/x.txt
    index 1..2 100644
    --- a/x.txt
    +++ b/x.txt
    @@ -1,3 +1,3 @@ heading
     a
    -b
    +B
     c
    """
    let p = DiffRows.patch(patch)
    #expect(p.contains { $0.kind == .file("x.txt") })
    #expect(p.contains { $0.kind == .hunk && $0.text == "heading" })
    #expect(p.contains { $0.kind == .removed && $0.oldLine == 2 && $0.text == "b" })
    #expect(p.contains { $0.kind == .added && $0.newLine == 2 && $0.text == "B" })
    #expect(p.contains { $0.kind == .context && $0.oldLine == 3 && $0.newLine == 3 && $0.text == "c" })
    #expect(p.first?.text == "commit abc")
}

// MARK: Scrubbing

@Test func replayingALogUpToAMoment() {
    let id = BlockID(host: .local)
    func stamp(_ ms: Int64) -> Stamp { Stamp(wall: ms, logical: 0, host: .local) }
    let entries = [
        Entry(seq: 1, at: stamp(100), event: .create(kind: .text, title: nil, path: "/x/a.txt")),
        Entry(seq: 2, at: stamp(200), event: .content("one\n", encoding: "utf-8", lineEnding: "\n", fingerprint: "f1")),
        Entry(seq: 3, at: stamp(300), event: .edit([TextEdit(TextRange(4, 4), "two\n")])),
        Entry(seq: 4, at: stamp(400), event: .edit([TextEdit(TextRange(0, 4), "")])),
    ]
    #expect(Block.replaying(entries, id: id)?.text?.text.string == "two\n")
    #expect(Block.replaying(entries, id: id, upTo: stamp(300))?.text?.text.string == "one\ntwo\n")
    #expect(Block.replaying(entries, id: id, upTo: stamp(250))?.text?.text.string == "one\n")
    #expect(Block.replaying(entries, id: id, upTo: stamp(50)) == nil)
    #expect(Block.replaying([], id: id) == nil)
}

// MARK: Retention

@Test func compactingALogKeepsABaseForHistory() throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("mf-store-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: dir) }
    let store = LogStore(directory: dir)
    let node = Node()
    let id = BlockID(host: .local)
    let shard = ShardID.block(id)
    func stamp(_ ms: Int64) -> Stamp { Stamp(wall: ms, logical: 0, host: .local) }
    var entries: [Entry] = []
    for (i, (ms, event)) in [(100, Event.create(kind: .text, title: nil, path: "/x/a.txt")),
                             (200, .content("one\n", encoding: "utf-8", lineEnding: "\n", fingerprint: "f")),
                             (300, .edit([TextEdit(TextRange(4, 4), "two\n")])),
                             (400, .edit([TextEdit(TextRange(8, 8), "three\n")]))].enumerated() {
        let e = Entry(seq: i + 1, at: stamp(Int64(ms)), event: event)
        _ = node.apply(e, to: shard)
        entries.append(e)
    }
    store.append(entries, to: shard)
    store.snapshot(node, shard)

    // Fold everything before 300 into the base.
    store.compact(shard, before: stamp(300), node: node)
    let h = store.history(shard)
    #expect(h.entries.map(\.seq) == [3, 4])
    #expect(h.base?.state.block?.text?.text.string == "one\n")
    #expect(Block.replaying(h.entries, id: id, base: h.base?.state.block)?.text?.text.string == "one\ntwo\nthree\n")
    #expect(Block.replaying(h.entries, id: id, upTo: stamp(300), base: h.base?.state.block)?.text?.text.string == "one\ntwo\n")

    // Loading afresh gives the same state, and appends carry on.
    let fresh = Node()
    #expect(store.load(shard, into: fresh))
    #expect(fresh.block(id)?.text?.text.string == "one\ntwo\nthree\n")
    #expect(fresh.seq(shard) == 4)
    let more = fresh.append(.edit([TextEdit(TextRange(0, 0), "zero\n")]), to: shard, at: stamp(500))!
    store.append([more], to: shard)
    #expect(store.history(shard).entries.map(\.seq) == [3, 4, 5])
    // Compacting again builds on the base.
    store.compact(shard, before: stamp(450), node: fresh)
    let again = store.history(shard)
    #expect(again.entries.map(\.seq) == [5])
    #expect(again.base?.state.block?.text?.text.string == "one\ntwo\nthree\n")
    store.closeAll()
}
