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

@Test func aChildEndedAtItsTimeoutTakesWhatItStartedWithIt() throws {
    // `sl` starts `hg.real` and waits on it: ended, only `sl` went, and
    // `hg.real` read on, alone, a repository's worth of memory.
    let started = Date()
    let r = try Child.run(["/bin/sh", "-c", "sleep 60 & echo $!; wait"], timeout: 1)
    #expect(Date().timeIntervalSince(started) < 10)
    let pid = try #require(Int32(String(decoding: r.output, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)))
    // Gone (or a zombie of no one's, a moment): signalled with its group.
    var gone = false
    for _ in 0..<50 where !gone {
        gone = kill(pid, 0) != 0
        if !gone { usleep(20_000) }
    }
    #expect(gone)
}

@Test func aChildIsEndedOnceItHasSaidAsMuchAsWanted() throws {
    // `yes` never ends on its own: asked for five lines, five come.
    let started = Date()
    let r = try Child.run(["/usr/bin/yes", "a"], timeout: 20, records: 5, separator: 0x0A)
    #expect(Date().timeIntervalSince(started) < 5)
    #expect(String(decoding: r.output, as: UTF8.self) == "a\na\na\na\na\n")
    #expect(r.status == 128 + 9)
    // Fewer than wanted: all of it, as it ends.
    let few = try Child.run(["/bin/sh", "-c", "printf 'a\\0b\\0'"], timeout: 10, records: 5)
    #expect(few.status == 0 && few.output.split(separator: 0).count == 2)
}

@Test func aChildNoLongerWantedIsEnded() throws {
    let started = Date()
    let r = try Child.run(["/bin/sleep", "30"], timeout: 30, cancelled: { Date().timeIntervalSince(started) > 0.5 })
    #expect(Date().timeIntervalSince(started) < 5)
    #expect(r.status == 128 + 9)
}
