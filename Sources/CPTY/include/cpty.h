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

// The name of the terminal's foreground process, or -1.
int mf_pty_foreground_name(int master, char *buf, int len);

#endif
