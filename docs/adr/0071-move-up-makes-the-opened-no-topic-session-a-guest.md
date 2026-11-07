# Move Up makes the opened No Topic Session a Guest

With `topics.in_play` set, Move Topic Up on a Benched Topic makes a Guest ([ADR-0070](0070-move-up-and-move-down-cross-the-in-play-lines-one-section-per-step.md)). The opened No Topic Session, which is a Session in no Topic that is not Locked, has no card in the Topics list. Move Up did nothing on it, so the user needed another Command to make it a Guest.

We make Move Up on the unlocked No Topic Session Make a Guest. A Session is a Guest through its Lock, so the step Locks it, and it goes to the end of the Guests. Move Down on it does nothing, because the Session has no card below.

- **App.** Move Topic Up is enabled on the opened No Topic Session with `topics.in_play`. Move Topic Down is not.
- **CLI.** `muxify session move up` does the same step. `muxify session move down` keeps its error: the Session has no card in the Topics list, and the user must Lock it first.
- **One rule.** MuxifyCore decides the step for both (`TopicCards.stepUnlockedSession`), so the CLI and the Sidebar cannot disagree ([ADR-0039](0039-the-cli-can-do-what-the-command-palette-can-do.md)).
- **Without `topics.in_play`.** No change. Move stays disabled, and Lock Session is the way.

## Considered Options

- **Move Down Unlocks or Locks the Session.** Rejected: Down goes toward the Bench, and an unlocked Session is already below every card. A Down that Locks it would go the wrong way.
- **The CLI keeps refusing.** Rejected: the CLI and the Sidebar would disagree about one card.
- **Lock to the top of the Guests.** Rejected: Lock Session puts a Session at the end of the Guests, and Make a Guest on a Session is a Lock.

## Consequences

- Move Topic Up is enabled at one more card.
- The step goes back with the opposite key: the Session is the last Guest, and Move Down from the last Guest is Bench, which Unlocks it.
