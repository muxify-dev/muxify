# Terminal visibility lives on the tmux Window

A Window can hide its terminal so that its open Browser takes the terminal's room. Whether it does is stored on the Window as the tmux window option `@muxify_terminal` (`off` while hidden, unset otherwise), next to the Browser state of ADR 0003 and for the same reasons: it lives and dies with the Window, a new Window starts with its terminal shown, and a reused window id can't inherit it. Muxify reads it in the snapshot it already polls and writes it straight from the App Window, as it does `@muxify_open` and `@muxify_agent_unread`. Until a snapshot reflects a change, the App Window keeps the value it set, so a snapshot already in flight doesn't undo it.

The terminal is only hidden while the Browser is open: `toggle_terminal` does nothing while the Browser is hidden, and closing the Browser (its last Tab, Hide Browser or `toggle_browser`) clears the option and brings the terminal back. A Window is never left showing nothing.

A hidden terminal stays laid out at no width rather than being removed. A zero size never reaches Ghostty, so the tmux client keeps its size and the Window's Panes don't reflow while hidden or when the terminal comes back. Ghostty is told the terminal is occluded so it stops drawing. Keyboard focus that would go to the hidden terminal, as on a Window switch, goes to the Browser's page instead; Focus Terminal brings the terminal back first.

## Considered Options

- **Per Session.** Rejected: the Browser is per Window, so a Session-wide flag would hide the terminal in some of its Windows and not others, depending on whether each has an open Browser.
- **Part of the Browser's own state (`@muxify_browser`, `Browser`).** Rejected: the Browser knows nothing about the terminal, and the rules connecting the two belong where the rest of that coordination is.
- **Per App Window, in memory.** Rejected: switching Windows would carry the choice to Windows it wasn't made for, and it would not survive a Muxify restart.
- **Shrinking the terminal to a minimum width.** Rejected: tmux would resize the Window and every Pane would reflow on each toggle.

## Consequences

Two App Windows showing the same tmux Window can briefly disagree after one toggles, until the other's next snapshot. Like the Browser state, it doesn't survive a tmux server restart.
