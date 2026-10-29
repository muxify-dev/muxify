"""Browser History and the Suggestions under the address field, with `browser.history: true` in the Config.

Each check serves its pages from its own HTTP server in this process, so that they share one host that no other
check's pages share. The checks type into the address
field with the driver's `set`, which gives the field its whole text at once, as a paste does, so a check that wants
Inline completion sets one letter more than the text before. ↩ is the field's Submit accessibility action.

Run from the repo root after `make build`:
    python3 -m unittest -v scripts.verify.suites.browser_history
"""

import json
import socket
import subprocess
import threading
import time
import unittest
from functools import partial
from http.server import SimpleHTTPRequestHandler, ThreadingHTTPServer

from scripts.verify.sandbox import Sandbox, wait

SHELL = '/bin/sh'
PAGES = ('alpha', 'beta', 'gamma', 'agent', 'after-agent', 'cleared')
# A page of the file that the app reads at launch, visited 10 days before the run.
OLD_PAGE = 'http://old.test/page'
# Swift's JSONEncoder writes a Date as seconds since 2001-01-01.
APPLE_EPOCH = 978307200


class DualStackServer(ThreadingHTTPServer):
    """localhost can be ::1 or 127.0.0.1, so the server takes both."""
    address_family = socket.AF_INET6

    def server_bind(self):
        self.socket.setsockopt(socket.IPPROTO_IPV6, socket.IPV6_V6ONLY, 0)
        super().server_bind()


class QuietHandler(SimpleHTTPRequestHandler):
    def log_message(self, *args):
        pass


