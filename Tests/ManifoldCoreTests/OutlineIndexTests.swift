import Foundation
import Testing
@testable import ManifoldCore

struct OutlineIndexTests {
    /// What the index should find, by looking at everything.
    private func brute(_ tiles: [String: (title: String, rows: [String])], order: [String], query: String) -> [String] {
        let words = query.lowercased().split(whereSeparator: \.isWhitespace).map { Array($0.utf8) }
        func has(_ s: String, _ w: [UInt8]) -> Bool {
            let t = Array(s.lowercased().utf8)
            guard w.count <= t.count else { return w.isEmpty }
            return (0...(t.count - w.count)).contains { Array(t[$0..<($0 + w.count)]) == w }
        }
        var out: [String] = []
        for t in order {
            guard let tile = tiles[t] else { continue }
            for (i, r) in tile.rows.enumerated() where words.allSatisfy({ has(r, $0) || has(tile.title, $0) }) { out.append("\(t)#\(i)") }
        }
        return out
    }

    private func found(_ index: OutlineIndex<String, String>, order: [String], query: String) -> [String] {
        index.find(query, in: order).flatMap { hit in hit.items.map { "\(hit.tile)#\($0)" } }
    }

    @Test func findsWhatLookingAtEverythingFinds() {
        var rng = SystemRandomNumberGenerator()
        let vocabulary = ["render", "layout", "parse", "token", "buffer", "Stream", "socket", "session", "window", "column",
                          "outline", "index", "symbol", "cache", "query", "ab", "x", "ünïcode", "naïve", "日本語"]
        func phrase() -> String { (0..<Int.random(in: 1...4, using: &rng)).map { _ in vocabulary.randomElement(using: &rng)! }.joined(separator: Bool.random(using: &rng) ? " " : "_") }
        let index = OutlineIndex<String, String>()
        var tiles: [String: (title: String, rows: [String])] = [:]
        let names = (0..<6).map { "t\($0)" }
        let queries = ["", "ren", "render lay", "x", "ab", "dex sym", "ünï", "日本", "socket session window", "zzz", "t2 col", "ïve", "STREAM"]
        for step in 0..<400 {
            let t = names.randomElement(using: &rng)!
            switch Int.random(in: 0..<10, using: &rng) {
            case 0:
                tiles[t] = nil
                index.remove(tile: t)
            default:
                var rows = tiles[t]?.rows ?? []
                // An edit somewhere: rows in, out or changed, as outlines change.
                let at = rows.isEmpty ? 0 : Int.random(in: 0...rows.count, using: &rng)
                let out = min(rows.count - at, Int.random(in: 0...3, using: &rng))
                rows.replaceSubrange(at..<(at + out), with: (0..<Int.random(in: 0...4, using: &rng)).map { _ in phrase() })
                if step % 50 == 0 { rows = (0..<Int.random(in: 0...200, using: &rng)).map { _ in phrase() } }
                let title = Bool.random(using: &rng) ? "\(t) \(phrase())" : (tiles[t]?.title ?? t)
                tiles[t] = (title, rows)
                index.update(t, title: title, rows: rows, signature: step) { $0 }
            }
            let order = names.shuffled(using: &rng)
            for q in queries {
                #expect(found(index, order: order, query: q) == brute(tiles, order: order, query: q), "step \(step), query “\(q)”")
            }
        }
        #expect(index.count == tiles.values.map(\.rows.count).reduce(0, +))
    }

    @Test func numbersItselfAgainOnceMostRowsAreGone() {
        let index = OutlineIndex<String, String>()
        let rows = (0..<5000).map { "symbol \($0) render" }
        index.update("a", title: "A", rows: rows, signature: 1) { $0 }
        index.update("a", title: "A", rows: Array(rows.prefix(100)), signature: 2) { $0 }
        #expect(index.renumbered == 1)
        #expect(index.count == 100)
        #expect(index.find("render 99", in: ["a"]).first?.items == [99])
        // One row changed in the middle: only it goes out and comes in.
        var edited = Array(rows.prefix(100))
        edited[50] = "symbol fifty render"
        index.update("a", title: "A", rows: edited, signature: 3) { $0 }
        #expect(index.find("fifty", in: ["a"]).first?.items == [50])
        #expect(index.find("symbol 50 ", in: ["a"]).isEmpty)
    }

    /// One row changed in a long outline: only it is taken out and put in
    /// (timed, and compared with indexing it all; not asserted, as timings
    /// on a busy machine aren't).
    @Test func anEditTouchesOnlyWhatChanged() {
        let index = OutlineIndex<String, String>()
        var rows = (0..<20000).map { "func symbol\($0)(render: Layout) -> Buffer" }
        let t0 = DispatchTime.now().uptimeNanoseconds
        index.update("a", title: "A.swift", rows: rows, signature: 1) { $0 }
        let t1 = DispatchTime.now().uptimeNanoseconds
        rows[10000] = "func edited(render: Layout) -> Buffer"
        index.update("a", title: "A.swift", rows: rows, signature: 2) { $0 }
        let t2 = DispatchTime.now().uptimeNanoseconds
        print(String(format: "indexing 20,000 rows: %.1f ms; one changed: %.2f ms", Double(t1 - t0) / 1e6, Double(t2 - t1) / 1e6))
        #expect(index.find("edited", in: ["a"]).first?.items == [10000])
        #expect(index.find("symbol10000(", in: ["a"]).isEmpty)
        #expect(index.find("symbol19999", in: ["a"]).first?.items == [19999])
        // Its title counts, unless asked not to.
        #expect(index.find("a.swift edited", in: ["a"]).first?.items == [10000])
        #expect(index.find("a.swift edited", in: ["a"], titles: false).isEmpty)
    }

    @Test func intersectsSortedLists() {
        let a: ContiguousArray<UInt32> = [1, 5, 9, 200, 201, 5000]
        let b = ContiguousArray<UInt32>((0..<6000).filter { $0 % 5 == 0 }.map(UInt32.init))
        #expect(OutlineIndex<Int, Int>.intersect(a, b) == [5, 200, 5000])
        #expect(OutlineIndex<Int, Int>.intersect(b, a) == [5, 200, 5000])
        #expect(OutlineIndex<Int, Int>.intersect([], b).isEmpty)
    }
}
