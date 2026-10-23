# End-to-end checks

These checks drive a Debug build of Muxify in a sandbox. Each suite is one file in `suites/`. Each check is one `test_` method.

## Run checks

Run all suites:

```sh
make verify
```

Run one suite, or a list of suites:

```sh
make verify SUITE=topics_cards_sidebar
make verify SUITE="topics_cards_sidebar command_palette"
```

`make verify` runs each suite in its own process, and 10 suites at the same time (`run.py`). Set `MUXIFY_VERIFY_JOBS` to change the number. With all suites at the same time, the Mac starts processes so slowly that checks fail by chance. It writes one line when a suite ends. The full output of a suite goes to `build/verify/<suite>/last-run.log` in the checkout, so runs in two checkouts at the same time do not overwrite each other's logs. When a suite fails, `make verify` also writes that output.

A suite that fails runs again alone after the others. When it passes then, the last line names it as FLAKY, and its first output stays in `first-run.log`. `make verify` fails only when a suite fails again. A FLAKY suite has a check that depends on timing: find the cause, do not ignore it.

Run one check. Build the app first, because this command does not build it:

```sh
make build
python3 -m unittest -v scripts.verify.suites.topics_worktrees_sidebar -k badge
```

Run these commands from the repo root. `-k` selects every check whose name contains the text.

Each run of a suite keeps its files in `/tmp/muxify-verify/<suite>/<run-id>/`. The app log is `logs/app.log` in that directory. The directory stays after the run, so you can read the log. The next run of any suite deletes it.

When a driver command times out, read `logs/app.log` and `driver/stall-<n>.txt` in that directory. The driver logs a command that took over a second, and writes a `sample` of the app each time its main thread has not reached the driver for two seconds.

## Add a suite

1. Make a file `suites/<feature>_<surface>.py`. Do not add `__init__.py`.
2. Import the sandbox with `from scripts.verify.sandbox import Sandbox, wait`.
3. Write one `unittest.TestCase` class.
4. In `setUpClass`, make the sandbox with the module name: `Sandbox(__name__.rsplit('.', 1)[-1])`. Two suites with different names can run at the same time.
5. Call `cls.addClassCleanup(sandbox.teardown)` on the next line. `tearDownClass` does not run when `setUpClass` fails.
6. Make the fixture that all checks share, for example the Config and the Session Paths. Then launch the app once.

`make verify` waits for the slowest suite, so keep each suite under about a minute. When a suite grows past that, split it by feature. If the parts share a fixture, put it in a `TestCase` without checks in a module beside `sandbox.py`, not in `suites/`, and make the Sandbox with `Sandbox(cls.__module__.rsplit('.', 1)[-1])`. Example: `topics_sidebar.py` and the `topics_*_sidebar` suites.

`make verify` finds the new file. You do not change the Makefile.

## Add a check

- Test one behavior in each check.
- Name the check for that behavior. Use the terms in `CONTEXT.md`. Example: `test_session_with_unknown_topic_stays_under_no_topic`.
- Make the fixture state that the check needs in the check. Use Session and Topic names that no other check uses. The check must pass alone and in any order.
- Assert the end result that the user sees: a row in the Sidebar, a tmux option, a file. Use `self.assert*`. Put the values that explain a failure in the assertion message.
- Send every tmux command through `sandbox.tmux` or `sandbox.tmux_ok`.
- Find UI elements by their accessibility identifier. If an element has no identifier, add `.accessibilityIdentifier(...)` to the SwiftUI view.
- Use generous time limits. The app reads tmux once per second, so a limit under 2 seconds is not reliable.
- Do not sleep for a fixed time to let the app see a change. Wait for what the app shows: `sandbox.wait_shown(window)` after you move the client, or `sandbox.wait_rows(...)`. Sleep only before you assert that something did not happen.
- If a check fails because of a known app bug, mark it `@unittest.expectedFailure`. Write a one-line comment above it that names the bug. When the bug is fixed, the run reports "unexpected success". Then remove the mark.

## Do not take focus

Checks run while the user works. A check must not take the keyboard focus, the mouse or the front position from the user.

