#ifndef LILTERM_CSPAWN_H
#define LILTERM_CSPAWN_H

#include <sys/types.h>

/**
 * Forks a child on the far side of a pty, with that pty as its controlling
 * terminal, and execs into it.
 *
 * This exists because `posix_spawn` cannot do it. Claiming a controlling
 * terminal needs TIOCSCTTY from inside the child, and there is no spawn file
 * action for an ioctl. POSIX_SPAWN_SETSID gets as far as making the child a
 * session leader; on Linux opening the tty would then finish the job, but on
 * BSD and macOS the ioctl is required. `login_tty` is setsid + TIOCSCTTY +
 * wiring stdin/stdout/stderr, which is what every terminal emulator does here.
 *
 * Everything between fork and exec is async-signal-safe. Callers must build
 * argv and envp before calling.
 *
 * @return the child pid, or -1 on failure to fork.
 */
pid_t lilterm_spawn_session(const char *path,
                            char *const argv[],
                            char *const envp[],
                            int master_fd,
                            int slave_fd,
                            const char *directory);

#endif
