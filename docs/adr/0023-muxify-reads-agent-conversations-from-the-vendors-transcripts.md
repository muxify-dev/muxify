# Muxify reads Agent conversations from the vendors' own Transcripts

A Chief of Staff Agent must read what the other Agents of a Topic said and did, from the command line. `muxify agent conversation` reads the Transcript that each Agent's CLI writes (Claude Code, Codex and Pi JSONL files, and `opencode export` for OpenCode). It changes each vendor format into one list of Entries, and gives the caller filters and windows over them. We decided this because only Muxify knows which conversation runs in which Pane and in which Topic. The vendor formats are not a public contract. Muxify owns this coupling in one decoder for each vendor in MuxifyCore, which the app and the CLI share.

## Considered Options

- **Capture the Pane screen.** Rejected: it loses the roles and the turns, contains TUI boxes and wrapped lines, has no scrollback for a TUI on the alternate screen, and gives nothing after the Pane closes.
- **Give only the Transcript path.** Rejected: every caller then parses four formats again, and OpenCode has no file.
- **Extensions write a digest at each turn end.** Rejected for now: it has only the last turn, and conversations from before the change have none.
- **Ask the Agent, or a fork of its conversation.** Rejected: a prompt in the live Pane interrupts work, and a fork costs a model call for each Agent.

## Consequences

- An Entry is one message, tool call or tool result. Its index is its position in the conversation. It does not change while the vendor only adds to the Transcript, and filters do not change it. A saved index belongs to one conversation, so the output names the conversation.
- A vendor update can change its format. A decoder skips records that it does not know. A Transcript that is not empty but gives no Entries is an error, not an empty result.
- Remote Environments are out of scope until the Muxify server exists, because the Transcript is on the other machine.
