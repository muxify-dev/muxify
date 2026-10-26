# Session Path discovery keeps its last output and runs git in parallel

On a Config with 178 Session Paths in 185 folders, discovery took about 9 s. Each list keeps the Session Paths it found last while discovery runs again, but after a start there was no last list. So for about 9 s after each start, Go to… and Add a Session had no Session Paths. This ADR makes discovery faster and keeps its last result on disk.

## The cache holds the script's output, valid for the same arguments

After each discovery that does not fail, the App Window saves the script's output in `$XDG_STATE_HOME/muxify/session-paths/`. This Mac uses `local.json`. A Remote Environment uses `remote-<name>.json`, with its name percent-encoded. When an App Window has no Session Paths yet, it parses the saved output and shows the result at once. Then discovery runs as before, and its result replaces the saved list.

- The file holds the output, not the parsed Session Paths. Muxify parses it again with the Config's aliases and `display_depth` of now, so an edit of these keys shows at once. The parsed types need no file format.
- The output depends only on the script's arguments: the paths and depths of `sessions.paths`. The file holds them too, and Muxify uses the output only when they are the same as now. Other roots or depths give no cache.
- A missing or unreadable file is no cache. A failed discovery and a Config without `sessions.paths` write nothing. An unchanged output is not written again.
- Several App Windows can write the same file. Each write replaces the whole file in one step, so a reader gets a complete record.

## The script runs git in 8 folders at a time

The script ran git three times in each folder, one folder after the other. The cost is the start of each process, not one slow repository: the slowest folder took 0.18 s. With 8 folders at a time, the git part took 2.6 s in place of 12 s. 16 at a time gave no more. On the same Config, all of discovery went from 8.4 s and 8.9 s to 4.0 s and 3.2 s.

The script stays POSIX `sh`, because it also runs over SSH on Linux Remote Environments. It first lists the folders in order, which is fast. Then it starts 8 workers in the background. Worker k does each folder whose line number modulo 8 is k, and writes that folder's lines to a file of its own. When all workers finish, the script prints the folders' lines in the order of the list. So the output is byte for byte the output of the old script, and the parser, which needs root order, does not change.

## Considered Options

- **Save the parsed Session Paths.** Rejected: they need a file format, and an alias or `display_depth` edit shows only after the next discovery.
- **`xargs -P 8`.** Rejected: `-P` is not in POSIX, so a Remote Environment can have an `xargs` without it. Its jobs also write to one output in the order they finish, so the script must sort the output again.
- **A queue of folders that free workers take.** Not chosen: in POSIX `sh`, workers can share a queue only through a lock, such as `mkdir`. The static split is simpler, and the cost per folder is almost the same in each folder.
- **Look first only in folders that are new since the last list.** Not chosen: the cache shows the last list at once, and a new folder joins when the full discovery finishes, about 3 s later.
