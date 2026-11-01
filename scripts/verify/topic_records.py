"""The Topic records of a sandbox: `state/muxify/topics.json`, read and written as the app writes it.

The file is one JSON object: `records`, a list of Topic records, and `open_places`, a list of Open Places. A change
holds the exclusive record lock (`topics.lock`, an flock, the one `TopicStore` takes) while it reads the file, changes
it and replaces it with one rename. The app reads a record and renames its new version in under that lock, so a change
between the two would bring the record back, or lose the app's write.
"""

import contextlib
import fcntl
import json
import os
from pathlib import Path

EMPTY = {'records': [], 'open_places': []}


class TopicRecords:
    def __init__(self, state):
        """`state` is the sandbox's `state/muxify` folder."""
        self.state = Path(state)
        self.path = self.state/'topics.json'
        self.lock_path = self.state/'topics.lock'
        self._lock = None

    # Reads. A read takes no lock: the app replaces the file with one rename, so a read sees a whole file.

    def read(self):
        """The file as a dict with `records` and `open_places`; the empty shape when there is no file."""
        if not self.path.exists():
            return json.loads(json.dumps(EMPTY))
        return json.loads(self.path.read_text())

    def records(self):
        """The entries that have a string `id`, by id. An entry that is not a record is left out."""
        return {entry['id']: entry for entry in self.read()['records']
                if isinstance(entry, dict) and isinstance(entry.get('id'), str)}

    def get(self, topic_id):
        """The record with this id, or None."""
        return self.records().get(topic_id)

    def ids(self):
        return sorted(self.records())

    def open_places(self):
        return self.read().get('open_places') or []

    # Changes.

    @contextlib.contextmanager
    def held(self):
        """Holds the exclusive record lock for the block, as a virus scanner holds a file open. A change inside the
        block uses this lock."""
        if self._lock is not None:
            yield
            return
        self.state.mkdir(parents=True, exist_ok=True)
        with open(self.lock_path, 'a') as lock:
            fcntl.flock(lock, fcntl.LOCK_EX)
            self._lock = lock
            try:
                yield
            finally:
                self._lock = None

    def change(self, apply):
        """Runs `apply(data)` on the file's dict under the lock, and replaces the file with one rename."""
        with self.held():
            data = self.read()
            apply(data)
            temporary = self.path.with_name(self.path.name + '.tmp-%d' % os.getpid())
            temporary.write_text(json.dumps(data, indent=2, sort_keys=True))
            os.replace(temporary, self.path)

    def put(self, record):
        """Writes the record in the place of the entry with its id, or at the end."""
        def apply(data):
            entries = data['records']
            for index, entry in enumerate(entries):
                if isinstance(entry, dict) and entry.get('id') == record['id']:
                    entries[index] = record
                    return
            entries.append(record)
        self.change(apply)

    def remove(self, topic_id):
        """Removes the entries with this id. Nothing happens when there is none."""
        self.change(lambda data: data['records'].__setitem__(
            slice(None), [e for e in data['records'] if not (isinstance(e, dict) and e.get('id') == topic_id)]))

    def set_open_places(self, places):
        self.change(lambda data: data.__setitem__('open_places', list(places)))
