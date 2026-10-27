# Find in Pane searches through tmux copy mode, from a find bar over the Terminal

The Terminal is one tmux Client. Ghostty's own search (`start_search`, ⌘F) finds only the screen that tmux draws, not a Pane's history, and the screen mixes every Pane of the Window. So ⌘F in the Terminal found nothing useful.

We decide that Find in Pane searches the history of the current Window's active Pane through tmux copy mode. tmux finds the matches, highlights all of them with `copy-mode-match-style`, and scrolls the Pane to the current one. Muxify types nothing into the Pane. It runs `copy-mode`, then `search-backward-incremental` with the query as plain text, then `search-again` for Find Next and `search-reverse` for Find Previous. tmux ignores case unless the query has a capital letter.

- The query is typed in a find bar of our own, the bar of Find in Page ([ADR 0033](0033-find-in-page-uses-a-find-bar-above-the-page.md)). The user reads a match and steps to the next one while the field stays open, so the palette's view cannot do it, as for Find in Page ([ADR 0014](0014-every-action-runs-in-the-palettes-view.md)).
- The bar floats over the top right corner of the Terminal. A bar above the Terminal would make the tmux Client one row shorter, and tmux would reflow every Pane of the Window each time the bar opens or closes.
- `find_in_pane` opens the bar. Its default is ⌘F, and it acts only while the Terminal has Focus ([ADR 0042](0042-pane-and-browser-keybinds-act-only-while-their-side-has-focus.md)). With the Browser's Focus, ⌘F is `find_in_page`, which opens Find in Page. Ghostty's `start_search` opens Find in Pane too, so a Ghostty keybind for it keeps working. ⌘F is Ghostty's default for `start_search`. ADR 0043 lets Muxify take a Ghostty default key when the Ghostty function still has a key. Here Find in Pane does the job of Ghostty's search, and `start_search` reaches it.
- The keys of the find field are keybindings of their own, `keybindings.find`, for Find in Pane and Find in Page alike: ↩ goes to the next match, ⇧↩ to the previous one, and Esc closes the bar. They act only while the field has Focus, so every other key keeps its keybinding, and ⌘G is always the Git View. Esc is the one exception: in the Terminal it goes on to tmux, which gives it to the active Pane, and then Muxify asks tmux which Pane is active. When it is the searched Pane, its copy mode took the key, so the bar closes. In another Pane, such as an editor the user selected, Esc is that Pane's key, and the bar stays. A guess from Muxify's snapshot of tmux could be a second old, and holding the key until tmux answers could reorder it with the next keys.
- The find field counts as the Terminal's Focus. The keybinds for the Browser do not act while the user types a query, and the Focus marker stays on the Terminal.
- A new query starts again at the newest output, and Find Next goes up to older output. The bar numbers the matches from the newest, so the first match is "1 of N". tmux counts the matches (`search_count`) but does not say which one is current. Muxify counts the matches below the current one in `capture-pane`.
- Muxify sets the highlight colors, `ui.find_colors`, on the searched Pane as its own `copy-mode-match-style` and `copy-mode-current-match-style`, and removes them when the bar closes. tmux's defaults use the terminal's palette and read badly on a light theme. Each highlight has one color in every theme, and the text is black or white for contrast. A Pane option leaves the user's tmux styles to every other Pane and to copy mode outside Find in Pane.
- With emacs keys, which tmux takes when `EDITOR` names no vi, a search down lands after the match and finds the match under the cursor. Find Previous then moves one cell right, searches down and searches up once, so every step lands on the start of a match with vi and emacs keys alike.
- The search stays in the Pane that it started in until the bar closes. Closing the bar leaves copy mode, so the Pane shows its newest output again. Going to another Window closes the bar.

## Considered Options

- **Ghostty's own search.** Rejected: it searches the Client's screen. tmux keeps the history, and Ghostty never sees it.
- **Search the text of `capture-pane` in Muxify and draw the highlights ourselves.** Rejected: Muxify would have to scroll the Pane and draw over cells that tmux owns. Copy mode already does both, and the user's `copy-mode-match-style` applies.
- **The incremental search prompt of tmux (`C-r`) in the Pane.** Rejected: it shows a prompt in tmux's status line, not a field with a count, and it needs keys typed into the Pane.
- **A bar above the Terminal, as Find in Page has above the page.** Rejected: it changes the Client's size, so tmux reflows the Panes.
- **⌘G and ⌘⇧G for Find Next and Find Previous while the bar is open**, as ADR 0043 planned for the Terminal's search. Rejected: they took ⌘G from the Git View while a search was open, and ↩ and ⇧↩ in the field do the job.
- **A light and a dark color for each highlight.** Rejected: one color is simpler to set, and the default yellow and orange with black text read well on light and dark themes.
- **Number the matches from the oldest, as tmux does.** Rejected: the search starts at the newest output, and "N of N" for the first match reads as the end of the list.

## Consequences

- A Pane in copy mode takes the keys typed in the Terminal as copy mode keys, as usual in tmux. `q` leaves copy mode while the bar stays open. The next step enters copy mode again with the same query.
- With output that arrives while the Pane is in copy mode, the count of the current match can be off by the matches in that output. tmux shows copy mode a copy of the history, and `capture-pane` reads the live Pane.
- A tmux older than 3.2 does not report `search_count`. The bar then shows "Not found" or nothing, and the highlight and the steps still work.
