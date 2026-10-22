# Muxify

A native macOS app for coding agents in tmux, locally or over SSH. Track Claude
Code, Codex, OpenCode and Pi in a sidebar and give each Window its own Browser.

## Download the beta

Download the Apple-silicon ZIP from [GitHub Releases](https://github.com/ykaratkou/muxify/releases),
unzip it, and move `Muxify.app` into `/Applications`.

Requires **macOS 14+** and `tmux` for Local (`brew install tmux`). Ghostty is
bundled; Xcode is not needed to run the desktop app.

Betas are **ad-hoc signed, not notarized**. If macOS blocks a download you trust,
use **System Settings → Privacy & Security → Open Anyway**. Do not disable
Gatekeeper globally. [Verify the download](docs/development.md#verify-a-download).

## Setup

From the **Muxify** menu:

- **Install Command Line Tool** adds `muxify` to `~/.local/bin`.
- **Install Extensions** enables Agent statuses. Restart running Agents;
  see [Agent setup](extensions/README.md#install) for dependencies and Codex requirements.

From a tmux Pane:

```sh
muxify browser open localhost:3000
muxify session open "debug"
```

⌘B toggles the Browser; ⌘G shows the current Window's repository in the
[Git View](docs/configuration.md#git-view); ⌘N opens another Local App Window.

## Session Paths and Worktrees

A Session groups tmux Windows, usually for one Session Path or Worktree. Open
**Go to…** (⇧⌘P by default) to go to a Topic, switch Sessions or start one in a Session Path.

Configure [`sessions.paths`](docs/configuration.md#session-paths) with the folders
that hold your repositories. A repository is one Session Path, and Muxify asks Git
for its Worktrees, wherever they live. A Session Path launches its exact name (or
reuses that name wherever it runs); Worktree launch names use `repo/worktree-folder`.
Every running Session has its own palette row. Topics group arbitrary Sessions,
including several in the same folder. ⌘↩ creates another with `+2`, `+3`, etc.

## Build from source

Requires Apple silicon, macOS 14+, Xcode 26+, Homebrew and `tmux`.

```sh
make run       # build and open
make test      # run tests
make install   # install a Release build into /Applications
```

## Documentation

- [Configuration](docs/configuration.md) — Remote Environments, Browser and header height
- [Keybindings](docs/keybindings.md)
- [Development](docs/development.md) — internals, Ghostty setup and beta releases
- [Testing](docs/testing.md)
- [Vocabulary](CONTEXT.md) and [design decisions](docs/adr)
