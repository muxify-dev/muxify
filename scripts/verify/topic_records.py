"""The Topic records of a sandbox: the `topics` and `open_places` tables of `state/muxify/muxify.db`, read and
written with Python's `sqlite3`, as another process writes them. `worktrees()` reads the Muxify Worktree records of
the `worktrees` table.

A record is a dict in the shape the old `topics.json` had: the columns by name, with `sessions` and `tags` as lists,
`pinned`, `guest` and `unread` as `True` or left out, `session_order` as `'manual'` or left out, and every other
column left out when it is NULL. A write is one transaction that changes only the rows it names. No write takes a lock
of Muxify's own: SQLite's own locks keep two writers apart, and a writer waits up to 10 seconds for another, as the app
does.
"""

import contextlib
import json
import sqlite3
from pathlib import Path

# The columns of `topics` besides `id`.
TEXT = ['title', 'slug', 'outcome', 'created_at', 'settled_at', 'session_order', 'note']
FLAGS = ['pinned', 'guest', 'unread']
LISTS = ['sessions', 'tags']
COLUMNS = TEXT + ['order'] + FLAGS + LISTS

# The tables as the app makes them. A helper that runs before the app's first launch makes them too, at the same
# `user_version`, so the app then finds nothing to add.
SCHEMA = [
    '''CREATE TABLE IF NOT EXISTS topics (
        id TEXT PRIMARY KEY NOT NULL, title TEXT, slug TEXT, outcome TEXT, "order" REAL, created_at TEXT,
        settled_at TEXT, session_order TEXT, pinned INTEGER NOT NULL DEFAULT 0, guest INTEGER NOT NULL DEFAULT 0,
        unread INTEGER NOT NULL DEFAULT 0, note TEXT, sessions TEXT NOT NULL DEFAULT '[]', tags TEXT NOT NULL DEFAULT '[]')''',
    '''CREATE TABLE IF NOT EXISTS open_places (id TEXT PRIMARY KEY NOT NULL, "order" REAL NOT NULL)''',
    '''CREATE TABLE IF NOT EXISTS worktrees (
        id TEXT PRIMARY KEY NOT NULL, environment TEXT, repository TEXT NOT NULL, name TEXT NOT NULL,
        path TEXT NOT NULL UNIQUE, branch TEXT NOT NULL, base TEXT NOT NULL, created_at TEXT NOT NULL)''',
    '''CREATE TABLE IF NOT EXISTS browser_history (
        key TEXT PRIMARY KEY NOT NULL, url TEXT NOT NULL, title TEXT NOT NULL, folded_score REAL, folded_at REAL,
        recent TEXT NOT NULL DEFAULT '[]', topics TEXT NOT NULL DEFAULT '[]')''',
]
SCHEMA_VERSION = 3


