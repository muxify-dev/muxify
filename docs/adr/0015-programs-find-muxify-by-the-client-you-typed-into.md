# Programs find Muxify by the Client you typed into

> **Superseded in part by [ADR-0056](0056-programs-find-muxify-by-the-server-it-shows.md):** the check no longer follows the Client you typed into. It answers for the server that a Muxify Client is attached to. The markers stay as this decision describes them.

A program in a Pane, such as an Agent skill that wants to show a page, must know if the user runs it from Muxify, so that it opens the page in that Window's Browser and not elsewhere. Each Muxify Client sets a server option `@muxify_client_<nonce>` whose value starts with its Client PID, and removes it when its connection retires. A program lists the Clients of its own Session with `tmux list-clients -t "$TMUX_PANE" -F '#{client_activity} #{client_control_mode} #{client_pid}'`, ignores control-mode Clients, and takes the one with the newest activity: the Client you typed into. It is in Muxify only when that PID is in a `@muxify_client_*` option. The check needs only the `tmux` binary, the same as Extensions ([0004](0004-agents-report-status-through-pane-options.md)), so it also works on a remote machine, where Muxify installs no helper ([0006](0006-remote-environments-use-owned-ssh-connections.md)). The marker also says whether the Environment is local or remote, because a page served on a remote machine must use an address that the Mac can reach.

## Considered Options

- **An environment variable on Muxify's Client.** Rejected: Pane processes get the server's environment, not the Client's, and a variable that reaches the server marks every later Pane, also in Ghostty.app.
- **One server option that says Muxify is connected.** Rejected: a skill run from Ghostty.app on the same server would also open its page in Muxify, which the user does not look at.
- **The Muxify app PID as the marker.** Rejected: for a Remote Environment the program runs on another machine, where that PID means nothing. A Client always runs beside its server, and a Client that died is not in `list-clients`, so a marker left by a crash never gives a false yes.
- **One shared option with a set of PIDs.** Rejected: App Windows would race on the read-modify-write. One option per Client has one writer.
- **A `muxify browser available` CLI command.** Rejected: remote machines have no Muxify CLI, and a second way to check would drift from the protocol. [0017](0017-muxify-browser-available-runs-the-client-check.md) adds it on the Mac, beside the script, with a check that both give the same answer.

## Consequences

The answer is for the moment of the check. A long run started in Muxify that checks after you typed in another terminal gets no, so programs check when they start. When no Client shows the Pane's Session, because Muxify shows another Session, the check takes the newest Client on the server ([0021](0021-the-client-check-falls-back-to-the-newest-client-on-the-server.md)).
