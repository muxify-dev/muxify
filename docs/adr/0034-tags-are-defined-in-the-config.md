# Tags are defined in the Config, and a Snooze by Tag is a Snooze of a set

> **Update 2026-10-20:** Cards show no Tags by default. `sidebar.tag_placement` is `none` (the default), `corner`, `title` or `line`. `corner` puts the Tag Marks at the right end of the title's first line on closed and open cards, so they never move to the Summary line. `title` chips also sit after the Pin or Lock. The `summary` value is gone, and an old Config that has it gets a Config problem with its line. Tag editing stays on whenever `topics.tags` exists.
>
> **Update 2026-10-20:** `display_name` is gone. A Tag shows as its key everywhere, and its only setting is `color`. An old `display_name` is a Config problem with its line (`unknown key`), and the Tag still loads with its colour. The palette draws Tag chips, Tag rows and the `#tag` part of Topic rows in the Tag's colour. A `color` can be a pair, `{light: …, dark: …}`, that follows the appearance.

A Topic can have Tags, such as `#backend`. Only the Tags that the Config lists in `topics.tags` exist. Each one can have a `color`, written as in `agent_colors`, and a `display_name` that shows in place of its name, as a Session Path alias does. Each Topic record keeps its own Tags in the field `tags`, so the record says which Topic has which Tag, and the Config says which Tags there are and how they look. Muxify suggests the Tags in Config order. A Tag with no Topic is still suggested. A Tag is lower case, with letters, digits and `-` only. A Config key that breaks this rule is a Config problem with its line number. When the Config has no `topics.tags`, Tags are off.

The user adds a Tag by typing `#` in a palette field (ADR [0014](0014-every-action-runs-in-the-palettes-view.md)). In New Topic, a word that starts with `#` is a Tag, not part of the title. The rows then show the Tags that match by name or display name, and ⇥ or ↩ makes the Tag a chip. A space after a complete Tag also makes it a chip. A `#word` that no Tag matches cannot become a chip, and ↩ does nothing while it is in the field. "Edit Tags…" uses one field that holds the Topic's Tags as chips: ⌫ removes a chip, and ↩ writes the result. To Snooze by Tag, the user picks a Tag row in the Snooze Topics pick step (ADR [0025](0025-a-pick-step-collects-topics-and-tags-as-chips.md)). The Tag chip names every Topic that has the Tag. The result is a usual Snooze of a set, with no record.

The Sidebar shows a Topic's Tags as Tag Marks: one small coloured square per Tag, in Config order, at the right end of the card's Summary. `sidebar.tag_placement` moves them: `summary` (the default), `title` (chips in the right corner of the title's first line) or `line` (chips on their own line under the title). The `topic.tags` Format part gives each Tag's text, with a `#{T:…}` loop over the Topic's Tags.

## Considered Options

- **Tags come from the Topic records, with no list of Tags.** This was the earlier decision. Rejected now: a typo makes a new Tag, a Tag has no colour or display name to give it meaning on a card, and a Tag goes away from the suggestions when its last Topic is Forgotten.
- **Free Tags, with presets in the Config that add a colour and a display name.** Rejected: the Tags still drift by typo, and a card can show Tags that have no colour, so Tag Marks lose their meaning.
- **A list of Tags in its own file that Muxify keeps.** Rejected: Muxify must then keep the list the same as the records. The Config is written by the user, so nothing has to match.
- **A choose-rows step for Tags in New Topic.** Rejected: it adds a step to every New Topic, also when the user wants no Tag. With `#`, a Topic with no Tag is made as before.
- **Chips in the Snooze search field.** Rejected for the same reason as in ADR 0020: ↩ and ⌫ would get a second meaning in the choose step. Chips are used only in a field whose value is the Tags.
- **One Tag for each Topic.** Rejected: a Topic can be in two groups, such as `#backend` and `#release`.
- **A Snoozed Tag that stays as a rule.** A Topic that gets the Tag later would also be hidden. Rejected: this is a second kind of Snooze beside `snoozed_until`, with a record to keep, as Zen has (ADR [0031](0031-zen-remembers-the-snoozes-it-changed.md)). It is not clear what a Topic with two Tags does when only one is Snoozed.
- **Filter by `#tag`, then ⌘A.** Rejected: the user must know ⌘A, and the set is not visible as one row.

## Consequences

- A record can hold a Tag that the Config does not define: an old record, or a Tag the user removed or renamed in the Config. Muxify does not change the record. The card shows that Tag dimmed and with no colour. Edit Tags can remove it, but nothing can add it again, and Go to… and Snooze Topics do not list it.
- `muxify topic tag` with a Tag that the Config does not define fails with an error that names `topics.tags`, and writes nothing.
- A Tag with no `color` gets a fixed colour made from its name, so two Tag Marks differ also without colours in the Config.
- Each App Window uses its Environment's Config (ADR [0010](0010-app-windows-use-their-environments-config.md)), so its Tags come from that Config.
- The pick step of Snooze Topics ([ADR 0025](0025-a-pick-step-collects-topics-and-tags-as-chips.md)) has three sections: **Tags**, **Topics** and **Already Snoozed**. ↩ on a Tag row makes the Tag a chip, which names all its Topics.
- A Topic that gets a Tag after a Snooze by Tag is not Snoozed.
- In Snooze Topics and Go to…, `#` in the query matches Tags, not words in titles.
- The CLI changes Tags through the Topic service (ADR [0032](0032-the-cli-runs-topic-requests-through-muxifycore.md)), as for the other Topic requests. A Tag change takes only the record lock, as a Snooze does. It writes one key of one record.
- In a field with chips, ⌫ in the empty field removes the last chip. When there is no chip, ⌫ goes back one step, as ADR [0014](0014-every-action-runs-in-the-palettes-view.md) says. ← and → select a chip, and ⌫ and ⌦ remove the selected chip (ADR [0025](0025-a-pick-step-collects-topics-and-tags-as-chips.md)).
- Go to… lists the Tags after the Topics, only for a query that is not empty. A Tag is not a place: it is a filter that leads to places. ↩ on a Tag row makes it a filter chip ("Go to… › #backend"), and the list then shows only the Topics with the Tag: open, Snoozed and Settled. ⌫ in the empty field removes the chip. ⌘K on a Tag row offers "Snooze its Topics…".
