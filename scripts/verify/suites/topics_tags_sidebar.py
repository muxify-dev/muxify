"""Tags on Topic cards (ADR 0034): no Tags by default, Tag Marks in the right corner of the title line with
`sidebar.tag_placement: corner`, the other placements, the `topic.tags` Format part, and `topic_tags` on other rows.

The Tags of a card are one accessibility element, `tags-topic-<id>`, drawn over their place in the card header, so a
check reads their names from its value and their place from its frame (CardTags in UI/CardTags.swift).

Run from the repo root after `make build`:
    python3 -m unittest -v scripts.verify.suites.topics_tags_sidebar
"""

import json
import re
import time
import unittest

from scripts.verify.sandbox import Sandbox, remove_topic, wait

SHELL = '/bin/zsh -f'
TAGS = '  tags:\n    work: {color: blue}\n    personal: {}\n'
CORNER = '  tag_placement: corner\n'


def rect(row):
    """(left, top, right, bottom) of a dump row's frame, in screen points with y up."""
    x, y, width, height = map(float, re.findall(r'-?[\d.]+', row['accessibilityFrame']))
    return x, y + height, x + width, y


class TopicsTagsSidebar(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.s = s = Sandbox(__name__.rsplit('.', 1)[-1])
        cls.addClassCleanup(s.teardown)
        cls.project = s.root/'projects/alpha'
        cls.project.mkdir(parents=True)
        cls.topics = s.root/'state/muxify/topics'
        cls.topics.mkdir(parents=True)
        cls.config = s.root/'config/muxify/config.yaml'
        cls.config.write_text(cls.config_text())
        cls.base = s.tmux('new-session', '-d', '-P', '-F', '#{window_id}', '-s', 'base', '-c', str(cls.project), SHELL)
        s.tmux('set-option', '-g', 'detach-on-destroy', 'off')
        s.launch(['-sidebarVisible', 'YES', '-sessionsVisible', 'YES', '-agentsVisible', 'YES', '-sidebarWorkView', 'Topics'])

    @classmethod
    def config_text(cls, sidebar=CORNER, tags=TAGS):
        return ('sessions:\n  paths:\n    - path: ' + str(cls.project) + '\n'
                + ('topics:\n' + tags if tags else '') + ('sidebar:\n' + sidebar if sidebar else ''))

    def setUp(self):
        self.select(self.base)

    def use_config(self, **parts):
        self.config.write_text(self.config_text(**parts))
        self.addCleanup(self.config.write_text, self.config_text())

    def select(self, window):
        for client in self.s.tmux('list-clients', '-F', '#{client_tty} #{client_control_mode}').splitlines():
            if client.endswith(' 0'):
                self.s.tmux('switch-client', '-c', client.split()[0], '-t', window)
        self.s.wait_shown(window)

    def topic(self, name, tags, session=True, **fields):
        """A Topic record with `tags`, and a live Session in it unless `session` is false; returns its Window."""
        path = self.topics/(name + '.json')
        path.write_text(json.dumps(dict(id=name, title=fields.pop('title', name), slug=name, home_project=str(self.project),
                                        tags=tags, **fields)))
        self.addCleanup(remove_topic, path)
        if not session:
            return None
        window = self.s.tmux('new-session', '-d', '-P', '-F', '#{window_id}', '-s', name, '-c', str(self.project), SHELL)
        self.addCleanup(self.s.tmux_ok, 'kill-session', '-t', name)
        self.s.tmux('set-option', '-t', name, '@muxify_topic', name)
        self.addCleanup(self.select, self.base)
        return window

    def tags(self, name, value, message, place=lambda tags, header: True):
        """Waits until the card of `name` shows Tags with `value` where `place` holds for the (tags, header) rects, as
        the app reads a changed Config only every two seconds; returns the rects."""
        key = 'tags-topic-' + name
        def shown(rs):
            if self.s.row(key, rs).get('accessibilityValue') != value or not self.s.has('topic-' + name, rs):
                return False
            return place(rect(self.s.row(key, rs)), rect(self.s.row('topic-' + name, rs)))
        rs = wait(lambda: (lambda rs: rs if shown(rs) else None)(self.s.rows()), '%s: want the Tags %r, have %r at %s in %s' % (
            message, value, self.s.row(key).get('accessibilityValue'), self.s.row(key).get('accessibilityFrame'),
            self.s.row('topic-' + name).get('accessibilityFrame')))
        return rect(self.s.row(key, rs)), rect(self.s.row('topic-' + name, rs))

    def test_by_default_no_card_shows_tags_and_edit_tags_is_still_offered(self):
        window = self.topic('tg-default', ['work'])
        self.topic('tg-default-closed', ['personal'])
        self.select(window)
        self.tags('tg-default', 'work', 'the card does not show its Tag with tag_placement: corner')
        self.use_config(sidebar='')
        self.s.wait_rows(lambda rs: self.s.has('topic-tg-default', rs) and self.s.has('topic-tg-default-closed', rs)
                         and not any(row.get('accessibilityIdentifier', '').startswith('tags-topic-') for row in rs),
                         'a card shows Tags with no sidebar.tag_placement')
        wait(lambda: self.s.driver('press', 'Commands')['pressed'], 'Commands did not open')
        self.addCleanup(self.s.act, 'action', 'palette-search', 'Close')
        self.s.wait_rows(lambda rs: self.s.has('palette-search', rs), 'the Commands field did not show')
        self.s.act('focus', 'palette-search')
        self.s.act('set', 'palette-search', 'Edit Tags')
        self.s.wait_rows(lambda rs: self.s.has('palette-row-command-Edit Tags…', rs), 'Edit Tags… is not offered with no tag_placement')

    def test_corner_tag_marks_end_the_title_line_of_a_closed_card_with_a_summary_in_config_order(self):
        self.topic('tg-corner', ['personal', 'gone', 'work'], pinned=True)
        self.tags('tg-corner', 'work, personal, gone',
                  'a closed card with a Summary does not show three small Tag Marks in Config order at the right end of its '
                  'title line, right of its Pin',
                  lambda tags, header: header[1] - tags[1] < 14 and header[1] - header[3] > 30 and header[2] - tags[2] < 14
                  and tags[2] - tags[0] < 40)

    def test_corner_tag_marks_end_the_title_line_of_an_open_card(self):
        self.select(self.topic('tg-open', ['work'], pinned=True))
        self.tags('tg-open', 'work', 'the Active Topic card does not show its Tag Mark at the right end of its title line, right of its Pin',
                  lambda tags, header: header[1] - tags[1] < 14 and header[2] - tags[2] < 14)

    def test_title_placement_puts_the_first_tag_and_plus_n_in_the_title_line_and_a_long_title_wraps_under_them(self):
        self.use_config(sidebar='  tag_placement: title\n')
        title = 'A Topic title long enough to wrap onto a second line in the Sidebar card'
        self.topic('tg-title', ['work', 'personal'], title=title, pinned=True)
        self.tags('tg-title', 'work, personal',
                  'the first chip and +1 are not at the right end of the title line, right of the Pin, over a wrapped title',
                  lambda tags, header: header[1] - tags[1] < 14 and tags[0] > (header[0] + header[2]) / 2 and header[2] - tags[2] < 14
                  and header[1] - header[3] > 60)

    def test_line_placement_puts_the_chips_on_their_own_line_under_the_title(self):
        self.use_config(sidebar='  tag_placement: line\n')
        self.topic('tg-line', ['personal', 'work'])
        self.tags('tg-line', 'work, personal', 'the chips are not on their own line under the title',
                  lambda tags, header: tags[0] - header[0] < 20 and 14 < header[1] - tags[1] < 40)

    def test_the_tags_format_part_names_each_tag_and_an_empty_format_hides_them(self):
        self.topic('tg-format', ['work', 'personal'])
        self.use_config(sidebar=CORNER + "  formats:\n    topic:\n      tags: '#{T:#{tag}}'\n")
        self.tags('tg-format', 'work, personal', 'tag is not the stored name')
        self.config.write_text(self.config_text(sidebar=CORNER + "  formats:\n    topic:\n      tags: '#{T:#{?#{==:#{tag},work},#{tag},}}'\n"))
        self.tags('tg-format', 'work', 'a pass with no text did not leave its Tag out')
        self.config.write_text(self.config_text(sidebar=CORNER + "  formats:\n    topic:\n      tags: ''\n"))
        self.s.wait_rows(lambda rs: self.s.has('topic-tg-format', rs) and not self.s.has('tags-topic-tg-format', rs),
                         "tags: '' did not hide the Tags")

    def test_with_tags_off_a_card_shows_no_tags(self):
        self.topic('tg-off', ['work'])
        self.tags('tg-off', 'work', 'the card does not show its Tag')
        self.use_config(tags='')
        self.s.wait_rows(lambda rs: self.s.has('topic-tg-off', rs) and not self.s.has('tags-topic-tg-off', rs),
                         'a card shows Tags with no topics.tags')

    def test_a_closed_settled_card_shows_no_tags_and_the_opened_one_shows_them_in_the_title_line(self):
        self.topic('tg-settled', ['work'], session=False, settled_at='2026-01-01T00:00:00Z')
        rs = self.s.wait_rows(lambda rs: self.s.has('settled-topics', rs), 'the Settled group did not show')
        if self.s.row('settled-topics', rs).get('accessibilityValue') != 'expanded':
            self.s.act('press', 'settled-topics')
        self.addCleanup(lambda: self.s.has('settled-topics') and self.s.row('settled-topics').get('accessibilityValue') == 'expanded'
                        and self.s.act('press', 'settled-topics'))
        self.s.wait_rows(lambda rs: self.s.has('topic-tg-settled', rs), 'the Settled card did not show')
        time.sleep(1)
        self.assertFalse(self.s.has('tags-topic-tg-settled'), 'a closed Settled card shows Tags')
        self.s.act('press', 'topic-tg-settled')
        self.tags('tg-settled', 'work', 'the opened Settled card does not show its Tag Mark in its title line',
                  lambda tags, header: header[1] - tags[1] < 14)

    def test_topic_tags_names_the_tags_of_an_agents_topic(self):
        self.topic('tg-agent', ['personal', 'work'], session=False)
        pane = self.s.tmux('new-session', '-d', '-P', '-F', '#{pane_id}', '-s', 'tg-agent', '-c', str(self.project), 'sleep 600')
        self.addCleanup(self.s.tmux_ok, 'kill-session', '-t', 'tg-agent')
        self.s.tmux('set-option', '-t', 'tg-agent', '@muxify_topic', 'tg-agent')
        self.s.tmux('set-option', '-p', '-t', pane, '@muxify_agent', 'claude')
        self.s.tmux('set-option', '-p', '-t', pane, '@muxify_agent_status', 'working')
        self.use_config(sidebar="  agents_scope: all\n  formats:\n    agent:\n      title: '#{topic_tags}'\n")
        self.s.wait_rows(lambda rs: self.s.row('agent-' + pane, rs).get('accessibilityValue', '').startswith('#work #personal'),
                         'the Agent title does not give topic_tags: %r' % self.s.row('agent-' + pane).get('accessibilityValue'))


if __name__ == '__main__':
    unittest.main()