- `Sandbox.launch` starts the app in the background through LaunchServices (`open -g`). Do not start the app in a different way.
- Use the driver commands: `dump`, `press`, `set`, `focus`, `action`, `click`, `drag`, `hover`, `snapshot` and `responder`. `action` performs a named accessibility action of an element: `sandbox.act('action', '<identifier>', '<action name>')`.
- `hover` puts the pointer on an element for the app's hover tracking, without moving the real pointer: `sandbox.act('hover', '<identifier>')`. A later `hover` on another element moves it there.
- `snapshot` draws the App Window into a PNG, without a screen capture, so it needs no screen recording permission: `sandbox.act('snapshot', '<identifier>', '<path>.png')` keeps only that element, and an empty identifier keeps the whole App Window. Use it for a picture of a visual change; a check asserts on the dump, not on pixels.
- `responder` gives the class name of the first responder of each visible App Window, such as `TerminalSurfaceView` or `WKWebView`. Use it to find which view has Focus: `sandbox.driver('responder')['responders']`.
- `click` sends a mouse down and a mouse up to the centre of an element, without the pointer: `sandbox.act('click', '<identifier>')`. Use it to test a gesture, because `press` performs the element's accessibility action and skips the gesture. `command_key=True` holds ⌘ through the click. The same first-click rule as for `drag` applies.
- `drag` drags an element to another element without the pointer: `sandbox.act('drag', '<source>', '<destination>')` releases in the upper quarter of the destination, and `edge='bottom'` releases in its lower quarter. `hold=<seconds>` keeps the press still that long before it moves, as a long press does. The app stays in the background, so the source's gesture must take the first click (`takesFirstClick` in `UI/SidebarView.swift`). A system drag session follows the real pointer, so `drag` cannot drive it.
- The Sidebar lists build only the rows they show, so a row far down is not in a dump. `sandbox.reveal('<identifier>')` scrolls the row to the top of its list, without the mouse or the keyboard, and returns the rows; every driver command takes the same `reveal=True` option.
- The driver has no command that types keys or opens a context menu, because these take the keyboard and the mouse. Do not add one.
- If a behavior is only available through a context menu, give the view an accessibility action with `.accessibilityActions` or an identifier. Then use `action` or `press`. In the suite, write which view you changed and why. Example: `topicMembershipActions` in `UI/TopicMembershipMenu.swift`.

## What to keep

Commit a check that must stay true with the feature that it checks. Keep a one-off probe in the run directory. Do not commit it.

## Accessibility permission

SwiftUI makes the accessibility tree of an App Window only after an accessibility client outside the app asks for it. Before that, the driver sees an App Window with no elements. So `Sandbox.launch` runs `ax_wake.swift`, which asks the app for its windows, and then waits until the driver sees the elements. `Sandbox.launch` compiles it with `swiftc` into `~/Library/Application Support/MuxifyVerify/ax-wake-<hash>`, once for each version of the source. Every worktree with the same source uses the same file.

macOS checks the Accessibility permission of the app that started the terminal, or the tmux server, that runs the checks. If that app has the permission, the helper needs none. If that app has no permission, or has quit, the helper starts itself again as its own responsible process, and macOS checks the helper.

So allow the helper once: in System Settings > Privacy & Security > Accessibility, click +, press ⌘⇧G and paste its path. Without the permission, `launch` stops with the message "the driver sees no SwiftUI elements" and the path to allow. When `ax_wake.swift` changes, the helper gets a new name, and you allow the new file.

## Sandbox guarantees

A `Sandbox` gives each run its own root, tmux server, Config, state and app copy. `Sandbox.tmux` always names the sandbox socket with `-S`, so it cannot reach the default tmux server. The app copy has a bundle id for that run only. The Debug-only `TestDriver` (`Sources/Muxify/App/TestDriver.swift`) refuses to start if `TMUX` is set or if `TMUX_TMPDIR` is outside the sandbox. Under the `TestDriver` the app starts its tmux server with `-f /dev/null`, so the user's tmux config and its hooks do not act on the sandbox server. `teardown` stops only the processes that the sandbox started, by PID: the app, its tmux clients, the tmux server and each process whose command line or environment names the sandbox directory.

## Clean-up of dead runs

Each root has the file `owner.json`. It holds the PID and the start time of the process that owns the `Sandbox`. Before a new `Sandbox` makes its root, it sweeps `/tmp/muxify-verify/*/<run-id>/`:

- If the owner process runs and has the same start time, the run is live. The sweep does not touch it.
- If the owner process is gone, or its PID now belongs to a later process, the run is dead. The sweep runs `teardown` for that root and checks that the tmux socket is inside the root before `kill-server`. Then it deletes the app's defaults and LaunchServices entry, and deletes the root. It deletes `owner.json` last, so the next sweep finishes a sweep that stopped halfway.
- If a root has no `owner.json`, the sweep deletes it only when the root is older than 60 seconds (`OWNERLESS_GRACE`). A run writes its owner file immediately after it makes its root, so a run that is starting is never swept.
- If processes of a dead run do not stop, the sweep keeps the root and writes a warning. The next sweep tries again.

`suites/harness.py` checks this: a run whose owner is killed with `-9` is swept, and a live run is not.
