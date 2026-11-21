# The Listener follows the Terminal's Session

> Supersedes [ADR-0063](0063-the-control-client-listens-from-its-own-watch-session.md), "The control Client listens from its own Watch Session".

Muxify's Listener, its control-mode Client, no longer has a Session of its own. It sits in the Session that its App Window's Terminal shows and moves there each time the Terminal does. This is what Muxify Mobile's control Client does already. The Watch Session, `muxify-watch`, is gone on this Mac, on a Remote Environment's host and in Sessions-only mode, so all three work the same way.

ADR 0063 moved the Listener out of the user's Sessions because tmux took a control Client's background as black and answered a Pane's background question from it. That still holds on tmux 3.8, measured on a throwaway server: tmux answers a Pane with no Colour Report from the first Client in its client list that shows the Session, and a control Client that attached before the Terminal's makes the answer black. Two things make it safe to share the Session: Muxify writes a Colour Report for every Pane of the Session it moves to, which comes before any Client's answer, and the Listener starts again after the Terminal's Client appears, so the Terminal lists first and answers a new Pane with its own colours. The Watch Session cost a hidden Session that the snapshot, the bootstrap, the store and the CLI each had to leave out.

- **One per App Window.** Each App Window has its own Listener, on this Mac as on a host, and only the key App Window's Listener writes Colour Reports.
- **Which Client it follows.** The Listener follows the Client that its App Window's Client marker names. When it hears `%client-session-changed` for that Client, it moves to that Session. A move that Muxify starts and one made inside tmux, such as prefix `s`, are the same event.
- **Before the Terminal attaches**, and after the Terminal's Session closes, the Listener sits in the Session that tmux picks (`attach-session` with no target) and moves when the Terminal attaches. It hears every Session's notifications from any Session.
- **When no Session is left**, the Listener exits with the server, and starts again when a Session appears. Nothing keeps the server running. So no read finds the server running without the Terminal's Session after its last Window closes: on this Mac, the Terminal's tmux Client exit status tells the end of the last Session (0) from a killed server (1), as SSH's status does on a Remote Environment.
- **It stays out of the Terminal's way.** It attaches with `no-output,ignore-size`, so it gets no Pane output and never sizes a Window, and it attaches and moves with `-E`, so tmux copies none of its environment into the Session (`update-environment`), such as `MUXIFY_TERMINAL`.
- **On a Remote Environment**, the Host Server's Listener follows the Mac's Terminal on the host, found by the Client marker whose nonce comes in `hello`; one Listener per App Window. In Sessions-only mode, the Listener that the Mac runs over SSH follows it the same way.

## Considered Options

- **Keep the Watch Session.** Rejected: the black answer has a narrower fix (the Listener lists after the Terminal, and the Colour Report comes first), and every part of Muxify that reads Sessions had to hide the Watch Session.
- **Wait for the Terminal before listening.** Rejected: Muxify needs events from the start, before the Terminal attaches.

## Consequences

- The Listener shows in `list-clients`, and a Session it sits in counts it as attached (`#{session_attached}`), as Muxify Mobile's control Client does. Muxify's own reads leave out control Clients.
- When the Session that the Listener sits in closes, tmux detaches it or moves it, by the Session's `detach-on-destroy`. A Listener that tmux detaches while the server runs starts again at once, in the Terminal's Session, so it misses no event; only a start that fails waits a second before the next.
- On connect, Muxify kills a Session named `muxify-watch` that an earlier version left.
- A Session that only a Listener shows, before the Terminal attaches, answers a Pane with no Colour Report black.
- In Sessions-only mode, nothing writes Colour Reports, so a Pane there relies on the Listener listing after the Terminal until the Host Server starts.
