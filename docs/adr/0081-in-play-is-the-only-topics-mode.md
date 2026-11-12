# In Play is the only Topics mode

`topics.in_play` was optional, and it was off by default. So the Topics list had two modes. Without the key, the Sidebar showed every card in one list, a Locked Session kept a place among the Topics, and `topics.insert_position` chose where a new Topic went. With the key, the Sidebar showed the In Play places, the Guests and the Bench ([ADR-0055](0055-the-sidebar-shows-only-the-topics-in-play.md), [ADR-0064](0064-in-play-places-stay-open-and-guests-show-in-their-own-section.md)). Each rule of the list had two answers, and each new rule had to give both. The phone showed both layouts too.

We make In Play the only mode. The Topics list always has places, Guests and a Bench.

- **The number of places.** `topics.in_play` is a whole number of 1 or more. A Config that does not set it gets 5. A value that is not valid is a Config problem, and Muxify uses 5.
- **New and returning Topics.** They go to the top of the Bench. `topics.insert_position` is gone, and a Config that sets it shows a Config problem.
- **Guest Session is the user's word.** A No Topic Session with a card is a Guest Session. The user makes one with Make a Guest and ends it with Bench. The Lock Session and Unlock Session Commands, the `toggle_lock` action, the `lock_session` and `unlock_session` palette row actions, the Lock and Unlock items of the card menus, `muxify session lock`, `muxify session unlock` and the `muxify://topic/lock` and `muxify://topic/unlock` URLs are gone. A Config that binds a removed action shows a Config problem that names the action to use.
- **The Lock stays in the code.** A Guest Session is still a Session with `@muxify_lock` ([ADR-0018](0018-a-lock-lives-on-the-tmux-session.md)). Lock is the name of that tmux option and of the code that reads it.
- **One request for a card.** `muxify topic make-guest` and `muxify topic bench` take a Session as well as a Topic. For a No Topic Session, Make a Guest sets the Lock and Bench ends it. The Topic service has no separate lock and unlock requests.
- **The snapshot keeps its shape.** `muxify environment show --json` gives `unpinned.kind: "in_play"` with `limit`, `places`, `guests` and `bench`, as before. It does not give `kind: "list"` again.
- **Upgrade.** There is no prompt. The first Topics that are not Pinned take the places, in the order of the list. Each Locked Session becomes a Guest. The other Topics are on the Bench. When the app finds that the order on disk is not the order of the three sections, it writes that order once. A list that is already in that order does not change, so the app keeps no flag.
- **Sessions mode and Remote Environments** have no Bench, as before.

## Considered Options

- **Keep the key optional, and turn it on in the Config template.** Rejected: the code keeps two modes, and a user who writes a Config from nothing gets the mode that we do not improve.
- **Ask the user at the first launch which Topics are In Play.** Rejected: the order of the list already says which Topics the user works on. Choose In Play changes the answer in one Command.
- **Keep `topics.insert_position` for the place of a new Topic on the Bench.** Rejected: In Play ignored the key before. A new Topic at the end of the Bench is the hardest one to find.
- **Keep Lock Session as a second name for Make a Guest.** Rejected: two names for one Action make the user think that there are two states.
- **Keep `kind: "list"` in the snapshot type.** Rejected: nothing sends it, and a reader that must accept an older Host CLI keeps its own decoder.

## Consequences

- A user who had no `topics.in_play` sees at most 5 Topics that are not Pinned, and a Bench line for the others. No Topic is lost. The Bench line or ⇧⌘S shows them.
- A script that runs `muxify session lock` or `muxify session unlock` fails. It must run `muxify topic make-guest --session <name>` or `muxify topic bench --session <name>`.
- A program that reads the snapshot can remove its `list` path when it needs a Host CLI with this change.
- The text in ADR-0018, ADR-0054, ADR-0055, ADR-0061, ADR-0064, ADR-0069, ADR-0070 and ADR-0071 about a Config without `topics.in_play`, about `topics.insert_position` and about Lock Session and Unlock Session does not apply.
