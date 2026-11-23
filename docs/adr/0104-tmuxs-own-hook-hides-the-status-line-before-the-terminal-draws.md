# tmux's own hook hides the status line before the Terminal draws

[ADR-0099](0099-the-header-hides-tmuxs-status-line-where-the-terminal-is.md) let the publisher hide tmux's status line after the Terminal moved, and let a tmux hook give it back to other terminals. Users still saw the status line for a moment on many switches, and on a Remote Environment on almost every switch. Measured on throwaway servers, by recording every byte the Terminal's Client wrote while it switched (tmux 3.8 on the Mac, tmux 3.2a on Ubuntu 22.04):

- A switch made inside tmux, a new Session, or a Session that another terminal had visited drew the status line once: the publisher's `status off` reached tmux after tmux drew the Client.
- Before tmux 3.8 a hook cannot read a Client's environment, so the hook took the Terminal for another terminal and gave the status line back at each of its moves, also at a switch that Muxify started with the status line already off. The publisher hid it again a moment later. That is every switch on a Remote Environment's host with an older tmux.

We decide that tmux itself hides the status line, in the hook, when a Muxify Terminal arrives in a Session. tmux runs a hook's commands before it draws the Client again, so no frame shows it, however the switch was made, and however slow the connection to Muxify is.

- **The hook tells a Muxify Terminal by its Client's pid.** The global option `@muxify_terminals` lists the pids of Muxify Terminals' Clients, each between spaces. The same entry 77 of `client-attached` and `client-session-changed` turns `status` off and sets `@muxify_status_hidden` when the arriving Client's pid is listed and the status line shows; otherwise it gives a marked Session its status line back to a Client that is not a control Client, as before. Every tmux from 3.2 reads `#{client_pid}` and `#{m:}` in a hook. The hook no longer reads `MUXIFY_TERMINAL`.
- **The Terminal lists itself before it attaches.** While `ui.status_line.enabled` is on, the Terminal's command, on this Mac and on a Remote Environment's host, appends its shell's pid to the list and sets the hooks, then runs `exec tmux attach-session`, so the pid is the Client's. The first frame has no status line either. A Sessions-only App Window does not list its Terminal.
- **The publisher keeps the list.** It lists its own Terminal's pid each time it hides the status line, which covers a Terminal that attached before the setting turned on, and about every 5 seconds removes the pids of processes that ended, with one `set-option -gF` and `#{s/ pid //:…}` each, so a Terminal that lists itself meanwhile stays. Turning the setting off also unsets the list.
- **The publisher still hides the status line before a switch that Muxify starts and after each move.** The hook then finds it off and changes nothing, so the Window is not resized twice.

## Considered Options

- **A Session of Muxify's own in each Session's group.** Grouped Sessions share Windows but have their own options, so a Muxify Session could keep `status off` while iTerm's keeps the status line. Rejected: each Session the Terminal shows would need a second Session, which every Session list, the Sidebar and the user's other terminals would show.
- **Clip the status line in the Terminal.** The Terminal could ask tmux for one more row and not draw it. Rejected: whether a Session shows the status line, and on how many rows, changes at the switch, so the Terminal would resize at each switch and still guess wrong for a moment.
- **The Client's tty instead of its pid.** Rejected: the tty is reused by the next terminal that opens one; a pid that ended is removed and is rarely reused by another tmux Client.

## Consequences

- One Session still has one `status`: when another terminal and the Terminal show the same Session, the last one to arrive still wins.
- A pid can stay listed after its Terminal ended while no Muxify runs. A later Client of another terminal with the same pid would lose the status line in the Sessions it arrives in, until Muxify starts and removes the pid.
