# Programs find Muxify by the tmux server it shows

[0015](0015-programs-find-muxify-by-the-client-you-typed-into.md) and [0021](0021-the-client-check-falls-back-to-the-newest-client-on-the-server.md) answered `local` only when the Client you typed into last was a Muxify Client. Agents in Muxify then often got `no`. An idle Ghostty.app Client on the Pane's Session, or one key typed in another terminal, was enough. And every tmux error looked like `no`: an Agent whose sandbox blocked the tmux socket, or whose `PATH` had no `tmux`, got `no` without a reason. The user wants one rule: an Agent that runs in Muxify opens its pages in Muxify.

The check now asks about the server. It answers `local` or `remote` when a `@muxify_client_*` marker names a non-control Client that is attached to the server now, and `no` when no marker does. Which Session that Client shows, and which Client had input last, do not count. Muxify shows every Window of the server and opens `@muxify_open` on any of them, so a page goes to that Window's Browser in either case. When a local and a remote Muxify both show the server, `local` wins, because the Mac reaches the server's pages directly. When the check cannot read tmux, `muxify browser available` prints tmux's reason on stderr and exits 2, and the script returns 2. The markers, the script in `docs/configuration.md` and the e2e check that runs the script and the command on the same Clients stay as [0015](0015-programs-find-muxify-by-the-client-you-typed-into.md) and [0017](0017-muxify-browser-available-runs-the-client-check.md) describe.

## Considered Options

- **Keep the Client you typed into, and let a newer Muxify Client win over the Session's Clients.** Rejected: one key in another terminal still flips the answer for an Agent in Muxify.
- **An environment variable in the tmux environment.** Rejected: a process keeps the value it started with. An Agent started before Muxify attached gets `no`, and an Agent that outlives Muxify gets `local`. Muxify also starts the server, so `MUXIFY_TERMINAL=1` is already in every Pane, also in Ghostty.app.

## Consequences

A page from a Session that you see only in Ghostty.app opens in Muxify's Browser for that Window, while Muxify shows the server. It waits there until you go to that Window in Muxify. A program on a server that Muxify does not show gets `no`, as before. The answer is still true only at the time of the check.
