# Remote Environments use an owned foreground SSH connection

> **Changed by [ADR-0086](0086-the-host-clis-server-lives-on-a-channel-of-the-attachments-ssh-master.md):** "ties connection lifetime to the visible attachment" now covers the Host Server too. It is a channel of the attachment's master and never outlives it.

The terminal's system OpenSSH client owns authentication and a private multiplexing socket; tmux queries and the event stream reuse that connection without independently authenticating. This keeps native host-verification and key-passphrase prompts in the terminal, requires no remote Muxify helper, and ties connection lifetime to the visible attachment rather than a separately backgrounded SSH master. Switching retires the old connection and its callbacks; remote tmux remains the source of truth and mutations with an uncertain outcome are never automatically replayed.

SSH reads the user's normal config so Host aliases, routing and external agents such as 1Password work as they do in `ssh -A`. Agent forwarding is enabled by default and can be disabled per Environment. Muxify still owns the tmux command and control socket, keeps authentication key-only, and does not create TCP tunnels; YAML overrides the username and any explicitly supplied port or identity file.
