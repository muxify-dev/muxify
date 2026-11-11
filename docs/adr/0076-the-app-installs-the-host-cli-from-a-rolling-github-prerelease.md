# The app installs the Host CLI from a rolling GitHub prerelease

The phone reads and changes a Host's Topics only through a `muxify` on that Host, and a Linux Host, or a Mac without Muxify.app, has none. We decide that the Mac app puts one there. Each time a Remote Environment connects, one script runs over the owned SSH connection (ADR 0006). It looks `muxify` up as the phone does: `command -v muxify`, then `~/.local/bin/muxify`, then, on a Mac only, `/Applications/Muxify.app/Contents/Resources/bin/muxify` (a Linux machine in OrbStack sees the Mac's own there, and it does not run). It leaves a `muxify` inside a Muxify.app alone, because that Host's own app owns it; a link into the bundle, such as the one Install Command Line Tool puts in `~/.local/bin`, counts as the bundle. Otherwise it compares the found `muxify --version` with the published `version` asset, and downloads `muxify-<uname -s, lowercased>-<uname -m>` into `~/.local/bin/muxify` when `muxify` is missing, when `--version` fails, or when the published commit time is later than the installed one. The Host downloads it itself with `curl`, else `wget`, from the hardcoded `https://github.com/muxify-dev/muxify/releases/download/cli-latest/`. The outcome goes to the Diagnostics log. A failure never blocks the Remote Environment, and there is no Action for it.

- **The contract** is shared with the phone, which will run the same install later. It consists of the tag `cli-latest`; the assets `muxify-linux-aarch64`, `muxify-linux-x86_64`, `muxify-darwin-arm64` and `version`; the line `muxify <short-sha> <commit-unix-time>` that `muxify --version` prints and the `version` asset holds; and the folder `~/.local/bin`.
- **CI** republishes `cli-latest` as a prerelease on every push to `master`. The Linux binaries are static (musl), so they run on any distribution.
- **A newer build is never replaced by an older one**, so a CLI that a test or a developer installed from a branch stays. A local `swift build` with no stamp prints `muxify dev 0`, which every published build replaces.
- `MUXIFY_CLI_BASE_URL` overrides the base URL, so the Live SSH test can serve a local build to an OrbStack machine. It is not a setting.

## Considered Options

- **The user installs it.** Rejected: every new Host would need a manual step, and the phone would show "No Topics on this Host" until it was done.
- **The app's own release tag, pinned.** Rejected: betas are prereleases, so `releases/latest` does not reach them, and a Debug build has no tag at all.
- **The Mac downloads and sends the bytes over SSH.** Rejected: it needs an upload path in the app and sends about 2× the bytes. A Host with no internet gets no CLI; the Diagnostics log says so.
- **An "Update Muxify CLI on Host" Action.** Rejected: the version check runs at every connect, so the Action would have nothing to do.
- **A ghcr.io package.** Rejected: a Host would need `oras` or a registry token, where `curl` is enough for a Release asset.

## Consequences

- This changes ADR 0006's "requires no remote Muxify helper". The app still runs no long-lived process on a Host; the Host CLI is a file that the phone and the Host's Agents run.
- The Mac app does not read the Host's Topics. A Remote Environment keeps `topicsAvailable: false`, and the Host's `topics.json` belongs to the Host CLI.
- `muxify-dev/muxify` must stay public, or a plain `curl` gets a 404.
