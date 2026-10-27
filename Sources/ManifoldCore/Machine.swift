import Foundation

/// The whole machine at a glance (§7.5): what its processors, memory,
/// network and disks are doing, and which processes most — as a host's
/// server reads them, macOS or Linux alike. Rates are over the moments
/// between two readings; the server keeps five minutes of the cheap part
/// (`MachinePoint`), read every two seconds, so a graph has its past as
/// soon as it's shown.

/// What's asked: the processes sorted, those matching a filter, so many,
/// and whatever the history has since a time.
public struct MachineQuery: Codable, Sendable, Equatable {
    public enum Sort: String, Codable, Sendable { case cpu, memory, pid, name, threads, user }
    public var sort: Sort
    public var ascending: Bool
    /// Narrows the processes: a name, a command, a user, a pid.
    public var filter: String
    public var limit: Int
    /// Processes kept whether or not they're among the first (selected).
    public var keep: [Int32]
    /// History newer than this (host time); nil for all of it.
    public var since: Double?

    public init(sort: Sort = .cpu, ascending: Bool = false, filter: String = "", limit: Int = 60, keep: [Int32] = [], since: Double? = nil) {
        self.sort = sort
        self.ascending = ascending
        self.filter = filter
        self.limit = limit
        self.keep = keep
        self.since = since
    }

    /// The processes this asks for, from all of them: matching, sorted,
    /// the first `limit`, and those kept.
    public func apply(_ all: [MachineProcess]) -> (shown: [MachineProcess], matching: Int) {
        let q = filter.trimmingCharacters(in: .whitespaces).lowercased()
        let matching = q.isEmpty ? all : all.filter {
            $0.name.lowercased().contains(q) || $0.command.lowercased().contains(q) || $0.user.lowercased() == q || String($0.pid) == q
        }
        func before(_ a: MachineProcess, _ b: MachineProcess) -> Bool {
            let r: ComparisonResult = switch sort {
            case .cpu: a.cpu == b.cpu ? .orderedSame : (a.cpu < b.cpu ? .orderedAscending : .orderedDescending)
            case .memory: a.memory == b.memory ? .orderedSame : (a.memory < b.memory ? .orderedAscending : .orderedDescending)
            case .threads: (a.threads ?? 0) == (b.threads ?? 0) ? .orderedSame : ((a.threads ?? 0) < (b.threads ?? 0) ? .orderedAscending : .orderedDescending)
            case .pid: .orderedSame
            case .name: a.name.localizedCaseInsensitiveCompare(b.name)
            case .user: a.user.localizedCaseInsensitiveCompare(b.user)
            }
            if r == .orderedSame { return ascending ? a.pid < b.pid : a.pid > b.pid }
            return ascending ? r == .orderedAscending : r == .orderedDescending
        }
        let sorted = matching.sorted(by: before)
        var shown = Array(sorted.prefix(max(0, limit)))
        let kept = Set(keep).subtracting(shown.map(\.pid))
        if !kept.isEmpty { shown += sorted.filter { kept.contains($0.pid) } }
        return (shown, matching.count)
    }
}

/// Memory, in bytes. `used` is what programs hold (what isn't available
/// to them again); `cached`, files kept in memory, given up when wanted.
public struct MachineMemory: Codable, Sendable, Equatable {
    public var total: UInt64 = 0
    public var used: UInt64 = 0
    public var available: UInt64 = 0
    public var cached: UInt64 = 0
    public var free: UInt64 = 0
    public var swapTotal: UInt64 = 0
    public var swapUsed: UInt64 = 0
    /// macOS's: compressed, and wired (the kernel's, never paged out).
    public var compressed: UInt64?
    public var wired: UInt64?

    public init() {}

    public var usedFraction: Double { total == 0 ? 0 : Double(used) / Double(total) }
}

/// A filesystem mounted from a disk: where, how big, how full.
public struct MachineDisk: Codable, Sendable, Equatable {
    public var mount: String
    public var device: String
    public var kind: String
    public var total: UInt64
    public var used: UInt64

