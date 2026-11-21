# The header hides tmux's status line where the Terminal is

While `ui.status_line.enabled` is on, which is the default, the App Window's header shows the Session and its Windows. tmux's own status line then shows them a second time, under the Terminal. Users hid it with a hook in their tmux config that read `MUXIFY_TERMINAL`, and a user without a tmux config had no way to hide it. We decide that Muxify hides tmux's status line itself, on this Mac and on a Remote Environment's host, in each Session that its Terminal shows. The last terminal to arrive in a Session wins.

tmux's `status` belongs to a Session, not to a Client, so one Session cannot show a status line in iTerm and none in Muxify at the same time. Measured on tmux 3.8, on a throwaway server:

- **The publisher hides it.** The Listener ([ADR-0097](0097-the-listener-follows-the-terminals-session.md)) sets `status off` and the mark `@muxify_status_hidden` on the Terminal's Session: when the Terminal moves there, which covers a switch made inside tmux; when the Listener starts again inside it; and, before a switch that Muxify starts, on the Listener's own connection ahead of the switch, as the Colour Report is ([ADR-0098](0098-colour-reports-are-written-without-waiting-by-the-screen-in-use.md)). It hides it in no other Session.
- **Another terminal gets it back.** With the same commands, Muxify sets index 77 of the `client-attached` and `client-session-changed` hooks, so the user's own hooks keep theirs. The hook gives a marked Session its status line back (`set-option -u status`) when a Client arrives there that is neither a control Client nor a Muxify Terminal, whose environment has `MUXIFY_TERMINAL=1`. The hook lives in the server, so it works after Muxify quits too.
- **Muxify undoes only its own change.** The hook and the restore act only on a Session with the mark, and they unset the Session's `status`, so the global value from the user's tmux config shows again. A Session where the user's tmux config sets `status` itself keeps it.
- **Turning it off gives everything back.** When `ui.status_line.enabled` turns off, the publisher unsets `status` and the mark on every marked Session, also those that an earlier Muxify marked, and removes its hooks.
- **On a Remote Environment**, the Mac sends `status_line { hidden }` to the Host Server after each `hello` and when the Config changes it, and the Host Server's publisher acts as on this Mac. It is a new request, so it comes with the capability `status-line` (ADR 0086). The Mac declares `status-line` too, the first capability it declares, and sends the request only to a server that declared it. An older Host Server's Sessions keep their status line. A Sessions-only App Window has no publisher and keeps it too.

tmux reads a Client's environment in formats (`#{I/e:MUXIFY_TERMINAL}`) from 3.8 on. An older tmux takes every Client for another terminal, so the hook also gives the status line back when the Terminal arrives, and the publisher hides it again right after. The status line can then show for a moment on each move.

## Considered Options

- **`status off` on the whole server.** Rejected: iTerm or Ghostty.app on the same server would lose the status line too, and the user's tmux config would no longer decide it there.
- **Hooks alone, as the users' tmux configs did.** Rejected: before tmux 3.8 a hook cannot read a Client's environment, so it cannot tell the Terminal from another terminal, and the Remote Environment's host may run tmux 3.2.
- **The publisher alone, with no hook.** Rejected: a Session that Muxify hid the status line in would keep it hidden for iTerm after Muxify quits, until the user notices and sets it back.
- **Give a Session its status line back when the Terminal leaves it.** Rejected: another App Window's Terminal may still show it, and the last arrival wins anyway.

## Consequences

- A user who kept a status-line hook in their tmux config for Muxify can remove it.
- The publisher installs tmux hooks, which it did not do before. They are Muxify's only hooks, and turning `ui.status_line.enabled` off removes them.
- `shownWindow()` already reads the Client's `status`, so the Terminal's Window size stays right whether the status line shows or not.
- The fixtures folder `4-status-line` pins the new `hello`s and the request.
