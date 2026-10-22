# Topics are a Source of the Command Palette, and Move stays a separate picker

> **Update 2026-10-22:** The Topics Source now follows the Sessions Source's switching order on an empty query: other live Topics by most recent visit, the current Topic last among live Topics, then Dormant and Empty Topics. Activity breaks visit ties using the most active member Session. Pins still affect Sidebar order, not this palette order. Typed queries keep fuzzy ranking; equal matches prefer live entries, then visits and activity. Snoozed and Settled sections stay last. The Sessions Source's current model is recorded in [0037](0037-the-sessions-source-lists-sessions-individually.md).

Our Switcher and upstream's Command Palette (see `0009-command-palettes-are-defined-in-the-config.md`) were two searches on ⇧⌘P for nearly the same things. We retire the Switcher. Topics become a fourth Source, beside Sessions, Windows and Agents. The `topics` Source lists open Topics, Pinned first, where `topics` sits among the palette's Sources. Its Snoozed and Settled Topics come last, after every other selected Source, even when they match the query better: they are the fallback, seldom the place to go. The `sessions` Source has one row for each Session Path and Worktree, which holds the Sessions that start in it, as the Switcher had, and one row for each Session outside every Session Path. In Topics mode a Session Path row holds only No Topic Sessions. The Switcher's ⌃S Snooze and ⌃Y paste path become palette actions. The default palette, Go to…, opens with `topics` and `sessions` selected.

Move (⌘⇧M) does not become a palette or a Source. It starts from a Session the user already chose, and its rows are places to send that Session, not places to go. It uses the palette's view and search.

The palette ranks rows with our ranker, which keeps sections, matches each field and marks what matched. On an equal score, a row with a running Session comes before a Session Path with no Session, as upstream ranks, then the most recent visit, then the most recent activity.

## Considered Options

- **Keep the Switcher beside the palettes, on another key.** Rejected: two pickers to learn, two keybinding schemes, and the Agents and Windows Sources would be missing in Topics mode.
- **Make Move a Source.** Rejected: a Source lists things to go to and act on. Move asks one question about one Session.
