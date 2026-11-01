# The Topic records live in one file

Every Topic record and the Open Places are one JSON file, `$XDG_STATE_HOME/muxify/topics.json`. A write replaces the file with one rename, so a write of any size makes one new file, and a read opens one file. This supersedes the file layout of [ADR 0028](0028-topic-records-live-outside-tmux.md), one file for each Topic in `topics/`, and the `open-places` file of [ADR 0064](0064-in-play-places-stay-open-and-guests-show-in-their-own-section.md). The record itself, the locks and the merge by JSON key of [ADR 0032](0032-the-cli-runs-topic-requests-through-muxifycore.md) do not change.

A virus scanner with a real-time scan holds each new or changed file open for seconds. With one file for each Topic, a write that changed two records, or removed one, copied the whole folder and swapped it in with one rename, so that a reader never saw half of the change. On a Mac with 77 Topics, each Settle, End Guest or In Play move made 78 new files, and every reader then opened 77 files again, because each had a new inode. The app froze for seconds after each of them.

The file is one object:

```json
{
  "open_places": [{"id": "6f1c…", "order": 2.5}],
  "records": [{"id": "reward-drop", "title": "Fix reward drop", "…": "…"}]
}
```

`records` holds the records in id order, by bytes, so every read lists them the same way, as the file names did. `open_places` holds the Open Places. The file is pretty-printed with sorted keys, as each record was: a person can read and diff it, and the size of one file does not matter to a scanner, which counts files.

## Considered Options

- **One file for each Topic, and a generation file that names the valid set.** A write would write only the changed records and then the generation file. Rejected: a reader must then open every named file, and a reader still opens one file for each Topic. The format would change as much as with one file, for less gain.
- **The records in memory, in one owner process, written behind.** Rejected for now: on `master` each App Window and each `muxify` command reads and writes the files, and only the files and the record lock keep them in agreement. An owner needs a transport from the command line tool and a lock on the state folder, and each flush would still copy the folder. One file first; an owner, if a measurement still shows stalls, after.
- **An exclusion in the scanner.** It needs the IT team on a managed Mac, and it does not help other users.

## Consequences

- A write that changes nothing writes no file. A write that changes anything writes the whole file once, with one atomic rename.
- An entry of `records` that is not a valid record, such as a record with one field of a wrong type, a second record with the id of an earlier one, or a value that is not an object, is a problem line in the Diagnostics log, and every write puts it back as it is. No write loses a record because one field is bad. A new Topic cannot take the id of such an entry. A file that is not a records file at all, not an object with a `records` array, is a problem line too, and no write replaces it: a write fails and names the file.
- The app's watcher polls the inode, modification time and size of one file, without the lock.
- The first write after the update moves the records out of the old folder: it reads `topics/<id>.json` for each Topic and `topics/open-places`, writes `topics.json`, and removes the files it read. A file that is JSON but not a record becomes an invalid entry, so it is kept. A file that is not JSON stays in the folder, with the folder, and each read reports that the folder stays, until the user removes it. A read before that first write reads the old folder, so nothing disappears after the update. The staging folders `.topics-*` that a writer left when it crashed before the update go with the folder.
- The record lock, the edit lock and the merge by JSON key stay as ADR 0032 says. A program that writes `topics.json` holds the exclusive lock while it reads, changes and replaces the file.
