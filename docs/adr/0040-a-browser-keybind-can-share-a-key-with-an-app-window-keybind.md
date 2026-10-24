# A Browser keybind can share a key with an App Window keybind

Reopen Closed Tab wants `cmd+shift+t`, the key that browsers give it. Move Pane has `cmd+shift+t`, and people already use it. ADR 0039 says that one trigger cannot belong to two Actions, so one of them had to lose the key.

We decide that one trigger can belong to two Actions when they never act under the same Focus. An Action for one side, such as `reopen_closed_tab` for the Browser, can share a trigger with an Action for the other side or with an Action that acts everywhere. While its side has Focus, the Action for that side acts. With other Focus, the other Action acts. This amends "one trigger cannot belong to two Actions" in ADR 0039.

- `reopen_closed_tab` acts only while the Browser has Focus, and its default is `cmd+shift+t`. `move_pane` keeps `cmd+shift+t`. From the Browser, `cmd+shift+t` reopens the last closed Tab. From the Terminal, it opens Move for the Pane.
- Two Actions that can act under the same Focus still cannot share a trigger. The Config reports the second one as "already bound", as before. A Command Palette trigger shares with nothing, because it acts before every keybind.
- A trigger that the Config gives to an Action for everywhere, when the trigger is not that Action's default, takes the trigger from every default. So `new_topic: cmd+shift+t` makes a Topic from the Browser too. A trigger that the Config gives to an Action for one side takes the trigger only from a default for the same side.
- The keybinds answer "which Action acts on this trigger" with the Focus as input.

## Considered Options

- **Give Reopen Closed Tab another key.** Rejected: `cmd+shift+t` is what people press in every browser.
- **Move Move Pane off `cmd+shift+t`.** Rejected: people already use it.
- **Make `cmd+shift+t` a special case in the key handling.** Rejected: the Config could not change it, and the next shared key would need another special case.

## Consequences

- The menu shows `cmd+shift+t` on Move Pane and on Reopen Closed Tab. The keybinds act before the menu sees the key, so the Focus decides, not the menu.
- Closing the last Tab hides the Browser, and Focus goes to the Terminal. Then `cmd+shift+t` opens Move Pane. The Command Palette and the menu item still reopen the Tab.
- `cmd+n` does nothing while no Action acts on it under the current Focus. Before, a Browser Action on `cmd+n` let Ghostty's `cmd+n` open an App Window from the Terminal.
