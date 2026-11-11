import Foundation

/// The Host CLI: the `muxify` that a Remote Environment's machine keeps in `~/.local/bin`, installed and updated from
/// the rolling `cli-latest` GitHub prerelease each time the Environment connects (ADR 0076).
public enum HostCLI {
    public static let defaultBaseURL = "https://github.com/muxify-dev/muxify/releases/download/cli-latest/"
    /// Where Muxify.app keeps its own `muxify`, the last place the phone looks.
    public static let appBundleCLI = "/Applications/Muxify.app/Contents/Resources/bin/muxify"
    /// The download is a few megabytes; a slow Host still finishes, a stuck one gives up.
    public static let timeout: TimeInterval = 60

    /// `MUXIFY_CLI_BASE_URL` when it is set, so a test serves its own build; else the release's.
    public static func baseURL(environment: [String: String]) -> String {
        environment["MUXIFY_CLI_BASE_URL"].flatMap { $0.isEmpty ? nil : $0 } ?? defaultBaseURL
    }

    /// The install, in POSIX `sh` so that the phone can run the same text. `$1` is the base URL, ending in `/`;
    /// `$2`, for tests, replaces `appBundleCLI`. It looks `muxify` up as the phone does, leaves one inside an app
    /// bundle alone, and downloads `muxify-<os>-<arch>` over `~/.local/bin/muxify` when none is found, when the
    /// found one's `--version` fails, or when the published commit time is later. A newer one is never replaced.
    /// It prints one line, `installed`, `updated`, `current`, `kept`, `skipped:` or `failed:`, and exits 0.
    public static let script = #"""
    set -f
    base=$1
    bundle=${2:-/Applications/Muxify.app/Contents/Resources/bin/muxify}
    dir=$HOME/.local/bin
    target=$dir/muxify
    new=$dir/muxify.new
    nl='
    '
    result() {
        printf '%s\n' "$1"
        exit 0
    }
    usable() {
        case $1 in
            /*) [ -f "$1" ] && [ -x "$1" ] ;;
            *) false ;;
        esac
    }
    # The path with its symlinks resolved, so a link to an app bundle counts as the bundle's.
    resolve() {
        p=$1
        n=0
        while [ -L "$p" ] && [ "$n" -lt 40 ]; do
            link=$(readlink "$p") || break
            case $link in
                /*) p=$link ;;
                *) p=${p%/*}/$link ;;
            esac
            n=$((n + 1))
        done
        if d=$(cd -P "${p%/*}/" 2>/dev/null && pwd -P); then p=${d%/}/${p##*/}; fi
        printf '%s\n' "$p"
    }
    # "<short-sha> <commit-unix-time>" from a `muxify --version` line; fails on any other line.
    version() {
        set -- $1
        [ "$#" -eq 3 ] && [ "$1" = muxify ] || return 1
        case $3 in
            '' | *[!0-9]*) return 1 ;;
        esac
        printf '%s %s\n' "$2" "$3"
    }

    found=
    if path=$(command -v muxify 2>/dev/null) && usable "$path"; then
        found=$path
    elif usable "$target"; then
        found=$target
    elif usable "$bundle"; then
        found=$bundle
    fi
    if [ -n "$found" ]; then
        real=$(resolve "$found")
        case $real in
            *.app/Contents/*) result "skipped: app bundle $real" ;;
        esac
    fi
    # An old CLI exits 2 on --version: it counts as the oldest.
    installed=
    if [ -n "$found" ] && out=$("$found" --version 2>/dev/null); then
        installed=$(version "${out%%"$nl"*}") || installed=
    fi

    os=$(uname -s | tr '[:upper:]' '[:lower:]')
    arch=$(uname -m)
    case $os-$arch in
        linux-aarch64 | linux-x86_64 | darwin-arm64) ;;
        *) result "failed: no Host CLI for $os $arch" ;;
    esac
    asset=muxify-$os-$arch

    if command -v curl >/dev/null 2>&1; then
        fetch() { curl -fsSL -o "$2" "$1"; }
    elif command -v wget >/dev/null 2>&1; then
        fetch() { wget -q -O "$2" "$1"; }
    else
        result "failed: neither curl nor wget"
    fi
    out=$(fetch "${base}version" - 2>/dev/null) || result "failed: cannot fetch ${base}version"
    line=${out%%"$nl"*}
    published=$(version "$line") || result "failed: ${base}version holds no version: $line"

    if [ -n "$installed" ]; then
        if [ "${installed##* }" -gt "${published##* }" ]; then
            result "kept $installed (newer than $published)"
        elif [ "${installed##* }" -eq "${published##* }" ]; then
            result "current $installed"
        fi
    fi

    mkdir -p "$dir" 2>/dev/null || result "failed: cannot create $dir"
    rm -f "$new"
    if ! fetch "$base$asset" "$new" 2>/dev/null; then
        rm -f "$new"
        result "failed: cannot download $base$asset"
    fi
    chmod +x "$new" 2>/dev/null || { rm -f "$new"; result "failed: cannot make $new executable"; }
    out=$("$new" --version 2>/dev/null) || out=
    if [ "${out%%"$nl"*}" != "$line" ]; then
        rm -f "$new"
        result "failed: $asset prints '${out%%"$nl"*}', not '$line'"
    fi
    mv -f "$new" "$target" 2>/dev/null || { rm -f "$new"; result "failed: cannot move $new to $target"; }
    if [ -z "$found" ]; then
        result "installed $published"
    fi
    result "updated ${installed:-unknown} -> $published"
    """#

    /// Runs the install on the Environment's machine, off the calling thread, and gives `report` its result line
    /// or its error, as `Host CLI: <Environment>: <line>`. Nothing waits for it, and nothing it finds changes the
    /// connection.
    public static func install(over scripts: any ScriptRunning, environmentName: String, baseURL: String,
                               report: @escaping @Sendable (String) -> Void) {
        DispatchQueue.global(qos: .utility).async {
            let line: String
            do {
                let output = try scripts.runScript(script, arguments: [baseURL], timeout: timeout)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                line = output.isEmpty ? "failed: the install printed nothing" : output
            } catch {
                line = "failed: \(error)"
            }
            report("Host CLI: \(environmentName): \(line)")
        }
    }
}
