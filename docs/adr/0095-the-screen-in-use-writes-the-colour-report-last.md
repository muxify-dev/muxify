# The screen in use writes the Colour Report last

Claude Code, nvim and Codex choose a light or a dark look from tmux's answer to a background question (OSC 11). tmux 3.8 answers a Pane from, in this order: the Pane's Colour Report, which a control Client writes with `refresh-client -r`; the Window's `window-style`; the Client that shows the Session. A Pane keeps one Colour Report, the last one that any control Client wrote. tmux keeps it while any control Client is attached. Muxify's listener in the Watch Session ([ADR-0063](0063-the-control-client-listens-from-its-own-watch-session.md)) is always attached, so a Colour Report never goes. Muxify Mobile writes its theme's colours when it attaches. After that, a program on the Mac got the phone's look.

We decide that **the screen in use writes the Colour Report last**. Muxify's listener writes the background and foreground of its Ghostty Terminal for every Pane of each Session that one of Muxify's Clients shows. A Client is Muxify's when a Client marker names its pid and tty and it is not a control Client.

The listener writes them:

- **Before each switch that Muxify starts.** It writes the Colour Report for every Pane of the target Session, waits for tmux's `%end` of the last command, and only then runs `switch-client`. tmux sends its colour-scheme notice (`?997`) at the switch, so a program that asks at once gets Muxify's colours. The check is in the runner of the app's local tmux commands, so every `switch-client` that the app runs gets it.
- **After a switch inside tmux**, such as prefix `s`: the next read finds a Session that Muxify's Clients did not show before, and the listener writes its Colour Report. A program that asks before that read can still get the old colours.
- **When an App Window becomes key, and when Ghostty's colours change**: for every Pane of every shown Session.
- **Before Muxify types a command into a Session that it just made**, such as a resume command of Reopen. No Client shows that Session yet, so without a Colour Report or a `window-style`, tmux answers no colour question there, and the program chooses dark. A Sandbox check of Reopen showed it: the Pane of the Session that the Terminal did not show got no answer in 8 seconds.

A read with no change in the shown Sessions writes nothing.

## Considered Options

- **Report after the switch only.** Rejected: tmux sends the notice at the switch, before Muxify's next read, so a program that asks at once gets the old colours.
- **Set `window-style` on the user's Windows.** Rejected: it changes how the Windows draw, and a Colour Report comes before it.
- **Report every new Pane in every hidden Session.** Not now: it covers Panes that other tools make, but it races with the program that starts in the new Pane.

## Consequences

- A Colour Report that changes in a Session that a Client already shows makes tmux send no notice. A program there changes its look only when it asks again. We accept this gap: Muxify does not flip the theme to force a notice.
- Only the Local Environment writes Colour Reports. A Remote Environment needs a Host Server change; it is issue #149.
- Two App Windows each have a listener, so both can write the same Colour Report. This is safe: the Colour Report is the same.
- A switch waits for tmux's answer to the Colour Report, for two seconds at most: one second for the control Client to join the Watch Session, and one second for the answer. When tmux does not answer, the switch runs, and the Diagnostics log has a line.
- A switch that the `muxify` command runs, such as the move of the caller's Terminal before a Remove, gets no Colour Report first. The command has no listener. The next read of the app writes the Colour Report, as after a switch inside tmux.
