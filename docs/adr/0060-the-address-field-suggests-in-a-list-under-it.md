# The address field suggests in a list under it

[ADR 0014](0014-every-action-runs-in-the-palettes-view.md) says that a new surface that takes input needs its own ADR. This is that ADR for the suggestions of the address field.

While the address field of a Tab has Focus and its text is not the URL of the Tab, a list under the field shows Suggestions for the text ([ADR 0059](0059-browser-history-ranks-pages-by-a-decaying-score.md)). A Suggestion is a History entry, a host or path from Browser History, an open Tab of the Window, a dev server port of the Window, or the search row. The list shows eight Suggestions at most. While Browser History is off, the list never shows, also for the open Tabs, the dev server ports and the search row.

- ↓ and ↑, or ⌃N and ⌃P, select a Suggestion. The field then shows its URL.
- ↩ opens the selected Suggestion. An open Tab is shown, not loaded again, as `Browser.open(_:)` does for a URL that is open. With no selection, ↩ opens the text, as before.
- ⎋ first closes the list, then gives back the URL of the Tab, as before.
- A click on a Suggestion opens it.
- The list closes when the field loses Focus.

**Inline completion.** When the first Suggestion is a tier 1 host or path, the field completes the text to it, and selects the added part. Typing goes on over the selection. ⌫ removes the completion, and the field does not complete again until the user types a letter. A paste does not complete.

The list is in the Browser, under its own field. It never takes Focus from the field, and it never shows while the Terminal or a Command Palette has Focus.

## Considered Options

- **Open Location as a step of the palette's view, with Sources for Tabs, Browser History and dev servers.** Not chosen by the user. It obeys ADR 0014 and uses the palette's ranking and keys. But the user looks at the address field when typing a URL, and a browser user expects the Suggestions there.
- **Both: the palette step for ⌘L, the list for a click in the field.** Rejected: two ways to do one thing, with two sets of keys.
- **No inline completion.** Rejected: with it, `gi↩` opens `github.com`, which is the main gain of the host Suggestions.

## Consequences

- The address field gets its own key handling for ↓, ↑, ⌃N, ⌃P and ⎋ while the list shows. The Browser keybinds ([ADR 0042](0042-pane-and-browser-keybinds-act-only-while-their-side-has-focus.md)) do not act while the field has Focus, as before.
- The palette's view stays the place for Actions. The list only opens a URL. It has no Actions.
