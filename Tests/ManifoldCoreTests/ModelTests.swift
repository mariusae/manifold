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

@Test func arrangementTilesAsAcmeDoes() {
    var a = ArrangementState()
    let t1 = Placement(block: BlockID(), lens: .terminal)
    let t2 = Placement(block: BlockID(), lens: .terminal)
    let e = Placement(block: BlockID(), lens: .editor)
    a.apply(.place(t1, column: 0, at: 0))
    a.apply(.place(t2, column: 1, at: 0))
    #expect(a.columns.count == 2)
    #expect(a.fractions == [0.5, 0.5])
    #expect(a.heights[t1.id] == 1 && a.heights[t2.id] == 1)
    #expect(a.focused == t2.id)
    // Brought into column 1: below its biggest tile, taking its lower half.
    for ev in a.bringing(e.block, lens: .editor, inColumn: 1, newPlacement: { e.id }) { a.apply(ev) }
    #expect(a.columns[1].map(\.id) == [t2.id, e.id])
    #expect(a.heights[t2.id] == 0.5 && a.heights[e.id] == 0.5)
    // Bringing a block with a tile here focuses it instead.
    #expect(a.bringing(t1.block, lens: .terminal, inColumn: 1, newPlacement: { "new" }) == [.focus(t1.id)])
    // Another below t2 in particular: t2 halves again; the biggest is now e.
    let n = Placement(block: BlockID(), lens: .preview)
    for ev in a.bringing(n.block, lens: .preview, inColumn: 1, below: t2.id, newPlacement: { n.id }) { a.apply(ev) }
    #expect(a.columns[1].map(\.id) == [t2.id, n.id, e.id])
    #expect(a.heights[t2.id] == 0.25 && a.heights[n.id] == 0.25 && a.heights[e.id] == 0.5)
    #expect(a.biggestTile(inColumn: 1)?.id == e.id)
    // Growing takes from the neighbors, nearest first; filling leaves slivers.
    for ev in a.growing(n.id, step: 0.1) { a.apply(ev) }
    #expect(abs(a.heights[n.id]! - 0.35) < 1e-9 && abs(a.heights[e.id]! - 0.4) < 1e-9)
    // Filling the column stashes the others (a share of 0); unstashing one
    // gives it the lower half of the biggest shown tile.
    for ev in a.growing(n.id, whole: true) { a.apply(ev) }
    #expect(a.heights[n.id] == 1 && a.isStashed(t2.id) && a.isStashed(e.id))
    #expect(a.stashedTiles(inColumn: 1).map(\.id) == [t2.id, e.id])
    for ev in a.unstashing(e.id) { a.apply(ev) }
    #expect(a.heights[n.id] == 0.5 && a.heights[e.id] == 0.5 && a.isStashed(t2.id))
    #expect(a.focused == e.id)
    for ev in a.stashing(e.id) { a.apply(ev) }
    #expect(a.heights[n.id] == 1 && a.isStashed(e.id))
    for ev in a.unstashing(e.id) { a.apply(ev) }
    // Maximized over the whole arrangement, until restored or gone.
    a.apply(.full(n.id))
    #expect(a.full == n.id && a.focused == n.id)
    a.apply(.full(nil))
    #expect(a.full == nil)
    a.apply(.full(n.id))
    // A tile removed gives its height to the one below, else above.
    a.apply(.remove(n.id))
    #expect(a.full == nil)
    #expect(a.columns[1].map(\.id) == [t2.id, e.id])
    #expect(abs(a.heights[t2.id]! + a.heights[e.id]! - 1) < 1e-9 && a.heights[e.id]! > 0.9)
    #expect(a.focused == e.id)
    // A new column beside; layouts from older logs are read and ignored.
    for ev in a.bringing(n.block, lens: .preview, inNewColumnAt: 1, newPlacement: { n.id }) { a.apply(ev) }
    #expect(a.columns.count == 3 && a.columns[1].first?.id == n.id)
    a.apply(.layout(.tiling))
    a.apply(.fractions([0.2, 0.3, 0.5]))
    a.apply(.moveColumn(from: 2, to: 0))
    #expect(a.columns[0].first?.id == t2.id)
    #expect(a.fractions == [0.5, 0.2, 0.3])
}

