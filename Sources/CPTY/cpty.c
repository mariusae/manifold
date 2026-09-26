#include "cpty.h"

#include <errno.h>
#include <fcntl.h>
#include <libproc.h>
#include <signal.h>
#include <spawn.h>
#include <string.h>
#include <sys/ioctl.h>
#include <unistd.h>
#include <util.h>

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
        int max = getdtablesize();
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
}

int mf_proc_cwd(pid_t pid, char *buf, int len) {
    struct proc_vnodepathinfo info;
    int n = proc_pidinfo(pid, PROC_PIDVNODEPATHINFO, 0, &info, sizeof(info));
    if (n != sizeof(info)) return -1;
    strlcpy(buf, info.pvi_cdir.vip_path, len);
    return 0;
}

int mf_pty_foreground_name(int master, char *buf, int len) {
    pid_t pg = tcgetpgrp(master);
    if (pg <= 0) return -1;
    if (proc_name(pg, buf, len) <= 0) return -1;
    return 0;
}
