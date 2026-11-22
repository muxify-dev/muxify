# The Terminal has a default theme under the Ghostty config

A user without a Ghostty config got Ghostty's built-in colours: one dark theme, whatever the macOS appearance. To get a theme that follows the appearance they had to write a Ghostty config file with `theme = light:…,dark:…` and name it in `ghostty.config_file`. We decide that the Terminal has a default theme pair, `iTerm2 Solarized Light` for light appearance and `Dracula` for dark, and that the Config can set the theme itself with `ghostty.theme`.

- **The default goes under the Ghostty config.** Muxify loads a `theme` line before Ghostty's default files, so a theme that the user's own Ghostty config sets wins over it, and a Ghostty user sees the same Terminal in Muxify as before.
- **`ghostty.theme` goes over it.** Muxify loads the Config's theme after the Ghostty config files, `ghostty.config_file` and the files they include, so it wins over all of them. It is one theme name, or a mapping with `light`, `dark` or both. A side that the mapping leaves out keeps the default's, so the Settings window can change one side alone.
- **libghostty reads settings only from files**, so Muxify writes the `theme` line to a file in the temporary directory, loads it and removes it. libghostty keeps the lines it read and replays them when it loads the theme at `finalize`.
- **Muxify does not check the name.** A name is a bundled theme, a file in `~/.config/ghostty/themes` or a path, and only libghostty knows where it looks. A name that it cannot find leaves Ghostty's built-in colours, and its message goes to Diagnostics.

## Considered Options

- **The default over the Ghostty config.** Rejected: a Ghostty user's own theme would change when they start Muxify.
- **A bundled Ghostty config file that sets the default.** Rejected: it would stand in for `ghostty.config_file`, or need a second file setting, for one line.
- **Choose the theme from the Ghostty config's colours after `finalize`.** Rejected: libghostty does not say whether a config set `theme`, only which colours resulted.

## Consequences

- A Ghostty config that sets `background` or `palette` but no `theme` now gets them over the default theme's other colours, as Ghostty puts a config's colours over its theme.
- The verify suite `terminal_theme` reads the Terminal's background through its Colour Report.