@Test func anOlderArrangementDecodesAsTiles() throws {
    // As saved before the grid: a stack with `shown`, a layout, no heights.
    let b1 = BlockID(), b2 = BlockID()
    let json = """
    {"title":"work","columns":[[{"id":"p1","block":"\(b1)","lens":"terminal"},{"id":"p2","block":"\(b2)","lens":"editor"}]],
     "fractions":[1],"focused":"p2","layout":"stacks","shown":["p2"]}
    """
    let a = try JSONDecoder().decode(ArrangementState.self, from: Data(json.utf8))
    #expect(a.visible.map(\.id) == ["p1", "p2"])
    #expect(a.heights["p1"] == 0.5 && a.heights["p2"] == 0.5)
    #expect(a.focused == "p2")
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
    #expect(node.leader(of: .desk(host)) == .host, "the desk is the host's metalog (§8.2)")
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

// MARK: Version control

@Test func saplingStatusAndLogParse() {
    let status = VCS.parseSaplingStatus("M src/a.swift\nA new.txt\nR gone.txt\n? scratch\n! lost.c\n")
    #expect(status.map(\.path) == ["src/a.swift", "new.txt", "gone.txt", "scratch", "lost.c"])
    #expect(status[0].workTree == "M" && status[0].index == " ")
    #expect(status[3].isUntracked)
    #expect(VCS.parseSaplingWhere("main\nabc1234\n") == "main")
    #expect(VCS.parseSaplingWhere("\nabc1234\n") == "abc1234")
    let log = VCS.sapling.parseLog("deadbeef\u{1f}deadbee\u{1f}Ada Lovelace <ada@example.com>\u{1f}1700000000 25200\u{1f}First line\n")
    #expect(log.count == 1)
    #expect(log[0].author == "Ada Lovelace")
    #expect(log[0].date == 1_700_000_000)
    #expect(log[0].summary == "First line")
    #expect(VCS.git.parseLog("abc\u{1f}a\u{1f}Me\u{1f}42\u{1f}Hi\n")[0].date == 42)
    // The committed version: HEAD for git, the working parent for Sapling.
    #expect(VCS.git.catArguments(path: "x", revision: "HEAD") == ["show", "HEAD:x"])
    #expect(VCS.sapling.catArguments(path: "x", revision: "HEAD") == ["cat", "x"])
    #expect(VCS.sapling.catArguments(path: "x", revision: "abc") == ["cat", "-r", "abc", "x"])
}

@Test func repositoryDetectionPrefersSapling() throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("mf-vcs-\(UUID().uuidString)").path
    defer { try? FileManager.default.removeItem(atPath: dir) }
    try FileManager.default.createDirectory(atPath: dir + "/repo/.git", withIntermediateDirectories: true)
    try FileManager.default.createDirectory(atPath: dir + "/repo/sub", withIntermediateDirectories: true)
    FileManager.default.createFile(atPath: dir + "/repo/sub/f.txt", contents: Data())
    #expect(VCS.repository(of: dir + "/repo/sub/f.txt")?.root == dir + "/repo")
    #expect(VCS.repository(of: dir + "/repo/sub/f.txt")?.vcs == .git)
    try FileManager.default.createDirectory(atPath: dir + "/repo/.sl", withIntermediateDirectories: true)
    #expect(VCS.repository(of: dir + "/repo/sub")?.vcs == .sapling)
    #expect(VCS.repository(of: dir) == nil)
}

// MARK: The graph

