"""The areas of the compare run (compare.py), their scenes, and the fixture helpers that scenes share.

An area is a part of the app with two versions while it moves from SwiftUI to AppKit
(docs/adr/0075-muxify-leaves-swiftui-entirely-one-area-at-a-time.md). `Area` names the list whose rows the gate
compares, the user default that chooses the version, how the run asks the driver which version shows, and the area's
scenes. AREAS lists the areas that have two versions now. An area leaves it when the user signs it off and its
SwiftUI version is deleted. The Sessions list was the first area; its scenes are in the git history before its
SwiftUI version was deleted.

A scene has a `name` for `make compare SCENE=`, a line `shows` for the report, a `fixture` and its `shots`:

- `fixture(s)` makes what the scene needs in its Sandbox before the app starts: tmux Sessions, Topic records, folders.
  It runs once, for both versions.
- `shots()` gives (name, arrange) pairs, in their order. The run calls `arrange(view)` for one version of the area
  (`View` in compare.py), then takes the picture and the dump of that shot. It calls every arrange again for the
  other version, so an arrange leaves tmux as it found it, or sets it again. The first arrange starts the app with
  `view.launch(config)`; a later one starts it again when the shot needs another Config. No arrange waits for a
  Config reload: the app reads the Config as it starts.

An arrange reaches a state only through tmux, the Config and the driver commands that take no focus. When one version
cannot show a shot, the arrange fails there and says what it does not show; the run still measures.

Both versions must start a shot from the same state, or `make compare SELF=1` finds a difference that is the scene's
own. So an arrange sets again what an earlier shot changed, such as a bell, and calls `view.rest()` before a step
that starts from where the list stands, such as a swipe or a hover.

To add a scene, write a class like the pilot's, add it to its area's `scenes`, and add its section to
compare-notes.md.
"""

import re
from typing import Callable, NamedTuple

from scripts.verify.sandbox import wait

SHELL = '/bin/zsh -f'
# What the Pane of an Agent runs. A Pane at a plain shell runs no Agent (`Agent.runs` in MuxifyCore), so the list shows
# no mark for it.
AGENT_PROGRAM = 'sleep 3600'


class Area(NamedTuple):
    """A part of the app with two versions. `name` is for `make compare AREA=`, and `title` names its list in the
    output and the report, such as 'Topics list'. `list` is the identifier of the element whose rows the gate
    compares. `default` is the user default that chooses the version: YES is the AppKit version, NO the SwiftUI one.
    `args` are the launch arguments every scene starts the app with, besides the default. `shown(sandbox)` answers
    which version the App Window shows, 'appkit' or 'swiftui', as the driver says it. `scenes` are its scenes, in
    their order."""
    name: str
    title: str
    list: str
    default: str
    args: list
    shown: Callable
    scenes: list


# The areas that have two versions now. None: the Sessions list was signed off and its SwiftUI version deleted.
AREAS = []


def config(sidebar='', ui='', more=''):
    """The Config of a scene. Every scene has no Agents section, only the Location's card open, and Working marks
    that stand still. `sidebar` and `ui` are more lines of these sections, each indented by two spaces; `more` is
    other sections."""
    return 'sidebar:\n  agents: false\n  session_cards: one\n%sui:\n  pulse: false\n%s%s' % (sidebar, ui, more)


def project(s):
    """The folder of the scene's Sessions, so no title or path in the list depends on where the run started."""
    folder = s.root/'project'
    folder.mkdir(exist_ok=True)
    return folder


def session(s, name, windows=('main',), folder=None):
    """A Session with a Window for each name. Returns (Session id, list of Window ids)."""
    folder = str(folder or project(s))
    found = s.tmux('new-session', '-d', '-P', '-F', '#{session_id} #{window_id}', '-s', name, '-n', windows[0],
                   '-c', folder, SHELL).split()
    ids = [found[1]] + [s.tmux('new-window', '-d', '-P', '-F', '#{window_id}', '-t', found[0] + ':', '-n', window,
                               '-c', folder, SHELL) for window in windows[1:]]
    return found[0], ids


def agent(s, pane, status, unread=False):
    """Makes the Pane an Agent with the Status, as an Extension reports it. The Pane runs AGENT_PROGRAM from then on."""
    def program():
        return s.tmux('display-message', '-p', '-t', pane, '#{pane_current_command}')
    if program() != AGENT_PROGRAM.split()[0]:
        s.tmux('respawn-pane', '-k', '-t', pane, AGENT_PROGRAM)
        wait(lambda: program() == AGENT_PROGRAM.split()[0], 'the program of the Agent in %s did not start' % pane, seconds=10)
    s.tmux('set-option', '-p', '-t', pane, '@muxify_agent', 'claude')
    s.tmux('set-option', '-p', '-t', pane, '@muxify_agent_status', status)
    if unread:
        s.tmux('set-option', '-p', '-t', pane, '@muxify_agent_unread', '1')


def ring(s, window):
    """Rings the terminal bell in the Window's Pane, as its program does, with no key, and waits until tmux marks the
    Window. tmux marks it only while it is not its Session's current Window."""
    with open(s.tmux('display-message', '-p', '-t', window, '#{pane_tty}'), 'w') as terminal:
        terminal.write('\a')
    wait(lambda: s.tmux('display-message', '-p', '-t', window, '#{window_bell_flag}') == '1',
         'tmux did not mark the Window %s with a bell' % window, seconds=10)


def fresh_shell(s, window):
    """Starts the shell of the Window's Pane again, in its folder. The Terminal shows the Location's Window in the
    picture. After a launch that changed the Pane's size, a shell can draw its prompt again on a new line, and the
    second version runs after more launches than the first. A new shell, at the size the Pane has now, draws one
    prompt in each version."""
    folder = s.tmux('display-message', '-p', '-t', window, '#{pane_current_path}')
    s.tmux('respawn-pane', '-k', '-t', window, '-c', folder, SHELL)


def window_rows(key, rows):
    return [row for row in rows if row.get('accessibilityIdentifier') == key]


def labels(key, rows):
    """The labels of a Window row's parts. SwiftUI gives the row's identifier to its parts."""
    return [row['accessibilityLabel'] for row in window_rows(key, rows) if row.get('accessibilityLabel')]


def cards(rows):
    """The value of each Session card's header by its identifier, such as {'session-$1': 'collapsed, Locked'}."""
    return {row['accessibilityIdentifier']: row.get('accessibilityValue') or '' for row in rows
            if re.fullmatch(r'session-\$\d+', row.get('accessibilityIdentifier', ''))}


def close_cards(view, session):
    """Closes the card of the Location's Session, and waits until the list shows closed cards only, with no Window
    row and no Pane row. With `sidebar.session_cards: one`, no other card is open."""
    view.close_card(session)
    def closed(rows):
        return (all(value.startswith('collapsed') for value in cards(rows).values())
                and not any(key.startswith(('session-window-', 'pane-')) for key in view.s.ids(rows)))
    view.wait(closed, lambda: 'the list does not show closed cards only: it has %s' % cards(view.s.rows()))
