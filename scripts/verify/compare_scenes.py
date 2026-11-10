"""The scenes of the compare run (compare.py): what each shows in the Sessions list, and how it gets there.

A scene has a `name` for `make compare SCENE=`, a line `shows` for the report, a `fixture` and its `shots`:

- `fixture(s)` makes what the scene needs in its Sandbox before the app starts: tmux Sessions, Topic records, folders.
  It runs once, for both versions.
- `shots()` gives (name, arrange) pairs, in their order. The run calls `arrange(view)` for one version of the list
  (`View` in compare.py), then takes the picture and the dump of that shot. It calls every arrange again for the
  other version, so an arrange leaves tmux as it found it, or sets it again. The first arrange starts the app with
  `view.launch(config)`; a later one starts it again when the shot needs another Config. No arrange waits for a
  Config reload: the app reads the Config as it starts.

An arrange reaches a state only through tmux, the Config and the driver commands that take no focus. When the list of
one version cannot show a shot, the arrange fails there and says what the list does not show; the run still measures.

Both versions must start a shot from the same state, or `make compare SELF=1` finds a difference that is the scene's
own. So an arrange sets again what an earlier shot changed, such as a bell, and calls `view.rest()` before a step
that starts from where the list stands, such as a swipe or a hover.

To add a scene, write a class like these, add it to SCENES, and add its section to compare-notes.md.
"""

import pathlib
import re
import subprocess

from scripts.verify.sandbox import frame, wait
from scripts.verify.topic_records import TopicRecords

SHELL = '/bin/zsh -f'
# What the Pane of an Agent runs. A Pane at a plain shell runs no Agent (`Agent.runs` in MuxifyCore), so the list shows
# no mark for it.
AGENT_PROGRAM = 'sleep 3600'
# The Session of the app's control client (`Tmux.watchSessionName`). The Sidebar never shows it.
WATCH_SESSION = 'muxify-watch'
# HoverLabel.delay in Sources/Muxify/UI/HoverLabel.swift.
HOVER_DELAY = 0.4
# How long the hover scene waits for its label. The user's windows can cover the App Window whole for a while, for
# example a window that fills the screen, and then the app's views get no hover (README, "Do not take focus").
UNCOVER_WAIT = 60
LONG_WINDOW = 'a-window-name-far-too-long-for-any-sidebar-row-to-show-whole'
# Where a held swipe stands: 0.400 from Topics, and 1.038 from Sessions, where the page resists past its end
# (SidebarPager's "Begin swipe left" sample, as in suites/sidebar_swipe.py and suites/sessions_list_sidebar.py).
SWIPE_FROM_TOPICS = '0.400'
SWIPE_FROM_SESSIONS = '1.038'


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


class Cards:
    name = 'cards'
    shows = 'Closed and open Session cards, with the Location\'s card open and its Window row selected.'

    def fixture(self, s):
        self.session, self.windows = session(s, 'atlas', ('editor', 'server', 'logs'))
        session(s, 'birch')
        session(s, 'cedar', ('main', 'notes'))

    def shots(self):
        return [('cards', self.cards)]

    def cards(self, view):
        view.launch(config())
        self.arrange(view)

    def arrange(self, view):
        window = self.windows[1]
        view.go(window)
        view.wait(lambda rs: 'expanded' in view.value('session-' + self.session, rs)
                  and 'selected' in [row.get('accessibilityValue') for row in window_rows('session-window-' + window, rs)],
                  'the card of the Location is not open with its Window row selected')


