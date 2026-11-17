import Foundation

// Outline editing: the commands an outliner gives, on a `Document`.
//
// Every command names its block by path — an index at each level,
// outermost first, as `Document.rows` gives them — and answers with the
// path the block has afterwards. A command that cannot be done changes
// nothing and answers nil. One rule runs through all of them: a block takes
// its children with it.

extension Markup {
    /// A block's place in a document.
    public typealias Path = [Int]

    public enum Outline {
        /// Where a new, empty row goes, beside a row.
        public enum Beside: Equatable, Sendable {
            /// After the row's whole branch.
            case below
            /// Before it.
            case above
            /// Its first child.
            case child
        }

        /// Makes a block the last child of the block before it.
        @discardableResult
        public static func indent(_ document: inout Document, _ path: [Int]) -> Path? {
            guard let index = path.last, index != 0 else { return nil }
            let parent = Array(path.dropLast())
            return document.modifySiblings(path) { siblings -> Path? in
                guard index < siblings.count, siblings[index - 1].canHaveChildren else { return nil }
                let block = siblings.remove(at: index)
                siblings[index - 1].children.append(block)
                return parent + [index - 1, siblings[index - 1].children.count - 1]
            } ?? nil
        }

        /// Moves a block out a level, children and all, to just after its
        /// parent's whole branch. The siblings that followed it stay under
        /// the parent — as Bike 2 does.
        @discardableResult
        public static func outdent(_ document: inout Document, _ path: [Int]) -> Path? {
            guard path.count >= 2, let index = path.last else { return nil }
            let parentPath = Array(path.dropLast())
            let parentIndex = parentPath[parentPath.count - 1]
            guard let block = document.modify(parentPath, { parent -> Block? in
                index < parent.children.count ? parent.children.remove(at: index) : nil
            }) ?? nil else { return nil }
            var moved = parentPath
            moved[moved.count - 1] = parentIndex + 1
            document.modifySiblings(parentPath) { $0.insert(block, at: parentIndex + 1) }
            return moved
        }

        /// Moves a block out a level, to just after its parent, the siblings
        /// that followed it coming under it. When it cannot hold them they
        /// stay where they were.
        @discardableResult
        public static func outdentTakingFollowers(_ document: inout Document, _ path: [Int]) -> Path? {
            guard path.count >= 2, let index = path.last else { return nil }
            let parentPath = Array(path.dropLast())
            let parentIndex = parentPath[parentPath.count - 1]
            guard let block = document.modify(parentPath, { parent -> Block? in
                guard index < parent.children.count else { return nil }
                var followers: [Block] = []
                if parent.children[index].canHaveChildren {
                    followers = Array(parent.children[(index + 1)...])
                    parent.children.removeSubrange((index + 1)...)
                }
                var block = parent.children.remove(at: index)
                block.children.append(contentsOf: followers)
                return block
            }) ?? nil else { return nil }
            var moved = parentPath
            moved[moved.count - 1] = parentIndex + 1
            document.modifySiblings(parentPath) { $0.insert(block, at: parentIndex + 1) }
            return moved
        }

        /// Swaps a block with the sibling before it.
        @discardableResult
        public static func moveUp(_ document: inout Document, _ path: [Int]) -> Path? {
            guard let index = path.last else { return nil }
            return document.modifySiblings(path) { siblings -> Path? in
                guard index > 0, index < siblings.count else { return nil }
                siblings.swapAt(index, index - 1)
                carryGap(&siblings, index - 1, index)
                return Array(path.dropLast()) + [index - 1]
            } ?? nil
        }

        /// Swaps a block with the sibling after it.
        @discardableResult
        public static func moveDown(_ document: inout Document, _ path: [Int]) -> Path? {
            guard let index = path.last else { return nil }
            return document.modifySiblings(path) { siblings -> Path? in
                guard index + 1 < siblings.count else { return nil }
                siblings.swapAt(index, index + 1)
                carryGap(&siblings, index, index + 1)
                return Array(path.dropLast()) + [index + 1]
            } ?? nil
        }

        /// After a swap, the blank lines stay where they were on the page.
        static func carryGap(_ siblings: inout [Block], _ first: Int, _ second: Int) {
            let gap = siblings[first].layout.gap
            siblings[first].layout.gap = siblings[second].layout.gap
            siblings[second].layout.gap = gap
        }

