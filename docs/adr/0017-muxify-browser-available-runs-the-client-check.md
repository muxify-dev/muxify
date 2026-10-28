# `muxify browser available` runs the Client check

> **Superseded in part by [ADR-0056](0056-programs-find-muxify-by-the-server-it-shows.md):** the command and the script run the server check, and the command exits 2 when it cannot read tmux.

[0015](0015-programs-find-muxify-by-the-client-you-typed-into.md) rejected a `muxify browser available` command, so a program on the Mac had to copy the tmux check script from `docs/configuration.md`. Agent instructions then need a copy of that script outside Muxify, which nobody keeps in step with Muxify. We add the command. It runs the same check as the script: the newest non-control Client of the Pane's Session, matched against the `@muxify_client_*` options, with the fallback to the newest Client on the server from [0021](0021-the-client-check-falls-back-to-the-newest-client-on-the-server.md). It prints `local`, `remote` or `no`. It exits 0 for `local` and `remote`, and 1 for `no`, so a shell can use it in `if`. The tmux script stays the protocol: a program on a machine without the Muxify CLI, such as a remote machine, still uses it. One e2e check runs the script and the command on the same Clients and expects the same word, so the two cannot drift apart.

## Considered Options

- **Keep only the script ([0015](0015-programs-find-muxify-by-the-client-you-typed-into.md)).** Rejected: each program on the Mac keeps its own copy of 35 lines of shell.
- **Ship the script in the app bundle.** Rejected: a command is easier to find in `muxify --help` than a file path, and its output is the same.
