"""The Update Button and the Update Popover against a feed that the suite serves over http from its run directory.

MUXIFY_UPDATE_FEED_URL turns the updater on in the Debug app, which carries the test public key, and points it at
this feed. The Debug app is build 1, so a feed item of build 2 is newer and one of build 1 is not. `Update` runs the
app with `update.check: false`, so no background check races its checks: they start Check for Updates from the
Commands palette or the app menu, open the popover with the button's press, and answer with the popover's buttons.
`BackgroundCheck` runs a second app with the default Config, whose background check at launch, and on a channel
change in the Config, shows the Update Button by itself without taking Focus. They never press the notes link, which would open a browser. Only one check presses
Install and Relaunch, on a zip that is not signed with the app's key, which Sparkle refuses before it installs:
an install that went through would quit the app, start a new copy and take Focus.

Run from the repo root after `make build`:
    python3 -m unittest -v scripts.verify.suites.update
"""

import hashlib
import http.server
import os
import pathlib
import plistlib
import re
import shutil
import subprocess
import threading
import time
import unittest

from scripts.verify.sandbox import Sandbox, wait

RELEASE_NOTES = 'https://github.com/muxify-dev/muxify/releases/tag/v0.2.0'
COMMIT = 'https://github.com/muxify-dev/muxify/commit/a1b2c3d'
SIZE = 12345678
RELEASED = 'Wed, 11 Nov 2026 09:30:00 +0000'


def feed(build, version, link, enclosure='http://127.0.0.1:1/Muxify.zip', size=SIZE):
    """A one-item appcast as scripts/write-feed.py writes it. Its signature is 64 zero bytes, which no key made, so
    Sparkle refuses its zip; only the wrongly signed zip's check downloads it."""
    return ('<?xml version="1.0" encoding="utf-8"?>\n'
            '<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">\n'
            '<channel><title>Muxify</title><item>\n'
            '<title>%(version)s</title><pubDate>%(date)s</pubDate><link>%(link)s</link>\n'
            '<sparkle:version>%(build)s</sparkle:version>\n'
            '<sparkle:shortVersionString>%(version)s</sparkle:shortVersionString>\n'
            '<sparkle:minimumSystemVersion>14.0</sparkle:minimumSystemVersion>\n'
            '<enclosure url="%(enclosure)s" length="%(size)d" type="application/octet-stream"'
            ' sparkle:edSignature="%(signature)s"/>\n'
            '</item></channel></rss>\n') % dict(version=version, date=RELEASED, link=link, build=build, size=size,
                                                enclosure=enclosure, signature='A' * 86 + '==')


def front_app():
    """The bundle id of the app in front, which a check must leave in front."""
    front = subprocess.run(['lsappinfo', 'front'], capture_output=True, text=True).stdout.strip()
    info = subprocess.run(['lsappinfo', 'info', '-only', 'bundleid', front], capture_output=True, text=True).stdout
    match = re.search(r'"CFBundleIdentifier"="([^"]*)"', info)
    return match.group(1) if match else None


def start_app(test_class, name, config):
    """A Sandbox app on its own feed, with `config` as its Config."""
    test_class.s = s = Sandbox(name)
    # Sparkle keeps a download and its installer's files under the run's own bundle id; after the teardown.
    for folder in ('Caches', 'HTTPStorages'):
        test_class.addClassCleanup(shutil.rmtree, pathlib.Path.home()/'Library'/folder/s.bundle_id, ignore_errors=True)
    test_class.addClassCleanup(s.teardown)
    test_class.feed = FeedServer()
    test_class.feed.start()
    test_class.addClassCleanup(test_class.feed.stop)
    (s.root/'config/muxify/config.yaml').write_text(config)
    s.app_env['MUXIFY_UPDATE_FEED_URL'] = test_class.feed.url
    s.tmux('new-session', '-d', '-s', 'update', '-c', str(s.root), '/bin/sh')
    test_class.front = front_app()
    s.launch()


def log_text(s):
    return ''.join(path.read_text(errors='replace') for path in sorted((s.root/'logs').glob('muxify-*.log')))


