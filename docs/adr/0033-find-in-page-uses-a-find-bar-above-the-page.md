# Find in Page uses a find bar above the page, outside the palette's view

> **Update 2026-10-27:** In the Terminal, ⌘F opens Find in Pane, which searches the active Pane's history through tmux copy mode ([ADR 0051](0051-find-in-pane-searches-tmux-copy-mode-from-a-bar-over-the-terminal.md)). Ghostty no longer keeps ⌘F there. ⌘F in the Browser is the `find_in_page` keybinding. ↩, ⇧↩ and Esc in the find field are keybindings of `keybindings.find`, and ⌘G and ⌘⇧G no longer step through the matches, so ⌘G is always the Git View.

[ADR-0014](0014-every-action-runs-in-the-palettes-view.md) puts every Action that takes input in the palette's view, and says a field outside it needs its own ADR. Find in Page is that exception. The user types a query and then reads the page and steps through the matches while the field stays open. The palette covers part of the page, and Esc closes it, so the user cannot read a match and then go to the next one.

Find in Page uses a find bar of our own, above the page of the active Tab. A script in each frame of the page finds the matches in its frame and highlights all of them with the CSS Custom Highlight API. This API does not change the page's DOM. The bar shows the number of the current match and the number of all matches. ⌘F, ⌘G, ⌘⇧G and Esc have their usual macOS meaning. The shortcuts work only when the Browser has Focus. In the Terminal, Ghostty keeps ⌘F.

Find in Page searches every frame, also a sandboxed iframe from another origin. Pages such as a Lavish review show their document in such an iframe, and a search of the main frame alone found only the text around it. The app steps through the matches of all frames as one list: the main frame first, then the other frames in the order they loaded. A new query starts in the frame that the user last clicked, scrolled or typed in. Before that, it starts in the frame that shows the most of the page, so on a Lavish review it starts in the document, not in the conversation beside it.

## Considered Options

- **A "type one value" step in the palette's view.** Rejected: the palette hides the match, and stepping to the next match opens the palette again.
- **The macOS find bar (`NSTextFinder`) with `WKWebView` as its client.** This was the first decision. A spike on macOS 26.5 rejected it:
  - `WKWebView` does not declare `NSTextFinderClient`. It has the methods, so it works only when we set it as the client through the Objective-C runtime.
  - With WebKit's default settings, the bar finds all matches, but Find Next and Find Previous do not scroll the page.
  - The page scrolls only after the private `_setUsePlatformFindUI(NO)`. Then the page shows no highlight for the matches.
  - The verify harness cannot type into the system find field, because the field has no accessibility identifier.
- **`WKWebView.find(_:configuration:)` alone.** Rejected: it finds and selects one match at a time. It does not highlight all matches and does not give the number of matches.
