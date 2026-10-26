# Configuration

Muxify reads `~/.config/muxify/config.yaml` (or
`$XDG_CONFIG_HOME/muxify/config.yaml`). Use **Muxify → Open Config** to edit it.

## Choose the Config for one launch

Set `MUXIFY_CONFIG` to the path of a Config file to use it in place of the XDG
path. A path that starts with `~/` starts in the home directory. An empty value
is the same as no value. Open Config, the Config problems banner and the reload
on change all use this file. For example, keep one Config with every feature on
for testing, and a personal Config with `sidebar: {sessions: false}`.

The app reads the variable when it starts, so start a new copy of the app with
it:

```sh
open -n --env MUXIFY_CONFIG="$HOME/.config/muxify/personal.yaml" /Applications/Muxify.app
```

To build and start the Debug app with a Config, use `make run`:

```sh
make run CONFIG=path/to/config.yaml
```

## Terminal environment

Muxify sets `MUXIFY_TERMINAL=1` for its terminal processes, locally and on the
remote host over SSH. It leaves Ghostty's `TERM` and `TERM_PROGRAM` unchanged.

tmux Panes are separate processes: attaching Muxify does not change the
environment of an existing shell. To copy the variable into a Session's
environment on attach (for new Panes), add this to your tmux config:

```tmux
set -ga update-environment ' MUXIFY_TERMINAL'
```

This records the attaching terminal, not which terminal is currently showing a
Pane. It is not a per-client status-bar setting; tmux's `status` option belongs
to the Session.

## Remote Environments

Manage tmux on Linux or macOS over SSH. The remote needs **tmux 3.2+**, not
Muxify. Add destinations to the Config:

```yaml
remote_environments:
  - name: Macbook Home
    host: macbook-home.example.ts.net
    username: your-user
    # port: 22
    # identity_file: ~/.ssh/id_ed25519
    # forward_agent: false
```

Names must be unique; `Local` is reserved. SSH reads `~/.ssh/config`, including
1Password's `IdentityAgent`. YAML `port` overrides SSH config; `identity_file`
names a local key. Password authentication is disabled.
Agent forwarding (`-A`) is on by default; set `forward_agent: false` for hosts
you don't trust with access to your agent.

Choose an Environment in the header to open its App Window, or focus it if
already open. ⌘N opens another Local App Window. Closing a window leaves tmux
running; dropped connections reconnect automatically. Muxify remembers the last
focused Environment and creates `main` in the remote home if no Session exists.