@Test func graphIndexesPlacementsLinksAndTheTrail() {
    let node = Node()
    let host = HostID("h")
    func stamp(_ ms: Int64) -> Stamp { Stamp(wall: ms, logical: 0, host: host) }
    let a = BlockID(host: host), f = BlockID(host: host), t = BlockID(host: host), g = BlockID(host: host)
    func put(_ event: Event, to shard: ShardID, at ms: Int64) { _ = node.append(event, to: shard, at: stamp(ms)) }
    put(.create(kind: .terminal, title: nil, path: nil), to: .block(t), at: 1)
    put(.create(kind: .text, title: nil, path: "/x/f.swift"), to: .block(f), at: 2)
    put(.create(kind: .text, title: nil, path: "/x/g.swift"), to: .block(g), at: 3)
    put(.create(kind: .arrangement, title: nil, path: nil), to: .block(a), at: 10)
    let pt = Placement(block: t, lens: .terminal), pf = Placement(block: f, lens: .editor)
    put(.place(pt, column: 0, at: 0), to: .block(a), at: 11)
    put(.step(Step(block: t, at: stamp(12), placement: pt.id)), to: .registry(host), at: 12)
    put(.place(pf, column: 1, at: 0), to: .block(a), at: 20)
    put(.step(Step(block: f, at: stamp(21), placement: pf.id)), to: .registry(host), at: 21)
    put(.link(Link(from: t, to: f, kind: .opened, at: stamp(20), context: "vim f.swift")), to: .links(host), at: 20)
    put(.step(Step(block: t, at: stamp(30), placement: pt.id)), to: .registry(host), at: 30)
    put(.step(Step(block: f, at: stamp(40), placement: pf.id)), to: .registry(host), at: 40)
    put(.remove(pf.id), to: .block(a), at: 50)
    let graph = node.graph

    // Placed: an interval, live until removed, held at moments in between.
    #expect(graph.count(to: t, kind: .placed) == 1)
    #expect(graph.count(to: f, kind: .placed) == 0)
    #expect(graph.arrangements(holding: f) == [])
    #expect(graph.arrangements(holding: f, at: stamp(25)) == [a])
    #expect(graph.arrangements(holding: f, at: stamp(15)) == [])
    #expect(graph.edges(from: a, kind: .placed).count == 1)
    #expect(graph.edges(from: a, kind: .placed, at: stamp(25)).count == 2)

    // Links: by kind, with context; a repeat replaces.
    #expect(graph.count(from: t, kind: .link(.opened)) == 1)
    #expect(graph.edges(to: f, kind: .link(.opened)).first?.context == "vim f.swift")
    put(.link(Link(from: t, to: f, kind: .opened, at: stamp(60), context: "again")), to: .links(host), at: 60)
    #expect(graph.count(from: t, kind: .link(.opened)) == 1)
    #expect(graph.edges(to: f, kind: .link(.opened)).first?.context == "again")

    // The trail: t, f, t, f. Before f came t, twice; after t came f, twice.
    #expect(graph.visits(f).count == 2)
    #expect(graph.trailNeighbors(of: f, offset: -1) == [TrailNeighbor(block: t, count: 2, last: stamp(30))])
    #expect(graph.trailNeighbors(of: t, offset: 1) == [TrailNeighbor(block: f, count: 2, last: stamp(40))])
    #expect(graph.step(from: f, offset: -1)?.block == t)
    #expect(graph.step(from: f, offset: 1) == nil)
    #expect(graph.recent().map(\.block) == [f, t])

    // The neighborhood, and distances for ranking.
    let n = graph.neighborhood(of: f)
    #expect(n.inbound[.link(.opened)]?.count == 1)
    #expect(n.inbound[.placed] == nil)
    #expect(n.before.first?.block == t)
    let d = graph.distances(from: g)
    #expect(d == [g: 0])
    let dt = graph.distances(from: t)
    #expect(dt[f] == 1 && dt[a] == 1)

    // A snapshot load rebuilds from state: live placements and links come
    // back, and the trail, from the registry.
    let fresh = Node()
    for shard in [ShardID.block(a), .block(t), .block(f), .links(host), .registry(host)] { fresh.load(node.snapshot(shard)!) }
    #expect(fresh.graph.count(to: t, kind: .placed) == 1)
    #expect(fresh.graph.count(from: t, kind: .link(.opened)) == 1)
    #expect(fresh.graph.visits(f).count == 2)
    #expect(fresh.graph.step(from: f, offset: -1)?.block == t)
    fresh.remove(.links(host))
    #expect(fresh.graph.count(from: t, kind: .link(.opened)) == 0)
}

