"""The areas of the compare run (compare.py), their scenes, and the fixture helpers that scenes share.

An area is a part of the app with two versions while it moves from SwiftUI to AppKit
(docs/adr/0075-muxify-leaves-swiftui-entirely-one-area-at-a-time.md). `Area` names the list whose rows the gate
compares, the user default that chooses the version, how the run asks the driver which version shows, and the area's
scenes. AREAS lists the areas that have two versions now: the Topics list (`make compare AREA=topics`). An area leaves
it when the user signs it off and its SwiftUI version is deleted. The Sessions list was the first area; its scenes are
in the git history before its SwiftUI version was deleted.

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

To add a scene, write a class like `TopicCards`, add it to its area's `scenes`, and add its section to
compare-notes.md.
"""

import re
from typing import Callable, NamedTuple

from scripts.verify.sandbox import TOPICS_LIST_DEFAULT, wait
from scripts.verify.topic_records import TopicRecords

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


def topic(s, topic_id, title, windows=('main',), **fields):
    """A Topic with a live Session: its record, with `fields` such as `order`, and a Session of the same name that
    names the Topic. Returns (Session id, list of Window ids)."""
    TopicRecords(s.root/'state/muxify').put(dict(id=topic_id, title=title, slug=topic_id, **fields))
    found = session(s, topic_id, windows)
    s.tmux('set-option', '-t', found[0], '@muxify_topic', topic_id)
    return found


def locked(s, name, order):
    """A No Topic Session that is Locked at `order` in the Topic order, as tmux keeps a Lock. Returns (Session id,
    list of Window ids)."""
    found = session(s, name)
    s.tmux('set-option', '-t', found[0], '@muxify_lock', str(order))
    return found


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
    view.close_card('session-' + session)
    def closed(rows):
        return (all(value.startswith('collapsed') for value in cards(rows).values())
                and not any(key.startswith(('session-window-', 'pane-')) for key in view.s.ids(rows)))
    view.wait(closed, lambda: 'the list does not show closed cards only: it has %s' % cards(view.s.rows()))


def remembered(s, topic_id):
    """A Session that a Topic's record remembers, as Settle or a Dormant Topic keeps one, in the scene's folder."""
    folder = project(s)
    name = folder.name + '/' + topic_id
    return dict(id='saved:' + name, name=name, base_name=folder.name, directory=str(folder))


def close_location(view, header, headers):
    """Closes the card of the Location, whose header is `header`, and waits until each of the headers is closed."""
    view.close_card(header)
    values = lambda rows: {key: view.value(key, rows) for key in headers}
    view.wait(lambda rows: all(value.startswith('collapsed') for value in values(rows).values()),
              lambda: 'the list does not show closed cards only: their headers have %s' % values(view.s.rows()))


class TopicCards:
    name = 'topic-cards'
    shows = ('Closed Topic cards with every note of the Topics list: a Pinned Topic first, the Location\'s Topic with a '
             'Topic Note, whose card a press closed, an Agent\'s spine, an Unread Topic, a Dormant and an Empty Topic.')

    def fixture(self, s):
        self.session, self.windows = topic(s, 'atlas', 'Atlas', order=0, note='Repro with seed 4411')
        topic(s, 'birch', 'Birch', order=1, pinned=True)
        _, cedar = topic(s, 'cedar', 'Cedar', order=2)
        agent(s, cedar[0], 'working')
        topic(s, 'dune', 'Dune', order=3, unread=True)
        records = TopicRecords(s.root/'state/muxify')
        records.put(dict(id='elm', title='Elm', slug='elm', order=4, sessions=[remembered(s, 'elm')]))
        records.put(dict(id='fir', title='Fir', slug='fir', order=5))
        # The headers of the cards, in the order of the list: the Pinned Topic first.
        self.headers = ['topic-' + name for name in ('birch', 'atlas', 'cedar', 'dune', 'elm', 'fir')]

    def shots(self):
        return [('topic-cards', self.cards)]

    def cards(self, view):
        view.launch(config())
        view.go(self.windows[0])
        fresh_shell(view.s, self.windows[0])
        close_location(view, 'topic-atlas', self.headers)
        notes = {'topic-birch': 'Pinned', 'topic-atlas': 'Note: Repro with seed 4411', 'topic-cedar': 'working',
                 'topic-dune': 'unread', 'topic-elm': 'Dormant', 'topic-fir': 'Empty'}
        missing = lambda rows: {key: view.value(key, rows) for key, note in notes.items() if note not in view.value(key, rows)}
        view.wait(lambda rows: not missing(rows), lambda: 'these headers miss their note: %s' % missing(view.s.rows()))


class LockedCards:
    name = 'locked-cards'
    shows = ('A Locked card with its lock and the bell of a Window that rang, under the closed card of the Location\'s '
             'Topic; then, with `topics.in_play: 1`, the Guests line, a Guest Topic and the Locked Session as a Guest.')

    def fixture(self, s):
        self.session, self.windows = topic(s, 'atlas', 'Atlas', order=0)
        topic(s, 'birch', 'Birch', order=1, guest=True)
        self.lock, self.locked_windows = session(s, 'dune', windows=('main', 'logs'))
        s.tmux('set-option', '-t', self.lock, '@muxify_lock', '2')

    def shots(self):
        return [('locked-cards', self.locked), ('guest-cards', self.guests)]

    def arrive(self, view, config_text, headers):
        """Starts the app with the Config, moves the Location to Atlas and closes its card, with a bell in the Locked
        Session's second Window."""
        view.launch(config_text)
        ring(view.s, self.locked_windows[1])
        view.go(self.windows[0])
        fresh_shell(view.s, self.windows[0])
        close_location(view, 'topic-atlas', headers)

    def locked(self, view):
        header = 'locked-' + self.lock
        self.arrive(view, config(), ['topic-atlas', 'topic-birch', header])
        view.wait(lambda rows: view.value(header, rows) == 'collapsed, Locked',
                  lambda: 'the Locked card has the value %r' % view.value(header, view.s.rows()))

    def guests(self, view):
        header = 'locked-' + self.lock
        self.arrive(view, config(more='topics:\n  in_play: 1\n'), ['topic-atlas', 'topic-birch', header])
        values = lambda rows: [view.value(key, rows) for key in ('topic-birch', header)]
        view.wait(lambda rows: values(rows) == ['collapsed, Guest', 'collapsed, Guest'] and view.s.has('topics-guests-line', rows),
                  lambda: 'the Guests show no Guest mark or no Guests line: %s' % values(view.s.rows()))


# The launch arguments of every scene of the Topics list: the Sidebar shows, with Topics.
TOPICS_ARGS = ['-sidebarVisible', 'YES', '-sessionsVisible', 'YES', '-sidebarWorkView', 'Topics']

# The areas that have two versions now.
AREAS = [
    Area(name='topics', title='Topics list', list='topics-list', default=TOPICS_LIST_DEFAULT, args=TOPICS_ARGS,
         shown=lambda s: s.topics_list(), scenes=[TopicCards(), LockedCards()]),
]
