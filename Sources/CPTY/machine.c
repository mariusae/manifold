// The machine's readings on macOS (the machine view, §7.5): what the
// kernel says of its cores, memory, network, disks and processes. Linux's
// are read from /proc, in Swift.
#ifdef __APPLE__
#include "cpty.h"
#include <CoreFoundation/CoreFoundation.h>
#include <IOKit/IOKitLib.h>
#include <IOKit/storage/IOBlockStorageDriver.h>
#include <libproc.h>
#include <mach/mach.h>
#include <mach/mach_time.h>
#include <net/if.h>
#include <net/if_types.h>
#include <net/route.h>
#include <string.h>
#include <sys/sysctl.h>

int mf_cpu_ticks(mf_core_ticks *out, int max) {
    natural_t count = 0;
    processor_info_array_t info;
    mach_msg_type_number_t n;
    if (host_processor_info(mach_host_self(), PROCESSOR_CPU_LOAD_INFO, &count, &info, &n) != KERN_SUCCESS) return -1;
    int cores = (int)count < max ? (int)count : max;
    for (int i = 0; i < cores; i++) {
        unsigned *t = (unsigned *)&info[i * CPU_STATE_MAX];
        out[i].user = t[CPU_STATE_USER];
        out[i].nice = t[CPU_STATE_NICE];
        out[i].system = t[CPU_STATE_SYSTEM];
        out[i].idle = t[CPU_STATE_IDLE];
    }
    vm_deallocate(mach_task_self(), (vm_address_t)info, n * sizeof(integer_t));
    return cores;
}

int mf_memory(mf_memory_info *m) {
    memset(m, 0, sizeof *m);
    size_t len = sizeof m->total;
    sysctlbyname("hw.memsize", &m->total, &len, NULL, 0);
    vm_statistics64_data_t vm;
    mach_msg_type_number_t n = HOST_VM_INFO64_COUNT;
    if (host_statistics64(mach_host_self(), HOST_VM_INFO64, (host_info64_t)&vm, &n) != KERN_SUCCESS) return -1;
    vm_size_t page = 0;
    host_page_size(mach_host_self(), &page);
    m->free = (uint64_t)(vm.free_count + vm.speculative_count) * page;
    m->wired = (uint64_t)vm.wire_count * page;
    m->compressed = (uint64_t)vm.compressor_page_count * page;
    m->purgeable = (uint64_t)vm.purgeable_count * page;
    m->external = (uint64_t)vm.external_page_count * page;
    m->internal = (uint64_t)vm.internal_page_count * page;
    struct xsw_usage swap;
    len = sizeof swap;
    if (sysctlbyname("vm.swapusage", &swap, &len, NULL, 0) == 0) {
        m->swap_total = swap.xsu_total;
        m->swap_used = swap.xsu_used;
    }
    return 0;
}

int mf_net_bytes(uint64_t *in, uint64_t *out) {
    *in = 0;
    *out = 0;
    int mib[] = {CTL_NET, PF_ROUTE, 0, 0, NET_RT_IFLIST2, 0};
    size_t len = 0;
    if (sysctl(mib, 6, NULL, &len, NULL, 0) != 0) return -1;
    char *buf = malloc(len);
    if (!buf) return -1;
    if (sysctl(mib, 6, buf, &len, NULL, 0) != 0) { free(buf); return -1; }
    for (char *p = buf; p < buf + len;) {
        struct if_msghdr *h = (struct if_msghdr *)p;
        if (h->ifm_msglen == 0) break;
        if (h->ifm_type == RTM_IFINFO2) {
            struct if_msghdr2 *h2 = (struct if_msghdr2 *)p;
            // The machine's own links (Ethernet, Wi-Fi), not loopback or a
            // tunnel over them (a VPN's bytes go through a link too).
            if (h2->ifm_data.ifi_type == IFT_ETHER) {
                *in += h2->ifm_data.ifi_ibytes;
                *out += h2->ifm_data.ifi_obytes;
            }
        }
        p += h->ifm_msglen;
    }
    free(buf);
    return 0;
}

