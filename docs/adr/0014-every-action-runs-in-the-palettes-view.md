# Every Action runs in the palette's view, and Commands are a Source

> **Update 2026-10-20:** Move Topic Up and Move Topic Down are now palette Commands that run at once, with the keybindings `move_topic_up` and `move_topic_down`. The Sidebar's Move Up / Move Down stay as well. Sort Sessions by Creation still stays outside the palette.

Muxify used to ask for input in many ways: sheets (New Topic, Add a Session Path, Snooze, Zen, Settle, Forget), `NSAlert`s with a text field (Rename Topic, Rename tmux Window, New Topic from this Window), confirm alerts (Kill Window), and context menu items that ran at once. We make every Action on a Topic, Session, Window, Pane, Agent or Tab run in the palette's view. The view is the one that Go to… and Move use, so the keyboard never leaves it and every Action has the same keys. There are three ways to start an Action: ⌘K on a Command Palette result, a direct keybinding for the thing the user looks at now, or the Sidebar and menu bar items, which stay. An Action runs at once, or in steps of three kinds: choose a row (Move, Add a Session Path, Snooze until), type one value in the search field (Rename, New Topic), or confirm what will happen (Settle, Forget, Kill Window). Esc always closes and changes nothing, ⌫ in an empty field goes back one step, and a step that kills a process needs ⌘↩. The `commands` Source lists app operations and entries that start an Action on the current item, without selecting a search result first. Go to… opens with it off. Without a `command_palettes` section there are now two palettes: Commands, with only the `commands` Source, on ⌘⇧P, where most editors open their commands, and Go to…, with `topics` and `sessions`, which moves from ⌘⇧P to ⌘P.

This is the rule for new work too: a new Action or Command is designed as palette steps. A sheet or an alert that takes input needs its own ADR that says why the palette's view cannot do it. An alert that only reports an error stays an alert.

This extends [0012](0012-topics-are-a-source-of-the-command-palette.md) and does not replace it. Move is still not a Source: it is an Action, now on a Pane and a Window as well as a Session. Error alerts, and the Sidebar's Move Up / Move Down and Sort Sessions by Creation, stay outside the palette. They are messages, or they change an order that the palette does not show.

## Considered Options

- **A sheet for each new feature, as before** (for example a Move Pane sheet). Rejected: each sheet has its own look and its own keys. Move, Add a Session Path and Snooze were already search lists, so most of the sheets did the palette's job a second time.
- **Keep Settle, Forget and Kill Window as sheets and alerts.** Rejected: one view for every Action was the goal, and ⌘↩ makes the user stop before a kill, as a sheet does.
- **No Commands Source.** Rejected: then the palette cannot do everything, and Commands stay in the menu bar only.
- **Keep Go to… on ⌘⇧P and give Commands another key.** Rejected: ⌘⇧P opens the commands in most editors, and ⌘P is their way to go to a file, which matches Go to….
- **Go to… opens with Commands on.** Rejected: Go to… is a search for places, and Command rows would come between Topics and Sessions.

## Commands for the current item

The Commands Source also offers Actions on the current Pane, Window, Session, Topic or Tab. These entries use the same steps as row Actions and direct shortcuts. Move Pane with Active Tab starts Move with Pane and Tab selected. Commands that need an unavailable item are omitted. Back from an input step returns to the Commands search. A Command row can have a ⌘↩ variant beside its ↩ form. The variant is the form that stops processes, so it takes the key that a kill takes, and it opens its confirm step: Remove Session from Topic removes on ↩, and ⌘↩ opens Remove from Topic and Kill. The note under the list names both keys while the row is highlighted. A menu has no modifier key, so the ⌘K row Actions and the Sidebar menu show the variant as a separate item.
