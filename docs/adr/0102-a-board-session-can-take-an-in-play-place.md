# A Board Session can take an In Play place, and the Bench holds only Topics

> Supersedes in part [ADR-0061](0061-a-guest-is-in-play-above-the-limit-and-keeps-its-position.md), [ADR-0081](0081-in-play-is-the-only-topics-mode.md) and [ADR-0101](0101-a-guest-session-lives-in-the-state-database.md): a Session's card is no longer always a Guest, the list of cards is the Board, and the Guest Session is a Board Session.

A No Topic Session could have a card only as a Guest. Muxify called it a Locked Session, and the user saw a Guest Session (ADR-0061, ADR-0081, ADR-0101). To give the Session an In Play place, the user had to make a Topic from it. That changed the card and what it meant: a Topic has a title, and the user can Settle it. The user wants a Session to take an In Play place and stay a Session.

We let a Session's card take an In Play place. A card is now an open Topic or a **Board Session**, so the list of cards gets a name that is not about Topics: the **Board**.

- **One kind of card.** A Board Session is a No Topic Session that has a card on the Board, live or Dormant. Its card takes an In Play place or is a Guest, by the rules of a Topic's card. Move Up and Move Down, Trade, Fill an Open Place, Choose In Play and Make a Guest work on it as on a Topic. Its row in the state database, in the `board_sessions` table, has a `guest` mark, as a Topic record has. Make a Guest of a No Topic Session that has no card makes a Board Session at the end of the Guests.
- **The Bench holds only Topics.** A Board Session has no record to wait on the Bench. Bench takes its card off the Board: a live Session stays as a No Topic Session, and a Dormant one is gone. Each move that would send it to the Bench does the same: Move Down from the last Guest, a Trade with a Benched Topic, Replace from Bench, and Choose In Play when it held a place and gets none. There is no new Action. The Open Place page lists the Guests, Topics and Board Sessions, then the Benched Topics. Replace from Bench and the Bench section list only Topics. When the user makes `topics.in_play` smaller, a Board Session past the last place shows among the Guests.
- **The places stay.** A Board Session that leaves an In Play place, by Bench or because its card leaves the Board (its Session goes into a Topic, or the user kills it), leaves an Open Place there, as a Topic does.
- **A new Topic from a Board Session** takes its place and its section: its In Play place, or its place among the Guests. This replaces the Guest mark that ADR-0094 and ADR-0096 give to that Topic.
- **The Topic Actions stay with Topics.** Settle, Pin, Forget, the Topic Note and Tags take a Topic only. A Board Session is never Pinned.
- **Dormant.** Reopen, Start Fresh and `topics.reopen_at_launch` work on a Dormant Board Session in a place as among the Guests. Its page in the Terminal's place offers Reopen and Start Fresh, as the page of a Dormant Topic does. Start Fresh creates its Session again with its name, its folder and one shell Window, by the rule of a Topic's Start Fresh, and the card keeps its place. The palette offers both, and `muxify topic start-fresh --board-session <id>` does the same.
- **The card.** On the Board, a Board Session's card shows a small terminal glyph before its title. A Topic's card has none. The Sessions view does not change.
- **The name.** The Sidebar view is the Board everywhere a user or a script sees it: Switch to Board, the pager button, the menus, the errors, the CLI help and the docs. The Config key `sidebar.topics` and the `topics:` key of a mapping by view are `board`. Muxify still reads the old keys, with a Config problem that names the new key, and still reads the stored view choice "Topics". The keys about Topics (`topics.in_play`, `topics.reopen_at_launch`, `topics.tags`) and the `muxify topic` verbs stay.
- **The protocol.** One capability, `board`, covers the `board_sessions` event of the `environment` subscription, the `dormant_session` cards and the `board_session` target and card of an `environment` request. The CLI takes `--board-session <id>`. A client that did not declare `board` gets no `board_sessions` event and no `dormant_session` card. In an In Play place it gets an Open Place card in the place of a Dormant Board Session, so the place numbers stay; a fill of that place fails, because the place is not open.
- **An older Mac.** Nothing changes for it. Each Window of a live Board Session keeps `lock_order`, so an older Mac shows the Session as a Guest, also when it holds an In Play place.

## Considered Options

- **Make a Topic automatically when a Session takes a place.** Rejected: the card and what it means change without the user's choice.
- **Let a Board Session wait on the Bench, and add a Remove from Board Action.** Rejected: the Bench is for Topics. A Session on a hidden Bench is easy to forget, and the user needs one more Action to end it.
- **Call it a Session card.** Rejected: the Config key `sidebar.session_cards` uses that name for the cards of the Sessions view.
- **Add a capability beside `guest-sessions`, and a new step of the state database.** Rejected: no release has `guest-sessions` or the `guest_sessions` table, so their names change in place.

## Consequences

- A user who had a Session in a place through a Topic only can now keep the Session without the Topic.
- A Config that sets `sidebar.topics`, or `topics:` in a mapping by view, shows a Config problem until the user writes `board`.
- A program that read `guest_sessions` or sent `guest_session` before a release must use `board_sessions` and `board_session`.
- An older Mac shows a Board Session in a place as a Guest, and an older phone does not show a Dormant one.
