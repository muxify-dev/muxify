#!/bin/sh
cd "$(dirname "$0")/.." || exit 2
found=$(rg -n --type swift 'EnvironmentService|@_spi\(CLI\)|environmentModule\.write\(|topicWatcher\.store\.write\(|connection\.run(Async)?\(' Sources/Muxify Sources/MuxifyCLI)
case $? in
0)
    printf '%s\n' "$found"
    echo "App and CLI Environment writes must use typed Perform requests. EnvironmentService is internal to Core." >&2
    exit 1 ;;
1) ;;
*) exit 2 ;;
esac
found=$(rg -n --type swift '\["(select-pane|split-window|resize-pane|select-layout|new-window|new-session|switch-client|set-option|set-buffer|paste-buffer|delete-buffer)"' Sources/Muxify -g '!RemoteSSH.swift')
case $? in
0)
    printf '%s\n' "$found"
    echo "Raw Environment writes belong to Core. Only the native Remote attachment bootstrap may create its Session before SSH is ready." >&2
    exit 1 ;;
1) ;;
*) exit 2 ;;
esac

found=$(rg -n --type swift 'TopicStore|TmuxServer\.local\.snapshot|runner\.run\("tmux"' Sources/MuxifyCLI -g '!CLIProcessRunner.swift')
case $? in
0)
    printf '%s\n' "$found"
    echo "CLI Environment reads and writes must use the module. CLIProcessRunner only supplies its transport." >&2
    exit 1 ;;
1) ;;
*) exit 2 ;;
esac
