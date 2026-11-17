import Testing
@testable import ManifoldCore

/// prism-markup's outline.rs tests.
struct OutlineTests {
    typealias O = Markup.Outline
    typealias Document = Markup.Document

    func doc(_ source: String) -> Document { Document.parse(source) }
    func shown(_ d: Document) -> [[Int]] { d.rows().map(\.path) }

    @Test func indentMakesAChildOfTheBlockBefore() {
        var d = doc("- a\n- b\n  - c\n- d\n")
        #expect(O.indent(&d, [1]) == [0, 0])
        #expect(d.toMarkdown() == "- a\n  - b\n    - c\n- d\n")
        #expect(O.indent(&d, [1]) == [0, 1])
        #expect(d.toMarkdown() == "- a\n  - b\n    - c\n  - d\n")
        #expect(O.indent(&d, [0]) == nil)
        #expect(O.indent(&d, [0, 0]) == nil)
        d = doc("para\n- item\n")
        #expect(O.indent(&d, [1]) == [0, 0])
        #expect(d.toMarkdown() == "- para\n  - item\n")
        #expect(O.indent(&d, [7]) == nil)
    }

    @Test func outdentGoesAfterTheParentsBranch() {
        var d = doc("- a\n  - b\n    - c\n  - d\n  - e\n- f\n")
        #expect(O.outdent(&d, [0, 0]) == [1])
        #expect(d.toMarkdown() == "- a\n  - d\n  - e\n- b\n  - c\n- f\n")
        #expect(O.outdent(&d, [0]) == nil)
    }

    @Test func outdentTakingFollowersTakesChildrenAndFollowersAlong() {
        var d = doc("- a\n  - b\n    - c\n  - d\n  - e\n- f\n")
        #expect(O.outdentTakingFollowers(&d, [0, 0]) == [1])
        #expect(d.toMarkdown() == "- a\n- b\n  - c\n  - d\n  - e\n- f\n")
        #expect(O.outdentTakingFollowers(&d, [0]) == nil)
        d = doc("- a\n\n  para\n  - b\n")
        #expect(O.outdentTakingFollowers(&d, [0, 0]) == [1])
        #expect(d.toMarkdown() == "- a\n\n- para\n  - b\n")
    }

    @Test func indentThenOutdentIsWhereItStarted() {
        let source = "- a\n- b\n  - c\n"
        var d = doc(source)
        let moved = O.indent(&d, [1])!
        #expect(O.outdent(&d, moved) == [1])
        #expect(d.toMarkdown() == source)
    }

    @Test func movingSwapsSiblingsAndLeavesBlankLinesInPlace() {
        var d = doc("- a\n  - a1\n\n- b\n- c\n")
        #expect(O.moveDown(&d, [0]) == [1])
        #expect(d.toMarkdown() == "- b\n\n- a\n  - a1\n- c\n")
        #expect(O.moveUp(&d, [1]) == [0])
        #expect(d.toMarkdown() == "- a\n  - a1\n\n- b\n- c\n")
        #expect(O.moveUp(&d, [0]) == nil)
        #expect(O.moveDown(&d, [2]) == nil)
    }

    @Test func removeInsertAndDuplicate() {
        var d = doc("- a\n  - a1\n- b\n")
        let taken = O.remove(&d, [0])!
        #expect(taken.children.count == 1)
        #expect(d.toMarkdown() == "- b\n")
        #expect(O.insert(&d, [1], taken) == [1])
        #expect(d.toMarkdown() == "- b\n- a\n  - a1\n")
        #expect(O.duplicate(&d, [1]) == [2])
        #expect(d.toMarkdown() == "- b\n- a\n  - a1\n- a\n  - a1\n")
        #expect(O.insert(&d, [9], .bullet("x")) == nil)
        #expect(O.remove(&d, [9]) == nil)
    }