class WindowParts:
    name = 'window-parts'
    shows = ('A Window row with every default part: app icon, Tab count, Pane count, Zoomed badge, bell, Git View icon '
             'and the "Main working copy" line.')

    def fixture(self, s):
        # The header shows its Git View button only in a repository.
        self.repository = s.root/'repository'
        self.repository.mkdir()
        subprocess.run(['/usr/bin/git', 'init', '-q', '-b', 'main', str(self.repository)], check=True)
        # The Topic remembers the Session in a Worktree, and the Session's Windows are in the repository itself.
        worktree = s.root/'worktree'
        worktree.mkdir()
        TopicRecords(s.root/'state/muxify').put(dict(id='parts', title='Parts', slug='parts', sessions=[dict(
            id='saved:parts', name='parts', base_name='parts', directory=str(worktree),
            repository_path=str(self.repository), worktree_path=str(worktree))]))
        self.session, (self.window, self.other) = session(s, 'parts', ('every-part', 'plain'), self.repository)
        s.tmux('set-option', '-t', self.session, '@muxify_topic', 'parts')
        s.tmux('set-option', '-t', self.session, '@muxify_session_id', 'saved:parts')
        for option, value in (('@muxify_tabs', 'data:text/html,one data:text/html,two'), ('@muxify_active_tab', '0')):
            s.tmux('set-option', '-w', '-t', self.window, option, value)
        s.tmux('split-window', '-d', '-t', self.window, '-c', str(self.repository), SHELL)
        s.tmux('resize-pane', '-Z', '-t', self.window + '.0')

    def shots(self):
        return [('window-parts', self.window_parts)]

    def window_parts(self, view):
        view.launch(config())
        self.arrange(view)

    def reset(self, s):
        """Puts tmux back where the fixture left it, for a shot that comes before `arrange` in the other version: the
        Window with every part is its Session's current Window again, and tmux takes the bell from a Window that
        becomes the current one."""
        s.tmux('select-window', '-t', self.window)

    def arrange(self, view):
        s = view.s
        # The Git View opens in the Window that shows, and the bell marks a Window that does not show.
        view.go(self.window)
        view.wait(lambda rs: s.has('toggle-git-view', rs), 'the header has no Git View button')
        if s.row('toggle-git-view').get('accessibilityValue') != 'on':
            s.act('press', 'toggle-git-view')
        view.wait(lambda rs: s.row('toggle-git-view', rs).get('accessibilityValue') == 'on', 'the Git View did not open')
        view.go(self.other)
        ring(s, self.window)
        key = 'session-window-' + self.window
        wanted = ['Main working copy', 'Bell', '2', '2, Zoomed']
        view.wait(lambda rs: all(label in labels(key, rs) for label in wanted)
                  and any(row.get('accessibilityHelp') == 'Git View open' for row in window_rows(key, rs)),
                  lambda: 'the Window row does not show every part: it has %s' % labels(key, s.rows()))


class WindowFormats:
    name = 'window-formats'
    shows = 'Window rows from Config Formats, with text, symbol and app icon parts on both sides, and a Summary.'
    FORMATS = '''  formats:
    window:
      title: 'Window #{window_name}'
      summary: 'Summary of #{window_name}'
      left: 'L #{symbol:star.fill} #{current_app_icon}'
      right: '#{current_app_icon} #{symbol:globe} R#{window_panes}'
'''

    def fixture(self, s):
        self.session, self.windows = session(s, 'formats', ('first', 'second'))

    def shots(self):
        return [('window-formats', self.window_formats)]

    def window_formats(self, view):
        view.launch(config(sidebar=self.FORMATS))
        view.go(self.windows[0])
        for window, name in zip(self.windows, ('first', 'second')):
            key = 'session-window-' + window
            wanted = ['L ', 'star.fill', 'Window ' + name, 'Summary of ' + name, 'globe', ' R1']
            view.wait(lambda rs: all(label in labels(key, rs) for label in wanted),
                      lambda: 'the Window row %s does not show its Format parts: it has %s' % (name, labels(key, view.s.rows())))


class PaneRows:
    name = 'pane-rows'
    shows = 'Pane rows, active and not, with each Agent mark, under a Window row and in the place of one.'
    MARKS = ('working', 'done', 'failed', 'blocked')

    def fixture(self, s):
        # The Agents are in a Window that does not show: the app reads an Agent's Notification when its Window shows.
        self.session, (self.agents, self.home) = session(s, 'panes', ('agents', 'home'))
        self.panes = [s.tmux('display-message', '-p', '-t', self.agents, '#{pane_id}')]
        self.panes += [s.tmux('split-window', '-d', '-P', '-F', '#{pane_id}', '-t', self.agents, '-c', str(project(s)), SHELL)
                       for _ in self.MARKS[1:]]
        s.tmux('select-layout', '-t', self.agents, 'even-vertical')
        s.tmux('split-window', '-d', '-t', self.home, '-c', str(project(s)), SHELL)
        self.solo, (self.solo_window,) = session(s, 'solo')
        s.tmux('split-window', '-d', '-t', self.solo_window, '-c', str(project(s)), SHELL)

    def shots(self):
        return [('under-a-window', self.under_a_window), ('in-place-of-a-window', self.in_place_of_a_window)]

    def mark_agents(self, s):
        for pane, mark in zip(self.panes, self.MARKS):
            agent(s, pane, mark, unread=mark in ('done', 'failed'))

    def under_a_window(self, view):
        self.mark_agents(view.s)
        view.launch(config(sidebar='  panes: true\n'))
        # The Location's Window is the last, so the card lists all its rows and no "N more…".
        view.go(self.home)
        view.wait(lambda rs: [view.value('pane-' + pane, rs) for pane in self.panes]
                  == ['active, working', 'done', 'failed', 'blocked'],
                  lambda: 'the Pane rows do not show each Agent mark: they have %s'
                  % [view.value('pane-' + pane, view.s.rows()) for pane in self.panes])

    def in_place_of_a_window(self, view):
        view.go(self.solo_window)
        panes = view.s.tmux('list-panes', '-t', self.solo_window, '-F', '#{pane_id}').split()
        view.wait(lambda rs: all(view.s.has('pane-' + pane, rs) for pane in panes)
                  and not view.s.has('session-window-' + self.solo_window, rs),
                  'the Pane rows do not stand in the place of the only Window row')