        /// Takes a block out, children and all, and gives it back.
        @discardableResult
        public static func remove(_ document: inout Document, _ path: [Int]) -> Block? {
            guard let index = path.last else { return nil }
            return document.modifySiblings(path) { siblings -> Block? in
                index >= 0 && index < siblings.count ? siblings.remove(at: index) : nil
            } ?? nil
        }

        /// Puts a block in at a path, moving what was there (and after) down.
        @discardableResult
        public static func insert(_ document: inout Document, _ path: [Int], _ block: Block) -> Path? {
            guard let index = path.last else { return nil }
            return document.modifySiblings(path) { siblings -> Path? in
                guard index >= 0, index <= siblings.count else { return nil }
                siblings.insert(block, at: index)
                return path
            } ?? nil
        }

        /// Puts a copy of a block, children and all, straight after it.
        @discardableResult
        public static func duplicate(_ document: inout Document, _ path: [Int]) -> Path? {
            guard let index = path.last else { return nil }
            return document.modifySiblings(path) { siblings -> Path? in
                guard index < siblings.count else { return nil }
                var copy = siblings[index]
                copy.layout.gap = []
                // A copy is another block: it has no name until it is given one.
                func unnamed(_ block: inout Block) {
                    block.anchor = nil
                    for i in block.children.indices { unnamed(&block.children[i]) }
                }
                unnamed(&copy)
                siblings.insert(copy, at: index + 1)
                return Array(path.dropLast()) + [index + 1]
            } ?? nil
        }

        /// Splits a block's text at a byte offset — what Return does. The
        /// text after it becomes a new block of the sort that follows. At the
        /// end of a block with children, the new block is its first child;
        /// otherwise it follows the block, the children staying with the first.
        @discardableResult
        public static func split(_ document: inout Document, _ path: [Int], _ offset: Int) -> Path? {
            guard let block = document.get(path) else { return nil }
            let text = block.text.u8
            guard offset <= text.count, text.isBoundary(offset), block.splits else { return nil }
            var new = Block(nextKind(block.kind), text.sub(from: offset).string)
            new.layout.spacing = max(block.layout.spacing, 1)
            let head = text.sub(0..<offset).string
            // Under a parent whose children are shown, the new row is its
            // first child. Under a folded one it comes after the whole branch.
            if !block.children.isEmpty && block.isItem && !block.folded {
                document.modify(path) { $0.text = head; $0.children.insert(new, at: 0) }
                return path + [0]
            }
            guard let index = path.last else { return nil }
            document.modify(path) { $0.text = head }
            document.modifySiblings(path) { siblings in
                siblings.insert(new, at: index + 1)
                renumber(&siblings)
            }
            return Array(path.dropLast()) + [index + 1]
        }

        /// The sort of row that follows a row of this sort: a bullet after a
        /// bullet, an open task after any task, the next number after a
        /// numbered item, a plain line after a heading.
        public static func nextKind(_ kind: BlockKind) -> BlockKind {
            switch kind {
            case .item(let item):
                var marker = item.marker
                if case .ordered(let number, let delimiter) = marker { marker = .ordered(number: number + 1, delimiter: delimiter) }
                return .item(Item(marker: marker, task: item.task.map { _ in .open }))
            case .heading: return .paragraph
            default: return kind
            }
        }

        /// Puts a new, empty row beside a row, of the sort that follows it. A
        /// row that cannot hold children gets the new row below it instead.
        @discardableResult
        public static func insertRow(_ document: inout Document, _ path: [Int], _ beside: Beside) -> Path? {
            guard let block = document.get(path) else { return nil }
            let kind: BlockKind
            switch block.kind {
            case .paragraph, .heading, .item, .quote: kind = nextKind(block.kind)
            default: kind = .item(Item(marker: .bullet("-"), task: nil))
            }
            var new = Block(kind, "")
            new.layout.spacing = max(block.layout.spacing, 1)
            if beside == .child && block.canHaveChildren {
                document.modify(path) { $0.folded = false; $0.children.insert(new, at: 0) }
                return path + [0]
            }
            guard let index = path.last else { return nil }
            let at = beside == .above ? index : index + 1
            document.modifySiblings(path) { siblings in
                siblings.insert(new, at: at)
                renumber(&siblings)
            }
            return Array(path.dropLast()) + [at]
        }