@Test func placementsKeepTheirStampThroughASnapshot() {
    let node = Node()
    let host = HostID("h")
    func stamp(_ ms: Int64) -> Stamp { Stamp(wall: ms, logical: 0, host: host) }
    let a = BlockID(host: host), t = BlockID(host: host)
    _ = node.append(.create(kind: .terminal, title: nil, path: nil), to: .block(t), at: stamp(1))
    _ = node.append(.create(kind: .arrangement, title: nil, path: nil), to: .block(a), at: stamp(10))
    let p = Placement(block: t, lens: .terminal)
    _ = node.append(.place(p, column: 0, at: 0), to: .block(a), at: stamp(50))
    #expect(node.block(a)?.arrangement?.placement(p.id)?.placedAt == stamp(50))
    #expect(node.graph.edges(to: t, kind: .placed).first?.at == stamp(50))
    // Loaded from a snapshot (no entries), the edge keeps its stamp.
    let fresh = Node()
    fresh.load(node.snapshot(.block(a))!)
    #expect(fresh.graph.edges(to: t, kind: .placed).first?.at == stamp(50))
    // The trail's neighbors come most recent first.
    let f = BlockID(host: host), g = BlockID(host: host)
    for (ms, b) in [(100, f), (110, t), (120, g), (130, t), (140, f), (150, t)] {
        _ = node.append(.step(Step(block: b, at: stamp(Int64(ms)))), to: .registry(host), at: stamp(Int64(ms)))
    }
    let before = node.graph.trailNeighbors(of: t, offset: -1)
    #expect(before.map(\.block) == [f, g])
    #expect(before[0].count == 2)
}

@Test func placementsKeepLensState() {
    let node = Node()
    let id = BlockID(host: .local)
    func stamp(_ ms: Int64) -> Stamp { Stamp(wall: ms, logical: 0, host: .local) }
    _ = node.append(.create(kind: .text, title: nil, path: "/x/a.md"), to: .block(id), at: stamp(1))
    _ = node.append(.view(placement: "p1", ["scroll": "120", "selStart": "3", "selEnd": "9"]), to: .block(id), at: stamp(2))
    _ = node.append(.view(placement: "p2", ["scroll": "7"]), to: .block(id), at: stamp(3))
    // Keys merge; an empty value takes one away; placements are apart.
    _ = node.append(.view(placement: "p1", ["scroll": "150", "selStart": "", "selEnd": ""]), to: .block(id), at: stamp(4))
    #expect(node.block(id)?.views?["p1"] == ["scroll": "150"])
    #expect(node.block(id)?.views?["p2"] == ["scroll": "7"])
    // A snapshot carries it.
    let fresh = Node()
    fresh.load(node.snapshot(.block(id))!)
    #expect(fresh.block(id)?.views?["p1"]?["scroll"] == "150")
}

@Test func typingIntoAnEmptyRope() {
    var r = Rope("")
    #expect(r.count == 0 && r.lineCount == 1)
    r.apply(TextEdit(TextRange(0, 0), "h"))
    #expect(r.string == "h" && r.count == 1)
    r.apply(TextEdit(TextRange(1, 1), "i\n"))
    #expect(r.string == "hi\n" && r.lineCount == 2)
    // Emptied and typed into again.
    r.apply(TextEdit(TextRange(0, 3), ""))
    #expect(r.count == 0)
    r.apply(TextEdit(TextRange(0, 0), "again"))
    #expect(r.string == "again")
    // A note's first entry is an empty content: the same path.
    var state = TextState()
    state.apply(.content("", encoding: "utf-8", lineEnding: "\n", fingerprint: ""))
    state.apply(.edit([TextEdit(TextRange(0, 0), "note")]))
    #expect(state.text.string == "note")
}

// MARK: Organizations over the graph

