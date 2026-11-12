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

from scripts.verify.compare_gate import rect
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


def member(s, topic_id, base, windows=('main',)):
    """A Session of a Topic, named as Muxify names one, `<base>/<Topic ID>`, so its Session line shows `base`. Returns
    (Session id, list of Window ids)."""
    found = session(s, base + '/' + topic_id, windows)
    s.tmux('set-option', '-t', found[0], '@muxify_topic', topic_id)
    return found


def split(s, window):
    """Splits the Window's Pane in two, so it shows Pane rows with `sidebar.panes: true`. Returns the new Pane's id."""
    return s.tmux('split-window', '-d', '-P', '-F', '#{pane_id}', '-t', window, '-c', str(project(s)), SHELL)


def top_of(view, key, rows):
    """The top edge of the row in points from the top of the screen, as the gate measures a frame; None without it."""
    frame = rect(view.s.row(key, rows))
    return None if frame is None else -(frame[1] + frame[3])


class TopicOpen:
    name = 'topic-open'
    shows = ('The open card of the Location\'s Topic with three Sessions: their Session lines, Window rows with their '
             'Pane counts and no bell, Pane rows under a split Window and in place of a Session\'s only Window, and '
             '"N more…" beside Settle; then the same card once "N more…" was pressed. A closed card stands under it. Last, '
             'the open card of an Empty Topic, which lists no Session and ends with the line for Settle.')

    def fixture(self, s):
        TopicRecords(s.root/'state/muxify').put(dict(id='atlas', title='Atlas', slug='atlas', order=0))
        self.api, self.api_windows = member(s, 'atlas', 'api', ('main', 'logs'))
        split(s, self.api_windows[1])
        self.web, self.web_windows = member(s, 'atlas', 'web', ('main', 'build', 'tests'))
        self.docs, (self.docs_window,) = member(s, 'atlas', 'docs')
        split(s, self.docs_window)
        topic(s, 'birch', 'Birch', order=1)
        TopicRecords(s.root/'state/muxify').put(dict(id='cedar', title='Cedar', slug='cedar', order=2))
        self.more = 'topic-atlas-more'

    def shots(self):
        return [('topic-open', self.open), ('topic-open-all-rows', self.all_rows), ('topic-open-empty', self.empty)]

    def open(self, view):
        view.launch(config(sidebar='  panes: true\n'))
        # A bell in a Window that is not the Location's: a Window row in the Topics list shows none.
        ring(view.s, self.web_windows[1])
        view.go(self.api_windows[0])
        fresh_shell(view.s, self.api_windows[0])
        rows = ['topic-atlas-session-' + self.api, 'topic-window-' + self.api_windows[0], 'topic-window-' + self.api_windows[1],
                'topic-atlas-session-' + self.web, 'topic-window-' + self.web_windows[0]]
        view.wait(lambda rs: view.value('topic-atlas', rs).startswith('expanded') and all(view.s.has(key, rs) for key in rows)
                  and view.s.row(self.more, rs).get('accessibilityLabel') == '4 more…',
                  lambda: 'the open card does not list its first five rows under their Session lines with "4 more…": %s'
                  % [key for key in rows + [self.more] if not view.s.has(key)])

    def all_rows(self, view):
        view.s.act('press', self.more)
        rows = ['topic-window-' + window for window in self.web_windows] + ['topic-atlas-session-' + self.docs]
        view.wait(lambda rs: all(view.s.has(key, rs) for key in rows) and not view.s.has(self.more, rs),
                  lambda: 'a press on "N more…" did not list every row: it misses %s' % [key for key in rows if not view.s.has(key)])

    def empty(self, view):
        # A press on the card of the Empty Topic goes to it, and its card opens.
        view.s.act('press', 'topic-cedar')
        view.wait(lambda rs: view.value('topic-cedar', rs).startswith('expanded, Empty'),
                  lambda: 'the card of the Empty Topic did not open: %s' % view.value('topic-cedar', view.s.rows()))


class NoTopicCard:
    name = 'no-topic-card'
    shows = ('The No Topic card of a Session with no Topic that holds the Location, open with its Window rows and '
             'Pane rows under the closed card of a Topic; then the same card closed.')

    def fixture(self, s):
        topic(s, 'atlas', 'Atlas', order=0)
        self.session, self.windows = session(s, 'scratch', ('main', 'notes', 'logs'))
        split(s, self.windows[2])
        self.header = 'no-topic-session-' + self.session

    def shots(self):
        return [('no-topic-card', self.open), ('no-topic-card-closed', self.closed)]

    def open(self, view):
        view.launch(config(sidebar='  panes: true\n'))
        view.go(self.windows[0])
        fresh_shell(view.s, self.windows[0])
        rows = [self.header] + ['topic-window-' + window for window in self.windows]
        view.wait(lambda rs: view.value(self.header, rs).startswith('expanded') and all(view.s.has(key, rs) for key in rows),
                  lambda: 'the No Topic card is not open with its Window rows: it misses %s' % [key for key in rows if not view.s.has(key)])

    def closed(self, view):
        view.close_card(self.header)
        view.wait(lambda rs: not view.s.has('topic-window-' + self.windows[0], rs),
                  'the closed No Topic card still lists its Window rows')