    public init(mount: String, device: String, kind: String, total: UInt64, used: UInt64) {
        self.mount = mount
        self.device = device
        self.kind = kind
        self.total = total
        self.used = used
    }

    public var usedFraction: Double { total == 0 ? 0 : Double(used) / Double(total) }
}

/// A process, as the machine view lists it.
public struct MachineProcess: Codable, Sendable, Equatable {
    public var pid: Int32
    public var parent: Int32
    public var user: String
    /// Its short name; `command`, its arguments (for those asked about),
    /// else its name.
    public var name: String
    public var command: String
    /// Of one core: 250 is two and a half cores' worth.
    public var cpu: Double
    /// Resident, in bytes.
    public var memory: UInt64
    /// Nil where it can't be read (another user's, on macOS).
    public var threads: Int?
    /// The terminal or agent block it runs under, if one of the host's.
    public var block: BlockID?

    public init(pid: Int32, parent: Int32, user: String, name: String, command: String, cpu: Double, memory: UInt64, threads: Int?, block: BlockID? = nil) {
        self.pid = pid
        self.parent = parent
        self.user = user
        self.name = name
        self.command = command
        self.cpu = cpu
        self.memory = memory
        self.threads = threads
        self.block = block
    }
}

/// The cheap part of a reading, kept as history: every two seconds.
public struct MachinePoint: Codable, Sendable, Equatable {
    /// Host time, seconds since 1970.
    public var at: Double
    /// Busy, of all cores, 0…1; and the kernel's part of it.
    public var cpu: Double
    public var system: Double
    /// Memory used, 0…1.
    public var memory: Double
    /// Bytes a second.
    public var netIn: Double
    public var netOut: Double
    public var diskRead: Double
    public var diskWrite: Double
    public var load: Double

    public init(at: Double, cpu: Double, system: Double, memory: Double, netIn: Double, netOut: Double, diskRead: Double, diskWrite: Double, load: Double) {
        self.at = at
        self.cpu = cpu
        self.system = system
        self.memory = memory
        self.netIn = netIn
        self.netOut = netOut
        self.diskRead = diskRead
        self.diskWrite = diskWrite
        self.load = load
    }
}

/// The machine now, and the history asked for.
public struct MachineSample: Codable, Sendable, Equatable {
    public var at: Double
    public var hostname: String
    /// "macOS 26.1", "Ubuntu 22.04.4 LTS · Linux 6.4.3".
    public var system: String
    public var processor: String
    /// GHz, where the host says.
    public var frequency: Double?
    public var uptime: Double
    /// Each core's busy, 0…1.
    public var cores: [Double]
    public var now: MachinePoint
    public var loads: [Double]
    public var memory: MachineMemory
    public var disks: [MachineDisk]
    /// Bytes through the network since it started.
    public var netInTotal: UInt64
    public var netOutTotal: UInt64
    public var processes: [MachineProcess]
    public var processCount: Int
    public var matching: Int
    public var history: [MachinePoint]

    public init(at: Double, hostname: String, system: String, processor: String, frequency: Double?, uptime: Double, cores: [Double], now: MachinePoint,
                loads: [Double], memory: MachineMemory, disks: [MachineDisk], netInTotal: UInt64, netOutTotal: UInt64,
                processes: [MachineProcess], processCount: Int, matching: Int, history: [MachinePoint]) {
        self.at = at
        self.hostname = hostname
        self.system = system
        self.processor = processor
        self.frequency = frequency
        self.uptime = uptime
        self.cores = cores
        self.now = now
        self.loads = loads
        self.memory = memory
        self.disks = disks
        self.netInTotal = netInTotal
        self.netOutTotal = netOutTotal
        self.processes = processes
        self.processCount = processCount
        self.matching = matching
        self.history = history
    }
}

