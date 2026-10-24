"""Find in Page, Vim Keys, Paste Path and Reopen Closed Tab in the Browser.

The checks dispatch keys inside the page, because the driver must not type keys (README: "Do not take focus").
A Vim Key dispatched there still reaches WebKit as the key it stands for, so the page scrolls for real.
The fixture page reports its scroll positions, the Find in Page highlight and its key results in its title,
which the Tab strip shows. The Paste Path check opens the palette from its View menu item.

Run from the repo root after `make build`:
    python3 -m unittest -v scripts.verify.suites.browser
"""

import re
import time
import unittest
from urllib.parse import unquote

from scripts.verify.sandbox import Sandbox, wait

SHELL = '/bin/zsh -f'
# The app reads tmux once per second.
SETTLE = 2.0

PAGE = '''<!doctype html>
<html><head><meta charset="utf-8"><style>
  body { margin: 0; font: 16px sans-serif; }
  #inner { height: 150px; overflow: auto; border: 1px solid gray; }
  #inner div { height: 2000px; }
  .spacer { height: 4000px; }
</style></head><body>
<input id="field">
<div id="inner"><div>inner scroller<p style="margin-top: 300px">clipped marker</p></div></div>
<p>needle one</p>
<p>nee<b>dle</b> two crosses an inline element</p>
<p>needle three</p>
<div class="spacer"></div>
<p>needle and the distant marker</p>
<div class="spacer"></div>
<script>
  const params = new URLSearchParams(location.search);
  const steps = [];
  let sent = 'waiting', passed = 0, native = 0;
  // Registered after the Vim Keys listener, so it sees whether Vim Keys took the key.
  addEventListener('keydown', (event) => { if (!event.defaultPrevented) passed++; });
  // Only WebKit makes a trusted key, so it counts the keys that Vim Keys pressed in place of a letter.
  addEventListener('keydown', (event) => { if (event.isTrusted) native++; });
  const position = () => {
    const bottom = document.scrollingElement.scrollHeight - innerHeight;
    return scrollY < 1 ? 'top' : Math.abs(scrollY - bottom) < 2 ? 'bottom' : String(Math.round(scrollY));
  };
  const send = (keys) => {
    for (const key of keys) {
      for (const type of ['keydown', 'keyup']) {
        (document.activeElement || document.body).dispatchEvent(
          new KeyboardEvent(type, { key, bubbles: true, cancelable: true, composed: true }));
      }
    }
  };
  // Holds each key as a person does. Just after a focus change, WebKit drops an arrow key whose key up comes in the same tick.
  const hold = async (keys) => {
    for (const key of keys) {
      const target = document.activeElement || document.body;
      for (const type of ['keydown', 'keyup']) {
        target.dispatchEvent(new KeyboardEvent(type, { key, bubbles: true, cancelable: true, composed: true }));
        await new Promise((done) => setTimeout(done, 100));
      }
    }
  };
  if (params.has('frame')) {
    const frame = document.createElement('iframe');
    frame.sandbox = 'allow-scripts';
    frame.src = 'frame.html';
    document.body.prepend(frame);
  }
  // A panel that a transform keeps below the viewport, as the chat of a narrow Lavish review.
  if (params.has('sheet')) {
    const sheet = document.createElement('aside');
    sheet.style.cssText = 'position: fixed; left: 0; right: 0; top: 0; height: 50vh; transform: translateY(100vh)';
    sheet.innerHTML = '<div style="height: 100%; overflow: auto">needle in a closed sheet</div>';
    document.body.append(sheet);
  }
  // A link over the whole page, so a click at the centre of the Browser lands on it.
  if (params.has('link')) {
    const link = Object.assign(document.createElement('a'), { href: location.pathname + '?' + params.get('link') });
    link.style.cssText = 'position: fixed; inset: 0';
    document.body.append(link);
  }
  if (params.has('invisible')) document.body.insertAdjacentHTML('beforeend', '<p style="visibility: hidden">needle unseen</p>');
  if (params.has('fill')) {
    document.body.style.cssText = 'height: 100vh; overflow: hidden';
    document.querySelector('iframe').style.cssText = 'width: 100vw; height: 90vh; border: 0';
  }
  setInterval(() => {
    const found = CSS.highlights.get('muxify-find');
    document.title = `mx q=${location.search.slice(1)} y=${Math.round(scrollY)} inner=${Math.round(inner.scrollTop)} hl=${found ? found.size : 0} passed=${passed} native=${native} active=${document.activeElement ? document.activeElement.tagName : 'none'}`
      + ` sent=${sent} steps=${steps.join('/')} value=${encodeURIComponent(field.value)}`;
  }, 100);
  addEventListener('load', () => setTimeout(async () => {
    if (params.has('focus')) field.focus();
    if (params.has('pagekeys')) document.addEventListener('keydown', (event) => event.preventDefault());
    if (params.has('escape')) field.dispatchEvent(new KeyboardEvent('keydown', { key: 'Escape', bubbles: true, cancelable: true }));
    if (params.has('history')) { location.hash = 'second'; await new Promise((done) => setTimeout(done, 300)); }
    // Only from a new Tab, so going Back to this page stays on it.
    if (params.has('goto') && history.length === 1) location.search = params.get('goto');
    if (params.has('every')) setInterval(() => send(params.get('every')), 200);
    for (const group of (params.get('keys') || '').split(',').filter(Boolean)) {
      if (params.has('held')) await hold(group); else send(group);
      await new Promise((done) => setTimeout(done, 1500));
      steps.push(params.has('history') ? location.hash.slice(1) || 'start' : position());
    }
    sent = 'yes';
  }, 300));
</script>
</body></html>
'''


