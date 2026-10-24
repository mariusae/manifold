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
    #expect(b.text?.isDirty == true)
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
    #expect(node.desk(host).selected == b)
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
    // A terminal working in a folder is at it: under the folder, as a place
    // (named by the app), and it moves with its working directory.
    let term = BlockID(host: host)
    _ = node.append(.create(kind: .terminal, title: nil, path: nil), to: .block(term), at: stamp(70))
    _ = node.append(.cwd("/Users/me/src/app/Sources/UI"), to: .block(term), at: stamp(71))
    var ui2 = g.fileTree(host: host, home: "/Users/me").first { $0.path == "/Users/me/src/app" }!.children.first { $0.path == "/Users/me/src/app/Sources/UI" }!
    #expect(ui2.children.contains { $0.isPlace && $0.block == term && $0.name.isEmpty })
    _ = node.append(.cwd("/Users/me"), to: .block(term), at: stamp(72))
    ui2 = g.fileTree(host: host, home: "/Users/me").first { $0.path == "/Users/me/src/app" }!.children.first { $0.path == "/Users/me/src/app/Sources/UI" }!
    #expect(!ui2.children.contains { $0.block == term })
    #expect(g.fileTree(host: host, home: "/Users/me").first { $0.path == "/Users/me" }!.children.contains { $0.isPlace && $0.block == term })
}

@Test func mentionsAreFoundInText() {
    let found = Mention.find(in: """
        See [[Design Doc]] and [the readme](../README.md#usage), [web](https://x.org/a.md),
        an image ![pic](assets/p.png "title") and [[Design Doc]] again, [[Other|alias]].
        """)
    #expect(found == [
        Mention(target: .title("Design Doc"), text: "Design Doc"),
        Mention(target: .path("../README.md"), text: "the readme"),
        Mention(target: .path("assets/p.png"), text: "pic", embeds: true),
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
    // A command the shell is about to run (OSC 7502), and its end (133 D).
    signals = scanner.feed(Data("\u{1b}]7502;  make -j8 \u{07}output\u{1b}]133;D;2\u{07}\u{1b}]133;D\u{1b}\\".utf8))
    #expect(signals == [.command("make -j8"), .commandEnded(status: 2), .commandEnded(status: nil)])
    #expect(scanner.feed(Data("\u{1b}]7502;\u{07}".utf8)).isEmpty)
    // Where the shell is (OSC 7): a file URL percent-decoded, kitty's raw.
    signals = scanner.feed(Data("\u{1b}]7;file://airy.local/Users/m/My%20Stuff\u{07}\u{1b}]7;kitty-shell-cwd://box/tmp/a b\u{1b}\\\u{1b}]7;ftp://x/y\u{07}".utf8))
    #expect(signals == [.directory(host: "airy.local", path: "/Users/m/My Stuff"), .directory(host: "box", path: "/tmp/a b")])

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
    // A busy terminal that says nothing has no status: only the program says.
    var t = Block(id: BlockID(), kind: .terminal, created: at)
    t.apply(.shell(.busy(true)), at: at)
    #expect(t.statusState == .idle && t.statusRecord == nil)
}

@Test func aProgramAskingAfter7501IsHeard() {
    var scanner = StatusScanner()
    let signals = scanner.feed(Data("\u{1B}]7501;?\u{1B}\\".utf8))
    #expect(signals == [.query])
    #expect(!scanner.sawReports, "a query is no report: 9;4 still counts")
    #expect(StatusSignal.queryReply.hasPrefix("\u{1B}]7501;?:states=idle,working,done,blocked,error"))
    // A report after it: heard, and 9;4 ignored from then on.
    _ = scanner.feed(Data("\u{1B}]7501;state=working:app=claude-code\u{1B}\\".utf8))
    #expect(scanner.sawReports)
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

@Test func aRewriteCutShortResumesAndKeepsTheSnapshotsPlace() throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("mf-session-\(ULID.make())")
    let logs = dir.appendingPathComponent("logs")
    try FileManager.default.createDirectory(at: logs, withIntermediateDirectories: true)
    let store = LogStore(directory: logs)
    let old = HostID.local
    let block = BlockID(host: old)
    let at = Stamp(wall: 1, host: old)
    let node = Node()
    let shard = ShardID.block(block)
    let create = Entry(seq: 1, at: at, event: .create(kind: .text, title: "note", path: nil))
    store.append([create], to: shard)
    node.apply(create, to: shard)
    // A snapshot part way, then more log after it.
    store.snapshot(node, shard)
    let rename = Entry(seq: 2, at: Stamp(wall: 2, host: old), event: .title("renamed"))
    store.append([rename], to: shard)
    store.closeAll()
    // A session already minted, as after a rewrite that was cut short.
    let minted = HostSession.mint()
    try Data(minted.raw.utf8).write(to: dir.appendingPathComponent("session"))
    let got = HostSession.identify(directory: dir, logs: logs)
    #expect(got.id == minted)
    let reloaded = LogStore(directory: logs)
    #expect(reloaded.shards() == [.block(BlockID(host: minted, ulid: block.ulid))])
    let replica = Node()
    for s in reloaded.shards() { reloaded.load(s, into: replica) }
    let moved = BlockID(host: minted, ulid: block.ulid)
    #expect(replica.block(moved)?.title == "renamed", "the entry after the snapshot is replayed from where the snapshot's offset landed")
    #expect(replica.seq(.block(moved)) == 2)
    try? FileManager.default.removeItem(at: dir)
}

@Test func blocksFromBeforeULIDsFollowTooAndAFileAlreadyRenamedIsFinished() throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("mf-session-\(ULID.make())")
    let logs = dir.appendingPathComponent("logs")
    try FileManager.default.createDirectory(at: logs, withIntermediateDirectories: true)
    let store = LogStore(directory: logs)
    let old = HostID.local
    let uuid = BlockID(host: old, ulid: "125CB03F-19D2-4890-A260-6227E7E1AE54")
    let at = Stamp(wall: 1, host: old)
    store.append([Entry(seq: 1, at: at, event: .create(kind: .terminal, title: "sh", path: nil))], to: .block(uuid))
    store.append([Entry(seq: 1, at: at, event: .register(RegistryEntry(id: uuid, kind: .terminal, created: at, lastSeen: at)))], to: .registry(old))
    store.closeAll()
    // A rewrite that renamed the block's file but left the old names in it
    // (as one from before UUIDs were known did), the session minted.
    let minted = HostSession.mint()
    try Data(minted.raw.utf8).write(to: dir.appendingPathComponent("session"))
    let moved = BlockID(host: minted, ulid: uuid.ulid)
    try FileManager.default.moveItem(at: logs.appendingPathComponent(ShardID.block(uuid).fileName + ".log"),
                                     to: logs.appendingPathComponent(ShardID.block(moved).fileName + ".log"))
    // And a stray log under the old name, made since: set aside, not written over.
    store.append([Entry(seq: 1, at: at, event: .create(kind: .terminal, title: "stray", path: nil))], to: .block(uuid))
    store.closeAll()
    #expect(HostSession.identify(directory: dir, logs: logs).id == minted)
    let node = Node()
    let reloaded = LogStore(directory: logs)
    #expect(Set(reloaded.shards()) == [.block(moved), .registry(minted)])
    for s in reloaded.shards() { reloaded.load(s, into: node) }
    #expect(node.block(moved)?.title == "sh")
    #expect(node.block(moved)?.created.host == minted)
    #expect(node.registry(minted).blocks[moved]?.id == moved)
    let names = try FileManager.default.contentsOfDirectory(atPath: logs.path)
    #expect(names.contains(ShardID.block(uuid).fileName + ".log.superseded"))
    try? FileManager.default.removeItem(at: dir)
}

@Test func aCommandsOutputLeavesTheNextPromptOff() {
    let line = "fbsource[f]/monarch› def run_worker_loop_forever"
    let prompt = ShellCommand.prompt(onLine: line, command: "def run_worker_loop_forever")
    #expect(prompt == "fbsource[f]/monarch›")
    // The next prompt, nothing typed at it, a right prompt's host before it.
    let shown = "./python/monarch/_src/actor/bootstrap.py:177:1:def run_worker_loop_forever(\ndevvm34959 fbsource[f]/monarch›\n"
    #expect(ShellCommand.output(shown, prompt: prompt) == "./python/monarch/_src/actor/bootstrap.py:177:1:def run_worker_loop_forever(")
    // A prompt whose path changed: it still ends in the same mark.
    #expect(ShellCommand.output("ok\n~/elsewhere ›", prompt: "~/src ›") == "ok")
    // Output ending in a word (not a mark) stays; so does output in the middle.
    #expect(ShellCommand.output("a ›\nb\n~ $", prompt: "~ $") == "a ›\nb")
    #expect(ShellCommand.output("done", prompt: nil) == "done")
}