        /// Joins the row after a row into it, a space between their words.
        /// Its children come under the joined row. Answers the row and where
        /// the two meet.
        @discardableResult
        public static func joinNext(_ document: inout Document, _ path: [Int], _ next: [Int]) -> (Path, Int)? {
            guard let this = document.get(path)?.text.u8, let that = document.get(next)?.text.u8 else { return nil }
            let space = !this.isEmpty && !that.isEmpty && !(this.scalar(before: this.count)?.isWS ?? false) && !(that.scalar(at: 0)?.isWS ?? false)
            guard let (onto, offset) = joinOnto(&document, next, path) else { return nil }
            if space {
                document.modify(onto) { block in
                    var t = block.text.u8
                    t.insert(.space, at: offset)
                    block.text = t.string
                }
            }
            return (onto, offset)
        }

        /// A row's children made the siblings that follow it.
        @discardableResult
        public static func promoteChildren(_ document: inout Document, _ path: [Int]) -> Path? {
            guard let index = path.last, let block = document.get(path), !block.children.isEmpty else { return nil }
            document.modify(path) { $0.folded = false; $0.children = [] }
            document.modifySiblings(path) { siblings in
                siblings.insert(contentsOf: block.children, at: index + 1)
                renumber(&siblings)
            }
            return path
        }

        /// The siblings that follow a row made its last children.
        @discardableResult
        public static func demoteSiblings(_ document: inout Document, _ path: [Int]) -> Path? {
            guard let index = path.last, let block = document.get(path), block.canHaveChildren else { return nil }
            guard let followers = document.modifySiblings(path, { siblings -> [Block]? in
                guard index + 1 < siblings.count else { return nil }
                let followers = Array(siblings[(index + 1)...])
                siblings.removeSubrange((index + 1)...)
                return followers
            }) ?? nil else { return nil }
            document.modify(path) { $0.folded = false; $0.children.append(contentsOf: followers) }
            return path
        }

        /// A row taken out, its children taking its place.
        @discardableResult
        public static func removeRowOnly(_ document: inout Document, _ path: [Int]) -> Block? {
            guard let index = path.last else { return nil }
            return document.modifySiblings(path) { siblings -> Block? in
                guard index < siblings.count else { return nil }
                var block = siblings.remove(at: index)
                let children = block.children
                block.children = []
                siblings.insert(contentsOf: children, at: index)
                renumber(&siblings)
                return block
            } ?? nil
        }

        /// Rows — siblings, in order — put under a new, empty row put where
        /// the first was. Answers the new row's path.
        @discardableResult
        public static func group(_ document: inout Document, _ paths: [Path]) -> Path? {
            guard let first = paths.first, !first.isEmpty else { return nil }
            let parent = Array(first.dropLast())
            if paths.contains(where: { Array($0.dropLast()) != parent }) { return nil }
            let indexes = paths.map { $0[$0.count - 1] }.sorted()
            return document.modifySiblings(first) { siblings -> Path? in
                var taken: [Block] = []
                for index in indexes.reversed() { taken.append(siblings.remove(at: index)) }
                taken.reverse()
                var new = Block(.item(Item(marker: .bullet("-"), task: nil)), "")
                new.layout.spacing = 1
                new.children = taken
                siblings.insert(new, at: indexes[0])
                renumber(&siblings)
                return parent + [indexes[0]]
            } ?? nil
        }

        /// Moves a row, with its branch, past the row shown before it,
        /// taking that row's level. `shown` is every row shown, in order.
        @discardableResult
        public static func moveUpShown(_ document: inout Document, _ path: [Int], _ shown: [Path]) -> Path? {
            guard let at = shown.firstIndex(of: path), at >= 1 else { return nil }
            let before = shown[at - 1]
            guard let block = remove(&document, path) else { return nil }
            // Taking the row out moved nothing before it: `before` still leads there.
            guard insert(&document, before, block) != nil else { return nil }
            guard document.modifySiblings(before, { renumber(&$0) }) != nil else { return nil }
            return before
        }

