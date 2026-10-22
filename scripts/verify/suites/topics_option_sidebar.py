"""Topics in the Sidebar: the tmux Topic option, Topic files, the Sidebar views, New Topic and the muxify://topic URL.

The fixture and the helpers that several suites use are in scripts/verify/topics_sidebar.py.

Run from the repo root after `make build`:
    python3 -m unittest -v scripts.verify.suites.topics_option_sidebar
"""

import json
import os
import subprocess
import time
import unittest
from urllib.parse import quote

from scripts.verify.sandbox import remove_topic, wait
from scripts.verify.topics_sidebar import REFRESH_LIMIT, TopicsSidebar


class TopicsOptionSidebar(TopicsSidebar):
    def test_session_without_topic_option_shows_as_the_no_topic_card_when_opened(self):
        sid = self.new_session('plain', self.beta)
        self.select_window(sid + ':')
        latency, rs = self.rows_until(lambda rs: self.no_topic_cards(rs) == [sid])
        self.assertIsNotNone(latency, 'Session %s is not the No Topic card: %s; Topic rows %s'
                             % (sid, self.no_topic_cards(rs), self.topic_rows(rs)))

    def test_session_moves_under_its_topic_when_topic_option_is_set(self):
        sid = self.new_session('joins', self.beta)
        self.write_topic('joins', 'Joins proof', self.beta)
        self.select_window(sid + ':')
        self.s.wait_rows(lambda rs: self.no_topic_cards(rs) == [sid], 'Session %s is not the No Topic card' % sid)
        self.s.tmux('set-option', '-t', sid, '@muxify_topic', 'joins')
        latency, rs = self.rows_until(lambda rs: self.s.has('topic-joins-session-' + sid, rs) and not self.no_topic_cards(rs))
        self.assertIsNotNone(latency, 'Session %s is not under Topic joins; %s; No Topic cards: %s'
                             % (sid, self.describe('topic-joins', rs), self.no_topic_cards(rs)))

    def test_session_returns_to_no_topic_when_topic_option_is_unset(self):
        sid = self.new_session('leaves', self.beta, topic='leaves')
        self.write_topic('leaves', 'Leaves proof', self.beta)
        self.select_window(sid + ':')
        self.s.wait_rows(lambda rs: self.s.has('topic-leaves-session-' + sid, rs), 'Session %s never joined Topic leaves' % sid)
        # A Topic that remembers its Session is Dormant when the Session leaves outside Muxify; one that never
        # remembered it is Empty.
        wait(lambda: self.records()['leaves'].get('sessions'), 'Topic leaves did not remember Session %s' % sid)
        self.s.tmux('set-option', '-u', '-t', sid, '@muxify_topic')
        latency, rs = self.rows_until(lambda rs: self.no_topic_cards(rs) == [sid] and 'Dormant' in self.describe('topic-leaves', rs))
        self.assertIsNotNone(latency, 'Session %s is not back in No Topic; %s; No Topic cards: %s'
                             % (sid, self.describe('topic-leaves', rs), self.no_topic_cards(rs)))

    def test_topic_option_change_shows_in_sidebar_within_refresh_limit(self):
        # Without the Agents section the Topic list has room for the Topic's Session row and the No Topic card, as
        # the check reads both.
        self.addCleanup(self.set_show_agents, True)
        self.set_show_agents(False)
        sid = self.new_session('timing', self.beta)
        self.write_topic('timing', 'Timing proof', self.beta)
        self.select_window(sid + ':')
        under_topic = lambda rs: self.s.has('topic-timing-session-' + sid, rs) and not self.no_topic_cards(rs)
        samples = []
        for attempt in range(13):
            self.s.tmux('set-option', '-u', '-t', sid, '@muxify_topic')
            self.s.wait_rows(lambda rs: self.no_topic_cards(rs) == [sid] and not self.s.has('topic-timing-session-' + sid, rs),
                             'Session %s did not return to No Topic' % sid, seconds=5)
            # Staggered offsets sample different phases of the app's refresh cycle.
            time.sleep(0.137 * (attempt % 7))
            self.s.tmux('set-option', '-t', sid, '@muxify_topic', 'timing')
            samples.append(self.rows_until(under_topic)[0])
        shown = ', '.join('%.3f' % v if v is not None else 'TIMEOUT' for v in samples)
        self.assertNotIn(None, samples, 'tmux set -> Session row under its Topic: ' + shown)
        self.assertLessEqual(max(samples), REFRESH_LIMIT, 'tmux set -> Session row under its Topic: ' + shown)

    def test_session_with_unknown_topic_stays_in_no_topic(self):
        sid = self.new_session('orphan', self.beta, topic='orphan-no-file')
        self.select_window(sid + ':')
        latency, rs = self.rows_until(lambda rs: self.no_topic_cards(rs) == [sid])
        self.assertIsNotNone(latency, 'Session %s naming Topic orphan-no-file is not the No Topic card: %s; Topic rows %s'
                             % (sid, self.no_topic_cards(rs), self.topic_rows(rs)))

    def test_topic_file_written_after_topic_option_shows_live_topic_within_refresh_limit(self):
        sid = self.new_session('late-file', self.beta, topic='late-file')
        self.select_window(sid + ':')
        self.s.wait_rows(lambda rs: self.no_topic_cards(rs) == [sid], 'Session %s is not the No Topic card' % sid)
        self.write_topic('late-file', 'Late file proof', self.beta)
        latency, rs = self.rows_until(lambda rs: self.s.has('topic-late-file', rs)
                                      and not self.no_topic_cards(rs)
                                      and 'Dormant' not in self.describe('topic-late-file', rs))
        self.assertIsNotNone(latency, 'no live Topic row; ' + self.describe('topic-late-file', rs))
        self.assertLessEqual(latency, REFRESH_LIMIT, 'file write -> live Topic row took %.3f s' % latency)

    def test_sessions_view_lists_every_session_and_no_topics(self):
        self.addCleanup(self.show_view, 'topics')
        self.new_session('listed', self.beta)
        self.new_session('alpha/listed-topic', self.alpha, topic='listed-topic')
        self.write_topic('listed-topic', 'Listed proof', self.alpha)
        self.show_view('sessions')
        live = dict(line.split('|', 1) for line in self.s.tmux('list-sessions', '-F', '#{session_id}|#{session_name}').splitlines())
        complete = lambda rs: (all(self.s.has('session-' + sid, rs) for sid in live) and not self.topic_rows(rs)
                               and not self.s.has('snoozed-topics', rs) and not self.s.has('settled-topics', rs))
        latency, rs = self.rows_until(complete, seconds=5)
        self.assertIsNotNone(latency, 'Sessions view: missing %s; Topic rows %s'
                             % ([name for sid, name in live.items() if not self.s.has('session-' + sid, rs)], self.topic_rows(rs)))

    def test_topics_view_shows_topics_and_no_session_rows(self):
        sid = self.new_session('alpha/view-back', self.alpha, topic='view-back')
        self.write_topic('view-back', 'View back proof', self.alpha)
        self.show_view('sessions')
        self.s.wait_rows(lambda rs: self.s.has('session-' + sid, rs), 'Sessions view has no row for %s' % sid)
        self.show_view('topics')
        self.find('topic-view-back')
        live = self.s.tmux('list-sessions', '-F', '#{session_id}').split()
        latency, rs = self.rows_until(lambda rs: self.s.has('topic-view-back', rs)
                                      and not any(self.s.has('session-' + sid, rs) for sid in live), seconds=5)
        self.assertIsNotNone(latency, 'Topics view: Topic rows %s; Sessions view rows %s'
                             % (self.topic_rows(rs), [sid for sid in live if self.s.has('session-' + sid, rs)]))

    def test_new_topic_stays_empty_until_adding_its_first_session_without_a_home(self):
        s = self.s
        record = self.create_topic('New Topic proof')
        self.assertNotIn('home_project', record, json.dumps(record))
        self.assertEqual(record.get('sessions'), [], json.dumps(record))
        key = 'topic-' + record['id']
        self.find(key)
        self.assertIn('Empty', self.describe(key, s.rows()), 'the new Topic card is not Empty')
        self.open_add_session()
        self.pick_project(self.alpha_tree['new-topic-base'], False)
        s.act('press', 'palette-accept')
        name = 'alpha/new-topic-base/new-topic-proof'
        self.wait_session(name)
        # tmux starts the Session before the command that sets its Topic option.
        session_path, topic = wait(lambda: (lambda fields: fields if fields[1] else None)(
            s.tmux('display-message', '-p', '-t', '=' + name + ':', '#{session_path}|#{@muxify_topic}').split('|')),
            'Session %s has no Topic option' % name, seconds=10)
        base = self.alpha_tree['new-topic-base']
        self.assertIn(session_path, (str(base), os.path.realpath(base)), 'Session path')
        self.assertEqual(topic, record['id'], 'Session %s names the wrong Topic' % name)
        saved = wait(lambda: self.records()[record['id']].get('sessions'), 'first Session was not remembered')
        self.assertEqual(saved[0]['name'], name)
        self.assertIn(saved[0]['directory'], (str(base), os.path.realpath(base)))
        self.assertNotIn('home_project', self.records()[record['id']])
        latency, rs = self.rows_until(lambda rs: not s.has('empty-topic-title', rs))
        self.assertIsNotNone(latency, 'the empty-Topic view stays after the first Session opened')

    def test_new_topic_is_last_in_topics_view_by_default(self):
        self.write_topic('insert-earlier', 'Earlier Topic', self.beta, order=0)
        self.find('topic-insert-earlier')
        record = self.create_topic('Last in order')
        rs = self.s.wait_rows(lambda rs: self.s.has('topic-' + record['id'], rs), 'no row for the new Topic')
        order = self.topic_rows(rs)
        self.assertEqual(order[-1], 'topic-' + record['id'],
                         'Topics view order %s; record orders %s' % (order, {i: r.get('order') for i, r in self.records().items()}))

    def test_a_topic_url_from_an_automation_creates_the_topic_and_its_session(self):
        # -a sends the URL to this run's app copy by its path, never to the user's Muxify; -g keeps it behind.
        url = 'muxify://topic/new?title=' + quote('URL proof') + '&sessionPath=' + quote(str(self.beta), safe='')
        subprocess.run(['open', '-g', '-a', str(self.s.app), url], check=True, capture_output=True)
        record = wait(lambda: next((r for r in self.records().values() if r.get('title') == 'URL proof'), None),
                      'no Topic record for the URL', seconds=10)
        self.addCleanup(remove_topic, self.topics_dir/(record['id'] + '.json'))
        self.wait_session('beta/url-proof')
        sid = self.s.tmux('display-message', '-p', '-t', '=beta/url-proof:', '#{session_id}')
        self.addCleanup(self.end_session, sid)
        # tmux starts the Session before the command that sets its Topic option.
        wait(lambda: self.s.tmux_ok('show-options', '-v', '-t', sid, '@muxify_topic').stdout.strip() == record['id'],
             'Session %s does not name the URL Topic' % sid, seconds=10)
        rs = self.s.wait_rows(lambda rs: self.s.has('topic-%s-session-%s' % (record['id'], sid), rs),
                              'the Session of the URL Topic is not on its card')
        # A second App Window would also get the next palette, and the driver would fill one and press the other.
        windows = [r.get('accessibilityFrame') for r in rs if r.get('accessibilityRole') == 'AXWindow']
        self.assertEqual(len(windows), 1, 'the URL opened another App Window: %s' % windows)

    def test_a_long_press_drags_a_topic_card_and_a_quick_drag_does_not(self):
        # TestDriver `drag` hands the mouse events to the window, so the pointer stays with the user; `hold` keeps
        # the press still before it moves, as a person does to lift the card.
        self.write_topic('press-upper', 'Press upper', self.beta, order=-2000001)
        self.write_topic('press-lower', 'Press lower', self.beta, order=-2000000)
        cards = lambda rs: [k for k in self.topic_rows(rs) if k.startswith('topic-press-')]
        self.s.wait_rows(lambda rs: len(cards(rs)) == 2, 'no cards for the two Topics')
        self.s.reveal('topic-press-upper')
        self.s.act('drag', 'topic-press-lower', 'topic-press-upper')
        time.sleep(REFRESH_LIMIT)
        self.assertEqual(cards(self.s.rows()), ['topic-press-upper', 'topic-press-lower'], 'a quick drag moved the Topic')
        self.s.act('drag', 'topic-press-lower', 'topic-press-upper', hold=2.0)
        # The dropped card shows at its new place while it glides there, and the order is saved when it lands. So the
        # saved order is the proof, and a check that ends on the rows would delete the records before the save.
        orders = lambda: {i: r.get('order') for i, r in self.records().items() if i.startswith('press-')}
        wait(lambda: orders()['press-lower'] < orders()['press-upper'],
             'the long press did not save press-lower above press-upper', seconds=5)
        self.s.wait_rows(lambda rs: cards(rs) == ['topic-press-lower', 'topic-press-upper'],
                         'the Sidebar does not show the saved order', seconds=5)

    def test_move_up_and_move_down_move_the_topic_card_and_save_the_order(self):
        # A long press drags a card; the driver cannot hold a press, so the card's Move Up and Move Down
        # accessibility actions (TopicCard in UI/SidebarView.swift) move it the way a drop does.
        self.write_topic('order-upper', 'Order upper', self.beta, order=-1000002)
        self.write_topic('order-middle', 'Order middle', self.beta, order=-1000001)
        self.write_topic('order-lower', 'Order lower', self.beta, order=-1000000)
        cards = lambda rs: [k for k in self.topic_rows(rs) if k.startswith('topic-order-')]
        self.s.wait_rows(lambda rs: len(cards(rs)) == 3, 'no cards for the three Topics')
        self.s.reveal('topic-order-upper')
        self.s.act('action', 'topic-order-lower', 'Move Up')
        latency, rs = self.rows_until(lambda rs: cards(rs) == ['topic-order-upper', 'topic-order-lower', 'topic-order-middle'], seconds=5)
        self.assertIsNotNone(latency, 'Topic order after Move Up: %s' % cards(rs))
        self.s.act('action', 'topic-order-upper', 'Move Down')
        latency, rs = self.rows_until(lambda rs: cards(rs) == ['topic-order-lower', 'topic-order-upper', 'topic-order-middle'], seconds=5)
        self.assertIsNotNone(latency, 'Topic order after Move Down: %s' % cards(rs))
        orders = {i: r.get('order') for i, r in self.records().items() if i.startswith('order-')}
        self.assertLess(orders['order-lower'], orders['order-upper'], 'saved Topic orders: %s' % orders)
        self.assertLess(orders['order-upper'], orders['order-middle'], 'saved Topic orders: %s' % orders)

    def test_title_suggestion_on_a_palette_topic_row_renames_the_topic(self):
        topic_id = 'row-suggestion'
        self.write_topic(topic_id, 'Row suggestion proof', self.alpha)
        sid = self.new_session('alpha/row-suggestion', self.alpha, '/bin/sleep 300', topic=topic_id)
        pane = self.s.tmux('display-message', '-p', '-t', sid + ':', '#{pane_id}')
        self.s.tmux('set-option', '-p', '-t', pane, '@muxify_agent', 'opencode')
        self.s.tmux('set-option', '-p', '-t', pane, '@muxify_agent_status', 'working')
        self.s.tmux('set-option', '-p', '-t', pane, '@muxify_agent_conversation', 'title-suggestion-conversation')
        self.find('topic-' + topic_id, 'the Topic did not appear')
        wait(lambda: self.s.driver('press', 'Go to…')['pressed'], 'Go to… did not open')
        self.s.wait_rows(lambda rs: self.s.has('palette-search', rs), 'the Go to… field did not show')
        self.s.act('focus', 'palette-search')
        self.s.act('set', 'palette-search', 'Row suggestion proof')
        key = 'palette-row-topic-' + topic_id
        self.s.wait_rows(lambda rs: self.s.has(key, rs), 'Go to… did not show the Topic row')
        self.s.act('action', key, 'Suggest title from Agents')
        wait(lambda: self.records()[topic_id].get('title') == 'Verified Agent Title',
             'suggest_topic_title on the Topic row did not rename the Topic: %s' % self.records()[topic_id], seconds=15)

    def test_title_suggestion_fills_rename_field_and_waits_for_confirmation(self):
        topic_id = 'title-suggestion'
        self.write_topic(topic_id, '', self.alpha)
        sid = self.new_session('alpha/title-suggestion', self.alpha, '/bin/sleep 300', topic=topic_id)
        pane = self.s.tmux('display-message', '-p', '-t', sid + ':', '#{pane_id}')
        self.s.tmux('set-option', '-p', '-t', pane, '@muxify_agent', 'opencode')
        self.s.tmux('set-option', '-p', '-t', pane, '@muxify_agent_status', 'working')
        self.s.tmux('set-option', '-p', '-t', pane, '@muxify_agent_conversation', 'title-suggestion-conversation')
        self.title_prompt.unlink(missing_ok=True)

        self.find('topic-' + topic_id, 'Untitled Topic did not appear')
        self.s.act('action', 'topic-' + topic_id, 'Suggest title from Agents')
        rs = self.s.wait_rows(
            lambda rs: self.s.row('palette-search', rs).get('accessibilityValue') == 'Verified Agent Title',
            'suggestion did not fill the Rename field')
        self.assertEqual(self.s.row('palette-search', rs).get('accessibilityValue'), 'Verified Agent Title')
        self.assertIn('⌥S', self.describe('palette-suggest-title', rs), 'the Rename step does not offer suggest_topic_title')
        self.assertIn('Title suggestion verification prompt', self.title_prompt.read_text())
        self.assertEqual(self.records()[topic_id]['title'], '', 'suggestion renamed the Topic before confirmation')

        self.s.act('press', 'palette-cancel')
        self.s.wait_rows(lambda rs: not self.s.has('palette-search', rs), 'Rename palette did not close')
        self.assertEqual(self.records()[topic_id]['title'], '', 'Cancel changed the Untitled Topic')
