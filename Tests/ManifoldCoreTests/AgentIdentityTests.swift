import Foundation
import Testing
@testable import ManifoldCore

@Suite struct AgentIdentityTests {
    @Test func aNewAgentGetsAFreeNameAndTheLeastUsedColour() {
        let taken = AgentIdentity.Taken(names: ["Fern", "Juniper"], colors: [0, 1])
        for seed in UInt64(0)..<50 {
            let (name, color) = AgentIdentity.choose(taken: taken, seed: seed)
            #expect(!taken.names.contains(name))
            // A free initial while there are some.
            #expect(name.first != "F" && name.first != "J")
            #expect(color >= 2 && color < AgentIdentity.colors)
        }
    }

    @Test func coloursGoRoundOnceEachIsUsed() {
        let taken = AgentIdentity.Taken(names: [], colors: Array(0..<AgentIdentity.colors) + [3])
        let (_, color) = AgentIdentity.choose(taken: taken, seed: 9)
        #expect(color != 3)
    }

    @Test func everyNameTakenStillGivesOne() {
        let taken = AgentIdentity.Taken(names: Set(AgentIdentity.names), colors: [])
        let (name, _) = AgentIdentity.choose(taken: taken, seed: 1)
        #expect(!taken.names.contains(name) && !name.isEmpty)
    }

    @Test func namesAreUnique() {
        #expect(Set(AgentIdentity.names).count == AgentIdentity.names.count)
    }
}
