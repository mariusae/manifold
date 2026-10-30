import Foundation

/// An index of the rows of many outlines — a space's tiles' (⌘P, §3.5) —
/// kept as they change, for finding, as a query is typed, the rows holding
/// every word of it: each word in the row's own text, or in its tile's
/// title.
///
/// A row's text, lowercased, is cut into trigrams of its UTF-8 bytes, and
/// each trigram keeps the rows it's in as a posting list. Rows are
/// numbered as they come, so a list is sorted and only ever grows at its
/// end. A word of three bytes or more is looked for in the rows on all of
/// its trigrams' lists, intersected shortest first, each other list
/// galloped through (exponential search), and the few left are confirmed
/// to hold it (`memmem`). A shorter word is looked for in every row: a few
/// megabytes at most, gone through at memory speed. Of a query's words the
/// one with the fewest rows to look at leads; the rest are checked in what
/// it found.
///
/// A row taken out is marked gone, and counted against each of its lists;
/// a list is compacted once half of it is gone, and the whole index
/// numbered again once half its rows are — each in time proportional to
/// what was taken out since, so taking out costs what putting in did. A
/// tile's new rows are compared with its last: only those between the
/// common head and tail go out and come in, so an edit touches only the
/// rows it changed, and the rest are only renumbered.
public final class OutlineIndex<Tile: Hashable, Row> {
    private struct Entry {
        /// Its tile's slot; -1 once it's gone.
        var slot: Int32
        /// Its place among its tile's rows.
        var item: Int32
        var text: ContiguousArray<UInt8>
    }

    private final class Posting {
        var ids = ContiguousArray<UInt32>()
        /// How many of `ids` are rows gone.
        var dead = 0
        var live: Int { ids.count - dead }
    }

    private final class Slot {
        var tile: Tile
        var title = ContiguousArray<UInt8>()
        var ids: [UInt32] = []
        var rows: [Row] = []
        /// Each row's text as given, to compare the next with.
        var texts: [String] = []
        var signature: AnyHashable?
        init(_ tile: Tile) { self.tile = tile }
    }

    private var entries = ContiguousArray<Entry>()
    private var postings: [UInt32: Posting] = [:]
    private var slots: [Slot?] = []
    private var slotOf: [Tile: Int32] = [:]
    private var freeSlots: [Int32] = []
    /// Rows in it (not gone).
    public private(set) var count = 0
    /// How many times it was numbered again (for tests, and debugging).
    public private(set) var renumbered = 0

    public init() {}

    // MARK: Tiles

    /// What a tile's rows were made from, as last given (`update`): the
    /// same again, nothing need be done.
    public func signature(of tile: Tile) -> AnyHashable? { slotOf[tile].flatMap { slots[Int($0)]?.signature } }

    public func rows(of tile: Tile) -> [Row] { slotOf[tile].flatMap { slots[Int($0)]?.rows } ?? [] }

    public var tiles: [Tile] { slots.compactMap { $0?.tile } }

    /// A tile's title changed (what each of its rows is found by too).
    public func setTitle(_ tile: Tile, _ title: String) {
        guard let s = slotOf[tile], let slot = slots[Int(s)] else { return }
        let t = Self.lowered(title)
        if slot.title != t { slot.title = t }
    }

    /// A tile's rows as they are now, each found by `text(row)`: those
    /// unchanged at the head and the tail kept, the others taken out and
    /// put in.
    public func update(_ tile: Tile, title: String, rows: [Row], signature: AnyHashable?, text: (Row) -> String) {
        let s = slotIndex(for: tile)
        let slot = slots[Int(s)]!
        slot.title = Self.lowered(title)
        slot.signature = signature
        // Compared as given; only those between the same head and tail
        // lowercased and cut up.
        let fresh = rows.map(text)
        let old = slot.ids, was = slot.texts
        var head = 0
        while head < was.count, head < fresh.count, was[head] == fresh[head] { head += 1 }
        var tail = 0
        while tail < was.count - head, tail < fresh.count - head, was[was.count - 1 - tail] == fresh[fresh.count - 1 - tail] { tail += 1 }
        for id in old[head..<(old.count - tail)] { remove(id) }
        var ids = Array(old[0..<head])
        ids.reserveCapacity(fresh.count)
        for i in head..<(fresh.count - tail) { ids.append(add(Self.lowered(fresh[i]), slot: s)) }
        ids += old[(old.count - tail)...]
        if head < fresh.count - tail || old.count != fresh.count {
            for i in head..<ids.count { entries[Int(ids[i])].item = Int32(i) }
        }
        slot.ids = ids
        slot.rows = rows
        slot.texts = fresh
        renumberIfSparse()
    }

