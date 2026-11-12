# Muxify updates itself with Sparkle from feeds in a GitHub release

Muxify.app updates itself with Sparkle 2. It reads one of two feeds, chosen by the local Config's `update.channel`: `stable.xml`, which lists the newest Release, or `tip.xml`, which lists the newest Tip Build. Both are assets of a rolling GitHub prerelease, `appcast`, at `https://github.com/muxify-dev/muxify/releases/download/appcast/<channel>.xml`, and each feed holds only its newest item. A Release's zip is an asset of its own `v*` release. Each Tip Build's zip, `Muxify-tip-<short-sha>-arm64.zip`, is an asset of a rolling `tip` prerelease that keeps the last ten. CI publishes a Tip Build on every push to master and a Release on every `v*` tag whose commit is on master, and each job rewrites only its own feed. This is the second rolling prerelease after `cli-latest` ([0076](0076-the-app-installs-the-host-cli-from-a-rolling-github-prerelease.md)), and it needs no server or domain: the repository must stay public.

- **Order.** `CFBundleVersion` is the number of commits on master (`git rev-list --count`), so a Release and a Tip Build of the same commit compare equal, and builds from the two channels order by history. A Release tag off master is refused. Sparkle never installs a lower build, so a switch from tip to stable keeps the Tip Build until a Release passes it.
- **Trust.** Sparkle checks every update with an EdDSA signature over the zip, whose private key is the CI secret `SPARKLE_ED_PRIVATE_KEY`. It does not depend on Apple signing, so updates work before Muxify has a Developer ID, and the key stays the same when it gets one. Until then CI signs with a self-signed "Muxify Release Signing" certificate, also a CI secret, so that macOS keeps Local Network, Accessibility and Input Monitoring grants across updates. Only the first install needs Open Anyway. A publishing job without either secret fails; it never publishes with another key.
- **Which builds update.** Only builds that CI packages carry a feed and an updater. A Debug or `make install` build has neither, so a local build is never replaced by a Tip Build. `MUXIFY_UPDATE_FEED_URL` turns the updater on in any build, Debug included, and points it at that feed, so an end-to-end check can serve a local one; it is not a setting. A feed may then be plain `http` on localhost, because the EdDSA signature, not the transport, is what Sparkle trusts.
- **The Config owns the settings** ([0005](0005-muxify-config-is-a-yaml-file.md)). `update.check` (default true) turns the check at launch and every 24 hours on or off; Check for Updates always works. `update.channel` is `stable` (default) or `tip`. Both are read only from the local Config, and a remote Config's `update` is ignored, as `ghostty` is ([0010](0010-app-windows-use-their-environments-config.md)). Sparkle's own "check automatically?" prompt is turned off.
- **The feeds come from `scripts/write-feed.py`**, which writes one item from the zip, its `sign_update` signature and the version, not from Sparkle's `generate_appcast`.

## Considered Options

- **GitHub Pages or a server for the feeds.** Rejected: a release asset needs no deploy, no domain and no second workflow, as `cli-latest` shows.
- **One feed with Sparkle channels** (`sparkle:channel`, `allowedChannels`). Rejected: both CI jobs would rewrite one file and race, and the feed would have to keep the newest item of each channel.
- **The GitHub run number as the build number.** Rejected: a rerun or a second workflow changes it, and a Release and a Tip Build of the same commit would differ.
- **Ad-hoc signing until Developer ID.** Rejected: each update would get a new signature, and macOS would ask for its permissions again after every Tip Build.
- **`generate_appcast`.** Rejected: it reads every old zip from a local folder, and it makes delta updates, which Muxify does not publish.
- **An updater in every build.** Rejected: `make install` builds have `CFBundleVersion` 1, so any Tip Build would replace them.

## Consequences

- Developer ID signing, hardened runtime and notarization come later, in their own change, once Muxify has the certificate. That change also signs Sparkle's helper tools with it.
- Sparkle does not check or update a copy that runs from a translocated or read-only location, such as one opened from `~/Downloads` without being moved. Its background check only logs this; Check for Updates shows Update Failed with "Move Muxify to Applications to update it." The Release notes say to move Muxify to Applications before opening it.
- When the Developer ID arrives, the first update to a Developer ID build resets the macOS permissions once, and later updates keep them.
- A plain `vX.Y.Z` Release becomes the repository's Latest release. Betas, `tip`, `appcast` and `cli-latest` stay prereleases that are never Latest.