class TopicsStuckHeader:
    name = 'topics-stuck-header'
    shows = ('The Topics list scrolled to its end, with the header of the open card of the Location\'s Topic, the last '
             'card, stuck at the top of the list while the card\'s rows scroll under it.')

    def fixture(self, s):
        topic(s, 'atlas', 'Atlas', order=0)
        topic(s, 'birch', 'Birch', order=1)
        # The last card is open with all its rows: the Location's Window is its last, past the fifth row.
        self.session, self.windows = topic(s, 'cedar', 'Cedar', ['window-%02d' % number for number in range(1, 61)], order=2)

    def shots(self):
        return [('topics-stuck-header', self.stuck)]

    def stuck(self, view):
        s = view.s
        view.launch(config())
        view.go(self.windows[-1])
        fresh_shell(s, self.windows[-1])
        card, header = 'card-topic-cedar', 'topic-cedar'
        view.wait(lambda rs: view.value(header, rs).startswith('expanded') and s.has('topic-window-' + self.windows[-1], rs),
                  'the card of the Location is not open with all its rows')
        view.rest()
        s.act('scroll', 'topics-list', from_end=0)
        # The card's top has left the list at its top, and its header has not.
        def stuck(rs):
            top, card_top, header_top = (top_of(view, key, rs) for key in ('topics-list', card, header))
            return None not in (top, card_top, header_top) and card_top < top - 100 and abs(header_top - top) <= 1
        view.wait(stuck, lambda: 'the list did not scroll with the header of its open card stuck at the top: list, card '
                  'and header tops %s' % [top_of(view, key, s.rows()) for key in ('topics-list', card, header)])


class TopicTags:
    name = 'topic-tags'
    shows = ('Tags on Topic cards in each placement of `sidebar.tag_placement`: Tag Marks in the corner, after a pin, '
             'with a dimmed Mark for a Tag the Config no longer defines; the first chip and "+N" after the title, with a '
             'long title of the open card wrapped under them, and chip texts from the `topic.tags` Format part; chips on '
             'their own line, before Dormant, and a row of chips that does not fit ending with "+N"; last, an opened card '
             'in the Settled group with its Tag Marks.')

    # The Tags of the Config, in its order: `personal` and `research` take the colour Muxify makes from the name.
    TAGS = ('topics:\n  tags:\n    work: {color: blue}\n    personal: {}\n    infrastructure: {color: purple}\n'
            '    documentation: {color: teal}\n    research: {}\n')
    LONG_TITLE = 'A Topic title long enough to wrap onto a second line in the Sidebar card'

    def fixture(self, s):
        self.session, self.windows = topic(s, 'atlas', self.LONG_TITLE, order=0, tags=['work', 'personal'])
        topic(s, 'birch', 'Birch', order=1, pinned=True,
              tags=['personal', 'gone', 'work', 'infrastructure', 'documentation', 'research'])
        topic(s, 'cedar', 'Cedar', order=2)
        records = TopicRecords(s.root/'state/muxify')
        records.put(dict(id='elm', title='Elm', slug='elm', order=3, sessions=[remembered(s, 'elm')], tags=['research']))
        records.put(dict(id='fir', title='Fir', slug='fir', settled_at='2026-01-01T00:00:00Z', sessions=[remembered(s, 'fir')],
                         tags=['work', 'personal']))
        self.values = {'atlas': 'work, personal', 'birch': 'work, personal, infrastructure, documentation, research, gone',
                       'elm': 'research'}

    def shots(self):
        return [('topic-tags-corner', lambda view: self.placement(view, 'corner')),
                ('topic-tags-title', lambda view: self.placement(view, 'title', "  formats:\n    topic:\n      tags: '#{T:@#{tag}}'\n")),
                ('topic-tags-line', lambda view: self.placement(view, 'line')),
                ('topic-tags-settled', self.settled)]

    def placement(self, view, placement, formats=''):
        """Starts the app with the placement, and the Location in Atlas, whose card is open."""
        view.launch(config(sidebar='  tag_placement: %s\n%s' % (placement, formats), more=self.TAGS))
        view.go(self.windows[0])
        fresh_shell(view.s, self.windows[0])
        prefix = '@' if formats else ''
        want = {'tags-topic-' + name: ', '.join(prefix + tag for tag in value.split(', ')) for name, value in self.values.items()}
        shown = lambda rows: {key: view.s.row(key, rows).get('accessibilityValue') for key in want}
        view.wait(lambda rows: view.value('topic-atlas', rows).startswith('expanded') and shown(rows) == want
                  and not view.s.has('tags-topic-cedar', rows),
                  lambda: 'the cards do not show their Tags with tag_placement: %s: %s' % (placement, shown(view.s.rows())))

    def settled(self, view):
        """The Settled group open, with the card of the Settled Topic opened, in the corner placement."""
        self.placement(view, 'corner')
        group, card = 'settled-topics', 'topic-fir'
        view.wait(lambda rows: view.s.has(group, rows), 'the Settled group does not show')
        if view.value(group, view.s.rows()) != 'expanded':
            view.s.act('press', group)
        view.wait(lambda rows: view.s.has(card, rows), 'the Settled group did not open with the card of the Settled Topic')
        if view.value(card, view.s.rows()).startswith('collapsed'):
            view.s.act('press', card)
        view.wait(lambda rows: view.value(card, rows).startswith('expanded')
                  and view.s.row('tags-' + card, rows).get('accessibilityValue') == 'work, personal',
                  lambda: 'the opened Settled card does not show its Tags: %r' % view.s.row('tags-' + card).get('accessibilityValue'))


