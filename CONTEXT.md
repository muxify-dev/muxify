# Muxify

A personal macOS front end for tmux with a Sidebar, Terminal and Browser.

## Language

### Environments

**Environment**:
The context whose Sessions, Windows, Panes and Agents Muxify presents. Local is the Environment on the machine running Muxify.
_Avoid_: workspace, project

**Remote Environment**:
An Environment on another machine, presented in the local Muxify app.
_Avoid_: remote Session, SSH session (when you mean the Environment)

**Active Environment**:
The Environment shown in an App Window. Each App Window has one Active Environment.
_Avoid_: current host, active workspace

### tmux

**Session**:
A tmux session. Sessions group Windows in the Sidebar and can belong to a Topic.
_Avoid_: project, workspace

**Session base name**:
A Session's name without its managed Topic suffix, such as `debug` in `debug/fix-payments`. It comes from the Session's own name, not its repository or folder, and can itself contain slashes.
_Avoid_: Session Path name, repository name (when you mean the Session's name)

**Window**:
A tmux window: the item you pick in the sidebar. Opening it shows all of its Panes.
_Avoid_: tab, workspace

**Pane**:
One split of a Window, laid out by tmux.
_Avoid_: split, terminal

**Client**:
A terminal attached to a tmux server, showing one of its Sessions. Each App Window's Terminal is one Client; Ghostty.app or another terminal attached to the same server is another.
_Avoid_: attachment, connection, viewer

**Watch Session**:
The Session `muxify-watch`, where Muxify's control-mode Client listens for tmux changes. Muxify makes it while you have a Session of your own and kills it after your last one closes. It has no Window you can see in the Sidebar, the Command Palette or the CLI, and no Terminal attaches to it.
_Avoid_: listener Session, infra Session, hidden Session

**Find in Pane**:
Searching the history of the current Window's active Pane, from a find bar over the Terminal, with every match highlighted. It never searches the other Panes, the Browser or a Command Palette.
_Avoid_: terminal search, scrollback search, Find (alone)

### Topics

**Topic**:
One thing the user wants to get done, such as "Fix reward drop bug in GS". It groups Sessions without a per-repository or per-folder limit, and it is open or Settled.
_Avoid_: task, project, workspace, thread

**Topic slug**:
A Topic's short name used as the suffix of its Sessions' names. It follows Topic renames and stays reserved while the Topic's record exists, including while Settled.
_Avoid_: Session base name, branch name (when you mean the Topic's slug)

**Session Path**:
A folder offered as a place to start a Session, found through `sessions.paths` or Git's Worktrees. It is a launch folder, not a running Session or a group of Sessions.
_Avoid_: Session Path, workspace, Session (when you mean the folder)

**Worktree**:
One checkout of a repository at its own path, such as a folder inside a bare repository's folder. Several Sessions, in the same Topic or different Topics, can use the same Worktree.
_Avoid_: checkout, clone, Session Path (when you mean one checkout)

**Muxify Worktree**:
A Worktree that Muxify made and remembers, so it can list and remove it. A Topic may own it, or none.
_Avoid_: managed worktree, created worktree

**Worktree setup**:
A project's `.worktree.json`: the files Muxify copies or links into a new Muxify Worktree, the hooks it runs after making it, and the hooks it runs before removing it.
_Avoid_: worktree config, sync config

**Untitled Topic**:
A Topic that has no title yet. A rename gives it one.
_Avoid_: draft, scratch, temp Topic

**Active Topic**:
The Topic of the App Window's Location: the Topic of its Window or of its Empty Topic page, or No Topic.
_Avoid_: current Topic, selected Topic, focused Topic

**Next Topic**:
The Topic or Locked Session that Muxify opens after the user Settles the Active Topic: the nearest row below it in the Topics list that stays in the list, else the nearest such row above it, else No Topic.
_Avoid_: following Topic, previous Topic, last Topic

**Tag**:
An optional short name on a Topic, written with `#`, such as `#backend`, that is one of the Tags the Config defines. A Topic can have several Tags. A Tag shows as its name everywhere, and it can have a colour.
_Avoid_: label, category, folder, group

**Tag Mark**:
The small coloured square that shows one Tag of a Topic on its card, in the colour of that Tag.
_Avoid_: dot, badge, chip (when you mean the mark on a card)

**Topic Note**:
An optional line of text on a Topic that tells the user what they were doing there, such as "Repro with seed 4411, then bisect". The user sets it, changes it or clears it. It stays through Dormant and Settle, so a Reopened Topic still shows it. Every card shows all of it on its own line, and a closed card shows it softer than the card of the Location.
_Avoid_: next step, comment, description, memo, Summary (when you mean the Note)

**Settle**:
To mark a Topic as done. It leaves the Sidebar, its Sessions are killed or leave the Topic, and its record stays so that it can be reopened.
_Avoid_: close, archive, resolve, complete

**Reopen**:
To bring a Settled or Dormant Topic back and create its remembered Sessions again, with their Windows, Panes, Tabs and Agents.
_Avoid_: restore, unsettle, resume

**Remembered Session**:
A Topic's saved Session identity, name, launch directory and restoration details, retained so it can be Reopened. Several Remembered Sessions can have the same launch directory.
_Avoid_: Session Path, Home Session, Home Session Path

**Start Fresh**:
To bring a Dormant or Settled Topic back with one new Session for each Session it remembers, each with one shell Window. Its remembered Windows, Tabs and Agents are not created again.
_Avoid_: start anew, reset, new Topic

**Forget**:
To remove a Topic for good, at any time, so that it can never be Reopened. Its live Sessions are killed or kept with no Topic, as in Settle, and the clean Worktrees it made can be removed with it.
_Avoid_: archive, delete, purge

**Dormant**:
An open Topic that has no live Sessions but remembers Sessions, for example after a tmux restart. It stays Dormant in the Sidebar until the user goes to it, which Reopens it, or Settles it.
_Avoid_: inactive, sleeping, suspended

**Empty**:
An open Topic that has no live Session and remembers no Session: the user stopped, removed or moved away its last Session or Window. Going to it offers Add a Session; nothing is Reopened.
_Avoid_: Dormant (when it remembers no Session), blank, cleared

**In Play**:
The Guests and the first open Topics in the Topics list that are not Pinned and are not Guests, up to the number that the Config gives. Their cards always show in the Sidebar, under the Pinned Topics and above the Bench line.
_Avoid_: active Topics, focus Topics, front Topics, WIP limit

**Bench**:
The open Topics in the Topics list after the In Play ones. The Sidebar hides them behind the Bench line until the user shows the Bench. A Benched Topic keeps its place in the list, its Sessions and its Agents. A Locked Session is never Benched: with In Play it is a Guest.
_Avoid_: backlog, queue, hidden Topics, overflow, Snooze (when you mean the Bench)

**Choose In Play**:
A Command that sets which open Topics are In Play, and in what order. The user checks them, then chooses the one for each place in turn. A place skips the positions that Guests hold, and the Guests stay where they are. The checked ones after the last place go to the top of the Bench.
_Avoid_: In Play Prioritisation Session, prioritise, reorder, Zen

**Replace from Bench**:
An Action on an In Play card. A Benched Topic that the user chooses takes its place, and the replaced card goes to the end of the Bench. On a Guest, the card that comes in gets the Guest mark.
_Avoid_: Done, Switch Topic Places, swap, Snooze

**Pin**:
To keep a Topic above every Topic that is not Pinned, in each list of Topics, until you unpin it. A Pinned Topic is neither In Play nor Benched.
_Avoid_: favorite, star, sticky, keep on top

**Lock**:
To keep a No Topic Session in the Topics list as a card with a number, in the order of the Topics, until the user Unlocks it, the Session ends, or the Session goes into a Topic. With In Play, a Lock makes the Session a Guest, so the user does it with Make a Guest.
_Avoid_: pin, keep, dock, sticky

**Locked Session**:
A No Topic Session that the user Locked. It has a card among the Topics, but it is not a Topic: it cannot be Settled, Pinned or Forgotten. With In Play, every Locked Session is a Guest.
_Avoid_: kept Session, pinned Session, Topic (when you mean the Session)

**Unlock**:
To end a Lock. The Session stays, as a No Topic Session. With In Play, End Guest of a Session Unlocks it.
_Avoid_: unpin, release

**Guest**:
A card In Play above the number that the Config gives: a Topic with the Guest mark, or a Locked Session. It does not count toward that number, and it keeps its position In Play when another card leaves. It never waits on the Bench.
_Avoid_: visitor, temporary Topic, extra slot, Pin (when you mean a Guest)

**Make a Guest**:
An Action on a Benched Topic or a No Topic Session. The card goes to the end of In Play, directly above the Bench line, as a Guest. No other card goes to the Bench. For a Session, it is a Lock.
_Avoid_: put In Play, promote, Lock (when the Config sets In Play)

**End Guest**:
An Action on a Guest. A Guest Topic goes to the top of the Bench, and a Guest Session is Unlocked, so its card ends. In Play is one card shorter, and no Benched card moves up.
_Avoid_: demote, bench, Unlock (when the Config sets In Play)

**Trade**:
A Sidebar drag that takes a card across the Bench line and lets it go on a card on the other side. The two cards exchange their places in the Topics list, so one goes In Play and the other goes to the Bench. No other card moves. A Guest gives its Guest mark to the card that comes In Play.
_Avoid_: swap, Replace from Bench (when the replaced card does not go to the end of the Bench), exchange

### Browser

**Browser**:
The web browsing view beside the Terminal. Each Window has its own Browser and Tabs; switching Windows switches the Browser too.
_Avoid_: webview, inspector, sidebar browser

**Tab**:
One page in a Window's Browser, with its own back/forward history. "Tab" never means a tmux Window or a Git View tab.
_Avoid_: page (when you mean the Tab itself), browser window

**Browser History**:
The pages that the user loaded in the Tabs of every Window, one History entry for each, kept in one file on the Mac. It is on by default; the Config key `browser.history: false` turns it off. It never records a page that a Browser command loads.
_Avoid_: history (alone, which is also a Tab's back/forward history and Find in Pane's), visits

**History entry**:
One page in Browser History: its URL, title, its visits of the last 7 days, one score for its older visits, and the Topics where the user visited it. The score grows with each visit and halves each 14 days.
_Avoid_: page (when you mean the entry), visit, bookmark

**Suggestion**:
One row in the list under the address field: a History entry, a host or path of Browser History, an open Tab, a dev server port of the Window, or the search row. The list shows only while Browser History is on.
_Avoid_: autocomplete, result, completion (when you mean the row)

**Inline completion**:
The text that the address field adds after the typed text, selected, when the first Suggestion is a host or path that starts with it.
_Avoid_: autofill, autocomplete

**Find in Page**:
Searching the text of the active Tab's page, its iframes included, from a find bar in the Browser, with every match highlighted. It never searches the Terminal, which has Find in Pane, or a Command Palette.
_Avoid_: search (when you mean the page text), Find (alone)

**Vim Keys**:
The letter keys h, j, k, l, d, u, gg and G, which scroll the active Tab's page as the arrow keys, Page Down, Page Up, Home and End do, and H and L, which go back and forward as the Back and Forward buttons do, when the Browser has Focus and the page does not use the key itself. They are on by default and the Config can turn them off.
_Avoid_: vim mode, keyboard navigation

**Browser command**:
A `muxify browser` command that an Agent uses to drive a Tab of its own Window, one step for each command: `tabs`, `open`, `snapshot`, `click`, `fill`, `press`, `wait`, `eval`, `screenshot` and `close`. It acts on the Tab that `--tab` names, else on the Window's active Tab. Muxify does each command in its own Browser, not in another browser.
_Avoid_: automation, Playwright (when you mean Muxify's commands), browser tool, Agent Tab

**Ref**:
The short name, such as `e3`, that `muxify browser snapshot` gives to an element of the page. `click`, `fill` and `press` take it. A Ref stays valid until the Tab loads a new document.
_Avoid_: handle, selector (when you mean the Ref), node id

### Agents

**Agent**:
A coding-agent CLI (Claude Code, Codex, OpenCode or Pi) running in a Pane, which reports its Status to Muxify through its Extension. The agent's own conversation is a "conversation", never a Session.
_Avoid_: bot, assistant, agent session

**Status**:
What an Agent is doing: working (a turn is running), blocked (waiting for the user to answer a permission prompt or question), done (the last turn ended, including by Esc) or failed (the last turn ended with an error). An Agent that has not run a turn yet has no Status.
_Avoid_: state, idle

**Unread**:
A separate mark saved on a Topic, or a done, failed or blocked Agent update that the user has not read. Automatic visits read shown Terminal Panes only and preserve Topic Unread except on a new Empty Topic page visit.
_Avoid_: unseen, new

**Manual Read**:
A Config behavior that preserves Unread during visits and Zoom changes. Agent updates become Unread even in shown Panes.

**Mark Read**:
An Action that clears Unread in its named target without changing Agent Status. Its Command and direct shortcut target the current Window or its Zoomed Pane, or the Topic mark on an Empty Topic page.
_Avoid_: dismiss Status

**Mark Unread**:
An Action that marks a Topic or eligible Agents in its named target Unread. Its Command and shortcut target the current Window or its Zoomed Pane, or the Topic mark on an Empty Topic page.

**Mark All as Read**:
A Command that clears Unread for all Topics and Agents in the Active Environment, including hidden, Benched and Settled Topics.

**Notification**:
A mark that Muxify shows because an Agent is Unread, or is blocked, such as the mark on its Topic. Its type is the Status: done, failed or blocked.
_Avoid_: alert, badge, Unread (when you mean the mark)

**Working mark**:
The gray, moving mark that shows an Agent is working. It is not a Notification, and it is never Unread.
_Avoid_: spinner, activity indicator, working dot, pulse

**Agent mark**:
A Working mark or a Notification. Each kind has one meaning, one shape family and one colour on every card, row and Command Palette result.
_Avoid_: indicator, status dot, status color, marker

**Extension**:
The file or plugin folder installed into an Agent's own plugin or hook system that reports the Agent and its Status to Muxify.
_Avoid_: integration, hook (when you mean the whole file), plugin (when you mean ours)

**Transcript**:
The file in which an Agent's own CLI stores one conversation. Muxify reads it and never writes it.
_Avoid_: log, history, session file

**Entry**:
One message, tool call or tool result in an Agent's conversation, with an index that never changes. A turn holds many Entries.
_Avoid_: line, record, event, turn, message (when you mean the Entry)

### Layout

**App Window**:
A native macOS Muxify window, with its own Active Environment, Location, terminal and Browser.
_Avoid_: instance, Window (without "App", when you mean the native window)

**Location**:
What an App Window shows in the Terminal's place: a Window or an Empty Topic page. Each App Window has one Location, and the Active Topic comes from it.
_Avoid_: place, focus, selection, current Window (when an Empty Topic page shows)

**Empty Topic page**:
The page in the Terminal's place for a Topic with no live Session, whether Empty, Dormant or Settled, or for No Topic when it has no Window. It offers Add a Session, or Reopen and Start Fresh.
_Avoid_: Topic page, empty view, Empty (when you mean the page of a Dormant or Settled Topic)

**Intent**:
A move to a Location that the Terminal does not show yet, such as a click on a Window row before tmux switches the Client. An App Window has at most one Intent, and a new one replaces it.
_Avoid_: pending selection, navigation, transition

**Sidebar**:
The panel on the left of the Muxify window that lists Sessions, Windows and Agents. The Git View's left pane is its List pane, never a sidebar.
_Avoid_: left sidebar, left panel

**Focus**:
Where keyboard input goes in an App Window: the Terminal, the Browser, the Git View or a Command Palette. One of them has Focus at a time, and a keybind for one of them acts only while it has Focus.
_Avoid_: the keyboard (when you mean where input goes), active side, first responder, context (when you mean Focus)

**Focus marker**:
A short line on the top edge of the Terminal or the Browser, whichever has Focus. It shows only while both show, and the Config turns it on.
_Avoid_: focus ring, focus indicator, grabber

**Maximize**:
Showing one of a Window's Terminal and Browser alone, with the Sidebar hidden, until the user restores the Window; it never changes the toggles.
_Avoid_: focus, zoom (tmux zooms a Pane), solo, full screen

**Zoom**:
tmux showing one Pane of a Window alone, until the user zooms it again. It never changes the Window's layout of Panes.
_Avoid_: Maximize (when you mean a Pane), full screen

**Hint**:
The key that Muxify shows on a Topic or Session card, a Window row, a Tab or the Terminal while the user holds a modifier alone, such as ⌃2, or at all times on the cards, Window rows and Tabs where the Config turns that on. When it shows at all times, it is the key alone, such as 2. Pressing that key goes to what the Hint is on.
_Avoid_: badge, number, label, Notification (when you mean the key mark)

**Summary**:
The line under the title of a closed Topic or Session card, or under the title of a Window or Pane row. It shows only when its Format gives text.
_Avoid_: subtitle, details, description, second line

**Sidebar typography**:
The typography of text in the Sidebar's Sessions and Agents sections, independent of the Terminal's typography and the App Window header.
_Avoid_: UI font, terminal font (when you mean Sidebar text)

**Action**:
Something the user does to one Topic, Session, Window, Pane, Agent or Tab, such as Jump To, Rename, Replace from Bench or Settle. Every Action runs in the palette's view, whichever way the user starts it.
_Avoid_: command (when you mean an Action on a thing), operation, menu item

**Command**:
An entry in the Commands Source that starts an app operation or an Action on the current Pane, Window, Session, Topic or Tab. It uses the current item without requiring a search result first.
_Avoid_: Action (when nothing is acted on), menu item, operation

### Command Palette

**Command Palette**:
A named search, opened by its own keybinding, over the Sources selected in it, whose highlighted result the user acts on or, for a Command, runs. Each palette opens with its own Sources selected; the others can be selected too.
_Avoid_: switcher, launcher, finder, sessionizer, Go to Topic

**Source**:
One kind of thing a Command Palette searches: Topics, Sessions, Windows, Agents or Commands. Sessions offers every running Session and Session Paths for Sessions that are not running yet, regardless of Sidebar mode.
_Avoid_: provider, category, section

**Row kind**:
What one row of a Command Palette or of an Action's list is: `topic`, `settled`, `session`, `topic-session`, `session-path`, `worktree`, `muxify-worktree`, `window`, `agent`, `command` or `tag`. A list's `show` names the Row kinds that it lists. A running Session is a `topic-session` when its Topic is not Settled, and a `session` in all other cases. A checkout is a `worktree` when its folder is outside the folder of its Session Path, and a `session-path` in all other cases, so the checkouts inside a bare repository's folder are `session-path` rows. A `muxify-worktree` row is a Muxify Worktree, wherever its folder is.
_Avoid_: type, category, Source (when you mean one kind of row)

**Pick list**:
The ranked list of an Action's step, such as Add a Session or Move. Each has a name in `pick_lists` and takes `show` and `tiebreak`, as a Command Palette does.
_Avoid_: picker, dropdown, menu

**Check step**:
A palette step that lists Topics and Locked Sessions with a box on each, before an Action on the checked ones. Choose In Play starts with it.
_Avoid_: pick step, chips, mark, multi-select, selection

### Git

**Git View**:
A view of the repository in its Window's folder: its Changes, history, branches and stashes in Git View tabs, with the selected one's diff. From it, the user stages, discards and commits Changes, or lines of them, and runs lazygit's git operations on branches, commits and stashes, such as push, checkout, merge and cherry-pick. A branch goes into its commits, and a selected commit or stash shows its Diff files under them. It opens as a popup over the App Window or in the terminal's place. Each Window has its own, which shows only while that Window is the Location and is kept as it was left meanwhile. An Empty Topic page has none.
_Avoid_: lazygit (when you mean ours), git panel, diff viewer

**Git View tab**:
One of the Git View's four lists: Changes, History, Branches and Stashes. Always qualified; a plain Tab is a Browser's.
_Avoid_: Tab (alone), panel, section

**Git View menu**:
A list of choices that a key opens in the Git View, each choice with its own key, such as Discard changes or Reset. A confirmation is a Git View menu with one choice.
_Avoid_: popup, dialog, sheet, palette step

**Git View prompt**:
A one-line field inside the Git View that asks for one value, as for the message of a stash. ↩ submits it and ⎋ cancels with no change. It can start with text filled in, and it can hide what is typed, as for a password. Like the Git View menu, it keeps the keyboard in the Git View.
_Avoid_: dialog, sheet, alert

**Copied commits**:
The commits that `C` copied in the Git View, for `V` to cherry-pick onto the branch you're on. They belong to the repository, not to one Window: every Git View in any Worktree of it shows and pastes them. Kept while Muxify runs, not saved.
_Avoid_: clipboard, copied commit list

**List pane**:
The Git View's left pane, holding its Git View tabs; the diff pane beside it shows the selection's diff.
_Avoid_: sidebar, Git View sidebar

**Changes**:
The files that differ from the last commit, staged or not, as the Git View lists them.
_Avoid_: working copy, status, modified files

**Diff files**:
The files the selected commit or stash changed, shown under it in the Git View; while comparing, the files that differ from the Base.
_Avoid_: commit files, changed files

**Base**:
The commit, branch or stash that W marks in the Git View. Every other commit, branch or stash selected then shows the diff from the Base to it, as lazygit's diffing mode; Changes don't.
_Avoid_: diff base, compare target, marked commit

### Configuration

**Config**:
The Muxify config file on a machine: settings, in YAML sections, that control how Muxify itself behaves. An App Window uses the Config of its Active Environment's machine, or the local one when that machine has none. It never holds what is open or shown now.
_Avoid_: settings, preferences, Muxify settings

**Format**:
A Config string with #{…} placeholders that sets a Sidebar line or a Window row part from the Topic, Session, Window or Pane that the row shows. Muxify expands it, not tmux. Titles and Summaries give plain text. Window left and right parts can also give the current app icon or macOS SF Symbols.
_Avoid_: template, pattern, label string, tmux format (when you mean ours)

**Ghostty config**:
The Ghostty config files that control the terminal: its fonts, theme and terminal keybinds.
_Avoid_: terminal config
