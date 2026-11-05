"""The side that had Focus keeps it after a Command runs from the Commands palette.

The palette's search field takes Focus while it is open. When a Command closes the palette, Focus must go back to
the Terminal or the Browser that had it, so the user can type again without a click.

The driver cannot type keys. A check opens Commands from its View menu item and presses a row, as the palette
suites do. `responder` names the view that has Focus: `TerminalSurfaceView` or `WKWebView`.

Run from the repo root after `make build`:
    python3 -m unittest -v scripts.verify.suites.focus_palette
"""

from scripts.verify.palette_fixture import PaletteFixture, SHELL
from scripts.verify.sandbox import wait

PAGE = '<!doctype html><html><head><meta charset="utf-8"></head><body><p>a page with Focus</p></body></html>'


class FocusPalette(PaletteFixture):
    @classmethod
    def config_text(cls, tags=None):
        return super().config_text(tags) + 'topics:\n  in_play: 1\n'

    def responders(self):
        return self.s.driver('responder')['responders']

    def focus_terminal(self):
        wait(lambda: self.s.driver('press', 'Focus Terminal')['pressed'], 'Focus Terminal stays disabled')
        wait(lambda: 'TerminalSurfaceView' in self.responders(), 'the Terminal did not take Focus')

    def assert_focus(self, view, after):
        try:
            wait(lambda: view in self.responders(), '', seconds=8)
        except AssertionError:
            self.fail('%s left Focus on %s, not on %s' % (after, self.responders(), view))

    def lock(self, session):
        return self.s.tmux('show-options', '-qv', '-t', session, '@muxify_lock').strip()

    def session(self, name):
        """A live Session outside every Topic, shown in the app; returns its Window."""
        window = self.s.tmux('new-session', '-d', '-P', '-F', '#{window_id}', '-s', name, '-c', str(self.project), SHELL)
        self.addCleanup(self.s.tmux_ok, 'kill-session', '-t', name)
        self.addCleanup(self.select, self.base)
        self.select(window)
        return window

    def shown_topic(self, name, order=0):
        """A Topic with a live Session that the app shows; returns its Window. The card can be on the Bench, out of
        sight, so run_command waits for the Topic's Commands in place of its card."""
        window = self.topic(name, order=order, session=True)
        self.select(window)
        return window

    def make_a_guest(self, session):
        self.run_command('Make a Guest')
        wait(lambda: self.lock(session), 'Make a Guest did not lock the Session')

    def test_make_a_guest_of_a_session_keeps_focus_in_the_terminal(self):
        self.session('fp-guest')
        self.focus_terminal()
        self.make_a_guest('fp-guest')
        self.assert_focus('TerminalSurfaceView', 'Make a Guest')

    def test_bench_of_a_guest_session_keeps_focus_in_the_terminal(self):
        self.session('fp-bench-guest')
        self.make_a_guest('fp-bench-guest')
        self.focus_terminal()
        self.run_command('Bench')
        wait(lambda: not self.lock('fp-bench-guest'), 'Bench did not unlock the Guest Session')
        self.assert_focus('TerminalSurfaceView', 'Bench of a Guest Session')

    def bench(self, prefix):
        """A Bench to toggle: one In Play Topic and one Benched Topic."""
        self.topic(prefix + '-in-play', order=0)
        self.topic(prefix + '-benched', order=1)
        self.s.wait_rows(lambda rs: self.s.has('topics-bench-line', rs), 'the Bench line did not show')

    def test_toggle_bench_keeps_focus_in_the_terminal(self):
        self.bench('fp-toggle')
        self.addCleanup(self.run_command, 'Toggle Bench')
        self.focus_terminal()
        self.run_command('Toggle Bench')
        self.assert_focus('TerminalSurfaceView', 'Toggle Bench')

    def test_make_a_guest_of_a_benched_topic_keeps_focus_in_the_terminal(self):
        self.topic('fp-in-play', order=0)
        self.shown_topic('fp-benched', order=1)
        self.focus_terminal()
        self.run_command('Make a Guest')
        wait(lambda: self.record('fp-benched').get('guest'), 'Make a Guest did not mark the Topic')
        self.assert_focus('TerminalSurfaceView', 'Make a Guest')

    def test_bench_topic_keeps_focus_in_the_terminal(self):
        self.shown_topic('fp-bench')
        self.focus_terminal()
        self.run_command('Bench')
        self.assert_focus('TerminalSurfaceView', 'Bench')

    def test_pin_topic_keeps_focus_in_the_terminal(self):
        self.shown_topic('fp-pin')
        self.focus_terminal()
        self.run_command('Pin Topic')
        wait(lambda: self.record('fp-pin').get('pinned'), 'Pin Topic did not pin the Topic')
        self.assert_focus('TerminalSurfaceView', 'Pin Topic')

    def test_unpin_topic_keeps_focus_in_the_terminal(self):
        self.shown_topic('fp-unpin')
        self.run_command('Pin Topic')
        wait(lambda: self.record('fp-unpin').get('pinned'), 'Pin Topic did not pin the Topic')
        self.focus_terminal()
        self.run_command('Unpin Topic')
        wait(lambda: not self.record('fp-unpin').get('pinned'), 'Unpin Topic did not unpin the Topic')
        self.assert_focus('TerminalSurfaceView', 'Unpin Topic')

    def test_rename_topic_keeps_focus_in_the_terminal_after_accept(self):
        self.shown_topic('fp-rename')
        self.focus_terminal()
        self.run_command('Rename Topic')
        self.s.wait_rows(lambda rs: 'Rename' in self.text('palette-breadcrumb', rs), 'Rename Topic did not open its step')
        self.s.act('set', 'palette-search', 'Renamed fp')
        self.s.act('action', 'palette-search', 'Accept')
        wait(lambda: self.record('fp-rename').get('title') == 'Renamed fp', 'Accept did not rename the Topic')
        self.assert_focus('TerminalSurfaceView', 'Rename Topic')

    def test_a_command_keeps_focus_in_the_browser_that_had_it(self):
        page = self.s.root/'focus-page.html'
        page.write_text(PAGE)
        name = 'fp-browser'
        # One tmux call, so the app never reads the Window without its Browser options.
        options = [arg for option, value in [('@muxify_tabs', page.as_uri()), ('@muxify_active_tab', '0'), ('@muxify_browser', 'on')]
                   for arg in (';', 'set-option', '-w', '-t', 'base:' + name, option, value)]
        self.s.tmux('new-window', '-d', '-t', 'base:', '-n', name, SHELL, *options)
        window = self.s.tmux('display-message', '-p', '-t', 'base:' + name, '#{window_id}')
        self.addCleanup(self.s.tmux_ok, 'kill-window', '-t', window)
        self.addCleanup(self.select, self.base)
        self.bench('fp-browser')
        self.addCleanup(self.run_command, 'Toggle Bench')
        self.select(window)
        wait(lambda: self.s.driver('press', 'Focus Browser')['pressed'], 'Focus Browser stays disabled')
        wait(lambda: 'WKWebView' in self.responders(), 'the Browser did not take Focus')
        self.run_command('Toggle Bench')
        self.assert_focus('WKWebView', 'Toggle Bench')
