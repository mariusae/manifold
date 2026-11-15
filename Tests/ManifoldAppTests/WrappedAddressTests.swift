import Testing
@testable import Manifold

// What starts the next line is taken as a broken address's rest only if
// it could be: an address's characters, and a mark only its middle has.
@Test func aBrokenAddressGoesOnOnlyIntoItsRest() {
    #expect(TerminalView.continuesAddress("om/doc/48ae5754-32b4-416a-a7f8-b671a63db589"))
    #expect(TerminalView.continuesAddress("ample.com/x?y=1"))
    #expect(TerminalView.continuesAddress("-b671a63db589"))     // a UUID's end
    #expect(!TerminalView.continuesAddress("and"))           // a word that follows
    #expect(!TerminalView.continuesAddress("Descriptor,"))
    #expect(!TerminalView.continuesAddress("(\"Demo:"))
    #expect(!TerminalView.continuesAddress(""))
}
