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

Run the suites against one version of the Topics list, while the list has two (`docs/adr/0075-muxify-leaves-swiftui-entirely-one-area-at-a-time.md`):

```sh
make verify TOPICS_LIST=appkit
make verify TOPICS_LIST=swiftui SUITE=topics_cards_sidebar
```

`TOPICS_LIST` makes every launch of every suite show that Topics list: `Sandbox.launch` adds the launch argument `-topicsListAppKit YES` or `NO`, unless the check's own arguments set the user default `topicsListAppKit`. Without the option, a suite gets the app's default, which is the SwiftUI list until the AppKit list is done. A run with `TOPICS_LIST` never satisfies the gate, because it proves nothing about the default. `Sandbox.topics_list()` asks the driver which Topics list the App Window shows, `appkit` or `swiftui`. The suite `topics_list_sidebar` checks the switch.

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

## Do not take focus

Checks run while the user works. A check must not take the keyboard focus, the mouse or the front position from the user.

- `Sandbox.launch` starts the app in the background through LaunchServices (`open -g`). Do not start the app in a different way.
- Use the driver commands: `dump`, `press`, `set`, `focus`, `action`, `actions`, `click`, `drag`, `hover`, `snapshot`, `responder`, `scroll`, `stall`, `binding`, `counts` and `topics-list`. `action` performs a named accessibility action of an element: `sandbox.act('action', '<identifier>', '<action name>')`.
- `actions` answers the names of the named accessibility actions of each element with the identifier, in the order of the dump and in the order each element gives them: `sandbox.actions('<identifier>')` gives a list for each element, such as `[['Lock Session', 'Go to Session']]`, and an empty list when no element has the identifier. Use it to check which items a context menu offers, where the menu gives its items as named actions. A dump row has no named actions, because a dump reads up to 2000 elements. SwiftUI gives the Buttons of `.accessibilityActions` from the last to the first.
- `hover` puts the pointer on an element for the app's hover tracking, without moving the real pointer: `sandbox.act('hover', '<identifier>')`. A later `hover` on another element moves it there. When other windows cover the App Window whole, macOS marks it as not visible and SwiftUI sends its views no hover, so `hover` fails and says so: uncover a part of the App Window, for example make a window in front smaller.
- `snapshot` draws the App Window into a PNG, without a screen capture, so it needs no screen recording permission: `sandbox.act('snapshot', '<identifier>', '<path>.png')` keeps only that element, and an empty identifier keeps the whole App Window. Use it for a picture of a visual change; a check asserts on the dump, not on pixels.
- `set` replaces the text of a field: `sandbox.act('set', '<identifier>', '<text>')`. `paste=True` puts the text in at the caret and moves the caret after it, as ⌘V does: `sandbox.act('set', 'palette-search', 'a line\n', paste=True)`.
- `responder` gives the class name of the first responder of each visible App Window, such as `TerminalSurfaceView` or `WKWebView`. Use it to find which view has Focus: `sandbox.driver('responder')['responders']`. When the first responder is a field editor, `editors` has its `frame`, its `visible` part and the `field` it edits, in the field's points; an editor taller than its field draws text that the field cuts off.
- `scroll` scrolls the scroll view under an element so that the end of its content is `from_end` points below the bottom edge, without the pointer: `sandbox.act('scroll', 'topics-list', from_end=10)`. Use it to put a list in one exact place near its end. With `by`, it scrolls down by that many points in `steps` equal moves, one each tick of the driver, so the app draws a frame between two moves as under a wheel: `sandbox.act('scroll', 'topics-list', by=600, steps=20)`. The result's `seconds` is how long the moves took, which grows with the frames' lag.
- `counts` reads how often each counted view's body ran since the last reset (`BodyCount` in `App/BodyCount.swift`), as `{'TopicCard': 41, ...}` in the result's `counts`; `reset=True` resets them after the read: `sandbox.driver('counts', reset=True)`. Use it to prove that a scroll or a change does not draw a list's cards again. To count a view, add `BodyCount.tick("<name>")` under `#if DEBUG` at the top of its body.
- `topics-list` answers which Topics list each visible App Window shows, `appkit` or `swiftui`, in the result's `versions`: `sandbox.topics_list()`. The AppKit list counts also while it is the Sidebar page that does not show.
- `stall` blocks the app's main thread for `seconds`, a freeze for Diagnostics to catch: `sandbox.act('stall', seconds=1.6)`.
- `binding` performs a Ghostty keybind action on the first Terminal, as its key does, without a key: `sandbox.act('binding', text='quit')`.
- `click` sends a mouse down and a mouse up to the centre of an element, without the pointer: `sandbox.act('click', '<identifier>')`. Use it to test a gesture, because `press` performs the element's accessibility action and skips the gesture. `command_key=True` holds ⌘ through the click. The same first-click rule as for `drag` applies.
- `drag` drags an element to another element without the pointer: `sandbox.act('drag', '<source>', '<destination>')` releases in the upper quarter of the destination, and `edge='bottom'` releases in its lower quarter. `inset=10` releases 10 points from that edge of the destination in place of its quarter. `hold=1.5` rests at the destination for 1.5 seconds, with no mouse event, before it releases, as a user who holds a card at the edge of a list. `via='<identifier>'` moves to the same quarter of that element first, then to the destination. The drag rests at `via` for half a second, so a Bench that it opens comes to rest. A destination that does not show when the drag starts, such as a Benched card that the drag shows, is found at `via`: the drag waits there until the destination shows, for at most 5 seconds. The result's `held` has the rows just before the drag lets go, after `hold`: use it to assert what the user sees while the card is still in the hand. The app stays in the background, so the source's gesture must take the first click (`takesFirstClick` in `UI/SidebarView.swift`; in the AppKit Sessions list, `acceptsFirstMouse` of `SidebarPressView`, whose Window rows hand the drag to `SessionCardDrag`). A system drag session follows the real pointer, so `drag` cannot drive it.
- `click`, `drag` and `hover` aim at the centre of an element's frame. While the Sidebar slides between Topics and Sessions, that frame moves, so these commands wait until the Sidebar comes to rest.
- `watch=['<identifier>', …]` on any driver command reads the frames of these elements after each frame that the app draws, for `watch_seconds` (1 by default) after the command. The result has `frames`: for each identifier, its frames `[x, y, width, height]` in screen points, in order, each once until it changes. Use it to check that a view never shows in a wrong place, also for one frame: `sandbox.act('press', '<identifier>', watch=['<card>'])`.
- The Sidebar lists build only the rows they show, so a row far down is not in a dump. `sandbox.reveal('<identifier>')` scrolls the row to the top of its list, without the mouse or the keyboard, and returns the rows; every driver command takes the same `reveal=True` option.
- The driver has no command that types keys or opens a context menu, because these take the keyboard and the mouse. Do not add one.
- If a behavior is only available through a context menu, give the view an accessibility action with `.accessibilityActions` or an identifier. Then use `action` or `press`. In the suite, write which view you changed and why. Example: `topicMembershipActions` in `UI/TopicMembershipMenu.swift`. In the AppKit Sessions list, one `SidebarMenu` (`UI/SidebarMenu.swift`) gives a view both its menu and its named actions.