    /// A tile gone: its rows taken out.
    public func remove(tile: Tile) {
        guard let s = slotOf.removeValue(forKey: tile), let slot = slots[Int(s)] else { return }
        for id in slot.ids { remove(id) }
        slots[Int(s)] = nil
        freeSlots.append(s)
        renumberIfSparse()
    }

    /// Only these tiles kept.
    public func retain(_ keep: Set<Tile>) {
        for t in Array(slotOf.keys) where !keep.contains(t) { remove(tile: t) }
    }

    private func slotIndex(for tile: Tile) -> Int32 {
        if let s = slotOf[tile] { return s }
        let s: Int32
        if let free = freeSlots.popLast() {
            s = free
            slots[Int(s)] = Slot(tile)
        } else {
            s = Int32(slots.count)
            slots.append(Slot(tile))
        }
        slotOf[tile] = s
        return s
    }

    // MARK: Rows

    private func add(_ text: ContiguousArray<UInt8>, slot: Int32) -> UInt32 {
        let id = UInt32(entries.count)
        entries.append(Entry(slot: slot, item: 0, text: text))
        count += 1
        Self.forEachGram(text, &scratch) { g in
            if let p = postings[g] { p.ids.append(id) } else {
                let p = Posting()
                p.ids.append(id)
                postings[g] = p
            }
        }
        return id
    }

    private func remove(_ id: UInt32) {
        let i = Int(id)
        guard entries[i].slot >= 0 else { return }
        let text = entries[i].text
        entries[i].slot = -1
        entries[i].text = []
        count -= 1
        Self.forEachGram(text, &scratch) { g in
            guard let p = postings[g] else { return }
            p.dead += 1
            if p.dead == p.ids.count {
                postings[g] = nil
            } else if p.dead * 2 > p.ids.count {
                p.ids = p.ids.filter { entries[Int($0)].slot >= 0 }
                p.dead = 0
            }
        }
    }

    /// Numbered again, densely, once half the numbers are of rows gone.
    private func renumberIfSparse() {
        guard entries.count > 4096, entries.count > count * 2 else { return }
        renumbered += 1
        var fresh = ContiguousArray<Entry>()
        fresh.reserveCapacity(count)
        for slot in slots {
            guard let slot else { continue }
            for (i, id) in slot.ids.enumerated() {
                slot.ids[i] = UInt32(fresh.count)
                fresh.append(entries[Int(id)])
            }
        }
        entries = fresh
        postings = [:]
        for (id, e) in entries.enumerated() {
            Self.forEachGram(e.text, &scratch) { g in
                if let p = postings[g] { p.ids.append(UInt32(id)) } else {
                    let p = Posting()
                    p.ids.append(UInt32(id))
                    postings[g] = p
                }
            }
        }
    }

    // MARK: Finding

    /// The rows of these tiles (only that one, if given) holding every word
    /// of the query — in their own text or (`titles`) their tile's title —
    /// by tile, in the order given, each tile's in its own order. An empty
    /// query: all of them.
    public func find(_ query: String, in order: [Tile], only: Tile? = nil, titles: Bool = true) -> [(tile: Tile, items: [Int])] {
        let words = query.lowercased().split(whereSeparator: \.isWhitespace).map { ContiguousArray($0.utf8) }
        let shown = order.filter { only == nil || $0 == only }
        var position: [Int32: Int] = [:]
        for (i, t) in shown.enumerated() { if let s = slotOf[t] { position[s] = i } }
        if words.isEmpty {
            return shown.compactMap { t in slotOf[t].flatMap { slots[Int($0)] }.map { (t, Array(0..<$0.ids.count)) } }
        }
        // Which words each tile's title holds: its every row holds those.
        var titled: [Int32: [Bool]] = [:]
        for s in position.keys {
            let title = slots[Int(s)]!.title
            titled[s] = words.map { titles && Self.contains(title, $0) }
        }
        func holds(_ e: Entry, _ w: Int) -> Bool { titled[e.slot]![w] || Self.contains(e.text, words[w]) }

        // The word with the fewest rows to look at leads.
        var lead: (word: Int, lists: [Posting]?, cost: Int)?
        for (w, word) in words.enumerated() where word.count >= 3 {
            var lists: [Posting]? = []
            Self.forEachGram(word, &scratch) { g in
                if let p = postings[g] { lists?.append(p) } else { lists = nil }
            }
            var cost = lists.map { $0.map(\.live).min() ?? 0 } ?? 0
            for (s, t) in titled where t[w] { cost += slots[Int(s)]!.ids.count }
            if lead == nil || cost < lead!.cost { lead = (w, lists, cost) }
        }

        var found: [Int32: [Int32]] = [:]
        func take(_ id: UInt32) {
            let e = entries[Int(id)]
            guard e.slot >= 0, position[e.slot] != nil else { return }
            for w in words.indices where w != lead?.word { if !holds(e, w) { return } }
            found[e.slot, default: []].append(e.item)
        }
        if let lead {
            // Those of tiles whose title holds it: every row.
            for (s, t) in titled where t[lead.word] { for id in slots[Int(s)]!.ids { take(id) } }
            // The rest: on all its trigrams' lists, and confirmed.
            if var lists = lead.lists, !lists.isEmpty {
                lists.sort { $0.ids.count < $1.ids.count }
                var ids = lists[0].ids
                for p in lists.dropFirst() where !ids.isEmpty { ids = Self.intersect(ids, p.ids) }
                let word = words[lead.word]
                for id in ids {
                    let e = entries[Int(id)]
                    guard e.slot >= 0, titled[e.slot]?[lead.word] == false, Self.contains(e.text, word) else { continue }
                    take(id)
                }
            }
        } else {
            // Every word short: every row looked at.
            for s in position.keys { for id in slots[Int(s)]!.ids { take(id) } }
        }
        return shown.compactMap { t in
            guard let s = slotOf[t], var items = found[s] else { return nil }
            items.sort()
            return (t, items.map(Int.init))
        }
    }

