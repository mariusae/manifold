import CPTY
import Foundation
import ManifoldCore

/// The machine view's readings (§7.5): every two seconds the cheap part —
/// cores, memory, network and disks — kept for five minutes as history;
/// the processes read only when asked, their CPU over the time since they
/// were last read. macOS's from the kernel (machine.c), Linux's from /proc.
final class MachineSampler {
    private let queue = DispatchQueue(label: "manifoldd.machine", qos: .utility)
    private var timer: DispatchSourceTimer?
    private var last: Reading?
    private var previous: Reading?
    private var history: [MachinePoint] = []
    private var processTimes: (at: Double, cpu: [Int32: Double])?
    private var lastProcesses: (at: Double, list: [MachineProcess])?
    private var users: [UInt32: String] = [:]
    private lazy var fixed = Fixed.read()
    static let interval: Double = 2
    static let kept: Double = 300

    /// A reading of the counters: each since the machine started.
    struct Reading {
        var at: Double
        var cores: [CoreTicks]
        var memory: MachineMemory
        var netIn: UInt64
        var netOut: UInt64
        var diskRead: UInt64
        var diskWrite: UInt64
        var loads: [Double]
    }

    /// What doesn't change while it runs.
    struct Fixed {
        var hostname: String
        var system: String
        var processor: String
        static func read() -> Fixed {
            var name = [CChar](repeating: 0, count: 256)
            gethostname(&name, name.count)
            let hostname = String(cString: name)
            #if os(macOS)
            let v = ProcessInfo.processInfo.operatingSystemVersion
            let system = "macOS \(v.majorVersion).\(v.minorVersion)" + (v.patchVersion > 0 ? ".\(v.patchVersion)" : "")
            let processor = sysctlString("machdep.cpu.brand_string") ?? "Processor"
            #else
            var u = utsname()
            uname(&u)
            let kernel = withUnsafeBytes(of: &u.release) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
            let release = (try? String(contentsOfFile: "/etc/os-release", encoding: .utf8)).flatMap(LinuxProc.release)
            let system = (release.map { $0 + " · " } ?? "") + "Linux " + kernel
            let processor = (try? String(contentsOfFile: "/proc/cpuinfo", encoding: .utf8)).flatMap { LinuxProc.processor($0).name } ?? "Processor"
            #endif
            return Fixed(hostname: hostname, system: system, processor: processor)
        }
    }

