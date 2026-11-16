# The visit log lives in the state database, and the Host CLI ranks Session Paths as Go to… does

The Mac app kept every Last visit in one UserDefaults key of the app, and the code that ranks Go to… was in the app only. The phone starts a Topic from a Session Path through the Host CLI, which could read neither. So the phone could not order its list as the Mac does, and a Session that the phone opened did not count on the Mac. We decide that **the Last visits of a machine are rows in that machine's `muxify.db`, and the Mac app and the Host CLI rank Session Paths with one ranker in MuxifyCore**.

- **One table, `visits`.** A row is one place (`topic:<id>`, `topic:-`, `session:<name>` or `path:<real path>`) and the time of its Last visit. A write changes a row only when its time is newer, so two writers do not undo each other. Each write keeps the 2000 newest rows of a machine.
- **The app reads the table again when a Command Palette opens.** It adds the rows that are newer than its own. A visit from the phone then ranks the next list. The app saves each visit as it records it, off the main thread.
- **The old UserDefaults key moves one time.** At launch, the app writes the key's visits into the table as this Mac's and removes the key. A visit that the Host CLI saved before that launch keeps its newer time.
- **`environment` keeps a Remote App Window's visits apart.** It is NULL for a visit to this machine's own Topics, Sessions and Session Paths. A Remote App Window on the Mac writes the name of its Remote Environment. Before, the two mixed in one key, so a Session name or a path that both machines have got the wrong time.
- **One ranker.** The fuzzy match, the pick list and the row of a Session Path or Worktree in Go to… are in MuxifyCore. `muxify session-paths [--query <text>]` makes the same rows from the same function and ranks them with the `tiebreak` of the Go to… palette, so the same folders, query and visits give the same order on the Mac and on the phone. It reads no `show`: a caller that asks for Session Paths gets them.
- **`session-paths` needs no Topic.** It answers from the Session Path discovery cache and then starts `muxify session-paths refresh` in a session of its own, with no pipe of the caller. An `ssh host muxify session-paths` ends when the answer is out, and the next answer has the new folders. Only one refresh runs for a cache file at a time. With no cache, the command finds the folders, saves them and then answers.
- **`session-paths visit <dir>` is a Request.** The phone sends it when it opens a Session in a folder. It records a visit to the Session Path or Worktree that holds the folder, as a look at the Session in the app does, else to the folder itself. It takes `--request`, and a second send records nothing. It changes no Topic record and nothing in tmux, so it is not an `EnvironmentRequest`.
- **`capabilities` gets `session-paths`.** A caller reads the list in `environment show --json` before it uses the two verbs.

## Consequences

- A Remote App Window's visits stay on the Mac, under the name of its Remote Environment. They do not go to the Host, so the Host's phone and the Mac's Remote App Window do not share them yet. The target is that a visit belongs to the machine that has the Session. `EnvironmentService.rankedSessionPaths` and `recordVisit` are the two functions that a Host Server request would call, and the Remote App Window would then read the Host's visits through a subscription.
- An older Muxify that runs after a newer one finds no `visits` key in UserDefaults and starts with no visits. It does not read the table.

## Considered Options

- **Keep UserDefaults and let the Host CLI read the app's preferences file.** Rejected: a Host has no app and no such file, and two processes that write one property list lose each other's writes.
- **A second ranker in the Host CLI.** Rejected: its order would drift from Go to… with each change to the match or the tiebreak rules.
- **Refresh the cache before the answer.** Rejected: one `git worktree list` in a large repository would hold each key press of the phone's Go to field.
- **Make the visit an `EnvironmentRequest`.** Rejected: every request there has a lane, a mirror and a place on the Host Server's wire, and a visit changes none of what those guard.
