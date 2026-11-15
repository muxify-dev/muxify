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

    def shown_topic(self, name, order=0):
        """A Topic with a live Session that the app shows; returns its Window. The card can be on the Bench, out of
        sight, so run_command waits for the Topic's Commands in place of its card."""
        window = self.topic(name, order=order, session=True)
        self.select(window)
        return window

    def bench(self, prefix):
        """A Bench to toggle: one In Play Topic and one Benched Topic."""
        self.topic(prefix + '-in-play', order=0)
        self.topic(prefix + '-benched', order=1)
        self.s.wait_rows(lambda rs: self.s.has('topics-bench-line', rs), 'the Bench line did not show')

    def test_bench_topic_keeps_focus_in_the_terminal(self):
        self.shown_topic('fp-bench')
        self.focus_terminal()
        self.run_command('Bench')
        self.assert_focus('TerminalSurfaceView', 'Bench')

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
