#include "cpty.h"

#include <errno.h>
#include <fcntl.h>
#include <signal.h>
#include <spawn.h>
#include <stdio.h>
#include <string.h>
#include <sys/ioctl.h>
#include <unistd.h>
#ifdef __APPLE__
#include <libproc.h>
#include <util.h>
#else
#define _GNU_SOURCE
#include <pty.h>
#include <utmp.h>
#include <sys/wait.h>
#endif

pid_t mf_pty_spawn(const char *path, char *const argv[], char *const envp[],
                   const char *cwd, unsigned short cols, unsigned short rows,
                   int *master) {
    struct winsize ws = {.ws_row = rows, .ws_col = cols};
    int m, s;
    if (openpty(&m, &s, NULL, NULL, &ws) < 0) return -1;

    pid_t pid = fork();
    if (pid < 0) {
        int e = errno;
        close(m);
        close(s);
        errno = e;
        return -1;
    }
    if (pid == 0) {
        // Only async-signal-safe calls from here to exec.
        sigset_t none;
        sigemptyset(&none);
        sigprocmask(SIG_SETMASK, &none, NULL);
        for (int sig = 1; sig < NSIG; sig++) signal(sig, SIG_DFL);
        close(m);
        if (login_tty(s) < 0) _exit(126);
        if (cwd == NULL || chdir(cwd) < 0) {
            // Fall back to wherever we are; the shell will manage.
        }
        int max = (int)sysconf(_SC_OPEN_MAX);
        if (max < 0 || max > 65536) max = 65536;
        for (int fd = 3; fd < max; fd++) close(fd);
        execve(path, argv, envp);
        _exit(127);
    }

    close(s);
    fcntl(m, F_SETFD, FD_CLOEXEC);
    fcntl(m, F_SETFL, fcntl(m, F_GETFL) | O_NONBLOCK);
    *master = m;
    return pid;
}

int mf_pty_resize(int master, unsigned short cols, unsigned short rows) {
    struct winsize ws = {.ws_row = rows, .ws_col = cols};
    return ioctl(master, TIOCSWINSZ, &ws);
}

pid_t mf_spawn_detached(const char *path, char *const argv[], const char *log) {
    extern char **environ;
#ifdef __APPLE__
    posix_spawn_file_actions_t fa;
    posix_spawnattr_t attr;
    posix_spawn_file_actions_init(&fa);
    posix_spawnattr_init(&attr);
    posix_spawn_file_actions_addopen(&fa, 0, "/dev/null", O_RDONLY, 0);
    posix_spawn_file_actions_addopen(&fa, 1, log, O_WRONLY | O_CREAT | O_APPEND, 0644);
    posix_spawn_file_actions_adddup2(&fa, 1, 2);
    sigset_t none, all;
    sigemptyset(&none);
    sigfillset(&all);
    posix_spawnattr_setsigmask(&attr, &none);
    posix_spawnattr_setsigdefault(&attr, &all);
    posix_spawnattr_setflags(&attr, POSIX_SPAWN_SETSID | POSIX_SPAWN_CLOEXEC_DEFAULT |
                                        POSIX_SPAWN_SETSIGMASK | POSIX_SPAWN_SETSIGDEF);
    pid_t pid;
    int err = posix_spawn(&pid, path, &fa, &attr, argv, environ);
    posix_spawn_file_actions_destroy(&fa);
    posix_spawnattr_destroy(&attr);
    if (err != 0) {
        errno = err;
        return -1;
    }
    return pid;
#else
    // A double fork, so the server is nobody's child and sits in its own
    // session.
    pid_t pid = fork();
    if (pid < 0) return -1;
    if (pid == 0) {
        setsid();
        pid_t inner = fork();
        if (inner != 0) _exit(inner < 0 ? 127 : 0);
        sigset_t none;
        sigemptyset(&none);
        sigprocmask(SIG_SETMASK, &none, NULL);
        for (int sig = 1; sig < NSIG; sig++) signal(sig, SIG_DFL);
        int in = open("/dev/null", O_RDONLY);
        int out = open(log, O_WRONLY | O_CREAT | O_APPEND, 0644);
        if (in >= 0) dup2(in, 0);
        if (out >= 0) { dup2(out, 1); dup2(out, 2); }
        int max = (int)sysconf(_SC_OPEN_MAX);
        if (max < 0 || max > 65536) max = 65536;
        for (int fd = 3; fd < max; fd++) close(fd);
        execve(path, argv, environ);
        _exit(127);
    }
    int status;
    waitpid(pid, &status, 0);
    return 1;
#endif
}

int mf_proc_cwd(pid_t pid, char *buf, int len) {
#ifdef __APPLE__
    struct proc_vnodepathinfo info;
    int n = proc_pidinfo(pid, PROC_PIDVNODEPATHINFO, 0, &info, sizeof(info));
    if (n != sizeof(info)) return -1;
    snprintf(buf, len, "%s", info.pvi_cdir.vip_path);
    return 0;
#else
    char link[64];
    snprintf(link, sizeof link, "/proc/%d/cwd", (int)pid);
    ssize_t n = readlink(link, buf, len - 1);
    if (n < 0) return -1;
    buf[n] = 0;
    return 0;
#endif
}

int mf_pty_foreground_name(int master, char *buf, int len) {
    pid_t pg = tcgetpgrp(master);
    if (pg <= 0) return -1;
#ifdef __APPLE__
    if (proc_name(pg, buf, len) <= 0) return -1;
    return 0;
#else
    char path[64];
    snprintf(path, sizeof path, "/proc/%d/comm", (int)pg);
    FILE *f = fopen(path, "r");
    if (!f) return -1;
    if (!fgets(buf, len, f)) { fclose(f); return -1; }
    fclose(f);
    size_t n = strlen(buf);
    if (n > 0 && buf[n - 1] == '\n') buf[n - 1] = 0;
    return 0;
#endif
}

pid_t mf_pty_foreground(int master) {
    pid_t pg = tcgetpgrp(master);
    return pg <= 0 ? -1 : pg;
}

int mf_terminal_size(int fd, unsigned short *cols, unsigned short *rows) {
    struct winsize ws;
    if (ioctl(fd, TIOCGWINSZ, &ws) != 0) return -1;
    *cols = ws.ws_col;
    *rows = ws.ws_row;
    return 0;
}
