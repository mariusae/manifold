import AppKit
import Testing
import ManifoldCore
@testable import Manifold

private let host = HostID("h")
private func space(_ ulid: String, _ name: String, _ chosen: SpaceMark? = nil) -> (id: BlockID, name: String, chosen: SpaceMark?) {
    (BlockID(host: host, ulid: ulid), name, chosen)
}
private func letters(_ marks: [BlockID: SpaceMark], _ ulid: String) -> String? {
    marks[BlockID(host: host, ulid: ulid)]?.words
}

// Every badge is a symbol the system has.
@Test func everyBadgeIsASymbol() {
    for (name, symbol) in SpaceLook.badges {
        #expect(NSImage(systemSymbolName: symbol, accessibilityDescription: nil) != nil, "\(name): \(symbol)")
    }
    for (symbol, name) in SpaceLook.markSymbols {
        #expect(NSImage(systemSymbolName: symbol, accessibilityDescription: nil) != nil, "\(name): \(symbol)")
    }
}

// Spaces whose names begin alike: the one made first keeps the letter; the
// other takes another of its own, one letter while there is one.
@Test func spacesLettersAvoidEachOther() {
    let m = SpaceLook.marks([space("02", "~/src/scratch"), space("01", "~/src/server"), space("03", "manifold"), space("04", "~/src/manifold-linux")])
    #expect(letters(m, "01") == "S")
    #expect(letters(m, "02") == "C")   // scratch: its next consonant
    #expect(letters(m, "03") == "M")
    #expect(letters(m, "04") == "L")   // manifold-linux: its second word's initial
}

// A chosen mark is kept, and the automatic ones step round it.
@Test func chosenMarksComeFirst() {
    let m = SpaceLook.marks([space("01", "main"), space("02", "review", .letters("M")), space("03", "tools", .symbol("hammer"))])
    #expect(letters(m, "02") == "M")
    #expect(letters(m, "01") == "N")
    #expect(letters(m, "03") == "symbol:hammer")
}

// Single letters run out: then two.
@Test func twoLettersOnceOnesRunOut() {
    let m = SpaceLook.marks([space("01", "ab"), space("02", "ab"), space("03", "ab")])
    #expect(letters(m, "01") == "A")
    #expect(letters(m, "02") == "B")
    #expect(letters(m, "03") == "Ab")
}

@Test func marksAreOneOrTwo() {
    #expect(SpaceLook.isLetters("P"))
    #expect(SpaceLook.isLetters("PR"))
    #expect(!SpaceLook.isLetters("PRS"))
    #expect(!SpaceLook.isLetters("P R"))
    #expect(!SpaceLook.isLetters(""))
}

// A name with no letters in it keeps its first mark.
@Test func aNameWithoutLettersKeepsItsMark() {
    #expect(SpaceLook.letter(of: "~") == "~")
    #expect(SpaceLook.letter(of: "~/src/manifold") == "M")
}
