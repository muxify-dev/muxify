"""Browser commands: an Agent in a Pane drives its own Window's Browser with `muxify browser`.

Each check runs the app's bundled CLI with the Pane's TMUX_PANE, as an Agent in that Pane does, so the CLI finds
the app through the sandbox server's `@muxify_browser_socket`. The commands never take focus, so the checks need
no driver command apart from showing a Window.

Run from the repo root after `make build`:
    python3 -m unittest -v scripts.verify.suites.browser_agent
"""

import json
import re
import struct
import subprocess
import unittest
import uuid

from scripts.verify.sandbox import Sandbox, wait

SHELL = '/bin/sh'

PAGE = '''<!doctype html>
<html><head><meta charset="utf-8"><title>Agent fixture</title></head><body>
<h1>Sign up</h1>
<label for="name">Name</label> <input id="name">
<button id="save">Save</button>
<p id="out">Nothing saved</p>
<p hidden>secret hidden text</p>
<form id="search"><input name="q" aria-label="Query"></form>
<a href="#details">Read the <b>details</b></a>
<script>
  window.fixtureMark = 'page-world';
  document.getElementById('save').addEventListener('click', () => setTimeout(() => {
    document.getElementById('out').textContent = 'Saved ' + document.getElementById('name').value;
  }, 300));
  document.getElementById('search').addEventListener('submit', (event) => {
    event.preventDefault();
    document.getElementById('out').textContent = 'Searched ' + event.target.q.value;
  });
</script>
</body></html>
'''


