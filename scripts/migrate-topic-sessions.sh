#!/bin/bash
# One-off beta migration. Python 3 supplies JSON, atomic replacement and flock on macOS.
set -euo pipefail
exec python3 - "$@" <<'PY'
import argparse
import copy
import datetime
import fcntl
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import uuid

parser = argparse.ArgumentParser(description="Convert local Topic records to Session identities. Quit Muxify and stop Topic CLI edits first. Dry-run unless --apply is supplied; tmux is only read, never changed.")
parser.add_argument('--state-dir', type=Path, default=Path(os.environ.get('XDG_STATE_HOME') or Path.home()/'.local/state')/'muxify')
mode = parser.add_mutually_exclusive_group()
mode.add_argument('--apply', action='store_true')
mode.add_argument('--dry-run', action='store_true')
parser.add_argument('--socket', help='read this tmux socket instead of the default socket')
parser.add_argument('--no-tmux', action='store_true', help='use reported folder-derived fallbacks only')
args = parser.parse_args()
state = args.state_dir.expanduser().resolve()
if not (state/'topics').is_dir():
    parser.error(f'no topics directory in {state}')

env = {k: v for k, v in os.environ.items() if k not in ('TMUX', 'TMUX_PANE')}
tmux = [shutil.which('tmux') or 'tmux'] + (['-S', args.socket] if args.socket else [])
live = []
if not args.no_tmux:
    try:
        # One read command queue: membership, exact names, launch folders, durable ids and Window ids.
        output = subprocess.run(tmux + ['list-windows', '-a', '-F',
            '#{session_id}\t#{session_name}\t#{session_path}\t#{@muxify_topic}\t#{@muxify_session_id}\t#{session_created}\t#{window_id}\t#{pid}:#{start_time}'],
            env=env, capture_output=True, text=True, check=True, timeout=10).stdout
        sessions = {}
        for line in output.splitlines():
            sid, name, directory, topic, saved, created, wid, server = line.split('\t')
            row = sessions.setdefault(sid, dict(id=saved or f'tmux:{server}:{sid}:{created}', name=name, directory=directory, topic=topic, windows=set()))
            row['windows'].add(wid)
        live = list(sessions.values())
    except (OSError, subprocess.SubprocessError, ValueError) as error:
        parser.error(f'tmux inventory unavailable ({error}); rerun with --no-tmux to explicitly accept fallbacks')

def canonical(path):
    return os.path.realpath(os.path.expanduser(path))

def base(name, slug):
    suffix = '/' + slug if slug else ''
    return name[:-len(suffix)] if suffix and name.endswith(suffix) else name

def folder_name(path):
    return Path(path).name.replace(' ', '').replace('.', '_').replace(':', '_') or 'session'

def allocate(stem, slug, taken):
    suffix = '/' + slug if slug else ''
    name = stem + suffix
    n = 2
    while name in taken:
        name = f'{stem}+{n}{suffix}'
        n += 1
    taken.add(name)
    return name