/// A core's time, in ticks, since it started: busy and all.
public struct CoreTicks: Sendable, Equatable {
    public var busy: UInt64
    public var system: UInt64
    public var total: UInt64

    public init(busy: UInt64, system: UInt64, total: UInt64) {
        self.busy = busy
        self.system = system
        self.total = total
    }

    /// Busy between two readings, 0…1.
    public static func busy(_ a: CoreTicks, _ b: CoreTicks) -> (busy: Double, system: Double) {
        guard b.total > a.total else { return (0, 0) }
        let t = Double(b.total - a.total)
        let busy = b.busy >= a.busy ? Double(b.busy - a.busy) : 0
        let sys = b.system >= a.system ? Double(b.system - a.system) : 0
        return (min(1, busy / t), min(1, sys / t))
    }
}

/// Linux's /proc, read: what each of its files says, parsed here (where
/// it can be tested on any machine); the server reads the files.
public enum LinuxProc {
    /// /proc/stat: all cores together, then each.
    public static func cpu(_ text: String) -> (all: CoreTicks?, cores: [CoreTicks]) {
        var all: CoreTicks?
        var cores: [CoreTicks] = []
        for line in text.split(separator: "\n") where line.hasPrefix("cpu") {
            let f = line.split(separator: " ", omittingEmptySubsequences: true)
            guard f.count >= 5 else { continue }
            // user nice system idle iowait irq softirq steal (guests are in user).
            let n = f.dropFirst().prefix(8).map { UInt64($0) ?? 0 }
            let idle = n[3] + (n.count > 4 ? n[4] : 0)
            let total = n.reduce(0, +)
            let system = n[2] + (n.count > 6 ? n[5] + n[6] : 0)
            let t = CoreTicks(busy: total - idle, system: system, total: total)
            if f[0] == "cpu" { all = t } else { cores.append(t) }
        }
        return (all, cores)
    }

    /// /proc/meminfo, in bytes.
    public static func memory(_ text: String) -> MachineMemory {
        var kb: [String: UInt64] = [:]
        for line in text.split(separator: "\n") {
            let parts = line.split(separator: ":", maxSplits: 1)
            guard parts.count == 2 else { continue }
            let v = parts[1].split(separator: " ").first.flatMap { UInt64($0) } ?? 0
            kb[String(parts[0])] = v * 1024
        }
        var m = MachineMemory()
        m.total = kb["MemTotal"] ?? 0
        m.free = kb["MemFree"] ?? 0
        // Older kernels have no MemAvailable: free and what's cached.
        let cached = (kb["Cached"] ?? 0) + (kb["SReclaimable"] ?? 0) + (kb["Buffers"] ?? 0)
        m.available = kb["MemAvailable"] ?? min(m.total, m.free + cached)
        m.used = m.total > m.available ? m.total - m.available : 0
        m.cached = cached
        m.swapTotal = kb["SwapTotal"] ?? 0
        m.swapUsed = m.swapTotal > (kb["SwapFree"] ?? 0) ? m.swapTotal - (kb["SwapFree"] ?? 0) : 0
        return m
    }

    /// /proc/net/dev: bytes in and out by interface.
    public static func network(_ text: String) -> [(name: String, rx: UInt64, tx: UInt64)] {
        var out: [(String, UInt64, UInt64)] = []
        for line in text.split(separator: "\n") {
            let parts = line.split(separator: ":", maxSplits: 1)
            guard parts.count == 2 else { continue }
            let f = parts[1].split(separator: " ", omittingEmptySubsequences: true)
            guard f.count >= 9, let rx = UInt64(f[0]), let tx = UInt64(f[8]) else { continue }
            out.append((parts[0].trimmingCharacters(in: .whitespaces), rx, tx))
        }
        return out
    }

    /// /proc/diskstats: bytes read and written by device (sectors of 512).
    public static func disks(_ text: String) -> [(name: String, read: UInt64, written: UInt64)] {
        var out: [(String, UInt64, UInt64)] = []
        for line in text.split(separator: "\n") {
            let f = line.split(separator: " ", omittingEmptySubsequences: true)
            guard f.count >= 10, let r = UInt64(f[5]), let w = UInt64(f[9]) else { continue }
            out.append((String(f[2]), r * 512, w * 512))
        }
        return out
    }