class BrowserAgent(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.s = s = Sandbox(__name__.rsplit('.', 1)[-1])
        cls.addClassCleanup(s.teardown)
        cls.page = s.root/'page.html'
        cls.page.write_text(PAGE)
        (s.root/'config/muxify/config.yaml').write_text('')
        cls.session = s.tmux('new-session', '-d', '-P', '-F', '#{session_id}', '-s', 'agent', '-x', '200', '-y', '50', SHELL)
        s.launch()
        wait(lambda: '0' in s.tmux('list-clients', '-F', '#{client_control_mode}').split(), 'the app attached no tmux client')
        cls.socket = wait(lambda: s.tmux('show-options', '-sqv', '@muxify_browser_socket'),
                          'the app did not publish its Browser socket')
        cls.cli = str(s.app/'Contents/Resources/bin/muxify')

    def window(self, name=None):
        """A new Window of the fixture Session, and its Pane."""
        name = name or self.id().rsplit('.', 1)[-1][5:]
        window, pane = self.s.tmux('new-window', '-d', '-P', '-F', '#{window_id} #{pane_id}',
                                   '-t', self.session + ':', '-n', name[:30], SHELL).split()
        return window, pane

    def url(self, tag):
        return self.page.as_uri() + '?' + tag

    def muxify(self, pane, *args):
        return subprocess.run([self.cli, 'browser', *args], env=dict(self.s.env, TMUX_PANE=pane),
                              capture_output=True, text=True, timeout=60)

    def ok(self, pane, *args):
        result = self.muxify(pane, *args)
        self.assertEqual(result.returncode, 0, 'muxify browser %s: %s' % (' '.join(args), result.stderr))
        return result.stdout

    def open(self, pane, tag):
        return json.loads(self.ok(pane, 'open', '--json', self.url(tag)))

    def stored_tabs(self, window):
        return self.s.tmux('show-options', '-wqv', '-t', window, '@muxify_tabs').split()

    def test_socket_sits_beside_the_tmux_socket(self):
        tmux_socket = self.s.tmux('display-message', '-p', '#{socket_path}')
        self.assertEqual(self.socket, tmux_socket + '.muxify-browser')

    def test_open_json_prints_the_tab_that_tabs_lists_as_the_agent_tab(self):
        window, pane = self.window()
        tab = self.open(pane, 'open-json')
        self.assertEqual(str(uuid.UUID(tab['id'])).upper(), tab['id'].upper())
        self.assertEqual(tab['url'], self.url('open-json'))
        self.assertEqual(tab['title'], 'Agent fixture', 'open returns after the page loaded')
        tabs = json.loads(self.ok(pane, 'tabs', '--json'))
        self.assertEqual([(t['id'], t['agent']) for t in tabs], [(tab['id'], True)])
        wait(lambda: self.stored_tabs(window) == [self.url('open-json')],
             'the Window does not keep the Tab: %s' % self.stored_tabs(window))

    def test_eval_runs_in_the_page_and_prints_json(self):
        _, pane = self.window()
        self.open(pane, 'eval')
        self.assertEqual(self.ok(pane, 'eval', 'window.fixtureMark'), '"page-world"\n')
        self.assertEqual(self.ok(pane, 'eval', 'await new Promise((done) => setTimeout(() => done({answer: 6 * 7}), 50))'),
                         '{"answer":42}\n')
        self.assertEqual(self.ok(pane, 'eval', 'const base = 2; return base + 1'), '3\n')
        self.assertEqual(self.ok(pane, 'eval', 'undefined'), 'undefined\n')
        failed = self.muxify(pane, 'eval', 'missingVariable.field')
        self.assertEqual(failed.returncode, 1)
        self.assertIn('ReferenceError', failed.stderr)

    def screenshot(self, pane, name):
        out = self.s.root/name
        self.assertEqual(self.ok(pane, 'screenshot', '--out', str(out)).strip(), str(out))
        return out

    def test_screenshot_of_the_shown_window_writes_a_png_of_the_page(self):
        window, pane = self.window()
        self.open(pane, 'screenshot-shown')
        self.s.show(window)
        width, height, dark = png_pixels(self.screenshot(pane, 'shown.png'))
        self.assertGreater(width * height, 10000, 'the PNG is %dx%d' % (width, height))
        self.assertGreater(dark, 100, 'the PNG shows no text of the page')

    def test_screenshot_of_a_window_that_the_app_does_not_show_writes_the_page(self):
        _, pane = self.window()
        self.open(pane, 'screenshot-unshown')
        _, _, dark = png_pixels(self.screenshot(pane, 'unshown.png'))
        self.assertGreater(dark, 100, 'the PNG shows no text of the page')

    def test_each_pane_reaches_the_agent_tab_of_its_own_window(self):
        first_window, first = self.window('own-first')
        second_window, second = self.window('own-second')
        first_tab = self.open(first, 'own-first')
        second_tab = self.open(second, 'own-second')
        self.assertNotEqual(first_tab['id'], second_tab['id'])
        self.assertEqual(self.ok(first, 'eval', 'location.search'), '"?own-first"\n')
        self.assertEqual(self.ok(second, 'eval', 'location.search'), '"?own-second"\n')
        other = self.muxify(first, 'eval', '--tab', second_tab['id'], 'location.search')
        self.assertEqual(other.returncode, 1, 'a Tab of another Window is not this Window\'s')
        self.assertIn('has no Tab', other.stderr)
        self.assertEqual(self.ok(second, 'eval', '--tab', second_tab['id'], 'location.search'), '"?own-second"\n')
        wait(lambda: self.stored_tabs(first_window) == [self.url('own-first')]
             and self.stored_tabs(second_window) == [self.url('own-second')],
             'each Window keeps only its own Tab: %s %s' % (self.stored_tabs(first_window), self.stored_tabs(second_window)))

    def test_a_pane_without_an_agent_tab_is_told_to_open_one(self):
        _, pane = self.window()
        result = self.muxify(pane, 'eval', 'document.title')
        self.assertEqual(result.returncode, 1)
        self.assertIn('muxify browser open', result.stderr)

    def test_open_without_json_also_makes_the_agent_tab(self):
        _, pane = self.window()
        self.assertEqual(self.ok(pane, 'open', self.url('plain-open')), '')
        self.assertEqual(self.ok(pane, 'eval', 'location.search'), '"?plain-open"\n')

    def refs(self, pane):
        """The snapshot, and the Ref of each line by its role and name, such as 'button "Save"'."""
        snapshot = self.ok(pane, 'snapshot')
        return snapshot, {match[0]: match[1] for match in re.findall(r'- (\w+ "[^"]*")[^\n]*\[ref=(e\d+)\]', snapshot)}

    def test_snapshot_shows_roles_names_and_refs_and_leaves_out_hidden_elements(self):
        _, pane = self.window()
        self.open(pane, 'snapshot')
        snapshot, refs = self.refs(pane)
        for line in ['- heading "Sign up" [level=1] [ref=', '- textbox "Name" [ref=', '- button "Save" [ref=',
                     ': Nothing saved', '- textbox "Query" [ref=', '- link "Read the details" [ref=']:
            self.assertIn(line, snapshot)
        self.assertIn('  - /url: ' + self.url('snapshot') + '#details', snapshot)
        self.assertNotIn('secret hidden text', snapshot)
        self.assertEqual(len(set(refs.values())), len(refs), 'each element has its own Ref: %s' % refs)

    def test_fill_click_and_wait_change_what_the_page_shows(self):
        _, pane = self.window()
        self.open(pane, 'fill-click')
        _, refs = self.refs(pane)
        self.assertEqual(self.ok(pane, 'fill', refs['textbox "Name"'], 'Ada Lovelace'), '')
        self.assertEqual(self.ok(pane, 'click', refs['button "Save"']), '')
        self.ok(pane, 'wait', '--text', 'Saved Ada Lovelace')
        self.assertEqual(self.ok(pane, 'eval', "document.getElementById('out').textContent"), '"Saved Ada Lovelace"\n')
        snapshot, _ = self.refs(pane)
        self.assertIn('- textbox "Name" [ref=%s]: Ada Lovelace' % refs['textbox "Name"'], snapshot)
        _, _, dark = png_pixels(self.screenshot(pane, 'saved.png'))
        self.assertGreater(dark, 100, 'the PNG shows no text of the page')

    def test_press_types_into_a_field_and_enter_submits_its_form(self):
        _, pane = self.window()
        self.open(pane, 'press')
        _, refs = self.refs(pane)
        for key in 'abc':
            self.ok(pane, 'press', key, refs['textbox "Query"'])
        self.ok(pane, 'press', 'Backspace')
        self.ok(pane, 'press', 'Enter')
        self.ok(pane, 'wait', '--selector', '#out', '--timeout', '5')
        self.assertEqual(self.ok(pane, 'eval', "document.getElementById('out').textContent"), '"Searched ab"\n')

    def test_commands_on_the_shown_window_leave_the_focus_where_it_was(self):
        window, pane = self.window()
        self.open(pane, 'focus')
        self.s.show(window)
        before = self.s.driver('responder')['responders']
        _, refs = self.refs(pane)
        self.ok(pane, 'fill', refs['textbox "Name"'], 'focus')
        self.ok(pane, 'click', refs['button "Save"'])
        self.ok(pane, 'press', 'a', refs['textbox "Query"'])
        self.ok(pane, 'wait', '--text', 'Saved focus')
        self.assertEqual(self.s.driver('responder')['responders'], before)
        self.assertNotIn('WKWebView', before, 'the Terminal keeps the focus that it had')

    def test_wait_fails_after_its_timeout_and_on_a_bad_selector(self):
        _, pane = self.window()
        self.open(pane, 'wait-timeout')
        self.ok(pane, 'wait', '--load')
        late = self.muxify(pane, 'wait', '--text', 'never on the page', '--timeout', '1')
        self.assertEqual(late.returncode, 1)
        self.assertIn('waited 1 s for the text "never on the page"', late.stderr)
        bad = self.muxify(pane, 'wait', '--selector', 'a:::b')
        self.assertEqual(bad.returncode, 2, bad.stderr)

    def test_refs_end_with_their_document_and_the_page_cannot_see_the_library(self):
        _, pane = self.window()
        self.open(pane, 'refs')
        _, refs = self.refs(pane)
        self.assertEqual(self.ok(pane, 'eval', 'typeof globalThis.muxifyAgent'), '"undefined"\n')
        self.ok(pane, 'eval', 'location.reload()')
        self.ok(pane, 'wait', '--load')
        stale = self.muxify(pane, 'click', refs['button "Save"'])
        self.assertEqual(stale.returncode, 1)
        self.assertIn('run muxify browser snapshot again', stale.stderr)


def png_pixels(path):
    """Width, height and the number of dark pixels, through sips's uncompressed BMP."""
    data = path.read_bytes()
    assert data[:8] == b'\x89PNG\r\n\x1a\n', 'not a PNG: %r' % data[:8]
    bmp = path.with_suffix('.bmp')
    subprocess.run(['sips', '-s', 'format', 'bmp', str(path), '--out', str(bmp)], check=True, capture_output=True)
    image = bmp.read_bytes()
    offset, = struct.unpack('<I', image[10:14])
    width, height = struct.unpack('<ii', image[18:26])
    step = struct.unpack('<H', image[28:30])[0] // 8
    pixels = image[offset:]
    dark = sum(1 for index in range(0, len(pixels) - 2, step) if max(pixels[index:index + 3]) < 80)
    return width, abs(height), dark


if __name__ == '__main__':
    unittest.main()
