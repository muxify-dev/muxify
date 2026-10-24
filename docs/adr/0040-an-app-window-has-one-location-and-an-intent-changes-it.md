---
status: proposed
---

# An App Window has one Location, and an Intent changes it

Muxify found the Active Topic from seven separate states: the selected Window, two flags for an Empty Topic page, three kinds of wait for a click or a request to arrive, and a flag for a Window that disappeared. Each writer kept the others correct by hand, and `TopicsModel` combined them with a precedence rule. When a script made a Session in the Topic whose Empty Topic page showed, that rule fell back to the Window under the page, and the app sent the user back to another Topic (632d61c).

We decide that each App Window has one **Location**: a Window, the Empty Topic page of a Topic, or the Empty Topic page of No Topic. The Active Topic comes from the Location only. A move that tmux does not show yet is the App Window's one **Intent**, which a new move replaces. One pure function in MuxifyCore takes the Location, the Intent and one event (a request, a tmux read, a finished tmux command, a new server) and gives the next Location and Intent, and the tmux commands to run. The tmux Client follows the Location. A read changes the Location from the Client only when the Client moved since the last read and no Intent waits.

A read ends an Intent only when the read started after the tmux command of the Intent finished. Each read has a number for this. A time limit stays only for a CLI request that names a Session that may never come.

Location is the word of the React Router for where the app is now (`useLocation()`). TanStack Router calls it `resolvedLocation`.

## Considered Options

- **Keep the states and correct each race where it shows.** Rejected: 632d61c is such a correction, and the cause stays. Each new rule adds one more order that `apply()` depends on.
- **The tmux Client's Window is the Location.** Rejected: on an Empty Topic page the Client still shows the Window under the page. The bug of 632d61c came from this.
- **Fixed time limits end a wait, as before (2, 3, 5 or 10 s).** Rejected: a read that is slower than the limit reverts a selection, and a longer limit only makes the race less frequent.
- **The model in the app target.** Rejected: the CLI's `TopicChange.Shown` already names two of the three cases. In MuxifyCore, the CLI and the app use one type, and its tests run without the app.
- **Other names.** Focus is where input goes ([0016](0016-focus-is-where-input-goes.md)). Place names five types already. Shown and Destination name two types each. View, Page and Screen have other meanings in the app. Route is a definition in a router, not where the app is now. Navigation, the React Router's word for a move in progress, was a candidate for the Intent. `WindowNavigation` already uses that word for Ghostty's numbered tab keys.

## Consequences

- `TopicChange.Shown` becomes `Location`. Its JSON keys stay, so the CLI output does not change.
- `selectedWindowID`, `emptyTopicID`, `showsEmptyNoTopic`, `pendingSelection`, `pendingSelect`, `pendingNextTopic`, `recoveryPending` and the 632d61c rule go away.
- The transitions have unit tests. An e2e check stays only where it must prove a real click or a real tmux read.