static uint64_t number(CFDictionaryRef d, const char *key) {
    CFStringRef k = CFStringCreateWithCString(NULL, key, kCFStringEncodingUTF8);
    CFNumberRef n = CFDictionaryGetValue(d, k);
    CFRelease(k);
    int64_t v = 0;
    if (n && CFGetTypeID(n) == CFNumberGetTypeID()) CFNumberGetValue(n, kCFNumberSInt64Type, &v);
    return (uint64_t)v;
}

int mf_disk_bytes(uint64_t *read, uint64_t *written) {
    *read = 0;
    *written = 0;
    io_iterator_t it;
    if (IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOBlockStorageDriver"), &it) != KERN_SUCCESS) return -1;
    io_registry_entry_t e;
    while ((e = IOIteratorNext(it))) {
        CFDictionaryRef stats = IORegistryEntryCreateCFProperty(e, CFSTR(kIOBlockStorageDriverStatisticsKey), NULL, 0);
        if (stats) {
            if (CFGetTypeID(stats) == CFDictionaryGetTypeID()) {
                *read += number(stats, kIOBlockStorageDriverStatisticsBytesReadKey);
                *written += number(stats, kIOBlockStorageDriverStatisticsBytesWrittenKey);
            }
            CFRelease(stats);
        }
        IOObjectRelease(e);
    }
    IOObjectRelease(it);
    return 0;
}

int mf_processes(mf_process *out, int max) {
    int mib[] = {CTL_KERN, KERN_PROC, KERN_PROC_ALL, 0};
    size_t len = 0;
    if (sysctl(mib, 4, NULL, &len, NULL, 0) != 0) return -1;
    len += len / 8;
    struct kinfo_proc *procs = malloc(len);
    if (!procs) return -1;
    if (sysctl(mib, 4, procs, &len, NULL, 0) != 0) { free(procs); return -1; }
    int n = (int)(len / sizeof(struct kinfo_proc)), k = 0;
    static mach_timebase_info_data_t tb;
    if (tb.denom == 0) mach_timebase_info(&tb);
    for (int i = 0; i < n && k < max; i++) {
        struct kinfo_proc *p = &procs[i];
        pid_t pid = p->kp_proc.p_pid;
        if (pid == 0) continue;
        mf_process *o = &out[k++];
        memset(o, 0, sizeof *o);
        o->pid = pid;
        o->ppid = p->kp_eproc.e_ppid;
        o->uid = p->kp_eproc.e_ucred.cr_uid;
        if (proc_name(pid, o->name, sizeof o->name) <= 0) {
            strlcpy(o->name, p->kp_proc.p_comm, sizeof o->name);
        }
        // The rest only for what we may look at (not root's, as a user).
        struct proc_taskinfo ti;
        if (proc_pidinfo(pid, PROC_PIDTASKINFO, 0, &ti, sizeof ti) == sizeof ti) {
            o->known = 1;
            o->threads = ti.pti_threadnum;
            o->rss = ti.pti_resident_size;
            // In Mach time units: nanoseconds on Intel, not on Apple's chips.
            o->cpu_ns = (ti.pti_total_user + ti.pti_total_system) * tb.numer / tb.denom;
        }
    }
    free(procs);
    return k;
}

int mf_proc_args(pid_t pid, char *buf, int len) {
    int mib[] = {CTL_KERN, KERN_PROCARGS2, pid};
    size_t size = 0;
    if (sysctl(mib, 3, NULL, &size, NULL, 0) != 0 || size == 0) return -1;
    char *args = malloc(size);
    if (!args) return -1;
    if (sysctl(mib, 3, args, &size, NULL, 0) != 0 || size < sizeof(int)) { free(args); return -1; }
    int argc;
    memcpy(&argc, args, sizeof argc);
    char *p = args + sizeof argc, *end = args + size;
    // The executable's path, then padding, then the arguments.
    while (p < end && *p) p++;
    while (p < end && !*p) p++;
    int w = 0;
    for (int a = 0; a < argc && p < end; a++) {
        size_t l = strnlen(p, end - p);
        if (a > 0 && w < len - 1) buf[w++] = ' ';
        for (size_t j = 0; j < l && w < len - 1; j++) buf[w++] = p[j];
        p += l + 1;
    }
    buf[w] = 0;
    free(args);
    return w > 0 ? 0 : -1;
}
#endif
