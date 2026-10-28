# Agents

Muxify knows each Agent that runs in a Pane: Claude Code, Codex, Pi or OpenCode. It shows each Agent's Status (`working`, `blocked`, `done` or `failed`) and marks it Unread when it has news for the user.

## Start a helper

1. Write the full task to a file, such as `/tmp/<task>.md`. The helper gets its task only from its start command, because its Pane takes input from the user.
2. Start it in a new Window of your Session: `muxify window new -- claude "Read /tmp/<task>.md"`. Use the command of the Agent you want. It prints the new Window's id, such as `@14`.
3. Find its Pane: `tmux list-panes -t @14 -F '#{pane_id}'`.

## Follow other Agents

- `muxify agent list` prints each Agent: its Pane, kind, Status, Unread, Topic and Session. `--topic`, `--status` and `--unread` filter the list.
- `muxify agent conversation <pane>` prints the last 20 user and assistant Entries of that Agent's conversation, each with an index that does not change. Read only new Entries with `--after <index>`, the tool calls with `--tools`, or matches with `--grep <regex>`.
- To wait for a helper, run `muxify agent list --json` until its Status is `done`, `blocked` or `failed`, then read its conversation.

A helper that is `blocked` waits for an answer. Tell the user which Pane needs them.
