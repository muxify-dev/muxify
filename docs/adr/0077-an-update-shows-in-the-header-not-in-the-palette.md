# An update shows in the header, not in the palette

When the updater finds an update, the Update Button appears in the header of every App Window, and a click opens the Update Popover: the version, size and release date, a link to the release notes or the commit, and Skip, Later, and Install and Relaunch. The button also shows a check that the user started, the download's and the extraction's progress, the install, "No Updates Available" for five seconds, and "Update Failed", whose popover holds the error with OK and Retry. Its texts and symbols follow Ghostty's, except that the error's text stays in the popover, where the header has room for it. This is the one place outside the palette's view that asks the user to choose, which [0014](0014-every-action-runs-in-the-palettes-view.md) and AGENTS.md allow only with an ADR.

The palette's view cannot do it, because Muxify starts this, not the user. A palette step opens only when the user asks for it, and an update found by a background check must wait, visible but without taking Focus ([0016](0016-focus-is-where-input-goes.md)), until the user turns to it. A Pill cannot do it either: it goes away by itself and takes no clicks. So the button waits in the header, and Muxify never opens the popover by itself.

Check for Updates is still a Command that runs at once, and an item in the app menu after About Muxify. Its result shows on the Update Button. Install and Relaunch quits Muxify as ⌘Q does, with no further confirmation, since tmux keeps every Session and Agent ([0001](0001-tmux-is-the-source-of-truth.md)).

## Considered Options

- **A palette step after a background check finds an update.** Rejected: it would open the palette while the user types in a Pane.
- **Sparkle's standard update window.** Rejected: it is a window that takes Focus, and it shows Sparkle's own "check automatically?" choice, which the Config owns ([0005](0005-muxify-config-is-a-yaml-file.md)).
- **A macOS notification.** Rejected: it can be turned off or missed, and the choice would still need a window.
