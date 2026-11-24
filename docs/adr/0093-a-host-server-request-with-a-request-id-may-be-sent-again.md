# A Host Server serves the phone: Request ids on the channel, and the computed view it draws

The phone (muxify-mobile) moves onto the Host Server, so that it reaches a Host as the Mac does and keeps as little Host logic as it can. Protocol 1 lacked four things that the phone used through the Host CLI's execs. Those were a write that applies one time when sent again, the computed `environment show` snapshot with `sidebar`, the ranked Go to with its visit record, and a Window's Browser Tabs. We decide that the Host Server adds them as capabilities of protocol 1, under the change rule of ADR 0086. The phone then has no other way to reach a Host's Topics.

- **`request`: a Request id on `environment` requests.** An `environment` request may carry an optional `request` (a UUID). The server applies it with the same Request ledger as `muxify --request` (ADR 0083): a second request with the same id, command and arguments gets the first answer and changes nothing; the same id with other arguments is refused; a Request that changed records and did not finish ends with its in-doubt failure. A request with an id may therefore be sent again after the channel ends, on a new Host Server. This amends the rule of ADRs 0085 and 0088 that a mutation is never sent again: that rule stays for every request without an id. The Mac sends none yet and may adopt it later.
- **`snapshot`: a subscription of the computed view.** `subscribe { snapshot }` pushes the whole `EnvironmentSnapshot`, with the Config's `sidebar`, as one keyed event whenever it changes. Its first item is the current one. The server's publisher already computes the snapshot on each trigger, so the event costs no extra read.
- **`topic-detail`: a subscription of one Topic.** `subscribe { topic: { id } }` pushes the Topic's detail, as `topic show` answers it, whenever it changes, and null when the Topic is gone.
- **`ranked-session-paths`.** `session_paths` also takes `query`, and with it, or with neither `roots` nor `query`, answers the rows of `muxify session-paths [--query]`, ranked by the shared `PickList` and the visit record. With `topic`, it answers that Topic's Add a Session rows, as `muxify topic session-paths --topic <id> --json` does. `visit_session_path { folder }` records a visit as `muxify session-paths visit` does.
- **`browser-tabs`.** `browser_tabs { window }` answers what `muxify browser tabs --window <id> --json` prints.

Each capability is declared in the server's `hello`, pinned by fixtures, and never sent to a peer that did not declare it. The phone declares them all.

[ADR 0105](0105-the-host-answers-the-whole-go-to-list.md) adds the `go-to` capability: `go_to` answers the Mac's whole Go to… list, and `visit_session` records a look at a Session. The phone's Go to list then needs no `ranked-session-paths` request.

ADR 0087 rejected a computed view built on the Host, because the Mac would need a second set of view code fed by it. That reason does not hold for the phone, whose only view code draws the computed snapshot it already reads today. The Mac keeps the raw `environment` subscription.

## Considered Options

- **The phone ports the card and In Play rules to TypeScript** and draws from the raw `environment` events. Rejected: two implementations of the card rules, in two languages.
- **The phone reads `environment_show` again on each `environment` event.** Rejected: the phone would still decide when to read, and each event would cost a round trip.
- **No Request id; a write cut off by a drop stays unknown.** Rejected: the phone already resends safely with `--request` (its ADR 0021), and losing that on cellular is a regression.
