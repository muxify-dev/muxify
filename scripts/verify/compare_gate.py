"""The gate of the compare run: do the two versions of the Sessions list give the same rows in the same places?

It reads two dumps of the test driver, one of each version (scripts/verify/compare.py), and needs no app:

    result = judge(list_rows(first_dump), list_rows(second_dump))

`list_rows` keeps the rows with an identifier inside the Sessions list. `judge` matches them between the two versions
by identifier and role. SwiftUI gives a row's identifier to the row's parts, so several rows can share one identifier
and one role: among these, the first of one version matches the first of the other, in the order of the dump.

The gate fails when a row has no match, when a matched pair differs in label, title, value or help, or when their
frames differ by more than TOLERANCE points on an edge. A dump has no named actions, so a shot reads them for the
elements it names, and `judge_actions` fails when their names or their order differ. A missing label and an empty label are different values, as
they are in the dump. A difference in the order of rows with different identifiers does not fail the gate; `judge`
reports it. suites/harness.py checks the matching on made-up rows.
"""

import re

LIST = 'sessions-list'
# A frame may stand this many points away on each edge. A frame is rounded to the display's pixels, half a point on
# a display with two pixels to the point.
TOLERANCE = .5
# What a matched pair must have in common, as the report names it and as the dump names it.
ATTRIBUTES = dict(label='accessibilityLabel', title='accessibilityTitle', value='accessibilityValue',
                  help='accessibilityHelp')
EDGES = ('left', 'top', 'right', 'bottom')


def rect(row):
    """(x, y, width, height) of a dump row's accessibilityFrame, in screen points with the origin at the bottom left;
    None for a row without a frame."""
    numbers = [float(number) for number in re.findall(r'-?[\d.]+', row.get('accessibilityFrame', ''))]
    return tuple(numbers) if len(numbers) == 4 else None


def list_rows(rows):
    """The rows of a dump that the gate compares: the Sessions list and every row inside it that has an identifier,
    in the order of the dump. Each is a dict with `identifier`, `role`, the ATTRIBUTES (None when the dump has
    none) and `frame`: (left, top, right, bottom) in points from the top left corner of the App Window, so the App
    Window may stand in another place on the screen in the two versions. Empty when the dump has no Sessions list,
    as while Topics shows: the Sidebar hides the page that does not show from accessibility."""
    start = next((index for index, row in enumerate(rows) if row.get('accessibilityIdentifier') == LIST), None)
    if start is None:
        return []
    depth = int(rows[start]['depth'])
    inside = [rows[start]]
    for row in rows[start + 1:]:
        if int(row['depth']) <= depth:
            break
        inside.append(row)
    # The App Window is the row without a parent that the Sessions list follows.
    window = next((rect(row) for row in reversed(rows[:start]) if int(row['depth']) == 0), None) or (0, 0, 0, 0)
    found = []
    for row in inside:
        if not row.get('accessibilityIdentifier'):
            continue
        frame = rect(row)
        if frame:
            x, y, width, height = frame
            left, top = x - window[0], window[1] + window[3] - (y + height)
            frame = (left, top, left + width, top + height)
        found.append(dict(identifier=row['accessibilityIdentifier'], role=row.get('accessibilityRole'), frame=frame,
                          **{name: row.get(key) for name, key in ATTRIBUTES.items()}))
    return found


def describe(frame):
    """A frame as the report shows it: where its left top corner stands in the App Window, and its size."""
    if frame is None:
        return 'no frame'
    left, top, right, bottom = frame
    return 'x %g, y %g, %g × %g' % (left, top, right - left, bottom - top)


def judge(first, second):
    """Matches the rows of two versions, each as `list_rows` gives them. Returns a dict:

    - `rows`: how many rows each version has, as [first, second].
    - `failed`: one dict for each difference that fails the gate, with `row` (the identifier and role, and the row's
      number among the rows that share them), `what` (no match, label, title, value, help or frame) and the values
      of the two versions, `first` and `second`. Empty when the gate passes.
    - `order`: None when the rows that match stand in the same order in both versions. Else a dict with the rows
      in the order of each version, `first` and `second`. It does not fail the gate.
    """
    def grouped(rows):
        groups = {}
        for row in rows:
            groups.setdefault((row['identifier'], row['role']), []).append(row)
        return groups

    def name(key, number, count):
        identifier, role = key
        return '%s (%s)%s' % (identifier, role or 'no role', ' #%d' % (number + 1) if count > 1 else '')

    ours, theirs = grouped(first), grouped(second)
    failed = []
    for key in list(ours) + [key for key in theirs if key not in ours]:
        a, b = ours.get(key, []), theirs.get(key, [])
        count = max(len(a), len(b))
        for number in range(count):
            row = name(key, number, count)
            if number >= len(a) or number >= len(b):
                present = a[number] if number < len(a) else b[number]
                shown = '%s, at %s' % (', '.join('%s %r' % (attribute, present[attribute]) for attribute in ATTRIBUTES
                                                 if present[attribute] is not None) or 'no text',
                                       describe(present['frame']))
                failed.append(dict(row=row, what='no match', first=shown if number < len(a) else None,
                                   second=shown if number < len(b) else None))
                continue
            one, other = a[number], b[number]
            for attribute in ATTRIBUTES:
                if one[attribute] != other[attribute]:
                    failed.append(dict(row=row, what=attribute, first=one[attribute], second=other[attribute]))
            if one['frame'] != other['frame']:
                moved = EDGES if one['frame'] is None or other['frame'] is None else [
                    edge for edge, here, there in zip(EDGES, one['frame'], other['frame'])
                    if abs(here - there) > TOLERANCE + 1e-9]
                if moved:
                    failed.append(dict(row=row, what='frame', first=describe(one['frame']),
                                       second=describe(other['frame']), edges=list(moved)))

    # The order of the rows that have a match. Rows that share an identifier and a role count as one place.
    def order(rows, others):
        seen = []
        for row in rows:
            key = (row['identifier'], row['role'])
            if key in others and key not in seen:
                seen.append(key)
        return [name(key, 0, 1) for key in seen]
    places = order(first, theirs), order(second, ours)
    return dict(rows=[len(first), len(second)], failed=failed,
                order=None if places[0] == places[1] else dict(first=places[0], second=places[1]))


def judge_actions(first, second):
    """Compares the named accessibility actions of two versions. Each is a dict that a shot's measure gives: for each
    identifier, a list with the names of each element's named actions, in the order of the dump (None or {} for a
    shot that reads none). Returns one failed dict for each identifier whose names, or their order, differ in the two
    versions, as `judge` gives a failed row: `row`, `what` and the two values `first` and `second`."""
    first, second = first or {}, second or {}

    def shown(found):
        if found is None:
            return None
        return ' '.join('[%s]' % ', '.join(names) for names in found) if found else 'no element'

    return [dict(row=key, what='named actions', first=shown(first.get(key)), second=shown(second.get(key)))
            for key in list(first) + [key for key in second if key not in first] if first.get(key) != second.get(key)]
