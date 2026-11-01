import CryptoKit
import Foundation
import MuxifyCore

/// Installs the bundled build through the Terminal's master, then names its watch command.
enum RemoteWatch {
    static func prepare(connection: TmuxConnection, binary: URL) throws -> CommandInvocation? {
        guard let remote = connection.remote else { throw TmuxError.notReady }
        let bytes = try Data(contentsOf: binary, options: .mappedIfSafe)
        let version = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
        let result = try connection.runScript(probe, arguments: [version])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if result == "unsupported" { return nil }
        guard result == "missing" || result == "ready" else { throw TmuxError.notReady }
        if result == "missing" {
            _ = try connection.runScript(install, arguments: [version], timeout: 120, inputFile: binary)
        }
        let executable = try connection.runScript(validate, arguments: [version])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if executable == "unsupported" { return nil }
        guard executable.hasPrefix("/"), executable.hasSuffix("/\(version)/muxify") else { throw TmuxError.notReady }
        return remote.script("""
        socket=$(tmux -u display-message -p '#{socket_path}') || exit $?
        export MUXIFY_REMOTE_MARKER="$2"
        exec "$1" environment watch --socket "$socket"
        """, arguments: [executable, remote.markerOption])
    }

    static let probe = """
    if [ "$(uname -s)" != Darwin ]; then printf 'unsupported'; exit 0; fi
    major=$(sw_vers -productVersion); major=${major%%.*}
    case "$major" in ''|*[!0-9]*) printf 'unsupported'; exit 0;; esac
    if [ "$major" -lt 14 ]; then printf 'unsupported'; exit 0; fi
    case "$(uname -m)" in arm64|x86_64) ;; *) printf 'unsupported'; exit 0;; esac
    if [ -f "$HOME/.local/share/muxify/bin/$1/muxify" ]; then printf 'ready'; else printf 'missing'; fi
    """

    static let install = """
    set -eu
    umask 077
    directory="$HOME/.local/share/muxify/bin/$1"
    mkdir -p "$directory"
    temporary=$(mktemp "$directory/.upload.XXXXXX")
    trap 'rm -f "$temporary"' EXIT HUP INT TERM
    cat > "$temporary"
    digest=$(/usr/bin/shasum -a 256 "$temporary"); digest=${digest%% *}
    [ "$digest" = "$1" ] || exit 74
    chmod 700 "$temporary"
    if ! ln "$temporary" "$directory/muxify" 2>/dev/null; then
        installed=$(/usr/bin/shasum -a 256 "$directory/muxify"); installed=${installed%% *}
        [ "$installed" = "$1" ] || exit 74
    fi
    """

    static let validate = """
    set -eu
    root="$HOME/.local/share/muxify/bin"
    executable="$root/$1/muxify"
    if ! "$executable" --help >/dev/null 2>&1; then printf 'unsupported'; exit 0; fi
    touch "$root/$1"
    kept=0
    for directory in $(cd "$root" && ls -1t); do
        case "$directory" in *[!0-9a-f]*|'') continue;; esac
        [ "${#directory}" -eq 64 ] || continue
        [ -f "$root/$directory/muxify" ] || continue
        kept=$((kept + 1))
        if [ "$kept" -gt 2 ] && [ "$directory" != "$1" ]; then rm -rf "$root/$directory"; fi
    done
    printf '%s' "$executable"
    """
}
