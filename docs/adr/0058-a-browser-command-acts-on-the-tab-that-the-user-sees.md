# A Browser command acts on the Tab that the user sees

[0057](0057-an-agent-drives-its-windows-browser-through-the-muxify-cli.md) gave each Pane an Agent Tab: the last Tab that the Pane opened. A command without `--tab` acted on it. This caused three problems:

- **Hidden state.** The Agent Tab was a map in the app's memory. The user and the Agent could not see it. A Tab that the user opened was not the Agent's, so a command without `--tab` could not read it.
- **Too early.** `open` replied when the first load stopped. A sign-in page with an empty body that goes on to the real page with JavaScript after its load gave an empty `snapshot`. `wait --load` had the same problem.
- **Lost pages.** A `target=_blank` link or `window.open` opened a new Tab and moved the focus to it, also during an Agent's `click`. The Agent's next command then read the old page. `open <url>` always made a new Tab, so an Agent could not go to another page in its own Tab.

The rules are now these:

- **The target.** `--tab <id>` names a Tab of the caller's Window. Without `--tab`, a command acts on the Window's active Tab, the one that the Browser shows. The Agent Tab is removed. `tabs` marks only the active Tab.
- **`open`.** `open <url>` opens a new Tab and prints its id. It keeps the rules of the Browser: it goes to a Tab that shows the URL already, and it uses the active Tab when that Tab is blank. It never replaces the page of a Tab. `open --tab <id> <url>` loads the URL in that Tab. Only the app can do this, so `open --tab` does not write `@muxify_open` when the app does not answer.
- **Loaded.** A page has loaded when no load runs, `document.readyState` is `complete`, and no navigation of the main frame started, committed, finished or failed in the last 400 ms. The Tab records the time of each of these events from its `WKNavigationDelegate`. The 400 ms start at the command, so a click whose navigation starts a moment later also counts. `open`, `click` and `press` reply when the page has loaded, or after 10 s, as before. `wait --load` waits until the page has loaded, and fails after `--timeout`. `wait --text` and `wait --selector` do not change.
- **Popups.** While a Browser command runs on a Tab, also while it waits for the load, a `target=_blank` link or `window.open` of that Tab loads in the same Tab. No Tab opens and the focus does not move. The user's own clicks and ⌘-click open a new Tab, as before.
- **An empty snapshot.** When the tree is empty, `snapshot` fails. The message names the page and tells the Agent to run `muxify browser wait --load` and then `snapshot` again.

An Agent that works in its own Tab runs `open --json` once and gives `--tab <id>` to each next command. The user can then go to another Tab, and the Agent stays on its page.

## Considered Options

- **Keep the Agent Tab, and show it in the Browser.** Rejected: it is still a second meaning of "the Tab" that the user must learn. `--tab` already names a Tab exactly.
- **`open` replaces the active page, and `--new-tab` opens a Tab.** Rejected: an Agent that opens a page must not replace the page that the user reads.
- **Wait for the network to stop, as Playwright's `networkidle` does.** Rejected: `WKWebView` does not tell the app about requests of the page, and a page that polls never stops.
- **Popups always load in the same Tab.** Rejected: a user who clicks a `target=_blank` link expects a new Tab.

## Consequences

- An Agent that gives no `--tab` follows the user. When the user selects another Tab, the next command reads that Tab.
- `open`, `click` and `press` take at least 400 ms.
- A page that goes on to another page more than 400 ms after its load, or after a `fetch`, is not caught. `wait --text` or `wait --selector` waits for it.
- A click by the user on a `target=_blank` link while a Browser command runs on the same Tab loads in that Tab.