@Test func containmentAndTheFileTree() {
    let node = Node()
    let host = HostID("h")
    func stamp(_ ms: Int64) -> Stamp { Stamp(wall: ms, logical: 0, host: host) }
    let repo = BlockID(host: host), ui = BlockID(host: host), a = BlockID(host: host), b = BlockID(host: host), note = BlockID(host: host), home = BlockID(host: host)
    _ = node.append(.create(kind: .git, title: nil, path: "/Users/me/src/app"), to: .block(repo), at: stamp(1))
    _ = node.append(.create(kind: .directory, title: nil, path: "/Users/me/src/app/Sources/UI"), to: .block(ui), at: stamp(2))
    _ = node.append(.create(kind: .text, title: nil, path: "/Users/me/src/app/Sources/UI/A.swift"), to: .block(a), at: stamp(3))
    _ = node.append(.create(kind: .text, title: nil, path: "/Users/me/src/app/README.md"), to: .block(b), at: stamp(4))
    _ = node.append(.create(kind: .text, title: nil, path: "/Users/me/notes/today.md"), to: .block(note), at: stamp(5))
    _ = node.append(.create(kind: .text, title: nil, path: "/etc/hosts"), to: .block(home), at: stamp(6))
    _ = node.append(.seen([a], at: stamp(50)), to: .registry(host), at: stamp(50))
    let g = node.graph
    // Containment comes from the paths: the listing holds the file, the repository the listing's folder's folder.
    #expect(g.edges(to: a, kind: .contains).map(\.from) == [ui])
    #expect(g.edges(from: ui, kind: .contains).map(\.to) == [a])
    #expect(g.edges(from: repo, kind: .contains).map(\.to) == [b])
    #expect(g.neighborhood(of: a).inbound[.contains]?.first?.from == ui)
    // The tree: roots are the repository, home, and /; single folders fold together.
    let tree = g.fileTree(host: host, home: "/Users/me")
    #expect(Set(tree.map(\.name)) == ["~", "app", "/"])
    let app = tree.first { $0.path == "/Users/me/src/app" }!
    #expect(app.block == repo && app.count == 4)
    #expect(app.children.map(\.name) == ["Sources/UI", "README.md"])
    let sources = app.children[0]
    #expect(sources.block == ui && sources.children.map(\.name) == ["A.swift"])
    #expect(sources.latest == stamp(50))
    let homeNode = tree.first { $0.path == "/Users/me" }!
    #expect(homeNode.children.map(\.name) == ["notes"] && homeNode.children[0].children.first?.block == note)
    // A path changed moves the block.
    _ = node.append(.path("/Users/me/src/app/B.swift"), to: .block(a), at: stamp(60))
    #expect(g.edges(from: ui, kind: .contains).isEmpty)
    #expect(g.edges(from: repo, kind: .contains).map(\.to).contains(a))
}

@Test func mentionsAreFoundInText() {
    let found = Mention.find(in: """
        See [[Design Doc]] and [the readme](../README.md#usage), [web](https://x.org/a.md),
        an image ![pic](assets/p.png "title") and [[Design Doc]] again, [[Other|alias]].
        """)
    #expect(found == [
        Mention(target: .title("Design Doc"), text: "Design Doc"),
        Mention(target: .path("../README.md"), text: "the readme"),
        Mention(target: .path("assets/p.png"), text: "pic"),
        Mention(target: .title("Other"), text: "Other|alias"),
    ])
    #expect(Mention.resolve("../README.md", from: "/a/b/c.md") == "/a/README.md")
    #expect(Mention.resolve("/x/y", from: nil) == "/x/y")
    #expect(Mention.resolve("y", from: nil) == nil)
    #expect(BlockKind.forFile("a.png") == .image && BlockKind.forFile("a.pdf") == .pdf && BlockKind.forFile("a.md") == .text)
}

