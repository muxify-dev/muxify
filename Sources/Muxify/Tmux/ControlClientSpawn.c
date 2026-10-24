#include "ControlClientSpawn.h"

#include <fcntl.h>
#include <signal.h>
#include <string.h>
#include <termios.h>
#include <unistd.h>
#include <util.h>

pid_t muxify_forkpty_exec(const char *path, char *const argv[], char *const envp[], int *master) {
    // Raw mode, so the pty passes tmux output through without turning "\n"
    // into "\r\n" and never echoes.
    struct termios raw;
    memset(&raw, 0, sizeof raw);
    cfmakeraw(&raw);
    cfsetspeed(&raw, B38400);
    sigset_t none;
    sigemptyset(&none);
    struct sigaction byDefault;
    memset(&byDefault, 0, sizeof byDefault);
    byDefault.sa_handler = SIG_DFL;
    int maxFD = getdtablesize();

    pid_t pid = forkpty(master, NULL, &raw, NULL);
    if (pid == 0) {
        // Only async-signal-safe calls from here on: the parent has threads.
        // A client that inherits an ignored SIGHUP would outlive the hangup.
        for (int sig = 1; sig < NSIG; sig++) sigaction(sig, &byDefault, NULL);
        sigprocmask(SIG_SETMASK, &none, NULL);
        int devNull = open("/dev/null", O_WRONLY);
        if (devNull >= 0) {
            dup2(devNull, STDERR_FILENO);
            if (devNull > STDERR_FILENO) close(devNull);
        }
        for (int fd = STDERR_FILENO + 1; fd < maxFD; fd++) close(fd);
        execve(path, argv, envp);
        _exit(127);
    }
    if (pid > 0) fcntl(*master, F_SETFD, FD_CLOEXEC);
    return pid;
}

pid_t muxify_forkpty_terminal_exec(const char *path, char *const argv[], char *const envp[], int *master) {
    // A wide window, so progress lines don't wrap, and a line-editing pty,
    // so a prompt reads a line; it doesn't echo the answers written to it.
    struct winsize size;
    memset(&size, 0, sizeof size);
    size.ws_col = 200;
    size.ws_row = 50;
    sigset_t none;
    sigemptyset(&none);
    struct sigaction byDefault;
    memset(&byDefault, 0, sizeof byDefault);
    byDefault.sa_handler = SIG_DFL;
    int maxFD = getdtablesize();

    pid_t pid = forkpty(master, NULL, NULL, &size);
    if (pid == 0) {
        // Only async-signal-safe calls from here on: the parent has threads.
        for (int sig = 1; sig < NSIG; sig++) sigaction(sig, &byDefault, NULL);
        sigprocmask(SIG_SETMASK, &none, NULL);
        struct termios mode;
        if (tcgetattr(STDIN_FILENO, &mode) == 0) {
            mode.c_lflag &= ~(ECHO | ECHONL);
            tcsetattr(STDIN_FILENO, TCSANOW, &mode);
        }
        for (int fd = STDERR_FILENO + 1; fd < maxFD; fd++) close(fd);
        execve(path, argv, envp);
        _exit(127);
    }
    if (pid > 0) fcntl(*master, F_SETFD, FD_CLOEXEC);
    return pid;
}
