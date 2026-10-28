# Extensions

An Extension is the small piece installed into a coding Agent's own hook or
plugin system that tells Muxify which Agent runs in a Pane and what it is
doing. There is one folder per Agent:

| Folder      | Agent       | Extension                                   |
| ----------- | ----------- | ------------------------------------------- |
| `claude/`   | Claude Code | `muxify-status.sh`, a hook script           |
| `codex/`    | Codex CLI   | `muxify-status.sh`, a hook script           |
| `opencode/` | OpenCode 2  | `muxify-status/`, a TUI plugin directory    |
| `pi/`       | Pi          | `muxify-status.ts`, an extension file       |

`skills/muxify-browser/` is not an Extension. It is a skill that tells an Agent
to drive Muxify's Browser with `muxify browser` commands when `muxify browser
available` exits 0. The installer puts it in the skills folder of Claude Code
and of Codex.

## What an Extension does

Claude Code, OpenCode and Pi write three tmux pane options on the Agent's own Pane
([ADR 0004](../docs/adr/0004-agents-report-status-through-pane-options.md)):

| Option                | Values                                  |
| --------------------- | --------------------------------------- |
| `@muxify_agent`       | `claude`, `codex`, `opencode` or `pi`   |
| `@muxify_agent_conversation` | The Agent's conversation id |
| `@muxify_agent_status`| `working`, `blocked`, `done` or `failed`; unset = no Status yet |

- Every write targets the Agent's own Pane: `tmux set -p -t "$TMUX_PANE" …`.
- Status reporting also names the Agent and its conversation, so an Extension
  installed during a conversation can report it.
- When the Agent exits normally, all three options are unset (`set -p -u`).
- Outside tmux (`TMUX_PANE` empty) an Extension does nothing, and it never
  fails the Agent's hook: tmux errors are ignored.

Codex writes conversation reports instead. See [Codex](#codex).

Muxify reads these options in its once-a-second tmux poll and lists the Agent in
the sidebar's Agents section. An Agent whose Pane is back at a plain shell is
hidden, which covers options left behind by a crash. Muxify itself sets a fourth
option, `@muxify_agent_unread`, when the Agent reaches done, failed or blocked
while you aren't looking at its Window (see Unread in
[CONTEXT.md](../CONTEXT.md)); Extensions never touch it.

## Install

Choose **Muxify ▸ Install Extensions**. It runs `install.sh` from the copy of
this folder bundled inside the app, which, for every Agent whose config
directory exists under your home directory, installs the Extension (or updates
it if it is already there) and prints one line per Agent, such as
`claude: installed`, `opencode: updated` or `pi: not found` (or
`claude: failed (<reason>)`). After a `codex: installed` or `codex: updated`
line it adds two reminders. Trust the hooks once through `/hooks` in Codex.
Restart existing Codex TUIs to load the conversation title setting.
Running it again changes nothing but the Extension files themselves, so it is
also how you update.

With the existing macOS command line tool installed, the same installer is
available without launching the app:

```sh
muxify extensions install
```

It resolves the command's app-bundle symlink and uses the bundled reporter
files. Run it on the Mac whose Agent configuration you want to update. Remote
installation is manual; selecting a Remote Environment never provisions it,
and the app's Install Extensions action is disabled while a remote is selected.
No Linux CLI package is provided. The existing `install.sh` and its adjacent
reporter folders can still be used directly on a remote host from a copy of
this folder. Reporters talk to tmux, not to the Muxify CLI or GUI.

For Claude Code (detected by `~/.claude`), the installer:

- copies `claude/muxify-status.sh` to `~/.claude/hooks/muxify-status.sh`
  (a copy, not a symlink);
- adds one hook entry per event below to `~/.claude/settings.json`, each
  running `sh "$HOME/.claude/hooks/muxify-status.sh"` synchronously (so events
  stay in order) with a 5 second timeout. The `PreToolUse` entry has the
  matcher `AskUserQuestion|ExitPlanMode`;
- copies `settings.json` to `settings.json.bak` before changing it, adds an
  entry only when that event has no hook with the identical command yet, never
  touches or reorders other entries (Raycast, herdr, lavish …) or other keys,
  and leaves both files alone when nothing is missing;
- needs `jq`; without it, it prints `claude: failed (jq not found)` and changes
  nothing;
- replaces `~/.claude/skills/muxify-browser/` with a copy of
  `skills/muxify-browser/`.

For Codex, the installer uses `$CODEX_HOME` when set, else `~/.codex`:

- requires `jq`, `python3` and `codex` on PATH;
- uses Codex's config editor to put `thread-id` first in `tui.terminal_title`,
  while it preserves the other title items and unrelated settings. When the
  setting is absent, it preserves Codex's default title items. An empty list
  becomes `["thread-id"]`. A changed config gets a `config.toml.bak` backup;
- copies `codex/muxify-status.sh` to the Codex home as `muxify-status.sh`.
  An existing symlink is replaced;
- adds one hook entry per event in the [Codex](#codex) table to
  `~/.codex/hooks.json` (creating it if missing), each
  `{"hooks": [{"type": "command", "command": "sh \"$HOME/.codex/muxify-status.sh\"", "timeout": 5}]}`:
  no matcher, so it runs for every tool, and synchronous. Codex runs hook
  commands through your login shell (fish here), so the command is a plain
  line that fish, zsh and bash all read the same way;
- follows the same rules as for Claude Code: `hooks.json.bak` before changing
  it, an entry only when that event has no hook with the identical command yet,
  other entries and keys left alone, and nothing written when nothing is missing;
- replaces `skills/muxify-browser/` in the Codex home with a copy of
  `skills/muxify-browser/`.

For OpenCode 2 (detected by `~/.config/opencode`), the installer replaces
`~/.config/opencode/plugins/muxify-status/` with a copy of
`opencode/muxify-status/`. OpenCode discovers the plugin there by itself, so no
config file is edited. Restart running OpenCode TUIs to load it.

For Pi (detected by `~/.pi/agent`), the installer copies `pi/muxify-status.ts`
to `~/.pi/agent/extensions/muxify-status.ts` (creating `extensions/` if needed;
a copy, not a symlink, and a symlink already there is replaced). Pi loads every
`.ts` file in that folder by itself, so no config file is edited. Restart
running Pi sessions (or run `/reload` in them) to load it.

To try the installer without touching your real setup, point it at a scratch
home: `HOME=$(mktemp -d) sh extensions/install.sh`.

## Claude Code

`claude/muxify-status.sh` is a POSIX `sh` script that handles every hook event.
Claude Code passes the event as JSON on stdin; the script reads
`hook_event_name` with `jq`, ignores payloads carrying an `agent_id` (they come
from subagents, so only the main conversation drives the Status), prints
nothing and always exits 0.

| Hook event                                        | Status                          |
| ------------------------------------------------- | ------------------------------- |
| `SessionStart`                                    | sets the Agent and conversation id       |
| `UserPromptSubmit`, `PostToolUse`, `ElicitationResult` | working                    |
| `PermissionRequest`, `Elicitation`                | blocked                         |
| `PreToolUse` (`AskUserQuestion`, `ExitPlanMode`)  | blocked                         |
| `Stop`                                            | done                            |
| `StopFailure`                                     | failed                          |
| `SessionEnd`                                      | unsets all three options             |
| anything else                                     | nothing                         |

Known gap: Claude Code fires no hook when you press Esc to interrupt a turn or
deny a permission prompt, so the Status keeps its last value (working or
blocked) until the next event, such as your next prompt.

## Codex

Codex works in its default shared-daemon mode. Its Extension records Status by
conversation ID. The Codex TUI puts that ID in its own terminal title. Muxify
joins the two during its normal poll, so a daemon's inherited `TMUX_PANE`
cannot send Status to the wrong Pane.

The installer adds `thread-id` to Codex's title settings. Muxify hides the ID
from its normal Sidebar labels. Restart existing Codex TUIs after installation
to load this setting. Run `/hooks` in Codex and trust the Muxify entries.
A project or profile that overrides `tui.terminal_title` must also include
`thread-id`.

`codex/muxify-status.sh` receives JSON on stdin. It ignores subagent events and
invalid conversation IDs. It writes one small JSON report, by atomic rename,
to `$HOME/.local/state/muxify/codex/<conversation-id>.json`. This fixed location
is independent of `CODEX_HOME` and `XDG_STATE_HOME`, which can differ between
the daemon and the app. Reports contain only a version, conversation ID and
Status. The Extension needs no tmux environment and writes no tmux options.

| Hook event | Status |
| --- | --- |
| `SessionStart`, `SessionEnd` | no Status |
| `UserPromptSubmit`, `PostToolUse` | working |
| `PreToolUse`, tool `request_user_input` | blocked |
| `PreToolUse`, any other tool | working |
| `PermissionRequest` | blocked |
| `Stop`, `Interrupt` | done |

Muxify detects a foreground `codex` command even before its first report.
A report supplies Status and the full conversation ID only when it matches the
Pane title without ambiguity. Codex 0.162.1 truncates the title ID, so Muxify
accepts a prefix only when it matches one report. Two Panes can show the same
conversation. A shell or another program does not become an Agent from a stale
title. Old Codex pane options do not override these reports and are ignored after
Codex exits. Other Agents continue to use their pane options.

The app and CLI read reports on the Environment's machine through the selected
tmux server. Normal polls read only reports for current title prefixes. Reports
remain after `SessionEnd` with no Status, because another TUI can still show the
same conversation. The foreground command determines whether an Agent runs.

Known gaps:

- Codex has no turn-failure hook, so it cannot report failed Status.
- After approval, Status changes from blocked to working at `PostToolUse`.
- Before a matching report arrives, the Agent has no Status or full conversation ID.
- Identity matching depends on Codex's terminal title format. This is verified
  against Codex 0.162.1. A changed format requires a matching parser update.

## OpenCode 2

`opencode/muxify-status/tui.js` is an OpenCode 2 TUI plugin (an ES module
exporting `{ id: "muxify.agent-status", setup(api) }`). Each OpenCode TUI loads
its own copy, so it reports on the Pane that TUI runs in. It listens to every
event with `api.data.listen` and writes synchronously, so the writes follow
event order.

All TUIs share one OpenCode server and see the events of every session on it,
so the plugin counts only events from the session open in its own TUI
(`api.ui.router.current()`) and that session's subagents: an event counts when
walking `parentID` up from its session reaches the same root session as the
open one. Events from other sessions, or while no session is open, write
nothing.

| Event                                                   | Status                          |
| ------------------------------------------------------- | ------------------------------- |
| plugin setup (TUI start)                                | sets the Agent and conversation id       |
| `session.execution.started` (root session)              | working                         |
| `session.execution.succeeded` (root session)            | done                            |
| `session.execution.interrupted` (root session, e.g. Esc) | done                            |
| `session.execution.failed` (root session)               | failed                          |
| `permission.asked`, `form.created` (any session in the tree) | blocked until answered     |
| `permission.replied`, `form.replied`, `form.cancelled`  | back to the last execution Status |
| cleanup (plugin unloaded) or process exit               | unsets all three options             |

While any permission or form in the tree is pending the Status is blocked;
once none is, it is the root session's last execution Status (unset if no
execution has been seen yet). Subagent sessions' own executions are ignored. A
Status is written only when it changes.

Known gap: the plugin reads which session is open only when an event arrives,
so after you switch to another session inside one TUI the Status still shows
the previous session's until the new session's next event (for example its
next execution starting). Requests that were pending in the previous session
are forgotten on the switch.

## Pi

`pi/muxify-status.ts` is a Pi extension (Pi 0.85, `@earendil-works/pi-coding-agent`):
a single TypeScript file whose default export is `function (pi)`, registering
its handlers with `pi.on`. It reports only when `ctx.mode` is `"tui"`: Pi
processes started in `json`, `print` or `rpc` mode (subagents, scripts) inherit
the Pane's `TMUX_PANE` and stay silent. It writes synchronously, so the writes
follow event order. It uses only TypeScript that Node can run by stripping
types (no enums, namespaces or parameter properties), so plain Node 24 can load
it too.

| Pi event                                   | Status                                    |
| ------------------------------------------ | ----------------------------------------- |
| `session_start`                            | sets the Agent and conversation id                 |
| `agent_start`                              | working                                   |
| `ui_prompt_start` (a dialog opens)         | blocked                                   |
| `ui_prompt_end` (the dialog closes)        | back to the run's Status (unset if no run yet) |
| `agent_end`                                | remembers the last assistant message's `stopReason` |
| `agent_settled`, when `ctx.isIdle()`       | failed if that `stopReason` is `error`, otherwise done (Esc, `aborted`, counts as done) |
| `session_shutdown` with reason `quit`      | unsets all three options                       |
| anything else                              | nothing                                   |

`agent_start` can fire more than once for one prompt (retries, compaction,
queued messages); the run ends only at `agent_settled`, which Pi fires once when
nothing more will run. A `session_shutdown` for `reload`, `new`, `resume` or
`fork` writes nothing, since Pi keeps running and the reloaded extension names
the Agent again. A Status is written only when it changes.

Blocked only appears while a dialog is open: `ui_prompt_start` and
`ui_prompt_end` (Pi ≥ 0.84.4) wrap every `select`, `confirm`, `input`, `editor`
or custom dialog that any extension opens. Pi has no permission prompts of its
own, so a run without such a dialog goes straight from working to done or
failed.

Known gap: a `/new`, `/resume` or `/fork` session keeps the previous session's
last Status until its first run starts.