@Test func programStatusIsScannedAndKept() {
    var scanner = StatusScanner()
    let msg = Data("Apply 3 to add".utf8).base64EncodedString()
    // A 7501 report with a message, in the middle of other output.
    var signals = scanner.feed(Data("hello\u{1b}]7501;state=blocked:kind=permission:app=terraform:msg=\(msg)\u{1b}\\world".utf8))
    #expect(signals == [.report(id: "", state: .blocked, kind: .permission, progress: nil, app: "terraform", title: nil, msg: "Apply 3 to add")])
    // A child record with progress, ended by BEL; a bad state is dropped whole.
    signals = scanner.feed(Data("\u{1b}]7501;id=deploy/us:state=working:progress=40\u{07}\u{1b}]7501;state=bogus\u{07}".utf8))
    #expect(signals == [.report(id: "deploy/us", state: .working, kind: nil, progress: 40, app: nil, title: nil, msg: nil)])
    // Once 7501 has spoken, OSC 9;4 is ignored; a prompt mark is seen.
    signals = scanner.feed(Data("\u{1b}]9;4;1;50\u{07}\u{1b}]133;A\u{07}\u{1b}]7501;state=clear\u{07}".utf8))
    #expect(signals == [.prompt, .clear(id: nil)])
    var fresh = StatusScanner()
    #expect(fresh.feed(Data("\u{1b}]9;4;1;50\u{07}".utf8)) == [.progress(.set, percent: 50)])

    // Records on a block: replaced whole, cleared with their children,
    // and working ones dropped when the shell ends.
    var b = Block(id: BlockID(), kind: .terminal, created: Stamp(wall: 1, host: HostID("h")))
    let at = Stamp(wall: 2, host: HostID("h"))
    b.apply(.status(id: "", StatusRecord(state: .working, progress: 10, at: at)), at: at)
    b.apply(.status(id: "build/test", StatusRecord(state: .blocked, kind: .question, at: at)), at: at)
    b.apply(.status(id: "build", StatusRecord(state: .done, at: at)), at: at)
    #expect(b.statusState == .working)
    #expect(b.status?.count == 3)
    b.apply(.status(id: "build", nil), at: at)
    #expect(b.status?.keys.sorted() == [""])
    b.apply(.shell(.ended(status: 0)), at: at)
    #expect(b.status == nil)
    b.apply(.status(id: "", StatusRecord(state: .done, msg: "Photos synced", at: at)), at: at)
    b.apply(.shell(.ended(status: 0)), at: at)
    #expect(b.statusRecord?.msg == "Photos synced", "done survives the process ending")
    // A busy terminal that says nothing is working, indeterminate.
    var t = Block(id: BlockID(), kind: .terminal, created: at)
    t.apply(.shell(.busy(true)), at: at)
    #expect(t.statusState == .working && t.statusRecord?.progress == nil)
}

@Test func aHostBecomesASessionAndItsLogsFollow() throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("mf-session-\(ULID.make())")
    let logs = dir.appendingPathComponent("logs")
    try FileManager.default.createDirectory(at: logs, withIntermediateDirectories: true)
    // A host named "local" with a block and a registry, as before sessions.
    let store = LogStore(directory: logs)
    let old = HostID.local
    let block = BlockID(host: old)
    let at = Stamp(wall: 1, host: old)
    store.append([Entry(seq: 1, at: at, event: .create(kind: .text, title: "note", path: nil))], to: .block(block))
    store.append([Entry(seq: 1, at: at, event: .register(RegistryEntry(id: block, kind: .text, created: at, lastSeen: at)))], to: .registry(old))
    store.closeAll()
    let first = HostSession.identify(directory: dir, logs: logs)
    #expect(first.id != old && first.id.raw.hasPrefix("h") && first.id.raw.count == 11)
    #expect(first.label == nil, "“local” is no one's label")
    // The same id next time; the logs under the new id, their contents rewritten.
    #expect(HostSession.identify(directory: dir, logs: logs).id == first.id)
    let node = Node()
    let reloaded = LogStore(directory: logs)
    let shards = reloaded.shards()
    #expect(shards.allSatisfy { $0.host == first.id })
    for s in shards { reloaded.load(s, into: node) }
    let moved = BlockID(host: first.id, ulid: block.ulid)
    #expect(node.block(moved)?.title == "note")
    #expect(node.registry(first.id).blocks[moved]?.id == moved)
    #expect(node.block(moved)?.created.host == first.id)
    try? FileManager.default.removeItem(at: dir)
}

@Test func remoteProvidersFillInTheirTemplates() {
    let p = RemoteProvider(name: "my", command: "my_special_script.sh --to %h %c")
    #expect(p.arguments(host: "box", command: "manifoldd bridge") == ["my_special_script.sh", "--to", "box", "manifoldd bridge"])
    let short = RemoteProvider(name: "s", command: "script.sh %h")
    #expect(short.arguments(host: "box", command: "run") == ["script.sh", "box", "run"], "no %c: the command is appended")
    #expect(RemoteProvider.ssh.arguments(host: "me@host", command: "x").first == "ssh")
}