def wrongly_signed_zip(folder, bundle_id):
    """A zip of a Muxify.app of build 2 that the feed's signature does not match. A random file makes it big
    enough that the download shows its progress while the server sends it slowly."""
    app = folder/'zip'/'Muxify.app'
    (app/'Contents/MacOS').mkdir(parents=True, exist_ok=True)
    with open(app/'Contents/Info.plist', 'wb') as f:
        plistlib.dump(dict(CFBundleIdentifier=bundle_id, CFBundleName='Muxify', CFBundleExecutable='MuxifyApp',
                           CFBundlePackageType='APPL', CFBundleVersion='2', CFBundleShortVersionString='0.2.0'), f)
    executable = app/'Contents/MacOS/MuxifyApp'
    executable.write_text('#!/bin/sh\nexit 0\n')
    executable.chmod(0o755)
    (app/'Contents/Resources').mkdir(exist_ok=True)
    (app/'Contents/Resources/padding').write_bytes(os.urandom(2 * 1024 * 1024))
    archive = folder/'Muxify-wrongly-signed.zip'
    subprocess.run(['ditto', '-c', '-k', '--keepParent', str(app), str(archive)], check=True)
    return archive.read_bytes()


class FeedServer:
    """Serves the feed on one port. `stop` makes it unreachable, and `start` serves it again on the same port."""

    def __init__(self):
        self.text = feed(2, '0.2.0', RELEASE_NOTES)
        self.delay = 0
        self.requests = 0
        # The zip at /Muxify.zip, sent in 64 KB pieces a tenth of a second apart.
        self.zip = b''
        self.zip_requests = 0
        self.port = 0
        self.server = None

    def start(self):
        owner = self

        class Handler(http.server.BaseHTTPRequestHandler):
            def do_GET(self):
                if self.path == '/Muxify.zip':
                    return self.send_zip()
                owner.requests += 1
                time.sleep(owner.delay)
                body = owner.text.encode()
                self.send_response(200)
                self.send_header('Content-Type', 'application/xml')
                self.send_header('Content-Length', str(len(body)))
                self.send_header('Cache-Control', 'no-store')
                self.end_headers()
                self.wfile.write(body)

            def send_zip(self):
                owner.zip_requests += 1
                self.send_response(200)
                self.send_header('Content-Type', 'application/zip')
                self.send_header('Content-Length', str(len(owner.zip)))
                self.end_headers()
                piece = 64 * 1024
                for start in range(0, len(owner.zip), piece):
                    self.wfile.write(owner.zip[start:start + piece])
                    self.wfile.flush()
                    time.sleep(0.1)

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

    @property
    def zip_url(self):
        return 'http://127.0.0.1:%d/Muxify.zip' % self.port