def bottom_of(view, key, rows):
    """The bottom edge of the row in points from the top of the screen, as `top_of` measures; None without it."""
    frame = rect(view.s.row(key, rows))
    return None if frame is None else -frame[1]


class Bench:
    name = 'bench'
    shows = ('With `topics.in_play: 2`, two Pinned cards, a card In Play and an Open Place, the Guests line, a Guest and '
             'the Bench line, the block that sticks; the Bench just shown, with the open card of the Location\'s Topic, '
             'the last Benched card, kept where it stood under the hidden Bench; then the list scrolled to its end, with '
             'that card\'s header stuck under the block while its rows and the other Benched cards scroll under it.')

    LINE = 'topics-bench-line'
    # Card Hints do not show: the Open Place's Hint comes with task 14 of the set remove-swiftui.
    CONFIG = 'topics:\n  in_play: 2\nhints:\n  cards: { always: false, hold: false }\n'

    def fixture(self, s):
        topic(s, 'atlas', 'Atlas', order=0)
        topic(s, 'birch', 'Birch', order=1, pinned=True)
        topic(s, 'cedar', 'Cedar', order=2, pinned=True)
        topic(s, 'dune', 'Dune', order=3, guest=True)
        topic(s, 'elm', 'Elm', order=4)
        topic(s, 'fir', 'Fir', order=5)
        # The Location's Window is the last of forty, so the open card lists them all and is taller than the Bench area.
        self.session, self.windows = topic(s, 'gale', 'Gale', ['window-%02d' % number for number in range(1, 41)], order=6)
        # The second In Play place, after Atlas.
        TopicRecords(s.root/'state/muxify').set_open_places([dict(id='bench-place', order=0.5)])
        self.block = ['topic-birch', 'topic-cedar', 'topic-atlas', 'open-place-2', 'topics-guests-line', 'topic-dune', self.LINE]

    def shots(self):
        return [('bench', self.shown), ('bench-scrolled', self.scrolled)]

    def line(self, view, rows):
        return view.s.row(self.LINE, rows).get('accessibilityLabel')

    def shown(self, view):
        s = view.s
        view.launch(config(more=self.CONFIG))
        view.go(self.windows[-1])
        fresh_shell(s, self.windows[-1])
        # Under the hidden Bench, the Location's card shows alone, open with all its rows.
        alone = lambda rs: (self.line(view, rs) == 'Bench' and view.value('topic-gale', rs).startswith('expanded')
                            and s.has('topic-window-' + self.windows[-1], rs) and all(s.has(key, rs) for key in self.block)
                            and not s.has('topic-elm', rs) and not s.has('topic-fir', rs))
        view.wait(alone, lambda: 'the list does not show the block and the Location\'s open card alone under the hidden Bench: %s'
                  % s.ids())
        view.rest()
        s.act('press', self.LINE)
        view.wait(lambda rs: self.line(view, rs) == 'Hide Bench' and s.has('topic-elm', rs) and s.has('topic-fir', rs),
                  lambda: 'a press on the Bench line did not show the Bench: %s' % self.line(view, s.rows()))

    def scrolled(self, view):
        s = view.s
        view.rest()
        s.act('scroll', 'topics-list', from_end=0)
        # The card's top has gone under the block, and its header stands right under the block.
        def stuck(rs):
            line, card, header = bottom_of(view, self.LINE, rs), top_of(view, 'card-topic-gale', rs), top_of(view, 'topic-gale', rs)
            return None not in (line, card, header) and card < line - 100 and abs(header - line) <= 1
        view.wait(stuck, lambda: 'the list did not scroll with the header of the open card stuck under the block: the line\'s '
                  'bottom, the card\'s top and the header\'s top %s'
                  % [f(view, key, s.rows()) for f, key in ((bottom_of, self.LINE), (top_of, 'card-topic-gale'), (top_of, 'topic-gale'))])