    func start() {
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now(), repeating: Self.interval, leeway: .milliseconds(200))
        t.setEventHandler { [weak self] in self?.tick() }
        t.resume()
        timer = t
    }

    /// Read, and kept: the history's point for it.
    private func tick() {
        guard let r = Self.read() else { return }
        previous = last
        last = r
        guard let p = previous, let point = Self.point(p, r) else { return }
        history.append(point)
        let cutoff = r.at - Self.kept
        if let i = history.firstIndex(where: { $0.at >= cutoff }), i > 0 { history.removeFirst(i) }
    }

    /// The machine as asked; on its own queue, answered there.
    func sample(_ q: MachineQuery, shells: [(BlockID, Int32)], done: @escaping (MachineSample?) -> Void) {
        queue.async { [self] in
            // Just started: two readings, a moment apart, for rates.
            if previous == nil {
                if last == nil { tick() }
                Thread.sleep(forTimeInterval: 0.4)
                tick()
            }
            guard let r = last, let p = previous, let now = Self.point(p, r) else { return done(nil) }
            let all = processes(shells: shells)
            var (shown, matching) = q.apply(all)
            for i in shown.indices { shown[i].command = Self.command(shown[i].pid) ?? shown[i].name }
            let cores = zip(p.cores, r.cores).map { CoreTicks.busy($0, $1).busy }
            var uptime: Double = 0
            #if os(macOS)
            var boot = timeval()
            var size = MemoryLayout<timeval>.size
            if sysctlbyname("kern.boottime", &boot, &size, nil, 0) == 0 { uptime = r.at - Double(boot.tv_sec) }
            let ghz: Double? = nil
            #else
            uptime = (try? String(contentsOfFile: "/proc/uptime", encoding: .utf8)).flatMap { $0.split(separator: " ").first.flatMap { Double($0) } } ?? 0
            let ghz = (try? String(contentsOfFile: "/proc/cpuinfo", encoding: .utf8)).flatMap { LinuxProc.processor($0).ghz }
            #endif
            let since = q.since ?? 0
            done(MachineSample(at: r.at, hostname: fixed.hostname, system: fixed.system, processor: fixed.processor, frequency: ghz, uptime: uptime,
                               cores: cores, now: now, loads: r.loads, memory: r.memory, disks: Self.disks(),
                               netInTotal: r.netIn, netOutTotal: r.netOut, processes: shown, processCount: all.count, matching: matching,
                               history: history.filter { $0.at > since }))
        }
    }

    /// The rates between two readings.
    static func point(_ a: Reading, _ b: Reading) -> MachinePoint? {
        let dt = b.at - a.at
        guard dt > 0.05 else { return nil }
        let all = { (cores: [CoreTicks]) in cores.reduce(CoreTicks(busy: 0, system: 0, total: 0)) { CoreTicks(busy: $0.busy + $1.busy, system: $0.system + $1.system, total: $0.total + $1.total) } }
        let cpu = CoreTicks.busy(all(a.cores), all(b.cores))
        func rate(_ x: UInt64, _ y: UInt64) -> Double { y >= x ? Double(y - x) / dt : 0 }
        return MachinePoint(at: b.at, cpu: cpu.busy, system: cpu.system, memory: b.memory.usedFraction,
                            netIn: rate(a.netIn, b.netIn), netOut: rate(a.netOut, b.netOut),
                            diskRead: rate(a.diskRead, b.diskRead), diskWrite: rate(a.diskWrite, b.diskWrite), load: b.loads.first ?? 0)
    }

    // MARK: Processes

    /// Every process, its CPU since they were last read (none, at first:
    /// read twice, a moment apart). Read again no more than each second —
    /// more than one view asking share it.
    private func processes(shells: [(BlockID, Int32)]) -> [MachineProcess] {
        let now = Date().timeIntervalSince1970
        if let l = lastProcesses, now - l.at < 1 { return Self.tag(l.list, shells: shells) }
        if processTimes == nil || now - processTimes!.at > 30 {
            processTimes = (now, Self.readProcesses(users: &users).times)
            Thread.sleep(forTimeInterval: 0.3)
        }
        let at = Date().timeIntervalSince1970
        var (list, times) = Self.readProcesses(users: &users)
        if let before = processTimes {
            let dt = max(at - before.at, 0.05)
            for i in list.indices {
                let pid = list[i].pid
                if let t = times[pid], let b = before.cpu[pid], list[i].cpu < 0 { list[i].cpu = max(0, (t - b) / dt * 100) }
            }
        }
        for i in list.indices where list[i].cpu < 0 { list[i].cpu = 0 }
        processTimes = (at, times)
        lastProcesses = (at, list)
        return Self.tag(list, shells: shells)
    }

    /// Each process under a terminal's or agent's shell, given its block.
    static func tag(_ list: [MachineProcess], shells: [(BlockID, Int32)]) -> [MachineProcess] {
        guard !shells.isEmpty else { return list }
        let parent = Dictionary(list.map { ($0.pid, $0.parent) }, uniquingKeysWith: { a, _ in a })
        let shell = Dictionary(shells.map { ($0.1, $0.0) }, uniquingKeysWith: { a, _ in a })
        var memo: [Int32: BlockID?] = [:]
        func block(_ pid: Int32, _ depth: Int) -> BlockID? {
            if let b = shell[pid] { return b }
            if let m = memo[pid] { return m }
            guard depth < 64, let p = parent[pid], p > 1, p != pid else { return nil }
            let b = block(p, depth + 1)
            memo[pid] = b
            return b
        }
        return list.map { var p = $0; p.block = block(p.pid, 0); return p }
    }

    /// The processes, and the CPU time (seconds) each has had; a process's
    /// `cpu` is -1 until worked out from two readings (macOS's for another
    /// user's, which can't be timed, comes from `ps`).
    static func readProcesses(users: inout [UInt32: String]) -> (list: [MachineProcess], times: [Int32: Double]) {
        var list: [MachineProcess] = []
        var times: [Int32: Double] = [:]
        func user(_ uid: UInt32) -> String {
            if let u = users[uid] { return u }
            let name = getpwuid(uid).map { String(cString: $0.pointee.pw_name) } ?? String(uid)
            users[uid] = name
            return name
        }
        #if os(macOS)
        var buf = [mf_process](repeating: mf_process(), count: 16384)
        let n = Int(mf_processes(&buf, Int32(buf.count)))
        var unknown = false
        for p in buf.prefix(max(n, 0)) {
            let name = withUnsafeBytes(of: p.name) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
            list.append(MachineProcess(pid: p.pid, parent: p.ppid, user: user(p.uid), name: name, command: name, cpu: -1,
                                       memory: p.rss, threads: p.known != 0 ? Int(p.threads) : nil))
            if p.known != 0 { times[p.pid] = Double(p.cpu_ns) / 1e9 } else { unknown = true }
        }
        // Another user's (root's): ps may read them (it's set-uid), its
        // CPU a recent average.
        if unknown, let out = try? Child.run(["ps", "-axo", "pid=,%cpu=,rss="], timeout: 5, quiet: true).output {
            var ps: [Int32: (Double, UInt64)] = [:]
            for line in String(decoding: out, as: UTF8.self).split(separator: "\n") {
                let f = line.split(separator: " ", omittingEmptySubsequences: true)
                if f.count >= 3, let pid = Int32(f[0]) { ps[pid] = (Double(f[1]) ?? 0, (UInt64(f[2]) ?? 0) * 1024) }
            }
            for i in list.indices where times[list[i].pid] == nil {
                if let (cpu, rss) = ps[list[i].pid] {
                    list[i].cpu = cpu
                    list[i].memory = rss
                }
            }
        }
        #else
        let tick = Double(sysconf(Int32(_SC_CLK_TCK)))
        let page = UInt64(sysconf(Int32(_SC_PAGESIZE)))
        let fm = FileManager.default
        for name in (try? fm.contentsOfDirectory(atPath: "/proc")) ?? [] {
            guard let pid = Int32(name), let text = try? String(contentsOfFile: "/proc/\(name)/stat", encoding: .utf8),
                  let p = LinuxProc.process(text) else { continue }
            var st = stat()
            let uid = lstat("/proc/\(name)", &st) == 0 ? st.st_uid : 0
            list.append(MachineProcess(pid: pid, parent: p.parent, user: user(uid), name: p.name, command: p.name, cpu: -1,
                                       memory: p.pages * page, threads: p.threads))
            times[pid] = Double(p.ticks) / tick
        }
        #endif
        return (list, times)
    }

    /// A process's arguments, as it was started.
    static func command(_ pid: Int32) -> String? {
        #if os(macOS)
        var buf = [CChar](repeating: 0, count: 2048)
        guard mf_proc_args(pid, &buf, Int32(buf.count)) == 0 else { return nil }
        return String(cString: buf)
        #else
        guard let d = FileManager.default.contents(atPath: "/proc/\(pid)/cmdline"), !d.isEmpty else { return nil }
        let s = String(decoding: d.prefix(2048), as: UTF8.self).split(separator: "\0").joined(separator: " ")
        return s.isEmpty ? nil : s
        #endif
    }

    // MARK: Readings

    static func read() -> Reading? {
        let at = Date().timeIntervalSince1970
        var loads = [Double](repeating: 0, count: 3)
        #if os(macOS)
        var ticks = [mf_core_ticks](repeating: mf_core_ticks(), count: 1024)
        let n = Int(mf_cpu_ticks(&ticks, Int32(ticks.count)))
        guard n > 0 else { return nil }
        let cores = ticks.prefix(n).map { t in
            CoreTicks(busy: t.user + t.nice + t.system, system: t.system, total: t.user + t.nice + t.system + t.idle)
        }
        var m = mf_memory_info()
        mf_memory(&m)
        var memory = MachineMemory()
        memory.total = m.total
        // As Activity Monitor has it: programs' own (less what they'd give
        // up), the kernel's, and what's compressed; files cached apart.
        let app = m.internal > m.purgeable ? m.internal - m.purgeable : 0
        memory.used = min(m.total, app + m.wired + m.compressed)
        memory.available = m.total - memory.used
        memory.cached = m.external + m.purgeable
        memory.free = m.free
        memory.wired = m.wired
        memory.compressed = m.compressed
        memory.swapTotal = m.swap_total
        memory.swapUsed = m.swap_used
        var netIn: UInt64 = 0, netOut: UInt64 = 0, read: UInt64 = 0, written: UInt64 = 0
        mf_net_bytes(&netIn, &netOut)
        mf_disk_bytes(&read, &written)
        getloadavg(&loads, 3)
        #else
        func file(_ p: String) -> String { (try? String(contentsOfFile: p, encoding: .utf8)) ?? "" }
        let cores = LinuxProc.cpu(file("/proc/stat")).cores
        guard !cores.isEmpty else { return nil }
        let memory = LinuxProc.memory(file("/proc/meminfo"))
        // The machine's own links: not loopback, not a virtual one (a
        // bridge, a container's) — unless there's nothing else.
        let links = LinuxProc.network(file("/proc/net/dev")).filter { $0.name != "lo" }
        let physical = links.filter { !FileManager.default.fileExists(atPath: "/sys/devices/virtual/net/\($0.name)") }
        let counted = physical.isEmpty ? links : physical
        let netIn = counted.reduce(0) { $0 + $1.rx }, netOut = counted.reduce(0) { $0 + $1.tx }
        let block = Set((try? FileManager.default.contentsOfDirectory(atPath: "/sys/block")) ?? [])
        let disks = LinuxProc.disks(file("/proc/diskstats")).filter { LinuxProc.isWholeDisk($0.name, among: block) }
        let read = disks.reduce(0) { $0 + $1.read }, written = disks.reduce(0) { $0 + $1.written }
        let l = file("/proc/loadavg").split(separator: " ").prefix(3).compactMap { Double($0) }
        if l.count == 3 { loads = l }
        #endif
        return Reading(at: at, cores: cores, memory: memory, netIn: netIn, netOut: netOut, diskRead: read, diskWrite: written, loads: loads)
    }

    /// The filesystems on the machine's disks, how full.
    static func disks() -> [MachineDisk] {
        var out: [MachineDisk] = []
        #if os(macOS)
        var mounts: UnsafeMutablePointer<statfs>?
        let n = Int(getmntinfo(&mounts, MNT_NOWAIT))
        guard let mounts else { return [] }
        for i in 0..<n {
            var s = mounts[i]
            let flags = UInt32(s.f_flags)
            // Local, and meant to be seen: the startup disk and those plugged in,
            // not the system's own volumes (its data, VM, Preboot).
            guard flags & UInt32(MNT_LOCAL) != 0, flags & UInt32(MNT_DONTBROWSE) == 0 else { continue }
            let mount = withUnsafeBytes(of: &s.f_mntonname) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
            let device = withUnsafeBytes(of: &s.f_mntfromname) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
            let kind = withUnsafeBytes(of: &s.f_fstypename) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
            guard kind != "devfs", kind != "autofs", s.f_blocks > 0 else { continue }
            let size = UInt64(s.f_bsize)
            let total = UInt64(s.f_blocks) * size
            let free = UInt64(s.f_bavail) * size
            out.append(MachineDisk(mount: mount, device: device, kind: kind, total: total, used: total > free ? total - free : 0))
        }
        #else
        let text = (try? String(contentsOfFile: "/proc/mounts", encoding: .utf8)) ?? ""
        for m in LinuxProc.mounts(text) {
            var s = statvfs()
            guard statvfs(m.mount, &s) == 0, s.f_blocks > 0 else { continue }
            let size = UInt64(s.f_frsize)
            let total = UInt64(s.f_blocks) * size
            let free = UInt64(s.f_bavail) * size
            out.append(MachineDisk(mount: m.mount, device: m.device, kind: m.kind, total: total, used: total > free ? total - free : 0))
        }
        #endif
        return out
    }

    #if os(macOS)
    static func sysctlString(_ name: String) -> String? {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var buf = [CChar](repeating: 0, count: size)
        guard sysctlbyname(name, &buf, &size, nil, 0) == 0 else { return nil }
        return String(cString: buf)
    }
    #endif
}
