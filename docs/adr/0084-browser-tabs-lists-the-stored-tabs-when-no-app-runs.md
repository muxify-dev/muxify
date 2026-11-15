# `browser tabs` lists the stored Tabs when no app runs

`muxify browser tabs` asked the app for the Tabs of a Window. When no app served the tmux server, the command failed. Muxify Mobile reads the Tabs of a Window with this command, through SSH on the Host. Without the app on the Mac, the phone showed no Tabs, also for Windows that had Tabs. The user wants the phone to work when the desktop app does not run.

The app already keeps each Window's Browser state on the Window, as tmux options ([0003](0003-browser-state-lives-on-the-tmux-window.md)). A program that runs `muxify browser open` while no app runs queues the URL in `@muxify_open` ([0057](0057-an-agent-drives-its-windows-browser-through-the-muxify-cli.md)). So tmux holds what the app shows when it starts.

The rules are now these:

- **The fallback.** When the CLI cannot reach the app, `tabs` reads `@muxify_tabs`, `@muxify_active_tab` and `@muxify_open` of the Window, and lists those Tabs. "Cannot reach" means that `@muxify_browser_socket` is empty, or that its socket does not accept a connection, as after the app stopped. An app that accepts the request and then fails is still a failure.
- **The same Tabs as the app.** The list is the stored Tabs, then each queued request, opened as the app opens it: a page that a Tab has already selects that Tab, a blank active Tab takes the page, and any other page adds a Tab and selects it. The app's Browser and the CLI use one rule for this, `TabOpening` in MuxifyCore, and one parser for a queued request, `Omnibox`.
- **No title, an id from the position.** tmux does not store page titles or Tab ids. A stored Tab has an empty title, and an id made from its position: `00000000-0000-0000-0000-000000000000` for the first Tab. The id is the same for each read until the Tabs change. Only `tabs` falls back. The other Browser commands need a page, so they still fail, and `--tab` with a stored id fails with them.
- **A read changes nothing.** The CLI does not clear `@muxify_open`. The app opens the queued pages when it starts, as before.

## Considered Options

- **The phone reads the tmux options itself.** Rejected: the phone would copy the storage format and the open rules of the desktop into a second repository, and they would drift apart.
- **List only `@muxify_tabs`.** Rejected: a page that an Agent opened while no app ran would be missing, and that is often the page that the user wants to see.
- **List the queued requests as they are, one Tab for each.** Rejected: an Agent that opens the same page four times gets one Tab in the app, so the list must show one.
- **Change the reply, so a stored Tab has no id.** Rejected: every client of `tabs --json` would need a change, and the phone reads `id` as a string.

## Consequences

- Muxify Mobile shows the Tabs of a Window when the desktop app does not run, with no change on the phone. A Tab shows its address, because it has no title.
- The app's `Browser.open` and the CLI cannot disagree on where a queued page goes.
- The rule for a queued request moved from the app to MuxifyCore, with `TabURL.matchKey`, which History and Suggestions also use.