class Browser(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.s = s = Sandbox(__name__.rsplit('.', 1)[-1])
        cls.addClassCleanup(s.teardown)
        cls.page = s.root/'page.html'
        cls.page.write_text(PAGE)
        (s.root/'frame.html').write_text('<!doctype html><p>needle in a sandboxed frame</p>')
        cls.config = s.root/'config/muxify/config.yaml'
        cls.config.write_text('')
        cls.session = s.tmux('new-session', '-d', '-P', '-F', '#{session_id}', '-s', 'browser', '-x', '200', '-y', '50', SHELL)
        s.launch(['-sidebarVisible', 'YES', '-sessionsVisible', 'YES'])
        wait(lambda: '0' in s.tmux('list-clients', '-F', '#{client_control_mode}').split(), 'the app attached no tmux client')

    def open_page(self, query, left=(), right=(), shows=None):
        """A new Window whose Browser shows the fixture page with the query, selected in the app's tmux client.
        The Tabs with the URLs in `left` and `right` stand on each side of it. `shows` is the query of the page
        that the Tab goes on to by itself."""
        name = self.id().rsplit('.', 1)[-1][5:]
        self.query = shows or query
        url = self.page.as_uri() + '?' + query
        tabs = ' '.join([*left, url, *right])
        # One tmux call, so the app never reads the Window without its Browser options.
        options = [arg for option, value in [('@muxify_tabs', tabs), ('@muxify_active_tab', str(len(left))), ('@muxify_browser', 'on')]
                   for arg in (';', 'set-option', '-w', '-t', 'browser:' + name, option, value)]
        self.s.tmux('new-window', '-d', '-t', self.session + ':', '-n', name, SHELL, *options)
        window = self.s.tmux('display-message', '-p', '-t', 'browser:' + name, '#{window_id}')
        for tty in self.s.tmux('list-clients', '-F', '#{client_tty} #{client_control_mode}').split('\n'):
            if tty.endswith(' 0'):
                self.s.tmux('switch-client', '-c', tty.split()[0], '-t', window)
        self.s.wait_shown(window)
        self.window = window
        self.wait_page(lambda page: True, 'the Tab does not show the fixture page')

    def page_state(self, rs=None):
        """The fields of this check's fixture page's title, from the Tab strip."""
        for row in rs if rs is not None else self.s.rows():
            if row.get('accessibilityIdentifier', '').startswith('browser-tab-title-'):
                for key in ('accessibilityValue', 'accessibilityLabel', 'accessibilityTitle'):
                    page = dict(re.findall(r'(\w+)=(\S*)', str(row.get(key, ''))))
                    if page.get('q') == self.query:
                        return page
        return None

    def wait_page(self, predicate, message, seconds=20):
        try:
            rs = self.s.wait_rows(lambda rs: (lambda page: page is not None and predicate(page))(self.page_state(rs)),
                                  message, seconds)
        except AssertionError:
            self.fail('%s: the page reports %s' % (message, self.page_state()))
        return self.page_state(rs)

    def wait_sent(self):
        return self.wait_page(lambda page: page['sent'] == 'yes', 'the page did not send its keys')

    def stored_tabs(self):
        """The Tabs and the active Tab that the app wrote onto this check's tmux Window."""
        option = lambda name: self.s.tmux('show-options', '-wqv', '-t', self.window, name)
        return option('@muxify_tabs').split(), option('@muxify_active_tab')

    def press_menu(self, title):
        # SwiftUI rebuilds the View menu a moment after the state it reads changes, and a press in that moment can miss.
        wait(lambda: self.s.driver('press', title)['pressed'], '%s stays disabled' % title, seconds=10)

    def find_status(self, rs=None):
        row = self.s.row('browser-find-status', rs)
        return row.get('accessibilityValue') or row.get('accessibilityLabel') or row.get('accessibilityTitle') or ''

    def find(self, query):
        self.s.act('action', 'browser-panel', 'Find in Page')
        self.s.wait_rows(lambda rs: self.s.has('browser-find-field', rs), 'Find in Page did not show the find bar')
        self.s.act('focus', 'browser-find-field')
        self.s.act('set', 'browser-find-field', query)

    def wait_status(self, expected, message):
        try:
            self.s.wait_rows(lambda rs: self.find_status(rs) == expected, message)
        except AssertionError:
            self.fail('%s: the status is %r, not %r' % (message, self.find_status(), expected))

    def reload_config(self, text):
        self.config.write_text(text)
        wait(lambda: self.s.driver('press', 'Reload Config')['pressed'], 'Reload Config stays disabled', seconds=10)

    # Find in Page

    def test_find_counts_matches_and_next_goes_to_the_second(self):
        self.open_page('find=count')
        self.find('Needle')
        self.wait_status('1 of 4', 'Find in Page did not count the matches')
        self.s.act('press', 'browser-find-next')
        self.wait_status('2 of 4', 'Find Next did not go to the second match')

    def test_find_highlights_every_match(self):
        self.open_page('find=highlight')
        self.find('needle')
        self.wait_page(lambda page: page['hl'] == '4', 'the page does not highlight all 4 matches')

    def test_find_scrolls_to_a_match_below_the_page(self):
        self.open_page('find=scroll')
        self.find('distant marker')
        self.wait_status('1 of 1', 'Find in Page did not find the distant marker')
        self.wait_page(lambda page: int(page['y']) > 1000, 'Find in Page did not scroll to the distant marker')

    def test_find_counts_and_reaches_a_match_in_an_iframe(self):
        self.open_page('find=frame&frame')
        self.find('needle')
        self.wait_status('1 of 5', 'Find in Page did not count the match in the iframe')
        self.s.act('press', 'browser-find-previous')
        self.wait_status('5 of 5', 'Find Previous did not wrap to the last match')

    def test_find_scrolls_a_match_that_a_scroller_clips(self):
        self.open_page('find=clipped')
        self.find('clipped marker')
        self.wait_status('1 of 1', 'Find in Page did not find the clipped marker')
        self.wait_page(lambda page: int(page['inner']) > 0, 'Find in Page did not scroll the inner scroller to the clipped marker')

    def test_find_skips_a_match_in_a_fixed_panel_below_the_viewport(self):
        self.open_page('find=sheet&sheet')
        self.find('needle')
        self.wait_status('1 of 4', 'Find in Page counted the match in the closed sheet')

    def test_find_skips_a_match_with_visibility_hidden(self):
        self.open_page('find=invisible&invisible')
        self.find('needle')
        self.wait_status('1 of 4', 'Find in Page counted the match with visibility: hidden')

    def test_find_shows_not_found(self):
        self.open_page('find=missing')
        self.find('no such text')
        self.wait_status('Not found', 'Find in Page did not say that nothing matches')

    def test_done_hides_the_find_bar_clears_the_highlight_and_gives_the_page_focus(self):
        self.open_page('find=done')
        self.find('needle')
        self.wait_page(lambda page: page['hl'] == '4', 'the page does not highlight the matches')
        self.s.act('press', 'browser-find-done')
        self.s.wait_rows(lambda rs: not self.s.has('browser-find-field', rs), 'Done did not hide the find bar')
        self.wait_page(lambda page: page['hl'] == '0', 'Done did not clear the highlight')
        wait(lambda: 'WKWebView' in self.s.driver('responder')['responders'], 'Done did not give the page Focus')

    # Focus

    def test_focus_browser_gives_focus_to_an_iframe_that_fills_the_page(self):
        self.open_page('fill&frame&case=fill')
        self.s.driver('press', 'Focus Browser')
        wait(lambda: 'WKWebView' in self.s.driver('responder')['responders'], 'Focus Browser did not give the page Focus')
        self.wait_page(lambda page: page['active'] == 'IFRAME', 'Focus Browser left the keys in a main frame that cannot scroll')

    def test_focus_browser_keeps_focus_in_a_page_that_scrolls(self):
        self.open_page('frame&case=scrolls')
        self.s.driver('press', 'Focus Browser')
        wait(lambda: 'WKWebView' in self.s.driver('responder')['responders'], 'Focus Browser did not give the page Focus')
        time.sleep(1)
        self.assertEqual(self.page_state()['active'], 'BODY', 'Focus Browser moved focus out of a main frame that scrolls')

    # Vim Keys

    def test_j_scrolls_the_page_and_stops(self):
        self.open_page('keys=jjj')
        page = self.wait_sent()
        time.sleep(1)
        self.assertEqual(page['native'], '3', 'jjj did not press Down Arrow three times')
        self.assertNotIn(page['steps'], ('top', 'bottom'), 'jjj did not scroll the page by three steps')
        self.assertEqual(self.page_state()['y'], page['steps'], 'the page kept scrolling after the last j went up')

    def test_g_g_goes_to_the_top_after_shift_g_goes_to_the_bottom(self):
        self.open_page('keys=G,gg')
        page = self.wait_sent()
        self.assertEqual(page['steps'], 'bottom/top', 'G did not go to the bottom, or gg to the top')

    def test_d_scrolls_most_of_a_screen(self):
        self.open_page('keys=d')
        page = self.wait_sent()
        self.assertGreater(int(page['y']), 200, 'd did not scroll the page by most of a screen')

    def test_shift_h_goes_back_and_shift_l_goes_forward(self):
        self.open_page('history&keys=H,L')
        page = self.wait_sent()
        self.assertEqual(page['steps'], 'start/second', 'H did not go back, or L did not go forward')

    def test_command_click_opens_the_link_in_a_new_tab(self):
        self.open_page('link=case=opened')
        self.s.act('click', 'browser-panel', command_key=True)
        self.query = 'case=opened'
        self.wait_page(lambda page: True, 'a ⌘-click on a link did not open the link in a new Tab')
        self.query = 'link=case=opened'
        self.assertIsNotNone(self.page_state(), 'a ⌘-click on a link left its own Tab')

    def test_j_in_a_text_field_types_and_does_not_scroll(self):
        self.open_page('focus&keys=jjj')
        self.wait_sent()
        time.sleep(1)
        page = self.page_state()
        self.assertEqual((page['passed'], page['y'], page['inner']), ('3', '0', '0'),
                         'Vim Keys took j from a text field: (keys passed to the page, scrollY, inner scrollTop)')

    def test_escape_in_a_text_field_gives_up_its_focus(self):
        self.open_page('focus&escape&held&keys=jjj')
        page = self.wait_sent()
        self.assertEqual(page['active'], 'BODY', 'Escape did not take focus from the text field')
        self.assertNotEqual(page['steps'], 'top', 'j did not scroll the page after Escape left the text field')

    def test_escape_the_page_uses_keeps_focus_in_the_text_field(self):
        self.open_page('focus&pagekeys&escape&case=escape-used')
        self.wait_sent()
        time.sleep(1)
        self.assertEqual(self.page_state()['active'], 'INPUT', 'Escape left a text field although the page used the key')

    def test_escape_leaves_a_text_field_with_vim_keys_off(self):
        self.addCleanup(self.reload_config, '')
        self.reload_config('browser:\n  vim_keys: false\n')
        self.open_page('focus&escape&config=off')
        self.wait_sent()
        self.assertEqual(self.page_state()['active'], 'BODY', 'Escape did not take focus from the text field with browser.vim_keys off')

    def test_a_key_the_page_uses_does_not_scroll(self):
        self.open_page('pagekeys&keys=jjj')
        self.wait_sent()
        time.sleep(1)
        self.assertEqual(self.page_state()['y'], '0', 'j scrolled although the page used the key')

    def test_vim_keys_off_in_the_config_do_not_scroll_a_new_page(self):
        self.addCleanup(self.reload_config, '')
        self.reload_config('browser:\n  vim_keys: false\n')
        self.open_page('keys=jjj&config=off')
        self.wait_sent()
        time.sleep(1)
        self.assertEqual(self.page_state()['y'], '0', 'j scrolled with browser.vim_keys off')

    # Reopen Closed Tab

    def test_reopen_closed_tab_brings_the_tab_back_at_its_index_with_its_back_history(self):
        left, right = self.page.as_uri() + '?tab=left', self.page.as_uri() + '?tab=right'
        first, second = self.page.as_uri() + '?goto=case=reopened', self.page.as_uri() + '?case=reopened'
        self.open_page('goto=case=reopened', left=[left], right=[right], shows='case=reopened')
        wait(lambda: self.stored_tabs() == ([left, second, right], '1'), 'the app did not store the second page in the middle Tab')

        self.press_menu('Close Tab')
        wait(lambda: self.stored_tabs()[0] == [left, right], 'Close Tab did not close the middle Tab')
        self.press_menu('Reopen Closed Tab')
        wait(lambda: self.stored_tabs() == ([left, second, right], '1'),
             'Reopen Closed Tab did not bring the second page back as the active middle Tab')
        self.wait_page(lambda page: True, 'the reopened Tab does not show the second page')

        self.press_menu('Back')
        self.query = 'goto=case=reopened'
        self.wait_page(lambda page: True, 'Back in the reopened Tab did not go to the first page')
        wait(lambda: self.stored_tabs() == ([left, first, right], '1'), 'Back did not store the first page in the middle Tab')

    def test_command_shift_t_reopens_a_closed_tab_with_browser_focus_and_opens_move_with_terminal_focus(self):
        left = self.page.as_uri() + '?tab=shift-t-left'
        url = self.page.as_uri() + '?case=shift-t'
        self.open_page('case=shift-t', left=[left])
        wait(lambda: self.stored_tabs() == ([left, url], '1'), 'the app did not store both Tabs')
        self.press_menu('Close Tab')
        wait(lambda: self.stored_tabs()[0] == [left], 'Close Tab did not close the active Tab')

        self.press_menu('Focus Browser')
        self.wait_focus(('WKWebView', 'WKContentView', 'NSTextView'), 'Focus Browser did not give the Browser Focus')
        self.press_key('⇧⌘T')
        wait(lambda: self.stored_tabs() == ([left, url], '1'), '⇧⌘T with Browser Focus did not reopen the closed Tab')
        self.assertFalse(self.s.has('palette-row-new-topic'), '⇧⌘T with Browser Focus opened Move')

        self.press_menu('Focus Terminal')
        self.wait_focus(('TerminalSurfaceView',), 'Focus Terminal did not give the Terminal Focus')
        self.press_key('⇧⌘T')
        self.s.wait_rows(lambda rs: self.s.has('palette-row-new-topic', rs), '⇧⌘T with Terminal Focus did not open Move')
        self.assertEqual(self.stored_tabs(), ([left, url], '1'), '⇧⌘T with Terminal Focus changed the Tabs')
        self.s.driver('action', 'palette-search', 'Close')
        self.s.wait_rows(lambda rs: not self.s.has('palette-search', rs), 'Move did not close')

    def press_key(self, symbol):
        """Runs the keybinds of a key, as a press of it does, without the keyboard (README: "Do not take focus")."""
        wait(lambda: self.s.driver('action', 'quick-switch-input', 'Press ' + symbol)['pressed'],
             'the app offers no Press %s' % symbol, seconds=10)

    def wait_focus(self, classes, message):
        wait(lambda: any(name.startswith(classes) for name in self.s.driver('responder')['responders']), message)

    # Paste Path

    def test_paste_path_types_the_raw_path_into_the_text_field_that_has_focus(self):
        folder = self.s.root/'pasted folder'
        folder.mkdir(exist_ok=True)
        sid = self.s.tmux('new-session', '-d', '-P', '-F', '#{session_id}', '-s', 'paste-into-page', '-c', str(folder), SHELL)
        self.addCleanup(self.s.tmux_ok, 'kill-session', '-t', sid)
        self.open_page('focus&case=paste')
        self.s.driver('press', 'Focus Browser')
        wait(lambda: 'WKWebView' in self.s.driver('responder')['responders'], 'Focus Browser did not give the page Focus')
        self.wait_page(lambda page: page['active'] == 'INPUT', 'the text field did not take focus')
        key = 'palette-row-session:' + sid
        def opened():
            self.s.driver('press', 'Go to…')
            try:
                self.s.wait_rows(lambda rs: self.s.has('palette-search', rs), 'not yet', seconds=3)
                return True
            except AssertionError:
                return False
        # SwiftUI rebuilds the View menu a moment after the state it reads changes, and a press in that moment can miss.
        wait(opened, 'the palette did not open', seconds=20)
        def searched():
            self.s.act('focus', 'palette-search')
            self.s.act('set', 'palette-search', 'paste-into-page')
            return self.s.has(key)
        wait(searched, 'no palette row for the Session paste-into-page', seconds=20)
        self.s.act('action', key, 'Paste Path')
        self.s.wait_rows(lambda rs: not self.s.has('palette-search', rs), 'the palette did not close after Paste Path')
        page = self.wait_page(lambda page: page['value'] != '', 'Paste Path typed nothing into the text field')
        self.assertEqual(unquote(page['value']), str(folder), 'the text field did not get the path as it is, without shell quotes')
        self.assertEqual(page['active'], 'INPUT', 'Paste Path took focus from the text field')
        pane = self.s.tmux('display-message', '-p', '-t', 'browser:' + self.id().rsplit('.', 1)[-1][5:], '#{pane_id}')
        self.assertNotIn('pasted folder', self.s.tmux('capture-pane', '-p', '-t', pane), 'Paste Path also typed the path at the prompt')

    def test_vim_keys_off_in_the_config_stop_an_open_page(self):
        self.addCleanup(self.reload_config, '')
        self.open_page('every=j')
        self.wait_page(lambda page: int(page['y']) > 0, 'j did not scroll the page')
        self.reload_config('browser:\n  vim_keys: false\n')
        time.sleep(SETTLE / 2)
        before = self.page_state()['y']
        time.sleep(SETTLE / 2)
        self.assertEqual(self.page_state()['y'], before, 'j still scrolled the open page with browser.vim_keys off')


if __name__ == '__main__':
    unittest.main()
