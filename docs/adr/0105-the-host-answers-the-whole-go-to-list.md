# The Host answers the whole Go to… list

The phone built its Go to list from two sources. It ranked the running Sessions itself, with a matcher and a record of recent Sessions of its own. It read only the Session Paths from the Host, through `session_paths` ([ADR 0092](0092-the-visit-log-lives-in-the-state-database-and-the-host-cli-ranks-session-paths-as-go-to-does.md), [ADR 0093](0093-a-host-server-request-with-a-request-id-may-be-sent-again.md)). So one state gave two lists. The Mac ranks Sessions and Session Paths together, hides a Session Path whose launch name has a running Session, puts the current Session last when the query is empty, ranks a Session by its Last visit, applies the `show` of the Go to… palette, and lists Topics, Settled Topics, Tags and Dormant Board Sessions. The phone did none of these.

We decide that **MuxifyCore builds the rows of Go to…'s topics and sessions Sources, and the Host answers the Mac's whole ranked list**.

- **One builder, `GoToInput`.** It takes the Board, the Topic records, the Windows, the Session Paths, the Agent marks, the Tags, the visits and the place where the user is. It makes the sections that the app made before: the open Topics with the Dormant Board Sessions, the Tags for a query, the Settled Topics, and the running Sessions with the Session Paths. The app's Command Palette calls it for these two Sources and keeps the windows, agents and commands Sources, which only an App Window has.
- **A row's payload is a `GoToTarget`.** It is a Topic with its state, a Settled Topic, a Dormant Board Session, a running Session, a Session Path with its launch name, or a Tag. The app maps a target to its own row item, and adds what only an App Window knows: the Window that it showed last in a Topic. A client of the Host acts on a row from the target alone.
- **The place where the user is has three forms.** The app gives the Window that it shows, or the page of a Topic with no live Session. A client with no App Window gives the name of the Session that it shows. The Topic of that Session is the Active Topic.
- **`go_to` is a Host Server request.** `{ "go_to": { "query": "…", "current_session": "…", "tag": "…" } }` answers `sections`, each with an `id`, a `title` and `rows`. A row has an `id`, its Row kind as `kind`, a `title` and a `detail` with the marks of the query, the `tags` of its Topic, the `trailing` text, the `mark` of its card, and its `target`. The Host reads its own Config, records, tmux server, discovery cache and visits. It ranks with the `sources`, `show`, `tiebreak` and `order` of the palette named `Go to…`. Every key of the request is optional.
- **`tag` is the filter of a Tag row.** A Tag is not a place. In the app, a pick of a Tag row lists the Topics of the Tag. A client sends the Tag's name as `tag` to get that list.
- **`visit_session` records a look at a Session.** `{ "visit_session": { "session": "<name>" } }` stamps the Session, its Topic and the Session Path or Worktree that holds its start folder. `VisitKey.keys` gives these keys to the app and to the Host, so a Session that the phone shows ranks as one that the app showed. A name that no running Session has fails.
- **One capability, `go-to`, covers both requests** ([ADR 0086](0086-the-mac-app-and-the-host-server-agree-on-a-protocol-and-capabilities-never-on-a-build.md)'s change rule). The server answers `unsupported` to a client that did not declare it. The Mac does not declare it, because it builds its own list.
- **The Host CLI has both.** `muxify go-to [--query <text>] [--current-session <name>] [--tag <tag>] [--json]` prints the list. `muxify go-to visit <session>` records the visit, takes `--request`, and may run again. The `capabilities` of `environment show --json` get `go-to`. They are reads and a visit with no palette Action, so they have no mirror ([ADR 0039](0039-the-cli-can-do-what-the-command-palette-can-do.md)).

This amends ADR 0092 and ADR 0093. `session_paths` with a `query` and `visit_session_path` stay as they are, for a phone that does not use `go-to` yet. A phone that uses `go_to` needs neither for its Go to list.

## Consequences

- The Host lists only the topics and sessions Sources. A Go to… palette whose Config also turns on windows, agents or commands shows those rows on the Mac only.
- The Host ranks with the palette's Config, not with the Source buttons that an App Window has switched on or off.
- The detail of a Settled Topic's row holds its date in the words of the Host's locale.
- A row's Tag chips have no colour. A client reads the colours from the `tags` of the snapshot.
- The phone still ranks its own list until it moves to `go_to`.

## Considered Options

- **Send the phone the visits and let it rank.** Rejected: the phone would keep a second matcher and a second copy of the section rules, which is the drift that ADR 0092 rejected for Session Paths.
- **Add the Sessions to `session_paths`.** Rejected: its answer is a flat list of folders with no Topics, and its `kind` and `name` keys describe a folder.
- **Stamp only the Session's key for a visit.** Rejected: the app stamps three keys for one look, and the Topic and the Session Path would rank differently after a look from the phone.
