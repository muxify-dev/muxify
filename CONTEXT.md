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

### Topics

**Topic**:
One thing the user wants to get done, such as "Fix reward drop bug in GS". It groups Sessions without a per-repository or per-folder limit, and it is open or Settled.
_Avoid_: task, project, workspace, thread

**Topic slug**:
A Topic's short name used as the suffix of its Sessions' names. It follows Topic renames and stays reserved while the Topic's record exists, including while Settled.
_Avoid_: Session base name, branch name (when you mean the Topic's slug)

**Session Path**:
A folder offered as a place to start a Session, found through `sessions.paths` or Git's Worktrees. It is a launch location, not a running Session or a group of Sessions.
_Avoid_: Session Path, workspace, Session (when you mean the folder)

**Worktree**:
One checkout of a repository at its own path, such as a folder inside a bare repository's folder. Several Sessions, in the same Topic or different Topics, can use the same Worktree.
_Avoid_: checkout, clone, Session Path (when you mean one checkout)

**Untitled Topic**:
A Topic that has no title yet. A rename or a title suggested from its Agents gives it one.
_Avoid_: draft, scratch, temp Topic

**Active Topic**:
The Topic of the Window the user looks at, or No Topic when that Window belongs to no Topic.
_Avoid_: current Topic, selected Topic, focused Topic

**Next Topic**:
The Topic or Locked Session that Muxify opens after the user Snoozes or Settles the Active Topic: the nearest row below it in the Topics list that stays in the list, else the nearest such row above it, else No Topic.
_Avoid_: following Topic, previous Topic, last Topic

**Tag**:
An optional short name on a Topic, written with `#`, such as `#backend`, that is one of the Tags the Config defines. A Topic can have several Tags. A Tag shows as its name everywhere, and it can have a colour.
_Avoid_: label, category, folder, group

**Tag Mark**:
The small coloured square that shows one Tag of a Topic on its card, in the colour of that Tag.
_Avoid_: dot, badge, chip (when you mean the mark on a card)

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

**Snooze**:
To hide one or more open Topics until a time, or until the user Unsnoozes them. Their Sessions and Agents keep running, but their Agents show no Notification until they come back. A Snooze on a Topic that is already Snoozed replaces its time. The Snoozed Topics are listed by the time they wake, soonest first, and the Topics Snoozed until the user Unsnoozes them come last. A Snoozed Topic loses its place in the Topics list, unless Zen Snoozed it: it comes back at the end that the Config gives to new Topics, among the Topics with its Pin, and the Topics that come back together keep their earlier order among themselves.
_Avoid_: hide, park, defer, archive, mass snooze

**Unsnooze**:
To end a Snooze before its time, so the Topic goes back to the Topics list. Nothing changes in tmux.
_Avoid_: restore, wake, resume

**Zen**:
A time when every open Topic except one is Snoozed, so the user can work on that one Topic. Locked Sessions are hidden too, and the Agents of No Topic show no Notification mark. It ends at its time or when the user ends it, and then each Topic it Snoozed comes back as it was before, in its earlier place in the Topics list.
_Avoid_: focus, focus mode, do not disturb, mass snooze

**Pin**:
To keep a Topic above every Topic that is not Pinned, in each list of Topics except the Snoozed Topics, until you unpin it. A Pinned Topic can be Snoozed as usual, and it is still Pinned when it comes back.
_Avoid_: favorite, star, sticky, keep on top

**Lock**:
To keep a No Topic Session in the Topics list as a card with a number, in the order of the Topics, until the user Unlocks it, the Session ends, or the Session goes into a Topic.
_Avoid_: pin, keep, dock, sticky

**Locked Session**:
A No Topic Session that the user Locked. It has a card among the Topics, but it is not a Topic: it cannot be Settled, Snoozed, Pinned or Forgotten.
_Avoid_: kept Session, pinned Session, Topic (when you mean the Session)

**Unlock**:
To end a Lock. The Session stays, as a No Topic Session.
_Avoid_: unpin, release

### Browser

**Browser**:
The web browsing view beside the Terminal. Each Window has its own Browser and Tabs; switching Windows switches the Browser too.
_Avoid_: webview, inspector, sidebar browser

**Tab**:
One page in a Window's Browser, with its own back/forward history. "Tab" never means a tmux Window or a Git View tab.
_Avoid_: page (when you mean the Tab itself), browser window

**Find in Page**:
Searching the text of the active Tab's page, its iframes included, from a find bar in the Browser, with every match highlighted. It never searches the Terminal or a Command Palette.
_Avoid_: search (when you mean the page text), Find (alone)

**Vim Keys**:
The letter keys h, j, k, l, d, u, gg and G, which scroll the active Tab's page as the arrow keys, Page Down, Page Up, Home and End do, and H and L, which go back and forward as the Back and Forward buttons do, when the Browser has Focus and the page does not use the key itself. They are on by default and the Config can turn them off.
_Avoid_: vim mode, keyboard navigation

### Agents

**Agent**:
A coding-agent CLI (Claude Code, Codex, OpenCode or Pi) running in a Pane, which reports its Status to Muxify through its Extension. The agent's own conversation is a "conversation", never a Session.
_Avoid_: bot, assistant, agent session

**Status**:
What an Agent is doing: working (a turn is running), blocked (waiting for the user to answer a permission prompt or question), done (the last turn ended, including by Esc) or failed (the last turn ended with an error). An Agent that has not run a turn yet has no Status.
_Avoid_: state, idle

**Unread**:
A Topic explicitly marked with Mark Unread, or an Agent with a done, failed or blocked update that the user has not marked read. Topic Unread is saved independently of Agents and remains when they exit. With Manual Read, updates stay Unread until Mark Read or Mark All as Read. Without Manual Read, a new visit to a Window or Topic clears Unread; continued viewing preserves an explicit mark. A Topic mark is not an Agent Status and does not add to an Agent count. Snooze hides its mark without clearing it.
_Avoid_: unseen, new

**Manual Read**:
A behavior the user turns on in the Config, in which visiting a Window or Topic does not clear Unread, and Agent updates become Unread even while the user looks at their Window. It is off by default, so a visit reads the Window or Topic.

**Mark Read**:
An Action that clears the Topic Unread mark and Unread for Agents in its target. Its Command and direct shortcut use the Active Topic, or the current Session when there is no Active Topic. It is available for every Topic, with or without Agents. A blocked Agent keeps its blocked Notification until its Status changes.
_Avoid_: dismiss Status

**Mark Unread**:
An Action that marks any Topic as Unread, with or without Agents. It also marks read Agents with done, failed or blocked Status as Unread. Its Command and direct shortcut use the Active Topic, or the current Session when there is no Active Topic. Its row Action uses the selected Topic, Session, Window or Agent.

**Mark All as Read**:
A Command that clears Unread for all Topics and Agents in the Active Environment, including hidden, Snoozed and Settled Topics.

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
A native macOS Muxify window, with its own Active Environment, selected tmux Window, terminal and Browser.
_Avoid_: instance, Window (without "App", when you mean the native window)

**Sidebar**:
The panel on the left of the Muxify window that lists Sessions, Windows and Agents. The Git View's left pane is its List pane, never a sidebar.
_Avoid_: left sidebar, left panel

**Focus**:
Where keyboard input goes in an App Window: the Terminal, the Browser or a Command Palette. One of them has Focus at a time.
_Avoid_: the keyboard (when you mean where input goes), active side, first responder

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
Something the user does to one Topic, Session, Window, Pane, Agent or Tab, such as Jump To, Snooze, Rename or Settle. Every Action runs in the palette's view, whichever way the user starts it.
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

**Check step**:
A palette step that lists Topics with a box on each, and Tag rows that check or uncheck all their Topics in the list, before an Action on the checked Topics. In Snooze Topics, a Tag row does not check its Already Snoozed Topics. The user checks each of them by its own row. A Tag row is not a member of the set. Snooze Topics and Unsnooze Topics start with it.
_Avoid_: pick step, chips, mark, multi-select, selection

### Git

**Git View**:
A view of the repository in the current Window's folder: its Changes, history, branches and stashes in Git View tabs, with the selected one's diff. Changes, or lines of them, can be staged and discarded from it, and what's staged committed. A branch goes into its commits, and a selected commit or stash shows its Diff files under them. It opens as a popup over the App Window or in the terminal's place. Each Window has its own, kept as it was left while another Window is shown.
_Avoid_: lazygit (when you mean ours), git panel, diff viewer

**Git View tab**:
One of the Git View's four lists: Changes, History, Branches and Stashes. Always qualified; a plain Tab is a Browser's.
_Avoid_: Tab (alone), panel, section

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
