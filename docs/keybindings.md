# Keybindings

## Configurable actions

These keybindings work throughout Muxify, including while a Browser page or its
address bar has Focus. The Pane actions act only while the Terminal has Focus,
and the Tab, history, `close_tab` and `reopen_closed_tab` actions only while the Browser has
Focus. With Focus elsewhere, their keys go on to Ghostty, the page or the menu:
⌘M still minimizes the App Window from the Browser, and ⌘⇧] still goes to the
next Window in the Terminal. An action for one side can share its key with an
action for the other side or for everywhere, and acts while its side has Focus:
⌘⇧T reopens the last closed Tab from the Browser and opens Move for the Pane
elsewhere. When you give an action for everywhere a key that is not its default,
it takes that key from every default. All available `keybindings` actions are
listed below.

| Action | Default shortcuts | What it does |
| --- | --- | --- |
| `new_app_window` | ⌘⇧N | Open a new Local Muxify App Window. While no action has ⌘N, ⌘N does nothing, so Ghostty's ⌘N does not open an App Window |
| `new_topic` | ⌘N | Open New Topic in the palette |
| `move_pane` | ⌘⇧T | Open Move for the current Pane. While the Browser has Focus, ⌘⇧T is `reopen_closed_tab` |
| `move_window` | Unbound | Open Move for the selected Window |
| `move_session` | ⌘⇧M | Open Move for the selected Window's Session, in the Command Palette's view |
| `add_session_to_topic` | ⌘⇧A | Open Add a Session for the Active Topic in the palette |
| `snooze_topic` | ⌥⌘S | Snooze the Active Topic, then open the Next Topic |
| `snooze_topics` | Unbound | Open Snooze Topics, with no Topic checked |
| `toggle_zen` | ⇧⌥⌘S | Start Zen, which Snoozes every open Topic except the Active Topic; while Zen is on, end it. While the Active Topic is No Topic or a Locked Session, or in Sessions mode, it only ends Zen |
| `settle_topic` | Unbound | Settle the Active Topic, then open the Next Topic |
| `remove_session_from_topic` | Unbound | Remove the current Session from the Active Topic. The Session stays live, and the Topic forgets it |
| `forget_topic` | Unbound | Open Forget for the Active Topic |
| `rename_topic` | Unbound | Open Rename for the Active Topic |
| `set_topic_note` | Unbound | Open Set Topic Note for the Active Topic. Its field starts with the current Topic Note, and ↩ on an empty field clears it |
| `mark_read` | ⌘⇧R | Clear Unread for the Active Topic, or the current Session when there is no Active Topic |
| `mark_unread` | ⌘⇧U | Mark the Active Topic Unread, or eligible Agents in the current Session when there is no Active Topic |
| `mark_all_read` | Unbound | Clear Unread in the Active Environment |
| `toggle_lock` | Unbound | Lock the current Session, which must be in No Topic, or Unlock it while it is Locked |
| `move_topic_up` | ⌥⌘↑ | Move the card of the Active Topic, or of the current Locked Session, one card up among the cards with its Pin. It does nothing at the top, for No Topic, for a Snoozed or Settled Topic, and in Sessions mode |
| `move_topic_down` | ⌥⌘↓ | Move the card of the Active Topic, or of the current Locked Session, one card down among the cards with its Pin. It does nothing at the bottom, for No Topic, for a Snoozed or Settled Topic, and in Sessions mode |
| `toggle_pin_topic` | Unbound | Pin the Active Topic, or Unpin it while it is Pinned. It does nothing for a Settled Topic |
| `unsnooze_topic` | Unbound | Unsnooze the Active Topic while it is Snoozed. Else, while a Snoozed Topic exists, choose one Snoozed Topic to Unsnooze |
| `unsnooze_topics` | Unbound | Open Unsnooze Topics, with no Topic checked |
| `toggle_sidebar` | ⌘S, ⌃⌘S | Show or hide the Sidebar |
| `toggle_bench` | ⇧⌘S | Show or hide the Bench, the Topics after the ones [In Play](configuration.md#topics-in-play). It does nothing while the Topics list has no Bench line |
| `toggle_terminal` | ⌘J | Show or hide the current Window's Terminal. It does nothing while the Terminal is the only side shown |
| `toggle_browser` | ⌘B | Show or hide the current Window's Browser. It does nothing while the Browser is the only side shown |
| `toggle_git_view` | ⌘G | Show or hide the [Git View](configuration.md#git-view) of the current Window's repository |
| `toggle_maximize` | ⇧⌘↩ | Maximize the side that has Focus: show it alone and hide the Sidebar. While the Window is Maximized, Restore it |
| `toggle_maximize_terminal` | ⌥⌘J | Maximize the Terminal and move Focus to it. While the Terminal is Maximized, Restore the Window |
| `toggle_maximize_browser` | ⌥⌘B | Maximize the Browser and move Focus to it, also when the Browser is hidden. While the Browser is Maximized, Restore the Window |
| `focus_terminal` | ⌘⇧J, ⌃ + backquote, ⌃0, ⌥0 | Move Focus to the Terminal. If the Terminal is hidden, show it. If the Browser is Maximized, Restore first |
| `focus_browser` | ⌘⇧B | Move Focus to the Browser: to its page, or to the address field of a blank Tab. If the Browser is hidden, show it. If the Terminal is Maximized, Restore first |
| `toggle_focus` | ⌘0 | Move Focus to the Terminal while the Browser has Focus, and to the Browser otherwise, as `focus_terminal` and `focus_browser` do. ⌘0 is also Ghostty's default for `reset_font_size` |
| `toggle_zoom_pane` | ⌘M | Zoom the current Pane: show it alone in its Window, or show all the Panes again. While a Pane is Zoomed, its Window's Pane badge in the Sidebar is on an accent capsule. Terminal Focus only |
| `resize_pane_left` | Unbound | Move the current Pane's border 10 cells left. Terminal Focus only |
| `resize_pane_right` | Unbound | Move the current Pane's border 10 cells right. Terminal Focus only |
| `resize_pane_up` | Unbound | Move the current Pane's border 10 cells up. Terminal Focus only |
| `resize_pane_down` | Unbound | Move the current Pane's border 10 cells down. Terminal Focus only |
| `find_in_pane` | ⌘F | Open [Find in Pane](#find-in-pane) over the Terminal, or select its query while it is open. Terminal Focus only. From the Browser, ⌘F is `find_in_page` |
| `find_in_page` | ⌘F | Open Find in Page above the page, and select the text in its field. Browser Focus only. From the Terminal, ⌘F is `find_in_pane` |
| `select_next_tab` | ⌘⇧], ⌃Tab | Select the next Browser Tab. Browser Focus only |
| `select_prev_tab` | ⌘⇧[, ⌃⇧Tab | Select the previous Browser Tab. Browser Focus only |
| `browser_back` | ⌘[ | Go back in the active Tab's history. Browser Focus only |
| `browser_forward` | ⌘] | Go forward in the active Tab's history. Browser Focus only |
| `close_tab` | ⌘W | Close the active Browser Tab. Browser Focus only. From the Terminal, ⌘W goes on to Ghostty |
| `reopen_closed_tab` | ⌘⇧T | Open the last closed Tab again at its place, with its history. Browser Focus only |
| `select_card_1` … `select_card_9` | ⌃1 … ⌃9 | Jump To the Topic or Session at that position in Sidebar order. A Benched card that does not show has no position |
| `select_tab_1` … `select_tab_9` | ⌥1 … ⌥9 | Select that Tab and move Focus to the Browser, showing it if hidden |
| `select_window_1` | ⌘1 | Select the first Window in the current Session |
| `select_window_2` | ⌘2 | Select the second Window |
| `select_window_3` | ⌘3 | Select the third Window |
| `select_window_4` | ⌘4 | Select the fourth Window |
| `select_window_5` | ⌘5 | Select the fifth Window |
| `select_window_6` | ⌘6 | Select the sixth Window |
| `select_window_7` | ⌘7 | Select the seventh Window |
| `select_window_8` | ⌘8 | Select the eighth Window |
| `select_window_9` | ⌘9 | Select the ninth Window, not the last one |
| `select_next_window` | Unbound | Select the next Window, wrapping to the first |
| `select_prev_window` | Unbound | Select the previous Window, wrapping to the last |
| `select_next_topic_window` | Unbound | Select the next Window of the Active Topic, wrapping to the first. In Topics mode, every Window of the Active Topic's Sessions takes part, in the order the Sidebar shows them; for No Topic, the Windows of the No Topic Sessions. In Sessions mode, only the current Session's Windows take part |
| `select_prev_topic_window` | Unbound | Select the previous Window of the Active Topic, wrapping to the last |

While the Browser has Focus, the keys of `select_next_window`,
`select_prev_window`, `select_next_topic_window` and `select_prev_topic_window`
select the next or previous Tab, so Windows and Tabs share their step keys.

| Action | Default shortcuts | What it does |
| --- | --- | --- |
| `select_next_session` | Unbound | Go to the next Session the Sidebar shows, wrapping to the first. In Topics mode, only the Active Topic's Sessions take part; for No Topic, the No Topic Sessions |
| `select_prev_session` | Unbound | Go to the previous Session the Sidebar shows, wrapping to the last. In Topics mode, only the Active Topic's Sessions take part |
| `select_next_topic` | Unbound | Go to the Topic below in the Topics list, wrapping to the first. Locked Sessions take part in their place; No Topic, Snoozed Topics and Benched cards that do not show do not. A Dormant Topic is Reopened. Works in both Sidebar modes |
| `select_prev_topic` | Unbound | Go to the Topic above in the Topics list, wrapping to the last |

The default [Command Palettes](configuration.md#command-palettes) are
**Commands** on ⌘⇧P and **Go to…** on ⌘P. `open_switcher` is gone.
A Config that still names it shows a problem.

Commands lists Mark Read and Mark Unread for the current Window, or only its
Zoomed Pane when Zoom is on. Mark Read requires an Unread Agent in that target.
Mark Unread requires a read Agent with done, failed or blocked Status. On an
Empty Topic page, both Commands act on the Topic mark, with or without Agents.
The Command Summary names the target. Explicit palette row Actions still use
the named Topic, Session, Window or Agent.
Mark All as Read clears all Topic and Agent Unread marks in the Active Environment
and appears when either kind of mark is set.

Commands also lists Move Pane, Move Window, Move Session, Move Pane with Active
Tab, Add a Session, Snooze Topic, Settle Topic, Lock Session or Unlock Session, and Zen
or End Zen. These use the
current item and appear when that item is available. Back returns from an input
step to the Commands search.

Commands also lists Move Topic Up and Move Topic Down, Pin Topic or Unpin Topic,
and Unsnooze Topic. They run at once on the Active Topic, as their keybindings
do. Move Topic Up and Move Topic Down also move the card of the current Locked
Session, and appear only when the card can move that way among the cards with
its Pin. Unsnooze Topic appears while a Snoozed Topic exists. While the Active
Topic is Snoozed, it Unsnoozes it at once. Else it lists the Snoozed Topics, and
↩ Unsnoozes the highlighted one.

Commands also lists Set Topic Note, and Clear Topic Note while the Active Topic
has a Topic Note. Set Topic Note opens one field that starts with the current
Note. ↩ writes the Note, and ↩ on an empty field clears it. ⎋ changes nothing.
Clear Topic Note runs at once. The actions menu of a Topic row has both, and
the context menu of a Topic card has Set Topic Note… and Clear Topic Note.

Commands also lists Snooze Topics…, which Snoozes several Topics until one time.
Its first step is the check step. The rows are the Tags of the Topics under
Tags, in Config order, the Topics in the Topics list under Topics, and the
Snoozed Topics under Already Snoozed. Each row has a box. No Topic starts
checked, also not the Active Topic. The search field holds only the query.

- Space or ⇥ checks or unchecks the highlighted row, also with a query. So the
  query of this step cannot hold a space. A click on a row does the same.
- ⌘A checks every Topic row that the filter shows, or unchecks them when all of
  them are already checked.
- A Tag row checks or unchecks the Topics that have the Tag in this list: with
  none or some checked, Space checks all of them, and with all checked, Space
  unchecks all of them. Its box shows none, some or all, in the colour of the
  Tag, and the row shows "2/3" while some are checked. Only Topics are in the
  set: a Topic that gets the Tag later is not Snoozed.
- With one or more Topics checked, ↩ on any row opens the time step with the
  checked Topics. With none checked, ↩ on a Topic row opens it with that Topic,
  and ↩ on a Tag row checks its Topics and stays in the check step.
- The note under the list names the checked Topics, counts the checked Topics
  that the filter hides, and says what ↩ does now.

The time that you choose replaces the time of each Topic of the set, also a
later time, and the step note names each Snooze that becomes shorter. ⌫ in the
empty time field goes back to the check step with the checks kept. Snooze Topic
is the same flow with its Topic checked, and it starts at the time step.

Commands also lists Unsnooze Topics… while a Snoozed Topic exists. It opens the
same check step with only the Snoozed Topics, and each row shows its wake time.
A Tag row counts only the Snoozed Topics. ↩ works as in Snooze Topics…, but it
Unsnoozes the Topics at once, with no time step.

In a field with chips (New Topic and Edit Tags), ← at the start
of the text selects the last chip, and ← and → move the selection. → after the
last chip puts the caret back in the text. ⌫ removes the selected chip and
selects the chip to its left, and ⌦ removes it and selects the chip to its
right. A letter puts the caret back and types. ⌫ in an empty field removes the
last chip.

A word that starts with `#` in the query of Snooze Topics or of a palette with
the topics Source, such as Go to…, matches the Tags of the Topics, not the words
in their titles. Each Topic row shows its Tags, also with no query. With a
query, Go to… also lists the Tags after the Topics. ↩ on
a Tag row makes it a filter chip, "Go to… › #backend", and the list then shows
only the Topics with the Tag: open, Snoozed and Settled. ⌫ in the empty field
removes the chip. ⌘K on a Tag row offers Snooze its Topics…, which opens the
check step with the Topics of the Tag checked.

Only the Tags that the Config lists in `topics.tags` exist (see
[Tags](configuration.md#tags)). In New Topic, a word that starts with `#` is a
Tag, not a part of the title. While you type it, the rows show the Tags of the
Config that match it by name or display name, in Config order. When none
matches, a row says so, the word cannot become a chip, and ↩ does nothing
while it is in the field. ⇥ or ↩ on a row makes the Tag a chip. A space after
a complete Tag also makes it a chip, so you can type `#backend ` and go on.
Without `topics.tags`, `#` is plain title text and Edit Tags… is not offered. ⌫ in an empty field removes the last chip. Commands also lists Edit Tags…
for the Active Topic, and the actions menu of a Topic row has it too. Its field
holds the Topic's Tags as chips. Type a Tag, with or without `#`, to add it.
↩ writes the Tags, and an empty field removes all of them.

Commands also lists Show Next Session, Show Previous Session, Show Next Topic
and Show Previous Topic. They do what `select_next_session`,
`select_prev_session`, `select_next_topic` and `select_prev_topic` do: Show Next
Topic goes to the Topic below in the Topics list. Each row shows its configured
shortcut.

Commands also lists the layout and Focus actions: Maximize or Restore, Maximize
Terminal, Maximize Browser, Focus Terminal, Focus Browser, and Show or Hide for
the Sidebar, the Terminal and the Browser, and Toggle Bench while the Topics list has a Bench line. Each row shows its configured shortcut.
Zoom Pane runs at once on the current Pane, as `toggle_zoom_pane` does.
A row appears only when its action can change something.

Move opens for a Pane with ⌘⇧T (while the Browser does not have Focus), a Window with `move_window` or a Session with ⌘⇧M.
Its Pane, Window and Session buttons select what moves. For a Pane or Window,
New Topic is the first row. A Pane can also move to a New Window. The ＋ Tab
button includes the active Browser Tab and keeps its history. A Topic that cannot accept the move shows
the reason. Move does nothing while `sidebar.topics` is off.

Every Action uses the palette's view, including Actions from Sidebar and menu
bar items. ⎋ closes without a change, after it hides the actions menu if that
shows. ⌫ in an empty field goes back one step.
At the first step it does nothing, so only ⎋ closes a palette.
A step that kills a process needs ⌘↩ to confirm.

Maximize never changes the toggles. On Restore, the Window shows what its
toggles say. While the Window is Maximized, the Maximized side's toggle has an
accent capsule, and the toggle of a side that Maximize hides shows its own state,
dimmed. A Sidebar, Terminal or Browser toggle used while the Window is
Maximized first keeps what is on screen, then restores the Window and applies.
Maximize of a side that is already alone, with the Sidebar hidden, has nothing to
hide and does nothing. Each Window keeps its own Maximize state: the Sidebar shows
again in a Window that is not Maximized. ⇧⌘↩ is also Ghostty's default for
`toggle_split_zoom`. Muxify's binding takes precedence, so Zoom of a Pane has its
own key, ⌘M (`toggle_zoom_pane`).

Focus is where keyboard input goes: the Terminal, the Browser or a Command
Palette. `focus_terminal`, `focus_browser` and `toggle_focus` move Focus only.
They never Maximize a side.

All tmux Window navigation stays within the focused App Window's current Session
and follows sidebar order, not tmux's window indices.
Switching Windows also restores that Window's Browser and moves Focus to
its Terminal, or to its Browser when its Terminal is hidden. If a
numbered position does not exist, the shortcut does nothing.

Use **Muxify → Open Config** to open `~/.config/muxify/config.yaml` (or
`$XDG_CONFIG_HOME/muxify/config.yaml`). This example lists every configurable
action, keeps the default bindings, and assigns optional next/previous shortcuts:

```yaml
keybindings:
  new_app_window: cmd+n
  new_topic: []
  move_pane: cmd+shift+t
  move_window: []
  move_session: cmd+shift+m
  add_session_to_topic: cmd+shift+a
  snooze_topic: alt+cmd+s
  snooze_topics: []
  toggle_zen: shift+alt+cmd+s
  settle_topic: []
  remove_session_from_topic: []
  forget_topic: []
  rename_topic: []
  set_topic_note: []
  toggle_lock: []
  move_topic_up: alt+cmd+up
  move_topic_down: alt+cmd+down
  toggle_pin_topic: []
  unsnooze_topic: []
  unsnooze_topics: []
  toggle_sidebar: [cmd+s, ctrl+cmd+s]
  toggle_bench: shift+cmd+s
  toggle_terminal: cmd+j
  toggle_browser: cmd+b
  toggle_git_view: cmd+g
  toggle_maximize: shift+cmd+enter
  toggle_maximize_terminal: alt+cmd+j
  toggle_maximize_browser: alt+cmd+b
  focus_terminal: [cmd+shift+j, ctrl+backquote, ctrl+0, alt+0]
  focus_browser: cmd+shift+b
  toggle_focus: cmd+0
  select_card_1: ctrl+1
  select_card_2: ctrl+2
  select_card_3: ctrl+3
  select_card_4: ctrl+4
  select_card_5: ctrl+5
  select_card_6: ctrl+6
  select_card_7: ctrl+7
  select_card_8: ctrl+8
  select_card_9: ctrl+9
  select_tab_1: alt+1
  select_tab_2: alt+2
  select_tab_3: alt+3
  select_tab_4: alt+4
  select_tab_5: alt+5
  select_tab_6: alt+6
  select_tab_7: alt+7
  select_tab_8: alt+8
  select_tab_9: alt+9

  select_window_1: cmd+1
  select_window_2: cmd+2
  select_window_3: cmd+3
  select_window_4: cmd+4
  select_window_5: cmd+5
  select_window_6: cmd+6
  select_window_7: cmd+7
  select_window_8: cmd+8
  select_window_9: cmd+9
  # These actions are unbound by default.
  select_next_window: ctrl+cmd+right
  select_prev_window: ctrl+cmd+left
  select_next_topic_window: cmd+right_bracket
  select_prev_topic_window: cmd+left_bracket
  select_next_session: ctrl+cmd+down
  select_prev_session: ctrl+cmd+up
  select_next_topic: ctrl+alt+cmd+down
  select_prev_topic: ctrl+alt+cmd+up
```

Triggers use Ghostty-style names: `cmd`, `ctrl`, `alt` (Option), and `shift`,
followed by a character or a named key such as `left`, `right`, `tab`, or
`left_bracket`. An action accepts one trigger or a list, such as
`select_window_2: [cmd+2, ctrl+cmd+2]`. A character names the key that types
it with ⌘ held on the current keyboard layout, as menu shortcuts do. So on a
non-Latin layout such as Russian, `cmd+p` is still the key labelled P, and
`cmd+shift+1` is the 1 key, not `!`.

Actions not listed keep their defaults. Naming an action replaces its defaults;
`[]` disables it (for example, `select_window_9: []`). A trigger explicitly
assigned to an action is removed from other actions' defaults. If two actions
explicitly claim the same trigger, the first keeps it and Muxify reports the
conflict. Muxify reloads the Config when it changes. Its bindings take precedence
over Ghostty and Browser page bindings, but only inside Muxify—not while another
app is active.

To change New App Window, use `new_app_window: cmd+shift+n`; use
`new_app_window: []` to disable its shortcuts. This also removes the terminal's
default ⌘N behavior. New tmux Session remains available from the File menu.

Focus Terminal defaults to Command + Shift + J, Control + backquote, Control + 0
and Option + 0. This leaves Command + backquote for macOS App Window switching.
Use `focus_terminal: []` to disable it, or `focus_terminal: cmd+backquote` to
use that key instead. Then macOS App Window switching does not work.

The old names `move_keyboard_to_terminal`, `new_topic_from_pane`,
`move_session_to_topic` and `zen_mode` are gone. A Config that names one shows a
problem that names the new action. `focus_terminal`, `focus_browser` and
`toggle_focus` keep their names with a new meaning. A Config that binds them
changes behavior and shows no problem. `toggle_focus` was the old name of
`toggle_maximize`.

## Hints

Cards and Tabs show a key-only Hint at rest. Window rows can show one too.
The rest Hint uses the first trigger with the usual modifiers for that item.
For example, `ctrl+j` shows `J` on a card. Positions above 9 have no Hint.
A loading Tab shows its spinner instead of the rest Hint.

Hold a modifier alone to show the full trigger. The default delay is 0.35 seconds.
[Hints Config](configuration.md#hints) controls the delay and each item's rest and hold Hints.
Pressing the configured key acts at once, even before the Hints appear.
Each Hint shows the trigger from the current Config. Its modifiers must match exactly.
For example, holding Control does not show a shortcut that needs Control and Command.
Letter remaps and multiple triggers appear as configured. Terminal Hints show numeric triggers only.

Card positions follow Pinned Topics, then other open Topics. No Topic Sessions have no position.
In Sessions mode, they follow the Session cards. The Agents section has no Hints.
Jump To a Dormant Topic Reopens it when it remembers a Session, and shows its empty Topic view when it does not.
Window positions stay within the current Session. Tab positions follow the Browser strip.
A missing position does nothing.

A hidden Sidebar still accepts card shortcuts, but shows no Hints.
A hidden Browser shows no Tab Hints, but a Tab shortcut shows the Browser and selects the Tab.
Only rendered cards and Window rows show Hints. A Pane row never takes a Window Hint.
A held card Hint hides its Pin mark. A rest Hint leaves the Pin mark visible.
A held Hint replaces the rest key in the leading slot. Tabs dim while held Hints stay at full opacity. Cards and the Terminal do not dim.

Any other key or modifier release clears held Hints. Rest Hints stay visible. After another key, release all modifiers before a new hold.
Opening a palette, changing the Environment, or leaving the App Window also clears held Hints.
Each App Window has its own hold state.

## Command Palette keybindings

A [Command Palette](configuration.md#command-palettes)'s own `keybinding` is
set on the palette and follows the rules above. While a palette is open, these
actions win over every other keybinding. They are configured under
`keybindings.command_palette`, with the same rules among themselves, and never
conflict with the actions above:

| Action | Default shortcuts | What it does |
| --- | --- | --- |
| `jump_to` | Enter | Jump to the highlighted result, or run the highlighted action |
| `new_session` | ⌘Enter | Start another Session from the highlighted Session or Session Path, keeping its Topic or No Topic scope, and switch to it |
| `select_next` | Down, ⌃J | Highlight the next result or action |
| `select_prev` | Up, ⌃K | Highlight the previous result or action |
| `show_actions` | ⌘K | Show or hide the actions menu. ⎋ also hides it, and keeps the palette open |
| `copy_folder` | ⌘C | Copy the result's folder |
| `copy_tmux_target` | ⌘⇧C | Copy the result's tmux target or Pane ID |
| `paste_folder` | ⌃Y | Type the result's folder where the Focus was: into the text field or web page that had it, or as one shell word at the prompt of the current Pane |
| `snooze_topic` | ⌃S | Open Snooze for the highlighted open, Dormant or Snoozed Topic |
| `move` | Unbound | Open Move for the highlighted result |
| `add_session_to_topic` | Unbound | Add a running Session or launch a new one in the highlighted Topic |
| `rename` | Unbound | Rename the highlighted Topic, Session or Window |
| `edit_tags` | Unbound | Open Edit Tags for the highlighted Topic |
| `set_topic_note` | Unbound | Open Set Topic Note for the highlighted Topic |
| `clear_topic_note` | Unbound | Clear the Topic Note of the highlighted Topic. The action shows only while the Topic has a Note |
| `start_zen` | Unbound | Start Zen for the highlighted Topic. While Zen is on, end it |
| `settle_topic` | Unbound | Settle the highlighted Topic |
| `forget_topic` | Unbound | Forget the highlighted Topic |
| `unsnooze_topic` | Unbound | Unsnooze the highlighted Topic |
| `reopen_topic` | Unbound | Reopen the highlighted Topic |
| `start_topic_fresh` | Unbound | Start Fresh for the highlighted Topic |
| `pin_topic` | Unbound | Pin the highlighted Topic |
| `unpin_topic` | Unbound | Unpin the highlighted Topic |
| `remove_from_topic` | Unbound | Remove the highlighted Session or Window from its Topic |
| `remove_from_topic_and_kill` | Unbound | Confirm a removal of the highlighted Session from its Topic and a kill of it |
| `new_window` | Unbound | Create a Window in the highlighted Session |
| `reveal_folder` | Unbound | Show the result's folder in Finder |
| `kill_window` | Unbound | Confirm a kill of the highlighted Window |
| `kill_session` | Unbound | Confirm a kill of the highlighted Session |
| `lock_session` | Unbound | Lock the highlighted Session, which must be in No Topic |
| `unlock_session` | Unbound | Unlock the highlighted Session |
| `choose_pane` | ⌥1 | Select the Pane button in Move |
| `choose_window` | ⌥2 | Select the Window button in Move |
| `choose_session` | ⌥3 | Select the Session button in Move |
| `toggle_include_tab` | ⌥T | Turn the ＋ Tab button on or off in Move |
| `toggle_new_worktree` | ⌥W | Turn the New Worktree option on or off when available |

```yaml
keybindings:
  command_palette:
    jump_to: enter
    select_next: [down, ctrl+j, ctrl+n]
    copy_tmux_target: []
```

Removed action names are not compatibility aliases. Unknown keys are reported
as Config problems.

⎋ and ⌘1–⌘5 (the Source buttons) are not configurable. With no results, ⌘C
copies the search text.

## Find bar keybindings

While the field of [Find in Pane](#find-in-pane) or Find in Page has Focus,
these actions win over every other keybinding. They are configured under
`keybindings.find`, with the same rules among themselves, and never conflict
with the actions above. `find_in_pane` and `find_in_page` open the bars.

| Action | Default shortcuts | What it does |
| --- | --- | --- |
| `next` | Enter | Go to the next match. In a Pane, that is up, in older output |
| `prev` | ⇧Enter | Go to the previous match. In a Pane, that is down, in newer output |
| `close` | Escape | Close the find bar and focus the Terminal or the page. In the Terminal, the key goes on to the active Pane, and it also closes Find in Pane when that Pane is the searched one |

```yaml
keybindings:
  find:
    next: [enter, ctrl+n]
    prev: [shift+enter, ctrl+p]
```

## Git View keys

While the [Git View](configuration.md#git-view) has focus, it uses keys like
lazygit's. They are not configurable, and keys it doesn't use, such as ⌘B or ⌘1,
go on to the actions above.

| Keys | What they do |
| --- | --- |
| 1–4 | Go to Changes, History, Branches or Stashes, as you left it; the Git View tab shown goes back to its own list |
| Tab / ⇧Tab | Next or previous Git View tab |
| j / k, ↓ / ↑ | Select the next or previous item; in the diff, the next or previous line |
| < / > | First or last item; in the diff, the first or last line |
| ↩ | On a folder, fold or open it; on a branch, go into its commits, or while comparing, into its Diff files; on a commit or stash, go into its Diff files; otherwise go to the diff |
| Space | In Changes, stage the file or folder, or unstage it once all of it is staged; on the `/` row, which holds the whole tree when more than one file or folder is on top, everything; in a change's diff, stage the selected lines, or the cursor's, or unstage them in its Staged part; in Diff files, fold or open a folder; in Stashes, apply the selected stash after confirming, and it stays; in Branches, check out the selected branch, and on the branch you're on do nothing; in History and in a branch's commits, check out the selected commit, which leaves a detached HEAD |
| - / = | Fold or open every folder of the list, in Changes the `/` row too; in Branches, - checks out the previous branch, as `git checkout -` does |
| l / h, → / ← | Go to the diff (on a branch, into its commits), or back to the list; from a list you went into, back out |
| ⇧↓ / ⇧↑ | Select one more line below or above |
| v | Start or end a range: moving then selects lines, as in lazygit |
| a | In the diff, select the hunk; in Changes, stage everything, or unstage it all once it all is |
| A | In Changes, amend the last commit with what's staged, keeping its message. It asks first, "Are you sure you want to amend the last commit?"; y confirms and ⎋ cancels. Hooks and signing run as they do for c, and a failure shows what they said. With nothing staged, with no commit yet, or during a merge, rebase, cherry-pick, revert or `git am`, the banner says why it can't. A commit that is already pushed can be amended; the next P then asks to force push |
| m | In every tab, while a merge, rebase, cherry-pick, revert or `git am` is in progress: a menu with c (continue), s (skip; not for a merge) and a (abort), through the Agent guard. Continue and skip run without an editor and keep git's message; while conflicts remain, git refuses and the banner says why. After staging the last conflicted file, the Git View asks "All merge conflicts resolved. Continue the rebase?": ↩ continues, ⎋ leaves it for later. With nothing in progress, the banner says so |
| M | In Branches, on a branch other than the one you're on: lazygit's merge menu, "Merge 'X' into 'Y'", through the Agent guard. f is a regular merge (fast-forward when it can, else a merge commit), n a regular merge with a merge commit (`--no-ff`), s a squash merge that commits with git's message, and u a squash merge that leaves the changes staged. No editor opens. A merge that conflicts stays in progress with its conflicts in Changes: c concludes it, and m continues or aborts it. On the current branch, the banner says a branch can't be merged into itself |
| r | In Branches, on a branch other than the one you're on: lazygit's rebase menu, "Rebase 'Y'", through the Agent guard, with one choice, s, "Simple rebase onto 'X'" (`git rebase X`; no editor opens). A rebase that conflicts stops with its conflicts in Changes: staging the last one asks to continue, and m continues, skips or aborts it. Commits that were already pushed can be rebased; the next push then asks to force push. On the current branch, the banner says a branch can't be rebased onto itself |
| C | In History and a branch's commits, copy the selected commit to cherry-pick it, or take it out again if it is copied, as lazygit's cherry-pick does. Copied commits show a "copied" mark on their rows in every commit list, and the toolbar says how many are copied. They belong to the repository, not to the Window: copy in the Git View of one Worktree and they show in, and can be pasted from, the Git View of every Window in any Worktree of the same repository, but not in another repository's. They are kept while Muxify runs and are not saved |
| c | In Changes and in a change's diff, commit what's staged, once something is, or conclude a merge: write a summary and a description, then ↩ in the summary or ⌘↩; ⎋ keeps the message for later. In Branches, check out by name: type a name, and the local and remote branches that match are offered; ↓ / ↑ choose one, ↩ checks out the chosen or the typed name, and a remote branch such as `origin/foo` makes a local branch that tracks it. In History and Stashes, c does nothing |
| d | In Changes, discard the file's or folder's changes, as in lazygit: x (or ↩) discards all of them, u only the unstaged ones when some are staged; new and untracked files are deleted. In a change's diff, discard the selected unstaged lines, or the cursor's, with x (or ↩). j / k move between the choices; ⎋ or q cancels; in Stashes, drop the selected stash after confirming; in Branches, open the delete menu for the selected branch: c deletes the local branch, asking to force when git finds it not fully merged (a branch you're on or another Worktree has checked out is never deleted); a branch with an upstream also offers r, delete the remote branch, and b, delete the local and remote branch, each after confirming |
| D | In Changes, open lazygit's reset options for the whole working tree: x nukes it (tracked files back to the last commit, new and untracked files deleted), u discards the unstaged changes of tracked files, c deletes the untracked files, S discards the staged changes, from the files too (git 2.35 or newer), and s, m and h reset softly, mixed or hard to the last commit. Each runs at once and can't be undone; the menu names any Agent working in the Worktree. A choice with nothing to do is dimmed, and with a clean working tree the banner says so and nothing opens |
| f | In Changes, fetch all remotes, as `git fetch --all`. It runs beside staging and committing, and the toolbar shows "Fetching…" until it ends. When git or ssh asks for a password, passphrase, PIN, token, username or an unknown host, a prompt asks it, hiding what you type for a secret: ↩ answers, ⎋ stops the fetch |
| g | In Stashes, pop the selected stash after confirming: it is applied and dropped. When applying conflicts, the conflicted files show in Changes, the banner says so, and the stash stays. In History, a branch's commits and Branches, open lazygit's Reset menu, "Reset to X", which moves the branch you're on to the selected commit or branch: s keeps the changes between them as staged changes, m as unstaged changes, and h discards them and all current Changes. Each choice shows a note. s and m run at once; h with Changes asks once more, "Discard N files and reset", and goes through the Agent guard in that menu (untracked files stay, so they aren't counted). h with no Changes also goes through the guard. Afterwards the lists show the new HEAD |
| p | Pull the branch you're on, in every tab, following your git config, such as `pull.rebase`. It waits in the write queue, goes through the Agent guard, and the toolbar shows "Pulling…" until it ends. Without an upstream it asks for one, as P does, and sets it. A pull that conflicts leaves the merge or rebase in progress, with the conflicted files in Changes, and the banner says so. Credential questions are asked as for f. A detached HEAD can't pull, and the banner says so |
| s | In Changes, stash all changes, as `git stash push`: type the stash's message (it may be empty), then ↩; ⎋ cancels. Untracked files stay. Nothing to stash is said, and nothing opens |
| S | In Changes, open lazygit's stash options: a all changes, U all changes including untracked files, s staged changes, u unstaged changes, i all changes and keep index; each then asks for the message. j / k move between the choices; ⎋ or q cancels |
| y, ⌘C | Copy the selected code, without + and −; in the list, the path, hash or branch |
| J / K, ⌃D / ⌃U | Scroll the diff by three lines, or half a page |
| ⌥↓ / ⌥↑ | Next or previous hunk |
| ] / [ | Next or previous file: the next file in Changes or Diff files, or the next file in a commit's, stash's or comparison's diff |
| / | Filter the list shown; ↓ / ↑ move through the matches, ↩ or ⎋ go back to the list |
| e | Open the file in your editor (`git_view.editor`) in a new tmux Window, at the cursor's line in the diff, or at the first changed line of a change or Diff files file; a removed line opens at the new line beside it |
| n | In Branches, create a branch off the selected one and check it out: type its name, then ↩ |
| o | In History and in a branch's commits, open the selected commit's page as a Tab in the Window's Browser, with Focus on the page: `https://<web domain>/<owner>/<repo>/commit/<full hash>`, also while a Base is marked. The repository is the one `origin` points to, or the only remote when there is no `origin`; with neither, the banner says "There is no 'origin' remote". The commit opens even when it isn't on the remote. In Branches, open the selected branch's "create pull request" page as a Tab in the Window's Browser, with Focus on the page: `https://<web domain>/<owner>/<repo>/compare/<upstream branch>?expand=1`, for the branch you're on or any other. The repository is the one the branch's upstream remote points to (`git_view.services` names other hosts). Nothing is checked first: not that the branch is pushed, nor that a pull request exists. A popup Git View closes; a fullscreen one stays open. A branch with no upstream, or a host no service claims, says so in the banner and opens nothing. In Changes, a change's diff, Diff files and Stashes, `o` does nothing |
| P | Push the branch you're on, in every tab, beside staging and committing: the toolbar shows "Pushing…" until it ends. Without an upstream, a prompt asks "Enter upstream as '<remote> <branch>'", starting at `origin <branch>`, and the push sets it. When the upstream has commits the branch doesn't, a menu asks "Your branch has diverged from the remote branch. Press ⎋ to cancel, or ↩ to force push."; ↩ pushes with `--force-with-lease`. Credential questions are asked as for f, and a rejection shows git's message. A detached HEAD can't push, and the banner says so |
| R | Read the repository again; in Branches, rename the selected branch: the prompt starts at its name |
| ⌃R | Clear the Copied commits of the repository, in every Window's Git View |
| V | In History, cherry-pick the Copied commits onto the branch you're on, oldest first, after asking "Are you sure you want to cherry-pick the N copied commit(s) onto this branch?"; y confirms and ⎋ cancels, and the menu names any Agent working in the Worktree (the Agent guard). When it succeeds the Copied commits are cleared. A pick that conflicts stops with the conflicts in Changes and the banner says so; m continues, skips or aborts it, and the Copied commits stay. With nothing copied, the banner says so; while a merge, rebase or the like is in progress, it asks you to continue or abort it first |
| W | Mark the selected commit, branch or stash as the base: every other commit, branch or stash selected then shows the diff from the base to it, as lazygit's diffing mode. W on another one moves the base there; W on the base ends the comparison |
| ⎋ | Clear the selected range, leave the diff, clear the filter, go back out of Diff files or a branch's commits, end the comparison, then close the Git View |
| q | Close the Git View |

Clicking selects an item; on a branch, it goes into the branch's commits, and on a
file of the Diff files, into the files. A folder's chevron folds it, and a click
on a Git View tab goes to it. In the diff, dragging over code selects it by
the character, a double click selects a word, and a triple click or the line
numbers select whole lines; shift-click extends the selection. In a split diff,
the selection is on the side you click. A commit's hash chip copies the full
hash.

## Built-in shortcuts
## Built-in shortcuts

These shortcuts are not configurable as actions in Muxify's `keybindings`
section. Configured Muxify bindings still take precedence over them. When the
terminal has Focus, Ghostty bindings can take precedence over menu shortcuts.

| Shortcut | Action |
| --- | --- |
| ⌘ + backquote / ⌘⇧ + backquote | Cycle App Windows forward / backward (macOS) |
| ⌘⇧, | Reload the Muxify Config and Ghostty config |

**Browser shortcuts** apply when the Browser has Focus. Menu clicks work even
when it does not. New Tab and Open Location can reveal a hidden Browser:

| Shortcut | Action |
| --- | --- |
| ⌘T | Open a new Browser Tab |
| ⌘-click (link) | Open the link in a new Browser Tab |
| ⌘L | Move Focus to the address bar, opening the Browser if hidden |
| ⌘W | Close the active Browser Tab (`close_tab`) |
| ⌘⇧T | Open the last closed Tab again (`reopen_closed_tab`) |
| ⌘⇧] or ⌃Tab | Select the next Browser Tab (`select_next_tab`) |
| ⌘⇧[ or ⌃⇧Tab | Select the previous Browser Tab (`select_prev_tab`) |
| ⌘[ | Go back (`browser_back`) |
| ⌘] | Go forward (`browser_forward`) |
| ⌘R | Reload the page, or stop it while loading |
| ⌘⇧C | Copy the active Browser Tab's current URL and show a “Copied URL” confirmation |
| ⌘⌥I | Open or focus Developer Tools for the active Browser Tab |
| ⌘F | Open Find in Page above the page, and select the text in its field (`find_in_page`) |
| Enter (address bar) | Navigate to the entered URL or search |
| Escape (address bar) | Restore the current URL and focus the page |
| Enter / ⇧Enter (Find in Page) | Go to the next / previous match ([find bar keybindings](#find-bar-keybindings)) |
| Escape (Find in Page) | Close Find in Page, remove the highlight and focus the page ([find bar keybindings](#find-bar-keybindings)) |

The Tab and history keys above are the defaults of their actions, and the Config
can change them. ⌘W never closes the Muxify app window. While the Terminal has
Focus, it goes on to Ghostty, so a Ghostty `cmd+w` keybind, such as one that
closes a tmux Pane, works. With other Focus, such as the Git View, it does nothing.

Find in Page highlights every match in the page and shows the number of the
current match, for example “3 of 7”. Each Tab keeps its own query while the Tab
is open. Find in Page also searches the text in
iframes. A new query starts in the frame that you last clicked, scrolled or
typed in. Before that, it starts in the frame that shows the most of the page. In the Terminal, ⌘F opens
[Find in Pane](#find-in-pane).

### Find in Pane

⌘F (`find_in_pane`) in the Terminal opens a find bar over the Terminal's top
right corner. It searches the history of the current Window's active Pane through
tmux copy mode: tmux highlights every match and scrolls the Pane to the current
one. The bar shows the number of the current match, counted from the newest
output, for example “1 of 7”. A query ignores case unless it has a capital letter.

| Key | Action |
| --- | --- |
| ⌘F | Open Find in Pane, or select its query while it is open (`find_in_pane`) |
| ↩ (in the field) | Go to the next match up, in older output (`find.next`) |
| ⇧↩ (in the field) | Go to the previous match down, in newer output (`find.prev`) |
| Esc | Close Find in Pane, leave copy mode and focus the Terminal (`find.close`). In the Terminal, only while the searched Pane is the active one |
| ‹ / › / Done | Go to the previous / next match, or close Find in Pane |

↩ and ⇧↩ act only while the find field has Focus. Esc in the find field closes
Find in Pane. In the Terminal, Esc goes to the active Pane as usual, and it also
closes Find in Pane when that Pane is the searched one. After you select another
Pane, Esc is that Pane's key, and the bar stays. Every other key, such as ⌘G for
the Git View, keeps its usual action. The [find bar keybindings](#find-bar-keybindings) change these keys. Ghostty's
`start_search` keybind also opens Find in Pane. While the Pane is in copy mode,
keys typed in the Terminal are copy mode keys, as usual in tmux: `q` leaves copy
mode, and the next step enters it again. Going to another Window closes the bar.

### Vim Keys

When the Browser has Focus, these keys scroll the page or go through its history:

| Key | Acts as | Scroll |
| --- | --- | --- |
| j / k | ↓ / ↑ | Down / up one step |
| h / l | ← / → | Left / right one step |
| d / u | Page Down / Page Up | Down / up almost one screen |
| gg | Home | To the top |
| G | End | To the bottom |
| H / L | Back / Forward | Previous / next page in the Tab's history |

A Vim Key presses the key in the "Acts as" column. The page scrolls the same
part, by the same step and with the same animation as for that key. Hold j to
scroll until you release it. H and L go one page for each press, also when you
hold them.

- The page wins. If the page uses the key itself, Vim Keys do nothing.
- Text fields type. In a text field or other editable text, the key types its
  letter.
- Modifiers pass through. A key with ⌘, ⌃ or ⌥ is not a Vim Key.

To turn Vim Keys off, set `browser.vim_keys` to `false` in the
[Config](configuration.md#browser-and-keybindings).

Developer Tools are also available from **Browser → Show Developer Tools**,
the Browser's **⋯** menu, or **Inspect Element** in a page's right-click menu.
They inspect the existing Tab, with its current cookies, DOM and JavaScript
state, and close when that Tab closes. Opening the in-app WebKit inspector is
best-effort because it uses runtime-checked private APIs; if unavailable, inspect
Muxify's Tab from Safari's Develop menu instead.

Other terminal keybindings come from your Ghostty config and tmux bindings,
not the Muxify Config.