class Update(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        start_app(cls, __name__.rsplit('.', 1)[-1], 'update:\n  check: false\n')

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
        return log_text(self.s)

    # checks

    def test_with_check_off_nothing_shows_until_check_for_updates(self):
        # Every other check of this class asks first, so the feed was read only if one of them ran before.
        requests = self.feed.requests
        time.sleep(3)
        self.assertFalse(self.s.has('update-button'), 'the Update Button showed with update.check: false')
        self.assertEqual(self.feed.requests, requests, 'a background check read the feed with update.check: false')
        log = self.log_text()
        self.assertIn('update: background checks off, stable channel', log)
        self.assertNotIn('update: background check,', log)
        self.check_from_the_menu()
        self.wait_button('Update Available: 0.2.0')

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

    def test_install_and_relaunch_on_a_wrongly_signed_zip_shows_the_download_then_update_failed(self):
        self.feed.zip = wrongly_signed_zip(self.s.root/'wrongly-signed', self.s.bundle_id)
        self.feed.text = feed(2, '0.2.0', RELEASE_NOTES, enclosure=self.feed.zip_url, size=len(self.feed.zip))
        installed = {path: hashlib.sha256((self.s.app/path).read_bytes()).hexdigest()
                     for path in ('Contents/Info.plist', 'Contents/MacOS/MuxifyApp')}
        pid = self.s.pid
        logged = self.log_text()
        self.check_with_the_command()
        self.wait_button('Update Available: 0.2.0')
        # Nothing downloads before Install and Relaunch.
        time.sleep(1)
        self.assertEqual(self.feed.zip_requests, 0, 'the zip downloaded before Install and Relaunch')
        self.open_popover()
        self.s.act('press', 'update-install')
        progress = self.s.wait_rows(lambda rs: (self.button(rs) or '').startswith('Downloading'),
                                    lambda: 'the Update Button shows no download: it shows %r' % self.button(), 20)
        self.assertRegex(self.button(progress), r'^Downloading(: \d{1,3}%|…)$')
        self.wait_button('Update Failed', seconds=60)
        rs = self.open_popover()
        message = self.s.row('update-failure-message', rs)
        self.assertIn('improperly signed', message.get('accessibilityValue') or message.get('accessibilityLabel') or '',
                      message)
        self.assertTrue(self.s.has('update-ok', rs) and self.s.has('update-retry', rs), 'the popover has no OK and Retry')
        self.assertEqual(self.feed.zip_requests, 1)
        # Nothing is installed, and the app keeps running in its own process.
        self.assertEqual({path: hashlib.sha256((self.s.app/path).read_bytes()).hexdigest() for path in installed},
                         installed, 'the update changed the app')
        self.assertEqual(self.s.pid, pid)
        os.kill(pid, 0)
        self.s.act('press', 'update-ok')
        self.wait_hidden()
        log = self.log_text()[len(logged):]
        for line in ('update: install and relaunch 0.2.0 (build 2)', 'update: downloading 0.2.0 (build 2)',
                     'update: failed: The update is improperly signed'):
            self.assertIn(line, log)
        self.assertNotIn('update: installed', log)


class BackgroundCheck(unittest.TestCase):
    """The default Config: a background check at launch, the first launch included, and on a channel change."""

    @classmethod
    def setUpClass(cls):
        start_app(cls, 'update-background', '')

    def button(self, rs=None):
        return self.s.row('update-button', rs).get('accessibilityLabel')

    def wait_button(self, text, seconds=20):
        """Waits for `text`, and returns every text that the Update Button showed on the way."""
        shown = []

        def showing(rs):
            text_now = self.button(rs)
            if text_now not in shown:
                shown.append(text_now)
            return text_now == text

        self.s.wait_rows(showing, lambda: 'the Update Button does not show %r: it showed %r' % (text, shown), seconds)
        return shown

    def assert_focus_unchanged(self, responders):
        time.sleep(1)
        self.assertFalse(self.s.has('update-popover'), 'a background check opened the Update Popover')
        self.assertEqual(self.s.driver('responder')['responders'], responders, 'a background check moved Focus')
        self.assertEqual(front_app(), self.front, 'a background check brought an app to the front')

    def test_1_the_launch_shows_the_update_button_with_no_user_action(self):
        responders = self.s.driver('responder')['responders']
        shown = self.wait_button('Update Available: 0.2.0')
        self.assertNotIn('Checking for Updates…', shown)
        self.assert_focus_unchanged(responders)
        self.assertGreaterEqual(self.feed.requests, 1)
        log = log_text(self.s)
        self.assertIn('update: background check, stable channel', log)
        self.assertIn('update: found 0.2.0 (build 2), background check', log)
        self.assertNotIn('asked by the user', log)

    def test_2_a_channel_change_in_the_config_checks_again_at_once(self):
        if self.button() is None:
            self.wait_button('Update Available: 0.2.0')
        # Later hides the button until the next background check finds the update again.
        if not self.s.has('update-popover'):
            self.s.act('press', 'update-button')
        self.s.wait_rows(lambda rs: self.s.has('update-popover', rs), 'the Update Popover did not open')
        self.s.act('press', 'update-later')
        self.s.wait_rows(lambda rs: not self.s.has('update-button', rs), 'Later did not hide the Update Button')
        responders = self.s.driver('responder')['responders']
        requests = self.feed.requests
        # The feed answers late, so "Checking for Updates…" would show if the check showed it.
        self.feed.delay = 3
        (self.s.root/'config/muxify/config.yaml').write_text('update:\n  channel: tip\n')
        shown = self.wait_button('Update Available: 0.2.0', seconds=30)
        self.assertEqual([text for text in shown if text is not None], ['Update Available: 0.2.0'], shown)
        self.assertGreater(self.feed.requests, requests, 'the channel change read no feed')
        self.assertIn('update: channel tip', log_text(self.s))
        self.assert_focus_unchanged(responders)


if __name__ == '__main__':
    unittest.main()