## What to keep

Commit a check that must stay true with the feature that it checks. Keep a one-off probe in the run directory. Do not commit it.

## The compare run

While an area of the app has two versions, a SwiftUI one and an AppKit one, the compare run is the check that they are the same (`docs/adr/0075-muxify-leaves-swiftui-entirely-one-area-at-a-time.md`, with the meaning of "the same" from ADR 0074). It shows each scene of the area in both versions, fails when the two differ in what a check can measure, and leaves a report of pictures for a person to judge.

```sh
make compare AREA=topics                          # every scene of the Topics list
make compare AREA=topics SCENE=<scene>            # one scene
make compare AREA=topics SCENE="<scene> <scene>"  # these scenes
make compare AREA=topics SELF=1                   # each scene twice in the SwiftUI version
```

**Areas.** An area (`Area` in `compare_scenes.py`) is a part of the app with two versions. It names the identifier of the list whose rows the gate compares, the user default that chooses the version (`YES` is the AppKit version), the launch arguments its scenes start the app with, how the run asks the driver which version shows, and its scenes. `AREAS` lists the areas that have two versions now. `AREA=<area>` chooses one; without it, the run takes the only one, and with several it asks for one. With no area that has two versions, `make compare` says so and passes. `SCENE=` and `SELF=1` choose among the scenes of the area that the run takes.

The area now is the Topics list, `topics`: its list is `topics-list`, its user default `topicsListAppKit`, its scenes start the app with the Sidebar showing Topics, and the driver answers its version with `topics-list`. Its scenes are `topic-cards`, closed Topic cards with every note; `locked-cards`, a Locked card and the Guests; `topic-open`, an open Topic card with Session lines, Window rows, Pane rows and "N more…"; `no-topic-card`, the No Topic card open and closed; `topics-stuck-header`, the header of an open card stuck at the top of a scrolled list; and `topic-tags`, Tags in each placement and on an opened Settled card. The Sessions list was the first area. The user signed it off, so its SwiftUI version, its switch and its scenes are deleted.

`make compare` builds the Debug app first. The scenes run one after the other, each in its own Sandbox. Without `make`, after `make build`: `python3 -m scripts.verify.compare [--area <area>] [--self] [scene ...]`.

The run follows "Do not take focus". It starts the app only through `Sandbox.launch`, and a scene reaches its state only through tmux, the Config and the driver commands of that section.

A scene makes its fixture once. Then the run does this for each version:

1. It starts the app with the area's user default as a launch argument, `NO` or `YES`, on the same tmux server, state and defaults. The argument wins over a stored default and over `TOPICS_LIST`.
2. It shows each shot of the scene. A scene has one shot or more, and each shot gives one picture.
3. It asks the driver which version shows, through the area. The shot fails when that is not the version the run asked for.
4. It waits until nothing moves: until the picture of the App Window and the dump are the same three times in a row.
5. It keeps the picture (`snapshot`) and the dump.

