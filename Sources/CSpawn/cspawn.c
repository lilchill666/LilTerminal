#include "include/cspawn.h"

#include <signal.h>
#include <stdlib.h>
#include <unistd.h>
#include <util.h>

pid_t lilterm_spawn_session(const char *path,
                            char *const argv[],
                            char *const envp[],
                            int master_fd,
                            int slave_fd,
                            const char *directory) {
    pid_t pid = fork();
    if (pid != 0) return pid;

    /* --- child --- */

    /* A GUI parent may have signals blocked or ignored, and exec preserves
       both. A shell that starts life ignoring SIGINT is a bad shell. */
    sigset_t empty;
    sigemptyset(&empty);
    sigprocmask(SIG_SETMASK, &empty, NULL);
    for (int signo = 1; signo < NSIG; signo++) signal(signo, SIG_DFL);

    /* setsid + TIOCSCTTY + dup2 onto 0/1/2. The reason this file exists. */
    if (login_tty(slave_fd) != 0) _exit(127);

    /* login_tty has rewired 0/1/2 from the slave. The master would otherwise
       stay open in the child, and the reader would never see EOF on exit. */
    close(master_fd);

    if (directory != NULL) chdir(directory);

    execve(path, argv, envp);
    _exit(127);
}