class CardMarks:
    name = 'card-marks'
    shows = 'Closed cards only, with an Agent mark spine, a Summary, a bell and a Locked Session.'
    FORMATS = "  formats:\n    session:\n      summary: 'Summary of #{session_name}'\n"

    def fixture(self, s):
        self.home, (self.window,) = session(s, 'home')
        self.marks = {}
        for status in ('working', 'blocked'):
            self.marks[status], _ = session(s, status)
            agent(s, s.tmux('display-message', '-p', '-t', self.marks[status] + ':', '#{pane_id}'), status)
        self.belled, (_, self.bell) = session(s, 'belled', ('main', 'rings'))
        self.locked, _ = session(s, 'locked')
        s.tmux('set-option', '-t', self.locked, '@muxify_lock', '1')

    def shots(self):
        return [('card-marks', self.card_marks)]

    def card_marks(self, view):
        s = view.s
        # The bell is on its Window before the app starts, so the app's first read of tmux has it. The header of a
        # card is one accessibility element, so no row tells that the card shows its bell.
        ring(s, self.bell)
        view.launch(config(sidebar=self.FORMATS))
        view.go(self.window)
        close_cards(view, self.home)
        wanted = {'session-' + self.home: 'collapsed', 'session-' + self.belled: 'collapsed',
                  'session-' + self.locked: 'collapsed, Locked',
                  **{'session-' + sid: 'collapsed, ' + status for status, sid in self.marks.items()}}
        view.wait(lambda rs: cards(rs) == wanted
                  and s.row('session-' + self.belled, rs).get('accessibilityHelp') == 'Summary of belled',
                  lambda: 'the cards do not show their marks and their Summary: they have %s, and the Summary %r'
                  % (cards(s.rows()), s.row('session-' + self.belled).get('accessibilityHelp')))


class Hints:
    name = 'hints'
    shows = 'Hints shown at all times, and Hints while a modifier is held.'
    # A hold shows its Hints at once, so the shot does not wait out a delay.
    HINTS = 'hints:\n  hold_delay: 0\n  cards: { always: true, hold: true }\n  windows: { always: true, hold: true }\n'

    def fixture(self, s):
        self.session, self.windows = session(s, 'hints', ('one', 'two', 'three'))
        self.other, _ = session(s, 'other')

    def shots(self):
        return [('at-all-times', self.at_all_times), ('control-held', self.control_held), ('command-held', self.command_held)]

    def at_all_times(self, view):
        view.launch(config(more=self.HINTS))
        view.go(self.windows[0])
        view.s.act('action', 'quick-switch-input', 'Release modifiers')
        view.wait(lambda rs: view.value('hint-session-' + self.session, rs) == '1'
                  and view.value('hint-window-' + self.windows[0], rs) == '1',
                  'the cards and the Window rows do not show their Hints at rest')

    def control_held(self, view):
        # The cards' shortcuts are ⌃1 to ⌃9 (Keybinds.swift).
        view.s.act('action', 'quick-switch-input', 'Hold Control')
        view.wait(lambda rs: view.value('hint-session-' + self.session, rs) == '⌃1',
                  'the cards do not show their Hints while Control is held')

    def command_held(self, view):
        # The Windows' shortcuts are ⌘1 to ⌘9.
        view.s.act('action', 'quick-switch-input', 'Release modifiers')
        view.s.act('action', 'quick-switch-input', 'Hold Command')
        view.wait(lambda rs: view.value('hint-window-' + self.windows[0], rs) == '⌘1',
                  'the Window rows do not show their Hints while Command is held')