class TopicRecords:
    def __init__(self, state):
        """`state` is the sandbox's `state/muxify` folder."""
        self.state = Path(state)
        self.path = self.state/'muxify.db'
        self._held = None

    @contextlib.contextmanager
    def _connection(self, write=False):
        """The held connection inside `held`, else a new one. With `write`, the block is one transaction that
        commits at its end, or rolls back when it raises."""
        if self._held is not None:
            yield self._held
            return
        connection = self._open()
        try:
            if not write:
                yield connection
                return
            connection.execute('BEGIN IMMEDIATE')
            try:
                yield connection
            except BaseException:
                connection.execute('ROLLBACK')
                raise
            connection.execute('COMMIT')
        finally:
            connection.close()

    def _open(self):
        self.state.mkdir(parents=True, exist_ok=True)
        connection = sqlite3.connect(str(self.path), timeout=10, isolation_level=None)
        connection.execute('PRAGMA journal_mode = WAL')
        version = connection.execute('PRAGMA user_version').fetchone()[0]
        if version < SCHEMA_VERSION:
            connection.execute('BEGIN IMMEDIATE')
            for statement in SCHEMA:
                connection.execute(statement)
            connection.execute('PRAGMA user_version = %d' % SCHEMA_VERSION)
            connection.execute('COMMIT')
        return connection

    # Reads.

    @staticmethod
    def _record(row):
        record = {'id': row['id']}
        for column in TEXT:
            if row[column] is not None:
                record[column] = row[column]
        if row['order'] is not None:
            record['order'] = row['order']
        for column in FLAGS:
            if row[column]:
                record[column] = True
        record['sessions'] = json.loads(row['sessions'] or '[]')
        tags = json.loads(row['tags'] or '[]')
        if tags:
            record['tags'] = tags
        return record

    def read(self):
        """A dict with `records`, a list of records in id order, and `open_places`, as `topics.json` had them."""
        if not self.path.exists():
            return {'records': [], 'open_places': []}
        with self._connection() as connection:
            connection.row_factory = sqlite3.Row
            try:
                records = [self._record(row) for row in connection.execute('SELECT * FROM topics ORDER BY id')]
                places = [dict(id=row['id'], order=row['order'])
                          for row in connection.execute('SELECT id, "order" FROM open_places ORDER BY rowid')]
            finally:
                connection.row_factory = None
        return {'records': records, 'open_places': places}

    def records(self):
        """Every record, by id."""
        return {record['id']: record for record in self.read()['records']}

    def get(self, topic_id):
        """The record with this id, or None."""
        return self.records().get(topic_id)

    def ids(self):
        return sorted(self.records())

    def open_places(self):
        return self.read()['open_places']

    def worktrees(self):
        """Every Muxify Worktree record, oldest first, as a dict in the shape the old `worktrees/<id>.json` had:
        the columns by name, with `environment` left out when it is NULL."""
        if not self.path.exists():
            return []
        with self._connection() as connection:
            connection.row_factory = sqlite3.Row
            try:
                rows = connection.execute('SELECT * FROM worktrees ORDER BY created_at, id').fetchall()
            finally:
                connection.row_factory = None
        return [{key: row[key] for key in row.keys() if row[key] is not None} for row in rows]

    # Changes.

    @contextlib.contextmanager
    def held(self):
        """Holds the database's write lock for the block, as another process in a long transaction does. A change
        inside the block joins that transaction, and the block commits it at its end."""
        if self._held is not None:
            yield
            return
        connection = self._open()
        try:
            connection.execute('BEGIN IMMEDIATE')
            self._held = connection
            try:
                yield
            except BaseException:
                connection.execute('ROLLBACK')
                raise
            connection.execute('COMMIT')
        finally:
            self._held = None
            connection.close()

    def put(self, record):
        """Writes the record in the place of the row with its id, or as a new row. A key the record leaves out is
        NULL, or false for a flag, or empty for a list."""
        values = [record['id']]
        for column in TEXT:
            values.append(record.get(column))
        values.append(record.get('order'))
        for column in FLAGS:
            values.append(1 if record.get(column) else 0)
        for column in LISTS:
            values.append(json.dumps(record.get(column) or [], sort_keys=True))
        names = ', '.join('"%s"' % column for column in ['id'] + COLUMNS)
        marks = ', '.join('?' for _ in values)
        with self._connection(write=True) as connection:
            connection.execute('INSERT OR REPLACE INTO topics (%s) VALUES (%s)' % (names, marks), values)

    def remove(self, topic_id):
        """Removes the row with this id. Nothing happens when there is none."""
        with self._connection(write=True) as connection:
            connection.execute('DELETE FROM topics WHERE id = ?', (topic_id,))

    def set_open_places(self, places):
        with self._connection(write=True) as connection:
            connection.execute('DELETE FROM open_places')
            connection.executemany('INSERT INTO open_places (id, "order") VALUES (?, ?)',
                                   [(place['id'], place['order']) for place in places])