The Browser stays local: use reachable URLs, such as Tailscale URLs. There is
no port forwarding or remote dev-server discovery; Reveal in Finder is disabled.
Install [Agent Extensions](../extensions/README.md#install) manually on the remote.

### Paste screenshots and files

Take a screenshot to the Mac's clipboard (for example, ⌃⇧⌘4), then press ⌘V
in the Terminal. Muxify saves the image as a PNG, uploads it over the Environment's
existing SSH connection, and pastes its remote path. You can also drag screenshot
thumbnails or files into the Terminal. Tools such as Claude Code can read the
uploaded image from that path; other tools must support image/file paths as input.

An upload status appears at the bottom of the App Window. The path is pasted
only after the upload succeeds, into the Pane where you started, even if you
switch Windows or Panes while it uploads. Reconnecting cancels pending uploads.
Files remain in private `muxify-paste.*` directories under the remote machine's
temporary directory, subject to that machine's temporary-file cleanup policy.
No remote clipboard helper is needed. Plain text pastes work as usual.

In Local, clipboard images are saved in the Mac's temporary directory and their
paths are pasted directly.

## Session Paths

Session Paths are the folders where you open Sessions. The New Topic and Add Session Path
lists and the Command Palette offer them:

```yaml
sessions:
  paths:
    - path: ~/Dev/*/*
      display_depth: 2
    - path: ~/projects
      depth: 1
    - path: ~/.dotfiles
  aliases:
    - ~/Dev/mixed/obsidian_vaults/glebglazov: My Obsidian
```

`path` is absolute, starts with `~/`, or starts at the directory of the Config.
It may be a glob, and each folder it matches is a root. `depth` defaults to 0,
the root itself; 1 lists its subfolders, and 2 also their subfolders. Hidden
folders are skipped, and so are folders this machine doesn't have, so one
Config can serve several Macs. When two entries find the same folder, the first
names it. Muxify looks for the folders each time a list or palette opens, so a
new folder joins without a Config edit.

A repository is one Session Path, plain or bare. Its Worktrees are rows of it, found
with `git worktree list`, wherever they are. Muxify does not look for Session Paths
inside a repository. In a list, a checkout inside the folder of a bare repository,
such as `game/main`, is a Session Path row. A Worktree outside that folder is a
Worktree row.

A Session Path's name is its last `display_depth` folder names (1 by default), so
`~/Dev/tripledot/game` with `display_depth: 2` is `tripledot/game`. Topic
records and Session names use it, so it does not change when other folders come
and go. In a Session name, `.` and `:` become `_` and spaces go. A Session in a
Worktree is named `<repo>/<folder>`. Launch matching uses the exact Session name,
never its directory: that name elsewhere is reused; another name in the same
folder does not suppress a launch. Duplicate launch names use the first configured
entry and show a warning; increase `display_depth` to distinguish them.

An alias shows in place of a launch row's name, not a running Session's real name.
A Worktree launch row shows `<alias>/<folder>`. The key is the path of a
Session Path, written as in `paths`. An alias can have spaces. It changes only what
Muxify shows: tmux Sessions and Topic records keep the name, so adding or
changing an alias does not rename a Session. Typing the alias or the name finds
the Session Path. An alias for a path that is not a Session Path does nothing.

An entry that cannot apply appears in the Config problems banner. So does the
removed sections. Muxify reports unknown keys and does not read legacy settings.

## Position of new and returning Topics

```yaml
topics:
  insert_position: bottom
```

`bottom` (the default) puts a new Topic below all Topics and Locked Sessions
that are not Pinned. `top` puts it first below the Pinned Topics.
Reopen and Start Fresh use this position when a Settled Topic returns.
Unsnooze and a Snooze that ends at its time also use it. Topics whose Snooze
ends at the same time go there together, in their earlier order.
The Topics that Zen Snoozed go back to their earlier places when Zen ends.
A Topic whose own earlier Snooze ended during Zen uses this position.
A Pinned Topic returns at the chosen end of the Pinned Topics.
A Dormant Topic keeps its place, including when it is Pinned.
A Topic made from a Locked Session takes that Lock's place.
An unknown value uses `bottom` and appears in the Config problems banner.

## Tags

```yaml
topics:
  tags:
    work:
      color: blue
    personal:
      color: {light: '#5E8C6A', dark: '#7FA88A'}
    gs: {}
```

`topics.tags` lists every Tag that a Topic can have, in the order Muxify shows
them. Each key is a Tag: lower case letters, digits and `-`, as a Topic record
stores it. A key that breaks this rule is a Config problem with its line
number, and that Tag does not exist.

A Tag shows as its key everywhere: on cards, in the palette, in Edit Tags and
in the CLI. Its only setting is `color`, the color of its mark on a Topic card
and of its chips and rows in the Command Palette, written as in
[Agent colors](#agent-colors). A Tag without a `color` gets a fixed color made
from its name. Any other key, such as an old `display_name`, is a Config
problem with its line number, and the Tag still loads with its color.

Only these Tags can be added: in New Topic, in Edit Tags, and with
`muxify topic tag`, which fails with an error that names `topics.tags` and
writes nothing. New Topic and Edit Tags suggest the Tags in Config order, also
a Tag that no Topic has. A `#word` that no Tag matches cannot become a chip,
and ↩ does nothing while it is in the field.

A Topic record can hold a Tag that the Config does not define, such as a Tag
that you removed or renamed here. Muxify does not change the record. The card
shows that Tag dimmed and with no color. Edit Tags can remove it, but nothing
can add it again, and Go to… and Snooze Topics do not list it.

Without `topics.tags`, or with an empty one, Tags are off: `#` in New Topic is
plain title text, Edit Tags is not offered, and no card, palette row or Format
shows a Tag. Each App Window uses its Environment's Config, so its Tags come
from that Config.

## Order of a Topic's Sessions

```yaml
topics:
  session_order: oldest_first
```

A Topic card, the Command Palette and the Topic record list a Topic's Sessions by when
tmux created them: `oldest_first`, the default, or `newest_first`. Sessions
created in the same second follow their tmux Session ID.

Move a Session with a drag on its line in an open Topic card: the Session
lifts with its Windows, the other Sessions slide aside, and an outlined
placeholder shows where it lands. Move Up and Move Down in the line's context
menu move it too. The Topic then keeps your
order, in its record, and a new Session goes to the end that `session_order`
gives new Sessions: the bottom for `oldest_first`, the top for `newest_first`.
A change of `session_order` does not change an order you gave. Sort Sessions by
Creation in the context menu goes back to the creation order. No Topic and the
Sessions mode keep the tmux order. Any other value uses the default and appears
in the Config problems banner.

A drag on a Window row moves the Window, with its Pane rows, within its
Session, in any card. The Session keeps its current Window, and tmux keeps the
new order. Topic cards and Locked Session cards move the same way among the
cards with their pin.

## Header

```yaml
ui:
  header_height: 30
  status_line_header: true
```

The height is in macOS points, defaults to 30, and must be a finite number of
at least 24 so the buttons fit. Changes apply live. Removing the setting restores
the default; invalid values use the default and appear in the Config problems
banner. A YAML syntax error keeps the last good Config.

`status_line_header` replaces tmux's status-line navigation with the current
Session name and its Window selector, inline
when the Window list fits and as a dropdown otherwise. It defaults to `true`.
Set it to `false` to hide only those two controls; the Git/branch button,
Environment selector and panel controls stay visible. Changes apply live.
Removing the setting restores the default. Invalid values use the default and
appear in the Config problems banner.

## Agent marks

An Agent mark is a Working mark or a Notification. Each kind has one meaning
and one color on every Sidebar card, Pane row, Agents row and Command Palette
result:

| Agent | Mark | Default color |
| --- | --- | --- |
| Working | Working mark: pixels that step around a square on a row, a fading bar on a card | gray |
| Done and Unread | Notification | blue |
| Failed and Unread | Notification | red |
| Blocked, read or Unread | Notification | orange |
| Done or failed and read, or no Status yet | none | — |

A card shows the strongest mark of its Agents: blocked, then failed, then
done, then working. A Snoozed Topic, and No Topic while Zen is on, show no
Notification on any surface, and their cards show no mark. An Agent's own Pane
row and Command Palette result there still show its Working mark.

A terminal bell is not an Agent mark. It shows as a gray bell symbol, and no
Config changes its color.

### Notifications

```yaml
notifications:
  manual_read: false
  done_enabled: true
  failed_enabled: true
  blocked_enabled: true
```

By default, a new visit reads the Panes shown in the Terminal. A normal Window
includes all its Panes. A Zoomed Window includes only its Zoomed Pane. Ending Zoom
reads newly shown Panes. Sidebar expansion and scrolling do not read anything.
Mark Unread stays set during continued viewing. Updates in shown Panes do not
become Unread. Hidden Panes can become Unread. Automatic reading pauses when the
Terminal is hidden or the Git View is open.

Set `manual_read: true` to turn on Manual Read. Visits and Zoom changes then
preserve Unread. A done, failed or blocked update becomes Unread even in a shown Pane.

**Mark Read** clears Unread in the current Window, or only its Zoomed Pane when
Zoom is on. Its default shortcut is ⌘⇧R. **Mark Unread**, on ⌘⇧U, uses the same
target. The Command Summary names that target, including when the Terminal is hidden.
Mark Unread applies to done, failed or blocked Agents. Neither Action changes
Status, so a blocked Agent keeps its blocked mark.

A palette row Action uses the named Topic, Session, Window or Agent. An explicit
Window Action includes all its Panes, even during Zoom. Topic and Session Actions
include their hidden Windows. Working Agents cannot become Unread.

A Topic's Mark Unread Action also saves a separate Topic mark, with or without
Agents. Window visits and Window or Pane Actions preserve this mark. Use the
Topic's Mark Read Action to clear it. On an Empty Topic page, the Commands act
on the Topic mark. A new visit to that page also clears it when Manual Read is off.
A Snoozed Topic keeps its mark but hides it until Snooze ends.

The expanded Active Topic shows Agent lines beside Window rows, or beside Pane
rows when they replace a Window. Working has a moving line. A title line shows
explicit Topic Unread separately. The more row shows the strongest hidden Agent
mark. Other cards keep their aggregate line.

**Mark All as Read** clears Unread in the Active Environment, including all Topic marks and Unread
working Agents. This includes hidden, Snoozed and Settled Topics. It has no default shortcut. Set `keybindings.mark_all_read` to
assign one. Use `keybindings.mark_unread` to change the Mark Unread shortcut.
The palette row Action has no default shortcut. Set
`keybindings.command_palette.mark_unread` to assign one.

Set a `*_enabled` key to `false` to turn off that type of Notification on every surface:
cards, Pane rows, the Agents section, and the Command Palette's marks and
status text. A wake message after a Snooze then does not count those Agents.
Each key is `true` by default. A value that is not a boolean, or an unknown
key, appears in the Config problems banner.

### Agent colors

```yaml
ui:
  agent_colors:
    working: gray
    done: blue
    blocked: orange
    failed: red
```

These are the defaults. A value is a macOS system color name (`blue`,
`orange`, `red`, `green`, `yellow`, `purple`, `pink`, `teal` or `gray`), which
adapts to light and dark appearance, or a `#RRGGBB` value, which is the same in
both. Put quotes around a `#RRGGBB` value, because YAML reads an unquoted `#`
as the start of a comment:

```yaml
ui:
  agent_colors:
    done: '#3366ff'
```

To set one color for light appearance and one for dark, write a mapping with
the keys `light` and `dark`. Each one is a system color name or a `#RRGGBB`
value. The color changes when the appearance of the App Window changes:

```yaml
ui:
  agent_colors:
    done: {light: '#3366ff', dark: '#88aaff'}
```

A mapping without `light` or `dark`, with another key, or with an invalid value
in it is a Config problem.

A color applies to the Sidebar and the Command Palette at once. The Command
Palette's terminal theme does not change Agent marks. Leave out a key to keep
its default. An invalid value keeps the default, and it and an unknown key
appear in the Config problems banner. Changes apply live.

### Pulse

```yaml
ui:
  pulse: false
```

Every Working mark moves: on a row its pixels step around a square, and on a
card its bar fades in and out. `pulse: false` keeps every Working mark still,
in the Sidebar and in the Command Palette. The default is `true`. Reduce Motion
in the macOS accessibility settings also keeps them still. A value that is not
a boolean uses the default and appears in the Config problems banner.

### Focus marker

```yaml
ui:
  focus_marker: true
```

A short line in the middle of the top edge of the Terminal or the Browser
shows which of them has Focus. It shows only while both show, and not while a
Command Palette or the Git View has Focus. The default is `false`. Changes
apply live. A value that is not a boolean uses the default and appears in the
Config problems banner.

```yaml
ui:
  focus_marker_color: {light: '#3366ff', dark: '#88aaff'}
  focus_marker_opacity: {light: 0.9, dark: 0.7}
```

`focus_marker_color` is `accent`, the macOS accent color, or a color as in
[Agent colors](#agent-colors): one color, or a mapping with `light` and
`dark`. The default is `accent`. `focus_marker_opacity` is a number above 0
and at most 1, or a mapping with `light` and `dark`. The default is `0.45`.
The Terminal and the Browser each pick the value for their own appearance.
Changes apply live. An invalid value uses the default and appears in the Config
problems banner.

## Sidebar typography

```yaml
ui:
  sidebar:
    font_size: 12
    font_family: system
```

These are the current defaults. `font_size` is a base size in macOS points:
Window and Agent titles use it directly, while Session names, headings,
metadata and numeric badges scale proportionally to preserve their existing
hierarchy and weights. It must be a finite number greater than zero; fractional
sizes are supported. Session rows grow to accommodate larger text.

`font_family` is `system` for the native macOS system font, or an installed macOS
font family name, such as `Helvetica`. Names are case-insensitive and surrounding
whitespace is ignored. Use a family name, not a font-file path or an individual
face/PostScript name. A family without an exact medium or semibold weight uses
its closest available weight.

Both options apply live to text in the Sessions and Agents sections of every
App Window, without changing selection, expansion or visibility. Symbols,
logos, status dots, the App Window header and Terminal fonts are unchanged.
Configure Terminal fonts in the Ghostty config instead.

Each option is independent: removing it restores its default, and an invalid
value uses its default and appears with its line in the Config problems banner
while valid sibling settings still apply. An unavailable family is also a
problem and uses `system`. A YAML syntax error keeps the entire last good Config.

## Git View

The Git View (⌘G, `toggle_git_view`) is a look at the repository of the current
Window's folder, where you can stage, discard and commit changes, or lines of
them, laid out like Xcode's source control navigator and colored with the
Ghostty theme. A toolbar shows the repository, whether this is
a linked worktree, and the commits ahead of and behind the upstream (or `main`
or `master` without one), and a merge, rebase, cherry-pick, revert or bisect in
progress. Below it, the list pane, with four Git View tabs along its bottom, and
the selection's diff:

| Git View tab | Lists | The diff shows |
| --- | --- | --- |
| Changes | Changed files as a folder tree, with lazygit's two letters: the staged change in green, the unstaged one in red (`M `, ` M`, `MM`, `??`). A file's name is green when all of it is staged, red otherwise | The file's unstaged changes, then its staged ones; an untracked file as new. A folder shows every change in it |
| History | The last 300 commits of the branch you're on, with their graph: a lane per line of history, a ring for a merge, and the branches and tags at each commit | The commit's message, author, parents and changes; a merge against its first parent |
| Branches | Local branches, yours first with a check: other worktrees', gone upstreams, and commits ahead of and behind yours | The branch and its latest commits. Clicking a branch, or ↩, goes into its last 300 commits, listed like the History |
| Stashes | `git stash list` | The stash's changes |

Under the History, a branch's commits and the Stashes, the Diff files list the
selected commit's or stash's files as a tree. ↩, or a click on a file, goes into
them, and the diff then shows one file, or a folder of them; ⎋ comes back to the
commits. A branch's commits have a back button (or ⎋) to the Branches. The Git
View opens on Changes every time; the other Git View tabs are kept as you left
them, each with its own filter, and clicking the one shown goes back to its own
list. The Git View tabs count the changes and stashes.

W compares two commits, branches or stashes, as lazygit's diffing mode does. W
on a commit (in the History or a branch's commits), a branch (in the Branches)
or a stash marks it as the base: its row shows a "base" mark, and the toolbar
shows "Comparing main", or "main → 1a2b3c4" while another one is selected. Any
other commit, branch or stash you select then shows the diff from the base to it
(`git diff <base> <selection>`, renames found), in any Git View tab: mark `main`
in the Branches and select a commit in the History. A card names both ends and
the totals, and the comparison's Diff files are under the selection, as a
commit's are: ↩ goes into them, also on a branch. A branch is read at the commit
it's at; when it moves, the comparison follows it. Selected, the base shows a
note instead, and Changes show their own diff. W on another one moves the base
there; W on the base ends the comparison, and so do ⎋ where it would close the
Git View, and closing the Git View. When git fails, the diff pane says why.

e opens the file in your editor, in a new tmux Window right after the current
one, and switches to it; the Git View stays open in the Window you left, as you
left it. When the editor's Window closes, Muxify goes back to that Window. With
`editor_in_window: false`, e opens no Window and the Git View keeps Focus. In
the diff, it opens the file of the cursor's line, or of the selection's first
line, at that line's number in the new file; a removed line opens at the new line
beside it. In a list, a change or a file of the Diff files opens at its first
changed line. A folder, a commit, a branch or a stash does nothing. The file is
the one in the working tree, also for a commit's, a stash's or a comparison's
files; when it is no longer there, the Git View says so and opens nothing. tmux
runs the editor, so on a Remote Environment it opens that machine's file.

As in lazygit, space in Changes stages the file or folder, or unstages it once
all of it is staged, and a stages or unstages everything; a click on a file's
letters does the same. d asks, as lazygit does, whether to discard all of a
file's or folder's changes, back to the last commit, or only the unstaged ones,
keeping what's staged. New and untracked files are deleted; it can't be undone.
The Git View asks in a menu, as lazygit does: each choice has its key, j and k
(or ↓ and ↑) move the highlight, ↩ picks the highlighted choice, and ⎋ or q
close the menu and change nothing. While it is open, no other Git View key acts.
When an operation needs one value, such as a message, the Git View asks in a
prompt: a one-line field over the Git View, filled in when the operation has a
suggestion. ↩ submits it and ⎋ cancels with no change; a prompt for a secret,
such as a password, shows dots as you type.

In Changes, s stashes all changes, as `git stash push` does: it asks for the
stash's message, which may be empty (git then names the stash itself), and
leaves untracked files where they are. S opens lazygit's stash options as a
menu: stash all changes (a); all changes including untracked files (U); only
what's staged (s), which needs git 2.35 or newer; only what isn't staged (u),
which keeps what's staged as it is, as lazygit does it, by committing it for a
moment and undoing that commit; or all changes while keeping what's staged in
the working tree too (i). Each asks for the message next. An option with
nothing to take is dimmed, and when there is nothing to stash at all the Git
View says so and opens nothing. Stashing changes the files of the Worktree, so it
asks first while an Agent is working there, as below. The new stash is the first
in Stashes, whose count goes up.

In Stashes, the selected stash is applied, popped or dropped as lazygit's Stash
panel does, each after a confirmation menu: space applies it ("Are you sure you
want to apply this stash entry?") and the stash stays; g pops it, which applies
it and drops it; d drops it ("Are you sure you want to drop the selected stash
entry?"). ↩ or y confirms and ⎋ cancels. Apply and pop change the files of the
Worktree, so the same menu names any Agent working there, as below; drop doesn't.
When applying conflicts, the conflicted files show in Changes and the banner
says so; a pop that conflicts keeps the stash, as git does. If the stash list
changed since the stash was selected, nothing is done and the banner says so.
The lists, the Stashes count and Changes update afterwards. In the stash's Diff
files and in other tabs the keys keep their meanings: space folds a folder, and
d discards in Changes.

In Branches, space checks out the selected branch, as in lazygit; on the branch
you're on it does nothing. In History and in a branch's commits, space checks out
the selected commit and leaves a detached HEAD, which the toolbar and the commit
box show. When Changes would be overwritten by the checkout, the Git View asks
"Autostash?" ("You must stash and pop your changes to bring them across. Do this
automatically?"): ↩ or y stashes them, including untracked files, checks out and
pops the stash onto the new HEAD; ⎋ changes nothing. If the pop conflicts, the
conflicted files show in Changes, the banner says so and the stash is kept. Any
other failure shows git's message in the banner. The toolbar, History, Branches and Changes show the new
HEAD afterwards. Every checkout changes the files of the Worktree, so it asks
first while an Agent is working there, as below. In a commit's Diff files, space
still folds a folder.

Four more keys in Branches check out, as lazygit's Local branches do. n asks for a
name ("New branch name (branch is off of 'feature')"; spaces become dashes),
creates the branch off the selected one and checks it out. R asks for a new name,
starting at the current one, and renames the selected branch; elsewhere R still
reads the repository again. - checks out the previous branch, as `git checkout -`
does; elsewhere - still folds. c asks for a name in a prompt that offers the local
and remote branches matching what you type: ↓ / ↑ choose one, and ↩ checks out
the chosen one, else what was typed. A remote branch such as `origin/foo` makes a
local branch `foo` that tracks it, unless `foo` exists, which is then checked out.
Each of these goes the way space does: through Autostash?, the Agent guard and
the offer to go to another Worktree. c now commits only in Changes and in a
change's diff, as in lazygit; in History and Stashes it does nothing. A merge is
still concluded with c in Changes.

d in Branches opens lazygit's delete menu for the selected branch. Its first
choice is c, "Delete local branch", which runs `git branch -d`. A branch with an
upstream also offers r, "Delete remote branch", and b, "Delete local and remote
branch". Each asks first, naming the remote branch: "Are you sure you want to
delete the remote branch 'origin/x'?" The remote delete runs `git push <remote>
--delete <branch>` beside the write queue, with the same credential prompts as
fetch, and the toolbar says "Deleting remote branch…". b then deletes the local
branch under the rules below, including the force question and the Topic note, and
is dimmed on the branch you're on; if the remote delete fails, the local branch
stays. A branch with no upstream, or whose upstream is gone, offers only c. The branch you're
on can't be deleted: the choice is dimmed with "You cannot delete the checked out
branch!". A branch that another Worktree has checked out is refused by git, and
its message shows in the banner; a Worktree is never removed. When git refuses
because the branch is not fully merged, a second menu asks "Force delete branch"
("'X' is not fully merged. Are you sure you want to delete it?"), and y deletes it
with `git branch -D`; ⎋ keeps it. When a Topic's record remembers the branch as the
`branch` of one of its remembered Sessions' Worktrees, in this repository, the
confirmation says so: "Topic 'Fix payments' remembers this branch; Reopen will
start it again from its base." That holds for open, Dormant and Settled Topics,
and the menu names each. The Topic records are on this Mac, so a Git View on a
Remote Environment names none. Deleting a branch changes no files, so the Agent
guard doesn't join the menu. In Changes d still discards, in Stashes it still
drops, and elsewhere it does nothing.

A branch that another Worktree has checked out can't be checked out here, so
space on it asks instead, in a Git View menu: "Branch feature is checked out by
Worktree repo-feature. Go to that Worktree?" ↩ or y goes there. If a Window of
the Environment has a Pane whose folder is that Worktree or inside it, Muxify goes
to the most recent such Window, as Jump To does, with the Pane active when it
wasn't. Windows are ranked by when their Session was visited last, then by the
active Window and the latest Session activity. Folders are compared by real path.
If no Window has a Pane there, Go to… opens searched for that Worktree's Session
Path, with its row under the cursor, so you can start a Session there with ↩; the
Git View starts nothing itself. ⎋ changes nothing: nothing is checked out, and
the Git View of the Window you were in stays as it was. This question changes no
files, so the Agent guard doesn't join it. Every later checkout, such as one from
another key, asks the same way.

f in Changes fetches all remotes, as lazygit's does by default (`git fetch
--all`). The fetch doesn't wait for staging, committing or other writes, and they
don't wait for it: the toolbar shows "Fetching…" until it ends, then the
repository is read again and the counts of commits ahead of and behind the
upstream update. While a fetch runs, f does nothing more. When it fails, the
banner shows git's message, without its progress lines.

The fetch runs in a pseudo-terminal with `LANG`, `LC_ALL` and `LC_MESSAGES` set to
`C`, as lazygit runs it, so git's and ssh's questions are in English. Muxify
watches its output for lazygit's credential prompts (`Password:`, `<user>'s
password:`, `Password for '…':`, `Username for '…':`, `Enter passphrase for key
'…':`, `Enter PIN for … key …:`, `Enter PIN for '…':` and `2FA Token`) and for
ssh's question about an unknown host ("Are you sure you want to continue
connecting (yes/no/[fingerprint])?", shown with the host and fingerprint ssh
named). Each is asked in a Git View prompt whose title is git's or ssh's
question; for a password, passphrase, PIN or token what you type is hidden, and
the prompt says "Hidden". ↩ writes the answer into the terminal, ⎋ stops the
fetch and the banner says "Fetch cancelled.". The fetch's two-minute timeout
doesn't run while a question waits. Selecting another Window keeps the question
for when you come back; closing the Git View stops the fetch. On a Remote
Environment the fetch runs over SSH with a remote terminal (`ssh -tt`), so the
same questions come from the remote machine. Other git commands of the Git View
run without a terminal and fail with git's message when they would ask.

P pushes the branch you're on and p pulls it, in every tab of the Git View.
The push runs beside the other writes, as the fetch does, and the toolbar shows
"Pushing…" until it ends. A branch with no upstream asks for one in a Git View
prompt, "Enter upstream as '<remote> <branch>'", starting at `origin <branch>`;
↩ pushes the branch to that remote branch and sets it as the upstream, and an
answer that isn't two words is told how to write it. When the upstream has
commits the branch doesn't, a menu asks "Your branch has diverged from the remote
branch. Press ⎋ to cancel, or ↩ to force push." and only ↩ pushes, with
`--force-with-lease`, which stops when the remote branch has moved since the last
fetch. Any other push is a plain `git push`, so a rejection shows git's message
in the banner. A push changes no files here, so the Agent guard doesn't join it.

The pull is `git pull --no-edit`, so it follows your git config, such as
`pull.rebase`, and a merge doesn't wait for an editor. It waits in the write
queue, behind the writes before it, and the writes after it wait for it; the
toolbar shows "Pulling…" while it runs. It changes files, so it goes through the
Agent guard: with an Agent working in the Worktree, a "Pull" menu names it and
asks for y. A branch with no upstream asks as push does, after which the pull
takes that remote branch and sets it as the upstream. A pull that conflicts
leaves the merge or the rebase in progress, with the conflicted files in
Changes, and the banner says so; any other failure shows git's message, such as
the question of how to reconcile divergent branches. Both run in the same
pseudo-terminal as the fetch, with its credential prompts and its "Push
cancelled." and "Pull cancelled." banners. A detached HEAD has no branch to push
or pull, and the banner says so.

m, in every tab, goes on with a merge, rebase, cherry-pick, revert or `git am` that is in progress, as lazygit's
does. It opens a Git View menu of c (continue), s (skip) and a (abort); a merge has no skip, as git has none. Nothing
opens an editor: a continue keeps git's message, and `git rebase --continue` and its kin run with the editor set to
`true`. Each goes through the Agent guard, since each changes files, so with an Agent working in the Worktree the menu
names it. While conflicts remain, git refuses to continue and the banner shows its reason, with a line saying to
resolve them in Changes and stage each file; a continue that reaches new conflicts, as a rebase does at its next
commit, leaves them in Changes, and m continues again. With nothing in progress, m says so; a bisect isn't continued
from the Git View. The toolbar's tag and the banner of c and A point at m.

After you stage the last conflicted file with space or a, the Git View asks lazygit's "All merge conflicts resolved.
Continue the rebase?", naming the operation in progress: ↩ continues and ⎋ leaves it for later, when m still does it.
It asks only after staging in the Git View, not when conflicts were resolved elsewhere.

A in Changes amends the last commit with what's staged, as lazygit does, and keeps its message. It asks first, in a
Git View menu: "Are you sure you want to amend the last commit?". Hooks and signing run as they do for c; when one
fails, the banner shows what it said. With nothing staged, with no commit yet, or while a merge, rebase, cherry-pick,
revert or `git am` is in progress, A changes nothing and the banner says why. A commit that is already pushed can be
amended; the next push then asks to force push.

M in Branches merges the selected branch into the one you're on, as lazygit does. It opens a menu titled "Merge 'X'
into 'Y'" with four choices: a regular merge, which fast-forwards when it can and else makes a merge commit (f); a
regular merge that always makes a merge commit, as `git merge --no-ff` does (n); a squash merge that commits what it took
in one commit, with the message git prepared (s); and a squash merge that leaves the changes staged (u). The merge runs
without an editor and keeps git's message, and it goes through the Agent guard. When it conflicts, the banner says so
and the conflicted files are in Changes. A merge stays in progress as git leaves it: after you stage the files, c
concludes it, and m continues or aborts it (m then c is the same). A squash merge is not a merge to git, so it leaves
only the conflicts: stage them, then c commits, or reset to give it up. On the branch you're on, M changes nothing and
the banner says a branch can't be merged into itself; while a merge, rebase or the like is in progress, the banner asks
you to continue or abort it first. When your uncommitted changes are in the way, git's own message shows.

r in Branches rebases the branch you're on onto the selected one, as lazygit's simple rebase does. It opens a menu
titled "Rebase 'Y'" with one choice, "Simple rebase onto 'X'" (s), which runs `git rebase X` without an editor, and it
goes through the Agent guard. The interactive rebase and the rebase onto a base branch are not offered. When it
conflicts, the banner says so and the rebase stays in progress with the conflicted files in Changes: after you stage the
last one, Muxify asks to continue, and m continues, skips or aborts it. Commits that were already pushed can be rebased;
their hashes change, so the next push asks to force push. On the branch you're on, r changes nothing and the banner says
a branch can't be rebased onto itself; while a merge, rebase or the like is in progress, the banner asks you to continue
or abort it first. When your uncommitted changes are in the way, git's own message shows.

g in History, in a branch's commits and in Branches resets the branch you're on to the selected commit or branch, as
lazygit's Reset menu does. It opens a menu titled "Reset to X" with three choices, each with a note: s, a soft reset
(`git reset --soft`), keeps the changes between the two commits as staged changes; m, a mixed reset, keeps them as
unstaged changes; h, a hard reset, discards them and all current Changes. Soft and mixed run at once. A hard reset that
would discard Changes asks once more, as d does: "Discard N files and reset", with "This can't be undone." beside
Cancel; N counts the files `git reset --hard` puts back, not the untracked files, which stay. That second menu also
carries the Agent guard, naming any Agent working in the Worktree, and a hard reset with no Changes still asks through
the guard. Soft and mixed don't, as they leave the files as they are. Afterwards the lists show the new HEAD. In
Stashes, g still pops the selected stash.

C in History and in a branch's commits copies the selected commit, or takes it out again, as lazygit's cherry-pick
does. Copied commits show a "copied" mark on their rows in every commit list, and the toolbar says "N copied". V in
History asks, in a menu, "Are you sure you want to cherry-pick the N copied commit(s) onto this branch?" and, on y,
cherry-picks them onto the branch you're on, oldest first, whatever order you copied them in; the menu also carries the
Agent guard, naming any Agent working in the Worktree. When the pick succeeds, the Copied commits are cleared. ⌃R
clears them at any time. A pick that conflicts stops with the conflicted files in Changes, and m continues, skips or
aborts it; the Copied commits stay until a paste succeeds. As in git, a cherry-pick wants staged changes committed or
stashed first: when git refuses, its message shows. Copied commits belong to the repository, not to the Window:
they are kept by the repository's common git directory, which every Worktree shares, so you can copy in the Git View of
one Topic's Worktree and paste in the Git View of a Window in another. A different repository has its own. They are
kept while Muxify runs and are not saved.

An operation that changes the files of the Worktree asks first while an Agent is
working there. If a Pane whose folder is the Worktree or inside it runs an Agent
that is working or blocked, the menu names each such Agent, by its Topic, or by
its Session when it has none, and the operation runs only when you confirm; ⎋
changes nothing. Agents that are done, failed or have no Status don't count, and
neither do Agents in other Worktrees of the same repository or in folders
outside it. An operation that asks already, such as Discard changes, shows the
Agents in its own menu instead of asking twice. Discard is the first to ask this
way; the operations that follow use the same guard.

In a change's diff, space stages the line under the cursor, the lines selected
with v, or the hunk selected with a; in its Staged part, it unstages them. d
there discards the selected unstaged lines, after asking. A new file's lines are
staged the same way. A conflicted file is staged whole, and only once it has no
conflict markers left; `git add` in the terminal stages it anyway.

c opens a box for the commit's summary and description: ↩ in the summary or ⌘↩
commits, and ⎋ closes it, keeping what you wrote until the Window's folder is in
another repository. A commit takes only what's staged; with nothing staged, c
does nothing but say so. On a detached HEAD, the box warns that the commit won't
be on any branch. During a merge, c concludes it once its conflicts are staged,
with git's message for it unless you've written one; during a rebase,
cherry-pick, revert or `git am`, c says to continue it with m instead.
Hooks and signing run as they do in a terminal; when one fails, the box shows
what it said.

Diffs have line numbers, syntax highlighting, and the enclosing function in each
hunk's header. The toolbar switches them between Unified and Split (side by
side); the choice is remembered. In a changed line, the words that changed are
marked with a stronger band than the line's, on both the removed line and the
added line it pairs with, as GitHub and delta do: a run of removed lines pairs
in order with the added lines right after it. A line with no pair, a pair
rewritten more than it's kept, a line over 1,000 characters and a block of over
100 lines show only the line's band. A change's hunk headers show the whole file.
Long lines wrap at the pane's edge. Drag over code to select words or any
part of it, double-click a word, triple-click or drag the line numbers for whole
lines, or use the keys; ⌘C or y copies the code. The filter field (/) narrows
the list shown.

```yaml
git_view:
  display: popup      # or fullscreen
  width: 80%
  height: 80%
  editor: nvim +{line} {file}   # without it: ${VISUAL:-${EDITOR:-vi}} +{line} {file}
  editor_in_window: true
```

The sizes are the defaults. `popup` floats over the whole App Window, Sidebar and
Browser too, like `tmux display-popup -w 80% -h 80%`; `width` and `height` are
its share of the App Window, from 10% to 100% (`80` means `80%`). `fullscreen`
takes the terminal's place, leaving the Sidebar and Browser. `editor` is the
shell command that e runs, in the repository's root folder, such as
`hx {file}:{line}`. It must name `{file}`; `{line}` is the line number. Both are
filled in for you, and `{file}` is the file's absolute path, shell-quoted.
Without `editor`, e runs `${VISUAL:-${EDITOR:-vi}} +{line} {file}`.

`editor_in_window: false` runs `editor` in the background, on the Environment's
machine, with no tmux Window: for a command that hands the file to an editor
that already runs. When it fails or runs over 10 seconds, the Git View says so.
For example, to open the file in a Neovim that listens on a socket:

```yaml
git_view:
  editor: >-
    nvim --server /tmp/nvim.sock --remote {file} &&
    nvim --server /tmp/nvim.sock --remote-send '<C-\><C-N>{line}G'
  editor_in_window: false
```

Changes apply live; invalid values use the defaults and appear in the Config
problems banner.

The Git View reads the repository when it opens, every 10 seconds, when Muxify
comes to the front, with R, and after you stage or commit. On a Remote
Environment, git runs on that machine. Code is sized from the terminal's font
size, in the system's monospaced font. Each Window has its own Git View: select
another Window and it stays open there, as you left it, until you come back; it
isn't read again meanwhile. A Window whose Git View is open shows its icon in the
Sidebar. The Git Views go when Muxify quits. The Git View's keys are in
[Keybindings](keybindings.md#git-view-keys).

## Command Palettes

A Command Palette searches Topics, Sessions, Windows, Agents and Commands.
It acts on the highlighted result or runs the highlighted Command. Each palette has a name, a keybinding that works anywhere
in Muxify, and the sources selected when it opens:

```yaml
command_palettes:
  - name: Commands
    keybinding: cmd+shift+p
    sources: [commands]
  - name: Go to…
    keybinding: cmd+p
    sources: [topics, sessions]
  - name: Agents
    keybinding: cmd+shift+o
    sources: [agents]
```

Without `command_palettes`, Muxify has two palettes. **Commands** opens on
⇧⌘P with only `commands`. **Go to…** opens on ⌘P with `topics` and `sessions`.
`command_palettes: []` removes both. Names must be unique. `sources` accepts:

- `topics`: with no query, other live Topics by most recent visit, then the current
  Topic, then Dormant and Empty Topics. Pins do not override this order; they
  still determine Sidebar order. Activity breaks visit ties using the most active
  member Session. Its Snoozed and Settled Topics
  come after the rows of every other Source, even when they match the query
  better. Only a Local App Window with Topics on has them.
- `sessions`: one row per running Session, including Topic members in either
  Sidebar mode, then [Session Paths](#session-paths) whose exact launch names are not
  running. ↩ selects that Session or launches that exact name. ⌘↩ starts another
  Session in the row's Topic or No Topic scope, with `+2`, `+3`, etc. before its
  Topic suffix. With no query, other running Sessions rank by visits/activity,
  the current Session is last among running rows, then unopened paths follow.
- `windows`, shown with nothing typed only when theirs is the only Source button on.
- `agents`: those that need you (blocked, failed or unread), then working ones,
  then the rest.
- `commands`: Commands such as New Topic, New Muxify Window, Reload Config
  and Browser commands. A Command acts on no result.

They aren't a hard limit: every palette has a Source button for each source, its own
first and on, and ⌘1–⌘5 or a click turn any Source button on or off. The last
Source button that is on stays on. A palette's `keybinding` takes one trigger or a list and
follows the [keybindings](keybindings.md) rules: it is removed from other
actions' defaults, and when two claim the same trigger the first in the file
keeps it. Each palette is also in the View menu. Its own keybinding closes a
palette; another palette's keybinding switches to that one and keeps what you
typed.

Results stay in sections, one or more for each source. Words match in any
order, fzf style, on the name, a type word (`topic`, `dormant`, `snoozed`,
`settled`, `session`, `worktree`, `window`), the details under the
name, or a Settled Topic's outcome, and the matched letters are marked. A word
must match at least 55% as well as it matches itself, so its letters spread
over a long path do not match. A word of one letter matches anywhere. With
nothing typed, Topics and Sessions put the current live row last among live rows,
before entries with nothing running. Other live rows are most recently visited first.
Typed queries use fuzzy match quality, without pushing the current row down.
On an equal match, the shorter name comes first, as fzf's default
`--tiebreak=length`. Then live entries come before unopened ones, then the more
recently visited or active one.

`show` gives the kinds of rows that a palette lists. Without `show`, the
palette lists every kind. The [row kinds](#row-kinds) are the words of `show`. A
word that is not a row kind, or an empty list, is a problem, and the palette is
not added. `show` does not change which sources a palette searches: a kind
that the selected sources do not have shows no rows.

To list No Topic Sessions in Go to… but not the Sessions of open Topics:

```yaml
command_palettes:
  - name: Go to…
    keybinding: cmd+p
    sources: [topics, sessions]
    show: [topic, snoozed, settled, session, session-path, worktree]
```

When a Session runs with the launch name of a Session Path, the palette lists
the Session and not the path. When `show` leaves out the kind of that Session,
the palette lists the path again.

### Row kinds

| Kind | Row |
| --- | --- |
| `topic` | An open Topic |
| `snoozed` | A Snoozed Topic |
| `settled` | A Settled Topic |
| `session` | A running Session in no open Topic: a No Topic Session, or a Session of a Settled Topic |
| `topic-session` | A running Session in an open Topic, Snoozed or not |
| `session-path` | A Session Path, or a checkout inside the folder of a bare repository, with no running Session |
| `worktree` | A Worktree outside the folder of its Session Path, with no running Session |
| `window` | A Window |
| `agent` | An Agent |
| `command` | A Command, or a choice in an Action |
| `tag` | A Tag |

A Window with an Agent is left out while the Agents Source button is on. ⎋ closes the
palette without a change. In an Action, ⌫ in an empty field goes back one step.
A step that kills a process needs ⌘↩ to confirm. The keys inside a palette are
[configurable](keybindings.md#command-palette-keybindings).

| Action | Topic | Session | Window | Agent | Session Path or Worktree |
| --- | --- | --- | --- | --- | --- |
| Jump to (↩) | Go to its Window, Reopen it when Dormant, or show its Reopen choice when Settled | Switch to it | Select it | Select its Window and Pane | Create the Session there, then switch |
| New Session (⌘↩) | — | — | — | — | Start another Session there, then switch |
| Copy Path (⌘C) | — | Its start folder | The active Pane's folder | The Pane's folder | The folder |
| Copy tmux Target (⌘⇧C) | — | Session name | `session:index` | Pane ID | — |
| Paste Path (⌃Y) | — | Its start folder | The Pane's folder | The Pane's folder | The folder |
| Snooze (⌃S) | Open the Snooze sheet, except when Settled | — | — | — | — |

⌘K opens these actions in a menu by the highlighted row.

## Pick lists

An Action that asks you to choose a row, such as Add a Session, shows a pick
list. `pick_lists` gives a pick list the `show` key of a
[Command Palette](#command-palettes). Each entry has the name of a pick list:

```yaml
pick_lists:
  add_session:
    show: [session-path]    # no running Sessions and no Worktrees
```

| Pick list | Action | Kinds for `show` |
| --- | --- | --- |
| `add_session` | Add a Session, also after New Topic | `session`, `topic-session`, `session-path`, `worktree` |
| `move` | Move to…, the Topic step | `topic` |
| `move_session` | Move to…, the step that chooses a Session | `session`, `topic-session` |
| `snooze_topics` | Snooze Topics…, the step that checks Topics | `tag`, `topic`, `snoozed` |
| `unsnooze_topics` | Unsnooze Topics…, the step that checks Topics | `tag`, `snoozed` |
| `unsnooze_topic` | Unsnooze Topic, when the Active Topic is not Snoozed | `snoozed` |
| `tags` | The Tags of New Topic and Edit Tags… | `tag` |
| `worktree_start` | Add a Session › New Worktree from | `command` |

A pick list without an entry lists every kind. The rows that a pick list always
shows, such as New Topic in Move to…, ignore `show`. These problems apply to one
entry: a name that is not in the table, a key other than `show`, an empty
`show`, or a kind that the pick list does not have. Muxify shows the problem,
and that pick list lists every kind.

## A Remote Environment's own Config

A Remote Environment's App Window uses the Config on that machine
(`~/.config/muxify/config.yaml`, or under its `$XDG_CONFIG_HOME`) when there is
one, as if Muxify ran there: its Session Paths, palettes, keybindings and `ui`.
Its `ghostty`, `browser` and `remote_environments` sections are ignored, because
they describe this Mac's app. Without a remote Config, the local Config applies, and
its Session Paths are looked for on the remote. Topics stay on this Mac. The menu shows the focused App
Window's keybindings.

Muxify reads the remote file when it connects, on **Reload Config** (⌘⇧,), and
each time a palette opens; it doesn't watch it. A syntax error keeps the last
good remote Config, and its problems show in that App Window with the host in
front of the path. **Open Config** there opens the remote file in the remote's
`$VISUAL` or `$EDITOR` in a new tmux Window.

## Browser and keybindings

The top-right header has the Maximize button and toggles the Sidebar, the Git
View, the Terminal and the Browser. ⌘J toggles the current Window's Terminal and
⌘B its Browser; the toggle of the only side shown does nothing. Maximize (⇧⌘↩)
shows the side that has Focus alone, with the Sidebar hidden. Press it again to
Restore the Window. ⌘⇧J and ⌘⇧B move Focus to the Terminal or the Browser and
show that side if it is hidden. Each Window remembers its Browser Tabs, its
toggles and its Maximize state.
Browser-opening requests (`muxify browser open …`, terminal Cmd-click links)
reveal its Browser.

[Vim Keys](keybindings.md#vim-keys) scroll a Browser page with h, j, k, l, d,
u, gg and G, and go back and forward with H and L. They are on by default. To turn them off:

```yaml
browser:
  vim_keys: false
```

The change applies to the pages that are open and to the pages that load later.

Configurable [Keybindings](keybindings.md) work throughout the app, including in
Browser pages. The guide lists all actions, defaults, built-in shortcuts and a
complete Config example.

Numbered card and Tab shortcuts show key-only [Hints](keybindings.md#hints) at rest.
Window rows can show them too. A modifier hold shows full triggers.
Hints use the resolved keybindings of the Active Environment's Config, including remaps and disabled actions.

### Check whether a program runs from Muxify

When the Muxify CLI is installed, run `muxify browser available` when the program starts.
It prints `local`, `remote` or `no`. It exits 0 for `local` or `remote`, and 1 for `no`.
The command uses the same Client check as the script below and does not start Muxify.

On a machine without the CLI, run this `/bin/sh` check when the program starts. It prints `local`, `remote`,
or `no`. It needs only `tmux` and shell builtins. It checks the most recently
active non-control Client of the Pane's own Session. When no such Client shows
that Session, for example because Muxify shows another Session, it checks the
most recently active non-control Client on the server.

```sh
muxify_environment() (
    [ -n "${TMUX_PANE:-}" ] || { printf '%s\n' no; return; }
    newest_client() {
        newest=-1
        client=
        while read -r activity control pid; do
            [ "$control" = 0 ] || continue
            if [ "$activity" -gt "$newest" ]; then
                newest=$activity
                client=$pid
            fi
        done <<EOF
$1
EOF
    }
    format='#{client_activity} #{client_control_mode} #{client_pid}'
    clients=$(tmux list-clients -t "$TMUX_PANE" -F "$format" 2>/dev/null) || { printf '%s\n' no; return; }
    newest_client "$clients"
    if [ -z "$client" ]; then
        clients=$(tmux list-clients -F "$format" 2>/dev/null) || { printf '%s\n' no; return; }
        newest_client "$clients"
    fi
    [ -n "$client" ] || { printf '%s\n' no; return; }
    options=$(tmux show-options -s 2>/dev/null) || { printf '%s\n' no; return; }
    separator='␟'
    while read -r option rest; do
        case "$option" in
            @muxify_client_*)
                marker=$(tmux show-options -sqv "$option" 2>/dev/null) || continue
                [ "${marker%%"$separator"*}" = "$client" ] || continue
                kind=${marker##*"$separator"}
                case "$kind" in
                    local|remote) printf '%s\n' "$kind"; return ;;
                esac
                ;;
        esac
    done <<EOF
$options
EOF
    printf '%s\n' no
)
muxify_environment
```

Each Muxify Client has a server option named `@muxify_client_<nonce>`. Its value
has five `␟`-separated fields: Client PID, TTY, home directory, host name, and
`local` or `remote`. Muxify removes its option when the Client detaches. A stale
option from a crash cannot match a Client that is no longer connected.

The result describes the time of the check. Input through another Client can
change it. tmux records Client activity in whole seconds. If Clients have the
same activity time, the check uses the first one in `list-clients`.

For `local`, a program can use `muxify browser open <url>`. For `remote`, it can
set `tmux set-option -w -t "$TMUX_PANE" @muxify_open <url>`. A page served on a
remote machine needs an address that the Mac can reach, such as its Tailscale
address. For `no`, use the program's normal browser behavior.

## Hints

All keys are optional. These are the defaults:

```yaml
hints:
  hold_delay: 0.35
  cards: { always: true, hold: true }
  windows: { always: false, hold: true }
  tabs: { always: true, hold: true }
  terminal: { hold: true }
```

`hold_delay` is a finite, nonnegative number of seconds. `0` shows hold Hints at once.
`false` disables hold Hints everywhere. `always` controls key-only Hints at rest.
`hold` controls full trigger Hints while a modifier is held alone.
The Terminal has no rest Hint and accepts only `hold`.

Changes apply live and use the Active Environment's Config.
With both switches off, an item has no Hint. Its shortcuts still work.
Cards use the leading title gutter. Window rows reserve a leading slot when `always` is true.
Tabs use the globe slot, except when a loading spinner is visible.
See [Hints and shortcut positions](keybindings.md#hints) for key remaps and hold behavior.

## Sidebar

`sidebar.topics` and `sidebar.sessions` enable the two Sidebar modes. Both default to `true`.
`sidebar.panes` shows or hides Pane rows. Leave it out to use **View > Show Panes**.
`sidebar.agents` shows or hides the Agents section. Leave it out to use **View > Show Agents**.
A configured value disables the corresponding View menu choice.

`sidebar.agents_scope` selects which Agents appear. It defaults to `active`.

| Value | Agents shown |
| --- | --- |
| `active` | The Active Topic in Topics mode, or the selected Window's Session in Sessions mode. |
| `window` | The selected Window, in either mode. |
| `all` | Every Agent. |

Without a selected Window, `active` and `window` show every Agent.
The existing Snooze and Zen rules still hide quiet Agents.
`agents` and `agents_scope` accept one value for both modes, or a mapping with `topics` and `sessions` values.

```yaml
sidebar:
  panes: true
  agents:
    topics: true
    sessions: false
  agents_scope:
    topics: window
    sessions: all
```

### Switching Topics and Sessions

Switch views with the Topics/Sessions buttons or a two-finger horizontal swipe
anywhere over the Sidebar, also over Agents. A swipe over the terminal or the
browser scrolls there and does not switch views. `sidebar.animate_switching` defaults to `true`. Set it to `false`
to switch instantly, without the sliding preview, spring, scale or fade. Buttons
and swipes still work, and both lists keep their scroll positions and opened cards.
Changes apply live. macOS Reduce Motion also disables these animations.

```yaml
sidebar:
  animate_switching: false
```

### Card titles

A long Topic or Session card title wraps onto as many lines as it needs, so it always shows whole.
`sidebar.titles.wrap: false` keeps each card title on one line and cuts a long one with `…` at the card's edge.
It defaults to `true`. The cut follows the Sidebar's width, which a Format's `#{=N:…}` cannot see.

```yaml
sidebar:
  titles:
    wrap: false
```


### Window tooltips

`sidebar.window_tooltips` controls the hover label on Window rows in both Sessions
and Topics mode, including remembered Windows in Settled Topics.

- `off`: never show the label.
- `truncated`: show it only when the row's formatted title is cut off.
- `always` (default): show it whenever the pointer rests on the row.

The label shows the Window's location and, when cut off, its full title. Changes
apply on Config reload, including to a label that is already open.

```yaml
sidebar:
  window_tooltips: truncated
```

### Tags on Topic cards

`sidebar.tag_placement` sets where a Topic card shows its [Tags](#tags):

| Value | Tags shown |
| --- | --- |
| `none` (default) | No Tags on the cards. |
| `corner` | One Tag Mark per Tag, a small square in the Tag's color, at the right end of the title's first line, on closed and open cards. |
| `title` | The first Tag as a chip, then a `+N` chip for the others, at the right end of the title's first line. A long title wraps under them at the full card width. |
| `line` | Chips on their own line under the title, before Dormant or Empty. When they do not all fit, the line ends with `+N`. |

In `corner` and `title`, the title line is, from left to right: the title, the
Hint, a Snoozed Topic's wake time, the Pin or Lock, and the Tags. Tag editing
does not depend on this setting: Edit Tags… and `#` in New Topic work whenever
`topics.tags` exists.

The hover label and the accessibility value of the Tags name every Tag. A
closed card in the Snoozed or Settled group shows no Tags; an opened one shows
them as an open card does. Locked Sessions and Session cards show no Tags.

```yaml
sidebar:
  tag_placement: corner
  formats:
    topic:
      tags: '#{T:#{tag}}'
```

`sidebar.formats.topic.tags` gives the text of each Tag: each pass of the `T`
loop is one chip, or one Tag Mark's hover text. A pass with no text leaves its
Tag out, and `''` hides the Tags. Text outside the `T` loop does not show.
Muxify draws the `+N` itself, so one Format serves every placement. It can
differ by Sidebar mode, as other parts can; Topic cards show only in Topics
mode. `null` keeps the default. To show Tags as plain text instead, set
`tags: ''` and put `#{topic_tags}` in the Summary.

### Formats

`sidebar.formats` sets the title and Summary of Topic cards, Session cards, Window rows, Pane rows, and Agent rows, and the Tags of Topic cards.
Each `title` or `summary` accepts a string, or a mapping with `topics` and `sessions` values.
An empty Summary hides its line. An empty title uses the default title.
Card Summaries appear only when the card is closed.
Session headings within Topics, Snoozed and Settled Topic rows, and Command Palette rows keep their existing text.
A Window, Pane or Agent row's hover label shows the formatted title, in the row's font, when the row cuts it off.
The line under it keeps its existing text.
With `agents_scope: window`, the Agents section header uses the formatted Window title.

```yaml
sidebar:
  formats:
    topic:
      summary: '#{S:#{session_base_name}#{?branch, ⎇ #{branch},}#{?loop_last_flag,, · }}'
    session:
      summary: '#{window_count}w #{pane_count}p'
    window:
      title: '#{window_index}:#{window_title}'
      summary:
        topics: '#{?agent_kind,#{agent_kind} · #{agent_status},#{b:pane_current_path}}'
        sessions: ''
    pane:
      summary: '#{pane_current_command}'
    agent:
      title:
        topics: '#{?topic_title,#{topic_title},#{window_name}}'
        sessions: '#{window_name}'
      summary: '#{agent_kind} · #{agent_status}'
```

Title and Summary Formats produce plain text. Window `left` and `right` Formats can also produce icons.
Muxify parses each configured Format once, when it reads the Config.
Bad syntax or an unknown variable produces a Config problem with its line number. Only that Format uses its default.
`#[` is reserved for future styles and is a Config problem. Use `##[` for literal text.

Window `left` replaces the app icon. Window `right` replaces the Tab and Pane badges.
Each accepts one Format string or separate `topics` and `sessions` values.
An omitted value or `null` keeps the built-in part. An empty string, or an expansion with no output, hides the part.
A custom right part does not change the bell indicator.

```yaml
sidebar:
  formats:
    window:
      left: '#{current_app_icon}'
      right:
        topics: '#{symbol:globe} #{tab_count}  #{symbol:rectangle.split.2x1} #{window_panes}'
        sessions: '🌐 #{tab_count}'
```

`#{current_app_icon}` draws the Window's app icon. This remains the row's Window icon inside a loop.
`#{symbol:name}` draws a macOS SF Symbol, such as `globe` or `rectangle.split.2x1`.
The symbol name must be literal and available on the Mac that reads the Config.
An unavailable symbol produces a Config problem for that part and mode. Other valid parts still apply.
Emoji are literal text. Spaces in a Format separate text and icons.

Icons are allowed only in Window `left` and `right` output, including conditional result branches and loop bodies.
Conditions, comparisons, truncation, and basename operations accept text only. An icon anywhere in those operands is a Config problem.
Expanded variable values remain text, even when they contain icon syntax.
Title and Summary Formats reject icon expressions. Sidebar typography still controls font, size, and color.
The built-in right part shows a Tab badge only when Tabs exist. It shows a Pane badge for every Window in Topics mode, and for multiple Panes in Sessions mode. While one Pane of the Window is Zoomed, the Pane badge is accent-colored on an accent capsule.

| Expression | Result |
| --- | --- |
| `#{name}` | A variable's value. |
| `#{?condition,yes,no}` | `yes` when the condition is neither empty nor `0`; otherwise `no`. A bare condition is a variable name. |
| `#{==:a,b}`, `#{!=:a,b}` | `1` or `0`. Each operand is literal text with optional nested expressions. |
| `#{=N:name}`, `#{=-N:name}` | The first or last N characters of the variable. A nested expression can replace the variable name. |
| `#{b:name}` | The last nonempty part of a path. A nested expression can replace the variable name. |
| `#{S:body}`, `#{W:body}`, `#{P:body}` | Repeat the body for each contained Session, Window, or Pane. |
| `#{T:body}` | Repeat the body for each Tag of the Topic, in Config order, then the Tags the Config no longer defines. |
| `#,`, `##`, `#}` | A literal comma, hash, or closing brace. |

Expressions can nest, up to 64 levels. Both branches of a conditional must be valid.
Inside a loop, `loop_index` starts at `0`. `loop_first_flag` and `loop_last_flag` are `1` on the first and last item.
A nested loop uses its own index and flags. An empty loop produces no text.
A known variable with no value in the current object produces no text.
A loop that the current object does not contain produces no text.

| Object | Variables | Loops |
| --- | --- | --- |
| Topic | `topic_title`, `topic_pinned_flag`, `topic_dormant_flag`, `topic_tags`, `tag_count`, `session_count`, `window_count`, `pane_count`, `agent_count`, `agents_working`, `agents_unread` | S, W, P, T |
| Tag, inside `T` | Its Topic's variables, plus `tag` | None |
| Session | `session_name`, `session_base_name`, `branch`, `topic_title`, `topic_tags`, `window_count`, `pane_count`, `agent_count`, `agents_working`, `agents_unread` | W, P |
| Window | Its Session variables, plus `window_index`, `window_name`, `window_title`, `window_panes`, `window_zoomed_flag`, `pane_current_command`, `pane_current_path`, `tab_count`, `agent_kind`, `agent_status` | P |
| Pane | Its Window and Session variables, plus `pane_index`, `pane_label`, `pane_title`, `pane_current_command`, `pane_current_path`, `pane_active_flag`, `agent_kind`, `agent_status`, `agent_unread_flag`, `agent_group` | None |
| Agent | Its Pane variables, including its own Window, Session, and Topic values | None |

Window Agent counts describe that Window. `agent_kind` and `agent_status` describe its first Agent in Pane order.
Its `pane_current_command` and `pane_current_path` describe the active Pane.
Pane values replace the inherited command, path, branch, Agent kind, and Agent Status.
Agent counts remain those of the Window.
Agent Formats use the Agent's own Pane, even when another Pane is selected.
`agent_group` is the Topic row title, or `No Topic`, in Topics mode. It is the Session name in Sessions mode.
It is empty for a Pane without an Agent, or when the Agents section is scoped to one Topic, Session, or Window.
A custom Agent Summary appears whenever its expansion is not empty, including in a scoped section.
Counts include Panes even when Pane rows are hidden. Flags use `1` and `0`.

`session_base_name` is the actual Session name without its managed Topic suffix;
`session_name` is the full tmux name. `branch` comes from the HEAD at the Session or Pane path.
Muxify reads the repository files directly and caches each file read for one refresh. It does not start git.
`branch` is empty on a Remote Environment or a detached HEAD.

`tag` is the Tag's name, as the record stores it. `tag_count` is the number of the Topic's Tags.
`topic_tags` is the Topic's Tags as plain text, such as `#work #personal`. It is also on Session, Window, Pane and Agent rows, for their Topic. The color of a
Tag is not a Format value: the card draws it. With Tags off, these values are empty.

The default Formats preserve the existing text. Window and Pane Summaries are empty.

| Line | Default Format |
| --- | --- |
| Topic title | `#{topic_title}` |
| Topic Summary | `#{?session_count,#{S:#{session_base_name}#{?loop_last_flag,, · }} · #{window_count} #{?#{==:#{window_count},1},Window,Windows},No Sessions}` |
| Session title | `#{session_name}` |
| Session Summary | `#{window_count} #{?#{==:#{window_count},1},Window,Windows}` |
| Window title | `#{window_title}` |
| Pane title | `#{pane_label}` |
| Agent title | `#{pane_label}` |
| Agent Summary | `#{agent_group}` |
| Topic Tags | `#{T:#{tag}}` |
