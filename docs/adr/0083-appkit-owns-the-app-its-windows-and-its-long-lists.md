# AppKit owns the app, its windows and its long lists; SwiftUI draws what a window shows

Muxify embeds libghostty as Ghostty's macOS app does, and we compared the two. Ghostty starts from `NSApplicationMain` with an AppKit app delegate. Its main menu is AppKit, and each window has its own `NSWindowController`. The terminal surface is an AppKit `NSView`. SwiftUI draws what a window shows (the splits, the overlays, the command palette) inside one hosting view per window. Ghostty began on the SwiftUI app life cycle and left it: a comment in its `TerminalView.swift` says "after switching from SwiftUI to AppKit lifecycle". Muxify already hosts its terminal surface the same way. Its app, its App Windows and its main menu are still a SwiftUI `App`, with a `WindowGroup`, `.commands` and a `Settings` scene. That shell carries six workarounds. Without them, SwiftUI opens an extra App Window for a `muxify://` URL, hands a live window its restored value, evaluates a closing scene again, and hides the `NSWindow` behind an invisible view. A key monitor also runs ahead of the menu. Two fixes came from that shell (`d1a5960`, `4bdfda1`).

The freeze that started this was not in the terminal. An animated `scrollTo` in the Sidebar's SwiftUI Sessions list never came to rest on a scaled page. It left about 37,000 display links behind and froze the whole app (`7cb4cb6`). Ghostty's split alone would not have prevented it, because Ghostty keeps window content in SwiftUI and the Sidebar is content. Ghostty has no long list that scrolls, animates and drags. Muxify does.

On the branch `swiftui-to-appkit`, ADR "An area leaves SwiftUI for AppKit only where SwiftUI caused bugs" moved the Sidebar's Sessions list to AppKit. ADR "Muxify leaves SwiftUI entirely, one area at a time" then moved the Topics list and planned six more stages, until no file imports SwiftUI. The first two stages wrote about 8,600 lines of AppKit for about 3,100 lines of SwiftUI. About 10,000 lines of SwiftUI are left: the App Window's header, the Command Palette, the Browser's chrome, the Git View, the Settings window and the overlays. The history shows no SwiftUI bug that a user saw in any of them.

We decide that Muxify takes Ghostty's split, with one rule that Ghostty does not need:

- AppKit owns the app: it starts from an AppKit app delegate through `NSApplicationMain`, with no SwiftUI `App`, `Scene` or `WindowGroup`.
- AppKit owns each App Window: one `NSWindowController` per App Window, whose content view is an AppKit container that holds one `NSHostingView` of the window's SwiftUI content. The Settings window has its own `NSWindowController` with a hosting view.
- AppKit owns the main menu. It is built in code, not in a nib, because its titles, check marks, enabled states and shortcuts follow the focused App Window and its Config. The menu shows the shortcuts. The key monitor still fires them, so the Focus rules of ADR 0042 do not change.
- AppKit's window restoration (`restorationClass`, `encodeRestorableState`) restores the App Windows, as `WindowGroup` did underneath and as Ghostty's `TerminalRestorable` does. The macOS setting "Close windows when quitting an application" still decides.
- The terminal surface stays an AppKit `NSView` hosted in SwiftUI, as it is.
- A view that scrolls a long list, animates every frame or drags is AppKit. The Sidebar is AppKit in full: its lists, the pager and its swipe, the Agents section and the resize handle. The branch `swiftui-to-appkit` does this work and lands on its own.
- SwiftUI draws everything else in a window: the header, the Command Palette, the Browser's chrome, the Git View, the Settings content, the Find bar, the overlays and the Empty Topic page. A new view of this kind is SwiftUI.
- The models stay `@Observable`. The deployment target stays macOS 14.
- The four build rules of ADR "An area leaves SwiftUI for AppKit only where SwiftUI caused bugs" stay for every AppKit view: frames, not Auto Layout; shared definitions; `withObservationTracking` once in a turn of the run loop; Core Animation with the durations and curves the design names.

This replaces the roadmap of ADR "Muxify leaves SwiftUI entirely, one area at a time" after the Sidebar. When the branch `swiftui-to-appkit` lands, that ADR is marked as replaced by this one.

## Considered Options

- **Leave SwiftUI entirely**, as the branch's ADR planned. Rejected: it spends about three lines of AppKit for each line of SwiftUI, plus a compare run and a sign-off for each area, on areas where SwiftUI caused no bug that a user saw. The materials, the menus and the accessibility rows the suites read would all be built by hand.
- **Ghostty's split alone, with the Sidebar back in SwiftUI.** Rejected: the freeze came from a SwiftUI list that scrolls and animates. That kind of view is the one place SwiftUI hurt Muxify.
- **Stop after the Sidebar and keep the SwiftUI `App`.** Rejected: the workarounds for the window scene stay, and so do `muxify://` routing, window identity and restoration done by fighting SwiftUI's defaults.
- **A main menu in a nib, as Ghostty has.** Rejected: most items change their title, check mark or enabled state with the focused App Window. Code says that in one place, and a review reads it as a diff.
- **Let the menu fire the shortcuts, as Ghostty's does.** Rejected for this move: the key monitor carries the rule that a Pane or Browser keybind acts only while its side has Focus. Changing who fires a shortcut changes behaviour, and this move does not.
- **Both shells side by side behind a launch switch, with a compare run.** Rejected: the window's content does not change, so a compare run would compare only the title bar. A record of today's menu bar, window parts and window behaviour, taken from the SwiftUI shell and passed by the AppKit shell, proves more for less.
- **Muxify's own record of open App Windows in the state database (ADR 0079).** Rejected: AppKit's restoration is what macOS users expect, and it follows the system setting.

## Consequences

- The app keeps two interface frameworks for good, with a seam at each hosting view. Each App Window has one seam for its content, plus the Sidebar's.
- An agent that adds a view decides by the rule above: AppKit for the app, the windows, the menu, the terminal surface and any long list that scrolls, animates every frame or drags; SwiftUI for the rest.
- The Edit, Window and Help menus that SwiftUI added for free are built by hand, and the record of the menu bar keeps them from going missing.
- The header's fixed space for the traffic lights stays as it is. Reading their real frame is a separate change.