@Test func aTileMovedUnderAStackDoesntTakeIt() {
    var a = ArrangementState()
    let top = Placement(block: BlockID(), lens: .terminal), x = Placement(block: BlockID(), lens: .terminal)
    let y = Placement(block: BlockID(), lens: .terminal), below = Placement(block: BlockID(), lens: .terminal)
    for (i, p) in [top, x, y, below].enumerated() { a.apply(.place(p, column: 0, at: i)) }
    a.apply(.stash(x.id, behind: top.id))
    a.apply(.stash(y.id, behind: top.id))
    #expect(a.columns[0].map(\.id) == [top.id, y.id, x.id, below.id])
    // x, from the stack, dropped just under its top (between top and y):
    // past the stack, which stays behind top.
    for e in a.moving(x.id, column: 0, at: 1, alone: true) { a.apply(e) }
    #expect(a.columns[0].map(\.id) == [top.id, y.id, x.id, below.id])
    #expect(!a.isStashed(x.id) && a.isStashed(y.id))
    #expect(a.tile(behind: y.id)?.id == top.id)
    // The top dragged out alone, dropped under its own spot: y shows in its
    // place, and the top lands under it, not in front of it.
    for e in a.moving(top.id, column: 0, at: 1, alone: true) { a.apply(e) }
    #expect(a.columns[0].first?.id == y.id && !a.isStashed(y.id) && !a.isStashed(top.id))
}

@Test func aTileStashedBehindAnotherComesBackUnderIt() {
    var a = ArrangementState()
    let x = Placement(block: BlockID(), lens: .terminal), y = Placement(block: BlockID(), lens: .terminal), z = Placement(block: BlockID(), lens: .terminal)
    a.apply(.place(x, column: 0, at: 0))
    a.apply(.place(y, column: 0, at: 1))
    a.apply(.place(z, column: 1, at: 0))
    // z, from the other column, dropped on x's pill: behind x, in x's column, taking no room; its column gone.
    a.apply(.stash(z.id, behind: x.id))
    #expect(a.columns.count == 1)
    #expect(a.columns[0].map(\.id) == [x.id, z.id, y.id])
    #expect(a.isStashed(z.id))
    #expect(a.tile(behind: z.id)?.id == x.id)
    #expect(abs(a.height(of: x.id) + a.height(of: y.id) - 1) < 0.001)
    // Back: the lower half of x, the tile it was behind.
    for e in a.unstashing(z.id) { a.apply(e) }
    #expect(!a.isStashed(z.id))
    #expect(abs(a.height(of: z.id) - a.height(of: x.id)) < 0.001)
    #expect(a.focused == z.id)
    // A stashed tile before every shown one is behind the first shown.
    var b = ArrangementState()
    b.apply(.place(x, column: 0, at: 0))
    b.apply(.place(y, column: 0, at: 1))
    b.apply(.heights([x.id: 0, y.id: 1]))
    #expect(b.tile(behind: x.id)?.id == y.id)
}

@Test func aWorkspaceRestoredIsAsItWas() {
    var a = ArrangementState()
    let x = Placement(block: BlockID(), lens: .terminal), y = Placement(block: BlockID(), lens: .editor)
    a.apply(.place(x, column: 0, at: 0))
    a.apply(.place(y, column: 0, at: 1))
    let before = a
    a.apply(.stash(y.id, behind: x.id))
    a.apply(.full(x.id))
    #expect(a.isStashed(y.id) && a.full == x.id)
    // Undo: the state before, in one entry; the log went on.
    a.apply(.restore(before))
    #expect(!a.isStashed(y.id))
    #expect(a.full == nil)
    #expect(a.columns[0].map(\.id) == [x.id, y.id])
    #expect(abs(a.height(of: x.id) + a.height(of: y.id) - 1) < 0.001)
}

@Test func aFoldedLogIsEmptyAndLoadsAsItWas() throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("mf-fold-\(ULID.make())")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let store = LogStore(directory: dir)
    let host = HostID("h0000000000")
    let block = BlockID(host: host)
    let shard = ShardID.block(block)
    let node = Node()
    let at = Stamp(wall: 1, host: host)
    let entries = [
        Entry(seq: 1, at: at, event: .create(kind: .git, title: "repo", path: "/r")),
        Entry(seq: 2, at: at, event: .gitRefreshed(branch: "main", status: [], log: [], ahead: 0, behind: 0, error: nil, at: at)),
    ]
    store.append(entries, to: shard)
    for e in entries { node.apply(e, to: shard) }
    store.closeAll()
    store.fold(shard, node: node)
    let size = (try? FileManager.default.attributesOfItem(atPath: dir.appendingPathComponent(shard.fileName + ".log").path))?[.size] as? UInt64
    #expect(size == 0)
    let replica = Node()
    #expect(LogStore(directory: dir).load(shard, into: replica))
    #expect(replica.block(block)?.git?.branch == "main")
    #expect(replica.seq(shard) == 2)
    #expect(store.history(shard).base != nil && store.history(shard).entries.isEmpty)
    try? FileManager.default.removeItem(at: dir)
}

@Test func remoteProvidersFillInTheirTemplates() {
    let p = RemoteProvider(name: "my", command: "my_special_script.sh --to %h %c")
    #expect(p.arguments(host: "box", command: "manifoldd bridge") == ["my_special_script.sh", "--to", "box", "manifoldd bridge"])
    let short = RemoteProvider(name: "s", command: "script.sh %h")
    #expect(short.arguments(host: "box", command: "run") == ["script.sh", "box", "run"], "no %c: the command is appended")
    #expect(RemoteProvider.ssh.arguments(host: "me@host", command: "x").first == "ssh")
}


@Test func aStackMovesWholeAndNeverComesOutByAccident() {
    var a = ArrangementState()
    let web = Placement(block: BlockID(), lens: .web), t1 = Placement(block: BlockID(), lens: .terminal)
    let t2 = Placement(block: BlockID(), lens: .terminal), dir = Placement(block: BlockID(), lens: .directory)
    let other = Placement(block: BlockID(), lens: .editor)
    a.apply(.place(web, column: 0, at: 0))
    a.apply(.place(t1, column: 0, at: 1))
    a.apply(.place(t2, column: 0, at: 2))
    a.apply(.place(dir, column: 0, at: 3))
    a.apply(.place(other, column: 1, at: 0))
    for p in [t1, t2, dir] { a.apply(.stash(p.id, behind: web.id)) }
    // The last stashed is nearest behind.
    #expect(a.columns[0].map(\.id) == [web.id, dir.id, t2.id, t1.id])
    // ⇧-click on dir's pill: dir takes web's place whole, the rest of the
    // stack (and web) behind it — nothing stashed comes out.
    for e in a.unstashing(dir.id) + [.stash(web.id, behind: dir.id), .focus(dir.id)] { a.apply(e) }
    #expect(a.shownTiles(inColumn: 0).map(\.id) == [dir.id])
    #expect(abs(a.height(of: dir.id) - 1) < 0.001)
    #expect(a.stashedTiles(inColumn: 0).count == 3)
    #expect(a.focused == dir.id)
    // dir's pill dropped on other's: dir and its whole stack go behind other.
    a.apply(.stash(dir.id, behind: other.id))
    #expect(a.columns.count == 1)
    #expect(a.columns[0].first?.id == other.id)
    #expect(a.stashedTiles(inColumn: 0).count == 4)
    #expect(a.columns[0].map(\.id).firstIndex(of: dir.id) == 1)
    #expect(abs(a.height(of: other.id) - 1) < 0.001)
    // Moved to a column of its own, the stack follows.
    a.apply(.move(other.id, column: 1, at: 0))
    #expect(a.columns.count == 1)
    #expect(a.columns[0].count == 5)
}