class TopicOverflow:
    name = 'topic-overflow'
    shows = ('A Topics list longer than its view. With `topics.in_play: 1`, the Bench shown and scrolled to its middle, '
             'with the "N more above" pill over the top of the Bench area and the "N more below" pill over the bottom of '
             'the list, each over the card it counts and covers; then the Bench scrolled 15 points, with the "more '
             'above" pill half come in from under the block; last, without In Play, the list scrolled to 14 points '
             'from its end, with the "more below" pill gone two thirds out with the end of the list.')

    LINE = 'topics-bench-line'
    COUNT = 24

    def fixture(self, s):
        self.session, self.windows = topic(s, 'atlas', 'Atlas', order=0)
        records = TopicRecords(s.root/'state/muxify')
        for order in range(1, self.COUNT + 1):
            records.put(dict(id='more-%02d' % order, title='More %02d' % order, slug='more-%02d' % order, order=order))

    def shots(self):
        return [('topic-overflow', self.middle), ('topic-overflow-slide', self.slide), ('topic-overflow-end', self.end)]

    def pills(self, view, above, below):
        """Waits until the "more above" pill shows or not, as `above` says, and the "more below" pill too."""
        s = view.s
        shown = lambda rs: (s.has('topics-more-above', rs), s.has('topics-more-below', rs))
        view.wait(lambda rs: shown(rs) == (above, below),
                  lambda: 'the list shows the pills (more above, more below) %s, not %s' % (shown(s.rows()), (above, below)))

    def middle(self, view):
        s = view.s
        view.launch(config(more='topics:\n  in_play: 1\n'))
        view.go(self.windows[0])
        fresh_shell(s, self.windows[0])
        close_location(view, 'topic-atlas', ['topic-atlas'])
        view.wait(lambda rs: s.row(self.LINE, rs).get('accessibilityLabel') in ('Bench', 'Hide Bench'), 'the list has no Bench line')
        if s.row(self.LINE).get('accessibilityLabel') == 'Bench':
            s.act('press', self.LINE)
        view.wait(lambda rs: s.row(self.LINE, rs).get('accessibilityLabel') == 'Hide Bench' and s.has('topic-more-%02d' % self.COUNT, rs),
                  'a press on the Bench line did not show the Bench')
        view.rest()
        # From the Bench's top, 300 points down: the Bench is longer than its area by far more.
        s.act('scroll', 'topics-list', from_end=100000)
        self.pills(view, above=False, below=True)
        s.act('scroll', 'topics-list', by=300, steps=1)
        self.pills(view, above=True, below=True)

    def slide(self, view):
        s = view.s
        view.rest()
        s.act('scroll', 'topics-list', from_end=100000)
        self.pills(view, above=False, below=True)
        s.act('scroll', 'topics-list', by=15, steps=1)
        self.pills(view, above=True, below=True)

    def end(self, view):
        s = view.s
        view.launch(config())
        view.wait(lambda rs: not s.has(self.LINE, rs) and s.has('topic-more-%02d' % self.COUNT, rs),
                  'without In Play, the list does not show every Topic with no Bench line')
        view.rest()
        s.act('scroll', 'topics-list', from_end=14)
        self.pills(view, above=False, below=True)


# The launch arguments of every scene of the Topics list: the Sidebar shows, with Topics.
TOPICS_ARGS = ['-sidebarVisible', 'YES', '-sessionsVisible', 'YES', '-sidebarWorkView', 'Topics']

# The areas that have two versions now.
AREAS = [
    Area(name='topics', title='Topics list', list='topics-list', default=TOPICS_LIST_DEFAULT, args=TOPICS_ARGS,
         shown=lambda s: s.topics_list(), scenes=[TopicCards(), LockedCards(), TopicOpen(), NoTopicCard(), TopicsStuckHeader(),
                                                    TopicTags(), Bench(), TopicOverflow()]),
]