    /// Whole disks, not their partitions or what's made of them (a
    /// device-mapper volume, a RAID, a loop): what's summed for the
    /// machine's reading and writing, given /sys/block's names.
    public static func isWholeDisk(_ name: String, among block: Set<String>) -> Bool {
        guard block.contains(name) else { return false }
        for p in ["loop", "ram", "zram", "dm-", "md", "sr", "fd", "nbd"] where name.hasPrefix(p) { return false }
        return true
    }

    /// /proc/mounts: the filesystems on devices, each once.
    public static func mounts(_ text: String) -> [(device: String, mount: String, kind: String)] {
        let real: Set<String> = ["ext2", "ext3", "ext4", "xfs", "btrfs", "zfs", "f2fs", "vfat", "exfat", "ntfs", "ntfs3", "jfs", "reiserfs", "bcachefs", "apfs", "hfsplus"]
        var seen: Set<String> = []
        var out: [(String, String, String)] = []
        for line in text.split(separator: "\n") {
            let f = line.split(separator: " ")
            guard f.count >= 3 else { continue }
            let device = String(f[0]), kind = String(f[2])
            // Spaces in a mount point are written \040.
            let mount = String(f[1]).replacingOccurrences(of: "\\040", with: " ")
            guard real.contains(kind) || (device.hasPrefix("/dev/") && kind != "squashfs" && !device.hasPrefix("/dev/loop")) else { continue }
            guard !mount.hasPrefix("/snap/"), !mount.hasPrefix("/var/lib/docker/"), !mount.hasPrefix("/run/"), !seen.contains(device) else { continue }
            seen.insert(device)
            out.append((device, mount, kind))
        }
        return out
    }

    /// One process's /proc/<pid>/stat: its name, parent, CPU time (ticks),
    /// threads and resident pages.
    public static func process(_ text: String) -> (name: String, parent: Int32, ticks: UInt64, threads: Int, pages: UInt64)? {
        // The name is in parentheses and may hold anything, parentheses too.
        guard let open = text.firstIndex(of: "("), let close = text.lastIndex(of: ")") else { return nil }
        let name = String(text[text.index(after: open)..<close])
        let f = text[text.index(after: close)...].split(separator: " ", omittingEmptySubsequences: true)
        // Fields from the state (3) on: ppid 4, utime 14, stime 15, threads 20, rss 24.
        guard f.count >= 22, let ppid = Int32(f[1]), let u = UInt64(f[11]), let s = UInt64(f[12]), let th = Int(f[17]), let rss = UInt64(f[21]) else { return nil }
        return (name, ppid, u + s, th, rss)
    }

    /// /etc/os-release's name for it.
    public static func release(_ text: String) -> String? {
        for line in text.split(separator: "\n") where line.hasPrefix("PRETTY_NAME=") {
            return String(line.dropFirst("PRETTY_NAME=".count)).trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
        }
        return nil
    }

    /// /proc/cpuinfo: the processor's name, and the cores' clock averaged (GHz).
    public static func processor(_ text: String) -> (name: String?, ghz: Double?) {
        var name: String?
        var mhz: [Double] = []
        for line in text.split(separator: "\n") {
            let parts = line.split(separator: ":", maxSplits: 1)
            guard parts.count == 2 else { continue }
            let key = parts[0].trimmingCharacters(in: .whitespaces), value = parts[1].trimmingCharacters(in: .whitespaces)
            if name == nil, key == "model name" || key == "Model" { name = value }
            if key == "cpu MHz", let v = Double(value) { mhz.append(v) }
        }
        return (name, mhz.isEmpty ? nil : mhz.reduce(0, +) / Double(mhz.count) / 1000)
    }
}
