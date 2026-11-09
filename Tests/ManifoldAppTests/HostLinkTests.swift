import Testing
@testable import Manifold

// I-6, M14 (STATE-MACHINES.md): how a host stands after its link closed
// comes from why it closed.

@Test func aLinkGivenUpOnForSilenceIsNotAnsweringNotUnanswered() {
    // The heartbeat heard nothing: it had answered, it's not answering now.
    let (link, unanswered) = HostClient.afterClose(answered: true, silent: true, unanswered: 2)
    #expect(link == .unreachable("not answering"))
    // Not one more toward copying its server over again.
    #expect(unanswered == 0)
}

@Test func aLinkClosedBeforeTheHostAnsweredIsCounted() {
    #expect(HostClient.afterClose(answered: false, silent: false, unanswered: 2)
        == (.unreachable("the connection closed before the host answered"), 3))
    #expect(HostClient.afterClose(answered: true, silent: false, unanswered: 2) == (.unreachable(nil), 0))
}