class Hover:
    name = 'hover'
    shows = 'A hovered Window row whose title is cut off, with its hover label.'

    def fixture(self, s):
        self.session, (self.short, self.long) = session(s, 'hover', ('short', LONG_WINDOW))

    def shots(self):
        return [('hover', self.hover)]

    def hover(self, view):
        view.launch(config())
        view.go(self.short)
        key = 'session-window-' + self.long
        view.wait(lambda rs: view.s.has(key, rs), 'the list has no Window row to hover')
        view.rest()
        # A row that the list lays out again loses the pointer that the driver gave it, and opens no label. So the
        # pointer goes to the row again, each time after the label had its time to open. The driver gives no pointer
        # to an App Window that other windows cover whole, so the scene also waits here for the user to uncover it.
        last = {}
        def label_opens():
            if view.s.has('hover-label'):
                return True
            last.update(error=None)
            last.update(view.s.driver('hover', key))
        wait(label_opens, lambda: 'no hover label opened over the Window row, in the %s list%s'
             % (view.side.version, ': ' + last['error'] if last.get('error') else ''), seconds=UNCOVER_WAIT,
             step=HOVER_DELAY + .6)


class MoreRows:
    name = 'more-rows'
    shows = 'A long card with its "N more…" row.'

    def fixture(self, s):
        self.session, self.windows = session(s, 'many', ['window-%d' % number for number in range(1, 9)])

    def shots(self):
        return [('more-rows', self.more_rows)]

    def more_rows(self, view):
        view.launch(config())
        view.go(self.windows[0])
        key = 'session-%s-more' % self.session
        view.wait(lambda rs: view.s.row(key, rs).get('accessibilityLabel') == '3 more…',
                  'the card does not end with "3 more…"')


class LongTitles:
    name = 'long-titles'
    shows = 'Closed cards only, with long titles, once cut off and once wrapped.'
    TITLES = ('a session name that is far too long for one line of a card',
              'another-session-name-without-a-space-that-is-far-too-long-for-one-line')

    def fixture(self, s):
        self.home, (self.window,) = session(s, 'home')
        for title in self.TITLES:
            session(s, title)

    def shots(self):
        return [('cut-off', lambda view: self.titles(view, wrap=False)), ('wrapped', lambda view: self.titles(view, wrap=True))]

    def titles(self, view, wrap):
        view.launch(config(sidebar='  titles:\n    wrap: %s\n' % ('true' if wrap else 'false')))
        view.go(self.window)
        close_cards(view, self.home)


class StuckHeader:
    name = 'stuck-header'
    shows = 'A scrolled list with an open card\'s header stuck at the top.'
    # How far the list scrolls: into the rows of the first card, which is open.
    SCROLL = 120.0

    def fixture(self, s):
        # The first card is open with all its rows: the Location's Window is its last. The cards under it make the
        # list longer than the Sidebar.
        self.session, self.windows = session(s, 'a-stuck', ['window-%02d' % number for number in range(1, 15)])
        for number in range(1, 17):
            session(s, 'filler-%02d' % number)

    def shots(self):
        return [('stuck-header', self.stuck_header)]

    def stuck_header(self, view):
        s = view.s
        view.launch(config())
        view.go(self.windows[-1])
        card, header = 'card-session-' + self.session, 'session-' + self.session
        view.wait(lambda rs: s.has(card, rs) and s.has('sessions-list', rs), 'the list has no card for the Location')
        s.act('scroll', 'sessions-list', by=self.SCROLL, steps=1)
        # The card has left the list at its top, and its header has not.
        def stuck(rs):
            top = frame(s.row('sessions-list', rs))[1]
            return frame(s.row(card, rs))[1] > top + self.SCROLL / 2 and frame(s.row(header, rs))[1] <= top + 1
        view.wait(lambda rs: s.has(card, rs) and s.has(header, rs) and stuck(rs),
                  'the list did not scroll with the header of its open card stuck at the top')


