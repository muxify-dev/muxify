# An Agent drives its Window's Browser through the Muxify CLI

An Agent in a Pane can open a page in its Window's Browser with `muxify browser open`, but it cannot read the page, click on it or see it. For that work, Agents start Playwright or another browser. That browser is not the user's: it has no logins, the user does not see what the Agent does, and it is one more large program to install. The user wants an Agent in Muxify to use the Browser of its own tmux Window, as Playwright drives a page.

The Agent drives the Browser with `muxify browser` commands, one step for each command, in the style of `playwright-cli`:

- `tabs` lists the Tabs of the Window. `open --json <url>` opens a Tab and prints its id.
- `snapshot` prints the page as an accessibility tree. Each element in the tree has a Ref, such as `e3`.
- `click <ref>`, `fill <ref> <text>` and `press <key> [<ref>]` act on the page.
- `wait --load`, `wait --text <text>` and `wait --selector <css>` wait for the page, until `--timeout`.
- `eval <js>` runs JavaScript in the page and prints the result as JSON. `screenshot` writes a PNG.

Muxify does these commands itself, in its `WKWebView`. There is no Chromium and no DevTools protocol.

**The channel.** The app serves a Unix domain socket next to the tmux server's socket: `<socket_path>.muxify-browser`. The tmux socket directory has mode 0700, so only the user can connect, and each tmux server gets its own path. The app writes the path into the server option `@muxify_browser_socket`, and removes the option when its connection to the server stops, as it does with `@muxify_client_*`. The CLI reads the option through `$TMUX`, so it finds the app of its own server with no Config. A request is one line of JSON, and the reply is one line of JSON, one request on each connection. The CLI and the app decode a request into one typed request, with one case for each command. A failure comes back as a message and the exit code for the CLI. Only the Local Environment has the socket now.

**The target.** A request has the caller's tmux Window and Pane, from `$TMUX_PANE` or `--window`. Several App Windows can show the same Environment, and each has its own Browsers. The App Window that consumes `@muxify_open` also gets the requests, so the Tab that an Agent opens is the Tab that its next command finds. The app remembers, for each Pane, the last Tab that the Pane opened: the Agent Tab. A command without `--tab` acts on the Agent Tab. When that Tab is gone, the command fails and tells the Agent to run `muxify browser open` or to give `--tab`. `--tab <id>` names any Tab of the Window.

**The page.** The code of `snapshot`, `click`, `fill`, `press` and `wait` runs in its own `WKContentWorld`, "muxify-agent", so the page cannot see it or change it. The map from Ref to element is in that world, so a Ref stays valid until the page loads a new document. `eval` runs in the page's own world, so it sees the page's own variables. `fill` sets the value through the element's own setter and sends `input` and `change`, so React and similar frameworks see the new value.

**Focus.** A command never activates the app, selects another Window or moves the keyboard focus. A Tab that opens in a Window that the user does not see stays there quietly, as `@muxify_open` does. When a page focuses an element, for example in `fill` or in its own click handler, WebKit makes AppKit focus the web view. So after each command, the app gives each App Window back the responder that it had before the command.

`muxify browser open` without `--json` also goes through the socket when the app serves it, so the Tab that it opens becomes the Agent Tab. When the app does not answer, it writes `@muxify_open` as before.

## Considered Options

- **Change the Browser to Chromium or CEF, and use the DevTools protocol.** Rejected: it replaces the whole Browser layer and adds about 200 MB to the app.
- **Headless Playwright next to Muxify.** Rejected: it is not the user's Browser, it has no logins, and the user does not see the page.
- **Safari's Remote Web Inspector protocol.** Rejected: it goes through the private `webinspectord` service, which can change with each macOS release.
- **tmux options as the channel.** Rejected: the app reads tmux once each second, so each step waits for the next read, and a large reply, such as a screenshot, does not fit well in an option.
- **A script runtime (`exec`) that runs many steps in one request.** Not now: one command for each step is easier for an Agent to follow and to correct. `eval` is the escape hatch.

## Consequences

- An Agent and the user see the same page, with the same logins.
- The events are DOM events, not system input. Their `isTrusted` is false, so a page that accepts only trusted input ignores them. `press` does not move the focus with Tab, and a key does not do what the browser does for it, except Enter, which submits the form of a field, Backspace, which deletes a character, and a character, which goes into a text field. There is no file upload and no drag.
- `snapshot` and the Refs see only the main frame, not the iframes.
- A Remote Environment has no socket yet. Later, the app can forward the socket with `ssh -O forward -R` on the SSH master that it owns.
