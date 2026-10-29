# The Browser

Muxify shows a Browser beside each tmux Window. Drive the Browser of your own Window with `muxify browser` commands, one step for each command. The user sees the same page, with their logins. Use these commands for browser work in place of Playwright or another browser.

1. Open your own Tab once: `muxify browser open --json <url>`. It prints `{"id":…,"url":…,"title":…}`. Keep the `id`.
2. Give `--tab <id>` to every next command. Without `--tab`, a command acts on the active Tab, the one that the user sees, and the user can select another Tab at any time.
3. Read the page: `muxify browser snapshot --tab <id>`. It prints an accessibility tree. Each element has a Ref, such as `[ref=e3]`.
4. Act with the Refs:
   - `muxify browser click --tab <id> e3`
   - `muxify browser fill --tab <id> e4 'text'` sets a field's value. For a select, give an option's value or label.
   - `muxify browser press --tab <id> Enter [e4]` sends a key to the Ref, or to the focused element. Enter in a field submits its form.
5. Wait for the result: `muxify browser wait --tab <id> --text 'Saved'`, `--selector '<css>'` or `--load`. The default limit is 10 s; `--timeout <seconds>` changes it.
6. Check: run `snapshot` again, run `muxify browser eval --tab <id> '<js>'` (an expression, or statements with `return`; `await` works; prints JSON), or run `muxify browser screenshot --tab <id> [--out file.png]` and read the PNG at the printed path.

To go to another page in your Tab, run `muxify browser open --tab <id> <url>`. `open` without `--tab` opens a new Tab.

`open`, `click` and `press` return when the page has loaded, also when it goes on to another page with JavaScript. A link that opens a new window loads in your Tab. When `snapshot` says that the page shows nothing yet, run `muxify browser wait --tab <id> --load`, then `snapshot` again.

A Ref is valid until the Tab loads a new document. After a navigation or a reload, run `snapshot` again. `muxify browser tabs --json` lists the Window's Tabs, with `active` on the Tab that the user sees.

The events are DOM events (`isTrusted` is false), and the commands see only the main frame, not iframes. When a page ignores them, use `eval`, or ask the user to do the step.