class Empty:
    name = 'empty'
    shows = '"No windows", and "No tmux server".'

    def fixture(self, s):
        """Each shot makes its own Session, because each shot ends its Session or its server."""

    def shots(self):
        return [('no-windows', self.no_windows), ('no-tmux-server', self.no_tmux_server)]

    def start(self, view):
        """The app on a tmux server with one Session. The shot before this one left a server without a Session, or
        no server; tmux starts one for a new Session."""
        s = view.s
        self.session, (self.window,) = session(s, 'only')
        # The run sets this on the first server only.
        s.tmux('set-option', '-g', 'status', 'off')
        view.launch(config())
        view.go(self.window)

    def says(self, view, text):
        view.wait(lambda rs: any(text in (row.get('accessibilityValue'), row.get('accessibilityLabel')) for row in rs),
                  'the Sidebar does not say "%s"' % text)

    def no_windows(self, view):
        s = view.s
        self.start(view)
        # A server without a Session stays, and the app stays when its Client detaches.
        s.tmux('set-option', '-s', 'exit-empty', 'off')
        s.tmux('detach-client', '-s', self.session)
        # An app that has not seen the detach closes when its Session ends.
        self.says(view, 'Detached from tmux')
        # The app reads tmux through its Watch Session, so it sees that the last Window is gone. Then it ends the
        # Watch Session itself. Without a Session the app cannot read tmux, and it keeps what it shows.
        for name in s.tmux('list-sessions', '-F', '#{session_name}').split('\n'):
            if name != WATCH_SESSION:
                s.tmux_ok('kill-session', '-t', '=' + name)
        self.says(view, 'No windows')
        wait(lambda: s.tmux_ok('has-session', '-t', '=' + WATCH_SESSION).returncode != 0,
             'the app did not end its Watch Session', seconds=10)

    def no_tmux_server(self, view):
        s = view.s
        # The app closes when the server ends after its last Session, and stays when the server ends under a Session.
        self.start(view)
        # Sandbox.tmux names the sandbox socket. Only the server of this scene ends.
        socket = s.tmux('display-message', '-p', '#{socket_path}')
        assert socket and pathlib.Path(socket).resolve().is_relative_to(s.root.resolve()), (
            'refusing kill-server: socket %s is outside %s' % (socket, s.root))
        s.tmux('kill-server')
        self.says(view, 'No tmux server')


class SizesAndLight:
    name = 'sizes-and-light'
    shows = 'The scenes cards and window-parts at Interface font size 18 and 24, and in a light theme.'
    LIGHT = 'background = #f4f4f2\nforeground = #1d1d1f\n'

    def __init__(self):
        self.cards, self.parts = Cards(), WindowParts()

    def fixture(self, s):
        self.cards.fixture(s)
        self.parts.fixture(s)
        self.theme = s.root/'config/light-theme.conf'
        self.theme.write_text(self.LIGHT)

    def shots(self):
        found = []
        for name, settings in (('18', dict(ui='  font_size: 18\n')), ('24', dict(ui='  font_size: 24\n')),
                               ('light', dict(light=True))):
            found.append(('cards-' + name, lambda view, settings=settings: self.start(view, **settings)))
            found.append(('window-parts-' + name, lambda view: self.parts.arrange(view)))
        return found

    def start(self, view, ui='', light=False):
        # The shot of window-parts before this one left a bell.
        self.parts.reset(view.s)
        view.launch(config(ui=ui, more='ghostty:\n  config_file: %s\n' % self.theme if light else ''))
        self.cards.arrange(view)


class MidSwipe:
    name = 'mid-swipe'
    shows = 'The Sidebar held partway between Topics and Sessions by a partial swipe.'

    def fixture(self, s):
        self.cards = Cards()
        self.cards.fixture(s)

    def shots(self):
        return [('past-sessions', self.past_sessions), ('from-topics', self.from_topics)]

    def swipe(self, view):
        return view.s.row('sidebar-swipe-input').get('accessibilityLabel', '')

    def sample(self, view, name):
        view.s.act('action', 'sidebar-swipe-input', name)

    def hold(self, view, position):
        # The Sidebar follows a swipe only while it animates. Reduce Motion in System Settings stops that for every app.
        assert not self.swipe(view).startswith('Sidebar swipe input instant'), (
            'Reduce Motion is on, so the Sidebar does not follow a swipe')
        # A swipe that begins while a card still opens holds the cards a fraction of a point from their places.
        view.rest()
        self.sample(view, 'Begin swipe left')
        view.wait(lambda rs: view.s.row('sidebar-swipe-input', rs).get('accessibilityLabel', '').endswith(' ' + position),
                  lambda: 'the Sidebar did not follow the swipe to %s: %s' % (position, self.swipe(view)))

    def past_sessions(self, view):
        # Sessions shows, so the dump has the list's rows while the swipe pulls the page past its end.
        view.launch(config())
        self.cards.arrange(view)
        self.hold(view, SWIPE_FROM_SESSIONS)

    def from_topics(self, view):
        # Topics shows, and the Sidebar hides the Sessions page from accessibility: this shot has a picture only.
        self.sample(view, 'Cancel current swipe')
        view.s.act('press', 'sidebar-view-topics')
        view.wait(lambda rs: view.value('sidebar-view-topics', rs) == 'selected'
                  and view.s.row('sidebar-swipe-input', rs).get('accessibilityLabel', '').endswith(' 0.000'),
                  'the Sidebar did not settle on Topics')
        self.hold(view, SWIPE_FROM_TOPICS)


SCENES = [Cards(), WindowParts(), WindowFormats(), PaneRows(), CardMarks(), Hints(), Hover(), MoreRows(), LongTitles(),
          StuckHeader(), Empty(), SizesAndLight(), MidSwipe()]
