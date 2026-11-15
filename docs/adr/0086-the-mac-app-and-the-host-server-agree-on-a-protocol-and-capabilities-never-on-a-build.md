# The Mac app and the Host server agree on a protocol and capabilities, never on a build

A Remote App Window talks to the Host CLI's server, and the two are usually different builds. CI publishes `cli-latest` and a Tip Build from the same push to `master`, and a Release is a tag on a `master` commit that is already published. So after the install chain (ADR 0076, and the Mac's upload when the Host cannot download), the server is the app's build or newer. Only a Debug app built from a branch is ahead of it. We decide that skew is handled, not avoided: the two sides compare a protocol integer and exchange capabilities, and the `build` line is never compared. Zed requires the exact build instead, which works because Zed installs the server matching the client. Here the Host's `muxify` is shared by Agents, the phone and every Mac that connects, and it follows `master`.

- **The gate is `protocol`.** The server's `hello` carries `protocol`, the highest it speaks, and `min_protocol`, the lowest. The Mac's `hello` names the protocol it will speak: the highest one both support. If there is none, or the binary has no server mode (an old CLI exits 2 on the unknown command), the App Window falls back to Sessions only at once, without waiting out the 10 s `hello` timeout. Both start at 1. A bump is for a change that is not additive, needs its own ADR, and is expected to be rare. Raising `min_protocol` needs an ADR too, and comes only after a Release that speaks the new protocol has shipped, so Release apps in the field keep working.
- **`build` is never compared.** It is the `muxify <short-sha> <commit-unix-time>` line. It goes to the Diagnostics log and into the reason the App Window gives when it falls back to Sessions only. The app gets its own: every build of the app, Debug included, has the line stamped into its Info.plist by a build phase. A Debug build also has its source root stamped.
- **Capabilities name additions.** The surface of the first server release is what `protocol: 1` means, and has no capability. A capability names one feature that a later release adds (for example `events.git` or `config.watch`). It comes into being when a release adds requests, events or values that the other side must know before it uses them.
- **Both sides declare capabilities, and each sends only what the other declared.** That covers a request case, an event kind in a subscription, a request the server starts, and an enum value. A newer server talks to an older Mac in the older Mac's terms. Since the server is usually the newer side, this is the rule that keeps Release apps working.
- **A Mac newer than its server** hides every Action whose capability the server lacks, as the `isRemote` guards hide them today. The App Window says nothing about it. One Diagnostics line per connect names the missing capabilities and both `build` lines. `unsupported` still answers a request that slips through.

## The change rule

1. A new key is optional or has a default, in both directions, and needs no capability. Every decoder ignores keys it does not know.
2. A new request case, event kind or enum value comes with a capability. A side sends it only when the other side's `hello` declared that capability. The change states what an older peer gets instead: the value mapped to an older one, or the record left out.
3. Renaming or removing a key, or changing its type or meaning, is never allowed within a protocol. It needs a protocol bump and an ADR.
4. A capability, once added, is never taken away while its protocol is spoken.
5. Tests pin the JSON form of every message, as they pin `EnvironmentRequest` today. Each release that changes the protocol adds a folder of its messages under MuxifyCore's `Tests/MuxifyCoreTests/Fixtures/Protocol/`, and a test decodes every folder, so the previous releases' fixtures keep decoding.

This is the protocol's form of ADR 0079's "the schema changes only by adding".

## Which binary serves

- **A Release or Tip Build app** runs the server from the `muxify` that the install chain left: the Host's own download of `cli-latest` into `~/.local/bin`, else the bytes of `cli-latest` that the Mac sends there.
- **On a Mac Host with Muxify.app**, the server runs from the bundle's `muxify`, which ADR 0076 leaves alone because that Host's app owns it. It may be older than the connecting Mac, and the capability rules degrade what it lacks. The Mac never writes over it.
- **A Debug app** uploads its own build only when it has one. It looks for `build/host-cli/` in its stamped source root, and uses it only if that folder's `version` names the sha stamped into the app. Uncommitted changes in the tree are the developer's to keep in step. The upload goes to `~/.local/share/muxify/server/muxify-<sha>`, never to `~/.local/bin/muxify`, so a branch build never reaches Agents, the phone or other Macs on the Host. On each upload the Mac removes all but the three newest files in that folder. A running server keeps its inode, so removing its file is safe. Without a matching local build, a Debug app uses `cli-latest` like any app, and the features beyond it are off by capability. The app never builds a Linux binary itself, because the Docker cross-compile takes minutes.
- **A server running during an update** keeps serving until its channel ends. The install's `mv` gives `~/.local/bin/muxify` a new inode and leaves the running process on the old one. The Mac never restarts a live server only because a newer binary appeared. Servers of different builds on one Host keep coordinating through `muxify.db`, whose schema only grows.

## Considered Options

- **The exact build must match** (Zed). Rejected: `cli-latest` moves on every push to `master`, so every Release app would mismatch within hours. The fix would be a binary per app build on each Host, which takes the Host's `muxify` away from Agents and the phone.
- **Semver on the build.** Rejected: the build is a sha and a commit time, not a version number, and a Tip Build has no semver.
- **One capability per request case**, generated from the enum. Rejected: the list is long, and the palette still has to group the cases into the features it offers.
- **No capabilities, only `unsupported`.** Rejected: the palette would offer Actions that fail when run. An older Mac also cannot decode a new event kind or enum value from a newer server, so the server must know what the Mac understands.
- **A Debug app that builds its own server on connect** (Zed's dev builds run `cargo build`). Rejected: the static Linux build is a Docker cross-compile of several minutes.

## Consequences

- ADR 0076's rejected option "the Mac downloads and sends the bytes over SSH" now has two uses: `cli-latest`'s bytes for a Host without internet, and a Debug app's own build into a folder of its own.
- A release that adds to the protocol must also add a capability, the older peer's fallback, and fixtures.
- Packaging stamps the `build` line into the app as well as into the Host CLI.
