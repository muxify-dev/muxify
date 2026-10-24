#ifndef MUXIFY_CONTROL_CLIENT_SPAWN_H
#define MUXIFY_CONTROL_CLIENT_SPAWN_H

#include <sys/types.h>

/// Runs `path` in a new session whose controlling terminal is a raw pty, with
/// stdin and stdout on the pty and stderr on /dev/null. Returns the child's
/// pid and stores the pty master, close-on-exec, in `*master`; returns -1
/// with errno set on failure.
pid_t muxify_forkpty_exec(const char *path, char *const argv[], char *const envp[], int *master);

/// Runs `path` in a new session whose controlling terminal is a pty, as a
/// terminal would, with stdin, stdout and stderr on it, so its questions,
/// such as git's and ssh's credential prompts, come through the pty. The pty
/// doesn't echo. Returns as `muxify_forkpty_exec` does.
pid_t muxify_forkpty_terminal_exec(const char *path, char *const argv[], char *const envp[], int *master);

#endif
