# A pick list shows only the Row kinds that its Config names

Go to… lists every running Session, also the Sessions in Topics. The user goes to such a Session through its Topic, so these rows only push the rows the user wants further down. Add a Session lists running Sessions and Worktrees next to Session Paths, but the user almost always adds a Session Path. Before this change, the Config could not remove rows of one kind from a list. Only a Command Palette had Config keys, and the Action lists used fixed rules.

## Every row has a Row kind

A row has exactly one Row kind: `topic`, `snoozed`, `settled`, `session`, `topic-session`, `session-path`, `worktree`, `window`, `agent`, `command` or `tag`. The Row kind decides the row's icon, the title of its ↩ Action, and if `show` lists it. It replaces the earlier `PaletteItem.Kind`, so the filter and the icon cannot disagree.

A checkout is a `worktree` row only when its folder is outside the folder of its Session Path. The checkouts inside a bare repository's folder, such as `main`, are `session-path` rows. For a bare repository, they are the folders that the user opens, so `show: [session-path]` must keep them.

A running Session is a `topic-session` when its Topic is not Settled. A Snoozed Topic's Session is a `topic-session`. A Locked Session and the Session of a Settled Topic are `session`. Move's destination list uses the same rule.

## A list takes `show` and `tiebreak`

- A Command Palette in `command_palettes` takes `show`, the Row kinds that it lists.
- The new section `pick_lists` names an Action's list and takes `show` and `tiebreak`. The list names are `add_session`, `move`, `move_session`, `snooze_topics`, `unsnooze_topics`, `unsnooze_topic`, `tags` and `worktree_start`.
- A list with no `show` lists every Row kind, and a list with no `tiebreak` uses the default list from [ADR 0049](0049-a-query-ranks-by-score-across-the-palettes-rows.md). So a list without an entry keeps the order it had before.
- `show` filters ranked rows only. Fixed rows, such as New Topic and New Session, always show.
- A list accepts only the Row kinds that it can show. An unknown list name, an unknown Row kind, or a Row kind that the list cannot show is a Config problem. A bad `pick_lists` entry does not apply. A bad `show` in a palette drops the palette, as every other palette problem does.

## A Session Path hides only behind a Session row that shows

Go to… hides a Session Path row when a Session with its launch name runs, because the Session row stands for it. If `show` hides that Session row, the Session Path row shows again. Without this rule, `show: [session-path]` would hide a folder whose Session runs.

## Every ranked list has a name in code

The ranker does not run without the rules of a named list. A new Action's list therefore gets a `pick_lists` name and its Row kinds when it is made, and the compiler finds each place that lists them. A list that holds only fixed rows, such as a confirm step, has no name, because nothing in it is filtered or ordered.

## Considered Options

- **Order by Row kind (`kind: [session-path, session]`), move `score`, score bands, a reverse switch, an alphabetical rule, and a separate order for the empty query.** Not chosen: the user needs to remove rows, not to order them. These rules can come later with no change to `show`.
- **Keep `PaletteItem.Kind` and add a Row kind beside it.** Rejected: two labels on one row can disagree.
- **Filter in each list's builder.** Rejected: a new list would get `show` only when its author remembered to add it.
