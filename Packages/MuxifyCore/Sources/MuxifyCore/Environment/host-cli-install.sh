# Installs or updates the Host CLI in ~/.local/bin (docs/adr/0076-the-app-installs-the-host-cli-from-a-rolling-github-prerelease.md).
# The one copy: the Mac app runs this text over SSH, and CI publishes it as the install.sh asset of cli-latest, which
# the phone pipes to `sh -s -- <base>`. POSIX sh. $1 is the base URL, ending in /; $2, for tests, replaces the app
# bundle's muxify. It prints one line, installed, updated, current, kept, skipped: or failed:, and exits 0.
set -f
base=$1
bundle=${2:-/Applications/Muxify.app/Contents/Resources/bin/muxify}
dir=$HOME/.local/bin
target=$dir/muxify
# A temp file of this run's own, so that installs from the Mac and the phone at once do not overwrite each other's.
new=$dir/muxify.new.$$
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
    # shellcheck disable=SC2086 # set -f: split on spaces only.
    set -- $1
    [ "$#" -eq 3 ] && [ "$1" = muxify ] || return 1
    case $3 in
        '' | *[!0-9]*) return 1 ;;
    esac
    printf '%s %s\n' "$2" "$3"
}

os=$(uname -s | tr '[:upper:]' '[:lower:]')
arch=$(uname -m)
found=
if path=$(command -v muxify 2>/dev/null) && usable "$path"; then
    found=$path
elif usable "$target"; then
    found=$target
# Muxify.app runs only on a Mac. A Linux machine can see the Mac's own through a shared folder (OrbStack
# mounts /Applications), and that one does not run there.
elif [ "$os" = darwin ] && usable "$bundle"; then
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
# Another run's temp file is left alone; one older than a day is from a run that was killed.
find "$dir/." ! -name . -prune -name 'muxify.new*' -type f -mtime +0 -exec rm -f {} + 2>/dev/null || :
# After a successful mv there is no $new left to remove.
trap 'rm -f "$new"' EXIT
trap 'exit 1' HUP INT TERM
fetch "$base$asset" "$new" 2>/dev/null || result "failed: cannot download $base$asset"
chmod +x "$new" 2>/dev/null || result "failed: cannot make $new executable"
out=$("$new" --version 2>/dev/null) || out=
if [ "${out%%"$nl"*}" != "$line" ]; then
    result "failed: $asset prints '${out%%"$nl"*}', not '$line'"
fi
mv -f "$new" "$target" 2>/dev/null || result "failed: cannot move $new to $target"
if [ -z "$found" ]; then
    result "installed $published"
fi
result "updated ${installed:-unknown} -> $published"
