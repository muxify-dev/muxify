# The Browser

Muxify shows a Browser beside each tmux Window. Drive the Browser of your own Window with `muxify browser` commands, one step for each command. The user sees the same page, with their logins. Use these commands for browser work in place of Playwright or another browser.

1. Open your own Tab: `muxify browser open --json <url>`. It returns after the page loads and prints `{"id":…,"url":…,"title":…}`. This Tab is your Agent Tab, and the next commands act on it.
2. Read the page: `muxify browser snapshot`. It prints an accessibility tree. Each element has a Ref, such as `[ref=e3]`.
3. Act with the Refs:
   - `muxify browser click e3`
   - `muxify browser fill e4 'text'` sets a field's value. For a select, give an option's value or label.
   - `muxify browser press Enter [e4]` sends a key to the Ref, or to the focused element. Enter in a field submits its form.
4. Wait for the result: `muxify browser wait --text 'Saved'`, `--selector '<css>'` or `--load`. The default limit is 10 s; `--timeout <seconds>` changes it.
5. Check: run `snapshot` again, run `muxify browser eval '<js>'` (an expression, or statements with `return`; `await` works; prints JSON), or run `muxify browser screenshot [--out file.png]` and read the PNG at the printed path.

A Ref is valid until the Tab loads a new document. After a navigation or a reload, run `snapshot` again. `muxify browser tabs --json` lists the Window's Tabs; `--tab <id>` acts on another Tab of your Window.

The events are DOM events (`isTrusted` is false), and the commands see only the main frame, not iframes. When a page ignores them, use `eval`, or ask the user to do the step.

