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
inside a repository.

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

Move a Session with a long press on its line in an open Topic card: the Session
lifts with its Windows, the other Sessions slide aside, and an outlined
placeholder shows where it lands. Move Up and Move Down in the line's context
menu move it too. The Topic then keeps your
order, in its record, and a new Session goes to the end that `session_order`
gives new Sessions: the bottom for `oldest_first`, the top for `newest_first`.
A change of `session_order` does not change an order you gave. Sort Sessions by
Creation in the context menu goes back to the creation order. No Topic and the
Sessions mode keep the tmux order. Any other value uses the default and appears
in the Config problems banner.

A long press on a Window row moves the Window, with its Pane rows, within its
Session, in any card. The Session keeps its current Window, and tmux keeps the
new order. Topic cards and Locked Session cards move the same way among the
cards with their pin.

## Header height

```yaml
ui:
  header_height: 30
```

The height is in macOS points, defaults to 30, and must be a finite number of
at least 24 so the buttons fit. Changes apply live. Removing the setting restores
the default; invalid values use the default and appear in the Config problems
banner. A YAML syntax error keeps the last good Config.

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
  manual_read: true
  done_enabled: true
  failed_enabled: true
  blocked_enabled: true
```

Manual Read is on by default. A done, failed or blocked update becomes Unread
even while you look at its Window. Visiting a Window or Topic does not clear it.
**Mark Read** clears the Active Topic, or the current Session when there is no
Active Topic. Its default shortcut is ⌘⇧R. A palette row also offers Mark Read
for that Topic, Session, Window or Agent. A blocked mark stays until the Agent
is no longer blocked.

**Mark Unread** marks any Topic as Unread, including an empty, Dormant, Snoozed
or Settled Topic. The mark is saved with the Topic and does not require an Agent.
Mark Read clears it. A Snoozed Topic keeps its mark but hides it until Snooze ends.
Its Command and shortcut, ⌘⇧U, use the same target as Mark Read. A palette row
also offers Mark Unread for that Topic, Session, Window or Agent. For Agents,
Mark Unread applies to done, failed or blocked Status. It does not change Status.

**Mark All as Read** clears Unread in the Active Environment, including all Topic marks and Unread
working Agents. This includes hidden, Snoozed and Settled Topics. It has no default shortcut. Set `keybindings.mark_all_read` to
assign one. Use `keybindings.mark_unread` to change the Mark Unread shortcut.
The palette row Action has no default shortcut. Set
`keybindings.command_palette.mark_unread` to assign one.

Set `manual_read: false` to restore automatic reading. A new visit to a Window or
Topic clears Unread. Mark Unread stays set while you continue to view the same
Window or empty Topic, until the next visit. Updates in the Window being viewed do not become
Unread.

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

As in lazygit, space in Changes stages the file or folder, or unstages it once
all of it is staged, and a stages or unstages everything; a click on a file's
letters does the same. d asks, as lazygit does, whether to discard all of a
file's or folder's changes, back to the last commit, or only the unstaged ones,
keeping what's staged. New and untracked files are deleted; it can't be undone.

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
cherry-pick, revert or `git am`, c says to continue it in the terminal instead.
Hooks and signing run as they do in a terminal; when one fails, the box shows
what it said.

Diffs have line numbers, syntax highlighting, and the enclosing function in each
hunk's header. The toolbar switches them between Unified and Split (side by
side); the choice is remembered. A change's hunk headers show the whole file.
Long lines wrap at the pane's edge. Drag over code to select words or any
part of it, double-click a word, triple-click or drag the line numbers for whole
lines, or use the keys; ⌘C or y copies the code. The filter field (/) narrows
the list shown.

```yaml
git_view:
  display: popup      # or fullscreen
  width: 80%
  height: 80%
```

These are the defaults. `popup` floats over the whole App Window, Sidebar and
Browser too, like `tmux display-popup -w 80% -h 80%`; `width` and `height` are
its share of the App Window, from 10% to 100% (`80` means `80%`). `fullscreen`
takes the terminal's place, leaving the Sidebar and Browser. Changes apply live; invalid
values use the defaults and appear in the Config problems banner.

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
name, or a Settled Topic's outcome, and the matched letters are marked. With
nothing typed, Topics and Sessions put the current live row last among live rows,
before entries with nothing running. Other live rows are most recently visited first.
Typed queries use fuzzy match quality, without pushing the current row down.
On an equal match, live entries come before unopened ones, then the more recently
visited or active one.
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

### Card titles

A long Topic or Session card title wraps onto as many lines as it needs, so it always shows whole.
`sidebar.titles.wrap: false` keeps each card title on one line and cuts a long one with `…` at the card's edge.
It defaults to `true`. The cut follows the Sidebar's width, which a Format's `#{=N:…}` cannot see.

```yaml
sidebar:
  titles:
    wrap: false
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
The built-in right part shows a Tab badge only when Tabs exist. It shows a Pane badge for every Window in Topics mode, and for multiple Panes in Sessions mode.

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
| Window | Its Session variables, plus `window_index`, `window_name`, `window_title`, `window_panes`, `pane_current_command`, `pane_current_path`, `tab_count`, `agent_kind`, `agent_status` | P |
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
