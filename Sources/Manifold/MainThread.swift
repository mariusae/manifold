import Foundation

extension MainActor {
    /// `body` run as the main actor's, from code that's on the main thread
    /// but isn't marked so (a main-run-loop timer's or observer's block):
    /// checked by the thread, not by asking the Swift runtime which executor
    /// it's on — `assumeIsolated`'s check, which reads the thread's record
    /// of the job it's in, and crashed (EXC_BAD_ACCESS at 0x1e in
    /// swift_task_isMainExecutorImpl, from timers firing between jobs) when
    /// that record had been left pointing at nothing.
    static func unchecked<T>(_ body: @MainActor () throws -> T) rethrows -> T {
        precondition(Thread.isMainThread, "MainActor.unchecked off the main thread")
        return try withoutActuallyEscaping(body) { b in
            try unsafeBitCast(b, to: (() throws -> T).self)()
        }
    }
}
