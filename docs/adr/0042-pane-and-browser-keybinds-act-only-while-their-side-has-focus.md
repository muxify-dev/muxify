# Pane and Browser keybinds act only while their side has Focus

Muxify's keybinds act before the Terminal, the Browser and the menu see a key. A keybind that acts everywhere takes its key from every side. Maximize had Ghostty's `toggle_split_zoom` key, `shift+cmd+enter`, so the user could not zoom a Pane by key. The next and previous Tab keys and Back and Forward were built into the code, so the Config could not change them.

We decide that an Action for one side acts only while that side has Focus. With Focus elsewhere, Muxify does not take the key, and Ghostty, the page or the menu gets it.

- `toggle_zoom_pane` and `resize_pane_left`, `resize_pane_right`, `resize_pane_up` and `resize_pane_down` act only while the Terminal has Focus. Zoom is on `cmd+m`, so from the Browser `cmd+m` still minimizes the App Window. Resize moves the Pane's border 10 cells, as Ghostty's `resize_split` does, and has no default key.
- `select_next_tab`, `select_prev_tab`, `browser_back` and `browser_forward` act only while the Browser has Focus. Their defaults are the keys that were built in: `cmd+shift+]` and `ctrl+tab`, `cmd+shift+[` and `ctrl+shift+tab`, `cmd+[` and `cmd+]`. In the Terminal, these keys stay Ghostty's next and previous Window and its previous and next Pane.
- A key that the Config gives to a Window step Action steps through Tabs while the Browser has Focus. Windows and Tabs then share one set of keys, and the user does not have to think about Focus before a press.
- `cmd+n` opens New Topic, and New App Window moves to `cmd+shift+n`. While no Action has `cmd+n`, `cmd+n` does nothing, so Ghostty's own `cmd+n` does not open an App Window.

## Considered Options

- **Give Pane Zoom `shift+cmd+enter` and move Maximize.** Rejected: people already use `shift+cmd+enter` for Maximize.
- **`cmd+shift+arrows` for resize.** Rejected: in a web text field these keys select to the start or end of a line or of the text.
- **Separate Tab keys only, with no pairing.** Rejected: one trigger cannot belong to two Actions, so a user who wants `cmd+]` for Windows and for Tabs could not set it.

## Consequences

- While the Browser has Focus, a Window step key cannot reach a Window. `cmd+1` … `cmd+9` still can.
- A Config that gives `cmd+[` or `cmd+]` to a Window step Action takes those keys from Back and Forward. Vim Keys H and L and the toolbar buttons still go back and forward.
- Other Muxify defaults still hide Ghostty defaults: `alt+cmd+up/down` (Move Topic) hides `goto_split:up/down`, and `cmd+g` (Git View) hides terminal search next. This ADR does not change them.
