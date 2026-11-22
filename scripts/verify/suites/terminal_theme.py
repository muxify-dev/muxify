"""The Terminal's theme: Muxify's default light and dark pair, under a theme that a Ghostty config sets, which is under
the Config's `ghostty.theme`.

Each check reads the Terminal's background through its Colour Report (ADR 0095): `fixtures/colour_probe.py` runs in
the shown Pane, asks for the background every half second and logs each answer.

Run from the repo root after `make build`:
    python3 -m unittest -v scripts.verify.suites.terminal_theme
"""

import subprocess
import sys
import unittest

from scripts.verify.sandbox import DEBUG_APP, REPO, Sandbox, wait

PROBE = REPO/'scripts/verify/fixtures/colour_probe.py'
THEMES = DEBUG_APP/'Contents/Resources/ghostty/themes'


def background(theme):
    """The theme's background as `rrggbb`, from its file in the app."""
    for line in (THEMES/theme).read_text().splitlines():
        key, _, value = line.partition('=')
        if key.strip() == 'background':
            return value.strip().lstrip('#').lower()
    raise AssertionError('the theme %s has no background' % theme)


def dark_appearance():
    result = subprocess.run(['defaults', 'read', '-g', 'AppleInterfaceStyle'], capture_output=True, text=True)
    return result.stdout.strip() == 'Dark'


class TerminalTheme(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.sandbox = Sandbox(__name__.rsplit('.', 1)[-1])
        cls.addClassCleanup(cls.sandbox.teardown)
        cls.config = cls.sandbox.root/'config/muxify/config.yaml'
        cls.ghostty = cls.sandbox.root/'config/muxify/ghostty.conf'
        cls.config.write_text('')
        cls.log = cls.sandbox.root/'probe.log'
        cls.log.touch()
        cls.sandbox.tmux('new-session', '-d', '-s', 'theme', '-x', '80', '-y', '24',
                         '%s %s %s' % (sys.executable, PROBE, cls.log))
        cls.sandbox.launch()
        wait(lambda: '@muxify_client_' in cls.sandbox.tmux('show-options', '-s'), 'Muxify did not register its Client')
        cls.sandbox.show(cls.sandbox.tmux('display-message', '-p', '-t', 'theme:', '#{window_id}').strip())

    def answers(self):
        """The backgrounds the probe got, as `rrggbb`: tmux writes each channel in 16 bits, `rgb:rrrr/gggg/bbbb`."""
        return [''.join(part[:2] for part in line.split()[1][len('rgb:'):].split('/'))
                for line in self.log.read_text().splitlines() if line.startswith('answer ')]

    def assert_background(self, theme):
        expected = background(theme)
        wait(lambda: self.answers()[-3:] == [expected] * 3,
             lambda: 'the Terminal does not have the background %s of %s: %s' % (expected, theme, self.answers()[-3:]),
             seconds=20)

    def test_the_terminal_has_muxifys_default_theme_without_a_theme_in_any_config(self):
        self.config.write_text('ui:\n  pulse: true\n')

        self.assert_background('Dracula' if dark_appearance() else 'iTerm2 Solarized Light')

    def test_a_theme_from_a_ghostty_config_wins_over_the_default(self):
        self.ghostty.write_text('theme = Nord\n')

        self.config.write_text('ghostty:\n  config_file: ghostty.conf\n')

        self.assert_background('Nord')

    def test_the_configs_ghostty_theme_wins_over_a_theme_from_a_ghostty_config(self):
        self.ghostty.write_text('theme = Nord\n')

        self.config.write_text('ghostty:\n  config_file: ghostty.conf\n  theme: {light: Gruvbox Light, dark: Gruvbox Dark}\n')

        self.assert_background('Gruvbox Dark' if dark_appearance() else 'Gruvbox Light')


if __name__ == '__main__':
    unittest.main()