**The gate** (`compare_gate.py`) reads the two dumps of a shot. It takes the rows that have an identifier and stand inside the area's list, and matches them between the versions by identifier and role. SwiftUI gives a row's identifier to the row's parts, so several rows can share an identifier and a role: among these, the first of one version matches the first of the other, in the order of the dump. The run fails when:

- a row has no match in the other version;
- a matched pair differs in label, title, value or help;
- the frames of a matched pair differ by more than half a point on an edge. The gate measures a frame from the top left corner of the App Window;
- the named actions of an element that the shot names differ in their names or their order. A dump has no named actions, so an arrange names the identifiers whose named actions the shot reads, with `view.read_actions('<identifier>', …)`, and the run reads them with `actions`. `build/verify/compare/<area>/<scene>/<shot>-<version>-actions.json` has them.

The run names each row that failed, with the values of both versions. When rows with different identifiers stand in another order in the two dumps, the report says so, and the run does not fail. While the Sidebar shows its other page, the dump has no rows of the list, so such a shot has pictures and no rows. `suites/harness.py` checks the matching on made-up rows, with no app.

**The report** is `build/verify/compare/<area>/index.html` in the checkout. For each shot of each scene it shows the two pictures side by side, a picture of their difference, the share of pixels that differ and the box around them, the gate's result with the rows that failed, and the scene's notes. A picture in the report is cut to the Sidebar; click it for the whole App Window. The difference picture shows a pixel that differs in magenta. `build/verify/compare/<area>/<scene>/` has the pictures, the dumps as `<shot>-<version>.json`, `result.json` and the app's logs. Nothing deletes the report: a run of some scenes replaces their part, and `make verify` leaves the folder alone. The share of pixels never fails the run, because two layout engines do not put glyphs on the same subpixels.

**`SELF=1`** shows each scene twice in the SwiftUI version. Then every difference is a fault of the run or of the scene, or the user changed a picture (see below), so one pixel that differs fails the run too. Its report is `build/verify/compare/<area>/self/index.html`. Run it after you add or change a scene.

**The notes** are `compare-notes.md`: first the record of the pilot, what the move of the Sessions list cost, then one section for each scene. A task that leaves a difference between the two versions in a scene writes it in that scene's section, with the reason. The report shows the section under the scene's pictures.

**What the picture does not show.** The driver's `snapshot` draws the App Window's layers. It is not a capture of the screen. So it does not show a material that the window server blends, such as the blur behind a translucent view, nor a Core Animation filter, such as the one that SwiftUI's `.saturation` adds: judge these in the running app.

**What the user changes in a picture.** The App Window stands on the user's screen, behind the front window, and the picture has all of it: the title bar and the Terminal too. The user can change a picture in three ways:

- The user's pointer rests on a part of the App Window that shows. The row under it draws its hover colour and opens its hover label.
- The App Window comes to the front, for example when the user closes the window in front of it. It then draws its title bar buttons in colour.
- The user's windows cover the App Window whole, or the user works in a full-screen window. A scene that hovers then gets no hover, as the `hover` command does not. Let such a scene wait a while for a part of the App Window to show, then fail and say so.

The gate reads rows, so the first two do not fail a run of the two versions. They do fail `SELF=1`, which then says where the pixels differ, as a box in points from the top left corner of the App Window. A box on one row, or on the title bar buttons, is the user's: run that scene again.

**Add a scene**

1. In `compare_scenes.py`, write a class with a `name`, a line `shows` for the report, `fixture(s)` and `shots()`. The fixture helpers there, such as `session`, `topic`, `locked`, `agent`, `ring` and `fresh_shell`, make what a scene needs; `TopicCards`, and the Sessions list's scenes in the git history before its SwiftUI version was deleted, show how. `fixture` makes the tmux Sessions, the Topic records and the folders in the Sandbox, before the app starts. `shots` gives `(name, arrange)` pairs.
2. In an arrange, start the app with `view.launch(config(...))`, move the Location with `view.go(window)`, close the card that the move opened with `view.close_card('<header>')`, and end with `view.wait(predicate, message)` on the rows that prove the list shows the state. When one version cannot show the state, the wait fails with the message, and the run still takes the picture.
3. Make each shot start from the same state in both versions. The second version runs after the first, on the same tmux server: set again what an earlier shot changed, such as a bell. The Terminal shows the Location's Window in the picture, and a shell there can draw its prompt again after a launch that changed its size: start it again with `fresh_shell(s, window)` after the move. Call `view.rest()` before a step that starts from where the list stands, such as a swipe or a hover. `config()` sets `ui.pulse: false`, so a Working mark stands still.
4. Add the scene to its area's `scenes`, and a section `## <name>` to `compare-notes.md`. A new area adds an `Area` to `AREAS`.
5. Run `make compare AREA=<area> SELF=1 SCENE=<name>` a few times. It must pass each time, with no pixel that differs.

The run compares two pictures with `picture_diff.swift`. It builds this helper once with `swiftc`, into the folder of `ax-wake` ("Accessibility permission"). The helper needs no permission.

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
