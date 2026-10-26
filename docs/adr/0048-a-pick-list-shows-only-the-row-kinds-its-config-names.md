# A pick list shows only the Row kinds that its Config names

Go to… lists every running Session, also the Sessions in Topics. The user goes to such a Session through its Topic, so these rows only push the rows the user wants further down. Before this change, the Config could not remove rows of one kind from a list.

## Every row has a Row kind

A row has exactly one Row kind: `topic`, `snoozed`, `settled`, `session`, `topic-session`, `session-path`, `worktree`, `window`, `agent`, `command` or `tag`. The Row kind decides the row's icon, the title of its ↩ Action, and if `show` lists it. It replaces the earlier `PaletteItem.Kind`, so the filter and the icon cannot disagree.

A running Session is a `topic-session` when its Topic is not Settled. A Snoozed Topic's Session is a `topic-session`. A Locked Session and the Session of a Settled Topic are `session`. Move's destination list uses the same rule.

## A palette takes `show`

- A Command Palette in `command_palettes` takes `show`, the Row kinds that it lists.
- A palette with no `show` lists every Row kind. So a palette without `show` keeps the rows it had before.
- An unknown Row kind is a Config problem. A bad `show` drops the palette, as every other palette problem does.

## A Session Path hides only behind a Session row that shows

Go to… hides a Session Path row when a Session with its launch name runs, because the Session row stands for it. If `show` hides that Session row, the Session Path row shows again. Without this rule, `show: [session-path]` would hide a folder whose Session runs.

## Considered Options

- **Order by Row kind (`kind: [session-path, session]`), move `score`, score bands, a reverse switch, an alphabetical rule, and a separate order for the empty query.** Not chosen: the user needs to remove rows, not to order them. These rules can come later with no change to `show`.
- **Keep `PaletteItem.Kind` and add a Row kind beside it.** Rejected: two labels on one row can disagree.
