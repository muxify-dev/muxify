# Default keybindings keep Ghostty's defaults reachable

> **Update 2026-10-26:** `toggle_focus` takes `cmd+0` by default, by the user's choice. This breaks the rule below: `cmd+0` is Ghostty's only default key for `reset_font_size`, so Muxify's default hides it. A user who wants it back gives `toggle_focus` another key, or gives `reset_font_size` a key in the Ghostty config.

Muxify's keybinds act before the Terminal, the Browser and the menu see a key. So a Muxify default on a Ghostty default key removes that Ghostty function. Three defaults did this: Move Topic Up/Down took `goto_split:up/down`, Maximize took `toggle_split_zoom`, and the Git View took terminal search Next.

We decide that a Muxify default must not use a key that Ghostty's defaults use. There is one exception: Muxify can take the key when the Ghostty function still has a key, either another Ghostty default or a Muxify Action. Inside this rule, a key tells the level and the direction. Brackets mean previous or next, with `cmd+shift` for Windows and Tabs and `ctrl+cmd` for Topics. Arrows mean move or resize.

- A key that steps to the previous or next Window steps to the previous or next Tab while the Browser has Focus. This holds for Ghostty's `previous_tab` and `next_tab` keys and for every key that the Config gives to `select_prev_window`, `select_next_window`, `select_prev_topic_window` or `select_next_topic_window`. Windows and Tabs keep one set of keys, so a user who moves the Window keys moves the Tab keys too.
- `ctrl+cmd+[` and `ctrl+cmd+]` go to the previous or next Topic.
- Move Topic Up/Down moves to `ctrl+alt+cmd+up/down`, so `alt+cmd+up/down` is Ghostty's `goto_split:up/down` again.
- Maximize keeps `shift+cmd+enter`. Zoom of a Pane moves to `cmd+m`, through a Muxify Action. This hides macOS Minimize while the Terminal has Focus.
- The Pane Actions, Zoom and resize, act only while the Terminal has Focus. With other Focus, the key goes on as usual, so `cmd+m` still Minimizes from the Browser.
- Resizing a Pane uses Ghostty's own `ctrl+cmd+arrows`, and Muxify sends Ghostty `resize_split` to tmux.
- The Git View keeps `cmd+g`, because people already use it. While the Browser's find bar or the Terminal's search is open, `cmd+g` goes to them as Find Next.
- `cmd+n` opens New Topic, and New App Window moves to `cmd+shift+n`.

## Considered Options

- **`cmd+[` and `cmd+]` for Windows and Tabs by default.** Rejected: in the Browser they are Back and Forward, and a user who wants them for Windows can set them in the Config. The Tab keys then follow.
- **Separate Config keys for previous and next Tab.** Rejected: a Window key and a Tab key that differ make the user think about Focus before each press.
- **`cmd+shift+arrows` for resize.** Rejected: in a web text field these keys select to the start or end of a line, and Muxify would take them from the page.
- **A new key for the Git View.** Rejected: people use `cmd+g` already, and the search case keeps Find Next while a search is open.

## Consequences

- While the Browser has Focus, a Window step key cannot reach a Window. `cmd+1` … `cmd+9` still can.
- A user who has learned the old keys must learn the new ones. The docs and the Config template show only the new defaults.
- The `alt+1` … `alt+9` Tab keys, `cmd+shift+t`, `cmd+shift+r` and the `cmd+s` keys do not change here. They clash with common expectations, not with Ghostty, and the Tab keys are part of the Hint design.