    /// How well a row's text matches a query, for ranking what `find`
    /// found (higher first): the text exactly, its start, a word's start,
    /// in order word by word, anywhere, every word somewhere; nothing when
    /// it was found by its tile's title alone.
    public static func score(_ text: String, query: String) -> Int {
        let t = text.lowercased().trimmingCharacters(in: .whitespaces)
        let q = query.lowercased().trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return 0 }
        if t == q { return 600 }
        if t.hasPrefix(q) { return 520 }
        let words = t.split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init)
        if words.contains(where: { $0.hasPrefix(q) }) { return 500 }
        let asked = q.split(whereSeparator: \.isWhitespace).map(String.init)
        if asked.count > 1 {
            var i = 0
            let ordered = asked.allSatisfy { w in
                guard i < words.count, let j = words[i...].firstIndex(where: { $0.hasPrefix(w) }) else { return false }
                i = j + 1
                return true
            }
            if ordered { return 480 }
        }
        if t.contains(q) { return 400 }
        if asked.allSatisfy({ t.contains($0) }) { return 300 }
        return 0
    }

    // MARK: Parts

    private var scratch: [UInt32] = []

    private static func lowered(_ s: String) -> ContiguousArray<UInt8> { ContiguousArray(s.lowercased().utf8) }

    /// Each distinct trigram of a text's bytes, once.
    private static func forEachGram(_ text: ContiguousArray<UInt8>, _ scratch: inout [UInt32], _ body: (UInt32) -> Void) {
        guard text.count >= 3 else { return }
        scratch.removeAll(keepingCapacity: true)
        text.withUnsafeBufferPointer { b in
            var g = UInt32(b[0]) << 8 | UInt32(b[1])
            for i in 2..<b.count {
                g = (g << 8 | UInt32(b[i])) & 0xFF_FFFF
                scratch.append(g)
            }
        }
        scratch.sort()
        var last: UInt32 = .max
        for g in scratch where g != last {
            body(g)
            last = g
        }
    }

    /// Whether `text` holds `word`, byte for byte.
    static func contains(_ text: ContiguousArray<UInt8>, _ word: ContiguousArray<UInt8>) -> Bool {
        if word.isEmpty { return true }
        if word.count > text.count { return false }
        return text.withUnsafeBytes { t in
            word.withUnsafeBytes { w in memmem(t.baseAddress, t.count, w.baseAddress, w.count) != nil }
        }
    }

    /// The numbers in both sorted lists: each of the shorter's looked for in
    /// the longer from where the last was found, by exponential search.
    static func intersect(_ a: ContiguousArray<UInt32>, _ b: ContiguousArray<UInt32>) -> ContiguousArray<UInt32> {
        let (short, long) = a.count <= b.count ? (a, b) : (b, a)
        var out = ContiguousArray<UInt32>()
        out.reserveCapacity(short.count)
        var j = 0
        for x in short {
            guard j < long.count else { break }
            if long[j] < x {
                // Doubling steps until past it, then halving back.
                var lo = j, step = 1, hi = j + 1
                while hi < long.count, long[hi] < x {
                    lo = hi
                    step <<= 1
                    hi = lo + step
                }
                var l = lo + 1, r = min(hi, long.count)
                while l < r {
                    let m = (l + r) >> 1
                    if long[m] < x { l = m + 1 } else { r = m }
                }
                j = l
            }
            if j < long.count, long[j] == x {
                out.append(x)
                j += 1
            }
        }
        return out
    }
}
