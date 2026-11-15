#!/bin/sh
# Every Action runs in the palette's view (docs/adr/0014-every-action-runs-in-the-palettes-view.md): Sources/Muxify has
# no sheet and no alert accessory view, and each NSAlert is an explicit exception in ALERTS, as file:count.
cd "$(dirname "$0")/.." || exit 2
ALERTS='Sources/Muxify/App/CommandLineToolInstaller.swift:1
Sources/Muxify/App/ExtensionInstaller.swift:1
Sources/Muxify/Browser/BrowserTab.swift:1
Sources/Muxify/Workspace/WorkspaceStore.swift:3'
status=0

sheets=$(rg -l -U --type swift '\.sheet\s*\(|\.accessoryView\s*=|enum\s+PresentedSheet\b' Sources/Muxify)
# rg exits 1 when it finds nothing. Any other failure, such as no rg (127), must not pass as a clean tree.
case $? in
0)
    printf '%s\n' "$sheets"
    echo "An Action runs in the palette's view, not in a sheet or an alert accessory view. See docs/adr/0014-every-action-runs-in-the-palettes-view.md." >&2
    status=1 ;;
1) ;;
*)
    echo "check-palette-structure.sh could not search the sources. It needs ripgrep (rg)." >&2
    exit 2 ;;
esac

alerts=$(rg -U --count-matches --sort path --type swift '\bNSAlert\s*\(' Sources/Muxify)
case $? in
0|1) ;;
*)
    echo "check-palette-structure.sh could not search the sources. It needs ripgrep (rg)." >&2
    exit 2 ;;
esac
if [ "$alerts" != "$ALERTS" ]; then
    printf 'NSAlert calls per file:\n%s\nALERTS in scripts/check-palette-structure.sh:\n%s\n' "$alerts" "$ALERTS"
    echo "A new alert that takes input needs its own ADR first (docs/adr/0014-every-action-runs-in-the-palettes-view.md). Then make ALERTS match." >&2
    status=1
fi
exit $status
