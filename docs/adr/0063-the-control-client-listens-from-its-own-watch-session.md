# The control Client listens from its own Watch Session

Muxify's control-mode Client attaches to the Watch Session, `muxify-watch`. Before, it attached to the selected Session, or to the first Session, and stayed there.

tmux answers a Pane's background color query (OSC 11) from the first Client attached to the Pane's Session, and it skips only Clients whose background is unknown. A control Client never gets a terminal, so tmux takes its background as black. The listener starts before the Terminal, so it is the first Client. nvim, Claude Code and Codex ask once at startup, so in a light theme they chose dark colors in the listener's Session and kept them. No Pane of the user's shares a Session with the listener now.

- The listener runs `new-session -A -s muxify-watch -f no-output,ignore-size cat`. The one command attaches when the Session runs and makes it when it does not, so a restart after `kill-session` or `kill-server` makes it again. The Pane runs `cat`, so no shell startup file runs in it.
- tmux sends notifications for every Session to a control Client, so the listener hears the user's Sessions from the Watch Session.
- The snapshot leaves out the Watch Session's Windows and Panes and keeps its Client. The Sidebar, the Command Palette, the CLI and the Unread marks read the snapshot, so none of them shows it.
- The listener starts only while the user has a Session. After the last one closes, Muxify kills the Watch Session, so the tmux server still exits as it did before.
- On a Remote Environment, the bootstrap does not count the Watch Session as a user Session, and it never attaches the Terminal to it.

A rule in the user's tmux config was the alternative. It would have fixed one machine and left every other user with the bug.

A command from outside tmux without `-t` goes to the Client with the newest activity. That can be the listener, so such a command can now act on the Watch Session. Muxify's own commands always name their target.
