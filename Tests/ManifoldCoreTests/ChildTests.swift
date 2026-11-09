import Foundation
import Testing
@testable import ManifoldCore

@Test func aChildsErrorsCanComeInWithItsOutput() throws {
    let both = try Child.run(["/bin/sh", "-c", "echo out; echo err >&2"], timeout: 10, errorsToOutput: true)
    #expect(both.status == 0)
    #expect(String(decoding: both.output, as: UTF8.self) == "out\nerr\n")
    let quiet = try Child.run(["/bin/sh", "-c", "echo out; echo err >&2"], timeout: 10, quiet: true)
    #expect(String(decoding: quiet.output, as: UTF8.self) == "out\n")
}

@Test func aChildsStatusIsAShells() throws {
    #expect(try Child.run(["/bin/sh", "-c", "exit 3"], timeout: 10).status == 3)
    // Ended by a signal: 128 and the signal, as a shell says.
    #expect(try Child.run(["/bin/sh", "-c", "kill -9 $$"], timeout: 10).status == 128 + 9)
}

@Test func aChildThatPrintsMoreThanAPipeHoldsIsReadToTheEnd() throws {
    // A megabyte, past the 64 KB a pipe holds: read as it comes, not left
    // to fill the pipe and hold the child up.
    let r = try Child.run(["/bin/sh", "-c", "head -c 1048576 /dev/zero"], timeout: 20, errorsToOutput: true)
    #expect(r.status == 0)
    #expect(r.output.count == 1 << 20)
}
