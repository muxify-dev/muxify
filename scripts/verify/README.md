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

The checks that fail run again, in `<suite>.rerun`. A rerun starts when the parallel pass has started every suite and at most 2 suites still run. When a check fails in a rerun that ran beside another suite, it runs once more, alone, after everything else, in `<suite>.alone`. When it passes in a rerun, the last lines name it as FLAKY. `make verify` fails only when a check also fails in its last rerun, and that run was alone. A FLAKY check depends on timing: find the cause, do not ignore it.

While it runs, `make verify` wakes the display and holds it awake with `caffeinate -u`. While the display sleeps, the app draws no frames, and checks fail that have no bug. The screen can stay locked: a locked screen turns the display off about ten seconds after a wake, and the held `-u` assertion stops that. A single check run with `python3 -m unittest` holds no assertion, so wake the display, or run it under `caffeinate -d -u`.

The runner stops a suite after 120 seconds without a check starting or ending. Import, discovery, and class fixtures have the same limit. Output does not extend it. A suite can take longer than 120 seconds while its checks make progress. After a timeout, the suite has 60 seconds to clean up before the runner kills its process group. The last completed checks and the active timeout remain in the results even if cleanup cannot finish. Previous suite times set the run order, not the timeout.

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
- To make the app show a Window before a check, use `sandbox.show(window)`. It asks the app, as `muxify window open` does. A `switch-client` to the Window that the client is already on does not move the client, so the app stays on an Empty Topic page.
- If a check fails because of a known app bug, mark it `@unittest.expectedFailure`. Write a one-line comment above it that names the bug. When the bug is fixed, the run reports "unexpected success". Then remove the mark.

## Topic records

The sandbox's Topic records are rows in `state/muxify/muxify.db`, the state database. Read and seed them through `TopicRecords` in `topic_records.py`, which uses Python's `sqlite3` and takes no lock of Muxify's own: `put`, `remove`, `get`, `ids` and `set_open_places`, and `held()` to hold the database's write lock for a block, as another process in a long transaction does. A record is a dict in the shape of the old `topics.json` entry. To prove the import of an old records file, write `state/muxify/topics.json` before the app's first launch, as `topics_reopen_at_launch` does: the first open of the database imports it and renames it to `topics.json.migrated`. The Muxify Worktree records are rows of the `worktrees` table there: read them through `TopicRecords.worktrees()`, as `worktrees_cli` does.

## Do not take focus

Checks run while the user works. A check must not take the keyboard focus, the mouse or the front position from the user.

