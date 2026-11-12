# The Settings window edits the Config file

Settings lists every setting of the local Config and saves changes into `config.yaml`. It reads its list from `Config.template`. The template without its `#` is YAML, and each key there is a setting. The comment above a key is its help. Its value is the default when it loads into the same Config as an empty file. Otherwise the value is an example, and the field shows it as a placeholder. A mapping whose keys the reader rejects as unknown is a group of settings. Any other mapping or list is one setting, edited as YAML text. A key whose wrong value gets the problem `expected a, b or c`, all single words, takes a value from that fixed list in a pop-up menu. A list or a mapping shows as controls: items with Add Item and remove, a mapping's keys with an Add Field menu, and a list of words as removable words with an add menu. The same probes give their shape: the keys of the template's items and its commented keys, as `# port: 22`, the words the reader expects, and whether a mapping takes keys of the user's own, as Tag names. A YAML switch shows the text instead, and text that is not YAML shows only as text. A key trigger has a Record button, which writes the next key pressed, as `shift+cmd+t`. A new setting in the template shows in the window with no other change, and a test keeps the uncommented template loading with no problems.

Save rewrites only the lines of the keys that changed. A new key goes under its section, and a missing section goes at the end. Reset removes the key and any section it leaves empty. The user's comments, order and indentation stay. The window checks each change with `Config.load` and shows a problem under its row. Save writes the file, and the Config reloads as after any other edit. The window checks a typed change after a short pause, off the main thread, and Save checks the draft again first. Settings edits only the local Config. A Remote Environment's Config still opens in that machine's editor.

The keybind `open_settings` (`cmd+comma`) opens it. It is a Muxify keybind, so it acts before the Terminal, where Ghostty's own `cmd+,` would otherwise take the key.

This supersedes "The UI never writes or overrides a setting" and the rejected option "The UI edits the file" in [ADR 0005](0005-muxify-config-is-a-yaml-file.md). That option was rejected because chezmoi undoes a UI write. The file stays the one source, and Open Config still opens it for edits by hand.

## Considered Options

- **A Swift schema of the settings, which also writes the template.** Rejected: it duplicates what `ConfigReader` knows, or means rewriting the reader around it. The template must already list every setting.
- **Write the file from the loaded Config.** Rejected: Yams drops comments and order.
- **Apply each change at once.** Rejected: a half-typed value writes the file.
- **A `# one of:` line in the template for each key with a fixed list.** Rejected: the reader already names the values in its problem, and a second list could disagree with it.
