---
fragment: 1f4cc900
generation: 0002
branch: master
---

+ Choose In Play
  A Command that sets which open Topics and Locked Sessions are In Play, and in what order. The user checks them, then chooses the one for each place in turn. The checked ones after the last place go to the top of the Bench.
  avoid: In Play Prioritisation Session, prioritise, reorder, Zen
  under: Topics

+ Replace from Bench
  An Action on an In Play Topic or Locked Session. A Benched Topic or Locked Session that the user chooses takes its place, and it goes to the end of the Bench.
  avoid: Done, Switch Topic Places, swap, Snooze
  under: Topics

- Snooze

- Unsnooze

- Zen

~ Next Topic
  The Topic or Locked Session that Muxify opens after the user Settles the Active Topic: the nearest row below it in the Topics list that stays in the list, else the nearest such row above it, else No Topic.
  was: The Topic or Locked Session that Muxify opens after the user Snoozes or Settles the Active Topic: the nearest row below it in the Topics list that stays in the list, else the nearest such row above it, else No Topic.

~ Topic Note
  An optional line of text on a Topic that tells the user what they were doing there, such as "Repro with seed 4411, then bisect". The user sets it, changes it or clears it. It stays through Dormant and Settle, so a Reopened Topic still shows it. Every card shows all of it on its own line, and a closed card shows it softer than the card of the Location.
  was: An optional line of text on a Topic that tells the user what they were doing there, such as "Repro with seed 4411, then bisect". The user sets it, changes it or clears it. It stays through Snooze, Zen, Dormant and Settle, so a Reopened Topic still shows it. Every card shows all of it on its own line, and a closed card shows it softer than the card of the Location.

~ Pin
  To keep a Topic above every Topic that is not Pinned, in each list of Topics, until you unpin it. A Pinned Topic is neither In Play nor Benched.
  was: To keep a Topic above every Topic that is not Pinned, in each list of Topics except the Snoozed Topics, until you unpin it. A Pinned Topic can be Snoozed as usual, and it is still Pinned when it comes back.

~ Locked Session
  A No Topic Session that the user Locked. It has a card among the Topics, but it is not a Topic: it cannot be Settled, Pinned or Forgotten.
  was: A No Topic Session that the user Locked. It has a card among the Topics, but it is not a Topic: it cannot be Settled, Snoozed, Pinned or Forgotten.

~ Mark All as Read
  A Command that clears Unread for all Topics and Agents in the Active Environment, including hidden, Benched and Settled Topics.
  was: A Command that clears Unread for all Topics and Agents in the Active Environment, including hidden, Snoozed and Settled Topics.

~ Action
  Something the user does to one Topic, Session, Window, Pane, Agent or Tab, such as Jump To, Rename, Replace from Bench or Settle. Every Action runs in the palette's view, whichever way the user starts it.
  was: Something the user does to one Topic, Session, Window, Pane, Agent or Tab, such as Jump To, Snooze, Rename or Settle. Every Action runs in the palette's view, whichever way the user starts it.

~ Row kind
  What one row of a Command Palette or of an Action's list is: `topic`, `settled`, `session`, `topic-session`, `session-path`, `worktree`, `window`, `agent`, `command` or `tag`. A list's `show` names the Row kinds that it lists. A running Session is a `topic-session` when its Topic is not Settled, and a `session` in all other cases. A checkout is a `worktree` when its folder is outside the folder of its Session Path, and a `session-path` in all other cases, so the checkouts inside a bare repository's folder are `session-path` rows.
  was: What one row of a Command Palette or of an Action's list is: `topic`, `snoozed`, `settled`, `session`, `topic-session`, `session-path`, `worktree`, `window`, `agent`, `command` or `tag`. A list's `show` names the Row kinds that it lists. A running Session is a `topic-session` when its Topic is not Settled, and a `session` in all other cases. A checkout is a `worktree` when its folder is outside the folder of its Session Path, and a `session-path` in all other cases, so the checkouts inside a bare repository's folder are `session-path` rows.

~ Check step
  A palette step that lists Topics and Locked Sessions with a box on each, before an Action on the checked ones. Choose In Play starts with it.
  was: A palette step that lists Topics with a box on each, and Tag rows that check or uncheck all their Topics in the list, before an Action on the checked Topics. In Snooze Topics, a Tag row does not check its Already Snoozed Topics. The user checks each of them by its own row. A Tag row is not a member of the set. Snooze Topics and Unsnooze Topics start with it.
