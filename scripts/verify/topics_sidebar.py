"""The fixture and helpers of the topics_*_sidebar suites: Topics in the Sidebar.

TopicsSidebar has no checks. Each suite subclasses it, so each suite makes its own Sandbox, Session Paths and app.

The open-Topic row in UI/SidebarView.swift gives "Add a Session…" as an accessibility action, so open_add_session
reaches the Add Session palette without the row's context menu. New Topic opens Add Session. The helper closes it
to test the empty-Topic view and its Add a Session button.
"""

import json
import os
import subprocess
import time
import unittest

from scripts.verify.sandbox import Sandbox, remove_topic, wait

# The app reads tmux and the Topic files once per second.
REFRESH_LIMIT = 2.0
SHELL = '/bin/zsh -f'


def remembered_session(directory, topic, base=None, **fields):
    """A current-schema restoration fixture, with identity independent of its launch directory."""
    base = base or directory.name
    name = base + '/' + topic
    return dict(id='saved:' + name, name=name, base_name=base, directory=str(directory), **fields)


class TopicsSidebar(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.s = s = Sandbox(cls.__module__.rsplit('.', 1)[-1])
        cls.addClassCleanup(s.teardown)
        cls.topics_dir = s.root/'state/muxify/topics'
        # The sandbox sets XDG_STATE_HOME to state/, so Muxify puts every new Worktree here.
        cls.worktrees = s.root/'state/muxify/worktrees'
        cls.alpha = s.root/'projects/alpha'
        cls.beta = s.root/'projects/beta'
        # Plain repositories like alpha: delta only for the legacy-Session check, epsilon only for the main-checkout check.
        cls.delta = s.root/'projects/delta'
        cls.epsilon = s.root/'projects/epsilon'
        # A bare repository with one Worktree folder per branch, as ~/Dev/work/game_server is.
        cls.gamma = s.root/'projects/gamma'
        # A bare repository that sorts first in the Session Path list, used only by the Add Session Path check, whose rows
        # show without a search.
        cls.acme = s.root/'projects/acme'
        bin_dir = s.root/'bin'
        zdot_dir = s.root/'zdot'
        for directory in [cls.topics_dir, cls.alpha, cls.beta, s.root/'codex-home', bin_dir, zdot_dir]:
            directory.mkdir(parents=True, exist_ok=True)
        opencode = bin_dir/'opencode'
        opencode.write_text("""#!/bin/sh
test "$1" = export || exit 2
printf '%s\\n' '{"messages":[{"info":{"role":"user"},"parts":[{"type":"text","text":"Title suggestion verification prompt"}]}]}'
""")
        opencode.chmod(0o755)
        cls.title_prompt = s.root/'title-prompt.txt'
        title_model = bin_dir/'title-model'
        title_model.write_text("#!/bin/sh\ncat > " + str(cls.title_prompt) + "\nprintf 'Verified Agent Title\\n'\n")
        title_model.chmod(0o755)
        (zdot_dir/'.zprofile').write_text('export PATH=' + str(bin_dir) + ':/usr/bin:/bin:/usr/sbin:/sbin\n')
        s.app_env['ZDOTDIR'] = str(zdot_dir)
        for repository in [cls.alpha, cls.delta, cls.epsilon]:
            git = ['/usr/bin/git', '-C', str(repository), '-c', 'user.name=Verifier', '-c', 'user.email=verifier@example.invalid',
                   '-c', 'commit.gpgSign=false']
            subprocess.run(['/usr/bin/git', 'init', '-q', '-b', 'main', str(repository)], check=True)
            (repository/'README').write_text(repository.name + '\n')
            subprocess.run(git + ['add', 'README'], check=True)
            subprocess.run(git + ['commit', '-q', '-m', 'init'], check=True)
        # Linked Worktrees of alpha, each the base of exactly one check. Many checks open live Topic Sessions in alpha
        # itself, so its main-checkout row says Also in those Topics, and no check picks that row. They sit outside projects/, so the
        # projects glob does not list them as Session Paths.
        cls.alpha_tree = {name: s.root/'alpha-trees'/name
                          for name in ['new-topic-base', 'worktree-base', 'worktree-row-base']}
        for name, path in cls.alpha_tree.items():
            subprocess.run(['/usr/bin/git', '-C', str(cls.alpha), 'worktree', 'add', '-q', str(path), '-b', name], check=True)
        subprocess.run(['/usr/bin/git', 'clone', '-q', '--bare', str(cls.alpha), str(cls.acme)], check=True)
        subprocess.run(['/usr/bin/git', '-C', str(cls.acme), 'worktree', 'add', '-q', str(cls.acme/'main'), 'main'], check=True)
        subprocess.run(['/usr/bin/git', '-C', str(cls.acme), 'worktree', 'add', '-q', str(cls.acme/'base'), '-b', 'base-line'], check=True)
        subprocess.run(['/usr/bin/git', 'clone', '-q', '--bare', str(cls.alpha), str(cls.gamma)], check=True)
        subprocess.run(['/usr/bin/git', '-C', str(cls.gamma), 'worktree', 'add', '-q', str(cls.gamma/'main'), 'main'], check=True)
        subprocess.run(['/usr/bin/git', '-C', str(cls.gamma), 'worktree', 'add', '-q', str(cls.gamma/'release'), '-b', 'release-line'],
                       check=True)
        # The base of the Worktrees that the New Worktree checks create; no check opens a Session in it.
        subprocess.run(['/usr/bin/git', '-C', str(cls.gamma), 'worktree', 'add', '-q', str(cls.gamma/'base'), '-b', 'base-line'], check=True)
        cls.config = s.root/'config/muxify/config.yaml'
        cls.config_text = ('sessions:\n  paths:\n    - path: ' + str(s.root/'projects') + '/*\n'
                           'topics:\n  title_command_fallbacks: /bin/sh ' + str(title_model) + '\n')
        cls.config.write_text(cls.config_text)
        # A running tmux server at launch, as a user has; no check uses this Session.
        s.tmux('new-session', '-d', '-s', 'base', '-c', str(cls.beta), SHELL)
        # Checks kill their Sessions and remove their Topic files when they end, so the Topic cards stay
        # short enough to show in the Sidebar. A client that end_session cannot move, as the app's control client, then
        # moves to another Session in place of detaching.
        s.tmux('set-option', '-g', 'detach-on-destroy', 'off')
        s.launch(['-sidebarVisible', 'YES', '-sessionsVisible', 'YES', '-agentsVisible', 'YES'])

    def setUp(self):
        if self.s.has('palette-search'):
            self.s.driver('action', 'palette-search', 'Close')
            self.s.wait_rows(lambda rs: not self.s.has('palette-search', rs), 'Palette did not close')
        self.show_view('topics')
        # An open group takes up to a third of the Sidebar, and the Topic list then builds fewer rows.
        rs = self.s.rows()
        for key in ['snoozed-topics', 'settled-topics']:
            if self.expanded(key, rs):
                # The previous check's cleanup can remove the group's last Topic, and the row with it, before the press.
                self.s.driver('press', key)
        self.s.wait_rows(lambda rs: not any(self.expanded(key, rs) for key in ['snoozed-topics', 'settled-topics']),
                         'a Topic group did not close')

    def new_session(self, name, project, command=SHELL, topic=None):
        sid = self.s.tmux('new-session', '-d', '-P', '-F', '#{session_id}', '-s', name, '-c', str(project), command)
        self.addCleanup(self.end_session, sid)
        if topic:
            self.s.tmux('set-option', '-t', sid, '@muxify_topic', topic)
            saved = next((row for row in self.records().get(topic, {}).get('sessions', []) if row.get('name') == name), None)
            if saved:
                self.s.tmux('set-option', '-t', sid, '@muxify_session_id', saved['id'])
        return sid

    def end_session(self, sid):
        """Kills the Session. A client on it moves to base first, and the check waits for the app to follow, so the
        Active Topic does not change under the next check."""
        if sid in self.s.tmux('list-clients', '-F', '#{session_id}').split():
            self.select_window('base:')
            self.s.wait_shown('base:')
        self.s.tmux_ok('kill-session', '-t', sid)

    def write_topic(self, topic_id, title, home, **fields):
        # A plain write, no temporary file: the way a person or script writes a Topic file by hand.
        path = self.topics_dir/(topic_id + '.json')
        self.addCleanup(remove_topic, path)
        with open(path, 'w') as handle:
            handle.write(json.dumps(dict(id=topic_id, title=title, slug=topic_id, **fields)))

    def records(self):
        out = {}
        for path in self.topics_dir.glob('*.json'):
            try:
                out[path.stem] = json.loads(path.read_text())
            except json.JSONDecodeError:
                pass
        return out

    def topic_rows(self, rs):
        """Topic header rows in Sidebar order."""
        skip = ('topic-window-',)
        return [key for key in self.s.ids(rs)
                if key.startswith('topic-') and '-session-' not in key and not key.startswith(skip)
                and not key.endswith('-more')]

    def describe(self, key, rs):
        row = self.s.row(key, rs)
        return '%s: %s | %s' % (key, row.get('accessibilityLabel', ''), row.get('accessibilityValue', ''))

    def rows_until(self, predicate, seconds=10):
        """Polls the UI as fast as the driver answers; (seconds until predicate held or None, last rows)."""
        start = time.monotonic()
        rs = []
        while time.monotonic() - start < seconds:
            rs = self.s.rows()
            if predicate(rs):
                return time.monotonic() - start, rs
        return None, rs

    def show_view(self, name):
        key = 'sidebar-view-' + name
        if self.s.row(key).get('accessibilityValue') != 'selected':
            self.s.act('press', key)
        self.s.wait_rows(lambda rs: self.s.row(key, rs).get('accessibilityValue') == 'selected', key + ' not selected')

    def expanded(self, key, rs):
        return self.s.row(key, rs).get('accessibilityValue', '').startswith('expanded')

    def find(self, key, message=None):
        """The rows once the row shows. A card far down the Topic list is not built until the list scrolls to it,
        so each try that misses scrolls the list to the row."""
        def found():
            rs = self.s.rows()
            if not self.s.has(key, rs):
                rs = self.s.driver('dump', key, reveal=True)['rows']
            return rs if self.s.has(key, rs) else None
        return wait(found, message or 'no row ' + key)

    def no_topic_cards(self, rs):
        """The Session IDs of the No Topic cards. The Topic list has one only while the selected Window is in No Topic."""
        return [key[len('no-topic-session-'):] for key in self.s.ids(rs)
                if key.startswith('no-topic-session-') and not key.endswith('-more')]

    def project_row(self, directory):
        """The New Topic or Add Session Path row of a Session Path or Worktree directory. Worktree rows follow git, a moment after the palette opens.
        The list builds only the rows it shows, so a row further down is found through the search.
        A row's id is its folder's real path, which differs from the Config spelling under /tmp."""
        key = 'palette-row-' + os.path.realpath(directory)
        if self.rows_until(lambda rs: self.s.has(key, rs), seconds=3)[0] is not None:
            return key
        def searched():
            # A set without focus fills the field but not its binding; a user focuses the field before typing.
            # A palette that is still opening can drop the text, so the search is set again until the row shows.
            self.s.act('focus', 'palette-search')
            self.s.act('set', 'palette-search', str(directory))
            return self.rows_until(lambda rs: self.s.has(key, rs), seconds=3)[0] is not None
        wait(searched, 'no Session Path row ' + key, seconds=20)
        return key

    def open_new_topic(self):
        """Presses the menu item until the palette shows. The menu follows a Topic change about a second after the
        store, so a press right after one can find the item still disabled."""
        def opened():
            self.s.driver('press', 'New Topic…')
            return self.rows_until(lambda rs: self.s.has('palette-search', rs), seconds=3)[0] is not None
        wait(opened, 'New Topic palette did not open', seconds=20)

    def create_topic(self, title):
        """Creates a Topic through the New Topic palette and waits for the empty-Topic view; returns its record."""
        s = self.s
        before = set(self.records())
        self.open_new_topic()
        # A set without focus fills the field but not its binding; a user focuses the field before typing.
        s.act('focus', 'palette-search')
        s.act('set', 'palette-search', title)
        s.wait_rows(lambda rs: s.row('palette-search', rs).get('accessibilityValue') == title, 'the title did not change')
        s.act('press', 'palette-accept')
        record = wait(lambda: [r for i, r in self.records().items() if i not in before and r.get('title') == title],
                      'no new Topic record for %r' % title, seconds=15)[0]
        self.addCleanup(remove_topic, self.topics_dir/(record['id'] + '.json'))
        s.wait_rows(lambda rs: 'Add a Session' in self.describe('palette-breadcrumb', rs),
                    'New Topic did not open Add a Session', seconds=15)
        s.act('press', 'palette-cancel')
        s.wait_rows(lambda rs: not s.has('palette-search', rs), 'Add Session Path palette did not close')
        s.wait_rows(lambda rs: s.row('empty-topic-title', rs).get('accessibilityValue') == title,
                    'the empty-Topic view does not show %r' % title)
        return record

    def open_add_session(self):
        """Opens the Add Session Path palette from the Add a Session Path button of the empty-Topic view."""
        s = self.s
        self.addCleanup(lambda: s.has('palette-accept') and s.act('press', 'palette-cancel'))
        s.act('press', 'empty-topic-add-session')
        s.wait_rows(lambda rs: s.has('palette-accept', rs), 'Add Session Path palette did not open')

    def pick_project(self, directory, worktree):
        """Selects the repository with an exact path query and sets New Worktree before the caller accepts it."""
        s = self.s
        s.act('focus', 'palette-search')
        s.act('set', 'palette-search', str(directory))
        key = self.project_row(directory)
        s.wait_rows(lambda rs: s.row(key, rs).get('accessibilityValue') == 'selected',
                    'the exact Session Path path did not select its row')
        want = 'on' if worktree else 'off'
        s.wait_rows(lambda rs: s.has('palette-new-worktree', rs),
                    'no New Worktree option for the repository row ' + str(directory))
        if s.row('palette-new-worktree').get('accessibilityValue') != want:
            s.act('press', 'palette-new-worktree')
            s.wait_rows(lambda rs: s.row('palette-new-worktree', rs).get('accessibilityValue') == want,
                        'New Worktree option is not %s' % want)

    def select_window(self, window):
        """Moves the app's tmux client to the Window, as tmux navigation does; the Sidebar follows the client."""
        for tty in self.s.tmux('list-clients', '-F', '#{client_tty}').split():
            self.s.tmux('switch-client', '-c', tty, '-t', window)

    def agent_session(self, name, topic=None, status='working', unread=False):
        """A Session whose only Pane runs an Agent; returns (session id, window id, pane id)."""
        command = ['new-session', '-d', '-P', '-F', '#{session_id} #{window_id} #{pane_id}',
                   '-s', name, '-c', str(self.beta), 'sleep 600',
                   ';', 'set-option', '-p', '@muxify_agent', 'claude',
                   ';', 'set-option', '-p', '@muxify_agent_status', status]
        if topic:
            command += [';', 'set-option', '@muxify_topic', topic]
        sid, window, pane = self.s.tmux(*command).split()
        self.addCleanup(self.end_session, sid)
        if unread:
            wait(lambda: self.s.tmux('display-message', '-p', '-t', pane, '#{pane_current_command}') == 'sleep',
                 'the Agent fixture process did not start', seconds=10)
            self.s.tmux('set-option', '-p', '-t', pane, '@muxify_agent_unread', '1')
        return sid, window, pane

    def press_menu_item(self, title):
        """The app updates its menu items a moment after its App Window gets focus, so a check that runs first
        in a fresh app can find the item still disabled."""
        wait(lambda: self.s.driver('press', title)['pressed'], 'the menu item %s stays disabled' % title, seconds=10)

    def set_show_agents(self, shown):
        """Sets View > Show Agents for the shown Sidebar mode. The driver presses the menu item without opening the menu."""
        if self.s.has('agents-header') != shown:
            self.press_menu_item('Show Agents')
        self.s.wait_rows(lambda rs: self.s.has('agents-header', rs) == shown,
                         'Agents section is not %s' % ('shown' if shown else 'hidden'))

    def wait_session(self, name):
        wait(lambda: self.s.tmux_ok('has-session', '-t', '=' + name).returncode == 0, 'no Session ' + name, seconds=10)

    def open_card(self, key):
        """Opens a card, a group or a grouped Topic row, each of which opens on a press.
        Muxify closes opened Topics when the selected Window moves to another Topic.
        A selection that arrives just before the press can open the card first, and the press then closes it,
        so the press repeats until the card stays open."""
        def opened():
            rs = self.find(key)
            if self.expanded(key, rs):
                return rs
            self.s.act('press', key)
            latency, rs = self.rows_until(lambda rs: self.expanded(key, rs), seconds=REFRESH_LIMIT)
            return rs if latency is not None else None
        return wait(opened, key + ' did not expand')

    def expand(self, key):
        """Opens a card, or a group row, and lists all its rows."""
        if self.s.has(key + '-more', self.open_card(key)):
            self.s.act('press', key + '-more')
            self.s.wait_rows(lambda rs: not self.s.has(key + '-more', rs), key + ' did not list all its rows')

    def grouped(self, key, group, rs):
        """Whether the Topic row sits in the group: the groups end the list, so the row follows the group row."""
        ids = self.s.ids(rs)
        return group in ids and key in ids and ids.index(key) > ids.index(group)

    def settled_rows(self, rs):
        return [key for key in self.topic_rows(rs) if self.grouped(key, 'settled-topics', rs)]

    def collapse(self, key):
        """Closes a group row. Waits for the row first: a group whose Topics are still loading has no row yet,
        and it would then appear in its remembered open state after the check decided not to press."""
        rs = self.s.wait_rows(lambda rs: self.s.has(key, rs), 'no row ' + key)
        if self.expanded(key, rs):
            self.s.act('press', key)
        self.s.wait_rows(lambda rs: not self.expanded(key, rs), key + ' did not collapse')

    def remove_topics(self, prefix):
        """Deletes the Topic files with the prefix and waits until their rows are gone, so later checks find their rows in view."""
        for path in self.topics_dir.glob(prefix + '*.json'):
            remove_topic(path)
        self.s.wait_rows(lambda rs: not any(key.startswith('topic-' + prefix) for key in self.s.ids(rs)),
                         'rows of the removed %s* Topics are still shown' % prefix)