@Test func aBlockLinkInATextIsAMention() {
    let id = BlockID(host: HostID("h4z3gpme3et"))
    let found = Mention.find(in: "See [the terminal](manifold:\(id.description)) and [a file](notes/plan.md) and [[Ideas]].")
    #expect(found.count == 3)
    #expect(found[0].target == .block(id))
    #expect(found[0].text == "the terminal")
    #expect(found[1].target == .path("notes/plan.md"))
    #expect(found[2].target == .title("Ideas"))
}


@Test func aTileClickedOutOfAStackComesOutAloneUnderIt() {
    var a = ArrangementState()
    let top = Placement(block: BlockID(), lens: .editor)
    let t1 = Placement(block: BlockID(), lens: .terminal), t2 = Placement(block: BlockID(), lens: .terminal), t3 = Placement(block: BlockID(), lens: .terminal)
    a.apply(.place(top, column: 0, at: 0))
    for (i, t) in [t1, t2, t3].enumerated() { a.apply(.place(t, column: 0, at: i + 1)) }
    for t in [t1, t2, t3] { a.apply(.stash(t.id, behind: top.id)) }
    // The stack is [t3, t2, t1] behind top; t2 clicked comes out under
    // the stack, which stays behind top.
    for e in a.unstashing(t2.id) { a.apply(e) }
    #expect(a.shownTiles(inColumn: 0).map(\.id) == [top.id, t2.id])
    #expect(a.columns[0].map(\.id) == [top.id, t3.id, t1.id, t2.id])
    #expect(a.tile(behind: t3.id)?.id == top.id && a.tile(behind: t1.id)?.id == top.id)
    #expect(abs(a.height(of: top.id) - a.height(of: t2.id)) < 0.001)
    #expect(a.focused == t2.id)
}


@Test func aTileDraggedOverAnotherCoversItWithItsStackBehind() {
    var a = ArrangementState()
    let x = Placement(block: BlockID(), lens: .terminal), y = Placement(block: BlockID(), lens: .editor)
    let z = Placement(block: BlockID(), lens: .web), w = Placement(block: BlockID(), lens: .terminal)
    a.apply(.place(x, column: 0, at: 0))
    a.apply(.place(y, column: 0, at: 1))
    a.apply(.place(z, column: 1, at: 0))
    a.apply(.place(w, column: 1, at: 1))
    a.apply(.stash(w.id, behind: z.id))
    // z (with w behind it) ⌥-dragged over y: z takes y's place and room, y behind it, w still behind z.
    var column = a.columns[0]
    column.removeAll { $0.id == z.id }
    let i = column.firstIndex { $0.id == y.id }!
    for e in [Event.move(z.id, column: 0, at: i + 1), .stash(y.id, behind: z.id), .focus(z.id)] { a.apply(e) }
    #expect(a.columns.count == 1)
    #expect(a.shownTiles(inColumn: 0).map(\.id) == [x.id, z.id])
    #expect(a.stashedTiles(inColumn: 0).map(\.id).sorted() == [y.id, w.id].sorted())
    #expect(abs(a.height(of: x.id) - 0.5) < 0.001 && abs(a.height(of: z.id) - 0.5) < 0.001)
    #expect(a.focused == z.id)
}