    @Test func splitMakesTheNextBlockOfTheSameSort() {
        var d = doc("- hello world\n")
        #expect(O.split(&d, [0], 5) == [1])
        #expect(d.toMarkdown() == "- hello\n-  world\n")
        d = doc("+ [x] done\n1. one\n2. two\n# Title\n")
        #expect(O.split(&d, [0], 4) == [1])
        O.split(&d, [2], 3)
        O.split(&d, [5], 5)
        #expect(d.toMarkdown() == "+ [x] done\n+ [ ]\n1. one\n2. \n3. two\n# Title\n- \n")
        #expect(d.blocks[6].kind == .paragraph)
    }

    @Test func splitAtTheEndOfAParentMakesItsFirstChild() {
        var d = doc("- parent\n  - child\n")
        #expect(O.split(&d, [0], 6) == [0, 0])
        #expect(d.toMarkdown() == "- parent\n\n  - \n  - child\n")
        d.modify([0, 0]) { $0.text = "typed" }
        #expect(d.toMarkdown() == "- parent\n  - typed\n  - child\n")
        d = doc("- parent\n  - child\n")
        #expect(O.split(&d, [0], 3) == [0, 0])
        #expect(d.toMarkdown() == "- par\n  - ent\n  - child\n")
        d = doc("- parent\n  - child\n")
        d.blocks[0].folded = true
        #expect(O.split(&d, [0], 3) == [1])
        #expect(d.toMarkdown() == "- par\n  - child\n- ent\n")
    }

    @Test func rowsPutInBesideARow() {
        var d = doc("- a\n  - a1\n- b\n")
        #expect(O.insertRow(&d, [0], .below) == [1])
        d.modify([1]) { $0.text = "below" }
        #expect(O.insertRow(&d, [0], .above) == [0])
        d.modify([0]) { $0.text = "above" }
        #expect(O.insertRow(&d, [1], .child) == [1, 0])
        d.modify([1, 0]) { $0.text = "child" }
        #expect(d.toMarkdown() == "- above\n- a\n  - child\n  - a1\n- below\n- b\n")
        d = doc("+ [x] done\n")
        O.insertRow(&d, [0], .below)
        #expect(d.blocks[1].kind == .item(.init(marker: .bullet("+"), task: .open)))
    }

    @Test func rowsJoinedPromotedDemotedGrouped() {
        var d = doc("- one\n- two\n  - kid\n- three\n")
        #expect(O.joinNext(&d, [0], [1])! == ([0], 3))
        #expect(d.toMarkdown() == "- one two\n  - kid\n- three\n")
        #expect(O.promoteChildren(&d, [0]) == [0])
        #expect(d.toMarkdown() == "- one two\n- kid\n- three\n")
        #expect(O.demoteSiblings(&d, [0]) == [0])
        #expect(d.toMarkdown() == "- one two\n  - kid\n  - three\n")
        #expect(O.removeRowOnly(&d, [0]) != nil)
        #expect(d.toMarkdown() == "- kid\n- three\n")
        #expect(O.group(&d, [[0], [1]]) == [0])
        d.modify([0]) { $0.text = "g" }
        #expect(d.toMarkdown() == "- g\n  - kid\n  - three\n")
    }

    @Test func aRowAloneMovesAsALineOfIndentedText() {
        var d = doc("- alpha\n  - beta\n  - gamma\n- delta\n- epsilon\n")
        #expect(O.moveRowAlone(&d, [1], up: true) == [1])
        #expect(d.toMarkdown() == "- alpha\n  - beta\n- delta\n  - gamma\n- epsilon\n")
        d = doc("- a\n- b\n  - b1\n- c\n")
        #expect(O.moveRowAlone(&d, [1], up: false) == [1])
        #expect(d.toMarkdown() == "- a\n  - b1\n- b\n- c\n")
        #expect(O.moveRowAlone(&d, [0], up: true) == nil)
    }

    @Test func movingDownAtTheSameLevel() {
        var d = doc("- one\n  - two\n  - three\n- four\n")
        var rows = shown(d)
        #expect(O.moveDownKeepingLevel(&d, [0, 1], rows) == [1, 0])
        #expect(d.toMarkdown() == "- one\n  - two\n- four\n  - three\n")
        d = doc("- one\n  - two\n- four\n")
        rows = shown(d)
        #expect(O.moveDownKeepingLevel(&d, [1], rows) == nil)
    }

