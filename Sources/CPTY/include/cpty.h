#ifndef CPTY_H
#define CPTY_H

#include <sys/types.h>

// Starts `path` on a new pseudo-terminal of the given size, as the leader of
// a new session with the terminal as its controlling terminal. Returns the
// child's pid and stores the (non-blocking, close-on-exec) master side in
// *master, or returns -1 with errno set.
pid_t mf_pty_spawn(const char *path, char *const argv[], char *const envp[],
                   const char *cwd, unsigned short cols, unsigned short rows,
                   int *master);

// Resizes the terminal behind a master fd.
int mf_pty_resize(int master, unsigned short cols, unsigned short rows);

// Starts `path` detached from us: in its own session, with stdin from
// /dev/null and stdout and stderr appended to `log`. Returns its pid or -1.
pid_t mf_spawn_detached(const char *path, char *const argv[], const char *log);

// The current working directory of a process, or -1.
int mf_proc_cwd(pid_t pid, char *buf, int len);
// The path of a process's executable; -1 if it can't be read.
int mf_proc_path(pid_t pid, char *buf, int len);

// The name of the terminal's foreground process, or -1.
int mf_pty_foreground_name(int master, char *buf, int len);

// The terminal's foreground process group, or -1.
pid_t mf_pty_foreground(int master);

// The size of the terminal on fd, or -1.
int mf_terminal_size(int fd, unsigned short *cols, unsigned short *rows);

#ifdef __APPLE__
#include <stdint.h>

// The machine's readings on macOS (machine.c).
typedef struct { uint64_t user, nice, system, idle; } mf_core_ticks;
// Each core's ticks since it started; the cores read, or -1.
int mf_cpu_ticks(mf_core_ticks *out, int max);

typedef struct {
    uint64_t total, free, wired, compressed, purgeable, external, internal, swap_total, swap_used;
} mf_memory_info;
int mf_memory(mf_memory_info *m);

// Bytes in and out through the machine's own links (Ethernet, Wi-Fi).
int mf_net_bytes(uint64_t *in, uint64_t *out);
// Bytes read and written by its disks.
int mf_disk_bytes(uint64_t *read, uint64_t *written);

typedef struct {
    int32_t pid, ppid;
    uint32_t uid;
    char name[64];
    // Whether the rest could be read (another user's can't be).
    int32_t known;
    int32_t threads;
    uint64_t cpu_ns;
    uint64_t rss;
} mf_process;
// Every process; how many, or -1.
int mf_processes(mf_process *out, int max);
// A process's arguments, spaced; -1 if they can't be read.
int mf_proc_args(pid_t pid, char *buf, int len);
#endif

#endif