def convert(record, filename):
    result = copy.deepcopy(record)
    result.pop('home_project', None)
    entries = result.get('sessions', [])
    if not isinstance(entries, list):
        raise ValueError(f'{filename}: sessions must be an array')
    members = [s for s in live if s['topic'] == record['id']]
    used = set()
    # Reserve all recoverable names before fallbacks, even when those entries occur later.
    names = {s['name'] for s in members} | {e['name'] for e in entries if isinstance(e, dict) and isinstance(e.get('name'), str)}
    converted = []
    for entry in entries:
        if not isinstance(entry, dict):
            raise ValueError(f'{filename}: invalid Session entry')
        if all(entry.get(k) for k in ('id', 'name', 'directory')):
            entry.setdefault('base_name', base(entry['name'], record.get('slug')))
            converted.append(entry)
            names.add(entry['name'])
            used.add(entry['id'])
            continue
        directory = entry.get('worktree_path') or entry.get('project_path') or entry.get('repository_path')
        if not isinstance(directory, str) or not directory:
            raise ValueError(f'{filename}: Session has no launch directory')
        old_windows = {w.get('window_id') for w in entry.get('windows', []) if isinstance(w, dict)}
        matches = [s for s in members if s['id'] not in used and s['windows'] & old_windows]
        if not matches:
            matches = [s for s in members if s['id'] not in used and canonical(s['directory']) == canonical(directory)]
        if len(matches) > 1:
            raise ValueError(f'{filename}: ambiguous live Sessions for {directory}; no files changed')
        row = copy.deepcopy(entry)
        repository = row.pop('project_path', None) or row.get('repository_path')
        if row.get('worktree_path') and repository:
            row['repository_path'] = repository
            if row.get('worktree_created') is not True:
                row['worktree_created'] = False
                print(f'KEEP WORKTREE (no explicit ownership): {filename}: {directory}')
        else:
            row.pop('repository_path', None)
        if matches:
            member = matches[0]
            row.update(id=member['id'], name=member['name'], directory=member['directory'])
            used.add(member['id'])
            names.add(member['name'])
            print(f'LIVE: {filename}: {member["name"]}')
        else:
            slug = record.get('slug')
            stem = folder_name(repository or directory)
            if entry.get('worktree_path') and canonical(directory) != canonical(repository or directory):
                stem += '/' + folder_name(directory)
            name = allocate(stem, slug, names)
            row.update(id=str(uuid.uuid4()), name=name, directory=directory)
            print(f'FALLBACK (inactive name cannot be recovered): {filename}: {directory} -> {name}')
        row['base_name'] = base(row['name'], record.get('slug'))
        converted.append(row)
    # Membership is authoritative; include a live member that had not reached its delayed record write.
    for member in members:
        if member['id'] not in used:
            converted.append(dict(id=member['id'], name=member['name'], base_name=base(member['name'], record.get('slug')), directory=member['directory'], windows=[]))
            print(f'LIVE (not yet remembered): {filename}: {member["name"]}')
    result['sessions'] = converted
    ids = [s['id'] for s in converted]
    if len(set(ids)) != len(ids):
        raise ValueError(f'{filename}: duplicate Session identity')
    return result

# Use the same edit -> record lock order as the app. Dry-run does not create any file.
locks = []
try:
    for name in ('topic-edits.lock', 'topics.lock'):
        path = state/name
        if args.apply or path.exists():
            handle = path.open('a' if args.apply else 'r')
            fcntl.flock(handle, fcntl.LOCK_EX | fcntl.LOCK_NB)
            locks.append(handle)
    changes = []
    for path in sorted((state/'topics').glob('*.json')):
        if path.is_symlink():
            raise ValueError(f'refusing symlink: {path}')
        record = json.loads(path.read_text())
        if record.get('id') != path.stem:
            raise ValueError(f'{path}: filename and Topic id differ')
        converted = convert(record, path.name)
        if converted != record:
            changes.append((path, converted))
    if args.apply and changes:
        stamp = datetime.datetime.now().strftime('%Y%m%d-%H%M%S') + '-' + uuid.uuid4().hex[:8]
        backup = state/('topics-before-session-migration-' + stamp)
        backup.mkdir(mode=0o700)
        for path, _ in changes:
            shutil.copy2(path, backup/path.name)
        print(f'BACKUP: {backup}')
        for path, record in changes:
            fd, temporary = tempfile.mkstemp(prefix='.' + path.stem + '-', dir=path.parent)
            try:
                with os.fdopen(fd, 'w') as out:
                    json.dump(record, out, ensure_ascii=False, indent=2)
                    out.write('\n')
                    out.flush()
                    os.fsync(out.fileno())
                shutil.copymode(path, temporary)
                os.replace(temporary, path)
            finally:
                if os.path.exists(temporary):
                    os.unlink(temporary)
    print(f'{"APPLIED" if args.apply else "DRY RUN"}: {len(changes)} Topic file(s); no tmux changes.')
except (ValueError, OSError, KeyError) as error:
    raise SystemExit(str(error))
finally:
    for handle in reversed(locks):
        handle.close()
PY
