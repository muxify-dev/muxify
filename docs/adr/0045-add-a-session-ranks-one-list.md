# Add a Session ranks one list

Add a Session ranks running Sessions and Session Paths in one list without a header. A running Session shows ■. A Session Path shows □. The row kind does not decide ties.

The list uses the existing search score, then the shorter title (added 2026-10-25, as fzf's default `--tiebreak=length`), then last visit, tmux activity, and candidate order. Session Paths keep Config order when all earlier values are equal. A strong Session Path match can now precede a weak running Session match. The Sessions Source keeps the order in [ADR 0037](0037-the-sessions-source-lists-sessions-individually.md).

The rows and their actions stay as [ADR 0041](0041-topics-group-sessions-not-repositories.md) defines them. A folder can still have a launch row while a running Session uses it. A running Session in the target Topic has no row. After a running Session moves into the Topic, Add a Session closes.

SessionPathRows resolves each Topic Window folder once when it builds the rows. WorkspaceStore caches these rows until their inputs change. CommandPalette also caches its results. Result snapshots expire after one second because Snooze choices contain absolute deadlines and visit ages change with time.

This change adds no Usage score or preference for shorter names. Discovery and fuzzy matching stay unchanged.
