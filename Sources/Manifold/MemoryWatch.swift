import AppKit
import ManifoldCore

/// Watches the app's own footprint from a thread of its own, so a runaway
/// is caught even with the main thread stuck: past `sampleAt` it has the
/// system sample the process into the logs folder once (every thread's
/// stack, for finding the loop); past `giveUpAt` it ends the process,
/// which is a renderer — the server and its logs keep everything — and
/// says so in the log, rather than take the machine down.
enum MemoryWatch {
    /// In MB through MANIFOLD_MEMORY_SAMPLE_AT / MANIFOLD_MEMORY_GIVE_UP_AT, for trying it.
    static let sampleAt: UInt64 = ProcessInfo.processInfo.environment["MANIFOLD_MEMORY_SAMPLE_AT"].flatMap(UInt64.init).map { $0 << 20 } ?? 6 << 30
    static let giveUpAt: UInt64 = ProcessInfo.processInfo.environment["MANIFOLD_MEMORY_GIVE_UP_AT"].flatMap(UInt64.init).map { $0 << 20 } ?? 24 << 30
    private static var timer: DispatchSourceTimer?
    private static var sampled = false
    private static var lastLogged: UInt64 = 0

    static func start() {
        let queue = DispatchQueue(label: "com.manifold.memory-watch", qos: .utility)
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now() + 5, repeating: 5)
        t.setEventHandler { check() }
        t.resume()
        timer = t
    }

    /// The process's physical footprint, as Activity Monitor counts it.
    static var footprint: UInt64 {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count) }
        }
        return result == KERN_SUCCESS ? info.phys_footprint : 0
    }

    private static func check() {
        let now = footprint
        // A step of a gigabyte is worth a line in the log.
        if now / (1 << 30) != lastLogged / (1 << 30) {
            NSLog("memory: footprint %.1f GB", Double(now) / Double(1 << 30))
            lastLogged = now
        }
        if now > sampleAt, !sampled {
            sampled = true
            sample(now)
        }
        if now > giveUpAt {
            NSLog("memory: footprint %.1f GB — giving up; see %@", Double(now) / Double(1 << 30), Paths.logs.path)
            _exit(70)
        }
    }

    private static func sample(_ footprint: UInt64) {
        try? FileManager.default.createDirectory(at: Paths.logs, withIntermediateDirectories: true)
        let file = Paths.logs.appendingPathComponent("memory-sample.txt")
        NSLog("memory: footprint %.1f GB — sampling the process into %@", Double(footprint) / Double(1 << 30), file.path)
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/sample")
        p.arguments = ["\(getpid())", "3", "-file", file.path]
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        try? p.run()
    }
}
