# Colour Reports are written without waiting, by the screen in use

> Supersedes, in [ADR-0095](0095-the-screen-in-use-writes-the-colour-report-last.md) "The screen in use writes the Colour Report last", the report before each switch, the report after the next read, and the wait for tmux's answer. The rule that the screen in use writes last stands.

Muxify wrote a Colour Report before each switch that it started and waited for tmux's answer, so a program that asked at the switch got Muxify's colours. The wait counted tmux's answers. When a long report overflowed the Listener's pty, the rest of a line was lost, the count never caught up, and every later switch waited a full second before it ran. With 11 and 8 Panes in two Sessions this happened after about ten switches.

We decide that the key App Window's Listener writes Colour Reports **without waiting for tmux**, and that a switch never waits for one. The Listener writes the background and foreground of its Terminal to every Pane of the Terminal's Session:

- **before a switch Muxify starts**, on its own connection, followed by the switch itself;
- **when it hears `%client-session-changed` for its Terminal** and has not written that Session for the move already, after it moves there ([ADR-0097](0097-the-listener-follows-the-terminals-session.md)). This covers a switch made inside tmux;
- **when another screen's control Client detaches** (`%client-detached`), such as Muxify Mobile's, whose Colour Report would stay on the Panes. A control Client with `ignore-size` is a Listener, not a screen, and its detach does not count, so a Listener that starts again never makes another screen write;
- **when the App Window becomes key, and when Ghostty's colours change**;
- **before Muxify types a command into a Session that it just made**, such as Reopen, to that Pane, also without waiting.

It also writes every Pane of the Window that the Terminal shows **when the Mac's user changes the focus there**: when it hears `%window-pane-changed` or `%session-window-changed` in the Terminal's Session and Muxify started the change or the Terminal had the user's key or mouse input in the half-second before. tmux does not say which Client made a focus change: a control Client's `select-pane` changes neither its `client_activity` nor the Window's latest Client, measured on tmux 3.8. So only the screen whose user made the change knows it, and only that screen writes. A focus change that another screen makes, such as Muxify Mobile, is that screen's to write.

**The next key takes the colours back, as it takes the size back.** tmux resizes a Window to the Client whose user typed last, but it never asks a terminal for its colours again once a Colour Report is on the Pane. So the Listener marks the Window that the Terminal shows as **taken** when it hears a focus change there that the Mac's user did not make, when another Client moves into the Terminal's Session, or when the Window takes a size that is not the Terminal's. The Terminal's next key or mouse input writes every Pane of that Window once and clears the mark. Muxify Mobile's `sizing.reclaim()` does the same for the size. The check on each key is as cheap as it can be: one Boolean read on the main thread, with no tmux call, no lock and no allocation; the Listener's events set the mark, and only a key that finds it set does any work.

**The Mac app decides; the publisher reports and writes.** The publisher, on this Mac and in the Host Server alike, does not decide whose focus change it heard. It tells its subscriber that the focus changed in a Window, or that a Window is taken, and writes a Window's Panes when the subscriber asks. The Mac app decides by the rules above. So this Mac and a Remote Environment have one decision path.

On a Remote Environment, the Mac sends its Terminal's colours to the Host Server in a protocol request, `colours`: when it connects, when the App Window becomes key, and when Ghostty's colours change. The colours request can name a Window to write; the Host Server sends the Mac its focus-changed and taken events on the `focus` subscription. The Host Server's publisher writes the Mac's colours by the rules above, and a switch that the Mac starts runs on the Host Server's Listener after the report, as on this Mac. The protocol version and `min_protocol` go up together, to 2, with no fallback for an older Host Server or an older Mac. This closes issue #149.

Measured on tmux 3.8, on throwaway servers: tmux sends the colour-scheme notice (`?997`) to a program with mode 2031 at the switch itself, when the Terminal's theme differs from the kind the Pane was last told, and a Colour Report that changes the kind sends the notice too, but only when the kind differs from the one last told. So a report written after a switch comes too late for a program that asks at the switch: it gets the old report, and the later report sends no notice. **A switch Muxify starts therefore runs on the Listener's own connection, after the report**: tmux runs one connection's commands in order, so the program gets the new colours at the notice, and still nothing waits. A switch made inside tmux (prefix `s`) can only be written after the move.

## Considered Options

- **Wait for a marker command's answer**, so a lost answer fails only its own batch. Rejected: it keeps a wait on every switch, and the measurement shows the wait buys nothing for a change of look.
- **Keep the count, and reset it on a timeout.** Rejected: late answers then end a later wait early.

## Consequences

- A switch is never held up by a Colour Report, and the Diagnostics log has no "colour report" timeout line.
- The Mac and Muxify Mobile follow the same rules, so the colours on a Pane are those of the screen whose user acted last there.
- After a switch made inside tmux, a program that asks at the switch's notice gets the old colours until it asks again.
- The Listener's writes never cut a line: what the pty does not take waits and goes when the pty can take more.
- A Mac and a Host Server of different builds do not connect.
