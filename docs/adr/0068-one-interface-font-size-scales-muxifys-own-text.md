# One interface font size scales Muxify's own text

Muxify's own text was sized in code, apart from `ui.sidebar.font_size`. That setting reached only part of the Sidebar. Pane rows, Summaries of closed cards, Topic Notes, tag chips, the Bench and Guests lines, Hints and the Settle and Reopen links stayed at 9–13 points. On a large display, the Sidebar and the Git View read much smaller than a Terminal set to 18 points.

We decide that one Config value, `ui.font_size`, sizes all of Muxify's own text in an App Window. That is everything except the Terminal and the Browser's pages: the Sidebar, the App Window header, the Git View, the Command Palette, the Browser's tabs, toolbar and address field, and the overlays over them (Pills, the Config problems banner, find bars, Hints, hover labels, Empty Topic pages and the Reopen choice).

- The value is a base size in macOS points, like Ghostty's `font-size`. It is a number from 9 to 24, and fractions are allowed. The default is 12, and at 12 every surface is as it was designed. A value outside the range is a Config problem, and the default applies.
- Each text keeps its ratio to 12. The factor is `ui.font_size / 12`. The Git View's 13-point list rows are 16.25 points at 15, and the palette's 24-point search field is 30.
- Three kinds of size scale by the same factor: fonts, the symbols that sit beside text (button icons, chevrons, status dots), and every fixed height or width that holds text. The last includes row and bar heights, gutters, the corner of a card, popup widths, and the bounds of the Sidebar and the List pane. Paddings, spacing, logos and app icons do not scale. A scaled width never exceeds what the App Window can show.
- `ui.header_height` is a length at size 12, and it scales by the factor. Its own rule, a finite number of at least 24, does not change.
- If the user never dragged the Sidebar, its default width of 260 scales. A width the user dragged stays as dragged, pulled inside the scaled bounds only when it falls outside them.
- The Git View's code and diff text follows the Terminal's `font-size`, less one point, not `ui.font_size`, because code reads like the Terminal. Its line-number and marker gutters and its `@@` hunk header follow the code font, so large line numbers do not clip.
- `ui.sidebar.font_size` is gone. A Config that names it gets the problem `ui.sidebar.font_size is gone: use ui.font_size`, and its value does not apply, as for a removed keybinding name. `ui.sidebar.font_family` stays, for Sidebar text only.
- `ui.font_size` is a `ui` key, so a Remote Environment's App Window uses the value in that machine's Config ([ADR 0010](0010-app-windows-use-their-environments-config.md)). It is read from the App Window's own Config, never from the local one in a remote App Window.
- The size changes only in the Config. Like every Config value, a change applies live, without a change to selection, expansion or what is open. No keybind or Command steps it: ⌘+, ⌘− and ⌘0 are Ghostty's font-size keys for the Terminal ([ADR 0043](0043-default-keybindings-keep-ghosttys-defaults.md)), and Muxify never writes the Config.

## Considered Options

- **A size for each surface**, such as `ui.sidebar.font_size`, `ui.git_view.font_size` and `ui.command_palette.font_size`. Rejected: the user wants the whole interface bigger, and several values give several places to forget.
- **Keep `ui.sidebar.font_size` as an override on top of `ui.font_size`.** Rejected: two values that combine are harder to predict than one.
- **The interface follows the Terminal's `font-size`, with no setting of its own.** Rejected: proportional text at a Terminal's 18 points is much larger than 18-point monospaced text looks. Ghostty's ⌘+ and ⌘− also change one Terminal only, and Muxify cannot see that.
- **A unitless scale, such as `ui.text_scale: 1.25`.** Rejected: a size in points is easier to compare with the Terminal's `font-size`.
- **A full zoom that also scales paddings and spacing.** Rejected: larger text needs room to fit, but larger gaps between rows add nothing to reading.
- **Fonts only.** Rejected: fixed rows and bars, such as the Git View's 24-point list rows and the palette's 52-point rows, would clip.
- **`ui.font_size` local-only, like the `ghostty` section.** Rejected: ADR 0010 rejected per-setting overlays of a remote Config on the local one. A user who wants the same size on a remote sets it in that Config too.

## Consequences

- With a Remote Environment whose Config exists but leaves out `ui.font_size`, that App Window shows 12-point text beside a local App Window at another size.
- A Config with `ui.sidebar.font_size` shows a problem until the user moves the value to `ui.font_size`.
- New text in Muxify must take its size from the interface font size, not from a number in code. Only Git View code text takes its size from the Terminal.
- Changing Ghostty's `font-size` reaches the Git View's code text only on its next redraw, as before this decision.
