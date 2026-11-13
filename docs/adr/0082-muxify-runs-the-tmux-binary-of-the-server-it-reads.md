# Muxify runs the tmux binary of the server it reads

Muxify and the `muxify` command run the program that the tmux server was started from, its Server binary. They find it from the server's socket: the process that listens on the socket, and that process's executable. With no server, they run the first tmux on `$PATH`, then one in the usual folders. A tmux failure other than "no server" is an error, not an empty snapshot.

A tmux of another release can fail on a server, even when both speak the same protocol version. On a Linux Host with tmux from Linuxbrew, the old fixed list found `/usr/bin/tmux` before `$PATH`. That tmux 3.4 could not talk to the Linuxbrew tmux 3.6a server and said "server exited unexpectedly". `TmuxServer.snapshot()` dropped that error and gave an empty snapshot, so `muxify environment show --json` exited 0 with no Sessions, and the phone showed "No Sessions".

The lookup uses `/proc/net/unix` and `/proc/<pid>/fd` on Linux, and libproc on macOS. The answer is kept for each socket file, so the app's many tmux calls do not scan processes. A server that restarts makes a new socket file, and it is looked up again. A Linux server whose program file was replaced runs from `/proc/<pid>/exe`.

tmux answers a refused connection, such as a stale socket file, with "no server running". That is "no server", not an error. Any other failure, such as a tmux of another version or a socket that tmux may not open, throws `TmuxError.serverFailed`. Its text names the tmux that failed. `environment show --json` then exits non-zero with that text in `failed.message`, which the phone shows.

## Considered Options

- **A fixed list of paths, then `$PATH`** (the old order). Rejected: it picks a tmux that the server may not match, and the user cannot change the order.
- **`$PATH` first, then the list.** Kept only as the answer when no server runs. Rejected as the whole answer: a non-interactive SSH shell has a short `$PATH`, and the first tmux on it is not always the server's.
- **A `MUXIFY_TMUX` variable that the phone sends.** Rejected: it needs a setting and a change in the phone, and the user must know which tmux the server runs.
- **Trying each tmux in turn until one works.** Rejected: each wrong tmux starts a process and fails, and a tmux that works is not known to match the server.

## Consequences

- No setting. The Server binary is a fact of the server, not of the user's `$PATH`.
- `muxify` in a Pane runs the tmux of the server in `$TMUX`, else of the default socket.
- A tmux call costs one `stat` of the socket when the answer is kept. The first call, and each call after a restart, scans the user's processes, those named `tmux` first.
- An update that replaces tmux under a running macOS server leaves the old program's path. If that file is gone, Muxify runs the searched tmux until the server restarts.
- The app's status line and the CLI's error name the tmux that failed.
