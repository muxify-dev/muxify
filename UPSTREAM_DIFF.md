# Differences from upstream

This branch (`gg-topics`) merges upstream Muxify at `20108f1`. This file tells
the upstream maintainer what the branch changes in upstream's designs. It is
not part of the merge.

The branch adds Topics: a Topic is one thing the user wants to get done, and it
groups arbitrary Sessions, including several in one folder. Topics have their own ADRs
(0006 to 0010 on this branch, `docs/topic-records.md`) and are not listed here.
This file is about what changes for upstream's own features.

## Upstream concepts that the branch replaces

### Session Path discovery

- `sessions.paths` keeps its name, and now finds Session Paths (ADR 0011). One list
  of folders serves the Command Palette, Topics and the CLI.
- `SessionPathDiscovery.swift` replaces `SessionPaths.swift`. One shell script finds
  the folders. It runs on this Mac, or over the Remote Environment's SSH master.
- A repository is one Session Path. Its Worktrees are rows of that Session Path, read
  from `git worktree list`. Upstream made each worktree its own Session Path
  and found worktrees only below a `.git` folder. Bare repositories, and a
  `.bare` folder beside a `.git` file, now work.
- Discovery does not list a folder inside a repository that it found.
- A new Session in a Worktree has the name `<repo>/<folder>`. Upstream used
  `repo [wt]`, and put the parent folder in front on a name clash. When a name
  is in use, New Session adds `+2`, `+3` and so on.
- A Session Path matches a running Session by exact name, not by its folder.

### Palette ranking

- `FuzzyMatcher` (a port of fzf's FuzzyMatchV2) and `PickList` replace
  `PaletteSearch`.
- Results stay in one section for each Source while you type. Upstream put all
  Sources in one list when a query was typed.
- Each word matches the best field of a row: its name, a type word (`topic`,
  `session`, `project`, `worktree`, `window` ...) or a detail. The matched
  letters are marked.
- Matching uses smart case. A word with a capital letter matches case. Upstream
  always ignored case.
- On an equal score, a row with a running Session comes before a Session Path with
  no Session, as upstream ranks. Then the last visit (new) breaks the tie,
  then the last activity.

### The Switcher

The branch had its own search, the Switcher, on ⌘⇧P. It is retired. Upstream's
Command Palette takes its place (ADR 0012). A Config that names
`open_switcher` gets a problem.

### Agent marks in the Sidebar

The Sidebar shows Status colours: working is blue and breathes, blocked is
orange, failed is red, done is green. An Unread Agent gets an accent dot.
Upstream's `AgentStatusIndicator` stays in the Command Palette only. The
Sidebar's Session header is replaced by Topic cards.

## Renamed

| Upstream | This branch | Note |
| --- | --- | --- |
| `keybindings.focus_terminal` (⌃`, keyboard to the terminal) | `move_keyboard_to_terminal` (⌃`) | `focus_terminal` now means Focus on the Terminal (⌥⌘T): the Terminal alone, with the Sidebar hidden. |
| `SidebarTypography` in the app | `SidebarTypography` in MuxifyCore | The app keeps the roles. Behavior is the same. |

## Extended

- `sessions.paths` takes upstream's `path` and `depth`, and adds:
  - a glob in `path`
  - a path relative to the Config file's folder
  - `display_depth`, the number of folder levels in the Session Path's name
- `sessions.aliases` gives a Session Path a name to show in the lists and the
  Sidebar. tmux Sessions keep the folder name.
- The palette has a fourth Source, `topics`. It has rows only in a Local App
  Window with Topics on.
- The `sessions` Source has a row for every running Session in both Sidebar modes,
  followed by Session Paths whose exact launch names are not running.
- There are three new palette keys: `new_session` (⌘↩) starts another
  Session in a Session Path or Worktree, even when one runs there, `paste_path` (⌃Y)
  types the row's path at the terminal prompt, and `snooze` (⌃S) snoozes a
  Topic. The chips are now ⌘1–⌘4.
- Move (⌘⇧M) sends a Session to a Topic. It uses the palette's view, and it is
  not a Source.
- There are new global keybindings: `new_topic_from_pane` ⌘⇧T,
  `move_session_to_topic` ⌘⇧M, `add_session_to_topic` ⌘⇧A, `snooze_topic` ⌥⌘S,
  `zen_mode` ⇧⌥⌘S, `toggle_terminal` ⌘J, `toggle_focus` ⇧⌘↩, `focus_terminal`
  ⌥⌘T and `focus_browser` ⌥⌘B.
- There are new Config sections: `topics`, `notifications`, `sidebar` and
  `ui.pulse`.

## Kept as is

- ADR 0009: `command_palettes` with `name`, `keybinding` and `sources`, chips
  you can turn on and off, the collision rules, and
  `keybindings.command_palette`.
- ADR 0010: the remote Config is read over SSH. Its `ghostty` and
  `remote_environments` sections are skipped. Session Paths are found on each
  Environment's machine.
- `depth`: 0 is the folder itself, and 1 to N are the levels below it. Hidden
  folders are skipped.
- `ui.sidebar.font_size` and `ui.sidebar.font_family`, with their checks and
  messages.
- With nothing typed, Windows show only when theirs is the only chip that is
  on. Beside the Agents chip, a Window with an Agent is not shown. Agents that
  need you come first.

## Divergences that upstream users will notice

1. **`focus_terminal` does a different thing, with no warning.** An upstream
   Config that binds `focus_terminal` now binds Focus on the Terminal. If that
   key is ⌃`, `move_keyboard_to_terminal` also loses its default key.
2. **Go to… opens with other chips.** Without `command_palettes`, Go to… opens
   with `topics` and `sessions`. Upstream opened with `agents`, `sessions` and
   `windows`. In a custom palette the chip order changes too, for example ⌘2
   moves from Sessions to Topics.
3. **New default keybindings can take keys from the terminal.** For example
   ⇧⌘↩ is also Ghostty's `toggle_split_zoom`, and ⌘J and ⌘⇧T are now taken.
4. **The empty palette puts the current row first.** Upstream put the current
   Session last, so that ↩ went to the one before it. Section headers always
   show.
5. **The same Agent can have two colours.** A failed Agent is red in the
   Sidebar and orange in the palette. A done Agent is green in the Sidebar and
   blue (Unread) in the palette.
6. **Some new sections ignore a remote Config.** In a Remote App Window,
   `ui.pulse`, `notifications`, `topics` and `sidebar` come from the local
   Config, not from the remote one. ADR 0010 says that only `ghostty` and
   `remote_environments` are skipped. This is a known gap on the branch.

## A fix that upstream also needs

On upstream, a Local App Window whose first read of tmux fails never listens
to tmux events again: `refresh` sets `isConnected = true` only for a Remote
Environment, and events start only when it is true. This branch sets it again
after a good local read (commit `46fbc04`).
