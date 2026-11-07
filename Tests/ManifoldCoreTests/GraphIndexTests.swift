import Foundation
import Testing
@testable import ManifoldCore

/// The graph's indexes (§3.12): edges by relation and by the place they
/// lead to, blocks by kind and by project, and walks narrowed by kind and
/// relation — and how fast they are on a graph far bigger than anyone's.
private let host = HostID.local
private func at(_ ms: Int64) -> Stamp { Stamp(wall: ms, logical: 0, host: host) }
private let none = ShardState.links(Links())

private func make(_ g: Graph, _ kind: BlockKind, path: String? = nil, ms: Int64 = 1) -> BlockID {
    let id = BlockID(host: host)
    g.apply(Entry(seq: 1, at: at(ms), event: .create(kind: kind, title: nil, path: path)), to: .block(id), state: none)
    return id
}

private func link(_ g: Graph, _ from: BlockID, _ to: BlockID, kind: LinkKind = .linked, anchor: String? = nil, relation: String? = nil, ms: Int64 = 2) -> Link {
    let l = Link(from: from, to: to, kind: kind, at: at(ms), toAnchor: anchor, relation: relation)
    g.apply(Entry(seq: 1, at: at(ms), event: .link(l)), to: .links(host), state: none)
    return l
}

@Test func edgesByRelationAndPlace() {
    let g = Graph()
    let file = make(g, .text, path: "/src/app/main.swift")
    let a = make(g, .output), b = make(g, .output), note = make(g, .text)
    let la = link(g, a, file, anchor: "abc123", relation: "annotates", ms: 5)
    _ = link(g, b, file, anchor: "abc123", relation: "annotates", ms: 6)
    _ = link(g, note, file, kind: .opened, anchor: "zzz999", relation: "mentions")
    _ = link(g, note, file, kind: .opened)

    #expect(g.edges(relation: "annotates").map(\.from) == [b, a])
    #expect(g.edges(relation: "mentions").map(\.from) == [note])
    #expect(Set(g.edges(to: file, anchor: "abc123").map(\.from)) == [a, b])
    #expect(g.edges(to: file, anchor: "abc123", relation: "mentions").isEmpty)
    #expect(g.edges(to: file, anchor: nil).map(\.from) == [note])
    #expect(g.anchorsLinked(in: file) == ["abc123": 2, "zzz999": 1])
    #expect(g.anchorsLinked(in: file, relation: "annotates") == ["abc123": 2])

    g.apply(Entry(seq: 2, at: at(9), event: .unlink(la.id)), to: .links(host), state: none)
    #expect(g.edges(relation: "annotates").map(\.from) == [b])
    #expect(g.edges(to: file, anchor: "abc123").map(\.from) == [b])
}

@Test func blocksByKind() {
    let g = Graph()
    let t1 = make(g, .output), t2 = make(g, .output), _ = make(g, .terminal)
    #expect(g.blocks(kind: .output) == [t1, t2])
    #expect(g.kind(of: t1) == .output)
    g.remove(.block(t1))
    #expect(g.blocks(kind: .output) == [t2])
    #expect(g.kind(of: t1) == nil)
}

@Test func blocksByProject() {
    let g = Graph()
    let main = make(g, .text, path: "/src/app/Sources/main.swift")
    let other = make(g, .text, path: "/src/other/x.swift")
    let term = make(g, .terminal)
    g.apply(Entry(seq: 2, at: at(3), event: .cwd("/private/src/app/Tests")), to: .block(term), state: none)
    #expect(g.project(of: main) == nil)

    // Made a project after the blocks: they're found in it.
    var p = Project(root: "/src/app", made: at(4))
    p.alias = "/private/src/app"
    var desk = DeskState()
    desk.apply(.project(p))
    g.apply(Entry(seq: 1, at: at(4), event: .project(p)), to: .desk(host), state: .desk(desk))
    #expect(g.project(of: main) == "/src/app")
    #expect(g.project(of: term) == "/src/app")
    #expect(g.project(of: other) == nil)
    #expect(g.blocks(inProject: "/src/app", on: host) == [main, term])
    #expect(g.project(holding: "/src/app", on: host) == "/src/app")
    #expect(g.project(holding: "/src/application", on: host) == nil)

    // A block made in it afterwards, and one moved out.
    let later = make(g, .text, path: "/src/app/README.md")
    g.apply(Entry(seq: 2, at: at(6), event: .path("/src/other/main.swift")), to: .block(main), state: none)
    #expect(g.blocks(inProject: "/src/app", on: host) == [term, later])

    // Unmade: nothing's in it.
    desk.apply(.unproject("/src/app"))
    g.apply(Entry(seq: 2, at: at(7), event: .unproject("/src/app")), to: .desk(host), state: .desk(desk))
    #expect(g.project(of: later) == nil)
    #expect(g.blocks(inProject: "/src/app", on: host).isEmpty)
}

