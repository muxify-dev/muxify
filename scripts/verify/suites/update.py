"""The Update Button and the Update Popover against a feed that the suite serves over http from its run directory.

MUXIFY_UPDATE_FEED_URL turns the updater on in the Debug app, which carries the test public key, and points it at
this feed. The Debug app is build 1, so a feed item of build 2 is newer and one of build 1 is not. The checks start
Check for Updates from the Commands palette or the app menu, open the popover with the button's press, and answer
with the popover's buttons. They never press Install and Relaunch, which would start a new copy and take Focus, and
never press the notes link, which would open a browser.

Run from the repo root after `make build`:
    python3 -m unittest -v scripts.verify.suites.update
"""

import http.server
import threading
import time
import unittest

from scripts.verify.sandbox import Sandbox, wait

RELEASE_NOTES = 'https://github.com/muxify-dev/muxify/releases/tag/v0.2.0'
COMMIT = 'https://github.com/muxify-dev/muxify/commit/a1b2c3d'
SIZE = 12345678
RELEASED = 'Wed, 11 Nov 2026 09:30:00 +0000'


def feed(build, version, link):
    """A one-item appcast as scripts/write-feed.py writes it. The signature is never checked: no check downloads."""
    return ('<?xml version="1.0" encoding="utf-8"?>\n'
            '<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">\n'
            '<channel><title>Muxify</title><item>\n'
            '<title>%(version)s</title><pubDate>%(date)s</pubDate><link>%(link)s</link>\n'
            '<sparkle:version>%(build)s</sparkle:version>\n'
            '<sparkle:shortVersionString>%(version)s</sparkle:shortVersionString>\n'
            '<sparkle:minimumSystemVersion>14.0</sparkle:minimumSystemVersion>\n'
            '<enclosure url="http://127.0.0.1:1/Muxify.zip" length="%(size)d" type="application/octet-stream"'
            ' sparkle:edSignature="%(signature)s"/>\n'
            '</item></channel></rss>\n') % dict(version=version, date=RELEASED, link=link, build=build, size=SIZE,
                                                signature='A' * 86 + '==')


class FeedServer:
    """Serves the feed on one port. `stop` makes it unreachable, and `start` serves it again on the same port."""

    def __init__(self):
        self.text = feed(2, '0.2.0', RELEASE_NOTES)
        self.delay = 0
        self.requests = 0
        self.port = 0
        self.server = None

    def start(self):
        owner = self

        class Handler(http.server.BaseHTTPRequestHandler):
            def do_GET(self):
                owner.requests += 1
                time.sleep(owner.delay)
                body = owner.text.encode()
                self.send_response(200)
                self.send_header('Content-Type', 'application/xml')
                self.send_header('Content-Length', str(len(body)))
                self.send_header('Cache-Control', 'no-store')
                self.end_headers()
                self.wfile.write(body)

            def log_message(self, *_):
                pass

        self.server = http.server.ThreadingHTTPServer(('127.0.0.1', self.port), Handler)
        self.port = self.server.server_address[1]
        threading.Thread(target=self.server.serve_forever, daemon=True).start()

    def stop(self):
        if self.server:
            self.server.shutdown()
            self.server.server_close()
            self.server = None

    @property
    def url(self):
        return 'http://127.0.0.1:%d/feed.xml' % self.port


