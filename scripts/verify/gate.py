"""The verify gate: passes only when a full verify run passed on exactly this checkout.

    python3 -m scripts.verify.gate

It fails when no full run passed on the files of now, committed or not. run.py writes
LAST_FULL_RUN, and runs the gate at the end of each run.
"""

import json
import os
import pathlib
import subprocess
import sys
import tempfile
import time

REPO = pathlib.Path(__file__).resolve().parents[2]
# Inside the checkout, so a run in another checkout or worktree cannot change what this one proved.
EVIDENCE = REPO/'build/verify'
LAST_FULL_RUN = EVIDENCE/'last-full-run.json'
TIME = '%Y-%m-%dT%H:%M:%S'


def git(*args, env=None):
    return subprocess.run(['git', *args], cwd=REPO, env=env, capture_output=True, check=True).stdout.decode().strip()


def tree_state():
    """What a run proves: the git tree id of every file as it is now, untracked files too. A commit of exactly
    these files has the same tree, so committing what passed keeps the gate passed. A scratch index leaves the
    user's staged changes alone."""
    with tempfile.TemporaryDirectory() as scratch:
        env = dict(os.environ, GIT_INDEX_FILE=os.path.join(scratch, 'index'))
        git('read-tree', 'HEAD', env=env)
        git('add', '--all', env=env)
        files = git('write-tree', env=env)
    return dict(head=git('rev-parse', 'HEAD'), files=files)


def record_full_run(run, tree, passed):
    """The latest full run wins: a full run that fails on a tree takes back the pass of an earlier one."""
    LAST_FULL_RUN.write_text(json.dumps(dict(tree, run=run, passed=passed, time=time.strftime(TIME)), indent=2))


def problems():
    """Why the gate fails; empty when it passes."""
    found = []
    try:
        last = json.loads(LAST_FULL_RUN.read_text())
    except (FileNotFoundError, ValueError):
        last = None
        found.append('no full verify run in this checkout')
    if last:
        tree = tree_state()
        if last.get('files') != tree['files']:
            found.append('the files differ from those of the last full run %s, on %s' % (last['run'], last['head'][:9]))
        elif not last['passed']:
            found.append('the last full run %s on this tree failed' % last['run'])
    return found


def main():
    found = problems()
    if found:
        print('verify gate: FAILED\n' + '\n'.join('  - ' + problem for problem in found))
        return 1
    print('verify gate: passed (full run %s)' % json.loads(LAST_FULL_RUN.read_text())['run'])
    return 0


if __name__ == '__main__':
    sys.exit(main())
