"""Topics in the Sidebar: Worktrees in New Topic and Add Session Path, bare repositories and the main checkout.

The fixture and the helpers that several suites use are in scripts/verify/topics_sidebar.py.

Run from the repo root after `make build`:
    python3 -m unittest -v scripts.verify.suites.topics_worktrees_sidebar
"""

import json
import os
import subprocess
import unittest

from scripts.verify.sandbox import wait
from scripts.verify.topics_sidebar import TopicsSidebar, remembered_session


class TopicsWorktreesSidebar(TopicsSidebar):
    def new_topic(self, title, directory, worktree=False):
        """Creates a Topic, then adds the Session Path or Worktree row at directory from the empty-Topic view; returns the
        record once it remembers that Session. With worktree, the Session starts on a new Worktree from that row."""
        s = self.s
        topic_id = self.create_topic(title)['id']
        self.open_add_session()
        self.pick_project(directory, worktree)
        s.act('press', 'palette-accept')
        s.wait_rows(lambda rs: not s.has('palette-accept', rs), 'Add Session Path palette did not close', seconds=15)
        return wait(lambda: (lambda r: r if r and r.get('sessions') else None)(self.records().get(topic_id)),
                    'Topic %s remembers no Session' % topic_id, seconds=15)

    def test_forget_removes_selected_clean_worktrees_with_and_without_live_sessions(self):
        s = self.s
        for live in [False, True]:
            topic = 'forget-tree-live' if live else 'forget-tree-dormant'
            tree = self.worktrees/'alpha'/topic
            dirty = self.worktrees/'alpha'/(topic + '-dirty')
            for path in [tree, dirty]:
                subprocess.run(['/usr/bin/git', '-C', str(self.alpha), 'worktree', 'add', '-q', str(path), '-b', path.name], check=True)
            (dirty/'draft').write_text('untracked work')
            self.write_topic(topic, topic, self.alpha, sessions=[
                remembered_session(path, topic, base='alpha' if path == tree else 'dirty',
                                   repository_path=str(self.alpha), worktree_path=str(path), branch=path.name, worktree_created=True)
                for path in [tree, dirty]
            ])
            if live:
                sid = self.new_session('alpha/' + topic, tree, topic=topic)
            self.find('topic-' + topic)
            # SidebarView exposes Forget as an accessibility action so the context menu stays closed.
            s.act('action', 'topic-' + topic, 'Forget Topic…')
            if live:
                kill = 'palette-row-session-' + sid
                s.wait_rows(lambda rows: s.has(kill, rows), 'Forget did not offer the live Session')
                s.act('press', kill)
            key = 'palette-row-worktree-' + str(tree)
            s.wait_rows(lambda rows: s.has(key, rows), 'Forget did not offer the clean Worktree')
            s.act('press', key)
            s.wait_rows(lambda rows: 'Remove' in s.row(key, rows).get('accessibilityLabel', ''), 'Worktree removal did not select')
            self.assertTrue(s.tmux('display-message', '-p', '#{socket_path}').startswith(str(s.root) + '/'))
            s.act('press', 'palette-accept')
            wait(lambda: topic not in self.records(), 'Forget kept the Topic record')
            self.assertFalse(tree.exists())
            self.assertEqual((dirty/'draft').read_text(), 'untracked work')
            s.wait_rows(lambda rows: not s.has('palette-accept', rows), 'Forget did not close')

    def test_new_worktree_topic_opens_session_in_git_worktree_on_its_branch(self):
        record = self.new_topic('Worktree proof', self.alpha_tree['worktree-base'], worktree=True)
        name = 'alpha/worktree-base/worktree-proof'
        expected = str(self.worktrees/'alpha/worktree-proof')
        paths = (expected, os.path.realpath(expected))
        self.wait_session(name)
        def session_fields():
            """session path, pane path, Topic; None until tmux knows the Pane path, which it reports once the Pane's process runs."""
            fields = self.s.tmux('display-message', '-p', '-t', '=' + name + ':',
                                 '#{session_path}|#{pane_current_path}|#{@muxify_topic}').split('|')
            return fields if fields[1] else None
        session_path, pane_path, topic = wait(session_fields, 'Session %s has no Pane path' % name, seconds=10)
        self.assertIn(session_path, paths, 'Session path')
        self.assertIn(pane_path, paths, 'Pane path')
        self.assertEqual(topic, record['id'], 'Session %s names the wrong Topic' % name)
        listing = subprocess.check_output(['/usr/bin/git', '-C', str(self.alpha), 'worktree', 'list'], text=True)
        self.assertTrue(any(line.startswith(tuple(path + ' ' for path in paths)) and '[worktree-proof]' in line
                            for line in listing.splitlines()), 'git worktree list:\n' + listing)

    def test_worktree_topic_session_row_keeps_selected_base(self):
        record = self.new_topic('Worktree row proof', self.alpha_tree['worktree-row-base'], worktree=True)
        name = 'alpha/worktree-row-base/worktree-row-proof'
        self.wait_session(name)
        sid = self.s.tmux('display-message', '-p', '-t', '=' + name + ':', '#{session_id}')
        key = 'topic-%s-session-%s' % (record['id'], sid)
        labelled = lambda rs: self.s.row(key, rs).get('accessibilityLabel') == 'alpha/worktree-row-base'
        self.find(key)
        latency, rs = self.rows_until(labelled)
        self.assertIsNotNone(latency, 'Topic Session row %s: %s' % (key, json.dumps(self.s.row(key, rs))))

    def test_add_session_list_shows_one_row_per_worktree_of_a_bare_repository(self):
        s = self.s
        self.create_topic('Bare rows proof')
        self.open_add_session()
        for folder in ['main', 'release']:
            row = s.row(self.project_row(self.gamma/folder))
            self.assertTrue(row.get('accessibilityLabel', '').startswith('gamma/' + folder), json.dumps(row))
        s.act('set', 'palette-search', 'gamma/main')
        rs = s.wait_rows(lambda rs: s.has('palette-row-' + os.path.realpath(self.gamma/'main'), rs), 'search by repo/folder found no gamma/main row')
        self.assertFalse(s.has('palette-row-' + os.path.realpath(self.gamma), rs), 'the bare folder itself is a row')
        s.act('set', 'palette-search', 'gamma/rel')
        rs = s.wait_rows(lambda rs: not s.has('palette-row-' + os.path.realpath(self.gamma/'main'), rs), 'search did not narrow the list')
        self.assertTrue(s.has('palette-row-' + os.path.realpath(self.gamma/'release'), rs), 'search by repo/folder lost the Worktree row')

    def test_worktree_of_another_open_topic_says_also_in_it_and_can_be_picked(self):
        s = self.s
        self.write_topic('shared-owner', 'Shared owner', self.gamma, created_at='2026-10-07T00:00:00Z', order=0)
        self.new_session('gamma/shared-owner', self.gamma/'main', topic='shared-owner')
        s.wait_rows(lambda rs: s.has('topic-shared-owner', rs), 'no row for Topic shared-owner')
        record = self.create_topic('Shared picker')
        self.open_add_session()
        s.act('focus', 'palette-search')
        s.act('set', 'palette-search', str(self.gamma/'main'))
        key = self.project_row(self.gamma/'main')
        s.wait_rows(lambda rs: 'Also in Shared owner' in s.row(key, rs).get('accessibilityLabel', ''),
                    'the Worktree row does not say Also in Shared owner')
        name = 'gamma/main/shared-picker'
        self.pick_project(self.gamma/'main', worktree=False)
        s.act('press', 'palette-accept')
        s.wait_rows(lambda rs: not s.has('palette-accept', rs), 'Add a Session Path did not take the shared Worktree row', seconds=15)
        self.wait_session(name)
        # The client is on the new Session. Killing it first would start the App Window's Window recovery,
        # which can pull the client back while the cleanup moves it to base.
        self.addCleanup(self.end_session, s.tmux('display-message', '-p', '-t', '=' + name + ':', '#{session_id}'))
        session_path = s.tmux('display-message', '-p', '-t', '=' + name + ':', '#{session_path}')
        self.assertIn(session_path, (str(self.gamma/'main'), os.path.realpath(self.gamma/'main')), 'Session path')
        self.assertEqual(s.tmux('display-message', '-p', '-t', '=gamma/shared-owner:', '#{@muxify_topic}'), 'shared-owner',
                         'the other Topic lost its Session in the shared Worktree')
        sessions = wait(lambda: self.records()[record['id']].get('sessions'), 'Topic Shared picker remembers no Session', seconds=15)
        self.assertEqual([(x.get('worktree_path'), x.get('worktree_created')) for x in sessions], [(str(self.gamma/'main'), False)],
                         json.dumps(sessions))

    def test_topic_on_a_picked_worktree_opens_its_session_there_under_the_worktrees_name(self):
        record = self.new_topic('Release worktree proof', self.gamma/'release')
        name = 'gamma/release/release-worktree-proof'
        self.wait_session(name)
        sid, session_path = self.s.tmux('display-message', '-p', '-t', '=' + name + ':', '#{session_id}|#{session_path}').split('|')
        self.assertIn(session_path, (str(self.gamma/'release'), os.path.realpath(self.gamma/'release')), 'Session path')
        self.assertEqual(record['sessions'][0].get('worktree_path'), str(self.gamma/'release'), json.dumps(record))
        key = 'topic-%s-session-%s' % (record['id'], sid)
        named = lambda rs: self.s.row(key, rs).get('accessibilityLabel') == 'gamma/release'
        self.find(key)
        latency, rs = self.rows_until(named)
        self.assertIsNotNone(latency, 'Topic Session row %s: %s' % (key, json.dumps(self.s.row(key, rs))))

    def test_new_worktree_from_a_chosen_base_of_a_bare_repository_lands_in_muxifys_worktrees_folder_on_the_slug_branch(self):
        base = self.gamma/'base'
        git = ['/usr/bin/git', '-C', str(base), '-c', 'user.name=Verifier', '-c', 'user.email=verifier@example.invalid',
               '-c', 'commit.gpgSign=false']
        (base/'BASE-NOTES').write_text('base\n')
        subprocess.run(git + ['add', 'BASE-NOTES'], check=True)
        subprocess.run(git + ['commit', '-q', '-m', 'base only'], check=True)
        base_head = subprocess.check_output(git + ['rev-parse', 'HEAD'], text=True).strip()
        record = self.new_topic('Base proof', base, worktree=True)
        expected = str(self.worktrees/'gamma/base-proof')
        self.wait_session('gamma/base/base-proof')
        session_path = self.s.tmux('display-message', '-p', '-t', '=gamma/base/base-proof:', '#{session_path}')
        self.assertIn(session_path, (expected, os.path.realpath(expected)), 'Session path')
        self.assertEqual(subprocess.check_output(['/usr/bin/git', '-C', expected, 'rev-parse', 'HEAD'], text=True).strip(), base_head,
                         'the new Worktree does not start at the base HEAD')
        self.assertEqual(subprocess.check_output(['/usr/bin/git', '-C', expected, 'symbolic-ref', '--short', 'HEAD'], text=True).strip(),
                         'base-proof', 'the new Worktree is not on the slug branch')
        session = record['sessions'][0]
        self.assertEqual(session.get('worktree_path'), expected, json.dumps(record))
        self.assertIs(session.get('worktree_created'), True, json.dumps(record))

    def test_main_checkout_of_a_plain_repository_is_a_worktree_row_that_says_also_in_its_topic(self):
        s = self.s
        record = self.new_topic('Main checkout proof', self.epsilon)
        name = 'epsilon/main-checkout-proof'
        self.wait_session(name)
        sid, session_path = s.tmux('display-message', '-p', '-t', '=' + name + ':', '#{session_id}|#{session_path}').split('|')
        self.assertIn(session_path, (str(self.epsilon), os.path.realpath(self.epsilon)), 'Session path')
        session = record['sessions'][0]
        self.assertEqual(session.get('worktree_path'), str(self.epsilon), json.dumps(record))
        self.assertIs(session.get('worktree_created'), False, json.dumps(record))
        key = 'topic-%s-session-%s' % (record['id'], sid)
        named = lambda rs: s.row(key, rs).get('accessibilityLabel') == 'epsilon'
        self.find(key)
        latency, rs = self.rows_until(named)
        self.assertIsNotNone(latency, 'Topic Session row %s: %s' % (key, json.dumps(s.row(key, rs))))
        self.create_topic('Main checkout picker')
        self.open_add_session()
        row = self.project_row(self.epsilon)
        s.wait_rows(lambda rs: 'Also in Main checkout proof' in s.row(row, rs).get('accessibilityLabel', ''),
                    'the main checkout of epsilon does not say Also in Main checkout proof')

    def test_live_session_of_an_older_topic_in_the_project_folder_shows_on_the_main_checkout(self):
        s = self.s
        self.write_topic('legacy-owner', 'Legacy owner', self.delta, created_at='2026-10-07T00:00:00Z', order=0)
        self.new_session('delta/legacy-owner', self.delta, topic='legacy-owner')
        s.wait_rows(lambda rs: s.has('topic-legacy-owner', rs), 'no row for Topic legacy-owner')
        self.create_topic('Legacy picker')
        self.open_add_session()
        key = self.project_row(self.delta)
        s.wait_rows(lambda rs: 'Also in Legacy owner' in s.row(key, rs).get('accessibilityLabel', ''),
                    'the main checkout of delta does not say Also in Legacy owner')

    def test_add_session_with_new_worktree_opens_the_session_in_a_worktree_from_the_picked_base(self):
        s = self.s
        self.write_topic('add-worktree', 'Add worktree proof', self.beta, created_at='2026-10-07T00:00:00Z', order=0)
        self.new_session('beta/add-worktree', self.beta, topic='add-worktree')
        s.wait_rows(lambda rs: s.has('topic-add-worktree', rs), 'no row for Topic add-worktree')
        self.addCleanup(lambda: s.has('palette-accept') and s.act('press', 'palette-cancel'))
        s.act('action', 'topic-add-worktree', 'Add a Session…')
        s.wait_rows(lambda rs: s.has('palette-accept', rs), 'Add Session Path palette did not open')
        base = self.acme/'base'
        git = ['/usr/bin/git', '-C', str(base), '-c', 'user.name=Verifier', '-c', 'user.email=verifier@example.invalid',
               '-c', 'commit.gpgSign=false']
        (base/'ADD-PROJECT-NOTES').write_text('add project base\n')
        subprocess.run(git + ['add', 'ADD-PROJECT-NOTES'], check=True)
        subprocess.run(git + ['commit', '-q', '-m', 'add project base'], check=True)
        self.pick_project(base, worktree=True)
        s.act('press', 'palette-accept')
        name = 'acme/base/add-worktree'
        expected = self.worktrees/'acme/add-worktree'
        self.wait_session(name)
        session_path = s.tmux('display-message', '-p', '-t', '=' + name + ':', '#{session_path}')
        self.assertIn(session_path, (str(expected), os.path.realpath(expected)), 'Session path')
        git_out = lambda path, *args: subprocess.check_output(['/usr/bin/git', '-C', str(path)] + list(args), text=True).strip()
        self.assertEqual(git_out(expected, 'symbolic-ref', '--short', 'HEAD'), 'add-worktree', 'the new Worktree is not on the slug branch')
        self.assertEqual(git_out(expected, 'rev-parse', 'HEAD'), git_out(base, 'rev-parse', 'HEAD'), 'the new Worktree does not start at the base HEAD')
        sessions = self.records()['add-worktree']['sessions']
        self.assertTrue(any(session.get('repository_path') == str(self.acme) and session.get('worktree_path') == str(expected)
                            and session.get('worktree_created') is True for session in sessions), json.dumps(sessions))
        s.wait_rows(lambda rs: not s.has('palette-accept', rs), 'Add Session Path palette did not close')

    def test_add_session_opens_with_new_worktree_off_after_a_project_added_with_it(self):
        s = self.s
        self.write_topic('add-reset', 'Add reset proof', self.beta, created_at='2026-10-07T00:00:00Z', order=0)
        self.new_session('beta/add-reset', self.beta, topic='add-reset')
        s.wait_rows(lambda rs: s.has('topic-add-reset', rs), 'no row for Topic add-reset')
        self.addCleanup(lambda: s.has('palette-accept') and s.act('press', 'palette-cancel'))
        s.act('action', 'topic-add-reset', 'Add a Session…')
        s.wait_rows(lambda rs: s.has('palette-accept', rs), 'Add Session Path palette did not open')
        self.pick_project(self.acme/'base', worktree=True)
        s.act('press', 'palette-accept')
        self.wait_session('acme/base/add-reset')
        s.wait_rows(lambda rs: not s.has('palette-accept', rs), 'Add Session Path palette did not close')
        s.act('action', 'topic-add-reset', 'Add a Session…')
        s.wait_rows(lambda rs: s.has('palette-accept', rs), 'Add Session Path palette did not open again')
        # Paths remain available for repeated-folder Sessions. A fresh step starts New Worktree off.
        s.act('focus', 'palette-search')
        s.act('set', 'palette-search', str(self.gamma/'main'))
        key = self.project_row(self.gamma/'main')
        s.wait_rows(lambda rs: s.row(key, rs).get('accessibilityValue') == 'selected', 'the gamma/main row is not selected')
        rs = s.wait_rows(lambda rs: s.has('palette-new-worktree', rs), 'no New Worktree option for the repository row')
        self.assertEqual(s.row('palette-new-worktree', rs).get('accessibilityValue'), 'off',
                         'New Worktree stayed on after the Session Path that used it')

    def test_existing_branch_allocates_a_new_worktree_name_without_changing_the_topic_slug(self):
        s = self.s
        self.write_topic('add-clash', 'Add clash proof', self.beta, created_at='2026-10-07T00:00:00Z', order=0)
        self.new_session('beta/add-clash', self.beta, topic='add-clash')
        s.wait_rows(lambda rs: s.has('topic-add-clash', rs), 'no row for Topic add-clash')
        subprocess.run(['/usr/bin/git', '-C', str(self.acme), 'branch', 'add-clash', 'main'], check=True)
        self.addCleanup(lambda: s.has('palette-accept') and s.act('press', 'palette-cancel'))
        s.act('action', 'topic-add-clash', 'Add a Session…')
        s.wait_rows(lambda rs: s.has('palette-accept', rs), 'Add Session Path palette did not open')
        self.pick_project(self.acme/'base', worktree=True)
        s.act('press', 'palette-accept')
        self.wait_session('acme/base/add-clash')
        expected = self.worktrees/'acme/add-clash-2'
        self.assertTrue(expected.is_dir())
        record = self.records()['add-clash']
        self.assertEqual(record['slug'], 'add-clash')
        saved = next(row for row in record['sessions'] if row.get('worktree_path') == str(expected))
        self.assertEqual(saved['branch'], 'add-clash-2')
        self.assertTrue(saved['worktree_created'])