        /// Moves a row, with its branch, past the row shown after its branch,
        /// so that that row is shown just before it.
        @discardableResult
        public static func moveDownShown(_ document: inout Document, _ path: [Int], _ shown: [Path]) -> Path? {
            guard let at = shown.firstIndex(of: path) else { return nil }
            guard var next = shown[(at + 1)...].first(where: { !$0.starts(with: path) }) else { return nil }
            guard let block = remove(&document, path) else { return nil }
            // The row after shifts up a place if it shared the moved row's list, after it.
            let d = path.count - 1
            if next.count >= path.count && Array(next[..<d]) == Array(path[..<d]) && next[d] > path[d] { next[d] -= 1 }
            guard let target = document.get(next) else { return nil }
            var to: Path
            if !target.children.isEmpty && !target.folded && target.canHaveChildren {
                to = next + [0]
            } else {
                to = next
                to[to.count - 1] += 1
            }
            guard insert(&document, to, block) != nil else { return nil }
            guard document.modifySiblings(to, { renumber(&$0) }) != nil else { return nil }
            return to
        }

        /// Moves a row down at its level: past the sibling after it; a last
        /// child, into the row shown after its parent's branch, as its first
        /// child — so it keeps its level, as Bike's does.
        @discardableResult
        public static func moveDownKeepingLevel(_ document: inout Document, _ path: [Int], _ shown: [Path]) -> Path? {
            if let moved = moveDown(&document, path) { return moved }
            guard let at = shown.firstIndex(of: path) else { return nil }
            guard let next = shown[(at + 1)...].first(where: { !$0.starts(with: path) }) else { return nil }
            guard next.count + 1 == path.count, document.get(next)?.canHaveChildren == true else { return nil }
            guard let block = remove(&document, path) else { return nil }
            document.modify(next) { $0.folded = false; $0.children.insert(block, at: 0) }
            return next + [0]
        }

        /// Moves a row alone a line up or down, as a line of indented text
        /// moves: it keeps its level, and the rows around it are put under
        /// whichever row then stands above them. A folded row's hidden rows
        /// go with it.
        @discardableResult
        public static func moveRowAlone(_ document: inout Document, _ path: [Int], up: Bool) -> Path? {
            // The rows as lines: each with its level, without its shown children.
            var lines: [(Int, Block, Path)] = []
            var at: Path = []
            func flatten(_ blocks: [Block], _ level: Int) {
                for (index, block) in blocks.enumerated() {
                    at.append(index)
                    var alone = block
                    if !block.folded { alone.children = [] }
                    lines.append((level, alone, at))
                    if !block.folded { flatten(block.children, level + 1) }
                    at.removeLast()
                }
            }
            flatten(document.blocks, 0)
            guard let index = lines.firstIndex(where: { $0.2 == path }) else { return nil }
            let other = up ? index - 1 : index + 1
            guard other >= 0, other < lines.count else { return nil }
            lines.swapAt(index, other)
            // Rebuilt: each line under the last line before it one level up.
            var blocks: [Block] = []
            var previous: Int? = nil
            var moved: Path = []
            func place(_ list: inout [Block], _ remaining: Int, _ at: inout Path, _ block: Block) {
                if remaining > 0, let last = list.indices.last, list[last].canHaveChildren {
                    at.append(last)
                    place(&list[last].children, remaining - 1, &at, block)
                } else {
                    at.append(list.count)
                    list.append(block)
                }
            }
            for (position, line) in lines.enumerated() {
                let level = min(line.0, previous.map { $0 + 1 } ?? 0)
                var at: Path = []
                place(&blocks, level, &at, line.1)
                previous = at.count - 1
                if position == other { moved = at }
            }
            document.blocks = blocks
            renumber(&document.blocks)
            return moved
        }

        /// Opens an empty block above a block — what Return does at the start
        /// of a block's words, which stay where the caret is. Answers the path
        /// the block itself then has.
        @discardableResult
        public static func openAbove(_ document: inout Document, _ path: [Int]) -> Path? {
            guard let block = document.get(path) else { return nil }
            let kind: BlockKind
            switch block.kind {
            case .item(let item): kind = .item(Item(marker: item.marker, task: item.task.map { _ in .open }))
            case .heading: kind = .paragraph
            case .paragraph, .quote: kind = block.kind
            default: return nil
            }
            var new = Block(kind, "")
            new.layout.spacing = max(block.layout.spacing, 1)
            new.layout.gap = block.layout.gap
            guard let index = path.last else { return nil }
            document.modify(path) { $0.layout.gap = [] }
            document.modifySiblings(path) { siblings in
                siblings.insert(new, at: index)
                renumber(&siblings)
            }
            return Array(path.dropLast()) + [index + 1]
        }