class Update(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.s = s = Sandbox(__name__.rsplit('.', 1)[-1])
        cls.addClassCleanup(s.teardown)
        cls.feed = FeedServer()
        cls.feed.start()
        cls.addClassCleanup(cls.feed.stop)
        s.app_env['MUXIFY_UPDATE_FEED_URL'] = cls.feed.url
        s.tmux('new-session', '-d', '-s', 'update', '-c', str(s.root), '/bin/sh')
        s.launch()

    def setUp(self):
        if self.feed.server is None:
            self.feed.start()
        self.feed.text = feed(2, '0.2.0', RELEASE_NOTES)
        self.feed.delay = 0
        self.hide_button()

    # helpers

    def button(self, rs=None):
        return self.s.row('update-button', rs).get('accessibilityLabel')

    def wait_button(self, text, seconds=20):
        return self.s.wait_rows(lambda rs: self.button(rs) == text,
                                lambda: 'the Update Button does not show %r: it shows %r' % (text, self.button()), seconds)

    def wait_hidden(self, seconds=10):
        self.s.wait_rows(lambda rs: not self.s.has('update-button', rs),
                         lambda: 'the Update Button still shows %r' % self.button(), seconds)

    def hide_button(self):
        """Ends what the button shows from an earlier check, as the user would."""
        text = self.button()
        if text is None:
            return
        if text == 'No Updates Available':
            self.s.act('press', 'update-button')
        elif text.startswith('Update Available') or text == 'Update Failed':
            self.open_popover()
            self.s.act('press', 'update-later' if text != 'Update Failed' else 'update-ok')
        self.wait_hidden(seconds=20)

    def check_with_the_command(self):
        wait(lambda: self.s.driver('press', 'Commands')['pressed'], 'Commands did not open')
        self.s.wait_rows(lambda rs: self.s.has('palette-search', rs), 'the Commands field did not show')
        self.s.act('focus', 'palette-search')
        self.s.act('set', 'palette-search', 'Check for Updates')
        key = 'palette-row-command-Check for Updates'
        self.s.wait_rows(lambda rs: self.s.has(key, rs), 'Check for Updates is missing from Commands')
        self.s.act('press', key)

    def check_from_the_menu(self):
        wait(lambda: self.s.driver('press', 'Check for Updates…')['pressed'], 'the app menu has no Check for Updates…')

    def open_popover(self):
        # A press on the button while its popover is open closes it.
        if not self.s.has('update-popover'):
            self.s.act('press', 'update-button')
        return self.s.wait_rows(lambda rs: self.s.has('update-popover', rs), 'the Update Popover did not open')

    def log_text(self):
        return ''.join(path.read_text(errors='replace') for path in sorted((self.s.root/'logs').glob('muxify-*.log')))

    # checks

    def test_the_command_shows_checking_then_the_update_available(self):
        # The feed answers late, so the check lasts long enough to see.
        self.feed.delay = 3
        self.check_with_the_command()
        self.wait_button('Checking for Updates…', seconds=10)
        self.wait_button('Update Available: 0.2.0')

    def test_the_popover_opens_only_on_a_click(self):
        self.check_from_the_menu()
        self.wait_button('Update Available: 0.2.0')
        time.sleep(1)
        self.assertFalse(self.s.has('update-popover'), 'the Update Popover opened by itself')
        self.open_popover()

    def test_the_popover_shows_the_version_size_release_date_and_release_notes(self):
        self.check_from_the_menu()
        self.wait_button('Update Available: 0.2.0')
        rs = self.open_popover()
        values = {key: self.s.row(key, rs).get('accessibilityValue') for key in ('update-version', 'update-size', 'update-released')}
        self.assertEqual(values['update-version'], '0.2.0', values)
        self.assertRegex(values['update-size'] or '', r'^12[.,]3 MB$', values)
        self.assertRegex(values['update-released'] or '', r'2026', values)
        notes = self.s.row('update-notes', rs)
        self.assertEqual((notes.get('accessibilityLabel'), notes.get('accessibilityValue')), ('View Release Notes', RELEASE_NOTES))
        titles = {key: self.s.row(key, rs).get('accessibilityTitle') or self.s.row(key, rs).get('accessibilityLabel')
                  for key in ('update-skip', 'update-later', 'update-install')}
        self.assertEqual(titles, {'update-skip': 'Skip', 'update-later': 'Later', 'update-install': 'Install and Relaunch'})

    def test_a_tip_build_links_its_commit(self):
        self.feed.text = feed(2, 'a1b2c3d (2026-11-11)', COMMIT)
        self.check_from_the_menu()
        self.wait_button('Update Available: a1b2c3d (2026-11-11)')
        notes = self.s.row('update-notes', self.open_popover())
        self.assertEqual((notes.get('accessibilityLabel'), notes.get('accessibilityValue')), ('View GitHub Commit', COMMIT))

    def test_skip_hides_the_button_and_check_for_updates_still_shows_the_skipped_version(self):
        self.check_from_the_menu()
        self.wait_button('Update Available: 0.2.0')
        self.open_popover()
        self.s.act('press', 'update-skip')
        self.wait_hidden()
        self.assertIn('update: skipped 0.2.0 (build 2)', self.log_text())
        self.check_with_the_command()
        self.wait_button('Update Available: 0.2.0')

    def test_later_hides_the_button(self):
        self.check_with_the_command()
        self.wait_button('Update Available: 0.2.0')
        self.open_popover()
        self.s.act('press', 'update-later')
        self.wait_hidden()
        self.assertFalse(self.s.has('update-popover'), 'the Update Popover stayed open')

    def test_a_feed_without_a_newer_build_shows_no_updates_available_for_five_seconds(self):
        self.feed.text = feed(1, '0.1.0', RELEASE_NOTES)
        self.check_with_the_command()
        self.wait_button('No Updates Available')
        shown = time.monotonic()
        self.wait_hidden(seconds=15)
        self.assertGreater(time.monotonic() - shown, 3, 'No Updates Available went away before five seconds')

    def test_an_unreachable_feed_shows_update_failed_and_retry_checks_again(self):
        self.feed.stop()
        self.check_with_the_command()
        self.wait_button('Update Failed')
        rs = self.open_popover()
        self.assertTrue(self.s.row('update-failure-message', rs).get('accessibilityValue')
                        or self.s.row('update-failure-message', rs).get('accessibilityLabel'),
                        'the Update Popover shows no message: %s' % self.s.row('update-failure-message', rs))
        self.assertTrue(self.s.has('update-ok', rs) and self.s.has('update-retry', rs), 'the popover has no OK and Retry')
        self.feed.start()
        requests = self.feed.requests
        self.s.act('press', 'update-retry')
        self.wait_button('Update Available: 0.2.0')
        self.assertGreater(self.feed.requests, requests, 'Retry did not read the feed again')

    def test_ok_hides_update_failed(self):
        self.feed.stop()
        self.check_from_the_menu()
        self.wait_button('Update Failed')
        self.open_popover()
        self.s.act('press', 'update-ok')
        self.wait_hidden()

    def test_each_check_and_its_result_go_to_the_diagnostics_log(self):
        self.feed.text = feed(1, '0.1.0', RELEASE_NOTES)
        checks = self.log_text().count('update: check for updates, asked by the user')
        results = self.log_text().count('update: no newer build')
        self.check_from_the_menu()
        self.wait_button('No Updates Available')
        wait(lambda: self.log_text().count('update: check for updates, asked by the user') > checks
             and self.log_text().count('update: no newer build') > results,
             lambda: 'the Diagnostics log has no check and result:\n' + self.log_text()[-2000:], 10)


if __name__ == '__main__':
    unittest.main()