- `Sandbox.launch` starts the app in the background through LaunchServices (`open -g`). Do not start the app in a different way.
- Use the driver commands: `dump`, `press`, `set`, `focus`, `action`, `click`, `drag`, `hover`, `snapshot`, `responder`, `scroll`, `stall`, `idle_clock`, `card_rebuild`, `binding` and `counts`. `action` performs a named accessibility action of an element: `sandbox.act('action', '<identifier>', '<action name>')`.
- `hover` puts the pointer on an element for the app's hover tracking, without moving the real pointer: `sandbox.act('hover', '<identifier>')`. A later `hover` on another element moves it there. When other windows cover the App Window whole, macOS marks it as not visible and SwiftUI sends its views no hover, so `hover` fails and says so: uncover a part of the App Window, for example make a window in front smaller.
- `snapshot` draws the App Window into a PNG, without a screen capture, so it needs no screen recording permission: `sandbox.act('snapshot', '<identifier>', '<path>.png')` keeps only that element, and an empty identifier keeps the whole App Window. Use it for a picture of a visual change; a check asserts on the dump, not on pixels.
- `set` replaces the text of a field: `sandbox.act('set', '<identifier>', '<text>')`. `paste=True` puts the text in at the caret and moves the caret after it, as ⌘V does: `sandbox.act('set', 'palette-search', 'a line\n', paste=True)`.
- `responder` gives the class name of the first responder of each visible App Window, such as `TerminalSurfaceView` or `WKWebView`. Use it to find which view has Focus: `sandbox.driver('responder')['responders']`. When the first responder is a field editor, `editors` has its `frame`, its `visible` part and the `field` it edits, in the field's points; an editor taller than its field draws text that the field cuts off.
- `scroll` scrolls the scroll view under an element so that the end of its content is `from_end` points below the bottom edge, without the pointer: `sandbox.act('scroll', 'topics-list', from_end=10)`. Use it to put a list in one exact place near its end. With `by`, it scrolls down by that many points in `steps` equal moves, one each tick of the driver, so the app draws a frame between two moves as under a wheel: `sandbox.act('scroll', 'topics-list', by=600, steps=20)`. The result's `seconds` is how long the moves took, which grows with the frames' lag.
- `counts` reads how often each counted view's body ran since the last reset (`BodyCount` in `App/BodyCount.swift`), as `{'TopicCard': 41, ...}` in the result's `counts`; `reset=True` resets them after the read: `sandbox.driver('counts', reset=True)`. Use it to prove that a scroll or a change does not draw a list's cards again. The counter is in every build and counts only while Diagnostics is on, so a suite that reads it sets `diagnostics.enabled: true` in its Config; the `minute` and `burst` records carry what it counted as `bodies=`, and a reset never makes them negative. To count a view, add `BodyCount.tick("<name>")` at the top of its body.
- `stall` blocks the app's main thread for `seconds`, a freeze for Diagnostics to catch: `sandbox.act('stall', seconds=1.6)`. With `busy=True` a thread off the main thread spins for `seconds` instead, and the command answers when it ends: a Burst of CPU for Diagnostics to catch, with no freeze: `sandbox.act('stall', seconds=5, busy=True)`.
- `idle_clock` and `card_rebuild` bring back the two past CPU costs on purpose, for the `diagnostics` suite to prove that the Diagnostics log names each one (`App/TestDriverCosts.swift`, with the CPU each reaches). Each is off until a command turns it on, and `views=0` turns it off again. `sandbox.act('idle_clock', views=1600)` fades that many small views under SwiftUI clocks at frame rate, as the Working marks did before #114. `sandbox.act('card_rebuild', views=2000)` makes every Sidebar card's body read the shown mode and lay out that many views from it, so each Sidebar switch runs every card again, as the Quick Switch Hints did before #119.
- `binding` performs a Ghostty keybind action on the first Terminal, as its key does, without a key: `sandbox.act('binding', text='quit')`.
- `click` sends a mouse down and a mouse up to the centre of an element, without the pointer: `sandbox.act('click', '<identifier>')`. Use it to test a gesture, because `press` performs the element's accessibility action and skips the gesture. `command_key=True` holds ⌘ through the click. The same first-click rule as for `drag` applies.
- `drag` drags an element to another element without the pointer: `sandbox.act('drag', '<source>', '<destination>')` releases in the upper quarter of the destination, and `edge='bottom'` releases in its lower quarter. `inset=10` releases 10 points from that edge of the destination in place of its quarter. `hold=1.5` rests at the destination for 1.5 seconds, with no mouse event, before it releases, as a user who holds a card at the edge of a list. `via='<identifier>'` moves to the same quarter of that element first, then to the destination. The drag rests at `via` for half a second, so a Bench that it opens comes to rest. A destination that does not show when the drag starts, such as a Benched card that the drag shows, is found at `via`: the drag waits there until the destination shows, for at most 5 seconds. The result's `held` has the rows just before the drag lets go, after `hold`: use it to assert what the user sees while the card is still in the hand. The app stays in the background, so the source's gesture must take the first click (`takesFirstClick` in `UI/SidebarView.swift`). A system drag session follows the real pointer, so `drag` cannot drive it.
- `click`, `drag` and `hover` aim at the centre of an element's frame. While the Sidebar slides between Topics and Sessions, that frame moves, so these commands wait until the Sidebar comes to rest.
- `watch=['<identifier>', …]` on any driver command reads the frames of these elements after each frame that the app draws, for `watch_seconds` (1 by default) after the command. The result has `frames`: for each identifier, its frames `[x, y, width, height]` in screen points, in order, each once until it changes. Use it to check that a view never shows in a wrong place, also for one frame: `sandbox.act('press', '<identifier>', watch=['<card>'])`.
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