        /// Joins a block's text onto the block before it in reading order —
        /// what Delete does at a block's start.
        @discardableResult
        public static func joinWithPrevious(_ document: inout Document, _ path: [Int]) -> (Path, Int)? {
            let rows = document.rows()
            guard let position = rows.firstIndex(where: { $0.path == path }), position >= 1 else { return nil }
            return joinOnto(&document, path, rows[position - 1].path)
        }

        /// Joins a block's text onto a block before it. Its children are
        /// kept, under whichever block now stands where it stood; a folded
        /// block they come under is unfolded.
        @discardableResult
        public static func joinOnto(_ document: inout Document, _ path: [Int], _ target: [Int]) -> (Path, Int)? {
            func joinable(_ kind: BlockKind) -> Bool {
                switch kind {
                case .paragraph, .heading, .item, .quote: return true
                default: return false
                }
            }
            guard target.lexicographicallyPrecedes(path), let this = document.get(path), joinable(this.kind),
                  let onto = document.get(target), joinable(onto.kind) else { return nil }
            guard let block = remove(&document, path), let index = path.last else { return nil }
            let parent = Array(path.dropLast())
            // Where the children go: in the block's place when it was a first
            // child; else under the sibling that came before it.
            if index == 0 {
                document.modifySiblings(path) { $0.insert(contentsOf: block.children, at: 0) }
            } else {
                let previousPath = parent + [index - 1]
                guard let previous = document.get(previousPath) else { return nil }
                if previous.canHaveChildren {
                    document.modify(previousPath) { previous in
                        previous.folded = previous.folded && block.children.isEmpty
                        previous.children.append(contentsOf: block.children)
                    }
                } else {
                    document.modifySiblings(path) { $0.insert(contentsOf: block.children, at: index) }
                }
            }
            guard let offset = document.modify(target, { onto -> Int in
                let offset = onto.text.utf8.count
                onto.text += block.text
                return offset
            }) else { return nil }
            return (target, offset)
        }

        /// Checks a task off, or opens it again; a list item with no checkbox
        /// gets an open one. Answers the new state.
        @discardableResult
        public static func toggleTask(_ document: inout Document, _ path: [Int]) -> Task? {
            document.modify(path) { block -> Task? in
                guard case .item(var item) = block.kind else { return nil }
                let next: Task = item.task == .open ? .done("x") : .open
                item.task = next
                block.kind = .item(item)
                return next
            } ?? nil
        }

        /// Makes a block another kind, keeping its text. A list item made
        /// something that cannot hold children hands them to the list it is
        /// in, straight after it.
        @discardableResult
        public static func setKind(_ document: inout Document, _ path: [Int], _ kind: BlockKind) -> Bool {
            guard let index = path.last else { return false }
            guard let children = document.modify(path, { block -> [Block] in
                block.kind = kind
                block.layout.spacing = max(block.layout.spacing, 1)
                if !block.canHaveChildren && !block.children.isEmpty {
                    block.folded = false
                    let children = block.children
                    block.children = []
                    return children
                }
                return []
            }) else { return false }
            if !children.isEmpty { document.modifySiblings(path) { $0.insert(contentsOf: children, at: index + 1) } }
            return true
        }

        /// Numbers each run of ordered items in a list from its first item's
        /// number on.
        public static func renumber(_ siblings: inout [Block]) {
            var next: Int? = nil
            for i in siblings.indices {
                if case .item(var item) = siblings[i].kind, case .ordered(let number, let delimiter) = item.marker {
                    let n = next ?? number
                    if n != number {
                        item.marker = .ordered(number: n, delimiter: delimiter)
                        siblings[i].kind = .item(item)
                    }
                    next = n + 1
                } else {
                    next = nil
                }
            }
        }

        /// How many top-level blocks a heading's section takes, the heading
        /// included. One for a block that is no heading.
        public static func sectionLength(_ document: Document, _ index: Int) -> Int {
            guard index < document.blocks.count, case .heading(let level) = document.blocks[index].kind else { return 1 }
            var n = 1
            for block in document.blocks[(index + 1)...] {
                if case .heading(let other) = block.kind, other <= level { break }
                n += 1
            }
            return n
        }
    }
}