@Test func narrowedWalks() {
    let g = Graph()
    let space = make(g, .arrangement), t = make(g, .output), file = make(g, .text, path: "/a.swift"), mentioned = make(g, .pdf)
    _ = link(g, space, t, kind: .pinned)
    _ = link(g, t, file, relation: "annotates")
    _ = link(g, t, mentioned, kind: .opened, relation: "mentions")

    #expect(g.walk(from: [space]) == [space: 0, t: 1, file: 2, mentioned: 2])
    #expect(g.walk(from: [space], depth: 1) == [space: 0, t: 1])
    #expect(g.walk(from: [t], relations: ["annotates"]) == [t: 0, file: 1])
    #expect(g.walk(from: [t], over: [.link(.opened)]) == [t: 0, mentioned: 1])
    // Back from a file to what's about it, and the space those are in.
    #expect(g.walk(from: [file], direction: .in) == [file: 0, t: 1, space: 2])
    #expect(g.walk(from: [mentioned], over: [.link(.opened)], direction: .both) == [mentioned: 0, t: 1])
}

/// Built big and asked: a project's threads, a place's threads, a
/// two-step walk, and the whole made again. 100k blocks and 1M edges with
/// MANIFOLD_BENCH set (a release build is about ten times quicker than
/// the tests'); else a tenth of that, checked against budgets made
/// generous for a debug build on a busy machine.
@Test func indexesAreQuick() {
    let full = ProcessInfo.processInfo.environment["MANIFOLD_BENCH"] != nil
    let blocks = full ? 100_000 : 10_000, edges = full ? 1_000_000 : 100_000, projects = 50
    let g = Graph()
    var ids: [BlockID] = []
    ids.reserveCapacity(blocks)
    var desk = DeskState()
    for p in 0..<projects {
        let project = Project(root: "/src/p\(p)", made: at(0))
        desk.apply(.project(project))
        g.apply(Entry(seq: p + 1, at: at(0), event: .project(project)), to: .desk(host), state: .desk(desk))
    }
    let started = Date()
    for i in 0..<blocks {
        let kind: BlockKind = i % 10 == 0 ? .output : i % 10 == 1 ? .terminal : .text
        ids.append(make(g, kind, path: kind == .text ? "/src/p\(i % projects)/d\(i % 97)/f\(i).swift" : nil, ms: Int64(i)))
    }
    var rng = SystemRandomNumberGenerator()
    for i in 0..<edges {
        let from = ids[Int.random(in: 0..<blocks, using: &rng)], to = ids[Int.random(in: 0..<blocks, using: &rng)]
        let annotates = g.kind(of: from) == .output && i % 3 == 0
        _ = link(g, from, to, kind: annotates ? .linked : .opened, anchor: annotates ? "a\(i % 7)" : nil,
                 relation: annotates ? "annotates" : (i % 5 == 0 ? "mentions" : nil), ms: Int64(blocks + i))
    }
    let built = Date().timeIntervalSince(started)

    func time(_ n: Int = 100, _ f: () -> Void) -> Double {
        let t = Date()
        for _ in 0..<n { f() }
        return Date().timeIntervalSince(t) / Double(n)
    }
    // A project's threads: the blocks in it, and the threads about them.
    var found = 0
    let projectTimeline = time {
        let members = g.blocks(inProject: "/src/p7", on: host)
        var threads: Set<BlockID> = []
        for b in members { for e in g.edges(to: b, kind: .link(.linked)) where e.relation == "annotates" { threads.insert(e.from) } }
        found = threads.count
    }
    let place = time(1000) { _ = g.edges(to: ids[42], anchor: "a3", relation: "annotates") }
    let twoSteps = time { _ = g.walk(from: [ids[7]], depth: 2) }
    let rebuilt = Date()
    let again = Graph()
    for e in g.edges(relation: "annotates") { again.apply(Entry(seq: 1, at: e.at, event: .link(Link(from: e.from, to: e.to, kind: .linked, at: e.at, toAnchor: e.toAnchor, relation: e.relation))), to: .links(host), state: none) }
    let rebuild = Date().timeIntervalSince(rebuilt)
    print("graph of \(blocks) blocks, \(edges) edges: built in \(String(format: "%.2f", built)) s; a project's threads (\(found)) \(String(format: "%.3f", projectTimeline * 1000)) ms; a place's \(String(format: "%.4f", place * 1000)) ms; a two-step walk \(String(format: "%.2f", twoSteps * 1000)) ms; annotations re-indexed \(String(format: "%.2f", rebuild)) s")
    #expect(found > 0)
    let scale = full ? 10.0 : 1.0
    #expect(projectTimeline < 0.02 * scale)
    #expect(place < 0.001 * scale)
    #expect(twoSteps < 0.05 * scale)
}
