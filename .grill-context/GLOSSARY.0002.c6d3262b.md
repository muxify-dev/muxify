---
fragment: c6d3262b
generation: 0002
branch: unify-app-focus-and-move-its
---

+ Location
  What an App Window shows in the Terminal's place: a Window or an Empty Topic page. Each App Window has one Location, and the Active Topic comes from it.
  avoid: place, focus, selection, current Window (when an Empty Topic page shows)
  under: Layout

+ Empty Topic page
  The page that an App Window shows in the Terminal's place for a Topic with no live Session, which is Empty, Dormant or Settled. It also shows for No Topic when No Topic has no Window. It offers Add a Session, or Reopen and Start Fresh.
  avoid: Topic page, empty view, Empty (when you mean the page of a Dormant or Settled Topic)
  under: Layout

+ Intent
  A move to a Location that the Terminal does not show yet, such as a click on a Window row before tmux switches the Client. An App Window has at most one Intent, and a new one replaces it.
  avoid: pending selection, navigation, transition
  under: Layout

~ Active Topic
  The Topic of the App Window's Location: the Topic of its Window or of its Empty Topic page, or No Topic.
  was: The Topic of the Window the user looks at, or No Topic when that Window belongs to no Topic.

~ App Window
  A native macOS Muxify window, with its own Active Environment, Location, terminal and Browser.
  was: A native macOS Muxify window, with its own Active Environment, selected tmux Window, terminal and Browser.

~ Session Path
  A folder offered as a place to start a Session, found through `sessions.paths` or Git's Worktrees. It is a launch folder, not a running Session or a group of Sessions.
  was: A folder offered as a place to start a Session, found through `sessions.paths` or Git's Worktrees. It is a launch location, not a running Session or a group of Sessions.
