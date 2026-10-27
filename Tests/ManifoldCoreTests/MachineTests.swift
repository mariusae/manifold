import Foundation
import Testing
@testable import ManifoldCore

@Test func linuxCoresAreReadFromProcStat() {
    let stat = """
    cpu  400 0 100 1400 100 0 0 0 0 0
    cpu0 300 0 50 600 50 0 0 0 0 0
    cpu1 100 0 50 800 50 0 0 0 0 0
    intr 12345
    """
    let (all, cores) = LinuxProc.cpu(stat)
    #expect(cores.count == 2)
    #expect(all == CoreTicks(busy: 500, system: 100, total: 2000))
    // Idle counts what waited on a disk too.
    #expect(cores[0] == CoreTicks(busy: 350, system: 50, total: 1000))
    let later = CoreTicks(busy: 850, system: 150, total: 2000)
    let b = CoreTicks.busy(cores[0], later)
    #expect(b.busy == 0.5 && b.system == 0.1)
    // A counter gone back (a core taken offline and on): nothing, not a crash.
    #expect(CoreTicks.busy(later, cores[0]).busy == 0)
}

@Test func linuxMemoryIsWhatIsntAvailable() {
    let m = LinuxProc.memory("""
    MemTotal:       16000000 kB
    MemFree:         1000000 kB
    MemAvailable:    6000000 kB
    Buffers:          500000 kB
    Cached:          4000000 kB
    SwapCached:            0 kB
    SReclaimable:     500000 kB
    SwapTotal:       2000000 kB
    SwapFree:        1500000 kB
    """)
    #expect(m.total == 16_000_000 * 1024)
    #expect(m.used == 10_000_000 * 1024)
    #expect(m.cached == 5_000_000 * 1024)
    #expect(m.swapUsed == 500_000 * 1024)
}

@Test func linuxNetworkDisksAndMountsAreParsed() {
    let dev = """
    Inter-|   Receive                                                |  Transmit
     face |bytes    packets errs drop fifo frame compressed multicast|bytes    packets errs drop fifo colls carrier compressed
        lo: 1000      10    0    0    0     0          0         0     1000      10    0    0    0     0       0          0
      eth0: 123456789 1000    0    0    0     0          0         0 987654321 2000    0    0    0     0       0          0
    """
    let links = LinuxProc.network(dev)
    #expect(links.count == 2)
    #expect(links[1].name == "eth0" && links[1].rx == 123_456_789 && links[1].tx == 987_654_321)

    let stats = """
     259       0 nvme0n1 1000 0 2000 100 500 0 4000 100 0 100 200
     259       1 nvme0n1p1 900 0 1800 90 400 0 3000 90 0 90 180
     253       0 dm-0 900 0 1800 90 400 0 3000 90 0 90 180
       7       0 loop0 10 0 20 1 0 0 0 0 0 1 1
    """
    let disks = LinuxProc.disks(stats)
    #expect(disks[0].read == 2000 * 512 && disks[0].written == 4000 * 512)
    let block: Set<String> = ["nvme0n1", "dm-0", "loop0"]
    #expect(disks.filter { LinuxProc.isWholeDisk($0.name, among: block) }.map(\.name) == ["nvme0n1"])

    let mounts = LinuxProc.mounts("""
    sysfs /sys sysfs rw 0 0
    /dev/nvme0n1p2 / ext4 rw,relatime 0 0
    /dev/nvme0n1p1 /boot/efi vfat rw 0 0
    /dev/loop3 /snap/core/1 squashfs ro 0 0
    tmpfs /run tmpfs rw 0 0
    /dev/nvme0n1p2 /var/lib/docker/overlay2 ext4 rw 0 0
    /dev/sdb1 /mnt/My\\040Disk xfs rw 0 0
    """)
    #expect(mounts.map(\.mount) == ["/", "/boot/efi", "/mnt/My Disk"])
}

@Test func aLinuxProcessIsReadFromItsStat() {
    // A name with spaces and parentheses in it.
    let line = "1234 (Web (Content) 2) S 1000 1234 1234 0 -1 4194560 100 0 0 0 250 50 0 0 20 0 17 0 12345 1000000 2560 18446744073709551615"
    let p = LinuxProc.process(line)
    #expect(p?.name == "Web (Content) 2")
    #expect(p?.parent == 1000)
    #expect(p?.ticks == 300)
    #expect(p?.threads == 17)
    #expect(p?.pages == 2560)
    #expect(LinuxProc.release("NAME=\"Ubuntu\"\nPRETTY_NAME=\"Ubuntu 22.04.4 LTS\"\n") == "Ubuntu 22.04.4 LTS")
    let cpu = LinuxProc.processor("processor : 0\nmodel name : AMD EPYC-Genoa\ncpu MHz : 1500.000\nprocessor : 1\ncpu MHz : 2500.000\n")
    #expect(cpu.name == "AMD EPYC-Genoa" && cpu.ghz == 2)
}

@Test func theMachinesProcessesAreSortedNarrowedAndKept() {
    func p(_ pid: Int32, _ name: String, cpu: Double, mem: UInt64, user: String = "me") -> MachineProcess {
        MachineProcess(pid: pid, parent: 1, user: user, name: name, command: name, cpu: cpu, memory: mem, threads: 1)
    }
    let all = [p(1, "launchd", cpu: 0.5, mem: 30), p(2, "hg", cpu: 90, mem: 2000), p(3, "fish", cpu: 1, mem: 5), p(4, "hg", cpu: 3, mem: 3000, user: "root")]
    var q = MachineQuery(limit: 2)
    #expect(q.apply(all).shown.map(\.pid) == [2, 4])
    q.sort = .memory
    #expect(q.apply(all).shown.map(\.pid) == [4, 2])
    q.sort = .name
    q.ascending = true
    #expect(q.apply(all).shown.map(\.name) == ["fish", "hg"])
    // Selected, kept though it isn't among the first.
    q.keep = [1]
    #expect(q.apply(all).shown.map(\.pid) == [3, 2, 1])
    let narrowed = MachineQuery(filter: "HG").apply(all)
    #expect(narrowed.matching == 2 && narrowed.shown.map(\.pid) == [2, 4])
    #expect(MachineQuery(filter: "root").apply(all).shown.map(\.pid) == [4])
}