    @Test func movingPastTheRowShown() {
        var d = doc("- one\n  - two\n  - three\n- four\n")
        #expect(O.moveUpShown(&d, [0, 0], shown(d)) == [0])
        #expect(d.toMarkdown() == "- two\n- one\n  - three\n- four\n")
        d = doc("- one\n  - two\n  - three\n- four\n")
        #expect(O.moveDownShown(&d, [0, 1], shown(d)) == [2])
        #expect(d.toMarkdown() == "- one\n  - two\n- four\n- three\n")
        d = doc("- alpha\n  - beta\n  - gamma\n- delta\n")
        #expect(O.moveUpShown(&d, [1], shown(d)) == [0, 1])
        #expect(d.toMarkdown() == "- alpha\n  - beta\n  - delta\n  - gamma\n")
        d = doc("- alpha\n  - beta\n- delta\n- epsilon\n")
        #expect(O.moveDownShown(&d, [0], shown(d)) == [1])
        #expect(d.toMarkdown() == "- delta\n- alpha\n  - beta\n- epsilon\n")
        d = doc("- a\n- b\n  - b1\n")
        #expect(O.moveDownShown(&d, [0], shown(d)) == [0, 0])
        #expect(d.toMarkdown() == "- b\n  - a\n  - b1\n")
    }

    @Test func joinPutsTextOnTheRowBeforeAndKeepsChildren() {
        var d = doc("- a\n- b\n  - b1\n")
        #expect(O.joinWithPrevious(&d, [1])! == ([0], 1))
        #expect(d.toMarkdown() == "- ab\n  - b1\n")
        d = doc("- a\n  - b\n    - c\n  - d\n")
        #expect(O.joinWithPrevious(&d, [0, 0])! == ([0], 1))
        #expect(d.toMarkdown() == "- ab\n  - c\n  - d\n")
        d = doc("- a\n  - a1\n- b\n")
        #expect(O.joinWithPrevious(&d, [1])! == ([0, 0], 2))
        #expect(d.toMarkdown() == "- a\n  - a1b\n")
        #expect(O.joinWithPrevious(&d, [0]) == nil)
        d = doc("```\ncode\n```\n- a\n")
        #expect(O.joinWithPrevious(&d, [1]) == nil)
    }

    @Test func tasksToggle() {
        var d = doc("- plain\n+ [ ] open\n- [X] done\ntext\n")
        #expect(O.toggleTask(&d, [0]) == .open)
        #expect(O.toggleTask(&d, [1]) == .done("x"))
        #expect(O.toggleTask(&d, [2]) == .open)
        #expect(O.toggleTask(&d, [3]) == nil)
        #expect(d.toMarkdown() == "- [ ] plain\n+ [x] open\n- [ ] done\ntext\n")
    }

    @Test func changingKindKeepsTextAndRehomesChildren() {
        var d = doc("- title\n  - child\n- next\n")
        #expect(O.setKind(&d, [0], .heading(2)))
        #expect(d.toMarkdown() == "## title\n- child\n- next\n")
        #expect(O.setKind(&d, [0], .item(.init(marker: .bullet("-"), task: .open))))
        #expect(d.toMarkdown() == "- [ ] title\n- child\n- next\n")
    }

    @Test func orderedRunsRenumber() {
        var d = doc("3. a\n7. b\n- break\n1. c\n1. d\n")
        O.renumber(&d.blocks)
        #expect(d.toMarkdown() == "3. a\n4. b\n- break\n1. c\n2. d\n")
    }

    @Test func aHeadingHoldsItsSection() {
        let d = doc("# A\ntext\n## A1\n- item\n# B\n## B1\n")
        #expect(O.sectionLength(d, 0) == 4)
        #expect(O.sectionLength(d, 2) == 2)
        #expect(O.sectionLength(d, 1) == 1)
        #expect(O.sectionLength(d, 4) == 2)
        #expect(O.sectionLength(d, 99) == 1)
    }
}
