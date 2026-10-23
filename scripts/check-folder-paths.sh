#!/bin/sh
# Every folder comparison goes through Folder (docs/adr/0022-a-folder-is-the-same-folder-through-symlinks.md).
# Foundation's path normalizers compare spellings, not folders, and they drop /private where realpath and git keep it.
cd "$(dirname "$0")/.." || exit 2
found=$(rg -n --type swift 'standardizingPath|resolvingSymlinksInPath|standardizedFileURL|realpath\(' Sources Packages/MuxifyCore/Sources \
    -g '!Folder.swift' -g '!CLICommand.swift' -g '!TestDriver.swift' \
    -g '!ConfigFileSet.swift' -g '!Config.swift')
# rg exits 1 when it finds nothing. Any other failure, such as no rg (127), must not pass as a clean tree.
case $? in
0)
    printf '%s\n' "$found"
    echo "Compare folders with Folder, not by their spelling. See docs/adr/0022-a-folder-is-the-same-folder-through-symlinks.md." >&2
    exit 1 ;;
1) ;;
*)
    echo "check-folder-paths.sh could not search the sources. It needs ripgrep (rg)." >&2
    exit 2 ;;
esac