class BrowserHistory(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.s = s = Sandbox(__name__.rsplit('.', 1)[-1])
        cls.addClassCleanup(s.teardown)
        cls.site = s.root/'site'
        cls.site.mkdir()
        for name in PAGES:
            (cls.site/(name + '.html')).write_text('<!doctype html><title>%s page</title><p>%s</p>' % (name.title(), name))
        cls.history_file = s.root/'state/muxify/browser-history.json'
        cls.history_file.parent.mkdir(parents=True, exist_ok=True)
        ten_days_ago = time.time() - APPLE_EPOCH - 10 * 86400
        cls.history_file.write_text(json.dumps([{'key': OLD_PAGE, 'url': OLD_PAGE, 'title': 'Old page', 'topics': [],
                                                 'recent': [], 'folded': {'score': 1, 'at': ten_days_ago}}]))
        (s.root/'config/muxify/config.yaml').write_text('browser:\n  history: true\n')
        cls.session = s.tmux('new-session', '-d', '-P', '-F', '#{session_id}', '-s', 'history', '-x', '200', '-y', '50', SHELL)
        s.launch()
        wait(lambda: '0' in s.tmux('list-clients', '-F', '#{client_control_mode}').split(), 'the app attached no tmux client')
        cls.cli = str(s.app/'Contents/Resources/bin/muxify')

    def setUp(self):
        server = DualStackServer(('::', 0), partial(QuietHandler, directory=str(self.site)))
        self.addCleanup(server.server_close)
        self.addCleanup(server.shutdown)
        threading.Thread(target=server.serve_forever, daemon=True).start()
        self.host = 'localhost:%d' % server.server_address[1]

    def url(self, page):
        return 'http://%s/%s.html' % (self.host, page)

    def new_window(self):
        name = self.id().rsplit('.', 1)[-1][5:]
        window, pane = self.s.tmux('new-window', '-d', '-P', '-F', '#{window_id} #{pane_id}',
                                   '-t', self.session + ':', '-n', name[:30], SHELL).split()
        self.s.show(window)
        return window, pane

    def stored_tabs(self, window):
        return self.s.tmux('show-options', '-wqv', '-t', window, '@muxify_tabs').split()

    def new_tab(self):
        count = len(self.tab_titles())
        wait(lambda: self.s.driver('press', 'New Tab')['pressed'], 'New Tab stayed disabled')
        self.s.wait_rows(lambda rs: len(self.tab_titles(rs)) == count + 1, 'New Tab did not add a Tab')

    def tab_titles(self, rs=None):
        return [r.get('accessibilityValue') or r.get('accessibilityLabel') or ''
                for r in (rs if rs is not None else self.s.rows())
                if r.get('accessibilityIdentifier', '').startswith('browser-tab-title-')]

    def type_in_address_field(self, *texts):
        self.s.act('focus', 'browser-address')
        for text in texts:
            self.s.act('set', 'browser-address', text)

    def load_from_the_field(self, window, page):
        self.s.act('press', 'Open Location…')
        self.type_in_address_field(self.url(page))
        self.s.act('action', 'browser-address', 'Submit')
        wait(lambda: self.url(page) in self.stored_tabs(window), 'the Tab did not load ' + page)
        self.s.wait_rows(lambda rs: page.title() + ' page' in self.tab_titles(rs), 'the page %s did not finish loading' % page)

    def entries(self):
        try:
            return {entry['key']: entry for entry in json.loads(self.history_file.read_text())}
        except (FileNotFoundError, json.JSONDecodeError):
            return {}

    def wait_recorded(self, *pages):
        keys = [self.url(page) for page in pages]
        wait(lambda: all(key in self.entries() for key in keys),
             'Browser History did not record %s; the file has %s' % (pages, sorted(self.entries())), seconds=10)

    @staticmethod
    def value(row):
        return row.get('accessibilityValue') or row.get('accessibilityTitle') or ''

    def test_a_typed_letter_completes_the_host_and_return_opens_it(self):
        window, _ = self.new_window()
        self.new_tab()
        for page in ('alpha', 'beta', 'gamma'):
            self.load_from_the_field(window, page)
        self.wait_recorded('alpha', 'beta', 'gamma')
        self.assertEqual({self.entries()[self.url(page)]['title'] for page in ('alpha', 'beta', 'gamma')},
                         {'Alpha page', 'Beta page', 'Gamma page'})

        self.new_tab()
        self.type_in_address_field('l')
        try:
            rs = self.s.wait_rows(lambda rs: self.value(self.s.row('browser-address', rs)) == self.host,
                                  'the address field did not complete l to the host')
        except AssertionError:
            self.fail('the address field shows %r, not %r' % (self.value(self.s.row('browser-address')), self.host))
        suggestions = [self.s.row('browser-suggestion-%d' % index, rs) for index in range(8)]
        labels = [row.get('accessibilityLabel', '') for row in suggestions if row]
        self.assertEqual(labels[0], self.host, 'the host is the first Suggestion: %s' % labels)
        pages = [label for label in labels[1:] if label.startswith(self.host + '/')]
        self.assertEqual(set(pages), {self.host + '/' + page + '.html' for page in ('alpha', 'beta', 'gamma')},
                         'the pages follow the host: %s' % labels)
        self.assertEqual(labels[-1], 'l', 'the search row is last: %s' % labels)

        self.s.act('action', 'browser-address', 'Submit')
        wait(lambda: 'http://%s/' % self.host in self.stored_tabs(window),
             'Return did not open the host; the Tabs are %s' % self.stored_tabs(window))
        self.s.wait_rows(lambda rs: not self.s.has('browser-suggestions', rs), 'the list stayed after Return')

    def test_a_click_on_a_suggestion_opens_it(self):
        window, _ = self.new_window()
        self.new_tab()
        self.load_from_the_field(window, 'alpha')
        self.load_from_the_field(window, 'beta')
        self.wait_recorded('alpha')
        self.new_tab()
        self.type_in_address_field(self.host + '/al')
        page = self.host + '/alpha.html'
        rs = self.s.wait_rows(lambda rs: any(r.get('accessibilityLabel') == page for r in rs), 'no Suggestion for ' + page)
        row = next(r for r in rs if r.get('accessibilityLabel') == page)
        self.s.act('click', row['accessibilityIdentifier'])
        wait(lambda: self.stored_tabs(window) == [self.url('beta'), self.url('alpha')],
             'the click did not open the Suggestion in the new Tab; the Tabs are %s' % self.stored_tabs(window))

    def test_a_page_that_a_browser_command_loads_is_not_recorded(self):
        window, pane = self.new_window()
        result = subprocess.run([self.cli, 'browser', 'open', '--json', self.url('agent')], env=dict(self.s.env, TMUX_PANE=pane),
                                capture_output=True, text=True, timeout=60)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.load_from_the_field(window, 'after-agent')
        self.wait_recorded('after-agent')
        time.sleep(1)
        self.assertNotIn(self.url('agent'), self.entries(), 'Browser History recorded the page of a Browser command')

    def test_clear_last_hour_from_the_palette_forgets_only_the_visits_of_the_last_hour(self):
        window, _ = self.new_window()
        self.new_tab()
        self.load_from_the_field(window, 'cleared')
        self.wait_recorded('cleared')
        wait(lambda: self.s.driver('press', 'Commands')['pressed'], 'Commands did not open')
        self.s.wait_rows(lambda rs: self.s.has('palette-search', rs), 'Commands search did not show')
        self.s.act('focus', 'palette-search')
        self.s.act('set', 'palette-search', 'Clear Browser History')
        self.s.wait_rows(lambda rs: self.s.has('palette-row-command-Clear Browser History', rs), 'no Clear Browser History row')
        self.s.act('press', 'palette-row-command-Clear Browser History')
        ranges = ['Last hour', 'Last 6 hours', 'Last day', 'Last 3 days', 'Last 7 days', 'All time']
        rs = self.s.wait_rows(lambda rs: all(self.s.has('palette-row-clear-' + r, rs) for r in ranges),
                              'the Command did not list the ranges')
        self.assertIn(OLD_PAGE, self.entries(), 'the step cleared before a choice')
        self.s.act('press', 'palette-row-clear-Last hour')
        self.s.wait_rows(lambda rs: not self.s.has('palette-search', rs), 'the choice did not close the palette')
        wait(lambda: self.url('cleared') not in self.entries(),
             'Last hour did not forget the page; the file has %s' % sorted(self.entries()), seconds=10)
        self.assertIn(OLD_PAGE, self.entries(), 'Last hour forgot a visit of 10 days ago')

        # Another Window, so that the open Tab of the page is not a Suggestion.
        self.new_window()
        self.new_tab()
        typed = self.host + '/clea'
        self.type_in_address_field(typed)
        rs = self.s.wait_rows(lambda rs: any(r.get('accessibilityLabel') == typed for r in rs), 'the Suggestions did not show')
        labels = [r.get('accessibilityLabel', '') for r in rs if r.get('accessibilityIdentifier', '').startswith('browser-suggestion-')]
        self.assertNotIn(self.host + '/cleared.html', labels, 'the cleared page is still a Suggestion')


if __name__ == '__main__':
    unittest.main()