@Test func anOldAboutLinkDecodesAsLinked() throws {
    // Logs written before links by hand had `about` edges, from a note to its subject.
    let json = #"{"id":"L1","from":"h/01ABC","to":"h/01DEF","kind":"about","at":{"wall":1,"seq":0}}"#
    var decoded: Link?
    do { decoded = try JSONDecoder().decode(Link.self, from: Data(json.utf8)) } catch {}
    if let decoded { #expect(decoded.kind == .linked) }
    // Every kind by the way there once was reads as opened now.
    let kind = try JSONDecoder().decode([LinkKind].self, from: Data(#"["about","linked","mention","found","opened"]"#.utf8))
    #expect(kind == [.linked, .linked, .opened, .opened, .opened])
}

@Test func bringingAStashedTileRevealsIt() {
    // ⌥⌘G with the project's git tile stashed behind another: it comes back, not just "focused" out of sight.
    var a = ArrangementState()
    let x = Placement(id: "x", block: BlockID(host: .local), lens: .terminal)
    let g = Placement(id: "g", block: BlockID(host: .local), lens: .git)
    a.apply(.place(x, column: 0, at: 0))
    a.apply(.place(g, column: 0, at: 1))
    a.apply(.heights(["x": 1, "g": 0]))
    a.apply(.focus("x"))
    #expect(a.isStashed("g"))
    for e in a.bringing(g.block, lens: .git, inColumn: 0, newPlacement: { "new" }) { a.apply(e) }
    #expect(!a.isStashed("g"))
    #expect(a.focused == "g")
}

@Test func removingAStacksTopRevealsTheNextBehindIt() {
    // ⌘W on an $EDITOR over a terminal: the terminal comes back in its place, its own stack still behind it.
    var a = ArrangementState()
    let w = Placement(id: "w", block: BlockID(host: .local), lens: .process)
    let x = Placement(id: "x", block: BlockID(host: .local), lens: .editor)
    let y = Placement(id: "y", block: BlockID(host: .local), lens: .terminal)
    let z = Placement(id: "z", block: BlockID(host: .local), lens: .git)
    for (i, p) in [w, x, y, z].enumerated() { a.apply(.place(p, column: 0, at: i)) }
    a.apply(.heights(["w": 0.5, "x": 0.5, "y": 0, "z": 0]))
    a.apply(.focus("x"))
    a.apply(.remove("x"))
    #expect(!a.isStashed("y"))
    #expect(a.isStashed("z"))
    #expect(a.tile(behind: "z")?.id == "y")
    #expect(abs(a.height(of: "w") - 0.5) < 0.001 && abs(a.height(of: "y") - 0.5) < 0.001)
    #expect(a.focused == "y")
}

@Test func aTopLeavingAloneLeavesItsStackWhereItWas() {
    // ⌘-drag of a stack's top to another column: the next behind comes out in its place; the rest stay behind that.
    var a = ArrangementState()
    let x = Placement(id: "x", block: BlockID(host: .local), lens: .editor)
    let y = Placement(id: "y", block: BlockID(host: .local), lens: .terminal)
    let z = Placement(id: "z", block: BlockID(host: .local), lens: .git)
    let o = Placement(id: "o", block: BlockID(host: .local), lens: .terminal)
    for (i, p) in [x, y, z].enumerated() { a.apply(.place(p, column: 0, at: i)) }
    a.apply(.place(o, column: 1, at: 0))
    a.apply(.heights(["x": 1, "y": 0, "z": 0]))
    for e in a.leavingAlone("x") + [.move("x", column: 1, at: 1)] { a.apply(e) }
    #expect(a.columns[0].map(\.id) == ["y", "z"])
    #expect(!a.isStashed("y") && a.isStashed("z"))
    #expect(a.columns[1].map(\.id) == ["o", "x"])
    #expect(!a.isStashed("x"))
}

@Test func aFolderBlocksPlaceIsItsOwnFolder() {
    // A listing or a repository is where it lists: a terminal made from it starts there, not in its parent.
    let at = Stamp(wall: 1, host: .local)
    let listing = Block(id: BlockID(), kind: .directory, created: at, path: "/Users/x/src/manifold")
    #expect(listing.place == "/Users/x/src/manifold")
    let repo = Block(id: BlockID(), kind: .git, created: at, path: "/Users/x/src/manifold")
    #expect(repo.place == "/Users/x/src/manifold")
    let file = Block(id: BlockID(), kind: .text, created: at, path: "/Users/x/src/manifold/README.md")
    #expect(file.place == "/Users/x/src/manifold")
}

@Test func aStatusThatNeedsAttentionIsWhatTheInboxLists() {
    var b = Block(id: BlockID(), kind: .terminal, created: Stamp(wall: 1, host: .local))
    #expect(!b.needsAttention)
    b.apply(.status(id: rootStatusID, StatusRecord(state: .working, at: Stamp(wall: 2, host: .local))), at: Stamp(wall: 9, host: .local))
    #expect(!b.needsAttention)
    b.apply(.status(id: rootStatusID, StatusRecord(state: .done, at: Stamp(wall: 3, host: .local))), at: Stamp(wall: 9, host: .local))
    #expect(b.needsAttention)
    // Read, it's attended to: out of the inbox, nothing to clear by hand.
    b.apply(.status(id: rootStatusID, StatusRecord(state: .done, at: Stamp(wall: 3, host: .local), read: true)), at: Stamp(wall: 9, host: .local))
    #expect(!b.needsAttention)
    b.apply(.status(id: rootStatusID, StatusRecord(state: .blocked, at: Stamp(wall: 4, host: .local))), at: Stamp(wall: 9, host: .local))
    #expect(b.needsAttention)
    b.apply(.status(id: rootStatusID, nil), at: Stamp(wall: 9, host: .local))
    #expect(!b.needsAttention)
    b.apply(.pinned(true), at: Stamp(wall: 9, host: .local))
    #expect(b.isPinned)
    b.apply(.pinned(false), at: Stamp(wall: 9, host: .local))
    #expect(!b.isPinned)
}

@Test func theFinderNamesThingsByTitleBeforeWhatIsAroundThem() {
    #expect(FileFinder.nameMatch("claude", title: "Claude Code", secondary: "agent ~/src/manifold") >= 500)
    #expect(FileFinder.nameMatch("claude", title: "Claude.pdf", secondary: "/Users/x/Claude.pdf") >= 500)
    #expect(FileFinder.nameMatch("code", title: "Claude Code", secondary: "") == 500)
    #expect(FileFinder.nameMatch("claude code", title: "Claude Code", secondary: "") == 600)
    #expect(FileFinder.nameMatch("aude", title: "Claude Code", secondary: "") == 400)
    // Only in what's around it: a weak match.
    let weak = FileFinder.nameMatch("terminal", title: "A.swift", secondary: "a note about the terminal")
    #expect(weak > 0 && weak < 200)
    #expect(FileFinder.nameMatch("zzz", title: "Claude Code", secondary: "") == 0)
}

@Test func aHostsPreferencesAreKeptInItsDeskAndOlderDesksStillRead() throws {
    // Saved before preferences: everything else as it was, the shell unset.
    let old = try JSONDecoder().decode(DeskState.self, from: Data(#"{"order":[],"settled":[],"settings":{"agentCommand":"codex"}}"#.utf8))
    #expect(old.settings.agentCommand == "codex")
    #expect(old.preferences.shell == nil)
    var d = old
    d.apply(.preferences(HostPreferences(shell: "fish")))
    #expect(d.preferences.shell == "fish")
    let back = try JSONDecoder().decode(DeskState.self, from: JSONEncoder().encode(d))
    #expect(back == d)
    d.apply(.preferences(HostPreferences()))
    #expect(d.preferences.shell == nil)
}

// MARK: Reaching hosts

/// A destination that runs its commands here, with HOME a fresh folder:
/// a provider on the PATH under a name of its own.
/// `filter`, what the provider puts its input through on the way.
private func scratchDestination(_ name: String, filter: String? = nil) throws -> (Destination, URL) {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("manifold-\(name)-\(UUID().uuidString)")
    let home = root.appendingPathComponent("home"), bin = root.appendingPathComponent("bin")
    try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
    let provider = bin.appendingPathComponent("provider")
    let run = filter.map { "\($0) | /bin/sh -c \"$2\"" } ?? "exec /bin/sh -c \"$2\""
    try "#!/bin/sh\nexport HOME='\(home.path)'\n\(run)\n".write(to: provider, atomically: true, encoding: .utf8)
    chmod(provider.path, 0o755)
    setenv("MANIFOLD_PROVIDER_\(name.uppercased())", provider.path, 1)
    return (Destination(provider: name, target: "here"), root)
}

@Test func aScriptForAProviderRunsInShWhateverItsQuotes() throws {
    let (out, status) = try Child.run(["/bin/sh", "-c", Bootstrap.posix(#"echo 'it''s' "$((1 + 1))"; printf '%s\n' "a b""#)])
    #expect(status == 0)
    #expect(String(decoding: out, as: UTF8.self) == "its 2\na b\n")
}

@Test func theServerGoesCompressedOrNotAndIsCheckedBeforeItsPutInPlace() throws {
    let (dest, root) = try scratchDestination("uploadtest")
    defer { try? FileManager.default.removeItem(at: root) }
    let bin = root.appendingPathComponent("home/.manifold/bin")
    let before = try Bootstrap.probe(dest)
    #expect(!before.os.isEmpty && !before.arch.isEmpty)
    #expect(before.hash == nil)
    #expect(before.gunzip)
    // A leftover from an upload that never finished is taken away.
    try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
    try Data("stale".utf8).write(to: bin.appendingPathComponent("manifoldd.new.1234"))
    let binary = Data((0..<300_000).map { UInt8(truncatingIfNeeded: $0 &* 7919) })
    let seen = Seen()
    for compressed in [true, false] {
        try Bootstrap.upload(dest, binary: binary, compressed: compressed) { seen.last = $0 }
        #expect(try Data(contentsOf: bin.appendingPathComponent("manifoldd")) == binary)
        #expect(seen.last == binary.count)
        #expect(try Bootstrap.probe(dest).hash == Bootstrap.sha256(binary))
    }
    let left = try FileManager.default.contentsOfDirectory(atPath: bin.path).sorted()
    #expect(left == ["manifold", "manifoldd"])
    #expect(FileManager.default.isExecutableFile(atPath: bin.appendingPathComponent("manifold").path))
}

private final class Seen: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    var last: Int {
        get { lock.lock(); defer { lock.unlock() }; return value }
        set { lock.lock(); value = newValue; lock.unlock() }
    }
}

@Test func aChildThatStopsMovingIsGivenUpOnButNotOneThatKeepsGoing() throws {
    let start = Date()
    let (_, stalled) = try Child.run(["/bin/sh", "-c", "sleep 30"], timeout: 60, stall: 1)
    #expect(stalled == 128 + SIGKILL)
    #expect(Date().timeIntervalSince(start) < 5)
    // Longer in all than the stall, but never still for that long.
    let (out, status) = try Child.run(["/bin/sh", "-c", "for i in 1 2 3 4; do echo $i; sleep 0.5; done"], timeout: 60, stall: 1)
    #expect(status == 0)
    #expect(String(decoding: out, as: UTF8.self) == "1\n2\n3\n4\n")
}

@Test func aServerThatArrivesCutShortIsNotPutInPlace() throws {
    let (dest, root) = try scratchDestination("truncatingtest", filter: "head -c 1000")
    defer { try? FileManager.default.removeItem(at: root) }
    let binary = Data(repeating: 7, count: 100_000)
    #expect(throws: RemoteError.self) { try Bootstrap.upload(dest, binary: binary, compressed: false) }
    let bin = root.appendingPathComponent("home/.manifold/bin")
    #expect(try FileManager.default.contentsOfDirectory(atPath: bin.path).isEmpty)
}

// MARK: Editing and viewing

@Test func aFileIsViewedAndANoteWrittenInEachByItsExtension() {
    #expect(Lens.default(for: .text, path: "/a/b.swift") == .preview)
    #expect(Lens.default(for: .text, path: "/a/README.md") == .preview)
    #expect(Lens.default(for: .text, path: nil) == .editor)
    #expect(Lens.viewRendering(for: "/a/README.md") == .markdown)
    #expect(Lens.viewRendering(for: "/a/main.GO") == .code)
    #expect(Lens.viewRendering(for: "/a/notes.xyz") == .plain)
    #expect(Lens.viewRendering(for: "/a/Makefile") == .plain)
    #expect(Lens.viewRendering(for: nil) == .markdown)
}

@Test func editingATextAndViewingItAreOneTileUnlessAskedForBoth() {
    var a = ArrangementState()
    let block = BlockID()
    let edited = Placement(block: block, lens: .editor)
    a.apply(.place(edited, column: 0, at: 0))
    #expect(a.tile(of: block, lens: .preview)?.id == edited.id)
    #expect(a.tile(of: block, lens: .preview, exact: true) == nil)
    #expect(a.bringing(block, lens: .preview, inColumn: 0, newPlacement: { "x" }).allSatisfy { if case .place = $0 { return false } else { return true } })
    #expect(a.bringing(block, lens: .preview, inColumn: 0, exact: true, newPlacement: { "x" }).contains { if case .place = $0 { return true } else { return false } })
    // Not for other lenses: a terminal isn't its block's other tile.
    #expect(a.tile(of: block, lens: .terminal) == nil)
}

@Test func aTilePushedDownGoesIntoTheStackOfTheTileBelowIt() {
    var a = ArrangementState()
    let x = Placement(block: BlockID(), lens: .terminal), y = Placement(block: BlockID(), lens: .terminal), z = Placement(block: BlockID(), lens: .terminal)
    let behindY = Placement(block: BlockID(), lens: .terminal)
    for (i, p) in [x, y, behindY, z].enumerated() { a.apply(.place(p, column: 0, at: i)) }
    a.apply(.heights([x.id: 0.4, y.id: 0.3, behindY.id: 0, z.id: 0.3]))
    #expect(a.tile(behind: behindY.id)?.id == y.id)
    // As the grid tells it when a line's drag pushes y down to nothing.
    a.apply(.stash(y.id, behind: z.id))
    a.apply(.heights([x.id: 0.7, y.id: 0, behindY.id: 0, z.id: 0.3]))
    #expect(a.columns[0].map(\.id) == [x.id, z.id, y.id, behindY.id])
    #expect(a.tile(behind: y.id)?.id == z.id)
    #expect(a.tile(behind: behindY.id)?.id == z.id)
    #expect(a.shownTiles(inColumn: 0).map(\.id) == [x.id, z.id])
}

@Test func theAgentsAHostHasAreOfferedInTheCatalogsOrder() throws {
    #expect(AgentCatalog.agents(among: ["muse", "claude", "unknown"]).map(\.command) == ["claude", "muse"])
    let old = try JSONDecoder().decode(DeskState.self, from: Data(#"{"order":[]}"#.utf8))
    #expect(old.agents.isEmpty)
    var d = old
    d.apply(.agents(["codex"]))
    #expect(d.agents == ["codex"])
    #expect(try JSONDecoder().decode(DeskState.self, from: JSONEncoder().encode(d)) == d)
}

@Test func aSaplingCheckoutInMercurialsDirectoryIsSaplings() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("manifold-vcs-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: root) }
    let hg = root.appendingPathComponent("hg"), git = root.appendingPathComponent("git"), both = root.appendingPathComponent("both")
    for (dir, marks) in [(hg, [".hg"]), (git, [".git"]), (both, [".git", ".hg"])] {
        for m in marks { try FileManager.default.createDirectory(at: dir.appendingPathComponent(m), withIntermediateDirectories: true) }
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("src/deep"), withIntermediateDirectories: true)
    }
    let found = VCS.repository(of: hg.appendingPathComponent("src/deep").path)
    #expect(found?.root == hg.path && found?.vcs == .sapling)
    #expect(VCS.sapling.stateFile(in: hg.path) == ".hg/dirstate")
    #expect(VCS.repository(of: git.appendingPathComponent("src").path)?.vcs == .git)
    #expect(VCS.repository(of: both.path)?.vcs == .sapling)
    try FileManager.default.createDirectory(at: hg.appendingPathComponent(".sl"), withIntermediateDirectories: true)
    #expect(VCS.sapling.stateFile(in: hg.path) == ".sl/dirstate")
}

// MARK: Agents' hooks

@Test func aHooksInputSaysWhatHappenedInTheAgent() {
    #expect(AgentHookCommand.event("prompt", agent: "claude", input: ["prompt": "fix the bug\nplease", "transcript_path": "/t.jsonl"]) == .prompt(agent: "claude", text: "fix the bug\nplease", transcript: "/t.jsonl"))
    #expect(AgentHookCommand.event("prompt", agent: "codex", input: ["input-messages": ["first", "second"]]) == .prompt(agent: "codex", text: "second", transcript: nil))
    #expect(AgentHookCommand.event("stop", agent: "claude", input: ["last_assistant_message": "Done."]) == .finished(agent: "claude", message: "Done.", transcript: nil))
    // The to-do list, when the tool that ran was the one that keeps it.
    let todos: [String: Any] = ["tool_name": "TodoWrite", "tool_input": ["todos": [["content": "Read it", "status": "completed"], ["content": "Fix it", "status": "in_progress"]]]]
    #expect(AgentHookCommand.event("working", agent: "claude", input: todos) == .todos(agent: "claude", [AgentTodo(text: "Read it", status: "completed"), AgentTodo(text: "Fix it", status: "in_progress")]))
    #expect(AgentHookCommand.event("working", agent: "claude", input: ["tool_name": "Edit"]) == .working(agent: "claude"))
    #expect(AgentHookCommand.event("waiting", agent: "claude", input: ["message": "Claude needs your permission to use Bash"]) == .waiting(agent: "claude", message: "Claude needs your permission to use Bash"))
    // A reminder that it's idle is no one waiting on anything.
    #expect(AgentHookCommand.event("waiting", agent: "claude", input: ["notification_type": "idle_prompt", "message": "x"]) == nil)
    #expect(AgentHookCommand.event("waiting", agent: "claude", input: ["message": "Claude is waiting for your input"]) == nil)
    #expect(AgentHookCommand.event("start", agent: "pi", input: [:]) == .started(agent: "pi"))
    #expect(AgentHookCommand.event("bogus", agent: "pi", input: [:]) == nil)
}

@Test func aTurnIsReadFromItsTranscriptFromItsPromptToTheNext() throws {
    // Claude Code's lines: the turn's prompt, what it said and the tools it used, then the next prompt.
    let lines: [[String: Any]] = [
        ["type": "user", "message": ["role": "user", "content": "an earlier ask"]],
        ["type": "assistant", "message": ["content": [["type": "text", "text": "not this"]]]],
        ["type": "user", "message": ["role": "user", "content": [["type": "text", "text": "fix the socket path"]]]],
        ["type": "assistant", "message": ["content": [["type": "text", "text": "Looking."], ["type": "tool_use", "name": "Read", "input": ["file_path": "/a/b.swift"]]]]],
        ["type": "user", "message": ["role": "user", "content": [["type": "tool_result", "content": "…"]]]],
        ["type": "assistant", "message": ["content": [["type": "tool_use", "name": "Bash", "input": ["command": "swift build\nmore"]], ["type": "text", "text": "Fixed."]]]],
        ["type": "user", "message": ["role": "user", "content": "the next ask"]],
        ["type": "assistant", "message": ["content": [["type": "text", "text": "nor this"]]]],
    ]
    let file = FileManager.default.temporaryDirectory.appendingPathComponent("turn-\(UUID().uuidString).jsonl")
    defer { try? FileManager.default.removeItem(at: file) }
    try lines.map { String(decoding: try JSONSerialization.data(withJSONObject: $0), as: UTF8.self) }.joined(separator: "\n").write(to: file, atomically: true, encoding: .utf8)
    let turn = TurnTranscript.render(path: file.path, prompt: "fix the socket path")
    #expect(turn == "Looking.\n\n- `Read` `/a/b.swift`\n- `Bash` `swift build`\n\nFixed.")
    #expect(TurnTranscript.render(path: file.path, prompt: "never asked") == nil)
}

@Test func anAgentsTurnsAreKeptByTheirCommand() {
    var t = TerminalState()
    var turn = AgentTurn(id: 3, agent: "claude", prompt: "do it", began: Stamp(wall: 1))
    t.apply(.turn(turn), at: Stamp(wall: 1))
    turn.after = "abc"
    turn.files = ["a.swift"]
    t.apply(.turn(turn), at: Stamp(wall: 2))
    #expect(t.turns?.count == 1 && t.turns?.first?.after == "abc" && t.turns?.first?.files == ["a.swift"])
}

@Test func installingHooksKeepsTheRestOfTheSettingsAndReplacesOnlyManifolds() throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("manifold-skill-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: dir) }
    let url = dir.appendingPathComponent("settings.json")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let theirs = #"{"model":"opus","hooks":{"Stop":[{"hooks":[{"type":"command","command":"say done"}]}]}}"#
    try Data(theirs.utf8).write(to: url)
    for _ in 0..<2 { try AgentSkill.installClaudeStyle(at: url, agent: "claude", events: AgentSkill.claudeEvents) }
    var json = try AgentSkill.readJSON(url)
    #expect(json["model"] as? String == "opus")
    let hooks = json["hooks"] as! [String: Any]
    let stop = (hooks["Stop"] as! [[String: Any]]).flatMap { $0["hooks"] as! [[String: Any]] }.map { $0["command"] as! String }
    // Theirs kept; ours once, however many times it's installed.
    #expect(stop.contains("say done"))
    #expect(stop.filter { $0.contains("agent stop --agent claude") && AgentSkill.isOurs($0) }.count == 1)
    #expect(Set(hooks.keys) == Set(AgentSkill.claudeEvents.map(\.hook)))
    #expect(FileManager.default.fileExists(atPath: url.appendingPathExtension("before-manifold").path))
    try AgentSkill.uninstallClaudeStyle(at: url)
    json = try AgentSkill.readJSON(url)
    let left = json["hooks"] as! [String: Any]
    #expect(Array(left.keys) == ["Stop"])
    #expect(json["model"] as? String == "opus")
}

@Test func semanticTokensGiveTheNamesThereIsSomewhereToGoTo() {
    // "func main() {" / "\tfmt.Println(\"日本\", x)": keyword, function; namespace, function, string, variable.
    let text = Rope("func main() {\n\tfmt.Println(\"日本\", x)\n}\n")
    let legend = ["keyword", "function", "namespace", "string", "variable"]
    let data = [0, 0, 4, 0, 0,   0, 5, 4, 1, 0,   1, 1, 3, 2, 0,   0, 4, 7, 1, 0,   0, 8, 4, 3, 0,   0, 6, 1, 4, 0]
    let names = SemanticTokens.navigable(data, legend: legend, in: text).map { String(text[$0]) }
    #expect(names == ["main", "fmt", "Println", "x"])
}

@Test func theSunIsWhereTheAlmanacSaysAndItsLightWarmsAsItSets() {
    func at(_ s: String) -> Date { ISO8601DateFormatter().date(from: s)! }
    let oslo = Daylight.Place(latitude: 59.92, longitude: 10.75)
    // Midsummer noon in Oslo: 90 − 59.92 + 23.44.
    #expect(abs(Daylight.elevation(at: at("2026-06-21T11:19:00Z"), from: oslo) - 53.5) < 0.5)
    // The equinox's noon on the equator, nearly overhead; Los Angeles's small hours in January, well below.
    #expect(Daylight.elevation(at: at("2026-03-20T12:07:00Z"), from: .init(latitude: 0, longitude: 0)) > 88)
    #expect(Daylight.elevation(at: at("2026-01-15T11:00:00Z"), from: .init(latitude: 34.05, longitude: -118.24)) < -40)

    let low = Daylight.cast(at: at("2026-06-21T20:20:00Z"), from: oslo)
    let high = Daylight.cast(at: at("2026-06-21T11:19:00Z"), from: oslo)
    #expect(low.kelvin < 4000 && high.kelvin > 6000)
    #expect(low.red == 1 && low.blue < low.green && low.green < 1)
    #expect(high.blue == 1 && high.red < high.green)
    // Subtle: no channel loses more than the strength.
    #expect(min(low.blue, high.red) >= 1 - Daylight.strength)

    let table = Daylight.parseZoneTable("# comment\nNO\t+5955+01045\tEurope/Oslo\nUS\t+340308-1181434\tAmerica/Los_Angeles\tPacific\n")
    #expect(abs(table["Europe/Oslo"]!.latitude - 59.9167) < 0.001 && abs(table["Europe/Oslo"]!.longitude - 10.75) < 0.001)
    #expect(abs(table["America/Los_Angeles"]!.longitude + 118.2428) < 0.001)
}

@Test func aNoteIsNamedWithoutBeingSavedAndItsFileNamesItOnceItIs() {
    let at = stamp()
    var b = Block(id: BlockID(), kind: .text, created: at)
    #expect(b.isNote && b.displayTitle == "Untitled")
    b.apply(.title("  Standup  "), at: at)
    #expect(b.isNote && b.displayTitle == "Standup")
    b.apply(.title(""), at: at)
    #expect(b.displayTitle == "Untitled")
    b.apply(.title("Standup"), at: at)
    b.apply(.path("/tmp/standup.md"), at: at)
    b.apply(.title(nil), at: at)
    #expect(!b.isNote && b.displayTitle == "standup.md")
}

@Test func aFileBlockNeedsReadingUntilItsTextComesInAndANoteNever() {
    let at = stamp()
    // A block made for a file before anyone opened it: nothing to show yet.
    var file = Block(id: BlockID(), kind: .text, created: at, path: "/tmp/b.txt")
    #expect(file.needsRead)
    file.apply(.content("hello\n", encoding: "utf-8", lineEnding: "\n", fingerprint: "f1"), at: at)
    #expect(!file.needsRead)
    // A new file: read as empty, but read.
    var fresh = Block(id: BlockID(), kind: .text, created: at, path: "/tmp/new.txt")
    fresh.apply(.content("", encoding: "utf-8", lineEnding: "\n", fingerprint: ""), at: at)
    #expect(!fresh.needsRead)
    // One that couldn't be read as text isn't asked for forever.
    var binary = Block(id: BlockID(), kind: .text, created: at, path: "/tmp/b.bin")
    binary.apply(.unreadable(true), at: at)
    #expect(!binary.needsRead)
    // A note has nothing to read; a note saved has its own text.
    var note = Block(id: BlockID(), kind: .text, created: at)
    #expect(!note.needsRead)
    note.apply(.edit([TextEdit(TextRange(0, 0), "mine")]), at: at)
    note.apply(.path("/tmp/mine.md"), at: at)
    #expect(!note.needsRead)
}

@Test func hooksRunManifoldByItsFullPathAndReplaceTheOnesThatDidnt() throws {
    let tool = "/Users/me/My Apps/Manifold.app/Contents/Helpers/manifold"
    let command = AgentSkill.command("stop", agent: "codex", tool: tool)
    #expect(command == #"[ -z "$MANIFOLD_BLOCK" ] || '/Users/me/My Apps/Manifold.app/Contents/Helpers/manifold' agent stop --agent codex"#)
    #expect(AgentSkill.shellQuoted("it's") == #"'it'\''s'"#)
    // Ours whether by path or bare, as they were once put in; not another's.
    #expect(AgentSkill.isOurs(command))
    #expect(AgentSkill.isOurs(#"[ -z "$MANIFOLD_BLOCK" ] || manifold agent stop --agent claude"#))
    #expect(!AgentSkill.isOurs("say done"))
    // An old bare hook is replaced, not kept beside the new one.
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("manifold-skill-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: dir) }
    let url = dir.appendingPathComponent("settings.json")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let old = #"{"hooks":{"Stop":[{"hooks":[{"type":"command","command":"[ -z \"$MANIFOLD_BLOCK\" ] || manifold agent stop --agent claude"}]}]}}"#
    try Data(old.utf8).write(to: url)
    try AgentSkill.installClaudeStyle(at: url, agent: "claude", events: AgentSkill.claudeEvents)
    let hooks = try AgentSkill.readJSON(url)["hooks"] as! [String: Any]
    let stop = (hooks["Stop"] as! [[String: Any]]).flatMap { $0["hooks"] as! [[String: Any]] }.map { $0["command"] as! String }
    #expect(stop.count == 1 && !stop[0].contains("|| manifold agent"))
    // Pi's extension runs it by the path too.
    let pi = AgentSkill.piExtension(tool: tool)
    #expect(pi.contains(#"pi.exec("/Users/me/My Apps/Manifold.app/Contents/Helpers/manifold", ["agent""#))
}

@Test func resettingTheGraphForgetsEveryLinkAndTheTrailButNotWhatsPlaced() {
    let node = Node()
    let host = HostID("h")
    func at(_ n: Int64) -> Stamp { Stamp(wall: 1000 + n, host: host) }
    let a = BlockID(host: host), b = BlockID(host: host), arr = BlockID(host: host)
    node.append(.create(kind: .text, title: nil, path: "/a"), to: .block(a), at: at(1))
    node.append(.create(kind: .text, title: nil, path: "/b"), to: .block(b), at: at(2))
    node.append(.create(kind: .arrangement, title: nil, path: nil), to: .block(arr), at: at(3))
    node.append(.place(Placement(block: a, lens: .editor), column: 0, at: 0), to: .block(arr), at: at(4))
    node.append(.link(Link(from: a, to: b, kind: .opened, at: at(5))), to: .links(host), at: at(5))
    node.append(.link(Link(from: b, to: a, kind: .linked, at: at(6))), to: .links(host), at: at(6))
    node.append(.step(Step(block: a, at: at(7))), to: .registry(host), at: at(7))
    node.append(.step(Step(block: b, at: at(8))), to: .registry(host), at: at(8))
    #expect(node.links(host).links.count == 2)
    #expect(node.graph.stepCount == 2)
    #expect(node.graph.edges(from: a, kind: .link(.opened)).count == 1)

    node.append(.clearGraph, to: .links(host), at: at(9))
    node.append(.clearGraph, to: .registry(host), at: at(10))
    #expect(node.links(host).links.isEmpty)
    #expect(node.registry(host).trail.isEmpty)
    #expect(node.graph.stepCount == 0)
    #expect(node.graph.edges(from: a, kind: .link(.opened)).isEmpty)
    #expect(node.graph.edges(from: b, kind: .link(.linked)).isEmpty)
    // What's placed stays.
    #expect(node.graph.edges(from: arr, kind: .placed).count == 1)
    // And a link made after comes back as ever.
    node.append(.link(Link(from: a, to: b, kind: .opened, at: at(11))), to: .links(host), at: at(11))
    #expect(node.graph.edges(from: a, kind: .link(.opened)).count == 1)
}

@Test func reachabilityFollowsStrongEdgesFromRoots() {
    let node = Node()
    let host = HostID("h"), other = HostID("o")
    func stamp(_ ms: Int64) -> Stamp { Stamp(wall: ms, logical: 0, host: host) }
    func put(_ event: Event, to shard: ShardID, at ms: Int64) { _ = node.append(event, to: shard, at: stamp(ms)) }
    let desk = BlockID(host: host), named = BlockID(host: host), off = BlockID(host: host)
    let t = BlockID(host: host), f = BlockID(host: host), n = BlockID(host: host), g = BlockID(host: host)
    let pinned = BlockID(host: host), held = BlockID(host: host), loose = BlockID(host: host)
    for (id, kind) in [(t, BlockKind.terminal), (f, .text), (n, .text), (g, .text), (pinned, .text), (held, .text), (loose, .text)] {
        put(.create(kind: kind, title: nil, path: nil), to: .block(id), at: 1)
    }
    put(.create(kind: .arrangement, title: nil, path: nil), to: .block(desk), at: 2)
    put(.create(kind: .arrangement, title: "kept", path: nil), to: .block(named), at: 2)
    put(.create(kind: .arrangement, title: nil, path: nil), to: .block(off), at: 2)
    put(.order([desk]), to: .desk(host), at: 3)
    // On the desk: t; t links f by hand, f opened g (weak); the named
    // workspace off the desk places n; the unnamed one off the desk
    // places loose.
    put(.place(Placement(block: t, lens: .terminal), column: 0, at: 0), to: .block(desk), at: 4)
    put(.link(Link(from: t, to: f, kind: .linked, at: stamp(5))), to: .links(host), at: 5)
    put(.link(Link(from: f, to: g, kind: .opened, at: stamp(6))), to: .links(host), at: 6)
    put(.place(Placement(block: n, lens: .editor), column: 0, at: 0), to: .block(named), at: 7)
    put(.place(Placement(block: loose, lens: .editor), column: 0, at: 0), to: .block(off), at: 8)
    put(.pinned(true), to: .block(pinned), at: 9)
    put(.hold(Hold(id: "x", block: held, holder: other, at: stamp(10))), to: .registry(host), at: 10)

    #expect(node.roots(on: host) == [desk, named, pinned, held])
    let r = node.reachable(on: host)
    #expect(r.contains(t) && r.contains(f) && r.contains(n) && r.contains(pinned) && r.contains(held))
    #expect(!r.contains(g))      // only opened: weak
    #expect(!r.contains(off) && !r.contains(loose))

    // The link by hand taken away, f goes; the hold released, held goes.
    let link = node.links(host).links.first { $0.to == f }!
    put(.unlink(link.id), to: .links(host), at: 11)
    put(.release("x"), to: .registry(host), at: 12)
    let r2 = node.reachable(on: host)
    #expect(!r2.contains(f) && !r2.contains(held) && r2.contains(t))
    #expect(EdgeKind.placed.isStrong && EdgeKind.link(.linked).isStrong && !EdgeKind.link(.opened).isStrong && !EdgeKind.contains.isStrong)
}

// MARK: Output

@Test func outputTrimsZshPartialLineMark() {
    let mark = "\u{1B}[1m\u{1B}[7m%\u{1B}[27m\u{1B}[1m\u{1B}[0m" + String(repeating: " ", count: 29) + "\r \r"
    #expect(OutputState.trimmed("done\r\n" + mark) == "done\r\n")
    #expect(OutputState.trimmed("\u{1B}[31mred\u{1B}[0m" + mark) == "\u{1B}[31mred\u{1B}[0m")
    #expect(OutputState.trimmed("100%\r \r") == "100%\r \r")
    #expect(OutputState.trimmed("plain\n") == "plain\n")
}

// MARK: Shell notebooks

@Test func notebookCellsRunAndKeepTheirLastOutput() {
    var nb = NotebookState()
    let a = NotebookCell(id: "a", source: "echo hi"), b = NotebookCell(id: "b")
    let t = Stamp(wall: 1)
    nb.apply(.insert(a, at: 0))
    nb.apply(.insert(b, at: 5))
    nb.apply(.insert(a, at: 1))  // the same cell again: ignored
    #expect(nb.cells.map(\.id) == ["a", "b"])
    nb.apply(.source("b", "false"))
    nb.apply(.queued(["a", "b"]))
    nb.apply(.started("a", count: 1, at: t))
    #expect(nb.running == "a" && nb.queued == ["b"] && nb.cell("a")?.output == "")
    nb.apply(.finished("a", output: "hi\r\n", status: 0, truncated: false, at: t))
    #expect(nb.running == nil && nb.cell("a")?.output == "hi\r\n" && nb.cell("a")?.status == 0)
    // A second run starts its output afresh.
    nb.apply(.started("a", count: 2, at: t))
    #expect(nb.cell("a")?.output == "" && nb.cell("a")?.count == 2 && nb.runs == 2)
    nb.apply(.finished("a", output: "again", status: 0, truncated: false, at: t))
    nb.apply(.move("b", to: 0))
    #expect(nb.cells.map(\.id) == ["b", "a"])
    nb.apply(.clear("a"))
    #expect(nb.cell("a")?.output == nil && nb.cell("a")?.count == nil && nb.cell("a")?.source == "echo hi")
    // The shell gone: nothing runs or waits.
    nb.apply(.queued(["b"]))
    nb.apply(.shell(pid: nil, name: nil, at: t))
    #expect(nb.queued.isEmpty && nb.pid == nil)
    nb.apply(.remove("b"))
    #expect(nb.cells.map(\.id) == ["a"])
    #expect(NotebookEdit.source("a", "x").isUsers && !NotebookEdit.started("a", count: 1, at: t).isUsers)
}

// MARK: Going to a block

@Test func aNewTileGoesAfterAStackNotIntoIt() {
    // A file opened with a stack's top focused: a tile of its own, the stack untouched.
    var a = ArrangementState()
    let top = Placement(id: "top", block: BlockID(host: .local), lens: .editor)
    let s1 = Placement(id: "s1", block: BlockID(host: .local), lens: .editor)
    let s2 = Placement(id: "s2", block: BlockID(host: .local), lens: .editor)
    let other = Placement(id: "other", block: BlockID(host: .local), lens: .terminal)
    for (p, i) in [(other, 0), (top, 1), (s1, 2), (s2, 3)] { a.apply(.place(p, column: 0, at: i)) }
    a.apply(.heights(["other": 0.3, "top": 0.7, "s1": 0, "s2": 0]))
    a.apply(.focus("top"))
    let file = BlockID(host: .local)
    for e in a.bringing(file, lens: .preview, inColumn: 0, newPlacement: { "new" }) { a.apply(e) }
    #expect(a.columns[0].map(\.id) == ["other", "top", "s1", "s2", "new"])
    #expect(a.tile(behind: "s1")?.id == "top" && a.tile(behind: "s2")?.id == "top")
    #expect(!a.isStashed("new") && a.focused == "new")
    // Its room from the stack's top (the tile that shows above it), halved.
    #expect(abs(a.height(of: "new") - a.height(of: "top")) < 0.001)
    #expect(abs(a.height(of: "other") / (a.height(of: "other") + a.height(of: "top") + a.height(of: "new")) - 0.3) < 0.001)
}

@Test func goingToAStackedTileBringsItToTheTop() {
    // ⌘J, a link, the finder: a tile in a stack comes to its top, the rest behind it.
    var a = ArrangementState()
    let top = Placement(id: "top", block: BlockID(host: .local), lens: .editor)
    let s1 = Placement(id: "s1", block: BlockID(host: .local), lens: .editor)
    let s2 = Placement(id: "s2", block: BlockID(host: .local), lens: .editor)
    let other = Placement(id: "other", block: BlockID(host: .local), lens: .terminal)
    for (p, i) in [(top, 0), (s1, 1), (s2, 2), (other, 3)] { a.apply(.place(p, column: 0, at: i)) }
    a.apply(.heights(["top": 0.6, "s1": 0, "s2": 0, "other": 0.4]))
    a.apply(.focus("other"))
    for e in a.revealing("s2") { a.apply(e) }
    #expect(a.focused == "s2" && !a.isStashed("s2"))
    #expect(a.isStashed("top") && a.isStashed("s1"))
    #expect(a.tile(behind: "top")?.id == "s2" && a.tile(behind: "s1")?.id == "s2")
    #expect(a.shownTiles(inColumn: 0).map(\.id) == ["s2", "other"])
    // In the stack's place and room.
    #expect(abs(a.height(of: "s2") / (a.height(of: "s2") + a.height(of: "other")) - 0.6) < 0.001)
    // The tile already showing: focused, nothing moved.
    #expect(a.revealing("other") == [.focus("other")])
}

@Test func aStackWalkedWithOptionHeldKeepsItsOrderUntilLetGo() {
    // ⌥-clicks with ⌥ held: each brings the next up; the ones passed stay where they were.
    var a = ArrangementState()
    let ids: [PlacementID] = ["a", "b", "c", "d"]
    for (i, id) in ids.enumerated() { a.apply(.place(Placement(id: id, block: BlockID(host: .local), lens: .editor), column: 0, at: i)) }
    a.apply(.place(Placement(id: "other", block: BlockID(host: .local), lens: .terminal), column: 0, at: 4))
    a.apply(.heights(["a": 0.6, "b": 0, "c": 0, "d": 0, "other": 0.4]))
    func stack() -> [PlacementID] { a.columns[0].map(\.id).filter { $0 != "other" } }
    for (k, want) in [(1, ["b", "a", "c", "d"]), (2, ["c", "a", "b", "d"]), (3, ["d", "a", "b", "c"]), (0, ["a", "b", "c", "d"])] {
        for e in a.walkingStack(ids, to: k) { a.apply(e) }
        #expect(stack() == want)
        #expect(a.focused == want[0] && !a.isStashed(want[0]))
        #expect(want.dropFirst().allSatisfy { a.isStashed($0) && a.tile(behind: $0)?.id == want[0] })
        #expect(a.shownTiles(inColumn: 0).map(\.id) == [want[0], "other"])
        #expect(abs(a.height(of: want[0]) / (a.height(of: want[0]) + a.height(of: "other")) - 0.6) < 0.001)
    }
}

@Test func anImageShownInATextIsEmbeddedAndKeptByIt() {
    // `![](…)` embeds (a strong edge, keeping the image); `[](…)` only mentions.
    let id = BlockID(host: HostID("h"), ulid: "01IMAGE")
    let found = Mention.find(in: "see ![](manifold:h/01IMAGE) and [it](other.md) and ![pic](pics/a.png)")
    #expect(found.count == 3)
    #expect(found[0].target == .block(id) && found[0].embeds)
    #expect(found[1].target == .path("other.md") && !found[1].embeds)
    #expect(found[2].target == .path("pics/a.png") && found[2].embeds)
    #expect(EdgeKind.link(.embeds).isStrong && !EdgeKind.link(.opened).isStrong)
}

@Test func openingAFolderSaysItIsOne() throws {
    // `manifold DIR` on another host: the app can't look there, so the path says it.
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("open-\(UUID().uuidString)").path
    try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(atPath: dir) }
    try "x".write(toFile: dir + "/f.txt", atomically: true, encoding: .utf8)
    guard case let .success(paths) = OpenCommand.resolve([dir, dir + "/f.txt", dir + "/new.md"]) else { Issue.record("no paths"); return }
    #expect(paths[0].hasSuffix("/") && !paths[1].hasSuffix("/") && !paths[2].hasSuffix("/"))
}

@Test func commandsAreFoundOnTheScreenPastOnesThatArent() {
    let p = "~/src› "
    // Three commands over several lines (newlines in them, spaces in their
    // text), the first of them scrolled off, then two plain ones.
    let multi = ["printf \"one\\ two\\ \"", "for x in a b  echo $x  end", "printf \"three\\ four\\ \""]
    let lines = [
        "                    two\\",        // the first's rest: its start scrolled off
        "                    \"",
        "onetwo",
        p + "for x in a b",
        "                    echo $x",
        "                    end",
        "a", "b",
        p + "printf \"three\\",
        "                    four\\",
        "                    \"",
        "threefour",
        p + "ls",
        "Package.swift  Sources",
        p + "git status  (main)",
        "nothing to commit",
        p,
    ]
    let found = CommandLines.locate(multi + ["ls", "git status"], in: lines)
    #expect(found[0] == nil)
    #expect(found[1] == 3 && found[2] == 8 && found[3] == 12 && found[4] == 14)
    // A short first line isn't taken for a command's start; nor is output.
    #expect(!CommandLines.lineShows("ls -la foo", in: "x ls"))
    #expect(!CommandLines.lineShows("git status", in: "nothing to commit"))
    // The same command twice: each its own line.
    #expect(CommandLines.locate(["ls", "ls"], in: [p + "ls", "a", p + "ls", "a", p]) == [0: 0, 1: 2])
    // Commands gone from the screen (cleared): the ones still there are found.
    #expect(CommandLines.locate((0..<50).map { "cmd\($0)" } + ["ls"], in: [p + "ls", "a", p]) == [50: 0])
}

@Test func pathsWithLinesInATerminalAreLinks() {
    let rg = "./python/monarch/_src/actor/bootstrap.py:177:1:def run_worker_loop_forever("
    let l = TerminalLinks.links(in: rg)
    #expect(l.map(\.target) == ["./python/monarch/_src/actor/bootstrap.py:177:1"])
    #expect(l.first?.range == 0..<46)
    let grep = "DESIGN.md:3:Manifold is a wiki, not a set of windows. Terminals, files, notes,"
    #expect(TerminalLinks.links(in: grep).map(\.target) == ["DESIGN.md:3"])
    // Clicked on the text after it: no link there.
    #expect(TerminalLinks.link(at: 14, in: grep) == nil)
    #expect(TerminalLinks.link(at: 2, in: grep)?.target == "DESIGN.md:3")
    // Not paths: a word and a number, prose with a slash; an address is one.
    #expect(TerminalLinks.links(in: "error:12: expected ';' and/or more").isEmpty)
    #expect(TerminalLinks.links(in: "see https://example.com/a, then (src/main.swift:9).").map(\.target) == ["https://example.com/a", "src/main.swift:9"])
    // A bare name: only when it's there.
    #expect(TerminalLinks.links(in: "Package.swift  Sources").isEmpty)
    #expect(TerminalLinks.links(in: "Package.swift  Sources", exists: { $0 == "Package.swift" }).map(\.target) == ["Package.swift"])
    // A path that isn't there isn't a link, line or not.
    #expect(TerminalLinks.links(in: "gone.txt:4:", exists: { _ in false }).isEmpty)
}

@Test func theAlternateScreenIsFollowedAcrossChunks() {
    var r = ReplayBuffer()
    r.append(Data("plain \u{1b}[31mred\u{1b}[0m\u{1b}[?25l".utf8))
    #expect(!r.altScreen)
    // Split across two chunks.
    r.append(Data("before \u{1b}[?10".utf8))
    r.append(Data("49h a full-screen program".utf8))
    #expect(r.altScreen)
    // The last switch in a chunk wins.
    r.append(Data("\u{1b}[?1049l back \u{1b}[?47h again".utf8))
    #expect(r.altScreen)
    r.append(Data("\u{1b}[?1047l".utf8))
    #expect(!r.altScreen)
}
