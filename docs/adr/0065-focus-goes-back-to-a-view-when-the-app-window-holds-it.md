# Focus goes back to a view when the App Window holds it

A Command Palette's search field takes Focus while the palette is open ([ADR 0016](0016-focus-is-where-input-goes.md)). When a Command closed the palette, the field went away and AppKit made the App Window itself the first responder. No view had Focus, and the user had to click before they could type again. Each close said whether it gave Focus back, and most Commands said no, because a later step was expected to take it. Only a route to a Window did. The Git View's close had the same parameter and the same gap.

The store now owns one Focus rule: **while nothing takes input on its own, one view of the App Window has Focus.** When the first responder becomes the App Window itself, the store waits one turn of the main queue, so a route or a close that gives Focus somewhere goes first. If the window still holds it, and no Command Palette is open, no sheet or alert is attached, and no Empty Topic page shows, Focus goes back to the holder that had it last: the Terminal side (the Terminal or its Find in Pane field), the Browser, or the Git View. An open Git View takes it over its sides, as going to a Window does. A last holder that is hidden gives it to the side on screen, as a Maximize does. A Window switch forgets the last holder, so the new Window starts in its Terminal, as going to a Window does. The decision is a pure function, `FocusGap.focusToRestore` in `Workspace/FocusRule.swift`, and the store reads the inputs when the one turn has passed.

`close()` on a palette or a Git View keeps one job: when its own field or key view has Focus at the close, it gives Focus back to the exact view that had it before, so a Find in Pane field or a pasted path lands where it was. Else it does nothing, and the rule covers the gap. The `restoringFocus:` parameter is gone.

**The Empty Topic page is the exception.** `showEmptyTopic` and `showTopic(.noTopic)` take Focus away from every view on purpose: the page offers buttons and no place to type. The rule leaves the window as the first responder there. The Browser does not show beside an Empty Topic page, because the page has no Window and so no Browser, so no Focus goes to it.

## Considered Options

- **Each close site says whether it gives Focus back.** The state before this change. Rejected: fourteen sites had to agree on what a later step does, and most were wrong.
- **Every Command ends with a Focus move.** Rejected: a Command that routes to a Window would move Focus twice, and a new Command could forget the move. The rule holds for a Command that no one wrote yet.
- **The rule acts at once, with no turn in between.** Rejected: a route that goes to another Window gives Focus to a Terminal that is not on screen yet, and the rule would give it to the old one first.
