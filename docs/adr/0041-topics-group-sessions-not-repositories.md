# Topics group Sessions, not repositories

A Topic can contain several Sessions in the same repository, across its main checkout and other Worktrees or in the same folder. Membership is about Sessions, so repository or folder identity must not limit it; this supersedes the one-Session-per-repository restriction in [ADR 0030](0030-a-repository-is-one-project.md).

Topic-associated Sessions retain the naming shape `<session_name>/<topic-slug>`. Adding an existing Session uses its real name as the base: `debug` becomes `debug/fix-payments`, regardless of its folder. Moving between Topics replaces the Topic suffix instead of stacking suffixes. Duplicate names are disambiguated before the slash with the first available number starting at 2: `debug+2/fix-payments`, `debug+3/fix-payments`; existing Sessions are not renumbered.

Moving a Window or Pane into a Topic chooses the Topic and then its destination Session, with an option to create another Session. Skip the Session picker when there is exactly one suitable destination; repository or folder identity must not silently choose among several Sessions.

Moving a Window or Pane out of a Topic explicitly chooses a No Topic destination Session or creates a new one; it does not infer a destination from the repository. A new destination starts in the source Window or Pane's current directory and uses its Session's base name, adding the destination Topic suffix when applicable and `+x` on collision.

Add a Session offers running Sessions and Session Paths. Picking a running Session moves it into the Topic; picking a Session Path creates a new member there, even when another member already uses that folder. Creating a new Worktree remains explicit opt-in, never a side effect of grouping Sessions.

Removing membership restores the Session's base name, including Keep during Settle or Forget, with the first available `+x` on collision. Reopen preserves remembered names when available, including existing numeric suffixes, and allocates `+x` when occupied; it never adopts an unrelated Session with the same name.

Keep leaves the original Session's identity intact. If Reopen creates a new Session while that original is still running, the recreated Session gets a fresh identity rather than aliasing the original.

A Topic has no Home Project or replacement Home Session. Each remembered Session has its own identity, name, launch directory and restoration details; an empty Topic stays empty instead of creating a fallback Session from a home folder.

Rename Topic changes its slug and the managed suffix of its live and remembered Sessions, preserving their base names. A slug stays reserved while its Topic record exists, including while Settled. Renaming does not rename Git branches or Worktree folders. Rename Session inside a Topic edits the base name, not the suffix. External tmux renames remain authoritative and do not end membership; Muxify does not enforce its naming convention through background renames.

Settle and Forget default every live Session to Keep, regardless of Agent status. Killing a Session requires an explicit choice; keeping it removes membership and restores its base name as described above.

Stopping a Session or closing a Window updates the Topic's saved layout to the state the user left. Reopen must not resurrect individually stopped Sessions or closed Windows by retaining an older layout. The proposed policy of remembering every missing Session until an explicit Remove was rejected.

An observed, confirmed stop of the last individual Session makes the Topic Empty. Losing the tmux server or its connection is different: keep the last successfully saved layout instead of replacing it with an empty one. Settle also deliberately preserves the layout before executing its explicit Kill choices, so the Settled Topic can be Reopened.

Use the simplest conservative boundary: confirmed Muxify Kill actions and removals observed through a complete inventory from the same running server update the saved layout; unavailable or absent servers do not prove closure. Unknown disappearances preserve the last saved layout. Do not add durable server-side instrumentation to distinguish an unobserved external last-Session kill from server loss. Never reconcile old layouts against a different server incarnation or an initial reconnect inventory as if absence proved the user closed them.

The beta does not retain legacy terminology as compatibility aliases. `scripts/migrate-topic-sessions.sh` converts local Topic records instead of a legacy reader in the app. It supports dry-run and backups, reads tmux inventory without changing live Sessions to recover running members' names, and explicitly reports folder-derived name fallbacks for remembered Sessions that are no longer running. See [Topic records](../topic-records.md).
