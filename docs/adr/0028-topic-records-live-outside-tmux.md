# Topic records live outside tmux; the Topic link lives on the Session

A Topic's record is one JSON file in `$XDG_STATE_HOME/muxify/topics/`. The record holds the title, Home Session Path, dates, outcome, remembered Sessions, snooze time and position. A Session's link to its Topic is the session option `@muxify_topic <topic id>` on tmux. This is the first state Muxify keeps outside tmux, and it is an exception to ADR 0001. A Settled Topic has no Sessions, and a Dormant Topic lost its Sessions in a tmux restart. tmux cannot hold the record of a thing that has no Session. The link stays on tmux because the Session is the thing that comes and goes. When the Session is killed, or when tmux restarts, the link goes too, so Muxify never shows a stale membership. ADR 0003 uses the same reason for Browser state.

## Considered Options

- **All Topic state on tmux (server or session options).** Rejected: a tmux server restart erases the open Topics, and there is nowhere to keep a Settled Topic.
- **Membership in the record too (a list of Session names or ids).** Rejected: you can rename Sessions, tmux reuses ids after a restart, and a Session killed with tmux would stay in the list. Muxify would then have to reconcile two sources of truth on each snapshot.

## Consequences

- tmux is still the source of truth for what runs now. The record says only what to rebuild on Reopen. Muxify writes remembered Sessions when a Topic's Windows change, debounced, as it does for Browser state.
- Session names are labels. Muxify writes `<project>/<topic-slug>` when it creates a Session and when you rename a Topic, and it never parses a name.
- `muxify topic …` and Muxify both write the record files. Muxify watches the folder, so a CLI write shows at once.
